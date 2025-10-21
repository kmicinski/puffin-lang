#lang racket

;; CIS531 Fall '25 Project 3
;; Compiling R3 -> x86-64
(require "irs.rkt") ;; Definition of each IR (please read)
(require "system.rkt") ;; System-specific details
(require "interpreters.rkt") ;; XXX

(provide (all-defined-out)) ;; export everything for testing

;; The compiler is designed in passes, which go:
;;
;; --> R3? -- Source program
;; |
;; +-> shrunk-R3? -- Shrunken R3 (removes several forms)
;; |
;; +-> unique-source-tree? -- every bound identifier is written exactly once
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
  (define (align16 n)
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

;; walks over instructions and replaces invalid movqs, where both
;; operands are indirects (offsets of %rax). In x86_64, we *cannot*
;; have all operands in memory, so we shuffle into utility register(s)
;; as necessary to restore the necessary invariants.
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
        ['(void)       `(imm 0)]
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
        ;; new
        [`(seq (assign ,x (void)) ,rest)
         `((movq (imm 0) (var ,x))
           ,@(h rest))]
        [`(seq (assign ,x (vector ,i)) ,rest)
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
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x (vector ,a)))]
      [`(let ([_ (vector-set! ,x ,i ,v)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(vector-set! ,x ,i ,v))]
      [`(let ([_ (void)]) ,e)
       (expr->blocks e current-block k)]
      [`(let ([,x (void)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x (void)))]
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
                 `(if (eq? ,a 0)
                      ;; take the false branch
                      (goto ,l-f)
                      ;; take the true branch...
                      (goto ,l-t)))]

      [(? atom? a)
       (hash current-block (k a))]))
  (match p
    [`(program ,info ,anf)
     `(program ,info ,(expr->blocks anf (entry-symbol) (lambda (a) `(return ,a))))]))

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

      ;; new forms
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
                       (convert-expr e1 (lambda (a1) `(vector-set! ,a0 ,i ,a1)))))]
      ;; let
      [`(let ([,x ,e]) ,e-b)
       (convert-expr e (lambda (atom)
                         `(let ([,x ,atom]) ,(convert-expr e-b k))))]))
  (match p
    [`(program ,info ,e)
     `(program ,info ,(convert-expr e (lambda (x) x)))]))

(define (assignment-convert p)
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
      ;; new forms
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
      ;; put original let last to avoid matching _
      [`(let ([,x ,e]) ,e-b)
       `(let ([,x (make-vector 1)])
          (let ([_ (vector-set! ,x 0 ,(a-c e))])
            ,(a-c e-b)))] ))
  (match p
    [`(program () ,exp)
     `(program () ,(a-c exp))]))

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
      [`(set! ,x ,e) `(set! ,x ,(rename e assignment))]))
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
      [`(vector-set! ,e ,i ,e-v) `(vector-set! ,(h e) ,i ,(h e-v))]
      [`(vector-ref ,e ,i) `(vector-ref ,(h e) ,i)]
      [`(while ,e-g ,e-b) `(let ([_ (while ,(h e-g) ,(h e-b))]) (void))]
      [`(let ([,x ,e0]) ,e-b)
       `(let ([,x ,(h e0)]) ,(h e-b))]
      [`(let* ([,x ,e0]) ,e-b)
       `(let ([,x ,(h e0)]) ,(h e-b))]
      [`(let* ([,x ,e0] ,rest ...) ,e-b)
       `(let ([,x ,(h e0)]) ,(h `(let* (,@rest) ,e-b)))]))
  (match p
    [`(program ,exp)
     ;; empty info
     `(program ,(h exp))]))

;; Live on the edge, don't typecheck

(define ex0 '(program
              (let* ([x (read)]
                     [i 0]
                     [acc 0])
                (begin
                  (while (< i x)
                         (begin
                           (set! acc (+ acc i))
                           (set! i (+ i 1))))
                  acc))))


(define (ezcompile p)
  (interpret-instr
   (select-instructions
    (uncover-locals
     (explicate-control
      (anf-convert
       (assignment-convert
        (uniqueify
         (shrink p)))))))
   (range 100)))

;(ezcompile ex0)

