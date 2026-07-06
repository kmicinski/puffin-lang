#lang racket
(let loop ([i 0] [acc ""])
  (if (< i 60000)
      (loop (+ i 1) (string-append acc (number->string (remainder i 10))))
      (displayln (string-length acc))))
