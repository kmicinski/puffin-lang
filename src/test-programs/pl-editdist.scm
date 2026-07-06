;; Levenshtein distance over symbol lists, twice: exponential
;; recursion for small inputs, then memoized via a mutable hash of
;; (i . j) keys -- results must agree
(define (naive a b)
  (cond [(null? a) (length b)]
        [(null? b) (length a)]
        [(eq? (car a) (car b)) (naive (cdr a) (cdr b))]
        [else (+ 1 (min (naive (cdr a) b)
                        (min (naive a (cdr b)) (naive (cdr a) (cdr b)))))]))
(define (memoized a0 b0)
  (define memo (make-hash))
  (define va (list->vector a0))
  (define vb (list->vector b0))
  (define (d i j)
    (define key (+ (* i 1000) j))
    (cond [(hash-has-key? memo key) (hash-ref memo key)]
          [else
           (define r
             (cond [(eq? i (vector-length va)) (- (vector-length vb) j)]
                   [(eq? j (vector-length vb)) (- (vector-length va) i)]
                   [(eq? (vector-ref va i) (vector-ref vb j)) (d (+ i 1) (+ j 1))]
                   [else (+ 1 (min (d (+ i 1) j) (min (d i (+ j 1)) (d (+ i 1) (+ j 1)))))]))
           (hash-set! memo key r)
           r]))
  (d 0 0))
(define w1 '(k i t t e n))
(define w2 '(s i t t i n g))
(println (list (naive w1 w2) (memoized w1 w2)))      ;; (3 3)
(println (memoized '(s a t u r d a y) '(s u n d a y)))
(println (memoized '() '(a b c)))
(println (memoized '(a b c a b c a b c a b c) '(c b a c b a c b a c b a)))
(memoized w2 w1)
