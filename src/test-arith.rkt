#lang racket
;; Checked-arithmetic contract: applying + - * or a comparison to a
;; non-integer is a RUNTIME ERROR naming the operator and the value —
;; byte-identical on every route — never a silently-computed garbage
;; word (the "#<unknown:N>" bug). The value slips past the checker
;; through _ (gradual), so the runtime check is the load-bearing net.
;;
;;   racket src/test-arith.rkt
;;
;; Routes: reference interp (bin/puffin -i), the bytecode VM
;; (bin/puffin -c -t bytecode + bin/puffin-vm), and the native
;; backend (bin/puffin -c, default/host target). When build/puffincc
;; exists (bin/build-puffincc), the same cases also compile through
;; puffincc's own native backend, proving the two compilers match.

(define here (path-only (path->complete-path (find-system-path 'run-file))))
(define (repo p) (build-path here 'up p))

(define cases
  ;; (source expected-stderr-line)
  (list
   (list "(define (foo a [b : Int] c) (+ a b c)) (println (foo 1 5 \"Hello\"))"
         "puffin runtime error: +: expected Int, got Hello")
   (list "(define (f x) (* 2 x)) (println (f 'oops))"
         "puffin runtime error: *: expected Int, got oops")
   (list "(define (g x) (if (< x 10) 'small 'big)) (println (g \"nine\"))"
         "puffin runtime error: <: expected Int, got nine")
   (list "(define (h x) (- x)) (println (h #t))"
         "puffin runtime error: -: expected Int, got #t")))

(define (run/capture-stderr cmd . args)
  (define-values (proc out in err)
    (apply subprocess #f #f #f cmd args))
  (close-output-port in)
  (define err-text (port->string err))
  (port->string out)
  (subprocess-wait proc)
  err-text)

(define failures 0)
(define tmp (find-system-path 'temp-dir))
(define puffincc
  (let ([p (repo "build/puffincc")])
    (and (file-exists? p) p)))

(for ([c cases] [i (in-naturals)])
  (match-define (list src expected) c)
  (define f (build-path tmp (format "arith-~a-~a.puf" (current-milliseconds) i)))
  (call-with-output-file f #:exists 'replace (λ (p) (displayln src p)))
  ;; route 1: reference interpreter
  (define e1 (run/capture-stderr (repo "bin/puffin") "-i" (path->string f)))
  (unless (string-contains? e1 expected)
    (set! failures (add1 failures))
    (printf "FAIL [interp] ~a\n  expected: ~a\n  stderr:   ~a\n" src expected e1))
  ;; route 2: bytecode VM
  (define pbc (path-replace-extension f ".pbc"))
  (run/capture-stderr (repo "bin/puffin") "-c" "-t" "bytecode"
                      "-o" (path->string pbc) (path->string f))
  (define e2 (run/capture-stderr (repo "bin/puffin-vm") (path->string pbc)))
  (unless (string-contains? e2 expected)
    (set! failures (add1 failures))
    (printf "FAIL [bytecode] ~a\n  expected: ~a\n  stderr:   ~a\n" src expected e2))
  ;; route 3: native (default/host target); the tag checks live in
  ;; the emitted code itself (backend-arm64.rkt / backend-x86.rkt)
  (define exe (path-replace-extension f ""))
  (run/capture-stderr (repo "bin/puffin") "-c"
                      "-o" (path->string exe) (path->string f))
  (define e3 (run/capture-stderr exe))
  (unless (string-contains? e3 expected)
    (set! failures (add1 failures))
    (printf "FAIL [native] ~a\n  expected: ~a\n  stderr:   ~a\n" src expected e3))
  ;; route 4 (when built): puffincc's own native backend
  ;; (puffincc-src/backends.puf) must die with the same bytes
  (when puffincc
    (define exe2 (path-add-extension exe ".pcc" "_"))
    (run/capture-stderr puffincc (path->string f) "-o" (path->string exe2))
    (define e4 (run/capture-stderr exe2))
    (unless (string-contains? e4 expected)
      (set! failures (add1 failures))
      (printf "FAIL [puffincc-native] ~a\n  expected: ~a\n  stderr:   ~a\n" src expected e4))))

(define n-routes (if puffincc 4 3))
(unless puffincc
  (printf "note: build/puffincc not present; skipped the puffincc-native route\n"))
(if (zero? failures)
    (printf "arith tests: all passed (~a cases x ~a routes)\n" (length cases) n-routes)
    (begin (printf "~a failures\n" failures) (exit 1)))
