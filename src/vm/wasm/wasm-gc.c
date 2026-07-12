// wasm-gc.c -- the §3.3 collector (docs/WASM-VM.md §3.2/§3.3).
//
// STATUS: the real collector. A linear-memory, NON-MOVING mark-sweep
// over segregated size classes, behind the Boehm allocation ABI
// (GC_MALLOC zeroed / GC_MALLOC_ATOMIC unzeroed + pointer-free /
// GC_add_roots / GC_INIT no-op). ONE implementation compiles for both
// wasm32-wasi and the native gctest build; the only #ifdef is the
// wasm data+bss root scan, which native does not have (its roots are
// all explicitly registered -- see "Roots" below).
//
// Heap
//   - Size-class chunks: 256 KB regions carved into equal blocks of
//     one class (16..4096 bytes, 8-byte-stepped small / geometric
//     large); allocations above 4096 bytes get a dedicated chunk.
//     Chunk memory comes from libc malloc on BOTH targets -- on wasm
//     that is wasi-libc's dlmalloc, which grows linear memory via
//     sbrk/memory.grow and REUSES freed large chunks, so the memory
//     footprint stays bounded once the live set plateaus.
//   - Non-moving: eq?-as-address, tagged refs, and every layout
//     assumption in lib/*.c survive. Atomic blocks (strings, symbol
//     name copies) live in atomic chunks and are never scanned.
//   - Per-chunk alloc/mark bitmaps; per-(class, atomicity) freelists
//     threaded through the free blocks' first words. Small chunks are
//     retained after they empty (high-water heap per class, reused
//     forever -- wasm linear memory cannot shrink anyway); dead LARGE
//     chunks are free()d back to malloc immediately.
//
// Roots (all scanned conservatively, word by word)
//   1. Every GC_add_roots region: the VM's unit string caches, v1
//      globals arrays, session cell blocks (all rooted_alloc'd in
//      puffin-vm.c), plus the runtime's pf-holding statics, which
//      register THEMSELVES (core.c: symbol_names,
//      string_const_cache, pf_arg_spill; lib/hamt.c: the empty
//      hash/set singletons) so that the native build needs no
//      data-segment scan.
//   2. The VM frame stack's LIVE extent, via the pvm_gc_frame_roots
//      callback (puffin-vm.c walks chunk_head..chunk_cur up to each
//      chunk's top). Dead slots above top are not scanned -- this is
//      what keeps stress mode (collect at every safepoint) tractable.
//   3. wasm only: the data+bss segment [__global_base, __data_end),
//      mirroring Boehm's static-data scan -- belt and suspenders over
//      (1), and cover for any future pf-holding static.
//   The C stack is NOT scanned on either target. That is the point of
//   the safepoint rule, not an oversight (see below).
//
// Tracing: conservative within the heap. Any 64-bit word in a scanned
// block that decodes to a live allocated block marks it, under two
// decodings:
//   - tag 001 (pf heap ref): word-1 must be a block's BASE (tagged
//     refs always point at the header word; verified against every
//     pf_heap_ref call site);
//   - tag 000: the word itself must be a block's BASE -- this is a
//     raw pointer stored in a payload (hamt root/child nodes, table
//     key/val slot arrays, symbol_names). Fixnums share the tag; one
//     whose value*8 happens to hit a live block's base over-retains
//     it (Boehm's classic false positive, accepted).
//   Interior pointers are NOT recognized: nothing in the runtime
//   stores a pointer into the middle of a GC block across a safepoint
//   (transient interior pointers -- display cursors, memcpy sources --
//   live only inside prims, which never see a collection).
//
// THE SAFEPOINT RULE (load-bearing): collection happens ONLY inside
// pf_gc_collect(), which ONLY the VM's dispatch loop calls, between
// instructions (JMP/branch/call opcodes check pf_gc_wants_collect).
// GC_MALLOC never collects: past the budget it keeps allocating
// (grows) and sets pf_gc_wants_collect; the deficit is settled at the
// next safepoint. A pf held in a C local (equivalently, a wasm local)
// mid-prim is therefore never live across a collection -- the
// unscannable-locals problem is made unreachable, not solved.
// Documented failure mode: a single prim allocating unboundedly grows
// memory rather than collecting first, same class as native Boehm
// under one huge allocation.
//
// Budget: collect when allocation since the last GC exceeds
// max(4 MB, live bytes after the last GC) -- the heap roughly doubles
// between collections. PUFFIN_VM_GC_STRESS=1 collects at EVERY
// safepoint (the CI gate: tools/gctest-corpus.sh runs the corpus this
// way) and poisons freed blocks (0xAB) so use-after-free fails loudly.

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern void pf_fatal(const char *) __attribute__((noreturn));

// puffin-vm.c: visit the live extent of every frame-stack chunk.
extern void pvm_gc_frame_roots(void (*visit)(void *lo, void *hi));

// ---------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------

#define GC_CHUNK_BYTES  (256u * 1024u)          // payload per size-class chunk
#define GC_LARGE_MIN    4096u                   // above this: dedicated chunk
#define GC_MIN_BUDGET   (4u * 1024u * 1024u)    // floor of the collect trigger

static const uint32_t class_bytes[] = {
  16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256,
  320, 384, 448, 512, 640, 768, 896, 1024, 1280, 1536, 1792, 2048,
  2560, 3072, 3584, 4096,
};
#define NCLASSES ((uint32_t)(sizeof class_bytes / sizeof class_bytes[0]))

// size (rounded up to 8) -> class index, built once
static uint8_t class_of_qwords[GC_LARGE_MIN / 8 + 1];

// ---------------------------------------------------------------
// Chunks and the address index
// ---------------------------------------------------------------

typedef struct Chunk {
  struct Chunk *next;      // all-chunks list
  char *base;              // first block (16-aligned)
  uint32_t block_size;     // bytes per block
  uint32_t nblocks;        // 1 for large chunks
  uint32_t class_idx;      // NCLASSES => large
  uint8_t atomic;          // pointer-free blocks: never scanned
  uint8_t *alloc_bits;
  uint8_t *mark_bits;
} Chunk;

static Chunk *all_chunks = NULL;

// chunks sorted by base address, for pointer -> chunk lookup
static Chunk **cindex = NULL;
static uint32_t cindex_n = 0, cindex_cap = 0;
static uintptr_t heap_lo = UINTPTR_MAX, heap_hi = 0;

// free blocks, threaded through their first word: [class][atomic?]
static void *freelist[NCLASSES][2];

// accounting
static size_t bytes_since_gc = 0;   // allocation since the last collection
static size_t gc_budget = GC_MIN_BUDGET;
static size_t live_bytes = 0;       // measured during mark
static int gc_stress = 0;
static int gc_initialized = 0;
static int gc_collecting = 0;

int pf_gc_wants_collect = 0;        // the safepoint flag (see gc.h)

static inline int bit_test(const uint8_t *bits, uint32_t i) {
  return (bits[i >> 3] >> (i & 7)) & 1;
}
static inline void bit_set(uint8_t *bits, uint32_t i) {
  bits[i >> 3] |= (uint8_t)(1u << (i & 7));
}

static void gc_init_once(void) {
  if (gc_initialized) return;
  gc_initialized = 1;
  const char *s = getenv("PUFFIN_VM_GC_STRESS");
  gc_stress = (s && *s && strcmp(s, "0") != 0);
  if (gc_stress) pf_gc_wants_collect = 1;
  // build the size -> class table
  uint32_t ci = 0;
  for (uint32_t q = 0; q <= GC_LARGE_MIN / 8; q++) {
    while (q * 8 > class_bytes[ci]) ci++;
    class_of_qwords[q] = (uint8_t)ci;
  }
}

static void cindex_insert(Chunk *c) {
  if (cindex_n == cindex_cap) {
    cindex_cap = cindex_cap ? cindex_cap * 2 : 64;
    cindex = (Chunk **)realloc(cindex, cindex_cap * sizeof(Chunk *));
    if (!cindex) pf_fatal("gc: out of memory (chunk index)");
  }
  uint32_t lo = 0, hi = cindex_n;
  while (lo < hi) {
    uint32_t mid = (lo + hi) / 2;
    if ((uintptr_t)cindex[mid]->base < (uintptr_t)c->base) lo = mid + 1;
    else hi = mid;
  }
  memmove(cindex + lo + 1, cindex + lo, (cindex_n - lo) * sizeof(Chunk *));
  cindex[lo] = c;
  cindex_n++;
  uintptr_t b = (uintptr_t)c->base;
  uintptr_t e = b + (size_t)c->block_size * c->nblocks;
  if (b < heap_lo) heap_lo = b;
  if (e > heap_hi) heap_hi = e;
}

static void cindex_remove(Chunk *c) {
  for (uint32_t i = 0; i < cindex_n; i++) {
    if (cindex[i] == c) {
      memmove(cindex + i, cindex + i + 1, (cindex_n - i - 1) * sizeof(Chunk *));
      cindex_n--;
      return;
    }
  }
}

// the chunk containing address a, or NULL (a need not be a block base)
static Chunk *find_chunk(uintptr_t a) {
  uint32_t lo = 0, hi = cindex_n;
  while (lo < hi) {           // find first chunk with base > a
    uint32_t mid = (lo + hi) / 2;
    if ((uintptr_t)cindex[mid]->base <= a) lo = mid + 1;
    else hi = mid;
  }
  if (lo == 0) return NULL;
  Chunk *c = cindex[lo - 1];
  if (a >= (uintptr_t)c->base + (size_t)c->block_size * c->nblocks) return NULL;
  return c;
}

// One malloc per chunk: [Chunk][alloc bits][mark bits][pad][blocks].
// Bitmaps are padded to whole uint64s so sweep can stride 8 bytes at
// a time without reading past its own map (slack bits stay zero:
// bits are only ever set for idx < nblocks).
static Chunk *chunk_new(uint32_t block_size, uint32_t nblocks,
                        uint32_t class_idx, int atomic) {
  size_t bitbytes = (((size_t)nblocks + 63) / 64) * 8;
  size_t hdr = (sizeof(Chunk) + 2 * bitbytes + 15) & ~(size_t)15;
  char *mem = (char *)malloc(hdr + (size_t)block_size * nblocks + 16);
  if (!mem) {
    gc_collecting = 0;
    pf_fatal("out of memory (gc heap exhausted)");
  }
  Chunk *c = (Chunk *)mem;
  c->alloc_bits = (uint8_t *)(mem + sizeof(Chunk));
  c->mark_bits = c->alloc_bits + bitbytes;
  memset(c->alloc_bits, 0, 2 * bitbytes);
  c->base = (char *)(((uintptr_t)mem + hdr + 15) & ~(uintptr_t)15);
  c->block_size = block_size;
  c->nblocks = nblocks;
  c->class_idx = class_idx;
  c->atomic = (uint8_t)atomic;
  c->next = all_chunks;
  all_chunks = c;
  cindex_insert(c);
  return c;
}

// ---------------------------------------------------------------
// Allocation (the Boehm ABI). Never collects -- see the header.
// ---------------------------------------------------------------

static void *gc_alloc(size_t bytes, int atomic) {
  gc_init_once();
  if (gc_collecting) { gc_collecting = 0; pf_fatal("gc: allocation during collection"); }
  if (bytes == 0) bytes = 1;
  void *p;
  size_t charged;
  if (bytes > GC_LARGE_MIN) {
    size_t rounded = (bytes + 7) & ~(size_t)7;
    if (rounded > 0xFFFFFFFFu - 64) { pf_fatal("gc: allocation too large"); }
    Chunk *c = chunk_new((uint32_t)rounded, 1, NCLASSES, atomic);
    bit_set(c->alloc_bits, 0);
    p = c->base;
    charged = rounded;
  } else {
    uint32_t ci = class_of_qwords[(bytes + 7) / 8];
    void **fl = &freelist[ci][atomic ? 1 : 0];
    if (!*fl) {
      // grow: one fresh chunk, all blocks onto the freelist.
      // A free block's word 0 is the freelist link, word 1 the owning
      // chunk (blocks are >= 16 bytes) -- so allocation needs no
      // pointer->chunk search on the hot path.
      Chunk *c = chunk_new(class_bytes[ci], GC_CHUNK_BYTES / class_bytes[ci],
                           ci, atomic);
      char *b = c->base + (size_t)(c->nblocks - 1) * c->block_size;
      void *head = NULL;
      for (uint32_t i = 0; i < c->nblocks; i++, b -= c->block_size) {
        ((void **)b)[0] = head;
        ((void **)b)[1] = c;
        head = b;
      }
      *fl = head;
    }
    p = *fl;
    *fl = ((void **)p)[0];
    Chunk *c = (Chunk *)((void **)p)[1];
    bit_set(c->alloc_bits, (uint32_t)(((uintptr_t)p - (uintptr_t)c->base) / c->block_size));
    charged = class_bytes[ci];
  }
  if (!atomic) memset(p, 0, charged);   // GC_MALLOC zeroes, per Boehm
  bytes_since_gc += charged;
  if (bytes_since_gc >= gc_budget) pf_gc_wants_collect = 1;
  return p;
}

void *GC_MALLOC(size_t bytes) { return gc_alloc(bytes, 0); }
void *GC_MALLOC_ATOMIC(size_t bytes) { return gc_alloc(bytes, 1); }

// ---------------------------------------------------------------
// Roots
// ---------------------------------------------------------------

static struct { void *low, *high; } *root_regions = NULL;
static uint32_t root_region_count = 0, root_region_cap = 0;

void GC_add_roots(void *low, void *high_plus_1) {
  if (root_region_count == root_region_cap) {
    root_region_cap = root_region_cap ? root_region_cap * 2 : 256;
    root_regions = realloc(root_regions, root_region_cap * sizeof(*root_regions));
    if (!root_regions) pf_fatal("gc: out of memory (root table)");
  }
  root_regions[root_region_count].low = low;
  root_regions[root_region_count].high = high_plus_1;
  root_region_count++;
}

// ---------------------------------------------------------------
// Mark
// ---------------------------------------------------------------

typedef struct { char *p; uint32_t n; } MarkEnt;
static MarkEnt *mark_stack = NULL;
static size_t ms_n = 0, ms_cap = 0;

// one-entry chunk cache for mark_word: consecutive words of a block
// overwhelmingly decode into the same chunk (a list's pairs share a
// size class). Reset each collection (sweep may free large chunks).
static Chunk *last_chunk = NULL;

static void ms_push(char *p, uint32_t n) {
  if (ms_n == ms_cap) {
    ms_cap = ms_cap ? ms_cap * 2 : 4096;
    mark_stack = (MarkEnt *)realloc(mark_stack, ms_cap * sizeof(MarkEnt));
    if (!mark_stack) { gc_collecting = 0; pf_fatal("gc: out of memory (mark stack)"); }
  }
  mark_stack[ms_n].p = p;
  mark_stack[ms_n].n = n;
  ms_n++;
}

// Scanning granularity is the POINTER size, not the pf size. On
// 64-bit native the two coincide. On wasm32 a pf is still a 64-bit
// word but pointers are 32-bit: scanned memory mixes 8-byte pf's
// (low half = the 32-bit ref, high half zero/sign) with PACKED 4-byte
// pointers (symbol_names' char** rows, hamt child slots' low halves,
// C pointer arrays in statics) -- reading 4-byte words decodes both,
// at the cost of also decoding a pf's high half (a fixnum's top bits;
// conservative false positive, same class as any other).
typedef uintptr_t scanword;

// Decode one word: tagged heap ref (addr|1 -> header) or raw block
// base pointer (tag 000). Mark the block; queue it if scannable.
static void mark_word(scanword w) {
  uintptr_t cand;
  switch (w & 7) {
  case 1: cand = (uintptr_t)(w - 1); break;  // pf heap reference
  case 0: cand = (uintptr_t)w; break;        // raw pointer (or fixnum)
  default: return;
  }
  if (cand < heap_lo || cand >= heap_hi) return;
  Chunk *c = last_chunk;
  if (!(c && cand >= (uintptr_t)c->base &&
        cand < (uintptr_t)c->base + (size_t)c->block_size * c->nblocks)) {
    c = find_chunk(cand);
    if (!c) return;
    last_chunk = c;
  }
  size_t off = cand - (uintptr_t)c->base;
  if (off % c->block_size) return;           // exact base only (see header)
  uint32_t idx = (uint32_t)(off / c->block_size);
  if (!bit_test(c->alloc_bits, idx) || bit_test(c->mark_bits, idx)) return;
  bit_set(c->mark_bits, idx);
  live_bytes += c->block_size;
  if (!c->atomic) ms_push(c->base + off, c->block_size);
}

static void drain_mark_stack(void) {
  while (ms_n) {
    MarkEnt e = mark_stack[--ms_n];
    const char *p = e.p;
    for (uint32_t i = 0; i + sizeof(scanword) <= e.n; i += sizeof(scanword)) {
      scanword w;
      memcpy(&w, p + i, sizeof w);
      mark_word(w);
    }
  }
}

// scan [lo, hi) as pointer-size words (also the pvm_gc_frame_roots
// callback)
static void scan_region(void *lo, void *hi) {
  const uintptr_t wmask = sizeof(scanword) - 1;
  uintptr_t a = ((uintptr_t)lo + wmask) & ~wmask;
  uintptr_t b = (uintptr_t)hi & ~wmask;
  while (a < b) {
    scanword w;
    memcpy(&w, (void *)a, sizeof w);
    mark_word(w);
    a += sizeof(scanword);
  }
  drain_mark_stack();
}

// ---------------------------------------------------------------
// Sweep: O(bitmap words + newly freed blocks). Freelists are NOT
// rebuilt -- a block is on its freelist iff its alloc bit is clear,
// and that invariant survives because small chunks are never freed.
// ---------------------------------------------------------------

static void sweep(void) {
  Chunk **pp = &all_chunks;
  while (*pp) {
    Chunk *c = *pp;
    size_t bitbytes = (((size_t)c->nblocks + 63) / 64) * 8; // as chunk_new sized them
    if (c->class_idx == NCLASSES) {           // large: dead => free()
      if (!bit_test(c->mark_bits, 0)) {
        *pp = c->next;
        cindex_remove(c);
        free(c);
        continue;
      }
      c->mark_bits[0] = 0;
      pp = &c->next;
      continue;
    }
    void **fl = &freelist[c->class_idx][c->atomic ? 1 : 0];
    // bitmaps are processed a uint64 at a time (they are sized in
    // whole bytes and the malloc'd header area is 8-aligned, with
    // slack bits zero in both maps)
    for (size_t i = 0; i < bitbytes; i += 8) {
      uint64_t av, mv;
      memcpy(&av, c->alloc_bits + i, 8);
      memcpy(&mv, c->mark_bits + i, 8);
      uint64_t freed = av & ~mv;
      if (av != mv) {
        memcpy(c->alloc_bits + i, &mv, 8);
        while (freed) {
          uint32_t bitpos = (uint32_t)__builtin_ctzll(freed);
          freed &= freed - 1;
          char *b = c->base + ((size_t)i * 8 + bitpos) * c->block_size;
          if (gc_stress) memset(b, 0xAB, c->block_size);
          ((void **)b)[0] = *fl;
          ((void **)b)[1] = c;
          *fl = b;
        }
      }
      if (mv) memset(c->mark_bits + i, 0, 8);
    }
    pp = &c->next;
  }
}

// ---------------------------------------------------------------
// Collection -- called ONLY from VM safepoints (dispatch loop,
// between instructions). See THE SAFEPOINT RULE in the header.
// ---------------------------------------------------------------

#ifdef __wasi__
// wasi-lld's linker-provided data-segment bounds (--stack-first puts
// the shadow stack below __global_base, so this range is exactly
// data+bss; the shadow stack is deliberately NOT scanned).
extern unsigned char __global_base;
extern unsigned char __data_end;
#endif

void pf_gc_collect(void) {
  if (!gc_initialized) { pf_gc_wants_collect = gc_stress; return; }
  // Nothing allocated since the last collection: another one cannot
  // hand out (or poison) any block an allocation could reuse, so it
  // proves nothing stress mode cares about. Skipping keeps stress
  // usable in compute-only stretches while every allocation boundary
  // still gets its collection.
  if (bytes_since_gc == 0) { pf_gc_wants_collect = gc_stress ? 1 : 0; return; }
  if (gc_collecting) { gc_collecting = 0; pf_fatal("gc: reentrant collection"); }
  gc_collecting = 1;
  live_bytes = 0;
  last_chunk = NULL;
  // mark bits are all clear here (cleared by the previous sweep;
  // freshly-created chunks zero theirs).
  for (uint32_t i = 0; i < root_region_count; i++)
    scan_region(root_regions[i].low, root_regions[i].high);
  pvm_gc_frame_roots(scan_region);
#ifdef __wasi__
  scan_region(&__global_base, &__data_end);
#endif
  sweep();
  bytes_since_gc = 0;
  gc_budget = live_bytes < GC_MIN_BUDGET ? GC_MIN_BUDGET : live_bytes;
  pf_gc_wants_collect = gc_stress ? 1 : 0;
  gc_collecting = 0;
}
