#lang racket

;; Puffin -- test-types.rkt: the gradual typechecker's verdicts
;; (docs/TYPES.md). Success paths live in the golden corpus
;; (typed-*); these are the compile-time rejections plus the
;; inference-leniency cases the corpus can't express as goldens.
;; Run: racket src/test-types.rkt

(require rackunit "types.rkt" "modules.rkt" "system.rkt")

(define (check-of source)
  (λ () (typecheck-program
         `(program ,@(with-input-from-string source
                       (λ () (let loop ([acc '()])
                               (define f (read))
                               (if (eof-object? f) (reverse acc) (loop (cons f acc))))))))))

(define-syntax-rule (rejects rx src)
  (check-exn (λ (e) (and (type-error? e) (regexp-match? rx (exn-message e))))
             (check-of src)))
(define-syntax-rule (admits src)
  (check-not-exn (check-of src)))

;; warning capture: run the checker with stderr redirected; returns
;; whatever the checker wrote there (exhaustiveness warnings)
(define (warnings-of source)
  (define err (open-output-string))
  (parameterize ([current-error-port err]) ((check-of source)))
  (get-output-string err))
(define-syntax-rule (warns rx src) (check-regexp-match rx (warnings-of src)))
(define-syntax-rule (no-warn src) (check-equal? (warnings-of src) ""))
(define-syntax-rule (rejects/strict rx src)
  (parameterize ([strict-exhaustiveness? #t])
    (check-exn (λ (e) (and (type-error? e) (regexp-match? rx (exn-message e))))
               (check-of src))))

;; concrete formals are contracts
(rejects #rx"argument has type Bool, expected Int"
         "(define (f [x : Int]) : Int (+ x 1)) (f #t)")
(rejects #rx"argument has type Int, expected \\(Option Int\\)"
         "(define-type (Option a) (None) (Some a))
          (define (g [o : (Option Int)]) : Int (match o [(Some x) x] [None 0]))
          (g 5)")
(rejects #rx"declared Int but its value has type Str"
         "(: total Int) (define total \"nope\")")
(rejects #rx"body has type Str, declared Int"
         "(define (f [x : Int]) : Int \"nope\")")
(rejects #rx"claims Bool but expression has type Int"
         "(ann (+ 1 2) Bool)")
(rejects #rx"expects 1 fields"
         "(define-type T (Wrap Int)) (match (Wrap 1) [(Wrap a b) a])")
(rejects #rx"expects 2 arguments"
         "(define (f [x : Int] [y : Int]) : Int (+ x y)) (f 1)")
(rejects #rx"argument has type Str, expected Int"
         "(+ 1 \"two\")")
(rejects #rx"type Option expects 1 parameters"
         "(define-type (Option a) (None) (Some a)) (define (f [x : (Option Int Int)]) x)")

;; the gradual guarantee: unannotated code never errors
(admits "(define (h x) (+ x 1)) (h 41)")
(admits "(define h (hash 'a 1 'b 2)) (hash-ref/default h 'a 'gone)")  ;; het. default
(admits "(define (compose f g) (lambda (x) (f (g x)))) ((compose car cdr) (list 1 2 3))")
(admits "(cons 1 2) (cons 1 (list 2 3))")   ;; pairs AND lists

;; instantiation: polymorphic prims and constructors
(admits "(ann (car (cons 1 \"s\")) Int)")
(admits "(define-type (Option a) (None) (Some a))
         (define (or-else [o : (Option Int)] [d : Int]) : Int
           (match o [(Some x) x] [None d]))
         (or-else (Some 1) 2)")
(rejects #rx"argument has type"
         "(define-type (Option a) (None) (Some a))
          (define (or-else [o : (Option Int)] [d : Int]) : Int
            (match o [(Some x) x] [None d]))
          (or-else (Some 1) \"nope\")")

;; List/Pairof equi-recursion
(admits "(define (sum [xs : (List Int)]) : Int
           (if (null? xs) 0 (+ (car xs) (sum (cdr xs)))))
         (sum (list 1 2 3))")

;; quasiquote pattern binders enter the env (typed _) rather than
;; falling through to a same-named top-level binding. Both programs
;; below were REJECTED before the fix: the pattern var picked up the
;; concrete top-level type. `,x` (plain unquote) and `,ps ...`
;; (ellipsis) exercise both binding positions.
(admits "(: x Str) (define x \"top\")
         (define (ev e) (match e [`(add ,x ,y) (+ x y)] [_ 0]))
         (ev `(add 1 2))")
(admits "(: ps Str) (define ps \"top\")
         (define (f e) (match e [`(,a ,ps ...) (car ps)] [_ 0]))
         (f `(1 2 3))")

;; scope: unknown variables are compile-time errors (outside REPL
;; mode). Before the fix they fell to _ and compiled into an
;; uninitialized cell (fixnum 0), which the bytecode VM's CALLI
;; dispatched as function index 0 = the program entry -- calling a
;; typo'd name re-entered main until the stack died.
(rejects #rx"unbound variable Plus"
         "(define-type Expr (Num Int) (Add Expr Expr))
          (define (ev [e : Expr]) : Int
            (match e [(Num n) n] [(Add a b) (+ (ev a) (ev b))]))
          (ev (Plus 20 20))")
(rejects #rx"unbound variable typo"
         "(define (f x) (* x 2)) (f typo)")
(rejects #rx"unbound variable nope"
         "(set! nope 5)")
;; ...but the forms the fallback used to paper over stay admitted:
;; desugar-level not/<=/>/>=, and variadic defines (dotted formals)
(admits "(println (not (<= 3 2))) (println (>= 4 4)) (println (> 2 1))")
(admits "(define (weigh a b . extras) (list a b extras))
         (println (weigh 1 2 3 4))")

;; ---------------------------------------------------------------------
;; variadic function types: (->* (t ...) trest tres)
;; ---------------------------------------------------------------------

;; derived: unannotated variadic defines get (->* (_ ...) _ _) -- the
;; arity floor is checked, everything else is dynamic
(admits "(define (weigh a b . extras) (list a b extras)) (weigh 1 2) (weigh 1 2 3 4)")
(rejects #rx"weigh expects at least 2 arguments, got 1"
         "(define (weigh a b . extras) (list a b extras)) (weigh 1)")

;; declared: (: f (->* ...)) types fixed args, extras, and the rest
;; binder ((List trest)) in the body
(admits "(: sum+ (->* (Int) Int Int))
         (define (sum+ a . rest) (if (null? rest) a (+ a (car rest))))
         (sum+ 1) (sum+ 1 2 3)")
(rejects #rx"sum\\+: argument has type Str, expected Int"
         "(: sum+ (->* (Int) Int Int))
          (define (sum+ a . rest) a)
          (sum+ \"one\")")
(rejects #rx"sum\\+: argument has type Str, expected Int"
         "(: sum+ (->* (Int) Int Int))
          (define (sum+ a . rest) a)
          (sum+ 1 2 \"three\")")
;; the rest binder is (List trest) in the body
(rejects #rx"\\+: argument has type Str, expected Int"
         "(: f (->* (Int) Str Int))
          (define (f a . rest) (+ a (car rest)))")
;; annotated fixed formals in a variadic define
(rejects #rx"g: argument has type Bool, expected Int"
         "(define (g [a : Int] . rest) a) (g #t)")
;; variadic lambdas
(admits "((lambda (a . rest) (cons a rest)) 1 2 3) ((lambda args args))")
(rejects #rx"application expects at least 1 arguments, got 0"
         "((lambda (a . rest) a))")
;; a variadic function fits a fixed-arrow expectation that supplies
;; its fixed arguments
(admits "(define (v a . r) a)
         (define (g [f : (-> Int Int)]) : Int (f 1))
         (g v)")
;; well-formedness of ->* annotations
(rejects #rx"unknown type constructor Nope"
         "(: f (->* ((Nope Int)) Int Int)) (define (f a . r) a)")

;; ---------------------------------------------------------------------
;; (Mut ...) containers: allocators produce it, mutators demand it,
;; read-only accessors take both flavors
;; ---------------------------------------------------------------------

(admits "(hash-set! (make-hash) 'a 1) (set-add! (make-set) 1)
         (vector-set! (make-vector 3) 0 1) (vector-set! (vector 1 2) 0 5)")
(admits "(hash-count (make-hash)) (hash-count (hash 'a 1))
         (hash-keys (make-hash)) (set-member? (make-set) 1)
         (vector-ref (vector 1 2) 0) (vector-length (make-vector 2))")
(admits "(let ([v : (Mut (Vec Int)) (make-vector 3)]) (vector-set! v 0 1))")
;; mutating a persistent collection is a type error when concrete...
(rejects #rx"hash-set!: argument has type \\(Hash _ _\\), expected \\(Mut \\(Hash Sym Int\\)\\)"
         "(hash-set! (hash 'a 1) 'b 2)")
(rejects #rx"hash-set!: argument has type \\(Hash Sym Int\\), expected \\(Mut \\(Hash Sym Int\\)\\)"
         "(let ([h : (Hash Sym Int) (hash)]) (hash-set! h 'a 1))")
(rejects #rx"set-add!: argument has type \\(Set _\\), expected \\(Mut \\(Set Int\\)\\)"
         "(set-add! (set) 1)")
(rejects #rx"vector-set!: argument has type \\(Vec Int\\), expected \\(Mut \\(Vec Int\\)\\)"
         "(define (f [v : (Vec Int)]) (vector-set! v 0 1))")
;; ...but stays dynamic (accepted) through _
(admits "(define (f h) (hash-set! h 'a 1)) (f (make-hash))")
;; a Mut value is fine where the plain container is expected
(admits "(define (count-em [h : (Hash Sym Int)]) : Int (hash-count h))
         (count-em (make-hash))")
;; ...the reverse is not: plain where Mut is demanded
(rejects #rx"f: argument has type \\(Hash Sym Int\\), expected \\(Mut \\(Hash Sym Int\\)\\)"
         "(define (f [h : (Mut (Hash Sym Int))]) (hash-set! h 'a 1))
          (define (g [h : (Hash Sym Int)]) (f h))")
;; well-formedness: Mut wraps containers only
(rejects #rx"\\(Mut \\.\\.\\.\\) wraps a Hash, Vec, or Set type, got Int"
         "(define (f [x : (Mut Int)]) x)")

;; ---------------------------------------------------------------------
;; prim types come from the manifest (spot checks through the checker)
;; ---------------------------------------------------------------------

(rejects #rx"string-length: argument has type Int, expected Str"
         "(string-length 5)")
(rejects #rx"substring: argument has type Sym, expected Str"
         "(substring 'nope 0 1)")
(admits "(string-concat (list \"a\" \"b\"))")
(rejects #rx"string-concat: argument has type \\(List Int\\), expected \\(List Str\\)"
         "(string-concat (list 1 2))")

;; ---------------------------------------------------------------------
;; exhaustiveness over closed ADTs: a warning (stderr), an error under
;; strict-exhaustiveness?
;; ---------------------------------------------------------------------

(warns #rx"^typecheck warning: match on Option is not exhaustive: missing None\n$"
       "(define-type (Option a) (None) (Some a))
        (define (f [o : (Option Int)]) : Int (match o [(Some x) x]))")
;; missing constructors are listed in declaration order
(warns #rx"^typecheck warning: match on E is not exhaustive: missing A, C\n$"
       "(define-type E (A) (B Int) (C))
        (define (f [e : E]) (match e [(B x) x]))")
;; the same program is an ERROR in strict mode, with the same text
(rejects/strict #rx"^typecheck: match on Option is not exhaustive: missing None$"
                "(define-type (Option a) (None) (Some a))
                 (define (f [o : (Option Int)]) : Int (match o [(Some x) x]))")
;; a catch-all clause (wildcard or binder) covers everything
(no-warn "(define-type (Option a) (None) (Some a))
          (define (f [o : (Option Int)]) : Int (match o [(Some x) x] [_ 0]))")
(no-warn "(define-type (Option a) (None) (Some a))
          (define (f [o : (Option Int)]) : Int (match o [(Some x) x] [other 0]))")
;; conservative: a guarded catch-all still counts as covering
(no-warn "(define-type (Option a) (None) (Some a))
          (define (f [o : (Option Int)]) : Int (match o [(Some x) x] [o2 #:when #t 0]))")
;; the gradual guarantee: a `_` scrutinee is exempt
(no-warn "(define-type (Option a) (None) (Some a))
          (define (f o) (match o [(Some x) x]))")
;; a fully covered match is quiet (bare nullary names count)
(no-warn "(define-type (Option a) (None) (Some a))
          (define (f [o : (Option Int)]) : Int (match o [(Some x) x] [None 0]))")
;; patterns we cannot prove partial count as covering everything
(no-warn "(define-type (Option a) (None) (Some a))
          (define (f [o : (Option Int)]) : Int (match o [(? procedure? p) 1]))")

(displayln "type tests: all passed")
