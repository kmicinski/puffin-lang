(program
 (define (mul x y)
   (if (<= y 0)
       0
       (+ x (mul x (- y 1)))))

 (define (square x)
   (mul x x))

 (define (sum_squares_to n)
   (let ([acc 0])
     (let ([i 0])
       (let ([_ (while (<= i n)
		       (begin
			 (set! acc (+ acc (square i)))
			 (set! i (+ i 1))))])
	 acc))))

 (define (sum_pairs n)
   ;; computes Σ_{i=0..n} (i + (n - i)) = (n + 1) * n
   (let ([acc 0])
     (let ([i 0])
       (let ([_ (while (<= i n)
		       (begin
			 (set! acc (+ acc (+ i (- n i))))
			 (set! i (+ i 1))))])
	 acc))))

 ;; main: read n and return sum_squares_to(n) + sum_pairs(10)
 (+ (sum_squares_to (read))
    (sum_pairs 10)))
