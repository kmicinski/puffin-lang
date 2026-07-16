This repository is the Puffin language (see README.md). Ground rules
for working on it:

- **puffincc (`puffincc-src/`, written in Puffin) is the primary
  compiler and the source of truth.** Extend it first. Build it
  Racket-free with `bin/bootstrap` (committed seed `boot/puffincc.pbc`
  + the bytecode VM; docs/BOOTSTRAP.md §7) and run the golden corpus
  with `tools/test-corpus.sh` (its `gen` mode writes `src/goldens` —
  puffincc + the VM are the golden authority). The Racket
  implementation in `src/` is the consistency oracle: keep the two in
  lockstep and verify with `racket src/diff-ir.rkt <pass> <prog>` and
  the oracle legs of the corpus (`racket src/test.rkt -m all`).
- The golden corpus contains only PASSING programs; **rejection
  behavior is corpus-tested too**: `tools/test-errors.sh` drives every
  must-fail program in `src/errors-corpus/` down every route (interp,
  Racket->VM, puffincc->VM, both native backends) and demands
  byte-identical diagnostics (its `gen` mode captures `.expect` files
  from agreed route output and REFUSES on disagreement). After
  touching a checker, resolver, reader, or runtime error message, run
  it — and `node web/test-errors.mjs` for the same corpus through the
  wasm VM.
- If `puffincc-src` outgrows the committed seed (a new language
  feature the seed can't compile), refresh the seed first
  (`bin/refresh-boot` from a commit that can compile the tree; see
  docs/BOOTSTRAP.md "Seed freshness").
- The browser playground (`web/`) runs puffincc compiled to bytecode
  on the wasm VM — there is no JS implementation of the language.
  After touching the compiler, runtime, or VM: `tools/gen-web-vm.sh`
  then `(cd web && npm test)`.
- The stdlib prim manifest (`src/stdlib.rkt`) and prelude
  (`src/prelude.puf`) are single sources of truth; regenerate derived
  tables (`racket src/gen-puffincc-tables.rkt`, `make -C src/vm` for
  vm-prims.inc — self-hosted via `tools/gen-vm-prims.puf`, Racket
  cross-checked when present — `racket tools/gen-prim-names.rkt`)
  rather than editing generated files.
- Puffin dialect notes for `puffincc-src/` edits: `string-append` is
  binary; no `with-handlers`; no `(or ...)` match patterns or `match*`;
  `(unquote ,e)`-shaped quasiquote patterns are escapes; `#:kw`
  literals in quasiquote patterns break the hosted build; unary
  `(- a)` must be `(- 0 a)`.
