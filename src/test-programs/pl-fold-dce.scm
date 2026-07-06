;; two classic optimizations over a let-based expression IR:
;; constant folding + dead-code elimination, to fixpoint
(define (fold e)
  (match e
    [(? fixnum? _) e]
    [(? symbol? _) e]
    [`(+ ,(? fixnum? a) ,(? fixnum? b)) (+ a b)]
    [`(* ,(? fixnum? a) ,(? fixnum? b)) (* a b)]
    [`(+ ,a ,b) `(+ ,(fold a) ,(fold b))]
    [`(* ,a ,b) `(* ,(fold a) ,(fold b))]
    [`(* ,_ 0) 0] [`(* 0 ,_) 0]
    [`(if ,(? fixnum? n) ,t ,f) (fold t)]   ;; ints truthy
    [`(if #f ,_ ,f) (fold f)]
    [`(if ,g ,t ,f) `(if ,(fold g) ,(fold t) ,(fold f))]
    [`(let ([,x ,rhs]) ,body) `(let ([,x ,(fold rhs)]) ,(fold body))]))
(define (free-in? x e)
  (match e
    [(? symbol? y) (eq? x y)]
    [`(let ([,y ,rhs]) ,body)
     (or (free-in? x rhs) (and (not (eq? x y)) (free-in? x body)))]
    [`(,_ ,es ...) (ormap (lambda (s) (free-in? x s)) es)]
    [_ #f]))
(define (dce e)
  (match e
    [`(let ([,x ,rhs]) ,body)
     (if (free-in? x body)
         `(let ([,x ,(dce rhs)]) ,(dce body))
         (dce body))]                        ;; rhs is pure in this IR
    [`(,op ,es ...) `(,op ,@(map dce es))]
    [_ e]))
(define (inline-consts e env)
  (match e
    [(? fixnum? _) e]
    [(? symbol? x) (hash-ref/default env x x)]
    [`(let ([,x ,(? fixnum? n)]) ,body) (inline-consts body (hash-set env x n))]
    [`(let ([,x ,rhs]) ,body) `(let ([,x ,(inline-consts rhs env)]) ,(inline-consts body env))]
    [`(,op ,es ...) `(,op ,@(map (lambda (s) (inline-consts s env)) es))]))
(define (optimize e)
  (let ([e2 (dce (fold (inline-consts e (hash))))])
    (if (equal? e2 e) e (optimize e2))))
(define prog
  '(let ([a 2])
     (let ([b (+ a 3)])
       (let ([dead (* b 999)])
         (let ([c (* b b)])
           (if 1 (+ c (* 0 dead)) 42))))))
(println (optimize prog))                       ;; 25
(println (optimize '(let ([x (+ 1 2)]) (let ([y 9]) (+ x x)))))
(optimize '(if (+ 0 0) 1 (let ([u 5]) (* u (+ u 1)))))
