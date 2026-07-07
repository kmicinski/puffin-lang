#lang racket

;; Puffin -- interpreters.rkt: reference interpreters for the IRs.
;;
;; Three levels (mirroring the class p5 layout):
;;   - interpret-puffin: source-level; works for every pass from
;;     desugar through anf-convert (all those IRs are subsets of
;;     core Puffin + the middle-end forms)
;;   - interpret-blocks: the blocks IR (explicate-control,
;;     uncover-locals)
;;   - instruction-level interpretation is per-backend; for now the
;;     backends' outputs are validated by running the native binary
;;     (see test.rkt), and dummy-interp explains that in traces
;;
;; All interpreters share the *reference value representation*
;; declared in stdlib.rkt, and every library primitive's behavior
;; comes from its manifest ref-impl--so the C runtime and these
;; interpreters can only drift apart in one place.
;;
;; Deltas from the class interpreters (see docs/DELTA.md): input is
;; a mutable box of remaining integers rather than threaded return
;; values (the prim table made threading unwieldy); truthiness is
;; Racket-style (#f is the only false value); mutable bindings use
;; Racket boxes.

(require "irs.rkt")
(require "system.rkt")
(require "stdlib.rkt")

(provide (all-defined-out))

(define (display-return v)
  ;; print the way the native conclusion does: non-void results only
  (unless (void? v) (displayln (render-value v)))
  v)

(define (next-input! inbox)
  (match (unbox inbox)
    ;; the REPL reads live from the terminal
    ['stdin (let ([v (read)])
              (if (fixnum? v) v (error 'interpret "(read) expected an integer")))]
    ['() (error 'interpret "input exhausted for (read)")]
    [`(,hd . ,tl) (set-box! inbox tl) hd]))

;; (read-all): the rest of the input, rendered the way it would look
;; on stdin (whitespace-separated integers)
(define (rest-of-input! inbox)
  (match (unbox inbox)
    ['stdin (port->string (current-input-port))]
    [ints (set-box! inbox '())
          (string-join (map number->string ints) " ")]))

;; The REPL's persistent top-level: consulted when a variable isn't
;; lexically bound, letting definitions arrive one at a time (and be
;; mutually recursive across inputs).
(define repl-toplevel (make-parameter #f))

;; ────────────────────────────────────────────────────────────────────
;; Source-level interpreter (desugar .. anf-convert)
;; ────────────────────────────────────────────────────────────────────

(struct clo (xs body env) #:transparent)

;; globals are one mutable vector; symbols/strings/immediates are
;; ordinary Racket values (see stdlib.rkt)
(define (eval-puffin-exp e env globals inbox)
  (define (ev e env)
    (match e
      [(? fixnum? n) n]
      [(? boolean? b) b]
      ['(void) (void)]
      ['(nil) '()]
      [`(quote ,(? symbol? s)) s]
      [`(string-lit ,s) s]
      ['(read) (next-input! inbox)]
      ;; middle-end forms
      [`(fun-ref ,f) (ev f env)]
      [`(global-ref ,i) (unbox (vector-ref globals i))]
      [`(global-set! ,i ,e+) (set-box! (vector-ref globals i) (ev e+ env)) (void)]
      [`(unsafe-vector-ref ,e0 ,i) (vector-ref (ev e0 env) i)]
      [`(unsafe-vector-set! ,e0 ,i ,e1)
       (vector-set! (ev e0 env) i (ev e1 env)) (void)]
      [`(make-closure ,e0) (make-vector (ev e0 env) 0)]
      ;; variables / binding
      [(? symbol? x)
       (unbox (hash-ref env x
                        (λ () (or (and (repl-toplevel) (hash-ref (repl-toplevel) x #f))
                                  (error 'interpret "unbound id ~a" x)))))]
      [`(let ([_ (while ,e-g ,e-b)]) ,e-r)
       (let loop ()
         (when (not (equal? (ev e-g env) #f))
           (ev e-b env)
           (loop)))
       (ev e-r env)]
      [`(while ,e-g ,e-b)
       (let loop ()
         (when (not (equal? (ev e-g env) #f))
           (ev e-b env)
           (loop)))
       (void)]
      [`(let ([_ ,e0]) ,e-b)
       (ev e0 env)
       (ev e-b env)]
      [`(let ([,x ,e0]) ,e-b)
       (ev e-b (hash-set env x (box (ev e0 env))))]
      [`(set! ,x ,e+)
       (set-box! (hash-ref env x
                           (λ () (or (and (repl-toplevel) (hash-ref (repl-toplevel) x #f))
                                     (error 'interpret "unbound id ~a" x))))
                 (ev e+ env))
       (void)]
      ;; control (Racket truthiness: only #f is false)
      [`(if ,e-g ,e-t ,e-f)
       (if (equal? (ev e-g env) #f) (ev e-f env) (ev e-t env))]
      ;; sequencing (pre-shrink IRs)
      [`(begin ,es ... ,e-ret)
       (for ([e es]) (ev e env))
       (ev e-ret env)]
      ;; intrinsics
      [`(- ,e0 ,e1) (- (ev e0 env) (ev e1 env))]
      [`(- ,e0) (- (ev e0 env))]
      [`(+ ,e0 ,e1) (+ (ev e0 env) (ev e1 env))]
      [`(* ,e0 ,e1) (* (ev e0 env) (ev e1 env))]
      [`(< ,e0 ,e1) (< (ev e0 env) (ev e1 env))]
      [`(<= ,e0 ,e1) (<= (ev e0 env) (ev e1 env))]
      [`(> ,e0 ,e1) (> (ev e0 env) (ev e1 env))]
      [`(>= ,e0 ,e1) (>= (ev e0 env) (ev e1 env))]
      [`(eq? ,e0 ,e1) (eqv? (ev e0 env) (ev e1 env))]
      [`(not ,e0) (equal? (ev e0 env) #f)]
      [`(and ,e0 ,e1) (if (equal? (ev e0 env) #f) #f (ev e1 env))]
      [`(or ,e0 ,e1) (let ([v (ev e0 env)]) (if (equal? v #f) (ev e1 env) v))]
      ;; lambdas / application
      [`(lambda (,xs ...) ,e-b) (clo xs e-b env)]
      [`(app ,e-f ,e-args ...) (ev `(,e-f ,@e-args) env)]
      [`(papp ,n ,e-f ,e-args ...)
       ;; a papp is by construction packed: the last argument is the
       ;; overflow vector holding arguments 6..n
       (define vs (map (λ (e) (ev e env)) e-args))
       (define full (append (take vs (sub1 (length vs)))
                            (vector->list (last vs))))
       (ev `(app ,e-f ,@(map (λ (v) `(quote-value ,v)) full)) env)]
      [`(quote-value ,v) v]
      ;; stdlib primitives, straight from the manifest
      [`(,(? stdlib-prim? op) ,es ...)
       #:when (not (hash-has-key? env op))
       (define impl (stdlib-ref-impl op))
       (match impl
         ['read (next-input! inbox)]
         ['read-all (rest-of-input! inbox)]
         [_ (apply impl (map (λ (e) (ev e env)) es))])]
      [`(,e-f ,e-args ...)
       (define f (ev e-f env))
       (define args (map (λ (e) (ev e env)) e-args))
       (apply-closure f args)]))
  (define (apply-closure f args)
    (match f
      [(clo xs body cenv)
       ;; a #%rest marker splits fixed formals from the rest binder
       (define mi (index-of xs '#%rest))
       (cond
         [mi
          (define fixed (take xs mi))
          (define rest-name (list-ref xs (add1 mi)))
          (unless (>= (length args) (length fixed))
            (error 'interpret "arity mismatch: (λ ~a ...) applied to ~a arguments" xs (length args)))
          (define env+ (foldl (λ (x v acc) (hash-set acc x (box v)))
                              cenv fixed (take args (length fixed))))
          (eval-puffin-exp body
                           (hash-set env+ rest-name (box (drop args (length fixed))))
                           globals inbox)]
         [else
          (unless (= (length xs) (length args))
            (error 'interpret "arity mismatch: (λ ~a ...) applied to ~a arguments: ~a" xs (length args) args))
          (eval-puffin-exp body
                           (foldl (λ (x v acc) (hash-set acc x (box v))) cenv xs args)
                           globals inbox)])]
      [_ (error 'interpret "application of a non-procedure: ~a" f)]))
  (ev e env))

;; Accepts programs both before collect-globals ((program ,forms...))
;; and after ((program ,info ,fun-defns...)).
(define (interpret-puffin p [in (range 10000)])
  (define inbox (box in))
  (define-values (info forms)
    (match p
      [`(program ,(? program-info? i) ,forms ...) (values i forms)]
      [`(program ,forms ...) (values (hash 'globals 0) forms)]))
  (define globals (build-vector (hash-ref info 'globals 0) (λ (_) (box (void)))))
  ;; two-pass environment: cells for every top-level name first (so
  ;; functions see each other *and* value defines textually after
  ;; them), then closures capturing the finished env. Value cells
  ;; start at 0, matching the native zeroed global array.
  (define fun-defns (filter (λ (f) (match f [`(define (,_ ,_ ...) ,_) #t] [_ #f])) forms))
  (define val-names (filter-map (λ (f) (match f
                                          [`(define (,_ ,_ ...) ,_) #f]
                                          [`(define ,(? symbol? x) ,_) x]
                                          [_ #f]))
                                forms))
  (define env
    (let* ([cells (append
                   (for/list ([d fun-defns])
                     (match d [`(define (,f ,_ ...) ,_) (cons f (box (void)))]))
                   (for/list ([x val-names]) (cons x (box 0))))]
           [env (for/fold ([h (hash)]) ([fc cells]) (hash-set h (car fc) (cdr fc)))])
      (for ([d fun-defns])
        (match d
          [`(define (,f ,args ...) ,e-b)
           (set-box! (hash-ref env f) (clo args e-b env))]))
      env))
  (define post-collect-globals? (program-info? (second p)))
  (define result
    (with-handlers ([puffin-error-stop? (λ (_) (void))])
      (if post-collect-globals?
          ;; everything (global inits, top-level effects, the final
          ;; expression) already lives inside main: just call it
          (eval-puffin-exp `(app ,(entry-symbol)) env globals inbox)
          ;; earlier IRs: run value defines and top-level expressions
          ;; in source order; the last expression's value is the result
          (let loop ([forms forms] [env env] [last (void)])
            (match forms
              ['() last]
              [`((define (,_ ,_ ...) ,_) . ,rest) (loop rest env last)]
              [`((define ,(? symbol? x) ,e) . ,rest)
               (set-box! (hash-ref env x) (eval-puffin-exp e env globals inbox))
               (loop rest env (void))]
              [`(,e . ,rest)
               (loop rest env (eval-puffin-exp e env globals inbox))])))))
  (display-return result))

;; ────────────────────────────────────────────────────────────────────
;; Blocks interpreter (explicate-control, uncover-locals)
;; ────────────────────────────────────────────────────────────────────

(define (interpret-blocks p [in (range 10000)])
  (define inbox (box in))
  (define (merge h0 h1)
    (foldl (λ (k0 h1) (hash-set h1 k0 (hash-ref h0 k0))) h1 (hash-keys h0)))
  (match-define `(program ,info ,defns ...) p)
  (define globals (make-vector (hash-ref info 'globals 0) (void)))
  (define name->args
    (foldl (lambda (defn acc) (match defn
                                [`(define (,f ,args ...) ,_) (hash-set acc f args)]
                                [`(define ,_ (,f ,args ...) ,_) (hash-set acc f args)]))
           (hash)
           defns))
  (define blocks
    (foldl merge (hash)
           (map (λ (d) (match d
                         [`(define (,f ,args ...) ,blocks) blocks]
                         [`(define ,_ (,f ,args ...) ,blocks) blocks]))
                defns)))
  (define (atom-val a env)
    (match a
      [(? fixnum? n) n]
      [(? boolean? b) b]
      ['(void) (void)]
      ['(nil) '()]
      [`(quote ,s) s]
      [(? symbol? x) (hash-ref env x (λ () (error 'interpret "unbound id ~a" x)))]))
  (define (rhs-val rhs env)
    (match rhs
      [`(string-lit ,s) s]
      [`(fun-ref ,f) `(fun-ref ,f)]
      [`(global-ref ,i) (vector-ref globals i)]
      [`(unsafe-vector-ref ,a ,i) (vector-ref (atom-val a env) i)]
      [`(- ,a) (- (atom-val a env))]
      [`(+ ,a0 ,a1) (+ (atom-val a0 env) (atom-val a1 env))]
      [`(* ,a0 ,a1) (* (atom-val a0 env) (atom-val a1 env))]
      [`(< ,a0 ,a1) (< (atom-val a0 env) (atom-val a1 env))]
      [`(eq? ,a0 ,a1) (eqv? (atom-val a0 env) (atom-val a1 env))]
      [`(,(? stdlib-prim? op) ,as ...)
       (define impl (stdlib-ref-impl op))
       (match impl
         ['read (next-input! inbox)]
         ['read-all (rest-of-input! inbox)]
         [_ (apply impl (map (λ (a) (atom-val a env)) as))])]
      [a (atom-val a env)]))
  (define (go s env stack)
    (match s
      [`(return ,a)
       (match stack
         ['(top-stack) (atom-val a env)]
         [`((,x ,env+ ,rst) . ,stack+)
          (go rst (hash-set env+ x (atom-val a env)) stack+)])]
      [`(seq (assign ,x (,(or 'app 'papp) ,maybe-n ...)) ,rst)
       (define-values (packed? f args)
         (match `(dispatch ,@maybe-n)
           [`(dispatch ,(? fixnum? _) ,f ,args ...) (values #t f args)]
           [`(dispatch ,f ,args ...) (values #f f args)]))
       (match-define `(fun-ref ,fptr) (rhs-val f env))
       (define vs (map (λ (a) (atom-val a env)) args))
       ;; rebuild the original arguments when the call was packed
       (define full (if packed?
                        (append (take vs (sub1 (length vs))) (vector->list (last vs)))
                        vs))
       (define formals (hash-ref name->args fptr))
       (define mi (index-of formals '#%rest))
       (define env+
         (cond
           [mi
            (define fixed (take formals mi))
            (define rest-name (list-ref formals (add1 mi)))
            (hash-set (foldl (λ (x v acc) (hash-set acc x v))
                             (hash) fixed (take full (length fixed)))
                      rest-name (drop full (length fixed)))]
           [(= (length formals) (length full))
            (foldl (λ (x v acc) (hash-set acc x v)) (hash) formals full)]
           [else ;; fixed >6-arg callee: it unpacks the vector itself
            (foldl (λ (x v acc) (hash-set acc x v)) (hash) formals vs)]))
       (go (hash-ref blocks fptr) env+ (cons `(,x ,env ,rst) stack))]
      ;; a tail call reuses the caller's continuation: no stack growth
      [`(tail-app ,n ,f ,args ...)
       (match-define `(fun-ref ,fptr) (rhs-val f env))
       (define vs (map (λ (a) (atom-val a env)) args))
       ;; packed iff the logical count exceeds what the registers held
       (define full (if (> n (length vs))
                        (append (take vs (sub1 (length vs))) (vector->list (last vs)))
                        vs))
       (define formals (hash-ref name->args fptr))
       (define mi (index-of formals '#%rest))
       (define env+
         (cond
           [mi
            (define fixed (take formals mi))
            (define rest-name (list-ref formals (add1 mi)))
            (hash-set (foldl (λ (x v acc) (hash-set acc x v))
                             (hash) fixed (take full (length fixed)))
                      rest-name (drop full (length fixed)))]
           [(= (length formals) (length full))
            (foldl (λ (x v acc) (hash-set acc x v)) (hash) formals full)]
           [else
            (foldl (λ (x v acc) (hash-set acc x v)) (hash) formals vs)]))
       (go (hash-ref blocks fptr) env+ stack)]
      [`(seq (assign ,x ,rhs) ,rst)
       (go rst (hash-set env x (rhs-val rhs env)) stack)]
      [`(seq (effect (app ,f ,args ...)) ,rst)
       (go `(seq (assign ,(gensym '_e) (app ,f ,@args)) ,rst) env stack)]
      [`(seq (effect ,rhs) ,rst)
       (rhs-val rhs env)
       (go rst env stack)]
      [`(seq (global-set! ,i ,a) ,rst)
       (vector-set! globals i (atom-val a env))
       (go rst env stack)]
      [`(seq (unsafe-vector-set! ,a0 ,i ,a1) ,rst)
       (vector-set! (atom-val a0 env) i (atom-val a1 env))
       (go rst env stack)]
      [`(if (,cmp ,a0 ,a1) (goto ,l-t) (goto ,l-f))
       (define v0 (atom-val a0 env))
       (define v1 (atom-val a1 env))
       (define truth
         (match cmp
           ['eq? (eqv? v0 v1)]
           ['<   (< v0 v1)]
           ['<=  (<= v0 v1)]
           ['>   (> v0 v1)]
           ['>=  (>= v0 v1)]))
       (go (hash-ref blocks (if truth l-t l-f)) env stack)]
      [`(goto ,l) (go (hash-ref blocks l) env stack)]))
  (display-return
   (with-handlers ([puffin-error-stop? (λ (_) (void))])
     (go (hash-ref blocks (entry-symbol)) (hash) '(top-stack)))))

;; ────────────────────────────────────────────────────────────────────
;; Instruction-level passes: validated natively (see test.rkt)
;; ────────────────────────────────────────────────────────────────────

(define (dummy-interp p i)
  "instruction-level IR not interpreted; validated by running the native binary")
