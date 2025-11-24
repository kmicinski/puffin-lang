#lang racket

;; CIS531 Fall '25 Project 5
;; Compiling Functions (R4/5) -> x86-64
(require "irs.rkt") ;; Definition of each IR (please read)
(require "system.rkt") ;; System-specific details

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


;; Assume that p is of the form `(program (define (f x0 ...) e-b)
;; ... e-main). Lift `e-b` into a special function named
;; `(entry-symbol)`. Also ensure that new forms are handled.
(define (shrink p)
  (define (h e)
    (match e
      ;; other cases...
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

;; Needs to be updated to map across definitions (I've done a bit of
;; this for you) and then to handle the new forms
(define (uniqueify p)
  (define (rename e assignment)
    (match e
      ;; 
      ;; old forms...
      ;;

      ;; NEW case: for any x ∈ xs, rename any one previously used...
      [`(lambda (,xs ...) ,e-b)
       'todo-transform-lambda]
      [`(,e-f ,e-args ...) 'todo-app]))
  (define (per-defn def)
    (match def
      [`(define (,f ,xs ...) ,e-b)
       'todo]))
  (match p
    [`(program ,defns ...)
     ;; empty info
     `(program ,@(map per-defn defns))]))


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
  ;; hint: want to define a recursive function that walks over
  ;; expressions and renames f -> (fun-ref f) whenever its in the set
  ;; of names..
  (define (walk e names)
    (match e
      [(? fixnum? n) n]
      [(? boolean? b) b]
      ;; ... other forms
      ))
  (match p
    [`(program (define (,names ,params ...) ,bodies) ...)
     ;; hint: you can calculate a set of names like this
     (define name-set
       (foldl (lambda (name acc) (hash-set acc name `(fun-ref ,name)))
              (hash)
              names))
     'todo]))


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

  ;; do lambda lifting on e, return the lifted expression and possibly
  ;; emit some defines by calling emit-define!
  (define (walk-expr e)
    (match e
      ;;
      ;; ...other forms...
      ;;

      ;; New: emit a wrapping vector (to make a closure)
      [`(fun-ref ,f) 
       (define v (gensym 'v))
       `(let ([,v (make-vector 1)])
          todo)]

      ;; lambdas: these should be lifted
      [`(lambda (,xs ...) ,e)
       ;; first, convert the body
       ;; ...

       ;; helper: generate a stack in the body to unwrap free vars
       (define (letstack vars-in-order i)
         (match vars-in-order
           [`(,hd . ,tl)
            `(let ([,hd (vector-ref env ,i)])
               ,(letstack tl (+ i 1)))]
           ['()
            'todo]))
       ;; just return todo here for now, you need to finish this...
       'todo]
      [`(app ,e-f ,e-args ...) 
       'todo]))

  (define (per-defn definition)
    (match definition
      [`(define (,fname ,formals ...) ,e-body)
       ;; add `env` but only to non-main symbols (main shouldn't take an env)
       (define maybe-env (if (equal? fname (entry-symbol)) '() '(env)))
       `(define (,fname ,@maybe-env ,@formals) ,(walk-expr e-body))]))
  (match p
    [`(program ,definitions ...)
     `(program ,@(map per-defn definitions) ,@(set->list emitted-defines))]))

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
  ;; I wrote a walk-expr function here which walks over all exprs and
  ;; identifies callsites with > 6 arguments to allocate / populate
  ;; vectors.
  (define (walk-expr e) 'todo)
  (define (per-defn definition)
    (match definition
      ;; > 6 formals: (f a0 a1 a2 a3 a4 a5 a-rest...)
      [`(define (,fname ,a0 ,a1 ,a2 ,a3 ,a4 ,a5 ,a-rest ...) ,e-body)
       'todo-special-case]  ;; start indexing at 0 (matches call-site)
      ;; ≤ 6 formals: unchanged except recursive walk
      [`(define (,fname ,formals ...) ,e-body)
       'todo-common-case]))
  (match p
    [`(program ,definitions ...)
     `(program ,@(map per-defn definitions))]))

;; New: map over all the definitions
;; Optimized assignment-convert, per-function:
;; - For each function, compute which vars are ever mutated with set!
;; - Only those vars are boxed in that function.
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
      ;;
      ;; ... old forms ...
      ;;

      ;; new forms
      [`(fun-ref ,g) e]
      [`(app ,es ...) `(app ,@(map a-c es))]
      [`(lambda (,xs ...) ,e)
       'todo]
      ;; put original let last to avoid matching _
      [`(let ([,x ,e]) ,e-b)
       'todo]))
  (define (per-defn definition)
    (match definition
      [`(define (,fname ,formals ...) ,e-body)
       'todo]))
  (match p
    [`(program ,defns ...)
     `(program ,@(map per-defn defns))]))

;; ANF Conversion--handle new cases, think carefully about if
(define (anf-convert p)
  (define (convert-expr e k)
    (match e
      ;; 
      ;; ... old forms ...
      ;;

      ;; new forms
      [`(app ,e0 ,e-rest ...)
       'todo]
      [`(fun-ref ,f) 
       'todo]
      ))
  (define (per-defn definition)
    (match definition
      [`(define (,fname ,formals ...) ,e-body)
       'todo]))
  (match p
    [`(program ,defns ...)
     `(program ,@(map per-defn defns))]))

;; Fairly easy pass: update to add the case described in the README.
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
      ;;
      ;; ... other cases...
      ;;;

      ;; NEW 
      [`(let ([,x (app ,a-f ,a-args ...)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x (app ,a-f ,@a-args)))]))
  (define (per-defn definition)
    (match definition
      [`(define (,fname ,formals ...) ,e-body)
       `(define (,fname ,@formals) ,(expr->blocks e-body fname (lambda (a) `(return ,a))))]))
  (match p
    [`(program ,defns ...)
     `(program ,@(map per-defn defns))]))

;; I'm giving to you this pass again...
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

        ;; 
        ;; other forms
        ;; 

        ;; NEW
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
    'todo 
    ;; basic idea:
    ;; - define blocks+, the new updated blocks (don't forget the conclusion block) 
    ;; 
    (define blocks+ (hash-set
                     'todo-calculuate-the-rest-of-the-blocks
                     (conclusion-block-name)
                     '((retq))))
    (define entry (hash-ref blocks+ f))
    ;; build a sequqence of `movq` instructions that move the argument registers into the variables
    (define move-sequence '(todo))
    ;; prepend the move sequence to the entry...
    (define blocks++ (hash-set blocks+ f (append move-sequence entry))) 
    `(define ,locals (,f ,@args) ,blocks++))
  ;; the input is C0: h is (hash 'start '(let ...))
  (match p
    [`(program ,defns ...)
      ;; also add an empty conclusion block
     `(program ,@(map per-defn defns))]))

;; Take variables into either the stack/registers
(define (assign-homes p)
  ;; traverse each instruction in the block to replace (var x) with
  ;; the appropriate stack position. Note: this will leave some
  ;; instructions
  (define (per-defn definition)
    (match-define `(define ,locals (,f ,args ...) ,blocks) definition)
    (define var->stackloc
      (let ([l (set->list locals)])
        (foldl (lambda (v i h) (hash-set h v (* -8 i))) (hash) l (range 1 (add1 (length l))))))
    ;; map (var x) to its home (an offset of rbp)
    (define (home a)
      (match a
        [`(var ,x) `(deref (reg rbp) ,(hash-ref var->stackloc x 'unknown))]
        [`(imm ,i) a]
        [`(reg ,r) a]
        [`(byte-reg ,al) a]
        [`(deref ,rest ...) a]))    
    (define (h block)
      (match block
        ;; 
        ;; ... previous forms...
        ;; 

        ;; new
        [`((retq) ,rest ...)
         'todo]
        [`((indirect-callq ,a) ,rest ...)
         'todo]
        [`((callq ,f ,i) ,rest ...)
         'todo]
        [`((leaq (fun-ref ,f) ,a) ,rest ...)
         'todo]))
    (define blocks+ (foldl (λ (blk acc)
                           (hash-set acc blk (h (hash-ref blocks blk)))) blocks (hash-keys blocks)))
    `(define ,var->stackloc (,f ,@args) ,blocks+)) ;; end of per-defn
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
      ;; 
      ;; ... older forms...
      ;;

      ;; NEW
      [`((leaq ,src (reg ,r)) ,rest ...)
       'todo]
      [`((leaq ,src ,dst) ,rest ...)
       'todo]
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

(define (prelude-and-conclusion p)
  (define (align16 n)
    (bitwise-and (+ n 15) (bitwise-not 15)))

  ;; walk over all blocks in a hash and replace '(jmp conclusion) to
  ;; `(jmp ,name)
  (define (rename-conclusion blocks name)
    ;; I'll let you write this one (if it's helpful...)
    'todo)
  
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

;; Dump x86-64 code to GAS assmbler
(define (dump-x86-64 p)
  (define functions (set-add (list->set (match p [`(program ,_ (define ,_ (,fs ,_ ...) ,_) ...) fs])) 'main))
  (define (render-op op)
    (match op
      [`(imm ,i) (format "$~a" i)]
      [`(reg ,x) (format "%~a" (symbol->string x))]
      [`(byte-reg ,x) (format "%~a" (symbol->string x))]
      [`(deref (reg ,reg) ,i) (format "~a(%~a)" i (symbol->string reg))]))
  (define (render-instr instr)
    (match instr
      ;; 
      ;; ...older forms...
      ;; 

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
