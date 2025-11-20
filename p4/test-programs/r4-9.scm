(program
 (define (mk_pair x y)
   (make-vector 2))

 (define (set_pair_first v x)
   (vector-set! v 0 x))

 (define (set_pair_second v y)
   (vector-set! v 1 y))

 (define (pair_first v)
   (vector-ref v 0))

 (define (pair_second v)
   (vector-ref v 1))

 (define (build_prefix_pairs n)
   ;; builds a chain of pairs (sum, i) where sum = 0 + 1 + ... + i
   (let ([sum 0])
     (let ([i 0])
       (let ([last (mk_pair 0 0)])
	 (begin 
           (set_pair_first last 0)
           (set_pair_second last 0)
           (let ([_ (while (<= i n)
                           (begin
                             (set! sum (+ sum i))
                             (set_pair_first last sum)
                             (set_pair_second last i)
                             (set! i (+ i 1))))]))
           last)))))

 (define (diff_of_pair v)
   ;; returns first - second
   (let ([a (pair_first v)])
     (let ([b (pair_second v)])
       (- a b))))

 (define (sum_diffs_up_to n)
   ;; Σ_{k=0..n} (sum_{i=0..k} i - k)
   (let ([acc 0])
     (let ([k 0])
       (let ([_ (while (<= k n)
                       (begin
                         (let ([p (build_prefix_pairs k)])
                           (set! acc (+ acc (diff_of_pair p))))
                         (set! k (+ k 1))))])
         acc))))

 ;; main: read n, compute sum_diffs_up_to(n)
 (sum_diffs_up_to (read)))
