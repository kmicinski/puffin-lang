;; bracket abstraction: lambda calculus -> SKI combinators, then a
;; normal-order SKI reducer; verify on church arithmetic
(define (free? x e)
  (match e
    [(? symbol? y) (eq? x y)]
    [`(lambda (,y) ,b) (and (not (eq? x y)) (free? x b))]
    [`(,f ,a) (or (free? x f) (free? x a))]
    [_ #f]))
;; bracket abstraction (eta-optimized)
(define (bracket x e)
  (cond
    [(not (free? x e)) `(K ,e)]
    [(eq? e x) 'I]
    [else
     (match e
       [`(,f ,a)
        (if (and (equal? a x) (not (free? x f)))
            f                                        ;; eta
            `((S ,(bracket x f)) ,(bracket x a)))]
       [`(lambda (,y) ,b) (bracket x (to-ski e))])]))
(define (to-ski e)
  (match e
    [(? symbol? _) e]
    [`(lambda (,x) ,b) (bracket x (to-ski b))]
    [`(,f ,a) `(,(to-ski f) ,(to-ski a))]))
;; SKI reduction, normal order, fuel-bounded
(define (red e fuel)
  (if (eq? fuel 0)
      e
      (match e
        [`(I ,x) (red x (- fuel 1))]
        [`((K ,x) ,_) (red x (- fuel 1))]
        [`(((S ,f) ,g) ,x) (red `((,f ,x) (,g ,x)) (- fuel 1))]
        [`(,f ,a)
         (let ([f2 (red f (- fuel 1))])
           (if (equal? f2 f)
               `(,f ,(red a (- fuel 1)))
               (red `(,f2 ,a) (- fuel 1))))]
        [_ e])))
;; count a church numeral by applying to 'succ-marker chains
(define (church->int e)
  (let loop ([t (red `((,e inc) zero) 500)] [n 0])
    (match t
      ['zero n]
      [`(inc ,rest) (loop rest (+ n 1))]
      [_ (list 'stuck t)])))
(define two '(lambda (f) (lambda (x) (f (f x)))))
(define three '(lambda (f) (lambda (x) (f (f (f x))))))
(define plus '(lambda (m) (lambda (n) (lambda (f) (lambda (x) ((m f) ((n f) x)))))))
(println (to-ski 'a))
(println (to-ski '(lambda (x) x)))
(println (to-ski '(lambda (x) (lambda (y) x))))
(println (church->int (to-ski two)))
(println (church->int (to-ski three)))
(println (church->int (to-ski `((,plus ,two) ,three))))
(church->int (to-ski `((,plus ,three) ,three)))
