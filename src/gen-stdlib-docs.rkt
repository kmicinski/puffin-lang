#lang racket

;; Puffin -- gen-stdlib-docs.rkt: docs/STDLIB.md is *generated* from
;; the manifest (stdlib.rkt), so it cannot drift from the
;; implementation. Rerun after editing the manifest:
;;
;;   racket src/gen-stdlib-docs.rkt > docs/STDLIB.md

(require "stdlib.rkt")

(displayln "# The Puffin Standard Library")
(displayln "")
(displayln "*Generated from `src/stdlib.rkt` by `src/gen-stdlib-docs.rkt` — do not edit by hand.*")
(displayln "")
(displayln "Each primitive below is implemented three times, and the manifest keeps them in lockstep:")
(displayln "in C (`src/runtime/lib/*.c`, called by compiled code), in Racket (the `ref-impl` used by")
(displayln "the reference interpreters and the console REPL), and in JavaScript (the web REPL,")
(displayln "cross-checked against the same goldens).")
(displayln "")
(displayln "Compiler *intrinsics* — `+`, `-`, `*`, `eq?`, `<` (and the comparators that shrink to")
(displayln "them: `<=`, `>`, `>=`, `not`) — are open-coded by the backends and are not library calls;")
(displayln "they are listed in `src/irs.rkt`.")
(displayln "")
(displayln "| Primitive | Arity | Runtime entry | Description |")
(displayln "|---|---|---|---|")
(for ([s stdlib-primitives])
  (when (prim-spec-surface? s)
    (printf "| `~a` | ~a | `~a` | ~a |\n"
            (prim-spec-name s)
            (prim-spec-arity s)
            (prim-spec-rt-sym s)
            (prim-spec-doc s))))
(displayln "")
(displayln "## Compiler-internal primitives")
(displayln "")
(displayln "| Primitive | Arity | Runtime entry | Description |")
(displayln "|---|---|---|---|")
(for ([s stdlib-primitives])
  (unless (prim-spec-surface? s)
    (printf "| `~a` | ~a | `~a` | ~a |\n"
            (prim-spec-name s)
            (prim-spec-arity s)
            (prim-spec-rt-sym s)
            (prim-spec-doc s))))
(displayln "")
(displayln "## Adding a primitive")
(displayln "")
(displayln "1. Implement `pf_<name>` in a module under `src/runtime/lib/` (new data structures")
(displayln "   register their heap kind + display/equal handlers via `pf_register_kind`; add the")
(displayln "   module to `lib/stdlib_init.c` and the runtime `Makefile`, then `make -C src/runtime`).")
(displayln "2. Add one `prim-spec` entry to `src/stdlib.rkt` (name, arity, runtime symbol,")
(displayln "   reference implementation, doc line).")
(displayln "3. Regenerate this file. No compiler-pass changes are needed: the IR predicates,")
(displayln "   instruction selection, externs, and interpreters all derive from the manifest.")