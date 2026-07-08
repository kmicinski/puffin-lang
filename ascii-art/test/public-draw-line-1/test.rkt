#lang racket

(require "../../ascii.rkt")


(displayln (draw-ascii-line '((1 2 #\X) (1 4 #\Y) (1 8 #\Z))))
(with-output-to-file "output"
  (lambda ()
    (displayln (draw-ascii-line '((1 2 #\X) (1 4 #\Y) (1 8 #\Z)))))
  #:exists 'replace)
