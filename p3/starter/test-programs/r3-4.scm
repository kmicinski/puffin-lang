(program
  (let* ([a (read)]
         [b (read)]
         [c (read)]
         [d (read)]
         [v (make-vector 4)]
         [tmp (make-vector 1)]
         [acc 0]
         [i 0])
    (begin
      (vector-set! v 0 a)
      (vector-set! v 1 b)
      (vector-set! v 2 c)
      (vector-set! v 3 d)
      ;; swap v[1] and v[2] using a temporary (all constant indices)
      (vector-set! tmp 0 (vector-ref v 1))
      (vector-set! v 1 (vector-ref v 2))
      (vector-set! v 2 (vector-ref tmp 0))
      ;; compute max of (v0,v1) and (v2,v3), then add a small loop accumulator
      (let ([m01 (if (>= (vector-ref v 0) (vector-ref v 1))
                     (vector-ref v 0)
                     (vector-ref v 1))])
        (let ([m23 (if (>= (vector-ref v 2) (vector-ref v 3))
                       (vector-ref v 2)
                       (vector-ref v 3))])
          (begin
            (while (< i 5)
		   (begin (set! acc (+ acc i))
			  (set! i (+ i 1))))
            (+ m01 (+ m23 acc))))))))
