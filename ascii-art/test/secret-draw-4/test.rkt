#lang racket

(require "../../ascii.rkt")

(demo "../../pictures/4.txt")

(with-output-to-file "output"
  (lambda ()
    (demo "../../pictures/4.txt"))
  #:exists 'replace)
