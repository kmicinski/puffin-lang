#lang racket

(require "../../interp-cek.rkt")

(define prog '(call/cc (lambda (k0) ((lambda (y) y) (call/cc (lambda (k1) (k0 k1)))))))

(with-output-to-file "answer"
  (lambda ()
    (print `(kont (fn (closure (lambda (y) y) ,(hash 'k0 '(kont halt))) halt))))
  #:exists 'replace)

(define v+ (interp-CEK prog (hash) 'halt))
(with-output-to-file "output"
  (lambda ()
    (print v+))
  #:exists 'replace)

