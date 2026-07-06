#lang racket
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
    [`(,_ ,l ,x ,r) `(B ,l ,x ,r)]))
(define (count t)
  (match t ['E 0] [`(,_ ,l ,_ ,r) (+ 1 (+ (count l) (count r)))]))
(define t
  (let loop ([i 0] [seed 12345] [t 'E])
    (if (< i 100000)
        (loop (+ i 1) (remainder (+ (* seed 75) 74) 8388593) (insert t seed))
        t)))
(displayln (count t))
