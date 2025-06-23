#lang racket
;; Main compiler entrypoint, handles things like calls to the
;; compiler, linker, etc.
(require racket/system) ; not strictly needed in #lang racket, but explicit is fine
(require "compile.rkt")

(define asm-file (make-parameter "./output.s"))
(define object-file (make-parameter "./output.o"))
(define executable-file (make-parameter "./output"))
(define runtime-file (make-parameter "./runtime.c"))
(define runtime-object-file (make-parameter "./runtime.o"))
(define verbose-mode (make-parameter #t))

(define (execute-get-output cmd)
  (displayln (format "Executing `~a`." cmd))
  (with-output-to-string (λ () 
                           (system cmd))))

(define file-path
  (command-line #:args (filename) filename))

(define (run-compiler source-tree)
  (displayln "Compiling using compile.rkt -> x86_64")
  (define output-string (compile source-tree (verbose-mode)))
  (with-output-to-file (asm-file)
    (λ () (let ([output-text output-string])
            (displayln output-text)))
    #:exists 'replace)
  ;; Assemble the output file
  (displayln "Assembling file to executable...")
  (execute-get-output (format "clang -target x86_64-apple-darwin -c ~a -o ~a " (asm-file) (object-file)))
  (execute-get-output (format "clang -target x86_64-apple-darwin -c ~a -o ~a " (runtime-file) (runtime-object-file)))
  (execute-get-output (format "clang -target x86_64-apple-darwin ~a ~a -o ~a" (object-file) (runtime-object-file) (executable-file)))
  (displayln (format "Executable now at ~a" (executable-file))))

;; Run a single test. Need:
;; - test name (string?)
;; - test file (string?)
;; - to-ir (which-ir?)
;; - golden-output (output file)

(define (main)
  (define source-tree (with-input-from-file file-path read))
  (run-compiler source-tree))

(main)
