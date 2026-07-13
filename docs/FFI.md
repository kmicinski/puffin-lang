# The Puffin FFI: foreign imports are typed boundaries

> **Status:** DESIGN, second edition (2026-07-13). This document
> REPLACES the 2026-07-07 FFI design in full (the old text is in git
> history at `7337b2e^:docs/FFI.md`). It is rewritten rather than
> patched because the ground it stood on moved twice: the **gradual
> type system shipped** (docs/TYPES.md — transient casts with blame,
> `pf_cast_check`, the dedicated ADT heap kind, manifest `#:type`,
> typed `.pufs`/`.pufi`), so the FFI no longer needs to invent its
> own checking machinery — it *reuses* the boundary-cast machinery
> the language already has; and the **browser consolidation
> happened** (docs/WASM-VM.md — the JS interpreter is deleted, the
> playground runs puffincc.pbc on the wasm bytecode VM), so "the web
> route" now means the VM, and the VM — not just the native backends
> — must be a first-class FFI citizen. Nothing here is implemented;
> §12 is the plan.

Design goals, in order: (1) **type-directed by construction** — a
foreign import is a typed declaration, and the declared type
*generates* the marshaling; there is no way to write an unmarshaled
or hand-marshaled call; (2) **gradual soundness at the boundary** —
values crossing the boundary are checked by the same transient cast
machinery that guards `_`→concrete boundaries today, with blame
labels naming the foreign import, byte-identical on every route;
(3) **the FFI is the manifest, user-extended** — a `foreign`
declaration behaves like a locally declared prim and rides the
existing prim-call machinery end to end; the runtime grows one
`lib/` module and a handful of manifest entries, the backends grow
nothing; (4) **honest about the browser** — the wasm VM has no
`dlopen` and we say so at load time rather than emulating.

## 1. What changed since the first design, and what survives

The 2026-07-07 design predated the type system. Its core insight —
*Puffin already has an FFI: every prim call is a direct call to a C
symbol declared in the manifest* — survives and is still the
foundation (§8). Three of its premises do not survive:

1. **It invented its own dynamic checks.** Per-declaration assembly
   stubs did ad-hoc tag tests with their own error style. Today the
   language has `pf_cast_check` (lib/cast.c): first-order shape
   checks, ADT constructor-set membership, blame labels, one message
   format proven byte-identical across interp / native / VM / wasm.
   The FFI boundary is now *literally* a set of casts — same descs,
   same blame grammar, same fatal-error contract (§5).
2. **It linked statically and only natively.** Archives resolved at
   link time meant the mechanism existed only on the two native
   backends; the interpreter needed a parallel `#:shared` story and
   the web story was "the JS interpreter refuses". The JS
   interpreter no longer exists. The new mechanism — `dlopen` at
   load time driven by a registered import table — is ONE semantics
   shared by the native backends, the native bytecode VM, and the
   reference interpreter, with the wasm VM refusing cleanly (§8).
   Static linking is demoted to a v2 optimization seam.
3. **It needed per-declaration generated assembly.** With the
   type-directed generic caller of §8.2, the compilers emit *no new
   instruction shapes at all*: a foreign declaration lowers in
   desugar to ordinary definitions whose bodies call manifest prims.
   Both backends, the bytecode backend, and the VM are untouched by
   construction.

What survives beyond the core insight: the GC/ownership discipline
(§7, condensed from the old §4 — it was correct and remains so), the
C++ shim rules and the Rust guest story (§9), and most of the old
open questions, several of which this edition answers (§13).

## 2. The design in one paragraph, and the art it stands on

A foreign import is written as a *type declaration inside a
`foreign` form* (§3). The declared type is the whole interface: the
checker registers it (so call sites typecheck statically, gradually,
like any `(: name τ)`), and the runtime derives from it — per
argument and result — the tagged-word ↔ C-ABI conversion, the
transient shape check with blame, the 61-bit range check on returns,
and the branded wrap/unwrap for opaque pointers. Values crossing
*out* of Puffin are checked against the declared argument types with
the existing `pf_cast_check`; values crossing *in* are constructed
(retagged, copied, or wrapped) so an ill-shaped C result is a loud
blamed error, never a corrupt heap word. Foreign pointers live in a
new unforgeable heap kind so they cannot be minted from `Int`s.
Failure anywhere names the import: `(blame: foreign regex-match?'s
argument 2)`.

The design is deliberately assembled from known-good parts:

- **The FFI is a language boundary** in the sense of Matthews &
  Findler's multi-language semantics (POPL 2007): our marshaling is
  their *natural embedding* for base types and their *lump
  embedding* for everything else (opaque handles). That paper is why
  §4's table has exactly two behaviors — convert or lump — and no
  third.
- **Boundary contracts with blame** come from Typed Racket
  (Tobin-Hochstadt & Felleisen: typed–untyped module boundaries
  compile to contracts whose blame labels name the boundary) and
  Wadler & Findler's "well-typed programs can't be blamed". Our
  labels name the foreign import, which is the only party a user can
  act on: fix the declaration, or fix the caller.
- **Transient (first-order) checking** is Vitousek et al.'s
  semantics from Reticulated Python — check the outermost shape at
  the boundary, don't traverse — which is what `pf_cast_check`
  already implements, sitting at the "shallow" point of Greenman &
  Felleisen's soundness spectrum. Here is the observation that makes
  the simple thing also the strong thing: **for the v1 marshallable
  universe, transient checking coincides with full natural-embedding
  soundness**, because every crossable type is either a base type
  (the shape *is* the type) or an opaque handle (identity *is* the
  type). There are no crossable containers or function types whose
  insides a shallow check would miss. First-order is not the
  compromise position at this boundary; it is complete. (It stops
  being complete the day callbacks or `(Vec Int)` borrows cross —
  §11 prices that in.)
- **Declared types generating the marshaling** is the wasm
  component model's canonical ABI (interface types → generated
  lift/lower), Racket's `ffi/unsafe` ctypes (Barzilay & Orlovsky),
  and Java Panama's jextract, all of which converged on: the human
  writes a signature, the machine writes the glue. Nobody hand-writes
  a conversion in this design because there is no place to put one.
- **Unforgeability by representation** is the CHERI instinct
  (capabilities you cannot conjure from integers) scaled to a
  language runtime: the ADT work proved a dedicated heap kind that
  only the runtime constructs is cheap and airtight — `(vector?
  (Some 1))` is `#f` and no user code can forge a constructor
  instance. Foreign pointers get the same treatment (§6).

## 3. Surface language

```scheme
;; regex.puf — a Puffin-face module for a foreign library
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

- **`(foreign lib-path decl ...)`** — a top-level module form, next
  to `require`/`provide`. `lib-path` containing a `/` resolves
  relative to the declaring module's file (like `require`); a bare
  name (`"libm.dylib"`) goes to the system loader's search. The
  library is loaded (`dlopen`) when the module's top level runs —
  **a missing library or symbol is a load-time error** (§5.3), on
  every route, because declaring a foreign library is asserting it
  is loadable. Repeatable; multiple `foreign` forms may name the
  same library.
- **Each `decl` is a `(: name τ)` declaration** — the same form the
  type system already owns — plus FFI clauses. `τ` must be a
  concrete `(-> τ ... τ)` over the marshallable types of §4: `_` is
  not marshallable, type variables are not marshallable, and an FFI
  declaration is the one place an annotation is mandatory (there is
  nothing to infer from; the far side is machine code). Arity ≤ 6
  in v1 (the prim-call convention's unpacked ceiling; §11).
  Clauses:
  - `#:c-name "sym"` — the linker symbol. Default: the Puffin name
    with `-` → `_` (`demo-add` → `demo_add`); names containing any
    other C-hostile character (`?`, `!`, `>`) have no default and
    require the clause. No cleverer renaming — magic is where FFI
    bugs breed.
  - `#:consumes` — the (single) handle-typed argument is *consumed*:
    after the call the handle is closed (§6.2).
  - `#:gift "free_sym"` — the `Str` result is malloc'd by the callee
    and ownership transfers: the runtime copies it into a Puffin
    string and immediately calls `free_sym` (resolved in the same
    library) on the original (§4.3).
- **`(define-foreign-type Name)`** — introduces an opaque handle
  type (§6). `Name` is a first-class type name exactly like a
  `define-type` head: it provides, requires, qualifies (`M.Regex`),
  mangles, and demangles-in-diagnostics through the module system
  unchanged (docs/MODULES.md §1.1), and annotations may use it
  anywhere, not just in `foreign` forms.

**A foreign name is an ordinary binding.** After desugar it *is* a
top-level function (§8.1): `procedure?` answers `#t`, it eta-passes
as a value, it provides and renames, a `.pufs` signature can ascribe
it, and a typed `.pufi` exports it at its declared type — clients
cannot tell (and must not be able to tell) whether `regex-compile`
is Puffin or C behind the interface.

**The declared type enters the checker untrusted.** Prelude
signatures (`#%prelude:`) are trusted and insert no casts; manifest
prim types are trusted the same way. A `foreign` declaration is the
opposite trust class — the *only* thing we know about the far side
is what the declaration claims — so the boundary checks it induces
are **never erased, even in fully typed code**. A wrong value across
this boundary is not a wrong answer; it is a corrupted heap. The FFI
is where gradual typing's "casts at the boundary" stops being a
metaphor, and the cost (a few compares per call, next to a C call)
is the cheapest insurance in the language.

## 4. The marshallable universe, type by type

The v1 types, chosen so every conversion is a handful of
instructions, none can silently lose information, and — a new
constraint the first design didn't have — **every C-side type is
integer-class in the calling convention**, which is what lets one
generic caller serve every route without libffi (§8.2):

| Puffin type | C type | out (Puffin → C) | in (C → Puffin) |
|---|---|---|---|
| `Int` | `int64_t` | cast-check `Int`, then `>> 3` | 61-bit range check, then `<< 3` |
| `I8 I16 I32 I64 U8 U16 U32 U64` | the matching C int | as `Int` + checked range for the width | mask/sign-extend per width, then `<< 3` (checked for `U64` > 2^60) |
| `Bool` | `bool` / `int` | cast-check `Bool`, then 0/1 | nonzero (low 32 bits) → `#t` |
| `Str` | `const char *` | cast-check `Str`, embedded-NUL check, borrow payload pointer (§4.3) | NULL check, copy into a fresh Puffin string (`#:gift`: then free the original) |
| `Void` (result only) | `void` | — | `PF_VOID` |
| foreign type `T` | `T *` (opaque) | kind+brand+open check, unwrap (§6) | NULL check, wrap in a branded handle |
| `(Nullable τ)` (result only; τ = `Str` or a foreign type) | as τ | — | NULL → `#f`, else as τ |

### 4.1 Int and the width spellings

Fixnums are `n << 3`, 61 bits signed. Inbound (C → Puffin): the
returned `int64_t` must survive `<< 3` — the check is
`(r >> 60) ∈ {0, -1}` (sign-uniform top four bits), and a violation
is a fatal cast error naming the import. **No silent wrapping,
ever**: a C function returning `INT64_MAX` is a loud error, not a
negative number (the spike in Appendix A demonstrates exactly this
firing). The width spellings exist because real C headers are full
of `int`, and the ABI makes ignoring that unsafe in one specific
direction: a callee *returning* `int32_t` leaves the register's high
bits unspecified, so reading it as `int64_t` retags garbage. To the
**type checker** every width spelling *is* `Int` — they are
FFI-declaration-only aliases, not new types, so they never leak into
the type grammar of docs/TYPES.md — but to the **marshaler** they
select the conversion: outbound values range-check against the
width (error on overflow — the FFI refuses to be a source of
integer-truncation bugs); inbound values mask and sign-/zero-extend
per the width before the fixnum check. `U64`/`size_t` returns above
2^60 are errors, stated here so nobody is surprised in year two.

### 4.2 Bool

Outbound requires an actual boolean (cast-check `Bool` — Racket
truthiness stops at this border; passing `0` where C expects a flag
is almost always a bug, and `(if x #t #f)` is cheap). Inbound, any
nonzero value in the low 32 bits is `#t`, matching both the C `int`
idiom and the AAPCS64/SysV `_Bool` return convention.

### 4.3 Str: borrow out, copy in

Two runtime facts make the cheap thing also the safe thing:
Puffin strings are **NUL-terminated by layout** (io.c's `cstr_of`
relies on this today), and Boehm is **non-moving** and scans the C
stack, so a pointer into a live object's payload stays valid while
the frame holding the tagged reference is live.

- **Outbound `Str` is a borrowed `const char *`** — the payload
  pointer, zero copies, valid *for the duration of the call only*.
  A callee that stashes it is governed by §7; a callee that mutates
  it is UB on both sides. One checked hazard: Puffin strings are
  byte strings and may contain embedded NULs, which would silently
  truncate meaning on the C side — the marshaler checks
  `strlen(p) == pf_len_of(v)` and errors otherwise. O(n) and
  branch-predictable; it converts a silent data bug into a loud one,
  which is this FFI's personality in one line. (Byte strings also
  answer "where is the `bytes` type": `Str` *is* Puffin's bytes; a
  distinct bytes/`uint8_t*`+length crossing is a v2 seam.)
- **Inbound `Str` is always a copy** (`pf_string_from_bytes` on the
  NUL-terminated result). Borrowing inbound is unsound (unknown
  lifetime) and transfer-by-default is a leak factory. When the
  callee transfers ownership (malloc'd result — `asprintf`, Rust's
  `CString::into_raw`), declare `#:gift "free_fn"`: copy, then
  immediately call the named deallocator on the original.
  Copy-then-free at the boundary means Puffin never holds foreign
  string memory and the foreign allocator never sees Puffin memory —
  the allocator-mismatch bug class is structurally impossible.
- `NULL` inbound: result type `Str` treats NULL as a blamed runtime
  error; `(Nullable Str)` maps NULL to `#f`, the Puffin idiom for
  "no answer" (`string->number` already returns it). C's
  billion-dollar mistake stays quarantined in the marshaler.

### 4.4 `(Nullable τ)`, precisely

`Nullable` is admitted **only as a foreign result type**, for `Str`
and foreign handle types. It is not in the type grammar: the checker
treats a `(Nullable τ)` result as `_` (documented, deliberate — the
honest gradual answer to "τ or `#f`" in a language without unions).
Untyped-style callers write `(if r ...)` and it just works; typed
callers who want precision should wrap the import in a two-line
Puffin function returning a real `(Option τ)` ADT — which costs an
allocation and reads beautifully, and which v2 may automate (§13
Q3). What `Nullable` buys over "just declare `_`": the *marshaling*
is still fully τ-directed (brand-wrapped handle or copied string,
never a raw word).

### 4.5 Floats: not forced, and why

Puffin has no flonums. The FFI does not smuggle them in: a `Float`
that exists only at the boundary would need representation,
printing, `equal?`, and arithmetic decisions that are *language*
decisions, made once for all four routes — not decisions an FFI doc
should make as a side effect. There is also a mechanism reason to
scope them out: floats pass in vector registers, which breaks the
integer-class generic caller (§8.2) and would demand per-shape call
thunks or libffi. So v1's rule is: **the marshallable universe is
exactly the representable universe.** The seam is clean — the week
the language grows `Float`, the FFI adds a `Float` row to §4's
table, a float-bearing caller variant, and nothing else changes.
(Recommended sequencing in §13 Q1.)

### 4.6 Not marshallable, v1

`_` and type variables (declare a real type or don't declare the
import); function types (Puffin closures cross only via the deferred
callback machinery, §11); containers (`List`/`Vec`/`Hash`/`Set` —
convert at the Puffin level; a `(Vec Int)` → `int64_t*` borrow is a
plausible v2 with the same transient caveat flagged in §2); structs,
unions, arrays by value (write a five-line C shim with accessor
functions and declare those — shims are not a failure of the FFI,
they are the FFI working as designed, and §9 makes the same move
mandatory for C++); variadic C functions (`printf` — shim it).

## 5. Boundary soundness: casts, blame, and the safety posture

### 5.1 What is checked, where

Every crossing is guarded; the guards are the type system's own:

- **Statically**: a foreign name enters the type environment at its
  declared type, so the bidirectional checker checks every call
  site's arguments (concrete-vs-concrete inconsistencies are
  compile-time errors; `_`-typed arguments flow in consistently, as
  everywhere). Arity is part of the arrow, so wrong-arity calls die
  at compile time even from untyped code (the derived function has
  fixed arity).
- **Dynamically, outbound** (Puffin → C): each argument is checked
  against its declared type with the existing first-order machinery
  — the same checks `pf_cast_check` performs for an annotated
  formal, with an FFI blame label — then converted. This is the
  transient cast that TYPES.md inserts at declared boundaries,
  relocated to the one boundary where it may never be erased.
- **Dynamically, inbound** (C → Puffin): the result is
  *constructed* per the declared type — range-checked retag,
  NULL-checked copy, branded wrap. There is no tag to check on a
  raw C value; construction is the check.
- **Load time**: library loadable, every symbol (including `#:gift`
  deallocators) resolvable, declaration well-formed (marshallable
  types only, arity ≤ 6, `#:consumes` names exactly one
  handle-typed argument). §12's negative test matrix pins each.

### 5.2 Blame

Failures speak the existing cast grammar with the import as the
blame party — byte-identical across interp, both native backends,
native VM, and wasm VM, because they are produced by the same
`lib/foreign.c` code (or its manifest ref-impl re-implementation,
which the golden runner holds equal):

```
puffin runtime error: cast: expected Int, got #t (blame: foreign regex-match?'s argument 2)
puffin runtime error: cast: expected Int (61-bit), got 9223372036854775807 (blame: foreign demo-big's result)
puffin runtime error: cast: expected Regex, got 7 (blame: foreign regex-match?'s argument 1)
puffin runtime error: foreign regex-match?: Regex handle is closed (blame: foreign regex-match?'s argument 1)
```

Arguments are blamed by position (C arguments are positional;
declarations have no formal names). The import name renders in
SOURCE spelling via the standing demangle table, like every cast
blame label today. Wadler–Findler discipline, boundary-shaped: if
blame lands on an *argument*, the caller (or the caller's missing
annotation) is at fault; if on a *result* or a load, the declaration
(or the library) is. The foreign side cannot be made to carry blame
labels — naming the declaration is precisely as actionable as an
FFI error can be.

### 5.3 Load-time errors, exact texts

`dlerror()` strings vary by platform and would poison goldens, so
they are not included in the message (they go to stderr as a
follow-on diagnostic line on native, best-effort):

```
puffin runtime error: foreign library vendor/libpfregex.dylib: cannot load
puffin runtime error: foreign regex-compile: symbol pfregex_compile not found in vendor/libpfregex.dylib
error: foreign library vendor/libpfregex.dylib is not available in the browser
```

The third fires on the wasm VM at registration time — i.e. **a
program that declares a foreign library fails at load in the
browser**, before any user code observes a half-initialized module.
Declaring is asserting loadability; the browser cannot load; the
refusal is immediate, stable, and a golden (§8.4). puffincc running
*in* the browser still compiles and typechecks programs containing
`foreign` forms — compilation registers nothing.

### 5.4 The posture, stated plainly

What the FFI **cannot** protect against — and no FFI can, short of
CHERI hardware or full sandboxing: **a lying declaration is
undefined behavior.** Declare `(-> Int Int)` for a function that
takes a pointer, and the callee will dereference your integer; no
check on our side of the call instruction survives the far side
being wrong about itself. Likewise foreign code that writes out of
bounds, frees Puffin memory, keeps a borrowed pointer past the call,
or unwinds an exception/panic through the boundary (§9) — the
runtime shares an address space with the library, full stop.

What **is** guaranteed, given truthful declarations: every value
crossing out has the declared shape or the program halts with blame;
every value crossing in becomes a well-formed tagged word or the
program halts with blame; no integer is silently truncated or
wrapped in either direction; foreign pointers cannot be forged,
double-closed, or used after close from the Puffin side (§6); the
two allocators never free each other's memory when the ownership
clauses are declared (`#:gift`, `#:consumes`). The design goal in
one sentence: **the boundary can be wrong only in ways the
declaration was wrong, and every other failure is loud, immediate,
and names its import.**

## 6. Foreign handles: the unforgeable kind

### 6.1 Representation

Every non-base C type crosses as an opaque handle: heap kind
**`PF_KIND_FOREIGN` = 19** (16/17 are the HAMTs, 18 the ADT kind —
the "one runtime module, one `pf_register_kind` call" precedent,
third use):

```c
// lib/foreign.c — handle payload
// | raw pointer | brand (interned symbol) | flags (bit 0: closed) |
```

- **Branded.** The brand is the interned symbol of the (mangled)
  `define-foreign-type` name — mangled because runtime identities
  are mangled identities (the ADT tag precedent); diagnostics render
  the source spelling through the demangle table. Unwrap checks kind
  *and* brand: passing a `Regex` where a `Sqlite` is declared is a
  blamed cast error naming the expected type, not a segfault three
  frames later.
- **Unforgeable.** Only the inbound marshaler constructs kind 19;
  no surface or internal prim builds one from an `Int`, ever. The
  ADT work proved this discipline airtight (a vector impostor
  cannot match a constructor pattern); handles inherit it. This is
  the CHERI idea at language scale: pointer authority flows only
  from having been *given* the pointer.
- Handles print as `#<Regex 0x104a3c200>`; `equal?` is identity
  (registered via the kind descriptor); `foreign-ptr?` is the
  disjoint surface predicate (`vector?`, `adt?`, `procedure?` all
  answer `#f`).
- **Typed.** `define-foreign-type` registers `Name` with the checker
  as an opaque nullary type — mechanically the `#%extern-type` path
  that typed `.pufi` imports already use (a define-type that defines
  no constructors). `pf_cast_check` grows one desc form
  (kind 19 + brand) so `(ann v Regex)` and annotated formals of
  handle type work everywhere, not just at `foreign` call sites.

### 6.2 Lifecycle: explicit close now, finalizers later

A `#:consumes` import is the type-directed close: the marshaler
unwraps the handle, calls the C function, then **nulls the stored
pointer and sets the closed bit**. Any later crossing of that handle
is `Regex handle is closed` with blame; a second close is the same
error, not a double free. Use-after-free and double-free are thus
unrepresentable from the Puffin side — and this null-on-close
discipline is exactly the at-most-once guarantee that makes the
C side's `free`/`Box::from_raw` sound (§9.2). The two disciplines
interlock; neither suffices alone.

**Finalizers are deferred, deliberately** (a change from the first
design, which specced a Boehm-finalizer backstop). Reasons, in
order: (a) the routes diverge — Boehm has
`GC_register_finalizer_no_order`, but the wasm VM's mark-sweep
collector (WASM-VM.md §3.3) has no finalization and growing it some
is real work for a backstop; a resource behavior that differs by
route is worse than one that is explicit everywhere; (b) finalizers
are a debugging comfort, not a resource discipline — scarce
resources (fds, connections, compiled regexes in a long-lived
process) want explicit close regardless, and every serious FFI's
documentation says so after learning it the hard way; (c) v1's
daily-driver reality is native, single-threaded, short-to-medium
processes, where "close it or exit" covers the need. The seam is
designed: the handle payload has room for a destructor slot, and a
v2 `#:destructor "c_name"` clause on `define-foreign-type` can add
the native-Boehm backstop (registered at wrap, cancelled at close)
without touching any v1 contract. §13 Q4 asks whether the backstop
should warn-to-stderr instead of silently collecting when it does
come — the Go `SetFinalizer` debugging trick.

## 7. GC discipline: what Boehm buys, and the rules that remain

Condensed from the first design (which got this right); normative.

**What conservative non-moving collection buys.** Boehm scans thread
stacks, registers, and static data, and objects never move. So: a
`pf` in the caller's frame keeps its object alive across any foreign
call — no handle tables, no `PROTECT`/`UNPROTECT` ceremony for
call-duration references; borrowed interior pointers (§4.3) stay
valid for the call; a `pf` stored in a foreign *global* is found by
the static-data scan. (The native VM links the same Boehm runtime,
so all of this holds on the bytecode route too. The wasm VM never
reaches foreign code, so its collector needs no story here.)

**The sharp edge: foreign *heap* memory is invisible.** Boehm does
not scan `malloc`'d memory — nor Rust's allocator. A `pf` stored
into a malloc'd struct is invisible; the object dies at the next GC
and the C side holds a dangling tagged word. The rules:

1. **Don't store `pf` values in foreign memory.** Store what they
   unwrap to. This covers *all* of v1's surface — v1 only ever
   passes unwrapped C values, so the rule is currently
   unbreakable-by-construction; it is stated for shim authors who
   take `pf_*` helpers into their own hands.
2. The pinning API (`pf_gc_pin`/`pf_gc_unpin`, a refcounted
   GC-visible pin table) ships **with callbacks** (§11), which are
   the first legitimate need. Until then, C authors who know Boehm
   have `GC_malloc_uncollectable`/`GC_add_roots`.
3. Foreign code allocating memory that will *contain* `pf` values
   should use `pf_alloc_raw` (already exported, GC-visible).

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

One sentence, which is also §9's Rust rule: **each side frees only
what its own allocator allocated, and every ownership-transferring
call is declared (`#:gift`, `#:consumes`) so the runtime — not the
programmer — performs the transfer.**

## 8. Mechanism: a user-level manifest extension

### 8.1 The lowering — no new call path, no backend changes

The first design's insight, restated with today's machinery: a prim
*is* a typed foreign import that happens to live in the manifest.
The FFI is the manifest opened to programs. Concretely, `lib/foreign.c`
contributes a handful of **internal manifest prims** (`surface? #f`,
appended like `cast-check` was):

```
#%ffi-register : (path cname desc) -> Int      dlopen (cached per path) + dlsym;
                                               records {fnptr, desc, blame};
                                               returns the import's index
#%ffi-call0..6 : (idx a1 ... an) -> result     the generic type-directed caller
#%ffi-wrap-type : (brand) -> Void              registers a foreign type's brand
foreign-ptr?   : (v) -> Bool                   surface predicate for kind 19
```

Module resolution parses `foreign`/`define-foreign-type` forms
(mangling the declared names uniformly, as ever); the checker
registers the declared types; **desugar lowers each import to
ordinary code**:

```scheme
;; (: regex-match? (-> Regex Str Bool) #:c-name "pfregex_is_match")
(define regex-match?
  (let ([i (#%ffi-register "vendor/libpfregex.dylib" "pfregex_is_match"
                           '#(desc (foreign Regex_regex_9ab) str -> bool))])
    (lambda (h s) (#%ffi-call2 i h s))))
```

Everything downstream of desugar is vanilla: the `let` runs at
module top level in DAG order (= load-time resolution, §5.3, falls
out of ordinary top-level evaluation semantics — including under
separate compilation, where it is simply part of the module's init);
the `lambda` is an ordinary top-level function (`procedure?`,
provide, eta, `.pufi` export at the declared type — all free); the
body is an ordinary prim call, so **both native backends, the
bytecode backend, and the interpreters need zero changes** — the
prim-call machinery (args in registers, ≤6-arg convention) carries
it. The desc is quoted data: the marshaling schedule derived from
the declared type at compile time, interpreted at run time
(cast-desc vocabulary extended with the width spellings, `str`
flags, `nullable`, `gift`, `consumes`, and the kind-19 brand form).
The blame string rides in the desc, built with source spelling at
desugar exactly as cast blame labels are today.

Two honest costs of this lowering, and why they are right for v1:
each call pays a desc-interpretation loop (a switch per argument)
on top of the C call — FFI calls are boundary crossings, not inner
loops, and the checks dominate the interpretation anyway; and the
import index is a runtime value threaded through a closure rather
than a compile-time immediate — which is exactly what makes the
same lowering correct under whole-program, separate-compilation,
REPL, and VM-session builds without four registration stories. The
rejected alternative — per-declaration open-coded assembly stubs
(the first design) — is faster per call and is the designated **-O1
seam**: a backend that recognizes `#%ffi-call` with a constant desc
may inline the marshaling like it fuses compares today. Not v1.

### 8.2 The generic caller, and why ≤6 integer-class args need no libffi

`#%ffi-calln` does: check+convert each argument per the desc (into
an `int64_t[6]`), make the call, construct the result per the desc.
The call itself is the classic trick the ABI makes sound: on both
SysV x86-64 and AAPCS64/Apple arm64, **any function whose parameters
and result are all integer-class and ≤ 6 passes everything in
integer registers**, so calling through
`int64_t (*)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t)`
with trailing arguments ignored is correct for every v1-declarable
signature (a callee of smaller width reads its register's low bits;
width-directed masking on our side handles returns, §4.1). One
switch on argc, seven function-pointer casts, no libffi, no
generated thunks, no dependency. This is the load-bearing reason §4
scopes v1 to integer-class types — the restriction is not a
limitation that happens to be convenient; it is the mechanism.
Appendix A's spike is this caller in miniature, run against a real
dylib and the real tag scheme, including the range check firing.

### 8.3 Route by route

- **Native backends (hosted src/ and puffincc):** as above —
  nothing to do beyond the front-end lowering, `lib/foreign.c`, and
  the manifest entries (regenerate `gen-puffincc-tables.rkt` output;
  the standing lockstep chore). Both compilers emit the same
  lowering from the same declaration; `diff-ir` stays the oracle.
- **Native bytecode VM (`bin/puffin-vm`):** the .pbc format is
  untouched — registration and calls are ordinary compiled
  top-level code invoking manifest prims, and `vm-prims.inc`
  regenerates from the manifest as always. The VM links
  libpuffin.a, so `dlopen` in `pf_ffi_register` just works. One
  dispatch completion: `OP_PRIM`'s arity switch currently handles
  0–3 arguments and must extend to 7 (`#%ffi-call6` is arity 7) —
  add cases, no format change.
- **Reference interpreter (Racket):** the manifest entries carry
  ref-impls built on `ffi/unsafe` — `(ffi-lib path)`,
  `(get-ffi-obj cname lib (_cprocedure (list _int64 ...) _int64))`
  — with every §4/§5 check re-implemented in the ref-impl layer,
  because the checks are *semantics* and the interpreter must stay
  golden-equal. Feasibility is not in doubt (`ffi/unsafe` is two
  decades mature and its `_int64`/`_bytes`/`_pointer` ctypes cover
  the v1 universe exactly); the cost is the usual
  two-implementations-one-message discipline, and it is confined to
  one ref-impl closure per prim, not per import. Racket's own
  load-failure exceptions are caught and re-raised in §5.3's exact
  texts.
- **Wasm VM:** `pf_ffi_register`'s dlopen seam is `#ifdef __wasm__`
  guarded — precisely io.c's existing `system()` precedent
  ("WASI-absent → documented refusal") — and fails at registration
  with §5.3's browser message. So: **declared foreign libraries
  fail at load in the browser, loudly and testably.** No wasm
  heroics in any planned version. The honest future seam, named but
  not designed: the wasm component model's typed imports are the
  *same shape* as a `foreign` form (declared signatures, generated
  lift/lower), so a browser-side registry mapping declared imports
  to component instances is a coherent v3 — it changes `pf_ffi_register`'s
  wasm branch and nothing above it. Until someone needs it, a clean
  refusal teaches the boundary better than an emulation would.
- **REPL:** native VM sessions register imports like any top-level
  code (dlopen'd libraries persist for the session); the browser
  REPL refuses per the above. A firing FFI cast aborts the eval and
  the session survives, like every cast today.

### 8.4 Testing (the house gates)

- **Corpus untouched**: 309/309 on every route, byte-identical —
  the FFI adds manifest entries only (appended; prim ids stable),
  and the gensym-budget invariant is respected (any new
  keyword-accepting Racket definitions are counted; the
  byte-identity baseline regenerates with the same .zo state).
- **`tests/ffi-demo/`** (directory corpus entries, the module
  runner's existing shape): `cdemo/` — a ~60-line C library
  exercising every §4 row *and every error path* (embedded NUL,
  out-of-range return, NULL constructor, brand mismatch,
  use-after-close, double close); `pfregex/` — §9.4's Rust crate; a
  Makefile building the `.dylib`s. Golden `.puf` programs per
  feature run on interp + both native backends + native VM; the
  wasm leg asserts the load-refusal text — **the refusals are
  goldens too**.
- **`src/test-ffi.rkt`** mirrors test-modules.rkt: every §5.1
  load-time rejection and §5.2 blame message, exact-text, on every
  route that can produce it (the test-arith.rkt precedent for
  4-route exact-text assertions).
- **Lockstep**: puffincc compiles the same corpus through its own
  lowering; `diff-ir desugar` matches on FFI programs; stage-2
  self-compile stays green (puffincc itself declares no imports,
  so this is the null case, asserted anyway).
- **A `bench/` entry** pitting `regex-find` against the pl-regex
  Puffin engine keeps us honest about boundary overhead, including
  the desc-interpretation cost of §8.1.

## 9. Guests: C++, and Rust as the first-class one

Unchanged in substance from the first design; condensed and updated
to the new surface. From Puffin's side a guest language is
invisible — only the C ABI crosses — so this section is discipline
for the *library's* author, not new mechanism.

### 9.1 C++: `extern "C"` shims, exceptions stop at the border

Only `extern "C"` symbols are declarable; mangled names, overloads,
templates, member functions get a shim (`extern "C"` functions over
an opaque `Widget*`). **No C++ exception may cross into a Puffin
frame** — generated Puffin code has no unwind tables, so a `throw`
unwinding through it is UB of the worst kind; every shim export
wraps its body in `try { } catch (...)` and converts to the C-idiom
error the declaration expects (NULL → `(Nullable T)`, sentinel
int). RAII and the STL live happily *inside* the shim; `new`/`delete`
stay on the C++ side of §7's table (`#:consumes` points at the
shim's `pfw_free`, never at `free`). A C++ shim dylib carries its
own `-lc++` linkage — a dylib's dependencies are its own business,
which is one more quiet advantage of the dlopen design: no `#:link`
flag passthrough in Puffin source at all (the first design's open
question 7 dissolves).

### 9.2 Rust: the ownership disciplines interlock

A `cdylib` crate (`crate-type = ["cdylib"]` — note: the first
design said `staticlib`; dlopen wants the dylib) with
`#[unsafe(no_mangle)] pub extern "C"` exports is indistinguishable
from a C library, and every rule in §§4–7 applies verbatim. Rust
adds memory safety *inside* the library and crates.io as Puffin's
borrowed ecosystem. The discipline:

- Only C types cross: raw pointers, fixed-width ints, `bool` —
  never `String`, `&str`, `Vec`, slices, trait objects, `Result`
  (not ABI-stable; Rust's own FFI law, not ours).
- Handles: born `Box::into_raw(Box::new(v))`, die
  `drop(Box::from_raw(p))` in exactly one export — the `#:consumes`
  target. Puffin's null-on-close guarantees that export runs at
  most once, which is precisely the contract `Box::from_raw`
  demands (§6.2).
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
  (honest, tiny, matches `pf_fatal` philosophy). Long-running-
  process libraries: `catch_unwind` at every export, converting to
  the declared error idiom.
- **Boehm cannot see Rust's heap** — but v1 Rust exports only ever
  receive unwrapped C values, so there is nothing taggable to
  stash. The rule bites when callbacks arrive (§11).

### 9.3 Build orchestration

puffincc will not run cargo or make. `foreign` names a `.dylib`
path; producing it is the library's Makefile's business (`cargo
build --release` → `target/release/libpfregex.dylib` with
`crate-type = ["cdylib"]`; `cbindgen --lang c` generates the header
that a v2 cross-check can verify declarations against — the
clang `-fsyntax-only` `_Static_assert` trick from the first design
carries forward unchanged as the v2 `#:include` seam). Target
triples must agree (`aarch64-apple-darwin` for the native routes);
a mismatch is a clean dlopen failure at load, not a runtime
surprise.

### 9.4 Worked example (carried, updated)

The Rust regex crate example from the first design survives with
two mechanical edits — `crate-type = ["cdylib"]`, and the Puffin
face becomes:

```scheme
(define-foreign-type Regex)
(foreign "pfregex/target/release/libpfregex.dylib"
  (: regex-compile (-> Str (Nullable Regex))   #:c-name "pfregex_compile")
  (: regex-match?  (-> Regex Str Bool)         #:c-name "pfregex_is_match")
  (: regex-find    (-> Regex Str (Nullable Str)) #:c-name "pfregex_find"
                                                 #:gift "pfregex_str_free")
  (: regex-close   (-> Regex Void)             #:c-name "pfregex_free"
                                               #:consumes))
```

`build/puffincc grep.puf -o grep && ./grep` — no linker flags, no
archives; the dylib resolves at load relative to the module.

## 10. What stays out (v1)

Deep struct/union/array marshaling (shim seam, §4.6); floats (§4.5
— a language project, sequenced in §13 Q1); callbacks and the
pinning API (§11); finalizer backstops (§6.2); varargs; C++ beyond
`extern "C"` shims; foreign threads calling anything; static
linking of foreign code (v2 `#:static` seam for single-binary
distribution — the mechanism is the first design's archive
collection, revived behind the same declarations); the `#:include`
clang cross-check (v2, designed, §9.3); any cargo/cmake
orchestration; libffi (structurally unnecessary, §8.2); arity > 6
(the packed-call convention could carry it; wait for a real need);
wasm component imports (v3 shape named in §8.3). Each exclusion has
a named seam; none requires revisiting §§3–7's contracts.

## 11. Callbacks: the designed-but-deferred piece

Deferred whole from v1 (the first design specced it; the type
system changes nothing about it, and it is the one feature whose
absence keeps §2's "transient is complete" theorem true — worth
being explicit that shipping callbacks *weakens* the boundary story
from complete to transient-with-caveats). Sketch retained so the
seams stay honest: `(callback (-> τ ... τ))` argument types; a
`pf_call_closure(clo, argc, argv)` runtime entry (per-target shim
mirroring the documented calling convention — the one place the FFI
would need target-specific code); trampolines passing the pinned
closure as `void *user_data`; the `pf_gc_pin` API shipping
alongside; callbacks legal only on the calling thread during the
call (v1 Puffin is single-threaded; Boehm scans the interleaved C
frames fine); foreign-spawned threads out until Puffin has threads
(`GC_register_my_thread` is the eventual answer); `error` inside a
callback exits the process (today's semantics everywhere) until
Puffin grows exceptions, at which point callbacks become an
exception barrier like Rust's `catch_unwind` discipline. On the
bytecode routes, `pf_call_closure` must call back *into the VM
dispatch loop* (closures are tagged function indices there) — a
re-entrancy seam the VM's frame stack already tolerates but which
needs its own verification gate when this ships.

## 12. Phases, each with its verification gate

1. **Scalars on every native route** — the shippable minimal slice.
   `foreign` + `(: ...)` parsing and typing in both compilers
   (`Int`/`Bool`/`Str`/`Void`/`(Nullable Str)`, `#:c-name`,
   `#:gift`); the desugar lowering; `lib/foreign.c` with
   `#%ffi-register`/`#%ffi-call0..6` + manifest entries (+
   `ffi/unsafe` ref-impls); VM `OP_PRIM` arity cases 4–7; wasm
   refusal; `tests/ffi-demo/cdemo` + `src/test-ffi.rkt`.
   **Gate:** corpus 309/309 untouched byte-identical on all routes;
   cdemo goldens green on interp + arm64 + x86-64 + native VM;
   every §5 message exact-text on every route incl. the wasm
   refusal; stage-2 fixpoint; tables regenerated
   (gen-puffincc-tables, gen-vm-prims, STDLIB/stdlib.html — the
   docs-as-tests generator will demand doc lines for any new
   surface prim, i.e. `foreign-ptr?`).
2. **Widths + handles.** `I8..U64` marshaling; `define-foreign-type`,
   kind 19 + brands + `foreign-ptr?`, cast-desc form, `#:consumes`
   null-on-close, `(Nullable T)` for handles.
   **Gate:** phase-1 gates; the full §5.2 blame matrix incl. brand
   mismatch / closed / double-close, exact-text everywhere;
   `(ann v Regex)` casts work; RSS-flat close loop (the leak
   check); `foreign-ptr?` disjointness pinned like `adt?` was.
3. **Rust end-to-end + interfaces.** `tests/ffi-demo/pfregex` (§9.4)
   as a corpus entry; typed `.pufs` ascription over an FFI module;
   `.pufi` export of foreign names at declared types under
   `--separate` (expected: falls out of §8.1's lowering — the gate
   proves it).
   **Gate:** pfregex goldens on all native routes; separate-
   compilation matrix (modules-typed style) with a foreign dep incl.
   staleness on declaration change; bench entry recorded.
4. **v2 seam items, by need:** `#:include` clang cross-check;
   `#:destructor` finalizer backstop (native, warn-vs-collect per
   §13 Q4); `#:static`; `Float` (blocked on flonums); struct
   declarations / `(Vec Int)` borrows; callbacks (§11, its own
   gates, incl. the VM re-entrancy one).

Phase 1 is deliberately small enough to build and gate in one
sitting: one runtime module, one lowering, zero backend edits — and
it already delivers the headline: typed, blamed, dlopen'd C calls
on all four native-capable routes with the browser refusing
honestly.

## 13. Open questions for Kris (each with a recommended default)

1. **The Float story.** The FFI is now the loudest customer for
   flonums (any numeric C library wants `double`). Options: (a) do
   flonums as their own language project first — representation
   (NaN-boxing vs boxed vs a 61-bit scheme), printing, `equal?`,
   all four routes — then the FFI adds `Float` as one table row;
   (b) let the FFI force a minimal boxed flonum in early.
   **Recommended: (a).** The FFI seam is clean either way (§4.5),
   and a representation chosen under FFI deadline pressure is the
   kind of decision this project exists to not make.
2. **Browser posture.** This design: declared `foreign` libraries
   fail at *load* on the wasm VM (§5.3) — consistent with native
   (dlopen at load), maximally honest, but it means a module can't
   carry an "optional native accelerator". Alternative: fail at
   first *call* (the first design's posture), which lets
   FFI-declaring modules load for their pure parts.
   **Recommended: fail at load.** One resolution semantics on every
   route beats browser-special laziness; if optional accelerators
   become real, that wants a designed feature (conditional
   requires), not a quiet divergence.
3. **`(Nullable τ)`.** Ships as an FFI-result-only form the checker
   sees as `_` (§4.4). Alternative: bless a stub-level `(Option τ)`
   wrap (allocates a `Some` per call; fully typed).
   **Recommended: ship `Nullable`, revisit after phase 3** — if
   your FFI-facing code ends up wrapping everything in Option by
   hand anyway, promote it then; the desc format has room.
4. **Finalizers.** v1 is explicit-close-only (§6.2). When the v2
   backstop comes: silently-collecting finalizer, or the stricter
   "finalizer only *warns* to stderr that a handle leaked, close is
   still mandatory"?
   **Recommended: the warning mode** — it matches the FFI's
   loud-over-silent personality and doubles as a leak detector; and
   note it would be native-Boehm-only until the wasm/VM collector
   grows finalization, which is exactly why it isn't in v1.
5. **Default `#:c-name` mapping.** Specced: `-` → `_`, anything
   else requires the clause (§3). Comfortable, or would you rather
   *always* require `#:c-name` (maximal explicitness, more noise)?
   **Recommended: keep the mapping** — it covers the honest
   majority and can't misfire silently (a wrong guess is a missing
   symbol at load, named).
6. **Embedded-NUL check strictness.** The `strlen == len` check on
   every outbound `Str` is O(n) (§4.3). Keep unconditional (my
   vote: yes — it is the FFI's personality), or add per-argument
   `#:unchecked` for hot paths after benchmarks say it matters?

---

## Appendix A: feasibility spike transcript (2026-07-13, macOS arm64, uncommitted, /tmp)

Three spikes, proving the §8 mechanism's load-bearing claims.
`libdemo.c` exports `demo_add(int64_t,int64_t)`, `demo_big(void)`
returning `INT64_MAX`, `demo_strlen(const char*)`, and a malloc'ing
`demo_greet` (the `#:gift` shape).

**Spike 1+2 — dlopen/dlsym + type-directed tagged round-trip**
(`host.c`: puffin.h's exact tag scheme; marshal derived from
`(-> Int Int Int)`; the 61-bit retag check as specced in §4.1):

```console
$ clang -O2 -dynamiclib -o libdemo.dylib libdemo.c
$ nm -gU libdemo.dylib
0000000000000408 T _demo_add
0000000000000410 T _demo_big
000000000000041c T _demo_greet
0000000000000418 T _demo_strlen
$ clang -O2 -o host host.c && ./host
dlopen/dlsym ok: demo_add=0x102a50408 getpid=0x18aece178 (pid=17232)
tagged in : a=0xa0 b=0xb0
round trip: raw=42 tagged=0x150 untagged-back=42
strlen via FFI: 6
gifted str  : hello kris (copied, original freed)
now calling demo_big (returns INT64_MAX; must die loudly):
puffin runtime error: cast: expected Int (61-bit), got 9223372036854775807 (blame: foreign demo-big's result)
exit: 255
```

Notes: dlopen resolved both the local dylib and
`/usr/lib/libSystem.B.dylib` (dyld shared cache) with `dlsym` of
`getpid` callable — system libraries need no special handling. The
tagged round trip is exact (`0xa0`=20, `0xb0`=22 → raw 42 →
`0x150`=42<<3), and the range check on `INT64_MAX` fires with the
specced message and `exit(255)` (the `pf_fatal` contract).

**Spike 3 — against the real runtime** (`host2.c` links the actual
`src/runtime/libpuffin.a`: `pf_init`, a Boehm-allocated Puffin heap
string via `pf_string_from_bytes`, its NUL-terminated payload
passed *borrowed* through a dlsym'd foreign function, result
retagged and printed by `pf_display_value` — §4.3's zero-copy
outbound claim, end to end; the empty whole-program literal tables
are defined the way the separate-compilation entry unit defines
them):

```console
$ clang -O2 -I$REPO/src/runtime -o host2 host2.c $REPO/src/runtime/libpuffin.a
$ ./host2
puffin str: kind=3 len=16 payload='a puffin appears'
borrowed strlen through dlsym: raw=16 tagged->16
exit: 0
```

Everything §8 needs from the platform is demonstrated: dlopen from
runtime-shaped C, integer-class calls through casted function
pointers, borrowed string payloads out of the real GC'd heap, and
the loud 61-bit boundary.
