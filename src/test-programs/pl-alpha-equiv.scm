;; alpha-equivalence of lambda terms two ways: via de Bruijn
;; conversion, and directly with a renaming environment -- both must
;; agree on every test pair
(define (db e env)
  (match e
    [(? symbol? x)
     (let loop ([env env] [i 0])
       (match env
         ['() `(free ,x)]
         [(cons hd tl) (if (eq? hd x) `(bound ,i) (loop tl (+ i 1)))]))]
    [`(lambda (,x) ,b) `(lam ,(db b (cons x env)))]
    [`(,f ,a) `(app ,(db f env) ,(db a env))]))
(define (alpha-db? e1 e2) (equal? (db e1 '()) (db e2 '())))
(define (alpha-env? e1 e2 m1 m2 depth)
  (match (list e1 e2)
    [`((lambda (,x) ,b1) (lambda (,y) ,b2))
     (alpha-env? b1 b2 (hash-set m1 x depth) (hash-set m2 y depth) (+ depth 1))]
    [`((,f1 ,a1) (,f2 ,a2))
     (and (alpha-env? f1 f2 m1 m2 depth) (alpha-env? a1 a2 m1 m2 depth))]
    [`(,(? symbol? x) ,(? symbol? y))
     (let ([dx (hash-ref/default m1 x 'free)] [dy (hash-ref/default m2 y 'free)])
       (if (eq? dx 'free)
           (and (eq? dy 'free) (eq? x y))
           (equal? dx dy)))]
    [_ #f]))
(define (check e1 e2)
  (let ([a (alpha-db? e1 e2)] [b (alpha-env? e1 e2 (hash) (hash) 0)])
    (println (list e1 '≡? e2 '=> a (if (eq? a b) 'agree 'DISAGREE)))))
(check '(lambda (x) x) '(lambda (y) y))
(check '(lambda (x) (lambda (y) (x y))) '(lambda (a) (lambda (b) (a b))))
(check '(lambda (x) (lambda (y) (x y))) '(lambda (a) (lambda (b) (b a))))
(check '(lambda (x) (x free)) '(lambda (y) (y free)))
(check '(lambda (x) (x free)) '(lambda (y) (y other)))
(check '(lambda (x) (lambda (x) x)) '(lambda (y) (lambda (z) z)))
(check '(lambda (x) (lambda (x) x)) '(lambda (y) (lambda (z) y)))
(alpha-db? '(lambda (u) u) '(lambda (v) v))
