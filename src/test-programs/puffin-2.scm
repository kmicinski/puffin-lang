(let loop ([i 0] [keep '()])
  (if (< i 10)
      (loop (+ i 1) (if (eq? (remainder i 3) 0) (cons i keep) keep))
      (println keep)))
