;; a small DPLL SAT solver over CNF (clauses = lists of literals;
;; negative literal = (not v)); unit propagation + splitting
(define (lit-var l) (match l [`(not ,v) v] [v v]))
(define (lit-sat? l asn)
  (match l
    [`(not ,v) (eq? (hash-ref/default asn v 'u) #f)]
    [v (eq? (hash-ref/default asn v 'u) #t)]))
(define (lit-unsat? l asn)
  (match l
    [`(not ,v) (eq? (hash-ref/default asn v 'u) #t)]
    [v (eq? (hash-ref/default asn v 'u) #f)]))
(define (simplify clauses asn)
  ;; returns 'conflict, or the remaining unresolved clauses
  (let loop ([cs clauses] [out '()])
    (match cs
      ['() (reverse out)]
      [(cons c rest)
       (cond
         [(ormap (lambda (l) (lit-sat? l asn)) c) (loop rest out)]
         [else
          (let ([remaining (filter (lambda (l) (not (lit-unsat? l asn))) c)])
            (if (null? remaining) 'conflict (loop rest (cons remaining out))))])])))
(define (find-unit cs)
  (findf (lambda (c) (eq? (length c) 1)) cs))
(define (assign l asn)
  (match l
    [`(not ,v) (hash-set asn v #f)]
    [v (hash-set asn v #t)]))
(define (dpll clauses asn)
  (match (simplify clauses asn)
    ['conflict #f]
    ['() asn]
    [cs
     (match (find-unit cs)
       [(list l) (dpll cs (assign l asn))]
       [#f
        (let ([v (lit-var (car (car cs)))])
          (let ([try-true (dpll cs (hash-set asn v #t))])
            (if try-true try-true (dpll cs (hash-set asn v #f)))))])]))
(define (solve clauses vars)
  (match (dpll clauses (hash))
    [#f 'unsat]
    [asn (map (lambda (v) (list v (hash-ref/default asn v 'free))) vars)]))
;; (a | b) & (~a | c) & (~b | ~c) & (a | c)
(println (solve '((a b) ((not a) c) ((not b) (not c)) (a c)) '(a b c)))
;; unsat: a & ~a via forcing chain
(println (solve '((a) ((not a) b) ((not b))) '(a b)))
;; pigeonhole 2->1: unsat
(println (solve '((p11) (p21) ((not p11) (not p21))) '(p11 p21)))
;; satisfiable 3-var xor-ish chain
(println (solve '((x y) ((not x) (not y)) (y z) ((not y) (not z))) '(x y z)))
(solve '((q)) '(q))
