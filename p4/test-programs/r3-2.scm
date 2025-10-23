(program
  (let* ([n (+ 25 (read))]
         [i 0]
         [acc 0])
    (begin
      (while (< i n)
             (begin (set! acc (+ acc i))
		    (set! i (+ i 1))))
      acc)))
