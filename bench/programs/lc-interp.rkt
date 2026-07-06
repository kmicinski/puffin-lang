#lang racket
(define (evaluate e env)
  (match e
    [(? fixnum? n) n]
    [(? symbol? x) (hash-ref env x)]
    [`(lambda (,xs ...) ,body) (list 'closure xs body env)]
    [`(if ,g ,t ,f) (if (evaluate g env) (evaluate t env) (evaluate f env))]
    [`(,op ,e0 ,e1) #:when (member op '(+ - * = <))
     (let ([a (evaluate e0 env)] [b (evaluate e1 env)])
       (cond [(eq? op '+) (+ a b)] [(eq? op '-) (- a b)] [(eq? op '*) (* a b)]
             [(eq? op '=) (eqv? a b)] [else (< a b)]))]
    [`(,ef ,eas ...)
     (apply-clo (evaluate ef env) (map (lambda (a) (evaluate a env)) eas))]))
(define (apply-clo f args)
  (match f
    [`(closure ,xs ,body ,env)
     (evaluate body (for/fold ([acc env]) ([x xs] [v args]) (hash-set acc x v)))]))
(define Z '(lambda (f) ((lambda (x) (f (lambda (v) ((x x) v))))
                        (lambda (x) (f (lambda (v) ((x x) v)))))))
(displayln (evaluate `((,Z (lambda (fib) (lambda (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))))) 25) (hasheq)))
