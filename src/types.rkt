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
;;   (-> t ... t)
;;   (Name t ...)          ADT instances
;;   a b c ...             type variables (lowercase first char)
;;
;; The prim-type table lives here beside the checker and is asserted
;; against the manifest's arities at load time (the manifest stays the
;; single source of truth for existence/arity; the `type` field folds
;; into prim-spec once the system settles).

(provide typecheck-program type-error?)

(require "stdlib.rkt" "irs.rkt")

(struct exn:type-error exn:fail ())
(define (type-error? e) (exn:type-error? e))
(define (type-error fmt . args)
  (raise (exn:type-error (string-append "typecheck: " (apply format fmt args))
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

;; ---------------------------------------------------------------------
;; the ADT registry: collected from define-type forms (pass 1 heads,
;; pass 2 bodies -- all of a module's types are mutually recursive)
;; ---------------------------------------------------------------------

(struct adt (name params ctors) #:transparent)         ;; ctors: name -> field types
(struct ctor-info (owner params fields) #:transparent) ;; result: (owner params...)

(define (collect-adts forms)
  (define adts (make-hasheq))   ;; type name -> adt
  (define ctors (make-hasheq))  ;; ctor name -> ctor-info
  ;; pass 1: heads
  (for ([f forms])
    (match f
      [`(define-type ,head ,_ ...)
       (define-values (n ps)
         (match head
           [`(,n ,ps ...) (values n ps)]
           [n (values n '())]))
       (when (hash-has-key? adts n)
         (type-error "type ~a defined twice" n))
       (hash-set! adts n (adt n ps (make-hasheq)))]
      [_ (void)]))
  ;; pass 2: constructor signatures (any type in the program may be
  ;; referenced -- the implicit recursive loop)
  (for ([f forms])
    (match f
      [`(define-type ,head ,cs ...)
       (define n (match head [`(,n ,_ ...) n] [n n]))
       (define a (hash-ref adts n))
       (for ([c cs])
         (match c
           [`(,cn ,fts ...)
            (when (hash-has-key? ctors cn)
              (type-error "constructor ~a defined twice" cn))
            (for ([ft fts]) (check-type-wf ft (adt-params a) adts))
            (hash-set! (adt-ctors a) cn fts)
            (hash-set! ctors cn (ctor-info n (adt-params a) fts))]))]
      [_ (void)]))
  (values adts ctors))

;; well-formedness: names resolve, arities match
(define (check-type-wf t params adts)
  (match t
    [(? symbol? s)
     (unless (or (set-member? base-types s) (memq s params) (tyvar? s)
                 (and (hash-has-key? adts s)
                      (null? (adt-params (hash-ref adts s)))))
       (when (and (hash-has-key? adts s)
                  (pair? (adt-params (hash-ref adts s))))
         (type-error "type ~a expects ~a parameters"
                     s (length (adt-params (hash-ref adts s))))))]
    [`(,(or 'Pairof 'Hash) ,a ,b)
     (check-type-wf a params adts) (check-type-wf b params adts)]
    [`(,(or 'List 'Vec 'Set) ,a) (check-type-wf a params adts)]
    [`(-> ,ts ...) (for ([s ts]) (check-type-wf s params adts))]
    [`(,(? symbol? n) ,args ...)
     (cond [(hash-has-key? adts n)
            (unless (= (length args) (length (adt-params (hash-ref adts n))))
              (type-error "type ~a expects ~a parameters, got ~a"
                          n (length (adt-params (hash-ref adts n))) (length args)))
            (for ([s args]) (check-type-wf s params adts))]
           [else (type-error "unknown type constructor ~a in ~a" n t)])]
    [_ (type-error "malformed type: ~a" t)]))

;; ---------------------------------------------------------------------
;; substitution & consistency
;; ---------------------------------------------------------------------

(define (subst t env)   ;; env: hasheq tyvar -> type
  (match t
    [(? symbol? s) (hash-ref env s s)]
    [`(,h ,ts ...) `(,h ,@(map (λ (s) (subst s env)) ts))]
    [_ t]))

;; one-step unfold of (List a) as nil-or-pair for consistency against
;; Pairof (docs/TYPES.md §4: equi-recursive List)
(define (consistent? t1 t2)
  (match* (t1 t2)
    [('_ _) #t]
    [(_ '_) #t]
    [((? tyvar?) _) #t]      ;; an uninstantiated variable fits anything
    [(_ (? tyvar?)) #t]
    [((? symbol? a) (? symbol? b)) (eq? a b)]
    [(`(List ,a) `(Pairof ,x ,y))
     (and (consistent? x a) (consistent? y `(List ,a)))]
    [(`(Pairof ,x ,y) `(List ,a))
     (and (consistent? x a) (consistent? y `(List ,a)))]
    [(`(,h1 ,as ...) `(,h2 ,bs ...))
     (and (eq? h1 h2) (= (length as) (length bs))
          (andmap consistent? as bs))]
    [(_ _) #f]))

;; greedy instantiation: walk formal against actual binding tyvars;
;; first concrete binding wins, `_` never binds
(define (instantiate! formal actual env)
  (match formal
    [(? tyvar? v)
     (unless (or (hash-has-key? env v) (eq? actual '_))
       (hash-set! env v actual))]
    [`(List ,a)
     (match actual
       [`(List ,x) (instantiate! a x env)]
       [`(Pairof ,x ,_) (instantiate! a x env)]
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
;; prim types (asserted against the manifest at load)
;; ---------------------------------------------------------------------

(define prim-types
  (hasheq
   '+ '(-> Int Int Int) '- '(-> Int Int Int) '* '(-> Int Int Int)
   'quotient '(-> Int Int Int) 'remainder '(-> Int Int Int) 'modulo '(-> Int Int Int)
   'bitwise-and '(-> Int Int Int) 'bitwise-ior '(-> Int Int Int)
   'bitwise-xor '(-> Int Int Int) 'arithmetic-shift '(-> Int Int Int)
   '< '(-> Int Int Bool) '<= '(-> Int Int Bool) '> '(-> Int Int Bool) '>= '(-> Int Int Bool)
   'eq? '(-> a b Bool) 'equal? '(-> a b Bool) 'not '(-> a Bool)
   'cons '(-> a b (Pairof a b)) 'car '(-> (Pairof a b) a) 'cdr '(-> (Pairof a b) b)
   'pair? '(-> a Bool) 'null? '(-> a Bool)
   'make-vector '(-> Int (Vec _)) 'vector-ref '(-> (Vec a) Int a)
   'vector-set! '(-> (Vec a) Int a Void) 'vector-length '(-> (Vec a) Int)
   'vector? '(-> a Bool)
   'string? '(-> a Bool) 'string-length '(-> Str Int)
   'string-append '(-> Str Str Str) 'string=? '(-> Str Str Bool)
   'string<? '(-> Str Str Bool) 'substring '(-> Str Int Int Str)
   'string-byte '(-> Str Int Int)
   'symbol->string '(-> Sym Str) 'string->symbol '(-> Str Sym)
   'number->string '(-> Int Str) 'string->number '(-> Str _)
   'value->string '(-> a Str)
   'hash-set '(-> (Hash k v) k v (Hash k v)) 'hash-remove '(-> (Hash k v) k (Hash k v))
   'hash-ref '(-> (Hash k v) k v) 'hash-ref/default '(-> (Hash k v) k v v)
   'hash-has-key? '(-> (Hash k v) k Bool) 'hash-count '(-> (Hash k v) Int)
   'hash-keys '(-> (Hash k v) (List k)) 'hash? '(-> a Bool)
   'hash-set! '(-> (Hash k v) k v Void) 'hash-remove! '(-> (Hash k v) k Void)
   'set-add '(-> (Set a) a (Set a)) 'set-remove '(-> (Set a) a (Set a))
   'set-member? '(-> (Set a) a Bool) 'set-count '(-> (Set a) Int)
   'set->list '(-> (Set a) (List a)) 'set? '(-> a Bool)
   'set-add! '(-> (Set a) a Void) 'set-remove! '(-> (Set a) a Void)
   'fixnum? '(-> a Bool) 'boolean? '(-> a Bool) 'symbol? '(-> a Bool)
   'void? '(-> a Bool) 'procedure? '(-> a Bool)
   'println '(-> a Void) 'display '(-> a Void) 'newline '(-> Void)
   'error '(-> a _) 'read '(-> Int) 'read-all '(-> Str)
   'gensym '(-> Sym Sym)
   'read-file '(-> Str Str) 'write-file '(-> Str Str Void)
   'file-exists? '(-> Str Bool) 'command-line-args '(-> (List Str))
   'system '(-> Str Int)))

;; manifest agreement: every typed prim exists with the arity its type says
(for ([(p t) (in-hash prim-types)])
  (match t
    [`(-> ,args ... ,_)
     (when (and (stdlib-prim? p) (surface-stdlib-prim? p))
       (define spec-arity (prim-arity p))
       (unless (= spec-arity (length args))
         (error 'types "prim-type arity mismatch for ~a: manifest ~a, table ~a"
                p spec-arity (length args))))]))

(define (prim-type-of op)
  (hash-ref prim-types op
            (λ ()
              ;; untyped prim: (-> _ ... _) from the manifest arity
              (if (prim? op)
                  `(-> ,@(for/list ([_ (in-range (prim-arity op))]) '_) _)
                  '_))))

;; ---------------------------------------------------------------------
;; the checker
;; ---------------------------------------------------------------------

(define (typecheck-program p)
  (match p
    [`(program ,forms ...)
     (define-values (adts ctors) (collect-adts forms))

     ;; the top-level environment: declared types, annotated defines,
     ;; constructors; everything else _
     (define top (make-hasheq))
     (define (formal-type f) (match f [`(,_ : ,t) t] [_ '_]))
     (define (formal-name f) (match f [`(,x : ,_) x] [x x]))
     (for ([f forms])
       (match f
         [`(: ,n ,t)
          (check-type-wf t '() adts)
          (hash-set! top n t)]
         [`(define-type ,_ ,cs ...)
          (for ([c cs])
            (match c
              [`(,cn ,fts ...)
               (define info (hash-ref ctors cn))
               (define res `(,(ctor-info-owner info) ,@(ctor-info-params info)))
               (define res* (if (null? (ctor-info-params info)) (ctor-info-owner info) res))
               (hash-set! top cn
                          (if (null? fts) res* `(-> ,@fts ,res*)))]))]
         [_ (void)]))
     (for ([f forms])
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
         [_ (void)]))

     ;; instantiate a possibly-polymorphic type at a use site
     (define (instantiate-fresh t)
       ;; tyvars stay as-is; application sites bind them greedily
       t)

     (define (lookup env x)
       (cond [(assq x env) => cdr]
             [(hash-ref top x #f)]
             [(prim? x) (prim-type-of x)]
             [else '_]))   ;; prelude names, unknowns: dynamic

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
     (define (check-app ft arg-ts where)
       (match ft
         ['_ '_]
         [(? tyvar?) '_]
         [`(-> ,formals ... ,res)
          (unless (= (length formals) (length arg-ts))
            (type-error "~a expects ~a arguments, got ~a" where (length formals) (length arg-ts)))
          (define tenv (make-hasheq))
          (for ([f formals] [a arg-ts]) (instantiate! f a tenv))
          (define conflicted (mutable-seteq))
          (for ([f formals] [a arg-ts])
            (define f* (subst f tenv))
            (unless (consistent? a f*)
              (if (consistent? a (blank-tyvars f))
                  ;; only the inferred binding conflicts: weaken it
                  (for ([v (in-set (tyvars-of f))]) (set-add! conflicted v))
                  (type-error "~a: argument has type ~a, expected ~a" where a f*))))
          (for ([v (in-set conflicted)]) (hash-set! tenv v '_))
          (subst res tenv)]
         [_ (type-error "~a: applying a non-function of type ~a" where ft)]))

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
                                s (length (ctor-info-fields info))))
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
          (define a (match scrut-t [`(Vec ,a) a] [_ '_]))
          (append-map (λ (p) (pattern-bindings p a)) ps)]
         [`(? ,_ ,p) (pattern-bindings p '_)]
         [`(,(? (λ (s) (hash-has-key? ctors s)) cn) ,ps ...)
          (define info (hash-ref ctors cn))
          (unless (= (length ps) (length (ctor-info-fields info)))
            (type-error "constructor ~a expects ~a fields, got ~a in pattern"
                        cn (length (ctor-info-fields info)) (length ps)))
          ;; field types instantiated from the scrutinee's type args
          (define tenv (make-hasheq))
          (match scrut-t
            [`(,n ,args ...) #:when (eq? n (ctor-info-owner info))
             (for ([p (ctor-info-params info)] [a args]) (hash-set! tenv p a))]
            [_ (void)])
          (append-map (λ (p ft) (pattern-bindings p (subst ft tenv)))
                      ps (ctor-info-fields info))]
         [_ '()]))

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
            (type-error "(ann ...) claims ~a but expression has type ~a" t et))
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
          (for/fold ([t '_] [first #t] #:result t)
                    ([cl clauses])
            (define-values (pat guard body)
              (match cl
                [`[,p #:when ,g ,body ...] (values p g body)]
                [`[,p ,body ...] (values p #f body)]))
            (define env+ (append (pattern-bindings pat st) env))
            (when guard (synth guard env+))
            (define bt (synth-body body env+))
            (values (if first bt (type-join t bt)) #f))]
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
            (type-error "lambda body has type ~a, declared ~a" bt rt))
          `(-> ,@fts ,(if (eq? rt '_) bt rt))]
         [`(,(or 'lambda 'λ) ,_ ,_ ...) '_]  ;; variadic: dynamic in v1
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
            (type-error "(set! ~a ...): value has type ~a, variable is ~a" x et xt))
          'Void]
         [`(and ,es ...) (for ([s es]) (synth s env)) '_]
         [`(or ,es ...) (for ([s es]) (synth s env)) '_]
         [`(list ,es ...)
          (define t (for/fold ([t '_]) ([s es]) (type-join t (synth s env))))
          `(List ,t)]
         [`(vector ,es ...)
          (define t (for/fold ([t '_]) ([s es]) (type-join t (synth s env))))
          `(Vec ,t)]
         [`(hash ,es ...) '(Hash _ _)]
         [`(set ,es ...) '(Set _)]
         [`(make-hash) '(Hash _ _)] [`(make-set) '(Set _)]
         ;; n-ary sugar the prim table types as binary
         [`(,(? (λ (op) (memq op '(+ - *))) op) ,es ...)
          (for ([s es])
            (define t (synth s env))
            (unless (consistent? t 'Int)
              (type-error "~a: argument has type ~a, expected Int" op t)))
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
         (type-error "~a is declared ~a but its value has type ~a" x t et)))
     (define (formal-type* f)
       (match f [`(,_ : ,t) (check-type-wf t '() adts) t] [_ '_]))
     (define (formal-name* f) (match f [`(,x : ,_) x] [x x]))

     ;; check every top-level form under `top`
     (for ([f forms])
       (match f
         [`(define-type ,_ ,_ ...) (void)]
         [`(: ,_ ,_) (void)]
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
            (type-error "~a: body has type ~a, declared ~a" g bt rt))]
         [`(define (,_ . ,_) ,_ ...) (void)]  ;; variadic: dynamic in v1
         [`(define ,(? symbol? x) ,e)
          (define et (synth e '()))
          (define dt (hash-ref top x '_))
          (unless (consistent? et dt)
            (type-error "~a is declared ~a but its value has type ~a" x dt et))
          (when (eq? dt '_) (hash-set! top x et))]
         [e (synth e '())]))
     p]))
