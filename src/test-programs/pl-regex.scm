;; regex -> Thompson NFA -> simulation (epsilon closure over state
;; sets as sorted lists). regex: sym | (seq r r) | (alt r r) | (star r)
(define nstate (vector 0))
(define (new-state!)
  (vector-set! nstate 0 (+ 1 (vector-ref nstate 0)))
  (vector-ref nstate 0))
;; build returns (start accept edges) where edges is a list of
;; (from label to), label a symbol or 'eps
(define (build r)
  (match r
    [(? symbol? c)
     (let* ([s (new-state!)] [a (new-state!)])
       (list s a (list (list s c a))))]
    [`(seq ,r1 ,r2)
     (match (list (build r1) (build r2))
       [`((,s1 ,a1 ,e1) (,s2 ,a2 ,e2))
        (list s1 a2 (cons (list a1 'eps s2) (append e1 e2)))])]
    [`(alt ,r1 ,r2)
     (match (list (build r1) (build r2))
       [`((,s1 ,a1 ,e1) (,s2 ,a2 ,e2))
        (let ([s (new-state!)] [a (new-state!)])
          (list s a (append (list (list s 'eps s1) (list s 'eps s2)
                                  (list a1 'eps a) (list a2 'eps a))
                            (append e1 e2))))])]
    [`(star ,r1)
     (match (build r1)
       [`(,s1 ,a1 ,e1)
        (let ([s (new-state!)] [a (new-state!)])
          (list s a (append (list (list s 'eps s1) (list s 'eps a)
                                  (list a1 'eps s1) (list a1 'eps a))
                            e1)))])]))
(define (eps-close states edges)
  (let ([next (foldl (lambda (e acc)
                       (match e
                         [`(,f eps ,t)
                          (if (and (member f acc) (not (member t acc))) (cons t acc) acc)]
                         [_ acc]))
                     states edges)])
    (if (eq? (length next) (length states)) states (eps-close next edges))))
(define (move states c edges)
  (foldl (lambda (e acc)
           (match e
             [`(,f ,l ,t) (if (and (eq? l c) (member f states) (not (member t acc)))
                              (cons t acc) acc)]))
         '() edges))
(define (matches? r input)
  (vector-set! nstate 0 0)
  (match (build r)
    [`(,start ,accept ,edges)
     (let loop ([states (eps-close (list start) edges)] [in input])
       (match in
         ['() (if (member accept states) #t #f)]
         [(cons c rest) (loop (eps-close (move states c edges) edges) rest)]))]))
;; (a|b)*abb -- the textbook regex
(define R '(seq (star (alt a b)) (seq a (seq b b))))
(println (matches? R '(a b b)))
(println (matches? R '(a a b a b b)))
(println (matches? R '(a b a)))
(println (matches? R '()))
(println (matches? '(star (seq a b)) '(a b a b a b)))
(matches? '(star (seq a b)) '(a b a))
