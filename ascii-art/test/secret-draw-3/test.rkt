#lang racket

(require "../../ascii.rkt")

(demo "../../pictures/3.txt")

(with-output-to-file "output"
  (lambda ()
    (demo "../../pictures/3.txt"))
  #:exists 'replace)
