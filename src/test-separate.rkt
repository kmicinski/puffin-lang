#lang racket

;; Puffin -- test-separate.rkt: separate compilation (docs/MODULES.md
;; §3) against the same goldens as every other route, plus the
;; §3-specific behaviors: incremental rebuilds keyed on source hash +
;; interface digests, init-once across a double diamond, and the
;; TYPED .pufi interface (§3.2): cross-unit imports typecheck at
;; their interface types (misuse is a compile-time error with
;; demangled names), imported ADTs match/warn/cast exactly like
;; whole-program ones, and type-level signature changes recompile
;; dependents while body-only edits still don't.
;;
;;   racket src/test-separate.rkt          (arm64 hosts only)

(require rackunit
         rackunit/text-ui
         racket/runtime-path)
(require "system.rkt"
         "separate.rkt")

(define-runtime-path here ".")
(define tests-dir  (build-path here "test-programs"))
(define inputs-dir (build-path here "input-files"))
(define goldens-dir (build-path here "goldens"))

;; every test works in a fresh scratch area
(define work-root (build-path (find-system-path 'temp-dir)
                              (format "puffin-sep-tests-~a" (current-milliseconds))))
(make-directory* work-root)

(define (fresh-dir name)
  (define d (build-path work-root name))
  (make-directory* d)
  d)

(define (run-exe exe input-string)
  (define-values (sp out in err) (subprocess #f #f #f exe))
  (with-handlers ([exn:fail? (λ (_) (void))])
    (display input-string in)
    (close-output-port in))
  (define stdout (port->string out))
  (define stderr (port->string err))
  (subprocess-wait sp)
  (close-input-port out) (close-input-port err)
  (string-append stdout stderr))

;; build entry -> exe inside cache-dir, logging rebuilt module paths
(define (build! entry exe cache-dir)
  (define log (box '()))
  (parameterize ([build-cache-root cache-dir]
                 [modules-rebuilt-log log])
    (build-separate entry (path->string exe)))
  (reverse (unbox log)))

(define (rebuilt-stems rebuilt)
  (sort (for/list ([p rebuilt])
          (path->string (path-replace-extension (file-name-from-path p) "")))
        string<?))

;; ---------------------------------------------------------------------
;; 1) modules-1..6 through --separate match their goldens
;; ---------------------------------------------------------------------

(define (golden prog input)
  (define p (build-path goldens-dir (format "~a_~a.golden" prog input)))
  (and (file-exists? p) (file->string p)))

(define (input-string input)
  (file->string (build-path inputs-dir (format "~a.in" input))))

(define (corpus-tests)
  (test-suite
   "modules corpus via separate compilation"
   (let ([cache (fresh-dir "cache-corpus")])
     (for ([prog (append (for/list ([n (in-range 1 7)]) (format "modules-~a" n))
                         ;; typed interfaces end-to-end: imported type
                         ;; annotations (plain and #:as-qualified),
                         ;; imported-constructor patterns incl. a bare
                         ;; nullary, an own define-type over an
                         ;; imported field type -- same goldens as
                         ;; every whole-program route
                         (list "modules-typed"))])
       (define entry (build-path tests-dir prog "main.puf"))
       (define exe (build-path work-root (format "exe-~a" prog)))
       (build! entry exe cache)
       (for ([input '(1 2 3)])
         (define g (golden prog input))
         (when g
           (test-equal? (format "~a/~a" prog input)
                        (string-trim (run-exe exe (input-string input)))
                        (string-trim g))))))))

;; ---------------------------------------------------------------------
;; 2) staleness: a dep's BODY edit rebuilds only that dep (its
;;    interface digest is unchanged, so nothing downstream recompiles);
;;    an untouched tree rebuilds nothing at all
;; ---------------------------------------------------------------------

(define (staleness-tests)
  (test-suite
   "incremental rebuilds"
   (let* ([tree (fresh-dir "stale-tree")]
          [cache (fresh-dir "cache-stale")]
          [exe (build-path work-root "exe-stale")])
     (for ([f (directory-list (build-path tests-dir "modules-2"))])
       (copy-file (build-path tests-dir "modules-2" f) (build-path tree f)))
     (define entry (build-path tree "main.puf"))
     ;; cold build: everything compiles (prelude, d, b, c, main)
     (test-equal? "cold build compiles every module"
                  (rebuilt-stems (build! entry exe cache))
                  '("b" "c" "d" "main" "prelude"))
     ;; warm build: nothing recompiles
     (test-equal? "warm build compiles nothing"
                  (build! entry exe cache)
                  '())
     ;; body-only edit of d.puf (same forms + a comment changes the
     ;; source sha but not the interface): only d recompiles
     (define d-path (build-path tree "d.puf"))
     (define d-src (file->string d-path))
     (with-output-to-file d-path #:exists 'replace
       (λ () (display (string-append ";; touched\n" d-src))))
     (test-equal? "dep body edit rebuilds only the dep"
                  (rebuilt-stems (build! entry exe cache))
                  '("d"))
     (test-equal? "the relinked program still runs"
                  (string-trim (run-exe exe ""))
                  "init-d\ninit-b\ninit-c\ninit-main\n23")
     ;; interface edit of d.puf (a new provided value define): d AND
     ;; its dependents (b, c, and the entry) recompile
     (with-output-to-file d-path #:exists 'replace
       (λ () (display (string-append d-src "(define base2 20)\n"))))
     (test-equal? "dep interface edit rebuilds dependents"
                  (rebuilt-stems (build! entry exe cache))
                  '("b" "c" "d" "main"))
     (test-equal? "still runs after the interface change"
                  (string-trim (run-exe exe ""))
                  "init-d\ninit-b\ninit-c\ninit-main\n23"))))

;; ---------------------------------------------------------------------
;; 3) double diamond: two stacked diamonds over a shared base whose
;;    init prints -- it must run exactly once, in postorder position
;; ---------------------------------------------------------------------

(define (write-module! dir name . lines)
  (with-output-to-file (build-path dir name) #:exists 'replace
    (λ () (for ([l lines]) (displayln l)))))

(define (diamond-tests)
  (test-suite
   "double-diamond init-once"
   (let* ([tree (fresh-dir "diamond-tree")]
          [cache (fresh-dir "cache-diamond")]
          [exe (build-path work-root "exe-diamond")])
     ;; main -> a, b -> mid -> c, d -> base   (two diamonds sharing base)
     (write-module! tree "base.puf"
                    "(provide origin)"
                    "(println 'init-base)"
                    "(define origin 100)")
     (write-module! tree "c.puf"
                    "(provide via-c)"
                    "(require \"base.puf\")"
                    "(println 'init-c)"
                    "(define (via-c) (+ origin 1))")
     (write-module! tree "d.puf"
                    "(provide via-d)"
                    "(require \"base.puf\")"
                    "(println 'init-d)"
                    "(define (via-d) (+ origin 2))")
     (write-module! tree "mid.puf"
                    "(provide mid-sum)"
                    "(require \"c.puf\")"
                    "(require \"d.puf\")"
                    "(println 'init-mid)"
                    "(define (mid-sum) (+ (via-c) (via-d)))")
     (write-module! tree "a.puf"
                    "(provide via-a)"
                    "(require \"mid.puf\")"
                    "(println 'init-a)"
                    "(define (via-a) (+ (mid-sum) 10))")
     (write-module! tree "b.puf"
                    "(provide via-b)"
                    "(require \"mid.puf\")"
                    "(println 'init-b)"
                    "(define (via-b) (+ (mid-sum) 20))")
     (write-module! tree "main.puf"
                    "(require \"a.puf\")"
                    "(require \"b.puf\")"
                    "(println 'init-main)"
                    "(println (+ (via-a) (via-b)))")
     (build! (build-path tree "main.puf") exe cache)
     (define out (string-trim (run-exe exe "")))
     (test-equal? "postorder, each init exactly once"
                  out
                  (string-join '("init-base" "init-c" "init-d" "init-mid"
                                 "init-a" "init-b" "init-main" "436")
                               "\n"))
     ;; belt and braces: the guard also holds on a rebuilt binary
     (build! (build-path tree "main.puf") exe cache)
     (test-equal? "identical after a warm rebuild"
                  (string-trim (run-exe exe "")) out))))

;; ---------------------------------------------------------------------
;; 4) typed interfaces (docs/MODULES.md §3.2): the .pufi carries types
;;    across units -- misuse of an imported name is a COMPILE-time
;;    type error with the demangled spelling; an imported ADT match
;;    is exhaustiveness-checked; a cast at a typed boundary blames
;;    across units at runtime
;; ---------------------------------------------------------------------

;; build, capturing (a) an exn message if the build fails, (b) stderr
;; (the exhaustiveness warning channel)
(define (build/catch! entry exe cache)
  (define err (open-output-string))
  (define exn-msg
    (with-handlers ([exn:fail? (λ (e) (exn-message e))])
      (parameterize ([current-error-port err])
        (build! entry exe cache))
      #f))
  (values exn-msg (get-output-string err)))

(define shapes-src
  (list "(provide Shape Point Circle Rect area)"
        "(define-type Shape (Point) (Circle Int) (Rect Int Int))"
        "(define (area [s : Shape]) : Int"
        "  (match s [Point 0] [(Circle r) (* 3 (* r r))] [(Rect w h) (* w h)]))"))

(define (typed-boundary-tests)
  (test-suite
   "typed cross-unit imports"
   (let* ([tree (fresh-dir "typed-tree")]
          [cache (fresh-dir "cache-typed")])
     (apply write-module! tree "shapes.puf" shapes-src)
     ;; a concrete misuse is a compile-time error, demangled
     (write-module! tree "bad.puf"
                    "(require \"shapes.puf\")"
                    "(println (area 5))")
     (define-values (msg1 _err1)
       (build/catch! (build-path tree "bad.puf") (build-path work-root "exe-t-bad") cache))
     (test-true "misuse of an imported typed name fails to compile"
                (and msg1 #t))
     (test-true "and the error carries the demangled type name"
                (and msg1
                     (regexp-match? #rx"typecheck: area: argument has type Int, expected Shape"
                                    msg1)
                     (not (regexp-match? #rx"Shape_shapes" msg1))))
     ;; a correct use admits, runs, and agrees with the source semantics
     (write-module! tree "good.puf"
                    "(require \"shapes.puf\")"
                    "(define (twice [s : Shape]) : Int (* 2 (area s)))"
                    "(println (twice (Rect 3 4)))"
                    "(println (area Point))")
     (define good-exe (build-path work-root "exe-t-good"))
     (define-values (msg2 _err2)
       (build/catch! (build-path tree "good.puf") good-exe cache))
     (test-false "correct use admits" msg2)
     (test-equal? "and computes through the imported constructors"
                  (string-trim (run-exe good-exe "")) "24\n0")
     ;; an inexhaustive match over an IMPORTED ADT warns (demangled)
     (write-module! tree "inex.puf"
                    "(require \"shapes.puf\")"
                    "(define (kind [s : Shape]) : Sym"
                    "  (match s [Point 'dot] [(Circle _) 'round]))"
                    "(println (kind (Circle 1)))")
     (define-values (msg3 err3)
       (build/catch! (build-path tree "inex.puf") (build-path work-root "exe-t-inex") cache))
     (test-false "inexhaustive imported-ADT match still compiles" msg3)
     (test-true "but warns, naming the missing constructor by source spelling"
                (regexp-match? #rx"typecheck warning: match on Shape is not exhaustive: missing Rect"
                               err3))
     ;; an untyped caller lying to a typed function across units: the
     ;; exporter's entry cast fires at runtime, blaming the boundary
     (write-module! tree "blame.puf"
                    "(require \"shapes.puf\")"
                    "(define (h s) (area s))"
                    "(println (h 99))")
     (define blame-exe (build-path work-root "exe-t-blame"))
     (define-values (msg4 _err4)
       (build/catch! (build-path tree "blame.puf") blame-exe cache))
     (test-false "the untyped caller compiles" msg4)
     (test-true "and the cast blames across units, demangled"
                (regexp-match? #rx"cast: expected Shape, got 99 \\(blame: area's argument s\\)"
                               (run-exe blame-exe ""))))))

;; ---------------------------------------------------------------------
;; 5) typed staleness: a dep's TYPE-level signature change (same
;;    provides, same arities -- only a type differs) recompiles
;;    dependents; a body-only edit still rebuilds just the dep
;; ---------------------------------------------------------------------

(define (typed-staleness-tests)
  (test-suite
   "typed incremental rebuilds"
   (let* ([tree (fresh-dir "typed-stale-tree")]
          [cache (fresh-dir "cache-typed-stale")]
          [exe (build-path work-root "exe-typed-stale")])
     (write-module! tree "d.puf"
                    "(provide base scale)"
                    "(define base 10)"
                    "(define (scale [k : Int]) : Int (* k base))")
     (write-module! tree "main.puf"
                    "(require \"d.puf\")"
                    "(println (scale 4))")
     (define entry (build-path tree "main.puf"))
     (test-equal? "cold build compiles everything"
                  (rebuilt-stems (build! entry exe cache))
                  '("d" "main" "prelude"))
     ;; body-only edit: base 10 -> 20. The SYNTHESIZED type (Int) is
     ;; unchanged, so the interface digest holds and main is reused
     (write-module! tree "d.puf"
                    "(provide base scale)"
                    "(define base 20)"
                    "(define (scale [k : Int]) : Int (* k base))")
     (test-equal? "value edit of the same type rebuilds only the dep"
                  (rebuilt-stems (build! entry exe cache))
                  '("d"))
     (test-equal? "and the relinked program sees the new value"
                  (string-trim (run-exe exe "")) "80")
     ;; type-level signature change: scale's argument type Int -> Sym.
     ;; Same provides, same arity -- only the .pufi TYPE changed; the
     ;; digest must change, dependents must recompile, and main's
     ;; (scale 4) is now a compile-time error at the boundary
     (write-module! tree "d.puf"
                    "(provide base scale)"
                    "(define base 20)"
                    "(define (scale [k : Sym]) : Int base)")
     (define-values (msg err)
       (build/catch! entry exe cache))
     (test-true "a type-only signature change reaches the importer"
                (and msg
                     (regexp-match? #rx"typecheck: scale: argument has type Int, expected Sym"
                                    msg))))))

(module+ main
  (unless (eq? (default-target) 'arm64)
    (eprintf "test-separate.rkt: arm64 host required; skipping\n")
    (exit 0))
  (define n
    (+ (run-tests (corpus-tests))
       (run-tests (staleness-tests))
       (run-tests (diamond-tests))
       (run-tests (typed-boundary-tests))
       (run-tests (typed-staleness-tests))))
  (delete-directory/files work-root #:must-exist? #f)
  (exit (if (zero? n) 0 1)))
