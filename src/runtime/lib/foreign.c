// lib/foreign.c -- the FFI runtime (docs/FFI.md).
//
// Manifest entries: #%ffi-register #%ffi-call0..6 (internal)
//                   foreign-ptr? (surface)
//
// A `foreign` declaration lowers (in both compilers' desugar passes)
// to ordinary top-level code:
//
//   (define name
//     (let ([i (#%ffi-register rpath spath cname 'desc)])
//       (lambda (a ...) (#%ffi-calln i a ...))))
//
// so registration happens when the module's top level runs (= load
// time, docs/FFI.md §5.3) and every call is an ordinary prim call.
// The desc is quoted data built at compile time from the declared
// type -- the marshaling schedule:
//
//   desc     := (name-str pos-str ret arg ...)
//   arg      := int | i8 i16 i32 i64 u8 u16 u32 u64 | bool | str
//             | (handle BRAND "Shown") | (handle-consume BRAND "Shown")
//   ret      := arg-scalars | void | (nullable str)
//             | (str-gift "free_sym")
//             | (handle BRAND "Shown") | (nullable-handle BRAND "Shown")
//
//   name-str  the import's SOURCE spelling ("regex-match?"), for
//             blame labels and load errors
//   pos-str   "" or " [file.puf:12]" -- the declaration's position,
//             appended to blame labels (same as cast blame)
//   BRAND     the (module-mangled) define-foreign-type symbol; the
//             runtime identity of the handle type
//   "Shown"   its source spelling, for diagnostics and display
//
// Marshaling per docs/FFI.md §4: outbound values are checked against
// the declared type (the transient cast, relocated to the one
// boundary where it may never be erased) and converted; inbound
// values are CONSTRUCTED (range-checked retag, NULL-checked copy,
// branded wrap) -- construction is the check. Every failure names
// the import (§5.2) with the exact grammar the Racket ref-impls in
// src/stdlib.rkt reproduce byte-for-byte.
//
// The generic caller (§8.2): on SysV x86-64 and AAPCS64, any function
// whose parameters and result are all integer-class and <= 6 passes
// everything in integer registers, so calling through
// int64_t(*)(int64_t x 6) with trailing arguments ignored is correct
// for every declarable signature. No libffi, no generated thunks.
// (#%ffi-call6 takes its six arguments PACKED in a vector: a prim
// call's arguments ride the six argument registers, and the import
// index occupies one -- the same >boundary packing discipline as the
// language's own calls.)
//
// Foreign handles are heap kind 19 (16/17 the HAMTs, 18 the ADT
// kind): payload | raw pointer | brand (interned symbol) | flags |
// (bit 0 of flags: closed). Only the inbound marshaler constructs
// kind 19 -- unforgeable by construction. #:consumes nulls the
// pointer and sets the closed bit after the call: use-after-close
// and double-close are loud blamed errors, never a double free.
//
// The wasm VM has no dlopen: registration fails at load with the
// stable browser refusal (io.c's system() precedent, §8.3).

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../puffin.h"

#ifndef __wasm__
#include <dlfcn.h>
#endif

#define PF_KIND_FOREIGN 19

// ---- desc spec encoding --------------------------------------------

enum {
  SP_INT, SP_BOOL, SP_STR, SP_VOID, SP_NSTR, SP_GIFT,
  SP_I8, SP_I16, SP_I32, SP_I64, SP_U8, SP_U16, SP_U32, SP_U64,
  SP_HANDLE, SP_HANDLE_CONSUME, SP_NHANDLE
};

typedef struct {
  int kind;
  pf brand;          // handle specs: the interned brand symbol
  char *shown;       // handle specs: source spelling, for messages
} ffi_spec;

typedef struct {
  void *fn;          // resolved symbol
  void *gift;        // (str-gift ...): the deallocator, same library
  int nargs;
  ffi_spec ret;
  ffi_spec args[6];
  char *name;        // import's source spelling
  char *pos;         // "" or " [file:line]"
} ffi_import;

static ffi_import *imports = NULL;
static int64_t import_count = 0, import_cap = 0;

// brand symbol -> display name, for #<Regex 0x...> rendering
#define MAX_BRANDS 256
static pf brand_syms[MAX_BRANDS];
static const char *brand_names[MAX_BRANDS];
static int brand_count = 0;

static const char *brand_display(pf brand) {
  for (int i = 0; i < brand_count; i++)
    if (brand_syms[i] == brand) return brand_names[i];
  return "foreign";  // unreachable: wraps always register first
}

static void brand_register(pf brand, const char *shown) {
  for (int i = 0; i < brand_count; i++)
    if (brand_syms[i] == brand) return;
  if (brand_count < MAX_BRANDS) {
    brand_syms[brand_count] = brand;
    brand_names[brand_count] = shown;
    brand_count++;
  }
}

// ---- small helpers ---------------------------------------------------

static const char *cstr_of(pf v) {
  // strings are NUL-terminated by layout (see lib/strings.c)
  pf_expect_kind(v, PF_KIND_STRING);
  return (const char *)(pf_heap_ptr(v) + 1);
}

extern pf pf_string_from_bytes(const char *bytes, int64_t n); // lib/strings.c

#ifndef __wasm__  // marshaling machinery: unreachable in the browser

static pf sym(const char *name) {
  return (pf_intern_symbol(name) << 3) | PF_TAG_SYMBOL;
}

static pf s_int, s_bool, s_str, s_void, s_nullable, s_str_gift,
          s_nullable_str_gift,
          s_handle, s_handle_consume, s_nullable_handle,
          s_i8, s_i16, s_i32, s_i64, s_u8, s_u16, s_u32, s_u64;
static int syms_ready = 0;
static void init_syms(void) {
  s_int = sym("int"); s_bool = sym("bool"); s_str = sym("str");
  s_void = sym("void"); s_nullable = sym("nullable");
  s_str_gift = sym("str-gift");
  s_nullable_str_gift = sym("nullable-str-gift");
  s_handle = sym("handle"); s_handle_consume = sym("handle-consume");
  s_nullable_handle = sym("nullable-handle");
  s_i8 = sym("i8"); s_i16 = sym("i16"); s_i32 = sym("i32"); s_i64 = sym("i64");
  s_u8 = sym("u8"); s_u16 = sym("u16"); s_u32 = sym("u32"); s_u64 = sym("u64");
  syms_ready = 1;
}

static pf pair_car(pf v) { return pf_heap_ptr(v)[1]; }
static pf pair_cdr(pf v) { return pf_heap_ptr(v)[2]; }
static int is_pair(pf v) { return pf_is_kind(v, PF_KIND_PAIR); }

__attribute__((noreturn)) static void fatal_fmt_flush(char *buf) {
  fflush(stdout);
  fprintf(stderr, "puffin runtime error: %s\n", buf);
  exit(255);
}

// "cast: expected <what>, got <v> (blame: foreign <name>'s argument
// <k><pos>)" -- k = 0 means "result"
__attribute__((noreturn)) static void blame_cast(const ffi_import *im,
                                                 const char *what, pf got,
                                                 int argk) {
  char *buf = NULL; size_t len = 0;
  FILE *mem = open_memstream(&buf, &len);
  if (!mem) pf_fatal("ffi: out of memory");
  fprintf(mem, "cast: expected %s, got ", what);
  pf_display_value_to(got, mem);
  if (argk > 0)
    fprintf(mem, " (blame: foreign %s's argument %d%s)", im->name, argk, im->pos);
  else
    fprintf(mem, " (blame: foreign %s's result%s)", im->name, im->pos);
  fclose(mem);
  fatal_fmt_flush(buf);
}

// "foreign <name>: <msg> (blame: foreign <name>'s argument <k><pos>)"
__attribute__((noreturn)) static void blame_msg(const ffi_import *im,
                                                const char *msg, int argk) {
  char *buf = NULL; size_t len = 0;
  FILE *mem = open_memstream(&buf, &len);
  if (!mem) pf_fatal("ffi: out of memory");
  fprintf(mem, "foreign %s: %s", im->name, msg);
  if (argk > 0)
    fprintf(mem, " (blame: foreign %s's argument %d%s)", im->name, argk, im->pos);
  else
    fprintf(mem, " (blame: foreign %s's result%s)", im->name, im->pos);
  fclose(mem);
  fatal_fmt_flush(buf);
}

static pf handle_wrap(void *p, pf brand) {
  pf v = pf_alloc(PF_KIND_FOREIGN, 3, 3 * 8);
  pf_heap_ptr(v)[1] = (pf)(uintptr_t)p;
  pf_heap_ptr(v)[2] = brand;
  pf_heap_ptr(v)[3] = 0;
  return v;
}

static void *handle_ptr(pf v)     { return (void *)(uintptr_t)pf_heap_ptr(v)[1]; }
static void handle_close(pf v)    { pf_heap_ptr(v)[1] = 0; pf_heap_ptr(v)[3] |= 1; }

#endif  // !__wasm__

// ---- kind 19: branded, unforgeable handles ---------------------------
//
// payload: [1] raw pointer  [2] brand (interned symbol)  [3] flags

static int handle_is(pf v)        { return pf_is_kind(v, PF_KIND_FOREIGN); }
static int handle_closed(pf v)    { return (pf_heap_ptr(v)[3] & 1) != 0; }

// the cast machinery's hook (lib/cast.c, desc form (fptr SHOWN BRAND)):
// kind + brand, one call
int pf_foreign_is_brand(pf v, pf brand) {
  return handle_is(v) && pf_heap_ptr(v)[2] == brand;
}

pf pf_foreign_ptr_huh(pf v) { return PF_BOOL(handle_is(v)); }

static void display_handle(pf v, FILE *out) {
  const char *name = brand_display(pf_heap_ptr(v)[2]);
  if (handle_closed(v))
    fprintf(out, "#<%s closed>", name);
  else
    fprintf(out, "#<%s 0x%llx>", name, (unsigned long long)pf_heap_ptr(v)[1]);
}

#ifndef __wasm__

// ---- the finalizer BACKSTOP: a warn-to-stderr leak detector ----------
//
// docs/FFI.md §6.2 + §13 Q4 (the warning mode): explicit close is the
// resource discipline; the backstop only WARNS. Native-Boehm-only --
// the wasm VM never constructs a handle. Every wrap is recorded in a
// GC-visible table; at process exit, handles that are still open AND
// whose brand participates in a close discipline (some import
// declares #:consumes for it) are reported to stderr. This is the
// simplest correct version of the §6.2 seam: no Boehm finalizers
// (ordering hazards for a debugging aid), one sweep at exit.

#define MAX_TRACKED 4096
static pf *tracked = NULL;          // GC-visible array of handles
static int64_t tracked_count = 0;
static int tracker_overflow = 0;
static int atexit_installed = 0;

// brands with a declared close (#:consumes) -- only these warn
#define MAX_CLOSEABLE 256
static pf closeable_brands[MAX_CLOSEABLE];
static int closeable_count = 0;
static void brand_closeable(pf brand) {
  for (int i = 0; i < closeable_count; i++)
    if (closeable_brands[i] == brand) return;
  if (closeable_count < MAX_CLOSEABLE)
    closeable_brands[closeable_count++] = brand;
}
static int is_closeable(pf brand) {
  for (int i = 0; i < closeable_count; i++)
    if (closeable_brands[i] == brand) return 1;
  return 0;
}

static void report_leaks(void) {
  int64_t leaked = 0;
  for (int64_t i = 0; i < tracked_count; i++)
    if (tracked[i] && !handle_closed(tracked[i])
        && is_closeable(pf_heap_ptr(tracked[i])[2])) leaked++;
  if (leaked > 0) {
    fflush(stdout);
    fprintf(stderr, "puffin ffi warning: %lld foreign handle%s left open at exit",
            (long long)leaked, leaked == 1 ? "" : "s");
    // name up to 8, deterministically (creation order)
    int shown = 0;
    for (int64_t i = 0; i < tracked_count && shown < 8; i++)
      if (tracked[i] && !handle_closed(tracked[i])
          && is_closeable(pf_heap_ptr(tracked[i])[2])) {
        fprintf(stderr, "%s #<%s>", shown ? "," : ":",
                brand_display(pf_heap_ptr(tracked[i])[2]));
        shown++;
      }
    if (leaked > 8) fprintf(stderr, ", ...");
    if (tracker_overflow) fprintf(stderr, " (tracking table overflowed; count is a floor)");
    fprintf(stderr, "\n");
  }
}

static void track_handle(pf v) {
  if (!tracked) {
    tracked = (pf *)pf_alloc_raw(MAX_TRACKED * sizeof(pf));  // GC-visible
    memset(tracked, 0, MAX_TRACKED * sizeof(pf));
  }
  if (!atexit_installed) { atexit(report_leaks); atexit_installed = 1; }
  if (tracked_count < MAX_TRACKED) tracked[tracked_count++] = v;
  else tracker_overflow = 1;
}

// ---- desc parsing ------------------------------------------------------

static int parse_scalar(pf s, ffi_spec *out) {
  if (s == s_int)  { out->kind = SP_INT;  return 1; }
  if (s == s_bool) { out->kind = SP_BOOL; return 1; }
  if (s == s_str)  { out->kind = SP_STR;  return 1; }
  if (s == s_i8)   { out->kind = SP_I8;   return 1; }
  if (s == s_i16)  { out->kind = SP_I16;  return 1; }
  if (s == s_i32)  { out->kind = SP_I32;  return 1; }
  if (s == s_i64)  { out->kind = SP_I64;  return 1; }
  if (s == s_u8)   { out->kind = SP_U8;   return 1; }
  if (s == s_u16)  { out->kind = SP_U16;  return 1; }
  if (s == s_u32)  { out->kind = SP_U32;  return 1; }
  if (s == s_u64)  { out->kind = SP_U64;  return 1; }
  return 0;
}

static void parse_handle_tail(pf rest, ffi_spec *out) {
  // rest = (BRAND "Shown")
  out->brand = pair_car(rest);
  out->shown = strdup(cstr_of(pair_car(pair_cdr(rest))));
}

// parse one spec (arg or ret position); gift_sym receives the
// (str-gift "free") deallocator name when present
static void parse_spec(pf s, ffi_spec *out, const char **gift_sym) {
  out->brand = 0; out->shown = NULL;
  if ((s & PF_TAG_MASK) == PF_TAG_SYMBOL) {
    if (parse_scalar(s, out)) return;
    if (s == s_void) { out->kind = SP_VOID; return; }
    pf_fatal("ffi: malformed desc (unknown spec symbol)");
  }
  if (is_pair(s)) {
    pf head = pair_car(s);
    if (head == s_nullable) { out->kind = SP_NSTR; return; }  // (nullable str)
    if (head == s_str_gift) {
      out->kind = SP_GIFT;
      *gift_sym = strdup(cstr_of(pair_car(pair_cdr(s))));
      return;
    }
    if (head == s_nullable_str_gift) {
      out->kind = SP_NSTR;
      *gift_sym = strdup(cstr_of(pair_car(pair_cdr(s))));
      return;
    }
    if (head == s_handle) { out->kind = SP_HANDLE; parse_handle_tail(pair_cdr(s), out); return; }
    if (head == s_handle_consume) { out->kind = SP_HANDLE_CONSUME; parse_handle_tail(pair_cdr(s), out); return; }
    if (head == s_nullable_handle) { out->kind = SP_NHANDLE; parse_handle_tail(pair_cdr(s), out); return; }
  }
  pf_fatal("ffi: malformed desc (unknown spec)");
}

// ---- registration (dlopen at load; the wasm refusal seam) -------------

// dlopen handles are cached per resolved path for the process
#define MAX_LIBS 128
static char *lib_paths[MAX_LIBS];
static void *lib_handles[MAX_LIBS];
static int lib_count = 0;

static void *lib_open(const char *rpath, const char *spath) {
  for (int i = 0; i < lib_count; i++)
    if (strcmp(lib_paths[i], rpath) == 0) return lib_handles[i];
  void *h = dlopen(rpath, RTLD_NOW | RTLD_LOCAL);
  if (!h) {
    // dlerror() strings vary by platform: keep them OUT of the fatal
    // line (which goldens compare) and emit a follow-on diagnostic
    char *buf = NULL; size_t len = 0;
    FILE *mem = open_memstream(&buf, &len);
    if (!mem) pf_fatal("ffi: out of memory");
    fprintf(mem, "foreign library %s: cannot load", spath);
    fclose(mem);
    fflush(stdout);
    fprintf(stderr, "puffin runtime error: %s\n", buf);
    const char *dle = dlerror();
    if (dle) fprintf(stderr, "  (dlerror: %s)\n", dle);
    exit(255);
  }
  if (lib_count < MAX_LIBS) {
    lib_paths[lib_count] = strdup(rpath);
    lib_handles[lib_count] = h;
    lib_count++;
  }
  return h;
}

static void *sym_resolve(void *lib, const char *cname, const char *iname,
                         const char *spath) {
  void *p = dlsym(lib, cname);
  if (!p) {
    char *buf = NULL; size_t len = 0;
    FILE *mem = open_memstream(&buf, &len);
    if (!mem) pf_fatal("ffi: out of memory");
    fprintf(mem, "foreign %s: symbol %s not found in %s", iname, cname, spath);
    fclose(mem);
    fatal_fmt_flush(buf);
  }
  return p;
}
#endif

// (#%ffi-register rpath spath cname desc) -> import index
//   rpath  the path to dlopen (module-relative resolution done at
//          compile time); spath  the path as WRITTEN (messages)
pf pf_ffi_register(pf rpath, pf spath, pf cname, pf desc) {
#ifdef __wasm__
  (void)rpath; (void)cname; (void)desc;
  // the browser refusal (docs/FFI.md §5.3): a program that declares a
  // foreign library fails at LOAD in the browser -- pf_error's exact
  // print-and-exit contract, io.c's system() precedent
  printf("error: foreign library %s is not available in the browser\n",
         cstr_of(spath));
  fflush(stdout);
  exit(1);
#else
  if (!syms_ready) init_syms();
  if (import_count == import_cap) {
    int64_t ncap = import_cap ? import_cap * 2 : 16;
    ffi_import *n = (ffi_import *)malloc(ncap * sizeof(ffi_import));
    if (!n) pf_fatal("ffi: out of memory");
    if (imports) memcpy(n, imports, import_count * sizeof(ffi_import));
    imports = n;
    import_cap = ncap;
  }
  ffi_import *im = &imports[import_count];
  memset(im, 0, sizeof *im);

  // desc = (name-str pos-str ret arg ...)
  pf d = desc;
  im->name = strdup(cstr_of(pair_car(d))); d = pair_cdr(d);
  im->pos  = strdup(cstr_of(pair_car(d))); d = pair_cdr(d);
  const char *gift_sym = NULL;
  parse_spec(pair_car(d), &im->ret, &gift_sym); d = pair_cdr(d);
  int n = 0;
  for (; is_pair(d); d = pair_cdr(d)) {
    if (n >= 6) pf_fatal("ffi: malformed desc (more than 6 arguments)");
    const char *no_gift = NULL;
    parse_spec(pair_car(d), &im->args[n], &no_gift);
    n++;
  }
  im->nargs = n;

  void *lib = lib_open(cstr_of(rpath), cstr_of(spath));
  im->fn = sym_resolve(lib, cstr_of(cname), im->name, cstr_of(spath));
  if (gift_sym)
    im->gift = sym_resolve(lib, gift_sym, im->name, cstr_of(spath));

  // register handle brands for display as soon as they are declared;
  // a #:consumes brand joins the leak detector's watch set
  for (int i = 0; i < n; i++)
    if (im->args[i].shown) {
      brand_register(im->args[i].brand, im->args[i].shown);
      if (im->args[i].kind == SP_HANDLE_CONSUME) brand_closeable(im->args[i].brand);
    }
  if (im->ret.shown) brand_register(im->ret.brand, im->ret.shown);

  return PF_FIX(import_count++);
#endif
}

// ---- the generic type-directed caller ---------------------------------

#ifndef __wasm__

static const char *width_name(int kind) {
  switch (kind) {
  case SP_I8: return "I8";   case SP_I16: return "I16";
  case SP_I32: return "I32"; case SP_I64: return "I64";
  case SP_U8: return "U8";   case SP_U16: return "U16";
  case SP_U32: return "U32"; case SP_U64: return "U64";
  }
  return "Int";
}

// outbound: check v against spec, convert to the raw C word.
// argk is 1-based (blame).
static int64_t marshal_out(const ffi_import *im, const ffi_spec *sp, pf v, int argk) {
  switch (sp->kind) {
  case SP_INT:
    if ((v & PF_TAG_MASK) != PF_TAG_FIXNUM) blame_cast(im, "Int", v, argk);
    return PF_UNFIX(v);
  case SP_I8: case SP_I16: case SP_I32: case SP_I64:
  case SP_U8: case SP_U16: case SP_U32: case SP_U64: {
    if ((v & PF_TAG_MASK) != PF_TAG_FIXNUM) blame_cast(im, "Int", v, argk);
    int64_t r = PF_UNFIX(v);
    int ok = 1;
    switch (sp->kind) {
    case SP_I8:  ok = (r >= -128 && r <= 127); break;
    case SP_I16: ok = (r >= -32768 && r <= 32767); break;
    case SP_I32: ok = (r >= -2147483648LL && r <= 2147483647LL); break;
    case SP_I64: break;                              // 61-bit always fits
    case SP_U8:  ok = (r >= 0 && r <= 255); break;
    case SP_U16: ok = (r >= 0 && r <= 65535); break;
    case SP_U32: ok = (r >= 0 && r <= 4294967295LL); break;
    case SP_U64: ok = (r >= 0); break;
    }
    if (!ok) blame_cast(im, width_name(sp->kind), v, argk);
    return r;
  }
  case SP_BOOL:
    if (v == PF_TRUE) return 1;
    if (v == PF_FALSE) return 0;
    blame_cast(im, "Bool", v, argk);
  case SP_STR: {
    if (!pf_is_kind(v, PF_KIND_STRING)) blame_cast(im, "Str", v, argk);
    const char *p = (const char *)(pf_heap_ptr(v) + 1);
    // embedded-NUL check (docs/FFI.md §4.3, unconditional): a byte
    // string with an interior NUL would silently truncate on the C
    // side -- convert the silent bug into a loud one
    if ((int64_t)strlen(p) != pf_len_of(v)) {
      char msg[80];
      snprintf(msg, sizeof msg, "argument %d contains an embedded NUL", argk);
      blame_msg(im, msg, argk);
    }
    return (int64_t)(uintptr_t)p;  // borrowed for the call (§4.3)
  }
  case SP_HANDLE: case SP_HANDLE_CONSUME: {
    if (!handle_is(v) || pf_heap_ptr(v)[2] != sp->brand)
      blame_cast(im, sp->shown, v, argk);
    if (handle_closed(v)) {
      char msg[128];
      snprintf(msg, sizeof msg, "%s handle is closed", sp->shown);
      blame_msg(im, msg, argk);
    }
    return (int64_t)(uintptr_t)handle_ptr(v);
  }
  }
  pf_fatal("ffi: malformed desc (argument spec)");
}

// inbound: construct the tagged result per spec
static pf marshal_in(const ffi_import *im, int64_t r) {
  const ffi_spec *sp = &im->ret;
  switch (sp->kind) {
  case SP_VOID: return PF_VOID;
  case SP_INT: case SP_I64: {
    // the 61-bit boundary: sign-uniform top four bits or die loudly
    int64_t top = r >> 60;
    if (top != 0 && top != -1) {
      char *buf = NULL; size_t len = 0;
      FILE *mem = open_memstream(&buf, &len);
      if (!mem) pf_fatal("ffi: out of memory");
      fprintf(mem, "cast: expected Int (61-bit), got %lld (blame: foreign %s's result%s)",
              (long long)r, im->name, im->pos);
      fclose(mem);
      fatal_fmt_flush(buf);
    }
    return PF_FIX(r);
  }
  // width returns: a callee returning a narrow type leaves the
  // register's high bits unspecified -- mask/sign-extend per the
  // declared width BEFORE the retag (docs/FFI.md §4.1)
  case SP_I8:  return PF_FIX((int64_t)(int8_t)r);
  case SP_I16: return PF_FIX((int64_t)(int16_t)r);
  case SP_I32: return PF_FIX((int64_t)(int32_t)r);
  case SP_U8:  return PF_FIX((int64_t)(uint8_t)r);
  case SP_U16: return PF_FIX((int64_t)(uint16_t)r);
  case SP_U32: return PF_FIX((int64_t)(uint32_t)r);
  case SP_U64: {
    uint64_t u = (uint64_t)r;
    if (u > ((uint64_t)1 << 60) - 1) {
      char *buf = NULL; size_t len = 0;
      FILE *mem = open_memstream(&buf, &len);
      if (!mem) pf_fatal("ffi: out of memory");
      fprintf(mem, "cast: expected Int (61-bit), got %llu (blame: foreign %s's result%s)",
              (unsigned long long)u, im->name, im->pos);
      fclose(mem);
      fatal_fmt_flush(buf);
    }
    return PF_FIX((int64_t)u);
  }
  case SP_BOOL: return PF_BOOL((r & 0xFFFFFFFF) != 0);
  case SP_STR: case SP_GIFT: {
    if (r == 0) blame_msg(im, "result is NULL", 0);
    const char *p = (const char *)(uintptr_t)r;
    pf s = pf_string_from_bytes(p, (int64_t)strlen(p));  // always a copy (§4.3)
    if (sp->kind == SP_GIFT && im->gift)
      ((void (*)(void *))im->gift)((void *)(uintptr_t)r);
    return s;
  }
  case SP_NSTR: {
    if (r == 0) return PF_FALSE;
    const char *p = (const char *)(uintptr_t)r;
    pf s = pf_string_from_bytes(p, (int64_t)strlen(p));
    if (im->gift) ((void (*)(void *))im->gift)((void *)(uintptr_t)r);
    return s;
  }
  case SP_HANDLE: {
    if (r == 0) blame_msg(im, "result is NULL", 0);
    pf h = handle_wrap((void *)(uintptr_t)r, sp->brand);
    track_handle(h);
    return h;
  }
  case SP_NHANDLE: {
    if (r == 0) return PF_FALSE;
    pf h = handle_wrap((void *)(uintptr_t)r, sp->brand);
    track_handle(h);
    return h;
  }
  }
  pf_fatal("ffi: malformed desc (result spec)");
}

typedef int64_t (*ffi_fn6)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);

static pf ffi_call(pf idx, pf *argv, int n) {
  ffi_import *im = &imports[PF_UNFIX(idx)];
  if (n != im->nargs) pf_fatal("ffi: call arity does not match the declaration");
  int64_t raw[6] = {0, 0, 0, 0, 0, 0};
  for (int i = 0; i < n; i++)
    raw[i] = marshal_out(im, &im->args[i], argv[i], i + 1);
  int64_t r = ((ffi_fn6)im->fn)(raw[0], raw[1], raw[2], raw[3], raw[4], raw[5]);
  pf out = marshal_in(im, r);
  // #:consumes closes AFTER the call: the C side has freed the
  // pointee; null-on-close makes a second crossing a loud error
  for (int i = 0; i < n; i++)
    if (im->args[i].kind == SP_HANDLE_CONSUME) handle_close(argv[i]);
  return out;
}

#else  // __wasm__: registration already refused; calls are unreachable

static pf ffi_call(pf idx, pf *argv, int n) {
  (void)idx; (void)argv; (void)n;
  pf_fatal("ffi: unreachable (registration refuses in the browser)");
}

#endif

pf pf_ffi_call0(pf i) { return ffi_call(i, NULL, 0); }
pf pf_ffi_call1(pf i, pf a) { pf v[1] = {a}; return ffi_call(i, v, 1); }
pf pf_ffi_call2(pf i, pf a, pf b) { pf v[2] = {a, b}; return ffi_call(i, v, 2); }
pf pf_ffi_call3(pf i, pf a, pf b, pf c) { pf v[3] = {a, b, c}; return ffi_call(i, v, 3); }
pf pf_ffi_call4(pf i, pf a, pf b, pf c, pf d) { pf v[4] = {a, b, c, d}; return ffi_call(i, v, 4); }
pf pf_ffi_call5(pf i, pf a, pf b, pf c, pf d, pf e) { pf v[5] = {a, b, c, d, e}; return ffi_call(i, v, 5); }

// six arguments arrive PACKED in a vector (the import index occupies
// one of the six prim-call argument registers; see the header note)
pf pf_ffi_call6(pf i, pf argv) {
  pf_expect_kind(argv, PF_KIND_VECTOR);
  if (pf_len_of(argv) != 6) pf_fatal("ffi: packed call expects 6 arguments");
  pf v[6];
  for (int k = 0; k < 6; k++) v[k] = pf_heap_ptr(argv)[1 + k];
  return ffi_call(i, v, 6);
}

void pf_lib_foreign_init(void) {
  // equal? on handles is identity (equal = NULL in the kind desc)
  static const pf_kind_desc desc = { "foreign", display_handle, NULL };
  pf_register_kind(PF_KIND_FOREIGN, &desc);
}
