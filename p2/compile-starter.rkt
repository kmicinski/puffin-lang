#lang racket

;; CIS531 Fall '25 Project 1
;; Compiling LVar -> x86-64
(require "irs.rkt") ;; Definition of each IR (please read)
(require "system.rkt") ;; System-specific details

(provide
 uniqueify
 anf-convert
 explicate-control
 uncover-locals
 select-instructions
 assign-homes
 patch-instructions
 prelude-and-conclusion
 dump-x86-64)

;; The compiler is designed in passes, which go:
;; --> R1? -- Source program
;; |
;; +-> unique-source-tree? -- every bound identifier is written exactly once
;; |
;; +-> anf-program? -- A-Normal form (flattening nested expressions)
;; |
;; +-> c0-program? -- The C0 IR: blocks of sequences of commands (assignments)
;; |
;; +-> locals-program? -- Uncovering local variables
;; |
;; +-> instr-program? -- Translate commands into x86 instructions
;; |
;; +-> homes-assigned-program? -- Assign variables to stack locations
;; |
;; +-> patched-program? -- Patch up problematic double-indirect moves
;; |
;; +-> x86-64? -- The final x86-program
;; |
;; +-> string? -- Rendered as a string so we can print it to a file

;; TODO -- Uniqueify
(define (uniqueify p)
  (match p
    [`(program ,exp)
     ;; empty info
     `(program () ,exp)]))

;; TODO -- ANF Conversion
(define (anf-convert p)
  (define (convert-expr e k)
    ;; INCORRECT
    e)
  (match p
    [`(program ,info ,e)
     `(program ,info ,(convert-expr e (lambda (x) x)))]))

;; TODO -- Convert p (in ANF) to  C-style IR consisting consisting of labeled blocks
(define (explicate-control p)
  (define (atom? a) (or (fixnum? a) (symbol? a)))
  (define (expr->seq e)
    ;; INCORRECT 
    e)
  (match p
    [`(program ,info ,anf)
     `(program ,info ,(hash (entry-symbol) (expr->seq anf)))]))

;; Simple pass: no additional work necessary by you (alreaday correct)
(define (uncover-locals p)
  (define (h seq)
    (match seq
      [`(return ,_) (set)]
      [`(seq (assign ,x0 ,_) ,rest)
       (set-add (h rest) x0)]))
  (match p
    [`(program () ,e)
     `(program ,(h (hash-ref e (entry-symbol))) ,e)]))

;; The output of this pass is almost x86, but there will still be an
;; issue: we won't be using *registers*, we'll keep using variables
;; for now.
(define (select-instructions p)
  ;; Translate ANF-ified C0 to a block of instructions
  (define (c0->block c0)
    (define (h-atom a)
      (match a
        [(? fixnum? n) `(imm ,n)]
        [(? symbol? x) `(var ,x)]))
    (define (h seq)
      (match seq
        ;; returns--we leave out the final (ret), we will take care of
        ;; that in the epilogue
        [`(return ,a)
         `((movq ,(h-atom a) (reg rax)))]
        ;; make a call to read (0 arguments), then move the result
        ;; into the corresponding variable
        [`(seq (assign ,x (read)) ,rest)
         `((callq read_int64 0)
           (movq (reg rax) (var ,x))
           ,@(h rest))]
        ;; other cases here!
        [_ 'todo]))
    (h c0))
  ;; the input is C0: h is (hash 'start '(let ...))
  (match p
    [`(program ,info ,h)
     `(program ,info ,(hash (entry-symbol) (c0->block (hash-ref h (entry-symbol)))))]))

;; Take variables into either the stack/registers
(define (assign-homes p)
  (match-define `(program ,info ,blocks) p)
  ;; helper hashmap: create a map from each variable to its place on the stack
  (define var->stackloc
    (let ([l (set->list info)])
      (foldl (lambda (v i h) (hash-set h v (* -8 i))) (hash) l (range 1 (add1 (length l))))))
  ;; map (var x) to its home (an offset of rbp)
  (define (home a)
    (match a
      [`(var ,x) `(deref (reg rbp) ,(hash-ref var->stackloc x))]
      [_ a]))
  ;; Basic idea: traverse each instruction in the block to replace
  ;; (var x) with the appropriate stack position. Note: this will
  ;; leave some instructions
  (define (h block)
    block)
  `(program ,var->stackloc ,(hash (entry-symbol) (h (hash-ref blocks (entry-symbol))))))

;; walks over instructions and replaces invalid movqs, where both
;; operands are indirects (offsets of %rax). In x86_64, we *cannot*
;; have both arguments on the stack, so we emit some code to
;; temporarily place one in a register.
(define (patch-instructions p)
  ;; TODO
  (define (patch-tail block)
    block)
  (match p
    [`(program ,info ,blocks)
     `(program ,info ,(hash (entry-symbol) (patch-tail (hash-ref blocks (entry-symbol)))))]))

;; adds the prelude and conclusion to each of the functions in the program
;; I have done this one for you 
(define (prelude-and-conclusion p)
  ;; ensure the stack is aligned
  (define (align8 n)
    (bitwise-and (+ n 8)
                 (bitwise-not 8)))  ; clear the low four bits
  (match p
    [`(program ,locals ,blocks)
     ;; negative number, added to %rsp
     (define space-needed (if (empty? (hash-values locals))
                              0
                              (- (align8 (- (apply min (hash-values locals)))))))
     (define start-block (hash-ref blocks (entry-symbol)))
     (define new-start-block
       `((pushq (reg rbp))
         (movq (reg rsp) (reg rbp))
         (addq (imm ,space-needed) (reg rsp))
         ,@start-block
         ;; move result into %rdi and print_int64 it
         (movq (reg rax) (reg rdi))
         (callq print_int64 0)
         ;; 0 return value (to the terminal/system) into %rax
         (movq (imm 0) (reg rax))
         ;; reinstate stored %rbp
         (movq (reg rbp) (reg rsp))
         (popq (reg rbp))
         ;; transfer back to caller
         (retq)))
     ;; to build a new block, insert the prelude / conclusion
     `(program ,locals ,(hash (entry-symbol) new-start-block))]))

;; Dump x86-64 code to GAS assmbler
(define (dump-x86-64 p)
  ;; a helper I used...
  (define (render-op op)
    'todo)
  (define (render-instr instr)
    (match instr
      [`(callq ,(? label? l) ,(? nonnegative-integer? num-args))
       ;; must call rt-sym here!
       (format "call ~a" (symbol->string (rt-sym l)))]
      ['(leave) "leave"]))
  (define (render-block block name)
    (apply string-append
           (cons (format "~a:\n" name)
                 (map (λ (instr) (format "    ~a\n" (render-instr instr))) block))))
  (match p
    [`(program ,info ,blocks)
     (string-append
      ;; Tells the ABI that we're OK with non-executable stacks (security enhancement)
      (format ".globl ~a\n" (rt-sym (entry-symbol)))
      ;; include these for sure
      (runtime-function-externs)
      (render-block (hash-ref blocks (entry-symbol)) (rt-sym (entry-symbol))))]))
