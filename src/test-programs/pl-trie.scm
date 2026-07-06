;; a trie over symbol lists, as nested immutable hashes:
;; node = (trie present? children-hash)
(define empty-trie `(trie #f ,(hash)))
(define (t-insert t path)
  (match (list t path)
    [`((trie ,_ ,kids) ()) `(trie #t ,kids)]
    [`((trie ,p ,kids) (,k . ,rest))
     (let ([child (hash-ref/default kids k empty-trie)])
       `(trie ,p ,(hash-set kids k (t-insert child rest))))]))
(define (t-member? t path)
  (match (list t path)
    [`((trie ,p ,_) ()) p]
    [`((trie ,_ ,kids) (,k . ,rest))
     (if (hash-has-key? kids k) (t-member? (hash-ref kids k) rest) #f)]))
(define (t-count t)
  (match t
    [`(trie ,p ,kids)
     (+ (if p 1 0)
        (foldl (lambda (k acc) (+ acc (t-count (hash-ref kids k)))) 0 (hash-keys kids)))]))
;; all stored paths, sorted for deterministic output
(define (t-paths t)
  (match t
    [`(trie ,p ,kids)
     (append (if p '(()) '())
             (append-map (lambda (k)
                           (map (lambda (sub) (cons k sub)) (t-paths (hash-ref kids k))))
                         (sort (hash-keys kids) symbol<?)))]))
(define words '((c a t) (c a r) (c a) (d o g) (d o) (c a r t) (b a t)))
(define t (foldl (lambda (w acc) (t-insert acc w)) empty-trie words))
(println (t-count t))
(println (list (t-member? t '(c a)) (t-member? t '(c)) (t-member? t '(c a r t)) (t-member? t '(z))))
(println (t-paths t))
(t-count (t-insert t '(c a)))    ;; idempotent insert
