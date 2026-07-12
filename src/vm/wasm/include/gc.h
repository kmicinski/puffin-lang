// gc.h -- Boehm-ABI shim for the wasm build (docs/WASM-VM.md §3.2/§3.3).
//
// The native build compiles core.c against the vendored Boehm header
// (src/runtime/vendor/gc/include/gc.h). The wasm build cannot use
// Boehm (its soundness depends on scanning the C stack, and wasm
// locals are not memory -- §3.3), so the wasm Makefile puts THIS
// directory on the include path instead. core.c and puffin-vm.c then
// compile *unchanged*: they still say GC_MALLOC / GC_INIT /
// GC_add_roots, and those names resolve here to the §3.3 collector
// (wasm-gc.c: non-moving mark-sweep over segregated size classes,
// safepoint-only collection). The whole platform difference lives in
// the allocator, exactly as the design demands ("no #ifdef forests").
//
// The entries below (+ GC_add_roots, declared in puffin-vm.c) are the
// entire allocation ABI the runtime uses -- confirmed by
//   grep -rho 'GC_[A-Za-z_]*' src/runtime src/vm
// which yields only GC_INIT, GC_MALLOC, GC_MALLOC_ATOMIC, GC_add_roots.
//
// The safepoint seam (pf_gc_wants_collect / pf_gc_collect) is used by
// puffin-vm.c ONLY when built with -DPVM_WASM_GC (the wasm and gctest
// builds); the Boehm build never sees these names.

#ifndef PUFFIN_WASM_GC_SHIM_H
#define PUFFIN_WASM_GC_SHIM_H

#include <stddef.h>

// GC_INIT is a macro in Boehm; keep it a macro here so `GC_INIT();`
// in pf_init compiles. wasm-gc.c does its setup lazily on first
// allocation, so this is a no-op.
#define GC_INIT() ((void)0)

// Zeroed allocation (Boehm's GC_MALLOC zeroes; the runtime relies on
// it, e.g. closure/globals seeding). NEVER collects: past the budget
// it grows and raises pf_gc_wants_collect for the next safepoint
// (the §3.3 safepoint rule -- prims never see a collection).
void *GC_MALLOC(size_t bytes);

// Pointer-free allocation. Boehm's GC_MALLOC_ATOMIC does NOT zero;
// the runtime only uses it for byte buffers it fills immediately
// (strings, symbol-name copies). Atomic blocks are never scanned.
void *GC_MALLOC_ATOMIC(size_t bytes);

// Root registration. The VM registers every malloc'd array that
// holds live pf values (unit string caches, v1 globals, session cell
// blocks); the runtime's pf-holding statics register themselves
// (core.c, lib/hamt.c). Regions cannot be unregistered -- all
// current callers are immortal.
void GC_add_roots(void *low, void *high_plus_1);

// --- the safepoint seam (VM dispatch loop only; -DPVM_WASM_GC) -----

// Set by the allocator when the collection budget is exceeded (and
// permanently under PUFFIN_VM_GC_STRESS=1). The dispatch loop checks
// it at safepoints (jumps, branches, calls) and calls pf_gc_collect.
extern int pf_gc_wants_collect;

// Collect NOW. Only legal at a VM safepoint: no pf may be live in a
// C/wasm local that isn't also reachable from the frame stack or a
// registered root (docs/WASM-VM.md §3.3).
void pf_gc_collect(void);

#endif
