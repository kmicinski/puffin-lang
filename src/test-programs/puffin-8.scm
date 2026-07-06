;; immutable-by-default collections: persistence, sharing, equal?
(define h0 (hash 'a 1 'b 2))
(define h1 (hash-set h0 'c 3))
(define h2 (hash-remove h1 'a))
(println (list (hash-count h0) (hash-count h1) (hash-count h2)))   ;; (2 3 2)
(println (hash-ref h0 'a))                 ;; h0 untouched: 1
(println (hash-ref/default h2 'a 'gone))   ;; gone
(println (equal? (hash 'x 1 'y 2) (hash 'y 2 'x 1)))  ;; #t (value semantics)
(println (equal? h0 h1))                   ;; #f

(define s0 (set 1 2 3))
(define s1 (set-add s0 4))
(define s2 (set-remove s1 1))
(println (list (set-count s0) (set-count s1) (set-count s2)))  ;; (3 4 3)
(println (set-member? s0 4))               ;; s0 untouched: #f
(println (equal? (set 1 2) (set 2 1)))     ;; #t
(println (list (hash? h0) (set? s0) (hash? s0) (set? '(1 2))))  ;; (#t #t #f #f)

;; persistence under heavy insertion: build 3 generations, all live
(define big
  (let loop ([i 0] [h (hash)])
    (if (< i 2000) (loop (+ i 1) (hash-set h i (* i i))) h)))
(println (hash-count big))                 ;; 2000
(println (hash-ref big 1234))              ;; 1522756
(define smaller
  (let loop ([i 0] [h big])
    (if (< i 1000) (loop (+ i 1) (hash-remove h i)) h)))
(println (list (hash-count big) (hash-count smaller)))  ;; (2000 1000)

;; mutable variants still tolerated, and distinct
(define mh (make-hash))
(hash-set! mh 'k 'v)
(println (list (hash-count mh) (hash? mh)))  ;; (1 #t)
(println (equal? (make-hash) (make-hash)))   ;; #f (identity)
(set->list (set 'just-one))
