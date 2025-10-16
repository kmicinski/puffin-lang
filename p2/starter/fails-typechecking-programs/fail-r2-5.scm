(program
  (let ([x (read)])
    (let ([x (eq? x 0)])               
      (let ([y (if x 10 20)])
        (+ y (+ 1 x))))))
