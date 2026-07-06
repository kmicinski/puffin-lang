#lang racket
(define (msort xs less?)
  (define (merge a b)
    (cond [(null? a) b]
          [(null? b) a]
          [(less? (car b) (car a)) (cons (car b) (merge a (cdr b)))]
          [else (cons (car a) (merge (cdr a) b))]))
  (define (split xs)
    (if (or (null? xs) (null? (cdr xs)))
        (cons xs '())
        (let ([rest (split (cddr xs))])
          (cons (cons (car xs) (car rest)) (cons (cadr xs) (cdr rest))))))
  (if (or (null? xs) (null? (cdr xs))) xs
      (let ([h (split xs)]) (merge (msort (car h) less?) (msort (cdr h) less?)))))
(define xs (let loop ([i 0] [seed 12345] [acc '()])
             (if (< i 1000000)
                 (loop (+ i 1) (remainder (+ (* seed 8121) 28411) 134456)
                       (cons seed acc))
                 acc)))
(define sorted (msort xs <))
(displayln (list (car sorted) (last sorted) (length sorted)))
