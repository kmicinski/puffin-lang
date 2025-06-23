#lang racket
;; CIS531 Fall '25 -- Project 1
(require racket/cmdline)
(require "irs.rkt") ;; Definition of languages / IRs used in P1 (READ!)

(provide compile)

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
     (define space-needed (align8 (- (apply min (hash-values locals)))))
     (define start-block (hash-ref blocks '_main))
     (define new-start-block
       `((pushq (reg rbp))
         (movq (reg rsp) (reg rbp))
         (subq (imm ,space-needed) (reg rsp))
         ,@start-block
         ;; move result into %rdi and print_int64 it
         (movq (reg rax) (reg rdi))
         (callq _print_int64 0)
         ;; 0 return value (to the terminal/system) into %rax
         (movq (imm 0) (reg rax))
         ;; reinstate stored %rbp
         (leave)
         ;; transfer back to caller
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

;; Dump x86-64 code to GAS assmbler
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
      ".extern _print_int64\n"
      (render-block (hash-ref blocks '_main) "_main"))]))

;; Generate a x86-64 GAS (as a string) given x86-64 assembly
#;
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

;; Testing facilities

;; Run a single pass, with an input satisfying some input predicate
;; and an output satisfying some output predicate. Return the value of
;; `(pass input)`.
;; 
;; If `golden-output` is provided, then `interp-output` (an
;; interpreter for the output IR) must be provided, too.
(define (run-pass-expect pass pass-name input input-pred output-pred
                         [golden-input #f]
                         [golden-output #f] [interp-output #f])
  (define output-equal? equal?) ;; for now, just use equal? for output comparison
  (define output (pass input))
  (define h (hash 'input (pretty-format input) 
                  'pass-name pass-name
                  'satisfies-input-predicate (input-pred input)
                  'satisfies-output-predicate (output-pred output)
                  'golden-input (pretty-format golden-input)
                  'pretty-output (if (string? output) output (pretty-format output))
                  'output output))
  (if golden-output
      (let* ([evaled-golden (interp-output golden-output)]
             [evaled-user (interp-output output)]
             [output-matches (output-equal? evaled-user evaled-golden)])
        (hash-set (hash-set (hash-set (hash-set h 'golden-output golden-output)
                            'evaled-golden (pretty-format evaled-golden))
                            'evaled-user evaled-user)
                  'correct
                  output-matches))
      ;; 
      h))

(define (yesno x)
  (if x "✅" "❌"))

(define (pass-output->stdout h)
  (when (hash-ref h 'golden-input #f)
      (displayln (format "Golden input:\n~a" (hash-ref h 'golden-input))))
  (displayln "Input:")
  (displayln (hash-ref h 'output))
  (displayln (format "Satsifes input predicate: ~a" (yesno (hash-ref h 'satisfies-input-predicate))))
  (displayln (format "Ran pass ~a. Output:" (hash-ref h 'pass-name)))
  (displayln (hash-ref h 'pretty-output))
  (displayln (format "Satisfies output predicate: ~a" (yesno (hash-ref h 'satisfies-output-predicate))))
  (when (hash-ref h 'golden-output #f)
    (displayln (format "Golden (instructor-provided) output:\n~a" (hash-ref h 'golden-input)))
    (displayln (format "Evaluation of golden output: ~a" (hash-ref h 'evaled-golden)))
    (displayln (format "Evaluation of your output: ~a" (hash-ref h 'evaled-user)))
    (displayln (format "Yours correct? ~a" (yesno (hash-ref h 'correct))))))

(define (trace->stdout trace)
  (define (print-summary trace)
    (displayln "\nSummary of passes run:\n\n")
    (for ([elt trace])
      (displayln (format "~a: Input (~a) Output (~a)"
                         (~a (hash-ref elt 'pass-name) #:align 'left  #:width 30)
                         (yesno (hash-ref elt 'satisfies-input-predicate))
                         (yesno (hash-ref elt 'satisfies-output-predicate))))))
  (for ([elt trace])
    (pass-output->stdout elt))
  (print-summary trace))

;; This function `run-chain` is a very general iterator function which
;; walks over a list of passes, while simultaneously (a) checking
;; input/output predicates for each pass, (b) checking consistency
;; with "golden" inputs and outputs. Golden inputs / outputs are
;; instructor-provided inputs / outputs which will be validated by the
;; test scripts.
;; 
;; The function accepts the following inputs:
;;  - The input source tree
;;  - A list of passes
;;  - A list of pass names for each pass
;;  - A list of input and output predicates for each pass
;;  - A list of golden inputs (one for each pass), possibly #f--see notes
;;  - A list of golden outputs (one for each pass), possibly #f--see notes
;;  - A list of interpreters which interpret the output of each pass
;; 
;; The function then produces a trace of each pass, which may be
;; rendered to screen, written to file, etc.
(define (run-chain source-tree passes pass-names input-predicates output-predicates
                   golden-inputs golden-outputs interpreters)
  (let loop ([passes      passes]
             [names       pass-names]
             [in-preds    input-predicates]
             [out-preds   output-predicates]
             [gold-ins    golden-inputs]
             [gold-outs   golden-outputs]
             [interps     interpreters]
             [input       source-tree]
             [trace       '()])
    (if (null? passes)
        (reverse trace)
        (let* ([pass       (car passes)]
               [pass-name  (car names)]
               [in-pred    (car in-preds)]
               [out-pred   (car out-preds)]
               [gold-in    (car gold-ins)]
               [gold-out   (car gold-outs)]
               [interp     (car interps)]
               [h          (run-pass-expect pass pass-name input
                                            in-pred out-pred
                                            gold-in gold-out interp)]
               [next-input (pass input)])
          (loop (cdr passes) (cdr names) (cdr in-preds) (cdr out-preds)
                (cdr gold-ins) (cdr gold-outs) (cdr interps)
                next-input (cons h trace))))))

;; Run each of the passes in sequence
(define (compile source-tree [verbose #f] [golden-inputs #f] [golden-outputs #f])
  ;; all of these defines used for verbose mode (to record each pass
  ;; and print its value)
  (define passes (list uniqueify anf-convert explicate-control uncover-locals
                       select-instructions assign-homes patch-instructions
                       prelude-and-conclusion dump-x86-64))
  (define pass-names (list "uniqueify" "anf-convert" "explicate-control" "uncover-locals"
                           "select-instructions" "assign-homes" "patch-instructions"
                           "prelude-and-conclusion" "render-x86"))
  (define input-predicates
    (list R1? unique-source-tree? anf-program? c0-program? locals-program?
          instr-program? homes-assigned-program? patched-program?
          x86-64?))
  (define output-predicates
    (list unique-source-tree? anf-program? c0-program? locals-program?
          instr-program? homes-assigned-program? patched-program? x86-64?
          string?)) 
  (define goldens-in (if golden-inputs golden-inputs (make-list (length passes) #f)))
  (define goldens-out (if golden-outputs golden-outputs (make-list (length passes) #f)))
  (define interpreters (make-list (length passes) #f))
  (let ([trace (run-chain source-tree
                          passes
                          pass-names
                          input-predicates
                          output-predicates
                          goldens-in
                          goldens-out
                          interpreters)])
    (when verbose
      (trace->stdout trace))
    (hash-ref (last trace) 'output)))

