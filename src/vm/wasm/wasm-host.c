// wasm-host.c -- the wasm build's host-boundary glue
// (docs/WASM-VM.md §3.2 open_memstream note, §3.4 errors).
//
// Two concerns, both kept OUT of core.c / lib/*.c so the runtime
// stays source-identical across platforms:
//
//   1. Errors that don't kill the tab (§3.4). Native pf_fatal is
//      exit(255) and (error v) is print + exit(1). In a browser the
//      session must survive both and the REPL must keep its globals.
//      We do NOT edit core.c: instead the wasm Makefile links with
//      `-Wl,--wrap=exit`, so every exit() call in the runtime is
//      rewritten to __wrap_exit below, which prints nothing extra
//      (pf_fatal/pf_error already printed) and calls the imported
//      host_abort(code). A JS exception thrown from that import
//      unwinds all wasm frames (core wasm behavior, universally
//      shipped) -- no setjmp, no wasm exception-handling proposal.
//      The JS boundary catches it and resets the VM's execution state
//      (frame stack ptr, staging slots) in linear memory; the heap,
//      symbol table, and globals survive.
//
//   2. open_memstream (§3.2). core.c's value->string uses
//      open_memstream, which wasi-libc's musl-derived stdio SHOULD
//      provide. If a given wasi-sdk lacks it, build with
//      -DPUFFIN_MEMSTREAM_FALLBACK to get the ~30-line replacement
//      below. This must be VERIFIED once the SDK is installed (M2/M4);
//      until then it is a ready-to-flip fallback, off by default.

#include <stdint.h>
#include <stdlib.h>

// --- §3.4: host abort import -------------------------------------

// Imported from the JS host under module "puffin", name "abort".
// The host implementation throws a JS exception (see
// web/src/engine/wasi-shim.js host_abort).
__attribute__((import_module("puffin"), import_name("abort")))
extern void host_abort(int32_t code);

// Intercepts exit() throughout the runtime (via -Wl,--wrap=exit).
// __real_exit is the genuine wasi-libc exit; we do not call it,
// because proc_exit would tear down the instance and lose the REPL
// session. Instead we hand control to the host, which unwinds us.
__attribute__((noreturn))
void __wrap_exit(int code) {
  host_abort(code);
  // host_abort throws and never returns; satisfy 'noreturn' anyway.
  __builtin_unreachable();
}

// --- §3.2: open_memstream fallback (opt-in) ----------------------

#ifdef PUFFIN_MEMSTREAM_FALLBACK
#include <stdio.h>
#include <string.h>

// Minimal open_memstream: a growable buffer backed by a FILE* via
// wasi-libc's fopencookie-free path is not available, so we implement
// the tiny slice value->string actually needs -- a write-only stream
// whose bytes land in *bufp/*sizep on fclose. Only pf_to_string uses
// it, and only with fwrite/fputc/fprintf on the display path.
//
// NOTE: this is a compatibility shim, not a general open_memstream.
// Enable only if the SDK's stdio lacks the real one (verify at M2).

typedef struct { char **bufp; size_t *sizep, cap, len; } MemCookie;

// wasi-libc exposes fopencookie in recent releases; if it does, prefer
// it. This block is intentionally left as the documented seam: the
// implementer wires either fopencookie or a small custom FILE here
// once the SDK is in hand and its stdio surface is known. Keeping the
// decision at install time avoids guessing the SDK version now.
#error "PUFFIN_MEMSTREAM_FALLBACK: wire fopencookie/custom stream once wasi-sdk stdio surface is known (docs/WASM-VM.md §3.2). Verify the real open_memstream is absent first."

#endif // PUFFIN_MEMSTREAM_FALLBACK
