#lang racket

;; Puffin -- diff-ir.rkt: compare puffincc's IR (via its dump-after
;; directive) against the Racket reference's, modulo gensym spelling.
;;
;;   racket src/diff-ir.rkt <pass-name> <prog.puf> [target]
;;
;; Runs the reference chain up to <pass-name>, runs
;; `build/puffincc` with (dump-after <pass-name>), alpha-normalizes
;; gensym'd symbols on both sides (any symbol ending in digits is
;; renamed to base%N in first-occurrence order), and diffs. Prints
;; MATCH or the first divergence. This is the chain-mode debugging
;; story extended across implementations.

(require "system.rkt")
(require "compile.rkt")
(require "main.rkt")

(define (normalize tree)
  (define seen (make-hash))
  (define counter 0)
  (define (norm-sym s)
    (define str (symbol->string s))
    (define m (regexp-match #rx"^(.*?)[.]?[0-9]+$" str))
    (cond
      [(and m (> (string-length (second m)) 0))
       (hash-ref! seen s
                  (λ ()
                    (set! counter (add1 counter))
                    (string->symbol (format "~a%~a" (second m) counter))))]
      [else s]))
  (let walk ([v tree])
    (cond [(symbol? v) (norm-sym v)]
          [(pair? v) (cons (walk (car v)) (walk (cdr v)))]
          [(hash? v)
           ;; align with puffincc's serialize-ir
           (cons 'hash-repr
                 (for/list ([k (sort (hash-keys v) (λ (a b) (string<? (format "~a" a) (format "~a" b))))])
                   (list (walk k) (walk (hash-ref v k)))))]
          [(set? v)
           (cons 'set-repr
                 (sort (map walk (set->list v)) (λ (a b) (string<? (format "~a" a) (format "~a" b)))))]
          [else v])))

(module+ main
  (match-define (vector pass-name prog rest ...) (current-command-line-arguments))
  (define tgt (match rest [(vector t) (string->symbol t)] [_ 'arm64]))
  ;; reference side
  (define program (read-program-file prog))
  (define ref
    (parameterize ([target tgt])
      (let loop ([chain (all-passes)] [ir program])
        (match chain
          ['() (error 'diff-ir "no such pass: ~a" pass-name)]
          [`((,pass ,name ,_ ,_ ,_) . ,more)
           (define out (pass ir))
           (if (equal? name pass-name) out (loop more out))]))))
  ;; puffincc side
  (define cmd (format "{ echo '(target ~a)'; echo '(dump-after ~a)'; cat ~a; } | build/puffincc"
                      tgt pass-name prog))
  (define pcc-out (with-output-to-string (λ () (system cmd))))
  (define pcc (with-input-from-string pcc-out read))
  (define n-ref (normalize ref))
  (define n-pcc (normalize pcc))
  (if (equal? n-ref n-pcc)
      (displayln "MATCH")
      (let find ([a n-ref] [b n-pcc] [path '()])
        (cond
          [(equal? a b) (void)]
          [(and (list? a) (list? b))
           (if (not (= (length a) (length b)))
               (printf "DIFF at ~a: lengths ~a vs ~a\n  ref: ~a\n  pcc: ~a\n"
                       (reverse path) (length a) (length b)
                       (substring (format "~s" a) 0 (min 200 (string-length (format "~s" a))))
                       (substring (format "~s" b) 0 (min 200 (string-length (format "~s" b)))))
               (for ([x a] [y b] [i (in-naturals)])
                 (find x y (cons i path))))]
          [else
           (printf "DIFF at ~a:\n  ref: ~s\n  pcc: ~s\n" (reverse path) a b)]))))
