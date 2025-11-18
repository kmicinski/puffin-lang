#lang racket

;; CIS531 Fall '25 Project 3
;; Compiling R4 -> x86-64
(require "irs.rkt") ;; Definition of each IR (please read)
(require "system.rkt") ;; System-specific details
(require "interpreters.rkt")

(provide (all-defined-out)) ;; export everything for testing

;; The compiler is designed in passes, which go:
;;
;; --> R4/R5? -- Source program (R5 is extra credit)                                         <INPUT>
;; |
;; +-> shrunk-R5? -- Core R4/5 (removes syntactic sugar / extra forms)                       [shrink]
;; |
;; +-> unique-source-tree? -- Every bound identifier is written exactly once                 [uniqueify]
;; |
;; +-> revealed-functions-program? -- Makes all calls explicit via fun-ref and app           [reveal-functions]
;; |
;; +-> assignment-converted-program? -- Eliminates set!; variables become 1-slot vectors     [assignment-convert]
;; |
;; +-> closure-converted-program? -- Lift lambdas to top-level defines, allocate closures    [lift-lambdas]
;; |
;; +-> limited-arity-program? -- Rewrites >6-arg functions to pass the rest in a vector      [limit-functions]
;; |
;; +-> anf-program? -- A-Normal form (flattening nested expressions)                         [anf-convert]
;; |
;; +-> blocks-program? -- (Formerly C2) blocks of sequences of commands, if, gotos, calls    [explicate-control]
;; |
;; +-> locals-program? -- Uncovering local variables for each function                       [uncover-locals]
;; |
;; +-> instr-program? -- Pseudo-x86, flattened blocks of instructions over pseudo-vars       [select-instructions]
;; |
;; +-> homes-assigned-program? -- Assigns variables to stack locations (rbp-relative homes)  [assign-homes]
;; |
;; +-> patched-program? -- Patches illegal x86 forms (e.g., mem-mem moves, bad leaq forms)   [patch-instructions]
;; |
;; +-> x86-64? -- Final x86-64 IR with prologue/epilogue and printing logic                  [prelude-and-conclusion]
;; |
;; +-> string? -- Rendered as GAS assembly text suitable for writing to a .s file            [dump-x86-64]

;; Dump x86-64 code to GAS assmbler
(define (dump-x86-64 p)
  (define functions (list->set (match p [`(program ,_ (define ,_ (,fs ,_ ...) ,_) ...) fs])))
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
      [`(goto ,l) (format "jmp ~a" (symbol->string  l))]
      ['(leave) "leave"]
      ;; NEW forms
      [`(leaq (fun-ref ,f) ,dst) ;; make sure to call (rt-sym f) when rendering f here!
       (format "leaq ~a(%rip), ~a" (rt-sym f) (render-op dst))]
      [`(indirect-callq ,a) (format "callq *~a" (render-op a))]))
  (define (render-block block name)
    (define txt-label (if (set-member? functions name) (format "~a:\n" (rt-sym name)) (format "~a:\n" name)))
    (apply string-append
           (cons txt-label
                 (map (λ (instr) (format "    ~a\n" (render-instr instr))) block))))
  (define (per-defn defn)
    (match-define `(define ,_ (,f ,formals ...) ,blocks) defn)
    (foldl (lambda (k acc) (string-append acc (render-block (hash-ref blocks k) k)))
           ""
           (hash-keys blocks)))
  (match p
    [`(program ,defns ...)
     (string-append
      ;; Tells the ABI that we're OK with non-executable stacks (security enhancement)
      (format ".globl ~a\n" (rt-sym (entry-symbol)))
      ;; include these for sure
      (runtime-function-externs)
      (foldl (λ (defn acc) (string-append acc (per-defn defn)))
             ""
             defns))]))

;; NEW: walks over each definition
;; 
;; - For (entry-symbol), it does the same thing as before--prints the
;; result of evaluating the expression.
;; 

(define (prelude-and-conclusion p)
  (define (align16 n)
    (bitwise-and (+ n 15) (bitwise-not 15)))

  ;; walk over all blocks in a hash and replace '(jmp conclusion) to
  ;; `(jmp ,name)
  (define (rename-conclusion blocks name)
    (define (h instr)
      (match instr
        [`(jmp ,blk) #:when (equal? blk (conclusion-block-name))
         `(jmp ,name)]
        [i i]))
    (foldl (lambda (k acc) (hash-set acc k (map h (hash-ref blocks k))))
           (hash)
           (hash-keys blocks)))
  
  (define (per-defn p)
    (match p
      [`(define ,locals (,f ,args ...) ,blocks)
       ;; negative number, added to %rsp
       (define space-needed (if (empty? (hash-values locals))
                                0
                                (- (align16 (- (apply min (hash-values locals)))))))
       (define start-block (hash-ref blocks f))
       (define new-start-block
         `((pushq (reg rbp))
           (movq (reg rsp) (reg rbp))
           (addq (imm ,space-needed) (reg rsp))
           ,@start-block))
       (define conclusion-block
         (if (equal? f (entry-symbol))
             `(;; move result into %rdi and print_int64 it
               (movq (reg rax) (reg rdi))
               (callq print_int64 0)
               ;; 0 return value (to the terminal/system) into %rax
               (movq (imm 0) (reg rax))
               ;; reinstate stored %rbp
               (movq (reg rbp) (reg rsp))
               (popq (reg rbp))
               ;; transfer back to caller
               (retq))
             ;; else, just return...
             `((movq (reg rbp) (reg rsp))
               (popq (reg rbp))
               (retq))))
       (define my-conclusion-block (gensym 'conclusion))
       (define blocks+ 
         (rename-conclusion
          (hash-set (hash-remove (hash-set blocks f new-start-block)
                                (conclusion-block-name))
                   my-conclusion-block
                   conclusion-block)
          my-conclusion-block))
       ;; change the block name from (conclusion-block-name) to a
       ;; per-definition conclusion. Make sure you use hash-remove to
       ;; clear the previous key from the hash so that it is not
       ;; printed!
       `(define ,locals (,f ,@args) ,blocks+)]))
  (match p
    [`(program ,defns ...)
     `(program ,@(map per-defn defns))]))

;; new:
;; - the destination of leaq must be a register
;; - the argument of 
(define (patch-instructions p)
  (define (patch-tail block)
    (match block
      ['() '()]
      ;; first move into %rax, then move %rax into i1(%r1)
      [`((movq (deref (reg ,r0) ,i0) (deref (reg ,r1) ,i1)) ,rest ...)
       `((movq (deref (reg ,r0) ,i0) (reg r11))
         (movq (reg r11) (deref (reg ,r1) ,i1))
         ,@(patch-tail rest))]
      [`((movzbq (byte-reg ,r) (deref (reg ,r1) ,i1)) ,rest ...)
       `((movzbq (byte-reg ,r) (reg rax))
         (movq (reg rax) (deref (reg ,r1) ,i1))
         ,@(patch-tail rest))]
      [`((cmpq ,a (deref (reg ,r1) ,i1)) ,rest ...)
       `((movq (deref (reg ,r1) ,i1) (reg rax))
         (cmpq ,a (reg rax))
         ,@(patch-tail rest))]
      [`((cmpq ,a (imm ,d)) ,rest ...)
       `((movq (imm ,d) (reg rax))
         (cmpq ,a (reg rax))
         ,@(patch-tail rest))]
      [`((leaq ,src (reg ,r)) ,rest ...)
       `((leaq ,src (reg ,r)) ,@(patch-tail rest))]
      [`((leaq ,src ,dst) ,rest ...)
       `((leaq ,src (reg rax)) 
         (movq (reg rax) ,dst)
         ,@(patch-tail rest))]
      [`(,instr ,rest ...)
       `(,instr ,@(patch-tail rest))]))
  (define (per-defn defn)
    (match-define `(define ,info (,f ,formals ...) ,blocks) defn)
    (define blocks+
      (foldl (lambda (k a) (hash-set a k (patch-tail (hash-ref blocks k))))
             (hash)
             (hash-keys blocks)))
    `(define ,info (,f ,@formals) ,blocks+))
  (match p
    [`(program ,defns ...)
     `(program ,@(map per-defn defns))]))

;; Take variables into either the stack/registers
(define (assign-homes p)
  (pretty-print p)
  ;; traverse each instruction in the block to replace (var x) with
  ;; the appropriate stack position. Note: this will leave some
  ;; instructions
  (define (per-defn definition)
    (match-define `(define ,locals (,f ,args ...) ,blocks) definition)
    (print definition)
    (define var->stackloc
      (let ([l (set->list locals)])
        (foldl (lambda (v i h) (hash-set h v (* -8 i))) (hash) l (range 1 (add1 (length l))))))
    ;; map (var x) to its home (an offset of rbp)
    (define (home a)
      (match a
        [`(var ,x) `(deref (reg rbp) ,(hash-ref var->stackloc x))]
        [`(imm ,i) a]
        [`(reg ,r) a]
        [`(byte-reg ,al) a]
        [`(deref ,rest ...) a]))    
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
        [`((jmp ,l) ,rest ...)
         `((jmp ,l) ,@(h rest))]
        [`((jmp-if ,cc ,l) ,rest ...)
         `((jmp-if ,cc ,l) ,@(h rest))]
        [`((set ,cc ,a) ,rest ...)
         `((set ,cc ,a) ,@(h rest))]
        [`((goto ,l) ,rest ...) `((goto ,l) ,@(h rest))]
        [`((xorq ,a0 ,a1) ,rest ...) `((xorq ,(home a0) ,(home a1)) ,@(h rest))]
        ;; new
        [`((indirect-callq ,a) ,rest ...)
         `((indirect-callq ,(home a)) ,@(h rest))]
        [`((callq ,f ,i) ,rest ...)
         `((callq ,f ,i) ,@(h rest))]
        [`((leaq (fun-ref ,f) ,a) ,rest ...)
         `((leaq (fun-ref ,f) ,(home a)) ,@(h rest))]))
    (define blocks+ (foldl (λ (blk acc)
                           (hash-set acc blk (h (hash-ref blocks blk)))) blocks (hash-keys blocks)))
    `(define ,var->stackloc (,f ,@args) ,blocks+))
  (match p
    [`(program ,defns ...)
     `(program ,@(map per-defn defns))]))


;; The output of this pass is almost x86, but there will still be an
;; issue: we won't be using *registers*, we'll keep using variables
;; for now.
;; 
;; NEW: need to handle fun-ref as an atom
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
           ,@(h rest))]
        [`(seq (assign ,x (void)) ,rest)
         `((movq (imm 0) (var ,x))
           ,@(h rest))]
        [`(seq (assign ,x (make-vector ,i)) ,rest)
         `((movq (imm ,i) (reg rdi))
           (callq make_vector 1)
           (movq (reg rax) (var ,x))
           ,@(h rest))]
        [`(seq (assign ,x (vector-ref ,a ,i)) ,rest)
         `((movq ,(h-atom a) (reg rax))
           (movq (deref (reg rax) ,(* 8 (+ i 1))) (var ,x))
           ,@(h rest))]
        [`(seq (vector-set! ,a0 ,i ,a-v) ,rest)
         `((movq ,(h-atom a0) (reg rax))
           (movq ,(h-atom a-v) (deref (reg rax) ,(* 8 (+ 1 i))))
           ,@(h rest))]
        ['(void) '()]
        [`(goto ,l)
         `((goto ,l))]
        ;; new
        [`(seq (assign ,x (fun-ref ,f)) ,rest)
         `((leaq (fun-ref ,f) (var ,x))
           ,@(h rest))]
        ;; non-tail application form:
        ;; - move each argument into a register in the order %rdi, %rsi, %rdx, %rcx, %r8, %r9
        ;; - Generate an `(indirect-callq ,fun) instruction (we will render this later)
        ;; - movq the result (left in rax) into the lhs
        [`(seq (assign ,lhs (app ,a-f ,args ...)) ,next)
         (define (copy-arguments remaining-args remaining-registers)
           (match remaining-args
             ['() `()]
             [`(,a . ,rst)
              `((movq ,(h-atom a) (reg ,(first remaining-registers))) ,@(copy-arguments rst (rest remaining-registers)))]))
         `(,@(copy-arguments args (argument-registers-list))
           (indirect-callq ,(h-atom a-f))
           (movq (reg rax) (var ,lhs))
           ,@(h next))]))
    (h c1))

  ;; per-defn here needs to build blocks+, the transformed blocks, and
  ;; also needs to add a little bit of code to the beginning of the
  ;; first block to copy the arguments from registers to their
  ;; respective locations
  (define (per-defn defn)
    (match-define `(define ,locals (,f ,args ...) ,blocks) defn)
    (define blocks+ (hash-set
                     (foldl (λ (block acc) (hash-set acc block (c1->block (hash-ref blocks block)))) (hash) (hash-keys blocks))
                     (conclusion-block-name)
                     '()))
    (define entry (hash-ref blocks+ f))
    (define moves
      (map (λ (a r) `(movq (reg ,r) (var ,a)))
           args (take (argument-registers-list) (length args))))
    (define blocks++
      (hash-set blocks+ f (append moves entry)))
    `(define ,locals (,f ,@args) ,blocks++))
  ;; the input is C0: h is (hash 'start '(let ...))
  (match p
    [`(program ,defns ...)
      ;; also add an empty conclusion block
     `(program ,@(map per-defn defns))]))

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
  (define (per-defn definition)
    (match definition
      [`(define (,fname ,formals ...) ,blocks)
       (define locals (set-union (list->set formals)
                                 (foldl (λ (block acc) (set-union acc (h (hash-ref blocks block))))
                                        (set)
                                        (hash-keys blocks))))
       `(define ,locals (,fname ,@formals) ,blocks)]))
  (match p
    [`(program ,definitions ...)
     `(program ,@(map per-defn definitions))]))

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
      [`(let ([,x ,(? boolean? b)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x ,b))]
      [`(let ([,x ,(? fixnum? n)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x ,n))]
      [`(let ([,x ,(? symbol? y)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x ,y))]
      [`(let ([,x (read)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x (read)))]
      [`(let ([,x (- ,a)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x (- ,a)))]
      [`(let ([,x (not ,a)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x (not ,a)))]
      [`(let ([,x (+ ,a0 ,a1)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x (+ ,a0 ,a1)))]
      [`(let ([,x (< ,a0 ,a1)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x (< ,a0 ,a1)))]
      [`(let ([,x (eq? ,a0 ,a1)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x (eq? ,a0 ,a1)))]
      [`(let ([,x (make-vector ,a)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x (make-vector ,a)))]
      [`(let ([_ (vector-set! ,x ,i ,v)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(vector-set! ,x ,i ,v))]
      [`(let ([,x (void)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x (void)))]
      [`(let ([,x (fun-ref ,f)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x (fun-ref ,f)))]
      [`(let ([,x (app ,a-f ,a-args ...)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x (app ,a-f ,@a-args)))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       (define l-rest (gensym 'rest))
       (define l-header (gensym 'header))
       (define l-body (gensym 'body))
       (define rest-blocks (expr->blocks e-r l-rest k))
       (define body-blocks (expr->blocks e-b l-body (λ (_) `(goto ,l-header))))
       (define header-blocks
         (expr->blocks e-g
                       l-header
                       (λ (a-g) `(if (eq? ,a-g #f) (goto ,l-rest) (goto ,l-body)))))
       (define this-block (hash current-block `(goto ,l-header)))
       (merge
        (merge
         (merge rest-blocks body-blocks)
         header-blocks)
        this-block)]
      [`(let ([,x (vector-ref ,e-v ,i)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x (vector-ref ,e-v ,i)))]
      [`(vector-set! ,x ,i ,v)
       (hash current-block `(seq (vector-set! ,x ,i ,v) ,(k '(void))))]
      [`(if ,a ,e-t ,e-f)
       (define l-t (gensym 'lab))
       (define l-f (gensym 'lab))
       (define true-blocks (expr->blocks e-t l-t k))
       (define false-blocks (expr->blocks e-f l-f k))
       (define all-blocks (merge true-blocks false-blocks))
       (hash-set all-blocks
                 current-block ;; the current block's label
                 `(if (eq? ,a #f)
                      ;; take the false branch
                      (goto ,l-f)
                      ;; take the true branch...
                      (goto ,l-t)))]
      [(? atom? a)
       (hash current-block (k a))]))
  (define (per-defn definition)
    (match definition
      [`(define (,fname ,formals ...) ,e-body)
       `(define (,fname ,@formals) ,(expr->blocks e-body fname (lambda (a) `(return ,a))))]))
  (match p
    [`(program ,defns ...)
     `(program ,@(map per-defn defns))]))

(define (anf-convert p)
  (define (convert-expr e k)
    (match e
      [(? fixnum? n) (k n)]
      [(? boolean? b) (k b)]
      ['(void) (k e)]
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
      [`(let ([_ (vector-set! ,e0 ,idx ,e1)]) ,e-b)
       (convert-expr e0 (lambda (a-vec)
                          (convert-expr e1 (lambda (a-val)
                                             `(let ([_ (vector-set! ,a-vec ,idx ,a-val)]) ,(convert-expr e-b k))))))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       `(let ([_ (while ,(convert-expr e-g (λ (a) a)) ,(convert-expr e-b (λ (a) a)))])
          ,(convert-expr e-r k))]
      [`(make-vector ,e)
       (convert-expr e (lambda (atom)
                         (define vec-a (gensym 'vec))
                         `(let ([,vec-a (make-vector ,atom)])
                            ,(k vec-a))))]
      [`(vector-ref ,e0 ,e1)
       (convert-expr e0
                     (λ (a0)
                       (convert-expr e1 (λ (a1)
                                          (define ref (gensym 'ref))
                                          `(let ([,ref (vector-ref ,a0 ,a1)]) ,(k ref))))))]
      [`(vector-set! ,e0 ,i ,e1)
       (convert-expr e0
                     (lambda (a0)
                       (convert-expr e1 (lambda (a1)
                                          `(let ([_ (vector-set! ,a0 ,i ,a1)]) ,(k '(void)))))))]
      ;; new forms
      [`(app ,e0 ,e-rest ...)
       (define (handle-rest e-rest as)
         (match e-rest
           ['()
            (let ([x (gensym 'x)])
              `(let ([,x (app ,@(reverse as))]) ,(k x)))]
           [`(,hd . ,rest)
            (convert-expr
             hd
             (lambda (a) (handle-rest rest (cons a as))))]))
       (convert-expr 
        e0
        (lambda (a0) (handle-rest e-rest `(,a0))))]
      [`(fun-ref ,f) 
       (define x (gensym 'funref))
       `(let ([,x (fun-ref ,f)]) ,(k x))]
      ;; let
      [`(let ([,x ,e]) ,e-b)
       (convert-expr e (lambda (atom)
                         `(let ([,x ,atom]) ,(convert-expr e-b k))))]))
  (define (per-defn definition)
    (match definition
      [`(define (,fname ,formals ...) ,e-body)
       `(define (,fname ,@formals) ,(convert-expr e-body (lambda (x) x)))]))
  (match p
    [`(program ,defns ...)
     `(program ,@(map per-defn defns))]))

;; New: map over all the definitions
(define (assignment-convert p)
  ;; box-formals: helper function (use for defines and lambdas)
  ;; transform (lambda (x y z) ...) => (lambda (x123 y235 z523) (let ([x (vector x12)]) ...)
  ;; genformals and realformals are lists of symbols
  ;; e-body is an expression which will be used when no vars left
  (define (box-formals genformals realformals e-body)
    (match genformals
      ['() e-body]
      [`(,x . ,rst)
       `(let ([,(first realformals) (make-vector 1)])
          (let ([_ (vector-set! ,(first realformals) 0 ,x)])
            ,(box-formals rst (rest realformals) e-body)))]))
  (define (a-c e)
    (match e
      [(? boolean? b) e]
      [(? fixnum? n)  e]
      [`(read)        e]
      ['(void)        e]
      [`(- ,e+) `(- ,(a-c e+))]
      [`(+ ,e0 ,e1) `(+ ,(a-c e0) ,(a-c e1))]
      [`(not ,e) `(not ,(a-c e))]
      [`(,(? shrunk-cmp? c) ,e0 ,e1) `(,c ,(a-c e0) ,(a-c e1))]
      ;; control
      [`(if ,e-g ,e-t ,e-f)
       `(if ,(a-c e-g)
            ,(a-c e-t)
            ,(a-c e-f))]
      ;; vars/let
      [(? symbol? x)
       `(vector-ref ,x 0)]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       `(let ([_ (while ,(a-c e-g) ,(a-c e-b))]) ,(a-c e-r))]
      [`(let ([_ ,e]) ,e-b)
       `(let ([_ ,(a-c e)]) ,(a-c e-b))]
      [`(set! ,x ,e+)
       `(vector-set! ,x 0 ,(a-c e+))]
      [`(vector-ref ,e ,i)
       `(vector-ref ,(a-c e) ,i)]
      [`(vector-set! ,e ,i ,e-v)
       `(vector-set! ,(a-c e) ,i ,(a-c e-v))]
      [`(make-vector ,i) e]
      ;; new forms
      [`(fun-ref ,g) e]
      [`(app ,es ...) `(app ,@(map a-c es))]
      [`(lambda (,xs ...) ,e)
       (define new-xs (map (lambda (x) (gensym x)) xs))
       `(lambda ,new-xs ,(box-formals new-xs xs (a-c e)))]
      ;; put original let last to avoid matching _
      [`(let ([,x ,e]) ,e-b)
       `(let ([,x (make-vector 1)])
          (let ([_ (vector-set! ,x 0 ,(a-c e))])
            ,(a-c e-b)))]))
  (define (per-defn definition)
    (match definition
      [`(define (,fname ,formals ...) ,e-body)
       (define genformals (map (lambda (x) (gensym x)) formals))
       `(define (,fname ,@genformals) ,(box-formals genformals formals (a-c e-body)))]))
  (match p
    [`(program ,defns ...)
     `(program ,@(map per-defn defns))]))

;; NEW: pass -- limit-functions
;;
;; This pass rewrites functions of >6 arguments to pass the rest via a
;; vector, rather than the stack (as in x86-64 typically).
;;
;; At this point, we only have toplevel defines--all closures have
;; been eliminted (turned into vector operations) via closure
;; conversion / lambda lifting. Now, we face a bit of a tricky issue:
;; in x86-64, we can pass the first six arguments in registers, but
;; the rest have to go on the stack. Passing things on the stack can
;; complicate some other implementation details (e.g., efficient tail
;; calls via indirect jump), and so this pass indirects the rest
;; through a vector.
(define (limit-functions p)
  (define (walk-expr e)
    (match e
      [(? fixnum? n) e]
      [(? boolean? b) e]
      [`(void) e]
      [`(read) e]
      [`(fun-ref ,f) e]
      [`(- ,e+) `(- ,(walk-expr e+))]
      [`(+ ,e0 ,e1) `(+ ,(walk-expr e0) ,(walk-expr e1))]
      [(? symbol? x) x] ;; variable reference
      [`(if ,e0 ,e1 ,e2) `(if ,(walk-expr e0)
                              ,(walk-expr e1)
                              ,(walk-expr e2))]
      [`(,(? cmp? c) ,e0 ,e1) `(,c ,(walk-expr e0) ,(walk-expr e1))]
      [`(and ,e0 ,e1) `(and ,(walk-expr e0) ,(walk-expr e1))]
      [`(or ,e0 ,e1)  `(or ,(walk-expr e0) ,(walk-expr e1))]
      [`(not ,e) `(not ,(walk-expr e))]
      [`(if ,e0 ,e1 ,e2)
       `(if ,(walk-expr e0) ,(walk-expr e1) ,(walk-expr e2))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       `(let ([_ (while ,(walk-expr e-g) ,(walk-expr e-b))]) ,(walk-expr e-r))]
      [`(let ([,x ,e]) ,e-b)
       `(let ([,x ,(walk-expr e)]) ,(walk-expr e-b))]
      [`(make-vector ,i) e]
      [`(vector-ref ,e ,i) `(vector-ref ,(walk-expr e) ,i)]
      [`(vector-set! ,e ,i ,e-v) `(vector-set! ,(walk-expr e) ,i ,(walk-expr e-v))]
      [`(set! ,x ,e) `(set! ,x ,(walk-expr e))]
      ;; > six arguments
      [`(app ,e-f ,ea0 ,ea1 ,ea2 ,ea3 ,ea4 ,ea5 ,ea-rest ...)
       (define rest-es (cons ea5 ea-rest))
       (define v (gensym 'vec))
       (define (rest-stack es i)
         (match es
           ['()
            `(app ,e-f ,ea0 ,ea1 ,ea2 ,ea3 ,ea4 ,v)]
           [`(,hd . ,rest)
            `(let ([_ (vector-set! ,v ,i ,hd)])
               ,(rest-stack rest (+ i 1)))]))
       (rest-stack rest-es 0)]
      ;; <= six arguments
      [`(app ,e-f ,e-args ...)
       `(app ,e-f ,@(map walk-expr e-args))]))
  (define (per-defn definition)
    (match definition
      [`(define (,fname ,a0 ,a1 ,a2 ,a3 ,a4 ,a5 ,a-rest ...) ,e-body)
       (define args-vec (gensym 'rest-args))
       (define (args-vec-stack formals i)
         (match formals
           ['() (walk-expr e-body)]
           [`(,hd . ,tl)
            `(let ([,hd (vector-ref ,args-vec ,i)])
               ,(args-vec-stack tl (add1 i)))]))
       `(define (,fname ,a0 ,a1 ,a2 ,a3 ,a4 ,args-vec)
          ,(args-vec-stack (cons a5 a-rest) 1))]
      [`(define (,fname ,formals ...) ,e-body)
       `(define (,fname ,@formals) ,(walk-expr e-body))]))
  (match p
    [`(program ,definitions ...)
     `(program ,@(map per-defn definitions))]))

;; NEW: pass -- lift-lambdas
;;
;; Perform closure conversion on the program. Lift every lambda to a
;; top-level function. Basic approach: walk over each definition in
;; the program, accumulate a list of expressions associated with
;; each. A function, `walk-body`, will demand the lifting of body
;; expressions, which happens recursively.
;;
;; I recommend doing bottom-up closure conversion, which involves
;; writing a recursive function which traverses expressions. The
;; function returns `(,converted-expr ,lifted-defns), i.e., a
;; two-element list consisting of the lifted expression and also a set
;; of definitions which resulted from the lifting of lambdas.
(define (lift-lambdas p)
  (pretty-print p)

  (define emitted-defines (set))
  (define (emit-define! defn) (set! emitted-defines (set-add emitted-defines defn)))
  ;; calculate the free variables of an expression e...
  (define (free-vars e)
    (match e
      [(? fixnum? n) (set)]
      [(? boolean? b) (set)]
      [`(void) (set)]
      [`(read) (set)]
      [`(fun-ref ,f) (set)]
      [`(- ,e+) (free-vars e+)]
      [`(+ ,e0 ,e1) (set-union (free-vars e0) (free-vars e1))]
      [(? symbol? x) (set x)]
      [`(if ,e0 ,e1 ,e2) (set-union (free-vars e0) (free-vars e1) (free-vars e2))]
      [`(,(? cmp? c) ,e0 ,e1) (set-union (free-vars e0) (free-vars e1))]
      [`(and ,e0 ,e1) (set-union (free-vars e0) (free-vars e1))]
      [`(or ,e0 ,e1)  (set-union (free-vars e0) (free-vars e1))]
      [`(not ,e) (free-vars e)]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       (set-union (free-vars e-g) (free-vars e-b) (free-vars e-b))]
      [`(let ([,x ,e]) ,e-b)
       (set-union (free-vars e) (set-remove (free-vars e-b) x))]
      [`(make-vector ,i) (set)]
      [`(vector-ref ,e ,i) (free-vars e)]
      [`(vector-set! ,e ,i ,e-v) (set-union (free-vars e) (free-vars e-v))]
      [`(set! ,x ,e) (free-vars e)]
      [`(lambda (,xs ...) ,e) (foldl (lambda (x acc) (set-remove acc x)) (free-vars e) xs)]
      [`(app ,e-f ,e-args ...) (foldl (lambda (s acc) (set-union s acc)) (free-vars e-f) (map free-vars e-args))]))
  (define (walk-expr e)
    (match e
      [(? fixnum? n) e]
      [(? boolean? b) e]
      [`(void) e]
      [`(read) e]
      ;; New: emit a wrapping vector (to make a closure)
      [`(fun-ref ,f) 
       (define v (gensym 'v))
       `(let ([,v (make-vector 1)])
          (let ([_ (vector-set! ,v 0 (fun-ref ,f))])
            ,v))]
      [`(- ,e+) `(- ,(walk-expr e+))]
      [`(+ ,e0 ,e1) `(+ ,(walk-expr e0) ,(walk-expr e1))]
      [(? symbol? x) x] ;; variable reference
      [`(if ,e0 ,e1 ,e2) `(if ,(walk-expr e0)
                              ,(walk-expr e1)
                              ,(walk-expr e2))]
      [`(,(? cmp? c) ,e0 ,e1) `(,c ,(walk-expr e0) ,(walk-expr e1))]
      [`(and ,e0 ,e1) `(and ,(walk-expr e0) ,(walk-expr e1))]
      [`(or ,e0 ,e1)  `(or ,(walk-expr e0) ,(walk-expr e1))]
      [`(not ,e) `(not ,(walk-expr e))]
      [`(if ,e0 ,e1 ,e2)
       `(if ,(walk-expr e0) ,(walk-expr e1) ,(walk-expr e2))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       `(let ([_ (while ,(walk-expr e-g) ,(walk-expr e-b))]) ,(walk-expr e-r))]
      [`(let ([,x ,e]) ,e-b)
       `(let ([,x ,(walk-expr e)]) ,(walk-expr e-b))]
      [`(make-vector ,i) e]
      [`(vector-ref ,e ,i) `(vector-ref ,(walk-expr e) ,i)]
      [`(vector-set! ,e ,i ,e-v) `(vector-set! ,(walk-expr e) ,i ,(walk-expr e-v))]
      [`(set! ,x ,e) `(set! ,x ,(walk-expr e))]
      [`(lambda (,xs ...) ,e)
       ;; first, convert the body
       (define fv (foldl (lambda (x acc) (set-remove acc x)) (free-vars e) xs))
       (define canonical-vars (set->list fv))
       (define converted-expr (walk-expr e))
       (define f-name (gensym 'lam))
       ;; generate a stack in the body to unwrap free vars
       (define (letstack vars-in-order i)
         (match vars-in-order
           [`(,hd . ,tl)
            `(let ([,hd (vector-ref env ,i)])
               ,(letstack tl (+ i 1)))]
           ['()
            converted-expr]))
       (define newly-created-define
         `(define (,f-name env ,@xs)
            ,(letstack canonical-vars 1)))
       (emit-define! newly-created-define)
       ;; now, return an expression that creates the closure...
       (define v (gensym 'clo))
       (define (init-stack vars-in-order i)
         (match vars-in-order
           [`(,hd . ,tl )
            `(let ([_ (vector-set! ,v ,i ,hd)])
               ,(init-stack tl (+ i 1)))]
           ['() ;; ultimate return point, return v
            v]))
       `(let ([,v (make-vector ,(+ (length canonical-vars) 1))])
          (let ([_ (vector-set! ,v 0 (fun-ref ,f-name))]) ;; function name
            ,(init-stack canonical-vars 1)))]
      [`(app ,e-f ,e-args ...) 
       (define clo (gensym 'clo))
       `(let ([,clo ,(walk-expr e-f)])
          (app (vector-ref ,clo 0) ,clo ,@(map (lambda (e) (walk-expr e))  e-args)))]))
  (define (per-defn definition)
    (match definition
      [`(define (,fname ,formals ...) ,e-body)
       ;; add `env` but only to non-main symbols
       (define maybe-env (if (equal? fname (entry-symbol)) '() '(env)))
       `(define (,fname ,@maybe-env ,@formals) ,(walk-expr e-body))]))
  (match p
    [`(program ,definitions ...)
     `(program ,@(map per-defn definitions) ,@(set->list emitted-defines))]))


;; NEW: pass -- reveal-functions
;;
;; Analyze the syntax of p, and collect up a set of available
;; top-level functions. Then, we walk over each body expression, and
;; mark those usages as fnames. Also, ensure that application of
;; user-defined functions is made explicit via `app`.
;;
;; (define (f x) (+ x (g 1))) (define (g y) y) (f 23)
;; => (define (f x) (+ x (app (fun-ref g) 1)))
;;    (define (g y) y)
;;    (app (fun-ref f) 23)

(define (reveal-functions p)
  (define (walk e assignment)
    (match e
      [(? fixnum? n) n]
      [(? boolean? b) b]
      [`(void) e]
      [`(read) e]
      [`(- ,e+) `(- ,(walk e+ assignment))]
      [`(+ ,e0 ,e1) `(+ ,(walk e0 assignment) ,(walk e1 assignment))]
      [(? symbol? x) (hash-ref assignment x x)]
      [`(if ,e0 ,e1 ,e2) `(if ,(walk e0 assignment)
                              ,(walk e1 assignment)
                              ,(walk e2 assignment))]
      [`(,(? cmp? c) ,e0 ,e1) `(,c ,(walk e0 assignment) ,(walk e1 assignment))]
      [`(and ,e0 ,e1) `(and ,(walk e0 assignment) ,(walk e1 assignment))]
      [`(or ,e0 ,e1)  `(or ,(walk e0 assignment) ,(walk e1 assignment))]
      [`(not ,e) `(not ,(walk e assignment))]
      [`(if ,e0 ,e1 ,e2)
       `(if ,(walk e0 assignment) ,(walk e1 assignment) ,(walk e2 assignment))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       `(let ([_ (while ,(walk e-g assignment) ,(walk e-b assignment))]) ,(walk e-r assignment))]
      [`(let ([,x ,e]) ,e-b)
       (let ([assignment+ (hash-set assignment x x)])
         `(let ([,x ,(walk e assignment+)]) ,(walk e-b assignment+)))]
      [`(make-vector ,i) e]
      [`(vector-ref ,e ,i) `(vector-ref ,(walk e assignment) ,i)]
      [`(vector-set! ,e ,i ,e-v) `(vector-set! ,(walk e assignment) ,i ,(walk e-v assignment))]
      [`(set! ,x ,e) `(set! ,x ,(walk e assignment))]
      [`(lambda (,xs ...) ,e) `(lambda ,xs ,(walk e assignment))]
      [`(,e-f ,e-args ...) `(app ,(walk e-f assignment) ,@(map (lambda (e-arg) (walk e-arg assignment)) e-args))]))
  (match p
    [`(program (define (,names ,params ...) ,bodies) ...)
     (define name-set
       (foldl (lambda (name acc) (hash-set acc name `(fun-ref ,name)))
              (hash)
              names))
     `(program
       ,@(map (lambda (name params body) `(define (,name ,@params) ,(walk body name-set)))
              names
              params
              bodies))]))

(define (uniqueify p)
  (define (rename e assignment)
    (match e
      [(? fixnum? n) n]
      [(? boolean? b) b]
      [`(void) e]
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
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       `(let ([_ (while ,(rename e-g assignment) ,(rename e-b assignment))]) ,(rename e-r assignment))]
      [`(let ([_ ,e]) ,e-b)
       `(let ([_ ,(rename e assignment)]) ,(rename e-b assignment))]
      [`(let ([,x ,e]) ,e-b)
       (if (hash-has-key? assignment x)
           (let* ([x+ (gensym x)]
                  [assignment+ (hash-set assignment x x+)])
             `(let ([,x+ ,(rename e assignment)]) ,(rename e-b assignment+)))
           (let ([assignment+ (hash-set assignment x x)])
             `(let ([,x ,(rename e assignment+)]) ,(rename e-b assignment+))))]
      [`(make-vector ,i) e]
      [`(vector-ref ,e ,i) `(vector-ref ,(rename e assignment) ,i)]
      [`(vector-set! ,e ,i ,e-v) `(vector-set! ,(rename e assignment) ,i ,(rename e-v assignment))]
      [`(set! ,x ,e) `(set! ,x ,(rename e assignment))]
      ;; NEW case: for any x ∈ xs, rename any one previously used...
      [`(lambda (,xs ...) ,e-b)
       (let* ([assignment+
               (foldl (lambda (x acc)
                        (if (hash-has-key? acc x)
                            (let ([x+ (gensym x)])
                              (hash-set acc x x+))
                            (hash-set acc x x)))
                      assignment
                      xs)]
              [new-xs (map (lambda (x) (hash-ref assignment+ x)) xs)])
         `(lambda ,new-xs ,(rename e-b assignment+)))]
      [`(,e-f ,e-args ...) `(,(rename e-f assignment) ,@(map (lambda (e-arg) (rename e-arg assignment)) e-args))]))
  (define (per-defn def)
    (match def
      [`(define (,f ,xs ...) ,e-b)
       (define assignment+ (foldl (lambda (x acc)
                                    (if (hash-has-key? acc x)
                                        (let ([x+ (gensym x)]) (hash-set acc x x+))
                                        (hash-set acc x x)))
                                  (hash)
                                  xs))
       `(define (,f ,@xs) ,(rename e-b assignment+))]))
  (match p
    [`(program ,defns ...)
     ;; empty info
     `(program ,@(map per-defn defns))]))

;; Takes p and...
;; - Removes binary minus
;; - Removes and/or (using if)
;; - Removes all binary comparators except < and eq?
(define (shrink p)
  (define (h e)
    (match e
      ;; base cases
      [`(void) e]
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
      [`(not ,e) `(not ,(h e))]
      [`(<= ,e0 ,e1) (h `(or (< ,e0 ,e1) (eq? ,e0 ,e1)))]
      [`(> ,e0 ,e1) (h `(< ,e1 ,e0))]
      [`(< ,e0 ,e1) `(< ,e0 ,e1)]
      [`(>= ,e0 ,e1) (h `(or (< ,e1 ,e0) (eq? ,e0 ,e1)))]
      [`(eq? ,e0 ,e1) `(eq? ,(h e0) ,(h e1))]
      [`(if ,e0 ,e1 ,e2) `(if ,(h e0) ,(h e1) ,(h e2))]
      [`(begin ,e0) (h e0)]
      [`(begin ,e0 ,e-rest ...) (h `(let ([_ ,e0]) (begin ,@e-rest)))]
      [`(set! ,x ,e) `(set! ,x ,(h e))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       `(let ([_ (while ,(h e-g) ,(h e-b))]) ,(h e-r))]
      [`(make-vector ,i) e]
      [`(vector-ref ,e ,i) `(vector-ref ,(h e) ,i)]
      [`(vector-set! ,e ,i ,e-v) `(vector-set! ,(h e) ,i ,(h e-v))]
      [`(while ,e-g ,e-b) `(let ([_ (while ,(h e-g) ,(h e-b))]) (void))]
      [`(let ([,x ,e0]) ,e-b)
       `(let ([,x ,(h e0)]) ,(h e-b))]
      [`(let* ([,x ,e0]) ,e-b)
       `(let ([,x ,(h e0)]) ,(h e-b))]
      [`(let* ([,x ,e0] ,rest ...) ,e-b)
       `(let ([,x ,(h e0)]) ,(h `(let* (,@rest) ,e-b)))]
      ;; new
      [`(lambda (,xs ...) ,e-b)
       `(lambda ,xs ,(h e-b))]
      [`(,e-f ,e-args ...)
       `(,(h e-f) ,@(map h e-args))]))
  (define (per-defn defn)
    (match defn
      [`(define (,f ,xs ...) ,e-b)
       `(define (,f ,@xs) ,(h e-b))]))
  (match p
    [`(program ,defns ... ,expr)
     `(program ,@(cons `(define (main) ,(h expr)) (map per-defn defns)))]))


;; (define ex0
;;   '(program
;;     (define (f x)
;;       (if (eq? x 0) 1 (+ 5 (f (- x 1)))))
;;     (f (read))))

;; #;
;; (pretty-print 
;;  (assignment-convert
;;   (reveal-functions
;;    (uniqueify
;;     (shrink
;;      '(program (define (f x) x)
;;                (f (read)))
;;      #;
;;      '(program (define (f x) (lambda (y) (+ x y)))
;;                (define (g x) (lambda (y) (lambda (z) ((f z) (+ y x)))))
;;                (g (read))))))))

;; (define nq
;;   '(program
;;      ;; =========================
;;      ;; List primitives (as in your ex3)
;;      ;; =========================
;;      (define (is_nil x) (eq? x (void)))

;;      ;; cons cell as 2-element vector: [0] = head, [1] = tail
;;      (define (cons h t)
;;        (let ([c (make-vector 2)])
;;          (let ([_ (vector-set! c 0 h)])
;;            (let ([_ (vector-set! c 1 t)])
;;              c))))

;;      (define (head c) (vector-ref c 0))
;;      (define (tail c) (vector-ref c 1))

;;      ;; absolute value
;;      (define (abs x)
;;        (if (< x 0)
;;            (- 0 x)
;;            x))

;;      ;; =========================
;;      ;; Check if placing a queen in column `col`
;;      ;; is safe w.r.t. existing queens list `qs`.
;;      ;; `qs` holds columns of queens in previous rows,
;;      ;; most recent queen first.
;;      ;; =========================
;;      (define (safe? col qs)
;;        (let ([ok #t])
;;          (let ([d 1])        ;; row-distance from new queen
;;            (let ([lst qs])
;;              (begin
;;                (while (if (is_nil lst) #f #t)
;;                  (begin
;;                    (let ([c (head lst)])
;;                      (if (eq? c col)
;;                          ;; same column -> conflict
;;                          (begin
;;                            (set! ok #f)
;;                            ;; force loop exit
;;                            (set! lst (void)))
;;                          (if (eq? (abs (- c col)) d)
;;                              ;; diag conflict
;;                              (begin
;;                                (set! ok #f)
;;                                (set! lst (void)))
;;                              ;; no conflict with this queen, move on
;;                              (begin
;;                                (set! lst (tail lst))
;;                                (set! d (+ d 1))))))))
;;                ok)))))

;;      ;; =========================
;;      ;; Recursive solver:
;;      ;; row: current row index (0..n)
;;      ;; n: board size
;;      ;; queens: list of columns for previously placed queens
;;      ;;         (most recent row at the head)
;;      ;; Returns:
;;      ;;   - a list of columns for all rows 0..n-1
;;      ;;   - or (void) if no solution from this state.
;;      ;; =========================
;;      (define (solve_row row n queens)
;;        (if (eq? row n)
;;            ;; all rows placed, solution found
;;            queens
;;            (let ([col 0])
;;              (let ([solution (void)])
;;                (begin
;;                  (while (< col n)
;;                    (begin
;;                      (if (safe? col queens)
;;                          (let ([s (solve_row (+ row 1) n (cons col queens))])
;;                            (if (eq? s (void))
;;                                (set! solution solution)
;;                                (set! solution s)))
;;                          (set! solution solution))
;;                      (set! col (+ col 1))))
;;                  solution)))))

;;      ;; Helper: top-level solver
;;      (define (solve_n_queens n)
;;        (solve_row 0 n (void)))

;;      ;; =========================
;;      ;; Entry expression:
;;      ;;   - read n
;;      ;;   - solve N-Queens
;;      ;;   - return solution list (columns, last row first)
;;      ;; =========================
;;      (let* ([n (read)]
;;             [solution (solve_n_queens n)])
;;        solution)))

;; (displayln
;;  (dump-x86-64
;;   (prelude-and-conclusion
;;    (patch-instructions
;;     (assign-homes
;;      (select-instructions
;;       (uncover-locals
;;        (explicate-control
;;         (anf-convert
;;          (limit-functions
;;           (lift-lambdas
;;            (assignment-convert
;;             (reveal-functions
;;              (uniqueify
;;               (shrink
;;                nq
;;                #;
;;                '(program (define (f x) (lambda (y) (+ x y)))
;;                          (define (g x) (lambda (y) (lambda (z) ((f z) (+ y x)))))
;;                          (g (read))))))))))))))))))


