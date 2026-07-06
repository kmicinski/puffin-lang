// core.c -- the Puffin runtime core.
//
// Owns exactly the things generated code and every library module
// depend on, and nothing else:
//   - GC initialization and allocation helpers (Boehm / bdw-gc)
//   - the kind registry (display + equal dispatch)
//   - fatal errors
//   - symbol interning (the compiler emits puffin_symbol_names)
//   - string constants (the compiler emits puffin_string_consts;
//     the string *type* itself lives in lib/strings.c)
//   - closures (generated code allocates them inline via
//     pf_make_closure; their layout is a codegen concern)
//   - basic I/O: pf_read_int, pf_display/println/newline,
//     pf_print_result, pf_error
//
// Everything with library flavor (pairs, vectors, strings, hashes,
// sets, ...) lives in lib/, registered through puffin.h's registry.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include <gc.h>
#include "puffin.h"

// ---------------------------------------------------------------
// Errors
// ---------------------------------------------------------------

void pf_fatal(const char *msg) {
  fflush(stdout);
  fprintf(stderr, "puffin runtime error: %s\n", msg);
  exit(255);
}

void pf_die_oob(void)   { pf_fatal("index out of range"); }
void pf_die_kind(void)  { pf_fatal("operation applied to a value of the wrong type"); }
void pf_die_arith(void) { pf_fatal("arithmetic error"); }

// ---------------------------------------------------------------
// Allocation
// ---------------------------------------------------------------

pf pf_alloc(int kind, int64_t len, int64_t payload_bytes) {
  int64_t *obj = (int64_t *)GC_MALLOC(8 + payload_bytes);
  obj[0] = pf_header(kind, len);
  return pf_heap_ref(obj);
}

pf pf_alloc_atomic(int kind, int64_t len, int64_t payload_bytes) {
  int64_t *obj = (int64_t *)GC_MALLOC_ATOMIC(8 + payload_bytes);
  obj[0] = pf_header(kind, len);
  return pf_heap_ref(obj);
}

void *pf_alloc_raw(int64_t bytes) { return GC_MALLOC(bytes); }

// ---------------------------------------------------------------
// Kind registry
// ---------------------------------------------------------------

static pf_kind_desc kinds[PF_KIND_MAX];

void pf_register_kind(int kind, const pf_kind_desc *desc) {
  if (kind < 1 || kind >= PF_KIND_MAX) pf_fatal("pf_register_kind: kind id out of range");
  kinds[kind] = *desc;
}

// ---------------------------------------------------------------
// Symbols
// ---------------------------------------------------------------

extern const char *puffin_symbol_names[] __attribute__((weak));
extern int64_t puffin_symbol_count __attribute__((weak));

static const char **symbol_names = NULL;
static int64_t symbol_count = 0, symbol_cap = 0;

int64_t pf_intern_symbol(const char *name) {
  for (int64_t i = 0; i < symbol_count; i++)
    if (strcmp(symbol_names[i], name) == 0) return i;
  if (symbol_count == symbol_cap) {
    symbol_cap = symbol_cap ? symbol_cap * 2 : 64;
    const char **grown = (const char **)GC_MALLOC(symbol_cap * sizeof(char *));
    memcpy(grown, symbol_names, symbol_count * sizeof(char *));
    symbol_names = grown;
  }
  char *copy = (char *)GC_MALLOC_ATOMIC(strlen(name) + 1);
  strcpy(copy, name);
  symbol_names[symbol_count] = copy;
  return symbol_count++;
}

const char *pf_symbol_name(pf sym) {
  int64_t id = sym >> 3;
  if (id < 0 || id >= symbol_count) pf_fatal("corrupt symbol");
  return symbol_names[id];
}

// ---------------------------------------------------------------
// String constants (emitted by the compiler; see dump passes).
// pf_string_const returns the i-th literal as a heap string, made
// by lib/strings.c's pf_string_from_bytes.
// ---------------------------------------------------------------

extern const char *puffin_string_consts[] __attribute__((weak));
extern int64_t puffin_string_const_count __attribute__((weak));

extern pf pf_string_from_bytes(const char *bytes, int64_t n); // lib/strings.c

static pf *string_const_cache = NULL;

pf pf_string_const(pf idx) {
  int64_t i = PF_UNFIX(idx);
  if (i < 0 || i >= puffin_string_const_count) pf_die_oob();
  if (string_const_cache[i] == 0)
    string_const_cache[i] = pf_string_from_bytes(puffin_string_consts[i],
                                                 strlen(puffin_string_consts[i]));
  return string_const_cache[i];
}

// ---------------------------------------------------------------
// Init: called first thing by the generated main.
// ---------------------------------------------------------------

extern void pf_stdlib_init(void); // lib/stdlib_init.c

void pf_init(void) {
  GC_INIT();
  pf_stdlib_init();
  if (&puffin_symbol_count && puffin_symbol_names) {
    for (int64_t i = 0; i < puffin_symbol_count; i++)
      pf_intern_symbol(puffin_symbol_names[i]);
  }
  if (&puffin_string_const_count && puffin_string_const_count > 0) {
    string_const_cache = (pf *)pf_alloc_raw(puffin_string_const_count * sizeof(pf));
    memset(string_const_cache, 0, puffin_string_const_count * sizeof(pf));
  }
}

// ---------------------------------------------------------------
// Closures: laid out like vectors (header + slots) but with their
// own kind so they print as procedures and fail vector type checks.
// Slot 0 is a raw code pointer; the remaining slots are captured
// values. Generated code reads slots with unsafe-vector-ref.
// ---------------------------------------------------------------

pf pf_make_closure(pf len) {
  int64_t n = PF_UNFIX(len);
  pf v = pf_alloc(PF_KIND_CLOSURE, n, n * 8);
  for (int64_t i = 0; i < n; i++) pf_heap_ptr(v)[1 + i] = PF_FIX(0);
  return v;
}

// ---------------------------------------------------------------
// Display / equal, dispatching through the registry
// ---------------------------------------------------------------

void pf_display_value_to(pf v, FILE *out) {
  switch (v & PF_TAG_MASK) {
  case PF_TAG_FIXNUM:
    fprintf(out, "%" PRId64, PF_UNFIX(v));
    return;
  case PF_TAG_SYMBOL:
    fprintf(out, "%s", pf_symbol_name(v));
    return;
  case PF_TAG_IMM:
    switch (v) {
    case PF_FALSE: fprintf(out, "#f"); return;
    case PF_TRUE:  fprintf(out, "#t"); return;
    case PF_VOID:  fprintf(out, "#<void>"); return;
    case PF_NIL:   fprintf(out, "()"); return;
    default:       fprintf(out, "#<imm:%" PRId64 ">", v); return;
    }
  case PF_TAG_HEAP: {
    int k = pf_kind_of(v);
    if (k == PF_KIND_CLOSURE) { fprintf(out, "#<procedure>"); return; }
    if (k > 0 && k < PF_KIND_MAX && kinds[k].name) {
      if (kinds[k].display) kinds[k].display(v, out);
      else fprintf(out, "#<%s>", kinds[k].name);
      return;
    }
    fprintf(out, "#<unknown:%d>", k);
    return;
  }
  }
}

pf pf_equal(pf a, pf b) {
  if (a == b) return PF_TRUE;
  if (!pf_is_heap(a) || !pf_is_heap(b)) return PF_FALSE;
  int k = pf_kind_of(a);
  if (k != pf_kind_of(b)) return PF_FALSE;
  if (k > 0 && k < PF_KIND_MAX && kinds[k].equal) return kinds[k].equal(a, b);
  return PF_FALSE;
}

// ---------------------------------------------------------------
// I/O
// ---------------------------------------------------------------

pf pf_read_int(void) {
  int64_t value;
  if (scanf("%" SCNd64, &value) != 1) {
    printf("Error: expected an integer. Exiting.");
    exit(1);
  }
  return PF_FIX(value);
}

pf pf_display(pf v) { pf_display_value(v); return PF_VOID; }
pf pf_newline(void) { printf("\n"); return PF_VOID; }
pf pf_println(pf v) { pf_display_value(v); printf("\n"); return PF_VOID; }

// The value of the program's main expression: print it (with
// newline) unless it is void--mirroring how a Racket module body
// treats its trailing expression.
pf pf_print_result(pf v) {
  if (v != PF_VOID) pf_println(v);
  return PF_VOID;
}

// (gensym base): a fresh symbol, interned as base + a counter that
// skips names already taken (so gensyms survive read-back).
pf pf_gensym(pf base) {
  static int64_t counter = 0;
  if ((base & PF_TAG_MASK) != PF_TAG_SYMBOL) pf_die_kind();
  const char *b = pf_symbol_name(base);
  char buf[256];
  for (;;) {
    counter++;
    snprintf(buf, sizeof buf, "%s%" PRId64, b, counter);
    int64_t before = symbol_count;
    int64_t id = pf_intern_symbol(buf);
    if (symbol_count > before) return (id << 3) | PF_TAG_SYMBOL; // fresh
  }
}

// (value->string v): render exactly as display would, into a string.
pf pf_to_string(pf v) {
  char *buf = NULL;
  size_t len = 0;
  FILE *mem = open_memstream(&buf, &len);
  if (!mem) pf_fatal("value->string: out of memory");
  pf_display_value_to(v, mem);
  fclose(mem);
  pf s = pf_string_from_bytes(buf, (int64_t)len);
  free(buf);
  return s;
}

// (read-all): the rest of standard input, as one string (the seed
// for a Puffin-written reader).
pf pf_read_all(void) {
  char *buf = NULL;
  size_t cap = 0, len = 0;
  char chunk[4096];
  size_t got;
  while ((got = fread(chunk, 1, sizeof chunk, stdin)) > 0) {
    if (len + got > cap) {
      cap = (cap ? cap * 2 : 8192);
      if (cap < len + got) cap = len + got;
      buf = realloc(buf, cap);
      if (!buf) pf_fatal("read-all: out of memory");
    }
    memcpy(buf + len, chunk, got);
    len += got;
  }
  pf s = pf_string_from_bytes(buf ? buf : "", (int64_t)len);
  free(buf);
  return s;
}

// (error v): display the value and abort with exit code 1. The
// message goes to stdout so golden tests see identical output from
// the native binary and the interpreters.
pf pf_error(pf v) {
  printf("error: ");
  pf_display_value(v);
  printf("\n");
  fflush(stdout);
  exit(1);
}
