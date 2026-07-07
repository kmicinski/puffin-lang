#lang racket

;; Puffin -- provenance.rkt: where did this IR node come from?
;;
;; Every pass's recursive walker is wrapped (one line per pass; see
;; compile.rkt, the backends, regalloc.rkt) so that each node it
;; constructs is tagged with the input node it was built from. Tags
;; live in a global weak eq-hash: the IRs stay plain s-expressions,
;; no pattern in any pass changes, and nodes that a pass returns
;; unchanged need no tag at all (object identity *is* provenance).
;;
;; Provenance composes across passes for free: run-chain feeds each
;; pass's actual output object to the next pass, so following
;; prov-of from a node in layer k lands on an object that occurs in
;; layer k-1's tree. The serializer (ir-json.rkt) resolves those
;; object references into per-layer node ids for the web UI.
;;
;; Discipline:
;;   - (prov out in): tag `out` (a pair, or a hash for block maps)
;;     as originating from `in`. First tag wins -- inner walkers run
;;     before outer wrappers, so the most specific origin sticks.
;;   - Atoms (symbols, fixnums, ...) are interned/immutable and
;;     cannot carry identity; the UI resolves clicks on them to the
;;     enclosing tagged node.
;;   - Untagged constructed nodes are fine: consumers walk up the
;;     output tree to the nearest tagged ancestor.

(provide prov prov-each prov-of prov-candidates prov-chain)

(require "system.rkt")

;; out-node -> (listof in-node), most specific (earliest-recorded)
;; first. Weak keys: dead IRs drop their entries. A node can carry a
;; few candidate origins: CPS-shaped passes (anf-convert) construct a
;; node inside one continuation and return it through several walker
;; frames, and which frame's input is the *resolvable* one (i.e.
;; actually part of the previous layer's tree) is only decidable at
;; serialization time -- so we keep the candidates and let
;; resolution try them in order.
(define prov-table (make-weak-hasheq))
(define max-candidates 4)

(define (taggable? v) (or (pair? v) (hash? v)))

;; Tag `out` with origin `in`. Returns out, so walkers can wrap
;; their body. Atom origins are skipped: they are interned (so
;; ambiguous as identities) and never registered by the serializer;
;; skipping them lets the next-outer walker frame supply the
;; compound origin instead.
(define (prov out in)
  (when (and (retain-trace?) (taggable? out) (taggable? in) (not (eq? out in)))
    (define cur (hash-ref prov-table out '()))
    (when (and (< (length cur) max-candidates)
               (not (memq in cur)))
      (hash-set! prov-table out (append cur (list in)))))
  out)

;; Tag every element of a list of nodes (e.g. emitted instructions)
;; with the same origin. Returns the list.
(define (prov-each outs in)
  (for ([o outs]) (prov o in))
  outs)

;; The primary (most specific) origin, or #f.
(define (prov-of node)
  (match (hash-ref prov-table node '())
    [`(,first-tag ,_ ...) first-tag]
    [_ #f]))

;; All candidate origins, most specific first.
(define (prov-candidates node) (hash-ref prov-table node '()))

;; The transitive origin chain of a node (nearest first), following
;; primary tags.
(define (prov-chain node)
  (let loop ([n (prov-of node)] [acc '()])
    (if (and n (not (member n acc eq?)))
        (loop (prov-of n) (cons n acc))
        (reverse acc))))
