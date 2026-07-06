;; recursive-descent parsing with precedence over a token list:
;;   expr := term (('+'|'-') term)*  ; term := factor (('*') factor)*
;;   factor := num | '(' expr ')' | '-' factor
;; returns (ast . rest-tokens); then evaluate the AST
(define (parse-expr ts)
  (let loop ([r (parse-term ts)])
    (match r
      [(cons lhs (cons '+ rest))
       (match (parse-term rest)
         [(cons rhs rest2) (loop (cons `(add ,lhs ,rhs) rest2))])]
      [(cons lhs (cons '- rest))
       (match (parse-term rest)
         [(cons rhs rest2) (loop (cons `(sub ,lhs ,rhs) rest2))])]
      [_ r])))
(define (parse-term ts)
  (let loop ([r (parse-factor ts)])
    (match r
      [(cons lhs (cons '* rest))
       (match (parse-factor rest)
         [(cons rhs rest2) (loop (cons `(mul ,lhs ,rhs) rest2))])]
      [_ r])))
(define (parse-factor ts)
  (match ts
    [(cons (? fixnum? n) rest) (cons n rest)]
    [(cons 'lp rest)
     (match (parse-expr rest)
       [(cons e (cons 'rp rest2)) (cons e rest2)])]
    [(cons '- rest)
     (match (parse-factor rest)
       [(cons e rest2) (cons `(neg ,e) rest2)])]))
(define (evaluate a)
  (match a
    [(? fixnum? n) n]
    [`(add ,x ,y) (+ (evaluate x) (evaluate y))]
    [`(sub ,x ,y) (- (evaluate x) (evaluate y))]
    [`(mul ,x ,y) (* (evaluate x) (evaluate y))]
    [`(neg ,x) (- (evaluate x))]))
(define (parse-eval ts)
  (match (parse-expr ts)
    [(cons ast '()) (list ast '=> (evaluate ast))]
    [(cons _ leftover) (list 'parse-error-leftover leftover)]))
(println (parse-eval '(1 + 2 * 3)))                      ;; 7: precedence
(println (parse-eval '(lp 1 + 2 rp * 3)))                ;; 9: parens
(println (parse-eval '(2 * 3 * 4 - 5)))                  ;; 19: assoc
(println (parse-eval '(- 4 * lp 2 + 3 rp)))              ;; -20: unary
(println (parse-eval '(1 + 2 rp)))                       ;; leftover
(parse-eval '(10 - 2 - 3))                               ;; 5: left assoc
