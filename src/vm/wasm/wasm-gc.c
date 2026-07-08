// wasm-gc.c -- the wasm build's allocator (docs/WASM-VM.md §3.2/§3.3).
//
// STATUS: scaffold. This is a NON-COLLECTING allocator: it satisfies
// the Boehm allocation ABI (GC_MALLOC / GC_MALLOC_ATOMIC /
// GC_add_roots) by forwarding to wasi-libc's malloc and never
// freeing. It grows linear memory rather than collecting -- which is
// the *documented failure mode* of the real collector under a single
// huge allocation (§3.3), just made total. It is correct (never
// reclaims a live object, because it reclaims nothing) and it runs
// the whole corpus as long as the heap fits; the playground's heaps
// are small (§2.1), so this is a legitimate M4-preliminary that lets
// the wasm pipeline be exercised end-to-end before the collector
// lands.
//
// The REAL collector that replaces this file (the M4/GC milestone) is
// a linear-memory, non-moving mark-sweep over segregated size classes
// with:
//   - precise roots: the VM frame-stack chunks (registered via
//     GC_add_roots below), the globals table, and the data+bss
//     segment [__global_base, __data_end) scanned conservatively;
//   - conservative tracing *within* the heap (a word that decodes as
//     addr|1 into a live block marks it) -- Boehm's trick, minus the
//     C-stack scan Boehm cannot do soundly on wasm;
//   - the load-bearing SAFEPOINT RULE: collection runs ONLY in the
//     dispatch loop, between instructions, when the budget is
//     exceeded. Prims never collect (they grow instead), so a pf held
//     in a C/wasm local mid-prim is never live across a collection --
//     the unscannable-locals problem is made unreachable, not solved.
//   - PUFFIN_VM_GC_STRESS=1 collects at every safepoint (CI gate).
// When it lands, this file is swapped out and NOTHING else changes:
// the ABI below is the seam.

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// --- the region table (populated for the real collector; unused by
// the scaffold beyond bookkeeping so the wiring is already correct) ---

#define PF_MAX_ROOT_REGIONS 4096
static struct { void *low, *high; } root_regions[PF_MAX_ROOT_REGIONS];
static size_t root_region_count = 0;

void GC_add_roots(void *low, void *high_plus_1) {
  if (root_region_count < PF_MAX_ROOT_REGIONS) {
    root_regions[root_region_count].low = low;
    root_regions[root_region_count].high = high_plus_1;
    root_region_count++;
  }
  // Scaffold: nothing to do beyond recording the region -- we never
  // collect, so we never scan. The real collector scans these on mark.
}

void *GC_MALLOC(size_t bytes) {
  // Zeroed, per Boehm's contract (pf_init and pf_make_closure rely on
  // it). calloc gives fresh zeroed pages from wasi-libc's dlmalloc.
  void *p = calloc(1, bytes ? bytes : 1);
  if (!p) {
    // Out of linear memory: the runtime's own OOM paths (pf_fatal)
    // handle a NULL from callers that check, but most call sites
    // assume success like they do with Boehm. Abort loudly.
    extern void pf_fatal(const char *);
    pf_fatal("out of memory (wasm heap exhausted)");
  }
  return p;
}

void *GC_MALLOC_ATOMIC(size_t bytes) {
  // Not zeroed (matches Boehm); callers fill the bytes immediately.
  void *p = malloc(bytes ? bytes : 1);
  if (!p) {
    extern void pf_fatal(const char *);
    pf_fatal("out of memory (wasm heap exhausted)");
  }
  return p;
}
