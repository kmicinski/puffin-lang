;; Okasaki's batched (two-list) persistent queue; persistence checked
;; by using an old version after updates
(define empty-q '(() ()))
(define (q-empty? q) (match q [`(() ()) #t] [_ #f]))
(define (check f r) (if (null? f) (list (reverse r) '()) (list f r)))
(define (snoc q v) (match q [`(,f ,r) (check f (cons v r))]))
(define (q-head q) (match q [`((,h . ,_) ,_) h]))
(define (q-tail q) (match q [`((,_ . ,f) ,r) (check f r)]))
(define (q->list q)
  (if (q-empty? q) '() (cons (q-head q) (q->list (q-tail q)))))
(define q3 (snoc (snoc (snoc empty-q 1) 2) 3))
(define q5 (snoc (snoc q3 4) 5))
(println (q->list q3))            ;; persistence: q3 unchanged by q5
(println (q->list q5))
(println (q->list (q-tail (q-tail q5))))
;; drive it as a BFS work queue: level-order of a binary tree
(define (bfs t)
  (let loop ([q (snoc empty-q t)] [acc '()])
    (if (q-empty? q)
        (reverse acc)
        (match (q-head q)
          ['leaf (loop (q-tail q) acc)]
          [`(node ,v ,l ,r)
           (loop (snoc (snoc (q-tail q) l) r) (cons v acc))]))))
(define tree '(node 1 (node 2 (node 4 leaf leaf) (node 5 leaf leaf))
                     (node 3 (node 6 leaf leaf) (node 7 leaf leaf))))
(println (bfs tree))
(q->list (q-tail q3))
