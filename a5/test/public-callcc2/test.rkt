#lang racket

(require "../../interp-cek.rkt")

(define prog '(call/cc
               (lambda (top)
                 (let ([cc (call/cc (lambda (cc) (cc cc)))])
                   (if (call/cc (lambda (k) (if (cc (lambda (x) (top #f))) (k #f) (k #f))))
                       #t
                       #t)))))

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

