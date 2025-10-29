(program
 (let ([a (+ 1 (read))])
   (if (< a 5)
       (let ([x (if (< a 2) 3 (+ 1 (- 2)))])
	 (if (> x 1) (- x (+ x x)) (- x x)))
       (+ a 15))))
