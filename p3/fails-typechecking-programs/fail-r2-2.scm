(program
  (let ([a (read)])
    (let ([b (if (>= a 0)
                 (and (eq? a 0) (<= a 10))
                 (or (< a -5) #t))])
      (let ([c (if b 3 7)])
        (+ (if (and b (eq? c 3)) #t #f)
           (+ c (if b 1 2)))))))
