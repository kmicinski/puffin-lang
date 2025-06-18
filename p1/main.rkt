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

(define (run-compiler input-tree)
  (displayln "Compiling using compiler.rkt -> x86_64")
  (define output-assembly (compile input-tree))
  ;; write the output file
  (with-output-to-file (asm-file) #:exists 'replace
    (λ () (displayln output-assembly)))
  ;; Assemble the output file
  (displayln "Assembling file to executable...")
  (execute-get-output (format "clang -target x86_64-apple-darwin -c ~a -o ~a " (asm-file) (object-file)))
  (execute-get-output (format "clang -target x86_64-apple-darwin -c ~a -o ~a " (runtime-file) (runtime-object-file)))
  (execute-get-output (format "clang -target x86_64-apple-darwin ~a ~a -o ~a" (object-file) (runtime-object-file) (executable-file)))
  (displayln (format "Executable now at ~a" (executable-file))))

(define (main)
  (define source-tree (with-input-from-file file-path read))
  (run-compiler source-tree))

(main)
