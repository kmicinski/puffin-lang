;; small-step structural operational semantics for arithmetic +
;; booleans, printing every intermediate term (a stepper)
(define (value? e) (or (fixnum? e) (boolean? e)))
(define (step e)
  (match e
    [`(+ ,(? fixnum? a) ,(? fixnum? b)) (+ a b)]
    [`(+ ,(? value? a) ,b) `(+ ,a ,(step b))]
    [`(+ ,a ,b) `(+ ,(step a) ,b)]
    [`(* ,(? fixnum? a) ,(? fixnum? b)) (* a b)]
    [`(* ,(? value? a) ,b) `(* ,a ,(step b))]
    [`(* ,a ,b) `(* ,(step a) ,b)]
    [`(< ,(? fixnum? a) ,(? fixnum? b)) (< a b)]
    [`(< ,(? value? a) ,b) `(< ,a ,(step b))]
    [`(< ,a ,b) `(< ,(step a) ,b)]
    [`(if #t ,t ,_) t]
    [`(if #f ,_ ,f) f]
    [`(if ,g ,t ,f) `(if ,(step g) ,t ,f)]))
(define (trace e)
  (println e)
  (if (value? e) e (trace (step e))))
(trace '(if (< (+ 1 2) (* 2 3)) (+ 10 (* 4 8)) 0))
