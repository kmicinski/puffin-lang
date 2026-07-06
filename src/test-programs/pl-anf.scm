;; A-normalization of expressions (the anf-convert pass in miniature)
;; with deterministic temp names, plus an ANF interpreter to verify
;; meaning is preserved
(define tmpc (vector 0))
(define (fresh-tmp)
  (vector-set! tmpc 0 (+ 1 (vector-ref tmpc 0)))
  (string->symbol (string-append "t." (number->string (vector-ref tmpc 0)))))
(define (atom? e) (or (fixnum? e) (symbol? e)))
(define (normalize e k)
  (match e
    [(? atom? _) (k e)]
    [`(,op ,a ,b)
     (normalize a (lambda (va)
       (normalize b (lambda (vb)
         (let ([t (fresh-tmp)])
           `(let ([,t (,op ,va ,vb)]) ,(k t)))))))]))
(define (anf e) (begin (vector-set! tmpc 0 0) (normalize e (lambda (v) v))))
(define (eval-anf e env)
  (match e
    [(? fixnum? n) n]
    [(? symbol? x) (hash-ref env x)]
    [`(let ([,x (,op ,a ,b)]) ,body)
     (let ([va (eval-anf a env)] [vb (eval-anf b env)])
       (eval-anf body (hash-set env x
         (cond [(eq? op '+) (+ va vb)] [(eq? op '-) (- va vb)] [else (* va vb)]))))]))
(define (eval-direct e)
  (match e
    [(? fixnum? n) n]
    [`(,op ,a ,b)
     (let ([va (eval-direct a)] [vb (eval-direct b)])
       (cond [(eq? op '+) (+ va vb)] [(eq? op '-) (- va vb)] [else (* va vb)]))]))
(define e1 '(* (+ 1 (* 2 3)) (- 10 (+ 4 4))))
(println (anf e1))
(println (list (eval-anf (anf e1) (hash)) (eval-direct e1)))
(define e2 '(+ (+ (+ 1 2) (+ 3 4)) (* (* 5 6) 7)))
(println (equal? (eval-anf (anf e2) (hash)) (eval-direct e2)))
(anf '(- 5 2))
