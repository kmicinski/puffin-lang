// lib/exn.c -- exceptions (docs/EXCEPTIONS.md).
//
// Manifest entries: raise exn? exn-message exn-kind (surface),
//                   call-with-handler (surface; implemented by the VM)
//
// This module claims a kind from the extension range (see puffin.h):
//   PF_KIND_EXN = 20   payload: | kind (symbol) | payload | style |
//
// Every way a Puffin program can fail at run time ends in pf_raise:
// `raise` itself, `(error v)` (core.c pf_error), and every runtime
// error (core.c pf_fatal, which arithmetic, cast, index and kind
// errors all reach) plus the file I/O failures (pf_fail).
//
// A runtime that can catch -- the bytecode VM, while a
// call-with-handler is active -- sets pf_raise_hook; pf_raise hands
// the value to it and it never returns. With no hook (no handler is
// installed, or a native binary, where call-with-handler is rejected
// at compile time) the exception is UNCAUGHT and the program ends
// exactly as it always has: each exn remembers its `style`, the
// bytes and exit status its failure printed before exceptions
// existed, so uncaught output is unchanged on every route.
//
// pf_fatal and pf_error check the hook BEFORE allocating anything:
// with no handler installed they print and exit as before, so an
// allocation failure can never recurse through here.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../puffin.h"

#define PF_KIND_EXN 20

extern pf pf_string_from_bytes(const char *bytes, int64_t n); // lib/strings.c

pf_raise_fn pf_raise_hook = NULL;

static pf sym(const char *name) { return (pf)((pf_intern_symbol(name) << 3) | PF_TAG_SYMBOL); }

pf pf_make_exn(pf kind, pf payload, int style) {
  pf v = pf_alloc(PF_KIND_EXN, 3, 3 * 8);
  pf_heap_ptr(v)[1] = kind;
  pf_heap_ptr(v)[2] = payload;
  pf_heap_ptr(v)[3] = PF_FIX(style);
  return v;
}

static pf runtime_exn(const char *msg, int style) {
  return pf_make_exn(sym("runtime"), pf_string_from_bytes(msg, (int64_t)strlen(msg)), style);
}

// The uncaught ending: what the failure printed before exceptions.
__attribute__((noreturn)) static void uncaught(pf v) {
  if (pf_is_kind(v, PF_KIND_EXN)) {
    pf payload = pf_heap_ptr(v)[2];
    switch ((int)PF_UNFIX(pf_heap_ptr(v)[3])) {
    case PF_EXN_ERROR:
      printf("error: ");
      pf_display_value(payload);
      printf("\n");
      fflush(stdout);
      exit(1);
    case PF_EXN_IO:
      fflush(stdout);
      fprintf(stderr, "error: ");
      pf_display_value_to(payload, stderr);
      fprintf(stderr, "\n");
      exit(1);
    default: // PF_EXN_FATAL
      fflush(stdout);
      fprintf(stderr, "puffin runtime error: ");
      pf_display_value_to(payload, stderr);
      fprintf(stderr, "\n");
      exit(255);
    }
  }
  printf("uncaught exception: ");
  pf_display_value(v);
  printf("\n");
  fflush(stdout);
  exit(1);
}

void pf_raise_value(pf v) {
  if (pf_raise_hook) pf_raise_hook(v);
  uncaught(v);
}

pf pf_raise(pf v) { pf_raise_value(v); return PF_VOID; }

// A runtime failure with its message: catchable when a handler is
// installed, else printed in `style` with no allocation.
void pf_fail(int style, const char *msg) {
  if (pf_raise_hook) pf_raise_value(runtime_exn(msg, style));
  fflush(stdout);
  if (style == PF_EXN_IO) {
    fprintf(stderr, "error: %s\n", msg);
    exit(1);
  }
  fprintf(stderr, "puffin runtime error: %s\n", msg);
  exit(255);
}

// (error v) with a handler installed (core.c pf_error decides).
void pf_raise_error(pf v) { pf_raise_value(pf_make_exn(sym("error"), v, PF_EXN_ERROR)); }

pf pf_exn_huh(pf v) { return PF_BOOL(pf_is_kind(v, PF_KIND_EXN)); }

pf pf_exn_kind(pf v) {
  pf_expect_kind(v, PF_KIND_EXN);
  return pf_heap_ptr(v)[1];
}

// the message: a runtime error's text; an (error v)'s value as a
// string (display's rendering, so (error "boom") gives "boom")
pf pf_exn_message(pf v) {
  pf_expect_kind(v, PF_KIND_EXN);
  pf payload = pf_heap_ptr(v)[2];
  if (pf_is_kind(payload, PF_KIND_STRING)) return payload;
  return pf_to_string(payload);
}

// call-with-handler is the VM's (puffin-vm.c); a native binary never
// reaches this (the native backends reject it at compile time)
pf pf_call_with_handler(pf thunk, pf handler) {
  (void)thunk; (void)handler;
  pf_fatal("call-with-handler: exceptions are not supported by this backend");
}

// #<exn: boom>
static void display_exn(pf v, FILE *out) {
  fprintf(out, "#<exn: ");
  pf payload = pf_heap_ptr(v)[2];
  pf_display_value_to(payload, out);
  fprintf(out, ">");
}

void pf_lib_exn_init(void) {
  static const pf_kind_desc desc = { "exn", display_exn, NULL, NULL };
  pf_register_kind(PF_KIND_EXN, &desc);
}
