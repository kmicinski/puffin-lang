;; big-step interpreter for IMP (While language); the store is an
;; immutable hash threaded through evaluation
(define (aeval a st)
  (match a
    [(? fixnum? n) n]
    [(? symbol? x) (hash-ref/default st x 0)]
    [`(+ ,a1 ,a2) (+ (aeval a1 st) (aeval a2 st))]
    [`(- ,a1 ,a2) (- (aeval a1 st) (aeval a2 st))]
    [`(* ,a1 ,a2) (* (aeval a1 st) (aeval a2 st))]))
(define (beval b st)
  (match b
    ['true #t] ['false #f]
    [`(= ,a1 ,a2) (eq? (aeval a1 st) (aeval a2 st))]
    [`(<= ,a1 ,a2) (<= (aeval a1 st) (aeval a2 st))]
    [`(not ,b1) (not (beval b1 st))]
    [`(and ,b1 ,b2) (and (beval b1 st) (beval b2 st))]))
(define (ceval c st)
  (match c
    ['skip st]
    [`(:= ,x ,a) (hash-set st x (aeval a st))]
    [`(seq ,c1 ,c2) (ceval c2 (ceval c1 st))]
    [`(if ,b ,c1 ,c2) (if (beval b st) (ceval c1 st) (ceval c2 st))]
    [`(while ,b ,body)
     (if (beval b st)
         (ceval c (ceval body st))
         st)]))
;; factorial in IMP
(define fact-prog
  '(seq (:= acc 1)
        (while (not (<= n 1))
               (seq (:= acc (* acc n))
                    (:= n (- n 1))))))
(define st1 (ceval fact-prog (hash 'n 10)))
(println (hash-ref st1 'acc))                     ;; 3628800
;; gcd in IMP (subtraction method)
(define gcd-prog
  '(while (not (= a b))
          (if (<= a b) (:= b (- b a)) (:= a (- a b)))))
(define st2 (ceval gcd-prog (hash 'a 252 'b 105)))
(println (list (hash-ref st2 'a) (hash-ref st2 'b)))   ;; (21 21)
;; sum of squares, reading the bound from input
(define sum-prog
  '(seq (:= s 0)
        (seq (:= i 1)
             (while (<= i n)
                    (seq (:= s (+ s (* i i)))
                         (:= i (+ i 1)))))))
(hash-ref (ceval sum-prog (hash 'n (+ 5 (remainder (read) 7)))) 's)
