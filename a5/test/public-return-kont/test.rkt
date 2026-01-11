#lang racket

(require "../../interp-cek.rkt")

(define prog '(call/cc (lambda (k0) ((call/cc (lambda (k1) (k0 k1))) #f))))

(with-output-to-file "answer"
  (lambda ()
    (print `(kont (ar #f ,(hash 'k0 '(kont halt)) halt))))
  #:exists 'replace)

(define v+ (interp-CEK prog (hash) 'halt))
(with-output-to-file "output"
  (lambda ()
    (print v+))
  #:exists 'replace)

