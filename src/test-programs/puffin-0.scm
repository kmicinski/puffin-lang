(define (fact n) (if (eq? n 0) 1 (* n (fact (- n 1)))))
(println (fact 10))
(fact 5)
