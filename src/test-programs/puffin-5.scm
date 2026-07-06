;; higher-order + eta-expanded prims + equal?
(define (map f xs) (if (null? xs) '() (cons (f (car xs)) (map f (cdr xs)))))
(define (filter p xs)
  (cond [(null? xs) '()]
        [(p (car xs)) (cons (car xs) (filter p (cdr xs)))]
        [else (filter p (cdr xs))]))
(define (foldl f acc xs) (if (null? xs) acc (foldl f (f (car xs) acc) (cdr xs))))
(println (map car (list (cons 1 2) (cons 3 4))))
(println (filter pair? (list 1 (cons 1 2) 'x (cons 3 4))))
(println (foldl + 0 (list 1 2 3 4 5)))
(println (equal? (list 1 (vector 2 3)) (list 1 (vector 2 3))))
(println (equal? "abc" (string-append "ab" "c")))
(println (eq? 'foo 'foo))
