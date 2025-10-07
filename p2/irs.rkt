#lang racket

(require "system.rkt")

;; 
;; This file provides detailed documentation of each of the IRs used
;; in the project.
;; 
;; Please do not modify this code (doing so will not help you): your
;; passes must conform to these specifications for the autograder to
;; work.

(provide (all-defined-out))

;; Helpers
(define (atom? a)           (or (fixnum? a)         (symbol? a)))
(define (imm?  op)          (match op [`(imm ,n)    (fixnum? n)] [_ #f]))
(define (reg?  op)          (match op [`(reg ,r)    (symbol? r)] [_ #f]))
(define (var?  op)          (match op [`(var ,x)    (symbol? x)] [_ #f]))
(define (deref? op)         (match op [`(deref (reg ,r) ,i) (and (symbol? r) (integer? i))] [_ #f]))
(define (label? l)          (symbol? l))

;;
;; Source language
;;

;; ---------------------------------------------------------------------
;; 1.  Raw R2 program (before uniqueify)
;; ---------------------------------------------------------------------

(define (cmp? cmp)
  (match cmp
    ['eq? '< '<= '> '>=]))

(define (R2-exp? e)
  (match e
    [#t #t] ;; boolean constant #t -- new
    [#f #t] ;; boolean constant #f -- new (notice the RHS is #t, not #f!)
    [(? fixnum? n) #t]
    [`(read) #t]
    [`(- ,(? R2-exp? e)) #t]
    [`(- ,(? R2-exp? e0) ,(? R2-exp? e)1) #t] ;; new
    [`(+ ,(? R2-exp? e0) ,(? R2-exp? e1)) #t]
    [`(and ,(? R2-exp? e0) ,(? R2-exp? e1))  #t] ;; new
    [`(or ,(? R2-exp? e0) ,(? R2-exp? e1)) #t] ;; new
    [`(if ,(? R2-exp? e-g) ,(? R2-exp? e-t) ,(? R2-exp? e-f)) #t] ;; new
    [`(not ,(? R2-exp? e1)) #t] ;; new
    [`(,(? cmp? cmp) ,(? R2-exp? e0) ,(? R2-exp? e1)) #t] ;; new
    [(? symbol? var) #t]
    [`(let ([,(? symbol? x) ,(? R2-exp? e)]) ,(? R2-exp? e-body)) #t]
    [_ #f]))

;; An R2 program is an R2 expression wrapped in '(program ...)
(define (R2? e)
  (match e
    [`(program ,(? R2-exp? exp)) #t]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 2.  Unique R2 (after uniqueify)
;;     – every bound identifier is written exactly once
;; ---------------------------------------------------------------------

(define (unique-source-tree? p)
  (define (walk e seen)
    (match e
      [(? fixnum?)                        seen]
      ['(read)                            seen]
      [`(- ,e)                            (walk e seen)]
      [`(+ ,e0 ,e1)                       (walk e1 (walk e0 seen))]
      [(? symbol?)                        seen]
      [`(let ([,(? symbol? x) ,e]) ,eb)
       (and (not (set-member? seen x))
            (let ([seen* (set-add (walk e seen) x)])
              (walk eb seen*)))]
      [_                                  #f]))
  (match p
    [`(program () ,e)
     (and (R2-exp? e)
          (set? (walk e (set)))           ; walk returns a set when OK
          )]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 3.  ANF (after anf-convert)
;; ---------------------------------------------------------------------

(define (anf-rhs? rhs)
  (match rhs
    [`(read)                          #t]
    [`(- ,(? atom? a))                #t]
    [`(+ ,(? atom? a0) ,(? atom? a1)) #t]
    [(? atom?)                        #t]
    [_                                #f]))

(define (anf-exp? e)
  (match e
    [(? atom?)                                           #t]
    [`(let ([,(? symbol?) ,(? anf-rhs?)]) ,(? anf-exp?)) #t]
    [_                                                   #f]))

(define (anf-program? p)
  (match p
    [`(program () ,(? anf-exp? e)) #t]
    [_                #f]))

;; ---------------------------------------------------------------------
;; 4.  C0 / explicated control (after explicate-control)
;; ---------------------------------------------------------------------

(define (c0-rhs? rhs)
  (match rhs
    [(? fixnum?)         #t]
    [(? symbol?)         #t]
    ['(read)             #t]
    [`(- ,a)             (atom? a)]
    [`(+ ,a0 ,a1)        (and (atom? a0) (atom? a1))]
    [_                   #f]))

(define (c0-seq? s)
  (match s
    [`(return ,a)                                   (atom? a)]
    [`(seq (assign ,(? symbol?) ,rhs) ,rest)        (and (c0-rhs? rhs)
                                                         (c0-seq? rest))]
    [_                                              #f]))

(define (c0-program? p)
  (match p
    [`(program ,info ,blocks)
     (and (hash? blocks)
          (hash-has-key? blocks (entry-symbol))
          (c0-seq? (hash-ref blocks (entry-symbol))))]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 5.  Locals uncovered (after uncover-locals)
;; ---------------------------------------------------------------------

(define (locals-program? p)
  (match p
    [`(program ,locals ,blocks)
     (and (set? locals)
          (c0-program? `(program () ,blocks)))]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 6.  Instruction selection (var-operands still present)
;; ---------------------------------------------------------------------
(define (operand/vars? op)  (or (imm? op) (reg? op) (var?  op)))

(define (instr/vars? i)
  (match i
    [`(movq ,(? operand/vars? src) ,(? operand/vars? dst))   #t]
    [`(addq ,(? operand/vars? src) ,(? operand/vars? dst))   #t]
    [`(negq ,(? operand/vars? op))                           #t]
    [`(pushq ,(? operand/vars? op))                          #t]
    [`(popq ,(? operand/vars? op))                           #t]
    [`(callq ,(? symbol?) ,(? integer?))                     #t]
    [`(retq)                                                 #t]
    [_                                                       #f]))

(define (instr-program? p)      ; after select-instructions
  (match p
    [`(program ,info ,blocks)
     (and (set? info)
          (hash-has-key? blocks (entry-symbol))
          (andmap instr/vars? (hash-ref blocks (entry-symbol))))]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 7.  Homes assigned (vars → (deref rbp n))
;; ---------------------------------------------------------------------
(define (operand/homes? op) (or (imm? op) (reg? op) (deref? op)))

(define (instr/homes? i)
  (match i
    [`(movq ,(? operand/homes? src) ,(? operand/homes? dst)) #t]
    [`(addq ,(? operand/homes? src) ,(? operand/homes? dst)) #t]
    [`(negq ,(? operand/homes? op))                          #t]
    [`(pushq ,(? operand/homes? op))                         #t]
    [`(popq ,(? operand/homes? op))                          #t]  
    [`(callq ,(? symbol?) ,(? integer?))                     #t]
    [`(retq)                                                 #t]
    [_                                                       #f]))

(define (homes-assigned-program? p)
  (match p
    [`(program ,var->loc ,blocks)
     (and (hash? var->loc)
          (hash-has-key? blocks (entry-symbol))
          (andmap instr/homes? (hash-ref blocks (entry-symbol))))]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 8.  Patched moves (after patch-instructions)
;;     – no movq where both operands are derefs
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
          (andmap patched-instr? (hash-ref blocks (entry-symbol)))]
         [_ #f])))

;; ---------------------------------------------------------------------
;; 9.  Prelude + conclusion added (final x86 block)
;; ---------------------------------------------------------------------

(define (x86-64? p)
  (and (patched-program? p)
       (match p
         [`(program ,_ ,blocks)
          (let* ([b  (hash-ref blocks (entry-symbol))]
                 [hd (first b)]
                 [tl (last  b)])
            (pretty-print hd)
            (pretty-print tl)
            (and (equal? hd '(pushq (reg rbp)))
                 (equal? tl '(retq))))]
         [_ #f])))
