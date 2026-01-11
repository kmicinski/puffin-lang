#lang racket

(require "../../interp-cek.rkt")

(define prog '(let ([id (lambda (x) x)])
                (let ([v (if (id #f) (id #f) (id #t))])
                  ((id id) v))))

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

