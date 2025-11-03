#lang racket

;; Interpreters for each IR in irs.rkt – updated for the new R4 pipeline.
(require "irs.rkt")
(require "system.rkt")

(provide (all-defined-out))

;; In this case we provide three interpreters:
;; - R4 -- works for shrink, uniqueify, assignment-convert, and anf-convert
;; - c2 -- works for explicate-control, uncover-locals
;; - instr -- works for select-instructions, assign-homes, patch-instructions, prelude-and-conclusion

;; ────────────────────────────────────────────────────────────────────────────
;; Helpers
;; ────────────────────────────────────────────────────────────────────────────

(define (display-return v) (displayln v) v)

(define (next-input in)
  (unless (pair? in)
    (error 'interpret "input exhausted for (read) / _read_int64"))
  (cons (car in) (cdr in)))

(define (atom-val a env)
  (cond [(fixnum? a) a]
        [(symbol? a) (hash-ref env a (λ () (error 'interpret "unbound id ~a" a)))]
        [(boolean? a) a]
        [(equal? a '(void)) (void)]
        [else (error 'interpret "bad atom ~a" a)]))

(define (expect-int v who)
  (if (fixnum? v) v (error who "expected Int, got ~a" v)))

(define (expect-bool v who)
  (if (boolean? v) v (error who "expected Bool, got ~a" v)))

(define (apply-binary op v0 v1 who)
  (match op
    ['+   (+ (expect-int v0 who) (expect-int v1 who))]
    ['-   (- (expect-int v0 who) (expect-int v1 who))]
    ['eq? (equal? v0 v1)] ;; permit non-ints to be eq?d 
    ['<   (< (expect-int v0 who) (expect-int v1 who))]
    ['<=  (<= (expect-int v0 who) (expect-int v1 who))]
    ['>   (> (expect-int v0 who) (expect-int v1 who))]
    ['>=  (>= (expect-int v0 who) (expect-int v1 who))]
    [_ (error who "unsupported binary op ~a" op)]))

;; ────────────────────────────────────────────────────────────────────────────
;; R4 / shrunk-R4 / unique-source-tree / ANF (source-level interpreter)
;;   - Supports while, begin, set!, make-vector, vector-ref, vector-set!
;; ────────────────────────────────────────────────────────────────────────────

(define r3-binary-ops '(+ - and or eq? < <= > >=))

(define (eval-R4-binary op e0 e1 env in)
  (cond
    [(equal? op 'and)
     (match (eval-R4-exp e0 env in)
       [(cons v0 in1)
        (expect-bool v0 'and)
        (if v0 (eval-R4-exp e1 env in1) (cons #f in1))])]
    [(equal? op 'or)
     (match (eval-R4-exp e0 env in)
       [(cons v0 in1)
        (expect-bool v0 'or)
        (if v0 (cons #t in1) (eval-R4-exp e1 env in1))])]
    [else
     (match (eval-R4-exp e0 env in)
       [(cons v0 in1)
        (match (eval-R4-exp e1 env in1)
          [(cons v1 in2) (cons (apply-binary op v0 v1 'R4) in2)])])]))

(define (eval-R4-begin es env in)
  (match es
    ['() (cons 0 in)]
    [`(,e) (eval-R4-exp e env in)]
    [`(,e . ,rest)
     (match (eval-R4-exp e env in)
       [(cons _ in1) (eval-R4-begin rest env in1)])]))

(define (eval-R4-while g b env in)
  (let loop ([env env] [in in])
    (match (eval-R4-exp g env in)
      [(cons vg in1)
       (if (expect-bool vg 'while)
           (match (eval-R4-exp b env in1)
             [(cons _ in2) (loop env in2)])
           (cons 0 in1))])))

(define (eval-R4-exp e env in)
  (match e
    [#t                              (cons #t in)]
    [#f                              (cons #f in)]
    [(? fixnum? n)                   (cons n in)]
    ['(read)                         (next-input in)]
    ['(void)                         (cons (void) in)]
    ;; unary
    [`(- ,e0)
     (match (eval-R4-exp e0 env in)
       [(cons v in*) (cons (- (expect-int v 'unary-)) in*)])]
    [`(not ,e0)
     (match (eval-R4-exp e0 env in)
       [(cons v in*) (cons (not (expect-bool v 'not)) in*)])]
    ;; binary
    [`(,op ,e0 ,e1) #:when (member op r3-binary-ops)
                    (eval-R4-binary op e0 e1 env in)]
    ;; control
    [`(if ,e-g ,e-t ,e-f)
     (match (eval-R4-exp e-g env in)
       [(cons vg in1)
        (if (expect-bool vg 'if)
            (eval-R4-exp e-t env in1)
            (eval-R4-exp e-f env in1))])]
    ;; sequencing and loops
    [`(begin ,es ... ,ret)          (eval-R4-begin (append es (list ret)) env in)]
    [`(while ,g ,b)                 (eval-R4-while g b env in)]
    ;; vectors
    [`(make-vector ,e-len)
     (match (eval-R4-exp e-len env in)
       [(cons len in1) (cons (make-vector len) in1)])]
    [`(vector-ref ,e-v ,e-i)
     (match (eval-R4-exp e-v env in)
       [(cons vv in1)
        (match (eval-R4-exp e-i env in1)
          [(cons vi in2) (cons (vector-ref vv vi) in2)])])]
    [`(vector-set! ,e-v ,e-i ,e-val)
     (match (eval-R4-exp e-v env in)
       [(cons vv in1)
        (match (eval-R4-exp e-i env in1)
          [(cons vi in2)
           (match (eval-R4-exp e-val env in2)
             [(cons v3 in3) (vector-set! vv vi v3) (cons 0 in3)])])])]
    ;; variables / let / set!
    [(? symbol? x)
     (cons (vector-ref (hash-ref env x (λ () (error 'interpret "unbound id ~a" x))) 0)  in)]
    [`(let ([,(? symbol? x) ,rhs]) ,body)
     (define cell (make-vector 1))
     (match (eval-R4-exp rhs env in)
       [(cons v in*)
        (vector-set! cell 0 v)
        (eval-R4-exp body (hash-set env x cell) in*)])]
    [`(set! ,(? symbol? x) ,rhs)
     (match (eval-R4-exp rhs env in)
       [(cons v in*)
        (vector-set! (hash-ref env x) 0 v)
        '(void)])]
    [_ (error 'interpret "malformed R4 expression: ~a" e)]))

(define (interpret-R4 p [in '()])
  (define e (match p
              [`(program ,e)      e]
              [`(program () ,e)   e]
              [_ (error 'interpret-R4 "bad program ~a" p)]))
  (define res (eval-R4-exp e (hash) in))
  (display-return (car res)))

;; ────────────────────────────────────────────────────────────────────────────
;; C2 (explicate-control and uncover-locals):
;;   - RHS supports: read, -, +, not, eq?, <, (vector aLen), (vector-ref a i)
;;   - Statement form in tails: (vector-set! a i v)
;;   - IF form: (if (<|eq? a0 a1) (goto lt) (goto lf))
;; ────────────────────────────────────────────────────────────────────────────

(define (rhs-val rhs env in)
  (match rhs
    [(? fixnum? n)                        (cons n in)]
    [(? boolean? b)                       (cons b in)]
    [(? symbol? x)                        (cons (hash-ref env x (λ () (error 'interpret "unbound id ~a" x))) in)]
    ['(void)                              (cons (void) in)]
    ['(read)                              (next-input in)]
    [`(- ,a)
     (cons (- (expect-int (atom-val a env) 'C2-unary-)) in)]
    [`(not ,a)                            (cons (not (atom-val a env)) in)]
    [`(+ ,a0 ,a1)
     (cons (+ (expect-int (atom-val a0 env) 'C2/+)
              (expect-int (atom-val a1 env) 'C2/+)) in)]
    [`(eq? ,a0 ,a1)
     (cons (equal? (atom-val a0 env) (atom-val a1 env)) in)]
    [`(< ,a0 ,a1)
     (cons (< (expect-int (atom-val a0 env) 'C2/<)
              (expect-int (atom-val a1 env) 'C2/<)) in)]
    [`(make-vector ,i)
     (cons (make-vector (expect-int (atom-val i env) 'C2/vector)) in)]
    [`(vector-ref ,a0 ,i)
     (cons (vector-ref (atom-val a0 env)
                       (expect-int (atom-val i env) 'C2/vector-ref)) in)]
    [_                                    (error 'interpret "bad C2 rhs ~a" rhs)]))

(define (exec-c2 blocks label env in)
  (define (go s env in)
    (match s
      [`(return ,a)                         (cons (atom-val a env) in)]
      [`(seq (assign ,(? symbol? x) ,rhs) ,rest)
       (match (rhs-val rhs env in)
         [(cons v in*) (go rest (hash-set env x v) in*)])]
      ;; side-effect statement
      [`(seq (vector-set! ,av ,i ,aval) ,rest)
       (vector-set! (atom-val av env) 
              (expect-int (atom-val i env) 'C2/vector-set!)
              (atom-val aval env))
       (go rest env in)]
      ;; generic IF on eq?/</etc.
      [`(if (,cmp ,a0 ,a1) (goto ,(? label? l-t)) (goto ,(? label? l-f)))
       (define v0 (atom-val a0 env))
       (define v1 (atom-val a1 env))
       (define truth
         (match cmp
           ['eq? (equal? v0 v1)]
           ['<   (< (expect-int v0 'C2/<) (expect-int v1 'C2/<))]
           [else (error 'interpret "unsupported cmp ~a in C2 if" cmp)]))
       (go (hash-ref blocks (if truth l-t l-f)) env in)]
      [`(goto ,(? label? l))               (go (hash-ref blocks l) env in)]
      [_                                   (error 'interpret "bad C2 tail ~a" s)]))
  (go (hash-ref blocks label) env in))

(define (interpret-c2 p [in '()])
  (match-define `(program ,_ ,blocks) p)
  (display-return (car (exec-c2 blocks (entry-symbol) (hash) in))))

;; ────────────────────────────────────────────────────────────────────────────
;; (Pseudo-)x86-64 Interpreter
;; ────────────────────────────────────────────────────────────────────────────

;; State is:
;; `(,regs ,vars ,mem ,stack ,flags)
;; 
;; Pointers are represented as `(pointer-to addr)`
;; Addresses are either '(stack-addr i) or '(heap-addr i)
;; Primitive operations are updated to work on pointers

(define (read-op op st)
  (match-define `(,regs ,vars ,mem ,stack ,flags) st)
  (match op
    [`(imm ,n)                    n]
    [`(reg ,r)                    (hash-ref regs r 0)]
    [`(byte-reg ,r)               (hash-ref regs r 0)]
    [`(var ,x)                    (hash-ref vars x (λ () (error 'interp-instrs "unbound var ~a" x)))]
    [`(deref (reg rbp) ,off)      (hash-ref mem off 0)]
    [`(deref (reg ,r) ,off)
     (match (read-op `(reg ,r) st)
       [(? vector? v) (vector-ref v (/ (- off 8) 8))])]))

(define (write-op op v st)
  (match-define `(,regs ,vars ,mem ,stack ,flags) st)
  (match op
    [`(reg ,r)                    `(,(hash-set regs r v) ,vars ,mem ,stack ,flags)]
    [`(byte-reg ,r)               `(,(hash-set regs r (bitwise-and v #xFF)) ,vars ,mem ,stack ,flags)]
    [`(var ,x)                    `(,regs ,(hash-set vars x v) ,mem ,stack ,flags)]
    [`(deref (reg rbp) ,off)      `(,regs ,vars ,(hash-set mem off v) ,stack ,flags)]
    [`(deref (reg ,r) ,off)
     (define vec (read-op `(reg ,r) st))
     (define idx (/ (- off 8) 8))
     (match vec
       [(? vector?) (vector-set! vec idx v)])
     `(,regs ,vars ,mem ,stack ,flags)]
    [_ (error 'interp-instrs "cannot write to ~a" op)]))

(define (cmp-flags srcv dstv)
  (define res (- dstv srcv))
  (define sign (λ (x) (if (< x 0) 1 0)))
  (define of? (and (not (= (sign dstv) (sign srcv)))
                   (not (= (sign dstv) (sign res)))))
  (hash 'ZF (= res 0) 'SF (< res 0) 'OF of?))

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

(define out? #f)

(define (interp-tail instrs blocks st in)
  (match instrs
    ['() (read-op '(reg rax) st)]
    [`((retq) . ,_) (read-op '(reg rax) st)]
    [`((goto ,l) . ,_)
     (interp-tail (hash-ref blocks l) blocks st in)]
    [`((movq ,src ,dst) . ,rst) 
     (interp-tail rst blocks (write-op dst (read-op src st) st) in)]
    [`((movzbq ,src ,dst) . ,rst)
     (interp-tail rst blocks (write-op dst (bitwise-and (read-op src st) #xFF) st) in)]
    [`((addq ,src ,dst) . ,rst)
     (define src-v (read-op src st))
     (define dst-v (read-op dst st))
     (define sum (match dst-v
                   [(? fixnum? n) (+ dst-v src-v)]
                   [`(stack-addr ,v) `(stack-addr ,(+ v src-v))]))
     (interp-tail rst blocks (write-op dst sum st) in)]
    [`((xorq ,src ,dst) . ,rst)
     (define res (bitwise-xor (read-op dst st) (read-op src st)))
     (match-define `(,regs ,vars ,mem ,stack ,_) (write-op dst res st))
     (define flags* (hash 'ZF (= res 0) 'SF (< res 0) 'OF #f))
     (interp-tail rst blocks `(,regs ,vars ,mem ,stack ,flags*) in)]
    [`((negq ,op) . ,rst)
     (interp-tail rst blocks (write-op op (- (read-op op st)) st) in)]
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
    [`((cmpq ,a0 ,a1) . ,rst)
     (match-define `(,regs ,vars ,mem ,stack ,flags) st)
     (define flags* (cmp-flags (read-op a0 st) (read-op a1 st)))
     (interp-tail rst blocks `(,regs ,vars ,mem ,stack ,flags*) in)]
    [`((set ,cc ,dst) . ,rst)
     (define b (if (cc-true? cc (last st)) 1 0))
     (interp-tail rst blocks (write-op dst b st) in)]
    [`((jmp ,lab) . ,_)
     (interp-tail (hash-ref blocks lab) blocks st in)]
    [`((jmp-if ,cc ,lab) . ,rst)
     (if (cc-true? cc (last st))
         (interp-tail (hash-ref blocks lab) blocks st in)
         (interp-tail rst blocks st in))]
    [`((callq ,lbl ,_) . ,rst)
     (match (linuxify lbl) 
       ['read_int64
        (define v (car in))
        (interp-tail rst blocks (write-op '(reg rax) v st) (cdr in)) ]
       ['print_int64
        (displayln (read-op '(reg rax) st))
        (set! out? #t)
        (interp-tail rst blocks st in)]
       ['make_vector
        (define i (read-op '(reg rdi) st))
        (define vec (make-vector i))
        (interp-tail rst blocks (write-op '(reg rax) vec st) in)]
       [_ (error 'interp-instrs "unknown call ~a" lbl)])]
    [_ (error 'interp-instrs "unknown instruction sequence ~a" instrs)]))

(define (interpret-instr prog [in '()])
  (set! out? #f)
  (match prog
    [`(program ,_ ,blocks)
     (define instrs (hash-ref blocks (entry-symbol)))
     (define init-regs (hash 'rsp '(stack-addr #xAA000000)
                             'rbp '(stack-addr #xAA000000)))
     (define init-state `(,init-regs ,(hash) ,(hash) () ,(hash 'ZF #f 'SF #f 'OF #f)))
     (define result (interp-tail instrs blocks init-state in))
     (if out? result (begin (displayln result) result))]))

(define (dummy-interp-x86-64 s i) 
  "x86-64 code not interpreted, skipping interpreter for this pass--test by running binary")

;; ────────────────────────────────────────────────────────────────────────────
;; Dispatcher
;; ────────────────────────────────────────────────────────────────────────────

(define (interpret p [in (range 100)])
  (cond [(R4? p)                                 (interpret-R4 p in)]
        [(shrunk-R4? p)                          (interpret-R4 p in)]
        [(unique-source-tree? p)                 (interpret-R4 p in)]
        [(anf-program? p)                        (interpret-R4 p in)]
        [(c2-program? p)                         (interpret-c2 p in)]
        [(locals-program? p)                     (interpret-c2 p in)]
        [(instr-program? p)                      (interpret-instr p in)]
        [(homes-assigned-program? p)             (interpret-instr p in)]
        [(patched-program? p)                    (interpret-instr p in)]
        [(x86-64? p)                             (interpret-instr p in)]
        [else (error 'interpret "unknown IR kind")]))
