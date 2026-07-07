#lang racket
;; -O1: cp0-style contraction + bounded inlining over the core IR
;; (post-uniqueify, pre-collect-globals). See docs/OPTIMIZER.md §4.
;;
;; The rewrite is demand-driven and metered: every node copied on
;; behalf of an inlining attempt charges an effort counter; when a
;; budget trips, the attempt residualizes. Total time is O(n · E).
(provide contract-program)

(require "../provenance.rkt")

;; ---------------------------------------------------------------
;; effect-free prims (safe to drop when their value is unused).
;; Anything not listed is treated as effectful. (read), set!, while,
;; vector-set!, hash-set!, print/error prims are the usual anchors.
;; ONLY genuine backend prims (stdlib manifest) belong here: prelude
;; functions (length, append, ...) are ordinary bindings a user may
;; shadow with something impure, so they must not be assumed pure.
(define pure-prims
  (set '+ '- '* 'eq? '< '<= '> '>= 'quotient 'remainder 'modulo
       'bitwise-and 'bitwise-ior 'bitwise-xor 'arithmetic-shift
       'cons 'car 'cdr 'pair? 'null? 'fixnum? 'boolean? 'symbol? 'string?
       'procedure? 'vector? 'hash? 'set?
       'vector 'make-vector 'vector-ref 'vector-length
       'string-length 'string-append 'substring 'string-byte 'string<? 'string=?
       'symbol->string 'string->symbol 'number->string 'string->number
       'hash 'hash-set 'hash-ref 'hash-ref/default 'hash-has-key? 'hash-count 'hash-keys 'hash-remove
       'set-add 'set-member? 'set-count 'set-remove 'set->list
       'equal? 'value->string))

(define (pure-exp? e)
  (match e
    [(? fixnum?) #t] [#t #t] [#f #t]
    ['(void) #t] ['(nil) #t]
    [`(quote ,_) #t] [`(string-lit ,_) #t]
    [(? symbol?) #t]
    [`(lambda ,_ ,_) #t]
    [`(if ,a ,b ,c) (and (pure-exp? a) (pure-exp? b) (pure-exp? c))]
    [`(let ([,_ ,r]) ,b) (and (pure-exp? r) (pure-exp? b))]
    [`(begin ,es ...) (andmap pure-exp? es)]
    [`(,(? symbol? op) ,args ...)
     (and (set-member? pure-prims op) (andmap pure-exp? args))]
    [_ #f]))

(define (literal? e)
  (match e
    [(? fixnum?) #t] [#t #t] [#f #t]
    ['(void) #t] ['(nil) #t]
    [`(quote ,_) #t] [`(string-lit ,_) #t]
    [_ #f]))

;; ---------------------------------------------------------------
;; census: one pass over the whole program.
;;   refs      var -> reference count
;;   assigned  vars that are ever set!
;;   binding   var -> rhs of its (unique) let binding / top-level define
;;   bound     every name BOUND in the censused program (let/lambda/
;;             define). Inlining freshens binders, so the rewrite can
;;             encounter names the census never saw; its facts about
;;             those (ref-count 0, unassigned) are vacuous, not true.
;;             Clients must treat unknown names conservatively (no
;;             substitution, no dead-drop, no inlining) -- the next
;;             round's census sees them and finishes the job.
(struct census (refs assigned binding bound) #:transparent)

(define (make-census p)
  (define refs (make-hasheq))
  (define assigned (mutable-seteq))
  (define binding (make-hasheq))
  (define bound (mutable-seteq))
  (define (ref! x) (hash-update! refs x add1 0))
  (define (walk e)
    (match e
      [(? symbol? x) (ref! x)]
      [(? fixnum?) (void)] [#t (void)] [#f (void)]
      ['(read) (void)] ['(void) (void)] ['(nil) (void)]
      [`(quote ,_) (void)] [`(string-lit ,_) (void)]
      [`(set! ,x ,e0) (set-add! assigned x) (walk e0)]
      [`(let ([,x ,rhs]) ,body)
       (hash-set! binding x rhs)
       (set-add! bound x)
       (walk rhs) (walk body)]
      [`(lambda ,xs ,body) (for ([x xs]) (set-add! bound x)) (walk body)]
      [`(if ,a ,b ,c) (walk a) (walk b) (walk c)]
      [`(while ,c ,b) (walk c) (walk b)]
      [`(begin ,es ...) (for-each walk es)]
      [`(,rator ,rands ...) (walk rator) (for-each walk rands)]))
  (match p
    [`(program ,forms ...)
     (for ([f forms])
       (match f
         [`(define (,name ,args ...) ,body)
          (hash-set! binding name `(lambda ,args ,body))
          (set-add! bound name)
          (for ([x args]) (set-add! bound x))
          (walk body)]
         [`(define ,name ,rhs)
          (hash-set! binding name rhs)
          (set-add! bound name)
          (walk rhs)]
         [e (walk e)]))])
  (census refs assigned binding bound))

(define (ref-count c x) (hash-ref (census-refs c) x 0))
(define (assigned? c x) (set-member? (census-assigned c) x))
(define (binding-of c x) (hash-ref (census-binding c) x #f))
(define (known? c x) (set-member? (census-bound c) x))

;; ---------------------------------------------------------------
;; size + fresh-renaming copy (charged against the effort counter)
(define (exp-size e)
  (match e
    [`(,es ...) (add1 (for/sum ([s es]) (exp-size s)))]
    [_ 1]))

;; effort: a mutable box of remaining fuel. Every copied node costs 1.
(define (spend! effort n)
  (define left (- (unbox effort) n))
  (set-box! effort left)
  (> left 0))

;; copy e, freshening every bound variable; rn maps old->new
(define (freshen e rn effort)
  (and (spend! effort 1)
       (match e
         [(? symbol? x) (hash-ref rn x x)]
         [(? fixnum?) e] [#t e] [#f e]
         ['(read) e] ['(void) e] ['(nil) e]
         [`(quote ,_) e] [`(string-lit ,_) e]
         [`(set! ,x ,e0)
          (define e0* (freshen e0 rn effort))
          (and e0* `(set! ,(hash-ref rn x x) ,e0*))]
         [`(let ([,x ,rhs]) ,body)
          ;; `_` is the throwaway binder (and the while wrapper's
          ;; marker): never referenced, must stay literally `_`
          (define x* (if (eq? x '_) '_ (gensym x)))
          (define rhs* (freshen rhs rn effort))
          (define body* (and rhs*
                             (freshen body
                                      (if (eq? x '_) rn (hash-set rn x x*))
                                      effort)))
          (and body* `(let ([,x* ,rhs*]) ,body*))]
         [`(lambda (,xs ...) ,body)
          ;; the #%rest variadic marker is a keyword, not a binder
          (define xs* (map (λ (x) (if (eq? x '#%rest) x (gensym x))) xs))
          (define rn* (for/fold ([m rn]) ([x xs] [x* xs*]) (hash-set m x x*)))
          (define body* (freshen body rn* effort))
          (and body* `(lambda ,xs* ,body*))]
         [`(if ,a ,b ,c)
          (let* ([a* (freshen a rn effort)]
                 [b* (and a* (freshen b rn effort))]
                 [c* (and b* (freshen c rn effort))])
            (and c* `(if ,a* ,b* ,c*)))]
         [`(while ,a ,b)
          (let* ([a* (freshen a rn effort)]
                 [b* (and a* (freshen b rn effort))])
            (and b* `(while ,a* ,b*)))]
         [`(begin ,es ...)
          (let loop ([es es] [acc '()])
            (if (null? es)
                `(begin ,@(reverse acc))
                (let ([e* (freshen (car es) rn effort)])
                  (and e* (loop (cdr es) (cons e* acc))))))]
         [`(,es ...)
          (let loop ([es es] [acc '()])
            (if (null? es)
                (reverse acc)
                (let ([e* (freshen (car es) rn effort)])
                  (and e* (loop (cdr es) (cons e* acc))))))])))

;; ---------------------------------------------------------------
;; prim folding on literal operands
(define (fold-prim op args)
  (define (fx a) (and (fixnum? a) a))
  (match (cons op args)
    [`(+ ,(? fixnum? a) ,(? fixnum? b)) (+ a b)]
    [`(- ,(? fixnum? a) ,(? fixnum? b)) (- a b)]
    [`(* ,(? fixnum? a) ,(? fixnum? b)) (* a b)]
    [`(- ,(? fixnum? a)) (- a)]
    [`(< ,(? fixnum? a) ,(? fixnum? b)) (< a b)]
    [`(<= ,(? fixnum? a) ,(? fixnum? b)) (<= a b)]
    [`(> ,(? fixnum? a) ,(? fixnum? b)) (> a b)]
    [`(>= ,(? fixnum? a) ,(? fixnum? b)) (>= a b)]
    [`(eq? ,(? literal? a) ,(? literal? b)) (equal? a b)]
    [`(quotient ,(? fixnum? a) ,(? fixnum? b)) #:when (not (zero? b)) (quotient a b)]
    [`(remainder ,(? fixnum? a) ,(? fixnum? b)) #:when (not (zero? b)) (remainder a b)]
    [`(null? (nil)) #t]
    [`(null? ,(? literal? v)) #:when (not (equal? v '(nil))) #f]
    [`(fixnum? ,(? fixnum?)) #t]
    [`(pair? ,(? literal?)) #f]
    [_ 'no-fold]))

;; ---------------------------------------------------------------
;; the rewrite. env maps var -> substitution (literal or variable).
;; inlining maps function names currently being inlined (recursion guard).
(define size-limit 50)       ; max nodes for an inlined body copy
(define effort-limit 400)    ; fuel per inlining attempt
(define always-inline-size 16)

(define (contract-program p)
  (define c (make-census p))
  (define changed (box #f))

  (define (subst-ok? x)
    ;; a variable reference can be replaced by its binding's
    ;; substitute; names the census never saw (freshened binders from
    ;; this round's inlining) have no facts, so leave them alone
    (and (known? c x) (not (assigned? c x))))

  (define (opt e env inlining)
    (define out (opt-core e env inlining))
    (prov out e))

  (define (opt-core e env inlining)
    (match e
      [(? symbol? x)
       ;; NB: the substitute may itself be the literal #f, so probe
       ;; with has-key? rather than a #f default
       (cond [(hash-has-key? env x) (set-box! changed #t) (hash-ref env x)]
             [else x])]
      [(? fixnum?) e] [#t e] [#f e]
      ['(read) e] ['(void) e] ['(nil) e]
      [`(quote ,_) e] [`(string-lit ,_) e]
      [`(set! ,x ,e0) `(set! ,x ,(opt e0 env inlining))]
      [`(let ([,x ,rhs]) ,body)
       (define rhs* (opt rhs env inlining))
       (cond
         ;; copy/constant propagation: literal or variable rhs, x unassigned
         [(and (subst-ok? x)
               (or (literal? rhs*)
                   (and (symbol? rhs*) (known? c rhs*) (not (assigned? c rhs*)))))
          (set-box! changed #t)
          (opt body (hash-set env x rhs*) inlining)]
         ;; dead binding with pure rhs (census facts only apply to
         ;; names it saw: a fresh binder's ref-count 0 is vacuous)
         [(and (known? c x) (zero? (ref-count c x)) (not (assigned? c x)) (pure-exp? rhs*))
          (set-box! changed #t)
          (opt body env inlining)]
         [else
          ;; a surviving lambda binding inlines as its OPTIMIZED self:
          ;; the census-time original may reference let-vars that
          ;; copy-propagation has since erased
          (when (match rhs* [`(lambda ,_ ,_) #t] [_ #f])
            (hash-set! (census-binding c) x rhs*))
          `(let ([,x ,rhs*]) ,(opt body env inlining))])]
      [`(lambda ,xs ,body) `(lambda ,xs ,(opt body env inlining))]
      [`(if ,a ,b ,c0)
       (define a* (opt a env inlining))
       (cond
         [(literal? a*)
          (set-box! changed #t)
          ;; Racket truthiness: only #f is false
          (if (equal? a* #f) (opt c0 env inlining) (opt b env inlining))]
         [else `(if ,a* ,(opt b env inlining) ,(opt c0 env inlining))])]
      [`(while ,a ,b)
       (define a* (opt a env inlining))
       (if (equal? a* #f)
           (begin (set-box! changed #t) '(void))
           `(while ,a* ,(opt b env inlining)))]
      [`(begin ,es ...)
       (define es* (map (λ (s) (opt s env inlining)) es))
       (define last* (last es*))
       (define init* (filter (λ (s) (not (pure-exp? s))) (drop-right es* 1)))
       (when (< (length init*) (- (length es*) 1)) (set-box! changed #t))
       (cond [(null? init*) last*]
             [else `(begin ,@init* ,last*)])]
      ;; direct beta: ((lambda (xs...) b) args...) -- fixed arity only
      ;; (a variadic's rest formal binds an argument LIST, not an arg)
      [`((lambda (,xs ...) ,body) ,args ...)
       #:when (and (= (length xs) (length args))
                   (not (memq '#%rest xs)))
       (set-box! changed #t)
       (define args* (map (λ (a) (opt a env inlining)) args))
       (opt (wrap-lets xs args* body) env inlining)]
      [`(,rator ,rands ...)
       (define rator* (opt rator env inlining))
       (define rands* (map (λ (r) (opt r env inlining)) rands))
       (cond
         ;; prim application: try folding
         [(and (symbol? rator*) (set-member? pure-prims rator*)
               (not (binding-of c rator*)))
          (define folded (fold-prim rator* rands*))
          (cond [(eq? folded 'no-fold) `(,rator* ,@rands*)]
                [else (set-box! changed #t) folded])]
         ;; known-function inlining through a variable/top-level name
         [(and (symbol? rator*)
               (known? c rator*)
               (not (assigned? c rator*))
               (not (set-member? inlining rator*))
               (match (binding-of c rator*)
                 [`(lambda (,xs ...) ,fbody)
                  #:when (and (= (length xs) (length rands*))
                              (not (memq '#%rest xs)))
                  (try-inline rator* xs fbody rands* env inlining)]
                 [_ #f]))
          => values]
         [else `(,rator* ,@rands*)])]))

  ;; does this function's body mention its own name? (memoized)
  (define recursive-cache (make-hasheq))
  (define (self-recursive? fname fbody)
    (hash-ref! recursive-cache fname
               (λ () (let walk ([e fbody])
                       (match e
                         [(? symbol? y) (eq? y fname)]
                         [`(quote ,_) #f] [`(string-lit ,_) #f]
                         [`(,es ...) (ormap walk es)]
                         [_ #f])))))

  ;; returns the rewritten inlined expression, or #f to residualize
  (define (try-inline fname xs fbody args env inlining)
    (define sz (exp-size fbody))
    (define single-use? (= (ref-count c fname) 1))
    ;; a self-recursive function re-inlines only when some argument is
    ;; a literal (constant-guided unrolling); otherwise each round
    ;; would duplicate its body exponentially for no benefit
    (and (or (not (self-recursive? fname fbody))
             (ormap literal? args))
         (or single-use? (<= sz always-inline-size)
             (<= sz size-limit))
         (let* ([effort (box (if (or single-use? (<= sz always-inline-size))
                                 (* 4 effort-limit)
                                 effort-limit))]
                [copy (freshen `(lambda ,xs ,fbody) (hash) effort)])
           (and copy
                (match copy
                  [`(lambda (,xs* ...) ,body*)
                   (set-box! changed #t)
                   (opt (wrap-lets xs* args body*) env
                        (set-add inlining fname))])))))

  (define (wrap-lets xs args body)
    (if (null? xs)
        body
        `(let ([,(car xs) ,(car args)])
           ,(wrap-lets (cdr xs) (cdr args) body))))

  (match p
    [`(program ,forms ...)
     (define out
       `(program
         ,@(map (λ (f)
                  (prov
                   (match f
                     [`(define (,name ,args ...) ,body)
                      `(define (,name ,@args) ,(opt body (hash) (seteq name)))]
                     [`(define ,name ,rhs)
                      `(define ,name ,(opt rhs (hash) (seteq)))]
                     [e (opt e (hash) (seteq))])
                   f))
                forms)))
     (values out (unbox changed))]))
