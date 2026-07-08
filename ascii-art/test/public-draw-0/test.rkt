#lang racket

(require "../../ascii.rkt")

(demo "../../pictures/0.txt")

(with-output-to-file "output"
  (lambda ()
    (demo "../../pictures/0.txt"))
  #:exists 'replace)
