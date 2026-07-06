;; Hindley-Milner inference for mini-ML: unification + Algorithm W
;; (monomorphic let for brevity: let generalization elided; the W
;; skeleton, substitutions, and occurs check are the point)
(define counter (vector 0))
(define (fresh!)
  (vector-set! counter 0 (+ 1 (vector-ref counter 0)))
  (list 'tv (vector-ref counter 0)))
(define (tv? t) (match t [`(tv ,_) #t] [_ #f]))
;; substitution: immutable hash tvnum -> type
(define (walk t s)
  (match t
    [`(tv ,n) (if (hash-has-key? s n) (walk (hash-ref s n) s) t)]
    [_ t]))
(define (occurs? n t s)
  (match (walk t s)
    [`(tv ,m) (eq? n m)]
    [`(-> ,a ,b) (or (occurs? n a s) (occurs? n b s))]
    [_ #f]))
(define (unify a b s)
  (let ([a (walk a s)] [b (walk b s)])
    (match (list a b)
      [`((tv ,n) ,_) (if (equal? a b) s (if (occurs? n b s) 'occurs-fail (hash-set s n b)))]
      [`(,_ (tv ,n)) (unify b a s)]
      [`((-> ,a1 ,a2) (-> ,b1 ,b2))
       (let ([s1 (unify a1 b1 s)])
         (if (eq? s1 'occurs-fail) 'occurs-fail (unify a2 b2 s1)))]
      [_ (if (equal? a b) s 'clash)]))) 
(define (resolve t s)
  (match (walk t s)
    [`(-> ,a ,b) `(-> ,(resolve a s) ,(resolve b s))]
    [t2 t2]))
;; W: returns (type . subst) or an error symbol
(define (W e ctx s)
  (match e
    [(? fixnum? _) (cons 'int s)]
    [#t (cons 'bool s)] [#f (cons 'bool s)]
    [(? symbol? x) (cons (hash-ref ctx x) s)]
    [`(lambda (,x) ,body)
     (let* ([a (fresh!)]
            [r (W body (hash-set ctx x a) s)])
       (if (symbol? (car r))
           r   ;; propagate unification failure
           (cons `(-> ,a ,(car r)) (cdr r))))]
    [`(let ([,x ,e0]) ,body)
     (let ([r0 (W e0 ctx s)])
       (W body (hash-set ctx x (car r0)) (cdr r0)))]
    [`(,f ,a)
     (let* ([rf (W f ctx s)]
            [ra (W a ctx (cdr rf))]
            [res (fresh!)]
            [s2 (unify (car rf) `(-> ,(car ra) ,res) (cdr ra))])
       (if (symbol? s2) (cons s2 (cdr ra)) (cons res s2)))]))
(define (infer e)
  (vector-set! counter 0 0)
  (let ([r (W e (hash) (hash))])
    (if (symbol? (car r)) (car r) (rename-tvs (resolve (car r) (cdr r))))))
;; canonical tv names for printing: a, b, c...
(define (rename-tvs t)
  (define names '(a b c d e f g h))
  (define seen (vector (hash) 0))
  (define (go t)
    (match t
      [`(tv ,n)
       (let ([m (vector-ref seen 0)])
         (if (hash-has-key? m n)
             (hash-ref m n)
             (let ([nm (list-ref names (vector-ref seen 1))])
               (vector-set! seen 0 (hash-set m n nm))
               (vector-set! seen 1 (+ 1 (vector-ref seen 1)))
               nm)))]
      [`(-> ,x ,y) `(-> ,(go x) ,(go y))]
      [_ t]))
  (go t))
(println (infer '(lambda (x) x)))                                ;; (-> a a)
(println (infer '(lambda (f) (lambda (x) (f x)))))               ;; (-> (-> a b) (-> a b))
(println (infer '(lambda (f) (lambda (g) (lambda (x) (f (g x)))))))
(println (infer '(let ([id (lambda (x) x)]) (id 5))))            ;; int
(println (infer '(lambda (x) (x x))))                            ;; occurs-fail
(println (infer '(lambda (f) (f 3))))                            ;; (-> (-> int a) a)
(infer '((lambda (x) x) #t))
