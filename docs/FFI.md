# The Puffin FFI: foreign imports are typed boundaries

This document is the reference for Puffin's foreign function
interface: the `foreign` form, the types that may cross the
boundary and the marshaling each one gets, the blame and error
grammar, the handle discipline, and the GC/ownership rules. It is
written for anyone binding a C (or C-ABI Rust/C++) library to
Puffin; the mechanism and testing sections near the end are for
contributors.

The design principles, in order:

1. **Type-directed by construction** — a foreign import is a typed
   declaration, and the declared type *generates* the marshaling;
   there is no way to write an unmarshaled or hand-marshaled call.
2. **Gradual soundness at the boundary** — values crossing the
   boundary are checked by the same transient cast machinery that
   guards `_`→concrete boundaries everywhere else (docs/TYPES.md),
   with blame labels naming the foreign import, byte-identical on
   every route.
3. **The FFI is the manifest, user-extended** — a `foreign`
   declaration behaves like a locally declared prim and rides the
   existing prim-call machinery end to end; the runtime contributes
   one `lib/` module and a handful of manifest entries, and the
   backends contribute nothing.
4. **Honest about the browser** — the wasm VM has no `dlopen`, and
   a program that declares a foreign library fails at load in the
   browser with a stable message rather than an emulation.

The design is assembled from known-good parts. The FFI is a
language boundary in the sense of Matthews & Findler's
multi-language semantics: marshaling is their *natural embedding*
for base types and their *lump embedding* for everything else
(opaque handles) — which is why the type table below has exactly
two behaviors, convert or lump, and no third. Boundary checks with
blame follow Typed Racket and Wadler & Findler: the label names the
foreign import, the only party a user can act on. The checks are
transient (first-order, Vitousek-style): the outermost shape is
checked at the boundary and nothing is traversed. For this FFI's
marshallable universe, that is not a compromise — every crossable
type is either a base type (the shape *is* the type) or an opaque
handle (identity *is* the type), so first-order checking coincides
with full natural-embedding soundness. It would stop being complete
the day callbacks or container borrows cross, which is one reason
they are excluded (the section "What stays out" below).

## 1. Surface language

```scheme
;; regex.puf -- a Puffin-face module for a foreign library
(provide Regex regex-compile regex-match? regex-find regex-close)

(define-foreign-type Regex)

(foreign "vendor/libpfregex.dylib"
  (: regex-compile (-> Str (Nullable Regex)) #:c-name "pfregex_compile")
  (: regex-match?  (-> Regex Str Bool)       #:c-name "pfregex_is_match")
  (: regex-find    (-> Regex Str (Nullable Str)) #:c-name "pfregex_find"
                                                 #:gift "pfregex_str_free")
  (: regex-close   (-> Regex Void)           #:c-name "pfregex_free"
                                             #:consumes))
```

### 1.1 The `foreign` form

`(foreign lib-path clause ... decl ...)` is a top-level module
form, next to `require`/`provide`. Path resolution: a `lib-path`
containing a `/` resolves relative to the declaring module's file
(like `require`); an absolute path loads as spelled; a bare name
(`"libSystem.B.dylib"`) goes to the system loader's search. The
library is loaded with `dlopen` when the module's top level runs —
**a missing library or symbol is a load-time error** (see the error
grammar below), on every route, because declaring a foreign library
is asserting it is loadable. The form is repeatable; multiple
`foreign` forms may name the same library, and `dlopen` handles are
cached per resolved path.

One form-level clause is accepted after the path:

- `#:include "header.h"` — opt-in cross-check of the declarations
  against the library's own C header, described in the
  header-cross-check section below. The header path resolves
  against the module's directory like the library path.

### 1.2 Import declarations

Each `decl` is a `(: name τ)` declaration — the same form the type
system already owns — plus FFI clauses. `τ` must be a concrete
`(-> τ ... τ)` over the marshallable types of the next section:
`_` is not marshallable, type variables are not marshallable, and
an FFI declaration is the one place an annotation is mandatory
(there is nothing to infer from; the far side is machine code).
Arity is at most 6 (the integer-class caller's ceiling; see the
mechanism section). The per-declaration clauses:

- `#:c-name "sym"` — the linker symbol. Default: the Puffin name
  with `-` → `_` (`demo-add` → `demo_add`); names containing any
  other C-hostile character (`?`, `!`, `>`) have no default and
  require the clause. No cleverer renaming — magic is where FFI
  bugs breed.
- `#:consumes` — the (single) handle-typed argument is *consumed*:
  after the call the handle is closed (handle lifecycle, below).
- `#:gift "free_sym"` — the `Str` result is malloc'd by the callee
  and ownership transfers: the runtime copies it into a Puffin
  string and immediately calls `free_sym` (resolved in the same
  library) on the original. Requires a `Str` or `(Nullable Str)`
  result.

### 1.3 Foreign handle types

`(define-foreign-type Name)` introduces an opaque handle type.
`Name` is a first-class type name exactly like a `define-type`
head: it provides, requires, qualifies (`M.Regex`), mangles, and
demangles-in-diagnostics through the module system unchanged
(docs/MODULES.md), and annotations may use it anywhere, not just in
`foreign` forms.

### 1.4 A foreign name is an ordinary binding

After desugar an import *is* a top-level function: `procedure?`
answers `#t`, it eta-passes as a value, it provides and renames, a
`.pufs` signature can ascribe it, and a typed `.pufi` exports it at
its declared type — clients cannot tell (and must not be able to
tell) whether `regex-compile` is Puffin or C behind the interface.

### 1.5 The declared type enters the checker untrusted

Prelude signatures are trusted and insert no casts; manifest prim
types are trusted the same way. A `foreign` declaration is the
opposite trust class — the *only* thing known about the far side is
what the declaration claims — so the boundary checks it induces are
**never erased, even in fully typed code**. A wrong value across
this boundary is not a wrong answer; it is a corrupted heap. The
FFI is where gradual typing's "casts at the boundary" stops being a
metaphor, and the cost (a few compares per call, next to a C call)
is the cheapest insurance in the language.

## 2. The marshallable universe, type by type

The crossable types are chosen so every conversion is a handful of
instructions, none can silently lose information, and **every
C-side type is integer-class in the calling convention** — the
property that lets one generic caller serve every route without
libffi (see the mechanism section):

| Puffin type | C type | out (Puffin → C) | in (C → Puffin) |
|---|---|---|---|
| `Int` | `int64_t` | cast-check `Int`, then `>> 3` | 61-bit range check, then `<< 3` |
| `I8 I16 I32 I64 U8 U16 U32 U64` | the matching C int | as `Int` + checked range for the width | mask/sign-extend per width, then `<< 3` (checked for `U64` > 2^60) |
| `Bool` | `bool` / `int` | cast-check `Bool`, then 0/1 | nonzero (low 32 bits) → `#t` |
| `Str` | `const char *` | cast-check `Str`, embedded-NUL check, borrow payload pointer | NULL check, copy into a fresh Puffin string (`#:gift`: then free the original) |
| `Void` (result only) | `void` | — | void |
| foreign type `T` | `T *` (opaque) | kind+brand+open check, unwrap | NULL check, wrap in a branded handle |
| `(Nullable τ)` (result only; τ = `Str` or a foreign type) | as τ | — | NULL → `#f`, else as τ |

### 2.1 Int and the width spellings

Fixnums are `n << 3`, 61 bits signed. Inbound (C → Puffin): the
returned `int64_t` must survive `<< 3` — the check is
`(r >> 60) ∈ {0, -1}` (sign-uniform top four bits), and a violation
is a fatal cast error naming the import. **No silent wrapping,
ever**: a C function returning `INT64_MAX` is a loud error, not a
negative number.

The width spellings exist because real C headers are full of `int`,
and the ABI makes ignoring that unsafe in one specific direction: a
callee *returning* `int32_t` leaves the register's high bits
unspecified, so reading it as `int64_t` retags garbage. To the
**type checker** every width spelling *is* `Int` — they are
FFI-declaration-only aliases, not new types, so they never appear
in the type grammar of docs/TYPES.md — but to the **marshaler**
they select the conversion: outbound values range-check against the
width (error on overflow — the FFI refuses to be a source of
integer-truncation bugs); inbound values mask and sign-/zero-extend
per the width before the fixnum retag. `U64`/`size_t` returns above
2^60 are errors, stated here so nobody is surprised in year two.

### 2.2 Bool

Outbound requires an actual boolean (cast-check `Bool` — truthiness
stops at this border; passing `0` where C expects a flag is almost
always a bug, and `(if x #t #f)` is cheap). Inbound, any nonzero
value in the low 32 bits is `#t`, matching both the C `int` idiom
and the AAPCS64/SysV `_Bool` return convention.

### 2.3 Str: borrow out, copy in

Two runtime facts make the cheap thing also the safe thing: Puffin
strings are **NUL-terminated by layout**, and Boehm is
**non-moving** and scans the C stack, so a pointer into a live
object's payload stays valid while the frame holding the tagged
reference is live.

- **Outbound `Str` is a borrowed `const char *`** — the payload
  pointer, zero copies, valid *for the duration of the call only*.
  A callee that stashes it is governed by the GC-discipline
  section; a callee that mutates it is UB on both sides. One
  checked hazard: Puffin strings are byte strings and may contain
  embedded NULs, which would silently truncate meaning on the C
  side — the marshaler checks `strlen(p) == length` and errors
  otherwise. The check is unconditional, O(n), and
  branch-predictable; it converts a silent data bug into a loud
  one, which is this FFI's personality in one line. (Byte strings
  also answer "where is the `bytes` type": `Str` *is* Puffin's
  bytes; a distinct `uint8_t*`+length crossing is an unbuilt seam.)
- **Inbound `Str` is always a copy** of the NUL-terminated result.
  Borrowing inbound is unsound (unknown lifetime) and
  transfer-by-default is a leak factory. When the callee transfers
  ownership (a malloc'd result — `asprintf`, Rust's
  `CString::into_raw`), declare `#:gift "free_fn"`: the runtime
  copies, then immediately calls the named deallocator on the
  original. Copy-then-free at the boundary means Puffin never holds
  foreign string memory and the foreign allocator never sees Puffin
  memory — the allocator-mismatch bug class is structurally
  impossible.
- `NULL` inbound: a result type of `Str` treats NULL as a blamed
  runtime error; `(Nullable Str)` maps NULL to `#f`, the Puffin
  idiom for "no answer" (`string->number` already returns it). C's
  billion-dollar mistake stays quarantined in the marshaler.

### 2.4 `(Nullable τ)`, precisely

`Nullable` is admitted **only as a foreign result type**, for `Str`
and foreign handle types. It is not in the type grammar: the
checker treats a `(Nullable τ)` result as `_` — documented and
deliberate, the honest gradual answer to "τ or `#f`" in a language
without unions. Untyped-style callers write `(if r ...)` and it
just works; typed callers who want precision can wrap the import in
a two-line Puffin function returning a real `(Option τ)` ADT, which
costs an allocation and reads well. What `Nullable` buys over
declaring `_`: the *marshaling* is still fully τ-directed — a
brand-wrapped handle or a copied string, never a raw word.

### 2.5 No Float, by design

Puffin has no flonums, and the FFI does not smuggle them in: a
`Float` that exists only at the boundary would need representation,
printing, `equal?`, and arithmetic decisions that are *language*
decisions, made once for all routes — not decisions an FFI makes as
a side effect. There is also a mechanism reason: floats pass in
vector registers, which breaks the integer-class generic caller and
would demand per-shape call thunks or libffi. So the rule is: **the
marshallable universe is exactly the representable universe.** The
seam is clean — if the language grows `Float`, the FFI adds a
`Float` row to the table above and a float-bearing caller variant,
and nothing else changes.

### 2.6 Not marshallable

`_` and type variables (declare a real type or don't declare the
import); function types (Puffin closures do not cross — see "What
stays out"); containers (`List`/`Vec`/`Hash`/`Set` — convert at the
Puffin level); structs, unions, arrays by value (write a five-line
C shim with accessor functions and declare those — shims are not a
failure of the FFI, they are the FFI working as designed, and the
C++ section makes the same move mandatory); variadic C functions
(`printf` — shim it). A non-marshallable declared type is a
compile-time error.

## 3. Boundary soundness: casts, blame, and the safety posture

### 3.1 What is checked, where

Every crossing is guarded; the guards are the type system's own:

- **Statically**: a foreign name enters the type environment at its
  declared type, so the bidirectional checker checks every call
  site's arguments (concrete-vs-concrete inconsistencies are
  compile-time errors; `_`-typed arguments flow in consistently, as
  everywhere). Arity is part of the arrow, so wrong-arity calls die
  at compile time even from untyped code (the derived function has
  fixed arity).
- **At compile time, per declaration**: the declared type must be a
  concrete arrow over marshallable types, arity ≤ 6, `#:consumes`
  must name exactly one handle-typed argument, `#:gift` requires a
  `Str` or `(Nullable Str)` result, a name with no default C
  spelling requires `#:c-name`, and duplicate declarations are
  rejected. Each violation is an exact-text typecheck error:

  ```
  error: typecheck: foreign f: arity 7 exceeds the FFI limit of 6 [prog.puf:2]
  error: typecheck: foreign f: argument type (List Int) is not marshallable [prog.puf:2]
  error: typecheck: foreign f: #:consumes requires exactly one foreign-handle argument [prog.puf:2]
  ```

- **Dynamically, outbound** (Puffin → C): each argument is checked
  against its declared type with the existing first-order machinery
  — the same checks `pf_cast_check` performs for an annotated
  formal, with an FFI blame label — then converted. This is the
  transient cast that docs/TYPES.md inserts at declared boundaries,
  relocated to the one boundary where it may never be erased.
- **Dynamically, inbound** (C → Puffin): the result is
  *constructed* per the declared type — range-checked retag,
  NULL-checked copy, branded wrap. There is no tag to check on a
  raw C value; construction is the check.
- **At load time**: the library must be loadable and every symbol
  (including `#:gift` deallocators) resolvable.

### 3.2 Blame

Failures speak the existing cast grammar with the import as the
blame party — byte-identical across the reference interpreter, both
native backends, the native bytecode VM, and the wasm VM, because
they are produced by the same `lib/foreign.c` code (or its ref-impl
re-implementation, which the golden runner holds equal). The
bracketed suffix is the declaration's source position:

```
puffin runtime error: cast: expected Int, got oops (blame: foreign c-abs's argument 1 [grep.puf:2])
puffin runtime error: cast: expected Int (61-bit), got 9223372036854775807 (blame: foreign demo-big's result [demo.puf:3])
puffin runtime error: cast: expected Regex, got 7 (blame: foreign regex-match?'s argument 1 [grep.puf:4])
puffin runtime error: foreign regex-match?: Regex handle is closed (blame: foreign regex-match?'s argument 1 [grep.puf:4])
puffin runtime error: foreign c-strlen: argument 1 contains an embedded NUL (blame: foreign c-strlen's argument 1 [grep.puf:3])
puffin runtime error: foreign demo-greet: result is NULL (blame: foreign demo-greet's result [demo.puf:5])
```

Width-spelled arguments blame with the width's name (`cast:
expected I8, got 300`). Arguments are blamed by position — C
arguments are positional; declarations have no formal names. The
import name renders in source spelling via the standing demangle
table, like every cast blame label. Wadler–Findler discipline,
boundary-shaped: if blame lands on an *argument*, the caller (or
the caller's missing annotation) is at fault; if on a *result* or a
load, the declaration (or the library) is. The foreign side cannot
be made to carry blame labels — naming the declaration is precisely
as actionable as an FFI error can be.

### 3.3 Load-time errors and the browser refusal

`dlerror()` strings vary by platform and would poison goldens, so
they are not part of the message; on native they go to stderr as a
best-effort follow-on diagnostic line:

```
puffin runtime error: foreign library vendor/libpfregex.dylib: cannot load
puffin runtime error: foreign regex-compile: symbol pfregex_compile not found in vendor/libpfregex.dylib
error: foreign library vendor/libpfregex.dylib is not available in the browser
```

The third fires on the wasm VM at registration time — **a program
that declares a foreign library fails at load in the browser**,
before any user code observes a half-initialized module. Declaring
is asserting loadability; the browser cannot load; the refusal is
immediate, stable, and held as a golden (web/test-vm-compile.mjs).
puffincc running *in* the browser still compiles and typechecks
programs containing `foreign` forms — compilation registers
nothing. Fail-at-load rather than fail-at-first-call is deliberate:
one resolution semantics on every route beats browser-special
laziness, and "optional native accelerator" modules would want a
designed feature (conditional requires), not a quiet divergence.

### 3.4 The posture, stated plainly

What the FFI **cannot** protect against — and no FFI can, short of
CHERI hardware or full sandboxing: **a lying declaration is
undefined behavior.** Declare `(-> Int Int)` for a function that
takes a pointer, and the callee will dereference the integer; no
check on this side of the call instruction survives the far side
being wrong about itself. Likewise foreign code that writes out of
bounds, frees Puffin memory, keeps a borrowed pointer past the
call, or unwinds an exception/panic through the boundary (the
guests section) — the runtime shares an address space with the
library, full stop.

What **is** guaranteed, given truthful declarations: every value
crossing out has the declared shape or the program halts with
blame; every value crossing in becomes a well-formed tagged word or
the program halts with blame; no integer is silently truncated or
wrapped in either direction; foreign pointers cannot be forged,
double-closed, or used after close from the Puffin side; the two
allocators never free each other's memory when the ownership
clauses are declared (`#:gift`, `#:consumes`). The design goal in
one sentence: **the boundary can be wrong only in ways the
declaration was wrong, and every other failure is loud, immediate,
and names its import.**

## 4. Foreign handles: the unforgeable kind

### 4.1 Representation

Every non-base C type crosses as an opaque handle: a dedicated heap
kind (`PF_KIND_FOREIGN`, kind 19) whose payload is the raw pointer,
a brand, and a flags word (bit 0: closed).

- **Branded.** The brand is the interned symbol of the (mangled)
  `define-foreign-type` name — mangled because runtime identities
  are mangled identities, as with ADT tags; diagnostics render the
  source spelling through the demangle table. Unwrap checks kind
  *and* brand: passing a `Regex` where a `Sqlite` is declared is a
  blamed cast error naming the expected type, not a segfault three
  frames later.
- **Unforgeable.** Only the inbound marshaler constructs kind 19;
  no surface or internal prim builds one from an `Int`, ever — the
  same discipline that makes ADT constructor instances impossible
  to counterfeit with a vector. This is the CHERI idea at language
  scale: pointer authority flows only from having been *given* the
  pointer.
- Handles print as `#<Regex 0x104a3c200>` (or `#<Regex closed>`);
  `equal?` is identity; `foreign-ptr?` is the disjoint surface
  predicate (`vector?`, `adt?`, `procedure?` all answer `#f`).
- **Typed.** `define-foreign-type` registers the name with the
  checker as an opaque nullary type — mechanically the same path
  typed `.pufi` imports use for extern types. The cast machinery
  has a desc form for kind 19 + brand, so `(ann v Regex)` and
  annotated formals of handle type work everywhere, not just at
  `foreign` call sites.

### 4.2 Lifecycle: `#:consumes` closes, leaks warn at exit

A `#:consumes` import is the type-directed close: the marshaler
unwraps the handle, calls the C function, then **nulls the stored
pointer and sets the closed bit**. Any later crossing of that
handle is `Regex handle is closed` with blame; a second close is
the same error, not a double free. Use-after-free and double-free
are thus unrepresentable from the Puffin side — and this
null-on-close discipline is exactly the at-most-once guarantee that
makes the C side's `free`/`Box::from_raw` sound (the Rust section).
The two disciplines interlock; neither suffices alone.

**Explicit close is the resource discipline; the backstop is a leak
detector, not a finalizer.** The runtime records every handle it
constructs in a GC-visible table. At process exit, handles that are
still open *and* whose brand participates in a close discipline
(some import declares `#:consumes` for that type) are reported to
stderr:

```
puffin ffi warning: 1 foreign handle left open at exit: #<Z3Context>
```

Up to eight leaked handles are named, in creation order; brands
with no declared close never warn (there is nothing the user could
have called). This is deliberately a warning, not a
silently-collecting finalizer: scarce resources (fds, connections,
long-lived contexts) want explicit close regardless, a resource
behavior that differs by route is worse than one that is explicit
everywhere (the wasm VM's collector has no finalization — and never
constructs a handle), and a warning doubles as a leak detector,
which matches the FFI's loud-over-silent personality. The tracking
table holds 4096 handles; past that the report states that its
count is a floor.

## 5. GC discipline: what Boehm buys, and the rules that remain

**What conservative non-moving collection buys.** Boehm scans
thread stacks, registers, and static data, and objects never move.
So: a value in the caller's frame stays alive across any foreign
call — no handle tables, no `PROTECT`/`UNPROTECT` ceremony for
call-duration references; borrowed interior pointers (outbound
`Str`) stay valid for the call; a tagged value stored in a foreign
*global* is found by the static-data scan. The native bytecode VM
links the same runtime, so all of this holds on the bytecode route
too; the wasm VM never reaches foreign code, so its collector needs
no story here.

**The sharp edge: foreign *heap* memory is invisible.** Boehm does
not scan `malloc`'d memory — nor Rust's allocator. A tagged value
stored into a malloc'd struct is invisible; the object dies at the
next GC and the C side holds a dangling word. The rules:

1. **Don't store tagged Puffin values in foreign memory.** Store
   what they unwrap to. The FFI only ever passes unwrapped C
   values, so this rule is unbreakable-by-construction at the
   declared surface; it is stated for shim authors who take `pf_*`
   helpers into their own hands.
2. C authors who know Boehm and need rooted foreign-side storage
   have `GC_malloc_uncollectable`/`GC_add_roots`.
3. Foreign code allocating memory that will *contain* tagged
   values should use `pf_alloc_raw` (exported, GC-visible).

**The ownership table.** "Puffin/GC" means nobody calls free and
foreign code must never `free`/`delete`/`drop` it:

| Memory | Allocated by | Freed by | Foreign side may | Puffin side may |
|---|---|---|---|---|
| Puffin heap values | Puffin GC | Puffin GC | read borrowed ptrs during the call | everything |
| Borrowed `Str` argument | Puffin GC | Puffin GC | read during the call; never write/stash/free | — |
| C string returned as `Str` | foreign | foreign — unless `#:gift`, then the *runtime* frees via the named fn after copying | — | sees only the copy |
| Handle *wrapper* (kind 19) | Puffin GC | Puffin GC | nothing (never sees it) | pass freely |
| Handle *pointee* | foreign | foreign code, invoked by Puffin at most once: the `#:consumes` call | per its own API | must not touch the raw pointer |
| Buffers malloc'd by foreign code | foreign | foreign | — | sees only boundary copies |

One sentence, which is also the Rust rule: **each side frees only
what its own allocator allocated, and every ownership-transferring
call is declared (`#:gift`, `#:consumes`) so the runtime — not the
programmer — performs the transfer.**

## 6. Mechanism: a user-level manifest extension

This section is for contributors; users need none of it.

### 6.1 The lowering — no new call path, no backend changes

Puffin already had an FFI before this one: every prim call is a
direct call to a C symbol declared in the manifest. The `foreign`
form is that manifest opened to programs. `lib/foreign.c`
contributes a handful of internal manifest prims:

```
#%ffi-register : (rpath spath cname desc) -> Int
                 dlopen (cached per path) + dlsym; records
                 {fnptr, desc, blame}; returns the import's index
#%ffi-call0..6 : the generic type-directed caller
foreign-ptr?   : the surface predicate for kind 19
```

Module resolution parses `foreign`/`define-foreign-type` forms
(mangling declared names uniformly, as ever) and resolves the
library path, threading it as a second string in the resolved form
`(foreign spath rpath decl ...)` — `spath` as written (for
messages), `rpath` spelled cwd-relative so both compilers agree
byte-for-byte. The checker registers the declared types; desugar
lowers each import to ordinary code:

```scheme
;; (: regex-match? (-> Regex Str Bool) #:c-name "pfregex_is_match")
(define regex-match?
  (let ([i (#%ffi-register "vendor/libpfregex.dylib" spath
                           "pfregex_is_match" 'desc)])
    (lambda (h s) (#%ffi-call2 i h s))))
```

Everything downstream of desugar is vanilla: the `let` runs at
module top level in DAG order (= load-time resolution, falling out
of ordinary top-level evaluation semantics — including under
separate compilation, where it is simply part of the module's
init); the `lambda` is an ordinary top-level function
(`procedure?`, provide, eta, `.pufi` export at the declared type —
all free); the body is an ordinary prim call, so the native
backends, the bytecode backend, and the interpreters carry it with
zero changes. The desc is quoted data — the marshaling schedule
derived from the declared type at compile time, interpreted at run
time — and includes the import's source name and declaration
position, which is how blame labels get their spelling and their
`[file:line]` suffix.

Two honest costs of this lowering: each call pays a
desc-interpretation loop (a switch per argument) on top of the C
call — FFI calls are boundary crossings, not inner loops, and the
checks dominate the interpretation anyway; and the import index is
a runtime value threaded through a closure rather than a
compile-time immediate — which is exactly what makes the same
lowering correct under whole-program, separate-compilation, REPL,
and VM-session builds without four registration stories. A backend
that recognizes `#%ffi-call` with a constant desc may inline the
marshaling; none currently does.

### 6.2 The generic caller: ≤6 integer-class args need no libffi

`#%ffi-calln` checks and converts each argument per the desc into
an `int64_t[6]`, makes the call, and constructs the result per the
desc. The call itself is the classic trick the ABI makes sound: on
both SysV x86-64 and AAPCS64/Apple arm64, any function whose
parameters and result are all integer-class and ≤ 6 passes
everything in integer registers, so calling through
`int64_t (*)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t)`
with trailing arguments ignored is correct for every declarable
signature (a callee of smaller width reads its register's low bits;
width-directed masking on our side handles returns). One switch on
argc, seven function-pointer casts, no libffi, no generated thunks,
no dependency. This is the load-bearing reason the marshallable
universe is integer-class only — the restriction is not a
limitation that happens to be convenient; it is the mechanism.

One calling-convention note: `#%ffi-call6` takes its six arguments
**packed in a vector** — the import index occupies one of the six
prim argument registers (x86-64 has exactly six), so the unpacked
ceiling for imports rides at five-plus-index. Same semantics,
different plumbing for the arity-6 case only.

### 6.3 Route by route

- **Native backends** (puffincc's arm64/x86-64, and the hosted
  Racket compiler kept as the optional consistency oracle): the
  front-end lowering, `lib/foreign.c`, and the manifest entries are
  the whole story; `diff-ir` holds the two compilers' lowerings
  equal.
- **Native bytecode VM** (`bin/puffin-vm`): the .pbc format is
  untouched — registration and calls are ordinary compiled
  top-level code invoking manifest prims. The VM links libpuffin.a,
  so `dlopen` in `pf_ffi_register` just works.
- **Reference interpreter** (Racket, `src/ffi-ref.rkt`): the
  manifest entries carry ref-impls built on `ffi/unsafe`, with
  every check re-implemented — the checks are *semantics*, and the
  interpreter stays golden-equal. Racket's own load-failure
  exceptions are caught and re-raised in the exact load-error
  texts.
- **Wasm VM:** `pf_ffi_register`'s dlopen seam is
  `#ifdef __wasm__`-guarded — the same pattern as io.c's `system()`
  ("WASI-absent → documented refusal") — and fails at registration
  with the browser message. Declared foreign libraries fail at load
  in the browser, loudly and testably. The honest future seam,
  named but not built: the wasm component model's typed imports are
  the same shape as a `foreign` form (declared signatures,
  generated lift/lower), so a browser-side registry mapping
  declared imports to component instances would change
  `pf_ffi_register`'s wasm branch and nothing above it. Until
  someone needs it, a clean refusal teaches the boundary better
  than an emulation would.
- **REPL:** native VM sessions register imports like any top-level
  code (dlopen'd libraries persist for the session); the browser
  REPL refuses per the above. A firing FFI cast aborts the eval and
  the session survives, like every cast.

### 6.4 Testing

- The golden corpus (309 checks, byte-identical on every route) is
  untouched by the FFI — it adds manifest entries only.
- `tests/ffi-demo/`: `cdemo/` — a small C library exercising every
  row of the type table *and every error path* (embedded NUL,
  out-of-range return, NULL constructor, brand mismatch,
  use-after-close, double close); `pfregex/` — the Rust regex crate
  bound per the Rust section; a Makefile building the dylibs.
  Golden programs per feature run on the interpreter, both native
  backends, and the native VM; the wasm leg asserts the
  load-refusal text — the refusals are goldens too.
- `src/test-ffi.rkt`: every load-time rejection and blame message,
  exact-text, on every route that can produce it, plus the leak
  warning and the header cross-check.
- The differential error corpus has FFI rows
  (`src/errors-corpus/{tc,rt}-ffi-*`, run by
  `tools/test-errors.sh`) pinning compile-time and runtime message
  texts across implementations.
- `tools/test-examples.sh` holds the goldens for `examples/ffi/`
  and `examples/z3/` on both self-hosted routes.

## 7. The `#:include` header cross-check

A declaration can lie (see the posture section), so the FFI offers
an opt-in way to have the C toolchain audit it:

```scheme
(foreign "vendor/libpfregex.dylib" #:include "vendor/pfregex.h"
  (: regex-compile (-> Str (Nullable Regex)) #:c-name "pfregex_compile")
  ...)
```

Desugar redeclares every import with the C prototype the Puffin
declaration implies (`Int` → `int64_t`, `Str` → `const char *`, a
gifted `Str` → `char *`, a handle → an opaque `Name *`, widths →
the matching `stdint.h` type) and runs `clang -fsyntax-only` over
the library's own header followed by those redeclarations.
Conflicting redeclarations are hard errors in C, so a declared type
that disagrees with the header fails the compile and the build
stops:

```
desugar: foreign: header cross-check failed for vendor/libpfregex.dylib against vendor/pfregex.h
```

The check is opt-in because it requires clang at build time and a
header that matches the library; when both are available it turns
"the declaration was wrong" — the one hazard the runtime cannot
check — into a compile-time error. Rust crates can generate the
header with `cbindgen --lang c`.

## 8. Guests: C++, and Rust as the first-class one

From Puffin's side a guest language is invisible — only the C ABI
crosses — so this section is discipline for the *library's* author,
not new mechanism.

### 8.1 C++: `extern "C"` shims, exceptions stop at the border

Only `extern "C"` symbols are declarable; mangled names, overloads,
templates, and member functions get a shim (`extern "C"` functions
over an opaque `Widget*`). **No C++ exception may cross into a
Puffin frame** — generated Puffin code has no unwind tables, so a
`throw` unwinding through it is UB of the worst kind; every shim
export wraps its body in `try { } catch (...)` and converts to the
C-idiom error the declaration expects (NULL → `(Nullable T)`,
sentinel int). RAII and the STL live happily *inside* the shim;
`new`/`delete` stay on the C++ side of the ownership table
(`#:consumes` points at the shim's `pfw_free`, never at `free`). A
C++ shim dylib carries its own `-lc++` linkage — a dylib's
dependencies are its own business, which is one quiet advantage of
the dlopen design: there is no `#:link` flag passthrough in Puffin
source at all.

### 8.2 Rust: the ownership disciplines interlock

A `cdylib` crate (`crate-type = ["cdylib"]`) with
`#[unsafe(no_mangle)] pub extern "C"` exports is indistinguishable
from a C library, and every rule above applies verbatim. Rust adds
memory safety *inside* the library and crates.io as Puffin's
borrowed ecosystem. The discipline:

- Only C types cross: raw pointers, fixed-width ints, `bool` —
  never `String`, `&str`, `Vec`, slices, trait objects, `Result`
  (not ABI-stable; Rust's own FFI law, not ours).
- Handles: born `Box::into_raw(Box::new(v))`, die
  `drop(Box::from_raw(p))` in exactly one export — the `#:consumes`
  target. Puffin's null-on-close guarantees that export runs at
  most once, which is precisely the contract `Box::from_raw`
  demands.
- Strings out: `CString::into_raw` paired with an exported
  `..._str_free`, declared as the `#:gift` function. **Never**
  `#:gift "free"` for a Rust string — Rust's allocator is not
  libc's, and freeing across allocators is heap corruption (the
  single most common Rust-FFI bug in the wild; `#:gift` makes the
  correct pairing a declaration, not a call-site habit).
- Strings in arrive as borrowed `*const c_char`:
  `CStr::from_ptr(p).to_str()` validates UTF-8, which Puffin byte
  strings do not promise — return the declared error idiom on
  invalid UTF-8 or use byte APIs; `to_owned` anything retained past
  the call (the borrow dies with the call).
- **Panics must not cross**: since Rust 1.81 a panic hitting an
  `extern "C"` boundary aborts the process — safe but blunt.
  Recommended default: `panic = "abort"` in the release profile
  (honest, tiny, matches the runtime's fatal-error philosophy).
  Long-running-process libraries: `catch_unwind` at every export,
  converting to the declared error idiom.
- **Boehm cannot see Rust's heap** — but declared exports only ever
  receive unwrapped C values, so there is nothing taggable to
  stash.

### 8.3 Build orchestration

puffincc does not run cargo or make. `foreign` names a `.dylib`
path; producing it is the library's Makefile's business
(`cargo build --release` → `target/release/libpfregex.dylib` with
`crate-type = ["cdylib"]`). Target triples must agree
(`aarch64-apple-darwin` for the native routes); a mismatch is a
clean dlopen failure at load, not a runtime surprise.

## 9. Examples

- **`examples/ffi/hello-libc.puf`** — the no-build-step starter:
  binds `labs`, `strlen`, `toupper`, `isdigit`, and `getenv` from
  `libSystem.B.dylib` (already loaded; dlopen just hands back its
  symbols), demonstrates `(Nullable Str)` for `getenv`, and passes
  a foreign name to `map` like any function.
- **`examples/z3/`** — the Z3 SMT solver bound as a Puffin API.
  `z3.puf` is the whole binding: two `define-foreign-type` handles
  (`Z3Config`, `Z3Context`), four lifecycle imports (the `del-`
  pair declared `#:consumes`), and `Z3_eval_smtlib2_string` as the
  workhorse —
  queries go out as SMT-LIB text and answers come back as
  s-expressions, so both directions are just Puffin data. On top of
  it, `sudoku.puf` is a constraint-solving showcase (solve a
  puzzle, then prove its solution unique). Requires
  `brew install z3`.
- **`tests/ffi-demo/`** — the test-facing examples: `cdemo/` (a C
  library covering every type-table row and error path) and
  `pfregex/` (the Rust regex crate behind the Puffin face shown in
  the surface-language section).
- The playground tutorial has a hands-on walk-through in its
  "Calling C (the FFI)" section (`web/public/tutorial.html`) —
  including what the browser refusal looks like.

The regex face from the surface-language section runs as:

```
build/puffincc grep.puf -o grep && ./grep
```

No linker flags, no archives; the dylib resolves at load relative
to the module.

## 10. What stays out

Each exclusion is a designed boundary with a named seam; none
requires revisiting the surface or marshaling contracts above.

- **Float** — excluded until the language has flonums; the FFI
  refuses to force a numeric representation as a side effect (the
  marshallable-universe section). The seam: one table row and a
  float-bearing caller variant.
- **Callbacks** (Puffin closures as C function pointers) —
  excluded, and their absence is what keeps the "transient checking
  is complete" property of the boundary true. The designed sketch,
  kept so the seams stay honest: `(callback (-> τ ... τ))` argument
  types; a `pf_call_closure(clo, argc, argv)` runtime entry (the
  one place the FFI would need target-specific code); trampolines
  passing the pinned closure as `void *user_data`; a
  `pf_gc_pin`/`pf_gc_unpin` API shipping alongside (the first
  legitimate need for one); callbacks legal only on the calling
  thread during the call; foreign-spawned threads out until Puffin
  has threads. On the bytecode routes, `pf_call_closure` must call
  back into the VM dispatch loop — a re-entrancy seam that needs
  its own verification gate if this is ever built.
- **Deep struct/union/array marshaling** — write a C shim with
  accessor functions; shims are the FFI working as designed.
- **Container borrows** (`(Vec Int)` → `int64_t*`) — plausible
  someday, with the transient-checking caveat priced in; convert at
  the Puffin level for now.
- **Varargs** — shim them.
- **Static linking** of foreign code (single-binary distribution):
  `#:static` is recognized and errors with a pointer to this
  section — a designed seam, not yet implemented.
- **Arity > 6** — the packed-call convention could carry it;
  a compile-time error until a real need shows up.
- **Foreign threads calling anything**; C++ beyond `extern "C"`
  shims; any cargo/cmake orchestration; libffi (structurally
  unnecessary — the generic-caller section); wasm component
  imports (the shape is named in the route-by-route section).
