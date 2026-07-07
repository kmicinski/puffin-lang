# The Puffin FFI: typed imports of the C ABI, Rust as a first-class guest

> **Status:** DESIGN (2026-07-07). Nothing here is implemented. The
> design is written against the current contract (puffin.h tag
> scheme + kind registry, stdlib.rkt manifest, modules.rkt front
> pass, gradual types on the `gradual` branch) and is meant to be
> buildable without touching any compiler pass — which, as §1
> argues, is the whole point.

Design goals, in order: (1) **bug-free over featureful** — every
boundary crossing is checked, every ownership rule is written down,
and anything we cannot make safe is *out* rather than half-in;
(2) **the FFI is the manifest, user-extensible** — Puffin already
compiles direct calls to foreign C symbols on every route; the FFI
must be that same machinery opened to users, not a second mechanism;
(3) **typed at the boundary** — an FFI declaration is a typed import,
and the gradual type system's cast points land exactly there;
(4) **Rust is a first-class guest**, not an afterthought: the dream
of writing performance/ecosystem leaves in Rust and gluing them into
Puffin programs is feasible today, with caveats this document states
plainly.

## 1. The core insight: Puffin already has an FFI

Look at what happens when the compiler sees `(string-append a b)`:

- `stdlib.rkt` says the runtime entry is `pf_string_append`, arity 2;
- instruction selection emits `movq`s into argument registers and a
  direct `callq pf_string_append` (or `bl` on arm64);
- the assembly declares `.extern pf_string_append`;
- the linker resolves it against `libpuffin.a`.

That *is* a foreign function interface — to a C function, following
the C calling convention, resolved by the system linker against a
static archive. The only things that make `pf_string_append` special
are (a) it appears in the manifest, and (b) it speaks tagged `pf`
words natively.

The FFI, then, is two small generalizations:

1. **A per-program extension of the manifest.** An `ffi` declaration
   adds one prim-spec-shaped entry (name, arity, extern symbol,
   type) to the tables the backends and IR predicates already
   consume. No new call machinery; the existing one, user-fed.
2. **Marshalling stubs for functions that speak C types instead of
   `pf`.** `pf_string_append` takes tagged words; `regcomp` does
   not. The compiler emits a tiny per-declaration stub that untags
   arguments, calls the foreign symbol, and retags the result. The
   stub is generated assembly (or equivalently a generated `.c`
   shim; see §7) — the runtime grows only three generic helpers.

Everything else in this document is working out what those stubs are
allowed to do (§3), what the GC promises (§4), and how the other two
implementations keep their honesty (§8).

## 2. Surface language

FFI declarations are top-level module forms, sitting next to
`require` and `provide`:

```scheme
;; regex.puf -- a Puffin-face module for a foreign library
(provide regex-compile regex-match?)

(ffi-lib "vendor/libpfregex.a"
         #:include "pfregex.h"                 ; documentation + v2 check
         #:shared  "vendor/libpfregex.dylib")  ; optional: interpreter parity

(define-foreign-type Regex #:destructor "pfregex_free")

(ffi regex-compile (-> Str Regex)  #:c-name "pfregex_compile")
(ffi regex-match?  (-> Regex Str Bool) #:c-name "pfregex_is_match")
```

- **`(ffi-lib path clause ...)`** — declares that this module's
  foreign symbols live in `path` (resolved relative to the module's
  file, like `require`). Repeatable. `#:include` names the C header
  the symbols come from: v1 treats it as documentation; v2 uses it
  for a compile-time signature cross-check (§3.6). `#:shared` names
  a dynamic-library build of the same code, used *only* by the
  reference interpreter (§8); native linking always uses the archive.
  `#:link "flags"` passes extra linker flags (frameworks, `-l`s)
  verbatim — needed in practice for Rust staticlibs (§6.4).
- **`(ffi name τ clause ...)`** — declares `name` as a foreign
  function of arrow type `τ` (which must be a concrete `(-> τ ... τ)`
  over the marshallable types of §3 — `_` is not marshallable, and
  an FFI declaration is the one place an annotation is mandatory).
  `#:c-name` gives the linker symbol when it differs from `name`
  (it usually does; Puffin names have `-` and `?`). The declared
  name is an ordinary module-level binding: it provides, requires,
  renames, and mangles through the module system unchanged — only
  the *extern symbol* is exempt from mangling, exactly as `pf_*`
  symbols are today.
- **`(define-foreign-type Name clause ...)`** — introduces an opaque
  handle type (§3.4). `#:destructor "c_name"` names the C function
  the GC finalizer backstop calls (one argument, the raw pointer).

**FFI declarations are typed imports.** This is the load-bearing
connection to TYPES.md: an `ffi` name enters the type environment at
its declared type — never `_` — so the bidirectional checker checks
every call site's arguments against real types. In fully-annotated
code, inconsistencies are compile-time errors as usual. In untyped
code, arguments flow in at `_`, and `_ ~ Int` is consistent — the
call checks statically, and the marshalling stub performs the
dynamic check (tag test, range test) at runtime. That stub *is* the
cast that TYPES.md phase 3 will insert at `_`→concrete boundaries,
with one difference in posture: **at the FFI boundary the dynamic
check is never erased, even from fully typed code**, because the far
side of the boundary is untrusted machine code and a wrong tag is
not a wrong answer but a corrupted heap. The FFI is where gradual
typing's "casts at the boundary" story stops being a metaphor.

Signature files compose: a `.pufs` signature can ascribe a module
whose exports happen to be FFI names — clients cannot tell (and must
not be able to tell) whether `regex-compile` is Puffin or C behind
the interface.

## 3. Marshalling, type by type

The v1 marshallable types, chosen so that every conversion is a
handful of instructions and *none* can silently lose information:

| Puffin type | C type | in (Puffin → C) | out (C → Puffin) |
|---|---|---|---|
| `Int` | `int64_t` | tag check, then `>> 3` | 61-bit range check, then `<< 3` |
| `(Int #:c "int")` etc. | `int`/`int32_t`/… | as above + checked truncation | sign/zero-extend, then `<< 3` |
| `Bool` | `bool` / `int` | `v == PF_TRUE ? 1 : 0` (tag-checked) | `r ? PF_TRUE : PF_FALSE` (any nonzero) |
| `Str` | `const char *` | borrow payload pointer (see 3.3) | copy into a fresh Puffin string |
| `Void` (result only) | `void` | — | `PF_VOID` |
| foreign type `T` | `T *` (opaque) | brand-checked unwrap (see 3.4) | wrap in a foreign handle |

### 3.1 Int

Fixnums are `n << 3`, 61 bits signed. Inbound: `pf_expect` fixnum
tag, arithmetic shift right by 3. Outbound: the returned `int64_t`
must survive `<< 3` — the stub checks that the top four bits are
sign-uniform and calls `pf_die_arith`-style fatal (with the FFI
name in the message) if not. **No silent wrapping, ever**: a C
function returning `INT64_MAX` is a runtime error, not a negative
number. Width-annotated variants (`#:c "int"`, `"int32_t"`,
`"size_t"`, `"uint32_t"`) exist because real C headers are full of
`int` — inbound values are range-checked against the declared width
(error on overflow), outbound values are sign- or zero-extended per
the width's signedness and always fit 61 bits except `uint64_t`/
`size_t` above 2^60, which is checked. This is deliberate friction:
the FFI refuses to be a source of integer-truncation bugs.

### 3.2 Bool

Inbound `Bool` requires an actual boolean (tag check; Racket
truthiness stops at this border — passing `0` where C expects a
flag is almost always a bug, and `(if x #t #f)` is cheap to write).
Outbound, any nonzero C value is `#t`, matching C idiom.

### 3.3 Str: borrow in, copy out

Two facts make the cheap thing also the safe thing here:

- Puffin strings are already **NUL-terminated by layout** (io.c's
  `cstr_of` relies on this today), and their payloads are
  `pf_alloc_atomic` bytes;
- Boehm is a **non-moving** collector that scans the C stack, so a
  pointer into a live object's payload stays valid for as long as
  the frame holding the tagged reference is live.

So **inbound `Str` is a borrowed `const char *`** — the stub passes
`pf_heap_ptr(v) + 1` directly, zero copies. The pointer is valid
*for the duration of the call only*; a callee that stashes it is
governed by the ownership table (§4.4), and a callee that mutates
it is undefined behavior on both sides (hence `const` in the
declared C signature — this is what `#:include` will cross-check in
v2). One checked hazard: a Puffin string may contain embedded NUL
bytes (they're byte strings), which would silently truncate meaning
on the C side. The stub checks `strlen(p) == pf_len_of(v)` and
errors otherwise — O(n), branch-predictable, and it converts a
silent data bug into a loud one. That trade is this FFI's
personality in one line.

**Outbound `Str` is always a copy** — the stub calls the runtime
helper `pf_ffi_str_copy(const char *)`, which allocates a fresh
Puffin string from the NUL-terminated result. Borrowing outbound is
unsound (we cannot know the C string's lifetime) and ownership-
transfer-by-default is a leak factory. When the callee transfers
ownership (it `malloc`ed the string for us — the Rust `CString`
pattern, `asprintf`, etc.), declare `(Str #:gift "free_fn")`: the
stub copies, then immediately calls the named free function
(`"free"`, or the library's paired deallocator) on the original.
Copy-then-free at the boundary means Puffin never holds foreign
string memory and the foreign allocator never sees Puffin memory —
the allocator-mismatch class of bug is structurally impossible.

`NULL` inbound-to-Puffin: a returned `char *` may be NULL in C
idiom ("not found"). A declaration of result type `Str` treats NULL
as a runtime error; declare `(Nullable Str)` to map NULL to `#f`
(and symmetrically for foreign handles). `#f` is the Puffin idiom
for "no answer" (`string->number` already returns it) — this keeps
C's billion-dollar mistake quarantined in the stub.

### 3.4 Everything else: opaque foreign handles

v1 does **not** marshal structs, arrays, callstructs-by-value,
unions, or pointers-to-anything-transparent. Every other C type
crosses as an **opaque handle**: a new heap kind (the HAMT
precedent — one runtime module, one `pf_register_kind` call, an
ext-kind id recorded in the manifest):

```c
// lib/foreign.c -- PF_KIND_FOREIGN = 18 (16/17 are the HAMTs)
// payload: | raw pointer | brand (symbol) | destructor fn or 0 |
```

- **Branded.** The brand is the interned symbol of the
  `define-foreign-type` name. Unwrapping checks kind *and* brand:
  passing a `Regex` where a `Sqlite` is declared is a runtime error
  naming both brands, not a segfault three frames later. Handles
  print as `#<Regex 0x104a3c200>`; `equal?` is identity.
- **Finalized, with an explicit-close escape hatch.** If the foreign
  type declares `#:destructor`, `pf_ffi_wrap` registers a Boehm
  finalizer (`GC_register_finalizer_no_order`) that calls it on the
  raw pointer. Boehm finalizers are a *backstop*, not a resource
  discipline — they run at some GC after unreachability, or never
  (program exit does not run outstanding finalizers). Libraries
  wrapping scarce resources (fds, connections) should also export an
  explicit close: declare it with `#:consumes` —
  `(ffi regex-free (-> Regex Void) #:c-name "pfregex_free" #:consumes)`
  — and the stub calls the destructor, **nulls the stored pointer,
  and cancels the finalizer**. Any later use of the handle is a
  "use of closed Regex handle" error; a double close is a no-op
  error, not a double free. Use-after-free and double-free are thus
  both unrepresentable from the Puffin side.
- **NULL from constructors:** `(Nullable Regex)` as in §3.3 — a NULL
  return becomes `#f` instead of a dead handle.

**The v2 seam.** Deep marshalling, when it comes, will be a new
*declaration* form — `(define-c-struct ...)` generating per-field
accessor stubs against a layout computed from `#:include` by a
clang-driven tool at build time — not a change to §3's types. The
stub generator is written per-declaration from day one precisely so
that new declaration forms mean new stub shapes, never new call
machinery. Until then the answer to "how do I get at
`struct stat`'s fields" is: write a five-line C shim with getter
functions and declare those. Shims are not a failure of the FFI;
they are the FFI working as designed (§5 makes the same move
mandatory for C++).

### 3.5 What is not marshallable at all (v1)

`_` (declare a real type or don't declare the import), function
types (Puffin closures cross only via the §4.3 callback machinery),
containers (`List`/`Vec`/`Hash`/`Set` — convert at the Puffin level
to repeated calls or strings; a `(Vec Int)`→`int64_t*` borrow is
plausible v2, same seam), floats (**Puffin has no flonums yet** —
this is the loudest gap when facing real C libraries, and it is a
language question, not an FFI question; the FFI adds `Float` the
week the language does), variadic C functions (`printf` — shim it).

### 3.6 The `#:include` cross-check (v2, designed now)

Trust-the-declaration is v1's posture and it is honest but human.
v2: at compile time, generate a `_Static_assert`-bearing `.c` file
from every `ffi` declaration —

```c
#include "pfregex.h"
static bool (*_pf_check_1)(const pfregex*, const char*) = pfregex_is_match;
```

— and run `clang -fsyntax-only` over it. A mismatch between the
Puffin declaration and the real prototype becomes a compile error
with clang's own diagnostics. Cheap, uses the toolchain we already
shell out to, catches the exact class of bug (stale declaration
after a library upgrade) that FFIs are notorious for.

## 4. GC discipline: what Boehm buys, and the rules that remain

### 4.1 What conservative scanning buys us

Boehm scans thread stacks, registers, and the executable's static
data — and since v1 links foreign code *statically* into the same
executable, that includes the foreign library's globals. It is also
non-moving. Consequences, all load-bearing above:

- A `pf` argument sitting in the caller's frame or a callee-saved
  register keeps its object alive across any foreign call — **no
  handle tables, no `PROTECT`/`UNPROTECT` ceremony** (the R and
  historical-Ruby FFI tax) for call-duration references.
- Borrowed interior pointers (§3.3) stay valid: interior pointers
  are enabled (puffin.h says so) and objects never move.
- A `pf` stored in a foreign **global** is found by the static-data
  scan. (Still declare it via §4.2's pin API for portability and
  documentation — but it is not the sharp edge.)

### 4.2 The sharp edge: foreign *heap* memory is invisible

Boehm does not scan memory from `malloc` — or from **Rust's
allocator** (§6). A `pf` stored into a malloc'd struct is invisible
to the collector; the object dies at the next GC and the C side
holds a dangling tagged pointer. The rules, in order of preference:

1. **Don't store `pf` values in foreign memory.** Store what they
   unwrap to (the C string copy, the int). This covers ~all of v1's
   surface, since v1 only passes unwrapped values anyway.
2. If foreign code must hold a `pf` (callbacks, §4.3), **pin it**:
   `pf_gc_pin(v)` / `pf_gc_unpin(v)`, two new runtime entries.
   Implementation: a GC-visible pin table (an uncollectable array of
   `pf` slots with a free list — `GC_malloc_uncollectable` so the
   table itself is a root and is scanned). Pinning is refcounted per
   value so independent holders compose.
3. Foreign code allocating memory that will *contain* `pf` values
   should allocate it with `pf_alloc_raw` (already exported: GC-
   visible, GC-managed) instead of `malloc`.

`GC_malloc_uncollectable` and `GC_add_roots` remain available to C
authors who know Boehm, but `pf_gc_pin` is the documented interface:
one call, no Boehm API surface leaking into user shims.

### 4.3 Callbacks: C calling Puffin closures

Foreign libraries want callbacks (`qsort`, event loops, Rust
iterator adapters). Two pieces:

- **`pf pf_call_closure(pf clo, int64_t argc, pf *argv)`** — a
  per-target assembly shim in the runtime that checks the closure
  kind, loads the code pointer from slot 0, places the closure in
  the closure register, `argc` in the arity register (`r10`/`x12` —
  the variadic protocol already exists), arguments in the argument
  registers (≤6; the packed-call protocol applies above, same as
  ordinary calls), and calls. This is the one place the FFI needs
  target-specific runtime code, and it is a mirror of what the
  compiler's own calling convention documents already specify.
- **Trampolines.** C callback signatures are C-typed, so a Puffin
  closure crosses as a *pair* `(fn, void *env)` in the C idiom: the
  stub pins the closure (§4.2), passes a generated trampoline as
  `fn` and the pinned `pf` as `env`; the trampoline marshals C
  arguments per the declared callback type (`(callback (-> Int Int
  Bool))` in the `ffi` arrow), calls `pf_call_closure`, and
  unmarshals the result. Libraries without a `void *user_data`
  parameter cannot receive Puffin closures — that is their bug, and
  the workaround (a C-side static) is the shim author's informed
  choice, not the FFI's default.
- **Constraints, stated plainly:** callbacks must arrive on a thread
  the GC knows. v1 Puffin is single-threaded, so: callbacks from
  the calling thread during a foreign call — fine (Boehm scans the
  C frames in between; a GC triggered inside the callback is
  business as usual). Callbacks from foreign-spawned threads —
  **out in v1** (the stub aborts with a clear message if it can
  detect it; the rule is documented regardless). When Puffin grows
  threads, `GC_register_my_thread` is the v2 answer. An `error`
  (Puffin `exit(1)`) inside a callback unwinds no foreign frames —
  it exits the process, which is today's semantics everywhere; when
  Puffin grows exceptions, callbacks become an exception barrier
  (trap, return a declared error value) exactly like Rust's
  `catch_unwind` discipline in §6.3.

### 4.4 The ownership table

Who frees what. "Puffin/GC" means: nobody calls free, the collector
handles it; foreign code must never `free`/`delete`/`drop` it.

| Memory | Allocated by | Owned/freed by | Foreign side may | Puffin side may |
|---|---|---|---|---|
| Puffin heap values (strings, vectors, handles, closures) | Puffin GC | Puffin GC | read borrowed ptrs during the call; hold across calls **only if pinned** | everything |
| Borrowed `Str` argument (§3.3) | Puffin GC | Puffin GC | read during the call; never write, never stash unpinned, never free | — |
| C string returned as `Str` | foreign | foreign — unless `#:gift`, then the **stub** frees via the named fn after copying | — | sees only the copy |
| Opaque handle *wrapper* | Puffin GC | Puffin GC | nothing (never sees it) | pass it around freely |
| Opaque handle *pointee* | foreign | foreign code, invoked by Puffin exactly once: `#:consumes` call or finalizer backstop | use per its own API | must not touch the raw pointer |
| `pf` stored in foreign heap memory | Puffin GC | Puffin GC | hold while pinned; must `pf_gc_unpin` | — |
| Callback closure held by a library | Puffin GC | Puffin GC (pinned by the registering stub; unpinned by the deregistering `#:consumes` call) | call via trampoline | — |
| Buffers `malloc`ed by foreign code | foreign | foreign | — | sees only boundary copies |

One sentence version, which is also the Rust rule in §6: **each side
frees only what its own allocator allocated, and every
ownership-transferring call is declared as such (`#:gift`,
`#:consumes`) so the stub — not the programmer — performs the
transfer.**

## 5. C++: `extern "C"` shims, exceptions stop at the border

Puffin speaks the C ABI. C++ is admitted the way every C-ABI
language admits it — through an `extern "C"` shim, written by the
library's Puffin-face author:

```cpp
// shim.cpp -- the only file that sees C++ types
#include "widget.hpp"
extern "C" {
  void *pfw_new(const char *name) {
    try { return new Widget(name); }
    catch (...) { return nullptr; }          // -> (Nullable Widget)
  }
  int64_t pfw_weight(void *w) noexcept {
    return static_cast<Widget *>(w)->weight();
  }
  void pfw_free(void *w) { delete static_cast<Widget *>(w); }
}
```

Rules, none negotiable:

- **Only `extern "C"` symbols are declarable.** Mangled names,
  overloads, templates, member functions: shim them. cppyy-style
  automatic binding is explicitly a non-goal — it is where FFI bug
  counts go to grow.
- **No C++ exception may cross into a Puffin frame.** Generated
  Puffin code has no unwind tables; a `throw` that unwinds through
  it is undefined behavior of the worst kind (it may even *appear*
  to work). Every shim export is `noexcept` in spirit: wrap anything
  that can throw in `try { } catch (...)` and convert to the C-idiom
  error the declaration expects (NULL → `(Nullable T)`, sentinel
  int). The v2 `#:include` check (§3.6) can additionally require
  shim headers to declare `noexcept`, making the rule mechanical.
- Same for the reverse direction: a Puffin callback invoked from
  C++ must not have C++ exceptions thrown *around* it (a `throw`
  above the trampoline unwinding through Puffin frames below is the
  same UB). Shims that take callbacks catch at the callback layer.
- RAII, STL, everything C++ lives happily *inside* the shim; the
  border speaks C. `new`/`delete` pairs stay on the C++ side of the
  ownership table — a `#:destructor` for a C++ type points at the
  shim's `pfw_free`, never at `free`.

Linking: C++ shims pull in the C++ runtime; the `ffi-lib` for a C++
library carries `#:link "-lc++"` (macOS). puffincc keeps driving
plain `clang` and the flag rides the declaration — the driver stays
language-agnostic.

## 6. Rust: yes, it is feasible — here is the whole story

The dream is real and the shape is boring, which is the highest
compliment an FFI design can pay. Rust compiles to ordinary machine
code with no runtime GC; a `staticlib` crate is a `.a` exactly like
`libpuffin.a`; `extern "C"` + `#[no_mangle]` gives C-ABI symbols.
From Puffin's side, **a Rust crate is indistinguishable from a C
library** — every rule in §§3–4 applies verbatim. What Rust adds is
a better story *inside* the library: memory safety in the shim
itself, and crates.io as Puffin's borrowed ecosystem (regex,
serde_json, reqwest…). The caveats are real but bounded; they are
listed after the worked example, and none of them is disqualifying.

### 6.1 The export discipline

```rust
#[unsafe(no_mangle)]
pub extern "C" fn pfregex_compile(pat: *const c_char) -> *mut Regex { ... }
```

- `crate-type = ["staticlib"]`; every export `extern "C"` +
  `#[no_mangle]` (spelled `#[unsafe(no_mangle)]` since Rust 2024).
  Only C types cross: raw pointers, fixed-width ints, `bool`.
  **Never** `String`, `&str`, `Vec`, slices, trait objects, or
  `Result` — those layouts are not ABI-stable. This is not a
  Puffin restriction; it is Rust's own FFI law.
- **cbindgen** generates the C header from the Rust source
  (`cbindgen --lang c -o pfregex.h`). That header is what `ffi-lib
  #:include` points at, which means the v2 cross-check (§3.6)
  closes the loop: Puffin declaration ↔ clang ↔ cbindgen ↔ Rust
  source, machine-checked end to end. Until v2 it is documentation
  — still generate it.

### 6.2 Ownership: `Box::into_raw` / `Box::from_raw`, and never touch Puffin memory

The §4.4 table, translated into Rust idiom:

- An opaque handle is born as `Box::into_raw(Box::new(value))` and
  dies as `drop(Box::from_raw(ptr))` in exactly one export — the
  destructor named by `#:destructor`/`#:consumes`. The Puffin-side
  null-on-close + cancel-finalizer discipline (§3.4) guarantees
  that export runs at most once, which is precisely the safety
  contract `Box::from_raw` demands. The two disciplines interlock;
  neither is sufficient alone.
- Returned strings: `CString::into_raw`, with a paired
  `pfregex_str_free(s: *mut c_char) { drop(CString::from_raw(s)) }`
  export, declared as the `#:gift` free function. **Never** declare
  `#:gift "free"` for a Rust string — Rust's allocator is not
  libc's `malloc`, and freeing across allocators is heap corruption
  (the single most common Rust-FFI bug in the wild; the `#:gift`
  design makes the correct pairing a declaration, not a call-site
  habit).
- Borrowed `Str` arguments arrive as `*const c_char`:
  `CStr::from_ptr(p).to_str()` — and note `.to_str()` performs
  UTF-8 validation, which Puffin byte strings do not promise.
  Return an error sentinel on invalid UTF-8 (or use
  `to_string_lossy`/byte APIs when the crate allows); *copy*
  (`to_owned`) anything retained past the call, because the borrow
  dies with the call (§3.3).
- Rust never frees, reallocates, or writes to Puffin memory —
  Puffin pointers reaching Rust are `*const`, always. And the §4.2
  rule bites here specifically: **Rust heap memory is invisible to
  Boehm.** A `pf` stashed in a Rust struct without `pf_gc_pin` is a
  latent use-after-free. v1 Rust exports should simply never store
  `pf` values (they receive unwrapped C types anyway); callback
  registration goes through the pinning stubs like everyone else.

### 6.3 Panics must not cross, same as C++ exceptions

A panic unwinding across an `extern "C"` boundary was UB for years;
since Rust 1.81 the `extern "C"` ABI aborts the process instead.
So the default is *safe* but *blunt* — a stray `.unwrap()` in the
crate kills the Puffin process with a Rust backtrace. Two sanctioned
postures, pick per library:

1. **`panic = "abort"` in the release profile.** Honest, tiny,
   matches Puffin's own `pf_fatal` philosophy (runtime errors exit;
   there is nothing to unwind into anyway, v1 Puffin has no
   exceptions). Recommended default.
2. **`catch_unwind` at every export** for libraries that want
   graceful degradation: wrap the body, convert a caught panic into
   the declared error idiom (NULL / sentinel). Costs a few percent
   and some boilerplate; a 10-line macro (`ffi_export! { ... }`)
   hides it. Choose this for long-running-process libraries.

Either way the invariant is the §5 invariant: **no foreign unwinding
through Puffin frames, ever** — Rust merely enforces it for us.

### 6.4 Worked example: the `regex` crate, end to end

```console
$ cargo new --lib pfregex && cd pfregex
```

```toml
# Cargo.toml
[lib]
crate-type = ["staticlib"]
[dependencies]
regex = "1"
[profile.release]
panic = "abort"
```

```rust
// src/lib.rs
use regex::Regex;
use std::ffi::{c_char, CStr, CString};

fn cstr<'a>(p: *const c_char) -> Option<&'a str> {
    unsafe { CStr::from_ptr(p) }.to_str().ok()
}

#[unsafe(no_mangle)]
pub extern "C" fn pfregex_compile(pat: *const c_char) -> *mut Regex {
    match cstr(pat).and_then(|s| Regex::new(s).ok()) {
        Some(re) => Box::into_raw(Box::new(re)),
        None => std::ptr::null_mut(),          // -> (Nullable Regex)
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn pfregex_is_match(re: *const Regex, hay: *const c_char) -> bool {
    let re = unsafe { &*re };                  // non-null: stub brand-checks
    cstr(hay).map_or(false, |h| re.is_match(h))
}

#[unsafe(no_mangle)]
pub extern "C" fn pfregex_find(re: *const Regex, hay: *const c_char) -> *mut c_char {
    let re = unsafe { &*re };
    match cstr(hay).and_then(|h| re.find(h)) {
        Some(m) => CString::new(m.as_str()).unwrap().into_raw(),
        None => std::ptr::null_mut(),          // -> (Nullable (Str ...))
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn pfregex_str_free(s: *mut c_char) {
    if !s.is_null() { drop(unsafe { CString::from_raw(s) }); }
}

#[unsafe(no_mangle)]
pub extern "C" fn pfregex_free(re: *mut Regex) {
    if !re.is_null() { drop(unsafe { Box::from_raw(re) }); }
}
```

```console
$ cargo build --release          # -> target/release/libpfregex.a
$ cbindgen --lang c -o pfregex.h # the #:include header
$ cargo rustc --release -- --print native-static-libs
  note: native-static-libs: -lSystem -lc -lm    # goes in #:link
```

```scheme
;; grep.puf
(ffi-lib "pfregex/target/release/libpfregex.a"
         #:include "pfregex/pfregex.h"
         #:link "-lSystem -lc -lm")            ; from native-static-libs

(define-foreign-type Regex #:destructor "pfregex_free")

(ffi regex-compile (-> Str (Nullable Regex)) #:c-name "pfregex_compile")
(ffi regex-match?  (-> Regex Str Bool)       #:c-name "pfregex_is_match")
(ffi regex-find    (-> Regex Str (Nullable (Str #:gift "pfregex_str_free")))
     #:c-name "pfregex_find")

(define re (regex-compile "pu+ffin"))
(unless re (error "bad pattern"))
(println (regex-match? re "puuuuffin!"))       ; #t
(println (regex-find re "a puffin appears"))   ; puffin
```

```console
$ build/puffincc grep.puf -o grep    # ffi-lib archives + #:link flags
$ ./grep                             # join the existing clang line
#t
puffin
```

### 6.5 The caveats, all of them

- **Binary size:** a staticlib carries Rust's `std` (a few hundred
  KB to ~1MB after dead-stripping). Fine for a compiler author's
  daily driver; worth knowing before wrapping `left-pad`.
- **Target triples must agree:** puffincc's `-target
  arm64-apple-darwin` ↔ cargo's `aarch64-apple-darwin`. Same-host
  builds agree by default; puffincc's `-t x86-64` Rosetta target
  needs `cargo build --target x86_64-apple-darwin`. A mismatch is a
  clean link error, not a runtime surprise.
- **Link closure:** Rust staticlibs need the flags from `--print
  native-static-libs` (macOS: usually just `-lSystem -lc -lm`,
  already implied by clang, so `#:link` is often empty in practice
  — but check per crate; e.g. anything using the system keychain
  wants `-framework Security`).
- **Two Rust staticlibs in one program** can collide (each bundles
  `std`). The known fix is one umbrella crate re-exporting both.
  Document it; don't engineer around it in v1.
- **Build orchestration:** puffincc will not run cargo (§7 — it
  links what exists and errors helpfully when the `.a` is missing).
  A `make` target owns the cargo step. v2 may grow `#:build "cargo
  build --release"` on `ffi-lib`; it is deliberately not in v1.
- **UTF-8 vs byte strings** (§6.2), **panics abort** (§6.3), and
  **Boehm can't see Rust's heap** (§6.2) — restated here because
  these three are the ones that will actually bite.

None of these threatens the core claim: **Rust linkage is a
first-class, v1 capability**, and the ownership disciplines of the
two systems (affine types there, branded null-on-close handles
here) genuinely reinforce each other — this pairing is *safer* than
the plain-C case, not more exotic.

## 7. Build integration: the driver already does this

puffincc's link step today (`puffincc-src/main.puf`,
`assemble-and-link`) is one clang invocation: assembly + `--runtime`
archive + stack-size flag. The FFI extends it, not replaces it:

```
/usr/bin/clang -target <triple> -Wl,-stack_size,0x20000000 \
    prog.s <runtime.a> <ffi-lib archives, DAG postorder> <#:link flags> -o prog
```

- **Archives come from declarations, not flags.** Module resolution
  already walks the require DAG; it now also collects each module's
  `ffi-lib` paths (resolved relative to the declaring file) and
  `#:link` flags, deduplicated, in postorder. No new CLI surface —
  though `--lib extra.a` is a cheap addition for experiments. The
  same collection happens in `src/main.rkt`'s
  `run-assembler-linker` for the hosted route.
- **Externs and calls are the existing machinery.** The backends
  emit `.extern pf_string_append` and direct calls because the
  manifest says so; `ffi` declarations feed the same tables
  program-locally (`stdlib-extern-symbols` grows a per-program
  component; `irs.rkt` prim predicates likewise — the derived-views
  discipline in stdlib.rkt was built for exactly this). An FFI call
  site compiles as: marshal args (open-coded shifts/checks in the
  stub), `callq c_name`, marshal result. The stub is emitted once
  per declaration into the program's assembly, named like a
  lifted lambda (`_ffi_regex_compile`), and calls route through it;
  at `-O1` the optimizer may inline the Int/Bool marshalling at
  call sites the way it fuses compares today. Runtime additions are
  exactly four entries: `pf_ffi_str_copy`, `pf_ffi_wrap` /
  `pf_ffi_unwrap` (brand-checked), `pf_call_closure`, plus the
  `pf_gc_pin`/`pf_gc_unpin` pair — a `lib/foreign.c` module with a
  manifest entry for its kind, per the standing "new features are
  new lib/ modules" rule. **No compiler-pass changes**; the three
  implementations change where they always change (§8).
- **What we do not build:** libffi or any dynamic call
  construction. Every signature is static at compile time; the
  stub is ordinary generated code. This keeps FFI calls at
  direct-call speed (the benchmarks live and die on `pf_*` call
  overhead already) and keeps a whole dependency out of the tree.
- **Separate compilation (MODULES.md §3, future):** a module's
  `.pufi` grows `(ffi-libs ...)` and `(ffi-externs ...)` entries so
  the final link can gather archives from interface files alone.
  Designed now, shipped with `.pufi` itself.

## 8. Three implementations, honestly

The lockstep rule (reference, web, puffincc — plus the native
runtime) applies to *semantics*, and FFI semantics are inherently
native. The parity story, route by route:

- **Native (both backends, hosted `src/` and self-hosted
  puffincc):** the real thing, as specified above. Both compilers
  emit the same stubs from the same declaration tables (regenerate
  `gen-puffincc-tables.rkt` output when the manifest schema grows
  the ffi fields — the standing lockstep chore, nothing new).
- **Reference interpreter (Racket):** *optional* parity via
  `ffi-lib`'s `#:shared` clause and Racket's `ffi/unsafe` —
  `(ffi-obj-ref ...)` on the dylib, `_int64`/`_string*`/`_pointer`
  per the declared type, the same range/NUL checks reimplemented in
  the ref-impl layer (they are part of the *semantics*, so the
  interpreter must check them to stay golden-equal). A declaration
  without `#:shared` makes every call raise
  `error: regex-compile is native-only (no #:shared library declared)`
  — a defined, testable behavior, not a gap. This keeps the golden
  discipline: FFI corpus programs run on interp + chain + both
  backends when the demo libraries build both `.a` and `.dylib`
  (they will — one extra linker line in the test Makefile).
- **Web:** declared-but-unavailable, cleanly. `modules.js` parses
  the forms (programs that merely declare still load and everything
  else in them runs); applying an FFI binding raises
  `error: ffi function regex-compile is not available in the web
  runtime`. No wasm heroics in any planned version — the web REPL
  is a teaching surface, and a clean refusal teaches the boundary
  better than an emulation would.

### Phasing

1. **Manifest + scalars:** declaration forms in all three parsers;
   stub emission for `Int`/width-ints/`Bool`/`Str`/`Void`/
   `Nullable`; link collection in both drivers; `lib/foreign.c`
   with `pf_ffi_str_copy`; web/interp refusal errors.
   Exit: `tests/ffi-demo` C library green on both backends.
2. **Handles:** `define-foreign-type`, kind 18, brands, finalizer
   backstop, `#:consumes` null-on-close, `#:gift`. Exit: the §6.4
   Rust regex example runs end to end, plus a leak check
   (`GC_gcollect` in a loop, RSS flat).
3. **Interpreter parity:** `#:shared` + `ffi/unsafe`; ffi corpus
   programs join the golden runner on all routes.
4. **Callbacks:** `pf_call_closure` shims (per target), trampolines,
   pinning. Exit: `qsort` over a Puffin comparator, both targets.
5. **v2 seam items,** in whatever order need dictates: `#:include`
   cross-check (§3.6), struct declarations, `(Vec Int)` borrows,
   `Float` (blocked on flonums), `#:build`, `.pufi` fields.

### Test strategy: `tests/ffi-demo/`

A directory corpus entry (the module runner already learned
directory shapes): `cdemo/` — a 60-line C library exercising every
§3 row including the error paths (embedded NUL, out-of-range
return, NULL constructor) plus `qsort` callbacks later;
`pfregex/` — the §6.4 crate verbatim; a Makefile building
`.a` + `.dylib` for both; golden `.puf` programs per feature, run on
every route (native = real, interp = dylib parity, web = asserted
error messages — the refusals are goldens too). Negative tests in
`src/test-ffi.rkt` mirror `test-modules.rkt`: bad declarations
(unmarshallable type, `_` in an arrow, missing archive at link,
brand mismatch, use-after-close, double-close) each produce their
documented diagnostic. A `bench/` entry pitting `regex-find` against
the pl-regex Puffin engine keeps us honest about boundary overhead.

## 9. What stays out (v1)

Deep struct/union/array marshalling (§3.4's seam), floats (language
gap, stated), varargs, C++ beyond `extern "C"` shims, foreign
threads calling back, dlopen-at-runtime in native code (everything
is statically linked; the interpreter's dylib use is a test
convenience, not a language feature), any cargo/cmake orchestration
inside puffincc, and libffi. Each exclusion has a named seam; none
requires revisiting §§2–4's contracts.

## 10. Open questions for Kris

1. **Strictness dial on strings:** the `strlen == len` embedded-NUL
   check is O(n) per inbound string. Keep it unconditional (my
   vote: yes — it is the FFI's personality), or `#:unchecked` per
   argument for hot paths?
2. **`Nullable` as a type constructor** leaks a union-ish type into
   TYPES.md's grammar for FFI results only. Acceptable as an
   FFI-boundary-only form, or would you rather bless a proper
   `(Option a)` ADT crossing (wrap in `Some`/`None` at the stub —
   costs an allocation, reads beautifully in typed code)?
3. **Width annotations** `(Int #:c "int")`: in v1 as specced, or
   ship int64-only first and add widths with the §3.6 checker so
   they're verified from birth?
4. **`define-foreign-type` vs ADT unification:** when ADTs get
   their dedicated heap kind, foreign types could become
   single-constructor opaque ADTs sharing that machinery. Worth
   converging, or keep kinds 18 (foreign) and the ADT kind separate?
5. **Finalizer policy:** is the "backstop + explicit `#:consumes`"
   posture right for your daily use, or do you want a mode where a
   foreign type *requires* explicit close (finalizer merely warns
   to stderr — the Go `runtime.SetFinalizer` debugging trick)?
6. **Interpreter parity cost:** the ref-impl layer reimplementing
   marshalling checks is real work per feature. Is native-only +
   web-refusal acceptable for v1 (phases 1–2), with phase 3 parity
   gated on how much FFI code you actually write?
7. **`#:link` passthrough** is a small escape hatch with a big
   surface (arbitrary linker flags in source files). Comfortable,
   or should it be allowlisted (`-l`, `-framework`, `-L` only)?
