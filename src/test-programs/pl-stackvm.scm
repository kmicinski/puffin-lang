;; the CIS352 classic: compile arithmetic expressions to a stack
;; machine, then run the machine -- and check it agrees with direct
;; evaluation on every test
(define (compile-expr e)
  (match e
    [(? fixnum? n) `((push ,n))]
    [`(+ ,a ,b) (append (compile-expr a) (append (compile-expr b) '((add))))]
    [`(- ,a ,b) (append (compile-expr a) (append (compile-expr b) '((sub))))]
    [`(* ,a ,b) (append (compile-expr a) (append (compile-expr b) '((mul))))]
    [`(neg ,a) (append (compile-expr a) '((neg)))]))
(define (run-vm instrs stack)
  (match instrs
    ['() (car stack)]
    [(cons i rest)
     (match (list i stack)
       [`((push ,n) ,st) (run-vm rest (cons n st))]
       [`((add) (,b ,a . ,st)) (run-vm rest (cons (+ a b) st))]
       [`((sub) (,b ,a . ,st)) (run-vm rest (cons (- a b) st))]
       [`((mul) (,b ,a . ,st)) (run-vm rest (cons (* a b) st))]
       [`((neg) (,a . ,st)) (run-vm rest (cons (- a) st))])]))
(define (direct e)
  (match e
    [(? fixnum? n) n]
    [`(+ ,a ,b) (+ (direct a) (direct b))]
    [`(- ,a ,b) (- (direct a) (direct b))]
    [`(* ,a ,b) (* (direct a) (direct b))]
    [`(neg ,a) (- (direct a))]))
(define tests
  '((+ 1 2)
    (* (+ 1 2) (- 10 4))
    (neg (* 3 (+ 4 5)))
    (- (* (* 2 3) (* 4 5)) (+ (+ 1 2) 3))
    (* (neg 7) (- 2 9))))
(for-each-check tests)
(define (for-each-check ts)
  (match ts
    ['() 'all-agree]
    [(cons t rest)
     (let ([c (run-vm (compile-expr t) '())] [d (direct t)])
       (println (list t '=> c (if (eq? c d) 'ok 'MISMATCH)))
       (for-each-check rest))]))
(println (compile-expr '(* (+ 1 2) 3)))
(run-vm (compile-expr '(* (+ 1 2) (- 10 4))) '())
