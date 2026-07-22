# The Puffin optimizer: -O 0|1|2

This document describes Puffin's optimizer: what each optimization
level does, where the passes sit in the pipeline, how the `-O1`
rewrite layer and the `-O2` abstract interpreter work, and how the
whole thing is tested. It is written for anyone who wants to know
what `-O 2` actually buys — or who wants to read the sources.

The optimizer exists in both compilers, kept in lockstep: the
primary implementation is `puffincc-src/contract.puf`,
`puffincc-src/aam.puf`, and `puffincc-src/optimize.puf` (with the
backend and block-level hooks in `puffincc-src/middle.puf` and
`puffincc-src/backends.puf`); the Racket implementation in
`src/opt/` is the consistency oracle. `racket src/diff-ir.rkt
optimize <prog.puf> [target] [olvl]` checks that both produce
identical IR after the `optimize` pass, modulo gensym spelling.

## The three levels

| level | what runs | cost bound |
|---|---|---|
| `-O0` | nothing — the base pipeline, verbatim | — |
| `-O1` (default) | cp0-style **contraction + bounded inlining** on the core IR, **block-level optimizations** at explicate-control, and **open-coding** of data-structure primitives in the native backends | O(n · E) for a constant effort limit E — the Waddell–Dybvig discipline Chez itself uses |
| `-O2` (opt-in) | everything in `-O1`, plus **AAM-based interprocedural flow analysis** (0-CFA-class, widened global store) and its clients: super-beta inlining, interprocedural constant folding, dead-definition pruning | polynomial and guaranteed terminating; a state ceiling backstops the bound |

`-O1` is never asymptotically worse than Chez's cp0: every
transformation is metered by an **effort counter** charged per node
visited on behalf of an inlining attempt; when the budget for an
attempt is exhausted, the attempt is abandoned (residualized),
exactly as in "Fast and Effective Procedure Inlining" (Waddell &
Dybvig, 1997). Total optimizer time is then linear in program size
times the constant limit.

Two designed boundaries on where the levels apply:

- **Separate compilation caps at `-O1`.** The `-O2` analysis assumes
  it can see the whole program; a separately compiled module cannot
  grant that, so the `--separate` build path compiles each unit at
  ≤ `-O1`. See the separate-compilation section of docs/MODULES.md.
- **The REPL runs at `-O0`.** `--repl` implies the bytecode target
  with the repl-mode passes, unoptimized.

## Where the optimizer sits in the pipeline

```
desugar → shrink → uniqueify → [optimize] → collect-globals → … → anf → explicate → backends
                        ▲
        unique names, full expression structure,
        set! still visible, closures not yet converted
```

The `optimize` pass is IR-preserving (`unique-source-tree?` in and
out), so every downstream pass, interpreter, predicate, golden
test, and the provenance/visualization machinery work unchanged;
`-O0` simply makes it the identity. The placement is deliberate:

- **before assignment-convert**: mutability is still syntactic
  (`set!` on a name), so the census can classify assigned variables
  exactly instead of seeing boxed cells;
- **before lift-lambdas**: inlining happens while lambdas are still
  expressions, so inlined closures simply dissolve (no closure
  record is ever allocated);
- **after uniqueify**: no capture questions; substitution is
  textual, and fresh names for inlined copies come from `gensym`.

The `-O1` block-level transformations and the backends' open-coding
live further downstream (see their sections below); they read the
same `optimize-level` switch.

## Labels and staging

Every core-IR node gets a fixnum label once, up front
(`label-program!`); the analysis and its clients speak in labels,
never in raw syntax.

The `-O2` analyzer is **staged against the program**: before
iteration begins, it walks the syntax once and compiles, for every
label, a specialized transfer closure — the abstract step with the
pattern-match on syntax already performed, so what remains is pure
lattice arithmetic on the store. The worklist loop never touches
syntax. This is the Racket/Puffin rendition of partially evaluating
the abstract machine against the program (abstract compilation),
and it removes the dominant constant factor of naive AAM.

The labeled, staged formulation is also deliberate headroom: a
labeled program is exactly an EDB (`(app ℓ ℓf ℓa)`, `(lam ℓ x ℓb)`,
…) and the transfer closures correspond one-to-one to Horn rules,
so re-hosting the heavyweight analyses on a Datalog engine would be
a transcription, not a redesign. Nothing in the current system
depends on that; it is a shape the code keeps on purpose.

## -O1: contraction and bounded inlining

One demand-driven recursive rewrite in the cp0 mold, over the core
IR (`puffincc-src/contract.puf`, `src/opt/contract.rkt`):

1. **Census** (one O(n) pass): for every variable — reference
   count, whether it is `set!`, whether its binding is a lambda,
   whether it escapes (is referenced other than in rator position).
2. **Contraction**, applied on the way down/up:
   - constant & copy propagation: `(let ([x k]) e)` substitutes `k`
     when `x` is unassigned and `k` a literal/variable (never past
     a `set!` of the rhs variable);
   - `if`-folding on literal tests (Racket truthiness: only `#f`
     is false);
   - algebraic prim folding on literal operands (`(+ 1 2)` → 3,
     `eq?` on literals, `not` chains — the same table the
     interpreters derive from the stdlib manifest);
   - dead-`let` elimination: unreferenced, unassigned, effect-free
     rhs (effect analysis is syntactic: prims from the manifest
     marked pure);
   - `begin`/`let` flattening.
3. **Inlining**: at every application whose rator is (or propagates
   to) a lambda or a known top-level function:
   - β-contract single-use lambdas unconditionally (pure size win);
   - otherwise attempt an inline: copy the body with fresh names,
     charge every node copied against the effort counter; abandon
     and residualize if the size limit or effort limit trips.
     Recursive functions inline at most once per call site per
     round (no loop unrolling at `-O1`);
   - a per-round **code-growth budget** caps multi-use inlining at
     a quarter of the program's size (with a floor of 2000 nodes so
     small programs are unconstrained; single-use inlines are
     net-zero and exempt). Without it, a large program with many
     small hot functions bloats 4–5× in assembly and swamps the
     assembler; with it, big-program compile times stay in cp0
     territory.
4. Iterate 1–3 until no change or a round limit (the effort fuel
   makes each round linear; the round limit is a small constant —
   currently 4).

**Correctness invariants**: never propagate into or past `set!`;
never let inlining make the census misclassify a binding as dead
when a copied lambda still shares an assigned variable; `(read)`
and effectful prims are immovable anchors.

## Open-coded primitives (native backends, ≥ -O1)

At `-O0`, `car`, `cdr`, `vector-ref`, `vector-set!`,
`vector-length`, `pair?`, `null?`, … are **runtime calls** — a
`callq`/`bl` per list node touched, the single largest run-time gap
against Chez on list-heavy code. At ≥ `-O1` the native backends
(arm64 and x86-64) emit them inline:

- the tag scheme makes this cheap: a tagged fixnum index *is* a
  byte offset (`v + idx + 7` addresses element `idx` of a vector
  whose payload starts at offset 8 behind ptr-tag 1);
- open-coding is **safe**: the kind/bounds checks are emitted
  inline (compare + branch to the runtime's error path), still
  several times cheaper than a call. The checks are always present
  — see Limitations for the not-yet-wired `-O2` check elision.

The bytecode target does not open-code these prims; they remain
calls through the manifest-ordered primitive table (see
docs/BYTECODE.md).

Also at ≥ `-O1`: applications whose rator is a known top-level
function of matching arity compile to **direct calls** — no closure
fetch, no indirect jump. The analysis-free case is syntactically
visible after reveal-functions; `-O2`'s super-beta client widens it
to flow-proven single-target sites.

## Block-level optimizations (explicate-control, ≥ -O1)

Three transformations that live where control flow becomes explicit
(explicate-control: `src/compile.rkt` on the Racket side,
`puffincc-src/middle.puf` in puffincc) — downstream of the
tree-level optimizer, upstream of all backends, so each is written
once and every target benefits:

- **Loop recovery**: a self tail call would otherwise run the full
  call protocol — stage arguments, set the arity register, jump,
  re-execute the prologue — every iteration. Instead, the
  function's entry tail moves to a fresh `loophead` label and every
  plain self tail call rewrites to parameter reassignment +
  `(goto loophead)`. The reassignment is two-phase (arguments into
  fresh temps, then temps into the formals) because the arguments
  may read the formals being reassigned. Applied to every
  non-entry, non-variadic function; `main` is exempt (it must reach
  its print-result conclusion), and `#%rest` functions keep the
  call protocol that packs their rest list.

- **Fused compare-and-branch**: an `if` whose test is a single
  comparison keeps the comparison *inside* the `if` through
  anf-convert and explicate-control (an `(if (cmp a b) …)` block
  tail), so the backends emit `cmp` + conditional branch directly —
  the boolean is never materialized into a register and immediately
  re-tested. This is the inner-loop pattern of every numeric
  benchmark.

- **Blocks cleanup**: (a) jump threading — a block that is exactly
  `(goto M)` is bypassed by retargeting its predecessors; (b)
  single-predecessor merging — a terminal `(goto M)` where `M` has
  exactly one predecessor splices `M`'s tail in place; (c)
  unreachable blocks are dropped. Mostly hygiene after loop
  recovery and fusion, but it also shrinks the code the register
  allocator sees.

## -O2: the AAM

An eval/apply CESK\* abstract machine over the *direct-style* core
IR — no pre-ANF required (`puffincc-src/aam.puf`,
`src/opt/aam.rkt`):

- **States**: `(E ℓ)` evaluates the node at label ℓ; `(A ℓ)`
  propagates ℓ's finished value to its continuations. Because value
  addresses are variable names (0-CFA — names are globally unique
  after uniqueify) and every expression's continuation address is
  its own label (monovariant), states carry no environment at all:
  the whole state space is 2 × |labels|.
- **Store**: one global widened store, `addr → ℘(abstract-value)`,
  join = set union + widening. It has three regions that never
  share keys: R(ℓ), the value set of expression ℓ; K(ℓ), the
  continuations awaiting ℓ; and σ(x), the value set of variable x.
  Store growth re-enqueues exactly the states that read the grown
  address (per-address dependency sets), so the fixpoint is
  incremental rather than round-based.
- **Abstract values**: a flat domain —
  `⊤ | (const k) | (clo ℓ) | type tags` (`pair`, `vector`,
  `string`, `symbol`, `fixnum`, `bool`, `hash`, `set`, `void`,
  `nil`) — small by design so the store stabilizes fast and every
  domain operation is near-O(1). Widening: two consts of one type
  collapse to the type tag; value sets past a small size collapse
  to ⊤.
- **Soundness around ⊤**: a closure that flows into a primitive's
  arguments, into a ⊤-callee's arguments, or into a set collapsed
  to ⊤ has *escaped* — it may be called from anywhere with
  anything. Escaped closures get their formals joined with ⊤ and
  their bodies analyzed under a top continuation (whose returned
  closures escape in turn). This is what keeps the clients honest
  on programs that store closures in hashes and lists.
- **Termination**: finite labels × finite addresses × finite domain
  ⇒ a finite state space; widening makes the fixpoint monotone. A
  global state ceiling (200,000 states processed) is a
  belt-and-braces backstop: if tripped, the analysis reports
  nothing and the clients degrade to `-O1` behavior — optimization
  may be lost, correctness never.

**Clients** (each a labeled-facts consumer; at `-O2` they run
first, then the `-O1` contraction rounds see the rewritten tree):

1. **Flow constant folding**: references whose flow set is a
   singleton `(const k)` rewrite to `k` — interprocedural constant
   propagation.
2. **Super-beta**: call sites whose rator's flow set is a singleton
   closure inline through variables (`-O1` only sees syntactic
   rators).
3. **Dead definitions**: top-level functions never read in any
   reachable abstract state are dropped, mutually recursive dead
   cliques together (subsuming and extending the parse-time prelude
   pruning).

Every client rewrite preserves `unique-source-tree?` and semantics;
anything doubtful is left alone.

One dialect delta between the two implementations: Puffin has no
exceptions, so puffincc's client walk cross-checks its traversal
against the analyzer's node table and any label desync is a loud,
fatal error rather than a silent identity fallback. The state
ceiling still degrades gracefully to `-O1` in both.

## Performance

There is a small 14-benchmark suite (`bench/`) run against Racket CS
(the Chez backend). Read it for what it is: a tiny, self-selected set
of programs, useful for keeping the optimizer honest across `-O`
levels, not a basis for any claim about beating Chez. Chez is a mature
system with decades of tuning behind it, and this suite is not the
evidence that would settle a comparison. On these programs Puffin's
native code lands in the same broad ballpark — ahead on some, behind
on others.

What the suite does show reliably is the effect of the levels
themselves: `-O1` is roughly a 1.5× geomean improvement over `-O0`;
`-O2` adds about 1% on these workloads (its clients mostly matter on
higher-order code the suite underweights).

Where Puffin is clearly slower, the causes are understood:

- **sort / symdiff** — small-object allocation churn: the Boehm
  collector's allocation path against Chez's generational bump
  allocator.
- **lc-interp / hamt** — persistent-hash operation constants; closing
  this would need HAMT node specialization or a flow-guided
  environment representation.

`bench/report.html` breaks every benchmark down per level, showing
run time *and* compile time — the optimizer's own cost is a reported
number, not a footnote.

## Testing discipline

- The full corpus (309 golden checks) must be green at **every**
  level, on both native targets, plus the chain-mode per-pass
  predicates (`racket src/test.rkt -m all -O1`, `-O2`).
- `bench/` runs every benchmark at all three levels.
- Chain mode interprets every IR after every pass; the optimizer's
  output interpreting identically to its input on every corpus
  program is the cheapest strong oracle available.
- `racket src/diff-ir.rkt optimize <prog.puf> [target] [olvl]`
  holds the two implementations to identical post-`optimize` IR,
  modulo gensym spelling.

## Limitations

- **Separate compilation is capped at `-O1`.** The AAM assumes a
  closed program; a separately compiled unit is not one. This is a
  designed boundary, not an oversight — see docs/MODULES.md, which
  also notes there is no cross-module inlining at `-O1`.
- **Check elision is not wired.** Open-coded primitives and the
  tag-checked arithmetic always emit their inline kind/bounds
  checks, even at `-O2`. The natural fourth client — dropping
  checks where the flow analysis proves pair-ness/vector-ness with
  an in-bounds index — is the intended consumer of the type-tag
  domain but is not yet implemented.
- **Big programs build at `-O0`.** On a program the size of
  puffincc itself (s-expression walkers everywhere), the open-coded
  pair/vector primitives multiply the assembly output by roughly
  4–5× and the system assembler grinds on the result; inlining is
  not the culprit (the growth budget binds it). Until open-coding
  is size-aware (shared per-function check stubs, or a per-function
  open-coding budget), `bin/build-puffincc` builds stage 1 at
  `-O0`. Normal-sized programs — the whole benchmark suite — are
  unaffected.
- **The bytecode target does not open-code primitives**; they
  remain table calls (the tree-level `-O1`/`-O2` rewrites still
  apply).
- **The REPL compiles at `-O0`.**
