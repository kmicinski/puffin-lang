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
  (define (compile-pattern pat subject success fail-e bound)
    (match pat
      ['_ success]
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
            ,fail-e)]))

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
      [(list '? _ p) (pattern-vars p)]))

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

  ;; Top-level definitions shadow stdlib primitives; colliding names
  ;; are renamed here, once, for the whole program.
  (define-values (top-bound top-forms)
    (match p
      [`(program ,forms ...)
       (define-values (b _)
         (bind* (hash)
                (filter-map (λ (form)
                              (match form
                                [`(define (,f ,_ ...) ,_ ...) f]
                                [`(define (,f . ,_) ,_ ...) f]
                                [`(define ,(? symbol? x) ,_) x]
                                [_ #f]))
                            forms)))
       (values b forms)]))
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
  `(program ,@(map per-form top-forms)))

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

(define (collect-globals p)
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
       (if (and (hash-has-key? name->idx x) (not (set-member? shadowed x)))
           `(global-ref ,(hash-ref name->idx x))
           x)]
      [`(if ,e0 ,e1 ,e2) `(if ,(walk e0 shadowed) ,(walk e1 shadowed) ,(walk e2 shadowed))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       `(let ([_ (while ,(walk e-g shadowed) ,(walk e-b shadowed))]) ,(walk e-r shadowed))]
      [`(let ([_ ,e]) ,e-b)
       `(let ([_ ,(walk e shadowed)]) ,(walk e-b shadowed))]
      [`(let ([,x ,e]) ,e-b)
       `(let ([,x ,(walk e shadowed)]) ,(walk e-b (set-add shadowed x)))]
      [`(set! ,x ,e)
       (if (and (hash-has-key? name->idx x) (not (set-member? shadowed x)))
           `(global-set! ,(hash-ref name->idx x) ,(walk e shadowed))
           `(set! ,x ,(walk e shadowed)))]
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
     (define name-set
       (foldl (lambda (name acc) (hash-set acc name `(fun-ref ,name)))
              (hash)
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
  (define emitted-defines (set))
  (define (emit-define! defn) (set! emitted-defines (set-add emitted-defines defn)))
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
     `(program ,n-globals ,@(map per-defn definitions) ,@(set->list emitted-defines))]))

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
  ;; convert a list of expressions left-to-right, collecting atoms
  (define (convert-args es k)
    (match es
      ['() (k '())]
      [`(,hd . ,tl)
       (convert-expr hd (λ (a) (convert-args tl (λ (as) (k (cons a as))))))]))
  (define (convert-expr e k) (prov (convert-expr-core e k) e))
  (define (convert-expr-core e k)
    (match e
      [(? literal?) (k e)]
      [(? symbol? x) (k x)]
      ['(read)
       (let ([x (gensym 'read)])
         (prov `(let ([,x (read)]) ,(k x)) e))]
      [`(string-lit ,s)
       (let ([x (gensym 'str)])
         (prov `(let ([,x (string-lit ,s)]) ,(k x)) e))]
      [`(fun-ref ,f)
       (define x (gensym 'funref))
       (prov `(let ([,x (fun-ref ,f)]) ,(k x)) e)]
      [`(global-ref ,i)
       (define x (gensym 'glob))
       (prov `(let ([,x (global-ref ,i)]) ,(k x)) e)]
      [`(global-set! ,i ,e+)
       (convert-expr e+ (λ (a)
                          (prov `(let ([_ (global-set! ,i ,a)]) ,(k '(void))) e)))]
      ;; fused compare-and-branch (>= -O1): when the test is one
      ;; comparison, keep it in the if -- never materialize the
      ;; boolean (explicate-control turns it into a cmp+jcc tail)
      [`(if (,(? cmp? op) ,ea ,eb) ,e1 ,e2)
       #:when (>= (optimize-level) 1)
       (convert-args
        (list ea eb)
        (λ (as)
          `(if (,op ,@as) ,(convert-expr e1 k) ,(convert-expr e2 k))))]
      [`(if ,e0 ,e1 ,e2)
       (convert-expr
        e0
        (λ (a-g)
          `(if ,a-g ,(convert-expr e1 k) ,(convert-expr e2 k))))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       `(let ([_ (while ,(convert-expr e-g (λ (a) a)) ,(convert-expr e-b (λ (a) a)))])
          ,(convert-expr e-r k))]
      [`(unsafe-vector-ref ,e0 ,i)
       (convert-expr e0 (λ (a0)
                          (define x (gensym 'uref))
                          (prov `(let ([,x (unsafe-vector-ref ,a0 ,i)]) ,(k x)) e)))]
      [`(unsafe-vector-set! ,e0 ,i ,e1)
       (convert-expr e0
                     (λ (a0)
                       (convert-expr e1 (λ (a1)
                                          (prov `(let ([_ (unsafe-vector-set! ,a0 ,i ,a1)]) ,(k '(void))) e)))))]
      ;; direct calls (>= -O1): a (fun-ref f) rator stays in place --
      ;; no materialization, the backends emit a direct call/jump
      [`(app (fun-ref ,f) ,es ...)
       #:when (>= (optimize-level) 1)
       (convert-args es (λ (as)
                          (define x (gensym 'app))
                          (prov `(let ([,x (app (fun-ref ,f) ,@as)]) ,(k x)) e)))]
      [`(papp ,n (fun-ref ,f) ,es ...)
       #:when (>= (optimize-level) 1)
       (convert-args es (λ (as)
                          (define x (gensym 'app))
                          (prov `(let ([,x (papp ,n (fun-ref ,f) ,@as)]) ,(k x)) e)))]
      [`(app ,es ...)
       (convert-args es (λ (as)
                          (define x (gensym 'app))
                          (prov `(let ([,x (app ,@as)]) ,(k x)) e)))]
      [`(papp ,n ,es ...)
       (convert-args es (λ (as)
                          (define x (gensym 'app))
                          (prov `(let ([,x (papp ,n ,@as)]) ,(k x)) e)))]
      [`(,(? prim? op) ,es ...)
       (convert-args es (λ (as)
                          (define x (gensym op))
                          (prov `(let ([,x (,op ,@as)]) ,(k x)) e)))]
      ;; let (place after the special _ forms)
      [`(let ([,x ,e0]) ,e-b)
       (convert-expr e0 (lambda (atom)
                          (prov `(let ([,x ,atom]) ,(convert-expr e-b k)) e)))]))
  (define (per-defn definition)
    (match definition
      [`(define (,fname ,formals ...) ,e-body)
       `(define (,fname ,@formals) ,(convert-expr e-body (lambda (x) x)))]))
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
           (hash-keys blocks)))
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
       (for/fold ([acc (hash)]) ([(l t) (in-hash moved)])
         (hash-set acc l (rewrite t)))]))
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
