#lang racket 

;; Please do not change (or at least, ask before you do)

;; This file abstracts common flags and abstracts around ABI-level
;; details.

(provide (all-defined-out))
(require racket/system)

(define asm-file (make-parameter "./output.s"))
(define object-file (make-parameter "./output.o"))
(define executable-file (make-parameter "./output"))
(define runtime-file (make-parameter "./runtime.c"))
(define runtime-object-file (make-parameter "./runtime.o"))
(define run-test-mode (make-parameter #f))
(define start-pass (make-parameter "typecheck")) ;; synced with main.rkt
(define end-pass (make-parameter "render-x86"))  ;; synced with main.rkt
(define write-stdout-mode (make-parameter #t))
(define debug-server-mode (make-parameter #f))
(define verbose-mode (make-parameter #t))
(define intermediate-ir (make-parameter #f))
(define test-mode (make-parameter "native"))
(define input-file (make-parameter #f))

(define (yesno b?) (if b? "YES" "NO")) ;; pretty terminal output

(define (host-os)      (system-type 'os))       ; 'macosx or 'unix (Linux/BSD)
(define (host-arch)    (system-type 'machine))  ; 'x86_64, 'aarch64, ...

(define (entry-symbol) 'main)
(define (conclusion-block-name)   'conclusion)

;; Turn a string into its "runtime symbol" version: on OSX, names need
;; to be prefixed with _, but not on Linux.
(define (rt-sym s)
  (if (equal? (host-os) 'macosx)
      (macify s)
      (linuxify s)))

;; have to include these extern definitions at the top of the file 
(define (runtime-function-externs)
  (define l '(read_int64 print_int64))
  (apply string-append (map (λ (x) (format ".extern ~a\n" (symbol->string (rt-sym x)))) l)))

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

(define (execute-get-output cmd)
  (define args (string-split cmd))
  ;; Start subprocess with pipes for stdout+stderr
  (displayln cmd)
  (define-values (sp out in err)
    (apply subprocess #f #f #f (car args) (cdr args)))
  (subprocess-wait sp)
  (define out-str (if out (port->string out) ""))
  (define err-str (if err (port->string err) ""))
  (when out (close-input-port out))
  (when in  (close-output-port in))
  (when err (close-input-port err))
  (string-append out-str err-str))

;; Get a thunk's output alongside its stdout
(define (run/capture thunk)
  (define out (open-output-string))
  (define err (open-output-string))
  (define v (parameterize ([current-output-port out] [current-error-port err]) (thunk)))
  (cons v (string-append (get-output-string out) (if (equal? (get-output-string err) "")
                                                     ""
                                                     (format " stderr: ~a" (get-output-string err))))))
