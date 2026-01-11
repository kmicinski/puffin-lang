#lang racket


(provide interp-CEK)


; Define interp-cek, a tail recursive (small-step) interpreter for the language:
;;;  e ::= (lambda (x) e)
;;;      | (e e)
;;;      | x
;;;      | (let ([x e]) e)   
;;;      | (call/cc e) 
;;;      | (if e e e)
;;;      | (and e e)
;;;      | (or e e)
;;;      | (not e)
;;;      | b
;;;  x ::= < any variable satisfying symbol? >
;;;  b ::= #t | #f

; You can use (error ...) to handle errors, but will only be tested on
; on correct inputs. The language should be evaluated as would the same subset 
; of Scheme/Racket. In order to implement call/cc properly, your interpreter
; must implement a stack (as opposed to using Racket's stack by making the
; interpreter directly recursive) yourself and then allow whole stacks to be
; used as first-class values, captured via the call/cc form. Because your 
; interpreter implements its own stack, it does not use Racket's stack,
; and so every call to interp-CEK must be in tail position!
; Use symbol 'halt for an initial, empty stack. When a value is returned
; to the 'halt continuation, that value is finally returned from interp-CEK.
; For first-class continuations, use a tagged `(kont ,k) form where k is the
; stack, just as in the CE interpreter you used a tagged `(closure ,lam ,env)
; form for representing closures.

; For example:
;;; (interp-CEK `(call/cc (lambda (k) (and (k #t) #f))) (hash) 'halt)
; should yield a value equal? to #t, and
;;; (interp-CEK `(call/cc (lambda (k0) ((call/cc (lambda (k1) (k0 k1))) #f))) (hash) 'halt)
; should yield a value equal? to `(kont (ar #f ,(hash 'k0 '(kont halt)) halt))


(define (interp-CEK cexp [env (hash)] [kont 'halt])
  (define (return kont v)
    (match kont
           [`(notk ,k)
            (return k (not v))]
           [`(andk ,e0 ,env ,k)
            (if v
                (interp-CEK e0 env k)
                (return k v))]
           [`(ork ,e0 ,env ,k)
            (if v
                (return k v)
                (interp-CEK e0 env k))]
           [`(letk ,x ,body ,env ,k)
            (interp-CEK body (hash-set env x v) k)]
           [`(fn (closure (lambda (,x) ,body) ,env) ,k)
            (interp-CEK body (hash-set env x v) k)]
           [`(fn (kont ,k) ,_)
            (return k v)]
           [`(ar ,e0 ,env ,k)
            (interp-CEK e0 env `(fn ,v ,k))]
           [`(ifk ,then ,else ,env ,k)
            (if v
                (interp-CEK then env k)
                (interp-CEK else env k))]
           [`(callcck ,k)
            (return `(fn ,v ,k) `(kont ,k))]
           ['halt
            v]))
  (match cexp
         [`(call/cc ,e)
          (interp-CEK e env `(callcck ,kont))]
         [`(let ([,x ,rhs]) ,body)
          (interp-CEK rhs env `(letk ,x ,body ,env ,kont))]
         [`(if ,guard ,then ,else)
          (interp-CEK guard env `(ifk ,then ,else ,env ,kont))]
         [`(and ,e0 ,e1)
          (interp-CEK e0 env `(andk ,e1 ,env ,kont))]
         [`(or ,e0 ,e1)
          (interp-CEK e0 env `(ork ,e1 ,env ,kont))]
         [`(not ,e0)
          (interp-CEK e0 env `(notk ,kont))]
         [(? boolean? b)
          (return kont b)]
         [`(lambda (,x) ,body)
          (return kont `(closure ,cexp ,env))]
         [`(,fun ,arg)
          (interp-CEK fun env `(ar ,arg ,env ,kont))]
         [(? symbol? x)
          (return kont (hash-ref env x (lambda () (error "Variable not bound."))))]
         [else (error (format "Exp not recognized: ~a" cexp))]))

