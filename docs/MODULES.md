# Puffin modules: SML structure discipline, Racket surface, separate compilation

> **Status (2026-07-07):** §1 and §2 are IMPLEMENTED, three times over:
> `src/modules.rkt` (the reference front pass, hooked into
> `read-program-file` so every route — interp, chain, both backends,
> the trace server — sees modules), `web/src/puffin/modules.js` (the
> web interpreter, over a virtual file map), and
> `puffincc-src/modules.puf` (puffincc itself, which both COMPILES
> module programs and IS one: puffincc-src/ is a module DAG rooted at
> main.puf). Resolution is whole-program (load the require DAG,
> mangle each non-entry module's top-level names, flatten in
> depth-first postorder). Corpus: `src/test-programs/modules-1..6`
> runs on every route; the compile-time failure modes live in
> `src/test-modules.rkt`.
>
> **§3 separate compilation is IMPLEMENTED** (same day, arm64 only)
> in `src/separate.rkt` + sep-mode hooks in the pipeline/backend:
> `bin/puffin -c --module foo.puf` builds `build-cache/<pathhash>/
> foo.{o,pufi}` (stale/missing deps rebuild recursively);
> `bin/puffin -c --separate main.puf -o prog` compiles every DAG
> module separately (cached) and links. The default no-flag route is
> untouched (verified byte-identical). Tests:
> `racket src/test-separate.rkt` (modules-1..6 + modules-typed
> goldens through --separate, incremental-rebuild behavior,
> double-diamond init-once, the typed-boundary matrix).
> Implementation notes that postdate this design are in §3.1 below;
> **interfaces are TYPED since 2026-07-12** (§3.2): dependency
> exports typecheck at their `.pufi` types, imported ADTs
> match/warn/cast like whole-program ones, and the interface digest
> covers types (signature edits rebuild dependents, body edits
> don't).
>
> Implementation notes that postdate the design: renaming is UNIFORM
> through a module (binders and references alike), which preserves
> binding structure without scope analysis — the renamer only knows
> where symbols are *data* (quoted datums, quasiquote templates
> outside unquotes, match-pattern structure, case datums). Importing
> a reserved word (`match`, `else`, …) unqualified is an error; use
> `#:as`/`#:rename`. `set!` to an imported name is currently allowed
> and mutates the exporting module's cell.
>
> **Types are module citizens (2026-07-11; §1.1 below):** `provide`
> may name a `define-type` head; importers then use the type in any
> annotation position, unqualified or as `M.Type`. Diagnostics are
> demangled (§1.1). Both resolvers (`src/modules.rkt`,
> `puffincc-src/modules.puf`) now also compute IDENTICAL module ids
> (fnv1a-32 over the entry-relative path), so
> `racket src/diff-ir.rkt desugar <module-program>` is a meaningful
> cross-compiler oracle (puffincc grew a `--dump-after <pass>` CLI
> flag for file mode, since a require DAG cannot arrive on stdin).

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

### 1.1 Type names are first-class exports

A `define-type` binds its head AND its constructors as ordinary
top-level names, and all of them provide/require/qualify/rename
uniformly. One rename map serves both namespaces:

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

This needs no dedicated machinery in the resolver: the renamer is
uniform over the module (data positions excepted), and a type
annotation is not a data position, so `[s : Shape]` rewrites through
the import map exactly like a reference to `area` does. Structural
heads (`Int Bool Sym Str Void _ -> ->* List Vec Hash Set Pairof
Mut`) are never in any rename map, so they pass through untouched.
What the type-name story adds around that:

- **Demangled diagnostics.** Resolution gives each non-entry module's
  top-level names a mangled spelling (`Shape` →
  `Shape_shapes_826109a6`); the resolver registers every mangled →
  source pair in a table (`src/system.rkt` /
  `puffincc-src/system.puf`), and both checkers consult it ONLY when
  RENDERING a name or type into an error/warning message — never when
  comparing (the mangled spellings ARE the type identities). The same
  table demangles exhaustiveness warnings (`match on Shape is not
  exhaustive: missing Rect`), cast blame labels (`area's argument
  s`), and the display element of ADT cast descs (`cast: expected
  Shape, ...` — the desc's constructor TAG list stays mangled, since
  those are the runtime identities the check compares). Byte-identical
  across the two compilers; `src/test-modules.rkt` pins that. Known
  edge: two modules exporting same-named types demangle to the same
  spelling, so confusing one for the other reads `argument has type
  Shape, expected Shape` — correct (they ARE different types) but
  unqualified; qualifying colliding spellings by module stem is a
  possible refinement.
- **Unknown types are errors.** Annotating with a type name that does
  not resolve — e.g. importing from a module that did NOT provide it —
  is `typecheck: unknown type Shape`, not a silently opaque type that
  fails later with a baffling mismatch.
- **One name, one namespace entry.** `define-type X` + `define X` in
  one module is an error (`X is defined as both a type and a value`) —
  a provide of `X` would otherwise be ambiguous. `define-type` of a
  built-in type or former (`Int`, `List`, ...) is likewise rejected.
- **Corpus**: `src/test-programs/modules-typed/` exercises all of the
  above positively on every route (interp, bytecode VM, native arm64,
  puffincc-on-wasm).

Separate compilation carries all of this across `.pufi` interfaces
(§3.2, 2026-07-12): a dependency's exports typecheck at their
interface types, imported ADTs register from the interface (the
`module-ext-*` `_`-escape remains only for names whose type really is
dynamic), and the sep-comp checker sees what whole-program resolution
sees. Racket-side only: puffincc has no separate compilation.

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
  defined. This is SML's opaque-ish ascription for namespace purposes.
- **Typed entries** (2026-07-12): `(val zero Int)`,
  `(fun add (-> Int Int Int))` (the arrow supplies the arity check),
  `(fun fmt (->* (Str) _ Str))`, and `(type Shape)` are accepted
  alongside the untyped forms. The stated type must be CONSISTENT
  (gradually — `_` matches anything, so an untyped module satisfies
  any typed signature) with what is known about the name: on the
  whole-program path that is the module's `(: n τ)` declaration if
  any; on the separate-compilation path it is the `.pufi`'s recorded
  type — declared, derived, or checker-synthesized (§3.2), which is
  where a signature bites hardest.
- A signature file can also be required by CLIENTS as documentation
  (`(require "int-ring.puf" #:sig "ring.pufs")` re-checks the
  interface at the use site — belt and braces for published
  libraries), but this is never required.

## 3. Separate compilation

`bin/puffin -c --module geometry.puf` produces:

- `build-cache/geometry.o` — native code, all module-level names
  **mangled** with a short hash of the module path
  (`area` → `pf_m3f9a_area`), so `.o`s never collide;
- `build-cache/geometry.pufi` — the interface, an s-expression
  (typed since 2026-07-12; see §3.2):

```scheme
(interface "geometry.puf"
  (hash "…sha1 of source…")
  (requires "vec.puf" "matrix.puf")
  (provides (area fun 1 pf_m3f9a_area (-> Shape_shapes_9ab Int))
            (perimeter fun 1 pf_m3f9a_perimeter (-> Int Int)))
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

### 3.1 As-built notes (2026-07-07)

Where the implementation refines (or deliberately deviates from) the
sketch above:

- **Symbol/string literals go through per-module slot tables.** The
  whole-program backend bakes symbol ids as immediates (pf_init
  interns the program's table in id order). Ids cannot agree across
  independently compiled `.o`s, so in separate mode each unit's init
  preamble interns its own symbol names (`pf_intern_symbol`) and
  materializes its string literals (`pf_string_from_bytes`) into
  assembler-local `Lpfm_syms`/`Lpfm_strs` arrays in `__DATA` (GC
  static roots); a literal is then one load. Cross-module `eq?` on
  symbols holds because the runtime interns by name. The entry unit
  also defines the runtime's whole-program table symbols
  (`puffin_symbol_names` etc.) as empty — they are declared weak but
  Mach-O wants definitions.
- **Mangling hashes the ABSOLUTE path** (`name_<stem>_<fnv1a32 of
  abs path>`), not the entry-relative path whole-program resolution
  uses: a module's `.o`/`.pufi` must not depend on who required it.
  Same for the cache key `build-cache/<fnv1a32 of abs path>/`.
- **`.pufi` extensions**: a `(flags ...)` row (target / -O level /
  safe-mode; mismatches rebuild), `requires` entries carry the dep's
  *interface digest* — a sha1 over (module-id, provides, types,
  globals label+count, init) only, so editing a dep's bodies rebuilds
  just the dep — `val` provides carry their globals-array slot, and
  `fun` arities are `(fixed n)`/`(variadic n)`. Require-site `#:sig`
  ascription re-checks against the `.pufi` (the whole point: no dep
  bodies are read), typed entries included (§2).
- **Per-module state**: globals array `pfm_globals_<mid>` (.globl,
  collect-globals numbering within the module — imported value
  defines compile to `(ext <label> <slot>)` descriptors that flow
  opaquely to the renderer), init `pfm_init_<mid>` with a run-once
  guard flag, so linking a module into any init order is safe; the
  entry's `main` calls every init in require-DAG postorder right
  after `pf_init`.
- **The prelude is one shared unpruned module** (deliberate v1
  relaxation of "pruned per module"): mangled labels like any
  module, implicitly required by all. Its exports are threaded to
  each unit as name→label pairs *at reveal-functions time* rather
  than pre-renamed, because desugar introduces references (e.g.
  `unquote-splicing` → `append`) after resolution runs. A module
  defining its own `map` still shadows the prelude's, exactly as in
  whole-program mode.
- **Entry unit caching**: `<stem>.entry.{o,rec}`; the record adds
  the init-call list (a new transitive dep changes it without
  touching the entry's source).
- **Separate mode compiles at ≤ -O1**: the -O2 AAM layer assumes a
  closed program (its dead-define client would drop a provided but
  locally-unused function). Cross-module inlining stays out, per §4.
- **arm64 only** for now; the x86-64 backend has not grown the
  sep-mode literal machinery (`--separate -t x86-64` errors).

### 3.2 Typed interfaces (2026-07-12)

The `.pufi` carries the types the whole-program checker would have
seen, so `--separate` typechecks module boundaries exactly like
whole-program compilation — Racket-side only (puffincc has no
separate compilation). Concretely:

- **Every provide row carries the export's gradual type** — from a
  `(: n τ)` declaration, inline annotations, or the checker's
  SYNTHESIZED type for an unannotated value define (`_` only when the
  type really is dynamic; an unannotated function still exports its
  arity-shaped `(-> _ ... _)`, so cross-unit arity misuse is a
  compile-time error). The prelude's trusted `(#%prelude: ...)`
  signatures ride along the same way, so `(length 5)` fails in a
  separately compiled module exactly as it does whole-program.
- **A provided `define-type` head is a `type` row**, backed by a
  `(types ...)` section carrying the full ADT: mangled + source
  spellings for the head and every constructor, the type parameters,
  and the constructors' field types. The mangled constructor names
  ARE the runtime tags (the exporting unit's `adt-alloc` quotes
  them), so an importer's match compilation, exhaustiveness warnings,
  and cast descs agree with the dependency's `.o` byte-for-byte. The
  section is transitively CLOSED: any ADT a provided signature or an
  embedded row's fields mention (own-private or from a transitive
  dep) is embedded too — the importing checker reads nothing but the
  one `.pufi`.
- **The importer consumes interfaces, not sources**: resolution
  splices one `#%extern-type` form per interface ADT (the checker and
  desugar register it exactly like a `define-type` that defines
  nothing) and threads provide types through `module-ext-types`
  (`system.rkt`), the typed refinement of the `module-ext-*` escape.
  Nullary constructors import as values (a globals-array slot),
  n-ary ones as functions (a mangled label) — both typed. Demangled
  spellings from the rows feed the diagnostics table, so a cross-unit
  error, exhaustiveness warning, or cast blame reads `Shape`, never
  `Shape_shapes_9ab`.
- **Staleness is type-aware**: the interface digest covers the
  provides' types and the types section, so a signature-level change
  (a type tightened, a constructor added) rebuilds dependents, while
  a body-only edit — including changing a value's initializer to
  another of the same synthesized type — still rebuilds only the
  module itself.
- Tests: `src/test-separate.rkt` (`modules-typed` through
  `--separate` against the shared goldens; the misuse /
  exhaustiveness / cross-unit-blame matrix; typed staleness).

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
2. `src/separate.rkt` — the build orchestrator: DAG load (reusing
   `load-modules`), per-module resolution against dep `.pufi`s,
   staleness, object compilation, linking. `src/puffin.rkt` grew the
   `--module`/`--separate` flags. Extern symbols flow to the
   backends as the existing `fun-ref`/global machinery (externs are
   just labels the assembler resolves at link time).
3. Backends: honoring extern labels for cross-module calls (direct
   `callq f_m… ` at ≥ -O1), the per-module init function (the
   synthesized entry, under a parameterized name), and the sep-mode
   literal tables of §3.1.
4. Tests: `src/test-programs/modules-1..6` — multi-file corpus
   entries (the golden runner learned one new shape: a directory
   with a `main.puf`) covering qualified/unqualified/renamed
   imports, sig ascription, and DAG init order on every route; sig
   failure modes in `src/test-modules.rkt`; stale-cache rebuilds and
   the double-diamond init-once in `src/test-separate.rkt`.
