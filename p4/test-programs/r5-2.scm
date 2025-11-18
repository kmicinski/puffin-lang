(program
 (define (is_even n)
   (begin (while (> n 0) 
		 (set! n (- n 2)))
          (eq? n 0)))
 (define (is_odd n)
   (not (is_even n)))
 (define (count_evens_up_to n)
   (let ([i 0])
     (let ([cnt 0])
       (let ([loop
              (lambda ()
                (if (<= i n)
                    (begin
                      (if (is_even i)
                          (set! cnt (+ cnt 1))
                          (set! cnt cnt))
                      (set! i (+ i 1))
                      (loop))
                    cnt))])
         (loop)))))
 ;; read and invoke
 (count_evens_up_to (read)))
