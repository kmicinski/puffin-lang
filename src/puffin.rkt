#lang racket

;; Puffin -- puffin.rkt: the day-to-day command-line entry point.
;;
;;   puffin                          the REPL
;;   puffin prog.puf                 compile natively and run
;;   puffin -i prog.puf              interpret (fast startup, same semantics)
;;   puffin -c prog.puf -o prog      compile to an executable
;;   puffin -c --module foo.puf      separate compilation: build one module
;;                                   (+ stale deps) into build-cache/
;;   puffin -c --separate main.puf -o prog
;;                                   compile every DAG module separately
;;                                   (cached) and link (docs/MODULES.md §3)
;;   puffin -t x86-64 ...            pick a target (default: host)
;;
;; bin/puffin wraps this in a shell script.

(require "system.rkt")
(require "compile.rkt")
(require "interpreters.rkt")
(require "main.rkt")
(require "repl.rkt")
(require "separate.rkt")

(define compile-only (make-parameter #f))
(define interp-mode (make-parameter #f))
(define output-path (make-parameter #f))
(define module-mode (make-parameter #f))
(define separate-mode (make-parameter #f))

(define (compile-to file out)
  (parameterize ([write-stdout-mode #f]
                 [verbose-mode #f]
                 [executable-file out]
                 ;; unique per process: concurrent compiles (test harness,
                 ;; background builds) must never share intermediates
                 [asm-file (path->string (build-path (find-system-path 'temp-dir)
                                                     (format "puffin-cli-~a.s" (current-milliseconds))))]
                 [object-file (path->string (build-path (find-system-path 'temp-dir)
                                                        (format "puffin-cli-~a.o" (current-milliseconds))))])
    (match (run/capture (λ () (run-assembler-linker (read-program-file file))))
      [(cons `(err ,_) out-str)
       (displayln out-str (current-error-port))
       (eprintf "puffin: compilation failed\n")
       (exit 1)]
      [_ (void)])))

(define (run-file file)
  (define exe (build-path (find-system-path 'temp-dir) (format "puffin-run-~a" (current-milliseconds))))
  (compile-to file (path->string exe))
  (define code (system/exit-code (format "~a" exe)))
  (delete-file exe)
  (exit code))

(define (interp-file file)
  (with-handlers ([exn:fail? (λ (e) (eprintf "error: ~a\n" (exn-message e)) (exit 1))])
    ;; live stdin for (read), like a native run
    (interpret-puffin (desugar (read-program-file file)) 'stdin))
  (exit 0))

(module+ main
  (define file
    (command-line
     #:program "puffin"
     #:once-each
     [("-c" "--compile") "Compile only (with -o)" (compile-only #t)]
     [("--module") "With -c: compile one module to build-cache/ (.o + .pufi)"
                   (module-mode #t)]
     [("--separate") "With -c: separate compilation of the whole DAG, then link"
                     (separate-mode #t)]
     [("-i" "--interp") "Interpret instead of compiling" (interp-mode #t)]
     [("-o" "--output") out "Executable output path" (output-path out)]
     [("-t" "--target") tgt "Target architecture: x86-64 or arm64" (target (string->symbol tgt))]
     [("-O" "--optimize") lvl "Optimization level: 0, 1 (default), 2" (optimize-level (string->number lvl))]
     #:args leftover
     (match leftover
       ['() #f]
       [(list f) f]
       [_ (error 'puffin "expected at most one <file>")])))
  (cond
    [(not file) (run-repl)]
    [(interp-mode) (interp-file file)]
    [(module-mode)
     (define info (build-module file))
     (printf "~a\n~a\n"
             (hash-ref info 'o-path)
             (path-replace-extension (hash-ref info 'o-path) ".pufi"))]
    [(separate-mode)
     (build-separate file (or (output-path)
                              (path->string (path-replace-extension file ""))))]
    [(compile-only)
     (compile-to file (or (output-path) (path->string (path-replace-extension file ""))))]
    [else (run-file file)]))
