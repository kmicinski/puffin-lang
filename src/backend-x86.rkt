#lang racket

;; Puffin -- backend-x86.rkt: the x86-64 backend.
;;
;; Everything after uncover-locals for the 'x86-64 target:
;;
;;   select-instructions-x86     blocks IR -> pseudo-x86 over (var x)
;;   allocate-registers-x86      live-range linear scan (regalloc.rkt)
;;   patch-instructions-x86      legalize (mem/mem moves, imm64, ...)
;;   prelude-and-conclusion-x86  frames, callee-saved saves, pf_init,
;;                               result printing
;;   render-x86                  GAS text (+ symbol/string/global data)
;;
;; The structure (and much of the code) descends from the class p5
;; compiler; the deltas are the tagged-value immediates, stdlib
;; calls driven by the manifest, globals, the new ALU ops needed by
;; tagging (* and boolean tagging), and the data-section emission.

(require "irs.rkt")
(require "system.rkt")
(require "stdlib.rkt")
(require "regalloc.rkt")

(provide (all-defined-out))

;; ---------------------------------------------------------------------
;; Literal tables: symbols and strings are collected from the blocks
;; IR in sorted order, so every pass that needs an id assigns the
;; same one deterministically.
;; ---------------------------------------------------------------------

(define (scan-literals p)
  (define symbols (mutable-set))
  (define strings (mutable-set))
  (define (scan-atom a)
    (match a
      [`(quote ,s) (set-add! symbols s)]
      [_ (void)]))
  (define (scan-rhs rhs)
    (match rhs
      [`(string-lit ,s) (set-add! strings s)]
      [`(,_ ,as ...) (for-each scan-atom as)]
      [a (scan-atom a)]))
  (define (scan-tail t)
    (match t
      [`(return ,a) (scan-atom a)]
      [`(tail-app ,as ...) (for-each scan-atom as)]
      [`(goto ,_) (void)]
      [`(if (,_ ,a0 ,a1) ,_ ,_) (scan-atom a0) (scan-atom a1)]
      [`(seq (assign ,_ ,rhs) ,rest) (scan-rhs rhs) (scan-tail rest)]
      [`(seq (effect ,rhs) ,rest) (scan-rhs rhs) (scan-tail rest)]
      [`(seq (global-set! ,_ ,a) ,rest) (scan-atom a) (scan-tail rest)]
      [`(seq (unsafe-vector-set! ,a0 ,_ ,a1) ,rest) (scan-atom a0) (scan-atom a1) (scan-tail rest)]))
  (match p
    [`(program ,_ ,defns ...)
     (for ([d defns])
       (match d
         [`(define ,_ (,_ ,_ ...) ,blocks)
          (for ([l (hash-keys blocks)]) (scan-tail (hash-ref blocks l)))]))])
  (values (sort (set->list symbols) symbol<?)
          (sort (set->list strings) string<?)))

(define (index-of-table lst v who)
  (or (index-of lst v) (error who "literal not in table: ~a" v)))

;; ---------------------------------------------------------------------
;; select-instructions
;; ---------------------------------------------------------------------

(define (select-instructions-x86 p)
  (define-values (symbol-table string-table) (scan-literals p))
  ;; Translate an atom to an operand (tagging literals)
  (define (h-atom a)
    (match a
      ['(void)        `(imm ,void-value)]
      ['(nil)         `(imm ,nil-value)]
      [(? fixnum? n)  `(imm ,(tag-fixnum n))]
      [(? boolean? b) `(imm ,(if b true-value false-value))]
      [`(quote ,s)    `(imm ,(tag-symbol (index-of-table symbol-table s 'select-instructions)))]
      [(? symbol? x)  `(var ,x)]))
  ;; move atoms into the argument registers
  (define (copy-arguments as)
    (map (λ (a r) `(movq ,(h-atom a) (reg ,r)))
         as (take (argument-registers-list) (length as))))
  ;; one rhs; `sink` is instructions storing %rax into the target
  ;; (empty for effect position)
  (define (rhs->instrs rhs sink)
    (match rhs
      ;; intrinsics
      [`(+ ,a0 ,a1)
       `((movq ,(h-atom a0) (reg rax))
         (addq ,(h-atom a1) (reg rax))
         ,@sink)]
      [`(- ,a)
       `((movq ,(h-atom a) (reg rax))
         (negq (reg rax))
         ,@sink)]
      [`(* ,a0 ,a1)
       ;; (a>>3) * b == (a*b)<<3 for tagged fixnums
       `((movq ,(h-atom a0) (reg rax))
         (sarq (imm 3) (reg rax))
         (imulq ,(h-atom a1) (reg rax))
         ,@sink)]
      [`(,(? shrunk-cmp? cmp) ,a0 ,a1)
       ;; compare, set, then tag the boolean: (0|1)<<3 | 2
       (define cc (match cmp ['eq? 'e] ['< 'l]))
       `((cmpq ,(h-atom a1) ,(h-atom a0))
         (set ,cc (byte-reg al))
         (movzbq (byte-reg al) (reg rax))
         (shlq (imm 3) (reg rax))
         (orq (imm ,false-value) (reg rax))
         ,@sink)]
      ;; heap access the compiler controls: no checks, tagged ptr
      ;; is object address + 1, header is 8 bytes -> offset 8i + 7
      [`(unsafe-vector-ref ,a ,i)
       `((movq ,(h-atom a) (reg rax))
         (movq (deref (reg rax) ,(+ 7 (* 8 i))) (reg rax))
         ,@sink)]
      ;; functions and calls
      [`(fun-ref ,f)
       `((leaq (fun-ref ,f) (reg rax))
         ,@sink)]
      [`(app ,a-f ,args ...)
       `(,@(copy-arguments args)
         (indirect-callq ,(h-atom a-f))
         ,@sink)]
      ;; globals
      [`(global-ref ,i)
       `((movq (global ,i) (reg rax))
         ,@sink)]
      ;; string literals materialize via the runtime's constant table
      [`(string-lit ,s)
       `((movq (imm ,(tag-fixnum (index-of-table string-table s 'select-instructions))) (reg rdi))
         (callq pf_string_const 1)
         ,@sink)]
      ;; every stdlib primitive is a call with args in registers
      [`(,(? stdlib-prim? op) ,args ...)
       `(,@(copy-arguments args)
         (callq ,(stdlib-rt-sym op) ,(length args))
         ,@sink)]
      ;; atoms
      [a
       `((movq ,(h-atom a) (reg rax))
         ,@sink)]))
  (define (h seq)
    (match seq
      [`(return ,a)
       `((movq ,(h-atom a) (reg rax))
         (jmp ,(conclusion-block-name)))]
      ;; tail call: load the target into scratch %r11 *before* the
      ;; argument moves, then a tail-jmp pseudo-instruction that
      ;; prelude-and-conclusion expands into epilogue + jmp *%r11
      [`(tail-app ,a-f ,args ...)
       `((movq ,(h-atom a-f) (reg r11))
         ,@(copy-arguments args)
         (tail-jmp (reg r11) ,(length args)))]
      [`(seq (assign ,x ,rhs) ,rst)
       (append (rhs->instrs rhs `((movq (reg rax) (var ,x)))) (h rst))]
      [`(seq (effect ,rhs) ,rst)
       (append (rhs->instrs rhs '()) (h rst))]
      [`(seq (global-set! ,i ,a) ,rst)
       `((movq ,(h-atom a) (global ,i))
         ,@(h rst))]
      [`(seq (unsafe-vector-set! ,a0 ,i ,a-v) ,rst)
       `((movq ,(h-atom a0) (reg rax))
         (movq ,(h-atom a-v) (deref (reg rax) ,(+ 7 (* 8 i))))
         ,@(h rst))]
      [`(if (,cmp ,a0 ,a1) (goto ,l0) (goto ,l1))
       (define cc (match cmp ['eq? 'e] ['< 'l]))
       `((cmpq ,(h-atom a1) ,(h-atom a0))
         (jmp-if ,cc ,l0)
         (jmp ,l1))]
      [`(goto ,l)
       `((jmp ,l))]))
  (define (per-defn defn)
    (match-define `(define ,locals (,f ,args ...) ,blocks) defn)
    (define blocks+ (hash-set
                     (foldl (λ (block acc) (hash-set acc block (h (hash-ref blocks block)))) (hash) (hash-keys blocks))
                     (conclusion-block-name)
                     '((retq))))
    (define entry (hash-ref blocks+ f))
    (define moves
      (map (λ (a r) `(movq (reg ,r) (var ,a)))
           args (take (argument-registers-list) (length args))))
    (define blocks++
      (hash-set blocks+ f (append moves entry)))
    `(define ,locals (,f ,@args) ,blocks++))
  (match p
    [`(program ,info ,defns ...)
     `(program ,(hash-set (hash-set info 'symbols symbol-table) 'strings string-table)
               ,@(map per-defn defns))]))

;; ---------------------------------------------------------------------
;; allocate-registers: uses/defs for pseudo-x86, then the shared
;; live-range linear scan (regalloc.rkt)
;; ---------------------------------------------------------------------

(define (x86-uses+defs i)
  (define (vars-of . ops)
    (append-map (λ (op) (match op [`(var ,x) (list x)] [_ '()])) ops))
  (match i
    [`(movq ,src ,dst)   (list (vars-of src) (vars-of dst))]
    [`(movzbq ,src ,dst) (list (vars-of src) (vars-of dst))]
    [`(leaq ,_ ,dst)     (list '() (vars-of dst))]
    [`(,(or 'addq 'imulq 'xorq 'orq 'andq) ,src ,dst)
     (list (vars-of src dst) (vars-of dst))]
    [`(,(or 'negq) ,dst) (list (vars-of dst) (vars-of dst))]
    [`(,(or 'sarq 'shlq) ,_ ,dst) (list (vars-of dst) (vars-of dst))]
    [`(cmpq ,a ,b)       (list (vars-of a b) '())]
    [`(indirect-callq ,a) (list (vars-of a) '())]
    [_ (list '() '())]))

(define (allocate-registers-x86 p)
  (allocate-registers-with p x86-uses+defs))

;; ---------------------------------------------------------------------
;; patch-instructions: legalize what linear scan and tagging produce
;;   - no memory/memory two-operand forms ((deref ...) and (global ...)
;;     both count as memory)
;;   - movzbq/leaq destinations must be registers
;;   - cmpq's second operand must not be an immediate
;;   - immediates beyond 32 bits go through movabsq + %r11
;; ---------------------------------------------------------------------

(define (patch-instructions-x86 p)
  (define (mem? op) (or (deref? op) (global? op)))
  (define (big-imm? op)
    (match op [`(imm ,i) (or (> i 2147483647) (< i -2147483648))] [_ #f]))
  (define (patch-instr instr)
    (match instr
      ;; imm64: stage through r11 (movq straight to a register is fine
      ;; via movabsq)
      [`(movq ,(? big-imm? src) ,(? reg? dst))
       `((movabsq ,src ,dst))]
      [`(,op ,(? big-imm? src) ,dst)
       `((movabsq ,src (reg r11))
         ,@(patch-instr `(,op (reg r11) ,dst)))]
      ;; memory/memory forms stage through r11
      [`(movq ,(? mem? src) ,(? mem? dst))
       `((movq ,src (reg r11))
         (movq (reg r11) ,dst))]
      [`(,(and op (or 'addq 'xorq 'orq 'andq)) ,(? mem? src) ,(? mem? dst))
       `((movq ,src (reg r11))
         (,op (reg r11) ,dst))]
      [`(cmpq ,(? mem? a) ,(? mem? b))
       `((movq ,b (reg r11))
         (cmpq ,a (reg r11)))]
      [`(cmpq ,a ,(? imm? b))
       `((movq ,b (reg r11))
         (cmpq ,a (reg r11)))]
      ;; imulq needs a register destination
      [`(imulq ,src ,(? mem? dst))
       `((movq ,dst (reg r11))
         (imulq ,src (reg r11))
         (movq (reg r11) ,dst))]
      [`(movzbq ,src ,(? mem? dst))
       `((movzbq ,src (reg rax))
         (movq (reg rax) ,dst))]
      [`(leaq ,src ,(? mem? dst))
       `((leaq ,src (reg r11))
         (movq (reg r11) ,dst))]
      [i (list i)]))
  (define (per-defn defn)
    (match-define `(define ,info (,f ,formals ...) ,blocks) defn)
    (define blocks+
      (foldl (lambda (k a) (hash-set a k (append-map patch-instr (hash-ref blocks k))))
             (hash)
             (hash-keys blocks)))
    `(define ,info (,f ,@formals) ,blocks+))
  (match p
    [`(program ,info ,defns ...)
     `(program ,info ,@(map per-defn defns))]))

;; the shape check exported for main.rkt's pass table
(define (patched-program-x86? p)
  (define (ok-instr? i)
    (match i
      [`(movq ,src ,dst)
       (not (and (or (deref? src) (global? src)) (or (deref? dst) (global? dst))))]
      [`(movzbq ,_ ,dst) (reg? dst)]
      [`(leaq ,_ ,dst) (reg? dst)]
      [`(imulq ,_ ,dst) (reg? dst)]
      [_ #t]))
  (and (homes-assigned-program? p)
       (match p
         [`(program ,_ ,defns ...)
          (andmap (λ (d)
                    (match d
                      [`(define ,_ (,f ,_ ...) ,blocks)
                       (andmap (λ (l) (andmap ok-instr? (hash-ref blocks l)))
                               (hash-keys blocks))]))
                  defns)])))

;; ---------------------------------------------------------------------
;; prelude-and-conclusion
;;
;; Per function: set up the frame, save the callee-saved registers
;; the allocator used, reserve spill space (keeping the stack
;; 16-byte aligned at call sites), and rewrite the placeholder
;; conclusion. main additionally calls pf_init first and prints its
;; result via pf_print_result.
;; ---------------------------------------------------------------------

(define (prelude-and-conclusion-x86 p)
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
  (define (per-defn defn)
    (match defn
      [`(define ,info (,f ,args ...) ,blocks)
       (define callee-saved (hash-ref info 'callee-saved '()))
       (define spill-bytes (hash-ref info 'spill-bytes 0))
       ;; after ret-addr+rbp pushes rsp is 16-aligned; keep it that
       ;; way past the callee-saved pushes and spill space
       (define push-bytes (* 8 (length callee-saved)))
       (define pad (modulo (- 16 (modulo (+ push-bytes spill-bytes) 16)) 16))
       (define frame-bytes (+ spill-bytes pad))
       (define start-block (hash-ref blocks f))
       (define new-start-block
         `((pushq (reg rbp))
           (movq (reg rsp) (reg rbp))
           ,@(map (λ (r) `(pushq (reg ,r))) callee-saved)
           ,@(if (zero? frame-bytes) '() `((addq (imm ,(- frame-bytes)) (reg rsp))))
           ,@(if (equal? f (entry-symbol)) `((callq pf_init 0)) '())
           ,@start-block))
       (define restore
         `(,@(if (zero? frame-bytes) '() `((addq (imm ,frame-bytes) (reg rsp))))
           ,@(map (λ (r) `(popq (reg ,r))) (reverse callee-saved))
           (popq (reg rbp))
           (retq)))
       (define conclusion-block
         (if (equal? f (entry-symbol))
             `(;; print the program's value (unless void), return 0
               (movq (reg rax) (reg rdi))
               (callq pf_print_result 0)
               (movq (imm 0) (reg rax))
               ,@restore)
             restore))
       (define my-conclusion (gensym 'conclusion))
       ;; expand tail-jmp: restore the frame, then jump through r11
       ;; (a scratch register, so untouched by the pops)
       (define (expand-tail-jmp instrs)
         (append-map
          (λ (i)
            (match i
              [`(tail-jmp ,op ,_)
               `(,@(if (zero? frame-bytes) '() `((addq (imm ,frame-bytes) (reg rsp))))
                 ,@(map (λ (r) `(popq (reg ,r))) (reverse callee-saved))
                 (popq (reg rbp))
                 (indirect-jmp ,op))]
              [_ (list i)]))
          instrs))
       (define blocks+
         (rename-conclusion
          (hash-set (hash-remove (hash-set blocks f new-start-block)
                                 (conclusion-block-name))
                    my-conclusion
                    conclusion-block)
          my-conclusion))
       (define blocks++
         (foldl (λ (k acc) (hash-set acc k (expand-tail-jmp (hash-ref acc k))))
                blocks+
                (hash-keys blocks+)))
       `(define ,info (,f ,@args) ,blocks++)]))
  (match p
    [`(program ,info ,defns ...)
     `(program ,info ,@(map per-defn defns))]))

;; ---------------------------------------------------------------------
;; render-x86: GAS text. Code, then the data segment: the symbol
;; table, the string-constant table, and the global array (BSS-ish
;; zeroed space in __DATA so the Boehm GC scans it as roots).
;; ---------------------------------------------------------------------

(define (render-x86 p)
  (define functions (set-add (list->set (match p [`(program ,_ (define ,_ (,fs ,_ ...) ,_) ...) fs])) (entry-symbol)))
  (define globals-sym (rt-sym 'puffin_globals))
  (define (render-op op)
    (match op
      [`(imm ,i) (format "$~a" i)]
      [`(reg ,x) (format "%~a" (symbol->string x))]
      [`(byte-reg ,x) (format "%~a" (symbol->string x))]
      [`(deref (reg ,reg) ,i) (format "~a(%~a)" i (symbol->string reg))]
      [`(global ,i) (format "~a+~a(%rip)" globals-sym (* 8 i))]))
  (define (render-cc cc)
    (match cc ['e "e"] ['ne "ne"] ['l "l"] ['ae "ae"]))
  (define (render-instr instr)
    (match instr
      [`(xorq ,src ,dst) (format "xorq ~a, ~a" (render-op src) (render-op dst))]
      [`(orq ,src ,dst) (format "orq ~a, ~a" (render-op src) (render-op dst))]
      [`(andq ,src ,dst) (format "andq ~a, ~a" (render-op src) (render-op dst))]
      [`(addq ,src ,dst) (format "addq ~a, ~a" (render-op src) (render-op dst))]
      [`(imulq ,src ,dst) (format "imulq ~a, ~a" (render-op src) (render-op dst))]
      [`(sarq ,src ,dst) (format "sarq ~a, ~a" (render-op src) (render-op dst))]
      [`(shlq ,src ,dst) (format "shlq ~a, ~a" (render-op src) (render-op dst))]
      [`(negq ,srcdst) (format "negq ~a" (render-op srcdst))]
      [`(movq ,src ,dst) (format "movq ~a, ~a" (render-op src) (render-op dst))]
      [`(movabsq ,src ,dst) (format "movabsq ~a, ~a" (render-op src) (render-op dst))]
      [`(movzbq ,src ,dst) (format "movzbq ~a, ~a" (render-op src) (render-op dst))]
      [`(pushq ,src) (format "pushq ~a" (render-op src))]
      [`(popq ,dst) (format "popq ~a" (render-op dst))]
      [`(cmpq ,op0 ,op1) (format "cmpq ~a, ~a" (render-op op0) (render-op op1))]
      [`(jmp-if ,cc ,lab) (format "j~a ~a" (render-cc cc) lab)]
      [`(jmp ,lab) (format "jmp ~a" lab)]
      [`(set ,cc ,byte-reg) (format "set~a ~a" (render-cc cc) (render-op byte-reg))]
      [`(callq ,(? label? l) ,(? nonnegative-integer? num-args))
       ;; must call rt-sym here!
       (format "call ~a" (symbol->string (rt-sym l)))]
      ['(retq) "ret"]
      [`(goto ,l) (format "jmp ~a" (symbol->string l))]
      [`(leaq (fun-ref ,f) ,dst) ;; make sure to call (rt-sym f) when rendering f here!
       (format "leaq ~a(%rip), ~a" (rt-sym f) (render-op dst))]
      [`(indirect-callq ,a) (format "callq *~a" (render-op a))]
      [`(indirect-jmp ,a) (format "jmp *~a" (render-op a))]))
  (define (render-block block name)
    (define txt-label (if (set-member? functions name) (format "~a:\n" (rt-sym name)) (format "~a:\n" name)))
    (apply string-append
           (cons txt-label
                 (map (λ (instr) (format "    ~a\n" (render-instr instr))) block))))
  (define (per-defn defn)
    (match-define `(define ,_ (,f ,formals ...) ,blocks) defn)
    ;; the function's entry block must come first
    (define rest-keys (sort (filter (λ (k) (not (equal? k f))) (hash-keys blocks))
                            symbol<?))
    (foldl (lambda (k acc) (string-append acc (render-block (hash-ref blocks k) k)))
           ""
           (cons f rest-keys)))
  (define (escape-c s)
    (apply string-append
           (map (λ (ch)
                  (match ch
                    [#\\ "\\\\"] [#\" "\\\""] [#\newline "\\n"] [#\tab "\\t"]
                    [_ (string ch)]))
                (string->list s))))
  (define (data-segment info)
    (define symbols (hash-ref info 'symbols '()))
    (define strings (hash-ref info 'strings '()))
    (define n-globals (hash-ref info 'globals 0))
    (define mac? (equal? (host-os) 'macosx))
    (string-append
     (if mac? ".section __TEXT,__cstring,cstring_literals\n" ".section .rodata\n")
     (apply string-append
            (for/list ([s symbols] [i (in-naturals)])
              (format "Lpfsym~a: .asciz \"~a\"\n" i (escape-c (symbol->string s)))))
     (apply string-append
            (for/list ([s strings] [i (in-naturals)])
              (format "Lpfstr~a: .asciz \"~a\"\n" i (escape-c s))))
     (if mac? ".section __DATA,__data\n" ".data\n")
     ".p2align 3\n"
     (apply string-append
            (for/list ([s '(puffin_symbol_names puffin_symbol_count
                            puffin_string_consts puffin_string_const_count
                            puffin_globals)])
              (format ".globl ~a\n" (rt-sym s))))
     (format "~a:\n" (rt-sym 'puffin_symbol_names))
     (apply string-append
            (for/list ([_ symbols] [i (in-naturals)]) (format "    .quad Lpfsym~a\n" i)))
     (format "~a: .quad ~a\n" (rt-sym 'puffin_symbol_count) (length symbols))
     (format "~a:\n" (rt-sym 'puffin_string_consts))
     (apply string-append
            (for/list ([_ strings] [i (in-naturals)]) (format "    .quad Lpfstr~a\n" i)))
     (format "~a: .quad ~a\n" (rt-sym 'puffin_string_const_count) (length strings))
     (format "~a: .space ~a\n" globals-sym (max 8 (* 8 n-globals)))))
  (match p
    [`(program ,info ,defns ...)
     (string-append
      (format ".globl ~a\n" (rt-sym (entry-symbol)))
      ".text\n"
      (foldl (λ (defn acc) (string-append acc (per-defn defn)))
             ""
             defns)
      (data-segment info))]))
