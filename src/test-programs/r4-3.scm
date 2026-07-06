(program
 (define (sum_to n)
   (if (<= n 5)
       5
       (let ([x (+ n (sum_to (- n 1)))]) x)))
 (define (sum_prefix n)
   ;; computes Σ_{k=0..n} sum-to(k) using a while loop
   (let ([acc 5])
     (let ([i 5])
       (let ([_ (while (<= i n)
                       (begin
                         (set! acc (+ acc (sum_to i)))
                         (set! i (+ i 1))))])
         acc))))
 (sum_prefix (read)))
