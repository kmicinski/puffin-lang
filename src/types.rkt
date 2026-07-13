#lang racket

;; Puffin -- types.rkt: the gradual typechecker (docs/TYPES.md).
;;
;; Runs on the module-resolved SURFACE program, invoked at the top of
;; desugar (so every route checks: interp, chain, both backends, the
;; web trace server). Bidirectional with the Siek-Taha consistency
;; relation: `_` (Any) is consistent with everything, consistency is
;; congruent and NOT transitive. Unannotated code is `_`-typed by
;; construction and never errors. v1 is check-then-erase (desugar
;; drops annotations); cast insertion with blame is phase 3.
;;
;; Types (internal form = surface form):
;;   _  Int Bool Sym Str Void
;;   (Pairof t t) (List t) (Vec t) (Hash t t) (Set t)
;;   (Mut t)               mutable-container wrapper (t: Hash/Vec/Set)
;;   (-> t ... t)
;;   (->* (t ...) t t)     variadic: fixed args, rest-elem, result
;;   (Name t ...)          ADT instances
;;   a b c ...             type variables (lowercase first char)
;;
;; Prim types come from the manifest (stdlib.rkt prim-spec `type`
;; field, asserted against the arity there); the tiny table kept here
;; covers only the desugar-level forms the manifest doesn't know
;; (the open-coded intrinsics + - * eq? <, the comparators <= > >=
;; that shrink to <, and `not`).
;;
;; (Mut ...) discipline: allocators (make-hash, make-set, make-vector,
;; the (vector ...) literal) synthesize (Mut ...); mutating prims
;; (hash-set!, vector-set!, set-add!, ...) REQUIRE it. Consistency is
;; DIRECTIONAL: a (Mut t) value is consistent where plain t' is
;; expected (read-only accessors are typed over the plain container
;; and accept both flavors), but a plain container is NOT consistent
;; where (Mut t) is demanded -- mutating a persistent hash/set is a
;; type error when the types are concrete. `_` papers over the
;; difference as usual (the gradual guarantee).

;; consistent? is exported for the typed-signature checks in
;; separate.rkt/modules.rkt (docs/MODULES.md §2): a .pufs entry's type
;; is verified consistent with the module's recorded/declared type.
(provide typecheck-program type-error? consistent?)

(require "stdlib.rkt" "irs.rkt" "system.rkt")

(struct exn:type-error exn:fail ())
(define (type-error? e) (exn:type-error? e))
(define (type-error fmt . args)
  ;; every type error carries the nearest enclosing top-level form's
  ;; source position when known (system.rkt origin-suffix)
  (raise (exn:type-error (string-append "typecheck: " (apply format fmt args)
                                        (origin-suffix))
                         (current-continuation-marks))))

;; ---------------------------------------------------------------------
;; type syntax helpers
;; ---------------------------------------------------------------------

(define (tyvar? t)
  (and (symbol? t)
       (let ([s (symbol->string t)])
         (and (> (string-length s) 0)
              (char-lower-case? (string-ref s 0))))))

(define base-types (seteq 'Int 'Bool 'Sym 'Str 'Void '_))

;; structural type formers: never user-definable (define-type of one
;; is rejected in collect-adts), never renamed by the module system
(define type-former-names (seteq '-> '->* 'List 'Vec 'Hash 'Set 'Pairof 'Mut))

;; ---------------------------------------------------------------------
;; diagnostic rendering: names and types in error/warning messages go
;; through the module demangling table (system.rkt), so a message
;; shows the SOURCE spelling (Shape), never the module-mangled one
;; (Shape_shapes_826109a6). Rendering only -- every comparison in this
;; file uses the mangled spellings, which ARE the type identities.
;; ---------------------------------------------------------------------

(define (nm x) (if (symbol? x) (module-demangle x) x))
(define (ty t)
  (cond [(symbol? t) (module-demangle t)]
        [(pair? t) (cons (ty (car t)) (ty (cdr t)))]
        [else t]))

;; ---------------------------------------------------------------------
;; the ADT registry: collected from define-type forms (pass 1 heads,
;; pass 2 bodies -- all of a module's types are mutually recursive).
;;
;; (#%extern-type head (ctor ft ...) ...) registers EXACTLY like
;; define-type but defines nothing: separate compilation splices one
;; per imported ADT (spellings already mangled, straight from the
;; dependency's .pufi), so annotations resolve, constructor
;; applications/patterns type, and exhaustiveness sees the closed
;; constructor set without the exporting module's source. Desugar
;; drops the form (the constructors' defines live in the exporting
;; unit's .o). Never produced by whole-program resolution.
;; ---------------------------------------------------------------------

(struct adt (name params ctors) #:transparent)         ;; ctors: name -> field types
(struct ctor-info (owner params fields) #:transparent) ;; result: (owner params...)

(define (collect-adts forms)
  (define adts (make-hasheq))   ;; type name -> adt
  (define ctors (make-hasheq))  ;; ctor name -> ctor-info
  (define ctor-orders (make-hasheq))  ;; type name -> (ctor ...) in declaration order
  ;; pass 1: heads
  (for-each-form forms
   (λ (f)
    (match f
      [`(,(or 'define-type '#%extern-type) ,head ,_ ...)
       (define-values (n ps)
         (match head
           [`(,n ,ps ...) (values n ps)]
           [n (values n '())]))
       (when (or (set-member? base-types n) (set-member? type-former-names n))
         (type-error "define-type cannot redefine built-in type ~a" n))
       (when (hash-has-key? adts n)
         (type-error "type ~a defined twice" (nm n)))
       (hash-set! adts n (adt n ps (make-hasheq)))]
      [_ (void)])))
  ;; pass 2: constructor signatures (any type in the program may be
  ;; referenced -- the implicit recursive loop)
  (for-each-form forms
   (λ (f)
    (match f
      [`(,(or 'define-type '#%extern-type) ,head ,cs ...)
       (define n (match head [`(,n ,_ ...) n] [n n]))
       (define a (hash-ref adts n))
       (hash-set! ctor-orders n (map car cs))
       (for ([c cs])
         (match c
           [`(,cn ,fts ...)
            (when (hash-has-key? ctors cn)
              (type-error "constructor ~a defined twice" (nm cn)))
            (for ([ft fts]) (check-type-wf ft (adt-params a) adts))
            (hash-set! (adt-ctors a) cn fts)
            (hash-set! ctors cn (ctor-info n (adt-params a) fts))]))]
      [_ (void)])))
  (values adts ctors ctor-orders))

;; well-formedness: names resolve, arities match
(define (check-type-wf t params adts)
  (match t
    [(? symbol? s)
     (cond
       [(or (set-member? base-types s) (memq s params) (tyvar? s)) (void)]
       [(hash-has-key? adts s)
        (unless (null? (adt-params (hash-ref adts s)))
          (type-error "type ~a expects ~a parameters"
                      (nm s) (length (adt-params (hash-ref adts s)))))]
       ;; an unresolved type name is an error: it would otherwise
       ;; check as an opaque type and fail every consistency test
       ;; downstream with a baffling message (the cross-module case:
       ;; annotating with a type the exporting module never provided)
       [else (type-error "unknown type ~a" (nm s))])]
    [`(,(or 'Pairof 'Hash) ,a ,b)
     (check-type-wf a params adts) (check-type-wf b params adts)]
    [`(,(or 'List 'Vec 'Set) ,a) (check-type-wf a params adts)]
    [`(Mut ,t0)
     (match t0
       [`(,(or 'Hash 'Vec 'Set) ,_ ...) (check-type-wf t0 params adts)]
       [_ (type-error "(Mut ...) wraps a Hash, Vec, or Set type, got ~a" (ty t0))])]
    [`(->* (,ts ...) ,tr ,tres)
     (for ([s ts]) (check-type-wf s params adts))
     (check-type-wf tr params adts)
     (check-type-wf tres params adts)]
    [`(,(or 'Mut '->*) ,_ ...) (type-error "malformed type: ~a" (ty t))]
    [`(-> ,ts ...) (for ([s ts]) (check-type-wf s params adts))]
    [`(,(? symbol? n) ,args ...)
     (cond [(hash-has-key? adts n)
            (unless (= (length args) (length (adt-params (hash-ref adts n))))
              (type-error "type ~a expects ~a parameters, got ~a"
                          (nm n) (length (adt-params (hash-ref adts n))) (length args)))
            (for ([s args]) (check-type-wf s params adts))]
           [else (type-error "unknown type constructor ~a in ~a" (nm n) (ty t))])]
    [_ (type-error "malformed type: ~a" (ty t))]))

;; ---------------------------------------------------------------------
;; substitution & consistency
;; ---------------------------------------------------------------------

(define (subst t env)   ;; env: hasheq tyvar -> type
  (match t
    [(? symbol? s) (hash-ref env s s)]
    [`(,h ,ts ...) `(,h ,@(map (λ (s) (subst s env)) ts))]
    [_ t]))

;; one-step unfold of (List a) as nil-or-pair for consistency against
;; Pairof (docs/TYPES.md §4: equi-recursive List).
;;
;; consistent? is called (synthesized, expected) at every site, so the
;; (Mut ...) rules below are DIRECTIONAL: a (Mut t) value fits a plain
;; expectation (unwrap on the left), a plain value never fits a (Mut t)
;; expectation.
(define (consistent? t1 t2)
  (match* (t1 t2)
    [('_ _) #t]
    [(_ '_) #t]
    [((? tyvar?) _) #t]      ;; an uninstantiated variable fits anything
    [(_ (? tyvar?)) #t]
    [((? symbol? a) (? symbol? b)) (eq? a b)]
    [(`(Mut ,a) `(Mut ,b)) (consistent? a b)]
    [(`(Mut ,a) _) (consistent? a t2)]     ;; elimination accepts both flavors
    [(`(List ,a) `(Pairof ,x ,y))
     (and (consistent? x a) (consistent? y `(List ,a)))]
    [(`(Pairof ,x ,y) `(List ,a))
     (and (consistent? x a) (consistent? y `(List ,a)))]
    ;; a variadic function fits a fixed arrow that supplies at least
    ;; the fixed arguments (the extras check against the rest type)
    [(`(->* (,fs ...) ,fr ,fres) `(-> ,as ... ,ares))
     (arrows-consistent? fs fr fres as ares)]
    [(`(-> ,as ... ,ares) `(->* (,fs ...) ,fr ,fres))
     (arrows-consistent? fs fr fres as ares)]
    [(`(,h1 ,as ...) `(,h2 ,bs ...))
     (and (eq? h1 h2) (= (length as) (length bs))
          (andmap consistent? as bs))]
    [(_ _) #f]))

(define (arrows-consistent? fs fr fres as ares)
  (and (>= (length as) (length fs))
       (let-values ([(fixed extra) (split-at as (length fs))])
         (and (andmap consistent? fs fixed)
              (andmap (λ (a) (consistent? a fr)) extra)
              (consistent? fres ares)))))

;; greedy instantiation: walk formal against actual binding tyvars;
;; first concrete binding wins, `_` never binds. A (Mut t) actual
;; unwraps against a plain formal (mirroring consistency's direction).
(define (instantiate! formal actual env)
  (match formal
    [(? tyvar? v)
     (unless (or (hash-has-key? env v) (eq? actual '_))
       (hash-set! env v actual))]
    [`(Mut ,f0)
     (match actual
       [`(Mut ,b) (instantiate! f0 b env)]
       [_ (void)])]
    [`(,_ ,_ ...)
     #:when (and (pair? actual) (eq? (car actual) 'Mut))
     (instantiate! formal (cadr actual) env)]
    [`(List ,a)
     (match actual
       [`(List ,x) (instantiate! a x env)]
       [`(Pairof ,x ,_) (instantiate! a x env)]
       [_ (void)])]
    ;; the equi-recursive unfold in the other direction: car/cdr's
    ;; (Pairof a d) formal against a (List x) actual
    [`(Pairof ,a ,d)
     (match actual
       [`(Pairof ,x ,y) (instantiate! a x env) (instantiate! d y env)]
       [`(List ,x) (instantiate! a x env) (instantiate! d `(List ,x) env)]
       [_ (void)])]
    [`(,h ,as ...)
     (match actual
       [`(,h2 ,bs ...) #:when (and (eq? h h2) (= (length as) (length bs)))
        (for ([a as] [b bs]) (instantiate! a b env))]
       [_ (void)])]
    [_ (void)]))

;; join for match-clause results: equal stays, else _
(define (type-join a b)
  (cond [(equal? a b) a]
        [(consistent? a b) (if (eq? a '_) b (if (eq? b '_) a '_))]
        [else '_]))

;; ---------------------------------------------------------------------
;; prim types: the manifest is the source of truth (stdlib.rkt
;; prim-spec `type` field, arity-asserted there). The local table
;; covers only desugar-level non-manifest forms: the open-coded
;; intrinsics (+ - * eq? <), the comparators that shrink to < (<= >
;; >=), and `not` (shrinks to if) -- these can also appear as VALUES
;; (e.g. (map not xs)), so they need lookup entries, not just synth
;; cases.
;; ---------------------------------------------------------------------

(define non-manifest-prim-types
  (hasheq
   '+ '(-> Int Int Int) '- '(-> Int Int Int) '* '(-> Int Int Int)
   '< '(-> Int Int Bool) '<= '(-> Int Int Bool) '> '(-> Int Int Bool) '>= '(-> Int Int Bool)
   'eq? '(-> a b Bool) 'not '(-> a Bool)))

(define (prim-type-of op)
  (cond [(hash-ref non-manifest-prim-types op #f)]
        [(and (stdlib-prim? op) (stdlib-type op))]
        ;; untyped prim: (-> _ ... _) from the manifest arity
        [(prim? op) `(-> ,@(for/list ([_ (in-range (prim-arity op))]) '_) _)]
        [else '_]))

;; ---------------------------------------------------------------------
;; the checker
;; ---------------------------------------------------------------------

(define (typecheck-program p)
  (match p
    [`(program ,forms ...)
     (define-values (adts ctors ctor-orders) (collect-adts forms))

     ;; a name cannot be both a type and a value: `provide` resolves a
     ;; name against both namespaces (docs/MODULES.md), so a collision
     ;; would make an export ambiguous -- and locally, references and
     ;; annotations would silently mean different things
     (for-each-form forms
      (λ (f)
       (define n
         (match f
           [`(define (,g . ,_) ,_ ...) (and (symbol? g) g)]
           [`(define ,(? symbol? x) ,_) x]
           [_ #f]))
       (when (and n (hash-has-key? adts n))
         (type-error "~a is defined as both a type and a value" (nm n)))))

     ;; the top-level environment: declared types, annotated defines,
     ;; constructors; everything else _
     (define top (make-hasheq))
     (define (formal-type f) (match f [`(,_ : ,t) t] [_ '_]))
     (define (formal-name f) (match f [`(,x : ,_) x] [x x]))
     ;; variadic formals: (a b . rest) -- or a bare symbol, as in
     ;; (lambda args ...). split-dotted returns the fixed formals and
     ;; the rest binder.
     (define (dotted-formals? formals)
       (or (symbol? formals)
           (and (pair? formals) (dotted-formals? (cdr formals)))))
     (define (split-dotted formals)
       (cond [(symbol? formals) (values '() formals)]
             [else
              (define-values (fixed rest) (split-dotted (cdr formals)))
              (values (cons (car formals) fixed) rest)]))
     (for-each-form forms
      (λ (f)
       (match f
         [`(: ,n ,t)
          (check-type-wf t '() adts)
          (hash-set! top n t)]
         ;; prelude signatures (src/prelude.puf) are TRUSTED: they
         ;; type calls exactly like (: n t), but desugar inserts no
         ;; casts for them (docs/TYPES.md §4) -- the same trust class
         ;; as the manifest's prim types
         [`(#%prelude: ,n ,t)
          (check-type-wf t '() adts)
          (hash-set! top n t)]
         [`(,(or 'define-type '#%extern-type) ,_ ,cs ...)
          (for ([c cs])
            (match c
              [`(,cn ,fts ...)
               (define info (hash-ref ctors cn))
               (define res `(,(ctor-info-owner info) ,@(ctor-info-params info)))
               (define res* (if (null? (ctor-info-params info)) (ctor-info-owner info) res))
               (hash-set! top cn
                          (if (null? fts) res* `(-> ,@fts ,res*)))]))]
         [_ (void)])))
     (for-each-form forms
      (λ (f)
       (match f
         [`(define (,g ,formals ...) : ,rt ,_ ...)
          #:when (andmap (λ (x) (or (symbol? x) (and (list? x) (= 3 (length x))))) formals)
          (unless (hash-has-key? top g)
            (hash-set! top g `(-> ,@(map formal-type formals) ,rt)))]
         [`(define (,g ,formals ...) ,_ ...)
          #:when (andmap (λ (x) (or (symbol? x) (and (list? x) (= 3 (length x))))) formals)
          (unless (hash-has-key? top g)
            (hash-set! top g `(-> ,@(map formal-type formals) _)))]
         [`(define ,(? symbol? x) ,_)
          (unless (hash-has-key? top x) (hash-set! top x '_))]
         ;; variadic defines -- (define (f a b . rest) ...) -- derive
         ;; a (->* (t ...) _ rt) type: annotated fixed formals keep
         ;; their types, the rest-element type is _ (a (: f (->* ...))
         ;; declaration tightens it), and the arity floor is known
         [`(define (,g . ,formals) ,body0 ...)
          #:when (and (symbol? g) (dotted-formals? formals))
          (unless (hash-has-key? top g)
            (define-values (fixed rest-name) (split-dotted formals))
            (define rt (match body0 [`(: ,t ,_ ...) t] [_ '_]))
            (hash-set! top g `(->* ,(map formal-type fixed) _ ,rt)))]
         ;; anything else define-shaped still BINDS (typed _), or
         ;; references to it are rejected as unbound by the strict
         ;; lookup below
         [`(define (,g . ,_) ,_ ...)
          #:when (symbol? g)
          (unless (hash-has-key? top g) (hash-set! top g '_))]
         [_ (void)])))

     ;; instantiate a possibly-polymorphic type at a use site
     (define (instantiate-fresh t)
       ;; tyvars stay as-is; application sites bind them greedily
       t)

     (define (lookup env x)
       (cond [(assq x env) => cdr]
             [(hash-ref top x #f)]
             [(prim? x) (prim-type-of x)]
             ;; desugar-level forms the local table types but the
             ;; manifest doesn't know (<=, >, >= rewrite to < in shrink)
             [(hash-ref non-manifest-prim-types x #f)]
             ;; separate compilation: imported names live in other
             ;; units. When the dependency's .pufi carried a type for
             ;; the name it applies here (typed interfaces,
             ;; docs/MODULES.md §3.2); otherwise dynamic, as before
             [(hash-ref (module-ext-types) x #f)]
             [(hash-ref (module-ext-funs) x #f) '_]
             [(hash-ref (module-ext-globals) x #f) '_]
             ;; REPL units late-bind by name (a still-unbound cell
             ;; errors at run time carrying the name)
             [(repl-mode?) '_]
             ;; everywhere else an unknown variable is an ERROR. It
             ;; used to fall through as _ ("dynamic"), and no later
             ;; pass checked scope either: the reference compiled into
             ;; an uninitialized cell holding fixnum 0, which CALLI
             ;; happily dispatched as function index 0 = the program
             ;; entry -- calling a typo'd name re-entered main until
             ;; the stack died. Scope errors are compile-time errors.
             [else (type-error "unbound variable ~a" (nm x))]))

     ;; check an application of `ft` to synthesized arg types.
     ;; Discipline (the gradual guarantee): a formal's CONCRETE
     ;; structure is a contract -- violating it is an error. A
     ;; constraint that exists only because greedy instantiation
     ;; bound a type VARIABLE from a sibling argument is an inference
     ;; hint -- a conflict there demotes the variable to _ instead of
     ;; erroring (unannotated code must never fail to check).
     (define (tyvars-of t)
       (match t
         [(? tyvar? v) (seteq v)]
         [`(,_ ,ts ...) (for/fold ([s (seteq)]) ([x ts]) (set-union s (tyvars-of x)))]
         [_ (seteq)]))
     (define (blank-tyvars t)
       (match t
         [(? tyvar?) '_]
         [`(,h ,ts ...) `(,h ,@(map blank-tyvars ts))]
         [_ t]))
     ;; the shared per-argument discipline: instantiate greedily, then
     ;; contract-check each argument against its (instantiated) formal,
     ;; demoting inference-only tyvar conflicts to _
     (define (check-args formals arg-ts res where)
       (define tenv (make-hasheq))
       (for ([f formals] [a arg-ts]) (instantiate! f a tenv))
       (define conflicted (mutable-seteq))
       (for ([f formals] [a arg-ts])
         (define f* (subst f tenv))
         (unless (consistent? a f*)
           (if (consistent? a (blank-tyvars f))
               ;; only the inferred binding conflicts: weaken it
               (for ([v (in-set (tyvars-of f))]) (set-add! conflicted v))
               (type-error "~a: argument has type ~a, expected ~a" (nm where) (ty a) (ty f*)))))
       (for ([v (in-set conflicted)]) (hash-set! tenv v '_))
       (subst res tenv))
     (define (check-app ft arg-ts where)
       (match ft
         ['_ '_]
         [(? tyvar?) '_]
         [`(-> ,formals ... ,res)
          (unless (= (length formals) (length arg-ts))
            (type-error "~a expects ~a arguments, got ~a" (nm where) (length formals) (length arg-ts)))
          (check-args formals arg-ts res where)]
         [`(->* (,fixed ...) ,trest ,res)
          (when (< (length arg-ts) (length fixed))
            (type-error "~a expects at least ~a arguments, got ~a"
                        (nm where) (length fixed) (length arg-ts)))
          ;; every extra argument checks against the rest-element type
          (define extras (for/list ([_ (in-range (- (length arg-ts) (length fixed)))]) trest))
          (check-args (append fixed extras) arg-ts res where)]
         [_ (type-error "~a: applying a non-function of type ~a" (nm where) (ty ft))]))

     ;; collect the binders a quasiquote pattern introduces. Every
     ;; quasiquote datum is dynamic, so each binder is typed _ -- the
     ;; point is only that they ENTER the env. Without this, a pattern
     ;; var like x in `(add ,x ,y) is invisible and a later reference
     ;; falls through `lookup` to a same-named TOP-LEVEL binding (the
     ;; bug this fixes). `depth` tracks nested quasiquote/unquote; an
     ;; unquote at depth 1 is a binding position whose sub is an
     ;; ordinary match pattern (reuse pattern-bindings for its names).
     (define (qq-pattern-binds tmpl depth)
       (match tmpl
         [`(,(or 'unquote 'unquote-splicing) ,sub)
          (if (= depth 1)
              (map (λ (b) (cons (car b) '_)) (pattern-bindings sub '_))
              (qq-pattern-binds sub (sub1 depth)))]
         [`(quasiquote ,inner) (qq-pattern-binds inner (add1 depth))]
         [(? pair?)
          (append (if (eq? (car tmpl) '...) '() (qq-pattern-binds (car tmpl) depth))
                  (qq-pattern-binds (cdr tmpl) depth))]
         [_ '()]))

     ;; pattern: returns bindings ((x . t) ...) and checks ctor shapes
     (define (pattern-bindings pat scrut-t)
       (match pat
         ['_ '()]
         [(? symbol? s)
          (cond
            [(hash-ref ctors s #f)
             => (λ (info)
                  (unless (null? (ctor-info-fields info))
                    (type-error "constructor ~a used bare but has ~a fields"
                                (nm s) (length (ctor-info-fields info))))
                  '())]
            [else (list (cons s (if (eq? scrut-t '_) '_ scrut-t)))])]
         [`(quote ,_) '()]
         [`(quasiquote ,tmpl) (qq-pattern-binds tmpl 1)]   ;; data is dynamic; bind vars to _
         [(? fixnum?) '()] [(? boolean?) '()] [(? string?) '()]
         [`(cons ,p0 ,p1)
          (define-values (a d)
            (match scrut-t
              [`(Pairof ,a ,d) (values a d)]
              [`(List ,a) (values a `(List ,a))]
              [_ (values '_ '_)]))
          (append (pattern-bindings p0 a) (pattern-bindings p1 d))]
         [`(list ,ps ...)
          (define a (match scrut-t [`(List ,a) a] [_ '_]))
          (append-map (λ (p) (pattern-bindings p a)) ps)]
         [`(vector ,ps ...)
          (define a (match scrut-t [`(Vec ,a) a] [`(Mut (Vec ,a)) a] [_ '_]))
          (append-map (λ (p) (pattern-bindings p a)) ps)]
         [`(? ,_ ,p) (pattern-bindings p '_)]
         [`(,(? (λ (s) (hash-has-key? ctors s)) cn) ,ps ...)
          (define info (hash-ref ctors cn))
          (unless (= (length ps) (length (ctor-info-fields info)))
            (type-error "constructor ~a expects ~a fields, got ~a in pattern"
                        (nm cn) (length (ctor-info-fields info)) (length ps)))
          ;; field types instantiated from the scrutinee's type args
          (define tenv (make-hasheq))
          (match scrut-t
            [`(,n ,args ...) #:when (eq? n (ctor-info-owner info))
             (for ([p (ctor-info-params info)] [a args]) (hash-set! tenv p a))]
            [_ (void)])
          (append-map (λ (p ft) (pattern-bindings p (subst ft tenv)))
                      ps (ctor-info-fields info))]
         [_ '()]))

     ;; exhaustiveness over closed ADTs (docs/TYPES.md §2): when the
     ;; scrutinee's type is a KNOWN ADT (a `_` scrutinee is exempt --
     ;; the gradual guarantee), compute the constructor set the
     ;; clauses cover. Conservative in the no-false-warnings
     ;; direction: a wildcard/binder clause, a #:when-guarded
     ;; catch-all, or any pattern we cannot prove partial (literals,
     ;; quasiquote, cons/list/vector, ?-tests) counts as covering
     ;; everything; a constructor pattern covers its constructor even
     ;; under a guard. Missing constructors are a WARNING on stderr
     ;; (strict-exhaustiveness? promotes it to an error).
     (define (check-match-exhaustiveness st clauses)
       (define name
         (match st
           [(? symbol? s) (and (hash-has-key? adts s) s)]
           [`(,n ,_ ...) (and (symbol? n) (hash-has-key? adts n) n)]
           [_ #f]))
       (when name
         (define all (hash-ref ctor-orders name '()))
         (define covered
           (for/fold ([cov (seteq)]) ([cl clauses])
             (define p (match cl
                         [`[,p0 #:when ,_ ,_ ...] p0]
                         [`[,p0 ,_ ...] p0]))
             (match p
               [(? symbol? s)
                (cond [(hash-ref ctors s #f)
                       => (λ (info)
                            (if (eq? (ctor-info-owner info) name) (set-add cov s) cov))]
                      ;; wildcard or binder: covers everything
                      [else (set-union cov (list->seteq all))])]
               [`(,(? (λ (s) (hash-has-key? ctors s)) cn) ,_ ...) (set-add cov cn)]
               ;; anything we cannot prove partial covers everything
               [_ (set-union cov (list->seteq all))])))
         (define missing (filter (λ (c) (not (set-member? covered c))) all))
         (when (pair? missing)
           (define msg (format "match on ~a is not exhaustive: missing ~a"
                               (nm name)
                               (string-join (map (λ (c) (symbol->string (nm c))) missing) ", ")))
           ;; the warning renders the position itself; the strict
           ;; error gets it from type-error -- same bytes either way
           (if (strict-exhaustiveness?)
               (type-error "~a" msg)
               (eprintf "typecheck warning: ~a~a\n" msg (origin-suffix))))))

     ;; bidirectional core: synth returns the expression's type
     (define (synth e env)
       (match e
         [(? fixnum?) 'Int]
         [#t 'Bool] [#f 'Bool]
         [(? string?) 'Str]
         ['(void) 'Void] ['(read) 'Int]
         [`(quote ,(? symbol?)) 'Sym]
         [`(quote ()) '(List _)]
         [`(quote ,_) '_]
         [`(quasiquote ,_) '_]
         [(? symbol? x) (lookup env x)]
         [`(ann ,e0 ,t)
          (check-type-wf t '() adts)
          (define et (synth e0 env))
          (unless (consistent? et t)
            (type-error "(ann ...) claims ~a but expression has type ~a" (ty t) (ty et)))
          t]
         [`(if ,g ,then ,els)
          (synth g env)
          (type-join (synth then env) (synth els env))]
         [`(cond ,clauses ...)
          (for/fold ([t '_]) ([cl clauses])
            (match cl
              [`[else ,body ...] (type-join t (synth-body body env))]
              [`[,g ,body ...] (synth g env) (type-join t (synth-body body env))]))]
         [`(,(or 'when 'unless) ,g ,body ...)
          (synth g env) (synth-body body env) '_]
         [`(case ,k ,clauses ...)
          (synth k env)
          (for ([cl clauses])
            (match cl
              [`[else ,body ...] (synth-body body env)]
              [`[,_ ,body ...] (synth-body body env)]))
          '_]
         [`(match ,scrut ,clauses ...)
          (define st (synth scrut env))
          (define res
            (for/fold ([t '_] [first #t] #:result t)
                      ([cl clauses])
              (define-values (pat guard body)
                (match cl
                  [`[,p #:when ,g ,body ...] (values p g body)]
                  [`[,p ,body ...] (values p #f body)]))
              (define env+ (append (pattern-bindings pat st) env))
              (when guard (synth guard env+))
              (define bt (synth-body body env+))
              (values (if first bt (type-join t bt)) #f)))
          (check-match-exhaustiveness st clauses)
          res]
         [`(let ,(? symbol? loop) (,bindings ...) ,body ...)
          (define bs (map binding-parts bindings))
          (define env+ (append (map (λ (b) (cons (first b) (second b))) bs) env))
          (for ([b bs])
            (check-binding b env))
          ;; the loop variable is a function; v1 gives it _
          (synth-body body (cons (cons loop '_) env+))]
         [`(,(or 'let 'let*) (,bindings ...) ,body ...)
          (define env+
            (for/fold ([env+ env]) ([b bindings])
              (define parts (binding-parts b))
              (check-binding parts (if (eq? (car e) 'let*) env+ env))
              (cons (cons (first parts) (second parts)) env+)))
          (synth-body body env+)]
         [`(,(or 'lambda 'λ) ,formals ,body ...)
          #:when (list? formals)
          (define fts (map formal-type* formals))
          (define-values (rt body*)
            (match body
              [`(: ,t ,rest ...) (values t rest)]
              [_ (values '_ body)]))
          (define env+ (append (map cons (map formal-name* formals) fts) env))
          (define bt (synth-body body* env+))
          (when (and (not (eq? rt '_)) (not (consistent? bt rt)))
            (type-error "lambda body has type ~a, declared ~a" (ty bt) (ty rt)))
          `(-> ,@fts ,(if (eq? rt '_) bt rt))]
         ;; variadic lambda -- (lambda (a . rest) ...) or (lambda args
         ;; ...): fixed formals may be annotated, the rest binder is
         ;; (List _) in the body
         [`(,(or 'lambda 'λ) ,formals ,body ...)
          #:when (dotted-formals? formals)
          (define-values (fixed rest-name) (split-dotted formals))
          (define fts (map formal-type* fixed))
          (define-values (rt body*)
            (match body
              [`(: ,t ,rest ...) (values t rest)]
              [_ (values '_ body)]))
          (define env+ (cons (cons rest-name '(List _))
                             (append (map cons (map formal-name* fixed) fts) env)))
          (define bt (synth-body body* env+))
          (when (and (not (eq? rt '_)) (not (consistent? bt rt)))
            (type-error "lambda body has type ~a, declared ~a" (ty bt) (ty rt)))
          `(->* ,fts _ ,(if (eq? rt '_) bt rt))]
         [`(,(or 'lambda 'λ) ,_ ,_ ...) '_]  ;; malformed formals: dynamic
         [`(begin ,es ... ,last)
          (for ([s es]) (synth s env))
          (synth last env)]
         [`(while ,g ,body ...)
          (synth g env) (synth-body body env) 'Void]
         [`(set! ,x ,e0)
          ;; SOUNDNESS INVARIANT (do not "fix" by adding narrowing):
          ;; the checker deliberately does NO occurrence typing, so a
          ;; variable's type is its declared/inferred type everywhere,
          ;; and this consistency check is all mutation needs. If flow
          ;; narrowing is ever added, it MUST refuse to refine any
          ;; variable that is set! anywhere (the Typed-Racket rule) --
          ;; otherwise a mutation could invalidate a narrowed fact. No
          ;; effect system is required for that; the assigned-var set
          ;; is a one-pass syntactic property. (Puffin has no unions to
          ;; narrow by design; `_` is the dynamic-dispatch mechanism.)
          (define xt (lookup env x))
          (define et (synth e0 env))
          (unless (consistent? et xt)
            (type-error "(set! ~a ...): value has type ~a, variable is ~a" (nm x) (ty et) (ty xt)))
          'Void]
         [`(and ,es ...) (for ([s es]) (synth s env)) '_]
         [`(or ,es ...) (for ([s es]) (synth s env)) '_]
         ;; `not` is a desugar-level form (shrink: (not e) -> (if e #f #t)),
         ;; not a prim or prelude function -- without a case here the
         ;; app fallthrough would look it up as a variable
         [`(not ,e0) (synth e0 env) 'Bool]
         [`(list ,es ...)
          (define t (for/fold ([t '_]) ([s es]) (type-join t (synth s env))))
          `(List ,t)]
         [`(vector ,es ...)
          ;; vector literals allocate a runtime-mutable vector, like
          ;; make-vector (there is no persistent Vec flavor)
          (define t (for/fold ([t '_]) ([s es]) (type-join t (synth s env))))
          `(Mut (Vec ,t))]
         ;; hash/set literals build PERSISTENT collections: plain
         ;; (Hash _ _)/(Set _), never (Mut ...). make-hash/make-set
         ;; type through the manifest ((-> (Mut (Hash _ _))) etc.).
         [`(hash ,es ...) '(Hash _ _)]
         [`(set ,es ...) '(Set _)]
         ;; n-ary sugar the prim table types as binary
         [`(,(? (λ (op) (memq op '(+ - *))) op) ,es ...)
          (for ([s es])
            (define t (synth s env))
            (unless (consistent? t 'Int)
              (type-error "~a: argument has type ~a, expected Int" op (ty t))))
          'Int]
         [`(,rator ,rands ...)
          (define ft (synth rator env))
          (define arg-ts (map (λ (r) (synth r env)) rands))
          (check-app (instantiate-fresh ft) arg-ts
                     (if (symbol? rator) rator "application"))]
         [_ '_]))

     (define (synth-body body env)
       ;; internal defines extend the env with _ (v1); expressions synth
       (define names
         (filter-map (λ (f) (match f
                              [`(define (,g ,_ ...) ,_ ...) g]
                              [`(define (,g . ,_) ,_ ...) #:when (symbol? g) g]
                              [`(define ,(? symbol? x) ,_) x]
                              [_ #f]))
                     body))
       (define env+ (append (map (λ (n) (cons n '_)) names) env))
       (for/fold ([t '_]) ([f body])
         (match f
           [`(define ,_ ,_ ...) '_]
           [e (synth e env+)])))

     (define (binding-parts b)
       (match b
         [`(,x : ,t ,e) (check-type-wf t '() adts) (list x t e)]
         [`(,x ,e) (list x '_ e)]))
     (define (check-binding parts env)
       (match-define (list x t e) parts)
       (define et (synth e env))
       (unless (consistent? et t)
         (type-error "~a is declared ~a but its value has type ~a" (nm x) (ty t) (ty et))))
     (define (formal-type* f)
       (match f [`(,_ : ,t) (check-type-wf t '() adts) t] [_ '_]))
     (define (formal-name* f) (match f [`(,x : ,_) x] [x x]))

     ;; check every top-level form under `top`
     (for-each-form forms
      (λ (f)
       (match f
         [`(define-type ,_ ,_ ...) (void)]
         [`(#%extern-type ,_ ,_ ...) (void)]
         [`(: ,_ ,_) (void)]
         [`(#%prelude: ,_ ,_) (void)]
         [`(define (,g ,formals ...) ,body0 ...)
          #:when (andmap (λ (x) (or (symbol? x) (and (list? x) (= 3 (length x))))) formals)
          (define-values (rt body)
            (match body0
              [`(: ,t ,rest ...) (check-type-wf t '() adts) (values t rest)]
              [_ (values '_ body0)]))
          ;; the function's declared/derived type constrains the body
          (define ft (hash-ref top g))
          (define fts (match ft [`(-> ,as ... ,_) as] [_ (map (λ (_) '_) formals)]))
          (define env (map cons (map formal-name* formals) fts))
          (for ([fm formals]) (formal-type* fm))  ;; well-formedness
          (define bt (synth-body body env))
          (unless (or (eq? rt '_) (consistent? bt rt))
            (type-error "~a: body has type ~a, declared ~a" (nm g) (ty bt) (ty rt)))]
         ;; variadic define: fixed formals get their (declared or
         ;; annotated) types, the rest binder is (List trest) in the
         ;; body (docs/TYPES.md §1: ->*)
         [`(define (,g . ,formals) ,body0 ...)
          #:when (and (symbol? g) (dotted-formals? formals))
          (define-values (fixed rest-name) (split-dotted formals))
          (define-values (rt body)
            (match body0
              [`(: ,t ,rest ...) (check-type-wf t '() adts) (values t rest)]
              [_ (values '_ body0)]))
          (define ft (hash-ref top g))
          (define-values (fts trest)
            (match ft
              [`(->* (,ts ...) ,tr ,_) #:when (= (length ts) (length fixed)) (values ts tr)]
              [_ (values (map (λ (_) '_) fixed) '_)]))
          (for ([fm fixed]) (formal-type* fm))  ;; well-formedness
          (define env (cons (cons rest-name `(List ,trest))
                            (map cons (map formal-name* fixed) fts)))
          (define bt (synth-body body env))
          (unless (or (eq? rt '_) (consistent? bt rt))
            (type-error "~a: body has type ~a, declared ~a" (nm g) (ty bt) (ty rt)))]
         [`(define (,_ . ,_) ,_ ...) (void)]  ;; malformed formals: dynamic
         [`(define ,(? symbol? x) ,e)
          (define et (synth e '()))
          (define dt (hash-ref top x '_))
          (unless (consistent? et dt)
            (type-error "~a is declared ~a but its value has type ~a" (nm x) (ty dt) (ty et)))
          (when (eq? dt '_) (hash-set! top x et))]
         [e (synth e '())])))
     ;; typed interfaces (separate compilation): deposit the final
     ;; top-level environment -- declared, derived, and synthesized
     ;; types alike -- for the .pufi writer. Inert when unset.
     (when (typecheck-top-sink)
       (set-box! (typecheck-top-sink)
                 (for/hash ([(k v) (in-hash top)]) (values k v))))
     p]))
