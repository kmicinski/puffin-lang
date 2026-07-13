# Puffin

The course compiler, grown into a language. **The compiler is
`puffincc`** — self-hosting, written in Puffin (`puffincc-src/`, a
module DAG) — with three backends (x86-64, arm64, bytecode), the
gradual typechecker, and the module system. It is the single source
of ground truth for the language: the browser playground (`web/`)
runs *puffincc itself*, compiled to bytecode, on a WebAssembly build
of the bytecode VM (`src/vm/`) — same compiler, same typechecker,
same semantics everywhere.

**Building and testing Puffin requires no Racket**: `bin/bootstrap`
builds `build/puffincc` from the committed bytecode seed
(`boot/puffincc.pbc`) with nothing but a C toolchain, and
`tools/test-corpus.sh` runs the golden corpus through puffincc + the
VM — which are the **golden authority** (its `gen` mode is what
writes `src/goldens`).

The Racket implementation in `src/` is the optional **consistency
oracle**: it cross-checks puffincc per-pass (`src/diff-ir.rkt`), and
its reference interpreter re-derives the goldens as a differential
test (`racket src/test.rkt -m gen` + diff — the two implementations
must agree byte-for-byte; they do, 309/309). It also hosts the
alternative stage-1 bootstrap (`bin/build-puffincc`) and the
**generators**: after changing the stdlib manifest (`src/stdlib.rkt`)
or prelude, regenerating the derived tables (`src/vm/vm-prims.inc`,
`puffincc-src/tables.puf`, docs/STDLIB.md) still uses Racket — that
is the one remaining Racket-needed activity. It is not the primary
compiler; extend puffincc first and verify against `src/`.

Start with [docs/DELTA.md](docs/DELTA.md) — "what's the delta from
p5?" — then [docs/LANGUAGE.md](docs/LANGUAGE.md),
[docs/TYPES.md](docs/TYPES.md), [docs/MODULES.md](docs/MODULES.md),
[docs/OPTIMIZER.md](docs/OPTIMIZER.md),
[docs/STDLIB.md](docs/STDLIB.md), and — for the browser/VM
architecture — [docs/WASM-VM.md](docs/WASM-VM.md) +
[docs/BYTECODE.md](docs/BYTECODE.md). The FFI design (typed foreign
imports; not yet implemented) is [docs/FFI.md](docs/FFI.md).

```
bin/bootstrap                       # Racket-free bootstrap: cc-only, from
                                    # the committed seed boot/puffincc.pbc,
                                    # with a stage-2/3 fixpoint proof
build/puffincc prog.puf -o prog     # puffincc compiles + links natively
build/puffincc -t bytecode prog.puf -o prog.pbc   # ... or to bytecode
bin/puffin-vm prog.pbc              # run bytecode on the native VM
tools/test-corpus.sh                # the golden corpus, Racket-free
                                    # (`gen` mode WRITES the goldens)
tools/test-errors.sh                # the differential ERROR corpus
                                    # (src/errors-corpus): must-fail
                                    # programs x every route, diagnostics
                                    # byte-identical (rejection behavior
                                    # is corpus-tested, like success)
tools/gen-web-vm.sh                 # browser engine artifacts (self-hosted)
(cd web && npm run dev)             # the playground: puffincc in wasm
bin/refresh-boot                    # refresh the seed at release points

# the Racket oracle + generators (optional):
bin/build-puffincc                  # hosted stage-1 bootstrap (alternative)
bin/puffin                          # the Racket-hosted CLI/REPL
racket src/test.rkt -m all          # the corpus through the oracle routes
racket src/diff-ir.rkt <pass> <prog>  # per-pass puffincc/Racket diff
(cd web && npm test)                # corpus + REPL through the wasm VM
node web/test-errors.mjs            # the error corpus through the wasm VM
```

Multi-file programs use the module system ((require "lib.puf") /
(provide ...)); every route — native backends, the bytecode VM, the
web playground — resolves them through puffincc's resolver.

---

# Progress

# Jun 10

- Worked on slides a ton for L0/L1
- Not quite done with L1 
# compilers-projects
