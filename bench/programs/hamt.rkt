#lang racket
(define h
  (let loop ([i 0] [h (hasheqv)])
    (if (< i 1000000) (loop (+ i 1) (hash-set h i (* i 3))) h)))
(let loop ([i 0] [acc 0])
  (if (< i 1000000) (loop (+ i 1) (+ acc (hash-ref h i))) (displayln acc)))
