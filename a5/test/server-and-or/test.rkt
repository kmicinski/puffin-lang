#lang racket

(require "../../interp-cek.rkt")

(define prog '(or (call/cc ((lambda (x) x)
                            (lambda (k)
                              (and #t
                                   (and (k #t)
                                        #f)))))
                  ((lambda (u) (u u))
                   (lambda (u) (u u)))))

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

