(program
 (define (mul x y)
   (if (<= y 0)
       0
       (+ x (mul x (- y 1)))))

 (define (weighted7 a b c d e f g)
   ;; 1a + 2b + 3c + 4d + 5e + 6f + 7*g
   (let ([t1 (mul a 1)])
     (let ([t2 (mul b 2)])
       (let ([t3 (mul c 3)])
	 (let ([t4 (mul d 4)])
	   (let ([t5 (mul e 5)])
	     (let ([t6 (mul f 6)])
	       (let ([t7 (mul g 7)])
		 (+ (+ (+ t1 t2)
		       (+ t3 t4))
		    (+ (+ t5 t6) t7))))))))))

 (define (sum_weighted_prefix n)
   ;; Σ_{i=0..n} weighted7(i,i,i,i,i,i,i)
   (let ([acc 0])
     (let ([i 0])
       (let ([_ (while (<= i n)
		       (begin
			 (set! acc
			       (+ acc (weighted7 i i i i i i i)))
			 (set! i (+ i 1))))])
	 acc))))

 (define (offset_sum n k)
   ;; Σ_{i=0..n} (i + k)
   (let ([acc 0])
     (let ([i 0])
       (let ([_ (while (<= i n)
		       (begin
			 (set! acc (+ acc (+ i k)))
			 (set! i (+ i 1))))])
	 acc))))

 ;; main: read n, combine two different aggregations
 (let ([n (read)])
   (+ (sum_weighted_prefix n)
      (offset_sum n 3))))
