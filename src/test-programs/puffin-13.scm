;; variadic functions: dotted formals, all-rest lambdas, the arity
;; protocol under packed (>6-arg) calls, closures, tail positions
(define (weigh a b . extras)
  (list a b (length extras) extras))
(println (weigh 1 2))                       ;; (1 2 0 ())
(println (weigh 1 2 3))                     ;; (1 2 1 (3))
(println (weigh 1 2 3 4 5))                 ;; (1 2 3 (3 4 5))
(println (weigh 1 2 3 4 5 6 7 8 9))         ;; packed call: (1 2 7 (3 4 5 6 7 8 9))

(define collect (lambda args args))
(println (collect))                          ;; ()
(println (collect 'a 'b 'c))                 ;; (a b c)
(println (collect 1 2 3 4 5 6 7 8))          ;; packed: (1 2 3 4 5 6 7 8)

;; variadic closures capture like anything else
(define (make-tagger tag)
  (lambda vals (cons tag vals)))
(define t (make-tagger 'best))
(println (t 1 2 3))                          ;; (best 1 2 3)

;; variadic in tail position, recursion via the rest list
(define (sum-all . ns)
  (foldl + 0 ns))
(println (sum-all 1 2 3 4 5 6 7 8 9 10))     ;; 55 (packed, tail-ish)

;; mixing with higher-order code
(println (map (lambda (k) (weigh k k k)) '(1 2)))
(sum-all 40 2)
