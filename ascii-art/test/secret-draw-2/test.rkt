#lang racket

(require "../../ascii.rkt")

(demo "../../pictures/2.txt")

(with-output-to-file "output"
  (lambda ()
    (demo "../../pictures/2.txt"))
  #:exists 'replace)
