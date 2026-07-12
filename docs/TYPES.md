# Puffin gradual types: ADTs first, `_` everywhere else

> **Status:** §1–§5 are LIVE in BOTH checkers — `src/types.rkt` (the
> reference, invoked at the top of desugar so every route checks) and
> `puffincc-src/types.puf` (byte-identical messages) — including the
> formerly-v1-deferred pieces: variadic `(->* ...)` types, the
> `(Mut ...)` container wrapper, exhaustiveness checking over closed
> ADTs (a stderr warning; `--strict-types` on both CLIs promotes it
> to an error), and prim types folded into the manifest (`prim-spec`'s
> `#:type` field is the single source of truth; `tables.puf` and
> docs/STDLIB.md carry it). `typed-1`/`typed-2` are golden corpus
> programs; the rejection matrix lives in `src/test-types.rkt`; the
> whole corpus passes unchanged (300/300 — the gradual guarantee).
> One refinement beyond the design: in applications, a formal's
> CONCRETE structure is a contract (violations error) but a
> constraint that exists only because greedy instantiation bound a
> type variable from a sibling argument is an inference hint —
> conflicts there demote the variable to `_`. Casts with blame (§4)
> and the dedicated ADT heap kind (§2) are shipped as well; the one
> remaining boundary is typed `.pufs` signatures for separate
> compilation (§6).

Design goals, in order: (1) **gradual by design** — every program that
runs today is well-typed tomorrow; the unannotated type is `_` (Any),
and annotations only ever tighten; (2) **algebraic datatypes as the
foundation** — the interesting types in a PL-course language are tree
shapes, and quasiquote-matched s-expressions deserve a typed
alternative; (3) **honest container types** for the collections the
language already has; (4) **inference over annotation** in practice —
you annotate module boundaries and tricky spots, the checker fills in
the rest locally.

## 1. The types

```
τ ::= _                                  the dynamic type (Any); the default
    | Int | Bool | Sym | Str | Void     base types
    | (Pairof τ τ)                       cons cells
    | (List τ)                           proper lists (see §4: μ-treatment)
    | (Vec τ) | (Hash τ τ) | (Set τ)     containers (persistent / read-only view)
    | (Mut τ)                            mutable-container wrapper (τ: Hash/Vec/Set)
    | (-> τ ... τ)                       functions, fixed arity
    | (->* (τ ...) τ τ)                  variadic: fixed args, rest-elem, result
    | (Name τ ...)                       ADT instances, e.g. (Option Int)
    | a b c ...                          type variables (lowercase)
```

**Variadics.** A dotted define `(define (f a b . rest) ...)` derives
`(->* (τa τb) _ rt)` from its (possibly annotated) fixed formals — so
the arity floor is checked at every application even in untyped code —
and a `(: f (->* (τ ...) τrest τres))` declaration tightens it: fixed
arguments check against their types, every extra argument against
τrest, and `rest` is `(List τrest)` in the body. Variadic lambdas
synthesize `->*` the same way. Consistency relates the two arrow
flavors: `(->* (τ ...) τr τres) ~ (-> σ ... σres)` when the fixed
arrow supplies at least the fixed arguments (extras against τr).

Type variables are scoped to the `define-type` or annotation that
introduces them; there is no explicit `forall` **by design** — top-level
function annotations with free lowercase names are implicitly
prenex-polymorphic, instantiated per use. (A deliberate, permanent
choice, not a staging artifact: with greedy per-use instantiation an
explicit binder buys no expressiveness and costs syntax.)

## 2. Algebraic datatypes

```scheme
(define-type (Option a)
  (None)
  (Some a))

(define-type Expr                 ;; no parameters: plain name
  (Num Int)
  (EAdd Expr Expr)
  (EMul Expr Expr))

(define (eval-expr [e : Expr]) : Int
  (match e
    [(Num n) n]
    [(EAdd a b) (+ (eval-expr a) (eval-expr b))]
    [(EMul a b) (* (eval-expr a) (eval-expr b))]))
```

- A constructor with fields is a function (`Some : (-> a (Option a))`);
  a **nullary constructor is a value** (`None : (Option a)`) — one
  immutable instance, referenced bare. This reads like ML and avoids
  the `(None)`-call noise.
- Constructor names live in the same top-level namespace as functions
  (they provide/require/mangle through the module system unchanged).
  Convention: capitalized, but the compiler keys on *what the name is
  bound to*, not its spelling.
- **Pattern matching**: `(Ctor p ...)` is a constructor pattern when
  `Ctor` names an in-scope constructor; a bare pattern symbol that
  names a nullary constructor matches that constructor (anything else
  stays a binder, as today).
- **Exhaustiveness** (implemented): a `match` whose scrutinee's
  synthesized type is a concrete known ADT is checked against the
  type's constructor set; missing constructors produce a stderr
  warning (`typecheck warning: match on <Name> is not exhaustive:
  missing <C1>, <C2>` — declaration order) and compilation proceeds.
  `--strict-types` (both `bin/puffin` and `puffincc`;
  `strict-exhaustiveness?` in `system.rkt`) promotes it to an error
  with the same text. Coverage is conservative in the
  no-false-warnings direction: a wildcard/binder clause, a guarded
  catch-all, or any pattern the checker cannot prove partial counts
  as covering everything, and a constructor pattern covers its
  constructor even under a `#:when` guard. A `_`-typed scrutinee is
  exempt (the gradual guarantee: untyped code never warns).

### Implicit mutual recursion (the fix-block question)

All `define-type` declarations in a module form **one implicitly
mutually recursive group** — no `fix`/`and` block. This is NOT hard to
implement, and it is the only choice consistent with the rest of the
language: top-level `define`s are already letrec*-mutually-recursive,
so types behave like values do. Concretely the checker makes two
passes: pass 1 collects every type's name and arity (and every
constructor's owner); pass 2 elaborates constructor field types, at
which point any type in the module (or any imported one) may be
referenced. A manual fix block would buy nothing — the two-pass
discipline costs a dozen lines — and would make Puffin's types feel
foreign next to its values. The natural boundary stays: **cross-module
type recursion is impossible** because requires form a DAG, and that
is a feature (a module's types are a closed world once its file ends,
which is also what makes exhaustiveness checkable).

### Runtime representation

A constructor instance is its own heap kind (`src/runtime/lib/adt.c`,
kind 18 — one runtime module + kind registration, the HAMT
precedent): the layout mirrors a vector's (slot 0 holds the
constructor's module-mangled symbol, slots 1..n the fields), but the
dedicated kind closes the old v1 leak — `(vector? (Some 1))` is
`#f`, and `adt?` is the disjoint surface predicate. Instances print
as `(Some 1)`; a nullary constructor (a value, referenced bare)
prints bare: `None`. `equal?` recurses structurally (same
constructor, `equal?` fields), like vectors; as hash/set keys,
instances compare by identity, exactly like vectors. Only the
desugar lowering can construct an instance (via the internal
`adt-alloc`/`adt-set!` prims) or take one apart positionally
(`adt-tag`/`adt-ref`): `match` compiles a constructor pattern to an
`adt?` kind check plus a tag `eq?` — the tag alone fixes the arity —
so user code cannot forge or mutate one.

## 3. Annotations: anything, anywhere, defaulting to `_`

```scheme
(: pi Int)                              ;; top-level declaration form
(define pi 314159)

(define (area [r : Int]) : Int ...)     ;; params + result
(define (mixed a [b : Int] c) ...)      ;; any subset; a, c default to _
(lambda ([x : Int] y) ...)              ;; lambdas too
(let ([x : (List Int) (range 0 10)]) ...)
(ann e τ)                               ;; expression ascription
```

Anything unannotated is `_`. A whole program with no annotations
type-checks by construction — gradual, not optional-but-nagging.

## 4. Checking: bidirectional, with consistency

The checker is **bidirectional** (synthesize / check-against) with the
Siek–Taha **consistency** relation `~` in place of equality:

- `_ ~ τ` and `τ ~ _` for every τ;
- congruent componentwise on constructors/containers/arrows;
- **not transitive** (so `Int ~ _ ~ Bool` proves nothing).

An inconsistency is a compile-time type error. Inference is *local*:
`define`/`let` right-hand sides synthesize their types (so most
bindings are precisely typed without annotations); unannotated lambda
parameters synthesize `_` unless the lambda is checked against an
arrow type (then parameters flow in). No unification variables escape
an expression; there is no Hindley–Milner generalization **by design**
(inference stays local and predictable — the gradual answer to an
underdetermined type is `_`, not a quantifier) — ADT constructors and
prenex-polymorphic prims instantiate their type variables greedily
against argument types, with `_` filling anything underdetermined.

**Lists vs pairs.** `cons : (-> a b (Pairof a b))` (so `(cons 1 2)`
is fine in any code), and `(List a)` is treated equi-recursively: the
consistency checker unfolds `(List a)` one step to
`(Pairof a (List a))`-or-nil on demand. `'() : (List _)`. This gives
assoc-pairs and proper lists honest types simultaneously without
unions or subtyping.

**Cast semantics (shipped).** Types are checked, then LOWERED —
not merely erased — in desugar: every *declared* `_`→concrete
boundary is guarded by a transient-style cast before the annotation
disappears. Both compilers (src/compile.rkt and
puffincc-src/desugar.puf) insert the same casts:

1. annotated formals `[x : τ]` → a check on `x` at function entry
   (also for formals typed by a `(: f (-> ...))`/`(->* ...)`
   declaration, including a declaration over a literal
   `(define f (lambda ...))`);
2. declared result types (`: rt`, or the declared arrow's result) →
   a check in return position (the body is wrapped in `(let () ...)`
   so internal defines keep letrec* scoping);
3. `(ann e τ)` → a check on `e`'s value;
4. annotated let/let*/named-let bindings `[x : τ e]` → a check on
   `e`'s value;
5. `(: x τ)` value defines → a check on the initializer.

The check is **first-order** (transient): only the value's outermost
shape is validated — `Int`/`Bool`/`Sym`/`Str`/`Void` by tag,
`Pairof`/`List`/`Vec`/`Hash`/`Set` by heap kind (`(Mut τ)` and plain
`τ` share kinds: same check), and an ADT annotation by the dedicated
ADT kind *plus* tag membership in the type's constructor set, so
`(Some 1)` passes an `(Option Int)` cast but a `Shape` instance
fails it. Element/field types are never traversed. `_` and type
variables insert **no cast** (the gradual guarantee: unannotated
programs compile byte-identically to before), and **arrow types
insert no cast** — on the bytecode VM a bare function value is a
tagged fixnum function index, indistinguishable from an `Int`, so
callability cannot be checked soundly; the call site's own failure
is the arrows' net.

The runtime half is one manifest-appended internal prim,
`(cast-check v desc blame)` (`pf_cast_check`, src/runtime/lib/cast.c;
Racket reference impl in the manifest entry). On failure it is fatal,
byte-identical on every route (interp, native, VM, wasm):

```
puffin runtime error: cast: expected Int, got #t (blame: f's argument x)
```

Blame labels name the boundary — `f's argument x`, `f's result`,
`ann`, `let x`, `define x` (positions aren't tracked). In a REPL
session a firing cast aborts only that eval; the session survives.
The PRELUDE's signatures are written `(#%prelude: name τ)`: the
checkers read them exactly like `(: name τ)`, but they are TRUSTED —
the same trust class as the manifest's prim types — so no casts are
inserted for them (and the prelude's tail loops stay tail; a result
cast would un-tail them). `cast-check` is in no purity table: a cast
can abort, so the optimizers never drop or fold it. Runtime tests:
src/test-casts.rkt.

## 5. Prim and container types come from the manifest

`prim-spec` carries a `#:type` field (default `#f` = untyped, giving
`(-> _ ... _)` from the arity) — the single-source-of-truth invariant
extends to types: `src/types.rkt` reads it directly,
`gen-puffincc-tables.rkt` emits it into `puffincc-src/tables.puf` for
`types.puf`, `gen-stdlib-docs.rkt` renders it as docs/STDLIB.md's
Type column, and the manifest asserts type-arity agreement at load.
The only local table left in the checkers covers desugar-level
non-manifest forms (`+ - * eq? < <= > >= not`). Representative
entries:

```
cons        : (-> a b (Pairof a b))        car  : (-> (Pairof a b) a)
vector-ref  : (-> (Vec a) Int a)           make-vector : (-> Int (Mut (Vec _)))
hash-set    : (-> (Hash k v) k v (Hash k v))
hash-ref    : (-> (Hash k v) k v)          set-add : (-> (Set a) a (Set a))
hash-set!   : (-> (Mut (Hash k v)) k v Void)
+           : (-> Int Int Int)             eq?  : (-> a b Bool)
println     : (-> a Void)                  read : (-> Int)
```

**`(Mut τ)`** (implemented) separates the mutability flavors:
allocators produce it (`make-hash : (-> (Mut (Hash _ _)))`,
`make-set`, `make-vector`, and `(vector ...)` literals — there is no
persistent vector), mutating prims demand it (`hash-set!`,
`hash-remove!`, `set-add!`, `set-remove!`, `vector-set!`), and
persistent operations (`hash`, `hash-set`, `set`, `set-add`, ...)
stay on the plain types. Read-only accessors (`hash-ref`,
`hash-count`, `vector-ref`, `set-member?`, ...) are typed over the
plain container and accept both flavors because consistency is
**directional**: `(Mut τ) ~ τ'` whenever `τ ~ τ'` (a mutable value
may be used read-only), but a plain container never fits a `(Mut τ)`
expectation — `(hash-set! (hash 'a 1) 'b 2)` is a compile-time type
error when the types are concrete, while `_` papers over the
difference as usual.

## 6. Pipeline placement

```
read + resolve-modules
  → collect-types      (pass 1: type heads; pass 2: constructor sigs)
  → typecheck          (bidirectional; errors stop compilation)
  → desugar            (erases annotations; lowers define-type to
                        constructor defines; extends match compilation)
  → ... unchanged ...
```

`typecheck` sees the module-flattened surface program, so imported
types/constructors are ordinary (mangled) top-level names — and since
2026-07-11 type names are first-class exports: `provide Shape` lets
importers annotate with `Shape` (or `S.Shape` under `#:as`), the
checker rejects annotations naming unresolved types (`unknown type
X`), and every diagnostic renders the SOURCE spelling via the
resolver-registered demangling table in `system.rkt`/`system.puf`
(rendering only — comparisons use the mangled identities; see
docs/MODULES.md §1.1). `.pufs` signatures grow typed entries
(`(val zero Int)`, `(fun add (-> Int Int Int))`) in a later phase —
until then, separate compilation keeps its `_`-typed `module-ext`
escape at dependency boundaries.

## 7. Adoption ("update all code under our purview")

- **Everything keeps compiling** — unannotated code is `_`-typed by
  construction. The corpus is the regression suite for that claim.
- The **prelude** gets annotations where inference can't reach
  (variadics, higher-order folds); most of it stays inferred.
- New `typed-*` corpus programs showcase ADTs (a typed Expr evaluator,
  a typed red-black tree, a typed Option pipeline) alongside their
  untyped quasiquote twins.
- The **web examples** gain a typed tour; the web interpreter needs
  only the *dynamic* semantics of `define-type` (tagged vectors +
  match extension) to stay golden-equal — the checker itself can stay
  hosted-only initially.
- **puffincc** likewise needs only the dynamic semantics to keep the
  corpus green; porting the checker (and then using ADTs in puffincc's
  own source) is the last phase, gated on the reference settling.

## 8. Phases

1. Reference: surface syntax, ADT dynamic semantics end-to-end
   (both backends), the checker, manifest types, `typed-*` corpus.
   DONE.
2. Web + puffincc: `define-type`/match dynamic semantics for parity;
   the ported checker (`types.puf`) with byte-identical messages.
   DONE.
3. Variadic `->*`, `(Mut ...)` containers, exhaustiveness (warning +
   `--strict-types` error option), prim types in the manifest. DONE.
4. Casts + blame (DONE — see §4 "Cast semantics"); the dedicated ADT
   heap kind (DONE). Remaining: typed `.pufs` signatures.
```
