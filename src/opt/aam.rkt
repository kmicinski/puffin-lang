#lang racket
;; -O2: AAM-style abstract interpretation over the post-uniqueify
;; core IR, plus its optimization clients. See docs/OPTIMIZER.md §3/§6.
;;
;; The analyzer is an eval/apply CESK* abstract machine:
;;   - Eval states (E ℓ) evaluate the node at label ℓ; Apply/return
;;     states (A ℓ) propagate the finished value of ℓ to its
;;     continuations. Because value addresses are variable names
;;     (0-CFA; names are globally unique after uniqueify) and every
;;     expression's continuation address is its own label
;;     (monovariant, P4F-lite), states carry no environment at all:
;;     the whole state space is 2 × |labels|.
;;   - ONE global widened store, addr → ℘(abstract value), join =
;;     set union + widening. Physically it has three regions (they
;;     never share keys): R(ℓ) the value set of expression ℓ, K(ℓ)
;;     the continuation set awaiting ℓ, and σ(x) the value set of
;;     variable x. Store growth re-enqueues exactly the states that
;;     read the grown address (per-address dependency sets), so the
;;     fixpoint is incremental rather than round-based.
;;   - STAGED against the program: one syntax walk, done before
;;     iteration, compiles a transfer closure per label (the match
;;     on syntax is performed once); the worklist loop is pure
;;     lattice work. Continuations are explicit tagged values
;;     (retk/ifk/letk/begk/setk/wgk/wbk/prmk/appk/defk/topk/donek)
;;     dispatched by apply-kont, in the house eval/apply style.
;;
;; Abstract values (flat): 'top | (const k) | (clo ℓ) | a type tag
;; ('pair 'vector 'string 'symbol 'fixnum 'bool 'hash 'set 'void
;; 'nil). Sets are widened: two consts of one type collapse to the
;; type tag; sets past ~8 elements collapse to ⊤ (any closures they
;; contained are marked escaped).
;;
;; Soundness around ⊤: a closure that flows into a primitive's
;; arguments, into a ⊤-callee's arguments, or into a set collapsed
;; to ⊤ has ESCAPED — it may be called from anywhere with anything.
;; Escaped closures get their formals joined with ⊤ and their bodies
;; analyzed under a (topk) continuation (whose returned closures
;; escape in turn). This is what keeps the clients honest on
;; programs that store closures in hashes/lists (pl-cek, puffin-9).
;;
;; Termination: finite labels × finite addresses × flat finite
;; domain. A processed-states ceiling is the belt-and-braces
;; backstop: if tripped, analyze returns #f and the clients degrade
;; to the identity (correctness never depends on the analysis).

(provide label-program! analyze aam-clients aam-clients/stats
         (struct-out aam-facts))

(require "../irs.rkt" "../provenance.rkt")

(define widen-limit 8)
(define state-ceiling 200000)

;; ---------------------------------------------------------------
;; Literals and the abstract-value vocabulary
;; ---------------------------------------------------------------

;; the self-evaluating literals of the core IR that the const domain
;; tracks (strings are excluded: string-lits are heap values whose
;; identity matters to eq?, so they abstract to the 'string tag)
(define (literal-node? e)
  (match e
    [(? fixnum?) #t] [#t #t] [#f #t]
    ['(void) #t] ['(nil) #t]
    [`(quote ,(? symbol?)) #t]
    [_ #f]))

(define (const-type k)
  (cond [(fixnum? k) 'fixnum]
        [(boolean? k) 'bool]
        [(equal? k '(void)) 'void]
        [(equal? k '(nil)) 'nil]
        [else 'symbol]))          ;; (quote s)

;; An operator position is primitive iff the name is prim-shaped AND
;; the program never binds that name (post-uniqueify a binder that
;; shadows a prim keeps its source name, so this is decidable with
;; one syntactic pass). The pre-shrink sugar ops are included
;; defensively; post-shrink they cannot appear.
(define (prim-op? op bound)
  (and (symbol? op)
       (not (set-member? bound op))
       (or (prim? op) (memq op '(and or not <= > >=)))))

;; the prim transfer table: op → abstract result set. car/cdr and
;; friends yield ⊤ (no heap modeling in v1 — sound). error yields ∅
;; (it never returns). Anything unknown yields ⊤.
(define (prim-result op)
  (cond
    [(memq op '(+ - * quotient remainder modulo bitwise-and bitwise-ior
                bitwise-xor arithmetic-shift string-length string-byte
                vector-length hash-count set-count read))
     (set 'fixnum)]
    [(memq op '(eq? < <= > >= not equal? pair? null? fixnum? boolean?
                symbol? string? vector? hash? set? void? procedure?
                hash-has-key? set-member? string=? string<?))
     (set 'bool)]
    [(memq op '(cons)) (set 'pair)]
    [(memq op '(make-vector)) (set 'vector)]
    [(memq op '(string-append substring symbol->string number->string
                value->string read-all read-file))
     (set 'string)]
    [(memq op '(string->symbol gensym)) (set 'symbol)]
    [(memq op '(hash hash-set hash-remove make-hash)) (set 'hash)]
    [(memq op '(set set-add set-remove make-set)) (set 'set)]
    [(memq op '(println display newline vector-set! hash-set!
                hash-remove! set-add! set-remove! write-file))
     (set 'void)]
    [(memq op '(string->number)) (set 'fixnum 'bool)]
    [(memq op '(hash-keys set->list command-line-args)) (set 'pair 'nil)]
    [(memq op '(file-exists?)) (set 'bool)]
    [(memq op '(system)) (set 'fixnum)]
    [(memq op '(error)) (set)]
    [(memq op '(and or)) (set 'top)]
    [else (set 'top)]))

;; ---------------------------------------------------------------
;; Syntactic pre-passes (each one O(n) walk)
;; ---------------------------------------------------------------

;; every name the program binds: define names, let binders, formals
(define (program-binders p)
  (define names (mutable-seteq))
  (define (walk e)
    (match e
      [(? literal-node?) (void)]
      [`(string-lit ,_) (void)]
      ['(read) (void)]
      [(? symbol?) (void)]
      [`(while ,g ,b) (walk g) (walk b)]
      [`(let ([,x ,rhs]) ,body)
       (unless (eq? x '_) (set-add! names x))
       (walk rhs) (walk body)]
      [`(if ,a ,b ,c) (walk a) (walk b) (walk c)]
      [`(set! ,_ ,e0) (walk e0)]
      [`(lambda (,xs ...) ,body)
       (for ([x xs] #:unless (eq? x '#%rest)) (set-add! names x))
       (walk body)]
      [`(begin ,es ...) (for-each walk es)]
      [`(,op ,es ...) #:when (symbol? op) (for-each walk es)]
      [`(,es ...) (for-each walk es)]))
  (match p
    [`(program ,forms ...)
     (for ([f forms])
       (match f
         [`(define (,g ,_ ...) ,body) (set-add! names g) (walk body)]
         [`(define ,(? symbol? x) ,rhs) (set-add! names x) (walk rhs)]
         [e (walk e)]))])
  names)

;; every name that is ever a set! target
(define (assigned-vars p)
  (define names (mutable-seteq))
  (define (walk e)
    (match e
      [`(set! ,x ,e0) (set-add! names x) (walk e0)]
      [`(quote ,_) (void)]
      [`(string-lit ,_) (void)]
      [(? pair?) (for-each walk e)]
      [_ (void)]))
  (match p [`(program ,forms ...) (for-each walk forms)])
  names)

;; conservative "mentions": every symbol occurring anywhere in a form
(define (mentions-of form)
  (define acc (mutable-seteq))
  (define (walk v)
    (cond [(symbol? v) (set-add! acc v)]
          [(pair? v) (walk (car v)) (walk (cdr v))]
          [else (void)]))
  (match form
    [`(define (,_ ,_ ...) ,body) (walk body)]
    [`(define ,_ ,rhs) (walk rhs)]
    [e (walk e)])
  acc)

;; ---------------------------------------------------------------
;; Facts: what analyze hands to clients
;; ---------------------------------------------------------------

(struct aam-facts
  (nodes       ;; vector: label → node (preorder occurrence)
   node->label ;; eq-hasheq: node → label (compound nodes; atoms are positional)
   rvals       ;; hasheqv: label → abstract value set (every expression)
   varvals     ;; hasheq: var name → abstract value set
   read-vars   ;; seteq: names read in some reachable state
   clo-name    ;; hasheqv: closure label → its top-level binding name
   escaped     ;; seteqv: closure labels that escaped to ⊤
   n-labels    ;; total labels
   n-states)   ;; states processed by the fixpoint
  #:transparent)

;; ---------------------------------------------------------------
;; The machine builder: one syntax walk that labels every node and
;; compiles its transfer closure; returns the labeling plus a run!
;; thunk (the worklist fixpoint).
;; ---------------------------------------------------------------

(struct machine (node->label nodes run!))

(define (build-machine p)
  (match-define `(program ,forms ...) p)
  (define bound (program-binders p))

  ;; ---- labels -------------------------------------------------
  (define label-count 0)
  (define nodes-rev '())
  (define node->label (make-hasheq))
  (define (next-label! e)
    (define l label-count)
    (set! label-count (add1 label-count))
    (set! nodes-rev (cons e nodes-rev))
    (when (and (pair? e) (not (hash-has-key? node->label e)))
      (hash-set! node->label e l))
    l)

  ;; ---- the widened store and its dependency sets ---------------
  (define rvals (make-hasheqv))    ;; label → value set (R)
  (define kvals (make-hasheqv))    ;; label → kont set (K)
  (define vvals (make-hasheq))     ;; name  → value set (σ)
  (define rdeps (make-hasheqv))    ;; addr → states that read it
  (define kdeps (make-hasheqv))
  (define vdeps (make-hasheq))

  ;; ---- worklist over fixnum states: (E ℓ) = 2ℓ, (A ℓ) = 2ℓ+1 ----
  (define worklist '())
  (define queued (make-hasheqv))
  (define seen (make-hasheqv))
  (define current-state -1)
  (define (ev-state l) (* 2 l))
  (define (ret-state l) (add1 (* 2 l)))
  (define (enqueue! s)
    (unless (hash-ref queued s #f)
      (hash-set! queued s #t)
      (hash-set! seen s #t)
      (set! worklist (cons s worklist))))
  (define (enqueue-if-new! s)
    (unless (hash-ref seen s #f) (enqueue! s)))

  ;; ---- reads (register the running state as a dependent) --------
  (define (depend! deps key)
    (when (>= current-state 0)
      (set-add! (hash-ref! deps key (λ () (mutable-seteqv))) current-state)))
  (define (wake! deps key)
    (define s (hash-ref deps key #f))
    (when s (for ([st (in-set s)]) (enqueue! st))))
  (define (read-r l) (depend! rdeps l) (hash-ref rvals l (set)))
  (define (read-k l) (depend! kdeps l) (hash-ref kvals l (set)))
  (define (read-v x) (depend! vdeps x) (hash-ref vvals x (set)))

  ;; ---- per-label staged tables ----------------------------------
  (define transfers (make-hasheqv))  ;; label → thunk for (E ℓ)
  (define comps (make-hasheqv))      ;; label → vector of component labels
  (define prim-res (make-hasheqv))   ;; label → result set of a prim node
  (define clo-info (make-hasheqv))   ;; label → (cons formals body-label)
  (define clo-name (make-hasheqv))   ;; label → top-level binding name
  (define read-vars (mutable-seteq))
  (define escaped (mutable-seteqv))

  ;; ---- widening / joins ------------------------------------------
  ;; escape: this closure may now be called from anywhere with anything
  (define (escape! l)
    (unless (set-member? escaped l)
      (set-add! escaped l)
      (match-define (cons formals lb) (hash-ref clo-info l))
      (for ([x formals] #:unless (eq? x '#%rest))
        (join-v! x (set 'top)))
      (push-kont! lb '(topk))))
  (define (escape-clos! S)
    (for ([v (in-set S)])
      (match v [`(clo ,l) (escape! l)] [_ (void)])))

  (define (widen S)
    (cond
      [(set-member? S 'top) (escape-clos! S) (set 'top)]
      [else
       ;; collapse same-type consts to the type tag; drop consts
       ;; already subsumed by a present tag
       (define by-type (make-hasheq))
       (for ([v (in-set S)])
         (match v
           [`(const ,k) (hash-update! by-type (const-type k) add1 0)]
           [_ (void)]))
       (define S1
         (for/fold ([acc (set)]) ([v (in-set S)])
           (match v
             [`(const ,k)
              (define t (const-type k))
              (if (or (> (hash-ref by-type t 0) 1) (set-member? S t))
                  (set-add acc t)
                  (set-add acc v))]
             [_ (set-add acc v)])))
       (cond [(> (set-count S1) widen-limit) (escape-clos! S1) (set 'top)]
             [else S1])]))

  (define (join-r! l S)
    (unless (set-empty? S)
      (define old (hash-ref rvals l (set)))
      (define new (cond [(set-member? old 'top) (escape-clos! S) old]
                        [else (widen (set-union old S))]))
      (unless (equal? old new)
        (hash-set! rvals l new)
        (wake! rdeps l)
        (enqueue! (ret-state l)))))

  (define (join-v! x S)
    (unless (or (eq? x '_) (set-empty? S))
      (define old (hash-ref vvals x (set)))
      (define new (cond [(set-member? old 'top) (escape-clos! S) old]
                        [else (widen (set-union old S))]))
      (unless (equal? old new)
        (hash-set! vvals x new)
        (wake! vdeps x))))

  (define (join-k! l k)
    (define old (hash-ref kvals l (set)))
    (unless (set-member? old k)
      (hash-set! kvals l (set-add old k))
      (wake! kdeps l)
      (enqueue! (ret-state l))))

  ;; hand ℓ a continuation and make sure it gets evaluated
  (define (push-kont! l k)
    (join-k! l k)
    (enqueue-if-new! (ev-state l)))

  ;; ---- truthiness on value sets (only (const #f) is false) --------
  (define (may-true? S)
    (for/or ([v (in-set S)]) (not (equal? v '(const #f)))))
  (define (may-false? S)
    (for/or ([v (in-set S)])
      (match v ['top #t] ['bool #t] [`(const #f) #t] [_ #f])))

  ;; ---- staging: label a node and compile its (E ℓ) transfer -------
  ;; Traversal order (shared verbatim with the client rewrite walk):
  ;; self first, then children left-to-right in source order.
  (define (stage! e)
    (define l (next-label! e))
    (define (T! th) (hash-set! transfers l th))
    (match e
      [(? literal-node? k)
       (T! (λ () (join-r! l (set `(const ,k)))))]
      [`(string-lit ,_)
       (T! (λ () (join-r! l (set 'string))))]
      ['(read)
       (T! (λ () (join-r! l (set 'fixnum))))]
      [(? symbol? x)
       (T! (λ () (set-add! read-vars x) (join-r! l (read-v x))))]
      [`(while ,g ,b)
       (define lg (stage! g))
       (define lb (stage! b))
       (hash-set! comps l (vector lg lb))
       (T! (λ () (push-kont! lg `(wgk ,l))))]
      [`(let ([,x ,rhs]) ,body)
       (define lr (stage! rhs))
       (define lb (stage! body))
       (T! (λ () (push-kont! lr `(letk ,l ,x ,lb))))]
      [`(if ,a ,b ,c)
       (define la (stage! a))
       (define lb (stage! b))
       (define lc (stage! c))
       (T! (λ () (push-kont! la `(ifk ,l ,lb ,lc))))]
      [`(set! ,x ,rhs)
       (define lr (stage! rhs))
       (T! (λ () (push-kont! lr `(setk ,l ,x))))]
      [`(lambda (,xs ...) ,body)
       (define lb (stage! body))
       (hash-set! clo-info l (cons xs lb))
       (T! (λ () (join-r! l (set `(clo ,l)))))]
      [`(begin ,es ..1)
       (define ls (for/vector ([s es]) (stage! s)))
       (hash-set! comps l ls)
       (T! (λ () (push-kont! (vector-ref ls 0) `(begk ,l 0))))]
      [`(,op ,es ...) #:when (prim-op? op bound)
       (define ls (for/vector ([a es]) (stage! a)))
       (define res (prim-result op))
       (hash-set! comps l ls)
       (hash-set! prim-res l res)
       (if (zero? (vector-length ls))
           (T! (λ () (join-r! l res)))
           (T! (λ () (push-kont! (vector-ref ls 0) `(prmk ,l 0)))))]
      [`(,f ,es ...)
       (define ls (for/vector ([a (cons f es)]) (stage! a)))
       (hash-set! comps l ls)
       (T! (λ () (push-kont! (vector-ref ls 0) `(appk ,l 0))))])
    l)

  ;; ---- kont application: the (A ℓ) half of the machine ------------
  (define (do-call l cs)
    (define fvals (read-r (vector-ref cs 0)))
    (define argRs
      (for/list ([i (in-range 1 (vector-length cs))])
        (read-r (vector-ref cs i))))
    (define nargs (length argRs))
    (for ([fv (in-set fvals)])
      (match fv
        ['top
         (for ([R argRs]) (escape-clos! R))
         (join-r! l (set 'top))]
        [`(clo ,lc)
         (match-define (cons formals lb) (hash-ref clo-info lc))
         (define mi (index-of formals '#%rest))
         (cond
           [mi ;; variadic: fixed formals bind, the rest escape into a list
            (define fixed (take formals mi))
            (define rest-name (list-ref formals (add1 mi)))
            (when (>= nargs (length fixed))
              (for ([x fixed] [R argRs]) (join-v! x R))
              (for ([R (drop argRs (length fixed))]) (escape-clos! R))
              (join-v! rest-name (set 'pair 'nil))
              (push-kont! lb `(retk ,l)))]
           [(= (length formals) nargs)
            (for ([x formals] [R argRs]) (join-v! x R))
            (push-kont! lb `(retk ,l))]
           [else (void)])] ;; arity mismatch: no value flows
        [_ (void)])))      ;; applying a non-closure: runtime error

  (define (apply-kont k S)
    (match k
      [`(retk ,lp) (join-r! lp S)]
      [`(letk ,l ,x ,lb) (join-v! x S) (push-kont! lb `(retk ,l))]
      [`(setk ,l ,x) (join-v! x S) (join-r! l (set '(const (void))))]
      [`(begk ,l ,i)
       (define cs (hash-ref comps l))
       (if (= i (sub1 (vector-length cs)))
           (join-r! l S)
           (push-kont! (vector-ref cs (add1 i)) `(begk ,l ,(add1 i))))]
      [`(ifk ,l ,lt ,lf)
       (when (may-true? S) (push-kont! lt `(retk ,l)))
       (when (may-false? S) (push-kont! lf `(retk ,l)))]
      [`(wgk ,l)
       (define cs (hash-ref comps l))
       (when (may-true? S) (push-kont! (vector-ref cs 1) `(wbk ,l)))
       (when (may-false? S) (join-r! l (set '(const (void)))))]
      [`(wbk ,l) (void)] ;; guard re-reads are dep-driven; body value dies
      [`(prmk ,l ,i)
       (define cs (hash-ref comps l))
       (cond
         [(= i (sub1 (vector-length cs)))
          ;; args may be retained by the prim (cons/hash-set/...): escape
          (for ([la (in-vector cs)]) (escape-clos! (read-r la)))
          (join-r! l (hash-ref prim-res l))]
         [else (push-kont! (vector-ref cs (add1 i)) `(prmk ,l ,(add1 i)))])]
      [`(appk ,l ,i)
       (define cs (hash-ref comps l))
       (if (= i (sub1 (vector-length cs)))
           (do-call l cs)
           (push-kont! (vector-ref cs (add1 i)) `(appk ,l ,(add1 i))))]
      [`(defk ,x) (join-v! x S)]
      ['(topk) (escape-clos! S)] ;; an escaped call's result escapes too
      ['(donek) (void)]))

  (define (do-ret l)
    (define Ks (read-k l))
    (define S (read-r l))
    (unless (set-empty? S)
      (for ([k (in-set Ks)]) (apply-kont k S))))

  ;; ---- stage the top level -----------------------------------------
  ;; A value define's cell starts at 0 and top-level forms run in
  ;; order, so a reference can concretely see 0 only from a function
  ;; body (callable any time) or from a form textually before the
  ;; define. Seed (const 0) exactly in those cases.
  (define fn-mentions
    (for/fold ([acc (seteq)]) ([f forms])
      (match f
        [`(define (,_ ,_ ...) ,_)
         (for/fold ([a acc]) ([m (in-set (mentions-of f))]) (set-add a m))]
        [_ acc])))
  (define roots '())
  (define (root! th) (set! roots (cons th roots)))
  (for/fold ([before (seteq)]) ([form forms])
    (match form
      [`(define (,f ,xs ...) ,body)
       (define lf (next-label! form))
       (define lb (stage! body))
       (hash-set! clo-info lf (cons xs lb))
       (hash-set! clo-name lf f)
       (root! (λ () (join-v! f (set `(clo ,lf)))))]
      [`(define ,(? symbol? x) ,rhs)
       (define lr (stage! rhs))
       (when (match rhs [`(lambda ,_ ,_) #t] [_ #f])
         (hash-set! clo-name lr x))
       (define seed0? (or (set-member? fn-mentions x) (set-member? before x)))
       (root! (λ ()
                (when seed0? (join-v! x (set '(const 0))))
                (push-kont! lr `(defk ,x))))]
      [e
       (define le (stage! e))
       (root! (λ () (push-kont! le '(donek))))])
    (for/fold ([a before]) ([m (in-set (mentions-of form))]) (set-add a m)))

  (define nodes (list->vector (reverse nodes-rev)))

  ;; ---- the fixpoint ---------------------------------------------
  (define (run!)
    (set! current-state -1)
    (for ([th (reverse roots)]) (th))
    (define ok?
      (let loop ([n 0])
        (cond
          [(null? worklist) n]
          [(> n state-ceiling) #f]
          [else
           (define s (car worklist))
           (set! worklist (cdr worklist))
           (hash-set! queued s #f)
           (set! current-state s)
           (if (even? s)
               ((hash-ref transfers (quotient s 2)))
               (do-ret (quotient s 2)))
           (loop (add1 n))])))
    (set! current-state -1)
    (and ok?
         (aam-facts nodes node->label rvals vvals read-vars clo-name
                    escaped label-count ok?)))

  (machine node->label nodes run!))

;; ---------------------------------------------------------------
;; Public analysis interface
;; ---------------------------------------------------------------

;; label-program!: one walk assigning a fixnum label to every
;; expression node; returns (values node->label label→node-vector).
(define (label-program! p)
  (define m (build-machine p))
  (values (machine-node->label m) (machine-nodes m)))

;; analyze: program → facts, or #f if the state ceiling tripped
;; (clients then degrade to the identity).
(define (analyze p)
  ((machine-run! (build-machine p))))

;; ---------------------------------------------------------------
;; Clients: flow constant folding, super-beta rator revelation,
;; dead top-level defines. Every rewrite preserves
;; unique-source-tree? and semantics; anything doubtful is left
;; alone.
;; ---------------------------------------------------------------

(define (aam-clients p)
  (define-values (p* _stats) (aam-clients/stats p))
  p*)

(define (aam-clients/stats p)
  (with-handlers ([exn:fail? (λ (_) (values p (hash 'analyzed #f)))])
    (define facts (analyze p))
    (cond
      [(not facts) (values p (hash 'analyzed #f))]
      [else
       (match-define `(program ,forms ...) p)
       (define bound (program-binders p))
       (define assigned (assigned-vars p))
       (define nodes (aam-facts-nodes facts))
       (define rvals (aam-facts-rvals facts))
       (define clo-name (aam-facts-clo-name facts))
       (define read-vars (aam-facts-read-vars facts))
       (define n-fold (box 0))
       (define n-beta (box 0))

       (define (flow l) (hash-ref rvals l (set)))
       (define (singleton-const S)
         (and (= (set-count S) 1)
              (match (set-first S) [`(const ,k) k] [_ #f])))
       (define (singleton-clo S)
         (and (= (set-count S) 1)
              (match (set-first S) [`(clo ,l) l] [_ #f])))

       ;; the rewrite walk mirrors build-machine's traversal exactly;
       ;; the nodes vector cross-check catches any drift (and bails
       ;; to the identity via the outer handler)
       (define ctr (box 0))
       (define (next!)
         (let ([l (unbox ctr)]) (set-box! ctr (add1 l)) l))
       (define (rw e)
         (define l (next!))
         (unless (if (pair? e)
                     (eq? e (vector-ref nodes l))
                     (equal? e (vector-ref nodes l)))
           (error 'aam-clients "label desync at ~a" l))
         (define out
           (match e
             [(? literal-node?) e]
             [`(string-lit ,_) e]
             ['(read) e]
             [(? symbol? x)
              ;; flow constant folding: a reference whose flow set is
              ;; exactly {(const k)} IS k (never for set! vars)
              (define k (and (not (set-member? assigned x))
                             (singleton-const (flow l))))
              (cond [k (set-box! n-fold (add1 (unbox n-fold))) k]
                    [else x])]
             [`(while ,g ,b) `(while ,(rw g) ,(rw b))]
             [`(let ([,x ,rhs]) ,body) `(let ([,x ,(rw rhs)]) ,(rw body))]
             [`(if ,a ,b ,c) `(if ,(rw a) ,(rw b) ,(rw c))]
             [`(set! ,x ,rhs) `(set! ,x ,(rw rhs))]
             [`(lambda (,xs ...) ,body) `(lambda ,xs ,(rw body))]
             [`(begin ,es ..1) `(begin ,@(map rw es))]
             [`(,op ,es ...) #:when (prim-op? op bound)
              `(,op ,@(map rw es))]
             [`(,f ,es ...)
              ;; super-beta marking: a rator variable that flows to
              ;; exactly one closure bound by a top-level define is
              ;; rewritten to that define's name (top-level defines
              ;; instantiate one closure per run, so the values are
              ;; identical); -O1's inliner takes it from there
              (define lf (unbox ctr)) ;; the label rw will give the rator
              (define f* (rw f))
              (define f**
                (cond
                  [(and (symbol? f) (symbol? f*))
                   (define lc (singleton-clo (flow lf)))
                   (define nm (and lc (hash-ref clo-name lc #f)))
                   (cond [(and nm
                               (not (set-member? assigned nm))
                               (not (set-member? assigned f))
                               (not (eq? nm f*)))
                          (set-box! n-beta (add1 (unbox n-beta)))
                          nm]
                         [else f*])]
                  [else f*]))
              `(,f** ,@(map rw es))]))
         (prov out e))

       (define forms1
         (for/list ([form forms])
           (match form
             [`(define (,f ,xs ...) ,body)
              (next!) ;; the define form's own (closure) label
              (prov `(define (,f ,@xs) ,(rw body)) form)]
             [`(define ,(? symbol? x) ,rhs)
              (prov `(define ,x ,(rw rhs)) form)]
             [e (rw e)])))

       ;; dead top-level defines: name never read in any reachable
       ;; abstract state AND unreferenced from any live form after
       ;; the rewrites (computed as a shrinking fixpoint so mutually
       ;; recursive dead cliques go together); only forms with
       ;; allocation-free rhs are dropped
       (define (defn-name f)
         (match f
           [`(define (,g ,_ ...) ,_) g]
           [`(define ,(? symbol? g) ,_) g]
           [_ #f]))
       (define (droppable-kind? f)
         (match f
           [`(define (,_ ,_ ...) ,_) #t]
           [`(define ,_ ,rhs)
            (or (literal-node? rhs) (symbol? rhs)
                (match rhs
                  [`(lambda ,_ ,_) #t]
                  [`(string-lit ,_) #t]
                  [_ #f]))]
           [_ #f]))
       (define candidates
         (for/seteq ([f forms1]
                     #:when (and (droppable-kind? f)
                                 (defn-name f)
                                 (not (set-member? read-vars (defn-name f)))))
           (defn-name f)))
       (define dead
         (let loop ([dead candidates])
           (define refs (mutable-seteq))
           (for ([f forms1]
                 #:unless (let ([n (defn-name f)])
                            (and n (set-member? dead n))))
             (for ([m (in-set (mentions-of f))]) (set-add! refs m)))
           (define dead*
             (for/seteq ([n (in-set dead)]
                         #:unless (set-member? refs n))
               n))
           (if (equal? dead* dead) dead (loop dead*))))
       (define forms2
         (filter (λ (f) (not (let ([n (defn-name f)])
                               (and n (set-member? dead n)))))
                 forms1))

       (define p* (prov `(program ,@forms2) p))
       (if (unique-source-tree? p*)
           (values p* (hash 'analyzed #t
                            'states (aam-facts-n-states facts)
                            'labels (aam-facts-n-labels facts)
                            'folded (unbox n-fold)
                            'revealed (unbox n-beta)
                            'dropped (set-count dead)))
           (values p (hash 'analyzed #t 'failed-predicate #t)))])))
