(program
 (let* ([x (read)]
	[y (read)]
	[tmp 0])
   (begin (set! tmp x)
	  (set! y x)
	  (set! x tmp)
	  y)))
