# Puffin

Puffin is a minimal Scheme/ML-like functional programming language
written by Claude Code, directed by (and extending) a compiler written
by Kristopher Micinski. The compiler is detailed here:
https://kmicinski.com/functional-programming/2025/11/23/build-a-language/
I used Claude Code to build Puffin by extending that compiler with
several useful features:

- Match patterns and quasiquoting
- A gradual type system using consistency-based typing
- A simple standard library consisting of sets, hashes (dictionaries),
  and several other facilities
- A simple module system inspired by SML
- A typed FFI

The project is, in some ways, an adventure in Slop. I glanced at all
of the code and understand the compiler's structure--but there are
still some serious gaps which have not been fully thought-through. I
have written some very large ports of Racket applications in Puffin
(some of which I cannot share quite yet) and a ~10kloc application did
demonstrate a serious Puffin compiler bug--so there are surely both
(a) genuinely bad, unsound design choices which must be rooted out and
(b) bugs in the implementation.

Puffin includes a self-hosting compiler, gradual types, and reasonably
good error messages. Here is a "hello world" example:

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

**The compiler is called `puffincc`**: it is self-hosting, written in
Puffin (see `puffincc-src/`), and includes with three backends: (a)
arm64, (b) x86-64, and (c) bytecode. It is the single source of ground
truth for the language: the browser playground (`web/`) runs *puffincc
itself*, compiled to bytecode, on a WebAssembly build of the bytecode
VM (`src/vm/`).

Some highlights coming from Racket:

- **Self-hosting, Racket-free**: `bin/bootstrap` builds the compiler
  from the committed bytecode seed with nothing but a minimal C
  toolchain (why not Rust!?), and should yield a stage-2/3
  byte-identical fixpoint every time.

- **Gradual types** are described in `docs/TYPES.md`: ADTs,
  annotations where you want them, `_` where you don't; transient
  casts with blame at declared boundaries; exhaustiveness warnings.

- **A typed FFI** (`docs/FFI.md`): `dlopen`'d C imports declared with
  ordinary `(: name τ)` types; the declaration generates the
  marshaling, and every crossing is checked with blame naming the
  import. As an example, `examples/z3/` binds the Z3 SMT solver as a
  Puffin API.

- **Modules + separate compilation** described in `docs/MODULES.md`, a native
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
`(provide ...)`); all backends (native, the bytecode VM, the web
playground) resolve via puffincc's resolver.

## Documentation

There is a tutorial here:
[docs/tutorial.html](docs/tutorial.html), *Puffin for Racketeers*. We (me and mister Claude) also wrote reference docs:

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
test: the two implementations must agree byte-for-byte.

```
bin/build-puffincc                  # hosted stage-1 bootstrap (alternative)
bin/puffin                          # the Racket-hosted CLI/REPL
racket src/test.rkt -m all          # the corpus through the oracle routes
racket src/diff-ir.rkt <pass> <prog>  # per-pass puffincc/Racket diff
(cd web && npm test)                # corpus + REPL through the wasm VM
node web/test-errors.mjs            # the error corpus through the wasm VM
```
