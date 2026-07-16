# Puffin

A Racket-family language with a self-hosting compiler, gradual types,
and honest error messages on every route. It started as a PL-course
compiler and grew into a daily driver.

```scheme
(define-type Expr
  (Num Int)
  (Add Expr Expr)
  (Mul Expr Expr))

(define (eval-expr [e : Expr]) : Int
  (match e
    [(Num n) n]
    [(Add a b) (+ (eval-expr a) (eval-expr b))]
    [(Mul a b) (* (eval-expr a) (eval-expr b))]))

(println (eval-expr (Add (Mul (Num 3) (Num 4)) (Num 1))))   ;; 13
```

**The compiler is `puffincc`** — self-hosting, written in Puffin
(`puffincc-src/`, a module DAG) — with three backends (arm64, x86-64,
bytecode), the gradual typechecker, the module system, and a typed
FFI. It is the single source of ground truth for the language: the
browser playground (`web/`) runs *puffincc itself*, compiled to
bytecode, on a WebAssembly build of the bytecode VM (`src/vm/`) —
same compiler, same typechecker, same semantics everywhere.

The highlights:

- **Self-hosting, Racket-free**: `bin/bootstrap` builds the compiler
  from the committed bytecode seed with nothing but a C toolchain,
  and proves a stage-2/3 byte-identical fixpoint every time.
- **Gradual types** (docs/TYPES.md): ADTs, annotations where you want
  them, `_` where you don't; transient casts with blame at declared
  boundaries; exhaustiveness warnings.
- **A typed FFI** (docs/FFI.md): `dlopen`'d C imports declared with
  ordinary `(: name τ)` types — the declaration generates the
  marshaling, and every crossing is checked with blame naming the
  import. `examples/z3/` binds the Z3 SMT solver as a Puffin API.
- **Modules + separate compilation** (docs/MODULES.md), a native
  REPL, a bytecode VM, and the in-browser playground with the real
  compiler and REPL.
- **Tested by construction**: a 309-check golden corpus and a
  differential *error* corpus run every program down every route —
  diagnostics byte-identical, rejection behavior corpus-tested like
  success.

## Quick start

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
                                    # programs x every route
tools/test-examples.sh              # the examples/ programs vs their
                                    # goldens, native + VM (z3 examples
                                    # skip when libz3 is absent)
tools/gen-web-vm.sh                 # browser engine artifacts (self-hosted)
(cd web && npm run dev)             # the playground: puffincc in wasm
bin/refresh-boot                    # refresh the seed at release points
```

Multi-file programs use the module system (`(require "lib.puf")` /
`(provide ...)`); every route — native backends, the bytecode VM, the
web playground — resolves them through puffincc's resolver.

## Documentation

New here? Read the tutorial —
[docs/tutorial.html](docs/tutorial.html), *Puffin for Racketeers* —
then the reference docs:

- [docs/LANGUAGE.md](docs/LANGUAGE.md) — the language, day to day
- [docs/TYPES.md](docs/TYPES.md) — the gradual type system
- [docs/MODULES.md](docs/MODULES.md) — modules and separate compilation
- [docs/FFI.md](docs/FFI.md) — the FFI, with runnable
  [examples/](examples/README.md) (including the Z3 binding and a
  solve-and-prove-unique Sudoku)
- [docs/STDLIB.md](docs/STDLIB.md) — the standard library
  (docs/stdlib.html is the generated reference; its examples are
  executed and asserted at generation time)
- [docs/OPTIMIZER.md](docs/OPTIMIZER.md) — `-O 0|1|2`
- [docs/WASM-VM.md](docs/WASM-VM.md) + [docs/BYTECODE.md](docs/BYTECODE.md)
  — the VM and the browser architecture
- [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md) — how the Racket-free
  bootstrap works
- [docs/DELTA.md](docs/DELTA.md) — the project's history: "what's the
  delta from the course compiler?"

## The Racket oracle

The Racket implementation in `src/` is the optional **consistency
oracle**: it cross-checks puffincc per-pass (`src/diff-ir.rkt`), and
its reference interpreter re-derives the goldens as a differential
test — the two implementations must agree byte-for-byte; they do,
309/309. It also hosts the alternative stage-1 bootstrap
(`bin/build-puffincc`) and the **generators**: after changing the
stdlib manifest (`src/stdlib.rkt`) or prelude, regenerating the
derived tables (`src/vm/vm-prims.inc`, `puffincc-src/tables.puf`,
docs/STDLIB.md) still uses Racket — the one remaining Racket-needed
activity. It is not the primary compiler; extend puffincc first and
verify against `src/`.

```
bin/build-puffincc                  # hosted stage-1 bootstrap (alternative)
bin/puffin                          # the Racket-hosted CLI/REPL
racket src/test.rkt -m all          # the corpus through the oracle routes
racket src/diff-ir.rkt <pass> <prog>  # per-pass puffincc/Racket diff
(cd web && npm test)                # corpus + REPL through the wasm VM
node web/test-errors.mjs            # the error corpus through the wasm VM
```
