;; pattern matching: guards, vectors, strings, case, predicates
(define (classify v)
  (match v
    [0 'zero]
    [(? fixnum? n) #:when (< n 0) 'negative]
    [(? fixnum? _) 'positive]
    [#t 'yes]
    [(vector a b) (list 'pair-vec a b)]
    ["hello" 'greeting]
    [(list) 'empty]
    [(list x) (list 'singleton x)]
    [_ 'other]))
(println (classify 0))
(println (classify -5))
(println (classify 12))
(println (classify #t))
(println (classify (vector 1 2)))
(println (classify "hello"))
(println (classify '()))
(println (classify (list 42)))
(println (classify (make-hash)))
(case (+ 1 2) [(1 2) (println 'low)] [(3 4) (println 'mid)] [else (println 'high)])
