#lang racket
(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
(displayln (fib 35))
