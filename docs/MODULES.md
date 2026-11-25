# Puffin modules: SML structure discipline, Racket surface, separate compilation

This document describes Puffin's module system for anyone writing
multi-file Puffin programs: how files become modules, how names and
types cross module boundaries, optional signatures, and how the
Racket toolchain compiles modules separately. Implementation
internals — the resolver, name mangling, the `.pufi` interface
format, build caching — live in the implementation notes at
[docs/internal/modules.md](internal/modules.md).

Design goals, in order: (1) modularity you can trust (explicit
exports, no accidental capture between files); (2) genuine
**separate compilation** (a module compiles to a `.o` + a small
interface file; downstream compilation reads only the interface);
(3) **optional** specs — signatures constrain and document when you
want them and stay out of the way when you don't.

Modules work on every route: the native backends, the bytecode VM,
the browser playground's file tabs, and the interpreter all resolve
the same way (puffincc-src/ itself is a module DAG). Separate
compilation is a feature of the Racket toolchain; puffincc compiles
module programs whole-program.

## Surface language

A **file is a module** (Racket's discipline). Its name is its path.

```scheme
;; geometry.puf
(provide area perimeter)            ; explicit export list (Racket)

(require "vec.puf")                 ; plain import: provided names in scope
(require "matrix.puf" #:as M)       ; qualified import: M.transpose, M.det

(define pi 314159)                  ; not provided: stays inside
(define (area r) (* pi (* r r)))
(define (perimeter r) (* 2 (* pi r)))
```

- `(provide name ...)` — anywhere at top level, unioned. **No provide
  form at all means everything top-level is provided** — except what
  the module declares `(private ...)` (specs are optional all the way
  down; a library grows a provide list when it wants one, and hides a
  helper with one declaration when it doesn't; see "Private
  definitions and opaque types").
- `(require "path.puf")` — imports the module's provided names
  unqualified. Collisions between two requires are a compile-time
  error (no silent shadowing across module boundaries).
- `(require "path.puf" #:as M)` — qualified only: references are
  `M.name` (the reader already reads `M.name` as one symbol; the
  module pass splits at the first dot when `M` is a module alias —
  user symbols containing dots that are NOT module aliases keep
  working).
- `(require "path.puf" #:only (f g))` and `#:rename ((old new))` —
  the Racket conveniences.
- Requires must form a DAG (cycles are a compile-time error naming
  the cycle). Order of top-level effects: depth-first postorder of
  the require DAG, each module once — SML/Racket agreement.

REPL and single-file programs are unchanged: a file with no
`require`/`provide` compiles exactly as before (the module pass is
the identity on it).

Two consequences of how resolution renames worth knowing day to day:

- Importing a reserved word (`match`, `else`, …) unqualified is an
  error; use `#:as`/`#:rename`.
- `set!` to an imported name is allowed and mutates the exporting
  module's cell.

## Type names are first-class exports

A `define-type` binds its head AND its constructors as ordinary
top-level names, and all of them provide/require/qualify/rename
uniformly — a type import looks exactly like a value import:

```scheme
;; shapes.puf
(provide Shape Point Circle Rect area)   ; the TYPE provides too
(define-type Shape (Point) (Circle Int) (Rect Int Int))

;; main.puf
(require "shapes.puf")
(define (describe [s : Shape]) : Sym ...)     ; imported type, by name

;; or qualified — M.Type in type positions, like M.name in expressions
(require "shapes.puf" #:as S)
(define (biggest [a : S.Shape] [b : S.Shape]) : S.Shape ...)
```

What you can rely on:

- **Diagnostics always use source spellings.** Internally, imported
  names get module-mangled spellings, but every error, exhaustiveness
  warning, and cast blame label renders the name as you wrote it
  (`match on Shape is not exhaustive: missing Rect`, `area's
  argument s`) — byte-identical across both compilers. Known edge:
  two modules exporting same-named types render the same spelling,
  so confusing one for the other reads `argument has type Shape,
  expected Shape` — correct (they ARE different types) but
  unqualified.
- **Unknown types are errors.** Annotating with a type name that
  does not resolve — e.g. importing from a module that did NOT
  provide it — is `typecheck: unknown type Shape`, not a silently
  opaque type that fails later with a baffling mismatch.
- **One name, one namespace entry.** `define-type X` + `define X` in
  one module is an error (`X is defined as both a type and a value`)
  — a provide of `X` would otherwise be ambiguous. `define-type` of
  a built-in type or former (`Int`, `List`, ...) is likewise
  rejected.

- **Type aliases are type names.** `(define-type-alias Env (Hash
  Str Value))` binds `Env` like a `define-type` head: it provides,
  imports unqualified or as `M.Env`, and renames the same way, and
  an importer may alias it again (`(define-type-alias Env2 E.Env)`).
  The checker unfolds it after resolution, so the exporting module's
  types are what the importer's annotations mean (docs/TYPES.md §3).
- **Templates are data; they never resolve.** A constructor builds
  the list headed by its own source name (docs/GRAMMARS.md §3), so a
  template spells a value with that name however the constructor was
  imported: `` `(Circle ,r) `` is the same value as `(Circle r)` after
  `(require "shapes.puf")`, as `(S.Circle r)` under `#:as S`, and as
  `(Disc r)` after `#:rename ((Circle Disc))`. Expressions and
  constructor patterns name the constructor through the module system
  like any other name; templates and quoted data never rename.
- **Grammars are type names.** A `define-grammar` binds its head like a
  `define-type` head: it provides, imports, qualifies and renames the
  same way. Inside its productions only type names (capitalized) are
  references; every other symbol is a literal.

Separate compilation carries all of this across module boundaries: a
dependency's exports typecheck at their recorded interface types,
and imported define-types (constructors, exhaustiveness) behave
exactly as under whole-program compilation. One difference: a cast
against an imported grammar or define-type checks nothing in the
importing unit (its recognizer lives in the exporting unit), so that
boundary is unchecked at run time under separate compilation.

## Signatures (the SML mix-in, optional)

```scheme
;; ring.pufs — a signature file
(signature RING
  (val zero)                 ; a value
  (fun add 2)                ; a function of stated arity
  (fun mul 2)
  (fun neg 1))
```

```scheme
;; int-ring.puf
(provide #:sig "ring.pufs")  ; ascribe: exports become exactly the sig
(define zero 0)
(define (add a b) (+ a b)) ...
```

- Ascription checks: every sig name is defined; `fun` arities match
  the definition (variadics satisfy any arity ≥ their fixed count);
  and it **narrows** — names outside the sig are private even if
  defined. This is SML's opaque ascription (`:>`) for namespace
  purposes, and for types too: a `(type T)` entry whose
  constructors the signature does not list makes `T` abstract
  outside the module (ML's `type t` in a signature); listing them —
  `(type T)` plus `(val Leaf)`/`(fun Node 2)` entries — is the
  transparent datatype spec. A signature cannot name a name the
  module declares `(private ...)`.
- **Typed entries**: `(val zero Int)`,
  `(fun add (-> Int Int Int))` (the arrow supplies the arity check),
  `(fun fmt (->* (Str) _ Str))`, and `(type Shape)` are accepted
  alongside the untyped forms. The stated type must be CONSISTENT
  (gradually — `_` matches anything, so an untyped module satisfies
  any typed signature) with what is known about the name: the
  module's `(: n τ)` declaration if any, or — under separate
  compilation — the type recorded in its interface, which is where a
  signature bites hardest.
- A signature file can also be required by CLIENTS as documentation
  (`(require "int-ring.puf" #:sig "ring.pufs")` re-checks the
  interface at the use site — belt and braces for published
  libraries), but this is never required.

## Private definitions and opaque types

Explicit exports are the first design goal, but a provide list is
all-or-nothing: until now the only way to hide one helper was to list
every other name. Hiding is now **per definition**, declared next to
the definition the way a type is declared with `(: name τ)`:

```scheme
;; queue.puf -- no provide form: everything not private is exported
(opaque Queue)                         ; the type's name goes out,
(define-type Queue                     ; its constructor stays home
  (Q (List Int) (List Int)))

(: empty Queue)
(define empty (Q '() '()))

(private balance)                      ; not exported at all
(define (balance [f : (List Int)] [b : (List Int)]) : Queue
  (if (null? f) (Q (reverse b) '()) (Q f b)))

(define (enqueue [q : Queue] [x : Int]) : Queue
  (match q [(Q f b) (balance f (cons x b))]))
```

### Private definitions

- `(private name ...)` — anywhere at top level, unioned, like
  `provide`. Any top-level binder can be private: a function, a
  value, a type alias, a grammar, a foreign import. A private
  `define-type` takes its constructors with it.
- A module with no provide form exports everything **not** private.
  With a provide list, `private` is documentation the resolver holds
  you to: providing a private name is an error, and so is a
  signature that names one.
- Private names are never imported, so they never collide: two
  modules may each keep a private `helper`, and a client may define
  its own.
- Reaching for one is reported as privacy, not as a typo:
  `M.helper`, `#:only (helper)`, and an unqualified `helper` all say
  `helper is private to lib.puf`.
- The entry module may declare privates too (nothing imports it, so
  it only documents).

### Opaque types

A `define-type` whose module exports **none of its constructors** is
**abstract** to every other module — ML's abstract type. Three ways
to get one, all meaning the same thing:

- `(opaque T ...)` — export `T`'s name, keep its constructors private
  (the convenient spelling in a module with no provide list, and a
  guard in one with a provide list: providing a constructor of an
  opaque type is then an error). Only a `define-type` can be opaque:
  a type alias *is* its expansion, so there is nothing to hide.
- a provide list that names `T` and none of its constructors;
- a signature with a `(type T)` entry and no constructor entries.

Outside its module an abstract type is a **bare name**. A client can
annotate with it, pass its values along, store them in lists, and
compare them with `eq?`/`equal?`; type tests (`(? symbol? x)`),
binders and `_` may match it. What it cannot do:

- **build one** — the constructors are not in scope
  (`C is private to counter.puf`);
- **take one apart** — any other pattern against a value whose type
  is abstract is an error (`Counter is abstract outside counter.puf:
  a pattern cannot take it apart`), constructor patterns and
  quasiquote templates alike;
- **forge one from data** — constructors build plain data (a list
  headed by the constructor's name, docs/GRAMMARS.md), so inside its
  module `'(C 41)` *is* a `Counter`; outside, an abstract type has no
  productions for a template or quoted datum to match, so
  `(: c Counter) (define c '(C 41))` is a type error.

The owning module sees through its own types as before — constructor
patterns, templates, exhaustiveness. The rule is checked per
top-level form: the resolver records which module every flattened
form came from, and the checker treats another module's abstract
types as opaque names while it checks that form (implementation
notes in [internal/modules.md](internal/modules.md)).

**What abstraction does not do** (deliberately — see Limitations):
it is static. Puffin is gradual and its data is data, so code typed
`_` can still build a value that looks like a `Counter`, and the
runtime cast at a typed boundary checks the *shape*, not who built
it. An abstract type keeps typed code honest and makes the module's
representation free to change; it is not a security boundary.

## Separate compilation

Separate compilation lives in the Racket toolchain, targeting arm64:

```
bin/puffin -c --module geometry.puf     # build one module (cached)
bin/puffin -c --separate main.puf -o prog
                                        # compile every DAG module
                                        # separately (cached), link
```

`--module` compiles one module to a cached `.o` (its names mangled
so objects never collide) plus a `.pufi` **interface file** — a
small s-expression recording what the module provides, at what
types, along with its dependencies' interface digests. Compiling a
module that `require`s others reads ONLY their `.pufi` files
(compiling them first if missing or stale — a built-in `make`).
`--separate` compiles every module in the DAG this way, links every
`.o` plus the runtime, and the entry's prelude calls each module's
init in postorder before its own top-level runs. The default no-flag
route is untouched — its output is byte-identical whether or not
separate compilation is ever used.

Interfaces are **typed**: every provide row carries the export's
gradual type (declared, derived, or synthesized — an unannotated
function still exports its arity shape, so cross-unit arity misuse
is a compile-time error), and provided ADTs travel with their full
definitions, so an importer's pattern matches, exhaustiveness
warnings, and cast blame agree with the dependency byte-for-byte.
Staleness is type-aware: a signature-level change (a type tightened,
a constructor added) rebuilds dependents; a body-only edit rebuilds
only the module itself.

The interface format, mangling scheme, per-module literal tables,
and cache layout are specified in the
[implementation notes](internal/modules.md).

## Limitations

- No functors, no nested modules, no first-class modules. The
  file-DAG + signatures covers the daily need; functors wait until
  the type system gives them something to abstract over.
- Privacy is per module. ML's `local ... in ... end` (helpers visible
  to a group of declarations only) has no counterpart: a module is a
  file, so a group that wants its own helpers is a small module of
  its own. There is no `define-private` either: privacy is a
  declaration beside an ordinary `define`, so every tool that reads
  definitions (the checker, assists, the studio) sees the same forms
  it always did.
- No opaque type **aliases** (SML's `type t = int` sealed by `:>`):
  an alias unfolds everywhere before checking, and keeping it nominal
  outside its module would mean unfolding per module. Make the
  representation a one-constructor `define-type` and declare it
  opaque instead.
- Abstraction is static (see "Opaque types"): no runtime sealing or
  branding of abstract values, and `equal?` still compares their
  representation (ML would ask for an equality type).
- Under separate compilation privacy narrows the interface (private
  names never reach a `.pufi`), but abstract types are enforced by
  whole-program checking only: an imported `.pufi`'s ADT rows carry
  no abstract mark yet, so a separately compiled importer still sees
  the representation.
- Separate compilation is Racket-toolchain-only and arm64-only.
  puffincc compiles module programs whole-program; the x86-64
  backend rejects `--separate`.
- No cross-module inlining: separate mode compiles at ≤ -O1 (the
  -O2 abstract interpreter assumes a closed program), and the
  interface carries arities and types, not bodies. A later `-O2`
  could put small bodies in the `.pufi` (Chez-style cross-module
  optimization) — the interface format has room.
- Two modules exporting same-named types demangle to the same
  spelling in diagnostics (see the type-exports section);
  qualifying colliding spellings by module stem is a possible
  refinement.
