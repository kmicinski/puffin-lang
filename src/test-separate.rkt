#lang racket

;; Puffin -- test-separate.rkt: separate compilation (docs/MODULES.md
;; §3) against the same goldens as every other route, plus the
;; §3-specific behaviors: incremental rebuilds keyed on source hash +
;; interface digests, and init-once across a double diamond.
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
     (for ([n (in-range 1 7)])
       (define prog (format "modules-~a" n))
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

(module+ main
  (unless (eq? (default-target) 'arm64)
    (eprintf "test-separate.rkt: arm64 host required; skipping\n")
    (exit 0))
  (define n
    (+ (run-tests (corpus-tests))
       (run-tests (staleness-tests))
       (run-tests (diamond-tests))))
  (delete-directory/files work-root #:must-exist? #f)
  (exit (if (zero? n) 0 1)))
