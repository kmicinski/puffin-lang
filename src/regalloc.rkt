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
    (define (instr-uses i)  (first (uses+defs i)))
    (define (instr-defs i)  (second (uses+defs i)))
    (define live-in (make-hash))   ;; label -> set of vars
    (define (block-live-in l live-out)
      ;; walk the block backward from live-out
      (foldr (λ (i acc) (set-union (list->set (instr-uses i))
                                   (set-subtract acc (list->set (instr-defs i)))))
             live-out
             (hash-ref blocks l)))
    (define (live-out-of l)
      (foldl (λ (s acc) (set-union acc (hash-ref live-in s (set))))
             (set)
             (block-successors (hash-ref blocks l))))
    (let fixpoint ()
      (define changed #f)
      (for ([l order])
        (define new-in (block-live-in l (live-out-of l)))
        (unless (equal? new-in (hash-ref live-in l (set)))
          (hash-set! live-in l new-in)
          (set! changed #t)))
      (when changed (fixpoint)))

    ;; ---- per-instruction live sets and intervals ----------------------
    ;; global linear numbering over `order`; extend each var's
    ;; interval to cover every occurrence and every point of liveness
    (define intervals (make-hash)) ;; var -> (cons start end)
    (define (touch! v i)
      (define cur (hash-ref intervals v (cons i i)))
      (hash-set! intervals v (cons (min (car cur) i) (max (cdr cur) i))))
    (define n 0)
    (for ([l order])
      (define instrs (hash-ref blocks l))
      (define outs (live-out-of l))
      ;; live-after set for each instruction: fold backward building
      ;; (before_0 before_1 ... before_{n-1} outs); instruction k's
      ;; live-after is before_{k+1}, i.e. the cdr, already in order
      (define live-afters
        (cdr (foldr (λ (i acc)
                      (define after (car acc))
                      (define before (set-union (list->set (instr-uses i))
                                                (set-subtract after (list->set (instr-defs i)))))
                      (cons before acc))
                    (list outs)
                    instrs)))
      (for ([i instrs] [after live-afters])
        (for ([v (instr-uses i)]) (touch! v n))
        (for ([v (instr-defs i)]) (touch! v n))
        (for ([v after]) (touch! v n))
        (set! n (add1 n))))

    ;; ---- linear scan ---------------------------------------------------
    (define regs (allocatable-registers-list))
    (define sorted (sort (hash->list intervals) < #:key cadr)) ;; by start
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
      (match-define (cons v (cons start end)) iv)
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
        [`(,op ,operands ...) `(,op ,@(map home operands))]))
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
