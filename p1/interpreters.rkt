#lang racket

;; Interpreters for each IR in irs.rkt – rewritten to use `cons` (pairs/lists)
;; instead of multiple values.

(require racket/match
         (only-in racket/hash make-hasheq hash-ref!))
(require "irs.rkt")

(provide (all-defined-out))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Helpers
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Consume one integer from the #:input list, returning a pair
;;   (cons read-value remaining-input)
(define (next-input in)
  (unless (pair? in)
    (error 'interpret "input exhausted for (read) / _read_int64"))
  (cons (car in) (cdr in)))

;;
;; 1 & 2 – raw / unique R1
;; 

(define (eval-R1-exp e env in)
  (match e
    [(? fixnum? n)                            (cons n in)]
    ['(read)                                  (next-input in)]
    [`(- ,e0)                                 (match (eval-R1-exp e0 env in)
                                                   [(cons v in*) (cons (- v) in*)])]
    [`(+ ,e0 ,e1)                             (match (eval-R1-exp e0 env in)
                                                   [(cons v0 in1)
                                                    (match (eval-R1-exp e1 env in1)
                                                      [(cons v1 in2) (cons (+ v0 v1) in2)])])]
    [(? symbol? x)                            (cons (hash-ref env x (λ () (error 'interpret "unbound id ~a" x)))
                                                     in)]
    [`(let ([,(? symbol? x) ,rhs]) ,body)     (match (eval-R1-exp rhs env in)
                                                   [(cons v in*) (eval-R1-exp body (hash-set env x v) in*)])]
    [_                                        (error 'interpret "malformed R1 expression: ~a" e)]))

(define (interpret-R1 p #:input [in '()])
  (define exp (match p
                [`(program ,e)      e]
                [`(program () ,e)   e]))
  (define res (eval-R1-exp exp (make-hash) in))
  (car res))

;;
;; 3 – ANF
;;

;; Atoms share semantics with R1 atoms
(define (atom-val a env)
  (cond [(fixnum? a) a]
        [(symbol? a) (hash-ref env a (λ () (error 'interpret "unbound id ~a" a)))]
        [else (error 'interpret "bad atom ~a" a)]))

(define (eval-anf-rhs rhs env in)
  (match rhs
    ['(read)                            (next-input in)]
    [`(- ,a)                            (cons (- (atom-val a env)) in)]
    [`(+ ,a0 ,a1)                       (cons (+ (atom-val a0 env) (atom-val a1 env)) in)]
    [(? atom?)                          (cons (atom-val rhs env) in)]
    [_                                  (error 'interpret "bad ANF rhs ~a" rhs)]))

(define (eval-anf-exp e env in)
  (match e
    [(? atom?)                           (cons (atom-val e env) in)]
    [`(let ([,(? symbol? x) ,rhs]) ,body) (match (eval-anf-rhs rhs env in)
                                            [(cons v in*) (eval-anf-exp body (hash-set env x v) in*)])]
    [_                                   (error 'interpret "bad ANF exp ~a" e)]))

(define (interpret-anf p #:input [in '()])
  (match-define `(program () ,body) p)
  (define res (eval-anf-exp body (make-hash) in))
  (car res))

;;
;; 4 & 5 – C0  (explicated control) + locals‑uncovered
;;

(define (rhs-val rhs env in)
  (match rhs
    [(? fixnum? n)                        (cons n in)]
    [(? symbol? x)                        (cons (hash-ref env x (λ () (error 'interpret "unbound id ~a" x))) in)]
    ['(read)                              (next-input in)]
    [`(- ,a)                              (cons (- (atom-val a env)) in)]
    [`(+ ,a0 ,a1)                         (cons (+ (atom-val a0 env) (atom-val a1 env)) in)]
    [_                                    (error 'interpret "bad C0 rhs ~a" rhs)]))

(define (exec-seq s env in)
  (match s
    [`(return ,a)                         (cons (atom-val a env) in)]
    [`(seq (assign ,(? symbol? x) ,rhs) ,rest)
                                         (match (rhs-val rhs env in)
                                           [(cons v in*) (exec-seq rest (hash-set env x v) in*)])]
    [_                                    (error 'interpret "bad C0 seq ~a" s)]))

(define (interpret-c0 p #:input [in '()])
  (match-define `(program ,_ ,blocks) p)
  (car (exec-seq (hash-ref blocks '_main) (make-hash) in)))

;;
;; 6–9 -- (Pseudo-)x86-64
;;

;; Registers and memory are modelled using mutable hash tables.
;;   * reg : symbol  → integer
;;   * mem : integer → integer  (address‑indexed, arbitrary units)

(define (x86-state? state)
  (match state
    [`(,insrs ,regs ,mem ,input)
     (and 
      (list? instrs) (andmap instr/vars? instrs)
      (hash? regs) (andmap symbol? (hash-keys regs)) (andmap integer? (hash-keys regs))
      (hash? mem) (andmap integer? (hash-keys mem)) (andmap integer? (hash-keys mem))
      (list? input) (andmap integer? input))]))

;; ---------- operand helpers ----------

(define (operand-value op reg mem)
  (match op
    [`(imm ,n)                n]
    [`(reg ,r)                (hash-ref reg r 0)]
    [`(deref (reg ,r) ,off)   (hash-ref mem (+ (hash-ref reg r 0) off) 0)]
    [`(var ,x)                (hash-ref reg x 0)]))  ; during select‑instructions stage

(define (store-operand dst v reg mem)
  (match dst
    [`(reg ,r)                (hash-set reg r v)]
    [`(deref (reg ,r) ,off)   (hash-set mem (+ (hash-ref reg r 0) off) v)]
    [`(var ,x)                (hash-set reg x v)]
    [_                        (error 'interpret "operand not assignable: ~a" dst)]))



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Master dispatcher
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (interpret p #:input [in '()])
  (cond [(R1? p)                                (interpret-R1 p #:input in)]
        [(unique-source-tree? p)                (interpret-R1 p #:input in)]
        [(anf-program? p)                       (interpret-anf p #:input in)]
        [(c0-program? p)                        (interpret-c0 p #:input in)]
        [(locals-program? p)                    (interpret-c0 p #:input in)]
        [(instr-program? p)                     (interpret-instr p #:input in)]
        [(homes-assigned-program? p)            (interpret-instr p #:input in)]
        [(patched-program? p)                   (interpret-instr p #:input in)]
        [(x86-64? p)                            (interpret-instr p #:input in)]
        [else (error 'interpret "unknown IR kind")]))
