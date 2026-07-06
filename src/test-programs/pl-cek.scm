;; the CEK machine: control / environment / kontinuation
(define (inject e) (list e (hash) 'halt))
(define (apply-k k v)
  (match k
    ['halt (list 'done v)]
    [`(arg ,e ,env ,k1) (list e env `(fun ,v ,k1))]
    [`(fun (closure ,x ,body ,cenv) ,k1) (list body (hash-set cenv x v) k1)]
    [`(prim1 ,op ,k1) (apply-k k1 (if (eq? op 'add1) (+ v 1) (- v 1)))]
    [`(ifk ,t ,e ,env ,k1) (list (if v t e) env k1)]))
(define (step s)
  (match s
    [`(,(? fixnum? n) ,env ,k) (apply-k k n)]
    [`(#t ,env ,k) (apply-k k #t)]
    [`(#f ,env ,k) (apply-k k #f)]
    [`(,(? symbol? x) ,env ,k) (apply-k k (hash-ref env x))]
    [`((lambda (,x) ,b) ,env ,k) (apply-k k `(closure ,x ,b ,env))]
    [`((add1 ,e) ,env ,k) (list e env `(prim1 add1 ,k))]
    [`((sub1 ,e) ,env ,k) (list e env `(prim1 sub1 ,k))]
    [`((zero? ,e) ,env ,k) (list e env `(prim1 zero ,k))]
    [`((if ,g ,t ,e) ,env ,k) (list g env `(ifk ,t ,e ,env ,k))]
    [`((,f ,a) ,env ,k) (list f env `(arg ,a ,env ,k))]))
;; zero? needs its own prim handling: extend apply-k via wrapper
(define (apply-k2 k v)
  (match k
    [`(prim1 zero ,k1) (apply-k2 k1 (eq? v 0))]
    [`(prim1 ,op ,k1) (apply-k2 k1 (if (eq? op 'add1) (+ v 1) (- v 1)))]
    ['halt (list 'done v)]
    [`(arg ,e ,env ,k1) (list e env `(fun ,v ,k1))]
    [`(fun (closure ,x ,body ,cenv) ,k1) (list body (hash-set cenv x v) k1)]
    [`(ifk ,t ,e ,env ,k1) (list (if v t e) env k1)]))
(define (step2 s)
  (match s
    [`(,(? fixnum? n) ,env ,k) (apply-k2 k n)]
    [`(#t ,env ,k) (apply-k2 k #t)]
    [`(#f ,env ,k) (apply-k2 k #f)]
    [`(,(? symbol? x) ,env ,k) (apply-k2 k (hash-ref env x))]
    [`((lambda (,x) ,b) ,env ,k) (apply-k2 k `(closure ,x ,b ,env))]
    [`((add1 ,e) ,env ,k) (list e env `(prim1 add1 ,k))]
    [`((sub1 ,e) ,env ,k) (list e env `(prim1 sub1 ,k))]
    [`((zero? ,e) ,env ,k) (list e env `(prim1 zero ,k))]
    [`((if ,g ,t ,e) ,env ,k) (list g env `(ifk ,t ,e ,env ,k))]
    [`((,f ,a) ,env ,k) (list f env `(arg ,a ,env ,k))]))
(define (run e)
  (let loop ([s (inject e)] [steps 0])
    (match s
      [`(done ,v) (list v 'in steps 'steps)]
      [_ (loop (step2 s) (+ steps 1))])))
(println (run '(add1 (add1 40))))
(println (run '((lambda (x) (add1 x)) 5)))
(println (run '(if (zero? (sub1 1)) 42 99)))
;; self-application of a doubler via explicit Y-free recursion:
(println (run '(((lambda (f) (lambda (x) (f (f x)))) (lambda (y) (add1 (add1 y)))) 10)))
(run '((lambda (x) (if (zero? x) 100 200)) 0))
