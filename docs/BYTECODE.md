# The Puffin bytecode (.pbc), versions 1 and 2

> **Status:** IMPLEMENTED (docs/WASM-VM.md milestones M1–M2 for v1;
> M5's REPL units are v2). This document is the format contract — the
> lockstep surface between the bytecode backend
> (src/backend-bytecode.rkt and backends.puf) and the VM
> (src/vm/puffin-vm.c). Any change to an encoding, an opcode, or the
> unit layout bumps the version word, and the VM refuses versions it
> does not implement. The format is **not** a stable distribution
> contract: the compiler and the VM ship together; nothing archives
> .pbc files.
>
> **Version 1** is a whole-program unit. **Version 2** is a REPL unit
> (`--repl`; docs/WASM-VM.md §4/§5.2): identical layout except the
> globals section carries the cells' NAMES (§3.1) and the RESULT
> opcode may appear. v1 bytes are unchanged by v2's existence.

## 0. Quick use

```
bin/puffin -t bytecode prog.puf          # compile to a unit and run it on the VM
bin/puffin -c -t bytecode prog.puf       # produce prog.pbc
bin/puffin-vm prog.pbc                   # run a unit
bin/puffin-vm -d prog.pbc                # disassemble a unit
bin/puffin-vm --session u1.pbc u2.pbc    # one SESSION, many units (REPL semantics)
racket src/main.rkt -f --repl -o e.pbc e.puf   # compile one REPL eval (v2)
build/puffincc --repl e.puf -o e.pbc     # same, self-hosted
build/puffincc --repl-prelude -o p.pbc   # the prelude as a REPL unit
make -C src/vm                           # build bin/puffin-vm (native)
make -C src/vm wasm wasm-repl            # the wasm command + reactor builds
racket src/test.rkt -m bytecode -O 0     # the golden corpus through this route
```

## 1. The machine, in one paragraph

A **register (frame-slot) machine** cut after uncover-locals
(WASM-VM.md §2.2): each function's named locals become numbered
frame slots, each blocks-IR statement becomes one instruction, each
tail becomes a branch. Values are the native runtime's 61-bit tagged
words, byte for byte (system.rkt / puffin.h: fixnum `n<<3`, heap
`ptr|1`, immediates `#f=2 #t=10 void=18 '()=26`, symbol `id<<3|3`).
The VM hosts the existing C runtime — prims are direct calls into
libpuffin.a, allocation is Boehm (native build; the linear-memory
collector is M4) — and frames live on a chunked value stack in
GC-visible memory, not the C stack, which is what makes proper tail
calls a `memmove`.

## 2. Frames, slots, and the call protocol

A frame is `nlocals` slots of 8 bytes each. Slot layout, fixed by
the backend (allocate-slots-bc):

```
slot 0 .. nformals-1     the formals, in order (arguments arrive here)
...                      remaining named locals, sorted by name
...                      the staging area: call arguments and
                         literal materialization (see §4)
```

`nlocals` is always at least 6, so any call site may deliver up to
six physical argument values before the callee looks at them. Fresh
frames are zeroed (slot value fixnum 0), matching the native
zero-seeded globals discipline and keeping the value stack clean for
conservative GC.

**The call protocol mirrors native exactly** (WASM-VM.md §2.4 —
"elegance loses to parity"):

- At most **6 physical argument slots**. The caller stages arguments
  contiguously at `base..base+nargs-1` in its own frame; CALL copies
  them into the callee frame's slots `0..nargs-1`.
- Every call carries the **logical arity**, which the VM keeps in a
  dedicated register — the analogue of native `r10`/`x12`. Fixed
  functions ignore it; variadic callees read it.
- **Packed calls** (`papp`, strictly more than 6 logical args): the
  frontend's limit-functions pass has already packed arguments 6+
  into a vector in the sixth slot; `nargs = 6`, `arity = n > 6`.
  Unchanged from native.
- **Variadic functions** (`#%rest` formals) begin with one COLLECT
  instruction: the VM spills frame slots 0–5 to the runtime's
  `pf_arg_spill` and calls `pf_collect_rest(kfixed, arity)` — the
  same C function native prologues call, compiled unchanged — and
  stores the rest list into the rest parameter's slot.
- **Tail calls** (TCALL/TCALLI) reuse the current frame: arguments
  are staged like any call, then moved to slots 0..nargs-1 and the
  frame is retargeted (regrown only if the callee needs more slots).
  Constant stack space for *all* tail calls — self, mutual,
  closure — by construction. `main` is exempt upstream
  (explicate-control untails it), exactly as native.

**Closures** are kind-4 heap records with the native layout — header,
slot 0, captured values — except slot 0 holds a **function index as a
tagged fixnum** (FUNREF), never a raw code pointer: units come and
go, and a fixnum is GC-inert and serializable. Call sites read slot 0
with UGET (the frontend already extracts it: lift-lambdas emits
`(app (unsafe-vector-ref clo 0) clo args...)`), so CALLI receives the
extracted index value, checks it is a fixnum in range, and dispatches
through the function table. Raw code addresses never appear in heap
values.

**Errors:** arity is not checked at calls (native doesn't); CALLI of
a value that is not a function index is a fatal error ("application
of a non-procedure"). Frame-stack depth is capped (default 4M
frames; `PUFFIN_VM_MAX_DEPTH` overrides) so runaway recursion errors
like native instead of consuming the machine.

## 3. The unit format

Little-endian throughout. All strings are length-prefixed byte
strings (`u32 len` + bytes; embedded NULs legal in the string pool).

```
header    'P' 'U' 'F' 0x01            4 bytes of magic
          u32 version                 1 = whole-program, 2 = REPL unit
          u32 reserved                0
symtab    u32 n, then n names         every symbol literal in the unit
strtab    u32 n, then n byte strings  the string-lit pool
globals   u32 count                   v1: count only (private array)
          [v2 only] count names       cell names, index order (§3.1)
funcs     u32 n, then per function:
            name                      length-prefixed (diagnostics only)
            u32 nformals
            u8  variadic (0/1)
            u8  kfixed                fixed-formal count if variadic
            u16 pad (0)
            u32 nlocals               total frame slots (>= 6)
            u32 code-offset           into the code section
            u32 code-length
entry     u32 function index of main
code      u32 total-length, then the instruction stream
```

Loading a unit: **symbols intern at load.** The compiler assigns
symbol ids from its sorted literal table, but ids are unit-relative;
the loader interns each symtab name through `pf_intern_symbol`
(which dedups) and maps SYM operands to VM-global tagged symbols.
Two units loaded into one session therefore agree on `eq?` for
symbols — the same promise MODULES.md §3 makes for separate native
compilation, by the same mechanism. String literals materialize
**lazily, once per literal per unit** (the `pf_string_const` cache
behavior, kept: repeated evaluation of one literal is `eq?`).
v1 globals are zero-seeded (`fixnum 0`), like the native `.space`
array.

### 3.1 Sessions and v2 link-by-name globals (docs/WASM-VM.md §5.2)

One VM instance may load MANY units (`--session` natively; the wasm
reactor build in the browser). Each unit's functions append to one
**global function table**: FUNREF/CALL/TCALL operands are
unit-relative and biased by the unit's `func_base` at dispatch, so
the tagged function index in a closure's slot 0 stays valid across
units — a closure made in unit A calls correctly from unit B.
CALLI/TCALLI dispatch on the global index directly.

A **v2 (REPL) unit's** globals section carries the cells' names. At
load, each name resolves against the **session cell table** (name →
one pf cell, a GC root), creating cells on demand seeded with the
reserved unbound sentinel `#<undef>` (immediate 34, after `#f`=2
`#t`=10 void=18 `'()`=26). GGET of an `#<undef>` cell is a runtime
error carrying the variable's name; GSET stores through the shared
cell, which is how redefinition replaces and cross-eval references
resolve at call time. v1 units keep their private zero-seeded arrays
and pay no check.

The wasm **reactor** build (`make -C src/vm wasm-repl`,
`-DPVM_REACTOR -mexec-model=reactor`) exports the session boundary:
`pvm_boot()` once, then `pvm_alloc(len)` + `pvm_load_run(ptr, len)`
per unit, all in one instance. Aborts (§WASM-VM 3.4) unwind only the
wasm frames; the host restores the exported `__stack_pointer` and
the session (heap, interned symbols, cells) survives —
`pvm_load_run` resets the VM frame stacks on entry.

## 4. The instruction set (29 opcodes)

Operands: `d`/`a`/`b`/`s`/`fs` are u16 frame-slot indices, `base` a
u16 slot index (first staged argument), `n` a u8 physical argument
count (<= 6), `arity` a u16 logical arity, `off` a u32 byte offset
from the start of the function's code, `k64` an i64 tagged word,
`k8` an i8 tagged word (sign-extended), `sym`/`str`/`fn`/`g`/`prim`
u16 table indices, `i` a u8 payload-slot index.

Literals never appear as instruction operands: the backend stages
them into staging slots with IMM/SYM first, so every operand is a
slot. (This is the MOV-heavy pattern superinstructions would later
compress; WASM-VM.md §6 names that seam.)

| op | encoding | semantics |
|---|---|---|
| 0x01 MOV    | `d s`          | `R[d] = R[s]` |
| 0x02 IMM    | `d k64`        | `R[d] = k64` (any tagged word) |
| 0x03 IMM8   | `d k8`         | `R[d] = sext(k8)` (small fixnums, `#f/#t/void/'()`) |
| 0x04 SYM    | `d sym`        | `R[d] =` interned symbol for unit symbol `sym` |
| 0x05 STR    | `d str`        | `R[d] =` cached heap string for literal `str` (lazy) |
| 0x06 FUNREF | `d fn`         | `R[d] = fix(fn)` (a closure-slot-0 value) |
| 0x07 NEG    | `d a`          | `R[d] = 0 - R[a]` (tagged negate, wrapping) |
| 0x08 ADD    | `d a b`        | `R[d] = R[a] + R[b]` (tagged, wrapping) |
| 0x09 MUL    | `d a b`        | `R[d] = (R[a] >> 3) * R[b]` (tagged, wrapping) |
| 0x0A LT     | `d a b`        | `R[d] = R[a] <s R[b] ? #t : #f` (signed tagged) |
| 0x0B EQ     | `d a b`        | `R[d] = R[a] == R[b] ? #t : #f` |
| 0x0C JMP    | `off`          | `ip = off` |
| 0x0D BREQ   | `a b off`      | `if R[a] == R[b]: ip = off` |
| 0x0E BRLT   | `a b off`      | `if R[a] <s R[b]: ip = off` |
| 0x0F BRLE   | `a b off`      | `if R[a] <=s R[b]: ip = off` |
| 0x10 BRGT   | `a b off`      | `if R[a] >s R[b]: ip = off` |
| 0x11 BRGE   | `a b off`      | `if R[a] >=s R[b]: ip = off` |
| 0x12 CALL   | `d fn base n arity` | direct call; result to `R[d]` |
| 0x13 CALLI  | `d fs base n arity` | indirect: `R[fs]` is a function index |
| 0x14 TCALL  | `fn base n arity`   | direct tail call: frame reuse |
| 0x15 TCALLI | `fs base n arity`   | indirect tail call: frame reuse |
| 0x16 PRIM   | `d prim base n`     | manifest prim: direct C call via the table |
| 0x17 COLLECT| `d k`          | variadic prologue: spill slots 0–5 to `pf_arg_spill`, `R[d] = pf_collect_rest(fix(k), arity)` |
| 0x18 UGET   | `d a i`        | `R[d] = heap(R[a])[1+i]` (unsafe-vector-ref) |
| 0x19 USET   | `a i s`        | `heap(R[a])[1+i] = R[s]` (unsafe-vector-set!) |
| 0x1A GGET   | `d g`          | `R[d] = G[g]` (v2: through the named cell; `#<undef>` errors with the name) |
| 0x1B GSET   | `g s`          | `G[g] = R[s]` (v2: through the named cell) |
| 0x1C RET    | `s`            | return `R[s]`; RET from the entry frame ends the unit's run |
| 0x1D RESULT | `s`            | v2 only: if `R[s]` is not void, render it with the runtime's value->string and deliver it as a REPL result (wasm: the `puffin.repl_result` host import; native: one stdout line) |

Notes:

- **No HALT opcode:** `main` never contains tail calls (untailed
  upstream), so its conclusion is a RET; the host prints the result
  via `pf_print_result` and exits 0, matching the native conclusion.
- **Branch orientation:** a blocks-IR two-way tail
  `(if (cmp a b) (goto l0) (goto l1))` lowers to `BRcc a b l0`
  (taken when the comparison holds) followed by `JMP l1` (dropped
  when `l1` is the fall-through block).
- **Intrinsics are exactly the ops the native selects open-code at
  -O0**: `+ - * eq? <`. Everything else — `car`, `vector-ref`,
  `hash-set`, all of lib/ — is a PRIM call at every optimization
  level in v1 (WASM-VM.md §2.3: no open-coded prims; the seam for
  adding them one at a time is named there).
- **Prim ids are stdlib.rkt manifest indices.** The VM's table
  (src/vm/vm-prims.inc) is *generated* from the manifest
  (`racket src/gen-vm-prims.rkt > src/vm/vm-prims.inc`), and the
  backend computes ids from the same list — one more derived view in
  the manifest discipline. A manifest change means regenerating the
  .inc and rebuilding the VM (and, being an encoding change, is only
  version-compatible if entries are appended).

## 5. What the backend passes do

The chain mirrors the native backends' shape (WASM-VM.md §4), in
src/backend-bytecode.rkt:

- **select-instructions-bc** — structural transcription of the
  blocks IR: atoms to slot operands (literals staged), statements to
  §4 instructions, calls staged per §2, the COLLECT prologue for
  variadics. No trap blocks, no `pair?`/`vector?` splitting — those
  are native open-coding machinery, and v1 does not open-code.
- **allocate-slots-bc** — numbers the locals (formals first, rest
  sorted — deterministic bytes are part of the bootstrap fixpoint
  discipline), sizes the staging area, resolves `(var x)`/`(stage k)`
  operands, enforces the 6-slot frame minimum. Any variable
  *mentioned* gets a slot even if never assigned (a match-clause
  predicate on a path never executed is read-only garbage natively;
  here it reads fixnum 0). No liveness, no interference, no spills;
  slot-reuse compaction is a named non-goal for v1.
- **linearize-bc** — orders blocks (entry first, then DFS favoring
  fall-through), lowers two-way branches, drops jumps to the next
  block.
- **render-pbc** — encodes §3/§4 into bytes. main.rkt writes them as
  the `.pbc` output and skips the assembler/linker entirely.

`-O1` needs nothing new: loop recovery has already turned self tail
calls into gotos, blocks cleanup ran, direct `(app (fun-ref f) ...)`
calls become CALL/TCALL, and fused compare branches use the BRcc
family. The full golden corpus is green through this route at -O0,
-O1, and -O2.

**REPL mode** (`--repl`, docs/WASM-VM.md §4; both compiler sources):
collect-globals compiles every top-level define — functions included
— into a NAMED cell (function defines become lambda initializers run
in source order), late-binds free variables by name, and wraps each
top-level expression in the internal `#%repl-result` prim, which
select-instructions-bc lowers to RESULT. reveal-functions then has
nothing to reveal (only the synthesized entry exists), so every
top-level call is indirect — which is exactly what makes redefinition
retroactive. REPL units always compile at -O0 and render as v2.

## 6. The VM (src/vm/puffin-vm.c)

One C file (~550 lines) linking libpuffin.a:

- **Dispatch:** a switch loop (computed-goto is a later, measured
  upgrade; fib(32) runs ~13x slower than native -O1 as is, inside
  the design's 15–40x envelope).
- **Value stack:** chunked (8 MB chunks) slot storage, each chunk a
  registered Boehm root region (`GC_add_roots`), so every frame slot
  is scanned. The C stack never holds Puffin state across
  instructions except prim temporaries, which Boehm's native stack
  scan covers.
- **Control stack:** frame metadata only (function index, return ip,
  result slot, slot-array bookkeeping) in plain malloc memory — no
  pf values live there.
- **Runtime fate (WASM-VM.md §3.2):** hosted, not replaced. core.c's
  weak whole-program literal tables are satisfied with empty
  definitions; symbol interning, gensym, display, equal?, errors,
  and I/O are the very same code native programs run, which is why
  the corpus gate is byte-for-byte.

## 7. Known gaps

- No re-encoding assembler: `puffin-vm -d` is a decoder/printer.
  The corpus (309 checks x 3 optimization levels) is the gate.
- Units are never unloaded: a very long session accumulates code
  and function-table rows per eval (small; bounded by eval count).
  (Unit *heap data* is collected normally by the §3.3 GC; this gap
  is about code + loader metadata only.)
- REPL evals may not define `main` (the entry name is synthesized
  per unit); the compile error returns to the session without
  killing it.

(Resolved since M2: the argv seam — `pf_set_args` lets the VM hand
the hosted program its own argv; the globals name table and version
bump landed as v2, above. Resolved with the §3.3 collector: the wasm
build's allocator now collects — mark-sweep at dispatch-loop
safepoints, src/vm/wasm/wasm-gc.c — and `PUFFIN_VM_GC_STRESS=1`
collects at every safepoint with freed-block poisoning; the full
corpus runs under stress as the third leg of tools/gctest-corpus.sh.
Under Boehm the safepoint macro compiles away, as before.)
