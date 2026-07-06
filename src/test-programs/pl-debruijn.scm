;; named lambda terms -> de Bruijn indices -> normalize by substitution
(define (index-in env x)
  (match env
    ['() (error `(unbound ,x))]
    [(cons hd tl) (if (eq? hd x) 0 (+ 1 (index-in tl x)))]))
(define (to-db e env)
  (match e
    [(? symbol? x) `(var ,(index-in env x))]
    [`(lambda (,x) ,b) `(lam ,(to-db b (cons x env)))]
    [`(,f ,a) `(app ,(to-db f env) ,(to-db a env))]))
;; shift free vars >= c by d
(define (shift e d c)
  (match e
    [`(var ,k) (if (< k c) `(var ,k) `(var ,(+ k d)))]
    [`(lam ,b) `(lam ,(shift b d (+ c 1)))]
    [`(app ,f ,a) `(app ,(shift f d c) ,(shift a d c))]))
;; substitute s for var j in e
(define (subst e j s)
  (match e
    [`(var ,k) (if (eq? k j) s `(var ,k))]
    [`(lam ,b) `(lam ,(subst b (+ j 1) (shift s 1 0)))]
    [`(app ,f ,a) `(app ,(subst f j s) ,(subst a j s))]))
;; normal-order reduction to normal form (terms are strongly normalizing here)
(define (nf e)
  (match e
    [`(app ,f ,a)
     (match (nf f)
       [`(lam ,b) (nf (shift (subst b 0 (shift a 1 0)) -1 0))]
       [g `(app ,g ,(nf a))])]
    [`(lam ,b) `(lam ,(nf b))]
    [_ e]))
(define I '(lambda (x) x))
(define K '(lambda (x) (lambda (y) x)))
(define S '(lambda (x) (lambda (y) (lambda (z) ((x z) (y z))))))
(println (to-db `((,K ,I) ,K) '()))
(println (nf (to-db `((,K ,I) ,K) '())))          ;; I = (lam (var 0))
(println (nf (to-db `(((,S ,K) ,K) ,I) '())))     ;; SKK = I applied to I -> I
(println (equal? (nf (to-db `((,S ,K) ,K) '())) (nf (to-db I '()))))  ;; #t: SKK = I
;; church 2^2 inside de Bruijn: (2 2) normalizes to 4 = \f x. f(f(f(f x)))
(define two '(lambda (f) (lambda (x) (f (f x)))))
(nf (to-db `(,two ,two) '()))
