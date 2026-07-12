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
(require "provenance.rkt")

(provide (all-defined-out))

;; ---------------------------------------------------------------------
;; Tag-checked arithmetic (the typed-error contract; src/runtime/lib/
;; arith.c). The open-coded + - * (and unary neg) and the < compare
;; lowerings check both operands' low 3 tag bits are 0 before
;; operating; on failure a shared per-function cold trap block loads
;; the operands and an operator-name cstring and calls
;; pf_die_arith_typed(op, a, b) -- the same helper the interpreter
;; and the bytecode VM route through, so the message is byte-identical
;; on every route ("<op>: expected Int, got <value>"). eq? is
;; polymorphic: no check. The op-name cstrings below are emitted in
;; every unit's data segment.
;; ---------------------------------------------------------------------

(define (arith-op-mangle op)
  (match op ['+ "add"] ['- "neg"] ['* "mul"]
            ['< "lt"] ['<= "le"] ['> "gt"] ['>= "ge"]))
(define (arith-op-label op)
  (string->symbol (format "Lpfop_~a" (arith-op-mangle op))))
(define arith-op-list '(+ - * < <= > >=))
(define (arith-op-cstrings)
  (apply string-append
         (for/list ([op arith-op-list])
           (format "~a: .asciz \"~a\"\n" (arith-op-label op) op))))

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
      ;; an atom rhs (e.g. a bare (quote s)) must not be
      ;; destructured by the generic operation pattern below
      [(? atom? a) (scan-atom a)]
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
  ;; ---- open-coded prims (>= -O1; docs/OPTIMIZER.md §5) ---------------
  ;; Hot pair/vector prims are emitted inline instead of as runtime
  ;; calls. Safety is kept: every check the runtime prim performs is
  ;; emitted as a compare-and-branch to a shared per-function TRAP
  ;; block, which calls the original runtime prim -- it re-checks and
  ;; errors with the exact original message and exit path. Since a
  ;; check failed, that call never returns, so the trap block needs
  ;; no rejoin (the jmp to the conclusion just keeps it well-formed).
  ;; Register discipline: the arguments are staged in the argument
  ;; registers (never allocated, never touched by patch-instructions'
  ;; %r11/%rax staging), so the trap block needs no register
  ;; shuffling and imposes no liveness demands on the allocator; the
  ;; checks themselves scratch only %rax.
  (define (open-code-prims?) (>= (optimize-level) 1))
  (define extra-blocks (make-hash))  ;; label -> instrs, reset per defn
  (define trap-labels  (make-hash))  ;; prim -> trap label, reset per defn
  (define (reset-open-coding!)
    (hash-clear! extra-blocks)
    (hash-clear! trap-labels))
  (define (trap-label! op nargs)
    (hash-ref! trap-labels op
               (λ ()
                 (define l (gensym (format "trap_~a_" (stdlib-rt-sym op))))
                 (hash-set! extra-blocks l
                            `((callq ,(stdlib-rt-sym op) ,nargs)
                              (jmp ,(conclusion-block-name))))
                 l)))
  ;; ---- tag-checked arithmetic (+ - * <; NOT eq?) ---------------------
  ;; Operands stage in rdi/rsi (argument registers: never allocated,
  ;; never touched by patch-instructions' %r11/%rax staging), so the
  ;; fast path is mov+or+test+jnz and the trap block needs no
  ;; register shuffling beyond the argument moves for
  ;; pf_die_arith_typed(op, a, b). Emitted at every -O level: the
  ;; arithmetic intrinsics are always open-coded. Future work (-O2):
  ;; AAM-based check elision when both operands are proven Int.
  (define (arith-trap-label! op)
    (hash-ref! trap-labels (cons 'arith op)
               (λ ()
                 (define l (gensym (format "trap_arith_~a_" (arith-op-mangle op))))
                 (hash-set! extra-blocks l
                            `(,@(if (equal? op '-)
                                    ;; unary: the VM passes (a, a)
                                    `((movq (reg rdi) (reg rsi))
                                      (movq (reg rdi) (reg rdx)))
                                    `((movq (reg rsi) (reg rdx))
                                      (movq (reg rdi) (reg rsi))))
                              (lea-label ,(arith-op-label op) (reg rdi))
                              (callq pf_die_arith_typed 3)
                              (jmp ,(conclusion-block-name))))
                 l)))
  ;; tagged fixnums have low bits 000, so or-ing the operands
  ;; preserves any nonzero tag; %rax scratch
  (define (arith-checks2 op)
    `((movq (reg rdi) (reg rax))
      (orq (reg rsi) (reg rax))
      (testq (imm 7) (reg rax))
      (jmp-if ne ,(arith-trap-label! op))))
  (define (arith-checks1 op)
    `((testq (imm 7) (reg rdi))
      (jmp-if ne ,(arith-trap-label! op))))
  ;; check that the value in `r` is a heap object (low bits 001) of
  ;; header kind `k`; branches to the trap otherwise (%rax scratch)
  (define (heap-kind-checks r k trap)
    `((movq (reg ,r) (reg rax))
      (andq (imm 7) (reg rax))
      (cmpq (imm 1) (reg rax))
      (jmp-if ne ,trap)
      (movzbq (deref (reg ,r) -1) (reg rax))  ;; header kind byte
      (cmpq (imm ,k) (reg rax))
      (jmp-if ne ,trap)))
  ;; check that `ri` holds a tagged fixnum index in bounds for the
  ;; vector in `rv`: (header >> 5) is the TAGGED length ((len<<8)>>5
  ;; = len<<3), so one unsigned compare of tagged index against it
  ;; checks the bound and catches negatives at once
  (define (index-checks ri rv trap)
    `((movq (reg ,ri) (reg rax))
      (andq (imm 7) (reg rax))
      (cmpq (imm 0) (reg rax))
      (jmp-if ne ,trap)
      (movq (deref (reg ,rv) -1) (reg rax))
      (sarq (imm 5) (reg rax))
      (cmpq (reg rax) (reg ,ri))
      (jmp-if ae ,trap)))
  ;; one rhs; `sink` is instructions storing %rax into the target
  ;; (empty for effect position)
  (define (rhs->instrs rhs sink) (prov-each (rhs->instrs-core rhs sink) rhs))
  (define (rhs->instrs-core rhs sink)
    (match rhs
      ;; intrinsics
      [`(+ ,a0 ,a1)
       `((movq ,(h-atom a0) (reg rdi))
         (movq ,(h-atom a1) (reg rsi))
         ,@(arith-checks2 '+)
         (movq (reg rdi) (reg rax))
         (addq (reg rsi) (reg rax))
         ,@sink)]
      [`(- ,a)
       `((movq ,(h-atom a) (reg rdi))
         ,@(arith-checks1 '-)
         (movq (reg rdi) (reg rax))
         (negq (reg rax))
         ,@sink)]
      [`(* ,a0 ,a1)
       ;; (a>>3) * b == (a*b)<<3 for tagged fixnums
       `((movq ,(h-atom a0) (reg rdi))
         (movq ,(h-atom a1) (reg rsi))
         ,@(arith-checks2 '*)
         (movq (reg rdi) (reg rax))
         (sarq (imm 3) (reg rax))
         (imulq (reg rsi) (reg rax))
         ,@sink)]
      ;; eq? is polymorphic: raw word compare, no tag check
      [`(eq? ,a0 ,a1)
       ;; compare, set, then tag the boolean: (0|1)<<3 | 2
       `((cmpq ,(h-atom a1) ,(h-atom a0))
         (set e (byte-reg al))
         (movzbq (byte-reg al) (reg rax))
         (shlq (imm 3) (reg rax))
         (orq (imm ,false-value) (reg rax))
         ,@sink)]
      ;; < in value position: tag-checked; on two proper fixnums a
      ;; raw compare of tagged words IS the value compare
      [`(< ,a0 ,a1)
       `((movq ,(h-atom a0) (reg rdi))
         (movq ,(h-atom a1) (reg rsi))
         ,@(arith-checks2 '<)
         (cmpq (reg rsi) (reg rdi))
         (set l (byte-reg al))
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
      ;; direct calls (>= -O1 anf output): a (fun-ref f) rator
      ;; becomes a direct call to f's label -- same argument and
      ;; arity-register protocol as the indirect case
      [`(app (fun-ref ,f) ,args ...)
       `(,@(copy-arguments args)
         (movq (imm ,(tag-fixnum (length args))) (reg r10))
         (callq ,f ,(length args))
         ,@sink)]
      [`(papp ,n (fun-ref ,f) ,args ...)
       `(,@(copy-arguments args)
         (movq (imm ,(tag-fixnum n)) (reg r10))
         (callq ,f ,(length args))
         ,@sink)]
      [`(app ,a-f ,args ...)
       `(,@(copy-arguments args)
         (movq (imm ,(tag-fixnum (length args))) (reg r10))
         (indirect-callq ,(h-atom a-f))
         ,@sink)]
      [`(papp ,n ,a-f ,args ...)
       ;; packed call: the arity register carries the ORIGINAL count
       `(,@(copy-arguments args)
         (movq (imm ,(tag-fixnum n)) (reg r10))
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
      ;; open-coded pair/vector prims (>= -O1): inline fast paths,
      ;; checks branch to the shared trap block (see above)
      [`(null? ,a) #:when (open-code-prims?)
       ;; (null? x) is (eq? x '()): the eq? compare/set/tag sequence
       `((cmpq (imm ,nil-value) ,(h-atom a))
         (set e (byte-reg al))
         (movzbq (byte-reg al) (reg rax))
         (shlq (imm 3) (reg rax))
         (orq (imm ,false-value) (reg rax))
         ,@sink)]
      [`(,(and op (or 'car 'cdr)) ,a) #:when (open-code-prims?)
       ;; pair layout: | header | car | cdr |, tagged ptr = addr + 1
       `((movq ,(h-atom a) (reg rdi))
         ,@(heap-kind-checks 'rdi heap-kind/pair (trap-label! op 1))
         (movq (deref (reg rdi) ,(match op ['car 7] ['cdr 15])) (reg rax))
         ,@sink)]
      [`(vector-length ,a) #:when (open-code-prims?)
       `((movq ,(h-atom a) (reg rdi))
         ,@(heap-kind-checks 'rdi heap-kind/vector (trap-label! 'vector-length 1))
         (movq (deref (reg rdi) -1) (reg rax))
         (sarq (imm 5) (reg rax))       ;; header>>5: the tagged length
         ,@sink)]
      [`(vector-ref ,a ,i) #:when (open-code-prims?)
       ;; a tagged index IS a byte offset: element i is at [v+i*8+7]
       (define trap (trap-label! 'vector-ref 2))
       `((movq ,(h-atom a) (reg rdi))
         (movq ,(h-atom i) (reg rsi))
         ,@(heap-kind-checks 'rdi heap-kind/vector trap)
         ,@(index-checks 'rsi 'rdi trap)
         (addq (reg rsi) (reg rdi))
         (movq (deref (reg rdi) 7) (reg rax))
         ,@sink)]
      [`(vector-set! ,a ,i ,v) #:when (open-code-prims?)
       (define trap (trap-label! 'vector-set! 3))
       `((movq ,(h-atom a) (reg rdi))
         (movq ,(h-atom i) (reg rsi))
         (movq ,(h-atom v) (reg rdx))
         ,@(heap-kind-checks 'rdi heap-kind/vector trap)
         ,@(index-checks 'rsi 'rdi trap)
         (addq (reg rsi) (reg rdi))
         (movq (reg rdx) (deref (reg rdi) 7))
         (movq (imm ,void-value) (reg rax))
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
    ;; instructions not already tagged (by rhs->instrs) belong to
    ;; the head statement of this tail
    (prov-each (h-core seq)
               (match seq [`(seq ,s ,_) s] [_ seq])))
  (define (h-core seq)
    (match seq
      [`(return ,a)
       `((movq ,(h-atom a) (reg rax))
         (jmp ,(conclusion-block-name)))]
      ;; direct tail call (>= -O1 anf output): no target register
      ;; needed; prelude-and-conclusion expands tail-jmp-direct into
      ;; epilogue + a direct jmp to f's label
      [`(tail-app ,n (fun-ref ,f) ,args ...)
       `(,@(copy-arguments args)
         (movq (imm ,(tag-fixnum n)) (reg r10))
         (tail-jmp-direct ,f ,(length args)))]
      ;; tail call: load the target into scratch %r11 *before* the
      ;; argument moves, then a tail-jmp pseudo-instruction that
      ;; prelude-and-conclusion expands into epilogue + jmp *%r11
      [`(tail-app ,n ,a-f ,args ...)
       `((movq ,(h-atom a-f) (reg r11))
         ,@(copy-arguments args)
         (movq (imm ,(tag-fixnum n)) (reg r10))
         (tail-jmp (reg r11) ,(length args)))]
      ;; open-coded pair?/vector? (>= -O1): the header kind may only
      ;; be loaded when the tag says heap, so the block splits: false
      ;; exits branch to a fresh #f block and both paths rejoin the
      ;; rest of the tail in a fresh continuation block
      [`(seq ,(and stmt `(assign ,x (,(and op (or 'pair? 'vector?)) ,a))) ,rst)
       #:when (open-code-prims?)
       (define k (match op ['pair? heap-kind/pair] ['vector? heap-kind/vector]))
       (define l-false (gensym (format "oc_~a_false_" (stdlib-rt-sym op))))
       (define l-join  (gensym (format "oc_~a_join_" (stdlib-rt-sym op))))
       (hash-set! extra-blocks l-false
                  (prov-each `((movq (imm ,false-value) (reg rax))
                               (movq (reg rax) (var ,x))
                               (jmp ,l-join))
                             stmt))
       (hash-set! extra-blocks l-join (h rst))
       `((movq ,(h-atom a) (reg r11))
         (movq (reg r11) (reg rax))
         (andq (imm 7) (reg rax))
         (cmpq (imm 1) (reg rax))
         (jmp-if ne ,l-false)
         (movzbq (deref (reg r11) -1) (reg rax))
         (cmpq (imm ,k) (reg rax))
         (jmp-if ne ,l-false)
         (movq (imm ,true-value) (reg rax))
         (movq (reg rax) (var ,x))
         (jmp ,l-join))]
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
      ;; fused compare-branch on eq?: polymorphic, no tag check
      [`(if (eq? ,a0 ,a1) (goto ,l0) (goto ,l1))
       `((cmpq ,(h-atom a1) ,(h-atom a0))
         (jmp-if e ,l0)
         (jmp ,l1))]
      ;; fused compare-branch on < (and defensively <= > >=, though
      ;; shrink rewrites those to <): tag-checked, so the trap's op
      ;; name matches what the VM's BR opcodes print for the same
      ;; source (a source-level (> x 1) is (< 1 x) on every route)
      [`(if (,cmp ,a0 ,a1) (goto ,l0) (goto ,l1))
       (define cc (match cmp ['< 'l] ['<= 'le] ['> 'g] ['>= 'ge]))
       `((movq ,(h-atom a0) (reg rdi))
         (movq ,(h-atom a1) (reg rsi))
         ,@(arith-checks2 cmp)
         (cmpq (reg rsi) (reg rdi))
         (jmp-if ,cc ,l0)
         (jmp ,l1))]
      [`(goto ,l)
       `((jmp ,l))]))
  (define (per-defn defn)
    (match-define `(define ,locals (,f ,args ...) ,blocks) defn)
    (reset-open-coding!)
    (define blocks-sel
      (hash-set
       (foldl (λ (block acc) (hash-set acc block (h (hash-ref blocks block)))) (hash) (hash-keys blocks))
       (conclusion-block-name)
       '((retq))))
    ;; splice in the trap/split blocks minted for this function
    (define blocks+
      (for/fold ([acc blocks-sel]) ([(l is) (in-hash extra-blocks)])
        (hash-set acc l is)))
    (define entry (hash-ref blocks+ f))
    (define mi (index-of args '#%rest))
    (define moves
      (cond
        [mi
         ;; variadic prologue: spill the six argument registers to
         ;; the runtime's arg area, build the rest list from the
         ;; incoming arity (r10), then load the fixed formals back
         (define fixed (take args mi))
         (define rest-name (list-ref args (add1 mi)))
         `(,@(map (λ (r i) `(movq (reg ,r) (argspill ,i)))
                  (argument-registers-list) (range 6))
           (movq (imm ,(tag-fixnum (length fixed))) (reg rdi))
           (movq (reg r10) (reg rsi))
           (callq pf_collect_rest 2)
           (movq (reg rax) (var ,rest-name))
           ,@(map (λ (a i) `(movq (argspill ,i) (var ,a)))
                  fixed (range (length fixed))))]
        [else
         (map (λ (a r) `(movq (reg ,r) (var ,a)))
              args (take (argument-registers-list) (length args)))]))
    (define blocks++
      (hash-set blocks+ f (append moves entry)))
    (define args+ (if mi (append (take args mi) (list (list-ref args (add1 mi)))) args))
    `(define ,locals (,f ,@args+) ,blocks++))
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
  (define (mem? op) (or (deref? op) (global? op)
                        (match op [`(argspill ,_) #t] [_ #f])))
  (define (big-imm? op)
    (match op [`(imm ,i) (or (> i 2147483647) (< i -2147483648))] [_ #f]))
  (define (patch-instr instr) (prov-each (patch-instr-core instr) instr))
  (define (patch-instr-core instr)
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
       ;; (a scratch register, so untouched by the pops);
       ;; tail-jmp-direct restores the same way but jumps straight
       ;; to the target function's label
       (define (expand-tail-jmp instrs)
         (append-map
          (λ (i)
            (match i
              [(and tj `(tail-jmp ,op ,_))
               (prov-each `(,@(if (zero? frame-bytes) '() `((addq (imm ,frame-bytes) (reg rsp))))
                 ,@(map (λ (r) `(popq (reg ,r))) (reverse callee-saved))
                 (popq (reg rbp))
                 (indirect-jmp ,op))
                tj)]
              [(and tj `(tail-jmp-direct ,f-target ,_))
               (prov-each `(,@(if (zero? frame-bytes) '() `((addq (imm ,frame-bytes) (reg rsp))))
                 ,@(map (λ (r) `(popq (reg ,r))) (reverse callee-saved))
                 (popq (reg rbp))
                 (jmp-direct ,f-target))
                tj)]
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

;; instruction rendering, shared by render-x86 and the pipeline
;; serializer's per-line provenance (ir-json.rkt)
(define (render-op-x86 op)
    (match op
      [`(imm ,i) (format "$~a" i)]
      [`(reg ,x) (format "%~a" (symbol->string x))]
      [`(byte-reg ,x) (format "%~a" (symbol->string x))]
      [`(deref (reg ,reg) ,i) (format "~a(%~a)" i (symbol->string reg))]
      [`(global ,i) (format "~a+~a(%rip)" (rt-sym 'puffin_globals) (* 8 i))]
      [`(argspill ,i) (format "~a+~a(%rip)" (rt-sym 'pf_arg_spill) (* 8 i))]))
(define (render-cc-x86 cc)
  (match cc ['e "e"] ['ne "ne"] ['l "l"] ['le "le"] ['g "g"] ['ge "ge"] ['ae "ae"]))
(define (render-instr-x86 instr)
    (match instr
      [`(xorq ,src ,dst) (format "xorq ~a, ~a" (render-op-x86 src) (render-op-x86 dst))]
      [`(orq ,src ,dst) (format "orq ~a, ~a" (render-op-x86 src) (render-op-x86 dst))]
      [`(andq ,src ,dst) (format "andq ~a, ~a" (render-op-x86 src) (render-op-x86 dst))]
      [`(addq ,src ,dst) (format "addq ~a, ~a" (render-op-x86 src) (render-op-x86 dst))]
      [`(imulq ,src ,dst) (format "imulq ~a, ~a" (render-op-x86 src) (render-op-x86 dst))]
      [`(sarq ,src ,dst) (format "sarq ~a, ~a" (render-op-x86 src) (render-op-x86 dst))]
      [`(shlq ,src ,dst) (format "shlq ~a, ~a" (render-op-x86 src) (render-op-x86 dst))]
      [`(negq ,srcdst) (format "negq ~a" (render-op-x86 srcdst))]
      [`(movq ,src ,dst) (format "movq ~a, ~a" (render-op-x86 src) (render-op-x86 dst))]
      [`(movabsq ,src ,dst) (format "movabsq ~a, ~a" (render-op-x86 src) (render-op-x86 dst))]
      [`(movzbq ,src ,dst) (format "movzbq ~a, ~a" (render-op-x86 src) (render-op-x86 dst))]
      [`(pushq ,src) (format "pushq ~a" (render-op-x86 src))]
      [`(popq ,dst) (format "popq ~a" (render-op-x86 dst))]
      [`(cmpq ,op0 ,op1) (format "cmpq ~a, ~a" (render-op-x86 op0) (render-op-x86 op1))]
      [`(testq ,op0 ,op1) (format "testq ~a, ~a" (render-op-x86 op0) (render-op-x86 op1))]
      ;; the address of an assembler-local data label (op-name cstrings)
      [`(lea-label ,l ,dst) (format "leaq ~a(%rip), ~a" l (render-op-x86 dst))]
      [`(jmp-if ,cc ,lab) (format "j~a ~a" (render-cc-x86 cc) lab)]
      [`(jmp ,lab) (format "jmp ~a" lab)]
      [`(set ,cc ,byte-reg) (format "set~a ~a" (render-cc-x86 cc) (render-op-x86 byte-reg))]
      [`(callq ,(? label? l) ,(? nonnegative-integer? num-args))
       ;; must call rt-sym here!
       (format "call ~a" (symbol->string (rt-sym l)))]
      ['(retq) "ret"]
      [`(goto ,l) (format "jmp ~a" (symbol->string l))]
      [`(leaq (fun-ref ,f) ,dst) ;; make sure to call (rt-sym f) when rendering f here!
       (format "leaq ~a(%rip), ~a" (rt-sym f) (render-op-x86 dst))]
      [`(indirect-callq ,a) (format "callq *~a" (render-op-x86 a))]
      [`(indirect-jmp ,a) (format "jmp *~a" (render-op-x86 a))]
      ;; direct tail jump to a function label (rt-sym, like callq)
      [`(jmp-direct ,f) (format "jmp ~a" (rt-sym f))]))
;; the code segment as (line-text . instr-node-or-#f) pairs -- the
;; pipeline serializer maps asm lines back to instructions with this
(define (render-lines-x86 p)
  (define functions (set-add (list->set (match p [`(program ,_ (define ,_ (,fs ,_ ...) ,_) ...) fs])) (entry-symbol)))
  (define (block-lines block name)
    (cons (cons (if (set-member? functions name) (format "~a:" (rt-sym name)) (format "~a:" name)) #f)
          (map (λ (instr)
                 ;; a rendered instruction may span several source
                 ;; lines (none do today on x86, but keep it robust)
                 (cons (format "    ~a" (string-replace (render-instr-x86 instr) "\n" "\n    ")) instr))
               block)))
  (define (per-defn defn)
    (match-define `(define ,_ (,f ,formals ...) ,blocks) defn)
    (define rest-keys (sort (filter (λ (k) (not (equal? k f))) (hash-keys blocks))
                            symbol<?))
    (append-map (λ (k) (block-lines (hash-ref blocks k) k)) (cons f rest-keys)))
  (match p
    [`(program ,_ ,defns ...) (append-map per-defn defns)]))

(define (render-x86 p)
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
     (arith-op-cstrings)
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
     (format "~a: .space ~a\n" (rt-sym 'puffin_globals) (max 8 (* 8 n-globals)))))
  (match p
    [`(program ,info ,defns ...)
     (string-append
      (format ".globl ~a\n" (rt-sym (entry-symbol)))
      ".text\n"
      (apply string-append
             (map (λ (ln) (string-append (car ln) "\n")) (render-lines-x86 p)))
      (data-segment info))]))
