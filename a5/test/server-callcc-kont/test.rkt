#lang racket

(require "../../interp-cek.rkt")

(define prog '(call/cc (call/cc (lambda (x) x))))

(with-output-to-file "answer"
  (lambda ()
    (print '(kont halt)))
  #:exists 'replace)

(define v+ (interp-CEK prog (hash) 'halt))
(with-output-to-file "output"
  (lambda ()
    (print v+))
  #:exists 'replace)

