#lang racket
;; The `optimize` pass: dispatches on (optimize-level).
;;   0 = identity
;;   1 = contraction + bounded inlining, iterated to a small round limit
;;   2 = AAM flow analysis clients first (when available), then -O1
;; IR-preserving: unique-source-tree? in and out.
(provide optimize)

(require "../system.rkt" "contract.rkt" "aam.rkt" "../provenance.rkt")

(define round-limit 4)

(define (optimize p)
  (cond
    [(zero? (optimize-level)) p]
    [else
     (define p2
       (if (>= (optimize-level) 2)
           (aam-clients p)
           p))
     (let loop ([p p2] [round 0])
       (if (>= round round-limit)
           p
           (let-values ([(p* changed) (contract-program p)])
             (if changed (loop p* (add1 round)) p*))))]))
