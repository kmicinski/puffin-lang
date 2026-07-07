#lang racket

;; Puffin -- backend-bytecode.rkt: the bytecode backend (docs/WASM-VM.md
;; variant B, milestone M1; format spec in docs/BYTECODE.md).
;;
;; Mirrors the native backends in shape, consuming the same
;; post-uncover-locals blocks IR, but targets the frame-slot virtual
;; machine (src/vm/puffin-vm.c) instead of an ISA:
;;
;;   select-instructions-bc   blocks IR -> bytecode instrs over
;;                            (var x)/(stage k) slot operands, still
;;                            grouped in labeled blocks
;;   allocate-slots-bc        replaces allocate-registers: number the
;;                            locals (formals first, the rest sorted --
;;                            deterministic output is part of the
;;                            bootstrap fixpoint discipline), resolve
;;                            (var x)/(stage k) to slot indices
;;   linearize-bc             replaces patch-instructions: order blocks
;;                            (entry first, fall-through favoring DFS),
;;                            lower two-way branch tails, drop jumps to
;;                            the next block
;;   render-pbc               binary encoding of the unit (a bytes?);
;;                            main.rkt writes it as the .pbc output
;;                            and skips the assembler/linker entirely
;;
;; Contract notes (docs/BYTECODE.md is the authority):
;;  - The call convention mirrors native: at most 6 argument slots,
;;    the logical arity travels with every call (the VM register that
;;    replaces native r10/x12), packed calls (papp, >6 args) put the
;;    overflow vector in the sixth slot, and the variadic prologue is
;;    one COLLECT instruction backed by the same pf_collect_rest.
;;  - Closure slot 0 holds a *function index* as a tagged fixnum
;;    (fun-ref renders as FUNREF), never a raw code pointer.
;;  - Prims are PRIM calls through the manifest-ordered table (no
;;    open-coding in v1, even at -O1); the VM's table is generated
;;    from the same stdlib.rkt manifest (src/gen-vm-prims.rkt).
;;  - Proper tail calls are TCALL/TCALLI: the VM reuses the frame, so
;;    all tail calls run in constant stack space, like native tail-jmp.

(require "irs.rkt")
(require "system.rkt")
(require "stdlib.rkt")
(require "provenance.rkt")

(provide (all-defined-out))
(provide bytecode-backend-passes)

;; ---------------------------------------------------------------------
;; The version word written into every unit header. Bump it whenever
;; the instruction encoding or the unit layout changes; the VM
;; refuses units whose version it does not implement.
;; ---------------------------------------------------------------------
(define pbc-version 1)

;; prim ids: the index of the prim in the stdlib manifest, in
;; manifest order -- the VM's table (src/vm/vm-prims.inc) is
;; generated from the same list in the same order.
(define prim-ids
  (for/hash ([s stdlib-primitives] [i (in-naturals)])
    (values (prim-spec-name s) i)))
(define (prim-id op)
  (hash-ref prim-ids op (λ () (error 'backend-bytecode "no prim id for ~a" op))))

;; the same literal-table scan as the native backends (sorted, so
;; every backend assigns identical ids)
(define (scan-literals-bc p)
  (define symbols (mutable-set))
  (define strings (mutable-set))
  (define (scan-atom a)
    (match a
      [`(quote ,s) (set-add! symbols s)]
      [_ (void)]))
  (define (scan-rhs rhs)
    (match rhs
      [`(string-lit ,s) (set-add! strings s)]
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
;; select-instructions-bc
;;
;; Slot operands at this level: (var x) for a named local, (stage k)
;; for slot k of the per-function staging area (call arguments and
;; literal materialization; allocate-slots-bc places the staging area
;; after the named locals). Literals never appear as instruction
;; operands: they are staged with IMM/SYM first, which keeps the
;; instruction set's operand model uniform (every operand is a slot).
;; ---------------------------------------------------------------------

(define (select-instructions-bc p)
  (define-values (symbol-table string-table) (scan-literals-bc p))
  ;; an atom as a "loadable": (var x) | (lit tagged-word) | (symlit i)
  (define (h-atom a)
    (match a
      ['(void)        `(lit ,void-value)]
      ['(nil)         `(lit ,nil-value)]
      [(? fixnum? n)  `(lit ,(tag-fixnum n))]
      [(? boolean? b) `(lit ,(if b true-value false-value))]
      [`(quote ,s)    `(symlit ,(index-of symbol-table s))]
      [(? symbol? x)  `(var ,x)]))
  ;; load an atom into destination slot d (any slot operand)
  (define (load-into d a)
    (match (h-atom a)
      [`(var ,x)    `((mov ,d (var ,x)))]
      [`(lit ,w)    `((imm ,d ,w))]
      [`(symlit ,i) `((sym ,d ,i))]))
  ;; an atom as a *source* operand: returns (values instrs slot),
  ;; staging literals in staging slot k
  (define (src-operand a k)
    (match (h-atom a)
      [`(var ,x) (values '() `(var ,x))]
      [_         (values (load-into `(stage ,k) a) `(stage ,k))]))
  ;; stage call arguments into (stage 0..n-1)
  (define (stage-args args)
    (append*
     (for/list ([a args] [i (in-naturals)])
       (load-into `(stage ,i) a))))
  ;; calls, shared by assign/effect/tail positions. dst = #f => tail.
  (define (emit-call dst rator args arity)
    (define n (length args))
    (match rator
      [`(fun-ref ,f)
       `(,@(stage-args args)
         ,(if dst
              `(call ,dst ,f (stage 0) ,n ,arity)
              `(tcall ,f (stage 0) ,n ,arity)))]
      [a
       ;; the callee value is read before the VM copies the staged
       ;; arguments, so staging slot n is a safe home for it
       (define-values (is fs) (src-operand a n))
       `(,@(stage-args args)
         ,@is
         ,(if dst
              `(calli ,dst ,fs (stage 0) ,n ,arity)
              `(tcalli ,fs (stage 0) ,n ,arity)))]))
  ;; a non-tail rhs computed into destination slot d
  (define (rhs->instrs rhs d) (prov-each (rhs->instrs-core rhs d) rhs))
  (define (rhs->instrs-core rhs d)
    (match rhs
      [`(+ ,a0 ,a1)
       (define-values (i0 s0) (src-operand a0 0))
       (define-values (i1 s1) (src-operand a1 1))
       `(,@i0 ,@i1 (add ,d ,s0 ,s1))]
      [`(- ,a)
       (define-values (i0 s0) (src-operand a 0))
       `(,@i0 (neg ,d ,s0))]
      [`(* ,a0 ,a1)
       (define-values (i0 s0) (src-operand a0 0))
       (define-values (i1 s1) (src-operand a1 1))
       `(,@i0 ,@i1 (mul ,d ,s0 ,s1))]
      [`(,(? shrunk-cmp? cmp) ,a0 ,a1)
       (define-values (i0 s0) (src-operand a0 0))
       (define-values (i1 s1) (src-operand a1 1))
       `(,@i0 ,@i1 (,(match cmp ['eq? 'eq] ['< 'lt]) ,d ,s0 ,s1))]
      [`(unsafe-vector-ref ,a ,i)
       (define-values (i0 s0) (src-operand a 0))
       `(,@i0 (uget ,d ,s0 ,i))]
      [`(fun-ref ,f)
       `((funref ,d ,f))]
      [`(string-lit ,s)
       `((str ,d ,(index-of string-table s)))]
      [`(global-ref ,i)
       `((gget ,d ,i))]
      [`(app (fun-ref ,f) ,args ...)  (emit-call d `(fun-ref ,f) args (length args))]
      [`(papp ,n (fun-ref ,f) ,args ...) (emit-call d `(fun-ref ,f) args n)]
      [`(app ,a-f ,args ...)          (emit-call d a-f args (length args))]
      [`(papp ,n ,a-f ,args ...)      (emit-call d a-f args n)]
      [`(,(? stdlib-prim? op) ,args ...)
       `(,@(stage-args args)
         (prim ,d ,(prim-id op) (stage 0) ,(length args)))]
      ;; a bare atom
      [a (load-into d a)]))
  (define (h seq)
    (prov-each (h-core seq)
               (match seq [`(seq ,s ,_) s] [_ seq])))
  (define (h-core seq)
    (match seq
      [`(return ,a)
       (define-values (i0 s0) (src-operand a 0))
       `(,@i0 (ret ,s0))]
      [`(tail-app ,n (fun-ref ,f) ,args ...)
       (emit-call #f `(fun-ref ,f) args n)]
      [`(tail-app ,n ,a-f ,args ...)
       (emit-call #f a-f args n)]
      [`(seq (assign ,x ,rhs) ,rst)
       (append (rhs->instrs rhs `(var ,x)) (h rst))]
      [`(seq (effect ,rhs) ,rst)
       ;; result discarded: staging slot 0 is a fine home (dead after)
       (append (rhs->instrs rhs `(stage 0)) (h rst))]
      [`(seq (global-set! ,i ,a) ,rst)
       (define-values (i0 s0) (src-operand a 0))
       `(,@i0 (gset ,i ,s0) ,@(h rst))]
      [`(seq (unsafe-vector-set! ,a0 ,i ,a-v) ,rst)
       (define-values (i0 s0) (src-operand a0 0))
       (define-values (i1 s1) (src-operand a-v 1))
       `(,@i0 ,@i1 (uset ,s0 ,i ,s1) ,@(h rst))]
      [`(if (,cmp ,a0 ,a1) (goto ,l0) (goto ,l1))
       ;; the first goto is taken when the comparison holds
       (define cc (match cmp ['eq? 'eq] ['< 'lt] ['<= 'le] ['> 'gt] ['>= 'ge]))
       (define-values (i0 s0) (src-operand a0 0))
       (define-values (i1 s1) (src-operand a1 1))
       `(,@i0 ,@i1 (br ,cc ,s0 ,s1 ,l0 ,l1))]
      [`(goto ,l)
       `((jmp ,l))]))
  (define (per-defn defn)
    (match-define `(define ,locals (,f ,args ...) ,blocks) defn)
    (define blocks-sel
      (foldl (λ (l acc) (hash-set acc l (h (hash-ref blocks l))))
             (hash) (hash-keys blocks)))
    ;; variadic prologue: COLLECT builds the #%rest list via
    ;; pf_collect_rest, spilling the six argument slots exactly like
    ;; the native prologue spills the six argument registers. It must
    ;; be the entry block's first instruction (the physical argument
    ;; values still sit in slots 0..5).
    (define mi (index-of args '#%rest))
    (define args+
      (if mi (append (take args mi) (list (list-ref args (add1 mi)))) args))
    (define blocks+
      (cond
        [mi
         (define rest-name (list-ref args (add1 mi)))
         (hash-set blocks-sel f
                   (cons `(collect (var ,rest-name) ,mi)
                         (hash-ref blocks-sel f)))]
        [else blocks-sel]))
    (define info (hash 'locals locals
                       'variadic (and mi #t)
                       'kfixed (or mi 0)))
    `(define ,info (,f ,@args+) ,blocks+))
  (match p
    [`(program ,info ,defns ...)
     `(program ,(hash-set (hash-set info 'symbols symbol-table) 'strings string-table)
               ,@(map per-defn defns))]))

;; ---------------------------------------------------------------------
;; allocate-slots-bc: formals first (they receive the arguments),
;; remaining locals sorted, then the staging area. The frame is at
;; least 6 slots so any call site may deliver up to six physical
;; arguments (variadics receive them without owning that many named
;; formals).
;; ---------------------------------------------------------------------

;; instruction slot-operand positions (0-based, past the opcode)
(define bc-slot-positions
  (hash 'mov '(0 1)   'imm '(0)    'sym '(0)   'str '(0)   'funref '(0)
        'gget '(0)    'gset '(1)
        'neg '(0 1)   'add '(0 1 2) 'mul '(0 1 2) 'lt '(0 1 2) 'eq '(0 1 2)
        'jmp '()      'br '(1 2)
        'call '(0 2)  'calli '(0 1 2) 'tcall '(1) 'tcalli '(0 1)
        'prim '(0 2)  'collect '(0)
        'uget '(0 1)  'uset '(0 2)
        'ret '(0)))

(define (allocate-slots-bc p)
  (define (per-defn defn)
    (match-define `(define ,info (,f ,formals ...) ,blocks) defn)
    (define locals (hash-ref info 'locals))
    ;; every (var x) mentioned anywhere gets a slot, not just the
    ;; uncovered locals: a syntactically-unbound-but-never-evaluated
    ;; variable (e.g. the predicate of a (? pred p) match clause that
    ;; no execution reaches) is READ without ever being assigned, and
    ;; the native backends tolerate it (regalloc hands it a home that
    ;; holds garbage). Slots are zero-seeded, so it reads fixnum 0.
    (define mentioned (mutable-set))
    (for ([(l is) (in-hash blocks)])
      (for ([i is])
        (for ([o (cdr i)])
          (match o [`(var ,x) (set-add! mentioned x)] [_ (void)]))))
    (define others
      (sort (filter (λ (x) (and (not (member x formals)) (not (eq? x '#%rest))))
                    (set->list (set-union (list->set (set->list locals))
                                          (list->set (set->list mentioned)))))
            symbol<?))
    (define ordered (append formals others))
    (define slot-of (for/hash ([x ordered] [i (in-naturals)]) (values x i)))
    (define nbase (length ordered))
    (define max-stage (box -1))
    (define (resolve op)
      (match op
        [`(var ,x) (hash-ref slot-of x
                             (λ () (error 'allocate-slots-bc "unknown local ~a in ~a" x f)))]
        [`(stage ,k)
         (when (> k (unbox max-stage)) (set-box! max-stage k))
         (+ nbase k)]))
    (define (resolve-instr i)
      (match-define `(,op ,ops ...) i)
      (define positions (hash-ref bc-slot-positions op))
      (prov-each
       (list
        `(,op ,@(for/list ([o ops] [k (in-naturals)])
                  (if (member k positions) (resolve o) o))))
       i))
    (define blocks+
      (foldl (λ (l acc) (hash-set acc l (append-map resolve-instr (hash-ref blocks l))))
             (hash) (hash-keys blocks)))
    ;; every frame holds >= 6 slots: an indirect call may deliver up
    ;; to six physical argument values before the callee looks at them
    (define nlocals (max 6 (+ nbase (add1 (unbox max-stage)))))
    `(define ,(hash-set (hash-set info 'nlocals nlocals) 'nformals (length formals))
       (,f ,@formals) ,blocks+))
  (match p
    [`(program ,info ,defns ...)
     `(program ,info ,@(map per-defn defns))]))

;; ---------------------------------------------------------------------
;; linearize-bc: block ordering + branch lowering. Output per defn is
;; one flat list of (label l) markers and instructions; the two-way
;; (br cc a b l0 l1) becomes (br cc a b l0) -- taken when cc holds --
;; followed by (jmp l1), and jumps to the immediately following label
;; are dropped.
;; ---------------------------------------------------------------------

(define (linearize-bc p)
  (define (per-defn defn)
    (match-define `(define ,info (,f ,formals ...) ,blocks) defn)
    ;; entry first, then DFS favoring fall-through (an unconditional
    ;; jump's target, or a branch's *else* target, comes next)
    (define visited (mutable-set))
    (define order '())
    (define (chain l)
      (when (and (hash-has-key? blocks l) (not (set-member? visited l)))
        (set-add! visited l)
        (set! order (cons l order))
        (match (last (hash-ref blocks l))
          [`(jmp ,m) (chain m)]
          [`(br ,_ ,_ ,_ ,l0 ,l1) (chain l1) (chain l0)]
          [_ (void)])))
    (chain f)
    ;; unreachable blocks (possible at -O0) go last, sorted
    (for ([l (sort (hash-keys blocks) symbol<?)]) (chain l))
    (define labels (reverse order))
    (define items
      (append*
       (for/list ([l labels] [k (in-naturals)])
         (define next (and (< (add1 k) (length labels)) (list-ref labels (add1 k))))
         (define is (hash-ref blocks l))
         (define lowered
           (append
            (drop-right is 1)
            (match (last is)
              [`(jmp ,m) (if (equal? m next) '() `((jmp ,m)))]
              [`(br ,cc ,a ,b ,l0 ,l1)
               (if (equal? l1 next)
                   `((br ,cc ,a ,b ,l0))
                   `((br ,cc ,a ,b ,l0) (jmp ,l1)))]
              [i (list i)])))
         (cons `(label ,l) lowered))))
    `(define ,info (,f ,@formals) ,items))
  (match p
    [`(program ,info ,defns ...)
     `(program ,info ,@(map per-defn defns))]))

;; ---------------------------------------------------------------------
;; render-pbc: encode the unit (docs/BYTECODE.md). Little-endian
;; throughout. Deterministic: same input program, same bytes.
;; ---------------------------------------------------------------------

;; opcode numbers -- keep in sync with docs/BYTECODE.md and
;; src/vm/puffin-vm.c (any change bumps pbc-version)
(define bc-opcodes
  (hash 'mov #x01 'imm #x02 'imm8 #x03 'sym #x04 'str #x05 'funref #x06
        'neg #x07 'add #x08 'mul #x09 'lt #x0A 'eq #x0B
        'jmp #x0C 'br-eq #x0D 'br-lt #x0E 'br-le #x0F 'br-gt #x10 'br-ge #x11
        'call #x12 'calli #x13 'tcall #x14 'tcalli #x15
        'prim #x16 'collect #x17
        'uget #x18 'uset #x19
        'gget #x1A 'gset #x1B
        'ret #x1C))

(define (imm8? w) (and (>= w -128) (< w 128)))

;; byte size of an encoded instruction
(define (instr-size i)
  (match i
    [`(label ,_) 0]
    [`(mov ,_ ,_) 5]
    [`(imm ,_ ,w) (if (imm8? w) 4 11)]
    [`(,(or 'sym 'str 'funref 'gget 'gset) ,_ ,_) 5]
    [`(neg ,_ ,_) 5]
    [`(,(or 'add 'mul 'lt 'eq) ,_ ,_ ,_) 7]
    [`(jmp ,_) 5]
    [`(br ,_ ,_ ,_ ,_) 9]
    [`(call ,_ ,_ ,_ ,_ ,_) 10]
    [`(calli ,_ ,_ ,_ ,_ ,_) 10]
    [`(tcall ,_ ,_ ,_ ,_) 8]
    [`(tcalli ,_ ,_ ,_ ,_) 8]
    [`(prim ,_ ,_ ,_ ,_) 8]
    [`(collect ,_ ,_) 4]
    [`(uget ,_ ,_ ,_) 6]
    [`(uset ,_ ,_ ,_) 6]
    [`(ret ,_) 3]))

(define (render-pbc p)
  (match-define `(program ,info ,defns ...) p)
  (define symbols (hash-ref info 'symbols '()))
  (define strings (hash-ref info 'strings '()))
  (define n-globals (hash-ref info 'globals 0))
  (define fun-names (map (λ (d) (match d [`(define ,_ (,f ,_ ...) ,_) f])) defns))
  (define fun-idx (for/hash ([f fun-names] [i (in-naturals)]) (values f i)))
  (define entry-idx (hash-ref fun-idx (entry-symbol)
                              (λ () (error 'render-pbc "no ~a function" (entry-symbol)))))
  (define out (open-output-bytes))
  (define (u8 n)  (write-byte n out))
  (define (u16 n)
    (unless (< n 65536) (error 'render-pbc "u16 overflow: ~a" n))
    (write-bytes (integer->integer-bytes n 2 #f #f) out))
  (define (u32 n) (write-bytes (integer->integer-bytes n 4 #f #f) out))
  (define (i64 n) (write-bytes (integer->integer-bytes n 8 #t #f) out))
  (define (lstr bs) (u32 (bytes-length bs)) (write-bytes bs out))
  ;; ---- encode one function's code, resolving labels ------------------
  (define (encode-fun items)
    (define offsets
      (let loop ([items items] [off 0] [acc (hash)])
        (match items
          ['() acc]
          [`((label ,l) . ,rest) (loop rest off (hash-set acc l off))]
          [`(,i . ,rest) (loop rest (+ off (instr-size i)) acc)])))
    (define (label-off l)
      (hash-ref offsets l (λ () (error 'render-pbc "unknown label ~a" l))))
    (define body (open-output-bytes))
    (define (b8 n) (write-byte n body))
    (define (b16 n)
      (unless (and (>= n 0) (< n 65536)) (error 'render-pbc "u16 operand overflow: ~a" n))
      (write-bytes (integer->integer-bytes n 2 #f #f) body))
    (define (b32 n) (write-bytes (integer->integer-bytes n 4 #f #f) body))
    (define (b64 n) (write-bytes (integer->integer-bytes n 8 #t #f) body))
    (define (op name) (b8 (hash-ref bc-opcodes name)))
    (for ([i items])
      (match i
        [`(label ,_) (void)]
        [`(mov ,d ,s)    (op 'mov) (b16 d) (b16 s)]
        [`(imm ,d ,w)
         (cond [(imm8? w) (op 'imm8) (b16 d) (b8 (bitwise-and w 255))]
               [else      (op 'imm)  (b16 d) (b64 w)])]
        [`(sym ,d ,i*)   (op 'sym) (b16 d) (b16 i*)]
        [`(str ,d ,i*)   (op 'str) (b16 d) (b16 i*)]
        [`(funref ,d ,f) (op 'funref) (b16 d) (b16 (hash-ref fun-idx f))]
        [`(neg ,d ,a)    (op 'neg) (b16 d) (b16 a)]
        [`(add ,d ,a ,b) (op 'add) (b16 d) (b16 a) (b16 b)]
        [`(mul ,d ,a ,b) (op 'mul) (b16 d) (b16 a) (b16 b)]
        [`(lt ,d ,a ,b)  (op 'lt)  (b16 d) (b16 a) (b16 b)]
        [`(eq ,d ,a ,b)  (op 'eq)  (b16 d) (b16 a) (b16 b)]
        [`(jmp ,l)       (op 'jmp) (b32 (label-off l))]
        [`(br ,cc ,a ,b ,l)
         (op (match cc ['eq 'br-eq] ['lt 'br-lt] ['le 'br-le] ['gt 'br-gt] ['ge 'br-ge]))
         (b16 a) (b16 b) (b32 (label-off l))]
        [`(call ,d ,f ,base ,n ,ar)
         (op 'call) (b16 d) (b16 (hash-ref fun-idx f)) (b16 base) (b8 n) (b16 ar)]
        [`(calli ,d ,fs ,base ,n ,ar)
         (op 'calli) (b16 d) (b16 fs) (b16 base) (b8 n) (b16 ar)]
        [`(tcall ,f ,base ,n ,ar)
         (op 'tcall) (b16 (hash-ref fun-idx f)) (b16 base) (b8 n) (b16 ar)]
        [`(tcalli ,fs ,base ,n ,ar)
         (op 'tcalli) (b16 fs) (b16 base) (b8 n) (b16 ar)]
        [`(prim ,d ,pid ,base ,n)
         (op 'prim) (b16 d) (b16 pid) (b16 base) (b8 n)]
        [`(collect ,d ,k) (op 'collect) (b16 d) (b8 k)]
        [`(uget ,d ,a ,i*)
         (unless (< i* 256) (error 'render-pbc "uget index too large: ~a" i*))
         (op 'uget) (b16 d) (b16 a) (b8 i*)]
        [`(uset ,a ,i* ,s)
         (unless (< i* 256) (error 'render-pbc "uset index too large: ~a" i*))
         (op 'uset) (b16 a) (b8 i*) (b16 s)]
        [`(gget ,d ,g) (op 'gget) (b16 d) (b16 g)]
        [`(gset ,g ,s) (op 'gset) (b16 g) (b16 s)]
        [`(ret ,s)     (op 'ret) (b16 s)]))
    (get-output-bytes body))
  ;; ---- per-function code + table rows ---------------------------------
  (define encoded (map (λ (d) (match d [`(define ,_ (,_ ,_ ...) ,items) (encode-fun items)])) defns))
  (define code-offsets
    (let loop ([es encoded] [off 0] [acc '()])
      (match es
        ['() (reverse acc)]
        [`(,e . ,rest) (loop rest (+ off (bytes-length e)) (cons off acc))])))
  (define total-code (apply bytes-append encoded))
  ;; ---- the unit --------------------------------------------------------
  (write-bytes (bytes (char->integer #\P) (char->integer #\U) (char->integer #\F) 1) out)
  (u32 pbc-version)
  (u32 0) ;; reserved
  (u32 (length symbols))
  (for ([s symbols]) (lstr (string->bytes/utf-8 (symbol->string s))))
  (u32 (length strings))
  (for ([s strings]) (lstr (string->bytes/utf-8 s)))
  (u32 n-globals)
  (u32 (length defns))
  (for ([d defns] [e encoded] [off code-offsets])
    (match-define `(define ,dinfo (,f ,formals ...) ,_) d)
    (lstr (string->bytes/utf-8 (symbol->string f)))
    (u32 (length formals))
    (u8 (if (hash-ref dinfo 'variadic) 1 0))
    (u8 (hash-ref dinfo 'kfixed))
    (u16 0) ;; pad
    (u32 (hash-ref dinfo 'nlocals))
    (u32 off)
    (u32 (bytes-length e)))
  (u32 entry-idx)
  (u32 (bytes-length total-code))
  (write-bytes total-code out)
  (get-output-bytes out))

;; ---------------------------------------------------------------------
;; predicates (light: the native instruction-level predicates check
;; operand discipline; here the discipline is "slots are resolved")
;; ---------------------------------------------------------------------

(define (bc-instr-program? p)
  (match p
    [`(program ,info ,defns ...)
     (andmap (λ (d) (match d
                      [`(define ,(? hash?) (,(? symbol?) ,_ ...) ,(? hash?)) #t]
                      [_ #f]))
             defns)]
    [_ #f]))

(define (bc-slots-program? p)
  (define (no-var-ops? is)
    (andmap (λ (i) (andmap (λ (o) (match o [`(var ,_) #f] [`(stage ,_) #f] [_ #t]))
                           (cdr i)))
            is))
  (match p
    [`(program ,info ,defns ...)
     (andmap (λ (d) (match d
                      [`(define ,(? hash?) (,_ ,_ ...) ,(? hash? blocks))
                       (andmap (λ (l) (no-var-ops? (hash-ref blocks l))) (hash-keys blocks))]
                      [_ #f]))
             defns)]
    [_ #f]))

(define (bc-linear-program? p)
  (match p
    [`(program ,info ,defns ...)
     (andmap (λ (d) (match d
                      [`(define ,(? hash?) (,_ ,_ ...) ,(? list?)) #t]
                      [_ #f]))
             defns)]
    [_ #f]))

;; the pass table main.rkt splices in for --target bytecode
(define (bytecode-backend-passes)
  (list
   `(,select-instructions-bc "select-instructions"  ,locals-program?    ,bc-instr-program?  ,dummy-interp-bc)
   `(,allocate-slots-bc      "allocate-slots"       ,bc-instr-program?  ,bc-slots-program?  ,dummy-interp-bc)
   `(,linearize-bc           "linearize"            ,bc-slots-program?  ,bc-linear-program? ,dummy-interp-bc)
   `(,render-pbc             "render-pbc"           ,bc-linear-program? ,bytes?             ,dummy-interp-bc)))

(define (dummy-interp-bc p i)
  "bytecode not interpreted here; validated by running bin/puffin-vm")
