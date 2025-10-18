#lang racket
;;
;; CIS531 Fall '25: Project 2 -- R2 / LIf
;;
;; This file specifies the IRs used across the compiler pipeline.  Do
;; not change the intended meaning of these contracts; your passes
;; must produce programs that satisfy these predicates.
;;

(require "system.rkt")
(provide (all-defined-out))

;; ---------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------

(define (atom? a)                (or (fixnum? a) (symbol? a) (boolean? a)))
(define (imm? op)                (match op [`(imm ,n)            (fixnum? n)] [_ #f]))
(define (byte-reg? op)           (match op [`(byte-reg ,r)       (symbol? r)] [_ #f]))
(define (reg? op)                (match op [`(reg ,r)            (symbol? r)] [_ #f]))
(define (var? op)                (match op [`(var ,x)            (symbol? x)] [_ #f]))
(define (cc? op)                 (member op '(e l le g ge))) ; we currently use only e (==) and l (<)
(define (deref? op)              (match op [`(deref (reg ,r) ,i) (and (symbol? r) (integer? i))] [_ #f]))
(define (label? l)               (symbol? l))

;; ---------------------------------------------------------------------
;; 1.  Raw R3 program (before shrink/uniqueify)
;; ---------------------------------------------------------------------

;; Comparators in the *source* language (shrink will reduce this set)
(define (cmp? cmp)
  (member cmp '(eq? < <= > >=)))

(define (R3-exp? e)
  (match e
    [#t #t]
    [#f #t]
    [(? fixnum? n) #t]
    [`(read) #t]
    [`(- ,(? R3-exp? e)) #t]
    [`(- ,(? R3-exp? e0) ,(? R3-exp? e1)) #t]
    [`(+ ,(? R3-exp? e0) ,(? R3-exp? e1)) #t]
    [`(and ,(? R3-exp? e0) ,(? R3-exp? e1)) #t]
    [`(or  ,(? R3-exp? e0) ,(? R3-exp? e1)) #t]
    [`(if ,(? R3-exp? e-g) ,(? R3-exp? e-t) ,(? R3-exp? e-f)) #t]
    [`(not ,(? R3-exp? e1)) #t]
    [`(,(? cmp? c) ,(? R3-exp? e0) ,(? R3-exp? e1)) #t]
    [(? symbol? var) #t]
    [`(let ([,(? symbol? x) ,(? R3-exp? e)]) ,(? R3-exp? e-body)) #t]
    ;; new forms
    [`(begin ,(? R3-exp?) ... ,(? R3-exp? return-value)) #t]
    [`(while ,(? R3-exp? e-g) ,(? R3-exp? es) ...) #t]
    [`(vector ,(? R3-exp?) ,(? R3-exp?) ...) #t] ;; at *least* one body
    [`(vector-ref ,(? R3-exp? vec) ,(? R3-exp? index)) #t]
    [`(vector-set! ,(? R3-exp? vec) ,(? R3-exp? index) ,(? R3-exp? value)) #t]
    [`(set! ,(? symbol? x) ,(? R3-exp? e)) #t]
    [_ #f]))

(define (R3? e)
  (match e
    [`(program ,(? R3-exp? exp)) #t]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 3.  Shrunk R3 (after shrink)
;;     – Removes binary minus, and/or, <=, >, >=
;;     – Keeps: integers, booleans, read, unary -, +, not, if, eq?, <, let, vars
;; ---------------------------------------------------------------------

(define (shrunk-cmp? c) (member c '(eq? <)))

(define (shrunk-R3-exp? e)
  (match e
    [#t #t]
    [#f #t]
    [(? fixnum? n) #t]
    [`(read) #t]
    ;; arithmetic
    [`(- ,(? shrunk-R3-exp? e)) #t]                         ; unary minus only
    [`(+ ,(? shrunk-R3-exp? e0) ,(? shrunk-R3-exp? e1)) #t] ; addition
    ;; logic / tests
    [`(not ,(? shrunk-R3-exp? e1)) #t]
    [`(,(? shrunk-cmp? c) ,(? shrunk-R3-exp? e0) ,(? shrunk-R3-exp? e1)) #t]
    ;; control
    [`(if ,(? shrunk-R3-exp? e-g) ,(? shrunk-R3-exp? e-t) ,(? shrunk-R3-exp? e-f)) #t]
    ;; vars/let
    [(? symbol? x) #t]
    ;; new -- sequence
    [`(let ([,(? symbol? x) ,(? shrunk-R3-exp? e)]) ,(? shrunk-R3-exp? e-b)) #t]
    ;; new forms
    [`(let ([_ ,(? shrunk-R3-exp?)]) ,(? shrunk-R3-exp?)) #t] ;; begin turns into multiple lets
    [`(vector ,(? shrunk-R3-exp?) ,(? shrunk-R3-exp?) ...) #t]
    [`(vector-ref ,(? shrunk-R3-exp? vec) ,(? shrunk-R3-exp? index)) #t]
    [`(vector-set! ,(? shrunk-R3-exp? vec) ,(? shrunk-R3-exp? index) ,(? R3-exp? value)) #t]
    [`(set! ,(? symbol? x) ,(? R3-exp? e)) #t]
    [_ #f]))

(define (shrunk-R3? p)
  (match p
    [`(program ,(? shrunk-R3-exp? e)) #t]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 4.  Unique R2 (after uniqueify) — performed *after* shrink
;;     – every bound identifier is written exactly once
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
    [_                                  #f]))

(define (unique-source-tree? p)
  (match p
    [`(program () ,e)
     (and (shrunk-R3-exp? e)
          (set? (unique-source-tree/walk e (set))))]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 5.  ANF (after anf-convert)
;; ---------------------------------------------------------------------

(define (anf-rhs? rhs)
  (match rhs
    ['(read)                          #t]
    [`(- ,(? atom? a))                #t]
    [`(+ ,(? atom? a0) ,(? atom? a1)) #t]
    [`(not ,(? atom? a))              #t]
    [`(eq? ,(? atom? a0) ,(? atom? a1)) #t]
    [`(<   ,(? atom? a0) ,(? atom? a1)) #t]
    [(? atom?)                        #t]
    [_                                #f]))

(define (anf-exp? e)
  (match e
    [(? atom?)                                           #t]
    [`(let ([,(? symbol?) ,(? anf-rhs?)]) ,(? anf-exp?)) #t]
    [`(if ,(? atom? a-g) ,(? anf-exp?) ,(? anf-exp?))    #t]
    [_                                                   #f]))

(define (anf-program? p)
  (match p
    [`(program () ,(? anf-exp? e)) #t]
    [_                             #f]))

;; ---------------------------------------------------------------------
;; 6.  C1 / explicated control (after explicate-control)
;;     (Comparators restricted to eq? and <)
;; ---------------------------------------------------------------------

(define (c1-cmp? cmp) (member cmp '(eq? <)))

(define (c1-rhs? rhs)
  (match rhs
    [(? fixnum?)                       #t]
    [(? symbol?)                       #t]
    [(? boolean?)                      #t]
    ['(read)                           #t]
    [`(- ,a)                           (atom? a)]
    [`(+ ,a0 ,a1)                      (and (atom? a0) (atom? a1))]
    [`(not ,a)                         (atom? a)]
    [`(make-vec ,a)                    (atom? a)]
    [`(vec-length ,a)                  (atom? a)]
    [`(unsafe-vector-ref ,a0 ,a1)      (and (atom? a0) (atom? a1))]
    [`(unsafe-vector-set! ,a0 ,a1 ,a2) (and (atom? a0) (atom? a1) (atom? a2))]
    [`(,(? c1-cmp?) ,a0 ,a1)           (and (atom? a0) (atom? a1))]
    [_                                 #f]))

(define (c1-tail? s)
  (match s
    [`(return ,a)                                   (atom? a)]
    [`(seq (assign ,(? symbol?) ,rhs) ,rest)        (and (c1-rhs? rhs)
                                                         (c1-tail? rest))]
    [`(if (,(? c1-cmp?) ,(? atom?) ,(? atom?))
          (goto ,(? label? l-t))
          (goto ,(? label? l-f)))                   #t]
    [`(goto ,(? label?))                            #t]
    [_                                              #f]))

(define (c1-program? p)
  (match p
    [`(program ,info ,blocks)
     (and (hash? blocks)
          (hash-has-key? blocks (entry-symbol))
          (andmap label? (hash-keys blocks))
          (andmap (λ (x) (c1-tail? (hash-ref blocks x))) (hash-keys blocks)))]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 7.  Locals uncovered (after uncover-locals)
;; ---------------------------------------------------------------------

(define (locals-program? p)
  (match p
    [`(program ,locals ,blocks)
     (and (set? locals)
          (c1-program? `(program () ,blocks)))]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 8.  Instruction selection (vars still present as (var x))
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
;; 9.  Homes assigned (vars → (deref rbp n))
;; ---------------------------------------------------------------------

(define (operand/homes? op)
  (or (imm? op) (reg? op) (deref? op) (byte-reg? op)))

(define (instr/homes? i)
  (match i
    [`(movq ,(? operand/homes? src) ,(? operand/homes? dst))     #t]
    [`(movzbq ,(? operand/homes? src) ,(? operand/homes? dst))   #t]
    [`(addq ,(? operand/homes? src) ,(? operand/homes? dst))     #t]
    [`(negq ,(? operand/homes? op))                              #t]
    [`(pushq ,(? operand/homes? op))                             #t]
    [`(popq ,(? operand/homes? op))                              #t]
    [`(callq ,(? symbol?) ,(? integer?))                         #t]
    [`(retq)                                                     #t]
    [`(cmpq ,(? operand/homes?) ,(? operand/homes?))             #t]
    [`(xorq ,(? operand/homes?) ,(? operand/homes?))             #t]
    [`(set  ,(? cc?) ,(? operand/homes?))                        #t]
    [`(jmp ,(? label?))                                          #t]
    [`(jmp-if ,(? cc?) ,(? label?))                              #t]
    [`(label ,(? label?))                                        #t]
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
;; 10. Patched moves (after patch-instructions)
;;     – no (movq (deref ...) (deref ...))
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
;; 11. Prelude + conclusion added (final x86 block)
;; ---------------------------------------------------------------------

(define x86-64? patched-program?)
