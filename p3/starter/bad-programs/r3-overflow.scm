(program
 (let* ([x 0]
	[y (make-vector 10000)])
   (while (< x 10000)
	  (let ([z (make-vector 10000000)])
	    (begin 
	      (vector-set! y x z)
	      (set! x (+ x 1)))))))
