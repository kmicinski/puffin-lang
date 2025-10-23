#lang racket

;; CIS531 Fall '25 Project 1
;; Compiling LVar -> x86-64
(require "irs.rkt") ;; Definition of each IR (please read)
(require "system.rkt") ;; System-specific details

(provide (all-defined-out)) ;; export everything for testing

;; The compiler is designed in passes, which go:
;;
;; --> R2? -- Source program
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



;; 
;; Type checking is separated into two functions: expr->type and
;; typecheck. If type checking fails, an exception is thrown.
;; 

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
  ;; helper function, typechecks e, expects type typ, and continues by
  ;; invoking the zero-argument function k.
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
     'todo]
    [`(+ ,(? R2-exp? e0) ,(? R2-exp? e1))
     'todo]
    [`(and ,(? R2-exp? e0) ,(? R2-exp? e1)) 
     'todo]
    [`(or ,(? R2-exp? e0) ,(? R2-exp? e1))
     'todo]
    [`(if ,(? R2-exp? e-g) ,(? R2-exp? e-t) ,(? R2-exp? e-f))
     'todo]
    [`(not ,e)
     'todo] 
    [`(,(? cmp? cmp) ,(? R2-exp? e0) ,(? R2-exp? e1))
     'todo]
    [(? symbol? x) 'todo]
    [`(let ([,x ,e]) ,e-b)
     'todo]))

;; Typecheck a program: a thin wrapper around expr->type. 
(define (typecheck p)
  (match-define `(program ,e) p)
  ;; possibly throw type error
  (define program-type (expr->type e (hash)))
  ;; success, if we got here the program typechecked
  p)

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
      [`(and ,e0 ,e1) 'todo]
      [`(or ,e0 ,e1) 'todo]
      [`(<= ,e0 ,e1) 'todo]
      [`(> ,e0 ,e1) 'todo]
      [`(>= ,e0 ,e1) 'todo]
      [`(eq? ,e0 ,e1) 'todo]
      [`(if ,e0 ,e1 ,e2) 'todo]))
  (match p
    [`(program ,exp)
     ;; empty info
     `(program ,(h exp))]))

;; must handle new cases, booleans, etc.
(define (uniqueify p)
  (define (rename e assignment)
    (match e
      ;; ... other cases todo...
      [`(if ,e0 ,e1 ,e2) 'todo]
      [`(,(? cmp? c) ,e0 ,e1) 'todo]
      [`(and ,e0 ,e1) 'todo]
      [`(or ,e0 ,e1)  'todo]
      [`(not ,e) 'todo]))
  (match p
    [`(program ,exp)
     ;; empty info
     `(program () ,(rename exp (hash)))]))

;; ANF Conversion--handle new cases, think carefully about if
(define (anf-convert p)
  (define (convert-expr e k)
    (match e
      [(? fixnum? n) (k n)]
      [(? boolean? b) (k b)]
      ['(read)
       (let ([x (gensym 'read)])
         `(let ([,x (read)]) ,(k x)))]
      [(? symbol? x) (k x)]
      [`(- ,e) 'todo]
      [`(not ,e) 'todo]
      [`(,(? cmp? c) ,e0 ,e1)
       'todo]
      [`(+ ,e0 ,e1)
       'todo]
      [`(if ,e0 ,e1 ,e2)
       'todo]
      [`(let ([,x ,e]) ,e-b)
       'todo]))
  (match p
    [`(program ,info ,e)
     `(program ,info ,(convert-expr e (lambda (x) x)))]))

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
        ;; ...other cases todo...
        [`(seq (assign ,x (< ,a0 ,a1)) ,rst)
         'todo]
        [`(seq (assign ,x (eq? ,a0 ,a1)) ,rst)
         'todo]
        ;; cmp is {eq?, <}
        [`(if (,cmp ,a0 ,a1) (goto ,l0) (goto ,l1))
         'todo]))
    (h c1))
  ;; the input is C0: h is (hash 'start '(let ...))
  (match p
    [`(program ,info ,h)
     (define blocks (hash-set 
                     (foldl (λ (block acc) (hash-set acc block (c1->block (hash-ref h block)))) h (hash-keys h))
                     (conclusion-block-name)
                     '())) ;; also add an empty conclusion block
     `(program ,info ,blocks)]))

;; I provide this one for you, again--I do not find it especially
;; challenging / interesting except that we have to work over all
;; blocks
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
  ;; merge two hashes, assume no common keys--useful in handling if
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
      ;; ... other cases todo...
      [`(if ,a ,e-t ,e-f)
       ;; basic idea: call expr->blocks on e-t and e-f with a
       ;; freshly-generated label. Both of these calls return hashes,
       ;; which you can combine using `merge`, and then you can
       ;; generate an `if` expression which uses `goto` on both
       ;; branches.
       (hash current-block `(if (eq? ,a #f) 'todo 'todo))]))
  (match p
    [`(program ,info ,anf)
     `(program ,info ,(expr->blocks anf (entry-symbol)))]))

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
  ;; instructions in a bad configuration, which will be cleaned up in
  ;; patch-instructions.
  (define (h block)
    (match block
      ;; ... other cases todo ...
      ['() '()]))
  (define blocks+ (foldl (λ (blk acc)
                           (hash-set acc blk (h (hash-ref blocks blk)))) blocks (hash-keys blocks)))
  `(program ,var->stackloc ,blocks+))

;; walks over instructions and replaces invalid movqs, where both
;; operands are indirects (offsets of %rax). In x86_64, we *cannot*
;; have both arguments in registers, so
(define (patch-instructions p)
  (define (patch-tail block)
    (match block
      ['() '()]
      ;; first move into %rax, then move %rax into i1(%r1)
      [`((movq (deref (reg ,r0) ,i0) (deref (reg ,r1) ,i1)) ,rest ...)
       'todo]
      ;; new ...
      [`((movzbq (byte-reg ,r) (deref (reg ,r1) ,i1)) ,rest ...)
       'todo]
      ;; new ...
      [`((cmpq ,a (deref (reg ,r1) ,i1)) ,rest ...)
       'todo]
      ;; new ...
      [`((cmpq ,a (imm ,d)) ,rest ...)
       'todo]
      [`(,instr ,rest ...)
       `(,instr ,@(patch-tail rest))]))
  (match p
    [`(program ,info ,blocks)
     (define blocks+ (foldl (λ (blk acc) (hash-set acc blk (patch-tail (hash-ref blocks blk)))) blocks (hash-keys blocks)))
     `(program ,info ,blocks+)]))

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
     ;; Consider using a conclusion block as well, that prints the
     ;; value assuming it is in %rax and exits with return value 0
     ;;
     ;; TODO: extend blocks so that you write the (entry-symbol)
     ;; and also the conclusion symbol
     `(program ,locals ,blocks)]))

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
      [`(xorq ,src ,dst) 'todo]
      ;; others ...
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
      ;; walk over all blocks, render each block by calling
      ;; `render-block` with the appropriate name. If the block's
      ;; name is main (or any function name), then make sure you call
      ;; `(rt-sym ...)`
      ";; todo -- erase this and replace with answer")]))
