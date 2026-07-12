#lang racket
;; Checked-arithmetic contract: applying + - * or a comparison to a
;; non-integer is a RUNTIME ERROR naming the operator and the value —
;; byte-identical on every route — never a silently-computed garbage
;; word (the "#<unknown:N>" bug). The value slips past the checker
;; through _ (gradual), so the runtime check is the load-bearing net.
;;
;;   racket src/test-arith.rkt
;;
;; Routes: reference interp (bin/puffin -i) and the bytecode VM
;; (bin/puffin -c -t bytecode + bin/puffin-vm). The native backends'
;; checks are exercised the same way once wired (add 'native here).

(define here (path-only (path->complete-path (find-system-path 'run-file))))
(define (repo p) (build-path here 'up p))

(define cases
  ;; (source expected-stderr-line)
  (list
   (list "(define (foo a [b : Int] c) (+ a b c)) (println (foo 1 5 \"Hello\"))"
         "puffin runtime error: +: expected Int, got Hello")
   (list "(define (f x) (* 2 x)) (println (f 'oops))"
         "puffin runtime error: *: expected Int, got oops")
   (list "(define (g x) (if (< x 10) 'small 'big)) (println (g \"nine\"))"
         "puffin runtime error: <: expected Int, got nine")
   (list "(define (h x) (- x)) (println (h #t))"
         "puffin runtime error: -: expected Int, got #t")))

(define (run/capture-stderr cmd . args)
  (define-values (proc out in err)
    (apply subprocess #f #f #f cmd args))
  (close-output-port in)
  (define err-text (port->string err))
  (port->string out)
  (subprocess-wait proc)
  err-text)

(define failures 0)
(define tmp (find-system-path 'temp-dir))

(for ([c cases] [i (in-naturals)])
  (match-define (list src expected) c)
  (define f (build-path tmp (format "arith-~a-~a.puf" (current-milliseconds) i)))
  (call-with-output-file f #:exists 'replace (λ (p) (displayln src p)))
  ;; route 1: reference interpreter
  (define e1 (run/capture-stderr (repo "bin/puffin") "-i" (path->string f)))
  (unless (string-contains? e1 expected)
    (set! failures (add1 failures))
    (printf "FAIL [interp] ~a\n  expected: ~a\n  stderr:   ~a\n" src expected e1))
  ;; route 2: bytecode VM
  (define pbc (path-replace-extension f ".pbc"))
  (run/capture-stderr (repo "bin/puffin") "-c" "-t" "bytecode"
                      "-o" (path->string pbc) (path->string f))
  (define e2 (run/capture-stderr (repo "bin/puffin-vm") (path->string pbc)))
  (unless (string-contains? e2 expected)
    (set! failures (add1 failures))
    (printf "FAIL [bytecode] ~a\n  expected: ~a\n  stderr:   ~a\n" src expected e2)))

(if (zero? failures)
    (printf "arith tests: all passed (~a cases x 2 routes)\n" (length cases))
    (begin (printf "~a failures\n" failures) (exit 1)))
