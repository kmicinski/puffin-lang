# Puffin gradual types: ADTs first, `_` everywhere else

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
    | (Vec τ) | (Hash τ τ) | (Set τ)     containers (both mutability flavors)
    | (-> τ ... τ)                       functions, fixed arity
    | (->* (τ ...) τ τ)                  variadic: fixed args, rest-elem, result
    | (Name τ ...)                       ADT instances, e.g. (Option Int)
    | a b c ...                          type variables (lowercase)
```

Type variables are scoped to the `define-type` or annotation that
introduces them; there is no explicit `forall` in v1 — top-level
function annotations with free lowercase names are implicitly
prenex-polymorphic, instantiated per use.

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
  stays a binder, as today). Exhaustiveness over a closed ADT is a
  warning, not an error, in v1.

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

### Runtime representation (v1, and the honest caveat)

A constructor instance is a tagged vector: slot 0 holds the
constructor's (module-mangled) symbol, slots 1..n the fields. `match`
compiles constructor patterns to a vector-kind + slot-0 `eq?` check —
all three implementations (reference, web, puffincc) get the dynamic
semantics with zero runtime changes. The leak: `(vector? (Some 1))`
is `#t` in v1. The fix — a dedicated heap kind with its own printer
(`(Some 1)` instead of `#(Some 1)`) and an `adt?` disjoint from
`vector?` — is one runtime module + kind registration (the HAMT
precedent), scheduled after the checker settles.

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
an expression; no Hindley–Milner generalization in v1 — ADT
constructors and prenex-polymorphic prims instantiate their type
variables greedily against argument types, with `_` filling anything
underdetermined.

**Lists vs pairs.** `cons : (-> a b (Pairof a b))` (so `(cons 1 2)`
is fine in any code), and `(List a)` is treated equi-recursively: the
consistency checker unfolds `(List a)` one step to
`(Pairof a (List a))`-or-nil on demand. `'() : (List _)`. This gives
assoc-pairs and proper lists honest types simultaneously without
unions or subtyping.

**Erasure semantics (v1).** Types are checked, then erased in
desugar; the runtime's existing tag checks are the dynamic safety
net. Phase 3 inserts casts with blame labels at `_`→concrete
boundaries (the classic gradual guarantee); the checker is written so
cast points are already identified (every use of `_ ~ τ` at an
elimination position).

## 5. Prim and container types come from the manifest

`prim-spec` grows a `type` field — the single-source-of-truth
invariant extends to types. Representative entries:

```
cons        : (-> a b (Pairof a b))        car  : (-> (Pairof a b) a)
vector-ref  : (-> (Vec a) Int a)           make-vector : (-> Int (Vec _))
hash-set    : (-> (Hash k v) k v (Hash k v))
hash-ref    : (-> (Hash k v) k v)          set-add : (-> (Set a) a (Set a))
+           : (-> Int Int Int)             eq?  : (-> a b Bool)
println     : (-> a Void)                  read : (-> Int)
```

Both mutability flavors share the container type in v1 (a `(Mut ...)`
wrapper is future work — gradualness papers over the difference at
`_` boundaries anyway).

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
types/constructors are ordinary (mangled) top-level names — the
module system needs no changes. `.pufs` signatures grow typed entries
(`(val zero Int)`, `(fun add (-> Int Int Int))`) in a later phase.

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
2. Web + puffincc: `define-type`/match dynamic semantics for parity.
3. Casts + blame; typed signatures; the dedicated ADT heap kind;
   exhaustiveness as an error option; `(Mut ...)` containers.
```
