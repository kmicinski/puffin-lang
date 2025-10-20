(program
  (let ([a (read)])
    (let ([b (+ a 3)])
      (let ([c (+ (- b) (+ a 7))])
        (if (not c)               
            (+ c 1)
            (- c))))))
