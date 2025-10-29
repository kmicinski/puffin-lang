(program
  (let* ([a (read)]
         [b (read)]
         [flag #t]
         [acc 0])
    (begin
      ;; warm-up branch: mix <, eq?, unary -
      (if (if (< b a) #t (eq? a b))
          (set! acc (+ acc a))
          (set! acc (+ acc (- b))))
      ;; triple-nested loops: 2 x 3 x 2 = 12 iterations
      (let* ([i 0])
        (while (< i 2)
          (begin
            (let* ([j 0])
              (while (< j 3)
                (begin
                  (let* ([k 0])
                    (while (< k 2)
                      (begin
                        (if flag
                            (set! acc (+ acc (+ i j)))
                            (set! acc (+ acc (+ j k))))
                        (set! k (+ k 1)))))
                  (set! j (+ j 1)))))
            (if flag
                (set! flag #f)
                (set! flag #t))
            (set! i (+ i 1)))))
      ;; boxed swap & accumulation
      (let* ([x (make-vector 1)]
             [y (make-vector 1)]
             [_ (vector-set! x 0 acc)]
             [_ (vector-set! y 0 (+ acc 5))]
             [t (make-vector 1)]
             [_ (vector-set! t 0 0)])
        (begin
          (vector-set! t 0 (vector-ref x 0))
          (vector-set! x 0 (vector-ref y 0))
          (vector-set! y 0 (vector-ref t 0))
          (set! acc (+ (vector-ref x 0) (vector-ref y 0)))))
      ;; finalize with not/eq?
      (if (not (eq? a b))
          (set! acc (+ acc 2))
          (set! acc (+ acc 1)))
      acc)))
