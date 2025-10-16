(program (let ([x (read)]) (let ([y (let ([x (read)]) (+ x (+ x x)))]) (+ (- (+ x y)) x))))
