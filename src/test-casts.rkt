#lang racket

;; Puffin -- test-casts.rkt: the transient casts' runtime behavior
;; (docs/TYPES.md §4). test-types.rkt covers the CHECKER's verdicts;
;; these are the DYNAMIC verdicts: a value crossing a declared
;; boundary under a lie must die with the right blame, byte-identical
;; on every route (reference interpreter, Racket->VM bytecode,
;; puffincc->VM bytecode; the canonical case also runs native).
;; Casts must also NOT fire across `_` chains that stay consistent.
;;
;; Run: racket src/test-casts.rkt
;; Needs: bin/puffin-vm (make -C src/vm) and build/puffincc
;; (bin/build-puffincc) for the compiled routes.

(require racket/runtime-path)

(define-runtime-path here ".")
(define repo (simplify-path (build-path here 'up)))
(define (bin p) (path->string (build-path repo "bin" p)))
(define puffincc (path->string (build-path repo "build" "puffincc")))

(define failures 0)
(define checks 0)

(define (run! cmd . args)
  ;; -> (values exit-code stdout stderr)
  (define-values (proc out in err)
    (apply subprocess #f #f #f cmd args))
  (close-output-port in)
  (define so (port->string out))
  (define se (port->string err))
  (subprocess-wait proc)
  (values (subprocess-status proc) so se))

(define (check! route name expected-exit expected-out expected-err got-exit got-out got-err)
  (set! checks (add1 checks))
  (unless (and (equal? got-exit expected-exit)
               (equal? got-out expected-out)
               (equal? got-err expected-err))
    (set! failures (add1 failures))
    (eprintf "FAIL [~a] ~a\n  expected exit ~a out ~s err ~s\n  got      exit ~a out ~s err ~s\n"
             route name expected-exit expected-out expected-err
             got-exit got-out got-err)))

;; a cast failure is pf_fatal's line on stderr + exit 255, identical
;; from every compiler and the reference interpreter
(define (fatal-line msg) (string-append "puffin runtime error: " msg "\n"))

(define (case! name source
               #:exit expected-exit #:out expected-out #:err expected-err
               #:native? [native? #f])
  ;; a FIXED filename: blame labels now carry [file:line] positions,
  ;; so the expected strings need a deterministic basename (the cases
  ;; run serially; no collision)
  (define src (build-path (find-system-path 'temp-dir) "puffin-cast.puf"))
  (with-output-to-file src #:exists 'replace (λ () (display source)))
  (define pbc-r (path-replace-extension src ".rkt.pbc"))
  (define pbc-p (path-replace-extension src ".pcc.pbc"))
  ;; route 1: reference interpreter
  (let-values ([(ec so se) (run! (bin "puffin") "-i" (path->string src))])
    (check! 'interp name expected-exit expected-out expected-err ec so se))
  ;; route 2: Racket bytecode backend -> VM
  (let-values ([(ec so se) (run! (bin "puffin") "-t" "bytecode" (path->string src))])
    (check! 'racket-vm name expected-exit expected-out expected-err ec so se))
  ;; route 3: puffincc bytecode backend -> VM
  (let-values ([(ec so se) (run! puffincc (path->string src) "-t" "bytecode"
                                 "-o" (path->string pbc-p))])
    (cond
      [(zero? ec)
       (let-values ([(ec so se) (run! (bin "puffin-vm") (path->string pbc-p))])
         (check! 'puffincc-vm name expected-exit expected-out expected-err ec so se))]
      [else (check! 'puffincc-vm name 0 "compiles" "" ec so se)]))
  ;; route 4 (optional): native arm64 via the Racket backend
  ;; (compile-and-run in one step; bin/puffin execs the binary)
  (when native?
    (let-values ([(ec so se) (run! (bin "puffin") (path->string src))])
      (check! 'native name expected-exit expected-out expected-err ec so se)))
  (for ([f (list src pbc-r pbc-p)])
    (when (file-exists? f) (delete-file f))))

;; ---------------------------------------------------------------------
;; the canonical lie: a typed function reached through `_` with a Bool
;; (all four routes; the blame names the function's formal)
;; ---------------------------------------------------------------------
(case! "canonical lie"
       "(define (f [x : Int]) : Int (* x 2))
        (define g (ann f _))
        (g #t)"
       #:exit 255 #:out ""
       #:err (fatal-line "cast: expected Int, got #t (blame: f's argument x [puffin-cast.puf:1])")
       #:native? #t)

;; ADT cast: (Some 5) passes an (Option Int) boundary...
(case! "adt pass"
       "(define-type (Option a) (None) (Some a))
        (define (get [o : (Option Int)]) : Int (match o [(Some x) x] [None 0]))
        (println (get (Some 5)))"
       #:exit 0 #:out "5\n" #:err "")

;; ...but a Shape instance fails it, blaming the argument
(case! "adt fail"
       "(define-type (Option a) (None) (Some a))
        (define-type Shape (Circle Int) (Square Int))
        (define (get [o : (Option Int)]) : Int (match o [(Some x) x] [None 0]))
        (define sneak (ann Circle _))
        ((ann get _) (sneak 3))"
       #:exit 255 #:out ""
       #:err (fatal-line "cast: expected (Option Int), got (Circle 3) (blame: get's argument o [puffin-cast.puf:3])"))

;; result-position blame: the body trusts a `_` value that lied
(case! "result blame"
       "(define lies (ann (lambda () \"nope\") _))
        (define (f) : Int (lies))
        (println (f))"
       #:exit 255 #:out ""
       #:err (fatal-line "cast: expected Int, got nope (blame: f's result [puffin-cast.puf:2])"))

;; (ann ...) blame
(case! "ann blame"
       "(define u (ann #t _))
        (println (ann u Sym))"
       #:exit 255 #:out ""
       #:err (fatal-line "cast: expected Sym, got #t (blame: ann [puffin-cast.puf:2])"))

;; annotated let binding blame
(case! "let blame"
       "(define v (ann \"str\" _))
        (let ([x : Int (ann v _)]) (println x))"
       #:exit 255 #:out ""
       #:err (fatal-line "cast: expected Int, got str (blame: let x [puffin-cast.puf:2])"))

;; declared value define blame
(case! "define blame"
       "(: total Int)
        (define total (ann \"x\" _))
        (println total)"
       #:exit 255 #:out ""
       #:err (fatal-line "cast: expected Int, got x (blame: define total [puffin-cast.puf:2])"))

;; a (: f (-> ...)) declaration alone inserts the same entry casts
(case! "declared arrow blame"
       "(: dbl (-> Int Int))
        (define (dbl n) (+ n n))
        ((ann dbl _) 'seven)"
       #:exit 255 #:out ""
       #:err (fatal-line "cast: expected Int, got seven (blame: dbl's argument n [puffin-cast.puf:2])"))

;; variadic: declared ->* fixed formals are checked
(case! "variadic blame"
       "(define (f [a : Int] . r) : Int (+ a (length r)))
        ((ann f _) \"s\" 1 2)"
       #:exit 255 #:out ""
       #:err (fatal-line "cast: expected Int, got s (blame: f's argument a [puffin-cast.puf:1])"))

;; casts must NOT fire across `_` chains that stay consistent, and
;; container/adt shapes must pass positively
(case! "consistent chains: no cast fires"
       "(define (id x) x)
        (define (f [n : Int]) : Int (id n))
        (println (f (ann (id 21) _)))
        (: g (-> Int (List Int)))
        (define (g n) (list n n))
        (println (g 4))
        (define-type (Box a) (B a))
        (define (open [b : (Box Int)]) : Int (match b [(B x) x]))
        (println (open (ann (B 7) _)))
        (let ([v : (Vec Int) (ann (vector 1 2) _)])
          (println (vector-ref v 1)))"
       #:exit 0 #:out "21\n(4 4)\n7\n2\n" #:err "")

(if (zero? failures)
    (printf "cast tests: all passed (~a checks)\n" checks)
    (begin (printf "cast tests: ~a/~a FAILED\n" failures checks) (exit 1)))
