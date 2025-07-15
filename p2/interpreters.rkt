#lang racket

;; Interpreters for each IR in irs.rkt – rewritten to use `cons` (pairs/lists)
;; instead of multiple values.
(require "irs.rkt")
(require "system.rkt")

(provide (all-defined-out))

;; Consume one integer from the #:input list, returning a pair
;;   (cons read-value remaining-input)
(define (next-input in)
  (unless (pair? in)
    (error 'interpret "input exhausted for (read) / _read_int64"))
  (cons (car in) (cdr in)))

(define (display-return v) (displayln v) v)

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

(define (interpret-R1 p [in '()])
  (define exp (match p
                [`(program ,e)      e]
                [`(program () ,e)   e]))
  (define res (eval-R1-exp exp (hash) in))
  (display-return (car res)))

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

(define (interpret-anf p [in '()])
  (match-define `(program () ,body) p)
  (define res (eval-anf-exp body (hash) in))
  (display-return (car res)))

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

(define (exec-tail s env in)
  (match s
    [`(return ,a)                         (cons (atom-val a env) in)]
    [`(seq (assign ,(? symbol? x) ,rhs) ,rest)
                                         (match (rhs-val rhs env in)
                                           [(cons v in*) (exec-tail rest (hash-set env x v) in*)])]
    [_                                    (error 'interpret "bad C0 seq ~a" s)]))

(define (interpret-c0 p [in '()])
  (match-define `(program ,_ ,blocks) p)
  (display-return (car (exec-tail (hash-ref blocks '_main) (hash) in))))

;;
;; Passes 6–9 -- (Pseudo-)x86-64, this interpreter works on each
;;

;; Interpreter state is `(,regs ,vars ,mem ,stack)
(define (read-op op st)
  (match-define `(,regs ,vars ,mem ,stack) st)
  (match op
    [`(imm ,n)                    n]
    [`(reg ,r)                    (hash-ref regs r 0)]
    [`(var ,x)                    (hash-ref vars x)]
    [`(deref (reg ,r) ,off)
     (if (eq? r 'rbp)
         (hash-ref mem off)
         (error 'interp-instrs "bad deref ~a" op))]))

(define (write-op op v st)
  (match-define `(,regs ,vars ,mem ,stack) st)
  (match op
    [`(reg ,r)                    `(,(hash-set regs r v) ,vars ,mem ,stack)]
    [`(var ,x)                    `(,regs ,(hash-set vars x v) ,mem ,stack)]
    [`(deref (reg ,r) ,off)
     (if (eq? r 'rbp)
         `(,regs ,vars ,(hash-set mem off v) ,stack)
         (error 'interp-instrs "bad deref ~a" op))]
    [_ (error 'interp-instrs "cannot write to ~a" op)]))

;; Tail-recursive step function, which walks through each of the
;; instructions, maintaining a state. Here, I also track an explicit
;; state; I make in (the input list) another parameter for consistency


;; This is a hack: I use out? to detect if we have printed to the
;; screen yet--this lets us handle both IRs (if we haven't printed yet
;; at the end, we print %rax).
(define out? #f)

;; This tail-recursive function walks through a list of instructions,
;; starting in an input state and with some input state
(define (interp-tail instrs st in)
  (match instrs
    ['() (read-op '(reg rax) st)] ;; supports earlier IRs which don't retq
    [`((retq) . ,_) (read-op '(reg rax) st)]
    [`((movq ,src ,dst) . ,rst) 
     (interp-tail rst (write-op dst (read-op src st) st) in)]
    [`((addq ,src ,dst) . ,rst)
     (define sum (+ (read-op dst st) (read-op src st)))
     (interp-tail rst (write-op dst sum st) in)]
    [`((negq ,op) . ,rst)
     (interp-tail rst (write-op op (- (read-op op st)) st) in)]
    [`((pushq ,src) . ,rst)
     (match-define `(,regs ,vars ,mem ,stack) st)
     (interp-tail rst `(,regs ,vars ,mem ,(cons (read-op src st) stack)) in)]
    [`((popq ,dst) . ,rst)
     (match-define `(,regs ,vars ,mem ,stack) st)
     (match stack
       ['() (error 'interp-instrs "pop from empty stack")]
       [`(,top . ,rest)
        (define st* (write-op dst top st))
        (match-define `(,regs* ,vars* ,mem* ,_) st*)
        (interp-tail rst `(,regs* ,vars* ,mem* ,rest) in)])]
    [`((callq ,lbl ,_) . ,rst)
     (match (linuxify lbl) 
       ['read_int64
        (define v (car in))
        (interp-tail rst (write-op '(reg rax) v st) (cdr in)) ]
       ['print_int64
        (displayln (read-op '(reg rax) st)) ;; print to the screen
        (set! out? #t)
        (interp-tail rst st in)]
       [_ (error 'interp-instrs "unknown call ~a" lbl)])]
    [_ (error 'interp-instrs "unknown instruction")]))

(define (interpret-instr prog [in '()])
  (set! out? #f)
  (match prog
    [`(program ,_ ,blocks)
     (define instrs (hash-ref blocks (entry-symbol)))
     (define init-state `(,(hash) ,(hash) ,(hash) ()))
     (define result (interp-tail instrs init-state in))
     (if out? result (begin (displayln result) result))]))

(define (dummy-interp-x86-64 s i) 
  "x86-64 code not interpreted, skipping interpreter for this pass--test by running binary")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Master dispatcher
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (interpret p [in '()])
  (cond [(R1? p)                                (interpret-R1 p in)]
        [(unique-source-tree? p)                (interpret-R1 p in)]
        [(anf-program? p)                       (interpret-anf p in)]
        [(c0-program? p)                        (interpret-c0 p in)]
        [(locals-program? p)                    (interpret-c0 p in)]
        [(instr-program? p)                     (interpret-instr p in)]
        [(homes-assigned-program? p)            (interpret-instr p in)]
        [(x86-64? p)                            (interpret-instr p in)]
        [else (error 'interpret "unknown IR kind")]))
