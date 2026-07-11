#lang racket

;; Puffin -- diff-ir.rkt: compare puffincc's IR (via its dump-after
;; directive) against the Racket reference's, modulo gensym spelling.
;;
;;   racket src/diff-ir.rkt <pass-name> <prog.puf> [target] [olvl]
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
(require "modules.rkt")

(define (normalize tree)
  (define seen (make-hash))
  (define counter 0)
  (define (norm-sym s)
    (define str0 (symbol->string s))
    ;; a gensym'd arithmetic name (+198) prints bare and would read
    ;; back from puffincc's dump as a number, so its serialize-ir
    ;; prefixes number-reading symbols with "%"; mirror that here
    ;; (same predicate as the runtime's string->number: strtoll,
    ;; i.e. an optional sign then digits)
    (define str (if (regexp-match #rx"^[+-]?[0-9]+$" str0)
                    (string-append "%" str0)
                    str0))
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
          ;; puffincc's serialize-ir renders a string as
          ;; (string-repr <byte> ...) -- println would display its
          ;; contents unquoted (unreadable if it holds "," or ")");
          ;; mirror that here
          [(string? v)
           (cons 'string-repr (bytes->list (string->bytes/utf-8 v)))]
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
  ;; `rest` is a LIST of the remaining argv (optional [target] [olvl]);
  ;; parse positionally (the old (vector ...) patterns never matched a
  ;; list, so target/olvl were silently stuck at arm64/1)
  (define tgt (if (>= (length rest) 1) (string->symbol (first rest)) 'arm64))
  (define olvl (if (>= (length rest) 2) (string->number (second rest)) 1))
  ;; reference side
  (define program (read-program-file prog))
  (define ref
    (parameterize ([target tgt] [optimize-level olvl])
      (let loop ([chain (all-passes)] [ir program])
        (match chain
          ['() (error 'diff-ir "no such pass: ~a" pass-name)]
          [`((,pass ,name ,_ ,_ ,_) . ,more)
           (define out (pass ir))
           (if (equal? name pass-name) out (loop more out))]))))
  ;; puffincc side: module programs need file mode (a require DAG
  ;; cannot come in on stdin), so they use the --dump-after CLI flag;
  ;; plain files keep the classic piped directives
  (define cmd
    (if (module-forms? (read-module-forms prog))
        (format "build/puffincc --dump-after ~a -t ~a -O ~a ~a"
                pass-name tgt olvl prog)
        (format "{ echo '(target ~a)'; echo '(dump-after ~a)'; cat ~a; } | build/puffincc -O ~a"
                tgt pass-name prog olvl)))
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
