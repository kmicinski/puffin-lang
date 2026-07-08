#lang racket

(require "../../ascii.rkt")

(demo "../../pictures/1.txt")

(with-output-to-file "output"
  (lambda ()
    (demo "../../pictures/1.txt"))
  #:exists 'replace)
