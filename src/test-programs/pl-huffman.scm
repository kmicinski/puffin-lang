;; Huffman coding: build the tree from frequencies (sorted-list
;; priority queue), derive the code table, encode/decode round-trip
(define (node-freq n) (match n [`(leaf ,_ ,f) f] [`(node ,_ ,_ ,f) f]))
(define (insert-by-freq n ns)
  (match ns
    ['() (list n)]
    [(cons hd tl)
     (if (or (< (node-freq n) (node-freq hd))
             (and (eq? (node-freq n) (node-freq hd)) (node<? n hd)))
         (cons n ns)
         (cons hd (insert-by-freq n tl)))]))
;; deterministic tie-break so trees are identical everywhere
(define (node-name n) (match n [`(leaf ,s ,_) s] [`(node ,l ,_ ,_) (node-name l)]))
(define (node<? a b) (symbol<? (node-name a) (node-name b)))
(define (build-tree freqs)
  (let loop ([ns (foldl insert-by-freq '() (map (lambda (p) `(leaf ,(car p) ,(cdr p))) freqs))])
    (match ns
      [(list only) only]
      [(cons a (cons b rest))
       (loop (insert-by-freq `(node ,a ,b ,(+ (node-freq a) (node-freq b))) rest))])))
(define (code-table t prefix)
  (match t
    [`(leaf ,s ,_) (list (cons s (reverse prefix)))]
    [`(node ,l ,r ,_) (append (code-table l (cons 0 prefix)) (code-table r (cons 1 prefix)))]))
(define (encode msg table)
  (append-map (lambda (s) (cdr (assoc s table))) msg))
(define (decode bits t root)
  (match (list t bits)
    [`((leaf ,s ,_) ,_) (cons s (if (null? bits) '() (decode bits root root)))]
    [`((node ,l ,r ,_) (,b . ,rest)) (decode rest (if (eq? b 0) l r) root)]))
(define freqs '((a . 45) (b . 13) (c . 12) (d . 16) (e . 9) (f . 5)))
(define t (build-tree freqs))
(define table (code-table t '()))
(println (map (lambda (p) (list (car p) (length (cdr p)))) table))
(define msg '(a b a c c a d f e a d))
(define bits (encode msg table))
(println (list 'bits (length bits) 'vs-fixed (* 3 (length msg))))
(println (decode bits t t))
(println (equal? (decode bits t t) msg))
(length bits)
