#lang racket

;; Puffin -- ir-json.rkt: serialize a compilation trace, with
;; provenance, for the web pipeline visualizer.
;;
;; For each layer (the source program, then every pass's output) we
;; emit:
;;   - text: a pretty-printed rendering of the IR
;;   - nodes: [id, start, end, parent-id] character spans, one per
;;     s-expression node (pairs and block hashes; atoms resolve to
;;     their enclosing node client-side)
;;   - back: { node-id -> node-id in the PREVIOUS layer }, resolved
;;     from the provenance table (provenance.rkt): pass-through
;;     subterms resolve by object identity, constructed nodes by
;;     their recorded origin (following the chain as needed)
;;
;; The final layer is the rendered assembly: plain text plus a
;; per-line back map to prelude-and-conclusion instructions, built
;; from the backends' render-lines.
;;
;; JSON shape:
;; { "source": <original text>,
;;   "target": "arm64",
;;   "passes": [ {"name","text","nodes","back"} ...,
;;               {"name":"render-asm","text","lineBack":{line->prevId}} ] }

(require json)
(require "provenance.rkt")
(require "system.rkt")

(provide trace->pipeline-jsexpr)

;; ---------------------------------------------------------------------
;; The span-tracking IR printer
;; ---------------------------------------------------------------------

;; A program-info hash (slot 1 of (program ...)) prints compactly.
(define (info-hash? v) (and (hash? v) (hash-has-key? v 'globals)))

(define (atom->string v)
  (cond [(symbol? v) (symbol->string v)]
        [(boolean? v) (if v "#t" "#f")]
        [(number? v) (number->string v)]
        [(string? v) (format "~s" v)]
        [(set? v) (format "~a" (sort (set->list v) (λ (a b) (string<? (format "~a" a) (format "~a" b)))))]
        [else (format "~s" v)]))

;; flat width of a term (memoized on pairs/hashes)
(define (make-width-fn)
  (define memo (make-hasheq))
  (define (width v)
    (cond
      [(pair? v)
       (hash-ref! memo v
                  (λ ()
                    (let loop ([v v] [acc 1]) ;; "("
                      (cond [(null? v) (add1 acc)]
                            [(pair? v) (loop (cdr v) (+ acc (width (car v)) 1))]
                            [else (+ acc 3 (width v) 1)]))))]
      [(info-hash? v) 20]
      [(hash? v)
       (hash-ref! memo v
                  (λ () (for/fold ([acc 10]) ([(k val) (in-hash v)])
                          (+ acc (width k) (width val) 4))))]
      [else (string-length (atom->string v))]))
  width)

;; Print v; record node spans. Returns (values text nodes) where
;; nodes = (list (vector id start end parent-id) ...)
(define (print-ir v)
  (define out (open-output-string))
  (define nodes '())
  (define next-id 0)
  (define obj->id (make-hasheq))
  (define width (make-width-fn))
  (define (register! v start end parent)
    (define id next-id)
    (set! next-id (add1 next-id))
    ;; a shared subterm can print in several places; obj->id keeps
    ;; one of its ids (any is a fine back-edge target), while the
    ;; node record carries the object for this occurrence
    (hash-set! obj->id v id)
    (set! nodes (cons (vector id start end parent v) nodes))
    id)
  (define (pos) (string-length (get-output-string out)))
  (define (emit-atom v) (display (atom->string v) out))
  ;; blocks hashes print as (blocks [label <tail>] ...)
  (define (emit-hash v indent parent)
    (define start (pos))
    (define id (register! v start start parent)) ;; end fixed up below
    (define labels (sort (hash-keys v) (λ (a b) (string<? (format "~a" a) (format "~a" b)))))
    (display "(blocks" out)
    (for ([l labels])
      (display (format "\n~a[~a\n~a " (make-string (+ indent 2) #\space) l
                       (make-string (+ indent 3) #\space)) out)
      (emit (hash-ref v l) (+ indent 4) id)
      (display "]" out))
    (display ")" out)
    (patch-end! id (pos)))
  (define (patch-end! id end)
    (set! nodes (map (λ (n) (if (= (vector-ref n 0) id)
                                (vector id (vector-ref n 1) end (vector-ref n 3) (vector-ref n 4))
                                n))
                     nodes)))
  (define (emit v indent parent)
    (cond
      [(info-hash? v)
       (display (format "#info[globals=~a]" (hash-ref v 'globals)) out)]
      [(hash? v) (emit-hash v indent parent)]
      [(pair? v)
       (define start (pos))
       (define id (register! v start start parent))
       (define flat? (<= (+ indent (width v)) 100))
       (display "(" out)
       (let loop ([rest v] [first? #t])
         (cond
           [(null? rest) (void)]
           [(pair? rest)
            (unless first?
              (if flat?
                  (display " " out)
                  (display (format "\n~a" (make-string (+ indent 2) #\space)) out)))
            (emit (car rest) (if flat? indent (+ indent 2)) id)
            (loop (cdr rest) #f)]
           [else
            (display " . " out)
            (emit rest indent id)]))
       (display ")" out)
       (patch-end! id (pos))]
      [else (emit-atom v)]))
  (emit v 0 -1)
  (values (get-output-string out) (reverse nodes) obj->id))

;; ---------------------------------------------------------------------
;; Back-edge resolution
;; ---------------------------------------------------------------------

;; For node object n at layer k, find its id in the previous layer's
;; obj->id map: object identity first (pass-through), then a bounded
;; search over the candidate-origin graph.
(define (resolve-back n prev-map)
  (define fuel (box 64))
  (define (search t)
    (and (positive? (unbox fuel))
         (begin
           (set-box! fuel (sub1 (unbox fuel)))
           (or (hash-ref prev-map t #f)
               (ormap search (prov-candidates t))))))
  (or (hash-ref prev-map n #f)
      (ormap search (prov-candidates n))))

;; ---------------------------------------------------------------------
;; Whole-trace serialization
;; ---------------------------------------------------------------------

;; trace: the list of pass hashes from run-chain (each with
;; 'pass-name, 'input, 'output). render-lines-of: #f, or a function
;; program -> (listof (cons line-text instr-node-or-#f)) for the
;; final asm layer (target-specific; see the backends).
(define (trace->pipeline-jsexpr trace source-text target-name render-lines-of)
  (define layers '())  ;; accumulated jsexpr layers, reversed
  (define prev-map (make-hasheq)) ;; obj -> id of previous layer
  (define (add-ir-layer! name ir)
    (define-values (text nodes obj->id) (print-ir ir))
    (define back
      (for*/hash ([nd nodes]
                  [target (in-value (resolve-back (vector-ref nd 4) prev-map))]
                  #:when target)
        (values (string->symbol (number->string (vector-ref nd 0))) target)))
    (set! layers (cons (hash 'name name
                             'text text
                             'nodes (map (λ (nd) (take (vector->list nd) 4)) nodes)
                             'back back)
                       layers))
    (set! prev-map obj->id))
  ;; layer 0: the source program s-expression (input of the first pass)
  (add-ir-layer! "source" (hash-ref (first trace) 'input))
  (for ([elt trace])
    (define name (hash-ref elt 'pass-name))
    (define output (hash-ref elt 'output))
    (cond
      [(string? output)
       ;; the rendered assembly: line-level provenance. An entry's
       ;; text may span several lines (arm's adrp/add pairs): split,
       ;; keeping the same origin for each resulting line.
       (define lines
         (append-map (λ (ln)
                       (map (λ (t) (cons t (cdr ln)))
                            (string-split (car ln) "\n")))
                     (if render-lines-of
                         (render-lines-of (hash-ref elt 'input))
                         '())))
       (define line-back
         (for/hash ([ln lines] [i (in-naturals)]
                    #:when (and (cdr ln) (resolve-back (cdr ln) prev-map)))
           (values (string->symbol (number->string i))
                   (resolve-back (cdr ln) prev-map))))
       (set! layers (cons (hash 'name name
                                'text (if (pair? lines)
                                          (string-join (map car lines) "\n")
                                          output)
                                'lineBack line-back
                                'nodes '()
                                'back (hash))
                          layers))]
      [else (add-ir-layer! name output)]))
  (hash 'source source-text
        'target target-name
        'passes (reverse layers)))
