(program
  (let* ([x (read)]
         [y (read)]
         [z (read)]
         [score 0]
         [tmp (make-vector 1)]
         [_ (vector-set! tmp 0 0)]
         [res (make-vector 1)]
         [_ (vector-set! res 0 0)])
    (begin
      ;; stage 1: pairwise adjustments
      (if (< x y)
          (set! score (+ score (+ x 3)))
          (set! score (+ score (+ y 1))))
      (if (eq? y z)
          (set! score (+ score 4))
          (set! score (+ score (- z))))
      ;; stage 2: small while with sequencing via (void)
      (let* ([i 0])
        (let* ([_ (while
                    (< i 5)
                    (begin
                      (set! score (+ score 2))
                      (set! i (+ i 1))))])
          (void)))
      ;; stage 3: store to vectors and shuffle
      (let* ([a (make-vector 1)]
             [b (make-vector 1)]
             [_ (vector-set! a 0 score)]
             [_ (vector-set! b 0 (+ score 7))])
        (begin
          (vector-set! tmp 0 (vector-ref a 0))
          (vector-set! a 0 (vector-ref b 0))
          (vector-set! b 0 (vector-ref tmp 0))
          (vector-set! res 0 (+ (vector-ref a 0) (vector-ref b 0)))))
      ;; stage 4: tiny conditional polish with not
      (let* ([flag #t])
        (if (not flag)
            (vector-set! res 0 (+ (vector-ref res 0) 1))
            (vector-set! res 0 (+ (vector-ref res 0) 2))))
      (vector-ref res 0))))
