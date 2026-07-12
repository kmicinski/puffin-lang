// puffin-vm.c -- the Puffin bytecode VM (docs/WASM-VM.md M2/M5, native
// build; docs/BYTECODE.md is the format contract).
//
//   puffin-vm prog.pbc [args...]      load and run a unit
//   puffin-vm -d prog.pbc             disassemble a unit
//   puffin-vm --session u1.pbc u2...  ONE session, MANY units (REPL
//                                     semantics: v2 units link their
//                                     named globals into the shared
//                                     session cell table)
//
// Design (docs/WASM-VM.md §3, §5.2):
//  - The VM *hosts* the existing runtime: this file links against
//    src/runtime/libpuffin.a (core.c + lib/*.c + vendored Boehm) and
//    calls the same pf_* entry points native code calls. Values are
//    the same 61-bit tagged words; nothing in lib/ knows it is
//    running under a VM.
//  - Frames are slot arrays on a chunked value stack registered as
//    Boehm root regions, NOT the C stack -- which is what makes
//    TCALL/TCALLI frame reuse (proper tail calls in O(1) space) a
//    memmove instead of a calling-convention headache.
//  - The call convention mirrors native: up to 6 argument slots, the
//    logical arity in a VM register (the analogue of native r10/x12),
//    >6-arg calls packed by the frontend (papp), and the variadic
//    prologue's COLLECT spilling the six argument slots to
//    pf_arg_spill and calling pf_collect_rest -- the very same C
//    function, unchanged.
//  - MULTI-UNIT SESSIONS (M5): one VM instance may load many units.
//    Each unit's functions append to ONE global function table, so a
//    closure's slot-0 function index (biased by the unit's func_base
//    at FUNREF time) stays valid across units -- a closure made in
//    unit A calls correctly from unit B. Symbols intern globally at
//    load (eq? agreement across units, as always); string caches are
//    per unit. v1 (whole-program) units keep private zero-seeded
//    globals; v2 (REPL) units link their NAMED globals into the
//    session cell table, cells seeded with the unbound sentinel
//    #<undef> (immediate 34) so reading a never-defined name is an
//    error carrying the variable's name.
//  - The wasm reactor build (-DPVM_REACTOR, `make wasm-repl`) exports
//    pvm_boot/pvm_alloc/pvm_load_run so the browser engine drives a
//    persistent session: one heap, one cell table, many evals.
//    Results of REPL top-level expressions are delivered through the
//    RESULT opcode -> vm_host_repl_result (a host import on wasm; on
//    native builds each result prints as its own stdout line).

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include "../runtime/puffin.h"

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int64_t i64;

// ---------------------------------------------------------------
// Runtime hooks (core.c / lib) not exposed in puffin.h
// ---------------------------------------------------------------

extern void pf_init(void);
extern pf pf_print_result(pf);
extern pf pf_collect_rest(pf, pf);
extern pf pf_arg_spill[8];
extern pf pf_string_from_bytes(const char *, int64_t);
extern pf pf_to_string(pf);
extern void *pf_alloc_raw(int64_t);

// Boehm (native) / wasm-gc.c (wasm): malloc'd arrays that hold pf
// values (frame chunks, unit string caches, unit globals, session
// cells) are registered as root regions so every live slot is
// scanned. The metadata around them stays plain malloc memory.
extern void GC_add_roots(void *low, void *high_plus_1);

// The §3.3 safepoint seam (wasm/gctest builds only, -DPVM_WASM_GC;
// docs/WASM-VM.md §3.3). The collector never runs inside GC_MALLOC:
// it raises pf_gc_wants_collect and the dispatch loop settles the
// debt here, BETWEEN instructions, where no pf lives in a C local.
// Safepoints sit on every jump, branch, and call opcode -- every
// loop the bytecode can express passes through one -- so the heap
// can only overshoot the budget by one basic block's allocations
// (or one prim's; a single huge allocation grows, as documented).
// Under Boehm the macro is empty: Boehm collects inside GC_MALLOC.
#ifdef PVM_WASM_GC
extern int pf_gc_wants_collect;
extern void pf_gc_collect(void);
#define PVM_SAFEPOINT() do { if (pf_gc_wants_collect) pf_gc_collect(); } while (0)
#else
#define PVM_SAFEPOINT() ((void)0)
#endif

// The compiler's whole-program literal tables are weak externs in
// core.c; the VM interns literals itself (per unit, at load time),
// so it supplies empty definitions to keep the linker happy.
const char *puffin_symbol_names[1] = {0};
int64_t puffin_symbol_count = 0;
const char *puffin_string_consts[1] = {0};
int64_t puffin_string_const_count = 0;

// The unbound-cell sentinel: immediate 34 = (4 << 3) | 2, reserved
// after #f=2 #t=10 void=18 '()=26 (docs/WASM-VM.md §4). Session
// cells seed to it; GGET of an undefined cell is a runtime error
// naming the variable. It never appears in whole-program units.
#define PF_UNDEF ((pf)34)

// ---------------------------------------------------------------
// The prim table, generated from the stdlib manifest (prim ids are
// manifest indices; see src/gen-vm-prims.rkt)
// ---------------------------------------------------------------

typedef void (*vm_prim_fn)(void);
typedef struct { const char *name; int arity; vm_prim_fn fn; } vm_prim;
#include "vm-prims.inc"

typedef pf (*fn0)(void);
typedef pf (*fn1)(pf);
typedef pf (*fn2)(pf, pf);
typedef pf (*fn3)(pf, pf, pf);

// ---------------------------------------------------------------
// Opcodes (docs/BYTECODE.md; keep in sync with backend-bytecode.rkt)
// ---------------------------------------------------------------

enum {
  OP_MOV = 0x01, OP_IMM = 0x02, OP_IMM8 = 0x03, OP_SYM = 0x04,
  OP_STR = 0x05, OP_FUNREF = 0x06,
  OP_NEG = 0x07, OP_ADD = 0x08, OP_MUL = 0x09, OP_LT = 0x0A, OP_EQ = 0x0B,
  OP_JMP = 0x0C, OP_BREQ = 0x0D, OP_BRLT = 0x0E, OP_BRLE = 0x0F,
  OP_BRGT = 0x10, OP_BRGE = 0x11,
  OP_CALL = 0x12, OP_CALLI = 0x13, OP_TCALL = 0x14, OP_TCALLI = 0x15,
  OP_PRIM = 0x16, OP_COLLECT = 0x17,
  OP_UGET = 0x18, OP_USET = 0x19,
  OP_GGET = 0x1A, OP_GSET = 0x1B,
  OP_RET = 0x1C, OP_RESULT = 0x1D,
};

#define PBC_VERSION 1       // whole-program units
#define PBC_VERSION_REPL 2  // REPL units: named globals, RESULT legal

// ---------------------------------------------------------------
// Units and the global function table
// ---------------------------------------------------------------

typedef struct Unit Unit;

typedef struct {
  char *name;      // diagnostics
  u32 nformals;
  u8 variadic;
  u8 kfixed;
  u32 nlocals;     // total frame slots (>= 6)
  u32 code_off;
  u32 code_len;
  Unit *unit;      // owning unit: code base, literal tables, globals
} VMFunc;

struct Unit {
  u32 version;
  u32 nsyms;   char **symnames;      // kept for disassembly
  pf *symvals;                       // unit symbol id -> tagged symbol
  u32 nstrs;   char **strs; u32 *strlens;
  pf *strcache;                      // lazy per-unit heap strings (rooted)
  u32 nglobals;
  char **gnames;                     // v2 only: cell names
  pf *globals;                       // v1: private array, fixnum-0 seeded (rooted)
  pf **cells;                        // v2: session cells, by name (cells rooted)
  u32 nfuncs;
  u32 func_base;                     // index of this unit's funcs[0] in the global table
  u32 entry;                         // unit-local entry function index
  u8 *code;    u32 code_len;
};

static VMFunc *funcs = NULL;
static u32 total_funcs = 0, funcs_cap = 0;

static void vm_die(const char *msg) {
  fflush(stdout);
  fprintf(stderr, "puffin-vm: %s\n", msg);
  exit(255);
}

static void *xmalloc(size_t n) {
  void *p = malloc(n ? n : 1);
  if (!p) vm_die("out of memory");
  return p;
}

// malloc'd, zeroed, and registered as a GC root region: for arrays
// that hold live pf values outside the GC heap.
static void *rooted_alloc(size_t bytes) {
  void *p = xmalloc(bytes ? bytes : 8);
  memset(p, 0, bytes ? bytes : 8);
  GC_add_roots(p, (char *)p + (bytes ? bytes : 8));
  return p;
}

// ---------------------------------------------------------------
// The session cell table (docs/WASM-VM.md §5.2): mangled name -> one
// pf cell, shared by every v2 unit in the session. Cells live in
// fixed blocks (each block a registered root region, never moved);
// the name index is plain malloc'd metadata.
// ---------------------------------------------------------------

#define CELL_BLOCK 256
static pf *cell_block = NULL;      // current block
static u32 cell_block_used = CELL_BLOCK;
static char **cell_names = NULL;   // name per cell, session-wide
static pf **cell_ptrs = NULL;
static u32 ncells = 0, cells_cap = 0;

static pf *session_cell(const char *name) {
  for (u32 i = 0; i < ncells; i++)
    if (strcmp(cell_names[i], name) == 0) return cell_ptrs[i];
  if (cell_block_used == CELL_BLOCK) {
    cell_block = rooted_alloc(CELL_BLOCK * sizeof(pf));
    for (u32 i = 0; i < CELL_BLOCK; i++) cell_block[i] = PF_UNDEF;
    cell_block_used = 0;
  }
  pf *cell = &cell_block[cell_block_used++];
  if (ncells == cells_cap) {
    cells_cap = cells_cap ? cells_cap * 2 : 128;
    cell_names = realloc(cell_names, cells_cap * sizeof(char *));
    cell_ptrs = realloc(cell_ptrs, cells_cap * sizeof(pf *));
    if (!cell_names || !cell_ptrs) vm_die("out of memory (cell table)");
  }
  cell_names[ncells] = strdup(name);
  cell_ptrs[ncells] = cell;
  ncells++;
  return cell;
}

// ---- loader -----------------------------------------------------

typedef struct { const u8 *p, *end; } Rd;

static u8  rd_u8(Rd *r)  { if (r->p + 1 > r->end) vm_die("truncated unit"); return *r->p++; }
static u16 rd_u16(Rd *r) { if (r->p + 2 > r->end) vm_die("truncated unit"); u16 v; memcpy(&v, r->p, 2); r->p += 2; return v; }
static u32 rd_u32(Rd *r) { if (r->p + 4 > r->end) vm_die("truncated unit"); u32 v; memcpy(&v, r->p, 4); r->p += 4; return v; }
static char *rd_lstr(Rd *r, u32 *len_out) {
  u32 n = rd_u32(r);
  if (r->p + n > r->end) vm_die("truncated unit");
  char *s = xmalloc(n + 1);
  memcpy(s, r->p, n);
  s[n] = 0;
  r->p += n;
  if (len_out) *len_out = n;
  return s;
}

// Parse a unit out of `buf` (malloc side only -- copies everything it
// keeps, so the caller may free buf afterward).
static Unit *load_unit(const u8 *buf, size_t len) {
  Unit *u = xmalloc(sizeof(Unit));
  memset(u, 0, sizeof(Unit));
  Rd r = {buf, buf + len};
  if (len < 12 || buf[0] != 'P' || buf[1] != 'U' || buf[2] != 'F' || buf[3] != 1)
    vm_die("not a Puffin bytecode unit (bad magic)");
  r.p += 4;
  u->version = rd_u32(&r);
  if (u->version != PBC_VERSION && u->version != PBC_VERSION_REPL) {
    fflush(stdout);
    fprintf(stderr, "puffin-vm: unit version %u, this VM implements %u and %u\n",
            u->version, PBC_VERSION, PBC_VERSION_REPL);
    exit(255);
  }
  rd_u32(&r); // reserved
  u->nsyms = rd_u32(&r);
  u->symnames = xmalloc(sizeof(char *) * (u->nsyms ? u->nsyms : 1));
  for (u32 i = 0; i < u->nsyms; i++) u->symnames[i] = rd_lstr(&r, NULL);
  u->nstrs = rd_u32(&r);
  u->strs = xmalloc(sizeof(char *) * (u->nstrs ? u->nstrs : 1));
  u->strlens = xmalloc(sizeof(u32) * (u->nstrs ? u->nstrs : 1));
  for (u32 i = 0; i < u->nstrs; i++) u->strs[i] = rd_lstr(&r, &u->strlens[i]);
  u->nglobals = rd_u32(&r);
  if (u->version == PBC_VERSION_REPL) {
    // v2: the globals section carries the cell NAMES (link-by-name)
    u->gnames = xmalloc(sizeof(char *) * (u->nglobals ? u->nglobals : 1));
    for (u32 i = 0; i < u->nglobals; i++) u->gnames[i] = rd_lstr(&r, NULL);
  }
  u->nfuncs = rd_u32(&r);
  VMFunc *fs = xmalloc(sizeof(VMFunc) * (u->nfuncs ? u->nfuncs : 1));
  for (u32 i = 0; i < u->nfuncs; i++) {
    VMFunc *f = &fs[i];
    f->name = rd_lstr(&r, NULL);
    f->nformals = rd_u32(&r);
    f->variadic = rd_u8(&r);
    f->kfixed = rd_u8(&r);
    rd_u16(&r); // pad
    f->nlocals = rd_u32(&r);
    f->code_off = rd_u32(&r);
    f->code_len = rd_u32(&r);
    f->unit = u;
    if (f->nlocals < 6) vm_die("function frame smaller than 6 slots");
  }
  u->entry = rd_u32(&r);
  if (u->entry >= u->nfuncs) vm_die("entry index out of range");
  u->code_len = rd_u32(&r);
  if (r.p + u->code_len > r.end) vm_die("truncated code section");
  u->code = xmalloc(u->code_len ? u->code_len : 1);
  memcpy(u->code, r.p, u->code_len);
  for (u32 i = 0; i < u->nfuncs; i++)
    if ((u64)fs[i].code_off + fs[i].code_len > u->code_len)
      vm_die("function code out of range");
  // append this unit's functions to the global table (func_base is
  // the bias FUNREF/CALL/TCALL apply to unit-relative indices)
  if (total_funcs + u->nfuncs > funcs_cap) {
    funcs_cap = funcs_cap ? funcs_cap : 256;
    while (funcs_cap < total_funcs + u->nfuncs) funcs_cap *= 2;
    funcs = realloc(funcs, funcs_cap * sizeof(VMFunc));
    if (!funcs) vm_die("out of memory (function table)");
  }
  u->func_base = total_funcs;
  memcpy(funcs + total_funcs, fs, u->nfuncs * sizeof(VMFunc));
  total_funcs += u->nfuncs;
  free(fs);
  return u;
}

// GC-side unit finalization (requires pf_init): intern symbols, seed
// globals/caches, and -- for v2 -- link named globals to session cells.
static void finish_unit(Unit *u) {
  u->symvals = xmalloc(sizeof(pf) * (u->nsyms ? u->nsyms : 1));
  for (u32 i = 0; i < u->nsyms; i++)
    u->symvals[i] = (pf_intern_symbol(u->symnames[i]) << 3) | PF_TAG_SYMBOL;
  u->strcache = rooted_alloc(sizeof(pf) * (u->nstrs ? u->nstrs : 1));
  if (u->version == PBC_VERSION_REPL) {
    u->cells = xmalloc(sizeof(pf *) * (u->nglobals ? u->nglobals : 1));
    for (u32 i = 0; i < u->nglobals; i++)
      u->cells[i] = session_cell(u->gnames[i]);
  } else {
    // v1: private zero-seeded array (PF_FIX(0)), like native .space
    u->globals = rooted_alloc(sizeof(pf) * (u->nglobals ? u->nglobals : 1));
  }
}

// ---------------------------------------------------------------
// The value stack: chunked frame slots, each chunk registered as a
// GC root region -- every live frame slot is scanned, and no Puffin
// state lives on the C stack across instructions.
// ---------------------------------------------------------------

#define CHUNK_SLOTS (1u << 20) // 8 MB of slots per chunk

typedef struct VChunk {
  struct VChunk *next;
  size_t cap, top;
  pf slots[];
} VChunk;

static VChunk *chunk_head = NULL; // kept for reuse across pops
static VChunk *chunk_cur = NULL;

static VChunk *chunk_new(size_t min_slots) {
  size_t cap = min_slots > CHUNK_SLOTS ? min_slots : CHUNK_SLOTS;
  VChunk *c = malloc(sizeof(VChunk) + cap * sizeof(pf));
  if (!c) vm_die("out of memory (frame stack)");
  c->next = NULL;
  c->cap = cap;
  c->top = 0;
  memset(c->slots, 0, cap * sizeof(pf));
#ifndef PVM_WASM_GC
  // Boehm scans the whole chunk (dead slots included -- Boehm has no
  // notion of our tops). The §3.3 collector instead walks the LIVE
  // extent via pvm_gc_frame_roots below, which is what keeps stress
  // mode (collect at every safepoint) tractable.
  GC_add_roots(c->slots, c->slots + cap);
#endif
  return c;
}

#ifdef PVM_WASM_GC
// Precise frame roots for the §3.3 collector: every slot below each
// chunk's top, in chunks up to chunk_cur (later chunks are kept only
// for reuse; nothing in them is live). Slots between a reused frame's
// live locals and its cap can hold stale values from a deeper call --
// scanned anyway, bounded over-retention, the conservative choice.
void pvm_gc_frame_roots(void (*visit)(void *lo, void *hi)) {
  for (VChunk *c = chunk_head; c; c = c->next) {
    visit(c->slots, c->slots + c->top);
    if (c == chunk_cur) break;
  }
}
#endif

// allocate n slots; records where they came from so frame_free can
// unwind exactly
static pf *frame_alloc(size_t n, VChunk **chunk_out, size_t *top_out) {
  if (!chunk_cur) {
    chunk_head = chunk_cur = chunk_new(n);
  }
  if (chunk_cur->top + n > chunk_cur->cap) {
    if (chunk_cur->next && n <= chunk_cur->next->cap) {
      chunk_cur = chunk_cur->next;
      chunk_cur->top = 0;
    } else {
      VChunk *c = chunk_new(n);
      c->next = chunk_cur->next;
      chunk_cur->next = c;
      chunk_cur = c;
    }
  }
  *chunk_out = chunk_cur;
  *top_out = chunk_cur->top;
  pf *slots = chunk_cur->slots + chunk_cur->top;
  chunk_cur->top += n;
  return slots;
}

static void frame_free(VChunk *chunk, size_t top_before) {
  chunk_cur = chunk;
  chunk_cur->top = top_before;
}

// ---------------------------------------------------------------
// The control stack (frame metadata only; no pf values live here)
// ---------------------------------------------------------------

typedef struct {
  u32 func;      // GLOBAL function index
  u32 ret_ip;    // where THIS frame resumes after its pending call
  u32 dst;       // caller slot that receives this frame's result
  pf *slots;
  size_t cap;    // allocated slot count (>= funcs[func].nlocals)
  VChunk *chunk;
  size_t top_before;
} CFrame;

static CFrame *cstack = NULL;
static size_t cdepth = 0, ccap = 0;
static size_t cmax = 4u << 20; // configurable depth limit (PUFFIN_VM_MAX_DEPTH)

static CFrame *cpush(void) {
  if (cdepth == ccap) {
    ccap = ccap ? ccap * 2 : 1024;
    cstack = realloc(cstack, ccap * sizeof(CFrame));
    if (!cstack) vm_die("out of memory (control stack)");
  }
  if (cdepth >= cmax) vm_die("frame stack overflow (deep non-tail recursion; raise PUFFIN_VM_MAX_DEPTH)");
  return &cstack[cdepth++];
}

// Reset execution state between session evals: a previous eval may
// have aborted mid-run (docs/WASM-VM.md §3.4 -- the heap, cells, and
// interned symbols survive; frames do not).
static void reset_exec_state(void) {
  cdepth = 0;
  chunk_cur = chunk_head;
  if (chunk_cur) chunk_cur->top = 0;
}

// ---------------------------------------------------------------
// REPL result delivery (the RESULT opcode; docs/WASM-VM.md §5.2).
// The value is rendered VM-side by the runtime's own value->string
// so formatting is identical to display. On wasm the bytes go to the
// host_repl_result import (wasm/wasm-host.c); natively each result
// prints as its own stdout line (the transcript surface --session
// runs produce).
// ---------------------------------------------------------------

#if defined(PVM_REACTOR) || defined(__wasi__)
// wasm builds (command and reactor): wasm/wasm-host.c forwards to the
// host_repl_result import (module "puffin", name "repl_result").
extern void vm_host_repl_result(const char *bytes, i64 len);
#else
// native: each result prints as its own stdout line (the transcript
// surface --session runs produce).
static void vm_host_repl_result(const char *bytes, i64 len) {
  fwrite(bytes, 1, (size_t)len, stdout);
  fputc('\n', stdout);
}
#endif

static void vm_deliver_result(pf v) {
  if (v == PF_VOID) return;
  pf s = pf_to_string(v);
  i64 *p = pf_heap_ptr(s);
  vm_host_repl_result((const char *)(p + 1), pf_len_of(s));
}

// ---------------------------------------------------------------
// The dispatch loop
// ---------------------------------------------------------------

static pf vm_run(u32 entry_gidx) {
  const VMFunc *fn = &funcs[entry_gidx];
  Unit *un = fn->unit;
  CFrame *cf = cpush();
  cf->func = entry_gidx;
  cf->ret_ip = 0;
  cf->dst = 0;
  cf->slots = frame_alloc(fn->nlocals, &cf->chunk, &cf->top_before);
  cf->cap = fn->nlocals;
  memset(cf->slots, 0, fn->nlocals * sizeof(pf));

  const u8 *code = un->code + fn->code_off;
  u32 ip = 0;
  pf areg = PF_FIX(0); // the arity register (native r10/x12)

  PVM_SAFEPOINT(); // settle any debt run up since the last vm_run

#define RD8()  (code[ip++])
#define RD16() (ip += 2, (u16)(code[ip-2] | ((u16)code[ip-1] << 8)))
#define RD32() (ip += 4, (u32)code[ip-4] | ((u32)code[ip-3] << 8) | ((u32)code[ip-2] << 16) | ((u32)code[ip-1] << 24))
#define RD64() (ip += 8, (i64)((u64)code[ip-8] | ((u64)code[ip-7] << 8) | ((u64)code[ip-6] << 16) | ((u64)code[ip-5] << 24) | \
                               ((u64)code[ip-4] << 32) | ((u64)code[ip-3] << 40) | ((u64)code[ip-2] << 48) | ((u64)code[ip-1] << 56)))

  for (;;) {
    u8 op = RD8();
    switch (op) {
    case OP_MOV: { u16 d = RD16(), s = RD16(); cf->slots[d] = cf->slots[s]; break; }
    case OP_IMM: { u16 d = RD16(); i64 w = RD64(); cf->slots[d] = (pf)w; break; }
    case OP_IMM8: { u16 d = RD16(); i64 w = (int8_t)RD8(); cf->slots[d] = (pf)w; break; }
    case OP_SYM: { u16 d = RD16(), i = RD16(); cf->slots[d] = un->symvals[i]; break; }
    case OP_STR: {
      u16 d = RD16(), i = RD16();
      if (un->strcache[i] == 0)
        un->strcache[i] = pf_string_from_bytes(un->strs[i], (int64_t)un->strlens[i]);
      cf->slots[d] = un->strcache[i];
      break;
    }
    case OP_FUNREF: { u16 d = RD16(), f = RD16(); cf->slots[d] = PF_FIX(un->func_base + f); break; }
    // Arithmetic/comparison intrinsics TAG-CHECK their operands: a
    // non-fixnum dies with "<op>: expected Int, got <value>" instead of
    // computing a garbage tagged word. (OP_EQ/BREQ are eq? -- any word.)
#define ARITH_CHECK1(opname, va) \
    do { if (((va) & 7) != 0) pf_die_arith_typed(opname, (va), (va)); } while (0)
#define ARITH_CHECK2(opname, va, vb) \
    do { if ((((va) | (vb)) & 7) != 0) pf_die_arith_typed(opname, (va), (vb)); } while (0)
    case OP_NEG: { u16 d = RD16(), a = RD16(); ARITH_CHECK1("-", cf->slots[a]); cf->slots[d] = (pf)(0 - (u64)cf->slots[a]); break; }
    case OP_ADD: { u16 d = RD16(), a = RD16(), b = RD16(); ARITH_CHECK2("+", cf->slots[a], cf->slots[b]); cf->slots[d] = (pf)((u64)cf->slots[a] + (u64)cf->slots[b]); break; }
    case OP_MUL: { u16 d = RD16(), a = RD16(), b = RD16(); ARITH_CHECK2("*", cf->slots[a], cf->slots[b]); cf->slots[d] = (pf)((u64)(cf->slots[a] >> 3) * (u64)cf->slots[b]); break; }
    case OP_LT:  { u16 d = RD16(), a = RD16(), b = RD16(); ARITH_CHECK2("<", cf->slots[a], cf->slots[b]); cf->slots[d] = PF_BOOL(cf->slots[a] < cf->slots[b]); break; }
    case OP_EQ:  { u16 d = RD16(), a = RD16(), b = RD16(); cf->slots[d] = PF_BOOL(cf->slots[a] == cf->slots[b]); break; }
    // Safepoints (§3.3) sit on every control transfer: JMP, the
    // conditional branches, and all four call forms. Any loop the
    // bytecode can express passes through one of these, so the GC
    // debt a basic block can run up is bounded by its length. The
    // check is one global load; collection itself only happens here,
    // between instructions -- never inside a prim. The comparison
    // branches ALSO tag-check their operands (ARITH_CHECK2 above);
    // BREQ is eq? -- any word, no check.
    case OP_JMP: { PVM_SAFEPOINT(); u32 off = RD32(); ip = off; break; }
    case OP_BREQ: { PVM_SAFEPOINT(); u16 a = RD16(), b = RD16(); u32 off = RD32(); if (cf->slots[a] == cf->slots[b]) ip = off; break; }
    case OP_BRLT: { PVM_SAFEPOINT(); u16 a = RD16(), b = RD16(); u32 off = RD32(); ARITH_CHECK2("<", cf->slots[a], cf->slots[b]); if (cf->slots[a] <  cf->slots[b]) ip = off; break; }
    case OP_BRLE: { PVM_SAFEPOINT(); u16 a = RD16(), b = RD16(); u32 off = RD32(); ARITH_CHECK2("<=", cf->slots[a], cf->slots[b]); if (cf->slots[a] <= cf->slots[b]) ip = off; break; }
    case OP_BRGT: { PVM_SAFEPOINT(); u16 a = RD16(), b = RD16(); u32 off = RD32(); ARITH_CHECK2(">", cf->slots[a], cf->slots[b]); if (cf->slots[a] >  cf->slots[b]) ip = off; break; }
    case OP_BRGE: { PVM_SAFEPOINT(); u16 a = RD16(), b = RD16(); u32 off = RD32(); ARITH_CHECK2(">=", cf->slots[a], cf->slots[b]); if (cf->slots[a] >= cf->slots[b]) ip = off; break; }
    case OP_CALL: case OP_CALLI: {
      PVM_SAFEPOINT();
      u16 d = RD16();
      u32 fi;
      if (op == OP_CALL) {
        fi = un->func_base + RD16();
      } else {
        u16 fs = RD16();
        pf v = cf->slots[fs];
        if ((v & PF_TAG_MASK) != PF_TAG_FIXNUM || (u64)PF_UNFIX(v) >= total_funcs)
          pf_fatal("application of a non-procedure");
        fi = (u32)PF_UNFIX(v);
      }
      u16 b = RD16(); u8 n = RD8(); u16 ar = RD16();
      const VMFunc *g = &funcs[fi];
      cf->ret_ip = ip;
      CFrame *nf = cpush();
      cf = &cstack[cdepth - 2]; // cpush may realloc
      nf->func = fi;
      nf->dst = d;
      nf->slots = frame_alloc(g->nlocals, &nf->chunk, &nf->top_before);
      nf->cap = g->nlocals;
      memset(nf->slots, 0, g->nlocals * sizeof(pf));
      memcpy(nf->slots, cf->slots + b, n * sizeof(pf));
      areg = PF_FIX(ar);
      cf = nf;
      fn = g;
      un = g->unit;
      code = un->code + g->code_off;
      ip = 0;
      break;
    }
    case OP_TCALL: case OP_TCALLI: {
      PVM_SAFEPOINT();
      u32 fi;
      if (op == OP_TCALL) {
        fi = un->func_base + RD16();
      } else {
        u16 fs = RD16();
        pf v = cf->slots[fs];
        if ((v & PF_TAG_MASK) != PF_TAG_FIXNUM || (u64)PF_UNFIX(v) >= total_funcs)
          pf_fatal("application of a non-procedure");
        fi = (u32)PF_UNFIX(v);
      }
      u16 b = RD16(); u8 n = RD8(); u16 ar = RD16();
      const VMFunc *g = &funcs[fi];
      if (g->nlocals <= cf->cap) {
        // frame reuse in place: staging slots sit at or above the
        // formal slots, so a forward memmove is safe
        memmove(cf->slots, cf->slots + b, n * sizeof(pf));
      } else {
        pf tmp[8];
        memcpy(tmp, cf->slots + b, n * sizeof(pf));
        frame_free(cf->chunk, cf->top_before);
        cf->slots = frame_alloc(g->nlocals, &cf->chunk, &cf->top_before);
        cf->cap = g->nlocals;
        memset(cf->slots, 0, g->nlocals * sizeof(pf));
        memcpy(cf->slots, tmp, n * sizeof(pf));
      }
      cf->func = fi;
      areg = PF_FIX(ar);
      fn = g;
      un = g->unit;
      code = un->code + g->code_off;
      ip = 0;
      break;
    }
    case OP_PRIM: {
      u16 d = RD16(), p = RD16(), b = RD16(); u8 n = RD8();
      if (p >= VM_PRIM_COUNT) vm_die("prim id out of range");
      const vm_prim *pr = &vm_prims[p];
      pf *a = cf->slots + b;
      pf res;
      switch (n) {
      case 0: res = ((fn0)pr->fn)(); break;
      case 1: res = ((fn1)pr->fn)(a[0]); break;
      case 2: res = ((fn2)pr->fn)(a[0], a[1]); break;
      case 3: res = ((fn3)pr->fn)(a[0], a[1], a[2]); break;
      default: vm_die("prim arity out of range"); res = PF_VOID;
      }
      cf->slots[d] = res;
      break;
    }
    case OP_COLLECT: {
      u16 d = RD16(); u8 k = RD8();
      memcpy(pf_arg_spill, cf->slots, 6 * sizeof(pf));
      cf->slots[d] = pf_collect_rest(PF_FIX(k), areg);
      break;
    }
    case OP_UGET: { u16 d = RD16(), a = RD16(); u8 i = RD8(); cf->slots[d] = pf_heap_ptr(cf->slots[a])[1 + i]; break; }
    case OP_USET: { u16 a = RD16(); u8 i = RD8(); u16 s = RD16(); pf_heap_ptr(cf->slots[a])[1 + i] = cf->slots[s]; break; }
    case OP_GGET: {
      u16 d = RD16(), g = RD16();
      if (un->cells) {
        pf v = *un->cells[g];
        if (v == PF_UNDEF) {
          char msg[256];
          snprintf(msg, sizeof msg, "%s: undefined; cannot reference an identifier before its definition",
                   un->gnames[g]);
          pf_fatal(msg);
        }
        cf->slots[d] = v;
      } else {
        cf->slots[d] = un->globals[g];
      }
      break;
    }
    case OP_GSET: {
      u16 g = RD16(), s = RD16();
      if (un->cells) *un->cells[g] = cf->slots[s];
      else un->globals[g] = cf->slots[s];
      break;
    }
    case OP_RESULT: { u16 s = RD16(); vm_deliver_result(cf->slots[s]); break; }
    case OP_RET: {
      u16 s = RD16();
      pf v = cf->slots[s];
      frame_free(cf->chunk, cf->top_before);
      u32 rd = cf->dst;
      cdepth--;
      if (cdepth == 0) return v;
      cf = &cstack[cdepth - 1];
      cf->slots[rd] = v;
      fn = &funcs[cf->func];
      un = fn->unit;
      code = un->code + fn->code_off;
      ip = cf->ret_ip;
      break;
    }
    default:
      fflush(stdout);
      fprintf(stderr, "puffin-vm: illegal opcode 0x%02x at %s+%u\n", op, fn->name, ip - 1);
      exit(255);
    }
  }
}

// Load, link, and run one unit in the current session. v1 units
// print their entry result (the native conclusion); v2 REPL units'
// mains return void -- their results already flowed through RESULT.
static pf run_unit_bytes(const u8 *buf, size_t len) {
  Unit *u = load_unit(buf, len);
  finish_unit(u);
  pf result = vm_run(u->func_base + u->entry);
  if (u->version == PBC_VERSION) pf_print_result(result);
  return result;
}

// ---------------------------------------------------------------
// Reactor entry points (wasm REPL sessions; docs/WASM-VM.md §5.2).
// Built with -DPVM_REACTOR -mexec-model=reactor (`make wasm-repl`):
// the host instantiates once, calls pvm_boot once, then
// pvm_alloc+pvm_load_run per eval. Aborts (pf_error/pf_fatal ->
// __wrap_exit -> host_abort throw) unwind to the host, which
// restores __stack_pointer and keeps the instance: the heap, the
// interned symbols, and the session cells survive; pvm_load_run
// resets the frame stacks on entry.
// ---------------------------------------------------------------

#ifdef PVM_REACTOR

__attribute__((export_name("pvm_boot")))
void pvm_boot(void) {
  static char *repl_argv[] = { (char *)"repl", NULL };
  extern void pf_set_args(int argc, char **argv); // lib/io.c
  pf_set_args(1, repl_argv);
  const char *depth = getenv("PUFFIN_VM_MAX_DEPTH");
  if (depth) cmax = (size_t)atoll(depth);
  pf_init();
}

__attribute__((export_name("pvm_alloc")))
void *pvm_alloc(int32_t n) {
  return xmalloc((size_t)(n > 0 ? n : 1));
}

__attribute__((export_name("pvm_load_run")))
int32_t pvm_load_run(uint8_t *buf, int32_t len) {
  reset_exec_state();
  run_unit_bytes(buf, (size_t)len);
  free(buf);
  fflush(stdout);
  return 0;
}

#else // ---- native / command-model build ---------------------------

// ---------------------------------------------------------------
// Disassembler (puffin-vm -d unit.pbc): the debugging surface that
// replaces reading .s files.
// ---------------------------------------------------------------

static void disassemble(Unit *u) {
  printf("puffin bytecode unit, version %u\n", u->version);
  printf("symbols (%u):", u->nsyms);
  for (u32 i = 0; i < u->nsyms; i++) printf(" %u=%s", i, u->symnames[i]);
  printf("\nstrings (%u):", u->nstrs);
  for (u32 i = 0; i < u->nstrs; i++) printf(" %u=%.20s", i, u->strs[i]);
  printf("\nglobals: %u", u->nglobals);
  if (u->gnames) {
    printf(" (named:");
    for (u32 i = 0; i < u->nglobals; i++) printf(" %u=%s", i, u->gnames[i]);
    printf(")");
  }
  printf("\nentry: %u (%s)\n", u->entry, funcs[u->func_base + u->entry].name);
  for (u32 fidx = 0; fidx < u->nfuncs; fidx++) {
    VMFunc *fn = &funcs[u->func_base + fidx];
    printf("\n[%u] %s: formals=%u%s locals=%u code=%u bytes\n",
           fidx, fn->name, fn->nformals,
           fn->variadic ? " variadic" : "", fn->nlocals, fn->code_len);
    const u8 *code = u->code + fn->code_off;
    u32 ip = 0;
    while (ip < fn->code_len) {
      printf("  %4u  ", ip);
      u8 op = RD8();
      switch (op) {
      case OP_MOV:  { u16 d = RD16(), s = RD16(); printf("mov   r%u, r%u\n", d, s); break; }
      case OP_IMM:  { u16 d = RD16(); i64 w = RD64(); printf("imm   r%u, %" PRId64 "\n", d, w); break; }
      case OP_IMM8: { u16 d = RD16(); i64 w = (int8_t)RD8(); printf("imm8  r%u, %" PRId64 "\n", d, w); break; }
      case OP_SYM:  { u16 d = RD16(), i = RD16(); printf("sym   r%u, %s\n", d, u->symnames[i]); break; }
      case OP_STR:  { u16 d = RD16(), i = RD16(); printf("str   r%u, \"%.20s\"\n", d, u->strs[i]); break; }
      case OP_FUNREF: { u16 d = RD16(), i = RD16(); printf("fnref r%u, %s\n", d, funcs[u->func_base + i].name); break; }
      case OP_NEG:  { u16 d = RD16(), a = RD16(); printf("neg   r%u, r%u\n", d, a); break; }
      case OP_ADD:  { u16 d = RD16(), a = RD16(), b = RD16(); printf("add   r%u, r%u, r%u\n", d, a, b); break; }
      case OP_MUL:  { u16 d = RD16(), a = RD16(), b = RD16(); printf("mul   r%u, r%u, r%u\n", d, a, b); break; }
      case OP_LT:   { u16 d = RD16(), a = RD16(), b = RD16(); printf("lt    r%u, r%u, r%u\n", d, a, b); break; }
      case OP_EQ:   { u16 d = RD16(), a = RD16(), b = RD16(); printf("eq    r%u, r%u, r%u\n", d, a, b); break; }
      case OP_JMP:  { u32 off = RD32(); printf("jmp   %u\n", off); break; }
      case OP_BREQ: case OP_BRLT: case OP_BRLE: case OP_BRGT: case OP_BRGE: {
        static const char *cc[] = {"eq", "lt", "le", "gt", "ge"};
        u16 a = RD16(), b = RD16(); u32 off = RD32();
        printf("br.%s r%u, r%u, %u\n", cc[op - OP_BREQ], a, b, off);
        break;
      }
      case OP_CALL:  { u16 d = RD16(), i = RD16(), b = RD16(); u8 n = RD8(); u16 ar = RD16();
        printf("call  r%u, %s, base=r%u, n=%u, arity=%u\n", d, funcs[u->func_base + i].name, b, n, ar); break; }
      case OP_CALLI: { u16 d = RD16(), s = RD16(), b = RD16(); u8 n = RD8(); u16 ar = RD16();
        printf("calli r%u, r%u, base=r%u, n=%u, arity=%u\n", d, s, b, n, ar); break; }
      case OP_TCALL: { u16 i = RD16(), b = RD16(); u8 n = RD8(); u16 ar = RD16();
        printf("tcall %s, base=r%u, n=%u, arity=%u\n", funcs[u->func_base + i].name, b, n, ar); break; }
      case OP_TCALLI: { u16 s = RD16(), b = RD16(); u8 n = RD8(); u16 ar = RD16();
        printf("tcalli r%u, base=r%u, n=%u, arity=%u\n", s, b, n, ar); break; }
      case OP_PRIM: { u16 d = RD16(), p = RD16(), b = RD16(); u8 n = RD8();
        printf("prim  r%u, %s, base=r%u, n=%u\n", d, p < VM_PRIM_COUNT ? vm_prims[p].name : "?", b, n); break; }
      case OP_COLLECT: { u16 d = RD16(); u8 k = RD8(); printf("collect r%u, kfixed=%u\n", d, k); break; }
      case OP_UGET: { u16 d = RD16(), a = RD16(); u8 i = RD8(); printf("uget  r%u, r%u[%u]\n", d, a, i); break; }
      case OP_USET: { u16 a = RD16(); u8 i = RD8(); u16 s = RD16(); printf("uset  r%u[%u], r%u\n", a, i, s); break; }
      case OP_GGET: { u16 d = RD16(), g = RD16();
        if (u->gnames) printf("gget  r%u, g%u (%s)\n", d, g, u->gnames[g]);
        else printf("gget  r%u, g%u\n", d, g);
        break; }
      case OP_GSET: { u16 g = RD16(), s = RD16();
        if (u->gnames) printf("gset  g%u (%s), r%u\n", g, u->gnames[g], s);
        else printf("gset  g%u, r%u\n", g, s);
        break; }
      case OP_RET:  { u16 s = RD16(); printf("ret   r%u\n", s); break; }
      case OP_RESULT: { u16 s = RD16(); printf("result r%u\n", s); break; }
      default: printf("??    0x%02x\n", op); return;
      }
    }
  }
}

// ---------------------------------------------------------------
// Entry
// ---------------------------------------------------------------

extern void pf_set_args(int argc, char **argv); // lib/io.c

static u8 *read_file_bytes(const char *path, size_t *len_out) {
  FILE *f = fopen(path, "rb");
  if (!f) { fflush(stdout); fprintf(stderr, "puffin-vm: cannot open %s\n", path); exit(2); }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  u8 *buf = xmalloc(n > 0 ? (size_t)n : 1);
  if (n > 0 && fread(buf, 1, (size_t)n, f) != (size_t)n) vm_die("short read");
  fclose(f);
  *len_out = (size_t)(n > 0 ? n : 0);
  return buf;
}

int main(int argc, char **argv) {
  int dis = 0, session = 0;
  const char *path = NULL;
  int path_idx = 0;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-d") == 0) dis = 1;
    else if (strcmp(argv[i], "--session") == 0) session = 1;
    else if (!path) { path = argv[i]; path_idx = i; }
  }
  if (!path) {
    fprintf(stderr, "usage: puffin-vm [-d] prog.pbc [args...]\n"
                    "       puffin-vm --session u1.pbc [u2.pbc ...]\n");
    return 2;
  }
  // Forward the hosted program's own argv: argv[0] = the unit path,
  // argv[1..] = everything after it. So (command-line-args) inside the
  // running unit — e.g. puffincc compiling under the VM — sees its own
  // args, not the VM's. (The io.c ctor captured the VM's raw argv.)
  // In session mode every trailing argument is another unit, so the
  // hosted argv is just the first unit's path.
  pf_set_args(session ? 1 : argc - path_idx, &argv[path_idx]);
  const char *depth = getenv("PUFFIN_VM_MAX_DEPTH");
  if (depth) cmax = (size_t)atoll(depth);

  if (dis) {
    size_t n;
    u8 *buf = read_file_bytes(path, &n);
    Unit *u = load_unit(buf, n);
    disassemble(u);
    return 0;
  }

  pf_init();
  if (session) {
    // one session, many units: load+run each in order, one heap, one
    // cell table -- the native mirror of the browser REPL
    for (int i = path_idx; i < argc; i++) {
      if (strcmp(argv[i], "--session") == 0) continue;
      size_t n;
      u8 *buf = read_file_bytes(argv[i], &n);
      run_unit_bytes(buf, n);
      free(buf);
      reset_exec_state();
    }
    return 0;
  }
  size_t n;
  u8 *buf = read_file_bytes(path, &n);
  run_unit_bytes(buf, n);
  return 0;
}

#endif // PVM_REACTOR
