#lang racket

;; Puffin -- compile.rkt: the frontend and middle-end.
;;
;; Descended from the CIS352/531 p5 compiler (R4/R5 -> x86-64); see
;; docs/DELTA.md for a pass-by-pass account of what changed. The
;; pipeline:
;;
;; --> Puffin        -- Source program (s-expressions; bare files get wrapped)  <INPUT>
;; |
;; +-> core          -- match/cond/case/when/unless/named-let/let*/multi-  [desugar]
;; |                    binding-let/multi-body/quote/list/vector/n-ary ops
;; |                    expanded; strings become (string-lit s)
;; |
;; +-> shrunk        -- and/or/not/binary minus/<=,>,>= removed; begin ->  [shrink]
;; |                    let chains; while wrapped as (let ([_ (while g b)]) r)
;; |
;; +-> unique        -- Every bound identifier is written exactly once     [uniqueify]
;; |
;; +-> globals       -- Top-level value defines and expressions folded     [collect-globals]
;; |                    into main; global reads/writes become
;; |                    (global-ref i)/(global-set! i e); program carries
;; |                    its global count
;; |
;; +-> revealed      -- Calls explicit via fun-ref and app                 [reveal-functions]
;; |
;; +-> no-set!       -- set! eliminated; mutated locals boxed (unsafe      [assignment-convert]
;; |                    one-slot vectors)
;; |
;; +-> closures      -- lambdas lifted to top-level defines; closure       [lift-lambdas]
;; |                    records via make-closure
;; |
;; +-> limited       -- >6-arg functions pass the rest in a vector         [limit-functions]
;; |
;; +-> ANF           -- flattened: every rhs is one prim/app over atoms    [anf-convert]
;; |
;; +-> blocks        -- labeled blocks of seq/assign/effect + if/goto      [explicate-control]
;; |
;; +-> locals        -- local variable sets uncovered per function         [uncover-locals]
;; |
;; +-> (backend)     -- select-instructions, allocate-registers (live-     [backend-x86.rkt /
;;                      range linear scan), patch-instructions,             backend-arm64.rkt]
;;                      prelude-and-conclusion, render

(require "irs.rkt")     ;; Definition of each IR (please read)
(require "system.rkt")  ;; System-specific details
(require "stdlib.rkt")  ;; The standard library manifest
(require "provenance.rkt") ;; IR provenance tags (see docs/DELTA.md)
(require "types.rkt")   ;; the gradual typechecker (docs/TYPES.md)

(provide (all-defined-out)) ;; export everything for testing

;; ---------------------------------------------------------------------
;; Pass: desugar
;;
;; Turns full Puffin into core Puffin. Everything here is *surface*
;; convenience: no new runtime concepts, only rewrites into forms
;; the rest of the pipeline already understands. Scope-aware: we
;; track bound variables so that a stdlib primitive used as a bare
;; variable ((map car xs)-style) eta-expands to a lambda, while a
;; let-bound `car` stays a variable reference.
;; ---------------------------------------------------------------------

(define (desugar p)
  ;; gradual typecheck first (docs/TYPES.md): desugar is the funnel
  ;; every route passes through, so checking here covers the
  ;; interpreter, the chain, both backends, and the trace server.
  ;; Types then erase below; unannotated code cannot fail.
  (typecheck-program p)
  ;; ---- gradual types (docs/TYPES.md): ADT tables ---------------------
  ;; define-type constructors are collected up front (all of a
  ;; module's types are implicitly mutually recursive, like top-level
  ;; defines), so match patterns can recognize constructor heads and
  ;; the lowering below can emit their defines before the prim-shadow
  ;; rename map is computed.
  (define ctor-arity (make-hasheq))     ;; ctor -> field count
  (define nullary-ctors (mutable-seteq))
  (define type-ctors (make-hasheq))     ;; ADT name -> (ctor ...), for cast descs
  (define decl-types (make-hasheq))     ;; (: name t) declarations, for casts
  (match p
    [`(program ,forms ...)
     (for ([f forms])
       (match f
         ;; #%extern-type: an imported ADT under separate compilation
         ;; (spliced from the dependency's .pufi; see types.rkt) --
         ;; registers constructors for patterns and cast descs exactly
         ;; like define-type, but lower-type-form emits NO defines
         ;; (the constructors live in the exporting unit's .o)
         [`(,(or 'define-type '#%extern-type) ,head ,ctors ...)
          (hash-set! type-ctors
                     (match head [`(,n ,_ ...) n] [n n])
                     (map car ctors))
          (for ([c ctors])
            (match c
              [`(,cn ,fts ...)
               (hash-set! ctor-arity cn (length fts))
               (when (null? fts) (set-add! nullary-ctors cn))]))]
         [`(: ,(? symbol? n) ,t) (hash-set! decl-types n t)]
         [_ (void)]))])
  (define (ctor-name? x) (and (symbol? x) (hash-has-key? ctor-arity x)))
  ;; define-foreign-type heads (docs/FFI.md §6): opaque handle types.
  ;; cast-desc gives them the (fptr <shown> <brand>) desc form.
  ;; (Plain scan over (cdr p), not a match: module-load gensym budget.)
  (define foreign-types (mutable-seteq))
  (for-each
   (λ (f)
     (when (and (pair? f)
                (or (eq? (car f) 'define-foreign-type)
                    (eq? (car f) '#%extern-foreign-type))
                (pair? (cdr f)) (symbol? (cadr f)))
       (set-add! foreign-types (cadr f))))
   (cdr p))

  ;; annotation helpers: [x : t] formals and [x : t e] let bindings
  (define (annotated-formal? f) (match f [`(,(? symbol?) : ,_) #t] [_ #f]))
  (define (strip-formals fs)
    (map (λ (f) (match f [`(,x : ,_) x] [x x])) fs))
  (define (annotated-binding? b) (match b [`(,(? symbol?) : ,_ ,_) #t] [_ #f]))
  (define (strip-binding b) (match b [`(,x : ,_ ,e) `(,x ,e)] [b b]))
  (define (formal-type f) (match f [`(,_ : ,t) t] [_ '_]))
  (define (cast-binding b)
    (match b
      [`(,x : ,t ,e) `(,x ,(cast-expr e t (string-append "let " (nm-str x))))]
      [b b]))

  ;; ---- transient casts (docs/TYPES.md §4) ---------------------------
  ;; A DECLARED concrete type is a runtime boundary: desugar guards it
  ;; with a first-order cast-check call (outermost shape only). The
  ;; desc is a bare SYMBOL for every built-in shape -- quoted symbols
  ;; are immediates, so the cast site allocates nothing -- and
  ;; (adt <type> tag ...) for define-types (the constructor set is
  ;; embedded so (Some 1) passes an (Option Int) cast but a Shape
  ;; instance fails it; those descs are quoted lists, rebuilt per
  ;; execution). `_` and type VARIABLES get no cast (the gradual
  ;; guarantee: unannotated code compiles untouched, byte-for-byte).
  ;; ARROW types get no cast either: on the bytecode VM a bare
  ;; function value is a tagged fixnum function INDEX,
  ;; indistinguishable from an Int, so "is this callable" cannot be
  ;; answered soundly -- the call site's own failure is the net for
  ;; arrows. (Mut t) shares heap kinds with t at runtime: same check.
  ;; The PRELUDE's signatures are (#%prelude: name t) -- the same
  ;; trust class as the manifest's prim types, so they type calls but
  ;; never insert casts (and prelude tail loops stay tail).
  ;; blame labels and the adt desc's display element carry SOURCE
  ;; spellings (system.rkt module-demangle): a runtime cast error must
  ;; say Shape, never Shape_shapes_826109a6. The desc's constructor
  ;; TAG list stays mangled -- those are the runtime identities the
  ;; check compares against.
  (define (nm-str s) (symbol->string (module-demangle s)))
  (define (demangle-type t)
    (cond [(symbol? t) (module-demangle t)]
          [(pair? t) (cons (demangle-type (car t)) (demangle-type (cdr t)))]
          [else t]))
  (define (cast-desc t)
    ;; foreign handle types first (a plain test, not a match clause:
    ;; gensym budget): kind 19 + brand (lib/foreign.c, lib/cast.c)
    (if (and (symbol? t) (set-member? foreign-types t))
        (list 'fptr (module-demangle t) t)
        (cast-desc-core t)))
  (define (cast-desc-core t)
    (match t
      [(or 'Int 'Bool 'Sym 'Str 'Void) t]
      [`(Pairof ,_ ,_) 'Pairof]
      [`(List ,_) 'List]
      [`(Vec ,_) 'Vec]
      [`(Hash ,_ ,_) 'Hash]
      [`(Set ,_) 'Set]
      [`(Mut ,t0) (cast-desc t0)]
      [(? symbol? n) #:when (hash-has-key? type-ctors n)
       `(adt ,(module-demangle n) ,@(hash-ref type-ctors n))]
      [`(,(? symbol? n) ,_ ...) #:when (hash-has-key? type-ctors n)
       `(adt ,(demangle-type t) ,@(hash-ref type-ctors n))]
      [_ #f]))
  ;; surface rewrite: e checked against t, or e untouched if t has no
  ;; first-order check (h then compiles cast-check like any prim).
  ;; The blame label carries the declared boundary's source position
  ;; (system.rkt origin-suffix) -- resolved HERE, at desugar time:
  ;; compile-time strings, no runtime cost change.
  (define (cast-expr e t blame)
    (define d (cast-desc t))
    (if d `(cast-check ,e (quote ,d) ,(string-append blame (origin-suffix))) e))
  ;; the shared body rewrite for annotated/declared functions: entry
  ;; checks on the annotated formals, a result check wrapping the
  ;; body -- (let () ...) keeps internal-define scoping intact under
  ;; the wrap. Everything stays SURFACE syntax; the ordinary walker
  ;; compiles it (and renames the formal references consistently).
  (define (body-with-casts owner formal-names arg-ts rt body)
    (define entry
      (filter-map
       (λ (x t)
         (define d (cast-desc t))
         (and d `(cast-check ,x (quote ,d)
                             ,(string-append owner "'s argument " (nm-str x)
                                             (origin-suffix)))))
       formal-names arg-ts))
    (define body+
      (cond
        [(cast-desc rt)
         => (λ (d) (list `(cast-check (let () ,@body) (quote ,d)
                                      ,(string-append owner "'s result"
                                                      (origin-suffix)))))]
        [else body]))
    (append entry body+))
  ;; a (: f ...) declaration supplies the formal/result types a
  ;; define doesn't spell inline (inline annotations win per position)
  (define (declared-arrow f nargs)
    (match (hash-ref decl-types f #f)
      [`(-> ,as ... ,r) #:when (= (length as) nargs) (cons as r)]
      [_ #f]))
  (define (declared-star f nfixed)
    (match (hash-ref decl-types f #f)
      [`(->* (,as ...) ,_ ,r) #:when (= (length as) nfixed) (cons as r)]
      [_ #f]))
  (define (split-dotted-formals formals)
    (let split ([fo formals] [acc '()])
      (cond [(symbol? fo) (values (reverse acc) fo)]
            [(pair? fo) (split (cdr fo) (cons (car fo) acc))]
            [else (values (reverse acc) fo)])))  ;; malformed: per-form errors
  (define (lower-annotated-define f formals rt body)
    (define da (declared-arrow f (length formals)))
    (define arg-ts
      (for/list ([fo formals] [i (in-naturals)])
        (match fo
          [`(,_ : ,t) t]
          [_ (if da (list-ref (car da) i) '_)])))
    (define rt* (or rt (and da (cdr da))))
    `(define (,f ,@(strip-formals formals))
       ,@(body-with-casts (nm-str f) (strip-formals formals)
                          arg-ts rt* body)))

  ;; `bound` maps every lexically bound name to the name to use for
  ;; it downstream. Binding a name that collides with a stdlib
  ;; primitive renames it (gensym), so that after this pass a
  ;; primitive name in operator position *always* means the
  ;; primitive--later passes never re-litigate shadowing.
  (define (bind bound x)
    (if (surface-prim? x)
        (let ([x+ (gensym x)]) (values (hash-set bound x x+) x+))
        (values (hash-set bound x x) x)))
  (define (bind* bound xs)
    (for/fold ([b bound] [acc '()] #:result (values b (reverse acc)))
              ([x xs])
      (define-values (b+ x+) (bind b x))
      (values b+ (cons x+ acc))))

  ;; expand a quoted datum into constructors over atoms
  (define (quote->expr d)
    (cond [(symbol? d)  `(quote ,d)]
          [(fixnum? d)  d]
          [(boolean? d) d]
          [(string? d)  `(string-lit ,d)]
          [(null? d)    '(nil)]
          [(pair? d)    `(cons ,(quote->expr (car d)) ,(quote->expr (cdr d)))]
          [else (error 'desugar "unsupported quoted datum: ~a" d)]))

  ;; quasiquote expression expansion (depth-aware; nested quasiquote
  ;; increments, unquote decrements; splicing only at depth 1)
  ;; (built with `list` where the template would mention unquote /
  ;; unquote-splicing as data -- Racket's quasiquote reads those as
  ;; escapes even under quote)
  (define (qq->expr q depth)
    (match q
      [(list 'unquote e)
       (if (= depth 1)
           e
           (list 'list (list 'quote 'unquote) (qq->expr e (sub1 depth))))]
      [(list 'quasiquote e)
       (list 'list (list 'quote 'quasiquote) (qq->expr e (add1 depth)))]
      [(cons (list 'unquote-splicing e) rest)
       (if (= depth 1)
           (list 'append e (qq->expr rest depth))
           (list 'cons
                 (list 'list (list 'quote 'unquote-splicing) (qq->expr e (sub1 depth)))
                 (qq->expr rest depth)))]
      [(cons a rest) (list 'cons (qq->expr a depth) (qq->expr rest depth))]
      ['() ''()]
      [(? symbol? s) (list 'quote s)]
      [d d]))

  ;; (body...) with implicit begin; internal defines are scoped over
  ;; the whole body, letrec*-style (bound first, initialized in
  ;; sequence position -- so mutual recursion between inner helpers
  ;; works, as in every pass of this very compiler)
  (define (body->expr es bound)
    (define def-names
      (filter-map (λ (e) (match e
                           [`(define (,f ,_ ...) ,_ ...) f]
                           [`(define ,(? symbol? x) ,_) x]
                           [_ #f]))
                  es))
    (cond
      [(null? def-names)
       (match es
         [`(,e) (h e bound)]
         [`(,es ...) `(begin ,@(map (λ (e) (h e bound)) es))])]
      [else
       (define-values (bound+ names+) (bind* bound def-names))
       (define (step e)
         (match e
           [`(define (,f ,xs ...) ,dbody ...)
            (h `(set! ,f (lambda ,xs ,@dbody)) bound+)]
           [`(define ,(? symbol? x) ,e0)
            (h `(set! ,x ,e0) bound+)]
           [e (h e bound+)]))
       (foldr (λ (n acc) `(let ([,n (void)]) ,acc))
              `(begin ,@(map step es))
              names+)]))

  ;; -----------------------------------------------------------------
  ;; match expansion. compile-clause chains clauses through `fail`
  ;; thunks so each clause's code appears exactly once.
  ;; -----------------------------------------------------------------

  ;; Compile pattern pat against subject (a variable), producing
  ;; success on a match (with pattern variables bound) and fail-e
  ;; otherwise. fail-e is duplicated only at test sites--it is
  ;; always a tiny thunk call. `bound` already contains the pattern
  ;; variables' (possibly renamed) bindings.
  ;; ADT constructor test + field extraction: an instance has its own
  ;; heap kind (docs/TYPES.md §2, lib/adt.c) carrying the constructor
  ;; symbol and the fields; the kind + tag check suffices (the tag is
  ;; unique per constructor and fixes the arity) and makes nullary
  ;; constructors safe in patterns even before their define
  ;; initializes
  (define (compile-ctor-pattern c ps subject success fail-e bound)
    (define (fields ps i success)
      (match ps
        ['() success]
        [`(,p . ,rest)
         (define x (gensym 'adt))
         `(let ([,x (adt-ref ,subject ,i)])
            ,(compile-pattern p x (fields rest (add1 i) success) fail-e bound))]))
    `(if (if (adt? ,subject)
             (eq? (adt-tag ,subject) (quote ,c))
             #f)
         ,(fields ps 0 success)
         ,fail-e))

  (define (compile-pattern pat subject success fail-e bound)
    (match pat
      ['_ success]
      ;; a bare nullary-constructor name matches that constructor,
      ;; not a binder (None in [(Some x) ...] [None ...])
      [(? (λ (s) (and (symbol? s) (set-member? nullary-ctors s))) c)
       (compile-ctor-pattern c '() subject success fail-e bound)]
      [(? symbol? x) `(let ([,(hash-ref bound x x) ,subject]) ,success)]
      [(? fixnum? n) `(if (eq? ,subject ,n) ,success ,fail-e)]
      [(? boolean? b) `(if (eq? ,subject ,b) ,success ,fail-e)]
      [(? string? s) `(if (if (string? ,subject) (string=? ,subject (string-lit ,s)) #f)
                          ,success ,fail-e)]
      [(list 'quote (? symbol? s)) `(if (eq? ,subject (quote ,s)) ,success ,fail-e)]
      [(list 'quote d) `(if (equal? ,subject ,(quote->expr d)) ,success ,fail-e)]
      [(list 'quasiquote q) (compile-quasi q subject success fail-e bound)]
      [(list 'cons p0 p1)
       (define a (gensym 'mat-a))
       (define d (gensym 'mat-d))
       `(if (pair? ,subject)
            (let ([,a (car ,subject)])
              ,(compile-pattern p0 a
                                `(let ([,d (cdr ,subject)])
                                   ,(compile-pattern p1 d success fail-e bound))
                                fail-e bound))
            ,fail-e)]
      [(list-rest 'list ps)
       ;; (list p...) = nested cons ending in '()
       (compile-pattern
        (foldr (λ (p acc) `(cons ,p ,acc)) ''() ps)
        subject success fail-e bound)]
      [(list-rest 'vector ps)
       (define n (length ps))
       (define (elems ps i success)
         (match ps
           ['() success]
           [`(,p . ,rest)
            (define x (gensym 'mat-v))
            `(let ([,x (vector-ref ,subject ,i)])
               ,(compile-pattern p x (elems rest (add1 i) success) fail-e bound))]))
       `(if (if (vector? ,subject) (eq? (vector-length ,subject) ,n) #f)
            ,(elems ps 0 success)
            ,fail-e)]
      [(list '? pred p)
       `(if (,(hash-ref bound pred pred) ,subject)
            ,(compile-pattern p subject success fail-e bound)
            ,fail-e)]
      ;; ADT constructor patterns: (Ctor p ...)
      [`(,(? ctor-name? c) ,ps ...)
       (unless (= (length ps) (hash-ref ctor-arity c))
         (error 'desugar "constructor ~a expects ~a fields, got ~a in pattern ~a"
                c (hash-ref ctor-arity c) (length ps) pat))
       (compile-ctor-pattern c ps subject success fail-e bound)]))

  ;; quasiquote patterns: symbols/numbers match themselves as data;
  ;; (unquote p) escapes back to pattern matching; lists match
  ;; proper lists element-wise. Ellipsis is supported in the form
  ;; the compiler itself is written in -- `(lambda (,xs ...) ,body),
  ;; `(program ,defns ...) -- i.e. the repeated pattern is a plain
  ;; variable (or _) that collects a sublist, with any fixed-shape
  ;; patterns after it.
  (define (compile-quasi q subject success fail-e bound)
    (match q
      [(list 'unquote p) (compile-pattern p subject success fail-e bound)]
      [`(,q0 ,dots . ,q-rest)
       #:when (equal? dots '...)
       ;; General ellipsis, Racket-style: q0 matches each element of
       ;; a middle segment (any fixed-shape q-rest follows), and each
       ;; variable inside q0 collects a *list* of its per-element
       ;; matches. Nested ellipsis composes (the inner collection is
       ;; just another per-element value).
       (define evars (sort (set->list (pattern-vars (list 'quasiquote q0))) symbol<?))
       (define accs (map (λ (v) (gensym 'mat-acc)) evars))
       (define k (length q-rest))
       ;; little recursive workers, tied with set! (assignment
       ;; conversion boxes them)
       (define len-f (gensym 'mat-len))
       (define take-f (gensym 'mat-take))
       (define drop-f (gensym 'mat-drop))
       (define rev-f (gensym 'mat-rev))
       (define walk-f (gensym 'mat-walk))
       (define n-var (gensym 'mat-n))
       (define suffix-var (gensym 'mat-suffix))
       (define elem (gensym 'mat-elem))
       (define elem-holder (gensym 'mat-l))
       ;; per-element: match q0 against elem; on success push each
       ;; var's value and keep walking; a non-matching element makes
       ;; the whole walk produce #f
       (define pushes
         (map (λ (v acc) `(set! ,acc (cons ,(hash-ref bound v v) ,acc))) evars accs))
       (define per-element
         (compile-quasi q0 elem
                        `(begin ,@pushes (,walk-f (cdr ,elem-holder)))
                        #f bound))
       ;; match the k suffix patterns element-wise against suffix-var
       (define (suffix-chain qs subj success)
         (match qs
           ['() success]
           [`(,q1 . ,rest)
            (define a (gensym 'mat-a))
            (define d (gensym 'mat-d))
            `(let ([,a (car ,subj)])
               ,(compile-quasi q1 a
                               `(let ([,d (cdr ,subj)])
                                  ,(suffix-chain rest d success))
                               fail-e bound))]))
       ;; bind each collected variable (reversing the pushes) around
       ;; the suffix match + success
       (define (bind-collected vs as body)
         (match (list vs as)
           [`(() ()) body]
           [`((,v . ,vs+) (,a . ,as+))
            `(let ([,(hash-ref bound v v) (,rev-f ,a (nil))])
               ,(bind-collected vs+ as+ body))]))
       `(let ([,len-f (void)])
          (let ([,take-f (void)])
            (let ([,drop-f (void)])
              (let ([,rev-f (void)])
                (let ([,walk-f (void)])
                  ,(let nest-accs ([as accs])
                     (match as
                       ['()
                        `(begin
                           (set! ,len-f (lambda (l n) (if (pair? l) (,len-f (cdr l) (+ n 1)) (if (null? l) n -1))))
                           (set! ,take-f (lambda (l i) (if (eq? i 0) (nil) (cons (car l) (,take-f (cdr l) (- i 1))))))
                           (set! ,drop-f (lambda (l i) (if (eq? i 0) l (,drop-f (cdr l) (- i 1)))))
                           (set! ,rev-f (lambda (l acc) (if (null? l) acc (,rev-f (cdr l) (cons (car l) acc)))))
                           (set! ,walk-f (lambda (,elem-holder)
                                           (if (null? ,elem-holder)
                                               #t
                                               (if (pair? ,elem-holder)
                                                   (let ([,elem (car ,elem-holder)])
                                                     ,per-element)
                                                   #f))))
                           (let ([,n-var (,len-f ,subject 0)])
                             (if (< ,n-var ,k)
                                 ,fail-e
                                 (if (,walk-f (,take-f ,subject (- ,n-var ,k)))
                                     ,(bind-collected
                                       evars accs
                                       `(let ([,suffix-var (,drop-f ,subject (- ,n-var ,k))])
                                          ,(suffix-chain q-rest suffix-var success)))
                                     ,fail-e))))]
                       [`(,a . ,more) `(let ([,a (nil)]) ,(nest-accs more))])))))))]
      [(? symbol? s) `(if (eq? ,subject (quote ,s)) ,success ,fail-e)]
      [(? fixnum? n) `(if (eq? ,subject ,n) ,success ,fail-e)]
      [(? boolean? b) `(if (eq? ,subject ,b) ,success ,fail-e)]
      ['() `(if (null? ,subject) ,success ,fail-e)]
      [`(,q0 . ,q-rest)
       (define a (gensym 'mat-a))
       (define d (gensym 'mat-d))
       `(if (pair? ,subject)
            (let ([,a (car ,subject)])
              ,(compile-quasi q0 a
                              `(let ([,d (cdr ,subject)])
                                 ,(compile-quasi q-rest d success fail-e bound))
                              fail-e bound))
            ,fail-e)]))

  ;; pattern variables bound by a pattern (needed to extend `bound`
  ;; around clause bodies and guards)
  (define (pattern-vars pat)
    (match pat
      ['_ (set)]
      ;; a bare nullary constructor is a test, not a binder
      [(? (λ (s) (and (symbol? s) (set-member? nullary-ctors s))) _) (set)]
      [(? symbol? x) (set x)]
      [(? fixnum?) (set)]
      [(? boolean?) (set)]
      [(? string?) (set)]
      [(list 'quote _) (set)]
      [(list 'quasiquote q)
       (let quasi-vars ([q q])
         (match q
           [(list 'unquote p) (pattern-vars p)]
           [`(,q0 . ,q1) (set-union (quasi-vars q0) (quasi-vars q1))]
           [_ (set)]))]
      [(list 'cons p0 p1) (set-union (pattern-vars p0) (pattern-vars p1))]
      [(list-rest 'list ps) (apply set-union (set) (map pattern-vars ps))]
      [(list-rest 'vector ps) (apply set-union (set) (map pattern-vars ps))]
      [(list '? _ p) (pattern-vars p)]
      [`(,(? ctor-name?) ,ps ...) (apply set-union (set) (map pattern-vars ps))]))

  (define (compile-match e-subj clauses bound)
    (define subject (gensym 'mat-subject))
    (define (per-clause clauses)
      (match clauses
        ['() `(error (quote match-failure))]
        [`([,pat #:when ,guard ,body ...] . ,rest)
         (per-clause-guarded pat guard body rest)]
        [`([,pat ,body ...] . ,rest)
         (per-clause-guarded pat #t body rest)]))
    (define (per-clause-guarded pat guard body rest)
      (define fail (gensym 'mat-fail))
      (define-values (bound+ _renamed) (bind* bound (set->list (pattern-vars pat))))
      (define success
        (if (equal? guard #t)
            (body->expr body bound+)
            `(if ,(h guard bound+) ,(body->expr body bound+) (,fail))))
      `(let ([,fail (lambda () ,(per-clause rest))])
         ,(compile-pattern pat subject success `(,fail) bound+)))
    `(let ([,subject ,(h e-subj bound)])
       ,(per-clause clauses)))

  ;; -----------------------------------------------------------------
  ;; the expression walker
  ;; -----------------------------------------------------------------

  (define (h e bound) (prov (h-core e bound) e))
  (define (h-core e bound)
    (match e
      [#t #t]
      [#f #f]
      [(? fixnum? n) n]
      [(? string? s) `(string-lit ,s)]
      ['(void) '(void)]
      ['(read) '(read)]
      [(list 'quote d) (quote->expr d)]
      ;; quasiquote EXPRESSIONS (the compiler-construction idiom:
      ;; `(let ([,x ,e]) ,body)). Standard depth-aware expansion into
      ;; cons/append; unquote-splicing supported. The emitted `cons`
      ;; and `append` are the primitives/prelude (desugar has already
      ;; renamed any user shadowing of them at binder sites).
      [(list 'quasiquote q) (h (qq->expr q 1) bound)]
      [(? symbol? x)
       (cond
         [(hash-has-key? bound x) (hash-ref bound x)]
         ;; a stdlib prim used as a value eta-expands
         [(and (surface-prim? x) (not (member x '(list vector not))))
          (let* ([arity (prim-arity x)]
                 [xs (for/list ([i (in-range arity)]) (gensym 'eta))])
            `(lambda ,xs (,x ,@xs)))]
         [else x])]
      ;; control
      [`(if ,e0 ,e1 ,e2) `(if ,(h e0 bound) ,(h e1 bound) ,(h e2 bound))]
      [`(cond) '(void)]
      [`(cond [else ,body ...]) (body->expr body bound)]
      [`(cond [,guard ,body ...] ,rest ...)
       `(if ,(h guard bound) ,(body->expr body bound) ,(h `(cond ,@rest) bound))]
      [`(when ,g ,body ...) `(if ,(h g bound) ,(body->expr body bound) (void))]
      [`(unless ,g ,body ...) `(if ,(h g bound) (void) ,(body->expr body bound))]
      [`(case ,e-k ,clauses ...)
       (define k (gensym 'case-k))
       (define (per-clause clauses)
         (match clauses
           ['() '(void)]
           [`([else ,body ...]) (body->expr body bound)]
           [`([(,ds ...) ,body ...] . ,rest)
            `(if ,(foldr (λ (d acc) `(or (eq? ,k ,(quote->expr d)) ,acc)) #f ds)
                 ,(body->expr body bound)
                 ,(per-clause rest))]))
       `(let ([,k ,(h e-k bound)]) ,(per-clause clauses))]
      [`(match ,e-subj ,clauses ...) (compile-match e-subj clauses bound)]
      ;; gradual types: annotations LOWER to transient casts guarding
      ;; the declared boundary (see cast-desc above), then erase; a
      ;; type with no first-order check erases as before. The rebuilt
      ;; plain forms re-enter the walker.
      [`(ann ,e0 ,t) #:when (not (hash-has-key? bound 'ann))
       (h (cast-expr e0 t "ann") bound)]
      [`(,(or 'lambda 'λ) (,formals ...) : ,rt ,body ...)
       #:when (andmap (λ (f) (or (symbol? f) (annotated-formal? f))) formals)
       (h `(lambda ,(strip-formals formals)
             ,@(body-with-casts "lambda" (strip-formals formals)
                                (map formal-type formals) rt body))
          bound)]
      [`(,(or 'lambda 'λ) (,formals ...) ,body ...)
       #:when (ormap annotated-formal? formals)
       (h `(lambda ,(strip-formals formals)
             ,@(body-with-casts "lambda" (strip-formals formals)
                                (map formal-type formals) #f body))
          bound)]
      [`(let ,(? symbol? loop) (,(? list? bindings) ...) ,body ...)
       #:when (ormap annotated-binding? bindings)
       (h `(let ,loop ,(map cast-binding bindings) ,@body) bound)]
      [`(let (,(? list? bindings) ...) ,body ...)
       #:when (ormap annotated-binding? bindings)
       (h `(let ,(map cast-binding bindings) ,@body) bound)]
      [`(let* (,(? list? bindings) ...) ,body ...)
       #:when (ormap annotated-binding? bindings)
       (h `(let* ,(map cast-binding bindings) ,@body) bound)]
      ;; binding
      [`(let ,(? symbol? loop) ([,xs ,es] ...) ,body ...)
       ;; named let: a self-referential closure via set! (assignment
       ;; conversion boxes `loop`, so the closure sees itself)
       (h `(let ([,loop (void)])
             (begin (set! ,loop (lambda ,xs ,@body))
                    (,loop ,@es)))
          bound)]
      [`(let ([,xs ,es] ...) ,body ...)
       ;; parallel let: evaluate rhs into temps, then bind
       (define ts (map (λ (x) (gensym x)) xs))
       (define-values (bound+ xs+) (bind* bound xs))
       (foldr (λ (t e acc) `(let ([,t ,(h e bound)]) ,acc))
              (foldr (λ (x t acc) `(let ([,x ,t]) ,acc))
                     (body->expr body bound+)
                     xs+ ts)
              ts es)]
      [`(letrec ([,xs ,es] ...) ,body ...)
       (h `(let ,(map (λ (x) `[,x (void)]) xs)
             ,@(map (λ (x e0) `(set! ,x ,e0)) xs es)
             ,@body)
          bound)]
      [`(let* () ,body ...) (body->expr body bound)]
      [`(let* ([,x ,e0] ,rest ...) ,body ...)
       (define-values (bound+ x+) (bind bound x))
       `(let ([,x+ ,(h e0 bound)]) ,(h `(let* (,@rest) ,@body) bound+))]
      [`(,(or 'lambda 'λ) (,xs ...) ,body ...)
       (define-values (bound+ xs+) (bind* bound xs))
       `(lambda ,xs+ ,(body->expr body bound+))]
      ;; variadic lambdas: dotted formals normalize to a #%rest
      ;; marker before the rest name ((lambda args ...) is all-rest)
      [`(,(or 'lambda 'λ) ,formals ,body ...)
       (define-values (fixed rest-name)
         (let split ([f formals] [acc '()])
           (cond [(symbol? f) (values (reverse acc) f)]
                 [(pair? f) (split (cdr f) (cons (car f) acc))]
                 [else (error 'desugar "bad lambda formals: ~a" formals)])))
       (define-values (bound+ names+) (bind* bound (append fixed (list rest-name))))
       `(lambda (,@(take names+ (length fixed)) #%rest ,(last names+))
          ,(body->expr body bound+))]
      ;; sequencing / loops / mutation
      [`(begin ,es ... ,e-ret)
       `(begin ,@(map (λ (e) (h e bound)) es) ,(h e-ret bound))]
      [`(while ,g ,body ...) `(while ,(h g bound) ,(body->expr body bound))]
      [`(set! ,x ,e) `(set! ,(hash-ref bound x x) ,(h e bound))]
      ;; n-ary arithmetic / logic
      [`(+ ,e0) (h e0 bound)]
      [`(+ ,e0 ,e1) `(+ ,(h e0 bound) ,(h e1 bound))]
      [`(+ ,e0 ,es ...) (h `(+ (+ ,e0 ,(first es)) ,@(rest es)) bound)]
      [`(* ,e0) (h e0 bound)]
      [`(* ,e0 ,e1) `(* ,(h e0 bound) ,(h e1 bound))]
      [`(* ,e0 ,es ...) (h `(* (* ,e0 ,(first es)) ,@(rest es)) bound)]
      [`(- ,e0) `(- ,(h e0 bound))]
      [`(- ,e0 ,e1) `(- ,(h e0 bound) ,(h e1 bound))]
      [`(- ,e0 ,es ...) (h `(- (- ,e0 ,(first es)) ,@(rest es)) bound)]
      [`(and) #t]
      [`(and ,e0) (h e0 bound)]
      [`(and ,e0 ,es ...) `(and ,(h e0 bound) ,(h `(and ,@es) bound))]
      [`(or) #f]
      [`(or ,e0) (h e0 bound)]
      [`(or ,e0 ,es ...) `(or ,(h e0 bound) ,(h `(or ,@es) bound))]
      [`(not ,e0) `(not ,(h e0 bound))]
      [`(,(? cmp? c) ,e0 ,e1) #:when (not (hash-has-key? bound c))
       `(,c ,(h e0 bound) ,(h e1 bound))]
      ;; data constructors
      [`(list ,es ...) #:when (not (hash-has-key? bound 'list))
       (foldr (λ (e acc) `(cons ,(h e bound) ,acc)) '(nil) es)]
      [`(vector ,es ...) #:when (not (hash-has-key? bound 'vector))
       (define v (gensym 'vec))
       (define n (length es))
       `(let ([,v (make-vector ,n)])
          ,(let fill ([es es] [i 0])
             (match es
               ['() v]
               [`(,e . ,rest)
                `(begin (vector-set! ,v ,i ,(h e bound)) ,(fill rest (add1 i)))])))]
      ;; n-ary constructors for the immutable collections:
      ;; (hash k v ...) and (set v ...) chain their 0-ary prims
      [`(hash ,es ...)
       #:when (and (not (hash-has-key? bound 'hash)) (pair? es))
       (unless (even? (length es))
         (error 'desugar "(hash ...) expects an even number of arguments in ~a" e))
       (h (let build ([es es] [acc '(hash)])
            (match es
              ['() acc]
              [`(,k ,v . ,rest) (build rest `(hash-set ,acc ,k ,v))]))
          bound)]
      [`(set ,es ...)
       #:when (and (not (hash-has-key? bound 'set)) (pair? es))
       (h (foldl (λ (v acc) `(set-add ,acc ,v)) '(set) es) bound)]
      ;; stdlib prims in operator position (when not shadowed)
      [`(,(? symbol? op) ,es ...)
       #:when (and (not (hash-has-key? bound op)) (prim? op))
       (unless (= (length es) (prim-arity op))
         (error 'desugar "~a expects ~a arguments, got ~a in ~a" op (prim-arity op) (length es) e))
       `(,op ,@(map (λ (e) (h e bound)) es))]
      ;; application
      [`(,e-f ,e-args ...)
       `(,(h e-f bound) ,@(map (λ (e) (h e bound)) e-args))]))

  ;; ---- the FFI lowering (docs/FFI.md §8.1) ---------------------------
  ;; (foreign spath [rpath] (: name τ clause ...) ...) lowers to one
  ;; ordinary top-level define per declaration:
  ;;
  ;;   (define name
  ;;     (let ([i (#%ffi-register rpath spath cname 'desc)])
  ;;       (lambda (a ...) (#%ffi-calln i a ...))))
  ;;
  ;; The register runs at module top level in DAG order (= load-time
  ;; dlopen, §5.3); the lambda is an ordinary function (procedure?,
  ;; provide, eta, .pufi export all free); the body is an ordinary
  ;; prim call, so no backend changes anywhere. The desc is quoted
  ;; data: the marshaling schedule derived from the declared type,
  ;; with the import's source spelling + declaration position for
  ;; blame. Six-argument imports pack their arguments in a vector
  ;; (the import index occupies one of the six prim argument
  ;; registers). The checker (types.rkt) has already validated every
  ;; declaration. All plain pair tests: module-load gensym budget.
  (define ffi-widths '(I8 I16 I32 I64 U8 U16 U32 U64))
  (define ffi-scalar-specs
    '((Int . int) (Bool . bool) (Str . str)
      (I8 . i8) (I16 . i16) (I32 . i32) (I64 . i64)
      (U8 . u8) (U16 . u16) (U32 . u32) (U64 . u64)))
  (define (ffi-handle-spec head t)
    (list head t (symbol->string (module-demangle t))))
  (define (ffi-arg-spec a consume?)
    (define hit (assq a ffi-scalar-specs))
    (if hit (cdr hit) (ffi-handle-spec (if consume? 'handle-consume 'handle) a)))
  (define (ffi-ret-spec r gift)
    (cond [(eq? r 'Void) 'void]
          [(eq? r 'Str) (if gift (list 'str-gift gift) 'str)]
          [(and (pair? r) (eq? (car r) 'Nullable))
           (if (eq? (cadr r) 'Str)
               (if gift (list 'nullable-str-gift gift) (list 'nullable 'str))
               (ffi-handle-spec 'nullable-handle (cadr r)))]
          [(assq r ffi-scalar-specs) => cdr]
          [else (ffi-handle-spec 'handle r)]))
  ;; the default #:c-name: source spelling, `-` -> `_` (types.rkt has
  ;; already rejected names this cannot spell)
  (define (ffi-default-c-name s)
    (list->string
     (map (λ (ch) (if (char=? ch #\-) #\_ ch)) (string->list s))))
  (define (ffi-parse-clauses cs)   ;; -> (vector c-name gift consumes?)
    (let loop ([cs cs] [c-name #f] [gift #f] [consumes #f])
      (cond
        [(null? cs) (vector c-name gift consumes)]
        [(eq? (car cs) '#:c-name) (loop (cddr cs) (cadr cs) gift consumes)]
        [(eq? (car cs) '#:gift) (loop (cddr cs) c-name (cadr cs) consumes)]
        [else (loop (cdr cs) c-name gift #t)])))   ;; #:consumes
  (define (ffi-ftype? a)
    (and (symbol? a) (not (assq a ffi-scalar-specs)) (not (eq? a 'Void))))
  (define (lower-foreign-decl spath rpath d)
    (define name (cadr d))
    (define t (caddr d))
    (define cv (ffi-parse-clauses (cdddr d)))
    (define tail (cdr t))
    (define args (reverse (cdr (reverse tail))))
    (define ret (car (reverse tail)))
    (define n (length args))
    (define nm* (nm-str name))
    (define cname (or (vector-ref cv 0) (ffi-default-c-name nm*)))
    ;; #:consumes names the (single) handle-typed argument
    (define arg-specs
      (map (λ (a) (ffi-arg-spec a (and (vector-ref cv 2) (ffi-ftype? a)))) args))
    (define desc
      (cons nm* (cons (origin-suffix)
                      (cons (ffi-ret-spec ret (vector-ref cv 1)) arg-specs))))
    (define idx (gensym 'ffi))
    (define formals (map (λ (_) (gensym 'ffa)) args))
    (define call
      (if (= n 6)
          (list '#%ffi-call6 idx (cons 'vector formals))
          (cons (string->symbol (string-append "#%ffi-call" (number->string n)))
                (cons idx formals))))
    (list 'define name
          (list 'let (list (list idx (list '#%ffi-register rpath spath cname
                                           (list 'quote desc))))
                (list 'lambda formals call))))
  ;; ---- the #:include cross-check (docs/FFI.md §9.3, phase 4) --------
  ;; a build-time lint: redeclare every import with the prototype the
  ;; Puffin declaration implies and let `clang -fsyntax-only` hold it
  ;; against the library's own header -- conflicting redeclarations
  ;; are hard errors in C. Handle types are spelled `<SourceName> *`
  ;; (the cbindgen convention); a header that spells them otherwise
  ;; wants the lint off (it is opt-in per foreign form).
  (define (ffi-c-arg-type a)
    (cond [(eq? a 'Int) "int64_t"] [(eq? a 'I64) "int64_t"]
          [(eq? a 'I8) "int8_t"] [(eq? a 'I16) "int16_t"] [(eq? a 'I32) "int32_t"]
          [(eq? a 'U8) "uint8_t"] [(eq? a 'U16) "uint16_t"] [(eq? a 'U32) "uint32_t"]
          [(eq? a 'U64) "uint64_t"]
          [(eq? a 'Bool) "bool"]
          [(eq? a 'Str) "const char *"]
          [else (string-append (symbol->string (module-demangle a)) " *")]))
  (define (ffi-c-ret-type r gift)
    (cond [(eq? r 'Void) "void"]
          [(eq? r 'Str) (if gift "char *" "const char *")]
          [(and (pair? r) (eq? (car r) 'Nullable))
           (if (eq? (cadr r) 'Str)
               (if gift "char *" "const char *")
               (ffi-c-arg-type (cadr r)))]
          [else (ffi-c-arg-type r)]))
  (define (ffi-header-check! spath hdr decls)
    (define lines
      (map (λ (d)
             (define name (cadr d))
             (define t (caddr d))
             (define cv (ffi-parse-clauses (cdddr d)))
             (define tail (cdr t))
             (define args (reverse (cdr (reverse tail))))
             (define ret (car (reverse tail)))
             (define cname (or (vector-ref cv 0) (ffi-default-c-name (nm-str name))))
             (string-append
              "extern " (ffi-c-ret-type ret (vector-ref cv 1)) " " cname
              "(" (if (null? args)
                      "void"
                      (string-join (map ffi-c-arg-type args) ", "))
              ");"))
           decls))
    (define src
      (string-append "#include <stdint.h>\n#include <stdbool.h>\n"
                     "#include \"" hdr "\"\n"
                     (string-join lines "\n") "\n"))
    (define tmp (build-path (find-system-path 'temp-dir)
                            (format "pf-ffi-check-~a.c" (current-milliseconds))))
    (call-with-output-file tmp #:exists 'replace (λ (p) (display src p)))
    (unless (system (format "clang -fsyntax-only -I. ~a" (path->string tmp)))
      (error 'desugar "foreign: header cross-check failed for ~a against ~a" spath hdr)))

  (define (lower-foreign-form form)
    ;; (foreign spath [rpath] [#:include hdr] decl ...); an unresolved
    ;; form (pipe mode, direct desugar tests) uses spath as the load path
    (define spath (cadr form))
    (define resolved? (and (pair? (cddr form)) (string? (caddr form))))
    (define rpath (if resolved? (caddr form) spath))
    (define rest0 (if resolved? (cdddr form) (cddr form)))
    ;; form-level clauses (the checker validated them)
    (define include-hdr
      (and (pair? rest0) (eq? (car rest0) '#:include) (cadr rest0)))
    (define decls (if include-hdr (cddr rest0) rest0))
    (when include-hdr (ffi-header-check! spath include-hdr decls))
    (map (λ (d) (lower-foreign-decl spath rpath d)) decls))

  ;; gradual types: lower type-level forms before the prim-shadow map
  ;; is computed. A define-type becomes one define per constructor
  ;; (nullary = the singleton instance, n-ary = a builder function);
  ;; (: name t) declarations vanish; annotated defines lose their
  ;; [x : t] formals and `: t` results.
  (define (lower-type-form form)
    ;; FFI forms first (plain tests, not match clauses: gensym budget)
    (cond
      [(and (pair? form)
            (or (eq? (car form) 'define-foreign-type)
                (eq? (car form) '#%extern-foreign-type)))
       '()]
      [(and (pair? form) (eq? (car form) 'foreign))
       (lower-foreign-form form)]
      [else (lower-type-form-core form)]))
  (define (lower-type-form-core form)
    (match form
      [`(define-type ,_ ,ctors ...)
       ;; builders allocate the dedicated ADT kind and initialize the
       ;; fields (adt-alloc + adt-set!, mirroring how (vector ...)
       ;; lowers); a nullary constructor is its 0-field singleton
       (for/list ([c ctors])
         (match c
           [`(,cn) `(define ,cn (adt-alloc (quote ,cn) 0))]
           [`(,cn ,fts ...)
            (define xs (for/list ([_ fts]) (gensym 'fld)))
            (define v (gensym 'adt))
            `(define (,cn ,@xs)
               (let ([,v (adt-alloc (quote ,cn) ,(length fts))])
                 (begin ,@(for/list ([x xs] [i (in-naturals)])
                            `(adt-set! ,v ,i ,x))
                        ,v)))]))]
      [`(: ,(? symbol?) ,_) '()]
      ;; an imported ADT's registration form: nothing to define here
      [`(#%extern-type ,_ ,_ ...) '()]
      ;; prelude signatures: trusted -- typed by the checker, but no
      ;; casts (the same trust class as the manifest's prim types)
      [`(#%prelude: ,(? symbol?) ,_) '()]
      [`(define (,f ,formals ...) : ,rt ,body ...)
       #:when (andmap (λ (x) (or (symbol? x) (annotated-formal? x))) formals)
       (list (lower-annotated-define f formals rt body))]
      [`(define (,f ,formals ...) ,body ...)
       #:when (and (andmap (λ (x) (or (symbol? x) (annotated-formal? x))) formals)
                   (or (ormap annotated-formal? formals)
                       (declared-arrow f (length formals))))
       (list (lower-annotated-define f formals #f body))]
      ;; variadic defines with a declared (->* ...) type or an inline
      ;; `: rt` / annotated fixed formals: strip + cast the FIXED
      ;; formals and the result (the rest binder is always a proper
      ;; list the runtime itself built -- nothing to check).
      ;; Unannotated variadic defines fall through untouched.
      [`(define (,f . ,formals) ,body0 ...)
       #:when (and (symbol? f) (not (list? formals))
                   (let-values ([(fixed _r) (split-dotted-formals formals)])
                     (or (ormap annotated-formal? fixed)
                         (match body0 [`(: ,_ ,_ ...) #t] [_ #f])
                         (declared-star f (length fixed)))))
       (define-values (fixed rest-name) (split-dotted-formals formals))
       (define-values (rt body)
         (match body0
           [`(: ,t ,rest ...) (values t rest)]
           [_ (values #f body0)]))
       (define ds (declared-star f (length fixed)))
       (define arg-ts
         (for/list ([fo fixed] [i (in-naturals)])
           (match fo
             [`(,_ : ,t) t]
             [_ (if ds (list-ref (car ds) i) '_)])))
       (define rt* (or rt (and ds (cdr ds))))
       (list `(define (,f ,@(strip-formals fixed) . ,rest-name)
                ,@(body-with-casts (nm-str f) (strip-formals fixed)
                                   arg-ts rt* body)))]
      ;; value defines with a declared type: a concrete non-arrow
      ;; type checks the initializer; a declared arrow over a literal
      ;; lambda pushes entry/result checks into the lambda (an arrow
      ;; over anything else is uncheckable first-order: no cast)
      [`(define ,(? symbol? x) ,e)
       #:when (hash-has-key? decl-types x)
       (define t (hash-ref decl-types x))
       (list
        (match* (t e)
          [(`(-> ,as ... ,r) `(,(or 'lambda 'λ) (,(? symbol? xs) ...) ,body ...))
           #:when (= (length as) (length xs))
           `(define ,x (lambda ,xs
                         ,@(body-with-casts (nm-str x) xs as r body)))]
          [(`(-> ,_ ...) _) form]
          [(`(->* ,_ ...) _) form]
          [(_ _) `(define ,x ,(cast-expr e t (string-append "define " (nm-str x))))]))]
      [form (list form)]))

  ;; Top-level definitions shadow stdlib primitives; colliding names
  ;; are renamed here, once, for the whole program.
  ;;
  ;; Source origins ride along: each surface form's origin (see
  ;; system.rkt) is set while it lowers (formal/result blame labels
  ;; are built there) and replicated onto every form the lowering
  ;; yields, so the per-form walk below (ann/let/define blame labels)
  ;; sees the right position too.
  (define-values (top-bound top-forms top-origins)
    (match p
      [`(program ,forms ...)
       (define os (surface-origins))
       (define aligned?
         (and (list? os) (= (length os) (length forms))))
       ;; multi-list map, not a parallel-clause for/list (module-load
       ;; gensym budget; see system.rkt)
       (define pieces
         (map (λ (form o)
                (current-form-origin-set! o)
                (define ls (lower-type-form form))
                (cons ls (map (λ (_) o) ls)))
              forms
              (if aligned? os (map (λ (_) #f) forms))))
       (current-form-origin-set! #f)
       (define lowered (append-map car pieces))
       (define lorigins (append-map cdr pieces))
       (define-values (b _)
         (bind* (hash)
                (filter-map (λ (form)
                              (match form
                                [`(define (,f ,_ ...) ,_ ...) f]
                                [`(define (,f . ,_) ,_ ...) f]
                                [`(define ,(? symbol? x) ,_) x]
                                [_ #f]))
                            lowered)))
       (values b lowered lorigins)]))
  (define (per-form form)
    (match form
      [`(define (,f ,xs ...) ,body ...)
       (define-values (bound+ xs+) (bind* top-bound xs))
       `(define (,(hash-ref top-bound f f) ,@xs+) ,(body->expr body bound+))]
      ;; variadic defines: (define (f a . r) body)
      [`(define (,f . ,formals) ,body ...)
       (define-values (fixed rest-name)
         (let split ([fo formals] [acc '()])
           (cond [(symbol? fo) (values (reverse acc) fo)]
                 [(pair? fo) (split (cdr fo) (cons (car fo) acc))]
                 [else (error 'desugar "bad define formals: ~a" formals)])))
       (define-values (bound+ names+) (bind* top-bound (append fixed (list rest-name))))
       `(define (,(hash-ref top-bound f f) ,@(take names+ (length fixed)) #%rest ,(last names+))
          ,(body->expr body bound+))]
      [`(define ,(? symbol? x) ,e)
       `(define ,(hash-ref top-bound x x) ,(h e top-bound))]
      [e (h e top-bound)]))
  (define out-forms
    (map (λ (form o)
           (current-form-origin-set! o)
           (per-form form))
         top-forms top-origins))
  (current-form-origin-set! #f)
  `(program ,@out-forms))

;; ---------------------------------------------------------------------
;; Pass: shrink
;;
;; Takes core Puffin and...
;; - Removes binary minus (via unary minus)
;; - Removes and/or (using if) and not (via Racket-style truthiness:
;;   (not e) == (eq? e #f))
;; - Removes all binary comparators except < and eq?
;; - Turns begin into let chains, wraps while for the ANF passes
;; ---------------------------------------------------------------------

(define (shrink p)
  (define (h e) (prov (h-core e) e))
  (define (h-core e)
    (match e
      ;; base cases
      [`(void) e]
      [`(nil) e]
      [`(quote ,_) e]
      [`(string-lit ,_) e]
      [(? symbol?) e]
      [(? fixnum?) e]
      [#t #t]
      [#f #f]
      [`(read) '(read)]
      [`(- ,e0 ,e1) `(+ ,(h e0) (- ,(h e1)))]
      [`(- ,e) `(- ,(h e))]
      [`(and ,e0 ,e1) `(if ,(h e0) ,(h e1) #f)]
      [`(or ,e0 ,e1)
       ;; keep the first value when it is truthy (Racket semantics)
       (define t (gensym 'or))
       `(let ([,t ,(h e0)]) (if ,t ,t ,(h e1)))]
      [`(not ,e) `(eq? ,(h e) #f)]
      [`(<= ,e0 ,e1) (h `(not (< ,e1 ,e0)))]
      [`(> ,e0 ,e1) (h `(< ,e1 ,e0))]
      [`(>= ,e0 ,e1) (h `(not (< ,e0 ,e1)))]
      [`(< ,e0 ,e1) `(< ,(h e0) ,(h e1))]
      [`(eq? ,e0 ,e1) `(eq? ,(h e0) ,(h e1))]
      [`(if ,e0 ,e1 ,e2) `(if ,(h e0) ,(h e1) ,(h e2))]
      [`(begin ,e0) (h e0)]
      [`(begin ,e0 ,e-rest ...) (h `(let ([_ ,e0]) (begin ,@e-rest)))]
      [`(set! ,x ,e) `(set! ,x ,(h e))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       `(let ([_ (while ,(h e-g) ,(h e-b))]) ,(h e-r))]
      [`(while ,e-g ,e-b) `(let ([_ (while ,(h e-g) ,(h e-b))]) (void))]
      [`(let ([,x ,e0]) ,e-b)
       `(let ([,x ,(h e0)]) ,(h e-b))]
      [`(lambda (,xs ...) ,e-b)
       `(lambda ,xs ,(h e-b))]
      [`(,(? prim? op) ,es ...)
       `(,op ,@(map h es))]
      [`(,e-f ,e-args ...)
       `(,(h e-f) ,@(map h e-args))]))
  (define (per-form form)
    (match form
      [`(define (,f ,xs ...) ,e-b)
       `(define (,f ,@xs) ,(h e-b))]
      [`(define ,(? symbol? x) ,e)
       `(define ,x ,(h e))]
      [e (h e)]))
  (match p
    [`(program ,forms ...)
     `(program ,@(map per-form forms))]))

;; ---------------------------------------------------------------------
;; Pass: uniqueify -- every bound identifier written exactly once
;; ---------------------------------------------------------------------

(define (uniqueify p)
  ;; Names used so far *in the current definition*: a binder is
  ;; renamed if its name was ever used before, even in a sibling
  ;; scope (two match clauses binding `a`, say) -- the class version
  ;; only consulted the enclosing scope's map, which let sibling
  ;; branches produce duplicate writes.
  (define used (mutable-set))
  (define (fresh! x)
    (cond [(equal? x '#%rest) x]   ;; the variadic marker is not a binder
          [(set-member? used x) (gensym x)]
          [else (set-add! used x) x]))
  (define (rename e assignment) (prov (rename-core e assignment) e))
  (define (rename-core e assignment)
    (match e
      [(? fixnum? n) n]
      [(? boolean? b) b]
      [`(void) e]
      [`(nil) e]
      [`(read) e]
      [`(quote ,_) e]
      [`(string-lit ,_) e]
      [(? symbol? x) (hash-ref assignment x x)]
      [`(if ,e0 ,e1 ,e2) `(if ,(rename e0 assignment)
                              ,(rename e1 assignment)
                              ,(rename e2 assignment))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       `(let ([_ (while ,(rename e-g assignment) ,(rename e-b assignment))]) ,(rename e-r assignment))]
      [`(let ([_ ,e]) ,e-b)
       `(let ([_ ,(rename e assignment)]) ,(rename e-b assignment))]
      [`(let ([,x ,e]) ,e-b)
       (define x+ (fresh! x))
       `(let ([,x+ ,(rename e assignment)]) ,(rename e-b (hash-set assignment x x+)))]
      [`(set! ,x ,e) `(set! ,(hash-ref assignment x x) ,(rename e assignment))]
      ;; for any x ∈ xs, rename any one previously used...
      [`(lambda (,xs ...) ,e-b)
       (let* ([new-xs (map fresh! xs)]
              [assignment+ (foldl (λ (x x+ acc) (hash-set acc x x+)) assignment xs new-xs)])
         `(lambda ,new-xs ,(rename e-b assignment+)))]
      [`(,(? prim? op) ,es ...) `(,op ,@(map (λ (e) (rename e assignment)) es))]
      [`(,e-f ,e-args ...) `(,(rename e-f assignment) ,@(map (lambda (e-arg) (rename e-arg assignment)) e-args))]))
  ;; Top-level names count as used everywhere: a local that collides
  ;; with a function or global name gets renamed, so downstream
  ;; passes (and their predicates) never have to reason about locals
  ;; shadowing top-level definitions.
  (define top-names
    (match p
      [`(program ,forms ...)
       (filter-map (λ (form)
                     (match form
                       [`(define (,f ,_ ...) ,_) f]
                       [`(define ,(? symbol? x) ,_) x]
                       [_ #f]))
                   forms)]))
  (define (per-form form)
    ;; uniqueness is per definition (matching unique-source-tree?)
    (set-clear! used)
    (for ([n top-names]) (set-add! used n))
    ;; the entry symbol doesn't exist yet (collect-globals synthesizes
    ;; it next), but locals must not collide with it either
    (set-add! used (entry-symbol))
    (match form
      [`(define (,f ,xs ...) ,e-b)
       (define new-xs (map fresh! xs))
       (define assignment+ (foldl (λ (x x+ acc) (hash-set acc x x+)) (hash) xs new-xs))
       `(define (,f ,@new-xs) ,(rename e-b assignment+))]
      [`(define ,(? symbol? x) ,e)
       `(define ,x ,(rename e (hash)))]
      [e (rename e (hash))]))
  (match p
    [`(program ,forms ...)
     `(program ,@(map per-form forms))]))

;; ---------------------------------------------------------------------
;; Pass: collect-globals (NEW)
;;
;; Handles top-level value defines and top-level expressions
;; "thoughtfully":
;;
;;   - Each (define x e) claims a slot in the runtime's global
;;     array. All initializers and top-level expressions run *in
;;     source order* inside main, before the final expression's
;;     value is produced. Reads become (global-ref i); (set! x e)
;;     on a global becomes (global-set! i e).
;;
;;   - Functions may reference globals defined textually later
;;     (they are read at call time, matching Racket's module
;;     semantics for defines).
;;
;;   - If the last top-level form is an expression, its value is
;;     main's result (and gets printed unless void); otherwise main
;;     produces (void).
;;
;; Output programs carry their global count: (program ,n ,defns ...).
;; ---------------------------------------------------------------------

;; REPL mode (docs/WASM-VM.md §4, §5.2): compile one eval's forms as a
;; link-by-name unit. Differences from whole-program mode, exactly:
;;   - EVERY top-level define -- functions included -- claims a NAMED
;;     global cell; function defines become lambda initializers run in
;;     source order, so a redefinition replaces the cell's closure and
;;     every earlier unit's call (indirect by construction: reveal-
;;     functions sees no top-level functions) picks it up at call time;
;;   - free variables that are neither locals nor prims become
;;     late-bound cells resolved by NAME against the VM's session
;;     table (reading a still-unbound cell errors at run time with the
;;     variable's name) instead of compile-time errors;
;;   - each top-level expression is wrapped in (#%repl-result e): the
;;     RESULT opcode delivers non-void values to the host, one per
;;     form, and main's own result is (void).
;; The unit's info carries 'global-names (cell index -> source name,
;; in claim order: defines in source order, then free names in
;; first-use order) and 'repl #t; render-pbc emits them as the v2
;; globals section.
(define (collect-globals-repl p)
  (match-define `(program ,forms ...) p)
  ;; the entry symbol is synthesized here, same as whole-program mode
  (for ([form forms])
    (match form
      [`(define (,f ,_ ...) ,_)
       #:when (equal? f (entry-symbol))
       (error 'collect-globals "~a is reserved for the program entry point" f)]
      [`(define ,(? symbol? x) ,_)
       #:when (equal? x (entry-symbol))
       (error 'collect-globals "~a is reserved for the program entry point" x)]
      [_ (void)]))
  ;; the cell table, grown on demand (deterministically: defines are
  ;; claimed in source order first, then the walk below runs in source
  ;; order, so free names are claimed in first-use order)
  (define name->idx (make-hash))
  (define names-rev '())
  (define (slot! x)
    (cond [(hash-ref name->idx x #f) => values]
          [else
           (define i (hash-count name->idx))
           (hash-set! name->idx x i)
           (set! names-rev (cons x names-rev))
           i]))
  (for ([form forms])
    (match form
      [`(define (,f ,_ ...) ,_) (slot! f)]
      [`(define ,(? symbol? x) ,_) (slot! x)]
      [_ (void)]))
  ;; rewrite variable reads/writes; `shadowed` holds locally-bound
  ;; names -- everything else is a cell, by name
  (define (walk e shadowed) (prov (walk-core e shadowed) e))
  (define (walk-core e shadowed)
    (match e
      [(? fixnum?) e]
      [(? boolean?) e]
      [`(void) e]
      [`(nil) e]
      [`(read) e]
      [`(quote ,_) e]
      [`(string-lit ,_) e]
      [(? symbol? x)
       (if (set-member? shadowed x) x `(global-ref ,(slot! x)))]
      [`(if ,e0 ,e1 ,e2) `(if ,(walk e0 shadowed) ,(walk e1 shadowed) ,(walk e2 shadowed))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       `(let ([_ (while ,(walk e-g shadowed) ,(walk e-b shadowed))]) ,(walk e-r shadowed))]
      [`(let ([_ ,e]) ,e-b)
       `(let ([_ ,(walk e shadowed)]) ,(walk e-b shadowed))]
      [`(let ([,x ,e]) ,e-b)
       `(let ([,x ,(walk e shadowed)]) ,(walk e-b (set-add shadowed x)))]
      [`(set! ,x ,e)
       (if (set-member? shadowed x)
           `(set! ,x ,(walk e shadowed))
           `(global-set! ,(slot! x) ,(walk e shadowed)))]
      [`(lambda (,xs ...) ,e-b)
       `(lambda ,xs ,(walk e-b (set-union shadowed (list->set xs))))]
      [`(,(? prim? op) ,es ...) `(,op ,@(map (λ (e) (walk e shadowed)) es))]
      [`(,e-f ,e-args ...) `(,(walk e-f shadowed) ,@(map (λ (e) (walk e shadowed)) e-args))]))
  ;; main: every form is an effect step, in source order; the unit's
  ;; own result is void (results travel through #%repl-result)
  (define main-steps
    (for/list ([form forms])
      (match form
        [`(define (,f ,xs ...) ,e-b)
         `(global-set! ,(slot! f) (lambda ,xs ,(walk e-b (list->set xs))))]
        [`(define ,(? symbol? x) ,e)
         `(global-set! ,(slot! x) ,(walk e (set)))]
        [e `(#%repl-result ,(walk e (set)))])))
  (define main-body
    (foldr (λ (step acc) `(let ([_ ,step]) ,acc)) '(void) main-steps))
  `(program ,(hash 'globals (hash-count name->idx)
                   'global-names (reverse names-rev)
                   'repl #t)
            (define (,(entry-symbol)) ,main-body)))

(define (collect-globals p)
  (if (repl-mode?)
      (collect-globals-repl p)
      (collect-globals-whole p)))

(define (collect-globals-whole p)
  (match-define `(program ,forms ...) p)
  ;; the entry symbol is synthesized here; a user definition of it
  ;; would collide silently, so reject it loudly
  (for ([form forms])
    (match form
      [`(define (,f ,_ ...) ,_)
       #:when (equal? f (entry-symbol))
       (error 'collect-globals "~a is reserved for the program entry point" f)]
      [`(define ,(? symbol? x) ,_)
       #:when (equal? x (entry-symbol))
       (error 'collect-globals "~a is reserved for the program entry point" x)]
      [_ (void)]))
  (define global-names
    (foldl (λ (form acc)
             (match form
               [`(define (,f ,_ ...) ,_) acc]
               [`(define ,(? symbol? x) ,_) (append acc (list x))]
               [_ acc]))
           '()
           forms))
  (define name->idx
    (foldl (λ (x acc) (hash-set acc x (hash-count acc))) (hash) global-names))
  ;; separate compilation: imported value defines resolve to slots in
  ;; the exporting module's globals array -- the slot descriptor is
  ;; (ext <label> <k>) rather than a plain index, and flows opaquely
  ;; through every later pass until the renderer addresses the label.
  ;; Empty (the default) under whole-program compilation.
  (define ext-globals (module-ext-globals))
  (define (global-slot x shadowed)
    (cond [(set-member? shadowed x) #f]
          [(hash-ref name->idx x #f) => values]
          [(hash-ref ext-globals x #f) => values]
          [else #f]))
  ;; rewrite global reads/writes; `shadowed` holds locally-bound names
  (define (walk e shadowed) (prov (walk-core e shadowed) e))
  (define (walk-core e shadowed)
    (match e
      [(? fixnum?) e]
      [(? boolean?) e]
      [`(void) e]
      [`(nil) e]
      [`(read) e]
      [`(quote ,_) e]
      [`(string-lit ,_) e]
      [(? symbol? x)
       (cond [(global-slot x shadowed) => (λ (i) `(global-ref ,i))]
             [else x])]
      [`(if ,e0 ,e1 ,e2) `(if ,(walk e0 shadowed) ,(walk e1 shadowed) ,(walk e2 shadowed))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       `(let ([_ (while ,(walk e-g shadowed) ,(walk e-b shadowed))]) ,(walk e-r shadowed))]
      [`(let ([_ ,e]) ,e-b)
       `(let ([_ ,(walk e shadowed)]) ,(walk e-b shadowed))]
      [`(let ([,x ,e]) ,e-b)
       `(let ([,x ,(walk e shadowed)]) ,(walk e-b (set-add shadowed x)))]
      [`(set! ,x ,e)
       (cond [(global-slot x shadowed)
              => (λ (i) `(global-set! ,i ,(walk e shadowed)))]
             [else `(set! ,x ,(walk e shadowed))])]
      [`(lambda (,xs ...) ,e-b)
       `(lambda ,xs ,(walk e-b (set-union shadowed (list->set xs))))]
      [`(,(? prim? op) ,es ...) `(,op ,@(map (λ (e) (walk e shadowed)) es))]
      [`(,e-f ,e-args ...) `(,(walk e-f shadowed) ,@(map (λ (e) (walk e shadowed)) e-args))]))
  ;; build main: initializers and expressions in source order
  (define main-steps
    (foldr (λ (form acc)
             (match form
               [`(define (,_ ,_ ...) ,_) acc]
               [`(define ,(? symbol? x) ,e)
                (cons `(global-set! ,(hash-ref name->idx x) ,(walk e (set))) acc)]
               [e (cons (walk e (set)) acc)]))
           '()
           forms))
  (define main-body
    (match main-steps
      ['() '(void)]
      [_ (foldr (λ (step acc) (if acc `(let ([_ ,step]) ,acc) step)) #f main-steps)]))
  (define fun-defns
    (foldr (λ (form acc)
             (match form
               [`(define (,f ,xs ...) ,e-b)
                (cons `(define (,f ,@xs) ,(walk e-b (list->set xs))) acc)]
               [_ acc]))
           '()
           forms))
  ;; From here down the program carries an *info hash* in slot one.
  ;; collect-globals records the global count; select-instructions
  ;; later adds the symbol and string-literal tables it uncovered
  ;; (the renderer emits them as data).
  (when (globals-count-sink)   ;; separate.rkt's .pufi slot assertion
    (set-box! (globals-count-sink) (length global-names)))
  `(program ,(hash 'globals (length global-names))
            (define (,(entry-symbol)) ,main-body)
            ,@fun-defns))

;; ---------------------------------------------------------------------
;; Pass: reveal-functions
;;
;; Collect the set of top-level functions; mark references as
;; (fun-ref f) and make application explicit via `app`.
;; ---------------------------------------------------------------------

(define (reveal-functions p)
  (define (walk e assignment) (prov (walk-core e assignment) e))
  (define (walk-core e assignment)
    (match e
      [(? fixnum? n) n]
      [(? boolean? b) b]
      [`(void) e]
      [`(nil) e]
      [`(read) e]
      [`(quote ,_) e]
      [`(string-lit ,_) e]
      [`(global-ref ,_) e]
      [`(global-set! ,i ,e+) `(global-set! ,i ,(walk e+ assignment))]
      [(? symbol? x) (hash-ref assignment x x)]
      [`(if ,e0 ,e1 ,e2) `(if ,(walk e0 assignment)
                              ,(walk e1 assignment)
                              ,(walk e2 assignment))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       `(let ([_ (while ,(walk e-g assignment) ,(walk e-b assignment))]) ,(walk e-r assignment))]
      [`(let ([,x ,e]) ,e-b)
       (let ([assignment+ (if (equal? x '_) assignment (hash-set assignment x x))])
         `(let ([,x ,(walk e assignment+)]) ,(walk e-b assignment+)))]
      [`(set! ,x ,e) `(set! ,x ,(walk e assignment))]
      [`(lambda (,xs ...) ,e)
       (define assignment+ (foldl (λ (x acc) (hash-set acc x x)) assignment xs))
       `(lambda ,xs ,(walk e assignment+))]
      [`(,(? prim? op) ,es ...) `(,op ,@(map (λ (e) (walk e assignment)) es))]
      [`(,e-f ,e-args ...) `(app ,(walk e-f assignment) ,@(map (lambda (e) (walk e assignment)) e-args))]))
  (match p
    [`(program ,n-globals (define (,names ,params ...) ,bodies) ...)
     ;; separate compilation: imported functions (mangled labels the
     ;; linker resolves against other modules' .o's) are revealed
     ;; exactly like own top-level functions. Own definitions win on
     ;; a name collision (they are folded in second). Empty under
     ;; whole-program compilation.
     (define ext-set
       (for/fold ([acc (hash)]) ([(name label) (in-hash (module-ext-funs))])
         (hash-set acc name `(fun-ref ,label))))
     (define name-set
       (foldl (lambda (name acc) (hash-set acc name `(fun-ref ,name)))
              ext-set
              names))
     `(program
       ,n-globals
       ,@(map (lambda (name params body) `(define (,name ,@params) ,(walk body name-set)))
              names
              params
              bodies))]))

;; ---------------------------------------------------------------------
;; Pass: assignment-convert
;;
;; Optimized per function: compute which vars are ever mutated with
;; set!; only those are boxed (one-slot cells accessed with the
;; unsafe vector ops--the cell is compiler-controlled, so no checks).
;; ---------------------------------------------------------------------

(define (assignment-convert p)
  ;; the set of set!-ed variables in e
  (define (mutated-vars e)
    (match e
      [(? literal?) (set)]
      ['(read) (set)]
      [`(string-lit ,_) (set)]
      [(? symbol?) (set)]
      [`(fun-ref ,_) (set)]
      [`(global-ref ,_) (set)]
      [`(global-set! ,_ ,e+) (mutated-vars e+)]
      [`(set! ,x ,e+) (set-add (mutated-vars e+) x)]
      [`(lambda (,xs ...) ,e+) (mutated-vars e+)]
      [`(if ,e0 ,e1 ,e2) (set-union (mutated-vars e0) (mutated-vars e1) (mutated-vars e2))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       (set-union (mutated-vars e-g) (mutated-vars e-b) (mutated-vars e-r))]
      [`(let ([,_ ,e]) ,e-b) (set-union (mutated-vars e) (mutated-vars e-b))]
      [`(,(? prim?) ,es ...) (foldl (λ (e acc) (set-union acc (mutated-vars e))) (set) es)]
      [`(app ,es ...) (foldl (λ (e acc) (set-union acc (mutated-vars e))) (set) es)]))
  ;; box-formals: wrap the body to box each mutated formal
  (define (box-formals genformals realformals e-body)
    (match genformals
      ['() e-body]
      [`(,x . ,rst)
       `(let ([,(first realformals) (make-vector 1)])
          (let ([_ (unsafe-vector-set! ,(first realformals) 0 ,x)])
            ,(box-formals rst (rest realformals) e-body)))]))
  (define (a-c e boxed) (prov (a-c-core e boxed) e))
  (define (a-c-core e boxed)
    (match e
      [(? literal?) e]
      [`(read) e]
      [`(string-lit ,_) e]
      [`(fun-ref ,_) e]
      [`(global-ref ,_) e]
      [`(global-set! ,i ,e+) `(global-set! ,i ,(a-c e+ boxed))]
      [(? symbol? x)
       (if (set-member? boxed x) `(unsafe-vector-ref ,x 0) x)]
      [`(if ,e-g ,e-t ,e-f)
       `(if ,(a-c e-g boxed) ,(a-c e-t boxed) ,(a-c e-f boxed))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       `(let ([_ (while ,(a-c e-g boxed) ,(a-c e-b boxed))]) ,(a-c e-r boxed))]
      [`(let ([_ ,e]) ,e-b)
       `(let ([_ ,(a-c e boxed)]) ,(a-c e-b boxed))]
      [`(set! ,x ,e+)
       `(unsafe-vector-set! ,x 0 ,(a-c e+ boxed))]
      [`(lambda (,xs ...) ,e)
       ;; boxed formals of the lambda itself
       (define mut (set-intersect (mutated-vars e) (list->set xs)))
       (define new-xs (map (λ (x) (if (set-member? mut x) (gensym x) x)) xs))
       (define to-box (filter (λ (x) (set-member? mut x)) xs))
       (define gen-of (for/hash ([x xs] [nx new-xs] #:when (set-member? mut x)) (values x nx)))
       `(lambda ,new-xs
          ,(box-formals (map (λ (x) (hash-ref gen-of x)) to-box)
                        to-box
                        (a-c e (set-union boxed mut))))]
      [`(let ([,x ,e]) ,e-b)
       (if (set-member? boxed x)
           `(let ([,x (make-vector 1)])
              (let ([_ (unsafe-vector-set! ,x 0 ,(a-c e boxed))])
                ,(a-c e-b boxed)))
           `(let ([,x ,(a-c e boxed)]) ,(a-c e-b boxed)))]
      [`(,(? prim? op) ,es ...) `(,op ,@(map (λ (e) (a-c e boxed)) es))]
      [`(app ,es ...) `(app ,@(map (λ (e) (a-c e boxed)) es))]))
  (define (per-defn definition)
    (match definition
      [`(define (,fname ,formals ...) ,e-body)
       (define mut (mutated-vars e-body))
       ;; boxed set for the whole body: every set! target (the
       ;; variadic marker is never a variable)
       (define boxed-formals (filter (λ (x) (and (not (equal? x '#%rest)) (set-member? mut x))) formals))
       (define genformals (map (λ (x) (if (and (not (equal? x '#%rest)) (set-member? mut x)) (gensym x) x)) formals))
       (define gen-of (for/hash ([x formals] [gx genformals] #:when (set-member? mut x)) (values x gx)))
       `(define (,fname ,@genformals)
          ,(box-formals (map (λ (x) (hash-ref gen-of x)) boxed-formals)
                        boxed-formals
                        (a-c e-body mut)))]))
  (match p
    [`(program ,n-globals ,defns ...)
     `(program ,n-globals ,@(map per-defn defns))]))

;; ---------------------------------------------------------------------
;; Pass: lift-lambdas (closure conversion)
;;
;; Bottom-up: convert each lambda body, lift it to a top-level
;; define taking `env` first, and replace the lambda with a closure
;; record: (make-closure 1+|fvs|) whose slot 0 is the code pointer
;; and remaining slots the captured values. Applications fetch slot
;; 0 and pass the closure itself as env.
;; ---------------------------------------------------------------------

(define (lift-lambdas p)
  ;; emitted defines accumulate on a list in emission order (gensym'd
  ;; names keep entries distinct). A set would work too, but its
  ;; iteration order is unspecified -- puffincc's HAMT sets iterate
  ;; differently, and diff-ir compares definitions positionally.
  (define emitted-defines '())
  (define (emit-define! defn) (set! emitted-defines (cons defn emitted-defines)))
  ;; calculate the free variables of an expression e...
  (define (free-vars e)
    (match e
      [(? literal?) (set)]
      [`(read) (set)]
      [`(string-lit ,_) (set)]
      [`(fun-ref ,_) (set)]
      [`(global-ref ,_) (set)]
      [`(global-set! ,_ ,e+) (free-vars e+)]
      [(? symbol? x) (set x)]
      [`(if ,e0 ,e1 ,e2) (set-union (free-vars e0) (free-vars e1) (free-vars e2))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       (set-union (free-vars e-g) (free-vars e-b) (free-vars e-r))]
      [`(let ([_ ,e]) ,e-b)
       (set-union (free-vars e) (free-vars e-b))]
      [`(let ([,x ,e]) ,e-b)
       (set-union (free-vars e) (set-remove (free-vars e-b) x))]
      [`(unsafe-vector-ref ,e ,_) (free-vars e)]
      [`(unsafe-vector-set! ,e ,_ ,e-v) (set-union (free-vars e) (free-vars e-v))]
      [`(lambda (,xs ...) ,e) (foldl (lambda (x acc) (set-remove acc x)) (free-vars e) xs)]
      [`(,(? prim?) ,es ...) (foldl (λ (e acc) (set-union acc (free-vars e))) (set) es)]
      [`(app ,es ...) (foldl (λ (e acc) (set-union acc (free-vars e))) (set) es)]
      [`(papp ,n ,es ...) (foldl (λ (e acc) (set-union acc (free-vars e))) (set) es)]))
  (define (walk-expr e) (prov (walk-expr-core e) e))
  (define (walk-expr-core e)
    (match e
      [(? literal?) e]
      [`(read) e]
      [`(string-lit ,_) e]
      [`(global-ref ,_) e]
      [`(global-set! ,i ,e+) `(global-set! ,i ,(walk-expr e+))]
      ;; a bare fun-ref becomes a (one-slot) closure record
      [`(fun-ref ,f)
       (define v (gensym 'v))
       `(let ([,v (make-closure 1)])
          (let ([_ (unsafe-vector-set! ,v 0 (fun-ref ,f))])
            ,v))]
      [(? symbol? x) x] ;; variable reference
      [`(if ,e0 ,e1 ,e2) `(if ,(walk-expr e0)
                              ,(walk-expr e1)
                              ,(walk-expr e2))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       `(let ([_ (while ,(walk-expr e-g) ,(walk-expr e-b))]) ,(walk-expr e-r))]
      [`(let ([,x ,e]) ,e-b)
       `(let ([,x ,(walk-expr e)]) ,(walk-expr e-b))]
      [`(unsafe-vector-ref ,e ,i) `(unsafe-vector-ref ,(walk-expr e) ,i)]
      [`(unsafe-vector-set! ,e ,i ,e-v) `(unsafe-vector-set! ,(walk-expr e) ,i ,(walk-expr e-v))]
      [`(lambda (,xs ...) ,e)
       ;; first, convert the body
       (define fv (foldl (lambda (x acc) (set-remove acc x)) (free-vars e) xs))
       (define canonical-vars (sort (set->list fv) symbol<?))
       (define converted-expr (walk-expr e))
       (define f-name (gensym 'lam))
       ;; The closure parameter gets a FRESH name: a literal `env`
       ;; would capture (or duplicate) any user variable named env --
       ;; e.g. an interpreter whose evaluator takes an `env` argument.
       (define env-param (gensym 'env))
       ;; generate a stack in the body to unwrap free vars
       (define (letstack vars-in-order i)
         (match vars-in-order
           [`(,hd . ,tl)
            `(let ([,hd (unsafe-vector-ref ,env-param ,i)])
               ,(letstack tl (+ i 1)))]
           ['()
            converted-expr]))
       (define newly-created-define
         (prov `(define (,f-name ,env-param ,@xs)
                  ,(letstack canonical-vars 1))
               e))
       (emit-define! newly-created-define)
       ;; now, return an expression that creates the closure...
       (define v (gensym 'clo))
       (define (init-stack vars-in-order i)
         (match vars-in-order
           [`(,hd . ,tl)
            `(let ([_ (unsafe-vector-set! ,v ,i ,hd)])
               ,(init-stack tl (+ i 1)))]
           ['() ;; ultimate return point, return v
            v]))
       `(let ([,v (make-closure ,(+ (length canonical-vars) 1))])
          (let ([_ (unsafe-vector-set! ,v 0 (fun-ref ,f-name))]) ;; function name
            ,(init-stack canonical-vars 1)))]
      ;; direct call to a known top-level function (>= -O1): no
      ;; closure record, no indirect jump. Top-level defines capture
      ;; nothing, so the env argument is a dead 0.
      [`(app (fun-ref ,f) ,e-args ...)
       #:when (>= (optimize-level) 1)
       `(app (fun-ref ,f) 0 ,@(map (lambda (e) (walk-expr e)) e-args))]
      [`(app ,e-f ,e-args ...)
       (define clo (gensym 'clo))
       `(let ([,clo ,(walk-expr e-f)])
          (app (unsafe-vector-ref ,clo 0) ,clo ,@(map (lambda (e) (walk-expr e)) e-args)))]
      [`(papp ,n ,e-f ,e-args ...)
       (define clo (gensym 'clo))
       `(let ([,clo ,(walk-expr e-f)])
          (papp ,(add1 n) (unsafe-vector-ref ,clo 0) ,clo ,@(map (lambda (e) (walk-expr e)) e-args)))]
      [`(,(? prim? op) ,es ...) `(,op ,@(map walk-expr es))]))
  (define (per-defn definition)
    (match definition
      [`(define (,fname ,formals ...) ,e-body)
       ;; add an env parameter (fresh name; see the lambda case), but
       ;; only to non-main symbols
       (define maybe-env (if (equal? fname (entry-symbol)) '() (list (gensym 'env))))
       `(define (,fname ,@maybe-env ,@formals) ,(walk-expr e-body))]))
  (match p
    [`(program ,n-globals ,definitions ...)
     `(program ,n-globals ,@(map per-defn definitions) ,@(reverse emitted-defines))]))

;; ---------------------------------------------------------------------
;; Pass: limit-functions
;;
;; Rewrites functions of >6 arguments to pass the rest via a vector
;; (see the class p5 README for the ABI rationale). Internal, so
;; the vector is accessed unsafely.
;; ---------------------------------------------------------------------

(define (limit-functions p)
  (define max-args (length (argument-registers-list)))
  (define (walk-expr e) (prov (walk-expr-core e) e))
  (define (walk-expr-core e)
    (match e
      [(? literal?) e]
      [`(read) e]
      [`(string-lit ,_) e]
      [`(fun-ref ,_) e]
      [`(global-ref ,_) e]
      [`(global-set! ,i ,e+) `(global-set! ,i ,(walk-expr e+))]
      [(? symbol? x) x] ;; variable reference
      [`(if ,e0 ,e1 ,e2) `(if ,(walk-expr e0)
                              ,(walk-expr e1)
                              ,(walk-expr e2))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       `(let ([_ (while ,(walk-expr e-g) ,(walk-expr e-b))]) ,(walk-expr e-r))]
      [`(let ([,x ,e]) ,e-b)
       `(let ([,x ,(walk-expr e)]) ,(walk-expr e-b))]
      [`(unsafe-vector-ref ,e ,i) `(unsafe-vector-ref ,(walk-expr e) ,i)]
      [`(unsafe-vector-set! ,e ,i ,e-v) `(unsafe-vector-set! ,(walk-expr e) ,i ,(walk-expr e-v))]
      ;; > six arguments: build a vector for the rest, pass it as last
      ;; arg. papp records the ORIGINAL arity, which call sites hand
      ;; to the callee in the arity register: a variadic callee reads
      ;; it to rebuild its rest list; fixed callees unpack the vector.
      [`(app ,e-f ,e-args ...)
       #:when (> (length e-args) max-args)
       (define orig-n (length e-args))
       (define keep (take e-args (- max-args 1)))
       (define rest-es (drop e-args (- max-args 1)))
       (define v (gensym 'rest-args))
       (define k (length rest-es))
       ;; build nested lets that fill v[0..k-1], then call
       (define (fill-rest es i body)
         (match es
           ['() body]
           [`(,hd . ,tl)
            (fill-rest
             tl
             (add1 i)
             `(let ([_ (unsafe-vector-set! ,v ,i ,(walk-expr hd))])
                ,body))]))
       (define call-expr
         `(papp ,orig-n ,(walk-expr e-f) ,@(map walk-expr keep) ,v))
       `(let ([,v (make-vector ,k)])
          ,(fill-rest rest-es 0 call-expr))]
      ;; ≤ six arguments: just recurse on all subexpressions
      [`(app ,e-f ,e-args ...)
       `(app ,(walk-expr e-f) ,@(map walk-expr e-args))]
      [`(,(? prim? op) ,es ...) `(,op ,@(map walk-expr es))]))
  (define (per-defn definition)
    (match definition
      ;; variadic definitions keep their shape; the prologue builds
      ;; the rest list from the arity register. Their fixed part must
      ;; fit in the registers below the overflow slot.
      [`(define (,fname ,formals ...) ,e-body)
       #:when (member '#%rest formals)
       (define fixed (- (length formals) 2))
       (unless (<= fixed (- max-args 1))
         (error 'limit-functions
                "variadic ~a has ~a fixed parameters; at most ~a fit alongside the overflow slot"
                fname fixed (- max-args 1)))
       `(define (,fname ,@formals) ,(walk-expr e-body))]
      ;; > 6 formals: (f a0 ... a4 a-rest...) -> last arg becomes a vector
      [`(define (,fname ,formals ...) ,e-body)
       #:when (> (length formals) max-args)
       (define keep (take formals (- max-args 1)))
       (define overflow (drop formals (- max-args 1)))
       (define args-vec (gensym 'rest-args))
       (define (args-vec-stack formals i)
         (match formals
           ['() (walk-expr e-body)]
           [`(,hd . ,tl)
            `(let ([,hd (unsafe-vector-ref ,args-vec ,i)])
               ,(args-vec-stack tl (add1 i)))]))
       `(define (,fname ,@keep ,args-vec)
          ,(args-vec-stack overflow 0))]
      ;; ≤ 6 formals: unchanged except recursive walk
      [`(define (,fname ,formals ...) ,e-body)
       `(define (,fname ,@formals) ,(walk-expr e-body))]))
  (match p
    [`(program ,n-globals ,definitions ...)
     `(program ,n-globals ,@(map per-defn definitions))]))

;; ---------------------------------------------------------------------
;; Pass: anf-convert -- flatten nested expressions
;; ---------------------------------------------------------------------

(define (anf-convert p)
  ;; The tail (return) continuation is the sentinel `ret-k`: the value
  ;; IS the result. Every other continuation is a real function that
  ;; binds the value and continues. `apply-k` applies either.
  ;;
  ;; join points: naively an if's continuation is duplicated into BOTH
  ;; branches, which is exponential under nested ifs. The fix is to
  ;; duplicate ONLY the tail continuation (needed to keep tail calls in
  ;; branches in tail position) and to reify every other continuation
  ;; as a single join point: bind the if's value once, apply k once.
  ;; The tail test is `(eq? k ret-k)` -- deciding it by *probing* k
  ;; (running it on a fresh var to measure output size) re-ran the whole
  ;; downstream conversion at every nested if and was itself the source
  ;; of the exponential blowup, so k is never run to make this choice.
  (define ret-k (list 'ret))          ;; a unique sentinel, compared by eq?
  (define (apply-k k v) (if (eq? k ret-k) v (k v)))
  ;; convert a list of expressions left-to-right, collecting atoms
  ;; (the collector k here is always a real function, never ret-k)
  (define (convert-args es k)
    (match es
      ['() (k '())]
      [`(,hd . ,tl)
       (convert-expr hd (λ (a) (convert-args tl (λ (as) (k (cons a as))))))]))
  (define (convert-expr e k) (prov (convert-expr-core e k) e))
  (define (convert-expr-core e k)
    (match e
      [(? literal?) (apply-k k e)]
      [(? symbol? x) (apply-k k x)]
      ['(read)
       (let ([x (gensym 'read)])
         (prov `(let ([,x (read)]) ,(apply-k k x)) e))]
      [`(string-lit ,s)
       (let ([x (gensym 'str)])
         (prov `(let ([,x (string-lit ,s)]) ,(apply-k k x)) e))]
      [`(fun-ref ,f)
       (define x (gensym 'funref))
       (prov `(let ([,x (fun-ref ,f)]) ,(apply-k k x)) e)]
      [`(global-ref ,i)
       (define x (gensym 'glob))
       (prov `(let ([,x (global-ref ,i)]) ,(apply-k k x)) e)]
      [`(global-set! ,i ,e+)
       (convert-expr e+ (λ (a)
                          (prov `(let ([_ (global-set! ,i ,a)]) ,(apply-k k '(void))) e)))]
      ;; fused compare-and-branch (>= -O1): when the test is one
      ;; comparison, keep it in the if -- never materialize the
      ;; boolean (explicate-control turns it into a cmp+jcc tail)
      [`(if (,(? cmp? op) ,ea ,eb) ,e1 ,e2)
       #:when (>= (optimize-level) 1)
       (convert-args
        (list ea eb)
        (λ (as)
          (if (eq? k ret-k)
              `(if (,op ,@as) ,(convert-expr e1 ret-k) ,(convert-expr e2 ret-k))
              (let ([x (gensym 'join)])
                `(let ([,x (if (,op ,@as)
                               ,(convert-expr e1 ret-k)
                               ,(convert-expr e2 ret-k))])
                   ,(apply-k k x))))))]
      [`(if ,e0 ,e1 ,e2)
       (convert-expr
        e0
        (λ (a-g)
          (if (eq? k ret-k)
              `(if ,a-g ,(convert-expr e1 ret-k) ,(convert-expr e2 ret-k))
              (let ([x (gensym 'join)])
                `(let ([,x (if ,a-g
                               ,(convert-expr e1 ret-k)
                               ,(convert-expr e2 ret-k))])
                   ,(apply-k k x))))))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       `(let ([_ (while ,(convert-expr e-g ret-k) ,(convert-expr e-b ret-k))])
          ,(convert-expr e-r k))]
      [`(unsafe-vector-ref ,e0 ,i)
       (convert-expr e0 (λ (a0)
                          (define x (gensym 'uref))
                          (prov `(let ([,x (unsafe-vector-ref ,a0 ,i)]) ,(apply-k k x)) e)))]
      [`(unsafe-vector-set! ,e0 ,i ,e1)
       (convert-expr e0
                     (λ (a0)
                       (convert-expr e1 (λ (a1)
                                          (prov `(let ([_ (unsafe-vector-set! ,a0 ,i ,a1)]) ,(apply-k k '(void))) e)))))]
      ;; direct calls (>= -O1): a (fun-ref f) rator stays in place --
      ;; no materialization, the backends emit a direct call/jump
      [`(app (fun-ref ,f) ,es ...)
       #:when (>= (optimize-level) 1)
       (convert-args es (λ (as)
                          (define x (gensym 'app))
                          (prov `(let ([,x (app (fun-ref ,f) ,@as)]) ,(apply-k k x)) e)))]
      [`(papp ,n (fun-ref ,f) ,es ...)
       #:when (>= (optimize-level) 1)
       (convert-args es (λ (as)
                          (define x (gensym 'app))
                          (prov `(let ([,x (papp ,n (fun-ref ,f) ,@as)]) ,(apply-k k x)) e)))]
      [`(app ,es ...)
       (convert-args es (λ (as)
                          (define x (gensym 'app))
                          (prov `(let ([,x (app ,@as)]) ,(apply-k k x)) e)))]
      [`(papp ,n ,es ...)
       (convert-args es (λ (as)
                          (define x (gensym 'app))
                          (prov `(let ([,x (papp ,n ,@as)]) ,(apply-k k x)) e)))]
      [`(,(? prim? op) ,es ...)
       (convert-args es (λ (as)
                          (define x (gensym op))
                          (prov `(let ([,x (,op ,@as)]) ,(apply-k k x)) e)))]
      ;; let (place after the special _ forms)
      [`(let ([,x ,e0]) ,e-b)
       (convert-expr e0 (lambda (atom)
                          (prov `(let ([,x ,atom]) ,(convert-expr e-b k)) e)))]))
  (define (per-defn definition)
    (match definition
      [`(define (,fname ,formals ...) ,e-body)
       `(define (,fname ,@formals) ,(convert-expr e-body ret-k))]))
  (match p
    [`(program ,n-globals ,defns ...)
     `(program ,n-globals ,@(map per-defn defns))]))

;; ---------------------------------------------------------------------
;; Pass: explicate-control -- ANF to labeled blocks
;; ---------------------------------------------------------------------

(define (explicate-control p)
  ;; merge two hashes, assume no common keys
  (define (merge h0 h1)
    (foldl (λ (k0 h1) (hash-set h1 k0 (hash-ref h0 k0))) h1 (hash-keys h0)))
  (define (extend h label instruction)
    (hash-set h label `(seq ,instruction ,(hash-ref h label))))
  ;; basic idea: return a hash which maps blocks to a label name
  ;;
  ;; k is a continuation which gets called on the ultimate return value
  (define (expr->blocks e current-block k)
    ;; tag the tail this expression contributes to its block
    (define r (expr->blocks-core e current-block k))
    (when (hash? r) (prov (hash-ref r current-block #f) e))
    r)
  (define (expr->blocks-core e current-block k)
    (match e
      ;; effect-position statements
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
      [`(let ([_ (unsafe-vector-set! ,a0 ,i ,a1)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(unsafe-vector-set! ,a0 ,i ,a1))]
      [`(let ([_ (global-set! ,i ,a)]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(global-set! ,i ,a))]
      [`(let ([_ ,(? atom?)]) ,e+)
       ;; pure and unused: drop it
       (expr->blocks e+ current-block k)]
      [`(let ([_ ,rhs]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(effect ,rhs))]
      ;; join points ((let ([x (if g e-t e-f)]) e+), from anf-convert
      ;; when the if's continuation was non-trivial): both branches
      ;; assign x and meet at a fresh label holding the (single)
      ;; continuation of the if
      [`(let ([,x (if ,g ,e-t ,e-f)]) ,e+)
       (define l-join (gensym 'join))
       (define rest-blocks (expr->blocks e+ l-join k))
       (define if-blocks
         (expr->blocks `(if ,g ,e-t ,e-f)
                       current-block
                       (λ (a) `(seq (assign ,x ,a) (goto ,l-join)))))
       (merge rest-blocks if-blocks)]
      ;; proper tail calls: an app whose value is immediately
      ;; returned becomes a tail-app (the backends turn it into an
      ;; epilogue + indirect jump, so loops run in constant stack)
      [`(let ([,x (app ,a-f ,a-args ...)]) ,body)
       #:when (and (equal? body x) (equal? (k x) `(return ,x)))
       (hash current-block `(tail-app ,(length a-args) ,a-f ,@a-args))]
      [`(let ([,x (papp ,n ,a-f ,a-args ...)]) ,body)
       #:when (and (equal? body x) (equal? (k x) `(return ,x)))
       (hash current-block `(tail-app ,n ,a-f ,@a-args))]
      [`(let ([,x ,rhs]) ,e+)
       (extend (expr->blocks e+ current-block k) current-block `(assign ,x ,rhs))]
      ;; fused compare-and-branch (>= -O1 anf output): the test is a
      ;; comparison over atoms; emit it directly as the block tail
      ;; with the TRUE branch first (the opposite order of the
      ;; (eq? a #f) form below, which tests for falseness)
      [`(if (,(? cmp? op) ,aa ,ab) ,e-t ,e-f)
       (define l-t (gensym 'lab))
       (define l-f (gensym 'lab))
       (define true-blocks (expr->blocks e-t l-t k))
       (define false-blocks (expr->blocks e-f l-f k))
       (define all-blocks (merge true-blocks false-blocks))
       (hash-set all-blocks
                 current-block
                 `(if (,op ,aa ,ab) (goto ,l-t) (goto ,l-f)))]
      [`(if ,a ,e-t ,e-f)
       (define l-t (gensym 'lab))
       (define l-f (gensym 'lab))
       (define true-blocks (expr->blocks e-t l-t k))
       (define false-blocks (expr->blocks e-f l-f k))
       (define all-blocks (merge true-blocks false-blocks))
       (hash-set all-blocks
                 current-block ;; the current block's label
                 `(if (eq? ,a #f)
                      ;; take the false branch
                      (goto ,l-f)
                      ;; take the true branch...
                      (goto ,l-t)))]
      [(? atom? a)
       (hash current-block (k a))]))
  ;; main must run its conclusion (print the result, return 0 to the
  ;; OS), so tail calls in the entry function become ordinary calls
  (define (untail blocks)
    (foldl (λ (l acc)
             (hash-set acc l
                       (let untail-tail ([t (hash-ref blocks l)])
                         (match t
                           [`(tail-app ,n ,f ,args ...)
                            (define tmp (gensym 'ret))
                            `(seq (assign ,tmp ,(if (= n (length args))
                                                    `(app ,f ,@args)
                                                    `(papp ,n ,f ,@args)))
                                  (return ,tmp))]
                           [`(seq ,s ,rest) `(seq ,s ,(untail-tail rest))]
                           [_ t]))))
           (hash)
           ;; sorted: this loop MINTS gensyms (ret temps), so the
           ;; visit order must not depend on hash iteration (mirrors
           ;; middle.puf: byte-reproducible output)
           (sort (hash-keys blocks) symbol<?)))
  ;; -------------------------------------------------------------------
  ;; Loop recovery (>= -O1; docs/OPTIMIZER.md §6.5 item 3): a self
  ;; tail call runs the full call/return protocol every iteration.
  ;; Instead, move the function's entry tail to a fresh loophead
  ;; label and rewrite every plain self tail call into parallel
  ;; parameter reassignment + (goto loophead). The reassignment is
  ;; two-phase (args into fresh temps first, then temps into the
  ;; formals) because the args may reference the formals being
  ;; reassigned.
  ;; -------------------------------------------------------------------
  (define (recover-loops fname formals blocks)
    (define (self-call? t)
      (match t
        [`(tail-app ,n (fun-ref ,g) ,args ...)
         (and (equal? g fname) (= n (length args)))]
        [`(seq ,_ ,rest) (self-call? rest)]
        [_ #f]))
    (cond
      [(not (ormap (λ (l) (self-call? (hash-ref blocks l))) (hash-keys blocks)))
       blocks]
      [else
       (define loophead (gensym 'loophead))
       (define (rewrite t)
         (match t
           [`(tail-app ,n (fun-ref ,g) ,args ...)
            #:when (and (equal? g fname) (= n (length args)))
            (define temps (map (λ (_) (gensym 'looptmp)) args))
            (foldr (λ (ti ai acc) `(seq (assign ,ti ,ai) ,acc))
                   (foldr (λ (fi ti acc) `(seq (assign ,fi ,ti) ,acc))
                          `(goto ,loophead)
                          formals temps)
                   temps args)]
           [`(seq ,s ,rest) `(seq ,s ,(rewrite rest))]
           [_ t]))
       (define moved
         (hash-set (hash-set blocks loophead (hash-ref blocks fname))
                   fname `(goto ,loophead)))
       ;; sorted for the same reason as untail: rewrite mints
       ;; looptmp gensyms per self tail call
       (for/fold ([acc (hash)]) ([l (sort (hash-keys moved) symbol<?)])
         (hash-set acc l (rewrite (hash-ref moved l))))]))
  ;; -------------------------------------------------------------------
  ;; Blocks cleanup (>= -O1): (a) jump threading -- a block that is
  ;; exactly (goto M) is bypassed by retargeting its predecessors;
  ;; (b) single-predecessor merging -- a terminal (goto M) where M
  ;; has exactly one predecessor splices M's tail in place; (c) drop
  ;; blocks unreachable from the entry.
  ;; -------------------------------------------------------------------
  (define (cleanup-blocks entry blocks)
    ;; (a) jump threading (the entry keeps its name: chains stop
    ;; there, and it is never removed)
    (define (thread blocks)
      (define (final-target l)
        (let loop ([l l] [seen (set)])
          (cond
            [(set-member? seen l) l]
            [(equal? l entry) l]
            [else
             (match (hash-ref blocks l #f)
               [`(goto ,m) #:when (not (equal? m l)) (loop m (set-add seen l))]
               [_ l])])))
      (define (retarget t)
        (match t
          [`(goto ,l) `(goto ,(final-target l))]
          [`(if ,c (goto ,l0) (goto ,l1))
           `(if ,c (goto ,(final-target l0)) (goto ,(final-target l1)))]
          [`(seq ,s ,rest) `(seq ,s ,(retarget rest))]
          [_ t]))
      (for/fold ([acc (hash)]) ([(l t) (in-hash blocks)])
        (hash-set acc l (retarget t))))
    ;; (b) single-predecessor merging, iterated to fixpoint (each
    ;; splice deletes one block, so it is bounded by the block count)
    (define (pred-counts blocks)
      (define counts (make-hash))
      (define (bump l) (hash-update! counts l add1 0))
      (for ([(l t) (in-hash blocks)])
        (let walk ([t t])
          (match t
            [`(goto ,m) (bump m)]
            [`(if ,_ (goto ,m0) (goto ,m1)) (bump m0) (bump m1)]
            [`(seq ,_ ,rest) (walk rest)]
            [_ (void)])))
      counts)
    (define (terminal-goto t)
      (match t
        [`(goto ,m) m]
        [`(seq ,_ ,rest) (terminal-goto rest)]
        [_ #f]))
    (define (merge-single-preds blocks)
      (define counts (pred-counts blocks))
      (define candidate
        (for/or ([l (sort (hash-keys blocks) symbol<?)])
          (define m (terminal-goto (hash-ref blocks l)))
          (and m
               (not (equal? m entry))
               (not (equal? m l))
               (= (hash-ref counts m 0) 1)
               (hash-has-key? blocks m)
               (cons l m))))
      (cond
        [candidate
         (match-define (cons l m) candidate)
         (define (splice t)
           (match t
             [`(goto ,g) #:when (equal? g m) (hash-ref blocks m)]
             [`(seq ,s ,rest) `(seq ,s ,(splice rest))]
             [_ t]))
         (merge-single-preds
          (hash-remove (hash-set blocks l (splice (hash-ref blocks l))) m))]
        [else blocks]))
    ;; (c) drop unreachable blocks
    (define (drop-unreachable blocks)
      (define seen (mutable-set))
      (define (targets t)
        (match t
          [`(goto ,m) (list m)]
          [`(if ,_ (goto ,m0) (goto ,m1)) (list m0 m1)]
          [`(seq ,_ ,rest) (targets rest)]
          [_ '()]))
      (let dfs ([l entry])
        (when (and (hash-has-key? blocks l) (not (set-member? seen l)))
          (set-add! seen l)
          (for-each dfs (targets (hash-ref blocks l)))))
      (for/fold ([acc (hash)]) ([(l t) (in-hash blocks)]
                                #:when (set-member? seen l))
        (hash-set acc l t)))
    (drop-unreachable (merge-single-preds (thread blocks))))
  (define (per-defn definition)
    (match definition
      [`(define (,fname ,formals ...) ,e-body)
       (define blocks (expr->blocks e-body fname (lambda (a) `(return ,a))))
       (define blocks-looped
         (if (and (>= (optimize-level) 1)
                  (not (equal? fname (entry-symbol)))
                  (not (member '#%rest formals)))
             (recover-loops fname formals blocks)
             blocks))
       (define blocks-untailed
         (if (equal? fname (entry-symbol)) (untail blocks-looped) blocks-looped))
       (define blocks-clean
         (if (>= (optimize-level) 1)
             (cleanup-blocks fname blocks-untailed)
             blocks-untailed))
       `(define (,fname ,@formals) ,blocks-clean)]))
  (match p
    [`(program ,n-globals ,defns ...)
     `(program ,n-globals ,@(map per-defn defns))]))

;; ---------------------------------------------------------------------
;; Pass: uncover-locals -- per-function local variable sets
;; ---------------------------------------------------------------------

(define (uncover-locals p)
  (define (h seq)
    (match seq
      [`(return ,_) (set)]
      [`(tail-app ,_ ...) (set)]
      [`(goto ,l) (set)]
      [`(if ,_ ,_ ,_) (set)]
      [`(seq (assign ,x0 ,_) ,rest)
       (set-add (h rest) x0)]
      [`(seq ,_ ,rest)
       (h rest)]))
  (define (per-defn definition)
    (match definition
      [`(define (,fname ,formals ...) ,blocks)
       (define locals (set-union (list->set formals)
                                 (foldl (λ (block acc) (set-union acc (h (hash-ref blocks block))))
                                        (set)
                                        (hash-keys blocks))))
       `(define ,locals (,fname ,@formals) ,blocks)]))
  (match p
    [`(program ,n-globals ,definitions ...)
     `(program ,n-globals ,@(map per-defn definitions))]))
