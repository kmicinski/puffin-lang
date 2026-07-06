;; closure conversion in miniature: lambdas become (closure code fvs)
;; records; an interpreter for the converted form checks meaning
(define (free-vars e bound)
  (match e
    [(? fixnum? _) (set)]
    [(? symbol? x) (if (set-member? bound x) (set) (set x))]
    [`(lambda (,x) ,b) (free-vars b (set-add bound x))]
    [`(+ ,a ,b) (set-union (free-vars a bound) (free-vars b bound))]
    [`(,f ,a) (set-union (free-vars f bound) (free-vars a bound))]))
(define (convert e)
  (match e
    [(? fixnum? _) e]
    [(? symbol? _) e]
    [`(+ ,a ,b) `(+ ,(convert a) ,(convert b))]
    [`(lambda (,x) ,b)
     (let ([fvs (sort (set->list (free-vars e (set))) symbol<?)])
       `(make-clo (code ,x ,fvs ,(convert b)) ,fvs))]
    [`(,f ,a) `(call ,(convert f) ,(convert a))]))
(define (ev e env)
  (match e
    [(? fixnum? n) n]
    [(? symbol? x) (hash-ref env x)]
    [`(+ ,a ,b) (+ (ev a env) (ev b env))]
    [`(make-clo (code ,x ,fvs ,body) ,_)
     ;; capture exactly the free variables, nothing else
     `(clo ,x ,body ,(foldl (lambda (v acc) (hash-set acc v (hash-ref env v))) (hash) fvs))]
    [`(call ,f ,a)
     (match (ev f env)
       [`(clo ,x ,body ,captured) (ev body (hash-set captured x (ev a env)))])]))
(define p1 '(((lambda (x) (lambda (y) (lambda (z) (+ x (+ y z))))) 100) 20))
(println (convert '(lambda (x) (lambda (y) (+ x y)))))
(println (ev (convert `(,p1 3)) (hash)))     ;; 123
(define compose '((lambda (f) (lambda (g) (lambda (v) (f (g v))))) (lambda (a) (+ a 1))))
(ev (convert `((,compose (lambda (b) (+ b b))) 20)) (hash))
