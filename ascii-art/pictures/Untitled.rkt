#lang racket

;; map the function f over each element of lst
(define (map f lst)
  (if (empty? lst)
      '()
      (cons (f (first lst)) (map f (rest lst)))))