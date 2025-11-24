(program (define (f x) x)
	 (define (g y) (+ (f y) 1))
         (g (read)))
