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
;;   (asr k d) (lsl k d) (orr k d)
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
  (define (h-atom a)
    (match a
      ['(void)        `(imm ,void-value)]
      ['(nil)         `(imm ,nil-value)]
      [(? fixnum? n)  `(imm ,(tag-fixnum n))]
      [(? boolean? b) `(imm ,(if b true-value false-value))]
      [`(quote ,s)    `(imm ,(tag-symbol (index-of symbol-table s)))]
      [(? symbol? x)  `(var ,x)]))
  (define (copy-arguments as)
    (map (λ (a r) `(mov ,(h-atom a) (reg ,r)))
         as (take (argument-registers-list) (length as))))
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
      [`(app ,a-f ,args ...)
       `(,@(copy-arguments args)
         (indirect-callq ,(h-atom a-f))
         ,@sink)]
      [`(global-ref ,i)
       `((ldr-global ,i (reg x0))
         ,@sink)]
      [`(string-lit ,s)
       `((mov (imm ,(tag-fixnum (index-of string-table s))) (reg x0))
         (callq pf_string_const 1)
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
      [`(tail-app ,a-f ,args ...)
       ;; x9 is scratch and survives the epilogue expansion
       `((mov ,(h-atom a-f) (reg x9))
         ,@(copy-arguments args)
         (tail-jmp (reg x9) ,(length args)))]
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
       (define cc (match cmp ['eq? 'e] ['< 'l]))
       `((cmp ,(h-atom a0) ,(h-atom a1))
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
      (map (λ (a r) `(mov (reg ,r) (var ,a)))
           args (take (argument-registers-list) (length args))))
    (define blocks++
      (hash-set blocks+ f (append moves entry)))
    `(define ,locals (,f ,@args) ,blocks++))
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
    [`(lea-fun ,_ ,dst)  (list '() (vars-of dst))]
    [`(,(or 'add 'sub 'mul 'orr) ,src ,dst)
     (list (vars-of src dst) (vars-of dst))]
    [`(neg ,dst)         (list (vars-of dst) (vars-of dst))]
    [`(,(or 'asr 'lsl) ,_ ,dst) (list (vars-of dst) (vars-of dst))]
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
      [`(global ,i) (values `((ldr-global ,i (reg ,scratch))) `(reg ,scratch))]))
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
      [`(,(and op (or 'neg 'asr 'lsl)) ,args ... ,dst)
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
  (define (per-defn defn)
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
       (define start-block (hash-ref blocks f))
       (define new-start-block
         `((frame-push)               ;; stp x29, x30, [sp, #-16]!; mov x29, sp
           ,@saves
           ,@(if (zero? frame-bytes) '() `((sp-sub ,frame-bytes)))
           ,@(if (equal? f (entry-symbol)) `((callq pf_init 0)) '())
           ,@start-block))
       (define restore
         `(,@(if (zero? frame-bytes) '() `((sp-add ,frame-bytes)))
           ,@restores
           (frame-pop)                ;; ldp x29, x30, [sp], #16
           (retq)))
       (define conclusion-block
         (if (equal? f (entry-symbol))
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
              [_ (list i)]))
          instrs))
       (define my-conclusion (gensym 'conclusion))
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
;; render
;; ---------------------------------------------------------------------

;; instruction rendering, shared by render-arm64 and the pipeline
;; serializer's per-line provenance (ir-json.rkt)
(define (reg-name op) (match op [`(reg ,r) (symbol->string r)]))
(define (render-op-arm op)
    (match op
      [`(imm ,i) (format "#~a" i)]
      [`(reg ,x) (symbol->string x)]))
(define (render-cc-arm cc)
  (match cc ['e "eq"] ['ne "ne"] ['l "lt"] ['ae "hs"]))
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
(define (render-instr-arm instr)
  (define globals-sym (rt-sym 'puffin_globals))
  (match instr
      [`(mov ,src ,dst) (format "mov ~a, ~a" (reg-name dst) (render-op-arm src))]
      [`(ldr-imm (imm ,i) ,dst) (format "ldr ~a, =~a" (reg-name dst) i)]
      [`(ldr ,mem ,dst) (render-mem-access #t dst mem)]
      [`(str ,src ,mem) (render-mem-access #f src mem)]
      [`(add ,src ,dst) (format "add ~a, ~a, ~a" (reg-name dst) (reg-name dst) (render-op-arm src))]
      [`(sub ,src ,dst) (format "sub ~a, ~a, ~a" (reg-name dst) (reg-name dst) (render-op-arm src))]
      [`(mul ,src ,dst) (format "mul ~a, ~a, ~a" (reg-name dst) (reg-name dst) (render-op-arm src))]
      [`(neg ,dst) (format "neg ~a, ~a" (reg-name dst) (reg-name dst))]
      [`(asr (imm ,k) ,dst) (format "asr ~a, ~a, #~a" (reg-name dst) (reg-name dst) k)]
      [`(lsl (imm ,k) ,dst) (format "lsl ~a, ~a, #~a" (reg-name dst) (reg-name dst) k)]
      [`(orr (imm ,k) ,dst) (format "orr ~a, ~a, #~a" (reg-name dst) (reg-name dst) k)]
      [`(cmp ,a ,b) (format "cmp ~a, ~a" (reg-name a) (render-op-arm b))]
      [`(cset ,cc ,dst) (format "cset ~a, ~a" (reg-name dst) (render-cc-arm cc))]
      [`(jmp-if ,cc ,lab) (format "b.~a ~a" (render-cc-arm cc) lab)]
      [`(jmp ,lab) (format "b ~a" lab)]
      [`(goto ,l) (format "b ~a" (symbol->string l))]
      [`(callq ,(? label? l) ,_) (format "bl ~a" (symbol->string (rt-sym l)))]
      [`(indirect-callq ,op) (format "blr ~a" (reg-name op))]
      [`(indirect-jmp ,op) (format "br ~a" (reg-name op))]
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
      ['(frame-push) "stp x29, x30, [sp, #-16]!\n    mov x29, sp"]
      ['(frame-pop) "ldp x29, x30, [sp], #16"]
      [`(sp-sub ,n) (format "sub sp, sp, #~a" n)]
      [`(sp-add ,n) (format "add sp, sp, #~a" n)]
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
  (match p
    [`(program ,info ,defns ...)
     (string-append
      (format ".globl ~a\n" (rt-sym (entry-symbol)))
      ".text\n.p2align 2\n"
      (apply string-append
             (map (λ (ln) (string-append (car ln) "\n")) (render-lines-arm64 p)))
      (data-segment info))]))

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
