# Puffin modules: SML structure discipline, Racket surface, separate compilation

Design goals, in order: (1) modularity you can trust (explicit exports,
no accidental capture between files); (2) genuine **separate
compilation** (a module compiles to a `.o` + a small interface file;
downstream compilation reads only the interface); (3) **optional**
specs — signatures constrain and document when you want them and stay
out of the way when you don't.

## 1. Surface language

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
- `(require "path.puf" #:only (f g))`, `#:rename ((old new))` — the
  Racket conveniences, cheap to support.
- Requires must form a DAG (cycles are a compile-time error naming the
  cycle). Order of top-level effects: depth-first postorder of the
  require DAG, each module once — SML/Racket agreement.

## 2. Signatures (the SML mix-in, optional)

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
  defined. This is SML's opaque-ish ascription for namespace purposes
  (no type components yet; when gradual types land, `val`/`fun` grow
  type annotations and this is where they get checked).
- A signature file can also be required by CLIENTS as documentation
  (`(require "int-ring.puf" #:sig "ring.pufs")` re-checks the
  interface at the use site — belt and braces for published
  libraries), but this is never required.

## 3. Separate compilation

`bin/puffin -c --module geometry.puf` produces:

- `build-cache/geometry.o` — native code, all module-level names
  **mangled** with a short hash of the module path
  (`area` → `pf_m3f9a_area`), so `.o`s never collide;
- `build-cache/geometry.pufi` — the interface, an s-expression:

```scheme
(interface "geometry.puf"
  (hash "…sha1 of source…")
  (requires "vec.puf" "matrix.puf")
  (provides (area fun 1 pf_m3f9a_area)
            (perimeter fun 1 pf_m3f9a_perimeter))
  (init pf_m3f9a__init))
```

Compiling a module that `require`s others reads ONLY their `.pufi`
files (compiling them first if missing/stale by source hash — a
built-in `make`). The final `bin/puffin -c main.puf` links every
`.o` in the DAG plus the runtime, and `main`'s prelude calls each
module's `_init` in postorder before its own top-level runs.

Each module gets its own globals segment and its own literal tables
(symbol interning is global at runtime — the runtime already interns
by name, so cross-module `eq?` on symbols holds).

The prelude (`src/prelude.puf`) becomes what it always morally was:
a module implicitly required by every module (still pruned to what
each module mentions, so `.o` sizes stay small).

## 4. What stays out (v1)

- No functors, no nested modules, no first-class modules. The
  file-DAG + signatures covers the daily need; functors wait until
  the type system gives them something to abstract over.
- No cross-module inlining at `-O1` (the interface carries arities,
  not bodies). `-O2` may later put small bodies in the `.pufi`
  (Chez-style cross-module optimization) — the interface format has
  room.
- REPL and single-file programs are unchanged: a file with no
  `require`/`provide` compiles exactly as today (the module pass is
  the identity on it).

## 5. Implementation map

One new front pass + a build orchestrator; the core pipeline is
untouched (module resolution happens before desugar):

1. `src/modules.rkt` — parse module forms, load/produce `.pufi`s,
   check signatures, resolve `M.name` and unqualified imports to
   mangled names, reject collisions/cycles. Output: an ordinary
   single-module program whose free references to other modules are
   already-mangled externs, plus link metadata.
2. `src/main.rkt` — `--module` compile mode (emit `.o`+`.pufi`),
   link mode gathers the DAG; extern symbols flow to the backends as
   the existing `fun-ref`/global machinery (externs are just labels
   the assembler resolves at link time).
3. Backends: nothing new except honoring extern labels for
   cross-module calls (direct `callq pf_m…_f` at ≥ -O1) and the
   per-module init function (a `define` like any other).
4. Tests: `src/test-programs/modules/` — a multi-file corpus entry
   (the golden runner learns one new shape: a directory with a
   `main.puf`), covering qualified/unqualified/renamed imports, sig
   ascription success + the three failure modes (missing name, arity
   mismatch, narrowing), DAG init order, stale-cache rebuilds, and a
   diamond dependency.
