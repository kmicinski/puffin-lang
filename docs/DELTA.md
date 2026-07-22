# Puffin: what's the delta from p5?

This is the project-history document. Puffin grew out of the
CIS352/531 p5 compiler (R4/R5 → x86-64), and this doc walks the whole
system and answers, at each spot: *what changed relative to p5, why,
and where do I look?* It is written for the person who wrote that
class compiler — and for anyone curious how a course project grows
into a daily-driver language. The sibling docs are the reference;
this one is the retrospective. Everything stayed s-expression-based,
everything stayed in the pass-chain style — the goal was a language
usable instead of Racket day to day, grown out of the class compiler
rather than replacing it.

## Where the project ended up

The compiler is **puffincc**, written in Puffin itself. The Racket
implementation the project grew through is still here, demoted to
the optional consistency oracle. The map:

```
puffincc-src/       the compiler, in Puffin — the ground truth
  main.puf          the driver: CLI, module resolution, clang link
  reader.puf desugar.puf middle.puf backends.puf    the pass chain
  types.puf         the gradual typechecker
  contract.puf aam.puf optimize.puf                 the optimizer
  modules.puf system.puf tables.puf prelude-data.puf
boot/puffincc.pbc   the committed bootstrap seed (bytecode)
bin/bootstrap       Racket-free build from the seed, with a
                    stage-2/3 byte-identical fixpoint proof
src/                the Racket oracle — where all of this grew up
  compile.rkt       frontend + middle-end passes     (grown from p5)
  irs.rkt           per-IR predicates                (grown from p5)
  interpreters.rkt  per-IR reference interpreters    (grown from p5)
  stdlib.rkt        THE STANDARD LIBRARY MANIFEST
  system.rkt        flags/ABI + tags + targets       (grown from p5)
  regalloc.rkt      live-range register allocation (shared)
  backend-x86.rkt   x86-64: select/allocate/patch/prelude/render
  backend-arm64.rkt AArch64: the same five passes
  backend-bytecode.rkt  the .pbc backend (docs/BYTECODE.md)
  main.rkt test.rkt puffin.rkt repl.rkt
  runtime/          partitioned C runtime + Boehm GC -> libpuffin.a
  vm/               the bytecode VM: bin/puffin-vm + the wasm builds
  test-programs/    the corpus; input-files/ goldens/
bin/puffin          the Racket-hosted CLI: REPL | run | compile
web/                browser playground: puffincc on the wasm VM
docs/STDLIB.md      generated from the manifest — never edit by hand
```

Quick orientation:

```
bin/bootstrap                    # cc-only build from the seed
build/puffincc prog.puf -o prog  # puffincc compiles + links natively
bin/puffin                       # Racket-hosted REPL
bin/puffin prog.puf              # compile natively and run
racket src/test.rkt -m all       # the corpus through the oracle
tools/test-corpus.sh             # the corpus, Racket-free
```

The corpus is the through-line of the whole story: every example
program from p1 through p5 runs **unmodified**, joined over time by
`puffin-*` feature tests, the module splits, and the PL-course
suite — today 309 golden checks per route, byte-identical on the
reference interpreter, both native backends, the bytecode VM, and
the wasm VM in the browser.

The rest of this document tells the story by theme.

## The big semantic shift: tagged values

p5 computed on raw 64-bit integers. Puffin values are tagged words —
the "runtime type tagging and dynamic types" step the p5 README calls
the next mandatory project. Low 3 bits:

| tag  | meaning | encoding |
|------|---------|----------|
| 000  | fixnum  | `n << 3` (61-bit) |
| 001  | heap object | address \| 1; kind byte + length in a header word |
| 010  | immediate | `#f`=2, `#t`=10, void=18, `'()`=26 |
| 011  | symbol  | `intern-id << 3 \| 3` |

Two consequences make the instruction selector barely change:
tagged `+`, `-`, `eq?`, `<` work directly on tagged words, and a tagged
fixnum index *is* a byte offset into a vector's slots. `*` costs one
extra `sarq $3`/`asr #3`. Comparison results get tagged with
`shl 3; or 2`. The scheme lives (documented) in the places that must
stay in lockstep: `src/system.rkt` and `puffincc-src/system.puf`,
`src/runtime/puffin.h`, and the interpreters' value mapping in
`src/stdlib.rkt`.

Heap objects: `| header | payload... |` with `header = (len << 8) | kind`.
Core kinds: 1 vector, 2 pair, 3 string, 4 closure, 5 hash, 6 set;
extension modules claim 16+ via the runtime's kind registry (the
immutable HAMT collections hold 16/17, ADT instances 18, foreign
handles their own).

**Truthiness is Racket's**: only `#f` is false. `explicate-control`
already branched on `(eq? a #f)`, so this fell out almost free; `not`
shrinks to `(eq? e #f)`.

Booleans print `#t`/`#f`, symbols print bare, vectors `#(1 2 3)`,
lists `(1 2 3)`. The p5 runtime printed booleans as integers, so the
class's golden files were not comparable; goldens are regenerated
from the reference interpreter, and every backend is held to those.

## The runtime: partitioned, GC'd, pluggable

p5's single `runtime.c` is gone. `src/runtime/` is:

- **`puffin.h`** — the whole ABI: tags, heap layout, allocation
  helpers, error hooks, and a *kind registry* (`pf_register_kind`)
  through which each data structure supplies its own display and
  `equal?` handlers. Read this first.
- **`core.c`** — only what everything depends on: Boehm GC glue
  (`GC_MALLOC` via the vendored universal `bdw-gc` in
  `runtime/vendor/gc`), symbol interning, string constants, fatal
  errors, display/equal *dispatch*, I/O, closures, `pf_init`.
- **`lib/`** — one module per feature: `pairs.c`, `vectors.c`,
  `strings.c`, `hashes.c`, `sets.c`, `arith.c`, `predicates.c`,
  `io.c`, `hamt.c` (the immutable collections), `adt.c`
  (`define-type` instances), `cast.c` (the gradual-typing casts),
  `foreign.c` (the FFI); `lib/table.c` holds the open-addressing
  table both mutable hashes and sets use (linear probing,
  power-of-two capacity, grow at 70%, eq?-keyed — the right notion
  for fixnum/boolean/symbol keys since symbols are interned).
- **`lib/stdlib_init.c`** — the one file that lists modules.
- **`Makefile`** — builds `libpuffin.a`, a *universal*
  (arm64+x86_64) static archive with libgc merged in, so linking any
  Puffin program is `clang [-target ...] output.o libpuffin.a -o
  output`.

GC: Boehm, conservative, interior pointers on (heap refs are ptr|1).
`GC_MALLOC_ATOMIC` for strings. The globals array is emitted in
`__DATA,__data` so it's scanned as roots. A 1M-iteration loop
allocating 100-slot vectors peaks under 150MB RSS.

### Immutable by design

Puffin's collections are immutable *by default*, with mutability
tolerated (Racket's own naming convention marks the split):
`(hash k v ...)`/`hash-set`/`hash-remove` and `(set v ...)`/
`set-add`/`set-remove` return new collections; `make-hash`/
`hash-set!`/`make-set`/`set-add!` are the mutable escape hatches.
The generic accessors (`hash-ref`, `hash-count`, `set-member?`, ...)
work on both flavors. Natively the immutable ones are persistent
HAMTs (`src/runtime/lib/hamt.c`, CHAMP-style, 64-way fanout,
path-copying updates) — and since keys are tagged words hashed by
fmix64, a *bijection*, the trie needs no collision buckets at all.
The module claims kinds 16/17 from the registry's extension range:
it is itself a demonstration of the stdlib pluggability story.
Immutable collections compare by value under `equal?`; mutable ones
by identity. Pairs, strings, symbols were already immutable; vectors
remain the raw mutable building block (the class corpus's
`vector-set!` code runs unchanged).

### The manifest (`src/stdlib.rkt`) — the pluggability keystone

Every library primitive is declared exactly once: name, arity, C entry
point, surface visibility, *reference implementation* (a Racket
procedure — this is the semantics), and a doc line. Derived from it:
the `prim?`/arity predicates in `irs.rkt`, instruction selection in
the backends (every stdlib prim compiles to "args in registers, call
`rt-sym`"), the interpreters' behavior, `docs/STDLIB.md` (via
`src/gen-stdlib-docs.rkt`), puffincc's generated
`puffincc-src/tables.puf`, and the extern lists. Adding a feature =
one C module + one manifest entry. Compiler intrinsics (`+ - * eq? <`
and the unsafe slot ops) are deliberately *not* in the manifest —
they're the compiler's vocabulary, not the library's.

## The front end: from R5 to a usable language

New pass **`desugar`** (before shrink) turns full Puffin into core
Puffin:

- **`match`** — patterns: `_`, variables, literals (fixnum, boolean,
  string), `'sym`, quoted lists, `(cons p p)`, `(list p ...)`,
  `(vector p ...)`, `(? pred p)`, and **quasiquote patterns**
  (`` `(add ,a ,b) `` — so Puffin is pleasant for writing compilers,
  matching how the compiler itself is written), including **general
  ellipsis** (`` `(lambda (,xs ...) ,body) ``, nested `` `(program
  (define (,ns ,ps ...) ,bs) ...) `` — variables under `...` collect
  per-element lists, fixed-shape patterns may follow). `#:when`
  guards.
  Compilation: each clause chains to the next through a `fail` thunk,
  so clause bodies appear exactly once; patterns compile to
  `pair?`/`vector?`/`eq?` tests with `car`/`cdr`/`vector-ref` binds.
- **niceties** — `cond`, `when`, `unless`, `case`, named `let`
  (becomes a self-referential closure via `set!` + assignment
  conversion), multi-binding parallel `let`, `let*`, multi-body
  bodies (implicit `begin`), n-ary `+ - * and or`, `λ`, `'datum`,
  `(list ...)`, `(vector ...)`, string literals.
- **shadowing, settled once** — `desugar` tracks scope with a rename
  map; any binding that collides with a primitive name is gensym-
  renamed *here*, so a primitive name in operator position downstream
  always means the primitive. (This is load-bearing: r4-6/r4-10 in
  the corpus define their own `cons`.) A primitive used as a bare
  value eta-expands: `(map car xs)` works.
- **top-level value defines** — see collect-globals below.

**`shrink`** also gained: `not` → `(eq? e #f)`; `or` keeps its first
truthy value via a temp (Racket semantics); `begin` → let-chains.

New pass **`collect-globals`** (after uniqueify): `(define x e)` forms
claim slots in a runtime globals array; initializers and top-level
expressions run in source order inside `main`; reads become
`(global-ref i)`, `set!` on a global becomes `(global-set! i e)`.
Functions may reference globals defined textually later (read at call
time — module-like semantics). The last top-level expression's value
is the program result (printed unless void, via `pf_print_result`).
From this pass on, programs carry an info hash: `(program ,info ,defns ...)`
with `'globals`, later joined by `'symbols`/`'strings` (the literal
tables, collected in *sorted* order so every pass assigns identical
ids; the renderer emits them as data and `pf_init` interns them).

**Middle passes** (uniqueify, reveal-functions, assignment-convert,
lift-lambdas, limit-functions, anf-convert, explicate-control,
uncover-locals) are the p5 passes, extended:

- compiler-internal heap access (assignment-conversion boxes, closure
  environments, arity-overflow vectors) uses **`unsafe-vector-ref` /
  `unsafe-vector-set!`** — inline, unchecked, literal index; the
  user-facing `vector-ref`/`vector-set!` are checked runtime calls
  with *dynamic* indices (the p5 IR only allowed literal indices).
- assignment-convert boxes **only the variables that are actually
  `set!`** (per function), not everything.
- closures allocate with `make-closure` (own heap kind), so
  `procedure?` works and closures print as `#<procedure>` instead of
  leaking their representation.
- lift-lambdas sorts captured free variables, keeping output
  deterministic.
- **`(effect rhs)`** joins `assign` in the blocks IR for
  effect-position primitives (`println` etc.).

### Proper tail calls

`explicate-control` recognizes `(let ([x (app f a ...)]) x)` under a
`return` continuation and emits a **`tail-app`** tail. The native
backends lower it to a `tail-jmp` pseudo-instruction: load the target
into a scratch register *before* the argument moves, then (expanded
by prelude-and-conclusion, which knows the frame) restore the frame
and jump. `main` is exempted (it must run its print-result
conclusion). Named-let loops therefore run in constant stack — the
corpus includes a 2M-iteration loop. This is the "efficient tail
calls via indirect jump" the p5 README gestures at.

## Register allocation (`regalloc.rkt`)

p5's `assign-homes` (everything spilled) is replaced by
**`allocate-registers`**:

1. per-instruction liveness — backward dataflow to fixpoint over the
   block CFG, then a backward walk within each block;
2. one live *interval* per variable — the convex hull of every point
   where it occurs or is live, over a reverse-postorder linearization
   (hulls ignore holes; that's the "simple", and it's conservative);
3. **linear scan** (Poletto–Sarkar) with furthest-end spilling.

Only **callee-saved** registers are allocated (x86: rbx, r12–r15;
arm64: x19–x26): values in them survive calls, so intervals crossing
calls need no special treatment — on call-heavy Puffin code that's
most of the win for a fraction of the complexity. Spills go below the
callee-saved save area (offset bias is per-target:
`callee-save-area-bytes`). The pass is target-independent; each
backend supplies a `uses+defs` function, and regalloc never inspects
opcodes. Frames stay 16-byte aligned at call sites (padding computed
in prelude-and-conclusion).

Output info per definition: `'var->loc`, `'callee-saved` (for the
prologue), `'spill-bytes`.

Compiling the compiler itself later exposed two scaling problems
here: liveness/interval construction was quadratic in live-set size
(rewritten with mutable backward walks + hull endpoint anchoring, in
both `src/regalloc.rkt` and `puffincc-src/backends.puf`), and arm64
frames larger than 4095 bytes crashed the assembler (sp adjustments
now split into a shifted-page part + remainder, both
implementations).

## Three backends, one shape

`system.rkt` has a `target` parameter (`'x86-64` | `'arm64` |
`'bytecode`; native default = host). `main.rkt` splices the target's
backend passes after uncover-locals; everything earlier is
target-independent (even limit-functions: the native targets use six
argument registers so the overflow ABI is identical).

- **backend-x86.rkt** is the p5 backend grown up: new ALU ops for
  tagging (`imulq/sarq/shlq/orq/andq/movabsq`), `(global i)` operands
  (`_puffin_globals+8i(%rip)`), stdlib calls from the manifest,
  `tail-jmp` expansion, data-segment emission (symbol table, string
  table, globals `.space`), and patch-instructions extended for
  mem/mem in all two-operand forms, imm64 staging, and `imulq`'s
  register-destination rule.
- **backend-arm64.rkt** mirrors it pass-for-pass. Differences worth
  knowing: the return address is in `x30`, so prologues `stp x29,x30`
  and tail calls jump through scratch `x9` after the frame restore;
  memory is only touched by `ldr/str`, so the selector emits x86-ish
  `mov`s freely and *patch* legalizes them; immediates are 12-bit in
  ALU ops (bigger ones stage through `x11` via the assembler's
  `ldr =imm` literal pool); callee-saved saves are `stp` pairs;
  `fun-ref`/globals use `adrp ... @PAGE/@PAGEOFF`. Scratch discipline:
  selector uses x9/x10, patcher x11 (+x10 for second operands),
  renderer x16 for far frame slots — they never collide.
- **backend-bytecode.rkt** joined the two native backends later:
  same cut point in the pipeline, same shape, emitting `.pbc` units
  for the VM in `src/vm/` (`bin/puffin-vm` natively, the wasm builds
  for the browser). docs/BYTECODE.md covers the instruction set and
  unit format; docs/WASM-VM.md covers the wasm builds.

On an ARM mac, `-t x86-64` output runs under Rosetta; the golden
corpus holds every backend to the same goldens.

## Gradual types

Puffin has a gradual type system (docs/TYPES.md): ADTs via
`define-type`, annotations via `(: name type)` and inline parameter
types where you want them, `_` where you don't, exhaustiveness
warnings, and transient casts with blame at declared boundaries. The
checker is a `typecheck` pass between desugar and shrink, and it
lives in both compiler sources — `src/types.rkt` and
`puffincc-src/types.puf`, held byte-identical on diagnostics — so it
runs on every route, including in the browser. The tagged
representation was chosen so checked and unchecked code coexist.

Type information reaches the backends: arithmetic (`+ - * <`) is
tag-checked with typed error messages (`eq?` stays polymorphic — a
raw word compare), and ADT instances are their own heap kind
(`src/runtime/lib/adt.c`, kind 18). The typed FFI (docs/FFI.md)
builds on the same machinery: `dlopen`'d C imports are declared with
ordinary `(: name τ)` types, the declaration generates the
marshaling, and every crossing is checked with blame naming the
import — `examples/z3/` binds the Z3 SMT solver this way.

## Modules and separate compilation

The module system (docs/MODULES.md): `(require "path.puf")` /
`(provide ...)` with `#:as`/`#:only`/`#:rename` and optional `.pufs`
signature ascription, implemented as a front pass in both
implementations — `src/modules.rkt` (one hook in `read-program-file`
covers every oracle route) and `puffincc-src/modules.puf`. The
browser playground resolves modules through puffincc's own resolver
against the engine shim's in-memory file map (the editor grew file
tabs). Corpus: `modules-1..6` — the stack-VM, LC-interpreter, and
sudoku programs split into modules, byte-identical to their
single-file originals; the failure modes are corpus-tested in
`src/test-modules.rkt`.

Separate compilation — the `.pufi`/`.o` cache and link-time DAG
assembly described in docs/MODULES.md — is implemented on the Racket
side (`src/separate.rkt`, `bin/puffin -c --separate`, arm64), with
the whole-program resolver as the semantic reference and
`src/test-separate.rkt` holding the two routes to identical output.
puffincc itself compiles whole-program.

## The optimizer

`-O0/1/2` in both compilers (docs/OPTIMIZER.md): cp0-style
contraction, a staged CESK* flow analysis and its clients, direct
known calls, fused compare-and-branch, loop recovery, blocks
cleanup, and open-coded pair/vector primitives with inline fast
paths. The whole stack is ported to Puffin in
`puffincc-src/{contract,aam,optimize}.puf` with hooks in
`middle.puf`/`backends.puf`; `src/diff-ir.rkt <pass> <prog> [tgt]
[olvl]` is the cross-implementation oracle that holds the two
optimizers to the same IR, pass by pass.

## Testing: goldens all the way down

Goldens are produced by the reference interpreter (desugar +
`interpret-puffin`) — the manifest's ref-impls *are* the semantics —
and every route must agree byte-for-byte: 309 golden checks per
route across the reference interpreter, x86-64, arm64, the bytecode
VM (`racket src/test.rkt -m bytecode`, or Racket-free via
`tools/test-corpus.sh`), and the wasm VM in the browser
(`node web/test-vm-corpus.mjs`). The oracle's modes:

- `-m interp` — the reference itself (sanity);
- `-m chain` — runs the run-chain trace over the frontend and checks
  every pass's interpreter output against the golden *and* both IR
  predicates per pass (this is the mode that localizes a bug to a
  pass in one command);
- `-m x86-64` / `-m arm64` — compile natively, feed each input file
  on stdin, compare;
- `-m gen` — regenerate goldens (reports programs the reference
  rejects instead of writing bad goldens).

Rejection is corpus-tested like success: a differential *error*
corpus (`src/errors-corpus`, `tools/test-errors.sh`,
`web/test-errors.mjs`) runs must-fail programs down every route and
holds the diagnostics byte-identical.

**The PL-course suite** (`pl-*.scm`, 29 programs): the workloads a
programming-languages course actually writes, as golden tests on
every route — interpreters and semantics (Church encodings, de
Bruijn + normalization, a CEK machine, an STLC checker,
Hindley-Milner inference with unification + occurs check, big-step
IMP, a small-step SOS stepper, the CBV CPS transform verified
against direct evaluation), compilers (arithmetic→stack-VM with
agreement checking, constant folding + DCE to fixpoint, ANF
conversion, closure conversion, a peephole optimizer, regex→Thompson
NFA simulation, recursive-descent parsing with precedence, SKI
bracket abstraction + reduction), data structures (Okasaki red-black
insertion with invariant validation, leftist heaps, batched
persistent queues, tries over nested hashes, tree zippers, graph
DFS/cycles/toposort), and the classics (n-queens, memoized edit
distance, Huffman round-trips, symbolic differentiation, lazy
streams + the sieve, a DPLL SAT solver, alpha-equivalence two ways).

The rest of the corpus: all class examples (r0-* through r5-*) run
**unmodified** — including the ones that define their own `cons`
over vectors — plus `puffin-*` tests covering
match/guards/quasiquote, closures, hashes/sets/symbols, strings,
eta-expanded prims, `equal?`, tail-call loops, `read`-driven
programs, the immutable collections, and an **eval/apply
interpreter for an extended lambda calculus** (puffin-9) written
exactly the way this compiler is written — quasiquote-match over
ASTs, immutable-hash environments, closures as tagged data. It runs
letrec factorial, Church numerals, the Z combinator, and a
meta-meta-interpreter, on every execution route; it was the warm-up
for bootstrapping the compiler in Puffin itself.

The per-pass interpreters in `interpreters.rkt`: `interpret-puffin`
covers desugar → anf-convert; `interpret-blocks` covers
explicate-control/uncover-locals (both drive primitive behavior from
the manifest). Instruction-level IRs are validated natively rather
than simulated: the class's pseudo-x86 interpreter didn't survive
tagging plus two ISAs, and chain mode + native goldens cover the
gap.

Three interpreter deltas from p5 style, deliberate: input is a
mutable box rather than threaded return values (the prim table made
threading unwieldy); truthiness is Racket's; mutable bindings are
Racket boxes.

## REPL, CLI, and tooling

- **`build/puffincc`** is a real compiler driver: it resolves the
  program's module DAG from disk, compiles, and drives clang itself
  (`build/puffincc prog.puf -o prog`); `-t bytecode` emits `.pbc`
  for `bin/puffin-vm`; pipe mode (`puffincc < prog.puf > prog.s`)
  survives for single-file programs; `--repl` compiles one eval's
  forms as a link-by-name unit for a persistent VM session — the
  mechanism behind the playground's REPL pane.
- **`bin/puffin`** is the Racket-hosted CLI: `bin/puffin` (REPL),
  `bin/puffin prog.puf` (compile natively and run), `-i` (interpret
  — same semantics, fast startup), `-c ... -o ...` (just compile),
  and `racket src/main.rkt -t <target> prog.puf` for the classic
  verbose pass trace.
- The console REPL (`src/repl.rkt`) runs on the reference
  interpreter with a persistent mutable top-level (`repl-toplevel`
  in interpreters.rkt), so defines arrive one at a time, mutual
  recursion across inputs works, and `(read)` reads live from the
  terminal. Commands: `,help`, `,env`, `,quit`. One documented
  limitation: a REPL define may not *shadow* a primitive name
  (files can).
- **Editor support**: `bin/puffin-lsp` is an LSP server over stdio
  (`tools/lsp/server.rkt`), and `editor/emacs/puffin-mode.el` is
  the Emacs mode.

### IR provenance and the pipeline visualizer

Every pass's walker is wrapped (one line per pass) to tag each node
it constructs with the input node it came from, in a global weak
eq-hash (`src/provenance.rkt`) — the IRs stay plain s-expressions
and no pattern anywhere changed. Because run-chain feeds each
pass's actual output object forward, provenance composes across the
whole pipeline by object identity. Nodes may carry a few candidate
origins (CPS-shaped passes construct nodes inside continuations);
resolution tries them in order, and untagged structural nodes
inherit their ancestor's origin.

`src/ir-json.rkt` serializes a trace for the web: a span-tracking
IR printer (per-node character ranges), per-layer back-edge maps,
and per-LINE provenance for the rendered assembly (both native
backends export `render-lines-*`). `src/ir-server.rkt` — the
descendant of the class debug-server.rkt — serves `POST /trace` for
the web app and has a `--dump` mode (the bundled demo trace).

The web app's **Pipeline** mode shows any layer pair side by side:
click a node to highlight its origin in the previous layer (with
ancestor fallback), click left to see everything it *became*
(reverse edges), and follow a breadcrumb chain from an assembly
line all the way to the source expression.

## The web playground (`web/`)

The browser playground runs the **real toolchain**: puffincc,
compiled to bytecode, executes on a WebAssembly build of the
bytecode VM, compiling + typechecking editor source in the tab and
running the result on the same VM — no JS reimplementation of the
language. (An earlier JS interpreter played this role and was
retired when the self-hosted compiler could replace it.) The UI is
Vite + SolidJS, Monaco with a Puffin tokenizer and a solarized-light
theme, the engine in a Web Worker (cancellable runs), a persistent
REPL session pane (a reactor-model VM instance loading one
link-by-name unit per eval), an examples dropdown, and a stdin box
for `(read)`. It is held to the same goldens as every other route
via `node web/test-vm-corpus.mjs` (309 checks). See `web/README.md`
and docs/WASM-VM.md.

## Self-hosting

Bootstrapping was planned as a report before it was code:
docs/BOOTSTRAP.md inventoried every Racket facility the compiler
used against what Puffin offered, and that inventory drove a feature
batch — quasiquote expressions, internal defines/letrec, gensym,
value->string/format, read-all, the string/bit-work/list-utility/
set-algebra batch, apply/sort/map2 — each implemented across the C
runtime, the manifest, and the reference interpreters, all under
golden tests. `puffin-10` in the corpus was the seed: shrink +
uniqueify written in Puffin, byte-identical on every route.

The port then proceeded pass by pass until the whole compiler —
reader, desugarer, typechecker, middle end, optimizer, all three
backends, the module resolver, the driver — lived in
`puffincc-src/` as a module DAG rooted at `main.puf` (the generated
`tables.puf`/`prelude-data.puf` are ordinary modules). New io
primitives (`read-file`, `write-file`, `file-exists?`,
`command-line-args`, `system`; `src/runtime/lib/io.c`) made it
self-contained.

Today the bootstrap is Racket-free: `bin/bootstrap` builds puffincc
from the committed bytecode seed `boot/puffincc.pbc` with nothing
but a C toolchain, and proves a stage-2/3 byte-identical fixpoint
every time; `bin/refresh-boot` refreshes the seed at release
points. `bin/build-puffincc` remains as the alternative
Racket-hosted stage-1. Even the VM's primitive-table generator is
self-hosted (`tools/gen-vm-prims.puf`), with the Racket generator
kept as a byte-identity lockstep check. The Racket implementation
in `src/` is now the optional consistency oracle — see the README's
"The Racket oracle" section — and puffincc is the ground truth.

## Bugs found in the class code

Growing the corpus and the language flushed out real bugs in the
course compilers — several latent in code that had shipped to
students. The curated log:

1. **`322@pr5/compile.rkt` `free-vars`** — for
   `(let ([_ (while g b)]) r)` it unioned `(free-vars e-b)` twice and
   dropped `e-r`. Fixed (matches the fix already in `p4/`).
2. **`322@pr5/compile.rkt` shrink** — the `<` case didn't recurse
   into its operands. Fixed (ditto).
3. **`uniqueify` missed sibling-scope collisions** (both `p4/` and
   `322@pr5/`, and inherited by Puffin) — a rebinding was renamed
   only if the name was visible in the *enclosing* scope's map, so
   `(if c (let ([a 1]) a) (let ([a 2]) a))` kept two writes to `a`,
   violating `unique-source-tree?`. Never fired on class test
   programs; Puffin's match expansion (same pattern variable in two
   clauses) trips it immediately. Fixed in all three compilers with
   a per-definition used-name set; all 51 of p4's uniqueify golden
   outputs are byte-identical under the fix (it only changes
   behavior on collision), and Puffin's chain mode stays green.
4. **Locals shadowing top-level function names confused the
   `revealed-functions` predicate** (latent in the class code too):
   `reveal-functions`' walk handles a local named like a function
   correctly, but `reveal-funcs-expr?` rejects any variable in the
   function set. Surfaced when the prelude added `last` and r4-9
   binds a local `last`. Puffin's fix: uniqueify seeds its used-name
   set with all top-level names, so such locals are renamed and the
   situation can't arise. Left as-is in p4/322@pr5 (unreachable
   with their corpus; a fix would perturb golden ASTs).
5. **`lift-lambdas` captured user variables named `env`** (also
   latent in the class p5 code): the closure parameter was literally
   named `env`, so a function with its own `env` argument — every
   interpreter ever written — got a duplicate/captured parameter
   after closure conversion. Surfaced by the eval/apply example
   (puffin-9). Puffin gensyms the closure parameter; logged for the
   class projects (any fix changes their golden ASTs).
6. **`main.rkt` `run-chain` ran every pass twice** — once inside
   `run-pass-expect` and once as `(pass input)` for the next input.
   With gensym in play the checked output and the next pass's actual
   input could differ (and everything compiled twice). Puffin's
   `run-chain` feeds the recorded output forward. *Deliberately not
   fixed in p4/322@pr5*: the existing goldens were generated under
   the old behavior, and refreshing them there is a bigger change
   than the bug.
7. **`system.rkt`'s `execute-get-output` captured assembler/linker
   errors and discarded them** (silent link failures); Puffin's
   `main.rkt` prints them.

Puffin's own bring-up produced its share, all covered by tests now:
spill slots initially collided with the callee-saved save area (the
classic frame-layout bug — `#<unknown:195>` garbage was the
symptom); `main` originally tail-jumped past its own conclusion;
prim shadowing was originally re-decided per pass instead of settled
in desugar. Writing the PL-course suite flushed out two more, in the
since-retired JS web interpreter: internal defines were honored only
in lambda/begin bodies (not cond/case/when/unless/let bodies), and —
subtler — quasiquote unquotes evaluated right-to-left, so side
effects in `` `(-> ,(go x) ,(go y)) `` ran in reverse source order
(caught by HM inference's canonical type naming).

## What it still doesn't do

- **macOS-native only**: the x86-64 renderer already emits ELF-style
  sections, but the arm64 renderer is Mach-O-only (`@PAGE`
  relocations), and neither native backend is exercised on Linux.
  The bytecode VM is plain C and is the portable route.
- **No character type**: strings are byte strings (`string-length`,
  `substring`, `string-byte`, `string-append`, `string<?`,
  `number->string`/`string->number` and friends exist; there is no
  `char` and no `string-ref`).
- **No instruction-level abstract machine**: below uncover-locals
  there is no per-backend simulator for single-stepping; chain mode
  plus native goldens are the coverage story.
- **puffincc compiles whole-program**: separate compilation lives on
  the Racket side (`src/separate.rkt`).
- A REPL define may not shadow a primitive name (files can).
