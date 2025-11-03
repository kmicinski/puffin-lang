(define (f x)
  (if (eq? x 0) 1 (+ 5 (f (- x 1)))))

(f (read))
