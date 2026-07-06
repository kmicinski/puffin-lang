;; a type checker for the simply-typed lambda calculus + booleans/ints
;; types: int | bool | (-> t1 t2)
(define (type=? a b) (equal? a b))
(define (typecheck e ctx)
  (match e
    [(? fixnum? _) 'int]
    [#t 'bool]
    [#f 'bool]
    [(? symbol? x) (hash-ref/default ctx x `(unbound ,x))]
    [`(lambda ([,x : ,t]) ,body)
     `(-> ,t ,(typecheck body (hash-set ctx x t)))]
    [`(if ,g ,th ,el)
     (let ([tg (typecheck g ctx)] [tt (typecheck th ctx)] [te (typecheck el ctx)])
       (cond [(not (type=? tg 'bool)) `(type-error if-guard ,tg)]
             [(not (type=? tt te)) `(type-error if-branches ,tt ,te)]
             [else tt]))]
    [`(+ ,a ,b)
     (if (and (type=? (typecheck a ctx) 'int) (type=? (typecheck b ctx) 'int))
         'int
         '(type-error plus))]
    [`(zero? ,a)
     (if (type=? (typecheck a ctx) 'int) 'bool '(type-error zero?))]
    [`(,f ,a)
     (match (typecheck f ctx)
       [`(-> ,t1 ,t2)
        (let ([ta (typecheck a ctx)])
          (if (type=? t1 ta) t2 `(type-error arg-mismatch expected ,t1 got ,ta)))]
       [tf `(type-error not-a-function ,tf)])]))
(define (tc e) (typecheck e (hash)))
(println (tc '(lambda ([x : int]) (+ x 1))))
(println (tc '((lambda ([x : int]) (+ x 1)) 41)))
(println (tc '(lambda ([f : (-> int bool)]) (lambda ([x : int]) (if (f x) 0 1)))))
(println (tc '((lambda ([x : int]) (+ x 1)) #t)))
(println (tc '(if (zero? 0) 1 #f)))
(println (tc '(lambda ([x : bool]) (x 1))))
(tc '((lambda ([f : (-> int int)]) (f (f 2))) (lambda ([y : int]) (+ y y))))
