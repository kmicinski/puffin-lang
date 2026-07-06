#lang racket

;; Puffin -- repl.rkt: the interactive console REPL.
;;
;; Backed by the reference interpreter (the same semantics the
;; compiled code is tested against). Top-level definitions persist
;; across inputs in a mutable environment (repl-toplevel), so
;; mutually recursive functions can be entered one at a time and
;; redefinition works the way you'd expect at a prompt.
;;
;;   puffin> (define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
;;   puffin> (fib 20)
;;   6765
;;
;; Special commands: ,quit  ,help  ,env (list defined names)

(require "system.rkt")
(require "irs.rkt")
(require "stdlib.rkt")
(require "compile.rkt")
(require "interpreters.rkt")

(provide run-repl)

(define (run-repl)
  (define toplevel (make-hash))       ;; name -> box(value)
  (define globals (vector))           ;; unused at the REPL (no collect-globals)
  (define inbox (box 'stdin))
  ;; the names defined so far, so desugar's shadowing logic treats
  ;; them as bound (a REPL define of `cons` shadows the prim)
  (define (top-bound)
    (for/hash ([(k _) (in-hash toplevel)]) (values k k)))
  ;; desugar one interactive form in the context of what's defined
  (define (desugar-form form)
    (match (desugar `(program ,@(for/list ([(k _) (in-hash toplevel)]) `(define ,k 0))
                              ,form))
      [`(program ,forms ...) (last forms)]))
  (define (handle-form form #:echo? [echo? #t])
    ;; a REPL define that shadows a primitive can't rename its later
    ;; uses consistently (each input desugars separately), so reject
    ;; it here; whole files support shadowing fine
    (define raw-name
      (match form
        [`(define (,f ,_ ...) ,_ ...) f]
        [`(define ,(? symbol? x) ,_) x]
        [_ #f]))
    (when (and raw-name (surface-prim? raw-name))
      (error 'repl "~a names a primitive; shadowing works in files but not at the REPL" raw-name))
    (match (desugar-form form)
      [`(define (,f ,xs ...) ,body)
       (hash-set! toplevel raw-name (box (clo xs body (hash))))
       (when echo? (printf "~a\n" raw-name))]
      [`(define ,(? symbol? x) ,e)
       (hash-set! toplevel raw-name (box (eval-puffin-exp e (hash) globals inbox)))
       (when echo? (printf "~a\n" raw-name))]
      [e
       (define v (eval-puffin-exp e (hash) globals inbox))
       (unless (void? v) (displayln (render-value v)))]))
  ;; preload the Puffin-written stdlib layer (silently)
  (parameterize ([repl-toplevel toplevel])
    (for ([form (with-input-from-file (build-path here-dir "prelude.puf")
                  (λ () (let loop ([acc (list)])
                          (define f (read))
                          (if (eof-object? f) (reverse acc) (loop (cons f acc))))))])
      (handle-form form #:echo? #f)))
  (displayln "Puffin REPL. ,help for help; ,quit or ^D to exit.")
  (let loop ()
    (display "puffin> ")
    (flush-output)
    (define form
      (with-handlers ([exn:fail? (λ (e) (displayln (format "read error: ~a" (exn-message e))) '(void))])
        (read)))
    (cond
      [(eof-object? form) (newline)]
      [(equal? form ',quit) (void)]
      [(equal? form ',help)
       (displayln "Enter Puffin forms: expressions evaluate and print; defines persist.")
       (displayln "Commands: ,quit ,help ,env")
       (loop)]
      [(equal? form ',env)
       (displayln (sort (hash-keys toplevel) symbol<?))
       (loop)]
      [else
       (with-handlers ([puffin-error-stop? (λ (_) (void))]
                       [exn:fail? (λ (e) (displayln (format "error: ~a" (exn-message e))))]
                       [exn:break? (λ (_) (displayln "interrupted"))])
         (parameterize ([repl-toplevel toplevel])
           (handle-form form)))
       (loop)])))

(module+ main (run-repl))
