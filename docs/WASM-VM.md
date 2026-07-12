# Puffin in the browser: a bytecode VM, and the end of the JS interpreter

> **STATUS (2026-07-10): SHIPPED.** Everything below §STATUS is the
> original design document, kept as written; this block records what
> actually happened. All milestones landed, plus the retirement the
> design promised:
>
> - **M1** — bytecode spec (docs/BYTECODE.md, the new lockstep
>   contract) + reference backend (src/backend-bytecode.rkt) +
>   disassembler (`puffin-vm -d`).
> - **M2** — the VM in C (src/vm/puffin-vm.c), native
>   (`bin/puffin-vm`) and wasm (wasi-sdk); corpus green natively and
>   under node.
> - **M3** — puffincc's third backend (backends.puf `-t bytecode`);
>   the stage-2 fixpoint holds on the new target (puffincc-on-the-VM
>   compiles byte-identically to native puffincc).
> - **M4** — wasm packaging + the JS boundary (web/src/engine/:
>   wasi-shim.js, vm-engine.js; tools/gen-web-vm.sh).
> - **M5** — REPL sessions: `--repl` v2 link-by-name units, the
>   reactor build, session cell table; 31/31 parity steps against the
>   frozen JS-Session transcript (web/repl-golden.json).
> - **M6** — the JS interpreter is deleted (§7 step 4:
>   web/src/puffin/ is gone; prelude.js, interp.js, modules.js died
>   with it). The web engine is puffincc-on-the-VM, exclusively.
>
> The corpus grew from 294 to **300 checks** (100 programs × 3
> inputs) along the way; all suites are green on every route,
> including `node web/test-vm-corpus.mjs` (the full corpus compiled
> *by puffincc running on the wasm VM* and run per input).
>
> **Where the built system deviates from the design:**
>
> - **Run needs no reactor.** §5.1 planned one instance doing
>   compile + execute ("two `main` invocations, one heap"); shipped
>   `run()` uses **two command-model instances** sharing the shim's
>   JS-side FS (compile writes /out.pbc, a fresh instance runs it).
>   Simpler, and the second instantiation is ~1 ms.
> - **Two wasm artifacts**, not one: `puffin-vm.wasm` (command model,
>   whole-program runs and per-eval compiler invocations) and
>   `puffin-vm-repl.wasm` (reactor model, `-DPVM_REACTOR`, one
>   persistent instance per REPL session exporting
>   `pvm_boot`/`pvm_alloc`/`pvm_load_run`).
> - **REPL results are an opcode.** Instead of §5.2's
>   `host_repl_result` conclusion hook, the unit format grew a
>   version 2 (REPL) variant with named globals and a RESULT opcode;
>   results are rendered VM-side (value->string) and delivered via
>   the `puffin.repl_result` import (one stdout line natively).
>   There is also no HALT opcode: `main` ends in RET and the host
>   prints via `pf_print_result`. Details: docs/BYTECODE.md.
> - **The §3.3 collector: SHIPPED (2026-07-12).** src/vm/wasm/wasm-gc.c
>   is the designed linear-memory, non-moving mark-sweep over
>   segregated size classes, behind the same GC_MALLOC ABI the
>   scaffold satisfied — precise registered roots + a live-extent
>   frame-stack callback, conservative tracing within the heap
>   (tagged refs AND raw base pointers; on wasm32 the scan stride is
>   the *pointer* size, 4 bytes, so packed C-pointer arrays like
>   symbol_names decode), collection ONLY at dispatch-loop safepoints
>   (jumps/branches/calls — prims never collect), budget =
>   max(4 MB, live-at-last-GC). `PUFFIN_VM_GC_STRESS=1` collects at
>   every safepoint and poisons freed blocks; the full corpus passes
>   under stress (tools/gctest-corpus.sh, the CI gate). Measured: a
>   40-eval allocation-heavy REPL session holds **flat at 16 MB**
>   where the scaffold grew 16 → 252 MB; the wasm corpus run *sped
>   up* 33.7 s → 14.3 s and an alloc-heavy benchmark halved (783 →
>   ~390 ms) — freelist reuse beats never-freeing dlmalloc. The
>   native VM uses Boehm, as designed; `make -C src/vm gctest` builds
>   the native VM through the collector seam for fast iteration.
> - **Migration was compressed.** §7's two-engines-behind-a-toggle
>   phase was skipped: the corpus + REPL-parity gates ran, the JS
>   Session's observable behavior was frozen into
>   web/repl-golden.json, and the JS interpreter was deleted in the
>   same change series.
> - **§6's budgets: raw sizes over, everything else far under.**
>   Measured artifacts (2026-07-10): puffin-vm.wasm **374,954 B raw /
>   127,236 B gz** (budget ≤350 KB raw — 7% over, and the reactor
>   build adds a second ~368 KB artifact §6 didn't price in);
>   puffincc.pbc **1,439,866 B raw / 527,407 B gz** (budget ≤1 MB
>   raw — 40% over). Latency estimates were pessimistic by one to
>   two orders of magnitude — see the measured block in §6.
> - **The §11.7 kill-criterion factor, measured** (Apple M4 Pro,
>   macOS 26.5, node 23.9; details in §6): the wasm VM runs
>   compute-bound bytecode **13–20× slower than native `-O1`
>   compiled code** (native VM: 7–12×) — inside the design's 15–40×
>   envelope and nowhere near a ×40 kill. And the number that
>   mattered most never materialized: *compiling* is prim/allocation
>   dominated, so puffincc-on-the-VM compiles typical programs in
>   **2–35 ms**, not the feared 100–500 ms.
>
> **Original status:** DESIGN (2026-07-07). Nothing here is implemented. The
> design is written against the current contract (puffin.h tag scheme
> + kind registry, the 16-pass pipeline mirrored in src/ and
> puffincc-src/, the stdlib.rkt manifest, modules on every route,
> gradual types on the `gradual-typing` branch) and against the web
> surface as it exists (web/src/puffin/index.js, the two workers, the
> Pipeline visualizer). Where a number is an estimate it says so, and
> §6 shows the arithmetic.

Design goals, in order: (1) **one semantics** — the language is what
the compiler says it is, and the browser should run *that*, not a
hand-maintained parallel implementation that needs a bug hunt every
time desugar changes; (2) **true self-hosting on the web** — the
thing running in the tab should be puffincc, because a language whose
compiler runs everywhere the language runs has no second-class
platforms; (3) **the native contract is sacred** — the 61-bit tag
scheme, the kind registry, the manifest, the variadic protocol, and
the 294-golden corpus are the invariants; the VM bends around them,
never the reverse; (4) **boring technology** — no dependence on wasm
proposals that aren't universally shipped (no wasm-GC, no
exception-handling section, no wasm tail calls), one toolchain we
already use (clang), and a migration where the old and new engines
run side by side until the corpus says the new one has earned it.

## 1. Two variants, weighed

### 1.1 What we have today, honestly

`web/src/puffin/` is a ~1,850-line hand-written JS tree-walking
interpreter (interp.js 1,028 + modules.js 410 + values.js 128 +
reader.js 135 + index.js 139), plus `prelude.js` — a hand-escaped
*copy* of src/prelude.puf whose header comment admits it exists to
fail loudly when it drifts. It is good: it passes the same goldens as
the native backends, it has proper tail calls, Racket truthiness,
scope-aware prims, the module resolver, and a REPL `Session`. It is
also the fourth implementation of Puffin semantics (reference
interpreter, two native backends via one compiler, JS), and it is the
one that has already produced real bug-log entries (internal defines
only in lambda/begin bodies; quasiquote unquote order — DELTA.md §9,
MEMORY). Every language change now costs a JS-interpreter port, and
the ports are where the divergence lives. Fixnums are BigInts, so
arithmetic-heavy programs crawl. This document is about retiring it.

Both variants below agree on the enabling move: **a compact Puffin
bytecode, and a small VM for it compiled to WebAssembly.** They
differ in what runs *on* that VM.

### 1.2 Variant A: an interpreter written in Puffin, compiled once

Kris's original sketch: write `eval.puf` — a meta-circular
interpreter for Puffin, in Puffin — compile it *once, offline* with
puffincc's new bytecode backend, and ship `eval.pbc` to the browser.
User programs are read (reader.puf is already pure Puffin) and
interpreted as data.

For it:

- **Zero in-browser compile latency.** User programs start
  instantly; the interpreter walks the AST directly.
- **The REPL is trivial.** The interpreter owns an environment as
  ordinary data; persistent globals, redefinition, and result
  capture need no linking story (§5.2's machinery disappears).
- **The bytecode backend can be lazier.** It only ever has to
  compile one known program; corner cases user programs might hit
  (deep quoted data, huge literal tables) can be deferred.
- If eval.puf reuses reader.puf + desugar.puf verbatim and interprets
  the *core* language, the front half of its semantics is literally
  the compiler's — a genuinely smaller lockstep surface than the JS
  interpreter has today.

Against it:

- **It is still a parallel semantics.** Everything after desugar —
  letrec cells, truthiness at every branch, prim dispatch and
  shadowing, tail positions, variadic collection, error behavior —
  is re-decided in eval.puf. Better-placed than JS (same value
  representation, same runtime underneath), but the class of bug
  that motivated this whole exercise survives, just relocated.
- **Double interpretation.** The VM interprets eval.puf's bytecode,
  which interprets the user's AST. Each layer costs roughly an order
  of magnitude; user code lands ~10–50× slower than variant B's,
  i.e. plausibly *slower than today's JS interpreter* on arithmetic
  (BigInt tax notwithstanding, JITted JS is a fast interpreter
  substrate; our VM is not a JIT).
- **It buys none of the self-hosting story.** The compiler still
  doesn't run on the web; the Pipeline mode, `-O1` behavior, and
  "what does this compile to" teaching surface stay native-only.
- **It is not actually less work where it counts.** The VM, the GC,
  the wasm packaging, the JS boundary, and the bytecode backend —
  the hard 80% — are all required anyway, because eval.puf has to be
  compiled by *something* onto *something*. Variant A spends that
  investment on the weaker outcome.

### 1.3 Variant B (recommended): puffincc itself runs in the browser

puffincc gains a third backend target, `bytecode`, alongside x86-64
and arm64. The build compiles **puffincc itself to bytecode**
(`puffincc -t bytecode puffincc-src/main.puf -o puffincc.pbc`) —
stage 1 of the existing bootstrap, retargeted. The browser loads the
VM (one wasm module) plus `puffincc.pbc`; when the user hits Run,
puffincc-on-the-VM reads, resolves modules against the virtual file
map, compiles the program *to bytecode in memory*, and the VM loads
and runs the result. One compiler, one semantics, on every platform
it has.

For it:

- **The JS interpreter's entire raison d'être evaporates.** The
  semantics in the tab are the compiler's semantics, including the
  `-O1` contract/optimizer behavior if we want it, the exact
  variadic/papp protocol, the exact error messages. The lockstep
  chore list gets *shorter*: prelude.js dies, interp.js dies,
  modules.js dies (modules.puf takes over, fed by the same virtual
  file map).
- **User code runs compiled**, one interpretation layer above the
  metal instead of two. Estimated 5–20× faster than the current JS
  interpreter on compute-bound code (§6).
- **True web self-hosting** — the compiler-compiling-itself demo
  runs in a browser tab, which is worth something to this project
  beyond engineering.
- **Variant A comes free later.** Once puffincc runs on the VM, an
  eval-in-Puffin library is just another Puffin program to compile,
  useful for instant-feedback modes if compile latency ever hurts.

Against it, honestly (details in §9):

- **In-browser compile latency.** Native puffincc compiles the
  largest corpus program in ~57 ms; on the VM expect 15–40× that —
  worst case a couple of seconds, typical examples a few hundred ms
  (§6, with mitigations: precompiled prelude unit, compile in the
  worker with a spinner).
- **The REPL needs a real design** (persistent globals across
  separately compiled units — §5.2), which touches collect-globals /
  reveal-functions in both compiler sources. Variant A gets this for
  free.
- puffincc needs its I/O prims (read-file, read-all, display,
  command-line-args) to work against a browser host — §3.5's shim,
  which is work variant A needs only partially.

### 1.4 A third variant, considered and rejected

Compiling user programs **directly to wasm** (a fourth native-style
target) was considered: it founders on (a) GC — wasm modules in
linear memory need exactly the collector the VM needs anyway, with
none of the VM's explicit-root advantages; (b) control flow — wasm
requires *structured* control flow, and explicate-control emits
arbitrary CFGs, so render would need a relooper, a genuinely hard
pass neither backend has; (c) per-run `WebAssembly.instantiate`
latency and browser codegen limits for large programs. A bytecode VM
sidesteps all three: unstructured `goto` is one opcode, and loading a
unit is a memcpy. If Puffin ever wants a *server-side* wasm target
(WASI CLI distribution), that is a separate design with a relooper in
it; nothing here precludes it.

### 1.5 Recommendation

**Variant B.** It is the strictly stronger endpoint for at most
modestly more work (the REPL linking design and the I/O shim), and it
converts the web from Puffin's most divergence-prone implementation
into a first-class consumer of the self-hosted compiler. The rest of
this document designs it. Where variant A shares a component (the
bytecode, the VM, the GC, the packaging — §§2–3, most of §6–8), the
design serves both, so choosing A later would discard only §4's REPL
mode and half of §5.

## 2. The bytecode

### 2.1 Value representation: the tag scheme survives wasm32 intact

A Puffin value stays a tagged 64-bit word — `pf` remains `int64_t` —
on wasm32:

- **Fixnums are `n << 3`, 61-bit signed, exactly as native.** This is
  non-negotiable: golden outputs, overflow behavior, and the
  `+`/`-`/`eq?`/`<`-work-tagged property must be bit-identical to the
  native backends or the corpus stops being one corpus. wasm has
  native i64 arithmetic; there is no BigInt tax inside the VM (the
  tax moves to the JS *boundary*, crossed only for I/O).
- **Heap references are `address | 1`** where the address is a wasm32
  linear-memory offset (< 2^32), stored in an i64 word whose high 32
  bits are zero. `pf_heap_ptr` truncates i64 → pointer, which is
  exactly the cast `(int64_t *)(v - PF_TAG_HEAP)` already performs —
  on wasm32 it compiles to `i32.wrap_i64`. One caveat to patch:
  `pf_heap_ref` casts through `intptr_t` (32-bit on wasm32), which
  would *sign-extend* addresses above 2 GB; route it through
  `uintptr_t` instead (a one-line, native-safe change to puffin.h)
  or cap the VM heap at 2 GB. Do both.
- Immediates (`#f`=2, `#t`=10, void=18, `'()`=26), symbols
  (`id << 3 | 3`), headers (`len << 8 | kind`), kind ids (1–6 core,
  16/17 HAMTs), Racket truthiness: **unchanged, byte for byte.** The
  whole point is that lib/*.c compiles as-is (§3.2).

The cost of i64 values on a 32-bit memory is 8 bytes per slot where 4
would often do. Accepted without ceremony: it buys source-identical
runtime code and semantics, and the playground's heaps are small.

### 2.2 The cut point: after uncover-locals

Where does the bytecode backend tap the pipeline? The candidates:

- **After anf-convert** (stack machine): compile ANF directly to a
  stack bytecode. Smaller instructions, classic design — but it
  discards explicate-control (tail-call discovery, `main` untailing,
  the `-O1` loop recovery and blocks cleanup) and uncover-locals,
  re-deciding tail positions and control flow in the new backend.
  Everything explicate-control settles would need settling again,
  divergently.
- **After uncover-locals** (register/slot machine — **recommended**):
  the IR here is
  `(program info (define locals (f params ...) blocks) ...)` with
  `blocks` a label→tail map over
  `seq/assign/effect/global-set!/return/goto/if-cmp/tail-app` and
  rhs forms that are prim applications, `app`/`papp`, `fun-ref`,
  `global-ref`, `string-lit`, closures-as-vectors, and atoms. Every
  variable is a named local with function scope, enumerated in the
  `locals` set. This maps 1:1 onto a frame-slot bytecode: **a local
  is a slot index, an assign is an instruction, a tail is a branch.**
  The three-address shape is already there; "instruction selection"
  is a structural transcription, and every pass the two native
  backends share keeps paying rent — including diff-ir as the
  differential oracle for the new backend's frontend half.
- **After allocate-registers**: pointless — physical registers and
  spill frames model an ISA the VM doesn't have. Register allocation
  *is* the thing a VM frame makes unnecessary.

So: **register (frame-slot) bytecode, cut after uncover-locals.**
The backend chain mirrors the native ones in shape (§4), which also
keeps the Pipeline visualizer's layer model intact.

One deliberate consequence: `limit-functions` and the packed-call
protocol (`papp`, packing strictly above 6 args) stay in the frontend
**unchanged**, even though a VM has no six-register limit. The VM's
call convention mirrors the native one — ≤6 direct argument slots,
extra args packed in a vector, logical arity carried alongside — so
`pf_collect_rest` compiles verbatim and variadic semantics are
provably the same code path as native. Elegance loses to parity.

### 2.3 The instruction set (sketch)

Variable-length encoding: one opcode byte, then operands. Slots are
u16 (a function with >65k locals has other problems); jump targets
are s32 byte offsets after linearization; constants live in per-unit
pools. Roughly 40 opcodes:

```
;; data movement
MOV       d, s               ; slot <- slot
IMM       d, k64             ; slot <- tagged immediate (fixnum/bool/void/nil)
IMM8      d, k8              ; common small tagged constants
SYM       d, symidx          ; slot <- tagged symbol (unit table; patched at load, §2.5)
STR       d, stridx          ; slot <- interned string constant (pf_string_const path)

;; intrinsics (exactly the ops select-instructions open-codes)
NEG d,a   ADD d,a,b   MUL d,a,b          ; tagged arithmetic, native overflow behavior
LT  d,a,b EQ  d,a,b                      ; tagged compare -> #t/#f

;; control (blocks linearized; every explicate-control tail form appears)
JMP       off
BRF       s, off             ; branch if slot = #f   (the (eq? a #f) if-tail)
BRLT      a, b, off          ; fused compare-branch  (the -O1 if-cmp tails)
BREQ      a, b, off
RET       s

;; calls (§2.4: base = first argument slot; args contiguous)
CALL      d, fidx, base, nargs, arity    ; direct   (app/papp (fun-ref f) ...)
CALLI     d, fs,   base, nargs, arity    ; indirect (closure value in slot fs)
TCALL     fidx, base, nargs, arity       ; direct tail call: frame reuse
TCALLI    fs,   base, nargs, arity
PRIM      d, primid, base, nargs         ; manifest prim: direct C call via table
COLLECT   d, kfixed                      ; variadic prologue: build #%rest list

;; heap the compiler controls (closures; checked variants stay prims)
CLO       d, size            ; pf_make_closure
UGET      d, a, i8           ; unsafe-vector-ref  (closure slots, packed args)
USET      a, i8, s           ; unsafe-vector-set!

;; globals
GGET      d, g               ; g is a unit-local global index, bound at load (§5.2)
GSET      g, s

;; misc
HALT      s                  ; main's conclusion: pf_print_result + stop
```

Notes:

- **Open-coded prims** (`car`, `cdr`, `vector-ref`, `pair?`, ...) do
  *not* get opcodes in v1. At `-O0` they are `PRIM` calls, same as
  the native `-O0` route; the VM's prim table is generated from the
  same stdlib.rkt manifest that drives everything else (the
  derived-views discipline extends: the manifest gains nothing, the
  table generator gains one output). If profiling later justifies it,
  hot prims become opcodes one at a time — the seam is the same
  `#:when (open-code-prims?)` seam the native backends use.
- **The dispatch loop owns safepoints** (§3.3): GC may run between
  instructions, never within one.
- A **disassembler ships with the assembler** from day one
  (`puffin-vm -d unit.pbc`); it is the debugging surface that
  replaces reading .s files, and M1's gate depends on it.

### 2.4 Calls, closures, variadics, tail calls

**Frames.** A frame is `[header | slot 0 .. slot n-1]` on a growable
frame stack in linear memory (not the C stack). `nlocals` comes from
the function table; formals occupy the first slots. Frame overflow
grows the segment — the native builds reserve 512 MB of stack for
deep non-tail recursion (map is non-tail); the VM equivalent is a
frame stack that grows toward the wasm 4 GB ceiling, with a
configurable depth limit so runaway recursion errors like native
does rather than OOMing the tab.

**Calling convention.** The caller stages arguments in contiguous
slots (`base..base+nargs-1`) of its own frame; `CALL` copies them
into the callee frame's formal slots (or aliases them via
overlapping frames later — an optimization, not v1). `arity` is the
*logical* argument count, the VM register that replaces native
r10/x12: variadic callees read it, and packed calls carry
`arity > 6` with `nargs = 6` and slot `base+5` holding the packed
vector — precisely the native protocol, so `COLLECT` can call
`pf_collect_rest` after spilling the six argument values to
`pf_arg_spill`, which compiles unchanged and is scanned as a root
exactly as its comment already promises.

**Closures** keep kind 4 and their layout: header + slot 0 + captured
values, allocated by `CLO` via `pf_make_closure`, slots read with
`UGET` — but slot 0 holds a **function index** (tagged fixnum into
the unit's function table) instead of a raw code pointer. `CALLI`
checks the kind, reads slot 0, and dispatches. Raw code pointers
must not appear in heap values: units come and go (REPL), and a
fixnum index is GC-inert and serializable. The one place codegen
knows closure layout today (slot 0, `unsafe-vector-ref`) is the one
place the bytecode backend differs.

**Proper tail calls are mandatory and structural.** `TCALL`/`TCALLI`
evaluate arguments into the caller's staging slots, then overwrite
the current frame's formals and resize/reuse it — constant stack by
construction, for *all* tail calls including mutual recursion and
closure calls, exactly matching the native `tail-jmp` guarantee.
`main` stays exempt (explicate-control's `untail` already runs before
our cut point, so the backend never sees a tail-app in `main`). This
does **not** depend on the wasm tail-call proposal: the VM loop is a
loop; frame reuse is arithmetic.

**Loop recovery and blocks cleanup** (`-O1`) arrive free: they run
before the cut point, so self tail calls are already `goto`s when the
backend sees them.

### 2.5 Symbols, gensym, and the unit format

A compiled program is a **unit** (`.pbc`), the loadable object:

```
header    magic "PUF\1", version, target-check word
symtab    n, then n names          ; every symbol literal in the unit
strtab    n, then n byte strings   ; string-lit pool (byte strings, embedded NULs fine)
globals   n, then n mangled names  ; unit-local index -> name (§5.2 links by name)
funcs     n, then per function:
            name (diagnostics), nformals, variadic? (+kfixed), nlocals,
            code offset, code length
entry     function index of main
code      the instruction stream
```

- **Symbols intern at load.** The compiler assigns symbol ids from
  its sorted literal table (bk-scan-literals), but ids are *unit-
  relative*: the loader interns each symtab name through
  `pf_intern_symbol` (which already exists and already dedups) and
  **patches every `SYM` operand once** to the VM-global id. Two
  units loaded into one session therefore agree on `eq?` for symbols
  — the same promise MODULES.md §3 makes for separate native
  compilation, delivered by the same mechanism (runtime interning).
- **gensym is `pf_gensym`, unchanged**: it interns
  base+counter names, skipping taken ones, with a VM-global counter
  — so gensyms from different REPL units never collide, and
  read-back survives, exactly as native.
- **Strings** are byte strings in the pool; `STR` goes through the
  `pf_string_const` cache path (one heap string per literal per
  unit, lazily).
- Quoted **structured** data needs nothing: desugar has already
  lowered `'(a 1 "s")` to cons/string-lit constructors before the
  cut point.
- The unit format is **not** a stable serialization contract in v1:
  it is versioned, and the VM refuses mismatches. The compiler and
  VM ship together; nothing archives .pbc files yet.

Since Puffin strings are byte strings and `write-file` writes bytes,
**backends.puf can render this binary format directly** — `render`
builds the unit as a byte string. No new I/O machinery.

## 3. The VM

### 3.1 Implementation language: C, compiled with wasi-sdk

The options:

- **Hand-written WAT.** Total control of output size; also thousands
  of lines of untyped stack assembly for a component with a GC in
  it. The VM will be rewritten twice before it is right; WAT makes
  every rewrite a fresh injury. No.
- **Rust.** A fine VM language in general, but here it is a second
  toolchain, a std-shaped binary floor, and — decisively — an FFI
  boundary against the C runtime it must call into ~80 times
  (every manifest prim). The FFI design (FFI.md §6) treats Rust as a
  guest for *leaf* libraries precisely because boundary crossings
  are where bugs live; putting the VM↔runtime boundary through it
  inverts that logic. No.
- **C (recommended).** The VM and the runtime become **one
  compilation unit**: the dispatch loop calls `pf_cons` the way
  core.c does, includes puffin.h, and inherits the tag scheme from
  the single header that defines it. One toolchain (clang, already
  the project's assembler/linker), one language for all runtime
  code, and the native-build story (§8, M2) is `cc` with a different
  target flag. The VM is an interpreter loop, a loader, and a GC —
  ~2,000–3,000 lines of exactly the C this project already writes.

Toolchain: **wasi-sdk** (clang targeting `wasm32-wasi`) rather than
Emscripten. Emscripten earns its keep when you need its ports
(Boehm, SDL), its JS glue, or Asyncify; §3.3 removes the Boehm need,
§3.4 removes the unwinding need, and the remaining host surface is
small enough that a purpose-built shim (§3.5) beats a generic
runtime by hundreds of KB. Dispatch uses computed goto
(labels-as-values — clang lowers it to `br_table` on wasm); a
portable `switch` fallback stays behind an `#ifdef` for MSVC-less
lives and debugging.

The same source compiles **natively** (`bin/puffin-vm`) with plain
clang; the native build is the primary development target, gets the
corpus first (§8), and — bonus — gives Puffin a fast-startup
portable execution route on machines without the assembler
toolchain.

### 3.2 The C runtime's fate: hosted, not replaced

The runtime is small and the VM should treasure that: core.c is 311
lines, lib/*.c ≈ 1,020 (arith 49, pairs 49, vectors 70, strings 118,
hashes 114, sets 84, hamt 342, table 64+h, io 93, predicates 12,
stdlib_init 24). **All of it compiles for wasm32 as-is**, with these
exceptions, each a seam not a rewrite:

| Native piece | wasm build |
|---|---|
| Boehm (`GC_MALLOC`, `GC_MALLOC_ATOMIC`) | replaced behind `pf_alloc`/`pf_alloc_atomic`/`pf_alloc_raw` by §3.3's collector — those three entries were the whole allocation ABI all along |
| `pf_fatal`/`pf_error`/`exit` | host abort import; §3.4 |
| `pf_read_int`/`pf_read_all` (scanf/fread on stdin) | wasi-libc fd 0 against the shim's stdin buffer — code unchanged |
| lib/io.c `read-file`/`write-file`/`system` | fopen against the shim's in-memory FS (the module file map); `system` returns the documented web refusal error |
| `open_memstream` (value->string) | provided by wasi-libc's musl stdio; **verify in M2**, else a 20-line memstream fallback |
| `__attribute__((constructor))` argv capture | loader passes argv explicitly (REPL/compile invocations construct it anyway) |

The rule that matters: **the wasm runtime is the same source files.**
No `#ifdef` forests — the platform differences live in the allocator
module, the host-abort module, and the shim. lib/*.c must not learn
it is in a browser.

`pf_print_result`, display formatting, error message texts: all
identical, because the corpus diff is textual and the corpus is the
gate at every stage.

### 3.3 GC: the Boehm question, answered with safepoints

> **SHIPPED (2026-07-12), as designed, stress-gated.** The collector
> below is implemented in src/vm/wasm/wasm-gc.c (its header comment
> is the as-built reference). Deltas from this section's sketch:
> (a) roots are *fully registered* — the runtime's pf-holding statics
> (core.c's symbol_names/string_const_cache/pf_arg_spill, hamt.c's
> empty-singleton cells) register themselves via GC_add_roots, so the
> native gctest build needs no data-segment scan; the wasm build
> scans [__global_base, __data_end) *as well*, as belt-and-suspenders;
> (b) the VM exposes the frame stack's LIVE extent through a
> pvm_gc_frame_roots callback instead of whole-chunk regions, which
> is what makes stress mode tractable; (c) in-heap tracing recognizes
> raw base pointers (tag 000) in addition to tagged refs — hamt nodes
> and table slot arrays are reachable only through such words — and
> on wasm32 scans at 4-byte (pointer-size) granularity; (d) freed
> blocks are poisoned (0xAB) under stress. The stress corpus gate is
> the third leg of tools/gctest-corpus.sh.

The strategies considered:

**Host JS GC via externref / wasm-GC** — represent Puffin values as
JS objects or wasm-GC structs and let V8 collect them. Rejected
outright: it abandons the tag scheme (fixnums stop being 61-bit
words; `eq?`, hashing, and HAMT layout all diverge), discards every
line of lib/*.c, and reintroduces exactly the parallel-runtime
maintenance this design exists to end. It is the JS interpreter with
extra steps. (wasm-GC also fails the boring-technology bar for another
year or so.)

**Boehm compiled to wasm** — bdwgc has Emscripten support, but its
soundness on wasm hinges on scanning the stack, and *wasm locals are
not memory*: a pointer held only in a wasm local is invisible to any
scanner. Emscripten's answer is Binaryen's `--spill-pointers` pass,
which spills pointer-typed i32 locals to the shadow stack — but
Puffin values are **i64 tagged words, not pointer-typed**, so
spill-pointers does not know to spill them, and a `pf` held in a
wasm local across a collection is a use-after-free. Making Boehm
sound here means auditing codegen output or forcing everything
through memory with volatile tricks. That is a research project
wearing a dependency's clothes. Rejected.

**Linear-memory mark-sweep with safepoint discipline
(recommended).** The VM changes the problem: unlike compiled native
code, an interpreter *knows where all the values are*. Design:

- **Heap:** non-moving mark-sweep over segregated size classes in
  linear memory, `memory.grow` to expand. Non-moving preserves
  `eq?`-as-address, interior-pointer tagged refs, and every layout
  assumption lib/*.c makes. An allocation header bit distinguishes
  atomic payloads (strings) — the existing
  `pf_alloc`/`pf_alloc_atomic` split, kept.
- **Roots, exactly:** (1) the VM frame stack and staging slots —
  every slot is a `pf`, scanned precisely; (2) the global table
  (§5.2); (3) the wasm data+bss segment `[__global_base, __data_end)`
  scanned conservatively — this covers core.c's statics
  (`symbol_names`, `string_const_cache` pointer, `pf_arg_spill`)
  with zero source changes, mirroring Boehm's static-data scan;
  (4) a pin table for the JS boundary, if we ever hold values across
  host calls.
- **Tracing:** conservative *within the heap* — non-atomic payloads
  and `pf_alloc_raw` blocks are scanned word-by-word; a word that
  decodes as `addr|1` into a live block marks it. This is Boehm's
  trick with Boehm's soundness argument, minus the part Boehm can't
  do on wasm (C stack scanning). No per-kind trace hooks, no
  changes to hamt.c's node building or table.c's raw slot arrays.
- **The safepoint rule, which makes it sound:** collection runs
  *only* in the dispatch loop, between instructions, when the
  allocation budget is exceeded. Prims and runtime helpers **never
  trigger GC**: `pf_alloc` inside a prim takes from the current
  budget or grows memory, and the deficit is settled at the next
  safepoint. Therefore a `pf` held in a C local (equivalently, a
  wasm local) mid-prim — hamt.c building a node chain, strings.c
  mid-append — is *never* live across a collection, because prims
  return before the loop reaches a safepoint. The unscannable-locals
  problem is not solved; it is made unreachable.
- Failure mode, stated: a single prim allocating unboundedly (a
  `make-vector` of 2^30) grows memory rather than collecting first —
  the same behavior class as native Boehm under a huge single
  allocation. Acceptable.
- **Stress mode is non-negotiable:** `PUFFIN_VM_GC_STRESS=1` collects
  at *every* safepoint; the corpus runs under stress in CI (§8, M2
  gate). A conservative collector's bugs are silent until they
  aren't; stress + 294 goldens is how we buy sleep.

Estimated size: ~400–600 lines of C. It is the scariest component in
this document and it is still smaller than hamt.c plus its test
surface was.

### 3.4 Errors that don't kill the tab

Native `pf_fatal` is `exit(255)` and `(error v)` is print +
`exit(1)`; a browser session must survive both, and the REPL must
keep its globals afterward. Mechanism, without setjmp and without the
wasm exception-handling proposal:

- The wasm build's `pf_fatal`/`pf_error` print through the normal
  output path (golden parity: the `error: ...` line is part of
  program output), then call an imported host function
  `host_abort(code)`, which **throws a JS exception**. A JS
  exception thrown from an import unwinds all wasm frames — core
  wasm behavior, universally shipped.
- The JS boundary catches it, and the engine **resets the VM's
  execution state** (frame stack pointer, staging slots) in linear
  memory — trivially possible because that state is data, not wasm
  frames. The heap, symbol table, and global table survive: a REPL
  error behaves like the JS Session's `PuffinHalt` today (results so
  far are kept, session continues).
- One rule inherited by all runtime code: **no runtime function may
  hold non-memory state that matters across a fatal error.** True
  today (prims are leaf calls); the VM keeps it true by construction.

This is strictly better than native semantics require, and it costs
one import.

### 3.5 The host shim (stdin/stdout/files), ~300 lines of JS

wasi-libc wants a WASI-shaped host. Rather than a full generic
polyfill, a purpose-built shim implements the handful of syscalls the
runtime actually reaches: `fd_write` (1/2 → `onOutput`, streamed
synchronously), `fd_read` (0 ← the stdin buffer), `path_open`/
`fd_read`/`fd_write` against an **in-memory FS initialized from the
module file map** — which is how puffincc's `read-file`-based module
resolution works unchanged in the browser — plus `proc_exit` (throws,
§3.4), `clock_time_get`, and stubs that return `ENOSYS` loudly.

- **stdin:** the boundary accepts what the app has today (`input:
  number[]`) and renders it as whitespace-separated text into the
  stdin buffer, so `scanf`-based `read` and `read-all` behave
  natively; a raw-text form (`stdin: string`) is also accepted for
  reader-based programs.
- **stdout streaming:** `fd_write` invokes `onOutput` synchronously;
  the existing run-worker buffering (8 KB / 50 ms flush) already
  handles flood control and stays exactly as is.
- **Cancellation** stays `worker.terminate()` + respawn, unchanged
  from today. (A cooperative fuel check at safepoints is a cheap
  later nicety; SharedArrayBuffer-based interrupts need COOP/COEP
  headers and are explicitly not v1.)

## 4. puffincc's third backend

The reference implementation (src/) grows the backend first — that is
where diff-ir, provenance, and fast iteration live — then
backends.puf ports it, per the standing lockstep discipline. What the
four backend passes become for target `bytecode`:

- **select-instructions-bc** — the structural transcription of §2.2:
  walk each definition's blocks, `h-atom` maps atoms to
  `imm/sym/str/slot` operands, each assign/effect/tail form to the
  §2.3 instruction (symbol/string literals collected by the existing
  `bk-scan-literals`). The variadic prologue emits `COLLECT`; the
  `pair?`/`vector?` block-splitting and trap-block machinery of the
  native backends **does not exist** (no open-coding at v1: prims are
  `PRIM`). It is the smallest of the three select passes by a
  multiple.
- **allocate-slots** — replaces allocate-registers: number the
  `locals` set (sorted, for deterministic output — the bootstrap
  fixpoint discipline extends to .pbc bytes), formals first; emit
  `nlocals`. No liveness, no interference, no spills. A later
  optimization may reuse dead slots via the existing live-interval
  hulls to shrink frames; explicitly not v1.
- **patch-instructions** — becomes **linearize**: order blocks
  (entry first, then a DFS order that favors fall-through), resolve
  label references to byte offsets, fuse `if-cmp` tails into
  `BRLT`/`BREQ` + `JMP`. No register staging, no imm64 splitting, no
  sp-adjust arithmetic.
- **prelude-and-conclusion** — mostly dissolves: no callee-save
  areas, no stack probes. What remains is per-function metadata
  (function-table rows) and `main`'s `HALT` conclusion.
- **render-bc** — binary encoding of the §2.5 unit into a byte
  string (Puffin strings are byte strings; `write-file` writes
  bytes). The hosted route writes `.pbc` where it writes `.s` today;
  `-o prog.pbc` skips the clang link step entirely.

Estimated size: ~350–500 lines in backends.puf vs ~640/650 for each
native backend. Tables: gen-puffincc-tables.rkt grows the primid
table (manifest-derived, same generator run — the standing lockstep
chore, nothing new). diff-ir already takes a target argument; it
gains `bytecode` and remains the differential oracle for every
frontend pass plus select/allocate (the encoded unit is compared via
the disassembler).

**REPL compilation mode** (used by §5.2): a driver flag under which
collect-globals treats *every* top-level define — functions included
— as a named global cell, reveal-functions reveals nothing across
the top level (all top-level calls go through `GGET` + `CALLI`), and
free variables that are neither locals nor prims become late-bound
`GGET`s by name instead of errors. Units compiled this way always run
at `-O0`. This is a real, contained change to two passes in both
compiler sources; it is the one place variant B touches pass code,
and it is called out in §11 because Kris should sign off on it
specifically. Cells need an *unbound* sentinel distinct from the
current seed of fixnum 0 — reserve immediate 34 (`#<undef>`) in the
wasm/VM globals table; `GGET` of an unbound cell errors with the
variable's name. Whole-program mode is unaffected (collect-globals
keeps erroring on genuinely unbound names at compile time).

## 5. The JS boundary API

### 5.1 One engine interface

The current index.js surface is nearly right and the workers already
isolate it; it becomes the **engine interface**, implemented twice
during migration (§7):

```js
// web/src/engine/index.js -- the only import App/workers use
run(source, { input, stdin, onOutput, files, entry })
  -> { ok: true, value: string | null } | { ok: false, error: string }
class Session {
  constructor({ input, stdin, onOutput })
  eval(text) -> { ok, results: string[], error? }
}
defaultInput(), render, surfacePrimNames, ModuleError, ...
```

The VM engine implements it as:

- **Boot (once per worker):** instantiate `puffin-vm.wasm`, load
  `puffincc.pbc` and the precompiled `prelude.pbc` (§6).
- **run():** write source + file map into the shim FS; invoke
  puffincc's entry with argv `["puffincc", "-t", "bytecode",
  "-o", "/out.pbc", "/main.puf"]`; load `/out.pbc`; run it with a
  fresh globals table. Compile and execute happen in the same VM
  instance — two `main` invocations, one heap. Errors from either
  phase surface via §3.4 and map onto today's `{ok:false, error}`.
- **Prelude injection** happens inside puffincc (main.puf's
  `prelude-inject`), not in JS: prelude.js is deleted, and the drift
  class it represents dies with it.

The interface deliberately keeps `input`/`onOutput`/`files`/`entry`
shapes identical so run-worker.js and repl-worker.js change only
their import path.

### 5.2 REPL sessions: linking by name

Today's Session is an interpreter environment; the VM Session is a
**link-by-name unit loader**:

- The VM keeps a session-global table: mangled name → cell (a `pf`
  slot, GC root). Loading a unit resolves each unit-local global
  index against this table, creating unbound cells on demand
  (§4's sentinel).
- `Session.eval(text)`: compile the new forms as one **REPL-mode
  unit** (§4) with puffincc-in-the-VM; load; run its `main` (which
  contains only the *new* forms' initializers and expressions —
  nothing re-executes). Top-level expression results are delivered
  through a `host_repl_result(v)` hook the REPL-mode conclusion
  calls instead of `pf_print_result`, rendered via `value->string`
  on the VM side so formatting is the runtime's own.
- **Redefinition** works like the JS Session: defining `f` again
  stores a new closure in the same cell, and every earlier unit's
  `GGET f` sees it — because REPL mode compiles all top-level calls
  as indirect (§4). This matches interpreter semantics exactly,
  which whole-program `-O1` direct calls would not; hence the
  REPL/whole-program mode split.
- The prelude loads once per session as a REPL-mode unit
  (precompiled at build time); user definitions shadow by
  redefinition, mirroring today's Session behavior.
- Session reset = discard the globals table + heap (or cheaper:
  respawn the worker, which is what the app does today anyway).

Cost stated plainly: per-eval compile latency (~tens of ms for
typical REPL entries on the VM — a one-liner is a small unit; the
prelude is *not* recompiled). Acceptable for a REPL; measured at M5.

### 5.3 The pipeline visualizer

Pipeline mode's provenance (`back` edges, breadcrumbs) is built on
Racket-side object identity: a weak eq-hash tagging every constructed
node, composed across passes by feeding each pass's literal output
object to the next. **puffincc cannot reproduce this cheaply** — the
bootstrap deliberately dropped prov wrappers, Puffin hashes are
equal?-keyed with no weak references, and retrofitting explicit
origin ids through 16 passes is a redesign of every walker.

So, honestly: **Pipeline mode stays served by src/ir-server.rkt**
(unchanged — it is a dev-mode tool that already requires a local
Racket process, and its API contract with Pipeline.jsx is untouched
by everything above). Two cheap improvements ride along later,
neither gating anything: (a) ir-server grows the bytecode backend's
layers automatically once src/ has them (the pass-table plumbing is
generic, and select/linearize/render-bc slot into the existing layer
model, with the disassembly as the terminal `lineBack` layer);
(b) a provenance-free "layers only" trace from puffincc's existing
`serialize-ir`/dump-after machinery could someday power a degraded
in-browser pipeline view — recorded as an idea, not designed here.

### 5.4 Boundary summary

| Need | Mechanism |
|---|---|
| compile+run | shim FS + puffincc.pbc invocation, in-worker |
| streaming stdout | `fd_write` → `onOutput`, existing worker buffering |
| stdin | `input: number[]` rendered to text, or raw `stdin: string` |
| module file maps | shim in-memory FS; puffincc's own resolver |
| REPL persistence | session globals table + link-by-name units |
| REPL results | `host_repl_result` hook, `value->string` rendering |
| errors | `host_abort` throw → `{ok:false,error}`; VM state reset |
| cancellation | `worker.terminate()` + respawn (unchanged) |
| pipeline traces | ir-server.rkt, unchanged (dev-mode) |

## 6. Size and startup budgets

Estimates with their arithmetic; **numbers marked (m) are measured
today, others are estimates to be validated at the marked
milestone.**

| Artifact | Estimate | Basis | Budget (gate) |
|---|---|---|---|
| puffin-vm.wasm | 150–300 KB raw, 50–100 KB gz | VM ~2.5k lines + runtime ~1.3k lines (m) + wasi-libc stdio/malloc; no Emscripten runtime | ≤ 350 KB raw (M4) |
| puffincc.pbc | 300 KB–1 MB, 100–300 KB gz | flattened source 133 KB (m); native .o 1.8 MB (m), asm text 6.1 MB (m); bytecode ≈ 3–8× denser than native code | ≤ 1 MB raw (M4) |
| prelude.pbc | 10–40 KB | prelude is a small fraction of puffincc | — |
| shim + engine JS | 10–20 KB | ~500 lines | — |
| **Total added** | **~0.5–1.3 MB raw** | vs ~60 KB for the JS interpreter it replaces | lazy-loaded on first Run |

Startup and latency:

| Event | Estimate | Basis |
|---|---|---|
| wasm instantiate + .pbc load | 30–150 ms | streaming compile of ≤1.3 MB; load = memcpy + symbol interning |
| compile typical example on VM | 100–500 ms | native 3–57 ms (m) × 15–40 (VM interpretation factor, the honest unknown — measured at M2) |
| compile largest corpus program | 1–2.5 s | 57 ms (m) × 15–40 |
| REPL eval (one form) | 10–100 ms | small unit; prelude precompiled |
| user-code speed vs JS interpreter | 3–20× faster (compute-bound) | i64 fixnums vs BigInt tree-walking; measured head-to-head at M5 with bench/ pairs |
| user-code speed vs native | 15–40× slower | classic bytecode-VM range for this design (no JIT); fib35 ≈ 4–10 s vs 0.25 s (m) native |

### §6-measured (2026-07-10) — the estimates above, validated

Apple M4 Pro, macOS 26.5; node v23.9.0 for the wasm rows; wasi-sdk 33
(`-O2`, switch dispatch); everything built from this tree
(`make -C src/vm wasm wasm-repl`, `tools/gen-web-vm.sh`). Native and
native-VM rows are whole-process wall time, best of 5 (≈2 ms process
startup included); wasm rows time `_start` only on a fresh instance
of a pre-compiled module, best of 3–5.

Artifacts vs budgets:

| Artifact | Measured raw | gzip -9 | Budget | Verdict |
|---|---|---|---|---|
| puffin-vm.wasm (command) | 374,954 B | 127,236 B | ≤ 350 KB raw | **7% over** |
| puffin-vm-repl.wasm (reactor) | 368,488 B | 125,504 B | (not budgeted) | second artifact, §STATUS |
| puffincc.pbc | 1,439,866 B | 527,407 B | ≤ 1 MB raw | **40% over** |
| **Total added** | **~2.18 MB raw** | **~780 KB gz** | ~0.5–1.3 MB raw | over raw, lazy-loaded; gz is what the wire sees |

Interpretation factor (same .pbc on `bin/puffin-vm` vs under node
through the WasiShim, against `build/puffincc`-compiled native `-O1`):

| Workload | native -O1 | native VM | wasm VM (node) | nVM / wasm factor |
|---|---|---|---|---|
| fib(30) | 6.7 ms | 45 ms | 72 ms | 6.7× / 10.7× |
| fib(35) | 40 ms | 460 ms | 820 ms | 11.5× / 20× |
| tail-loop 20M adds | 45 ms | 317 ms | 593 ms | 7.0× / 13.2× |
| HAMT 200k insert+lookup | 109 ms | 125 ms | 1,309 ms | 1.15× / 12× |

So: **7–12× (native VM) and 13–20× (wasm VM) on compute-bound
code** — inside the 15–40× envelope, well clear of a ×40 kill
(§11.7). Two notes the estimates missed: (a) prim-dominated work
(HAMT) is nearly native speed on the native VM because the time is
in the C runtime, not the dispatch loop; (b) the same workload is
~10× worse on the *wasm* build — allocation-heavy code paid for the
scaffold allocator (calloc + never-free + memory.grow); the §3.3
collector roughly halved alloc-heavy wasm times (a 4M-pair
build/consume benchmark: 783 → ~390 ms) and cut the full wasm corpus
run from 33.7 s to 14.3 s. (fib35 native measured 40 ms here vs the
0.25 s (m) above — that older number predates `-O1` and this
machine.)

In-browser-equivalent Run latency (puffincc-on-the-wasm-VM, `_start`
timed, compile to /out.pbc): hello-world **2 ms**, small typed
program **3–4 ms**, fib **33 ms**, the HAMT program **6 ms** — vs
the 100–500 ms estimate. Compilation is prim/allocation-bound (reader,
HAMTs, strings), which the VM executes as native C, so the compiler's
effective interpretation factor is ~1.2–2×, not 15–40×. End-to-end
`run()` (compile + instantiate + execute) under node: hello **2–3 ms**,
fib(30) **~100 ms** (of which ~72 ms is running fib(30) itself).

REPL (engine Session over the reactor build, per test-vm-repl.mjs's
path): first-ever boot including wasm module compile **~165 ms**;
session boot + first eval with warm modules **2–4 ms**; per-eval
**1.5–8 ms** for one-liners through a 100k-iteration loop — vs the
10–100 ms estimate.

Full `node web/test-vm-corpus.mjs` (every corpus program compiled by
puffincc-on-the-VM and run per input, 300 checks): **33.8 s wall**.

If the ×15–40 interpretation factor comes in materially worse at M2,
the fallback levers are, in order: open-code the hot prims as opcodes
(§2.3), superinstructions for the `MOV`-heavy patterns select emits,
and slot-reuse frames — all inside the VM/backend, none touching
semantics.

## 7. Migration: two engines behind one interface

The JS interpreter is not deleted; it is **outlived**.

1. Extract today's index.js surface into `web/src/engine/` with the
   JS interpreter as the sole implementation. Pure refactor;
   `node web/test-corpus.mjs` (294 checks (m)) green — this is the
   gate that proves the interface cut drew no blood.
2. Land the VM engine beside it. Engine selection: `?engine=vm`
   query param + a settings toggle; default stays `js`.
   test-corpus.mjs grows `--engine`, and **CI runs the full corpus
   on both engines** from this point on.
3. Flip the default to `vm` when §8's M5 gate holds. The JS engine
   stays selectable for one release as the escape hatch.
4. Delete `web/src/puffin/` (interp.js, prelude.js, modules.js,
   values.js — reader.js survives only if any UI feature still wants
   client-side parsing for, e.g., form-boundary detection in the
   REPL input; otherwise it goes too). The lockstep documentation
   (MEMORY, BOOTSTRAP.md) is updated the same day: "sync prelude.puf
   → prelude.js" dies as a chore; ".pbc format ↔ VM decoder ↔
   backends.puf render-bc" is born as one.

The corpus is the gate at *every* stage: no stage merges with fewer
than 294/294 on its route, and the golden texts are never edited to
accommodate the VM — output differences are VM bugs by definition.

## 8. Staged milestones, each with its verification gate

- **M1 — Bytecode spec + reference backend.** Freeze §2 into
  docs/BYTECODE.md (opcode table, encodings, unit format, call
  protocol — the new lockstep contract). Implement
  select/allocate-slots/linearize/render for target `bytecode` in
  src/ (backend-bytecode.rkt), plus an assembler-independent
  **disassembler**. *Gate:* encode→decode→re-encode is a fixpoint on
  10 seed programs (fib, variadics, papp>6, closures, HAMT-heavy,
  deep non-tail map, gensym, error paths); disassembly is
  code-reviewed against the spec.
- **M2 — VM in C, native first, then Node.** Dispatch loop, loader,
  frames, safepoint GC; runtime compiled in unchanged. Build
  `bin/puffin-vm` (native) and `puffin-vm.wasm` (wasi-sdk).
  *Gate:* full corpus — 294/294 goldens — through
  `racket src/main.rkt -t bytecode | puffin-vm`, natively **and**
  under Node on the wasm build, **and** natively under
  `PUFFIN_VM_GC_STRESS=1`. Measure the interpretation factor here;
  revisit §6 if it exceeds ×40.
- **M3 — puffincc's third backend + self-hosting on the VM.** Port
  the backend to backends.puf; extend gen-puffincc-tables.rkt.
  *Gate:* diff-ir green per pass for target bytecode; corpus 294/294
  via native puffincc `-t bytecode`; then the bootstrap closes —
  **puffincc compiled to bytecode, running on the VM, compiles the
  corpus to bytecode byte-identically to native puffincc's output**
  (the stage-2 fixpoint, relocated to the new target).
- **M4 — wasm packaging + JS boundary.** The shim, the engine
  module, error unwinding, budgets. *Gate:*
  `node web/test-corpus.mjs --engine=vm` 294/294 (this exercises the
  full in-browser path: puffincc-on-VM compiling and running every
  corpus program, module programs included, under Node); size
  budgets of §6 enforced by a CI check.
- **M5 — Web integration.** Workers wired, REPL-mode compilation
  (§4/§5.2), examples, stdin, streaming, both engines behind the
  toggle. *Gate:* corpus on both engines in CI; a scripted REPL
  parity suite (defines, redefinition, shadowing prelude, error
  recovery, results formatting) run against both Sessions with
  identical transcripts; every web example runs under `?engine=vm`;
  the bench/ paired workloads measured VM-vs-JS-interpreter and the
  numbers published in this document's revision. Default flips when
  Kris says the REPL feels right.

Ordering note: the task of writing the VM before puffincc's backend
exists is served by M1's *reference* backend — the same
src-first-then-port sequence every pass has followed, with diff-ir as
the bridge.

## 9. Risks and honest costs

- **A fifth implementation?** The VM is new executable surface
  (~3–4k lines with the GC and shim) that must be maintained. The
  mitigation is what it *isn't*: it implements the bytecode spec,
  not the language — semantics keep flowing from the one compiler.
  Net, the project trades ~1,850 lines of semantics-bearing JS for
  ~3.5k lines of semantics-free C+JS plus a spec. That is more code
  and less risk; worth saying plainly rather than pretending it is
  less of both.
- **The GC is the scary part.** A conservative-heap collector's bugs
  are heisenbugs. Mitigations are structural (safepoint rule makes
  the unscannable-locals problem unreachable; non-moving keeps
  invariants simple) and procedural (stress mode in CI from M2,
  corpus as the detector). Residual risk: real, accepted, and
  contained to one 500-line file.
- **Compile latency is user-visible.** 100–500 ms typical, seconds
  worst-case (§6). Mitigations: precompiled prelude, worker +
  spinner (already the UX), and the interpretation-factor levers.
  If it still hurts, variant A's eval.puf becomes the instant-start
  mode *on the same VM* — the designs compose rather than compete.
- **REPL mode touches passes.** §4's collect-globals /
  reveal-functions REPL flag violates the "new features are never
  pass edits" instinct. It is small, flag-gated, and lands in both
  compiler sources in lockstep with diff-ir coverage — but it is a
  pass edit, and it is the piece most likely to surface a subtle
  semantic difference (top-level mutual recursion across evals,
  shadowing order). The parity transcript suite at M5 exists for it.
- **wasm32 address-space ceiling.** 4 GB (practically 2 GB in some
  engines) bounds heap + frame stack. The native 512 MB
  deep-recursion reservation becomes a growable segment, but a
  program that legitimately needs multi-GB heaps is a native
  program. The playground has never been that; stated so no one is
  surprised.
- **i64 at the JS boundary** costs BigInt conversions — confined to
  `host_repl_result` and diagnostics; program I/O crosses as bytes.
  Negligible, but it is why the boundary API traffics in strings.
- **Two artifacts to version together** (puffincc.pbc ↔ VM). The
  unit-format version word (§2.5) plus shipping them in one bundle
  makes skew a load-time error, not a wrong answer.
- **What gradual typing asks of all this: nothing, yet.** TYPES.md
  v1 is erasure — the checker runs pre-desugar, no casts exist at
  runtime, ADTs are a dedicated heap kind whose prims (lib/adt.c)
  reach the VM through the manifest like any others. When
  phase-3 casts land, they arrive as runtime prims with blame labels
  (manifest entries + lib module, per FFI.md's pattern), i.e. `PRIM`
  calls — no opcodes, no VM changes. The FFI itself stays
  native-only with the documented web refusal (FFI.md §8), which the
  VM inherits by simply not linking foreign archives.

## 10. What stays out (v1)

A JIT or baseline compiler in the VM; open-coded prim opcodes and
superinstructions (named seam, §2.3/§6); slot-reuse frame
compaction; wasm-GC/externref anything; the wasm exception-handling
and tail-call proposals; SharedArrayBuffer interrupts; .pbc as a
stable distribution format; a WASI CLI/server target (separate
design); FFI in the browser; in-browser provenance for Pipeline mode
(§5.3); variant A's eval.puf (composes later if wanted).

## 11. Decisions for Kris

1. **Variant: B** — puffincc-as-bytecode in the browser, compiling
   user programs to bytecode on the VM — over A (Puffin-written
   interpreter on the same VM). §1 is the case; A remains buildable
   later on B's substrate. Sign off on B?
2. **VM implementation language: C via wasi-sdk**, one compilation
   unit with the existing runtime, native build first-class; over
   Rust (boundary + toolchain cost) and hand-WAT (unmaintainable).
   Agreed?
3. **GC: linear-memory non-moving mark-sweep, precise VM-stack roots
   + conservative heap tracing, collection only at dispatch-loop
   safepoints**; Boehm-on-wasm rejected for the i64-locals soundness
   hole, JS-GC/externref rejected as runtime abandonment. The
   safepoint rule ("prims never collect; grow instead") is the load-
   bearing invariant. Agreed, including stress-mode-in-CI as a
   standing gate?
4. **Cut point: after uncover-locals, register/frame-slot bytecode**,
   keeping limit-functions' packed-call protocol and pf_collect_rest
   verbatim for parity; over an ANF-cut stack machine. Agreed?
5. **REPL mode as a pass flag** (all-top-levels-as-globals,
   late-bound names, indirect top-level calls, `-O0`) in both
   compiler sources — the one pass edit in the design. Acceptable,
   or would you rather v1 ship whole-program runs only and defer the
   VM REPL (keeping the JS Session alive longer)?
6. **Pipeline mode stays ir-server-backed** (dev-only, Racket
   required) rather than attempting in-browser provenance. Fine
   long-term, or should a provenance-free layers view be a real
   milestone?
7. **Budgets** (§6): ~1 MB added download (lazy), 100–500 ms typical
   compile, seconds worst-case — acceptable for the playground, or
   should M2's measured interpretation factor gate the whole project
   (i.e., a kill criterion at ×N)?
   *[Measured 2026-07-10 (§6-measured): the interpretation factor is
   7–12× native VM / 13–20× wasm VM on compute-bound code — no kill;
   typical in-browser compiles measured 2–35 ms, not 100–500 ms.]*
8. **Retirement**: JS interpreter deleted one release after the
   default flips (§7). Comfortable, or keep it indefinitely as a
   reference implementation despite the lockstep cost?
