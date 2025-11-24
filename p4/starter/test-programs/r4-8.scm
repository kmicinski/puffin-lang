(program
 (define (gcd a b)
   ;; Euclidean algorithm via repeated subtraction
   (if (<= b 0)
       a
       (if (< a b)
	   (gcd b a)
	   (gcd (- a b) b))))
 (define (sum_gcd_prefix n m)
   ;; Σ_{i=0..n} gcd(i, m)
   (let ([acc 0])
     (let ([i 0])
       (let ([_ (while (<= i n)
		       (begin
			 (set! acc (+ acc (gcd i m)))
			 (set! i (+ i 1))))])
	 acc))))
 (define (sum_gcd_pairs n)
   ;; Σ_{i=0..n} gcd(i, n - i)
   (let ([acc 0])
     (let ([i 0])
       (let ([_ (while (<= i n)
		       (begin
			 (set! acc (+ acc (gcd i (- n i))))
			 (set! i (+ i 1))))])
	 acc))))
 (define (main-helper)
   (let* ([n (read)]
	  [m (read)])
     (+ (sum_gcd_prefix n m)
	(sum_gcd_pairs n))))
 (main-helper))
