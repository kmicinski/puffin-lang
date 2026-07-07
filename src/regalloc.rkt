#lang racket

;; Puffin -- regalloc.rkt: live-range register allocation.
;;
;; Replaces the class compiler's assign-homes (everything on the
;; stack) with simple live-range allocation, shared by both
;; backends:
;;
;;   1. per-instruction liveness, by backward dataflow over the
;;      block CFG (fixpoint at block granularity, then a backward
;;      walk within each block);
;;   2. one live *interval* per variable: the convex hull of every
;;      point where it occurs or is live, over a fixed linear order
;;      of blocks (reverse postorder from the entry). Hulls ignore
;;      lifetime holes--that is the "simple" in simple live-range
;;      allocation, and it is always conservative;
;;   3. linear scan (Poletto & Sarkar) over the sorted intervals.
;;
;; We hand out only callee-saved registers (system.rkt's
;; allocatable-registers-list): values in them survive calls, so
;; intervals crossing calls need no special casing. Intervals that
;; don't get a register spill to rbp/x29-relative stack slots.
;;
;; The backends stay in charge of instruction semantics: they pass
;; in `uses+defs`, a function from an instruction to
;; (list use-vars def-vars). This file never inspects opcodes.
;;
;; Output per definition: (define ,info (,f ,args ...) ,blocks)
;; where info is a hash with:
;;   'var->loc      var -> (reg r) or (deref (reg <fp>) offset)
;;   'callee-saved  the allocated registers, to save/restore in the
;;                  prelude/conclusion
;;   'spill-bytes   stack bytes needed for spilled variables

(require "system.rkt")
(require "irs.rkt")
(require "provenance.rkt")

(provide allocate-registers-with)

;; variables mentioned in an operand
(define (operand-vars op)
  (match op
    [`(var ,x) (list x)]
    [_ '()]))

;; block successors: labels named by control instructions
(define (block-successors instrs)
  (foldl (λ (i acc)
           (match i
             [`(jmp ,l) (cons l acc)]
             [`(jmp-if ,_ ,l) (cons l acc)]
             [`(goto ,l) (cons l acc)]
             [_ acc]))
         '()
         instrs))

;; reverse postorder over blocks from the entry label
(define (block-order blocks entry)
  (define visited (mutable-set))
  (define order '())
  (define (dfs l)
    (when (and (hash-has-key? blocks l) (not (set-member? visited l)))
      (set-add! visited l)
      (for ([s (block-successors (hash-ref blocks l))]) (dfs s))
      (set! order (cons l order))))
  (dfs entry)
  ;; append any unreachable blocks (shouldn't happen, but be total)
  (append order (filter (λ (l) (not (set-member? visited l))) (hash-keys blocks))))

(define (allocate-registers-with p uses+defs)
  (define fp (frame-pointer-register))
  (define (per-defn defn)
    (match-define `(define ,locals (,f ,args ...) ,blocks) defn)
    (define order (block-order blocks f))

    ;; ---- block-level liveness fixpoint -------------------------------
    ;; One mutable set walked backward per block: O(uses+defs) per
    ;; instruction instead of persistent-set unions (which made this
    ;; and the interval pass quadratic in live-set size -- visible on
    ;; the -O1-inlined puffincc build).
    (define uses+defs-of (make-hasheq))  ;; instr -> (list uses defs), cached
    (define (instr-uses+defs i)
      (or (hash-ref uses+defs-of i #f)
          (let ([ud (uses+defs i)]) (hash-set! uses+defs-of i ud) ud)))
    (define live-in (make-hash))   ;; label -> set of vars (immutable snapshot)
    (define (block-live-in l live-out)
      ;; walk the block backward from live-out
      (define live (set-copy live-out))
      (for ([i (in-list (reverse (hash-ref blocks l)))])
        (match-define (list us ds) (instr-uses+defs i))
        (for ([d (in-list ds)]) (set-remove! live d))
        (for ([u (in-list us)]) (set-add! live u)))
      live)
    (define (live-out-of l)
      (define out (mutable-set))
      (for ([s (block-successors (hash-ref blocks l))])
        (set-union! out (hash-ref live-in s (mutable-set))))
      out)
    (let fixpoint ()
      (define changed #f)
      (for ([l order])
        (define new-in (block-live-in l (live-out-of l)))
        (unless (equal? new-in (hash-ref live-in l (mutable-set)))
          (hash-set! live-in l new-in)
          (set! changed #t)))
      (when changed (fixpoint)))

    ;; ---- intervals -----------------------------------------------------
    ;; global linear numbering over `order`. A hull only needs its
    ;; endpoints anchored: touching every occurrence, plus each
    ;; block's live-in vars at its first point and live-out vars at
    ;; its last, covers every point of liveness (a var live at point
    ;; k has a def-or-live-in anchor at or before k and a
    ;; use-or-live-out anchor at or after k, and hulls are convex).
    (define intervals (make-hash)) ;; var -> (vector start end)
    (define (touch! v i)
      (define cur (hash-ref intervals v #f))
      (if cur
          (begin (when (< i (vector-ref cur 0)) (vector-set! cur 0 i))
                 (when (> i (vector-ref cur 1)) (vector-set! cur 1 i)))
          (hash-set! intervals v (vector i i))))
    (define n 0)
    (for ([l order])
      (define instrs (hash-ref blocks l))
      (define start n)
      (define end (+ n (max 0 (sub1 (length instrs)))))
      (for ([v (in-set (hash-ref live-in l (mutable-set)))]) (touch! v start))
      (for ([v (in-set (live-out-of l))]) (touch! v end))
      (for ([i instrs])
        (match-define (list us ds) (instr-uses+defs i))
        (for ([v (in-list us)]) (touch! v n))
        (for ([v (in-list ds)]) (touch! v n))
        (set! n (add1 n))))

    ;; ---- linear scan ---------------------------------------------------
    (define regs (allocatable-registers-list))
    (define sorted (sort (hash->list intervals) < #:key (λ (iv) (vector-ref (cdr iv) 0)))) ;; by start
    (define var->loc (make-hash))
    (define active '())   ;; list of (end var reg), kept sorted by end
    (define free-regs regs)
    (define spill-count 0)
    (define (expire! start)
      (define-values (dead live) (partition (λ (a) (< (first a) start)) active))
      (for ([a dead]) (set! free-regs (cons (third a) free-regs)))
      (set! active live))
    ;; symbolic slot for now; materialized as an fp-relative offset
    ;; *below* the callee-saved save area once we know its size
    (define (spill-slot!)
      (set! spill-count (add1 spill-count))
      `(spill ,spill-count))
    (for ([iv sorted])
      (match-define (cons v (vector start end)) iv)
      (expire! start)
      (cond
        [(pair? free-regs)
         (define r (first free-regs))
         (set! free-regs (rest free-regs))
         (hash-set! var->loc v `(reg ,r))
         (set! active (sort (cons (list end v r) active) < #:key first))]
        [else
         ;; no free register: spill whichever of {current, furthest
         ;; active} ends last
         (define furthest (if (pair? active) (last active) #f))
         (cond
           [(and furthest (> (first furthest) end))
            ;; steal its register, spill it
            (match-define (list f-end f-var f-reg) furthest)
            (hash-set! var->loc f-var (spill-slot!))
            (hash-set! var->loc v `(reg ,f-reg))
            (set! active (sort (cons (list end v f-reg) (remove furthest active)) < #:key first))]
           [else
            (hash-set! var->loc v (spill-slot!))])]))

    ;; ---- rewrite operands ----------------------------------------------
    ;; the frame below the frame pointer: [callee-saved saves][spills]
    (define used-callee-saved*
      (filter (λ (r) (for/or ([(v loc) (in-hash var->loc)]) (equal? loc `(reg ,r))))
              regs))
    (define save-area-bytes (callee-save-area-bytes (length used-callee-saved*)))
    (define (materialize loc)
      (match loc
        [`(spill ,k) `(deref (reg ,fp) ,(- (+ save-area-bytes (* 8 k))))]
        [_ loc]))
    (define (home op)
      (match op
        [`(var ,x) (materialize
                    (hash-ref var->loc x
                              (λ () (error 'allocate-registers "no home for ~a" x))))]
        [_ op]))
    (define (rewrite-instr i)
      (match i
        [`(,op ,operands ...) (prov `(,op ,@(map home operands)) i)]))
    (define (useless-move? i)
      (match i
        [`(movq ,a ,b) (equal? a b)]
        [`(mov ,a ,b) (equal? a b)]
        [_ #f]))
    (define blocks+
      (foldl (λ (l acc)
               (hash-set acc l (filter (λ (i) (not (useless-move? i)))
                                       (map rewrite-instr (hash-ref blocks l)))))
             (hash)
             (hash-keys blocks)))
    (define info (hash 'var->loc (for/hash ([(v loc) (in-hash var->loc)])
                                   (values v (materialize loc)))
                       'callee-saved used-callee-saved*
                       'spill-bytes (* 8 spill-count)))
    `(define ,info (,f ,@args) ,blocks+))
  (match p
    [`(program ,n-globals ,defns ...)
     `(program ,n-globals ,@(map per-defn defns))]))
