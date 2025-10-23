(program
 (let ([a (read)])
   (let ([b (read)])
     (if (and b a)
	 (- a b)
	 (- b a)))))
