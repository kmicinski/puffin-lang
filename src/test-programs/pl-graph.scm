;; graphs as immutable hashes of adjacency lists: DFS, cycle
;; detection, topological sort (all deterministic: neighbors sorted)
(define (add-edge g u v)
  (hash-set g u (sort (cons v (hash-ref/default g u '())) symbol<?)))
(define (neighbors g u) (hash-ref/default g u '()))
(define g1
  (foldl (lambda (e g) (add-edge g (car e) (cdr e))) (hash)
         '((a . b) (a . c) (b . d) (c . d) (d . e) (f . a) (c . f2) (f2 . e))))
(define (dfs g start)
  (let walk ([stack (list start)] [seen (set)] [order '()])
    (match stack
      ['() (reverse order)]
      [(cons u rest)
       (if (set-member? seen u)
           (walk rest seen order)
           (walk (append (neighbors g u) rest) (set-add seen u) (cons u order)))])))
(println (dfs g1 'a))
(println (dfs g1 'f))
;; cycle detection via colors (white/gray/black), functional style
(define (has-cycle? g nodes)
  (define (visit u colors)
    (match (hash-ref/default colors u 'white)
      ['gray 'cycle]
      ['black colors]
      ['white
       (let ([r (foldl (lambda (v acc) (if (eq? acc 'cycle) 'cycle (visit v acc)))
                       (hash-set colors u 'gray)
                       (neighbors g u))])
         (if (eq? r 'cycle) 'cycle (hash-set r u 'black)))]))
  (eq? 'cycle (foldl (lambda (u acc) (if (eq? acc 'cycle) 'cycle (visit u acc)))
                     (hash) nodes)))
(define nodes '(a b c d e f f2))
(println (has-cycle? g1 nodes))
(println (has-cycle? (add-edge g1 'e 'a) nodes))
;; topological sort: postorder DFS reversed
(define (toposort g nodes)
  (define (visit u st)   ;; st = (seen . order)
    (if (set-member? (car st) u)
        st
        (match (foldl (lambda (v acc) (visit v acc))
                      (cons (set-add (car st) u) (cdr st))
                      (neighbors g u))
          [(cons seen order) (cons seen (cons u order))])))
  (cdr (foldl (lambda (u st) (visit u st)) (cons (set) '()) nodes)))
(println (toposort g1 nodes))
(length (dfs g1 'a))
