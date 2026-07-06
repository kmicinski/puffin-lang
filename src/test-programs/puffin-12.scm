;; puffin-12: a small interpreter for PCF, the canonical toy typed
;; language (Plotkin 1977): naturals with succ/pred, the zero test
;; ifz, unary lambdas, application, and general recursion via fix.
;; Written with quasiquote PATTERNS on the way in and quasiquote
;; CONSTRUCTION on the way out -- values are tagged s-expressions,
;; environments are immutable hashes. (This is also the bundled demo
;; for the web pipeline visualizer.)
;;
;;   e ::= n | x | (lambda (x) e) | (e e)
;;       | (succ e) | (pred e) | (ifz e e e) | (fix e)
;;
;; fix is call-by-value, eta-delayed: (fix f) is a value; applying
;; it to v unrolls one step, applying f to (fix f) and then to v.

(define (pcf-eval e env)
  (match e
    [(? fixnum? n) n]
    [(? symbol? x)
     (if (hash-has-key? env x)
         (hash-ref env x)
         (error `(unbound ,x)))]
    [`(lambda (,x) ,body) `(closure ,x ,body ,env)]
    [`(succ ,e0) (+ (pcf-eval e0 env) 1)]
    [`(pred ,e0)
     (let ([n (pcf-eval e0 env)])
       (if (eq? n 0) 0 (- n 1)))]                 ;; pred 0 = 0, as in PCF
    [`(ifz ,e0 ,e1 ,e2)
     (if (eq? (pcf-eval e0 env) 0)
         (pcf-eval e1 env)
         (pcf-eval e2 env))]
    [`(fix ,e0) `(fixpoint ,(pcf-eval e0 env))]
    [`(,e-f ,e-a)
     (pcf-apply (pcf-eval e-f env) (pcf-eval e-a env))]
    [_ (error `(bad-pcf-expression ,e))]))

(define (pcf-apply vf va)
  (match vf
    [`(closure ,x ,body ,env) (pcf-eval body (hash-set env x va))]
    [`(fixpoint ,f) (pcf-apply (pcf-apply f vf) va)]
    [_ (error `(not-a-function ,vf))]))

(define (run e) (pcf-eval e (hash)))

;; addition, defined recursively on the first argument
(define pcf-add
  '(fix (lambda (add)
          (lambda (m)
            (lambda (n)
              (ifz m n (succ ((add (pred m)) n))))))))

(println (run `((,pcf-add 3) 4)))                          ;; 7

;; multiplication, using add
(define pcf-mul
  `(fix (lambda (mul)
          (lambda (m)
            (lambda (n)
              (ifz m 0 ((,pcf-add n) ((mul (pred m)) n))))))))

(println (run `((,pcf-mul 6) 7)))                          ;; 42

;; factorial, using mul
(define pcf-fact
  `(fix (lambda (fact)
          (lambda (n)
            (ifz n (succ 0) ((,pcf-mul n) (fact (pred n))))))))

(println (run `(,pcf-fact 6)))                             ;; 720

;; higher-order: twice, and pred as a first-class function
(println (run '(((lambda (f) (lambda (x) (f (f x))))
                 (lambda (y) (pred y)))
                9)))                                       ;; 7

;; PCF programs are data: count the lambdas in pcf-fact
(define (count-lambdas e)
  (match e
    [`(lambda (,_) ,body) (+ 1 (count-lambdas body))]
    [`(,es ...) (foldl (lambda (x acc) (+ acc (count-lambdas x))) 0 es)]
    [_ 0]))

(println (list 'lambdas-in-fact (count-lambdas pcf-fact)))
(run `(,pcf-fact 5))
