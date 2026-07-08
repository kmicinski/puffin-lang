#lang racket

(require "../../ascii.rkt")

(demo "../../pictures/5.txt")

(with-output-to-file "output"
  (lambda ()
    (demo "../../pictures/5.txt"))
  #:exists 'replace)
