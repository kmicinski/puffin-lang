#lang racket 

;; Please do not change (or at least, ask before you do)

;; This file contains passes, parameters, and system-specific details

(provide (all-defined-out))
(require racket/runtime-path)
(require racket/system)

(define-runtime-path here-dir ".")         ; path to folder containing this file

(define asm-file (make-parameter "./output.s"))
(define object-file (make-parameter "./output.o"))
(define executable-file (make-parameter "./output"))
(define runtime-file (make-parameter "./runtime.c"))
(define runtime-object-file (make-parameter "./runtime.o"))
(define run-test-mode (make-parameter #f))
(define start-pass "uniqueify") ;; synced with main.rkt
(define end-pass "render-x86")  ;; synced with main.rkt
(define write-stdout-mode (make-parameter #t))
(define debug-server-mode (make-parameter #f))
(define intermediate-ir (make-parameter #f))
(define test-mode (make-parameter "native"))
(define input-file (make-parameter #f))

(define (host-os)      (system-type 'os))       ; 'macosx or 'unix (Linux/BSD)
(define (host-arch)    (system-type 'machine))  ; 'x86_64, 'aarch64, ...
(define (entry-symbol)
  (if (eq? (host-os) 'macosx) '_main 'main))

(define (macify s)
  (define str (symbol->string s))
  (if (and (positive? (string-length str))
           (char=? (string-ref str 0) #\_))
      s
      (string->symbol (string-append "_" str))))

;; Convert a Mac symbol to Linux
(define (linuxify s)
  (define str (symbol->string s))
  (cond [(and (positive? (string-length str))
              (char=? (string-ref str 0) #\_))
         (string->symbol (substring str 1))]
        [else s]))

;; Execute a command and get an output
(define (execute-get-output cmd)
  (displayln (format "Executing `~a`." cmd))
  (with-output-to-string (λ () 
                           (system cmd))))

;; Get a thunk's output alongside its stdout
(define (run/capture thunk)
  (define out (open-output-string))
  (define v (parameterize ([current-output-port out]) (thunk)))
  (cons v (get-output-string out)))
