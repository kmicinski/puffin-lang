#lang racket

(require "../../interp-cek.rkt")

(define prog '(((call/cc (lambda (x) ((x x) x))) (lambda (y) y)) #t))

(define v (eval prog (make-base-namespace)))
(with-output-to-file "answer"
  (lambda ()
    (print v))
  #:exists 'replace)

(define v+ (interp-CEK prog (hash) 'halt))
(with-output-to-file "output"
  (lambda ()
    (print v+))
  #:exists 'replace)

