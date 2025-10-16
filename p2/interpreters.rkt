#lang racket

;; Interpreters for each IR in irs.rkt – updated for the new IRs.
(require "irs.rkt")
(require "system.rkt")

(provide (all-defined-out))
(define (display-return v) (displayln v) v)

(define (next-input in)
  (unless (pair? in)
    (error 'interpret "input exhausted for (read) / _read_int64"))
  (cons (car in) (cdr in)))

(define (atom-val a env)
  (cond [(fixnum? a) a]
        [(symbol? a) (hash-ref env a (λ () (error 'interpret "unbound id ~a" a)))]
        [(boolean? a) a]
        [else (error 'interpret "bad atom ~a" a)]))

(define (expect-int v who)
  (if (fixnum? v) v (error who "expected Int, got ~a" v)))

(define (expect-bool v who)
  (if (boolean? v) v (error who "expected Bool, got ~a" v)))

;; Apply non-short-circuit binary ops uniformly on *values* (already evaluated)
(define (apply-binary op v0 v1 who)
  (match op
    ['+   (+ (expect-int v0 who) (expect-int v1 who))]
    ['-   (- (expect-int v0 who) (expect-int v1 who))]
    ['eq? (= (expect-int v0 who) (expect-int v1 who))]
    ['<   (< (expect-int v0 who) (expect-int v1 who))]
    ['<=  (<= (expect-int v0 who) (expect-int v1 who))]
    ['>   (> (expect-int v0 who) (expect-int v1 who))]
    ['>=  (>= (expect-int v0 who) (expect-int v1 who))]
    [_ (error who "unsupported binary op ~a" op)]))

(define (bool->int b) (if b 1 0))
(define (int->bool n) (not (zero? n)))

;; ────────────────────────────────────────────────────────────────────────────
;; R2 / Shrunk-R2
;;   - Handles every binary form uniformly via `eval-R2-binary` + `apply-binary`
;;   - AND/OR short-circuit by lazily evaluating the RHS
;; ────────────────────────────────────────────────────────────────────────────

(define r2-binary-ops '(+ - and or eq? < <= > >=))

;; Evaluate a binary expression `(op e0 e1)` with uniform control.
(define (eval-R2-binary op e0 e1 env in)
  (cond
    ;; short-circuit ops
    [(eq? op 'and)
     (match (eval-R2-exp e0 env in)
       [(cons v0 in1)
        (expect-bool v0 'and)
        (if v0
            (match (eval-R2-exp e1 env in1)
              [(cons v1 in2) (expect-bool v1 'and) (cons v1 in2)])
            (cons #f in1))])]
    [(eq? op 'or)
     (match (eval-R2-exp e0 env in)
       [(cons v0 in1)
        (expect-bool v0 'or)
        (if v0
            (cons #t in1)
            (match (eval-R2-exp e1 env in1)
              [(cons v1 in2) (expect-bool v1 'or) (cons v1 in2)]))])]
    ;; numeric/relational ops
    [else
     (match (eval-R2-exp e0 env in)
       [(cons v0 in1)
        (match (eval-R2-exp e1 env in1)
          [(cons v1 in2) (cons (apply-binary op v0 v1 'R2) in2)])])]))

(define (eval-R2-exp e env in)
  (match e
    ;; literals / read
    [#t                                      (cons #t in)]
    [#f                                      (cons #f in)]
    [(? fixnum? n)                           (cons n in)]
    ['(read)                                 (next-input in)]

    ;; unary
    [`(- ,e0)
     (match (eval-R2-exp e0 env in)
       [(cons v in*) (cons (- (expect-int v 'unary-)) in*)])]
    [`(not ,e0)
     (match (eval-R2-exp e0 env in)
       [(cons v in*) (cons (not (expect-bool v 'not)) in*)])]
    ;; uniform binary case
    [`(,op ,e0 ,e1) #:when (member op r2-binary-ops)
     (eval-R2-binary op e0 e1 env in)]
    ;; control
    [`(if ,e-g ,e-t ,e-f)
     (match (eval-R2-exp e-g env in)
       [(cons vg in1)
        (if (expect-bool vg 'if)
            (eval-R2-exp e-t env in1)
            (eval-R2-exp e-f env in1))])]
    ;; vars / let
    [(? symbol? x)
     (cons (hash-ref env x (λ () (error 'interpret "unbound id ~a" x))) in)]
    [`(let ([,(? symbol? x) ,rhs]) ,body)
     (match (eval-R2-exp rhs env in)
       [(cons v in*) (eval-R2-exp body (hash-set env x v) in*)])]
    [_ (error 'interpret "malformed R2 expression: ~a" e)]))

(define (interpret-R2 p [in '()])
  (define e (match p
              [`(program ,e)      e]
              [`(program () ,e)   e]
              [_ (error 'interpret-R2 "bad program ~a" p)]))
  (define res (eval-R2-exp e (hash) in))
  (display-return (car res)))

;; ────────────────────────────────────────────────────────────────────────────
;; ANF
;;   - Binary handled uniformly by `anf-binary`
;;   - ANF rhs only uses +, eq?, < (per your predicate), but the helper is
;;     generic enough for the relational family in case you extend it.
;; ────────────────────────────────────────────────────────────────────────────

(define anf-binary-ops '(+ eq? < <= > >=))

(define (anf-binary op a0 a1 env)
  (apply-binary op (atom-val a0 env) (atom-val a1 env) 'ANF))

(define (eval-anf-rhs rhs env in)
  (match rhs
    ['(read)                  (next-input in)]
    [`(- ,a)                  (cons (- (expect-int (atom-val a env) 'ANF)) in)]
    [`(not ,a)                (cons (not (expect-bool (atom-val a env) 'ANF)) in)]
    [`(,op ,a0 ,a1) #:when (member op anf-binary-ops)
     (cons (anf-binary op a0 a1 env) in)]
    [(? atom?)                (cons (atom-val rhs env) in)]
    [_                        (error 'interpret "bad ANF rhs ~a" rhs)]))

(define (eval-anf-exp e env in)
  (match e
    [(? atom?)                            (cons (atom-val e env) in)]
    [`(let ([,(? symbol? x) ,rhs]) ,body) (match (eval-anf-rhs rhs env in)
                                           [(cons v in*) (eval-anf-exp body (hash-set env x v) in*)])]
    [`(if ,a-g ,e-t ,e-f)                 (if (expect-bool (atom-val a-g env) 'ANF-if)
                                              (eval-anf-exp e-t env in)
                                              (eval-anf-exp e-f env in))]
    [_                                    (error 'interpret "bad ANF exp ~a" e)]))

(define (interpret-anf p [in '()])
  (match-define `(program () ,body) p)
  (define res (eval-anf-exp body (hash) in))
  (display-return (car res)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; 4/5 – C1 (explicate-control) and Locals (same interpreter)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Evaluate a C1 RHS using current env/in
(define (rhs-val rhs env in)
  (match rhs
    [(? fixnum? n)                        (cons n in)]
    [(? boolean? b)                       (cons b in)]
    [(? symbol? x)                        (cons (hash-ref env x (λ () (error 'interpret "unbound id ~a" x))) in)]
    ['(read)                              (next-input in)]
    [`(- ,a)                              (cons (- (atom-val a env)) in)]
    [`(+ ,a0 ,a1)                         (cons (+ (atom-val a0 env) (atom-val a1 env)) in)]
    [`(not ,a)                            (cons (not (expect-bool (atom-val a env) 'C1-not)) in)]
    [`(eq? ,a0 ,a1)                       (cons (equal? (atom-val a0 env) (atom-val a1 env)) in)]
    [`(<   ,a0 ,a1)                       (cons (< (atom-val a0 env) (atom-val a1 env)) in)]
    [_                                    (error 'interpret "bad C1 rhs ~a" rhs)]))

;; Execute a C1 tail starting at a given label. Blocks is a (hash label -> tail).
(define (exec-c1 blocks label env in)
  (define (go s env in)
    (match s
      [`(return ,a)                         (cons (atom-val a env) in)]
      [`(seq (assign ,(? symbol? x) ,rhs) ,rest)
                                           (match (rhs-val rhs env in)
                                             [(cons v in*) (go rest (hash-set env x v) in*)])]
      [`(if (eq? ,(? atom? a0) ,(? atom? a1))
            (goto ,(? label? l-t))
            (goto ,(? label? l-f)))
       (if (equal? (atom-val a0 env) (atom-val a1 env))
           (go (hash-ref blocks l-t) env in)
           (go (hash-ref blocks l-f) env in))]
      [`(if (< ,(? atom? a0) ,(? atom? a1))
            (goto ,(? label? l-t))
            (goto ,(? label? l-f)))
       (if (< (atom-val a0 env) (atom-val a1 env))
           (go (hash-ref blocks l-t) env in)
           (go (hash-ref blocks l-f) env in))]
      [`(goto ,(? label? l))               (go (hash-ref blocks l) env in)]
      [_                                   (error 'interpret "bad C1 tail ~a" s)]))
  (go (hash-ref blocks label) env in))

(define (interpret-c1 p [in '()])
  (match-define `(program ,_ ,blocks) p)
  (display-return (car (exec-c1 blocks (entry-symbol) (hash) in))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; 6–11 — (Pseudo-)x86-64
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Interpreter state is `(,regs ,vars ,mem ,stack ,flags)
;; where flags is a hash containing 'ZF 'SF 'OF.
(define (read-op op st)
  (match-define `(,regs ,vars ,mem ,stack ,flags) st)
  (match op
    [`(imm ,n)                    n]
    [`(reg ,r)                    (hash-ref regs r 0)]
    [`(byte-reg ,r)               (hash-ref regs r 0)]
    [`(var ,x)                    (hash-ref vars x (λ () (error 'interp-instrs "unbound var ~a" x)))]
    [`(deref (reg ,r) ,off)
     (if (eq? r 'rbp)
         (hash-ref mem off 0)
         (error 'interp-instrs "bad deref ~a" op))]))

(define (write-op op v st)
  (match-define `(,regs ,vars ,mem ,stack ,flags) st)
  (match op
    [`(reg ,r)                    `(,(hash-set regs r v) ,vars ,mem ,stack ,flags)]
    [`(byte-reg ,r)               `(,(hash-set regs r (bitwise-and v #xFF)) ,vars ,mem ,stack ,flags)]
    [`(var ,x)                    `(,regs ,(hash-set vars x v) ,mem ,stack ,flags)]
    [`(deref (reg ,r) ,off)
     (if (eq? r 'rbp)
         `(,regs ,vars ,(hash-set mem off v) ,stack ,flags)
         (error 'interp-instrs "bad deref ~a" op))]
    [_ (error 'interp-instrs "cannot write to ~a" op)]))

;; Compute flags for `cmpq src, dst` (AT&T). Sets ZF, SF, OF.
(define (cmp-flags srcv dstv)
  (define res (- dstv srcv))
  (define sign (λ (x) (if (< x 0) 1 0)))
  (define of? (and (not (= (sign dstv) (sign srcv)))
                   (not (= (sign dstv) (sign res)))))
  (hash 'ZF (= res 0) 'SF (< res 0) 'OF of?))

;; Evaluate condition code from flags; only 'e and 'l are used by our pipeline.
(define (cc-true? cc flags)
  (match cc
    ['e  (hash-ref flags 'ZF #f)]
    ['l  (let ([ZF (hash-ref flags 'ZF #f)]
               [SF (hash-ref flags 'SF #f)]
               [OF (hash-ref flags 'OF #f)])
           (and (not ZF) (not (equal? SF OF))))] ; signed less-than
    ['le (let ([ZF (hash-ref flags 'ZF #f)]
               [SF (hash-ref flags 'SF #f)]
               [OF (hash-ref flags 'OF #f)])
           (or ZF (not (equal? SF OF))))]
    ['g  (let ([ZF (hash-ref flags 'ZF #f)]
               [SF (hash-ref flags 'SF #f)]
               [OF (hash-ref flags 'OF #f)])
           (and (not ZF) (equal? SF OF)))]
    ['ge (equal? (hash-ref flags 'SF #f) (hash-ref flags 'OF #f))]
    [_ (error 'interp-instrs "unsupported cc ~a" cc)]))

;; This is a hack: I use out? to detect if we have printed to the
;; screen yet—this lets us handle both IRs (if we haven't printed yet
;; at the end, we print %rax).
(define out? #f)

;; Tail-recursive function that can jump across blocks.
;; - instrs  : current instruction list
;; - blocks  : hash -- label → instruction list
;; - st      : `(,regs ,vars ,mem ,stack ,flags)
;; - in      : remaining (read) input stream
(define (interp-tail instrs blocks st in)
  (match instrs
    ['() (read-op '(reg rax) st)] ;; supports earlier IRs which don't retq
    [`((retq) . ,_) (read-op '(reg rax) st)]
    ;; no-op labels
    [`(((label ,_) . ,rst) ...)
     (interp-tail rst blocks st in)]
    ;; data movement
    [`((movq ,src ,dst) . ,rst) 
     (interp-tail rst blocks (write-op dst (read-op src st) st) in)]
    [`((movzbq ,src ,dst) . ,rst)
     (interp-tail rst blocks (write-op dst (bitwise-and (read-op src st) #xFF) st) in)]
    ;; arithmetic
    [`((addq ,src ,dst) . ,rst)
     (define sum (+ (read-op dst st) (read-op src st)))
     (interp-tail rst blocks (write-op dst sum st) in)]
    [`((xorq ,src ,dst) . ,rst)
     (define res (bitwise-xor (read-op dst st) (read-op src st)))
     (match-define `(,regs ,vars ,mem ,stack ,_) (write-op dst res st))
     ;; Minimal flags: ZF/SF from result; OF cleared (CF/PF unused here)
     (define flags* (hash 'ZF (= res 0) 'SF (< res 0) 'OF #f))
     (interp-tail rst blocks `(,regs ,vars ,mem ,stack ,flags*) in)]
    [`((negq ,op) . ,rst)
     (interp-tail rst blocks (write-op op (- (read-op op st)) st) in)]
    ;; stack ops
    [`((pushq ,src) . ,rst)
     (match-define `(,regs ,vars ,mem ,stack ,flags) st)
     (interp-tail rst blocks `(,regs ,vars ,mem ,(cons (read-op src st) stack) ,flags) in)]
    [`((popq ,dst) . ,rst)
     (match-define `(,regs ,vars ,mem ,stack ,flags) st)
     (match stack
       ['() (error 'interp-instrs "pop from empty stack")]
       [`(,top . ,rest)
        (define st* (write-op dst top st))
        (match-define `(,regs* ,vars* ,mem* ,_ ,flags*) st*)
        (interp-tail rst blocks `(,regs* ,vars* ,mem* ,rest ,flags*) in)])]
    ;; compare / flags
    [`((cmpq ,a0 ,a1) . ,rst)
     (match-define `(,regs ,vars ,mem ,stack ,flags) st)
     (define flags* (cmp-flags (read-op a0 st) (read-op a1 st)))
     (interp-tail rst blocks `(,regs ,vars ,mem ,stack ,flags*) in)]
    ;; setcc
    [`((set ,cc ,dst) . ,rst)
     (define b (if (cc-true? cc (last st)) 1 0))
     (interp-tail rst blocks (write-op dst b st) in)]
    ;; control flow
    [`((jmp ,lab) . ,_)
     (interp-tail (hash-ref blocks lab) blocks st in)]
    [`((jmp-if ,cc ,lab) . ,rst)
     (if (cc-true? cc (last st))
         (interp-tail (hash-ref blocks lab) blocks st in)
         (interp-tail rst blocks st in))]
    ;; runtime calls
    [`((callq ,lbl ,_) . ,rst)
     (match (linuxify lbl) 
       ['read_int64
        (define v (car in))
        (interp-tail rst blocks (write-op '(reg rax) v st) (cdr in)) ]
       ['print_int64
        (displayln (read-op '(reg rax) st))
        (set! out? #t)
        (interp-tail rst blocks st in)]
       [_ (error 'interp-instrs "unknown call ~a" lbl)])]
    [_ (error 'interp-instrs "unknown instruction sequence ~a" instrs)]))

(define (interpret-instr prog [in '()])
  (set! out? #f)
  (match prog
    [`(program ,_ ,blocks)
     (define instrs (hash-ref blocks (entry-symbol)))
     (define init-state `(,(hash) ,(hash) ,(hash) () ,(hash 'ZF #f 'SF #f 'OF #f)))
     (define result (interp-tail instrs blocks init-state in))
     (if out? result (begin (displayln result) result))]))

(define (dummy-interp-x86-64 s i) 
  "x86-64 code not interpreted, skipping interpreter for this pass--test by running binary")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Dispatcher
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (interpret p [in (range 100)])
  (cond [(R2? p)                                (interpret-R2 p in)]
        [(shrunk-R2? p)                         (interpret-R2 p in)]
        [(unique-source-tree? p)                (interpret-R2 p in)]
        [(anf-program? p)                       (interpret-anf p in)]
        [(c1-program? p)                        (interpret-c1 p in)]
        [(locals-program? p)                    (interpret-c1 p in)]
        [(instr-program? p)                     (interpret-instr p in)]
        [(homes-assigned-program? p)            (interpret-instr p in)]
        [(patched-program? p)                   (interpret-instr p in)]
        [(x86-64? p)                            (interpret-instr p in)]
        [else (error 'interpret "unknown IR kind")]))
