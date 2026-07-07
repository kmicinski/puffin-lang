#lang racket
;;
;; Puffin -- irs.rkt
;;
;; Interface (predicates) for every IR used across the pipeline,
;; descended from the class projects' irs.rkt. Keep these aligned
;; with compile.rkt's expectations.
;;
;; What changed vs. the class p5 irs.rkt (see docs/DELTA.md):
;;  - The language grew: symbols, quoted data, strings, pairs,
;;    sets, hashes, match, cond/when/unless/case, named let,
;;    top-level value defines, n-ary arithmetic, * and
;;    quotient/remainder, dynamic vector indices, printing.
;;  - Primitives are factored into tables (unary-prims etc.) that
;;    the passes, the interpreters, and these predicates all share;
;;    writing one match case per prim per predicate stopped scaling.
;;  - New IR forms: (quote s), (nil), (string-lit s), (global-ref i),
;;    (global-set! i e), (unsafe-vector-ref e i), (unsafe-vector-set! e i e),
;;    (make-closure i).
;;  - After uncover-locals the pipeline forks per target
;;    (backend-x86.rkt / backend-arm64.rkt); the instruction-level
;;    predicates live here so both backends share them.

(require "system.rkt")
(require "stdlib.rkt")
(provide (all-defined-out))

;; ---------------------------------------------------------------------
;; Primitive vocabulary. Library primitives come from the manifest
;; (stdlib.rkt); the compiler's own intrinsics--operations the
;; backends open-code rather than call--are listed here.
;; ---------------------------------------------------------------------

;; Comparators in the *source* language (shrink reduces this set)
(define (cmp? cmp)               (member cmp '(eq? < <= > >=)))

;; After shrink we keep only eq? and <
(define (shrunk-cmp? c)          (member c '(eq? <)))

;; Intrinsics: open-coded by both backends.
(define intrinsic-unary  '(-))          ;; negation
(define intrinsic-binary '(+ * eq? <))

;; Any operator that may appear applied in post-desugar IRs.
(define (prim? op)
  (and (symbol? op)
       (or (stdlib-prim? op)
           (member op intrinsic-unary)
           (member op intrinsic-binary))
       #t))

(define (prim-arity op)
  (cond [(member op intrinsic-unary)  1]
        [(member op intrinsic-binary) 2]
        [else (stdlib-arity op)]))

;; Operators allowed in *source* programs: surface library prims,
;; intrinsics, the sugar the desugarer removes (not, n-ary ops, the
;; full comparator set, binary minus, list/vector constructors).
(define (surface-prim? op)
  (and (symbol? op)
       (or (surface-stdlib-prim? op)
           (member op intrinsic-unary)
           (member op intrinsic-binary)
           (cmp? op)
           (member op '(not list vector)))
       #t))

;; A "self-evaluating literal / immediate" at every IR level.
;; (quote s) is a symbol literal; (nil) is the empty list.
(define (atom? a)
  (or (fixnum? a) (symbol? a) (boolean? a)
      (equal? a '(void)) (equal? a '(nil))
      (match a [`(quote ,(? symbol?)) #t] [_ #f])))

;; Atoms minus variables (for predicates that need the distinction)
(define (literal? a) (and (atom? a) (not (symbol? a))))

;; An application's rator at the anf/blocks levels: an atom, or --
;; direct calls to known top-level functions (>= -O1; see
;; docs/OPTIMIZER.md §5) -- a bare (fun-ref f).
(define (app-rator? a)
  (or (atom? a)
      (match a [`(fun-ref ,(? symbol?)) #t] [_ #f])))

(define (imm? op)                (match op [`(imm ,n)            (fixnum? n)] [_ #f]))
(define (byte-reg? op)           (match op [`(byte-reg ,r)       (symbol? r)] [_ #f]))
(define (reg? op)                (match op [`(reg ,r)            (symbol? r)] [_ #f]))
(define (var? op)                (match op [`(var ,x)            (symbol? x)] [_ #f]))
(define (deref? op)              (match op [`(deref (reg ,r) ,i) (and (symbol? r) (integer? i))] [_ #f]))
(define (global? op)             (match op [`(global ,i)         (integer? i)] [_ #f]))
(define (label? l)               (symbol? l))

;; Condition codes: e, ne, l, ae (ae backs the unsigned bounds
;; checks); le/g/ge back the fused compare-and-branch tails
(define (cc? op)                 (member op '(e ne l le g ge ae)))

;; ---------------------------------------------------------------------
;; 1) Puffin source programs
;;
;; A program is a sequence of top-level forms: function defines,
;; value defines, and expressions (evaluated in order; the last
;; expression's value is printed, unless void). main.rkt's reader
;; wraps bare files in (program ...) automatically.
;; ---------------------------------------------------------------------

(define (quoted-datum? d)
  (or (symbol? d) (fixnum? d) (boolean? d) (null? d) (string? d)
      (and (pair? d) (quoted-datum? (car d)) (quoted-datum? (cdr d)))))

;; Note: quote/quasiquote/unquote are *special* inside Racket match's
;; quasiquote patterns, so these meta-level matches (matching Puffin
;; patterns, which are plain s-expressions) use (list 'quote ...) form.
(define (match-pattern? pat)
  (match pat
    ['_ #t]
    [(? symbol?) #t]
    [(? fixnum?) #t]
    [(? boolean?) #t]
    [(? string?) #t]
    [(list 'quote (? quoted-datum?)) #t]
    [(list 'quasiquote q) (quasi-pattern? q)]
    [(list 'cons (? match-pattern?) (? match-pattern?)) #t]
    [(list-rest 'list (? (λ (ps) (andmap match-pattern? ps)))) #t]
    [(list-rest 'vector (? (λ (ps) (andmap match-pattern? ps)))) #t]
    [(list '? (? symbol?) (? match-pattern?)) #t]
    [_ #f]))

(define (quasi-pattern? q)
  (match q
    [(list 'unquote (? match-pattern?)) #t]
    [(? symbol?) #t]
    [(? fixnum?) #t]
    [(? boolean?) #t]
    [(? list?) (andmap quasi-pattern? q)]
    [_ #f]))

(define (puffin-exp? e)
  (match e
    [#t #t]
    [#f #t]
    [(? fixnum?) #t]
    [(? string?) #t]
    ['(read) #t]
    ['(void) #t]
    [`(quote ,(? quoted-datum?)) #t]
    [(? symbol?) #t]
    ;; n-ary arithmetic / logic (desugar rewrites to binary)
    [`(,(? (λ (op) (member op '(+ * - and or))) _) ,(? puffin-exp?) ...) #t]
    [`(not ,(? puffin-exp?)) #t]
    [`(,(? (λ (op) (member op '(quotient remainder))) _) ,(? puffin-exp?) ,(? puffin-exp?)) #t]
    [`(,(? cmp?) ,(? puffin-exp?) ,(? puffin-exp?)) #t]
    ;; control
    [`(if ,(? puffin-exp?) ,(? puffin-exp?) ,(? puffin-exp?)) #t]
    [`(cond [,(? puffin-exp?) ,(? puffin-exp?) ...] ...) #t]
    [`(when ,(? puffin-exp?) ,(? puffin-exp?) ...) #t]
    [`(unless ,(? puffin-exp?) ,(? puffin-exp?) ...) #t]
    [`(case ,(? puffin-exp?) [,_ ,(? puffin-exp?) ...] ...) #t]
    [`(match ,(? puffin-exp?) ,clauses ...) (andmap match-clause? clauses)]
    ;; binding
    [`(let ([,(? symbol?) ,(? puffin-exp?)] ...) ,(? puffin-exp?) ...) #t]
    [`(let ,(? symbol? loop) ([,(? symbol?) ,(? puffin-exp?)] ...) ,(? puffin-exp?) ...) #t]
    [`(let* ([,(? symbol?) ,(? puffin-exp?)] ...) ,(? puffin-exp?) ...) #t]
    [`(lambda (,(? symbol?) ...) ,(? puffin-exp?) ...) #t]
    [`(λ (,(? symbol?) ...) ,(? puffin-exp?) ...) #t]
    ;; variadic lambdas: dotted or all-rest formals
    [`(lambda ,(? symbol?) ,(? puffin-exp?) ...) #t]
    [`(λ ,(? symbol?) ,(? puffin-exp?) ...) #t]
    [`(lambda ,(? pair?) ,(? puffin-exp?) ...) #t]
    [`(λ ,(? pair?) ,(? puffin-exp?) ...) #t]
    ;; sequences / loops / mutation
    [`(begin ,(? puffin-exp?) ... ,(? puffin-exp?)) #t]
    [`(while ,(? puffin-exp?) ,(? puffin-exp?) ...) #t]
    [`(set! ,(? symbol?) ,(? puffin-exp?)) #t]
    ;; data
    [`(,(? surface-prim?) ,(? puffin-exp?) ...) #t]
    ;; application
    [`(,(? puffin-exp?) ,(? puffin-exp?) ...) #t]
    [_ #f]))

(define (match-clause? c)
  (match c
    [`[,(? match-pattern?) #:when ,(? puffin-exp?) ,(? puffin-exp?) ...] #t]
    [`[,(? match-pattern?) ,(? puffin-exp?) ...] #t]
    [_ #f]))

(define (puffin-defn? defn)
  (match defn
    [`(define (,(? symbol?) ,(? symbol?) ...) ,(? puffin-exp?) ...) #t]
    ;; variadic: dotted formals
    [`(define (,(? symbol?) . ,_) ,(? puffin-exp?) ...) #t]
    [`(define ,(? symbol?) ,(? puffin-exp?)) #t]
    [_ #f]))

(define (puffin-program? p)
  (match p
    [`(program ,forms ...)
     (andmap (λ (f) (or (puffin-defn? f) (puffin-exp? f))) forms)]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 2) Core Puffin (after desugar)
;;
;; match/cond/when/unless/case/named-let/let*/multi-binding-let/
;; multi-body/quoted-lists/n-ary-ops are gone. Strings appear as
;; (string-lit s). Value defines and top-level expressions remain
;; (collect-globals removes them later).
;; ---------------------------------------------------------------------

(define (core-exp? e)
  (match e
    [#t #t]
    [#f #t]
    [(? fixnum?) #t]
    ['(read) #t]
    ['(void) #t]
    ['(nil) #t]
    [`(quote ,(? symbol?)) #t]
    [`(string-lit ,(? string?)) #t]
    [(? symbol?) #t]
    [`(- ,(? core-exp?) ,(? core-exp?)) #t] ;; binary minus (shrink removes)
    [`(and ,(? core-exp?) ,(? core-exp?)) #t]
    [`(or ,(? core-exp?) ,(? core-exp?)) #t]
    [`(not ,(? core-exp?)) #t]
    [`(,(? cmp?) ,(? core-exp?) ,(? core-exp?)) #t]
    [`(if ,(? core-exp?) ,(? core-exp?) ,(? core-exp?)) #t]
    [`(let ([,(? symbol?) ,(? core-exp?)]) ,(? core-exp?)) #t]
    [`(begin ,(? core-exp?) ... ,(? core-exp?)) #t]
    [`(while ,(? core-exp?) ,(? core-exp?)) #t]
    [`(set! ,(? symbol?) ,(? core-exp?)) #t]
    [`(lambda (,(? symbol?) ...) ,(? core-exp?)) #t]
    [`(,(? prim? op) ,(? core-exp?) ...) #t]
    [`(,(? core-exp?) ,(? core-exp?) ...) #t]
    [_ #f]))

(define (core-program? p)
  (match p
    [`(program ,forms ...)
     (andmap (λ (f) (match f
                      [`(define (,(? symbol?) ,(? symbol?) ...) ,(? core-exp?)) #t]
                      [`(define ,(? symbol?) ,(? core-exp?)) #t]
                      [e (core-exp? e)]))
             forms)]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 3) Shrunk Puffin (after shrink)
;;     - binary minus, and/or/not, <=/>/>= removed
;;     - begin -> let chains; while wrapped as (let ([_ (while g b)]) r)
;;     - value defines / trailing expressions still present
;; ---------------------------------------------------------------------

(define (shrunk-exp? e)
  (match e
    [#t #t]
    [#f #t]
    [(? fixnum?) #t]
    ['(read) #t]
    ['(void) #t]
    ['(nil) #t]
    [`(quote ,(? symbol?)) #t]
    [`(string-lit ,(? string?)) #t]
    [(? symbol?) #t]
    [`(,(? shrunk-cmp?) ,(? shrunk-exp?) ,(? shrunk-exp?)) #t]
    [`(if ,(? shrunk-exp?) ,(? shrunk-exp?) ,(? shrunk-exp?)) #t]
    [`(let ([,(? symbol?) ,(? shrunk-exp?)]) ,(? shrunk-exp?)) #t]
    [`(let ([_ ,(? shrunk-exp?)]) ,(? shrunk-exp?)) #t]
    [`(let ([_ (while ,(? shrunk-exp?) ,(? shrunk-exp?))]) ,(? shrunk-exp?)) #t]
    [`(set! ,(? symbol?) ,(? shrunk-exp?)) #t]
    [`(lambda (,(? symbol?) ...) ,(? shrunk-exp?)) #t]
    [`(,(? prim?) ,(? shrunk-exp?) ...) #t]
    [`(,(? shrunk-exp?) ,(? shrunk-exp?) ...) #t]
    [_ #f]))

(define (shrunk-program? p)
  (match p
    [`(program ,defns ...)
     (andmap (λ (f) (match f
                      [`(define (,(? symbol?) ,(? symbol?) ...) ,(? shrunk-exp?)) #t]
                      [`(define ,(? symbol?) ,(? shrunk-exp?)) #t]
                      [e (shrunk-exp? e)]))
             defns)]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 4) Unique source tree (after uniqueify)
;;     - every bound identifier is written exactly once
;; ---------------------------------------------------------------------

(define (unique-source-tree/walk e seen)
  (match e
    [(? literal?)                       seen]
    ['(read)                            seen]
    [`(string-lit ,_)                   seen]
    [(? symbol?)                        seen]
    [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
     (unique-source-tree/walk e-r (unique-source-tree/walk e-b (unique-source-tree/walk e-g seen)))]
    [`(let ([_ ,e]) ,e-b)
     (unique-source-tree/walk e-b (unique-source-tree/walk e seen))]
    ;; Important: put after _ cases
    [`(let ([,(? symbol? x) ,e]) ,eb)
     (and (not (set-member? seen x))
          (let ([seen* (unique-source-tree/walk e seen)])
            (and seen* (unique-source-tree/walk eb (set-add seen* x)))))]
    [`(set! ,x ,e)                      (unique-source-tree/walk e seen)]
    [`(if ,e-g ,e-t ,e-f)
     (let* ([s0 (unique-source-tree/walk e-g seen)]
            [s1 (and s0 (unique-source-tree/walk e-t s0))])
       (and s1 (unique-source-tree/walk e-f s1)))]
    [`(lambda (,(? symbol? xs) ...) ,e)
     (unique-source-tree/walk e (set-union seen (list->set xs)))]
    ;; prims and applications: fold over subexpressions
    [`(,_ ,es ...)
     (foldl (λ (e acc) (and acc (unique-source-tree/walk e acc))) seen es)]
    [_                                  #f]))

(define (unique-source-tree? p)
  (define (per-defn d)
    (match d
      [`(define (,(? symbol? f) ,(? symbol? args) ...) ,e-body)
       (unique-source-tree/walk e-body (list->set args))]
      [`(define ,(? symbol? x) ,e)
       (unique-source-tree/walk e (set))]
      [e (unique-source-tree/walk e (set))]))
  (match p
    [`(program ,defns ...) (andmap (λ (d) (and (per-defn d) #t)) defns)]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 5) Globals collected (after collect-globals)
;;     - No more (define x e) or top-level expressions: only function
;;       defines, with (entry-symbol) present
;;     - Global reads are (global-ref i); writes are (global-set! i e)
;;     - The program carries the global count: (program ,n-globals ,defns ...)
;; ---------------------------------------------------------------------

(define (globals-exp? e)
  (match e
    [(? literal?) #t]
    ['(read) #t]
    [`(string-lit ,(? string?)) #t]
    [(? symbol?) #t]
    [`(global-ref ,(? exact-nonnegative-integer?)) #t]
    [`(global-set! ,(? exact-nonnegative-integer?) ,(? globals-exp?)) #t]
    [`(,(? shrunk-cmp?) ,(? globals-exp?) ,(? globals-exp?)) #t]
    [`(if ,(? globals-exp?) ,(? globals-exp?) ,(? globals-exp?)) #t]
    [`(let ([_ (while ,(? globals-exp?) ,(? globals-exp?))]) ,(? globals-exp?)) #t]
    [`(let ([,_ ,(? globals-exp?)]) ,(? globals-exp?)) #t]
    [`(set! ,(? symbol?) ,(? globals-exp?)) #t]
    [`(lambda (,(? symbol?) ...) ,(? globals-exp?)) #t]
    [`(,(? prim?) ,(? globals-exp?) ...) #t]
    [`(,(? globals-exp?) ,(? globals-exp?) ...) #t]
    [_ #f]))

;; The info hash in program slot one (from collect-globals onward):
;; 'globals (count), and after select-instructions also 'symbols and
;; 'strings (the literal tables, in id order).
(define (program-info? i) (and (hash? i) (hash-has-key? i 'globals)))

(define (globals-program? p)
  (match p
    [`(program ,(? program-info?) ,defns ...)
     (and (andmap (λ (d) (match d
                           [`(define (,(? symbol?) ,(? symbol?) ...) ,(? globals-exp?)) #t]
                           [_ #f]))
                  defns)
          (member (entry-symbol)
                  (map (λ (d) (match d [`(define (,f ,_ ...) ,_) f])) defns))
          #t)]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 6) Revealed functions: references to functions f become (fun-ref f)
;; ---------------------------------------------------------------------

(define (revealed-exp? e fs)
  (match e
    [(? literal?) #t]
    ['(read) #t]
    [`(string-lit ,_) #t]
    [(? symbol? x) (not (set-member? fs x))]
    [`(fun-ref ,f) (set-member? fs f)]
    [`(global-ref ,_) #t]
    [`(global-set! ,_ ,(? (λ (e) (revealed-exp? e fs)))) #t]
    [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
     (and (revealed-exp? e-g fs) (revealed-exp? e-b fs) (revealed-exp? e-r fs))]
    [`(let ([,_ ,e]) ,e-b)
     (and (revealed-exp? e fs) (revealed-exp? e-b fs))]
    [`(set! ,x ,e) (revealed-exp? e fs)]
    [`(if ,e0 ,e1 ,e2) (and (revealed-exp? e0 fs) (revealed-exp? e1 fs) (revealed-exp? e2 fs))]
    [`(lambda (,xs ...) ,e) (revealed-exp? e fs)]
    [`(,(? prim?) ,es ...) (andmap (λ (e) (revealed-exp? e fs)) es)]
    [`(app ,es ...) (andmap (λ (e) (revealed-exp? e fs)) es)]
    [_ #f]))

(define (revealed-functions-program? p)
  (match p
    [`(program ,n-globals ,defns ...)
     (match defns
       [`((define (,fs ,_ ...) ,_) ...)
        (define f-set (list->set fs))
        (andmap (λ (d) (match d [`(define (,_ ,_ ...) ,e-b) (revealed-exp? e-b f-set)])) defns)]
       [_ #f])]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 7) Assignment conversion: set! is gone; mutated locals are boxed
;;    into one-slot closures cells via unsafe vector ops.
;; ---------------------------------------------------------------------

(define (assignment-converted-exp? e)
  (match e
    [(? literal?) #t]
    ['(read) #t]
    [`(string-lit ,_) #t]
    [(? symbol?) #t]
    [`(fun-ref ,_) #t]
    [`(global-ref ,_) #t]
    [`(global-set! ,_ ,(? assignment-converted-exp?)) #t]
    [`(unsafe-vector-ref ,(? assignment-converted-exp?) ,(? fixnum?)) #t]
    [`(unsafe-vector-set! ,(? assignment-converted-exp?) ,(? fixnum?) ,(? assignment-converted-exp?)) #t]
    [`(let ([_ (while ,(? assignment-converted-exp?) ,(? assignment-converted-exp?))])
        ,(? assignment-converted-exp?)) #t]
    [`(let ([,_ ,(? assignment-converted-exp?)]) ,(? assignment-converted-exp?)) #t]
    [`(if ,(? assignment-converted-exp?) ,(? assignment-converted-exp?) ,(? assignment-converted-exp?)) #t]
    [`(lambda (,(? symbol?) ...) ,(? assignment-converted-exp?)) #t]
    [`(,(? prim?) ,(? assignment-converted-exp?) ...) #t]
    [`(app ,(? assignment-converted-exp?) ...) #t]
    [_ #f]))

(define (assignment-converted-program? p)
  (match p
    [`(program ,n-globals ,defns ...)
     (andmap (λ (d) (match d
                      [`(define (,f ,formals ...) ,e-body)
                       (and (andmap symbol? (cons f formals))
                            (assignment-converted-exp? e-body))]
                      [_ #f]))
             defns)]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 8) Closure conversion: no lambdas remain; closures are heap
;;    records made with (make-closure k) and read with unsafe ops.
;; ---------------------------------------------------------------------

(define (closure-converted-exp? e)
  (match e
    [(? literal?) #t]
    ['(read) #t]
    [`(string-lit ,_) #t]
    [(? symbol?) #t]
    [`(fun-ref ,_) #t]
    [`(global-ref ,_) #t]
    [`(global-set! ,_ ,(? closure-converted-exp?)) #t]
    [`(unsafe-vector-ref ,(? closure-converted-exp?) ,(? fixnum?)) #t]
    [`(unsafe-vector-set! ,(? closure-converted-exp?) ,(? fixnum?) ,(? closure-converted-exp?)) #t]
    [`(let ([_ (while ,(? closure-converted-exp?) ,(? closure-converted-exp?))])
        ,(? closure-converted-exp?)) #t]
    [`(let ([,_ ,(? closure-converted-exp?)]) ,(? closure-converted-exp?)) #t]
    [`(if ,(? closure-converted-exp?) ,(? closure-converted-exp?) ,(? closure-converted-exp?)) #t]
    [`(,(? prim?) ,(? closure-converted-exp?) ...) #t]
    [`(app ,(? closure-converted-exp?) ...) #t]
    [`(papp ,(? fixnum?) ,(? closure-converted-exp?) ...) #t]
    [_ #f]))

(define (closure-converted-program? p)
  (match p
    [`(program ,n-globals ,defns ...)
     (andmap (λ (d) (match d
                      [`(define (,f ,formals ...) ,e-body)
                       (and (andmap symbol? (cons f formals))
                            (closure-converted-exp? e-body))]
                      [_ #f]))
             defns)]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 9) Limited arity: every definition has at most six arguments
;; ---------------------------------------------------------------------

;; effective register footprint of a formals list: a variadic's rest
;; parameter arrives via the arity protocol, not a register
(define (formals-register-count formals)
  (if (member '#%rest formals)
      (- (length formals) 1)   ;; fixed + the overflow slot allowance
      (length formals)))

(define (limited-arity-program? p)
  (match p
    [`(program ,n-globals ,defns ...)
     (andmap (λ (d) (match d
                      [`(define (,f ,formals ...) ,e-body)
                       (and (<= (formals-register-count formals)
                                (add1 (length (argument-registers-list))))
                            (closure-converted-exp? e-body))]
                      [_ #f]))
             defns)]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 10) ANF: RHS is atomic or one prim/app over atoms
;; ---------------------------------------------------------------------

(define (anf-rhs? rhs)
  (match rhs
    [(? atom?)                           #t]
    [`(string-lit ,_)                    #t]
    [`(fun-ref ,(? symbol?))             #t]
    [`(global-ref ,_)                    #t]
    [`(global-set! ,_ ,(? atom?))        #t]
    [`(unsafe-vector-ref ,(? atom?) ,(? fixnum?)) #t]
    [`(unsafe-vector-set! ,(? atom?) ,(? fixnum?) ,(? atom?)) #t]
    [`(app ,(? app-rator?) ,args ...)    (andmap atom? args)]
    [`(papp ,(? fixnum?) ,(? app-rator?) ,args ...) (andmap atom? args)]
    [`(,(? prim?) ,args ...)             (andmap atom? args)]
    [_                                   #f]))

(define (anf-exp? e)
  (match e
    [(? atom?)                                                      #t]
    [`(let ([_ (while ,(? anf-exp?) ,(? anf-exp?))]) ,(? anf-exp?)) #t]
    ;; join points: an if in a let rhs, both branches reducing to
    ;; the bound atom -- emitted by anf-convert when the if's
    ;; continuation is non-trivial (binding it once instead of
    ;; duplicating it into both branches, which is exponential
    ;; under nested ifs)
    [`(let ([,_ (if ,(? atom?) ,(? anf-exp?) ,(? anf-exp?))]) ,(? anf-exp?)) #t]
    [`(let ([,_ (if (,(? cmp?) ,(? atom?) ,(? atom?)) ,(? anf-exp?) ,(? anf-exp?))]) ,(? anf-exp?)) #t]
    [`(let ([,_ ,(? anf-rhs?)]) ,(? anf-exp?))                      #t]
    [`(if ,(? atom?) ,(? anf-exp?) ,(? anf-exp?))                   #t]
    ;; fused compare-and-branch (>= -O1): the test is one comparison
    ;; over atoms, never materialized as a boolean
    [`(if (,(? cmp?) ,(? atom?) ,(? atom?)) ,(? anf-exp?) ,(? anf-exp?)) #t]
    [_                                                              #f]))

(define (anf-program? p)
  (match p
    [`(program ,n-globals ,defns ...)
     (andmap (λ (d) (match d
                      [`(define (,f ,formals ...) ,e-body)
                       (and (andmap symbol? (cons f formals))
                            (anf-exp? e-body))]
                      [_ #f]))
             defns)]
    [_                     #f]))

;; ---------------------------------------------------------------------
;; 11) Blocks IR: labeled blocks of seq/assign over atomic rhs
;; ---------------------------------------------------------------------

(define (blocks-rhs? rhs)
  (match rhs
    [(? atom?)                         #t]
    [`(string-lit ,_)                  #t]
    [`(fun-ref ,(? symbol?))           #t]
    [`(global-ref ,_)                  #t]
    [`(unsafe-vector-ref ,(? atom?) ,(? fixnum?)) #t]
    [`(app ,(? app-rator?) ,args ...)  (andmap atom? args)]
    [`(papp ,(? fixnum?) ,(? app-rator?) ,args ...) (andmap atom? args)]
    [`(,(? prim?) ,args ...)           (andmap atom? args)]
    [_                                 #f]))

(define (blocks-stmt? s)
  (match s
    [`(assign ,(? symbol?) ,(? blocks-rhs?))                         #t]
    [`(global-set! ,(? exact-nonnegative-integer?) ,(? atom?))       #t]
    [`(unsafe-vector-set! ,(? atom?) ,(? fixnum?) ,(? atom?))        #t]
    [`(effect ,(? blocks-rhs?))                                      #t]
    [_                                                               #f]))

(define (blocks-tail? s)
  (match s
    [`(return ,a)                                   (atom? a)]
    [`(tail-app ,(? fixnum?) ,(? app-rator?) ,args ...) (andmap atom? args)]
    [`(seq ,(? blocks-stmt?) ,rest)                 (blocks-tail? rest)]
    ;; the test is either the classic (eq? a #f)/(< a b) over atoms
    ;; or a fused comparison (>= -O1); the FIRST goto is the branch
    ;; taken when the comparison holds
    [`(if (,(? cmp?) ,(? atom?) ,(? atom?))
          (goto ,(? label?))
          (goto ,(? label?)))                       #t]
    [`(goto ,(? label?))                            #t]
    [_                                              #f]))

(define (blocks-program? p)
  (define (per-defn defn)
    (match defn
      [`(define (,f ,formals ...) ,blocks)
       (and (hash? blocks)
            (hash-has-key? blocks f)
            (andmap label? (hash-keys blocks))
            (andmap (λ (x) (blocks-tail? (hash-ref blocks x))) (hash-keys blocks)))]
      [_ #f]))
  (match p
    [`(program ,n-globals ,defns ...)
     (andmap per-defn defns)]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 12) Locals uncovered on a per-function basis
;; ---------------------------------------------------------------------

(define (locals-program? p)
  (define (per-defn defn)
    (match defn
      [`(define ,locals (,f ,formals ...) ,blocks)
       (and (set? locals)
            (hash? blocks)
            (hash-has-key? blocks f)
            (andmap label? (hash-keys blocks))
            (andmap (λ (x) (blocks-tail? (hash-ref blocks x))) (hash-keys blocks)))]
      [_ #f]))
  (match p
    [`(program ,n-globals ,defn ...)
     (andmap per-defn defn)]
    [_ #f]))

;; ---------------------------------------------------------------------
;; 13) Instruction-level IRs. Both backends produce "abstract
;; machine instructions with (var x) operands", then registers are
;; allocated (regalloc.rkt), then target-specific patching runs.
;; The instruction vocabularies differ per target, so the precise
;; per-instruction predicates live in the backends; here we check
;; program shape and operand discipline generically.
;; ---------------------------------------------------------------------

(define (operand/vars? op)
  (or (imm? op) (reg? op) (var? op) (byte-reg? op) (deref? op) (global? op)))

(define (operand/homes? op)
  (or (imm? op) (reg? op) (deref? op) (byte-reg? op) (global? op)))

;; instr-program?: blocks are lists whose operands may still be vars
(define (instr-program? p)
  (define (per-defn defn)
    (match defn
      [`(define ,info (,f ,formals ...) ,blocks)
       (and (hash? blocks)
            (hash-has-key? blocks f)
            (andmap (λ (blk-name) (list? (hash-ref blocks blk-name)))
                    (hash-keys blocks)))]
      [_ #f]))
  (match p
    [`(program ,n-globals ,defns ...)
     (andmap per-defn defns)]
    [_ #f]))

;; After register allocation, no (var x) operands remain anywhere.
(define (no-vars-instr? i)
  (match i
    [`(,_ ,ops ...) (andmap (λ (op) (match op [`(var ,_) #f] [_ #t])) ops)]
    [_ #t]))

(define (homes-assigned-program? p)
  (define (per-defn defn)
    (match defn
      [`(define ,info (,f ,args ...) ,blocks)
       (and (hash? info)
            (hash-has-key? blocks f)
            (andmap (λ (blk-name)
                      (andmap no-vars-instr? (hash-ref blocks blk-name)))
                    (hash-keys blocks)))]
      [_ #f]))
  (match p
    [`(program ,n-globals ,defns ...) (andmap per-defn defns)]
    [_ #f]))

;; patched-program? and the final target predicate are supplied by
;; each backend (they know their ISA's constraints); backends export
;; patched-program-x86?/patched-program-arm64? and main.rkt selects.

(define (final-program? p) (homes-assigned-program? p))
