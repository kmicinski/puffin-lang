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
(provide typecheck-program type-error? consistent?
         ;; grammar types, for desugar's recognizers and casts
         grammar-table gram-name gram-pred-name g-params g-prods
         lit? slist? star? sym-except? split-star tyvar?)

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
  (cond [(sexp-type? t) (string->symbol (render-sexp-type (cadr t)))]
        [(symbol? t) (module-demangle t)]
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

;; ---- type aliases (docs/TYPES.md §3) --------------------------------
;; (define-type-alias Name τ) and (define-type-alias (Name a ...) τ):
;; Name abbreviates τ, transparently. Aliases are unfolded before
;; anything else reads a type, so the checker, desugar's casts and the
;; backends only ever see what they abbreviate; the form itself stays
;; in the program (the walkers ignore it) and desugar drops it.
;; Mirrors puffincc-src/types.puf. aliases: hasheq name -> (params . body)

(define (alias-head-np head f)
  (match head
    [`(,(? symbol? n) ,(? symbol? ps) ...) (cons n ps)]
    [(? symbol? n) (cons n '())]
    [_ (type-error "malformed define-type-alias: ~a" (ty f))]))

(define (collect-aliases forms)
  (define aliases (make-hasheq))
  ;; the heads of the ADTs and foreign types, to refuse a name used both ways
  (define type-heads (mutable-seteq))
  (for-each-form forms
   (λ (f)
     (match f
       [`(,(or 'define-type '#%extern-type 'define-grammar) ,head ,_ ...)
        (set-add! type-heads (match head [`(,n ,_ ...) n] [n n]))]
       [`(,(or 'define-foreign-type '#%extern-foreign-type) ,n) (set-add! type-heads n)]
       [_ (void)])))
  (for-each-form forms
   (λ (f)
     (match f
       [`(define-type-alias ,head ,body)
        (define np (alias-head-np head f))
        (define n (car np))
        (when (or (set-member? base-types n) (set-member? type-former-names n))
          (type-error "define-type-alias cannot redefine built-in type ~a" n))
        (when (tyvar? n)
          (type-error "define-type-alias ~a: a type name is capitalized (a lowercase name is a type variable)" n))
        (when (or (set-member? type-heads n) (hash-has-key? aliases n))
          (type-error "type ~a defined twice" (nm n)))
        (hash-set! aliases n (cons (cdr np) body))]
       [`(define-type-alias ,_ ...)
        (type-error "malformed define-type-alias: ~a" (ty f))]
       [_ (void)])))
  aliases)

(define (subst-type t env)
  (cond [(symbol? t) (let ([hit (assq t env)]) (if hit (cdr hit) t))]
        [(pair? t) (cons (subst-type (car t) env) (subst-type (cdr t) env))]
        [else t]))

;; τ with every alias unfolded; `seen` holds the aliases being
;; unfolded, so a cycle is an error rather than a loop
(define (expand-alias-type t aliases) (expand-alias-type* t aliases '()))
(define (expand-alias-type* t aliases seen)
  (define (unfold n args)
    (match-define (cons ps body) (hash-ref aliases n))
    (when (memq n seen)
      (type-error "type alias ~a is recursive" (nm n)))
    (unless (= (length ps) (length args))
      (type-error "type alias ~a expects ~a parameters, got ~a" (nm n) (length ps) (length args)))
    (expand-alias-type* (subst-type body (map cons ps args)) aliases (cons n seen)))
  (define (expand s) (expand-alias-type* s aliases seen))
  (match t
    [(? symbol? s) (if (hash-has-key? aliases s) (unfold s '()) s)]
    ;; the fixed-argument list of a ->* is a list of types, not an application
    [`(->* (,ts ...) ,tr ,tres) (list '->* (map expand ts) (expand tr) (expand tres))]
    [`(,(? symbol? h) ,args ...) #:when (hash-has-key? aliases h) (unfold h (map expand args))]
    ;; any other list: its elements are types (never its tails, which
    ;; would read (-> Env Int)'s (Env Int) as an application)
    [(? list? l) (map expand l)]
    [(cons a d) (cons (expand a) (expand d))]
    [_ t]))

;; the program with every type position unfolded: [x : τ] formals and
;; bindings, the `: τ` result of a define or lambda, (: n τ),
;; (#%prelude: n τ), (ann e τ), define-type and #%extern-type fields,
;; and foreign declarations (: n τ). Quoted data is left alone, a
;; template is entered only through its escapes, and the alias forms
;; themselves stay (checked for well-formedness in typecheck-program).
(define (expand-type-aliases forms aliases)
  (define (tyx t) (expand-alias-type t aliases))
  (define (walk-ctor c)
    (match c [`(,cn ,fts ...) (cons cn (map tyx fts))] [_ c]))
  ;; a production: its type leaves unfold, its literals (quoted data,
  ;; and the symbols no alias names) stay
  (define (walk-prod q)
    (match q
      [(? symbol? s) (if (hash-has-key? aliases s) (tyx s) s)]
      [`(quote ,_) q]
      [`(,(? symbol? h) ,_ ...) #:when (or (set-member? type-former-names h) (hash-has-key? aliases h))
       (tyx q)]
      [(cons a d) (cons (walk-prod a) (walk-prod d))]
      [_ q]))
  (define (walk-grammar rest)
    (if (and (pair? rest) (eq? (car rest) '#:keywords) (pair? (cdr rest)))
        (list* (car rest) (cadr rest) (map walk-prod (cddr rest)))
        (map walk-prod rest)))
  (define (walk-template q depth)
    (match q
      [(list 'unquote x)
       (list 'unquote (if (= depth 1) (walk x) (walk-template x (- depth 1))))]
      [(list 'unquote-splicing x)
       (list 'unquote-splicing (if (= depth 1) (walk x) (walk-template x (- depth 1))))]
      [(list 'quasiquote x) (list 'quasiquote (walk-template x (+ depth 1)))]
      [(cons a d) (cons (walk-template a depth) (walk-template d depth))]
      [_ q]))
  (define (walk e)
    (match e
      [`(quote ,_) e]
      [`(quasiquote ,q) (list 'quasiquote (walk-template q 1))]
      [`(define-type-alias ,_ ,_) e]
      [`(,(and h (or 'define-type '#%extern-type)) ,head ,cs ...) (cons h (cons head (map walk-ctor cs)))]
      [`(define-grammar ,head . ,rest) (list* 'define-grammar head (walk-grammar rest))]
      [`(: ,n ,t) (list ': n (tyx t))]
      [`(#%prelude: ,n ,t) (list '#%prelude: n (tyx t))]
      [`(ann ,x ,t) (list 'ann (walk x) (tyx t))]
      ;; [x : τ] and [x : τ e]
      [`(,(? symbol? x) : ,t . ,rest) (cons x (cons ': (cons (tyx t) (walk rest))))]
      ;; (define (f ...) : τ body ...), (lambda (...) : τ body ...)
      [`(,(and h (or 'define 'lambda 'λ)) ,formals : ,t . ,body)
       (cons h (cons (walk formals) (cons ': (cons (tyx t) (walk body)))))]
      [(cons a d) (cons (walk a) (walk d))]
      [_ e]))
  (if (zero? (hash-count aliases))
      forms
      (map-form forms walk)))

(define (collect-adts forms0)
  ;; constructor fields may name type aliases: unfold them first
  (define forms (expand-type-aliases forms0 (collect-aliases forms0)))
  (define adts (make-hasheq))   ;; type name -> adt
  (define ctors (make-hasheq))  ;; ctor name -> ctor-info
  (define ctor-orders (make-hasheq))  ;; type name -> (ctor ...) in declaration order
  ;; pass 0: define-foreign-type heads (docs/FFI.md §6) -- opaque
  ;; nullary types. They enter `adts` (annotations resolve; zero
  ;; constructors, so exhaustiveness never fires) AND the foreign-type
  ;; set (the FFI's handle-marshaling test). #%extern-foreign-type is
  ;; the separate-compilation splice, exactly like #%extern-type.
  ;; (Plain pair tests, not match clauses: module-load gensym budget.)
  (define ftypes (mutable-seteq))
  (for-each-form forms
   (λ (f)
    (when (and (pair? f)
               (or (eq? (car f) 'define-foreign-type)
                   (eq? (car f) '#%extern-foreign-type)))
      (unless (and (pair? (cdr f)) (symbol? (cadr f)) (null? (cddr f)))
        (type-error "malformed define-foreign-type: ~a" f))
      (define n (cadr f))
      (when (or (set-member? base-types n) (set-member? type-former-names n))
        (type-error "define-foreign-type cannot redefine built-in type ~a" n))
      (when (hash-has-key? adts n)
        (type-error "type ~a defined twice" (nm n)))
      (hash-set! adts n (adt n '() (make-hasheq)))
      (set-add! ftypes n))))
  ;; pass 1: heads
  (for-each-form forms
   (λ (f)
    (match f
      [`(,(and dt (or 'define-type '#%extern-type 'define-grammar)) ,head ,_ ...)
       (define-values (n ps)
         (match head
           [`(,n ,ps ...) (values n ps)]
           [n (values n '())]))
       (when (or (set-member? base-types n) (set-member? type-former-names n))
         (type-error "~a cannot redefine built-in type ~a" (if (eq? dt 'define-grammar) dt 'define-type) n))
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
       ;; every constructor is (Name field-type ...): a bare Name is the
       ;; mistake the reference syntax (None, not (None)) invites
       (for ([c cs])
         (match c
           [`(,(? symbol?) ,_ ...) (void)]
           [(? symbol? s)
            (type-error "define-type ~a: constructor ~a is declared (~a), referenced bare" (nm n) (nm s) (nm s))]
           [_ (type-error "define-type ~a: malformed constructor, expected (Name field-type ...)" (nm n))]))
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
  ;; pass 3: the grammar table -- every define-type and define-grammar
  ;; as its productions (docs/GRAMMARS.md)
  (set! grammar-table (make-hasheq))
  (for-each-form forms
   (λ (f)
    (match f
      [`(,(or 'define-type '#%extern-type) ,head ,cs ...)
       (define n (match head [`(,n ,_ ...) n] [n n]))
       (hash-set! grammar-table n
                  (list (adt-params (hash-ref adts n)) '() (map ctor->shape cs) 'type (map car cs)))]
      [`(define-grammar ,head . ,rest)
       (define n (match head [`(,n ,_ ...) n] [n n]))
       (define ps (adt-params (hash-ref adts n)))
       (define kp (grammar-parts n rest))
       (when (null? (cdr kp))
         (type-error "define-grammar ~a: expected at least one production" (nm n)))
       (hash-set! grammar-table n
                  (list ps (car kp)
                        (map (λ (q) (prod->shape q n ps (car kp) adts)) (cdr kp))
                        'grammar '()))]
      [_ (void)])))
  (values adts ctors ctor-orders ftypes))

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
    ;; s-expression types (docs/GRAMMARS.md): into a grammar or an
    ;; exact shape is inclusion; an exact shape anywhere is inclusion
    ;; too; a grammar used as an ordinary type needs only to overlap it
    [(_ (? sexpy?)) (sx-sub? t1 t2)]
    [((? sexp-type?) _) (sx-sub? t1 t2)]
    [((? gram-name) _) (sx-overlap? t1 t2)]
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
       (hash-set! env v (if (and (sexp-type? actual) (lit? (cadr actual)))
                            (widen actual)
                            actual)))]
    ;; an exact shape: a type variable takes a list shape as is (above;
    ;; it may be a grammar's term) and an atom as its base type; a
    ;; structured formal reads the ordinary type it inhabits
    [_ #:when (sexp-type? actual) (instantiate! formal (widen actual) env)]
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
        [(eq? a '_) b]
        [(eq? b '_) a]
        ;; s-expression types: the larger when one includes the other,
        ;; else _ (a widening would lose that both fit some grammar)
        [(and (sexpy? a) (sexpy? b))
         (cond [(sx-sub? a b) b]
               [(sx-sub? b a) a]
               [else '_])]
        [(sexp-type? a) (type-join (widen a) b)]
        [(sexp-type? b) (type-join a (widen b))]
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

;; ---------------------------------------------------------------------
;; grammar types (docs/GRAMMARS.md)
;; ---------------------------------------------------------------------
;; A grammar is a union of productions over plain s-expressions, and a
;; define-type is one too (literal head symbols, plus constructor
;; functions). Productions, quoted data and templates are all
;; normalized to SHAPES:
;;   (#%lit d)             the literal atom d (symbol, fixnum, string,
;;                         boolean); () is (#%list)
;;   (#%list e ...)        a proper list; at most one element is
;;                         (#%star s): zero or more s
;;   (#%sym-except k ...)  a Sym leaf of a grammar with #:keywords
;;   any type τ            a leaf: every value of τ
;; The type of a quoted datum or a template is (#%sexp s). Mirrors
;; puffincc-src/types.puf (diagnostics byte-for-byte).

;; name -> (list params keywords prods kind ctors): kind is 'type for a
;; define-type (ctors: its constructor names, one per production) or
;; 'grammar. Set by collect-adts for the program being checked.
(define grammar-table (make-hasheq))

(define (g-params gi) (first gi))
(define (g-prods gi) (third gi))
(define (g-kind gi) (fourth gi))
(define (g-ctors gi) (fifth gi))

(define (lit? s) (and (pair? s) (eq? (car s) '#%lit)))
(define (slist? s) (and (pair? s) (eq? (car s) '#%list)))
(define (star? s) (and (pair? s) (eq? (car s) '#%star)))
(define (sym-except? s) (and (pair? s) (eq? (car s) '#%sym-except)))
(define (sexp-type? t) (and (pair? t) (eq? (car t) '#%sexp)))
(define (unstar e) (if (star? e) (cadr e) e))

;; the grammar a type names, or #f
(define (gram-name t)
  (cond [(and (symbol? t) (hash-has-key? grammar-table t)) t]
        [(and (pair? t) (symbol? (car t)) (hash-has-key? grammar-table (car t))) (car t)]
        [else #f]))
(define (sexpy? t) (or (sexp-type? t) (and (gram-name t) #t)))

;; substitution into a shape: literals are data, never parameters
(define (subst-shape s env)
  (cond [(lit? s) s]
        [(sym-except? s) s]
        [(slist? s) (cons '#%list (map (λ (e) (subst-shape e env)) (cdr s)))]
        [(star? s) (list '#%star (subst-shape (cadr s) env))]
        [else (subst-type s env)]))

;; a grammar type's productions, its parameters instantiated (a missing
;; argument is _)
(define (gram-prods t)
  (define gi (hash-ref grammar-table (gram-name t)))
  (define ps (g-params gi))
  (define args (if (pair? t) (cdr t) '()))
  (if (null? ps)
      (g-prods gi)
      (let ([env (let loop ([ps ps] [as args] [acc '()])
                   (if (null? ps)
                       acc
                       (loop (cdr ps) (if (pair? as) (cdr as) '())
                             (cons (cons (car ps) (if (pair? as) (car as) '_)) acc))))])
        (map (λ (p) (subst-shape p env)) (g-prods gi)))))

;; a quoted datum as a shape, or #f for an improper list
(define (datum->shape d)
  (cond [(null? d) (list '#%list)]
        [(pair? d)
         (if (list? d)
             (let ([es (map datum->shape d)])
               (if (andmap (λ (e) (and e #t)) es) (cons '#%list es) #f))
             #f)]
        [else (list '#%lit d)]))

(define (capitalized? s)
  (let ([str (symbol->string s)])
    (and (> (string-length str) 0)
         (char<=? #\A (string-ref str 0) #\Z))))

;; (define-grammar head [#:keywords (k ...)] prod ...): the keywords
;; and the productions
(define (grammar-parts gname rest)
  (if (and (pair? rest) (eq? (car rest) '#:keywords))
      (if (and (pair? (cdr rest)) (list? (cadr rest)) (andmap symbol? (cadr rest)))
          (cons (cadr rest) (cddr rest))
          (type-error "define-grammar ~a: #:keywords takes a list of symbols" (nm gname)))
      (cons '() rest)))

;; a production as written -> its shape
(define (prod->shape p gname params kws adts)
  (define (type-sym? s)
    (or (set-member? base-types s) (and (memq s params) #t) (hash-has-key? adts s)))
  (define (conv p)
    (cond
      [(symbol? p)
       (cond [(type-sym? p)
              (check-type-wf p params adts)
              (if (and (eq? p 'Sym) (pair? kws)) (cons '#%sym-except kws) p)]
             [(eq? p '...) (type-error "define-grammar ~a: ... must follow an element" (nm gname))]
             [(capitalized? p)
              (type-error "define-grammar ~a: unknown type ~a (quote it for the literal symbol)"
                          (nm gname) (nm p))]
             [else (list '#%lit p)])]
      [(and (pair? p) (eq? (car p) 'quote) (pair? (cdr p)) (null? (cddr p)))
       (or (datum->shape (cadr p))
           (type-error "define-grammar ~a: dotted productions are not supported" (nm gname)))]
      [(and (pair? p) (symbol? (car p))
            (or (set-member? type-former-names (car p))
                (and (hash-has-key? adts (car p)) (pair? (adt-params (hash-ref adts (car p)))))))
       (check-type-wf p params adts)
       p]
      [(list? p) (cons '#%list (conv-elems p))]
      [(pair? p) (type-error "define-grammar ~a: dotted productions are not supported" (nm gname))]
      [else (list '#%lit p)]))
  (define (conv-elems l)
    (let loop ([l l] [acc '()] [stars 0])
      (cond
        [(null? l) (reverse acc)]
        [(eq? (car l) '...)
         (type-error "define-grammar ~a: ... must follow an element" (nm gname))]
        [(and (pair? (cdr l)) (eq? (cadr l) '...))
         (when (> stars 0)
           (type-error "define-grammar ~a: at most one ... per list" (nm gname)))
         (loop (cddr l) (cons (list '#%star (conv (car l))) acc) (add1 stars))]
        [else (loop (cdr l) (cons (conv (car l)) acc) stars)])))
  (conv p))

;; a define-type constructor (Cn ft ...) as a production: its head is
;; the constructor's SOURCE spelling (what the constructor builds)
(define (ctor->shape c)
  (match c
    [`(,cn) (list '#%lit (module-demangle cn))]
    [`(,cn ,fts ...) (cons '#%list (cons (list '#%lit (module-demangle cn)) fts))]))

;; ---- inclusion: every value of a is a value of b --------------------
;; `_` and type variables include and are included by everything (the
;; gradual reading). Grammar pairs are assumed included while their
;; productions are compared (coinduction); a non-grammar revisiting a
;; grammar it is already being compared against fails (left recursion).
(define (sx-sub? a b) (sub* a b '()))

(define (sub* a b as)
  (cond
    [(equal? a b) #t]
    [(or (eq? a '_) (eq? b '_) (tyvar? a) (tyvar? b)) #t]
    [(sexp-type? a) (sub* (cadr a) b as)]
    [(sexp-type? b) (sub* a (cadr b) as)]
    [(gram-name a)
     (or (and (member (cons a b) as) #t)
         (let ([as+ (cons (cons a b) as)])
           (andmap (λ (p) (sub* p b as+)) (gram-prods a))))]
    [(gram-name b)
     (if (member (cons a b) as)
         #f
         (let ([as+ (cons (cons a b) as)])
           (ormap (λ (q) (sub* a q as+)) (gram-prods b))))]
    [(lit? a) (lit-in? (cadr a) b)]
    [(sym-except? a)
     (cond [(eq? b 'Sym) #t]
           [(sym-except? b) (andmap (λ (k) (and (member k (cdr a)) #t)) (cdr b))]
           [else #f])]
    [(slist? a) (list-in? (cdr a) b as)]
    ;; a is an ordinary type
    [(or (lit? b) (sym-except? b)) #f]
    [(slist? b) (type-in-list? a (cdr b) as)]
    [else (consistent? a b)]))

;; a literal atom in a shape or type
(define (lit-in? d b)
  (cond [(lit? b) (equal? d (cadr b))]
        [(sym-except? b) (and (symbol? d) (not (member d (cdr b))))]
        [(eq? b 'Sym) (symbol? d)]
        [(eq? b 'Int) (fixnum? d)]
        [(eq? b 'Str) (string? d)]
        [(eq? b 'Bool) (boolean? d)]
        [(eq? b '_) #t]
        [else #f]))

;; a list shape's elements es in b
(define (list-in? es b as)
  (cond
    [(slist? b) (elems-in? es (cdr b) as)]
    [(and (pair? b) (eq? (car b) 'List))
     (andmap (λ (e) (sub* (unstar e) (cadr b) as)) es)]
    [(and (pair? b) (eq? (car b) 'Pairof))
     (and (pair? es) (not (star? (car es)))
          (sub* (car es) (cadr b) as)
          (sub* (cons '#%list (cdr es)) (caddr b) as))]
    [else #f]))

;; an ordinary (List τ) / (Pairof x y) type in a list shape
(define (type-in-list? a fs as)
  (match a
    [`(List ,t)
     (match fs
       [`((#%star ,s)) (sub* t s as)]
       [_ #f])]
    [`(Pairof ,x ,y)
     (match fs
       [`((#%star ,s)) (and (sub* x s as) (sub* y (cons '#%list fs) as))]
       [(cons f rest) (and (not (star? f)) (sub* x f as) (sub* y (cons '#%list rest) as))]
       [_ #f])]
    [_ #f]))

;; elements split at their star: (list prefix star-or-#f suffix)
(define (split-star es)
  (let loop ([es es] [pre '()])
    (cond [(null? es) (list (reverse pre) #f '())]
          [(star? (car es)) (list (reverse pre) (cadr (car es)) (cdr es))]
          [else (loop (cdr es) (cons (car es) pre))])))

(define (pairwise-sub? xs ys as)
  (cond [(and (null? xs) (null? ys)) #t]
        [(or (null? xs) (null? ys)) #f]
        [(sub* (car xs) (car ys) as) (pairwise-sub? (cdr xs) (cdr ys) as)]
        [else #f]))

(define (elems-in? es fs as)
  (match-define (list pe se qe) (split-star es))
  (match-define (list pf sf qf) (split-star fs))
  (define lpf (length pf))
  (define lqf (length qf))
  (cond
    [(not sf) (and (not se) (pairwise-sub? es fs as))]
    [(not se)
     (define n (length es))
     (and (>= n (+ lpf lqf))
          (pairwise-sub? (take es lpf) pf as)
          (pairwise-sub? (drop es (- n lqf)) qf as)
          (andmap (λ (e) (sub* e sf as)) (take (drop es lpf) (- n (+ lpf lqf)))))]
    [else
     (and (>= (length pe) lpf) (>= (length qe) lqf)
          (pairwise-sub? (take pe lpf) pf as)
          (pairwise-sub? (drop qe (- (length qe) lqf)) qf as)
          (andmap (λ (e) (sub* e sf as)) (drop pe lpf))
          (sub* se sf as)
          (andmap (λ (e) (sub* e sf as)) (take qe (- (length qe) lqf))))]))

;; ---- overlap: a grammar used where an ordinary type is expected -----
;; consistent when some value could be both (car on an Expr); disjoint
;; is the error
(define (sx-overlap? a t) (ovl* a t '()))
(define (ovl* a t vs)
  (cond
    [(or (eq? a '_) (eq? t '_) (tyvar? a) (tyvar? t)) #t]
    [(sexp-type? a) (ovl* (cadr a) t vs)]
    [(gram-name a)
     (if (member a vs)
         #f
         (ormap (λ (p) (ovl* p t (cons a vs))) (gram-prods a)))]
    [(lit? a) (lit-in? (cadr a) t)]
    [(sym-except? a) (consistent? 'Sym t)]
    [(slist? a)
     (match t
       [`(List ,_) #t]
       [`(Pairof ,_ ,_) (pair? (cdr a))]
       [_ #f])]
    [else (consistent? a t)]))

;; ---- patterns against productions (docs/GRAMMARS.md §5) ------------
;; (list prefix ellipsis-element-or-#f after-ellipsis tail) of a
;; quasiquote pattern list: tail is the pattern of a dotted ,tail, #f,
;; or 'bad
(define (split-qpat q)
  (let loop ([q q] [pre '()])
    (cond
      [(null? q) (list (reverse pre) #f '() #f)]
      [(and (pair? q) (eq? (car q) 'unquote) (pair? (cdr q)) (null? (cddr q)))
       (list (reverse pre) #f '() (cadr q))]
      [(and (pair? q) (pair? (cdr q)) (eq? (cadr q) '...))
       (list (reverse pre) (car q) (cddr q) #f)]
      [(pair? q) (loop (cdr q) (cons (car q) pre))]
      [else (list (reverse pre) #f '() 'bad)])))

;; the base type a type-test establishes
(define (pred-base pred)
  (cond [(memq pred '(fixnum? integer?)) 'Int]
        [(eq? pred 'symbol?) 'Sym]
        [(eq? pred 'string?) 'Str]
        [(eq? pred 'boolean?) 'Bool]
        [else #f]))

;; can quasiquote pattern q (depth 1) match some value of shape or type
;; s? The checker's binding alignment (align) succeeds exactly when
;; this does; coverage and the editor's fill-match need only the yes/no
(define (tmpl-overlap? q s vs)
  (cond
    [(and (pair? q) (eq? (car q) 'unquote) (pair? (cdr q)) (null? (cddr q))) #t]
    [(sexp-type? s) (tmpl-overlap? q (cadr s) vs)]
    [(gram-name s)
     (if (member s vs)
         #f
         (ormap (λ (p) (tmpl-overlap? q p (cons s vs))) (gram-prods s)))]
    [(or (eq? s '_) (tyvar? s)) #t]
    [(null? q)
     (cond [(slist? s) (andmap star? (cdr s))]
           [(and (pair? s) (eq? (car s) 'List)) #t]
           [else #f])]
    [(pair? q)
     (cond [(slist? s) (list-overlap? q (cdr s) vs)]
           [(and (pair? s) (memq (car s) '(List Pairof))) #t]
           [else #f])]
    [else (lit-in? q s)]))
(define (all-overlap? ps fs vs)
  (cond [(and (null? ps) (null? fs)) #t]
        [(or (null? ps) (null? fs)) #f]
        [(tmpl-overlap? (car ps) (car fs) vs) (all-overlap? (cdr ps) (cdr fs) vs)]
        [else #f]))
(define (list-overlap? q fs vs)
  (match-define (list pre ell post tail) (split-qpat q))
  (match-define (list pf sf qf) (split-star fs))
  (define lpre (length pre))
  (define lpf (length pf))
  (define lqf (length qf))
  (cond
    [(eq? tail 'bad) #t]
    [tail
     (cond [(and (not sf) (>= (length fs) lpre)) (all-overlap? pre (take fs lpre) vs)]
           [(and sf (<= lpre lpf)) (all-overlap? pre (take pf lpre) vs)]
           [else #t])]
    [(not ell)
     (cond [(not sf) (and (= lpre (length fs)) (all-overlap? pre fs vs))]
           [(>= lpre (+ lpf lqf))
            (and (all-overlap? (take pre lpf) pf vs)
                 (andmap (λ (p) (tmpl-overlap? p sf vs)) (take (drop pre lpf) (- lpre (+ lpf lqf))))
                 (all-overlap? (drop pre (- lpre lqf)) qf vs))]
           [else #f])]
    [(not (list? post)) #t]
    [(member '... post) #t]
    [else
     (define lpost (length post))
     (cond
       [(not sf)
        (and (<= (+ lpre lpost) (length fs))
             (all-overlap? pre (take fs lpre) vs)
             (all-overlap? post (drop fs (- (length fs) lpost)) vs)
             (andmap (λ (f) (tmpl-overlap? ell f vs))
                     (take (drop fs lpre) (- (length fs) (+ lpre lpost)))))]
       [else
        (define pre-f (append (take pf (min lpre lpf))
                              (map (λ (_) sf) (range 0 (max 0 (- lpre lpf))))))
        (define post-f (append (map (λ (_) sf) (range 0 (max 0 (- lpost lqf))))
                               (drop qf (max 0 (- lqf lpost)))))
        (define cands (append (drop pf (min lpre lpf))
                              (cons sf (take qf (max 0 (- lqf lpost))))))
        (and (all-overlap? pre pre-f vs)
             (all-overlap? post post-f vs)
             (ormap (λ (c) (tmpl-overlap? ell c vs)) cands))])]))

;; exhaustiveness coverage: the indices of the productions pattern p
;; can match ('all patterns -- binders, _, cons/list/vector, unknown
;; predicates -- cover every production). ctors: the checker's
;; constructor table (nullary-constructor names and constructor
;; patterns spell their source-named data).
(define (covers-all prods) (range 0 (length prods)))
(define (indices-where ok? prods)
  (for/list ([p prods] [i (in-naturals)] #:when (ok? p)) i))
;; does production s admit a value of base type b?
(define (admits-base? s b vs)
  (cond [(or (eq? s '_) (tyvar? s)) #t]
        [(lit? s) (lit-in? (cadr s) b)]
        [(sym-except? s) (eq? b 'Sym)]
        [(gram-name s)
         (if (member s vs) #f
             (ormap (λ (p) (admits-base? p b (cons s vs))) (gram-prods s)))]
        [(symbol? s) (eq? s b)]
        [else #f]))
(define (pattern-cover p prods ctors)
  (match p
    [(? symbol? s)
     (define info (hash-ref ctors s #f))
     (if (and info (null? (ctor-info-fields info)))
         (indices-where (λ (q) (tmpl-overlap? (module-demangle s) q '())) prods)
         (covers-all prods))]
    [`(quasiquote ,q) (indices-where (λ (s) (tmpl-overlap? q s '())) prods)]
    [`(quote ,d) (indices-where (λ (s) (tmpl-overlap? d s '())) prods)]
    [`(,(? (λ (s) (hash-has-key? ctors s)) cn) ,ps ...)
     (define q (cons (module-demangle cn) (map (λ (x) (list 'unquote x)) ps)))
     (indices-where (λ (s) (tmpl-overlap? q s '())) prods)]
    [`(? ,pred ,_)
     (define b (pred-base pred))
     (if b
         (indices-where (λ (s) (admits-base? s b '())) prods)
         (covers-all prods))]
    [(or (? fixnum?) (? string?) (? boolean?))
     (indices-where (λ (s) (tmpl-overlap? p s '())) prods)]
    [_ (covers-all prods)]))

;; ---- widening: an exact shape as the ordinary type it inhabits ------
(define (widen t) (if (sexp-type? t) (widen-shape (cadr t)) t))
(define (widen-shape s)
  (cond
    [(lit? s)
     (define d (cadr s))
     (cond [(symbol? d) 'Sym] [(fixnum? d) 'Int] [(string? d) 'Str]
           [(boolean? d) 'Bool] [else '_])]
    [(sym-except? s) 'Sym]
    [(slist? s)
     (list 'List
           (let loop ([es (cdr s)] [acc #f])
             (if (null? es)
                 (or acc '_)
                 (let ([w (widen-shape (unstar (car es)))])
                   (loop (cdr es) (if acc (type-join acc w) w))))))]
    [else s]))

;; a leaf's shape: an exact type contributes its shape, any other type
;; is a leaf
(define (leaf->shape t) (if (sexp-type? t) (cadr t) t))
;; a shape as the type a binder gets
(define (shape->type s)
  (cond [(or (lit? s) (slist? s)) (list '#%sexp s)]
        [(sym-except? s) 'Sym]
        [else s]))

;; ---- rendering ------------------------------------------------------
(define (render-datum d)
  (cond [(symbol? d) (symbol->string (nm d))]
        [(fixnum? d) (number->string d)]
        [(string? d) (string-append "\"" d "\"")]
        [(eq? d #t) "#t"]
        [(eq? d #f) "#f"]
        [else (format "~a" d)]))
;; leaf renders a type leaf
(define (render-shape s leaf)
  (cond
    [(lit? s) (render-datum (cadr s))]
    [(sym-except? s) (leaf 'Sym)]
    [(slist? s)
     (string-append
      "("
      (string-join (map (λ (e)
                          (if (star? e)
                              (string-append (render-shape (cadr e) leaf) " ...")
                              (render-shape e leaf)))
                        (cdr s))
                   " ")
      ")")]
    [else (leaf s)]))
(define (shape-has-leaf? s)
  (cond [(lit? s) #f]
        [(slist? s) (ormap (λ (e) (shape-has-leaf? (unstar e))) (cdr s))]
        [else #t]))
;; a production as written (exhaustiveness reports)
(define (render-prod s) (render-shape s (λ (t) (format "~a" (ty t)))))
;; an exact type, as the datum or template it came from
(define (render-sexp-type s)
  (if (shape-has-leaf? s)
      (string-append "`" (render-shape s (λ (t) (string-append "," (format "~a" (ty t))))))
      (string-append "'" (render-shape s (λ (t) (format "~a" (ty t)))))))

;; the recognizer a grammar's casts call (compile.rkt desugar)
(define (gram-pred-name n) (string->symbol (string-append "#%gram?-" (symbol->string n))))

;; map over top-level forms with current-form-origin set per form
;; (system.rkt for-each-form, keeping the results)
(define (map-form forms proc)
  (define os (surface-origins))
  (define aligned? (and (list? os) (= (length os) (length forms))))
  (define out
    (map (λ (f o) (current-form-origin-set! o) (proc f))
         forms
         (if aligned? os (map (λ (_) #f) forms))))
  (current-form-origin-set! #f)
  out)

(define (typecheck-program p0)
  (match p0
    [`(program ,forms00 ...)
     ;; type aliases are unfolded everywhere before any type is read
     (define aliases (collect-aliases forms00))
     (define forms0 (expand-type-aliases forms00 aliases))
     (define-values (adts ctors ctor-orders ftypes) (collect-adts forms0))
     ;; quote and quasiquote are data at every depth (docs/GRAMMARS.md):
     ;; nothing is rewritten, the checker types them by their shape
     (define forms forms0)
     (define p (cons 'program forms))

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
       (when (and n (or (hash-has-key? adts n) (hash-has-key? aliases n)))
         (type-error "~a is defined as both a type and a value" (nm n)))))

     ;; every alias abbreviates a well-formed type (its parameters in scope)
     (for-each-form forms
      (λ (f)
        (match f
          [`(define-type-alias ,head ,body)
           (define np (alias-head-np head f))
           (check-type-wf (expand-alias-type body aliases) (cdr np) adts)]
          [_ (void)])))

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

     ;; ---- foreign declarations (docs/FFI.md §3, §5.1) ----------------
     ;; (foreign spath [rpath] (: name τ clause ...) ...): validate each
     ;; declaration -- τ a concrete arrow over the marshallable universe
     ;; (§4), arity <= 6, clauses well-formed, the default #:c-name
     ;; derivable -- and enter `name` at its declared type. Width
     ;; spellings are Int to the checker; a (Nullable τ) result is `_`
    ;; (§4.4). The declared type is UNTRUSTED: desugar's lowering makes
     ;; the runtime check every crossing; the checker only types call
     ;; sites. All plain pair tests (module-load gensym budget).
     (define ffi-widths '(I8 I16 I32 I64 U8 U16 U32 U64))
     (define (ftype? a) (and (symbol? a) (set-member? ftypes a)))
     (define (ffi-arg-ok? a)
       (or (memq a '(Int Bool Str)) (memq a ffi-widths) (ftype? a) #f))
     (define (nullable? r)
       (and (pair? r) (eq? (car r) 'Nullable)
            (pair? (cdr r)) (null? (cddr r))
            (or (eq? (cadr r) 'Str) (ftype? (cadr r)))))
     (define (ffi-ret-ok? r)
       (or (ffi-arg-ok? r) (eq? r 'Void) (nullable? r)))
     ;; every name a define binds (foreign names must not collide)
     (define defined-names (mutable-seteq))
     (for-each
      (λ (f)
        (when (and (pair? f) (eq? (car f) 'define) (pair? (cdr f)))
          (define h (cadr f))
          (cond [(symbol? h) (set-add! defined-names h)]
                [(and (pair? h) (symbol? (car h))) (set-add! defined-names (car h))]
                [else (void)])))
      forms)
     ;; #:c-name default: source spelling with `-` -> `_`; any other
     ;; C-hostile character means the clause is required (§3)
     (define (c-name-defaultable? s)
       (let loop ([i 0])
         (or (= i (string-length s))
             (let ([b (char->integer (string-ref s i))])
               (and (or (and (>= b 97) (<= b 122))    ;; a-z
                        (and (>= b 65) (<= b 90))     ;; A-Z
                        (and (>= b 48) (<= b 57))     ;; 0-9
                        (= b 95) (= b 45))            ;; _ -
                    (loop (add1 i)))))))
     ;; clause parse -> (vector c-name gift consumes?)
     (define (parse-foreign-clauses name cs)
       (let loop ([cs cs] [c-name #f] [gift #f] [consumes #f])
         (cond
           [(null? cs) (vector c-name gift consumes)]
           [(and (eq? (car cs) '#:c-name) (pair? (cdr cs)) (string? (cadr cs)))
            (loop (cddr cs) (cadr cs) gift consumes)]
           [(and (eq? (car cs) '#:gift) (pair? (cdr cs)) (string? (cadr cs)))
            (loop (cddr cs) c-name (cadr cs) consumes)]
           [(eq? (car cs) '#:consumes)
            (loop (cdr cs) c-name gift #t)]
           [else (type-error "foreign ~a: malformed clause ~a" (nm name) (car cs))])))
     (define (check-foreign-decl d)
       (unless (and (pair? d) (eq? (car d) ':)
                    (pair? (cdr d)) (symbol? (cadr d))
                    (pair? (cddr d)))
         (type-error "foreign: malformed declaration ~a" d))
       (define name (cadr d))
       (define t (caddr d))
       (define cv (parse-foreign-clauses name (cdddr d)))
       (when (hash-has-key? adts name)
         (type-error "~a is defined as both a type and a value" (nm name)))
       (when (or (hash-has-key? top name) (set-member? defined-names name))
         (type-error "foreign ~a: duplicate declaration" (nm name)))
       (unless (and (pair? t) (eq? (car t) '->) (pair? (cdr t)))
         (type-error "foreign ~a: declared type must be a concrete (-> ...) arrow, got ~a"
                     (nm name) (ty t)))
       (define tail (cdr t))
       (define args (reverse (cdr (reverse tail))))
       (define ret (car (reverse tail)))
       (when (> (length args) 6)
         (type-error "foreign ~a: arity ~a exceeds the FFI limit of 6" (nm name) (length args)))
       (for-each (λ (a)
                   (unless (ffi-arg-ok? a)
                     (type-error "foreign ~a: argument type ~a is not marshallable"
                                 (nm name) (ty a))))
                 args)
       (unless (ffi-ret-ok? ret)
         (type-error "foreign ~a: result type ~a is not marshallable" (nm name) (ty ret)))
       (when (vector-ref cv 1)   ;; #:gift
         (unless (or (eq? ret 'Str)
                     (and (nullable? ret) (eq? (cadr ret) 'Str)))
           (type-error "foreign ~a: #:gift requires a Str or (Nullable Str) result" (nm name))))
       (when (vector-ref cv 2)   ;; #:consumes
         (unless (= (length (filter ftype? args)) 1)
           (type-error "foreign ~a: #:consumes requires exactly one foreign-handle argument"
                       (nm name))))
       (unless (vector-ref cv 0)
         (unless (c-name-defaultable? (symbol->string (nm name)))
           (type-error "foreign ~a: needs #:c-name (the name has no default C spelling)"
                       (nm name))))
       ;; the declared type, as the checker sees it
       (hash-set! top name
                  (append (cons '-> (map (λ (a) (if (memq a ffi-widths) 'Int a)) args))
                          (list (cond [(nullable? ret) '_]
                                      [(memq ret ffi-widths) 'Int]
                                      [else ret])))))
     (for-each-form forms
      (λ (f)
       (when (and (pair? f) (eq? (car f) 'foreign))
         (unless (and (pair? (cdr f)) (string? (cadr f)))
           (type-error "foreign: expected a library path string in ~a" f))
         ;; module resolution may have inserted the resolved path
         (define ds0 (if (and (pair? (cddr f)) (string? (caddr f)))
                         (cdddr f)
                         (cddr f)))
         ;; form-level clauses: #:include is the header cross-check
         ;; (desugar runs it); #:static is a designed seam, not v1
         (define ds
           (let strip ([r ds0])
             (cond
               [(and (pair? r) (eq? (car r) '#:include)
                     (pair? (cdr r)) (string? (cadr r)))
                (strip (cddr r))]
               [(and (pair? r) (eq? (car r) '#:static))
                (type-error "foreign ~a: #:static linking is a designed seam, not yet implemented (docs/FFI.md §10)" (cadr f))]
               [else r])))
         (when (null? ds)
           (type-error "foreign ~a: expected at least one (: name type) declaration" (cadr f)))
         (for-each check-foreign-decl ds))))
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
         ;; against an s-expression type, a template's binders take
         ;; their types from the productions it matches (docs/GRAMMARS.md §5)
         [`(quasiquote ,tmpl)
          (if (sexpy? scrut-t)
              (or (align tmpl (leaf->shape scrut-t) '()) (qq-pattern-binds tmpl 1))
              (qq-pattern-binds tmpl 1))]
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
         ;; a type-test narrows, when the scrutinee is typed
         [`(? ,pred ,p)
          (if (sexpy? scrut-t)
              (pattern-bindings p (or (pred-base pred) scrut-t))
              (pattern-bindings p '_))]
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

     ;; --- templates against shapes (docs/GRAMMARS.md §5) ---
     ;; align: the bindings a quasiquote pattern q (depth 1) makes
     ;; against the shape or type s, or #f when no value of s can match
     ;; it. vs: the grammars being expanded for this q (left
     ;; recursion stops there). Mirrors puffincc-src/types.puf.
     (define (untyped-binds q) (qq-pattern-binds q 1))
     (define (align q s vs)
       (cond
         [(and (pair? q) (eq? (car q) 'unquote) (pair? (cdr q)) (null? (cddr q)))
          (pattern-bindings (cadr q) (shape->type s))]
         [(sexp-type? s) (align q (cadr s) vs)]
         [(gram-name s)
          (if (member s vs)
              #f
              (let ([alts (filter-map (λ (p) (align q p (cons s vs))) (gram-prods s))])
                (if (null? alts) #f (merge-binds alts))))]
         [(or (eq? s '_) (tyvar? s)) (untyped-binds q)]
         [(null? q)
          (cond [(slist? s) (if (andmap star? (cdr s)) '() #f)]
                [(and (pair? s) (eq? (car s) 'List)) '()]
                [else #f])]
         [(pair? q)
          (cond [(slist? s) (align-list q (cdr s) vs)]
                [(and (pair? s) (memq (car s) '(List Pairof))) (untyped-binds q)]
                [else #f])]
         [else (if (lit-in? q s) '() #f)]))
     ;; the alternatives' bindings, joined name by name
     (define (merge-binds alts)
       (map (λ (b)
              (cons (car b)
                    (foldl (λ (alt acc)
                             (let ([hit (assoc (car b) alt)])
                               (if hit (type-join acc (cdr hit)) '_)))
                           (cdr b) (cdr alts))))
            (car alts)))
     (define (concat-binds bss)
       (if (andmap (λ (b) (and b #t)) bss) (foldr append '() bss) #f))
     ;; a pattern list: prefix, an ellipsis element and what follows it,
     ;; or a dotted ,tail
     (define (align-list q fs vs)
       (match-define (list pre ell post tail) (split-qpat q))
       (match-define (list pf sf qf) (split-star fs))
       (define lpre (length pre))
       (define lpf (length pf))
       (define lqf (length qf))
       (define (al p f) (align p f vs))
       (cond
         [(eq? tail 'bad) (untyped-binds q)]
         [tail
          (cond [(and (not sf) (>= (length fs) lpre))
                 (concat-binds
                  (append (map al pre (take fs lpre))
                          (list (pattern-bindings tail (list '#%sexp (cons '#%list (drop fs lpre)))))))]
                [(and sf (<= lpre lpf))
                 (concat-binds
                  (append (map al pre (take pf lpre))
                          (list (pattern-bindings tail (list '#%sexp (cons '#%list (drop fs lpre)))))))]
                [else (untyped-binds q)])]
         [(not ell)
          (cond [(not sf)
                 (if (= lpre (length fs))
                     (concat-binds (map al pre fs))
                     #f)]
                [(>= lpre (+ lpf lqf))
                 (concat-binds
                  (append (map al (take pre lpf) pf)
                          (map (λ (p) (al p sf)) (take (drop pre lpf) (- lpre (+ lpf lqf))))
                          (map al (drop pre (- lpre lqf)) qf)))]
                [else #f])]
         [(not (list? post)) (untyped-binds q)]
         [(member '... post) (untyped-binds q)]
         [else
          (define lpost (length post))
          (cond
            [(not sf)
             (if (<= (+ lpre lpost) (length fs))
                 (let ([fixed (concat-binds
                               (append (map al pre (take fs lpre))
                                       (map al post (drop fs (- (length fs) lpost)))))]
                       [middle (take (drop fs lpre) (- (length fs) (+ lpre lpost)))])
                   (and fixed
                        (let ([eb (ell-binds ell middle vs #t)])
                          (and eb (append fixed eb)))))
                 #f)]
            [else
             ;; the prefix runs into the star, the suffix back from the
             ;; end; the ellipsis element meets whatever fixed elements
             ;; neither reaches, and the star
             (define pre-f (append (take pf (min lpre lpf))
                                   (map (λ (_) sf) (range 0 (max 0 (- lpre lpf))))))
             (define post-f (append (map (λ (_) sf) (range 0 (max 0 (- lpost lqf))))
                                    (drop qf (max 0 (- lqf lpost)))))
             (define fixed (concat-binds (append (map al pre pre-f) (map al post post-f))))
             (define cands (append (drop pf (min lpre lpf))
                                   (cons sf (take qf (max 0 (- lqf lpost))))))
             (and fixed
                  (let ([eb (ell-binds ell cands vs #f)])
                    (and eb (append fixed eb))))])]))
     ;; the ellipsis element's binders, each a (List τ) of what it meets
     ;; in cands; all? says every candidate is an element it must match
     (define (ell-binds ell cands vs all?)
       (define alts (map (λ (c) (align ell c vs)) cands))
       (define ok (filter (λ (b) (and b #t)) alts))
       (cond
         [(and all? (not (andmap (λ (b) (and b #t)) alts))) #f]
         [(null? ok)
          (if (and (not all?) (pair? cands))
              #f
              (map (λ (b) (cons (car b) (list 'List '_))) (untyped-binds ell)))]
         [else (map (λ (b) (cons (car b) (list 'List (cdr b)))) (merge-binds ok))]))
     ;; exhaustiveness over grammars and define-types (docs/GRAMMARS.md
     ;; §5): when the scrutinee's type is a KNOWN grammar (a `_`
     ;; scrutinee is exempt -- the gradual guarantee), a production no
     ;; clause can match is missing. Conservative in the
     ;; no-false-warnings direction: guards are ignored, a clause that
     ;; matches part of a production covers it, and a pattern the
     ;; checker cannot analyze (cons, list, vector, an unknown
     ;; predicate, a binder, _) covers everything. A define-type's
     ;; report names its constructors; a grammar's spells the
     ;; productions. A WARNING on stderr (strict-exhaustiveness?
     ;; promotes it to an error).
     (define (check-match-exhaustiveness st clauses)
       (define name (gram-name st))
       (when name
         (define gi (hash-ref grammar-table name))
         (define prods (gram-prods st))
         (define covered
           (for/fold ([cov (set)]) ([cl clauses])
             (define p (match cl
                         [`[,p0 #:when ,_ ,_ ...] p0]
                         [`[,p0 ,_ ...] p0]))
             (set-union cov (list->set (pattern-cover p prods ctors)))))
         (define missing (filter (λ (i) (not (set-member? covered i))) (covers-all prods)))
         (when (pair? missing)
           (define msg (format "match on ~a is not exhaustive: missing ~a"
                               (nm name)
                               (string-join
                                (map (λ (i)
                                       (if (eq? (g-kind gi) 'type)
                                           (symbol->string (nm (list-ref (g-ctors gi) i)))
                                           (render-prod (list-ref (g-prods gi) i))))
                                     missing)
                                ", ")))
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
         ;; quoted data and templates have the exact type of their
         ;; shape (docs/GRAMMARS.md §4); () stays (List _)
         [`(quote ()) '(List _)]
         [`(quote ,d) (let ([s (datum->shape d)]) (if s (list '#%sexp s) '_))]
         [`(quasiquote ,q) (let ([s (qq->shape q env)]) (if s (list '#%sexp s) '_))]
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

     ;; a template at depth 1 as a shape, or #f when it has none (two
     ;; splices in one list, a dotted non-list tail, nested
     ;; quasiquote). Every hole is synthesized either way.
     (define (qq->shape q env)
       (match q
         [(list 'unquote e) (leaf->shape (synth e env))]
         [(list 'quasiquote _) #f]
         ['() (list '#%list)]
         [(? pair?) (qq-list->shape q env)]
         [d (list '#%lit d)]))
     ;; a list-typed tail or splice as shape elements, or #f
     (define (tail-elems t)
       (cond [(and (pair? t) (eq? (car t) 'List)) (list (list '#%star (leaf->shape (cadr t))))]
             [(and (sexp-type? t) (slist? (cadr t))) (cdr (cadr t))]
             [(eq? t '_) (list (list '#%star '_))]
             [else #f]))
     (define (count-stars es) (length (filter star? es)))
     (define (qq-list->shape q env)
       (let loop ([q q] [acc '()] [stars 0] [ok #t])
         (match q
           ['() (if (and ok (<= stars 1)) (cons '#%list (reverse acc)) #f)]
           ;; a dotted tail: `(a . ,e)
           [(list 'unquote e)
            (define els (tail-elems (synth e env)))
            (if (and ok els (<= (+ stars (count-stars els)) 1))
                (cons '#%list (append (reverse acc) els))
                #f)]
           [(list 'quasiquote _) #f]
           [(cons (list 'unquote-splicing e) rest)
            (define els (tail-elems (synth e env)))
            (if els
                (loop rest (append (reverse els) acc) (+ stars (count-stars els)) ok)
                (loop rest acc stars #f))]
           [(cons a rest)
            (define s (qq->shape a env))
            (loop rest (cons (or s '_) acc) stars ok)]
           [_ (loop '() acc stars #f)])))

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
       ;; FFI forms were validated above (plain test, not a match
       ;; clause: gensym budget)
       (if (and (pair? f) (memq (car f) '(foreign define-foreign-type #%extern-foreign-type)))
           (void)
       (match f
         [`(define-type ,_ ,_ ...) (void)]
         [`(define-grammar ,_ ,_ ...) (void)]
         [`(define-type-alias ,_ ,_) (void)]
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
         [e (synth e '())]))))
     ;; typed interfaces (separate compilation): deposit the final
     ;; top-level environment -- declared, derived, and synthesized
     ;; types alike -- for the .pufi writer. Inert when unset.
     (when (typecheck-top-sink)
       (set-box! (typecheck-top-sink)
                 (for/hash ([(k v) (in-hash top)]) (values k v))))
     p]))
