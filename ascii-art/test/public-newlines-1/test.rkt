#lang racket

(require "../../ascii.rkt")

(displayln (newlines 0))

(with-output-to-file "output"
  (lambda ()
    (displayln (newlines 0)))
  #:exists 'replace)
