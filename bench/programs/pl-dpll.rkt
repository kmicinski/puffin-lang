#lang racket
(define (lit-var l) (match l [`(not ,v) v] [v v]))
(define (lit-sat? l asn)
  (match l
    [`(not ,v) (eq? (hash-ref asn v 'u) #f)]
    [v (eq? (hash-ref asn v 'u) #t)]))
(define (lit-unsat? l asn)
  (match l
    [`(not ,v) (eq? (hash-ref asn v 'u) #t)]
    [v (eq? (hash-ref asn v 'u) #f)]))
(define (simplify clauses asn)
  (let loop ([cs clauses] [out '()])
    (match cs
      ['() (reverse out)]
      [(cons c rest)
       (cond
         [(ormap (lambda (l) (lit-sat? l asn)) c) (loop rest out)]
         [else
          (let ([remaining (filter (lambda (l) (not (lit-unsat? l asn))) c)])
            (if (null? remaining) 'conflict (loop rest (cons remaining out))))])])))
(define (dpll clauses asn)
  (match (simplify clauses asn)
    ['conflict #f]
    ['() asn]
    [cs
     (match (findf (lambda (c) (eqv? (length c) 1)) cs)
       [(list l) (dpll cs (match l [`(not ,v) (hash-set asn v #f)] [v (hash-set asn v #t)]))]
       [#f
        (let ([v (lit-var (car (car cs)))])
          (let ([try (dpll cs (hash-set asn v #t))])
            (if try try (dpll cs (hash-set asn v #f)))))])]))
(define (pigeon p h) (string->symbol (string-append "p" (number->string p) (number->string h))))
(define (php P H)
  (append
   (map (lambda (p) (map (lambda (h) (pigeon p h)) (range 0 H))) (range 0 P))
   (append-map
    (lambda (h)
      (append-map
       (lambda (p1)
         (filter-map
          (lambda (p2) (if (< p1 p2) (list `(not ,(pigeon p1 h)) `(not ,(pigeon p2 h))) #f))
          (range 0 P)))
       (range 0 P)))
    (range 0 H))))
(displayln (if (dpll (php 7 6) (hash)) 'sat 'unsat))
