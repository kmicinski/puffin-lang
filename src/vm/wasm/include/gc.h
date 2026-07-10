// gc.h -- Boehm-ABI shim for the wasm build (docs/WASM-VM.md §3.2/§3.3).
//
// The native build compiles core.c against the vendored Boehm header
// (src/runtime/vendor/gc/include/gc.h). The wasm build cannot use
// Boehm (its soundness depends on scanning the C stack, and wasm
// locals are not memory -- §3.3), so the wasm Makefile puts THIS
// directory on the include path instead. core.c and puffin-vm.c then
// compile *unchanged*: they still say GC_MALLOC / GC_INIT /
// GC_add_roots, and those names resolve here to the allocator module
// (wasm-gc.c). The whole platform difference lives in the allocator,
// exactly as the design demands ("no #ifdef forests").
//
// The three entries below (+ GC_add_roots, declared in puffin-vm.c)
// are the entire allocation ABI the runtime uses -- confirmed by
//   grep -rho 'GC_[A-Za-z_]*' src/runtime src/vm
// which yields only GC_INIT, GC_MALLOC, GC_MALLOC_ATOMIC, GC_add_roots.

#ifndef PUFFIN_WASM_GC_SHIM_H
#define PUFFIN_WASM_GC_SHIM_H

#include <stddef.h>

// GC_INIT is a macro in Boehm; keep it a macro here so `GC_INIT();`
// in pf_init compiles. wasm-gc.c does its setup lazily on first
// allocation, so this is a no-op.
#define GC_INIT() ((void)0)

// Zeroed allocation (Boehm's GC_MALLOC zeroes; the runtime relies on
// it, e.g. closure/globals seeding).
void *GC_MALLOC(size_t bytes);

// Pointer-free allocation. Boehm's GC_MALLOC_ATOMIC does NOT zero;
// the runtime only uses it for byte buffers it fills immediately
// (strings, symbol-name copies), so leaving it unzeroed matches
// native behavior and is faster.
void *GC_MALLOC_ATOMIC(size_t bytes);

// Root registration. The VM registers each frame-stack chunk as a
// root region. For the non-collecting scaffold allocator this is a
// no-op (nothing is ever freed, so everything is trivially rooted);
// the §3.3 mark-sweep collector will record these regions and scan
// them precisely.
void GC_add_roots(void *low, void *high_plus_1);

#endif
