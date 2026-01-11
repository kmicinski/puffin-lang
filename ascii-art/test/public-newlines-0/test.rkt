#lang racket

(require "../../ascii.rkt")

(displayln (newlines 5))

(with-output-to-file "output"
  (lambda ()
    (displayln (newlines 5)))
  #:exists 'replace)
