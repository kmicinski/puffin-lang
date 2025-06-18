#lang racket
;; CIS531 Fall '25 -- Project 1
(require racket/cmdline)
(provide compile)


;; The compiler is designed in passes, which go:
;;   - Source language (R1)
;;   - Intermediate representation (C0)
;;   - Target (x86)

;; We document these IRs here, along with their semantics, by writing
;; interpreters for them.

;;
;; Source language
;;

;; The R1 language--the source language which will be the input to
;; your project.
(define (R1-exp? e)
  (match e
    [(? fixnum? n) #t]
    [`(read) #t]    
    [`(- ,(? R1-exp? e)) #t]
    [`(+ ,(? R1-exp? e0) ,(? R1-exp? e1)) #t]
    [(? symbol? var) #t]
    [`(let ([,(? symbol? x) ,(? R1-exp? e)]) ,(? R1-exp? e-body)) #t]
    [_ #f]))

;; An R1 program is an R1 expression wrapped with some information
(define (R1? e)
  (match e
    [`(program ,info ,(? R1-exp? exp)) #t]
    [_ #f]))

;; An interpreter for R1
(define (interp-R1 e)
  (define (interp e env)
    (match e
      [(? fixnum? n) n]
      [`(read) (read)]    
      [`(- ,(? R1-exp? e)) (- (interp e env))]
      [`(+ ,(? R1-exp? e0) ,(? R1-exp? e1)) (+ (interp e0 env) (interp e1 env))]
      [(? symbol? var) (hash-ref env var)]
      [`(let ([,(? symbol? x) ,(? R1-exp? e)]) ,(? R1-exp? e-body))
       (interp e-body (hash-set env x (interp e env)))]))
  (match e
    [`(program ,info ,e)
     (interp e (hash))]))

;;
;; Target language: x86
;;
(define label? symbol?)
(define (reg? r)
  (set-member? (set 'rsp 'rbp 'rax 'rbx 'rcx 'rdx 'rsi 'rdi
                    'r8 'r9 'r10 'r11 'r12 'r13 'r14 'r15)))

(define (arg? arg)
  (match arg
    [`(int ,(? fixnum? i)) #t]
    [`(reg ,(? reg?)) #t]
    [`(deref ,(? reg?) ,(? fixnum? i)) #t]
    [_ #f]))

(define (instr? i)
   (match i
     [`(addq (,(? arg? src) ,(? arg? dst))) #t]
     [`(subq (,(? arg? src) ,(? arg? dst))) #t]
     [`(negq (,(? arg? srcdst))) #t]
     [`(movq (,(? arg? src) ,(? arg? dst))) #t]
     [`(pushq (,(? arg? src))) #t]
     [`(popq (,(? arg? dst))) #t]
     [`(callq ,(? label? l) ,(? nonnegative-integer? num-args)) #t]
     ['(retq) #t]
     ['(leave) #t]
     [_ #f]))

;; A block has some metadata and a list of instructions
(define (block? b) 
  (match b
    [`(block ,info (,(? instr? instrs) ...)) #t]
    [_ #f]))

;; An x86-64 program has some metadata and a dictionary (hash) mapping
;; labels to blocks
(define (x86-int? p)
  (match p
    [`(program ,info ,h)
     (and (hash? h) (andmap label? (hash-keys h)) (andmap block? (hash-values h)))]
    [_ #f]))

;; adds the prelude and conclusion to each of the functions in the program
(define (prelude-and-conclusion p)
  (define (align16 n)
    (bitwise-and (+ n 15)     ; add 0xF so any remainder pushes into next block
                 (bitwise-not 15)))  ; clear the low four bits
  (match p
    [`(program ,locals ,blocks)
     (define space-needed (align16 (* -1 (apply min (hash-values locals)))))
     (define start-block (hash-ref blocks '_main))
     (define new-start-block
       `((pushq (reg rbp))
         (movq (reg rsp) (reg rbp))
         (subq (imm ,space-needed) (reg rsp))
         ,@start-block
         (leave)
         (retq)))
     ;; to build a new block, insert the prelude / conclusion
     `(program ,locals ,(hash '_main new-start-block))]))

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
     `(program ,info ,(hash '_main (patch-tail (hash-ref blocks '_main))))]))

(define (assign-homes p)
  (match-define `(program ,info ,blocks) p)
  (define var->stackloc
    (let ([l (set->list info)])
          (foldl (lambda (v i h) (hash-set h v (* -4 i))) (hash) l (range 1 (add1 (length l))))))
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
  `(program ,var->stackloc ,(hash '_main (h (hash-ref blocks '_main)))))

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
         `((callq _read_int64 0)
           (movq (reg rax) (var ,x))
           ,@(h rest))]
        [`(seq (assign ,x ,(? fixnum? n)) ,rest)
         `((movq (imm ,n) (var ,x))
           ,@(h rest))]
        [`(seq (assign ,x ,(? symbol? y)) ,rest)
         `((movq (var ,x) (var ,y))
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
     `(program ,info ,(hash '_main (c0->block (hash-ref h '_main))))]))

(define (uncover-locals p)
  (define (h seq)
    (match seq
      [`(return ,_) (set)]
      [`(seq (assign ,x0 ,_) ,rest)
       (set-add (h rest) x0)]))
  (match p
    [`(program () ,e)
     `(program ,(h (hash-ref e '_main)) ,e)]))

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
     `(program ,info ,(hash '_main (expr->seq anf)))]))

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

(define (dump-x86-64 p)
  (define (render-op op)
    (match op
      [`(imm ,i) (format "$~a" i)]
      [`(reg ,x) (format "%~a" (symbol->string x))]
      [`(deref (reg ,reg) ,i) (format "~a(%~a)" i (symbol->string reg))]))
  (define (render-instr instr)
    (pretty-print instr)
    (match instr
     [`(addq ,src ,dst) (format "addq ~a, ~a" (render-op src) (render-op dst))]
     [`(subq ,src ,dst) (format "subq ~a, ~a" (render-op src) (render-op dst))]
     [`(negq ,srcdst) (format "negq ~a" (render-op srcdst))]
     [`(movq ,src ,dst) (format "movq ~a, ~a" (render-op src) (render-op dst))]
     [`(pushq ,src) (format "pushq ~a" (render-op src))]
     [`(popq ,dst) (format "popq ~a" (render-op dst))]
     [`(callq ,(? label? l) ,(? nonnegative-integer? num-args))
      (format "call ~a" (symbol->string l))]
     ['(retq) "ret"]
     ['(leave) "leave"]))
  (define (render-block block name)
    (apply string-append
           (cons (format "~a:\n" name)
                 (map (λ (instr) (format "    ~a\n" (render-instr instr))) block))))
  (match p
    [`(program ,info ,blocks)
     (string-append 
      ".globl _main\n"
      ".extern _read_int64\n"
      (render-block (hash-ref blocks '_main) "_main"))]))

;; Generate a x86-64 GAS (as a string) given x86-64 assembly
(define (compile source-tree)
  (define unique-source-tree (uniqueify source-tree)) 
  (displayln "-> unique")
  (pretty-print unique-source-tree)
  (define normalized-source-tree (anf-convert unique-source-tree))
  (displayln "-> normalized")
  (pretty-print normalized-source-tree)
  (define explicit-control (explicate-control normalized-source-tree))
  (displayln "-> explicit control")
  (pretty-print explicit-control)
  (define uncovered-locals (uncover-locals explicit-control))
  (displayln "-> uncovered-locals")
  (pretty-print uncovered-locals)
  (define select-instr (select-instructions uncovered-locals))
  (displayln "-> select-instructions")
  (pretty-print select-instr)
  (define assigned-homes (assign-homes select-instr))
  (displayln "-> assign-homes")
  (pretty-print assigned-homes)
  (define patched-instructions (patch-instructions assigned-homes))
  (displayln "-> patch-instructions")
  (pretty-print patched-instructions)
  (define prelude-conclusion (prelude-and-conclusion patched-instructions))
  (displayln "-> prelude-and-conclusion")
  (pretty-print prelude-conclusion)
  (dump-x86-64 prelude-conclusion))
