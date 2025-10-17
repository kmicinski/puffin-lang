#lang racket

;; CIS531 Fall '25 Project 1
;; Compiling LVar -> x86-64
(require "irs.rkt") ;; Definition of each IR (please read)
(require "system.rkt") ;; System-specific details

(provide (all-defined-out)) ;; export everything for testing

;; The compiler is designed in passes, which go:
;;
;; --> R3? -- Source program
;; |
;; +-> typed-R2? -- Typechecking R2
;; | 
;; +-> shrunk-R2? -- Shrunken R2 (removes several forms)
;; |
;; +-> unique-source-tree? -- every bound identifier is written exactly once
;; |
;; +-> anf-program? -- A-Normal form (flattening nested expressions)
;; |
;; +-> c1-program? -- The C1 IR: blocks of sequences of commands, if, and gotos
;; |
;; +-> locals-program? -- Uncovering local variables
;; |
;; +-> instr-program? -- Pseudo-x86, flattened (blocks of lists) IR
;; |
;; +-> homes-assigned-program? -- Assign variables to stack locations
;; |
;; +-> patched-program? -- Patch up problematic double-indirect moves
;; |
;; +-> x86-64? -- The final x86-program
;; |
;; +-> string? -- Rendered as a string so we can print it to a file

;; Dump x86-64 code to GAS assmbler
(define (dump-x86-64 p)
  (define (render-op op)
    (match op
      [`(imm ,i) (format "$~a" i)]
      [`(reg ,x) (format "%~a" (symbol->string x))]
      [`(byte-reg ,x) (format "%~a" (symbol->string x))]
      [`(deref (reg ,reg) ,i) (format "~a(%~a)" i (symbol->string reg))]))
  (define (render-instr instr)
    (match instr
      [`(xorq ,src ,dst) (format "xorq ~a, ~a" (render-op src) (render-op dst))]
      [`(addq ,src ,dst) (format "addq ~a, ~a" (render-op src) (render-op dst))]
      [`(negq ,srcdst) (format "negq ~a" (render-op srcdst))]
      [`(movq ,src ,dst) (format "movq ~a, ~a" (render-op src) (render-op dst))]
      [`(movzbq ,src ,dst) (format "movzbq ~a, ~a" (render-op src) (render-op dst))]
      [`(pushq ,src) (format "pushq ~a" (render-op src))]
      [`(popq ,dst) (format "popq ~a" (render-op dst))]
      [`(cmpq ,op0 ,op1) (format "cmpq ~a, ~a" (render-op op0) (render-op op1))]
      [`(jmp-if ,cc ,lab)
       (define instr (match cc ['e "je"] ['l "jl"]))
       (format "~a ~a" instr lab)]
      [`(jmp ,lab)
       (format "jmp ~a" lab)]
      [`(set ,cc ,byte-reg)
       (match cc
         ['e (format "sete ~a" (render-op byte-reg))]
         ['l (format "setl ~a" (render-op byte-reg))])]
      [`(callq ,(? label? l) ,(? nonnegative-integer? num-args))
       ;; must call rt-sym here!
       (format "call ~a" (symbol->string (rt-sym l)))]
      ['(retq) "ret"]
      ['(leave) "leave"]))
  (define (render-block block name)
    (apply string-append
           (cons (format "~a:\n" name)
                 (map (λ (instr) (format "    ~a\n" (render-instr instr))) block))))
  ;; which block names are top-level functions? In this language, this
  ;; is only `main`.
  (define (function-name? block-name) (equal? block-name (entry-symbol)))
  (match p
    [`(program ,info ,blocks)
      (string-append
       ;; Tells the ABI that we're OK with non-executable stacks (security enhancement)
       (format ".globl ~a\n" (rt-sym (entry-symbol)))
       ;; include these for sure
       (runtime-function-externs)
       (foldl (λ (block-name acc) (string-append acc (render-block (hash-ref blocks block-name)
                                                                   (if (function-name? block-name)
                                                                       (rt-sym block-name)
                                                                       block-name))))
              ""
              (hash-keys blocks)))]))

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
         ,@start-block))
     (define conclusion-block
       `(;; move result into %rdi and print_int64 it
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
     `(program ,locals ,(hash-set (hash-set blocks (entry-symbol) new-start-block)
                                  (conclusion-block-name)
                                  conclusion-block))]))

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
      ;; new ...
      [`((movzbq (byte-reg ,r) (deref (reg ,r1) ,i1)) ,rest ...)
       `((movzbq (byte-reg ,r) (reg rax))
         (movq (reg rax) (deref (reg ,r1) ,i1))
         ,@(patch-tail rest))]
      ;; new ...
      [`((cmpq ,a (deref (reg ,r1) ,i1)) ,rest ...)
       `((movq (deref (reg ,r1) ,i1) (reg rax))
         (cmpq ,a (reg rax))
         ,@(patch-tail rest))]
      [`((cmpq ,a (imm ,d)) ,rest ...)
       `((movq (imm ,d) (reg rax))
         (cmpq ,a (reg rax))
         ,@(patch-tail rest))]
      [`(,instr ,rest ...)
       `(,instr ,@(patch-tail rest))]))
  (match p
    [`(program ,info ,blocks)
     (define blocks+ (foldl (λ (blk acc) (hash-set acc blk (patch-tail (hash-ref blocks blk)))) blocks (hash-keys blocks)))
     `(program ,info ,blocks+)]))

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
      [`((cmpq ,a0 ,a1) ,rest ...)
       `((cmpq ,(home a0) ,(home a1)) ,@(h rest))]
      [`((movzbq ,a0 ,a1) ,rest ...)
       `((movzbq ,(home a0) ,(home a1)) ,@(h rest))]
      [`((movq ,a0 ,a1) ,rest ...)
       `((movq ,(home a0) ,(home a1)) ,@(h rest))]
      [`((addq ,a0 ,a1) ,rest ...)
       `((addq ,(home a0) ,(home a1)) ,@(h rest))]
      [`((negq ,a) ,rest ...)
       `((negq ,(home a)) ,@(h rest))]
      [`(,instr0 ,rest ...)
       `(,instr0 ,@(h rest))]))
  (define blocks+ (foldl (λ (blk acc)
                           (hash-set acc blk (h (hash-ref blocks blk)))) blocks (hash-keys blocks)))
  `(program ,var->stackloc ,blocks+))


;; The output of this pass is almost x86, but there will still be an
;; issue: we won't be using *registers*, we'll keep using variables
;; for now.
(define (select-instructions p)
  ;; Translate ANF-ified C0 to a block of instructions
  (define (c1->block c1)
    (define (h-atom a)
      (match a
        [(? fixnum? n) `(imm ,n)]
        [(? symbol? x) `(var ,x)]
        [(? boolean? b) `(imm ,(if b 1 0))]))
    (define (h seq)
      (match seq
        ;; returns--we leave out the final (ret), we will take care of
        ;; that in the epilogue
        [`(return ,a)
         `((movq ,(h-atom a) (reg rax))
           ;; now jump to the conclusion
           (jmp ,(conclusion-block-name)))]
        ;; make a call to read (0 arguments), then move the result
        ;; into the corresponding variable
        [`(seq (assign ,x (read)) ,rst)
         `((callq read_int64 0)
           (movq (reg rax) (var ,x))
           ,@(h rst))]
        [`(seq (assign ,x (< ,a0 ,a1)) ,rst)
         `((cmpq  ,(h-atom a1) ,(h-atom a0))
           (set l (byte-reg al))
           (movzbq (byte-reg al) (var ,x))
           ,@(h rst))]
        [`(seq (assign ,x (eq? ,a0 ,a1)) ,rst)
         `((cmpq ,(h-atom a1) ,(h-atom a0))
           (set e (byte-reg al))
           (movzbq (byte-reg al) (var ,x))
           ,@(h rst))]
        ;; cmp is {eq?, <}
        [`(if (,cmp ,a0 ,a1) (goto ,l0) (goto ,l1))
         (define cc (match cmp ['eq? 'e] ['< 'l]))
         `((cmpq ,(h-atom a1) ,(h-atom a0))
           (jmp-if ,cc ,l0)
           (jmp ,l1))]
        [`(seq (assign ,x ,(? boolean? b)) ,rest)
         `((movq (imm ,(if b 1 0)) (var ,x))
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
        [`(seq (assign ,x (not ,a)) ,rest)
         `((movq ,(h-atom a) (reg rax))
           (xorq (imm 1) (reg rax))
           (movq (reg rax) (var ,x))
           ,@(h rest))]
        [`(seq (assign ,x (+ ,a0 ,a1)) ,rest)
         `((movq ,(h-atom a0) (reg rax))
           (addq ,(h-atom a1) (reg rax))
           (movq (reg rax) (var ,x))
           ,@(h rest))]))
    (h c1))
  ;; the input is C0: h is (hash 'start '(let ...))
  (match p
    [`(program ,info ,h)
     (define blocks (hash-set 
                     (foldl (λ (block acc) (hash-set acc block (c1->block (hash-ref h block)))) h (hash-keys h))
                     (conclusion-block-name)
                     '())) ;; also add an empty conclusion block
     `(program ,info ,blocks)]))

(define (uncover-locals p)
  (define (h seq)
    (match seq
      [`(return ,_) (set)]
      [`(if (,cmp ,a0 ,a1) (goto ,l0) (goto ,l1)) (set)]
      [`(seq (assign ,x0 ,_) ,rest)
       (set-add (h rest) x0)]))
  (match p
    [`(program () ,blocks)
     (define locals (foldl (λ (block acc) (set-union acc (h (hash-ref blocks block))))
                           (set)
                           (hash-keys blocks)))
     `(program ,locals ,blocks)]))

;; Convert p (in ANF) to  C-style IR consisting consisting of labeled blocks
(define (explicate-control p)
  ;; merge two hashes, assume no common keys
  (define (merge h0 h1)
    (foldl (λ (k0 h1) (hash-set h1 k0 (hash-ref h0 k0))) h1 (hash-keys h0)))
  (define (atom? a) (or (fixnum? a) (symbol? a) (boolean? a)))
  ;; basic idea: return a hash which maps blocks to a label name
  (define (expr->blocks e current-block)
    ;; prefixing a basic block with an instruction
    ;; (prefix-w-instruction (hash 'main (return 1)) 'main (assign x 1))
    ;; => (hash 'main (seq (assign x 1) (return 1)))
    (define (extend h label instruction)
      (hash-set h label `(seq ,instruction ,(hash-ref h label))))
    (match e
      [`(let ([,x ,(? boolean? b)]) ,e+)
       (extend (expr->blocks e+ current-block) current-block `(assign ,x ,b))]
      [`(let ([,x ,(? fixnum? n)]) ,e+)
       (extend (expr->blocks e+ current-block) current-block `(assign ,x ,n))]
      [`(let ([,x ,(? symbol? y)]) ,e+)
       (extend (expr->blocks e+ current-block) current-block `(assign ,x ,y))]
      [`(let ([,x (read)]) ,e+)
       (extend (expr->blocks e+ current-block) current-block `(assign ,x (read)))]
      [`(let ([,x (- ,a)]) ,e+)
       (extend (expr->blocks e+ current-block) current-block `(assign ,x (- ,a)))]
      [`(let ([,x (not ,a)]) ,e+)
       (extend (expr->blocks e+ current-block) current-block `(assign ,x (not ,a)))]
      [`(let ([,x (+ ,a0 ,a1)]) ,e+)
       (extend (expr->blocks e+ current-block) current-block `(assign ,x (+ ,a0 ,a1)))]
      [`(let ([,x (< ,a0 ,a1)]) ,e+)
       (extend (expr->blocks e+ current-block) current-block `(assign ,x (< ,a0 ,a1)))]
      [`(let ([,x (eq? ,a0 ,a1)]) ,e+)
       (extend (expr->blocks e+ current-block) current-block `(assign ,x (eq? ,a0 ,a1)))]
      [(? atom? a)
       (hash current-block `(return ,a))]
      [`(if ,a ,e-t ,e-f)
       (define l-t (gensym 'lab))
       (define l-f (gensym 'lab))
       (define h (merge (expr->blocks e-t l-t) (expr->blocks e-f l-f)))
       (hash-set h current-block `(if (eq? ,a #f) (goto ,l-f) (goto ,l-t)))]))
  (match p
    [`(program ,info ,anf)
     `(program ,info ,(expr->blocks anf (entry-symbol)))]))

(define (anf-convert p)
  (define (convert-expr e k)
    (match e
      [(? fixnum? n) (k n)]
      [(? boolean? b) (k b)]
      ['(read)
       (let ([x (gensym 'read)])
         `(let ([,x (read)]) ,(k x)))]
      [(? symbol? x) (k x)]
      [`(- ,e) (convert-expr e
                             (lambda (atom)
                               (let ([x (gensym)])
                                 `(let ([,x (- ,atom)]) ,(k x)))))]
      [`(not ,e) (convert-expr e
                               (lambda (atom)
                                 (let ([x (gensym)])
                                   `(let ([,x (not ,atom)]) ,(k x)))))]
      [`(,(? cmp? c) ,e0 ,e1)
       (convert-expr e0
                     (λ (a0)
                       (convert-expr e1
                                     (λ (a1)
                                       (define x (gensym))
                                       `(let ([,x (,c ,a0 ,a1)]) ,(k x))))))]
      [`(+ ,e0 ,e1)
       (convert-expr e0
                     (λ (a0)
                       (convert-expr e1
                                     (λ (a1)
                                       (let ([x (gensym '+)])
                                         `(let ([,x (+ ,a0 ,a1)]) ,(k x)))))))]
      [`(if ,e0 ,e1 ,e2)
       (convert-expr
        e0
        (λ (a-g)
          `(if ,a-g ,(convert-expr e1 k) ,(convert-expr e2 k))))]
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
      [(? boolean? b) b]
      [`(read) e]
      [`(- ,e+) `(- ,(rename e+ assignment))]
      [`(- ,e0 ,e1) `(- ,(rename e0 assignment) ,(rename e1 assignment))]
      [`(+ ,e0 ,e1) `(+ ,(rename e0 assignment) ,(rename e1 assignment))]
      [(? symbol? x) (hash-ref assignment x x)]
      [`(if ,e0 ,e1 ,e2) `(if ,(rename e0 assignment)
                              ,(rename e1 assignment)
                              ,(rename e2 assignment))]
      [`(,(? cmp? c) ,e0 ,e1) `(,c ,(rename e0 assignment) ,(rename e1 assignment))]
      [`(and ,e0 ,e1) `(and ,(rename e0 assignment) ,(rename e1 assignment))]
      [`(or ,e0 ,e1)  `(or ,(rename e0 assignment) ,(rename e1 assignment))]
      [`(not ,e) `(not ,(rename e assignment))]
      [`(if ,e0 ,e1 ,e2)
       `(if ,(rename e0 assignment) ,(rename e1 assignment) ,(rename e2 assignment))]
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

;; Takes p and...
;; - Removes binary minus
;; - Removes and/or (using if)
;; - Removes all binary comparators except < and eq?
(define (shrink p)
  (define (h e)
    (match e 
      ;; base cases
      [(? symbol?) e]
      [(? number?) e]
      [#t #t]
      [#f #f]
      [`(read) '(read)]
      [`(+ ,e0 ,e1) `(+ ,(h e0) ,(h e1))]
      [`(- ,e0 ,e1) `(+ ,(h e0) (- ,(h e1)))]
      [`(- ,e) `(- ,(h e))]
      [`(and ,e0 ,e1) `(if ,(h e0) ,(h e1) #f)]
      [`(or ,e0 ,e1) `(if ,(h e0) #t ,(h e1))]
      [`(<= ,e0 ,e1) (h `(or (< ,e0 ,e1) (eq? ,e0 ,e1)))]
      [`(> ,e0 ,e1) (h `(< ,e1 ,e0))]
      [`(>= ,e0 ,e1) (h `(or (< ,e1 ,e0) (eq? ,e0 ,e1)))]
      [`(eq? ,e0 ,e1) `(eq? ,(h e0) ,(h e1))]
      [`(if ,e0 ,e1 ,e2) `(if ,(h e0) ,(h e1) ,(h e2))]
      [(list es ...) (map h es)]))
  (match p
    [`(program ,exp)
     ;; empty info
     `(program ,(h exp))]))

;; Type checking is separated into two functions:

;; Translate an expression to its corresponding type.
;;       e : R2-exp?
;;     env : hash from symbol -> R2-type?
;; 
;; If there is a type ERORR, you should raise an exception, but you
;; *MUST* raise an exception using the 'type-error tag, for example:
;;      (error type-error-tag "Expected integer, got boolean")
;; Note that type-error-tag is defined in irs.rkt--you are encouraged
;; to make use of it. 
(define (expr->type e env)
  (define (expect-type e typ k)
    (if (equal? (expr->type e env) typ) 
        (k)
        (error type-error-tag (format "~a: Expected type ~a" (pretty-format e) (symbol->string typ)))))
  (match e
    [#t 'Bool] 
    [#f 'Bool] 
    [(? fixnum? n) 'Int]
    [`(read) 'Int] ;; assume (read) returns int
    [`(- ,(? R2-exp? e)) (expect-type e 'Int (λ () 'Int))]
    [`(- ,(? R2-exp? e0) ,(? R2-exp? e1))
     (expect-type e0 'Int
                  (λ ()
                    (expect-type e1 'Int
                                 (λ () 'Int))))]
    [`(+ ,(? R2-exp? e0) ,(? R2-exp? e1))
     (expect-type e0 'Int
                  (λ ()
                    (expect-type e1 'Int
                                 (λ () 'Int))))]
    [`(and ,(? R2-exp? e0) ,(? R2-exp? e1)) 
     (expect-type e0 'Bool
                  (λ ()
                    (expect-type e1 'Bool
                                 (λ () 'Bool))))]
    [`(or ,(? R2-exp? e0) ,(? R2-exp? e1))
     (expect-type e0 'Bool
                  (λ ()
                    (expect-type e1 'Bool
                                 (λ () 'Bool))))]
    [`(if ,(? R2-exp? e-g) ,(? R2-exp? e-t) ,(? R2-exp? e-f))
     (expect-type e-g
                  'Bool
                  (λ ()
                    (define t (expr->type e-t env))
                    (expect-type e-f t (λ () t))))]
    [`(not ,e)
     (expect-type e 'Bool (λ () 'Bool))] 
    [`(,(? cmp? cmp) ,(? R2-exp? e0) ,(? R2-exp? e1))
     (expect-type e0 'Int (λ () (expect-type e1 'Int (λ () 'Bool))))]
    [(? symbol? x) (hash-ref env x (λ () (error type-error-tag "Undefined variable")))]
    [`(let ([,x ,e]) ,e-b)
     (define t (expr->type e env))
     (expr->type e-b (hash-set env x t))]))

;; Typecheck a program: a thin wrapper around expr->type. 
(define (typecheck p)
  (match-define `(program ,e) p)
  ;; possibly throw type error
  (define program-type (expr->type e (hash)))
  ;; success, if we got here the program typechecked
  p)
