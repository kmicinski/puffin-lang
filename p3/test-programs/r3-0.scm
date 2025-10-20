(program
 (let* ([v (make-vector 3)])
   (begin (vector-set! v 0 10)
          (vector-set! v 1 20)
          (vector-set! v 2 30)
          (vector-ref v 1))))
