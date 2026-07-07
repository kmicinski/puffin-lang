#lang racket

;; Puffin -- test-types.rkt: the gradual typechecker's verdicts
;; (docs/TYPES.md). Success paths live in the golden corpus
;; (typed-*); these are the compile-time rejections plus the
;; inference-leniency cases the corpus can't express as goldens.
;; Run: racket src/test-types.rkt

(require rackunit "types.rkt" "modules.rkt")

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

(displayln "type tests: all passed")
