(program
 (let ([a (read)])
   (let ([b (read)])
     (if (>= b a)
	 (- a b)
	 (- b a)))))
