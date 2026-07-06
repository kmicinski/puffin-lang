;; a peephole optimizer over stack-machine code: rewrite windows
;; until fixpoint (push 0 / add elim, push-push-swap, double neg,
;; mul-by-1, strength reduction mul-by-2 -> dup add)
(define (peep instrs)
  (match instrs
    ['() '()]
    [`((push 0) (add) . ,rest) (peep rest)]
    [`((push 1) (mul) . ,rest) (peep rest)]
    [`((neg) (neg) . ,rest) (peep rest)]
    [`((push ,a) (push ,b) (swap) . ,rest) (peep `((push ,b) (push ,a) ,@rest))]
    [`((push 2) (mul) . ,rest) (peep `((dup) (add) ,@rest))]
    [`((push ,(? fixnum? a)) (push ,(? fixnum? b)) (add) . ,rest)
     (peep `((push ,(+ a b)) ,@rest))]
    [(cons i rest) (cons i (peep rest))]))
(define (fixpoint f x)
  (let ([y (f x)]) (if (equal? x y) x (fixpoint f y))))
(define prog
  '((push 4) (push 0) (add) (push 3) (push 5) (swap) (add)
    (push 2) (mul) (neg) (neg) (push 1) (mul) (push 10) (push 20) (add)))
(println (fixpoint peep prog))
;; the rewrites preserve meaning: run both through a tiny vm
(define (vm is st)
  (match is
    ['() st]
    [`((push ,n) . ,r) (vm r (cons n st))]
    [`((add) . ,r) (vm r (cons (+ (car (cdr st)) (car st)) (cdr (cdr st))))]
    [`((mul) . ,r) (vm r (cons (* (car (cdr st)) (car st)) (cdr (cdr st))))]
    [`((neg) . ,r) (vm r (cons (- (car st)) (cdr st)))]
    [`((swap) . ,r) (vm r (cons (car (cdr st)) (cons (car st) (cdr (cdr st)))))]
    [`((dup) . ,r) (vm r (cons (car st) st))]))
(println (vm prog '()))
(println (vm (fixpoint peep prog) '()))
(equal? (vm prog '()) (vm (fixpoint peep prog) '()))
