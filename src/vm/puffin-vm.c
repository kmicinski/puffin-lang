// puffin-vm.c -- the Puffin bytecode VM (docs/WASM-VM.md M2, native
// build; docs/BYTECODE.md is the format contract).
//
//   puffin-vm prog.pbc [args...]     load and run a unit
//   puffin-vm -d prog.pbc            disassemble a unit
//
// Design (docs/WASM-VM.md §3):
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
//  - M2 uses Boehm as-is (native build); the linear-memory collector
//    with safepoint discipline is M4's work.

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
extern void *pf_alloc_raw(int64_t);

// Boehm: frame chunks are malloc'd and registered as root regions
// (allocating 8 MB blocks from the GC heap itself trips its
// large-block warning on stderr, and frame slots are roots, not
// collectable objects).
extern void GC_add_roots(void *low, void *high_plus_1);

// The compiler's whole-program literal tables are weak externs in
// core.c; the VM interns literals itself (per unit, at load time),
// so it supplies empty definitions to keep the linker happy.
const char *puffin_symbol_names[1] = {0};
int64_t puffin_symbol_count = 0;
const char *puffin_string_consts[1] = {0};
int64_t puffin_string_const_count = 0;

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
  OP_RET = 0x1C,
};

#define PBC_VERSION 1

// ---------------------------------------------------------------
// The unit
// ---------------------------------------------------------------

typedef struct {
  char *name;      // diagnostics
  u32 nformals;
  u8 variadic;
  u8 kfixed;
  u32 nlocals;     // total frame slots (>= 6)
  u32 code_off;
  u32 code_len;
} VMFunc;

typedef struct {
  u32 nsyms;   pf *symvals;          // unit symbol id -> tagged symbol
  u32 nstrs;   char **strs; u32 *strlens;
  pf *strcache;                      // lazy per-unit heap strings
  u32 nglobals; pf *globals;
  u32 nfuncs;  VMFunc *funcs;
  u32 entry;
  u8 *code;    u32 code_len;
} Unit;

// Static so the GC's data-segment scan roots the globals array, the
// string cache, and (transitively) the frame chunks.
static Unit U;

static void vm_die(const char *msg) {
  fprintf(stderr, "puffin-vm: %s\n", msg);
  exit(255);
}

// ---- loader -----------------------------------------------------

typedef struct { const u8 *p, *end; } Rd;

static u8  rd_u8(Rd *r)  { if (r->p + 1 > r->end) vm_die("truncated unit"); return *r->p++; }
static u16 rd_u16(Rd *r) { if (r->p + 2 > r->end) vm_die("truncated unit"); u16 v; memcpy(&v, r->p, 2); r->p += 2; return v; }
static u32 rd_u32(Rd *r) { if (r->p + 4 > r->end) vm_die("truncated unit"); u32 v; memcpy(&v, r->p, 4); r->p += 4; return v; }
static char *rd_lstr(Rd *r, u32 *len_out) {
  u32 n = rd_u32(r);
  if (r->p + n > r->end) vm_die("truncated unit");
  char *s = malloc(n + 1);
  if (!s) vm_die("out of memory");
  memcpy(s, r->p, n);
  s[n] = 0;
  r->p += n;
  if (len_out) *len_out = n;
  return s;
}

// Parse the malloc'd side of the unit (no GC yet: called before
// pf_init so nothing here may allocate GC memory).
static char **sym_names_tmp; // interned after pf_init

static void load_unit(const u8 *buf, size_t len) {
  Rd r = {buf, buf + len};
  if (len < 12 || buf[0] != 'P' || buf[1] != 'U' || buf[2] != 'F' || buf[3] != 1)
    vm_die("not a Puffin bytecode unit (bad magic)");
  r.p += 4;
  u32 version = rd_u32(&r);
  if (version != PBC_VERSION) {
    fprintf(stderr, "puffin-vm: unit version %u, this VM implements %u\n", version, PBC_VERSION);
    exit(255);
  }
  rd_u32(&r); // reserved
  U.nsyms = rd_u32(&r);
  sym_names_tmp = malloc(sizeof(char *) * (U.nsyms ? U.nsyms : 1));
  for (u32 i = 0; i < U.nsyms; i++) sym_names_tmp[i] = rd_lstr(&r, NULL);
  U.nstrs = rd_u32(&r);
  U.strs = malloc(sizeof(char *) * (U.nstrs ? U.nstrs : 1));
  U.strlens = malloc(sizeof(u32) * (U.nstrs ? U.nstrs : 1));
  for (u32 i = 0; i < U.nstrs; i++) U.strs[i] = rd_lstr(&r, &U.strlens[i]);
  U.nglobals = rd_u32(&r);
  U.nfuncs = rd_u32(&r);
  U.funcs = malloc(sizeof(VMFunc) * (U.nfuncs ? U.nfuncs : 1));
  for (u32 i = 0; i < U.nfuncs; i++) {
    VMFunc *f = &U.funcs[i];
    f->name = rd_lstr(&r, NULL);
    f->nformals = rd_u32(&r);
    f->variadic = rd_u8(&r);
    f->kfixed = rd_u8(&r);
    rd_u16(&r); // pad
    f->nlocals = rd_u32(&r);
    f->code_off = rd_u32(&r);
    f->code_len = rd_u32(&r);
    if (f->nlocals < 6) vm_die("function frame smaller than 6 slots");
  }
  U.entry = rd_u32(&r);
  if (U.entry >= U.nfuncs) vm_die("entry index out of range");
  U.code_len = rd_u32(&r);
  if (r.p + U.code_len > r.end) vm_die("truncated code section");
  U.code = malloc(U.code_len ? U.code_len : 1);
  memcpy(U.code, r.p, U.code_len);
  for (u32 i = 0; i < U.nfuncs; i++)
    if ((u64)U.funcs[i].code_off + U.funcs[i].code_len > U.code_len)
      vm_die("function code out of range");
}

// GC-side unit finalization: intern symbols, seed globals/caches.
static void finish_unit(void) {
  U.symvals = pf_alloc_raw(sizeof(pf) * (U.nsyms ? U.nsyms : 1));
  for (u32 i = 0; i < U.nsyms; i++)
    U.symvals[i] = (pf_intern_symbol(sym_names_tmp[i]) << 3) | PF_TAG_SYMBOL;
  U.strcache = pf_alloc_raw(sizeof(pf) * (U.nstrs ? U.nstrs : 1));
  memset(U.strcache, 0, sizeof(pf) * (U.nstrs ? U.nstrs : 1));
  U.globals = pf_alloc_raw(sizeof(pf) * (U.nglobals ? U.nglobals : 1));
  memset(U.globals, 0, sizeof(pf) * (U.nglobals ? U.nglobals : 1)); // PF_FIX(0), like native .space
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
  GC_add_roots(c->slots, c->slots + cap);
  return c;
}

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
  u32 func;      // function index
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

// ---------------------------------------------------------------
// The dispatch loop
// ---------------------------------------------------------------

static pf vm_run(void) {
  const VMFunc *fn = &U.funcs[U.entry];
  CFrame *cf = cpush();
  cf->func = U.entry;
  cf->ret_ip = 0;
  cf->dst = 0;
  cf->slots = frame_alloc(fn->nlocals, &cf->chunk, &cf->top_before);
  cf->cap = fn->nlocals;
  memset(cf->slots, 0, fn->nlocals * sizeof(pf));

  const u8 *code = U.code + fn->code_off;
  u32 ip = 0;
  pf areg = PF_FIX(0); // the arity register (native r10/x12)

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
    case OP_SYM: { u16 d = RD16(), i = RD16(); cf->slots[d] = U.symvals[i]; break; }
    case OP_STR: {
      u16 d = RD16(), i = RD16();
      if (U.strcache[i] == 0)
        U.strcache[i] = pf_string_from_bytes(U.strs[i], (int64_t)U.strlens[i]);
      cf->slots[d] = U.strcache[i];
      break;
    }
    case OP_FUNREF: { u16 d = RD16(), f = RD16(); cf->slots[d] = PF_FIX(f); break; }
    case OP_NEG: { u16 d = RD16(), a = RD16(); cf->slots[d] = (pf)(0 - (u64)cf->slots[a]); break; }
    case OP_ADD: { u16 d = RD16(), a = RD16(), b = RD16(); cf->slots[d] = (pf)((u64)cf->slots[a] + (u64)cf->slots[b]); break; }
    case OP_MUL: { u16 d = RD16(), a = RD16(), b = RD16(); cf->slots[d] = (pf)((u64)(cf->slots[a] >> 3) * (u64)cf->slots[b]); break; }
    case OP_LT:  { u16 d = RD16(), a = RD16(), b = RD16(); cf->slots[d] = PF_BOOL(cf->slots[a] < cf->slots[b]); break; }
    case OP_EQ:  { u16 d = RD16(), a = RD16(), b = RD16(); cf->slots[d] = PF_BOOL(cf->slots[a] == cf->slots[b]); break; }
    case OP_JMP: { u32 off = RD32(); ip = off; break; }
    case OP_BREQ: { u16 a = RD16(), b = RD16(); u32 off = RD32(); if (cf->slots[a] == cf->slots[b]) ip = off; break; }
    case OP_BRLT: { u16 a = RD16(), b = RD16(); u32 off = RD32(); if (cf->slots[a] <  cf->slots[b]) ip = off; break; }
    case OP_BRLE: { u16 a = RD16(), b = RD16(); u32 off = RD32(); if (cf->slots[a] <= cf->slots[b]) ip = off; break; }
    case OP_BRGT: { u16 a = RD16(), b = RD16(); u32 off = RD32(); if (cf->slots[a] >  cf->slots[b]) ip = off; break; }
    case OP_BRGE: { u16 a = RD16(), b = RD16(); u32 off = RD32(); if (cf->slots[a] >= cf->slots[b]) ip = off; break; }
    case OP_CALL: case OP_CALLI: {
      u16 d = RD16();
      u32 fi;
      if (op == OP_CALL) {
        fi = RD16();
      } else {
        u16 fs = RD16();
        pf v = cf->slots[fs];
        if ((v & PF_TAG_MASK) != PF_TAG_FIXNUM || (u64)PF_UNFIX(v) >= U.nfuncs)
          pf_fatal("application of a non-procedure");
        fi = (u32)PF_UNFIX(v);
      }
      u16 b = RD16(); u8 n = RD8(); u16 ar = RD16();
      const VMFunc *g = &U.funcs[fi];
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
      code = U.code + g->code_off;
      ip = 0;
      break;
    }
    case OP_TCALL: case OP_TCALLI: {
      u32 fi;
      if (op == OP_TCALL) {
        fi = RD16();
      } else {
        u16 fs = RD16();
        pf v = cf->slots[fs];
        if ((v & PF_TAG_MASK) != PF_TAG_FIXNUM || (u64)PF_UNFIX(v) >= U.nfuncs)
          pf_fatal("application of a non-procedure");
        fi = (u32)PF_UNFIX(v);
      }
      u16 b = RD16(); u8 n = RD8(); u16 ar = RD16();
      const VMFunc *g = &U.funcs[fi];
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
      code = U.code + g->code_off;
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
    case OP_GGET: { u16 d = RD16(), g = RD16(); cf->slots[d] = U.globals[g]; break; }
    case OP_GSET: { u16 g = RD16(), s = RD16(); U.globals[g] = cf->slots[s]; break; }
    case OP_RET: {
      u16 s = RD16();
      pf v = cf->slots[s];
      frame_free(cf->chunk, cf->top_before);
      u32 rd = cf->dst;
      cdepth--;
      if (cdepth == 0) return v;
      cf = &cstack[cdepth - 1];
      cf->slots[rd] = v;
      fn = &U.funcs[cf->func];
      code = U.code + fn->code_off;
      ip = cf->ret_ip;
      break;
    }
    default:
      fprintf(stderr, "puffin-vm: illegal opcode 0x%02x at %s+%u\n", op, fn->name, ip - 1);
      exit(255);
    }
  }
}

// ---------------------------------------------------------------
// Disassembler (puffin-vm -d unit.pbc): the debugging surface that
// replaces reading .s files.
// ---------------------------------------------------------------

static void disassemble(void) {
  printf("puffin bytecode unit, version %u\n", PBC_VERSION);
  printf("symbols (%u):", U.nsyms);
  for (u32 i = 0; i < U.nsyms; i++) printf(" %u=%s", i, sym_names_tmp[i]);
  printf("\nstrings (%u):", U.nstrs);
  for (u32 i = 0; i < U.nstrs; i++) printf(" %u=%.20s", i, U.strs[i]);
  printf("\nglobals: %u\nentry: %u (%s)\n", U.nglobals, U.entry, U.funcs[U.entry].name);
  for (u32 f = 0; f < U.nfuncs; f++) {
    VMFunc *fn = &U.funcs[f];
    printf("\n[%u] %s: formals=%u%s locals=%u code=%u bytes\n",
           f, fn->name, fn->nformals,
           fn->variadic ? " variadic" : "", fn->nlocals, fn->code_len);
    const u8 *code = U.code + fn->code_off;
    u32 ip = 0;
    while (ip < fn->code_len) {
      printf("  %4u  ", ip);
      u8 op = RD8();
      switch (op) {
      case OP_MOV:  { u16 d = RD16(), s = RD16(); printf("mov   r%u, r%u\n", d, s); break; }
      case OP_IMM:  { u16 d = RD16(); i64 w = RD64(); printf("imm   r%u, %" PRId64 "\n", d, w); break; }
      case OP_IMM8: { u16 d = RD16(); i64 w = (int8_t)RD8(); printf("imm8  r%u, %" PRId64 "\n", d, w); break; }
      case OP_SYM:  { u16 d = RD16(), i = RD16(); printf("sym   r%u, %s\n", d, sym_names_tmp[i]); break; }
      case OP_STR:  { u16 d = RD16(), i = RD16(); printf("str   r%u, \"%.20s\"\n", d, U.strs[i]); break; }
      case OP_FUNREF: { u16 d = RD16(), i = RD16(); printf("fnref r%u, %s\n", d, U.funcs[i].name); break; }
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
        printf("call  r%u, %s, base=r%u, n=%u, arity=%u\n", d, U.funcs[i].name, b, n, ar); break; }
      case OP_CALLI: { u16 d = RD16(), s = RD16(), b = RD16(); u8 n = RD8(); u16 ar = RD16();
        printf("calli r%u, r%u, base=r%u, n=%u, arity=%u\n", d, s, b, n, ar); break; }
      case OP_TCALL: { u16 i = RD16(), b = RD16(); u8 n = RD8(); u16 ar = RD16();
        printf("tcall %s, base=r%u, n=%u, arity=%u\n", U.funcs[i].name, b, n, ar); break; }
      case OP_TCALLI: { u16 s = RD16(), b = RD16(); u8 n = RD8(); u16 ar = RD16();
        printf("tcalli r%u, base=r%u, n=%u, arity=%u\n", s, b, n, ar); break; }
      case OP_PRIM: { u16 d = RD16(), p = RD16(), b = RD16(); u8 n = RD8();
        printf("prim  r%u, %s, base=r%u, n=%u\n", d, p < VM_PRIM_COUNT ? vm_prims[p].name : "?", b, n); break; }
      case OP_COLLECT: { u16 d = RD16(); u8 k = RD8(); printf("collect r%u, kfixed=%u\n", d, k); break; }
      case OP_UGET: { u16 d = RD16(), a = RD16(); u8 i = RD8(); printf("uget  r%u, r%u[%u]\n", d, a, i); break; }
      case OP_USET: { u16 a = RD16(); u8 i = RD8(); u16 s = RD16(); printf("uset  r%u[%u], r%u\n", a, i, s); break; }
      case OP_GGET: { u16 d = RD16(), g = RD16(); printf("gget  r%u, g%u\n", d, g); break; }
      case OP_GSET: { u16 g = RD16(), s = RD16(); printf("gset  g%u, r%u\n", g, s); break; }
      case OP_RET:  { u16 s = RD16(); printf("ret   r%u\n", s); break; }
      default: printf("??    0x%02x\n", op); return;
      }
    }
  }
}

// ---------------------------------------------------------------
// Entry
// ---------------------------------------------------------------

int main(int argc, char **argv) {
  int dis = 0;
  const char *path = NULL;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-d") == 0) dis = 1;
    else if (!path) path = argv[i];
  }
  if (!path) {
    fprintf(stderr, "usage: puffin-vm [-d] prog.pbc [args...]\n");
    return 2;
  }
  const char *depth = getenv("PUFFIN_VM_MAX_DEPTH");
  if (depth) cmax = (size_t)atoll(depth);

  FILE *f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "puffin-vm: cannot open %s\n", path); return 2; }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  u8 *buf = malloc(n > 0 ? (size_t)n : 1);
  if (!buf) vm_die("out of memory");
  if (n > 0 && fread(buf, 1, (size_t)n, f) != (size_t)n) vm_die("short read");
  fclose(f);

  load_unit(buf, (size_t)n);
  if (dis) { disassemble(); return 0; }

  pf_init();
  finish_unit();
  pf result = vm_run();
  pf_print_result(result);
  return 0;
}
