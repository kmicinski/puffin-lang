# Puffin: what's the delta from p5?

This document is for the person who wrote the CIS352/531 p5 compiler
(R4/R5 → x86-64) and is about to start writing code in this repo. It
walks the whole system and answers, at each spot: *what changed, why,
and where do I look?* Everything s-expression-based, everything in
your pass-chain style — the goal was a language you can actually use
instead of Racket day to day, grown out of the class compiler rather
than replacing it.

## TL;DR tour

```
src/
  puffin.rkt        the CLI: `bin/puffin` = REPL | run | compile     (NEW)
  repl.rkt          console REPL over the reference interpreter      (NEW)
  main.rkt          run-chain / traces / assemble+link  (same bones as p5)
  test.rkt          golden runner over the WHOLE class corpus        (NEW)
  compile.rkt       frontend + middle-end passes        (grown from p5)
  irs.rkt           per-IR predicates                   (grown from p5)
  interpreters.rkt  per-IR reference interpreters       (grown from p5)
  stdlib.rkt        THE STANDARD LIBRARY MANIFEST                    (NEW)
  system.rkt        flags/ABI + tags + targets          (grown from p5)
  regalloc.rkt      live-range register allocation (shared)          (NEW)
  backend-x86.rkt   x86-64: select/allocate/patch/prelude/render     (from p5 code)
  backend-arm64.rkt AArch64: the same five passes                    (NEW)
  runtime/          partitioned C runtime + Boehm GC -> libpuffin.a  (NEW)
  test-programs/    all r0-..r5-* class examples + puffin-* tests
  input-files/ goldens/
bin/puffin          the day-to-day entry point
web/                browser interpreter + REPL (Monaco, solarized light)
docs/STDLIB.md      generated from the manifest — never edit by hand
```

Quick start:

```
bin/puffin                       # REPL
bin/puffin prog.puf              # compile natively (arm64 on this mac) and run
bin/puffin -i prog.puf           # interpret (same semantics, fast startup)
bin/puffin -c prog.puf -o prog   # just compile
racket src/main.rkt -t x86-64 prog.puf     # the classic verbose trace
racket src/test.rkt -m all       # interp + x86-64 + arm64 over the corpus
racket src/test.rkt -m gen       # regenerate goldens from the reference
```

The full corpus — every example program from p1 through p5, unmodified,
plus new `puffin-*` feature tests — passes on the reference interpreter,
the x86-64 backend (under Rosetta), and the arm64 backend: 168 checks
per route, byte-identical output.

## 1. The big semantic shift: tagged values

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
`shl 3; or 2`. The scheme lives (documented) in three places that must
stay in lockstep: `system.rkt`, `runtime/puffin.h`, and the
interpreters' value mapping in `stdlib.rkt`.

Heap objects: `| header | payload... |` with `header = (len << 8) | kind`.
Kinds: 1 vector, 2 pair, 3 string, 4 closure, 5 hash, 6 set (extension
modules can claim 16+ via the runtime's kind registry).

**Truthiness is Racket's**: only `#f` is false. `explicate-control`
already branched on `(eq? a #f)`, so this fell out almost free; `not`
shrinks to `(eq? e #f)`.

Booleans print `#t`/`#f`, symbols print bare, vectors `#(1 2 3)`,
lists `(1 2 3)`. The old runtime printed booleans as integers, so old
golden files are not comparable; `test.rkt -m gen` regenerates goldens
from the reference interpreter, and both backends are held to those.

## 2. The runtime: partitioned, GC'd, pluggable

`runtime.c` is gone. `src/runtime/` is:

- **`puffin.h`** — the whole ABI: tags, heap layout, allocation
  helpers, error hooks, and a *kind registry* (`pf_register_kind`)
  through which each data structure supplies its own display and
  `equal?` handlers. Read this first.
- **`core.c`** — only what everything depends on: Boehm GC glue
  (`GC_MALLOC` via the vendored universal `bdw-gc` in
  `runtime/vendor/gc`), symbol interning, string constants, fatal
  errors, display/equal *dispatch*, I/O, closures, `pf_init`.
- **`lib/pairs.c, vectors.c, strings.c, hashes.c, sets.c, arith.c,
  predicates.c`** — one module per feature; `lib/table.c` holds the
  open-addressing table both hashes and sets use (linear probing,
  power-of-two capacity, grow at 70%, eq?-keyed — the right notion for
  fixnum/boolean/symbol keys since symbols are interned).
- **`lib/stdlib_init.c`** — the one file that lists modules.
- **`Makefile`** — builds `libpuffin.a`, a *universal* (arm64+x86_64)
  static archive with libgc merged in, so linking any Puffin program
  is `clang [-target ...] output.o libpuffin.a -o output`.

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
both backends (every stdlib prim compiles to "args in registers, call
`rt-sym`"), the interpreters' behavior, `docs/STDLIB.md` (via
`src/gen-stdlib-docs.rkt`), and the extern lists. Adding a feature =
one C module + one manifest entry. Compiler intrinsics (`+ - * eq? <`
and the unsafe slot ops) are deliberately *not* in the manifest —
they're the compiler's vocabulary, not the library's.

## 3. Language additions (frontend)

New pass **`desugar`** (before shrink) turns full Puffin into core
Puffin:

- **`match`** — patterns: `_`, variables, literals (fixnum, boolean,
  string), `'sym`, quoted lists, `(cons p p)`, `(list p ...)`,
  `(vector p ...)`, `(? pred p)`, and **quasiquote patterns**
  (`` `(add ,a ,b) `` — so Puffin is pleasant for writing compilers,
  matching how compile.rkt itself is written), including **general
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

**`shrink`** now also: `not` → `(eq? e #f)`; `or` keeps its first
truthy value via a temp (Racket semantics), `begin` → let-chains.

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
uncover-locals) are your p5 passes, extended:

- compiler-internal heap access (assignment-conversion boxes, closure
  environments, arity-overflow vectors) uses **`unsafe-vector-ref` /
  `unsafe-vector-set!`** — inline, unchecked, literal index; the
  user-facing `vector-ref`/`vector-set!` are checked runtime calls
  with *dynamic* indices (the p5 IR only allowed literal indices).
- assignment-convert now boxes **only the variables that are actually
  `set!`** (per function), not everything.
- closures allocate with `make-closure` (own heap kind), so
  `procedure?` works and closures print as `#<procedure>` instead of
  leaking their representation.
- lift-lambdas sorts captured free variables, keeping output
  deterministic.
- **`(effect rhs)`** joins `assign` in the blocks IR for
  effect-position primitives (`println` etc.).

### Proper tail calls (NEW, and important)

`explicate-control` recognizes `(let ([x (app f a ...)]) x)` under a
`return` continuation and emits a **`tail-app`** tail. Both backends
lower it to a `tail-jmp` pseudo-instruction: load the target into a
scratch register *before* the argument moves, then (expanded by
prelude-and-conclusion, which knows the frame) restore the frame and
jump. `main` is exempted (it must run its print-result conclusion).
Named-let loops therefore run in constant stack — the corpus includes
a 2M-iteration loop. This is the "efficient tail calls via indirect
jump" the p5 README gestures at.

## 4. Register allocation (`regalloc.rkt`)

`assign-homes` (everything spilled) is replaced by **`allocate-registers`**:

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

## 5. Two backends, one shape

`system.rkt` has a `target` parameter (`'x86-64` | `'arm64`, default =
host). `main.rkt` splices the target's five backend passes after
uncover-locals; everything earlier is target-independent (even
limit-functions: both targets use six argument registers so the
overflow ABI is identical).

- **backend-x86.rkt** is your p5 backend grown up: new ALU ops for
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

On this mac, `-t x86-64` output runs under Rosetta; `test.rkt -m all`
holds both backends to the same goldens.

## 6. Testing (`src/test.rkt`)

Goldens are produced by the reference interpreter (desugar +
`interpret-puffin`) — the manifest's ref-impls *are* the semantics —
and every route must agree byte-for-byte:

- `-m interp` — the reference itself (sanity);
- `-m chain` — runs your run-chain trace over the frontend and checks
  every pass's interpreter output against the golden *and* both IR
  predicates per pass (this is the mode that localizes a bug to a
  pass in one command);
- `-m x86-64` / `-m arm64` — compile natively, feed each input file
  on stdin, compare;
- `-m gen` — regenerate goldens (reports programs the reference
  rejects instead of writing bad goldens).

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
Writing it flushed out two real interpreter bugs: internal defines
were only honored in lambda/begin bodies (not cond/case/when/
unless/let bodies) in the web interpreter, and — subtler — the web
interpreter evaluated quasiquote unquotes right-to-left, so side
effects in `` `(-> ,(go x) ,(go y)) `` ran in reverse source order
(caught by HM inference's canonical type naming).

Corpus: all class examples (r0-* through r5-*) run **unmodified** —
including the ones that define their own `cons` over vectors — plus
`puffin-*` tests covering match/guards/quasiquote, closures,
hashes/sets/symbols, strings, eta-expanded prims, `equal?`, tail-call
loops, `read`-driven programs, the immutable collections
(puffin-8), and puffin-9: an **eval/apply interpreter for an
extended lambda calculus** written exactly the way this compiler is
written (quasiquote-match over ASTs, immutable-hash environments,
closures as tagged data — the warm-up for bootstrapping the compiler
in Puffin itself). It runs letrec factorial, Church numerals, the Z
combinator, and a meta-meta-interpreter, on every execution route.

The per-pass interpreters in `interpreters.rkt`: `interpret-puffin`
covers desugar → anf-convert; `interpret-blocks` covers
explicate-control/uncover-locals (both drive primitive behavior from
the manifest). Instruction-level IRs are validated natively rather
than simulated (the old pseudo-x86 interpreter didn't survive tagging
+ two ISAs; the chain mode + native goldens cover the gap — a
per-backend abstract-machine simulator is future work if you miss it).

Three interpreter deltas from p5 style, deliberate: input is a
mutable box rather than threaded return values (the prim table made
threading unwieldy); truthiness is Racket's; mutable bindings are
Racket boxes.

## 7. REPL and CLI

- `bin/puffin` → `src/puffin.rkt` (see §TL;DR for flags).
- The console REPL (`src/repl.rkt`) runs on the reference
  interpreter with a persistent mutable top-level (`repl-toplevel` in
  interpreters.rkt), so defines arrive one at a time, mutual
  recursion across inputs works, and `(read)` reads live from the
  terminal. Commands: `,help`, `,env`, `,quit`. One documented
  limitation: a REPL define may not *shadow* a primitive name
  (files can).

## 8. The web REPL (`web/`)

A browser interpreter + REPL: Vite + SolidJS (fine-grained reactive
signals), Monaco editor with a Puffin tokenizer and a solarized-light
theme, the interpreter running in a Web Worker (long computations
never block the UI; runs are cancellable), a persistent REPL session
pane, an examples dropdown seeded from the corpus, and a stdin box
for `(read)`. The JS interpreter (BigInt fixnums, `Symbol.for`
symbols, Map/Set-backed hashes/sets) is held to the *same 168
goldens* via `node web/test-corpus.mjs`. See `web/README.md`.

## 9. IR provenance and the pipeline visualizer

Every pass's walker is wrapped (one line per pass) to tag each node
it constructs with the input node it came from, in a global weak
eq-hash (`src/provenance.rkt`) -- the IRs stay plain s-expressions
and no pattern anywhere changed. Because run-chain feeds each
pass's actual output object forward, provenance composes across all
17 layers by object identity. Nodes may carry a few candidate
origins (CPS-shaped passes construct nodes inside continuations);
resolution tries them in order, and untagged structural nodes
inherit their ancestor's origin.

`src/ir-json.rkt` serializes a trace for the web: a span-tracking
IR printer (per-node character ranges), per-layer back-edge maps,
and per-LINE provenance for the rendered assembly (both backends
export `render-lines-*`). `src/ir-server.rkt` -- the descendant of
the class debug-server.rkt -- serves `POST /trace` for the web app
and has a `--dump` mode (the bundled demo trace).

The web app's **Pipeline** mode shows any layer pair side by side:
click a node to highlight its origin in the previous layer (with
ancestor fallback), click left to see everything it *became*
(reverse edges), and follow a breadcrumb chain from an assembly
line all the way to the source expression.

## 10. Bootstrapping (see docs/BOOTSTRAP.md)

The report covers the compiler evaluation, the Racket-facility
inventory, and the feature batch it demanded -- quasiquote
expressions, internal defines/letrec, gensym, value->string/format,
read-all, the string/bit-work/list-utility/set-algebra batch,
apply/sort/map2 -- each implemented across the C runtime, the
manifest, the reference interpreters, and the web interpreter, all
under golden tests. `puffin-10` in the corpus is the bootstrap
seed: shrink + uniqueify written in Puffin, byte-identical on every
route.

## 11. Bugs found along the way (the log)

In the course projects:

1. **`322@pr5/compile.rkt` line 790** — `free-vars` of
   `(let ([_ (while g b)]) r)` unioned `(free-vars e-b)` twice and
   dropped `e-r`. Fixed (matches the fix already in `p4/`).
2. **`322@pr5/compile.rkt` line 1015** — shrink's `<` case didn't
   recurse into its operands. Fixed (ditto).
3. **`uniqueify` missed sibling-scope collisions** (both `p4/` and
   `322@pr5/`, and inherited by Puffin) — a rebinding was renamed
   only if the name was visible in the *enclosing* scope's map, so
   `(if c (let ([a 1]) a) (let ([a 2]) a))` kept two writes to `a`,
   violating `unique-source-tree?`. Never fired on class test
   programs; Puffin's match expansion (same pattern variable in two
   clauses) trips it immediately. Fixed in all three compilers with
   a per-definition used-name set; all 51 of p4's uniqueify golden
   outputs are byte-identical under the fix (it only changes
   behavior on collision), and Puffin's chain mode (1848 checks)
   is green.
4. **locals shadowing top-level function names confused the
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
   fixed in p4/322@pr5*: your existing goldens were generated under
   the old behavior, and refreshing them there is a bigger change
   than the bug.
5. `system.rkt`'s `execute-get-output` captured assembler/linker
   errors and discarded them (silent link failures); Puffin's
   `main.rkt` prints them.

In Puffin during bring-up (all covered by tests now): spill slots
initially collided with the callee-saved save area (the classic
frame-layout bug — `#<unknown:195>` garbage was the symptom);
`main` originally tail-jumped past its own conclusion; prim shadowing
was originally re-decided per pass instead of settled in desugar.

## 12. Modules, the optimizer, and the self-contained puffincc (2026-07)

Three coordinated moves, each documented in its own file:

- **The module system** (docs/MODULES.md) — `(require "path.puf")` /
  `(provide ...)` with `#:as`/`#:only`/`#:rename` and optional `.pufs`
  signature ascription, implemented as a front pass in all THREE
  implementations: `src/modules.rkt` (one hook in `read-program-file`
  covers every route), `web/src/puffin/modules.js` (virtual file map;
  the playground grew file tabs), and `puffincc-src/modules.puf`.
  Corpus: `modules-1..6` (the stack-VM, LC-interpreter, and sudoku
  programs split into modules, byte-identical to their single-file
  originals); failure modes in `src/test-modules.rkt`.

- **The optimizer** (docs/OPTIMIZER.md) — `-O0/1/2` in both compilers.
  The whole analysis + optimization stack (cp0-style contraction,
  the staged CESK* flow analysis and its clients, direct known
  calls, fused compare-and-branch, loop recovery, blocks cleanup,
  open-coded pair/vector prims) is ported to Puffin in
  `puffincc-src/{contract,aam,optimize}.puf` + hooks in
  `middle.puf`/`backends.puf`. `src/diff-ir.rkt <pass> <prog> [tgt]
  [olvl]` is the cross-implementation oracle.

- **puffincc as a real compiler driver** — puffincc-src/ became a
  module DAG rooted at `main.puf` (no more concatenation; the
  generated `tables.puf`/`prelude-data.puf` are ordinary modules).
  New io primitives (`read-file`, `write-file`, `file-exists?`,
  `command-line-args`, `system`; `src/runtime/lib/io.c`) make it
  self-contained: `build/puffincc prog.puf -o prog` resolves the
  program's modules from disk, compiles, and drives clang itself.
  `bin/puffincc-compile` is gone; `bin/build-puffincc` is just the
  stage-1 hosted build. Pipe mode (`puffincc < prog.puf > prog.s`)
  survives for single-file programs.

Performance work this exposed: the shared register allocator's
liveness/interval construction was quadratic in live-set size
(rewritten with mutable backward walks + hull endpoint anchoring, in
both `src/regalloc.rkt` and `backends.puf`), and arm64 frames larger
than 4095 bytes crashed the assembler (sp adjustments now split into
a shifted-page part + remainder, both implementations).

## 13. Where to take it next (agreed direction + loose ends)

- **Separate compilation** (docs/MODULES.md §3) — the `.pufi`/`.o`
  cache and link-time DAG assembly; the interface format is designed,
  the whole-program resolver is the semantic reference.
- **Gradual types** — the planned next step. The natural seam: a
  `typecheck` pass between desugar and shrink, annotations via
  `(: name type)` forms, tag checks elided where types are known.
  The tagged representation was chosen so checked/unchecked code can
  coexist.
- Arithmetic is currently unchecked (adding tagged words); with
  gradual types, checks become elidable rather than always-on.
  `car`/`cdr`/vector ops/hash/set ops *are* fully checked.
- `vector-ref`/`set!` as runtime calls are correct but leave inline
  performance on the table; an inline fast path behind `safe-mode`
  is sketched in backend comments.
- Strings are minimal (literals, append, compare, symbol conversion).
  No characters, no string-ref, no number->string yet — manifest
  entries away.
- The instruction-level abstract-machine interpreter (per backend) if
  you want single-stepping below uncover-locals.
- Linux support: x86-64 renderer already emits ELF-style sections;
  arm64 render is Mach-O-only (`@PAGE`); a `linuxify` pass of the
  arm64 renderer is mechanical.
