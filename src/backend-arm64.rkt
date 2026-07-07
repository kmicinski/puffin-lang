#lang racket

;; Puffin -- backend-arm64.rkt: the AArch64 backend (Apple Silicon).
;;
;; Mirrors backend-x86.rkt pass-for-pass:
;;
;;   select-instructions-arm64     blocks IR -> pseudo-AArch64 over (var x)
;;   allocate-registers-arm64      the same live-range linear scan
;;   patch-instructions-arm64      legalize (loads/stores are explicit,
;;                                 immediate ranges, operand classes)
;;   prelude-and-conclusion-arm64  frames (fp+lr pairs!), callee-saved
;;                                 stp/ldp, pf_init, result printing
;;   render-arm64                  GAS text (+ the same data segment)
;;
;; ABI notes vs x86-64 (see docs/DELTA.md for the full story):
;;  - args in x0-x5 (we use six of the eight so limit-functions
;;    behaves identically across targets), result in x0
;;  - the return address lives in the link register x30, so the
;;    prologue must save x29/x30 as a pair and tail calls must NOT
;;    touch them after restore (we jump through scratch x9)
;;  - memory is only touched by ldr/str: the selector emits x86-ish
;;    `mov`s freely and patch-instructions-arm64 turns memory movs
;;    into loads/stores
;;  - immediates: arithmetic takes 12-bit immediates; anything
;;    bigger is staged through scratch x11 (the assembler's
;;    `ldr xN, =imm` literal-pool pseudo handles the constants)
;;
;; Abstract instructions (operands: imm/reg/var/deref/global):
;;   (mov s d) (add s d) (sub s d) (mul s d) (neg d)
;;   (asr k d) (lsl k d) (orr k d) (and k d)
;;   (cmp a b)              flags of a-b (note: sane order, not AT&T)
;;   (cset cc d)
;;   (jmp l) (jmp-if cc l) (retq)
;;   (callq f n) (indirect-callq op) (tail-jmp op n) (indirect-jmp op)
;;   (lea-fun f d)          address of function f
;;   (ldr (deref ...) d) (str s (deref ...))  after patching
;;   (ldr-global i d) (str-global s i)        after patching

(require "irs.rkt")
(require "system.rkt")
(require "stdlib.rkt")
(require "regalloc.rkt")
(require "provenance.rkt")

(provide (all-defined-out))
(provide arm64-backend-passes)

;; the same literal-table scan as x86 (kept here so each backend is
;; self-contained; the tables are deterministic--sorted--so both
;; backends assign identical ids)
(define (scan-literals-arm p)
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

;; ---------------------------------------------------------------------
;; select-instructions
;; ---------------------------------------------------------------------

(define (select-instructions-arm64 p)
  (define-values (symbol-table string-table) (scan-literals-arm p))
  ;; separate compilation (docs/MODULES.md §3): symbol ids are interned
  ;; at module-init time (they must agree across .o's), so a symbol
  ;; literal is a load from the module's Lpfm_syms slot table rather
  ;; than a compile-time immediate; string literals likewise load
  ;; their init-materialized heap object from Lpfm_strs.
  (define sep? (and (module-sep-mode) #t))
  (define (h-atom a)
    (match a
      ['(void)        `(imm ,void-value)]
      ['(nil)         `(imm ,nil-value)]
      [(? fixnum? n)  `(imm ,(tag-fixnum n))]
      [(? boolean? b) `(imm ,(if b true-value false-value))]
      [`(quote ,s)    (if sep?
                          `(symref ,(index-of symbol-table s))
                          `(imm ,(tag-symbol (index-of symbol-table s))))]
      [(? symbol? x)  `(var ,x)]))
  (define (copy-arguments as)
    (map (λ (a r) `(mov ,(h-atom a) (reg ,r)))
         as (take (argument-registers-list) (length as))))
  ;; ---- open-coded prims (>= -O1; docs/OPTIMIZER.md §5) ---------------
  ;; The arm64 mirror of backend-x86.rkt's open coding: hot
  ;; pair/vector prims emit inline fast paths, and every check the
  ;; runtime prim performs becomes a compare-and-branch to a shared
  ;; per-function TRAP block that calls the original runtime prim --
  ;; it re-checks and errors with the exact original message, and
  ;; never returns (the jmp to the conclusion keeps it well-formed).
  ;; Register discipline: arguments are staged in the argument
  ;; registers (never allocated, never used by patch-instructions'
  ;; x10/x11 staging), so the trap block needs no register shuffling
  ;; and imposes no liveness demands on the allocator; the checks
  ;; scratch only x9 (x10 for the pair?/vector? split below).
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
  ;; check that the value in `r` is a heap object (low bits 001) of
  ;; header kind `k`; branches to the trap otherwise (x9 scratch)
  (define (heap-kind-checks r k trap)
    `((mov (reg ,r) (reg x9))
      (and (imm 7) (reg x9))
      (cmp (reg x9) (imm 1))
      (jmp-if ne ,trap)
      (ldr (deref (reg ,r) -1) (reg x9))  ;; the header word
      (and (imm 255) (reg x9))            ;; its kind byte
      (cmp (reg x9) (imm ,k))
      (jmp-if ne ,trap)))
  ;; check that `ri` holds a tagged fixnum index in bounds for the
  ;; vector in `rv`: (header >> 5) is the TAGGED length ((len<<8)>>5
  ;; = len<<3), so one unsigned compare of tagged index against it
  ;; checks the bound and catches negatives at once
  (define (index-checks ri rv trap)
    `((mov (reg ,ri) (reg x9))
      (and (imm 7) (reg x9))
      (cmp (reg x9) (imm 0))
      (jmp-if ne ,trap)
      (ldr (deref (reg ,rv) -1) (reg x9))
      (asr (imm 5) (reg x9))
      (cmp (reg ,ri) (reg x9))
      (jmp-if ae ,trap)))
  ;; `sink` stores x0 (the result register) into the target
  (define (rhs->instrs rhs sink) (prov-each (rhs->instrs-core rhs sink) rhs))
  (define (rhs->instrs-core rhs sink)
    (match rhs
      [`(+ ,a0 ,a1)
       `((mov ,(h-atom a0) (reg x0))
         (add ,(h-atom a1) (reg x0))
         ,@sink)]
      [`(- ,a)
       `((mov ,(h-atom a) (reg x0))
         (neg (reg x0))
         ,@sink)]
      [`(* ,a0 ,a1)
       `((mov ,(h-atom a0) (reg x0))
         (asr (imm 3) (reg x0))
         (mul ,(h-atom a1) (reg x0))
         ,@sink)]
      [`(,(? shrunk-cmp? cmp) ,a0 ,a1)
       (define cc (match cmp ['eq? 'e] ['< 'l]))
       `((cmp ,(h-atom a0) ,(h-atom a1))
         (cset ,cc (reg x0))
         (lsl (imm 3) (reg x0))
         (orr (imm ,false-value) (reg x0))
         ,@sink)]
      [`(unsafe-vector-ref ,a ,i)
       ;; detag (-1) then an aligned, scaled load of slot i
       `((mov ,(h-atom a) (reg x9))
         (sub (imm 1) (reg x9))
         (ldr (deref (reg x9) ,(* 8 (+ i 1))) (reg x0))
         ,@sink)]
      [`(fun-ref ,f)
       `((lea-fun ,f (reg x0))
         ,@sink)]
      ;; direct calls (>= -O1 anf output): a (fun-ref f) rator
      ;; becomes a direct bl to f's label -- same argument and
      ;; arity-register protocol as the indirect case
      [`(app (fun-ref ,f) ,args ...)
       `(,@(copy-arguments args)
         (mov (imm ,(tag-fixnum (length args))) (reg x12))
         (callq ,f ,(length args))
         ,@sink)]
      [`(papp ,n (fun-ref ,f) ,args ...)
       `(,@(copy-arguments args)
         (mov (imm ,(tag-fixnum n)) (reg x12))
         (callq ,f ,(length args))
         ,@sink)]
      [`(app ,a-f ,args ...)
       `(,@(copy-arguments args)
         (mov (imm ,(tag-fixnum (length args))) (reg x12))
         (indirect-callq ,(h-atom a-f))
         ,@sink)]
      [`(papp ,n ,a-f ,args ...)
       ;; packed call: the arity register carries the ORIGINAL count
       `(,@(copy-arguments args)
         (mov (imm ,(tag-fixnum n)) (reg x12))
         (indirect-callq ,(h-atom a-f))
         ,@sink)]
      [`(global-ref ,i)
       `((ldr-global ,i (reg x0))
         ,@sink)]
      [`(string-lit ,s)
       (if sep?
           `((ldr-slot Lpfm_strs ,(index-of string-table s) (reg x0))
             ,@sink)
           `((mov (imm ,(tag-fixnum (index-of string-table s))) (reg x0))
             (callq pf_string_const 1)
             ,@sink))]
      ;; open-coded pair/vector prims (>= -O1): inline fast paths,
      ;; checks branch to the shared trap block (see above)
      [`(null? ,a) #:when (open-code-prims?)
       ;; (null? x) is (eq? x '()): the eq? compare/cset/tag sequence
       `((cmp ,(h-atom a) (imm ,nil-value))
         (cset e (reg x0))
         (lsl (imm 3) (reg x0))
         (orr (imm ,false-value) (reg x0))
         ,@sink)]
      [`(,(and op (or 'car 'cdr)) ,a) #:when (open-code-prims?)
       ;; pair layout: | header | car | cdr |, tagged ptr = addr + 1
       `((mov ,(h-atom a) (reg x0))
         ,@(heap-kind-checks 'x0 heap-kind/pair (trap-label! op 1))
         (ldr (deref (reg x0) ,(match op ['car 7] ['cdr 15])) (reg x0))
         ,@sink)]
      [`(vector-length ,a) #:when (open-code-prims?)
       `((mov ,(h-atom a) (reg x0))
         ,@(heap-kind-checks 'x0 heap-kind/vector (trap-label! 'vector-length 1))
         (ldr (deref (reg x0) -1) (reg x0))
         (asr (imm 5) (reg x0))         ;; header>>5: the tagged length
         ,@sink)]
      [`(vector-ref ,a ,i) #:when (open-code-prims?)
       ;; a tagged index IS a byte offset: element i is at [v+i*8+7];
       ;; compute the address with an add, then load off it
       (define trap (trap-label! 'vector-ref 2))
       `((mov ,(h-atom a) (reg x0))
         (mov ,(h-atom i) (reg x1))
         ,@(heap-kind-checks 'x0 heap-kind/vector trap)
         ,@(index-checks 'x1 'x0 trap)
         (add (reg x1) (reg x0))
         (ldr (deref (reg x0) 7) (reg x0))
         ,@sink)]
      [`(vector-set! ,a ,i ,v) #:when (open-code-prims?)
       (define trap (trap-label! 'vector-set! 3))
       `((mov ,(h-atom a) (reg x0))
         (mov ,(h-atom i) (reg x1))
         (mov ,(h-atom v) (reg x2))
         ,@(heap-kind-checks 'x0 heap-kind/vector trap)
         ,@(index-checks 'x1 'x0 trap)
         (add (reg x1) (reg x0))
         (str (reg x2) (deref (reg x0) 7))
         (mov (imm ,void-value) (reg x0))
         ,@sink)]
      [`(,(? stdlib-prim? op) ,args ...)
       `(,@(copy-arguments args)
         (callq ,(stdlib-rt-sym op) ,(length args))
         ,@sink)]
      [a
       `((mov ,(h-atom a) (reg x0))
         ,@sink)]))
  (define (h seq)
    ;; instructions not already tagged (by rhs->instrs) belong to
    ;; the head statement of this tail
    (prov-each (h-core seq)
               (match seq [`(seq ,s ,_) s] [_ seq])))
  (define (h-core seq)
    (match seq
      [`(return ,a)
       `((mov ,(h-atom a) (reg x0))
         (jmp ,(conclusion-block-name)))]
      ;; direct tail call (>= -O1 anf output): no target register
      ;; needed; prelude-and-conclusion expands tail-jmp-direct into
      ;; epilogue + a direct b to f's label
      [`(tail-app ,n (fun-ref ,f) ,args ...)
       `(,@(copy-arguments args)
         (mov (imm ,(tag-fixnum n)) (reg x12))
         (tail-jmp-direct ,f ,(length args)))]
      [`(tail-app ,n ,a-f ,args ...)
       ;; x9 is scratch and survives the epilogue expansion
       `((mov ,(h-atom a-f) (reg x9))
         ,@(copy-arguments args)
         (mov (imm ,(tag-fixnum n)) (reg x12))
         (tail-jmp (reg x9) ,(length args)))]
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
                  (prov-each `((mov (imm ,false-value) (reg x0))
                               (mov (reg x0) (var ,x))
                               (jmp ,l-join))
                             stmt))
       (hash-set! extra-blocks l-join (h rst))
       `((mov ,(h-atom a) (reg x9))
         (mov (reg x9) (reg x10))
         (and (imm 7) (reg x10))
         (cmp (reg x10) (imm 1))
         (jmp-if ne ,l-false)
         (ldr (deref (reg x9) -1) (reg x10))
         (and (imm 255) (reg x10))
         (cmp (reg x10) (imm ,k))
         (jmp-if ne ,l-false)
         (mov (imm ,true-value) (reg x0))
         (mov (reg x0) (var ,x))
         (jmp ,l-join))]
      [`(seq (assign ,x ,rhs) ,rst)
       (append (rhs->instrs rhs `((mov (reg x0) (var ,x)))) (h rst))]
      [`(seq (effect ,rhs) ,rst)
       (append (rhs->instrs rhs '()) (h rst))]
      [`(seq (global-set! ,i ,a) ,rst)
       `((mov ,(h-atom a) (reg x10))
         (str-global (reg x10) ,i)
         ,@(h rst))]
      [`(seq (unsafe-vector-set! ,a0 ,i ,a-v) ,rst)
       `((mov ,(h-atom a0) (reg x9))
         (sub (imm 1) (reg x9))
         (mov ,(h-atom a-v) (reg x10))
         (str (reg x10) (deref (reg x9) ,(* 8 (+ i 1))))
         ,@(h rst))]
      [`(if (,cmp ,a0 ,a1) (goto ,l0) (goto ,l1))
       (define cc (match cmp ['eq? 'e] ['< 'l] ['<= 'le] ['> 'g] ['>= 'ge]))
       `((cmp ,(h-atom a0) ,(h-atom a1))
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
         ;; variadic prologue (see backend-x86.rkt): spill arg regs,
         ;; call pf_collect_rest(k, n=x12), reload the fixed formals
         (define fixed (take args mi))
         (define rest-name (list-ref args (add1 mi)))
         `(,@(map (λ (r i) `(str-argspill (reg ,r) ,i))
                  (argument-registers-list) (range 6))
           (mov (imm ,(tag-fixnum (length fixed))) (reg x0))
           (mov (reg x12) (reg x1))
           (callq pf_collect_rest 2)
           (mov (reg x0) (var ,rest-name))
           ,@(map (λ (a i) `(ldr-argspill ,i (var ,a)))
                  fixed (range (length fixed))))]
        [else
         (map (λ (a r) `(mov (reg ,r) (var ,a)))
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
;; allocate-registers
;; ---------------------------------------------------------------------

(define (arm64-uses+defs i)
  (define (vars-of . ops)
    (append-map (λ (op) (match op [`(var ,x) (list x)] [_ '()])) ops))
  (match i
    [`(mov ,src ,dst)    (list (vars-of src) (vars-of dst))]
    [`(ldr ,src ,dst)    (list (vars-of src) (vars-of dst))]
    [`(str ,src ,dst)    (list (vars-of src dst) '())]
    [`(ldr-global ,_ ,dst) (list '() (vars-of dst))]
    [`(str-global ,src ,_) (list (vars-of src) '())]
    [`(ldr-slot ,_ ,_ ,dst) (list '() (vars-of dst))]
    [`(str-slot ,src ,_ ,_) (list (vars-of src) '())]
    [`(ldr-argspill ,_ ,dst) (list '() (vars-of dst))]
    [`(str-argspill ,src ,_) (list (vars-of src) '())]
    [`(lea-fun ,_ ,dst)  (list '() (vars-of dst))]
    [`(,(or 'add 'sub 'mul 'orr) ,src ,dst)
     (list (vars-of src dst) (vars-of dst))]
    [`(neg ,dst)         (list (vars-of dst) (vars-of dst))]
    [`(,(or 'asr 'lsl 'and) ,_ ,dst) (list (vars-of dst) (vars-of dst))]
    [`(cmp ,a ,b)        (list (vars-of a b) '())]
    [`(cset ,_ ,dst)     (list '() (vars-of dst))]
    [`(indirect-callq ,a) (list (vars-of a) '())]
    [`(tail-jmp ,a ,_)   (list (vars-of a) '())]
    [_ (list '() '())]))

(define (allocate-registers-arm64 p)
  (allocate-registers-with p arm64-uses+defs))

;; ---------------------------------------------------------------------
;; patch-instructions: make every instruction encodable
;;   - loads/stores become explicit (mov mem->x / x->mem)
;;   - ALU operands must be registers (except small immediates)
;;   - big immediates stage through x11 (ldr =imm)
;; scratch discipline: x9/x10 are used by the selector inside a
;; statement; the patcher uses x11 (and x10 for a second operand)
;; so patched code never collides with selector scratch.
;; ---------------------------------------------------------------------

(define (patch-instructions-arm64 p)
  (define (mem? op) (or (deref? op) (global? op)))
  (define (small-imm? op)
    (match op [`(imm ,i) (and (>= i 0) (< i 4096))] [_ #f]))
  (define (mov-imm-ok? op)
    ;; mov (wide immediate) handles 16-bit patterns; keep it simple
    (match op [`(imm ,i) (and (>= i 0) (< i 65536))] [_ #f]))
  ;; load operand into a given scratch register, returning (instrs reg-op)
  (define (into-reg op scratch)
    (match op
      [`(reg ,_) (values '() op)]
      [`(imm ,_) (if (mov-imm-ok? op)
                     (values `((mov ,op (reg ,scratch))) `(reg ,scratch))
                     (values `((ldr-imm ,op (reg ,scratch))) `(reg ,scratch)))]
      [`(deref ,_ ,_) (values `((ldr ,op (reg ,scratch))) `(reg ,scratch))]
      [`(global ,i) (values `((ldr-global ,i (reg ,scratch))) `(reg ,scratch))]
      ;; separate compilation: a symbol literal is slot i of the
      ;; module's init-interned symbol table (see select-instructions)
      [`(symref ,i) (values `((ldr-slot Lpfm_syms ,i (reg ,scratch))) `(reg ,scratch))]))
  (define (patch-instr instr) (prov-each (patch-instr-core instr) instr))
  (define (patch-instr-core instr)
    (match instr
      ;; mov: memory and large immediates get staged
      [`(mov ,src ,dst)
       (match* (src dst)
         [(`(reg ,_) `(reg ,_)) (list instr)]
         [((? mov-imm-ok?) `(reg ,_)) (list instr)]
         [(`(imm ,_) `(reg ,_)) `((ldr-imm ,src ,dst))]
         [((? mem?) `(reg ,_)) `((ldr ,src ,dst))]
         [(`(symref ,i) `(reg ,_)) `((ldr-slot Lpfm_syms ,i ,dst))]
         [(_ (? mem?))
          (define-values (is r) (into-reg src 'x11))
          `(,@is (str ,r ,dst))]
         [(_ _) (list instr)])]
      ;; ALU: dst must be a register; src register or small imm
      [`(,(and op (or 'add 'sub 'mul 'orr)) ,src ,dst)
       (cond
         [(and (reg? dst) (or (reg? src) (and (small-imm? src) (not (equal? op 'mul)))))
          (list instr)]
         [(reg? dst)
          (define-values (is r) (into-reg src 'x11))
          `(,@is (,op ,r ,dst))]
         [else
          ;; dst in memory: load, operate, store back
          (define-values (is-s r-s) (into-reg src 'x11))
          `((ldr ,dst (reg x10))
            ,@is-s
            (,op ,r-s (reg x10))
            (str (reg x10) ,dst))])]
      [`(,(and op (or 'neg 'asr 'lsl 'and)) ,args ... ,dst)
       (if (reg? dst)
           (list instr)
           `((ldr ,dst (reg x10))
             (,op ,@args (reg x10))
             (str (reg x10) ,dst)))]
      [`(cset ,cc ,dst)
       (if (reg? dst)
           (list instr)
           `((cset ,cc (reg x10))
             (str (reg x10) ,dst)))]
      [`(cmp ,a ,b)
       (define-values (is-a r-a) (into-reg a 'x10))
       (cond
         [(or (reg? b) (small-imm? b))
          `(,@is-a (cmp ,r-a ,b))]
         [else
          (define-values (is-b r-b) (into-reg b 'x11))
          `(,@is-a ,@is-b (cmp ,r-a ,r-b))])]
      [`(indirect-callq ,op)
       (if (reg? op)
           (list instr)
           (let-values ([(is r) (into-reg op 'x11)])
             `(,@is (indirect-callq ,r))))]
      [`(lea-fun ,f ,dst)
       (if (reg? dst)
           (list instr)
           `((lea-fun ,f (reg x11))
             (str (reg x11) ,dst)))]
      [`(ldr-global ,i ,dst)
       (if (reg? dst)
           (list instr)
           `((ldr-global ,i (reg x11))
             (str (reg x11) ,dst)))]
      [`(str-global ,src ,i)
       (if (reg? src)
           (list instr)
           (let-values ([(is r) (into-reg src 'x11)])
             `(,@is (str-global ,r ,i))))]
      [`(ldr-argspill ,i ,dst)
       (if (reg? dst)
           (list instr)
           `((ldr-argspill ,i (reg x11))
             (str (reg x11) ,dst)))]
      [`(str-argspill ,src ,i)
       (if (reg? src)
           (list instr)
           (let-values ([(is r) (into-reg src 'x11)])
             `(,@is (str-argspill ,r ,i))))]
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

(define (patched-program-arm64? p)
  ;; after patching: no (var _) anywhere (regalloc) and every mov is
  ;; register/immediate-to-register
  (define (ok-instr? i)
    (match i
      [`(mov ,src ,dst) (and (reg? dst) (or (reg? src) (imm? src)))]
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
;; ---------------------------------------------------------------------

;; ---------------------------------------------------------------------
;; separate-compilation init preamble (docs/MODULES.md §3): a module's
;; init function (or main, in the entry unit) interns the unit's
;; symbol literals and materializes its string literals into local
;; slot tables before any user code runs. Straight-line, pre-patched
;; instructions (this runs after patch-instructions): only x0/x1/x16
;; and the callee's caller-saved registers are touched, at a point
;; where nothing is live.
;; ---------------------------------------------------------------------

(define (literal-init-instrs prog-info)
  (define symbols (hash-ref prog-info 'symbols '()))
  (define strings (hash-ref prog-info 'strings '()))
  (append
   (append*
    (for/list ([s symbols] [i (in-naturals)])
      `((lea-label ,(string->symbol (format "Lpfsym~a" i)) (reg x0))
        (callq pf_intern_symbol 1)
        (lsl (imm 3) (reg x0))
        (orr (imm 3) (reg x0))
        (str-slot (reg x0) Lpfm_syms ,i))))
   (append*
    (for/list ([s strings] [i (in-naturals)])
      `((lea-label ,(string->symbol (format "Lpfstr~a" i)) (reg x0))
        (ldr-imm (imm ,(bytes-length (string->bytes/utf-8 s))) (reg x1))
        (callq pf_string_from_bytes 2)
        (str-slot (reg x0) Lpfm_strs ,i))))))

;; run-once guard: if the unit's init flag is already set, return
;; (void) through the ordinary conclusion; otherwise set it and fall
;; through into the init body
(define (init-guard-instrs conclusion-label)
  `((ldr-slot Lpfm_initflag 0 (reg x9))
    (mov (imm ,void-value) (reg x0))
    (cmp (reg x9) (imm 0))
    (jmp-if ne ,conclusion-label)
    (mov (imm 1) (reg x10))
    (str-slot (reg x10) Lpfm_initflag 0)))

(define (prelude-and-conclusion-arm64 p)
  (define (rename-conclusion blocks name)
    (define (h instr)
      (match instr
        [`(jmp ,blk) #:when (equal? blk (conclusion-block-name))
         `(jmp ,name)]
        [i i]))
    (foldl (lambda (k acc) (hash-set acc k (map h (hash-ref blocks k))))
           (hash)
           (hash-keys blocks)))
  ;; pair up callee-saved registers for stp/ldp (odd tail uses str/ldr
  ;; but still consumes a full 16-byte slot to keep sp aligned)
  (define (save-pairs regs)
    (match regs
      ['() '()]
      [`(,a) `((,a))]
      [`(,a ,b . ,rest) (cons (list a b) (save-pairs rest))]))
  (define sep (module-sep-mode))
  (define sep-kind (and sep (hash-ref sep 'kind)))
  (define (per-defn defn prog-info)
    (match defn
      [`(define ,info (,f ,args ...) ,blocks)
       (define callee-saved (hash-ref info 'callee-saved '()))
       (define spill-bytes (hash-ref info 'spill-bytes 0))
       (define save-bytes (callee-save-area-bytes (length callee-saved)))
       ;; sp stays 16-aligned: round the spill area up
       (define frame-bytes (* 16 (ceiling (/ spill-bytes 16))))
       (define pairs (save-pairs callee-saved))
       (define saves
         (append-map (λ (pr)
                       (match pr
                         [`(,a ,b) `((stp ,a ,b))]
                         [`(,a)    `((stp ,a #f))])) ;; str + pad
                     pairs))
       (define restores
         (append-map (λ (pr)
                       (match pr
                         [`(,a ,b) `((ldp ,a ,b))]
                         [`(,a)    `((ldp ,a #f))]))
                     (reverse pairs)))
       (define entry? (equal? f (entry-symbol)))
       (define my-conclusion (gensym 'conclusion))
       ;; what runs between the prologue and the user code:
       ;;   whole-program main      pf_init
       ;;   separate entry main     pf_init, own literals, then every
       ;;                           module init in require-DAG postorder
       ;;   separate module init    run-once guard, own literals
       (define entry-extras
         (cond
           [(not entry?) '()]
           [(not sep) `((callq pf_init 0))]
           [(eq? sep-kind 'entry)
            `((callq pf_init 0)
              ,@(literal-init-instrs prog-info)
              ,@(map (λ (l) `(callq ,l 0)) (hash-ref sep 'init-calls '())))]
           [else ;; 'module
            `(,@(init-guard-instrs my-conclusion)
              ,@(literal-init-instrs prog-info))]))
       (define start-block (hash-ref blocks f))
       (define new-start-block
         `((frame-push)               ;; stp x29, x30, [sp, #-16]!; mov x29, sp
           ,@saves
           ,@(if (zero? frame-bytes) '() `((sp-sub ,frame-bytes)))
           ,@entry-extras
           ,@start-block))
       (define restore
         `(,@(if (zero? frame-bytes) '() `((sp-add ,frame-bytes)))
           ,@restores
           (frame-pop)                ;; ldp x29, x30, [sp], #16
           (retq)))
       (define conclusion-block
         (if (and entry? (not (eq? sep-kind 'module)))
             `(;; result already in x0: print it, then return 0
               (callq pf_print_result 0)
               (mov (imm 0) (reg x0))
               ,@restore)
             restore))
       (define (expand-tail-jmp instrs)
         (append-map
          (λ (i)
            (match i
              [(and tj `(tail-jmp ,op ,_))
               (prov-each `(,@(if (zero? frame-bytes) '() `((sp-add ,frame-bytes)))
                 ,@restores
                 (frame-pop)
                 (indirect-jmp ,op))
                tj)]
              [(and tj `(tail-jmp-direct ,f-target ,_))
               (prov-each `(,@(if (zero? frame-bytes) '() `((sp-add ,frame-bytes)))
                 ,@restores
                 (frame-pop)
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
     `(program ,info ,@(map (λ (d) (per-defn d info)) defns))]))

;; ---------------------------------------------------------------------
;; render
;; ---------------------------------------------------------------------

;; Materialize an arbitrary 64-bit immediate with movz/movk (or
;; movn/movk for mostly-ones values). No literal pools: `ldr =imm`
;; fixups go out of range once .text exceeds +-1MB, which large
;; programs (puffincc itself) hit.
(define (render-mov-imm64 dst i)
  (define u (bitwise-and i #xFFFFFFFFFFFFFFFF))
  (define hws (for/list ([k 4]) (bitwise-and (arithmetic-shift u (* -16 k)) #xFFFF)))
  (define nz (for/sum ([h hws]) (if (= h 0) 0 1)))
  (define nf (for/sum ([h hws]) (if (= h #xFFFF) 0 1)))
  (define (movks skip-idx skip-val)
    (for/list ([h hws] [k (in-naturals)]
               #:when (and (not (= k skip-idx)) (not (= h skip-val))))
      (format "movk ~a, #~a, lsl #~a" dst h (* 16 k))))
  (cond
    [(zero? nz) (format "movz ~a, #0" dst)]
    [(< nf nz)
     ;; mostly ffff: movn the first non-ffff halfword, movk the rest
     (define first-idx (or (for/first ([h hws] [k (in-naturals)] #:when (not (= h #xFFFF))) k) 0))
     (define first (list-ref hws first-idx))
     (string-join
      (cons (format "movn ~a, #~a, lsl #~a" dst (bitwise-and (bitwise-not first) #xFFFF) (* 16 first-idx))
            (movks first-idx #xFFFF))
      "\n    ")]
    [else
     (define first-idx (for/first ([h hws] [k (in-naturals)] #:when (not (= h 0))) k))
     (define first (list-ref hws first-idx))
     (string-join
      (cons (format "movz ~a, #~a, lsl #~a" dst first (* 16 first-idx))
            (movks first-idx 0))
      "\n    ")]))

;; instruction rendering, shared by render-arm64 and the pipeline
;; serializer's per-line provenance (ir-json.rkt)
(define (reg-name op) (match op [`(reg ,r) (symbol->string r)]))
(define (render-op-arm op)
    (match op
      [`(imm ,i) (format "#~a" i)]
      [`(reg ,x) (symbol->string x)]))
(define (render-cc-arm cc)
  (match cc ['e "eq"] ['ne "ne"] ['l "lt"] ['le "le"] ['g "gt"] ['ge "ge"] ['ae "hs"]))
;; an fp-relative slot: ldur/stur handle +-255 directly; farther
;; slots compute the address in x16 (the linker-scratch register)
(define (render-mem-access ldr? op mem)
    (match mem
      [`(deref (reg ,base) ,off)
       (cond
         [(and (<= -256 off 255))
          (format "~a ~a, [~a, #~a]" (if ldr? "ldur" "stur") (reg-name op) base off)]
         [(and (>= off 0) (zero? (modulo off 8)) (<= off 32760))
          (format "~a ~a, [~a, #~a]" (if ldr? "ldr" "str") (reg-name op) base off)]
         [else
          (format "mov x16, #~a\n    add x16, x16, ~a\n    ~a ~a, [x16]"
                  off base (if ldr? "ldr" "str") (reg-name op))])]))
;; sp +- n: add/sub immediates encode 12 bits, optionally shifted
;; left 12; frames larger than 4095 bytes emit the page part and the
;; remainder separately (n is always a positive multiple of 16)
(define (sp-adjust op n)
  (define hi (arithmetic-shift n -12))
  (define lo (bitwise-and n 4095))
  (unless (< hi 4096)
    (error 'render "frame too large for sp adjustment: ~a bytes" n))
  (cond
    [(zero? hi) (format "~a sp, sp, #~a" op n)]
    [(zero? lo) (format "~a sp, sp, #~a, lsl #12" op hi)]
    [else (format "~a sp, sp, #~a, lsl #12\n    ~a sp, sp, #~a" op hi op lo)]))

(define (render-instr-arm instr)
  (define globals-sym (rt-sym (module-globals-label)))
  (match instr
      ;; separate compilation: a slot in another module's globals
      ;; array -- the label is external (.globl on the defining side)
      [`(ldr-global (ext ,lbl ,k) ,dst)
       (format "adrp x16, ~a@PAGE\n    add x16, x16, ~a@PAGEOFF\n    ldr ~a, [x16, #~a]"
               (rt-sym lbl) (rt-sym lbl) (reg-name dst) (* 8 k))]
      [`(str-global ,src (ext ,lbl ,k))
       (format "adrp x16, ~a@PAGE\n    add x16, x16, ~a@PAGEOFF\n    str ~a, [x16, #~a]"
               (rt-sym lbl) (rt-sym lbl) (reg-name src) (* 8 k))]
      ;; separate compilation: assembler-local data (slot tables, the
      ;; init flag, cstring addresses) -- labels are used verbatim
      [`(lea-label ,l ,dst)
       (format "adrp ~a, ~a@PAGE\n    add ~a, ~a, ~a@PAGEOFF"
               (reg-name dst) l (reg-name dst) (reg-name dst) l)]
      [`(ldr-slot ,l ,i ,dst)
       (format "adrp x16, ~a@PAGE\n    add x16, x16, ~a@PAGEOFF\n    ldr ~a, [x16, #~a]"
               l l (reg-name dst) (* 8 i))]
      [`(str-slot ,src ,l ,i)
       (format "adrp x16, ~a@PAGE\n    add x16, x16, ~a@PAGEOFF\n    str ~a, [x16, #~a]"
               l l (reg-name src) (* 8 i))]
      [`(mov ,src ,dst) (format "mov ~a, ~a" (reg-name dst) (render-op-arm src))]
      [`(ldr-imm (imm ,i) ,dst) (render-mov-imm64 (reg-name dst) i)]
      [`(ldr ,mem ,dst) (render-mem-access #t dst mem)]
      [`(str ,src ,mem) (render-mem-access #f src mem)]
      [`(add ,src ,dst) (format "add ~a, ~a, ~a" (reg-name dst) (reg-name dst) (render-op-arm src))]
      [`(sub ,src ,dst) (format "sub ~a, ~a, ~a" (reg-name dst) (reg-name dst) (render-op-arm src))]
      [`(mul ,src ,dst) (format "mul ~a, ~a, ~a" (reg-name dst) (reg-name dst) (render-op-arm src))]
      [`(neg ,dst) (format "neg ~a, ~a" (reg-name dst) (reg-name dst))]
      [`(asr (imm ,k) ,dst) (format "asr ~a, ~a, #~a" (reg-name dst) (reg-name dst) k)]
      [`(lsl (imm ,k) ,dst) (format "lsl ~a, ~a, #~a" (reg-name dst) (reg-name dst) k)]
      [`(orr (imm ,k) ,dst) (format "orr ~a, ~a, #~a" (reg-name dst) (reg-name dst) k)]
      [`(and (imm ,k) ,dst) (format "and ~a, ~a, #~a" (reg-name dst) (reg-name dst) k)]
      [`(cmp ,a ,b) (format "cmp ~a, ~a" (reg-name a) (render-op-arm b))]
      [`(cset ,cc ,dst) (format "cset ~a, ~a" (reg-name dst) (render-cc-arm cc))]
      [`(jmp-if ,cc ,lab) (format "b.~a ~a" (render-cc-arm cc) lab)]
      [`(jmp ,lab) (format "b ~a" lab)]
      [`(goto ,l) (format "b ~a" (symbol->string l))]
      [`(callq ,(? label? l) ,_) (format "bl ~a" (symbol->string (rt-sym l)))]
      [`(indirect-callq ,op) (format "blr ~a" (reg-name op))]
      [`(indirect-jmp ,op) (format "br ~a" (reg-name op))]
      ;; direct tail jump to a function label (rt-sym, like callq)
      [`(jmp-direct ,f) (format "b ~a" (rt-sym f))]
      ['(retq) "ret"]
      [`(lea-fun ,f ,dst)
       (format "adrp ~a, ~a@PAGE\n    add ~a, ~a, ~a@PAGEOFF"
               (reg-name dst) (rt-sym f) (reg-name dst) (reg-name dst) (rt-sym f))]
      [`(ldr-global ,i ,dst)
       (format "adrp x16, ~a@PAGE\n    add x16, x16, ~a@PAGEOFF\n    ldr ~a, [x16, #~a]"
               globals-sym globals-sym (reg-name dst) (* 8 i))]
      [`(str-global ,src ,i)
       (format "adrp x16, ~a@PAGE\n    add x16, x16, ~a@PAGEOFF\n    str ~a, [x16, #~a]"
               globals-sym globals-sym (reg-name src) (* 8 i))]
      [`(ldr-argspill ,i ,dst)
       (format "adrp x16, ~a@PAGE\n    add x16, x16, ~a@PAGEOFF\n    ldr ~a, [x16, #~a]"
               (rt-sym 'pf_arg_spill) (rt-sym 'pf_arg_spill) (reg-name dst) (* 8 i))]
      [`(str-argspill ,src ,i)
       (format "adrp x16, ~a@PAGE\n    add x16, x16, ~a@PAGEOFF\n    str ~a, [x16, #~a]"
               (rt-sym 'pf_arg_spill) (rt-sym 'pf_arg_spill) (reg-name src) (* 8 i))]
      ['(frame-push) "stp x29, x30, [sp, #-16]!\n    mov x29, sp"]
      ['(frame-pop) "ldp x29, x30, [sp], #16"]
      ;; add/sub immediates encode 12 bits (optionally shifted 12);
      ;; big frames (large spill counts) split into a shifted-page
      ;; part and a remainder
      [`(sp-sub ,n) (sp-adjust "sub" n)]
      [`(sp-add ,n) (sp-adjust "add" n)]
      [`(stp ,a ,b) (if b
                        (format "stp ~a, ~a, [sp, #-16]!" a b)
                        (format "str ~a, [sp, #-16]!" a))]
      [`(ldp ,a ,b) (if b
                        (format "ldp ~a, ~a, [sp], #16" a b)
                        (format "ldr ~a, [sp], #16" a))]))
;; the code segment as (line-text . instr-node-or-#f) pairs
(define (render-lines-arm64 p)
  (define functions (set-add (list->set (match p [`(program ,_ (define ,_ (,fs ,_ ...) ,_) ...) fs])) (entry-symbol)))
  (define (block-lines block name)
    (cons (cons (if (set-member? functions name) (format "~a:" (rt-sym name)) (format "~a:" name)) #f)
          (map (λ (instr)
                 ;; several arm instructions render as multiple lines
                 (cons (format "    ~a" (render-instr-arm instr)) instr))
               block)))
  (define (per-defn defn)
    (match-define `(define ,_ (,f ,formals ...) ,blocks) defn)
    (define rest-keys (sort (filter (λ (k) (not (equal? k f))) (hash-keys blocks))
                            symbol<?))
    (append-map (λ (k) (block-lines (hash-ref blocks k) k)) (cons f rest-keys)))
  (match p
    [`(program ,_ ,defns ...) (append-map per-defn defns)]))

(define (render-arm64 p)
  (define (escape-c s)
    (apply string-append
           (map (λ (ch)
                  (match ch
                    [#\\ "\\\\"] [#\" "\\\""] [#\newline "\\n"] [#\tab "\\t"]
                    [_ (string ch)]))
                (string->list s))))
  ;; separate compilation: no whole-program literal tables (pf_init
  ;; would intern them with ids that can't agree across .o's).
  ;; Instead: the same cstrings, two local slot tables the unit's
  ;; init preamble fills (interned symbol words / materialized heap
  ;; strings -- the GC scans __DATA, so they are roots), the
  ;; run-once flag, and the unit's own exported globals array.
  (define (data-segment-sep info kind)
    (define symbols (hash-ref info 'symbols '()))
    (define strings (hash-ref info 'strings '()))
    (define n-globals (hash-ref info 'globals 0))
    (define gsym (rt-sym (module-globals-label)))
    (string-append
     ".section __TEXT,__cstring,cstring_literals\n"
     (apply string-append
            (for/list ([s symbols] [i (in-naturals)])
              (format "Lpfsym~a: .asciz \"~a\"\n" i (escape-c (symbol->string s)))))
     (apply string-append
            (for/list ([s strings] [i (in-naturals)])
              (format "Lpfstr~a: .asciz \"~a\"\n" i (escape-c s))))
     ".section __DATA,__data\n"
     ".p2align 3\n"
     (format "Lpfm_syms: .space ~a\n" (max 8 (* 8 (length symbols))))
     (format "Lpfm_strs: .space ~a\n" (max 8 (* 8 (length strings))))
     (if (eq? kind 'module) "Lpfm_initflag: .space 8\n" "")
     (format ".globl ~a\n" gsym)
     (format "~a: .space ~a\n" gsym (max 8 (* 8 n-globals)))))
  (define (data-segment info)
    (define symbols (hash-ref info 'symbols '()))
    (define strings (hash-ref info 'strings '()))
    (define n-globals (hash-ref info 'globals 0))
    (string-append
     ".section __TEXT,__cstring,cstring_literals\n"
     (apply string-append
            (for/list ([s symbols] [i (in-naturals)])
              (format "Lpfsym~a: .asciz \"~a\"\n" i (escape-c (symbol->string s)))))
     (apply string-append
            (for/list ([s strings] [i (in-naturals)])
              (format "Lpfstr~a: .asciz \"~a\"\n" i (escape-c s))))
     ".section __DATA,__data\n"
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
  (define sep (module-sep-mode))
  (match p
    [`(program ,info ,defns ...)
     (string-append
      (format ".globl ~a\n" (rt-sym (entry-symbol)))
      (if sep
          (apply string-append
                 (for/list ([l (hash-ref sep 'exports '())]
                            #:unless (equal? l (entry-symbol)))
                   (format ".globl ~a\n" (rt-sym l))))
          "")
      ".text\n.p2align 2\n"
      (apply string-append
             (map (λ (ln) (string-append (car ln) "\n")) (render-lines-arm64 p)))
      (if sep
          (data-segment-sep info (hash-ref sep 'kind))
          (data-segment info)))]))

;; the pass table main.rkt splices in for --target arm64
(define (arm64-backend-passes)
  (list
   `(,select-instructions-arm64     "select-instructions"    ,locals-program?         ,instr-program?           ,dummy-interp-arm)
   `(,allocate-registers-arm64      "allocate-registers"     ,instr-program?          ,homes-assigned-program?  ,dummy-interp-arm)
   `(,patch-instructions-arm64      "patch-instructions"     ,homes-assigned-program? ,patched-program-arm64?   ,dummy-interp-arm)
   `(,prelude-and-conclusion-arm64  "prelude-and-conclusion" ,patched-program-arm64?  ,homes-assigned-program?  ,dummy-interp-arm)
   `(,render-arm64                  "render-asm"             ,homes-assigned-program? ,string?                  ,dummy-interp-arm)))

(define (dummy-interp-arm p i)
  "instruction-level IR not interpreted; validated by running the native binary")
