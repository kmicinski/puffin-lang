#lang racket
(define (safe? col placed dist)
  (match placed
    ['() #t]
    [(cons p rest)
     (and (not (eqv? p col)) (not (eqv? p (+ col dist))) (not (eqv? p (- col dist)))
          (safe? col rest (+ dist 1)))]))
(define (solve n)
  (define (place row placed)
    (if (eqv? row n)
        1
        (foldl + 0 (map (lambda (col) (if (safe? col placed 1) (place (+ row 1) (cons col placed)) 0))
                        (range 0 n)))))
  (place 0 '()))
(displayln (solve 11))
