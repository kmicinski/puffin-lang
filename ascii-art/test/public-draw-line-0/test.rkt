#lang racket

(require "../../ascii.rkt")

(displayln (draw-ascii-line '((1 0 #\X) (1 1 #\Y) (1 2 #\Z))))

(with-output-to-file "output"
  (lambda ()
    (displayln (draw-ascii-line '((1 0 #\X) (1 1 #\Y) (1 2 #\Z)))))
  #:exists 'replace)
