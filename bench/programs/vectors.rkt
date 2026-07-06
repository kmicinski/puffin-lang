#lang racket
(define v (make-vector 50000000 0))
(let loop ([i 0]) (when (< i 50000000) (vector-set! v i (* i 2)) (loop (+ i 1))))
(let loop ([i 0] [acc 0])
  (if (< i 50000000) (loop (+ i 1) (+ acc (vector-ref v i))) (displayln acc)))
