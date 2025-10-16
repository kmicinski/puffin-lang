(program
  (let ([a (read)])
    (let ([b (read)])
      (let ([c (+ a (+ b 3))])
        (let ([flag (or (>= c 10) (<= a (- b)))])
          (if (< flag (+ c 2))          ; <-- Bool < Int
              (+ c (if flag 1 2))
              (if (and (eq? a b) (not flag))
                  0
                  (+ a b))))))))
