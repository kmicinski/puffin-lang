#lang racket

(require "../../interp-cek.rkt")

(define prog '(and (not (and #t #f)) (and #t #t)))

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

