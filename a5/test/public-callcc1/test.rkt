#lang racket

(require "../../interp-cek.rkt")

(define prog '(or #f (call/cc (lambda (k) (or (k #t) #f)))))

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

