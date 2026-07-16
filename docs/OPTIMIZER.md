
# The Puffin optimizer: pervasive analyses, staged, at three levels

Goal: make Puffin-compiled programs competitive with — and where possible
faster than — Chez on the benchmark suite, by exposing program analyses
pervasively through the pipeline. The reference implementation is Racket;
the analyses are written so the heavyweight ones can later be re-hosted in
Datalog/Rust (§6) without redesign.

## 1. The three levels

| level | what runs | cost bound | flag |
|---|---|---|---|
| `-O0` | nothing (the existing pipeline, verbatim) | — | default off-switch, baseline for diffing |
| `-O1` | cp0-style **contraction + bounded inlining** on the core IR, plus **safe open-coding** of data-structure primitives in the backends | O(n · E) for a constant effort limit E — the Waddell–Dybvig discipline Chez itself uses, so asymptotically no worse than Chez | default |
| `-O2` | everything in `-O1`, plus **AAM-based interprocedural analysis** (0-CFA-class, widened global store) and its clients: super-beta inlining, flow-proven check elimination, dead-definition pruning | polynomial (0-CFA is O(n³) worst case; the widened-store worklist with a flat value domain is far below that in practice), guaranteed terminating | playground |

`-O1` must never be asymptotically worse than Chez's cp0: every transformation
is metered by an **effort counter** charged per node visited on behalf of an
inlining attempt; when the effort budget for an attempt is exhausted, the
attempt is abandoned (residualized), exactly as in "Fast and Effective
Procedure Inlining" (Waddell & Dybvig, 1997). Total optimizer time is then
linear in program size times the constant limit.

## 2. Where the analyses live in the pipeline

```
desugar → shrink → uniqueify → [optimize] → collect-globals → … → anf → explicate → backends
                        ▲
        unique names, full expression structure,
        set! still visible, closures not yet converted
```

The `optimize` pass is IR-preserving (`unique-source-tree?` in and out), so
every downstream pass, interpreter, predicate, golden test, and the
provenance/visualization machinery work unchanged; `-O0` simply makes it the
identity. This placement is deliberate:

- **before assignment-convert**: mutability is still syntactic (`set!` on a
  name), so the census can classify assigned variables exactly instead of
  seeing boxed cells;
- **before lift-lambdas**: inlining happens while lambdas are still
  expressions, so inlined closures simply dissolve (no closure record was
  ever allocated);
- **after uniqueify**: no capture questions; substitution is textual, and
  fresh names for inlined copies come from `gensym`.

A second, later analysis point (post-ANF, on `blocks`) is reserved for
register-pressure- and representation-level analyses; the framework (§3) is
IR-agnostic so the same interface serves both. The backends themselves take
one bit of analysis product: the set of applications proven safe to
open-code without checks (§5).

## 3. The framework (src/opt/framework.rkt)

An analysis is a first-class description:

```racket
(analysis  init        ; program → state
           step        ; state → state         (or a per-node transfer)
           join        ; state state → state   (lattice ⊔)
           done?       ; state state → boolean (convergence test)
           extract)    ; state → facts          (what clients consume)
```

run through a generic worklist driver with **global store widening**: one
store shared by all abstract states, monotonically growing, iterated to
fixpoint (the structure of the `aam.rkt` gist). Facts are exposed to clients
as hash tables keyed by node label.

**Labels.** Every core-IR node gets a fixnum label once, up front
(`label-program!`); analyses and clients speak in labels, never in raw
syntax. This is the seam for the Datalog future: a labeled program *is* the
EDB (`(app ℓ ℓf ℓa)`, `(lam ℓ x ℓb)`, …).

**Staging.** The reference AAM is *staged against the program*: before
iteration begins, the analyzer walks the syntax once and compiles, for every
label, a specialized transfer closure (the abstract step with the
pattern-match on syntax already performed — what remains is pure lattice
arithmetic on the store). The worklist loop then never touches syntax. This
is the honest Racket rendition of partially evaluating the abstract machine
against the program (abstract compilation; cf. staged abstract
interpreters), it removes the dominant constant factor of naive AAM, and it
is exactly the shape a Datalog backend wants (transfer closures ≈ rule
instantiations).

## 4. -O1: contraction and bounded inlining (src/opt/contract.rkt)

One demand-driven recursive rewrite in the cp0 mold, over the core IR:

1. **Census** (one O(n) pass): for every variable — reference count, whether
   it is `set!`, whether its binding is a lambda, whether it escapes (is
   referenced other than in rator position).
2. **Contraction**, applied on the way down/up:
   - constant & copy propagation: `(let ([x k]) e)` substitutes `k` when `x`
     unassigned and `k` a literal/variable (never past a `set!` of the rhs var);
   - `if`-folding on literal tests (Racket truthiness: only `#f` is false);
   - algebraic prim folding on literal operands (`(+ 1 2)` → 3, `eq?` on
     literals, `not` chains — the same table the interpreters derive from
     the stdlib manifest);
   - dead-`let` elimination: unreferenced, unassigned, effect-free rhs
     (effect analysis is syntactic: prims from the manifest marked pure);
   - `begin`/`let` flattening.
3. **Inlining**: at every application whose rator is (or propagates to) a
   lambda or a known top-level function:
   - β-contract single-use lambdas unconditionally (pure size win);
   - otherwise attempt an inline: copy the body with fresh names, charge
     every node copied against the **effort counter**; abandon and
     residualize if the size limit or effort limit trips. Recursive
     functions inline at most once per call site per round (no loop
     unrolling at `-O1`).
4. Iterate 1–3 until no change or a round limit (the fuel makes each round
   linear; the round limit is a small constant).

**Correctness invariants**: never propagate into/past `set!`; never inline a
lambda that captures an assigned variable *by copy* (the copy shares the
variable — fine — but the census must not then treat the binding as dead);
`(read)` and effectful prims are immovable anchors.

## 5. Open-coded primitives (backends, ≥ -O1)

At `-O0` today, `car`, `cdr`, `vector-ref`, `vector-set!`, `vector-length`,
`pair?`, `null?` … are **runtime calls** — a `callq`/`bl` per list node
touched. That is the single largest run-time gap against Chez on the
list-heavy benchmarks. At `-O1` the backends emit them inline:

- the tag scheme makes this cheap: a tagged fixnum index *is* a byte offset
  (`v + idx + 7` addresses element `idx` of a vector whose payload starts at
  offset 8 behind ptr-tag 1);
- `-O1` open-codes **safely**: the kind/bounds checks are emitted inline
  (compare + branch to the runtime's error path), still several times
  cheaper than a call;
- `-O2` consults the analysis: where the abstract value at the argument
  label proves pair-ness / vector-ness with an in-bounds index domain, the
  checks are dropped. Check elimination is thus an analysis *client*, not a
  trust-me flag.

Also at ≥ `-O1`: applications whose rator is a known top-level function of
matching arity compile to **direct calls** (no closure fetch, no indirect
jump) — the analysis-free case is already syntactically visible after
reveal-functions; `-O2` widens it to flow-proven single-target sites
(super-beta).

## 6. -O2: the AAM (src/opt/aam.rkt)

An eval/apply CESK\* abstract machine over the *direct-style* core IR — no
pre-ANF required (the eval/apply split keeps the continuation vocabulary
small: `app-k`, `arg-k`, `if-k`, `let-k`, `begin-k`, `set-k`, `while-k`):

- **States**: `(E ℓ ρ κa)` evaluating the node at label ℓ, and `(A v κa)`
  returning abstract value v — environmentless, per the eval/apply insight.
- **Store**: one global widened store, `addr → ℘(abstract-value)`, join =
  set union; the worklist reprocesses states whose dependencies grew
  (dependency tracking per address, so the fixpoint is incremental rather
  than round-based).
- **Allocation** (the polyvariance dial, chosen per AAM): value addresses
  are variable names (0-CFA); continuation addresses are `(ℓ, ρ)` of the
  target — the pushdown-for-free choice that recovers call/return precision
  without an explicit stack machine.
- **Abstract values**: a flat product domain —
  `⊤ | (const k) | (closs {ℓ…}) | (prim p) | type-only tags (pair, vector,
  string, symbol, fixnum, bool)` — small by design so the store stabilizes
  fast and every domain operation is O(1)-ish (respecting the
  O(n·log n)-per-fact spirit).
- **Termination**: finite labels × finite addresses × finite domain ⇒
  finite state space; widening makes the fixpoint monotone. A global effort
  ceiling (states processed) is a belt-and-braces backstop: if tripped, the
  analysis returns ⊤-everywhere and the clients degrade to `-O1` behavior —
  optimization may be lost, correctness never.

**Clients** (each a labeled-facts consumer, run before/with `-O1`'s
contraction):

1. **Super-beta**: call sites whose rator's flow set is a singleton closure
   inline through variables (`-O1` only sees syntactic rators).
2. **Flow constant folding**: references whose flow set is a singleton
   `(const k)` rewrite to `k` — interprocedural constant propagation.
3. **Check elimination**: argument labels whose flow sets prove `pair`-ness
   etc. mark their applications for checkless open-coding (§5).
4. **Dead definitions**: top-level functions whose entry labels are
   unreachable in the final state graph are dropped (subsumes and extends
   the parse-time prelude pruning).

## 7. The Datalog/Rust future

The staged, labeled formulation is chosen so that migrating the heavyweight
analyses is a transcription, not a redesign: labels are the EDB; the
transfer closures correspond one-to-one to Horn rules (`flows(ℓv, addr) :-
app(ℓ, ℓf, ℓa), flows(ℓf, lam(ℓ')), …`); the widened store is the IDB;
Slog/Soufflé-style engines take it from there. The Racket reference stays as
the executable spec and differential-testing oracle (same facts in, same
facts out, modulo set ordering).

## 8. Testing & benchmarking discipline

- The full corpus (92 programs × 3 inputs) must be green at **every**
  level, on both targets, plus the chain-mode per-pass predicates
  (`racket src/test.rkt -m all -O1`, `-O2`).
- `bench/` runs every benchmark at all three levels; the report shows
  run-time *and* compile-time per level (the optimizer's own cost is a
  reported number, not a footnote — Chez's cp0 speed is the bar).
- Differential fuzzing: chain mode already interprets every IR after every
  pass; the optimizer's output interpreting identically to its input *on
  every corpus program* is the cheapest strong oracle we have.

puffincc remains `-O0`-only for now; once the reference optimizer settles,
the contraction layer (§4) is the first candidate for translation.
