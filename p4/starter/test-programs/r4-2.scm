(program 
 (define (fib x)
   (if (eq? x 0)
       1
       (if (eq? x 1)
	   1
	   (+ (fib (- x 1)) (fib (- x 2))))))
 (let ([x (read)])
   (if (< x 8) (fib x) (fib 8))))
