;; symbolic differentiation with algebraic simplification
(define (d e x)
  (match e
    [(? fixnum? _) 0]
    [(? symbol? y) (if (eq? y x) 1 0)]
    [`(+ ,a ,b) (simp `(+ ,(d a x) ,(d b x)))]
    [`(- ,a ,b) (simp `(- ,(d a x) ,(d b x)))]
    [`(* ,a ,b) (simp `(+ (* ,(d a x) ,b) (* ,a ,(d b x))))]
    [`(pow ,a ,(? fixnum? n))
     (simp `(* ,n (* (pow ,a ,(- n 1)) ,(d a x))))]))
(define (simp e)
  (match e
    [`(+ 0 ,b) (simp b)] [`(+ ,a 0) (simp a)]
    [`(- ,a 0) (simp a)]
    [`(* 0 ,_) 0] [`(* ,_ 0) 0]
    [`(* 1 ,b) (simp b)] [`(* ,a 1) (simp a)]
    [`(pow ,a 1) (simp a)] [`(pow ,_ 0) 1]
    [`(+ ,(? fixnum? a) ,(? fixnum? b)) (+ a b)]
    [`(* ,(? fixnum? a) ,(? fixnum? b)) (* a b)]
    [`(,op ,a ,b)
     (let ([a2 (simp a)] [b2 (simp b)])
       (if (and (equal? a a2) (equal? b b2)) e (simp `(,op ,a2 ,b2))))]
    [_ e]))
(println (d '(pow x 3) 'x))                          ;; (* 3 (pow x 2))
(println (d '(* x x) 'x))                            ;; (+ x x)
(println (d '(+ (* 3 (pow x 2)) (* 5 x)) 'x))
(println (d '(* x (* x x)) 'x))
(println (d '(pow (+ x 1) 2) 'x))
;; evaluate d/dx of x^3 + 2x at x=4 numerically: 3*16+2 = 50
(define (ev e env)
  (match e
    [(? fixnum? n) n]
    [(? symbol? y) (hash-ref env y)]
    [`(+ ,a ,b) (+ (ev a env) (ev b env))]
    [`(- ,a ,b) (- (ev a env) (ev b env))]
    [`(* ,a ,b) (* (ev a env) (ev b env))]
    [`(pow ,a ,n) (let ([v (ev a env)]) (let loop ([i 0] [acc 1]) (if (< i n) (loop (+ i 1) (* acc v)) acc)))]))
(ev (d '(+ (pow x 3) (* 2 x)) 'x) (hash 'x 4))
