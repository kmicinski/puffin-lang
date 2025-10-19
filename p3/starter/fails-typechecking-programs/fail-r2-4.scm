(program
  (let ([u (read)])
    (let ([v (read)])
      (let ([is-eq (eq? u v)])
        (let ([t (if (or is-eq (<= u v)) 5 9)])
          (+ t (- is-eq)))))))
