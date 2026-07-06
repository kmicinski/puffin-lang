;; puffin-9: an eval/apply interpreter for an extended lambda calculus,
;; written the way the Puffin compiler itself is written -- match with
;; quasiquote patterns over s-expression ASTs, immutable hashes for
;; environments, closures as tagged data. This is the warm-up for
;; bootstrapping: `evaluate` below is a miniature of interpret-puffin.
;;
;; The object language ("LC+"):
;;   e ::= n | #t | #f | x
;;       | (lambda (x ...) e) | (e e ...)
;;       | (if e e e) | (let ([x e] ...) e) | (letrec ([f e]) e)
;;       | (prim e e)            prim in {+ - * = < cons}
;;       | (car e) | (cdr e) | (null? e) | 'datum
;;
;; Values: numbers, booleans, pairs/nil, and closures
;; (closure formals body env). letrec is implemented with a
;; back-patched environment cell, mirroring how the reference
;; interpreter ties recursive knots.

;; ---- environments: immutable hashes, symbol-keyed ------------------
(define (env-lookup env x)
  (if (hash-has-key? env x)
      (hash-ref env x)
      (error (list 'unbound-variable x))))

(define (env-extend* env xs vs)
  (cond [(and (null? xs) (null? vs)) env]
        [(or (null? xs) (null? vs)) (error 'arity-mismatch)]
        [else (env-extend* (hash-set env (car xs) (car vs)) (cdr xs) (cdr vs))]))

;; ---- recursive cells for letrec ------------------------------------
;; a cell is a 1-slot vector; deref happens at variable lookup time
(define (make-cell) (vector 'undefined))
(define (cell? v) (and (vector? v) (eq? (vector-length v) 1)))
(define (cell-set! c v) (vector-set! c 0 v))
(define (cell-get c)
  (let ([v (vector-ref c 0)])
    (if (eq? v 'undefined) (error 'letrec-used-before-defined) v)))

;; ---- the evaluator ---------------------------------------------------
(define (evaluate e env)
  (match e
    [(? fixnum? n) n]
    [#t #t]
    [#f #f]
    [`(quote ,d) d]
    [(? symbol? x)
     (let ([v (env-lookup env x)])
       (if (cell? v) (cell-get v) v))]
    [`(lambda (,xs ...) ,body) (list 'closure xs body env)]
    [`(if ,g ,t ,f)
     (if (evaluate g env) (evaluate t env) (evaluate f env))]
    [`(let ([,xs ,es] ...) ,body)
     (evaluate body (env-extend* env xs (map (lambda (e0) (evaluate e0 env)) es)))]
    [`(letrec ([,f ,e0]) ,body)
     (let* ([cell (make-cell)]
            [env+ (hash-set env f cell)])
       (begin (cell-set! cell (evaluate e0 env+))
              (evaluate body env+)))]
    [`(car ,e0) (car (evaluate e0 env))]
    [`(cdr ,e0) (cdr (evaluate e0 env))]
    [`(null? ,e0) (null? (evaluate e0 env))]
    [`(,op ,e0 ,e1)
     #:when (member op '(+ - * = < cons))
     (delta op (evaluate e0 env) (evaluate e1 env))]
    [`(,e-f ,e-args ...)
     (apply-closure (evaluate e-f env)
                    (map (lambda (e0) (evaluate e0 env)) e-args))]
    [_ (error (list 'bad-expression e))]))

(define (delta op a b)
  (match op
    ['+ (+ a b)]
    ['- (- a b)]
    ['* (* a b)]
    ['= (eq? a b)]
    ['< (< a b)]
    ['cons (cons a b)]))

(define (apply-closure f args)
  (match f
    [`(closure ,xs ,body ,env)
     (evaluate body (env-extend* env xs args))]
    [_ (error (list 'not-a-procedure f))]))

(define (run e) (evaluate e (hash)))

;; ---- programs in the object language ---------------------------------

;; recursion via letrec: factorial
(println (run '(letrec ([fact (lambda (n) (if (= n 0) 1 (* n (fact (- n 1)))))])
                 (fact 10))))                                        ;; 3628800

;; higher-order functions: compose and twice
(println (run '(let ([compose (lambda (f g) (lambda (x) (f (g x))))]
                     [add3 (lambda (n) (+ n 3))]
                     [dbl (lambda (n) (* n 2))])
                 ((compose add3 dbl) 10))))                          ;; 23

;; church numerals, converted back to integers
(println (run '(let ([zero (lambda (f) (lambda (x) x))]
                     [succ (lambda (n) (lambda (f) (lambda (x) (f ((n f) x)))))]
                     [to-int (lambda (n) ((n (lambda (k) (+ k 1))) 0))])
                 (let ([three (succ (succ (succ zero)))])
                   (to-int (succ three))))))                         ;; 4

;; recursion WITHOUT letrec: the Z combinator (strict Y)
(println (run '(let ([Z (lambda (f)
                          ((lambda (x) (f (lambda (v) ((x x) v))))
                           (lambda (x) (f (lambda (v) ((x x) v))))))])
                 (let ([fib (Z (lambda (fib)
                                 (lambda (n)
                                   (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))))])
                   (fib 15)))))                                      ;; 610

;; lists in the object language: build 1..5 and sum it
(println (run '(letrec ([build (lambda (i) (if (= i 6) '() (cons i (build (+ i 1)))))])
                 (letrec ([sum (lambda (l) (if (null? l) 0 (+ (car l) (sum (cdr l)))))])
                   (sum (build 1))))))                               ;; 15

;; the interpreter interpreting an interpreter (two levels down):
;; LC+ runs a tiny evaluator for arithmetic expression trees
(println (run '(letrec ([ev (lambda (t)
                              (if (null? (cdr t))
                                  (car t)
                                  (let ([op (car t)]
                                        [a (ev (car (cdr t)))]
                                        [b (ev (car (cdr (cdr t))))])
                                    (if (= op 0) (+ a b) (* a b)))))])
                 ;; tree: (* (+ 1 2) (+ 3 4)) encoded as nested lists
                 ;; ops: 0 = add, 1 = mul; leaves: (n . '())
                 (ev (cons 1 (cons (cons 0 (cons (cons 1 '()) (cons (cons 2 '()) '())))
                                   (cons (cons 0 (cons (cons 3 '()) (cons (cons 4 '()) '())))
                                        '())))))))                   ;; 21

;; errors surface as Puffin errors: applying a number halts cleanly
;; (uncomment to see:  (run '(5 5))  =>  error: (not-a-procedure 5)
(run '(((lambda (x) (lambda (y) (- x y))) 20) 6))
