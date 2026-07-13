# Puffin

The course compiler, grown into a language. **The compiler is
`puffincc`** — self-hosting, written in Puffin (`puffincc-src/`, a
module DAG) — with three backends (x86-64, arm64, bytecode), the
gradual typechecker, and the module system. It is the single source
of ground truth for the language: the browser playground (`web/`)
runs *puffincc itself*, compiled to bytecode, on a WebAssembly build
of the bytecode VM (`src/vm/`) — same compiler, same typechecker,
same semantics everywhere.

The Racket implementation in `src/` is the **consistency oracle**:
it generates the golden corpus, cross-checks puffincc per-pass
(`src/diff-ir.rkt`), and hosts the stage-1 bootstrap. It is not the
primary compiler; extend puffincc first and verify against `src/`.
(Its remaining unique role — golden generation via the reference
interpreter — is the last step of a future full retirement.)

Start with [docs/DELTA.md](docs/DELTA.md) — "what's the delta from
p5?" — then [docs/LANGUAGE.md](docs/LANGUAGE.md),
[docs/TYPES.md](docs/TYPES.md), [docs/MODULES.md](docs/MODULES.md),
[docs/OPTIMIZER.md](docs/OPTIMIZER.md),
[docs/STDLIB.md](docs/STDLIB.md), and — for the browser/VM
architecture — [docs/WASM-VM.md](docs/WASM-VM.md) +
[docs/BYTECODE.md](docs/BYTECODE.md). The FFI design (typed foreign
imports; not yet implemented) is [docs/FFI.md](docs/FFI.md).

```
bin/build-puffincc                  # stage-1 bootstrap, then:
build/puffincc prog.puf -o prog     # puffincc compiles + links natively
build/puffincc -t bytecode prog.puf -o prog.pbc   # ... or to bytecode
bin/puffin-vm prog.pbc              # run bytecode on the native VM
tools/gen-web-vm.sh                 # build the browser engine artifacts
(cd web && npm run dev)             # the playground: puffincc in wasm

bin/puffin                          # the Racket-hosted CLI/REPL (oracle)
racket src/test.rkt -m all          # the whole corpus, all routes
racket src/diff-ir.rkt <pass> <prog>  # per-pass puffincc/Racket diff
(cd web && npm test)                # corpus + REPL through the wasm VM
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
