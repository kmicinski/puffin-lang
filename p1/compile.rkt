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

;; adds the prelude and conclusion to each of the functions in the program
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

;; walks over instructions and replaces invalid movqs, where both
;; operands are indirects (offsets of %rax). In x86_64, we *cannot*
;; have both arguments in registers, so
(define (patch-instructions p)
  (define (patch-tail block)
    (match block
      ['() '()]
      ;; first move into %rax, then move %rax into i1(%r1)
      [`((movq (deref (reg ,r0) ,i0) (deref (reg ,r1) ,i1)) ,rest ...)
       `((movq (deref (reg ,r0) ,i0) (reg rax))
         (movq (reg rax) (deref (reg ,r1) ,i1))
         ,@(patch-tail rest))]
      [`(,instr ,rest ...)
       `(,instr ,@(patch-tail rest))]))
  (match p
    [`(program ,info ,blocks)
     `(program ,info ,(hash (entry-symbol) (patch-tail (hash-ref blocks (entry-symbol)))))]))

;; Take variables into either the stack/registers
(define (assign-homes p)
  (match-define `(program ,info ,blocks) p)
  (define var->stackloc
    (let ([l (set->list info)])
      (foldl (lambda (v i h) (hash-set h v (* -8 i))) (hash) l (range 1 (add1 (length l))))))
  ;; map (var x) to its home (an offset of rbp)
  (define (home a)
    (match a
      [`(var ,x) `(deref (reg rbp) ,(hash-ref var->stackloc x))]
      [_ a]))
  ;; traverse each instruction in the block to replace (var x) with
  ;; the appropriate stack position. Note: this will leave some
  ;; instructions
  (define (h block)
    (match block
      ['() '()]
      [`((movq ,a0 ,a1) ,rest ...)
       `((movq ,(home a0) ,(home a1)) ,@(h rest))]
      [`((addq ,a0 ,a1) ,rest ...)
       `((addq ,(home a0) ,(home a1)) ,@(h rest))]
      [`((negq ,a) ,rest ...)
       `((negq ,(home a)) ,@(h rest))]
      [`(,instr0 ,rest ...)
       `(,instr0 ,@(h rest))]))
  `(program ,var->stackloc ,(hash (entry-symbol) (h (hash-ref blocks (entry-symbol))))))

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
        [`(seq (assign ,x ,(? fixnum? n)) ,rest)
         `((movq (imm ,n) (var ,x))
           ,@(h rest))]
        [`(seq (assign ,x ,(? symbol? y)) ,rest)
         `((movq (var ,y) (var ,x))
           ,@(h rest))]
        [`(seq (assign ,x (- ,a)) ,rest)
         `((movq ,(h-atom a) (reg rax))
           (negq (reg rax))
           (movq (reg rax) (var ,x))
           ,@(h rest))]
        [`(seq (assign ,x (+ ,a0 ,a1)) ,rest)
         `((movq ,(h-atom a0) (reg rax))
           (addq ,(h-atom a1) (reg rax))
           (movq (reg rax) (var ,x))
           ,@(h rest))]))
    (h c0))
  ;; the input is C0: h is (hash 'start '(let ...))
  (match p
    [`(program ,info ,h)
     `(program ,info ,(hash (entry-symbol) (c0->block (hash-ref h (entry-symbol)))))]))

(define (uncover-locals p)
  (define (h seq)
    (match seq
      [`(return ,_) (set)]
      [`(seq (assign ,x0 ,_) ,rest)
       (set-add (h rest) x0)]))
  (match p
    [`(program () ,e)
     `(program ,(h (hash-ref e (entry-symbol))) ,e)]))

;; Convert p (in ANF) to  C-style IR consisting consisting of labeled blocks
(define (explicate-control p)
  (define (atom? a) (or (fixnum? a) (symbol? a)))
  (define (expr->seq e)
    (match e
      [`(let ([,x ,(? fixnum? n)]) ,e+)
       `(seq (assign ,x ,n) ,(expr->seq e+))]
      [`(let ([,x ,(? symbol? y)]) ,e+)
       `(seq (assign ,x ,y) ,(expr->seq e+))]
      [`(let ([,x (read)]) ,e+)
       `(seq (assign ,x (read)) ,(expr->seq e+))]
      [`(let ([,x (- ,a)]) ,e+)
       `(seq (assign ,x (- ,a)) ,(expr->seq e+))]
      [`(let ([,x (+ ,a0 ,a1)]) ,e+)
       `(seq (assign ,x (+ ,a0 ,a1)) ,(expr->seq e+))]
      [(? atom? a)
       `(return ,a)]))
  (match p
    [`(program ,info ,anf)
     `(program ,info ,(hash (entry-symbol) (expr->seq anf)))]))

(define (anf-convert p)
  (define (convert-expr e k)
    (match e
      [(? fixnum? n) (k n)]
      ['(read)
       (let ([x (gensym 'read)])
         `(let ([,x (read)]) ,(k x)))]
      [(? symbol? x) (k x)]
      [`(- ,e) (convert-expr e
                             (lambda (atom)
                               (let ([x (gensym)])
                                 `(let ([,x (- ,atom)]) ,(k x)))))]
      [`(+ ,e0 ,e1)
       (convert-expr e0
                     (λ (a0)
                       (convert-expr e1
                                     (λ (a1)
                                       (let ([x (gensym '+)])
                                         `(let ([,x (+ ,a0 ,a1)]) ,(k x)))))))]
      [`(let ([,x ,e]) ,e-b)
       (convert-expr e (lambda (atom)
                         `(let ([,x ,atom]) ,(convert-expr e-b k))))]))
  (match p
    [`(program ,info ,e)
     `(program ,info ,(convert-expr e (lambda (x) x)))]))

(define (uniqueify p)
  (define (rename e assignment)
    (match e
      [(? fixnum? n) n]
      [`(read) e]
      [`(- ,e+) `(- ,(rename e+ assignment))]
      [`(+ ,e0 ,e1) `(+ ,(rename e0 assignment) ,(rename e1 assignment))]
      [(? symbol? x) (hash-ref assignment x x)]
      [`(let ([,x ,e]) ,e-b)
       (if (hash-has-key? assignment x)
           (let* ([x+ (gensym x)]
                  [assignment+ (hash-set assignment x x+)])
             `(let ([,x+ ,(rename e assignment)]) ,(rename e-b assignment+)))
           (let ([assignment+ (hash-set assignment x x)])
             `(let ([,x ,(rename e assignment+)]) ,(rename e-b assignment+))))]))
  (match p
    [`(program ,exp)
     ;; empty info
     `(program () ,(rename exp (hash)))]))

;; Dump x86-64 code to GAS assmbler
(define (dump-x86-64 p)
  (define (render-op op)
    (match op
      [`(imm ,i) (format "$~a" i)]
      [`(reg ,x) (format "%~a" (symbol->string x))]
      [`(deref (reg ,reg) ,i) (format "~a(%~a)" i (symbol->string reg))]))
  (define (render-instr instr)
    (match instr
      [`(addq ,src ,dst) (format "addq ~a, ~a" (render-op src) (render-op dst))]
      [`(negq ,srcdst) (format "negq ~a" (render-op srcdst))]
      [`(movq ,src ,dst) (format "movq ~a, ~a" (render-op src) (render-op dst))]
      [`(pushq ,src) (format "pushq ~a" (render-op src))]
      [`(popq ,dst) (format "popq ~a" (render-op dst))]
      [`(callq ,(? label? l) ,(? nonnegative-integer? num-args))
       ;; must call rt-sym here!
       (format "call ~a" (symbol->string (rt-sym l)))]
      ['(retq) "ret"]
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

