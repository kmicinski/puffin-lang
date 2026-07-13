// lib/cast.c -- transient gradual-type casts (docs/TYPES.md §4).
//
// Manifest entry: cast-check (internal)
//
// (cast-check v desc blame): the compilers' desugar passes guard
// every DECLARED annotation boundary -- [x : t] formals, `: rt`
// results, (ann e t), annotated let bindings, (: x t) value
// defines -- with a call to this function. The check is FIRST-ORDER
// (transient-style): only the value's outermost shape is validated;
// element types, field types, and function types are never
// traversed.
//
// desc is quoted data built at compile time by desugar:
//
//   Int Bool Sym Str Void        base kinds (a bare symbol)
//   Pairof List Vec Hash Set     heap shapes (a bare symbol: the
//                                desugars strip type arguments --
//                                first-order means only the head is
//                                checkable anyway -- and strip (Mut
//                                ...) wrappers, because a (Mut t)
//                                and a plain t share heap kinds at
//                                runtime: the same check applies)
//   (adt <type> tag ...)         a define-type annotation: the value
//                                must be a constructor instance
//                                whose tag is one of the listed
//                                (module-mangled) constructor
//                                symbols. <type> is the annotation
//                                as written, for the error message,
//                                so (Some 1) passes an (Option Int)
//                                cast but a Shape instance fails it.
//
// Arrow types (-> ...)/(->* ...) get NO cast at all -- the desugars
// emit none. On the bytecode VM a bare function value is a tagged
// fixnum function INDEX, indistinguishable from an Int, so "is this
// callable" cannot be answered soundly there; the call site's own
// failure is the dynamic net for arrows. Likewise `_` and type
// variables emit no cast (the gradual guarantee: unannotated code
// compiles untouched).
//
// On failure: pf_fatal with
//   cast: expected <type>, got <value> (blame: <label>)
// where <label> is a compile-time string naming the boundary
// ("f's argument x", "f's result", "ann", "let x", "define x").
// The Racket reference implementation in src/stdlib.rkt prints the
// identical line and exits 255; golden-style cast tests compare the
// two byte-for-byte.

#include <stdio.h>
#include <stdlib.h>
#include "../puffin.h"

// ext-kind predicates owned by other lib modules (hamt.c, adt.c,
// foreign.c); using them keeps the ext kind ids (16/17/18/19) in one
// place each.
extern int pf_ihash_is(pf v);
extern int pf_iset_is(pf v);
extern pf pf_adt_huh(pf v);
extern pf pf_adt_tag(pf v);
extern int pf_foreign_is_brand(pf v, pf brand);

// desc head symbols, interned once (the intern table is shared with
// compile-time symbols, so tagged-word equality is exact)
static pf s_Int, s_Bool, s_Sym, s_Str, s_Void;
static pf s_Pairof, s_List, s_Vec, s_Hash, s_Set, s_adt, s_fptr;
static int syms_ready = 0;

static pf sym(const char *name) {
  return (pf_intern_symbol(name) << 3) | PF_TAG_SYMBOL;
}

static void init_syms(void) {
  s_Int = sym("Int");   s_Bool = sym("Bool"); s_Sym = sym("Sym");
  s_Str = sym("Str");   s_Void = sym("Void");
  s_Pairof = sym("Pairof"); s_List = sym("List"); s_Vec = sym("Vec");
  s_Hash = sym("Hash"); s_Set = sym("Set");   s_adt = sym("adt");
  s_fptr = sym("fptr");
  syms_ready = 1;
}

static pf pair_car(pf v) { return pf_heap_ptr(v)[1]; }
static pf pair_cdr(pf v) { return pf_heap_ptr(v)[2]; }

static int shape_ok(pf v, pf desc) {
  if ((desc & PF_TAG_MASK) == PF_TAG_SYMBOL) {
    if (desc == s_Int)    return (v & PF_TAG_MASK) == PF_TAG_FIXNUM;
    if (desc == s_Bool)   return v == PF_TRUE || v == PF_FALSE;
    if (desc == s_Sym)    return (v & PF_TAG_MASK) == PF_TAG_SYMBOL;
    if (desc == s_Str)    return pf_is_kind(v, PF_KIND_STRING);
    if (desc == s_Void)   return v == PF_VOID;
    if (desc == s_Pairof) return pf_is_kind(v, PF_KIND_PAIR);
    if (desc == s_List)   return v == PF_NIL || pf_is_kind(v, PF_KIND_PAIR);
    if (desc == s_Vec)    return pf_is_kind(v, PF_KIND_VECTOR);
    if (desc == s_Hash)   return pf_is_kind(v, PF_KIND_HASH) || pf_ihash_is(v);
    if (desc == s_Set)    return pf_is_kind(v, PF_KIND_SET) || pf_iset_is(v);
    return 1;                       // unknown head: permissive (unreachable
                                    // from desugar-built descs)
  }
  if (pf_is_kind(desc, PF_KIND_PAIR) && pair_car(desc) == s_adt) {
    if (pf_adt_huh(v) != PF_TRUE) return 0;
    pf tag = pf_adt_tag(v);
    for (pf rest = pair_cdr(pair_cdr(desc)); pf_is_kind(rest, PF_KIND_PAIR);
         rest = pair_cdr(rest))
      if (pair_car(rest) == tag) return 1;
    return 0;
  }
  // (fptr <shown> <brand>): a define-foreign-type annotation -- the
  // value must be a kind-19 handle carrying the (mangled) brand
  // (docs/FFI.md §6.1). <shown> is the source spelling, for messages.
  if (pf_is_kind(desc, PF_KIND_PAIR) && pair_car(desc) == s_fptr)
    return pf_foreign_is_brand(v, pair_car(pair_cdr(pair_cdr(desc))));
  return 1;                         // malformed desc: permissive
}

pf pf_cast_check(pf v, pf desc, pf blame) {
  if (!syms_ready) init_syms();
  if (shape_ok(v, desc)) return v;
  char *buf = NULL;
  size_t len = 0;
  FILE *mem = open_memstream(&buf, &len);
  if (!mem) pf_fatal("cast: out of memory");
  fprintf(mem, "cast: expected ");
  pf shown = (pf_is_kind(desc, PF_KIND_PAIR)
              && (pair_car(desc) == s_adt || pair_car(desc) == s_fptr))
                 ? pair_car(pair_cdr(desc))
                 : desc;
  pf_display_value_to(shown, mem);
  fprintf(mem, ", got ");
  pf_display_value_to(v, mem);
  fprintf(mem, " (blame: ");
  pf_display_value_to(blame, mem);
  fprintf(mem, ")");
  fclose(mem);
  pf_fatal(buf);
}
