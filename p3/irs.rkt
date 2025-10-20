#lang racket
;;
;; CIS531 Fall '25: Project 3 -- R3 with vectors, set!, and while
;;
;; Interface (predicates) for every IR used across the pipeline.
;; Keep these aligned with compile.rkt’s expectations.
;;

(require "system.rkt")
(provide (all-defined-out))

;; ---------------------------------------------------------------------
;; Helpers (shared across IRs)
;; ---------------------------------------------------------------------

(define (atom? a)                (or (fixnum? a) (symbol? a) (boolean? a)))
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
;; 1) Raw R3 (source)
;; ---------------------------------------------------------------------

(define (R3-exp? e)
  (match e
    [#t #t]
    [#f #t]
    [(? fixnum?) #t]
    ['(read) #t]
    [`(- ,(? R3-exp? e)) #t]
    [`(- ,(? R3-exp? e0) ,(? R3-exp? e1)) #t]
    [`(+ ,(? R3-exp? e0) ,(? R3-exp? e1)) #t]
    [`(and ,(? R3-exp? e0) ,(? R3-exp? e1)) #t]
    [`(or  ,(? R3-exp? e0) ,(? R3-exp? e1)) #t]
    [`(not ,(? R3-exp? e1)) #t]
    [`(,(? cmp? c) ,(? R3-exp? e0) ,(? R3-exp? e1)) #t]
    [`(if ,(? R3-exp? e-g) ,(? R3-exp? e-t) ,(? R3-exp? e-f)) #t]
    [(? symbol?) #t]
    [`(let ([,(? symbol? x) ,(? R3-exp? e)]) ,(? R3-exp? eb)) #t]
    ;; sequences / loops / vectors / mutation
    [`(begin ,(? R3-exp?) ... ,(? R3-exp? ret)) #t]
    [`(while ,(? R3-exp? e-g) ,(? R3-exp? es) ...) #t]
    [`(make-vector ,(? R3-exp? len)) #t]
    [`(vector-ref ,(? R3-exp? v) ,(? R3-exp? i)) #t]
    [`(vector-set! ,(? R3-exp? v) ,(? R3-exp? i) ,(? R3-exp? val)) #t]
    [`(set! ,(? symbol? x) ,(? R3-exp? e)) #t]
    [_ #f]))

(define (R3? p)
  (match p
    [`(program ,(? R3-exp? e)) #t]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 2) Shrunk R3 (after shrink)
;;     - binary minus removed
;;     - and/or/<=/>/>= removed
;;     - keeps: integers, booleans, read, unary -, +, not, if, eq?, <, let, vars
;;     - also keeps while/make-vector/vector-ref/vector-set!/set!/begin (as let chains)
;; ---------------------------------------------------------------------

(define (shrunk-R3-exp? e)
  (match e
    [#t #t]
    [#f #t]
    [(? fixnum?) #t]
    ['(read) #t]
    ;; arithmetic
    [`(- ,(? shrunk-R3-exp? e)) #t]
    [`(+ ,(? shrunk-R3-exp? e0) ,(? shrunk-R3-exp? e1)) #t]
    ;; logic / tests
    [`(not ,(? shrunk-R3-exp? e1)) #t]
    [`(,(? shrunk-cmp? c) ,(? shrunk-R3-exp? e0) ,(? shrunk-R3-exp? e1)) #t]
    ;; control
    [`(if ,(? shrunk-R3-exp? e-g) ,(? shrunk-R3-exp? e-t) ,(? shrunk-R3-exp? e-f)) #t]
    ;; vars/let
    [(? symbol?) #t]
    [`(let ([,(? symbol? x) ,(? shrunk-R3-exp? e)]) ,(? shrunk-R3-exp? eb)) #t]
    ;; canonicalized forms that shrink passes through
    [`(let ([_ ,(? shrunk-R3-exp?)]) ,(? shrunk-R3-exp?)) #t]
    [`(let ([_ (while ,(? shrunk-R3-exp?) ,(? shrunk-R3-exp?))]) ,(? shrunk-R3-exp?)) #t]
    [`(make-vector ,(? shrunk-R3-exp? len)) #t]
    [`(vector-ref ,(? shrunk-R3-exp? v) ,(? shrunk-R3-exp? i)) #t]
    [`(vector-set! ,(? shrunk-R3-exp? v) ,(? shrunk-R3-exp? i) ,(? shrunk-R3-exp? val)) #t]
    [`(set! ,(? symbol?) ,(? shrunk-R3-exp?)) #t]
    [_ #f]))

(define (shrunk-R3? p)
  (match p
    [`(program ,(? shrunk-R3-exp? e)) #t]
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
    [`(let ([,(? symbol? x) ,e]) ,eb)
     (and (not (set-member? seen x))
          (let ([seen* (set-add (unique-source-tree/walk e seen) x)])
            (unique-source-tree/walk eb seen*)))]
    ;; while / vector ops / set! just traverse
    [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
     (unique-source-tree/walk e-r (unique-source-tree/walk e-b (unique-source-tree/walk e-g seen)))]
    [`(let ([_ ,e]) ,e-b)
     (unique-source-tree/walk e-b (unique-source-tree/walk e seen))]
    [`(make-vector ,e)                  (unique-source-tree/walk e seen)]
    [`(vector-ref ,e ,i)                (unique-source-tree/walk i (unique-source-tree/walk e seen))]
    [`(vector-set! ,e ,i ,v)            (unique-source-tree/walk v (unique-source-tree/walk i (unique-source-tree/walk e seen)))]
    [`(set! ,x ,e)                      (unique-source-tree/walk e seen)]
    [_                                  #f]))

(define (unique-source-tree? p)
  (match p
    [`(program () ,e)
     (and (shrunk-R3-exp? e)
          (set? (unique-source-tree/walk e (set))))]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 4) ANF (after anf-convert)
;;     - RHS is atomic or a small op over atoms
;;     - Allows let([x rhs]) ..., if over atomic guard, and the while/vector-set!
;;       side-effect form as (let ([_ (vector-set! ...)]) ...)
;; ---------------------------------------------------------------------

(define (anf-rhs? rhs)
  (match rhs
    ['(read)                            #t]
    [`(- ,(? atom? a))                  #t]
    [`(+ ,(? atom? a0) ,(? atom? a1))   #t]
    [`(not ,(? atom? a))                #t]
    [`(eq? ,(? atom? a0) ,(? atom? a1)) #t]
    [`(<   ,(? atom? a0) ,(? atom? a1)) #t]
    [`(make-vector ,(? atom? a))        #t]
    [(? atom?)                          #t]
    [_                                  #f]))

(define (anf-exp? e)
  (match e
    [(? atom?)                                                      #t]
    [`(let ([_ (while ,(? anf-exp?) ,(? anf-exp?))]) ,(? anf-exp?)) #t]
    [`(let ([,(? symbol?) ,(? anf-rhs?)]) ,(? anf-exp?))            #t]
    [`(if ,(? atom? a-g) ,(? anf-exp?) ,(? anf-exp?))               #t]
    ;; vector-ref lowered via let-binding in anf-convert, but allow it if present:
    [`(let ([,(? symbol?) (vector-ref ,(? atom?) ,(? atom?))]) ,(? anf-exp?)) #t]
    ;; side-effect in ANF via dummy binding:
    [`(let ([_ (vector-set! ,(? atom?) ,(? atom?) ,(? atom?))]) ,(? anf-exp?)) #t]
    [_                                                              #f]))

(define (anf-program? p)
  (match p
    [`(program () ,(? anf-exp? e)) #t]
    [_                             #f]))

;; ---------------------------------------------------------------------
;; 5) C2 / explicated control (after explicate-control)
;;     - Blocks of tails, with seq/assign of simple rhs
;;     - `vector-ref` and `vector` can appear on the RHS of an assignment 
;;     - 
;; ---------------------------------------------------------------------

(define (c2-cmp? cmp) (member cmp '(eq? <)))

(define (c2-rhs? rhs)
  (match rhs
    [(? fixnum?)                       #t]
    [(? symbol?)                       #t]
    [(? boolean?)                      #t]
    ['(read)                           #t]
    [`(- ,a)                           (atom? a)]
    [`(+ ,a0 ,a1)                      (and (atom? a0) (atom? a1))]
    [`(not ,a)                         (atom? a)]
    [`(vector ,a)                      (atom? a)] ; vector *constructor* at this stage
    [`(vector-ref ,a0 ,i)              (and (atom? a0) (or (fixnum? i) (symbol? i) (boolean? i)))]
    [`(,(? c2-cmp?) ,a0 ,a1)           (and (atom? a0) (atom? a1))]
    [_                                 #f]))

(define (c2-tail? s)
  (match s
    [`(return ,a)                                   (atom? a)]
    [`(seq (assign ,(? symbol?) ,rhs) ,rest)        (and (c2-rhs? rhs) (c2-tail? rest))]
    [`(seq (vector-set! ,(? atom?) ,(? fixnum?) ,(? atom? v)) ,rest)
     (c2-tail? rest)]
    [`(vector-set! ,(? atom?) ,(? fixnum?) ,(? atom? v)) #t]
    [`(if (,(? c2-cmp?) ,(? atom?) ,(? atom?))
          (goto ,(? label? l-t))
          (goto ,(? label? l-f)))                   #t]
    [`(goto ,(? label?))                            #t]
    [_                                              #f]))

(define (c2-program? p)
  (match p
    [`(program ,info ,blocks)
     (and (hash? blocks)
          (hash-has-key? blocks (entry-symbol))
          (andmap label? (hash-keys blocks))
          (andmap (λ (x) (c2-tail? (hash-ref blocks x))) (hash-keys blocks)))]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 6) Locals uncovered (after uncover-locals)
;; ---------------------------------------------------------------------

(define (locals-program? p)
  (match p
    [`(program ,locals ,blocks)
     (and (set? locals)
          (c2-program? `(program () ,blocks)))]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 7) Instruction selection (vars still present as (var x))
;;     - Matches the ops compile.rkt emits, including (goto l) which
;;       gets rendered as `jmp` later by dump-x86-64.
;; ---------------------------------------------------------------------

(define (operand/vars? op)
  (or (imm? op) (reg? op) (var? op) (byte-reg? op)))

(define (instr/vars? i)
  (match i
    [`(movq ,(? operand/vars? src) ,(? operand/vars? dst))     #t]
    [`(movzbq ,(? byte-reg? src) ,(? operand/vars? dst))       #t]
    [`(addq ,(? operand/vars? src) ,(? operand/vars? dst))     #t]
    [`(negq ,(? operand/vars? op))                             #t]
    [`(pushq ,(? operand/vars? op))                            #t]
    [`(popq ,(? operand/vars? op))                             #t]
    [`(callq ,(? symbol?) ,(? integer?))                       #t]
    [`(retq)                                                   #t]
    [`(xorq ,(? operand/vars?) ,(? operand/vars?))             #t]
    [`(cmpq ,(? operand/vars?) ,(? operand/vars?))             #t]
    [`(set  ,(? cc?) ,(? byte-reg? dst))                       #t]
    [`(jmp ,(? label?))                                        #t]
    [`(jmp-if ,(? cc?) ,(? label?))                            #t]
    [`(goto ,(? label?))                                       #t]
    [_                                                         #f]))

(define (instr-program? p)      ; after select-instructions
  (match p
    [`(program ,info ,blocks)
     (and (set? info)
          (hash-has-key? blocks (entry-symbol))
          (andmap (λ (blk-name)
                    (andmap instr/vars? (hash-ref blocks blk-name)))
                  (hash-keys blocks)))]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 8) Homes assigned (vars → (deref rbp n))
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
    [`(set  ,(? cc?) ,(? byte-reg?))                             #t] ; set targets a byte-reg
    [`(jmp ,(? label?))                                          #t]
    [`(jmp-if ,(? cc?) ,(? label?))                              #t]
    [`(goto ,(? label?))                                         #t]
    [_                                                           #f]))

(define (homes-assigned-program? p)
  (match p
    [`(program ,var->loc ,blocks)
     (and (hash? var->loc)
          (hash-has-key? blocks (entry-symbol))
          (andmap (λ (blk-name)
                    (andmap instr/homes? (hash-ref blocks blk-name)))
                  (hash-keys blocks)))]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 9) Patched moves (after patch-instructions)
;;     – forbid (movq (deref ...) (deref ...)) in any block
;; ---------------------------------------------------------------------

(define (patched-instr? i)
  (match i
    [`(movq ,src ,dst)
     (not (and (deref? src) (deref? dst)))]
    [_ #t]))

(define (patched-program? p)
  (and (homes-assigned-program? p)
       (match p
         [`(program ,_ ,blocks)
          (andmap
           (λ (blk-name)
             (andmap patched-instr? (hash-ref blocks blk-name)))
           (hash-keys blocks))]
         [_ #f])))

;; ---------------------------------------------------------------------
;; 10) Final x86-64? (after prelude+conclusion)
;; ---------------------------------------------------------------------

(define x86-64? patched-program?)
