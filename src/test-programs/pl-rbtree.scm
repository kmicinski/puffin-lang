;; Okasaki red-black tree insertion: THE pattern-matching showcase
;; (balance is one four-way match), plus invariant validation
(define (balance t)
  (match t
    [`(B (R (R ,a ,x ,b) ,y ,c) ,z ,d) `(R (B ,a ,x ,b) ,y (B ,c ,z ,d))]
    [`(B (R ,a ,x (R ,b ,y ,c)) ,z ,d) `(R (B ,a ,x ,b) ,y (B ,c ,z ,d))]
    [`(B ,a ,x (R (R ,b ,y ,c) ,z ,d)) `(R (B ,a ,x ,b) ,y (B ,c ,z ,d))]
    [`(B ,a ,x (R ,b ,y (R ,c ,z ,d))) `(R (B ,a ,x ,b) ,y (B ,c ,z ,d))]
    [_ t]))
(define (insert t v)
  (define (ins t)
    (match t
      ['E `(R E ,v E)]
      [`(,c ,l ,x ,r)
       (cond [(< v x) (balance `(,c ,(ins l) ,x ,r))]
             [(< x v) (balance `(,c ,l ,x ,(ins r)))]
             [else t])]))
  (match (ins t)
    [`(,_ ,l ,x ,r) `(B ,l ,x ,r)]))   ;; root always black
(define (from-list xs) (foldl (lambda (v t) (insert t v)) 'E xs))
(define (to-list t)
  (match t
    ['E '()]
    [`(,_ ,l ,x ,r) (append (to-list l) (cons x (to-list r)))]))
;; invariants: no red-red parent/child; equal black height everywhere
(define (no-red-red? t)
  (match t
    ['E #t]
    [`(R (R ,_ ,_ ,_) ,_ ,_) #f]
    [`(R ,_ ,_ (R ,_ ,_ ,_)) #f]
    [`(,_ ,l ,_ ,r) (and (no-red-red? l) (no-red-red? r))]))
(define (black-height t)
  (match t
    ['E 1]
    [`(,c ,l ,_ ,r)
     (let ([hl (black-height l)] [hr (black-height r)])
       (if (or (eq? hl #f) (not (eq? hl hr)))
           #f
           (+ hl (if (eq? c 'B) 1 0))))]))
(define xs (list 8 3 10 1 6 14 4 7 13 2 12 5 11 9 15 16))
(define t (from-list xs))
(println (to-list t))
(println (list 'no-red-red (no-red-red? t) 'black-height (black-height t)))
;; larger pseudo-random insertion
(define big
  (let loop ([i 0] [seed 7] [t 'E])
    (if (< i 200)
        (loop (+ i 1) (remainder (+ (* seed 8121) 28411) 134456) (insert t seed))
        t)))
(println (list 'n (length (to-list big)) 'sorted
               (let ok ([l (to-list big)])
                 (match l
                   [(cons a (cons b _)) (and (< a b) (ok (cdr l)))]
                   [_ #t]))
               'rb-ok (and (no-red-red? big) (if (black-height big) #t #f))))
(black-height t)
