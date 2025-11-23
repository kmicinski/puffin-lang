#lang racket
;;
;; CIS531 Fall '25: Project 5 -- Functions and Lambdas
;;
;; Interface (predicates) for every IR used across the pipeline.
;; Keep these aligned with compile.rkt’s expectations.
;;

(require "system.rkt")
(provide (all-defined-out))

;; ---------------------------------------------------------------------
;; Helpers (shared across IRs)
;; ---------------------------------------------------------------------

(define (atom? a)                (or (fixnum? a) (symbol? a) (boolean? a) (equal? a '(void))))
(define (imm? op)                (match op [`(imm ,n)            (fixnum? n)] [_ #f]))
(define (byte-reg? op)           (match op [`(byte-reg ,r)       (symbol? r)] [_ #f]))
(define (reg? op)                (match op [`(reg ,r)            (symbol? r)] [_ #f]))
(define (var? op)                (match op [`(var ,x)            (symbol? x)] [_ #f]))
(define (deref? op)              (match op [`(deref (reg ,r) ,i) (and (symbol? r) (integer? i))] [_ #f]))
(define (label? l)               (symbol? l))

;; Condition codes we actually use after shrink: eq? and < → e and l
(define (cc? op)                 (member op '(e l)))

;; Comparators in the *source* language (shrink reduces this set)
(define (cmp? cmp)               (member cmp '(eq? < <= > >=)))

;; After shrink we keep only eq? and <
(define (shrunk-cmp? c)          (member c '(eq? <)))

;; ---------------------------------------------------------------------
;; 1) Raw R4 (source)
;; ---------------------------------------------------------------------

(define (R4-exp? e)
  (match e
    [#t #t]
    [#f #t]
    [(? fixnum?) #t]
    ['(read) #t]
    ['(void) #t]
    [`(- ,(? R4-exp? e)) #t]
    [`(- ,(? R4-exp? e0) ,(? R4-exp? e1)) #t]
    [`(+ ,(? R4-exp? e0) ,(? R4-exp? e1)) #t]
    [`(and ,(? R4-exp? e0) ,(? R4-exp? e1)) #t]
    [`(or  ,(? R4-exp? e0) ,(? R4-exp? e1)) #t]
    [`(not ,(? R4-exp? e1)) #t]
    [`(,(? cmp? c) ,(? R4-exp? e0) ,(? R4-exp? e1)) #t]
    [`(if ,(? R4-exp? e-g) ,(? R4-exp? e-t) ,(? R4-exp? e-f)) #t]
    [(? symbol?) #t]
    [`(let* ([,(? symbol? xs) ,(? R4-exp? es)] ...) ,(? R4-exp? eb)) #t]
    [`(let ([,(? symbol? x) ,(? R4-exp? e)]) ,(? R4-exp? eb)) #t]
    ;; sequences / loops / vectors / mutation
    [`(begin ,(? R4-exp?) ... ,(? R4-exp? ret)) #t]
    [`(while ,(? R4-exp? e-g) ,(? R4-exp? es) ...) #t]
    [`(make-vector ,(? R4-exp? len)) #t]
    [`(vector-ref ,(? R4-exp? v) ,(? fixnum? i)) #t]
    [`(vector-set! ,(? R4-exp? v) ,(? fixnum? i) ,(? R4-exp? e-v)) #t]
    [`(set! ,(? symbol? x) ,(? R4-exp? e)) #t]
    ;; new forms
    [`(,(? R4-exp? e-f) ,(? R4-exp? a-args) ...) #t]
    [_ #f]))

(define (R4-definition? defn)
  (match defn
    [`(define (,(? symbol? procedure-name) ,(? symbol? formal-args) ...)
        ,(? R4-exp? body))
     #t]
    [_ #f]))

(define (R4? p)
  (match p
    [`(program (? R4-definition? defns) ... ,(? R4-exp?)) #t]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 1) R5: Adds lambdas / application of lambdas
;; ---------------------------------------------------------------------

(define (R5-exp? e)
  (match e
    [#t #t]
    [#f #t]
    [(? fixnum?) #t]
    ['(read) #t]
    ['(void) #t]
    [`(- ,(? R5-exp? e)) #t]
    [`(- ,(? R5-exp? e0) ,(? R5-exp? e1)) #t]
    [`(+ ,(? R5-exp? e0) ,(? R5-exp? e1)) #t]
    [`(and ,(? R5-exp? e0) ,(? R5-exp? e1)) #t]
    [`(or  ,(? R5-exp? e0) ,(? R5-exp? e1)) #t]
    [`(not ,(? R5-exp? e1)) #t]
    [`(,(? cmp? c) ,(? R5-exp? e0) ,(? R5-exp? e1)) #t]
    [`(if ,(? R5-exp? e-g) ,(? R5-exp? e-t) ,(? R5-exp? e-f)) #t]
    [(? symbol?) #t]
    [`(let* ([,(? symbol? xs) ,(? R5-exp? es)] ...) ,(? R5-exp? eb)) #t]
    [`(let ([,(? symbol? x) ,(? R5-exp? e)]) ,(? R5-exp? eb)) #t]
    ;; sequences / loops / vectors / mutation
    [`(begin ,(? R5-exp?) ... ,(? R5-exp? ret)) #t]
    [`(while ,(? R5-exp? e-g) ,(? R5-exp? es) ...) #t]
    [`(make-vector ,(? R5-exp? len)) #t]
    [`(vector-ref ,(? R5-exp? v) ,(? fixnum? i)) #t]
    [`(vector-set! ,(? R5-exp? v) ,(? fixnum? i) ,(? R5-exp? e-v)) #t]
    [`(set! ,(? symbol? x) ,(? R5-exp? e)) #t]
    ;; new forms
    [`(,(? R5-exp? e-f) ,(? R5-exp? a-args) ...) #t]
    [`(lambda (,(? symbol? xs) ...) ,(? R5-exp? e-body)) #t]
    #;[_ #f]
    ))

(define (R5-defn? defn)
  (match defn
    [`(define (,(? symbol? f) ,(? symbol? formals) ...)  ,(? R5-exp? e-b)) #t]
    [_ #f]))

(define (R5? p)
  (match p
    [`(program ,(? R5-defn? defns) ... ,(? R5-exp?)) #t]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 2) Shrunk R5 (after shrink)
;;     - binary minus removed
;;     - and/or/<=/>/>= removed
;;     - keeps: integers, booleans, read, unary -, +, not, if, eq?, <, let, vars
;;     - also keeps while/make-vector/vector-ref/vector-set!/set!/begin (as let chains)
;; ---------------------------------------------------------------------

(define (shrunk-R5-exp? e)
  (match e
    [#t #t]
    [#f #t]
    [(? fixnum?) #t]
    ['(read) #t]
    ['(void) #t]
    [`(- ,(? shrunk-R5-exp? e)) #t]
    [`(+ ,(? shrunk-R5-exp? e0) ,(? shrunk-R5-exp? e1)) #t]
    [`(not ,(? shrunk-R5-exp? e1)) #t]
    [`(,(? shrunk-cmp? c) ,(? shrunk-R5-exp? e0) ,(? shrunk-R5-exp? e1)) #t]
    [`(if ,(? shrunk-R5-exp? e-g) ,(? shrunk-R5-exp? e-t) ,(? shrunk-R5-exp? e-f)) #t]
    [(? symbol?) #t]
    [`(let ([,(? symbol? x) ,(? shrunk-R5-exp? e)]) ,(? shrunk-R5-exp? eb)) #t]
    [`(let ([_ ,(? shrunk-R5-exp?)]) ,(? shrunk-R5-exp?)) #t]
    [`(let ([_ (while ,(? shrunk-R5-exp?) ,(? shrunk-R5-exp?))]) ,(? shrunk-R5-exp?)) #t]
    [`(make-vector ,(? shrunk-R5-exp? len)) #t]
    [`(vector-ref ,(? shrunk-R5-exp? v) ,(? fixnum? i)) #t]
    [`(vector-set! ,(? shrunk-R5-exp? v) ,(? fixnum? i) ,(? shrunk-R5-exp? val)) #t]
    [`(set! ,(? symbol?) ,(? shrunk-R5-exp?)) #t]
    ;; new forms
    [`(,(? shrunk-R5-exp? e-f) ,(? shrunk-R5-exp? a-args) ...) #t]  ;; app 
    [`(lambda (,(? symbol? xs) ...) ,(? shrunk-R5-exp? e-body)) #t] ;; lambda
    [_ #f]))


(define (shrunk-R5-defn? defn)
  (match defn
    [`(define (,(? symbol? f) ,(? symbol? formals) ...)  ,(? shrunk-R5-exp? e-b)) #t]
    [_ #f]))

(define (shrunk-R5? p)
  (match p
    [`(program ,(? shrunk-R5-defn? defns) ... ,(? shrunk-R5-exp?)) #t]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 3) Unique source tree (after uniqueify)
;;     - every bound identifier written exactly once
;; ---------------------------------------------------------------------

(define (unique-source-tree/walk e seen)
  (match e
    [(? fixnum?)                        seen]
    [#t                                 seen]
    [#f                                 seen]
    ['(read)                            seen]
    ['(void)                            seen]
    ;; arithmetic
    [`(- ,e)                            (unique-source-tree/walk e seen)]
    [`(+ ,e0 ,e1)                       (unique-source-tree/walk e1 (unique-source-tree/walk e0 seen))]
    ;; logic/tests
    [`(not ,e)                          (unique-source-tree/walk e seen)]
    [`(,(? shrunk-cmp? _) ,e0 ,e1)      (unique-source-tree/walk e1 (unique-source-tree/walk e0 seen))]
    ;; control
    [`(if ,e-g ,e-t ,e-f)               (unique-source-tree/walk e-f (unique-source-tree/walk e-t (unique-source-tree/walk e-g seen)))]
    ;; variables
    [(? symbol?)                        seen]
    ;; let-binding (check "unique write" property)
    [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
     (unique-source-tree/walk e-r (unique-source-tree/walk e-b (unique-source-tree/walk e-g seen)))]
    [`(let ([_ ,e]) ,e-b)
     (unique-source-tree/walk e-b (unique-source-tree/walk e seen))]
    ;; Important: put after _ cases
    [`(let ([,(? symbol? x) ,e]) ,eb)
     (and (not (set-member? seen x))
          (let ([seen* (set-add (unique-source-tree/walk e seen) x)])
            (unique-source-tree/walk eb seen*)))]
    [`(make-vector ,e)                  (unique-source-tree/walk e seen)]
    [`(vector-ref ,e ,(? fixnum? i))                (unique-source-tree/walk i (unique-source-tree/walk e seen))]
    [`(vector-set! ,e ,(? fixnum? i) ,v)            (unique-source-tree/walk v (unique-source-tree/walk e seen))]
    [`(set! ,x ,e)                      (unique-source-tree/walk e seen)]
    ;; NEW forms (function application, checks scopedness), lambdas
    [`(,(? (lambda (e) (unique-source-tree/walk e seen)) e-f)
       ,(? (lambda (e) (unique-source-tree/walk e seen)) e-args) ...)
     (unique-source-tree/walk e-f (foldl (lambda (e acc) (unique-source-tree/walk e acc)) seen e-args))]
    [`(lambda (,(? symbol? xs) ...) ,e) (unique-source-tree/walk e (set-union seen (list->set xs)))]
    [_                                  #f]))

(define (unique-source-tree? p)
  (define (per-defn d)
    (match d
      [`(define (,(? symbol? f) ,(? symbol? args) ...) ,e-body)
       (unique-source-tree/walk e-body (list->set args))]
      [_ #f]))
  (match p
    [`(program ,defns ...) (andmap per-defn defns)]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 4) Revealed functions:
;;     - References to functions f rewritten to (fun-ref f)
;; ---------------------------------------------------------------------

(define (reveal-funcs-expr? e fs)
  (match e
    [(? fixnum?)                        #t]
    [#t                                 #t]
    [#f                                 #t]
    ['(read)                            #t]
    ['(void)                            #t]
    ;; arithmetic
    [`(- ,e)                            (reveal-funcs-expr? e fs)]
    [`(+ ,e0 ,e1)                       (and (reveal-funcs-expr? e0 fs) (reveal-funcs-expr? e1 fs))]
    ;; logic/tests
    [`(not ,e)                          (reveal-funcs-expr? e fs)]
    [`(,(? shrunk-cmp? _) ,e0 ,e1)      (and (reveal-funcs-expr? e0 fs) (reveal-funcs-expr? e1 fs))]
    ;; control
    [`(if ,e-g ,e-t ,e-f)               (and (reveal-funcs-expr? e-g fs) (reveal-funcs-expr? e-t fs) (reveal-funcs-expr? e-f fs))]
    ;; variables
    [(? symbol? x)                        (not (set-member? fs x))]
    ;; let-binding (check "unique write" property)
    [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
     (and (reveal-funcs-expr? e-g fs) (reveal-funcs-expr? e-b fs) (reveal-funcs-expr? e-r fs))]
    [`(let ([_ ,e]) ,e-b)
     (and (reveal-funcs-expr? e fs) (reveal-funcs-expr? e-b fs))]
    ;; Important: put after _ cases
    [`(let ([,(? symbol? x) ,e]) ,e-b)
     (and (reveal-funcs-expr? e fs)      (reveal-funcs-expr? e-b fs))]
    [`(make-vector ,e)                   (reveal-funcs-expr? e fs)]
    [`(vector-ref ,e ,(? fixnum? i))     (reveal-funcs-expr? e fs)]
    [`(vector-set! ,e ,(? fixnum? i) ,v) (reveal-funcs-expr? e fs)]
    [`(set! ,x ,e)                       (reveal-funcs-expr? e fs)]
    ;; NEW CASES
    [`(fun-ref ,f)                       (set-member? fs f)]
    [`(lambda (,(? symbol? xs) ...) ,e)  (reveal-funcs-expr? e fs)]
    [`(app ,(? (lambda (x) (reveal-funcs-expr? x fs))) ,es ...)
     (andmap (lambda (x) (reveal-funcs-expr? x fs)) es)]
    [_                                  #f]))

(define (revealed-functions-program? p)
  (define (per-defn d fs)
    (match d
      [`(define (,(? symbol? f) ,(? symbol? args) ...) ,e-body)
       (reveal-funcs-expr? e-body fs)]
      [_ #f]))
  (match p
    [`(program ,defns ...)
     (match defns
       [`((define (,fs ,_ ...) ,_) ...) 
        (define f-set (list->set fs))
        (andmap (lambda (x) (per-defn x f-set))  defns)]
       [_ #f])]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 5) assignment conversion
;;     - Replaces let-bindings with allocations: make-vector and vector-set! 
;;     - Replaces variable references with vector-ref (no bare bindings)
;;     - Replaces set! by vector-set! 
;; ---------------------------------------------------------------------
(define (assignment-converted-exp? e)
  (match e
    [#t #t]
    [#f #t]
    [(? fixnum?) #t]
    ['(void) #t]
    ['(read) #t]
    [`(- ,(? assignment-converted-exp? e)) #t]
    [`(+ ,(? assignment-converted-exp? e0) ,(? assignment-converted-exp? e1)) #t]
    [`(not ,(? assignment-converted-exp? e)) #t]
    [`(,(? shrunk-cmp? c) ,(? assignment-converted-exp? e0) ,(? assignment-converted-exp? e1)) #t]
    [`(if ,(? assignment-converted-exp? g)
          ,(? assignment-converted-exp? t)
          ,(? assignment-converted-exp? f)) #t]
    [`(vector-ref ,(? assignment-converted-exp? v) ,(? fixnum?)) #t]
    [`(vector-set! ,(? assignment-converted-exp? v) ,(? fixnum?) ,(? assignment-converted-exp? val)) #t]
    [`(make-vector ,(? assignment-converted-exp? len)) #t]
    [`(let ([_ (while ,(? assignment-converted-exp? g)
                      ,(? assignment-converted-exp? b))])
        ,(? assignment-converted-exp? r)) #t]
    [`(let ([_ ,(? assignment-converted-exp? sidefx)]) ,(? assignment-converted-exp? body)) #t]
    [`(let ([,(? symbol? x) (make-vector ,(? fixnum? i))])
        ,(? assignment-converted-exp? body)) #t]
    [`(let ([,(? symbol? x) ,(? assignment-converted-exp? rhs)])
        ,(? assignment-converted-exp? body)) #t]
    [(? symbol?) #t]
    ;; NEW forms
    [`(fun-ref ,f)                       #t]
    [`(lambda (,(? symbol? xs) ...) ,e)  (assignment-converted-exp? e)]
    [`(app ,(? assignment-converted-exp? e-f) ,(? assignment-converted-exp? e-args) ...) #t]
    [_ #f]))

(define (assignment-converted-program? p)
  (define (per-defn defn)
    (match defn
      [`(define (,f ,formals ...) ,e-body)
       (and (andmap symbol? (cons f formals))
            (assignment-converted-exp? e-body))]
      [_ #f]))
  (match p
    [`(program ,defns ...) (andmap per-defn defns)]
    [_ #f]))


;; ---------------------------------------------------------------------
;; 6) closure conversion
;;     - If you are not attempting extra credit, skip this (just return input)
;;     - Needs to remove lambdas, replacing them with closure allocations
;;     - See README and course note for more details
;; ---------------------------------------------------------------------
(define (closure-converted-exp? e)
  (match e
    [#t #t]
    [#f #t]
    [(? fixnum?) #t]
    ['(void) #t]
    ['(read) #t]
    [(? symbol? x) #t]
    [`(- ,(? closure-converted-exp? e)) #t]
    [`(+ ,(? closure-converted-exp? e0) ,(? closure-converted-exp? e1)) #t]
    [`(not ,(? closure-converted-exp? e)) #t]
    [`(,(? shrunk-cmp? c) ,(? closure-converted-exp? e0) ,(? closure-converted-exp? e1)) #t]
    [`(if ,(? closure-converted-exp? g)
          ,(? closure-converted-exp? t)
          ,(? closure-converted-exp? f)) #t]
    [`(vector-ref ,(? closure-converted-exp? v) ,(? fixnum?)) #t]
    [`(vector-set! ,(? closure-converted-exp? v) ,(? fixnum?) ,(? closure-converted-exp? val)) #t]
    [`(make-vector ,(? closure-converted-exp? len)) #t]
    [`(let ([_ (while ,(? closure-converted-exp? g)
                      ,(? closure-converted-exp? b))])
        ,(? closure-converted-exp? r)) #t]
    [`(let ([_ ,(? closure-converted-exp? sidefx)]) ,(? closure-converted-exp? body)) #t]
    [`(let ([,(? symbol? x) (make-vector ,(? closure-converted-exp? len))])
        ,(? closure-converted-exp? body)) #t]
    [`(let ([,(? symbol? x) ,(? closure-converted-exp? rhs)])
        ,(? closure-converted-exp? body)) #t]
    ;; NEW forms
    [`(fun-ref ,f) #t]
    [`(app ,(? closure-converted-exp? e-f) ,(? closure-converted-exp? e-args) ...) #t]
    [_ #f]))

(define (closure-converted-program? p)
  (define (per-defn defn)
    (match defn
      [`(define (,f ,formals ...) ,e-body)
       (and (andmap symbol? (cons f formals))
            (closure-converted-exp? e-body))]
      [_ #f]))
  (match p
    [`(program ,defns ...) (andmap per-defn defns)]
    [_ #f]))


;; ---------------------------------------------------------------------
;; 7) limit function arities
;;     - Every definition can have at most six arguments
;;     - If more arguments, put the rest in a vector
;; ---------------------------------------------------------------------
(define (limited-arity-program? p)
  (define (per-defn defn)
    (match defn
      [`(define (,f ,formals ...) ,e-body)
       (and (andmap symbol? (cons f formals))
            (<= (length formals) (length (argument-registers-list)))
            (closure-converted-exp? e-body))]
      [_ #f]))
  (match p
    [`(program ,defns ...) (andmap per-defn defns)]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 8) ANF (after anf-convert)
;;     - RHS is atomic or a small op over atoms
;;     - Allows let([x rhs]) ..., if over atomic guard, and the while/vector-set!
;;       side-effect form as (let ([_ (vector-set! ...)]) ...)
;; ---------------------------------------------------------------------

(define (anf-rhs? rhs)
  (match rhs
    ['(read)                             #t]
    [`(- ,(? atom? a))                   #t]
    [`(+ ,(? atom? a0) ,(? atom? a1))    #t]
    [`(not ,(? atom? a))                 #t]
    [`(eq? ,(? atom? a0) ,(? atom? a1))  #t]
    [`(<   ,(? atom? a0) ,(? atom? a1))  #t]
    [`(make-vector ,(? fixnum? i))       #t]
    ;; NEW forms
    [`(app ,(? atom? a-f) ,args ...)     (andmap atom? args)]
    [`(fun-ref ,(? symbol? f))           #t]
    [(? atom?)                           #t]
    [_                                   #f]))

(define (anf-exp? e)
  (match e
    [(? atom?)                                                      #t]
    [`(let ([_ (while ,(? anf-exp?) ,(? anf-exp?))]) ,(? anf-exp?)) #t]
    [`(let ([_ (vector-set! ,(? atom?) ,(? fixnum? i) ,(? atom?))]) ,(? anf-exp?)) #t]
    [`(let ([,(? symbol?) (vector-ref ,(? atom?) ,(? fixnum?))]) ,(? anf-exp?)) #t]
    [`(let ([,(? symbol?) ,(? anf-rhs?)]) ,(? anf-exp?))            #t]
    [`(if ,(? atom? a-g) ,(? anf-exp?) ,(? anf-exp?))               #t]
    ;; allow bare vector-set!
    [`(vector-set! ,(? atom?) ,(? atom?) ,(? atom?))                #t]
    [_                                                              #f]))

(define (anf-program? p)
  (define (per-defn defn)
    (match defn
      [`(define (,f ,formals ...) ,e-body)
       (and (andmap symbol? (cons f formals))
            (anf-exp? e-body))]
      [_ #f]))
  (match p
    [`(program ,defns ...) (andmap per-defn defns)]
    [_                     #f]))

;; ---------------------------------------------------------------------
;; 9) Blocks IR (formerly C1/2/...)
;;     - Blocks of tails, with seq/assign of simple rhs
;;     - `vector-ref` and `vector` can appear on the RHS of an assignment 
;;     - `app` can appear on the RHS of an assignment
;; ---------------------------------------------------------------------

(define (blocks-cmp? cmp) (member cmp '(eq? <)))

(define (blocks-rhs? rhs)
  (match rhs
    [(? fixnum?)                       #t]
    [(? symbol?)                       #t]
    [(? boolean?)                      #t]
    ['(read)                           #t]
    [`(void)                           #t]
    [`(- ,a)                           (atom? a)]
    [`(+ ,a0 ,a1)                      (and (atom? a0) (atom? a1))]
    [`(not ,a)                         (atom? a)]
    [`(make-vector ,i)                 (fixnum? i)] ; vector *constructor* at this stage
    [`(vector-ref ,a0 ,i)              (and (atom? a0) (fixnum? i))]
    [`(,(? blocks-cmp?) ,a0 ,a1)           (and (atom? a0) (atom? a1))]
    ;; new forms
    [`(app ,a-f ,args ...)             (andmap atom? (cons a-f args))] 
    [`(fun-ref ,f)                     (symbol? f)]
    [_                                 #f]))

(define (blocks-tail? s)
  (match s
    [`(return ,a)                                   (atom? a)]
    [`(seq (assign ,(? symbol?) ,rhs) ,rest)        (and (blocks-rhs? rhs) (blocks-tail? rest))]
    [`(seq (vector-set! ,(? atom?) ,(? fixnum?) ,(? atom? v)) ,rest)
     (blocks-tail? rest)]
    [`(vector-set! ,(? atom?) ,(? fixnum?) ,(? atom? v)) #t]
    [`(if (,(? blocks-cmp?) ,(? atom?) ,(? atom?))
          (goto ,(? label? l-t))
          (goto ,(? label? l-f)))                   #t]
    [`(goto ,(? label?))                            #t]
    [_                                              #f]))

(define (blocks-program? p)
  (define (per-defn defn)
    (match defn
      [`(define (,f ,formals ...) ,blocks)
       (and (hash? blocks)
            (hash-has-key? blocks f)
            (andmap label? (hash-keys blocks))
            (andmap (λ (x) (blocks-tail? (hash-ref blocks x))) (hash-keys blocks)))]
      [_ #f]))
  (match p
    [`(program ,defns ...)
     (andmap per-defn defns)]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 10) Locals uncovered on a per-function basis
;; ---------------------------------------------------------------------

(define (locals-program? p)
  (define (per-defn defn)
    (match defn
      [`(define ,locals (,f ,formals ...) ,blocks)
       (and (set? locals)
            (hash? blocks)
            (hash-has-key? blocks f)
            (andmap label? (hash-keys blocks))
            (andmap (λ (x) (blocks-tail? (hash-ref blocks x))) (hash-keys blocks)))]
      [_ #f]))
  (match p
    [`(program ,defn ...)
     (andmap per-defn defn)]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 10) Instruction selection (vars still present as (var x))
;;     - Matches the ops compile.rkt emits, including (goto l) which
;;       gets rendered as `jmp` later by dump-x86-64.
;; ---------------------------------------------------------------------

(define (operand/vars? op)
    (or (imm? op) (reg? op) (var? op) (byte-reg? op) (deref? op)))

(define (instr/vars? i)
  (match i
    [`(retq)                                                   #t]
    [`(movq ,(? operand/vars? src) ,(? operand/vars? dst))     #t]
    [`(movzbq ,(? byte-reg? src) ,(? operand/vars? dst))       #t]
    [`(addq ,(? operand/vars? src) ,(? operand/vars? dst))     #t]
    [`(negq ,(? operand/vars? op))                             #t]
    [`(pushq ,(? operand/vars? op))                            #t]
    [`(popq ,(? operand/vars? op))                             #t]
    [`(callq ,(? symbol?) ,(? integer?))                       #t]
    [`(xorq ,(? operand/vars?) ,(? operand/vars?))             #t]
    [`(cmpq ,(? operand/vars?) ,(? operand/vars?))             #t]
    [`(set  ,(? cc?) ,(? byte-reg? dst))                       #t]
    [`(jmp ,(? label?))                                        #t]
    [`(jmp-if ,(? cc?) ,(? label?))                            #t]
    [`(goto ,(? label?))                                       #t]
    ;; NEW
    [`(indirect-callq ,(? operand/vars?))                      #t]
    [`(leaq (fun-ref ,f) ,(? operand/vars? dst))               #t]
    [_                                                         #f]))

(define (instr-program? p)      ; after select-instructions
  (define (per-defn defn)
    (match defn
      [`(define ,locals (,f ,formals ...) ,blocks)
       (and 
          (hash-has-key? blocks f)
          (andmap (λ (blk-name)
                    (andmap instr/vars? (hash-ref blocks blk-name)))
                  (hash-keys blocks)))]
      [_ #f]))
  (match p
    [`(program ,defns ...)
     (andmap per-defn defns)]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 11) Homes assigned (vars → (deref rbp n))
;; ---------------------------------------------------------------------

(define (operand/homes? op)
  (or (imm? op) (reg? op) (deref? op) (byte-reg? op)))

(define (instr/homes? i)
  (match i
    [`(movq ,(? operand/homes? src) ,(? operand/homes? dst))     #t]
    [`(movzbq ,(? byte-reg? src) ,(? operand/homes? dst))        #t]
    [`(addq ,(? operand/homes? src) ,(? operand/homes? dst))     #t]
    [`(negq ,(? operand/homes? op))                              #t]
    [`(pushq ,(? operand/homes? op))                             #t]
    [`(popq ,(? operand/homes? op))                              #t]
    [`(callq ,(? symbol?) ,(? integer?))                         #t]
    [`(retq)                                                     #t]
    [`(cmpq ,(? operand/homes?) ,(? operand/homes?))             #t]
    [`(xorq ,(? operand/homes?) ,(? operand/homes?))             #t]
    [`(set  ,(? cc?) ,(? byte-reg?))                             #t]
    [`(jmp ,(? label?))                                          #t]
    [`(jmp-if ,(? cc?) ,(? label?))                              #t]
    [`(goto ,(? label?))                                         #t]
    [`(indirect-callq ,(? operand/homes?))                       #t]
    [`(leaq (fun-ref ,f) ,(? operand/homes? dst))                #t]    
    [_                                                           #f]))

(define (homes-assigned-program? p)
  (define (per-defn defn)
    (match defn
    [`(define ,var->loc (,f ,args ...) ,blocks)
     (and (hash? var->loc)
          (hash-has-key? blocks f)
          (andmap (λ (blk-name)
                    (andmap instr/homes? (hash-ref blocks blk-name)))
                  (hash-keys blocks)))]
    [_ #f]))
  (match p
    [`(program ,defns ...) (andmap per-defn defns)]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 12) Patched moves (after patch-instructions)
;;     – Forbid certain derefs in instructions
;; ---------------------------------------------------------------------

(define (patched-instr? i)
  (match i
    [`(movq ,src ,dst)
     (not (and (deref? src) (deref? dst)))]
    [`(movzbq ,src ,dst) (not (deref? dst))]
    [`(leaq ,src ,dst) (not (deref? dst))]
    [_ #t]))

(define (patched-program? p)
  (define (per-defn defn)
    (match defn
      [`(define ,_ (,f ,args ...) ,blocks)
       (andmap
        (λ (blk-name)
          (andmap patched-instr? (hash-ref blocks blk-name)))
        (hash-keys blocks))]
      [_ #f]))
  (and (homes-assigned-program? p)
       (match p
         [`(program ,defns ...)
          (andmap per-defn defns)]
         [_ #f])))

;; ---------------------------------------------------------------------
;; 13) Prelude and conclusion yield x86-64?
;;     - For now, we don't do any extra checking
;; ---------------------------------------------------------------------

(define x86-64? patched-program?)

