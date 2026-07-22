// puffin.h -- the Puffin runtime ABI.
//
// This header is the *entire* contract between (a) the compiler's
// generated code, (b) the runtime core (core.c), and (c) standard
// library modules (lib/*.c). A stdlib module includes this header
// and nothing else from the runtime; the core includes this header
// and knows nothing about specific library modules. That is the
// pluggability story: new features are new lib/ modules + manifest
// entries in stdlib.rkt, with no edits to the core or the compiler
// passes.
//
// The tag scheme and heap layout here must stay in sync with
// system.rkt (compiler) and the interpreters. Change them in
// lockstep or not at all.
//
// -------------------------------------------------------------------
// Value representation
// -------------------------------------------------------------------
//
// A Puffin value ("pf") is a tagged 64-bit word. Low 3 bits:
//
//   000  fixnum        value is n << 3 (61-bit signed integers)
//   001  heap object   value is (object address | 1); see below
//   010  immediate     #f = 2, #t = 10, void = 18, '() = 26
//   011  symbol        value is (intern id << 3) | 3
//
// Because fixnums are n << 3: tagged +, -, eq?, and < work directly
// on tagged words, and a tagged fixnum index is already a byte
// offset into a vector's payload. The compiler exploits both.
//
// -------------------------------------------------------------------
// Heap objects
// -------------------------------------------------------------------
//
// Every heap object is GC-allocated (Boehm), 8-byte aligned:
//
//   | header (8 bytes) | payload ... |
//
//   header = (length << 8) | kind
//
// A heap *reference* is the object's address | 1. The Boehm GC is
// configured with interior pointers enabled, so a tagged reference
// keeps its object alive.

#ifndef PUFFIN_H
#define PUFFIN_H

#include <stdint.h>
#include <stdio.h>

typedef int64_t pf; // a tagged Puffin value

// ---- tags ---------------------------------------------------------

#define PF_TAG_MASK   7
#define PF_TAG_FIXNUM 0
#define PF_TAG_HEAP   1
#define PF_TAG_IMM    2
#define PF_TAG_SYMBOL 3

#define PF_FALSE   2
#define PF_TRUE    10
#define PF_VOID    18
#define PF_NIL     26

#define PF_FIX(n)   ((pf)((uint64_t)(n) << 3))
#define PF_UNFIX(v) ((v) >> 3)
#define PF_BOOL(b)  ((b) ? PF_TRUE : PF_FALSE)

// ---- heap object kinds --------------------------------------------
//
// Kinds 1-6 are *core kinds*: the compiler emits code that depends
// on their ids and layouts (vectors, pairs, closures) or the core
// itself does (strings). Library modules may claim kinds from
// PF_KIND_FIRST_EXT upward; ids are part of the module's manifest
// entry so they stay stable and documented.

#define PF_KIND_VECTOR  1
#define PF_KIND_PAIR    2
#define PF_KIND_STRING  3
#define PF_KIND_CLOSURE 4
#define PF_KIND_HASH    5
#define PF_KIND_SET     6
#define PF_KIND_FIRST_EXT 16
#define PF_KIND_MAX     64

static inline int64_t *pf_heap_ptr(pf v)    { return (int64_t *)(v - PF_TAG_HEAP); }
// Route the pointer->pf cast through uintptr_t, not intptr_t: on
// wasm32 intptr_t is 32-bit, so an address above 2 GB would
// sign-extend into the tag bits and corrupt the value. uintptr_t
// zero-extends. Native-safe (identical codegen on LP64). See
// docs/WASM-VM.md §2.1.
static inline pf       pf_heap_ref(void *p) { return ((pf)(uintptr_t)p) | PF_TAG_HEAP; }
static inline int      pf_is_heap(pf v)     { return (v & PF_TAG_MASK) == PF_TAG_HEAP; }
static inline int      pf_kind_of(pf v)     { return (int)(pf_heap_ptr(v)[0] & 0xFF); }
static inline int64_t  pf_len_of(pf v)      { return pf_heap_ptr(v)[0] >> 8; }
static inline int      pf_is_kind(pf v, int k) { return pf_is_heap(v) && pf_kind_of(v) == k; }
static inline int64_t  pf_header(int kind, int64_t len) { return (len << 8) | kind; }

// ---- core services available to library modules -------------------

// Allocate a heap object with `payload_bytes` bytes of payload; the
// header is filled in from kind/len. The _atomic variant promises
// the payload contains no Puffin values (e.g. string bytes), letting
// the GC skip scanning it.
pf pf_alloc(int kind, int64_t len, int64_t payload_bytes);
pf pf_alloc_atomic(int kind, int64_t len, int64_t payload_bytes);

// Raw GC memory for internal structures (e.g. a hash's slot arrays).
void *pf_alloc_raw(int64_t bytes);

// Fatal runtime errors: print `msg` to stderr and exit(255).
void pf_fatal(const char *msg) __attribute__((noreturn));
void pf_die_kind(void) __attribute__((noreturn));
void pf_die_oob(void) __attribute__((noreturn));
void pf_die_arith(void) __attribute__((noreturn));
// typed arithmetic error (lib/arith.c): names the operator and the
// offending value; a/b are the operands, the first non-fixnum is shown
void pf_die_arith_typed(const char *op, pf a, pf b) __attribute__((noreturn));

// Type-check helper: die unless v is a heap object of `kind`.
static inline void pf_expect_kind(pf v, int kind) {
  if (!pf_is_kind(v, kind)) pf_die_kind();
}

// Display a value (no newline) to `out`; recursively dispatches
// through the kind registry. (Streams, not stdout, so value->string
// can render into a memory buffer.)
void pf_display_value_to(pf v, FILE *out);
#define pf_display_value(v) pf_display_value_to((v), stdout)

// Structural equality (Puffin's equal?); dispatches through the
// kind registry. Returns PF_TRUE / PF_FALSE.
pf pf_equal(pf a, pf b);

// Structural hash, CONSISTENT with pf_equal: equal? values hash the
// same. Dispatches through the kind registry's `hash` handler (see
// pf_kind_desc); immediates/symbols/fixnums hash their canonical
// word, heap kinds without a hash handler hash by identity (matching
// their identity-only equal?). Used to key the immutable HAMT
// collections structurally. pf_mix64 is the fmix64 finalizer, a good
// 64-bit avalanche used to fold words together.
uint64_t pf_hash(pf v);
uint64_t pf_mix64(uint64_t x);

// Symbol interning (also used by string->symbol).
int64_t pf_intern_symbol(const char *name);
const char *pf_symbol_name(pf sym);

// ---- the kind registry --------------------------------------------
//
// A library module describes each heap kind it owns. The core uses
// the registry to display values, to implement equal?, and to give
// honest error messages. Register during your module's init hook
// (called from stdlib_init.c, before user code runs).

typedef struct {
  const char *name;              // e.g. "hash" -> prints #<hash ...> by default
  void (*display)(pf v, FILE *); // NULL: print #<name>
  pf (*equal)(pf a, pf b);       // NULL: identity only
  uint64_t (*hash)(pf v);        // NULL: identity hash (pf_mix64 of the word).
                                 // MUST be provided whenever `equal` is a
                                 // STRUCTURAL comparison, and consistent with
                                 // it: a==b (by equal) implies hash(a)==hash(b).
} pf_kind_desc;

void pf_register_kind(int kind, const pf_kind_desc *desc);

// Every stdlib module exports exactly one init hook, listed in
// lib/stdlib_init.c:
//   void pf_lib_<module>_init(void);

#endif // PUFFIN_H
