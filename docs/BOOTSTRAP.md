# Bootstrapping Puffin

This document is for contributors: how puffincc builds itself from a
C toolchain alone — the committed bytecode seed, the stage chain in
`bin/bootstrap` and its byte-identical fixpoint, the seed-refresh
discipline (`bin/refresh-boot`), and where the golden-corpus
authority lives. The history of the port from the Racket compiler is
in docs/DELTA.md.

## The self-hosted compiler

puffincc lives in `puffincc-src/` (~8,200 lines of Puffin), a module
DAG rooted at `main.puf` (docs/MODULES.md): the s-expression reader
(`reader.puf`), module resolution, desugar, the typechecker
(`types.puf`, docs/TYPES.md), the optimizer (`optimize.puf` =
contraction/inlining, `aam.puf` = the `-O2` flow analysis;
docs/OPTIMIZER.md), the middle passes, register allocation, the
arm64 and x86-64 backends, the bytecode backend (docs/BYTECODE.md),
and the CLI driver.

`build/puffincc prog.puf -o prog` compiles a program (resolving its
require/provide modules from disk), writes the assembly, and shells
out to clang through the runtime's `system` primitive — no wrapper
script. `-o out.s` stops at assembly; with no `-o` it prints the
assembly to stdout, so the classic pipe mode `puffincc < prog.puf >
prog.s` also works for single-file programs. `-t bytecode` emits a
`.pbc` unit for the bytecode VM instead.

Two components stay in C by design: the runtime (`src/runtime`,
linked into every native binary) and the bytecode VM (`src/vm`,
which also compiles to wasm for the browser — docs/WASM-VM.md).

## The seed

`boot/puffincc.pbc` — puffincc compiled to bytecode — is the
committed seed. A bytecode seed was chosen over a native one because
it is portable across both native targets, deterministic, and runs
on the VM we build from C anyway.

## The bootstrap chain (bin/bootstrap)

`bin/bootstrap` builds everything with a C toolchain only (cc/clang,
make, ar/libtool/lipo) — no Racket anywhere on the machine:

1. `make -C src/runtime` — `libpuffin.a` from `cc` plus the
   committed vendored Boehm collector (`src/runtime/vendor/gc`).
2. `make -C src/vm` — `bin/puffin-vm` from `cc` plus the committed
   `src/vm/vm-prims.inc`. (The Makefile regenerates that prim table
   only when a generator is available — `build/puffincc` running
   `tools/gen-vm-prims.puf`, cross-checked against the Racket
   generator when `racket` is also present; a fresh machine has
   neither and uses the committed copy, with a loud note.)
3. **Stage 1**: the seed runs *on the VM* and compiles
   `puffincc-src/main.puf` → `build/stage1.pbc`. The script notes
   whether `stage1.pbc` matches the seed byte-for-byte (see "Seed
   freshness" below).
4. **Native**: `stage1.pbc` runs on the VM and compiles the same
   source to `build/puffincc` (at `-O0`) — puffincc shells out to
   `/usr/bin/clang` through the VM's `system` primitive. `system` is
   native-only; the wasm VM stubs it, and the browser's
   `-t bytecode` path never needs it.
5. **Stage 2**: `build/puffincc` self-compiles → `build/stage2.pbc`.
6. **Stage 3**: `stage2.pbc` runs on the VM and self-compiles →
   `build/stage3.pbc`. The script fails unless stage 2 and stage 3
   are **byte-identical**.

The fixpoint is the correctness proof of the chain: the same
compiler source, compiled by itself twice — once hosted natively,
once hosted on the VM — must agree byte-for-byte. Determinism comes
free because the runtime's gensym counter starts fresh per process.

The whole chain runs end-to-end with Racket stripped from `PATH`,
and from a fresh clone. It takes ~6 minutes on an M-series mac (each
self-compile is ~85 s; the VM-hosted compiler and the `-O0` native
one run at about the same speed). A full native-vs-Racket benchmark
suite with plots lives in `bench/report.html` (regenerate:
`python3 bench/run-benchmarks.py && python3 bench/build-report.py`).

## Seed freshness (bin/refresh-boot)

Classic self-hosting seed rules apply:

- The seed does **not** need to match current `puffincc-src`
  byte-for-byte; it only needs to be *able to compile* it. A stale
  but compatible seed shifts `stage1.pbc` (`bin/bootstrap` notes
  this), never the stage-2/stage-3 fixpoint.
- Refresh at release points with `bin/refresh-boot`, which rebuilds
  a candidate seed from the current `build/puffincc` and refuses to
  install one that does not reach a self-compile fixpoint on the VM
  (the candidate, run on the VM over `puffincc-src`, must reproduce
  itself byte-identically). Commit the refreshed seed.
- If `puffincc-src` starts using a language feature the committed
  seed cannot compile, refresh the seed **first** from a commit that
  can compile the tree (check out that commit, `bin/bootstrap`,
  `bin/refresh-boot`, carry `boot/puffincc.pbc` forward) — or use
  the hosted `bin/build-puffincc` as the escape hatch while the
  Racket implementation is around.

## The golden authority: tools/test-corpus.sh

`tools/test-corpus.sh` is the Racket-free corpus harness and the
author of record for the goldens: every program in
`src/test-programs` (plain files and module directories) × every
`src/input-files/*.in`, compiled with `build/puffincc -t bytecode`,
run on `bin/puffin-vm`, and compared (whitespace-trimmed) against
`src/goldens` — **309 checks**. Its `gen` mode *writes* the goldens
the same way; setting `GOLDENS_DIR` regenerates into a fresh
directory so it can be diffed against `src/goldens`.

## The Racket oracle

The Racket implementation in `src/` is the optional **consistency
oracle**, not the source of truth. `racket src/test.rkt -m interp`
(and `-m gen` plus a diff) re-derives the goldens independently —
regenerating with the reference interpreter and diffing against the
puffincc-authored goldens *is* the differential test between the two
implementations, and it is byte-identical, 309/309. `src/diff-ir.rkt`
cross-checks the two compilers per pass, via puffincc's
`(dump-after pass)` directive. `bin/build-puffincc` is the hosted
alternative to stage 1: it builds `build/puffincc` with the Racket
compiler instead of the seed.

## What still needs Racket

Only the generators. After a stdlib-manifest (`src/stdlib.rkt`) or
prelude change, `src/gen-puffincc-tables.rkt`,
`tools/gen-prim-names.rkt`, and the STDLIB-doc generator
(`src/gen-stdlib-docs.rkt`) re-derive the committed tables and
docs/STDLIB.md. The VM prim table is already self-hosted:
`tools/gen-vm-prims.puf` regenerates `src/vm/vm-prims.inc`, with
`src/gen-vm-prims.rkt` kept as a lockstep cross-check. Building,
testing, and shipping Puffin — `bin/bootstrap`,
`tools/test-corpus.sh`, `tools/gen-web-vm.sh` — need no Racket.
