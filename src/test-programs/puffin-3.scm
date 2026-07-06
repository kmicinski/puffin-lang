(let loop ([i 0])
  (if (< i 2000000) (loop (+ i 1)) i))
