(program (define (f a b c) (lambda (x y) (lambda (z) (+ (+ (+ a b) c) (+ (+ x y) z)))))
         (((f 1 2 3) 4 5) 6))
