(program
 (define (sum_to n)
   (if (<= n 0)
       0
       (+ n (sum_to (- n 1)))))
 (define (sum_prefix n)
   ;; computes Σ_{k=0..n} sum-to(k) using a while loop
   (let ([acc 0])
     (let ([i 0])
       (let ([_ (while (<= i n)
                       (begin
                         (set! acc (+ acc (sum_to i)))
                         (set! i (+ i 1))))])
         acc))))
 (sum_prefix (read)))
