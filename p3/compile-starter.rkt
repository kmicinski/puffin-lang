#lang racket

;; CIS531 Fall '25 Project 4
;; Compiling Loops / set! -> x86-64
(require "irs.rkt") ;; Definition of each IR (please read)
(require "system.rkt") ;; System-specific details

(provide (all-defined-out)) ;; export everything for testing

;; The compiler is designed in passes, which go:
;;
;; --> R3? -- Source program
;; |
;; +-> shrunk-R3? -- Shrunken R3 (removes several forms)
;; |
;; +-> unique-source-tree? -- every bound identifier is written exactly once
;; |
;; +-> assignment-converted-program? -- eliminates set!, replaces variable references by vector-ref
;; |
;; +-> anf-program? -- A-Normal form (flattening nested expressions)
;; |
;; +-> c2-program? -- The C2 IR: blocks of sequences of commands, if, and gotos
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


;; Takes p and...
;; - Removes binary minus
;; - Removes and/or (using if)
;; - Removes all binary comparators except < and eq?
;; - Rewrites (while e-g e-b) to (let ([_ (while e-g e-b)]) (void))
;; - Handles `(begin e0 e-rest ...) to (let ([_ e0]) (begin e-rest ...))
;; - let* becomes nested let...
;; - Handles new forms...
(define (shrink p)
  (define (h e)
    (match e
      ;; base cases
      [`(void) e] ;; new 
      ;; 
      ;; ...
      ;; 
      ;; NEW
      [`(begin ,e0) 'todo]
      [`(begin ,e0 ,e-rest ...) 'todo]
      [`(set! ,x ,e) 'todo]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       'todo]
      [`(make-vector ,i) e] ;; just e... i is constant 
      [`(vector-ref ,e ,i) 'todo]
      [`(vector-set! ,e ,i ,e-v) 'todo]
      [`(while ,e-g ,e-b) 'todo]
      [`(let* ([,x ,e0]) ,e-b)
       `(let ([,x ,(h e0)]) ,(h e-b))] ;; new -- giving it
      [`(let* ([,x ,e0] ,rest ...) ,e-b)
       'todo]))
  (match p
    [`(program ,exp)
     ;; empty info
     `(program ,(h exp))]))

;; must handle new cases, booleans, etc.
(define (uniqueify p)
  (define (rename e assignment)
    (match e
      [`(void) e]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       'todo]
      ;; Put general case later...
      [`(let ([,x ,e]) ,e-b)
       'todo]
      [`(make-vector ,i) e]
      [`(vector-ref ,e ,i) 'todo]
      [`(vector-set! ,e ,i ,e-v) 'todo]
      [`(set! ,x ,e) 'todo]))
  (match p
    [`(program ,exp)
     ;; empty info
     `(program () ,(rename exp (hash)))]))

;; Assignment conversion:
;; - Replace every let-binding with an allocation:
;;   (let ([x e]) e-b) => (let ([x (make-vector 1)]) (let ([_ (vector-set! x 0 e))) e-b))
;; - Replace every variable reference `x` by a `(vector-ref x 0)`
;; - Replace (set! x e) by `(vector-set! x 0 e)`
(define (assignment-convert p)
  (define (a-c e)
    (match e
      [(? boolean? b) e]
      [(? fixnum? n)  e]
      [`(read)        e]
      ['(void)        e]
      ;; other forms...
      ;; vars/let
      [(? symbol? x) `(vector-ref ,x 0)] ;; giving you the answer to this one...
      ;; new forms
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       'todo]
      [`(let ([_ ,e]) ,e-b)
       'todo]
      [`(set! ,x ,e+)
       'todo]
      [`(vector-ref ,e ,i)
       'todo]
      [`(vector-set! ,e ,i ,e-v)
       'todo]
      [`(make-vector ,i) e]
      ;; put original let last to avoid matching _
      [`(let ([,x ,e]) ,e-b)
       'todo]))
  (match p
    [`(program () ,exp)
     `(program () ,(a-c exp))]))

;; ANF Conversion--handle new cases, think carefully about if
(define (anf-convert p)
  (define (convert-expr e k)
    (match e
      ;;
      ;; ... old forms...
      ;; 

      ;; new forms
      [`(let ([_ (vector-set! ,e0 ,idx ,e1)]) ,e-b)
       'todo]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       ;; I'll give you this one... while should only come in this form...
       `(let ([_ (while ,(convert-expr e-g (λ (a) a)) ,(convert-expr e-b (λ (a) a)))])
          ,(convert-expr e-r k))]
      ;; these are mostly standard
      [`(make-vector ,e)
       'todo]
      [`(vector-ref ,e0 ,e1)
       'todo]
      [`(vector-set! ,e0 ,i ,e1)
       'todo]
      ;; put let last to avoid matching (let ([_ ...]) ...)
      [`(let ([,x ,e]) ,e-b)
       'always-put-general-let-last]))
  (match p
    [`(program ,info ,e)
     `(program ,info ,(convert-expr e (lambda (x) x)))]))

;; Convert p (in ANF) to  C-style IR consisting consisting of labeled blocks
(define (explicate-control p)
  ;; merge two hashes, assume no common keys
  (define (merge h0 h1)
    (foldl (λ (k0 h1) (hash-set h1 k0 (hash-ref h0 k0))) h1 (hash-keys h0)))
  (define (atom? a) (or (fixnum? a) (symbol? a) (boolean? a) (equal? a '(void))))
  (define (extend h label instruction)
    (hash-set h label `(seq ,instruction ,(hash-ref h label))))
  ;; basic idea: return a hash which maps blocks to a label name
  ;;
  ;; k is a continuation which gets called on the ultimate return value
  (define (expr->blocks e current-block k)
    (match e
      ;; ... other cases...
      
      ;; NEW cases
      [`(let ([,x (make-vector ,a)]) ,e+)
       'todo]
      [`(let ([_ (vector-set! ,x ,i ,v)]) ,e+)
       'todo]
      [`(let ([,x (void)]) ,e+)
       ;; I'll give you this one...
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x (void)))]
      
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       ;; Basic idea: generate three new labels, l-rest, l-header, and l-body
       ;; then use expr->blocks pass a continuation 
       
       ;; for example, as part of my solution I did....
       #;
       (define header-blocks
         (expr->blocks e-g
                       l-header
                       (λ (a-g) `(if (eq? ,a-g #f) (goto ,l-rest) (goto ,l-body)))))
       'todo]
      [`(let ([,x (vector-ref ,e-v ,i)]) ,e+)
       'todo]
      [`(vector-set! ,x ,i ,v)
       ;; giving this one away as a starter...
       (hash current-block `(seq (vector-set! ,x ,i ,v) ,(k '(void))))]
      
      
      ;; NEW: where k is actually invoked (this was previously a `return`)
      [(? atom? a)
       (hash current-block (k a))]))
  (match p
    [`(program ,info ,anf)
     `(program ,info ,(expr->blocks anf (entry-symbol) (lambda (a) `(return ,a))))]))

;; The output of this pass is almost x86, but there will still be an
;; issue: we won't be using *registers*, we'll keep using variables
;; for now.
(define (select-instructions p)
  ;; Translate ANF-ified C0 to a block of instructions
  (define (c1->block c1)
    (define (h-atom a)
      (match a
        ['(void)       `(imm ,(void-magic-value))]
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

        ;;
        ;; ... preexisting cases...
        ;; 


        ;; NEW
        [`(seq (assign ,x (void)) ,rest)
         ;; Advice: use (void-magic-value) in system.rkt
         'todo]
        [`(seq (assign ,x (make-vector ,i)) ,rest)
         ;; moveq i to %rdi, then callq make_vector (1 argument), then movq rax to x
         'todo]
        [`(seq (assign ,x (vector-ref ,a ,i)) ,rest)
         ;; movq a to rax, then movq OFF(%rax) to x (where OFF is (i+1)*8)
         'todo]
        [`(seq (vector-set! ,a0 ,i ,a-v) ,rest)
         ;; movq a to rax, then move a-v to OFF(%rax), where OFF is (i+1)*8
         'todo]

        ;; two final cases I already did for you...
        ['(void) '()] 
        [`(goto ,l)
         `((goto ,l))]))

    (h c1))
  ;; the input is C0: h is (hash 'start '(let ...))
  (match p
    [`(program ,info ,h)
     (define blocks (hash-set
                     (foldl (λ (block acc) (hash-set acc block (c1->block (hash-ref h block)))) h (hash-keys h))
                     (conclusion-block-name)
                     '())) ;; also add an empty conclusion block
     `(program ,info ,blocks)]))

;; I did this one for you again, because it is a very small pass...
(define (uncover-locals p)
  (define (h seq)
    (match seq
      [`(return ,_) (set)]
      [`(goto ,l) (set)]
      [`(if (,cmp ,a0 ,a1) (goto ,l0) (goto ,l1)) (set)]
      [`(set! ,_ ,_) (set)] ;; must be introduced by a let
      [`(seq (vector-set! ,x ,_ ,_) ,rest)
       (set-add (h rest) x)]
      [`(seq (assign ,x0 ,_) ,rest)
       (set-add (h rest) x0)]))
  (match p
    [`(program () ,blocks)
     (define locals (foldl (λ (block acc) (set-union acc (h (hash-ref blocks block))))
                           (set)
                           (hash-keys blocks)))
     `(program ,locals ,blocks)]))


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
      ;; other cases...
      [`(,instr0 ,rest ...)
       `(,instr0 ,@(h rest))]))
  
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
      [`((movzbq (byte-reg ,r) (deref (reg ,r1) ,i1)) ,rest ...)
       'todo]
      [`((cmpq ,a (deref (reg ,r1) ,i1)) ,rest ...)
       'todo]
      [`((cmpq ,a (imm ,d)) ,rest ...)
       'todo]
      ;; otherwise, ignore...
      [`(,instr ,rest ...)
       `(,instr ,@(patch-tail rest))]))
  (match p
    [`(program ,info ,blocks)
     (define blocks+ (foldl (λ (blk acc) (hash-set acc blk (patch-tail (hash-ref blocks blk)))) blocks (hash-keys blocks)))
     `(program ,info ,blocks+)]))

;; adds the prelude and conclusion to each of the functions in the program
;; I have written all of this one for you this time--no need to modify it
(define (prelude-and-conclusion p)
  ;; ensure the stack is aligned
  (define (align16 n) ;; make sure to align %rsp to 16 bytes
    (bitwise-and (+ n 15) (bitwise-not 15)))
  ; clear the low four bits
  (match p
    [`(program ,locals ,blocks)
     ;; negative number, added to %rsp
     (define space-needed (if (empty? (hash-values locals))
                              0
                              (- (align16 (- (apply min (hash-values locals)))))))
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
      ;; other forms here...
      [`(callq ,(? label? l) ,(? nonnegative-integer? num-args))
       ;; must call rt-sym here!
       (format "call ~a" (symbol->string (rt-sym l)))]
      ['(retq) "ret"]
      [`(goto ,l) (format "jmp ~a" (symbol->string  l))]
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
      (format ".globl ~a\n" (rt-sym (entry-symbol)))
      ;; include these for sure
      (runtime-function-externs)
      (foldl (λ (block-name acc) (string-append acc (render-block (hash-ref blocks block-name)
                                                                  (if (function-name? block-name)
                                                                      (rt-sym block-name)
                                                                      block-name))))
             ""
             (hash-keys blocks)))]))
