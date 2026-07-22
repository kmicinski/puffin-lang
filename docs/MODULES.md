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

(define pi 314159)                  ; private unless provided
(define (area r) (* pi (* r r)))
(define (perimeter r) (* 2 (* pi r)))
```

- `(provide name ...)` — anywhere at top level, unioned. **No provide
  form at all means everything top-level is provided** (specs are
  optional all the way down; a library grows a provide list when it
  wants one).
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

Separate compilation carries all of this across module boundaries: a
dependency's exports typecheck at their recorded interface types,
and imported ADTs (constructors, exhaustiveness, cast blame) behave
exactly as under whole-program compilation.

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
  defined. This is SML's opaque-ish ascription for namespace
  purposes.
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
