;; the Plotkin call-by-value CPS transform, with deterministic
;; continuation names; both original and transformed terms are run
;; through one CBV interpreter and must agree
(define kc (vector 0))
(define (fresh-k base)
  (vector-set! kc 0 (+ 1 (vector-ref kc 0)))
  (string->symbol (string-append base (number->string (vector-ref kc 0)))))
(define (cps e)
  (match e
    [(? fixnum? _) (let ([k (fresh-k "k")]) `(lambda (,k) (,k ,e)))]
    [(? symbol? _) (let ([k (fresh-k "k")]) `(lambda (,k) (,k ,e)))]
    [`(lambda (,x) ,b)
     (let ([k (fresh-k "k")])
       `(lambda (,k) (,k (lambda (,x) ,(cps b)))))]
    [`(,f ,a)
     (let ([k (fresh-k "k")] [fv (fresh-k "f")] [av (fresh-k "a")])
       `(lambda (,k)
          (,(cps f) (lambda (,fv)
            (,(cps a) (lambda (,av)
              ((,fv ,av) ,k)))))))]))
(define (ev e env)
  (match e
    [(? fixnum? n) n]
    [(? symbol? x) (hash-ref env x)]
    [`(prim-inc ,a) (+ 1 (ev a env))]
    [`(lambda (,x) ,b) `(clo ,x ,b ,env)]
    [`(,f ,a)
     (match (ev f env)
       [`(clo ,x ,b ,cenv) (ev b (hash-set cenv x (ev a env)))])]))
;; inc is an ordinary closure in direct style, and a CPS-protocol
;; closure ((inc x) k) = (k (x+1)) on the transformed side
(define (direct-env) (hash 'inc (ev '(lambda (x) (prim-inc x)) (hash))))
(define (cps-env)
  (hash 'inc (ev '(lambda (x) (lambda (k) (k (prim-inc x)))) (hash))))
(define (run-direct e) (ev e (direct-env)))
(define (run-cps e)
  (vector-set! kc 0 0)
  (ev `(,(cps e) (lambda (v) v)) (cps-env)))
(define p1 '((lambda (x) (inc x)) 41))
(define p2 '(((lambda (f) (lambda (x) (f (f x)))) inc) 5))
(define p3 '((lambda (g) (g (g 10))) (lambda (y) (inc (inc y)))))
(println (list (run-direct p1) (run-cps p1)))
(println (list (run-direct p2) (run-cps p2)))
(println (list (run-direct p3) (run-cps p3)))
(vector-set! kc 0 0)
(cps '(lambda (x) x))
