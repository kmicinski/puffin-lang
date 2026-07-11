// lib/adt.c -- algebraic-datatype constructor instances.
//
// Manifest entries: adt-alloc adt-set! adt-ref adt-tag (internal)
//                   adt? (surface)
//
// This module claims a kind from the extension range (see puffin.h):
//   PF_KIND_ADT = 18   payload: | tag (ctor symbol) | field 0 | ... |
//
// A `define-type` constructor instance gets its OWN heap kind
// (docs/TYPES.md §2): the layout mirrors vectors (slot 0 is the
// constructor's module-mangled symbol, slots 1..n the fields), but
// the distinct kind means `(vector? (Some 1))` is #f, instances
// print as `(Some 1)` (nullary constructors print bare: `None`),
// and `adt?` is a real, disjoint surface predicate. Only the
// desugar lowering constructs instances (adt-alloc/adt-set! are
// compiler-internal), so user code can never forge one.
//
// The header length counts ALL payload slots (tag + fields), like a
// vector's; the field count is len - 1.

#include <stdio.h>
#include "../puffin.h"

#define PF_KIND_ADT 18

pf pf_adt_alloc(pf tag, pf nfields) {
  if ((tag & PF_TAG_MASK) != PF_TAG_SYMBOL) pf_die_kind();
  if ((nfields & PF_TAG_MASK) != PF_TAG_FIXNUM || nfields < 0) pf_die_kind();
  int64_t n = PF_UNFIX(nfields);
  pf v = pf_alloc(PF_KIND_ADT, n + 1, (n + 1) * 8);
  pf_heap_ptr(v)[1] = tag;
  for (int64_t i = 0; i < n; i++) pf_heap_ptr(v)[2 + i] = PF_FIX(0);
  return v;
}

pf pf_adt_set(pf v, pf idx, pf val) {
  pf_expect_kind(v, PF_KIND_ADT);
  if ((idx & PF_TAG_MASK) != PF_TAG_FIXNUM) pf_die_kind();
  int64_t i = PF_UNFIX(idx);
  if (i < 0 || i >= pf_len_of(v) - 1) pf_die_oob();
  pf_heap_ptr(v)[2 + i] = val;
  return PF_VOID;
}

pf pf_adt_ref(pf v, pf idx) {
  pf_expect_kind(v, PF_KIND_ADT);
  if ((idx & PF_TAG_MASK) != PF_TAG_FIXNUM) pf_die_kind();
  int64_t i = PF_UNFIX(idx);
  if (i < 0 || i >= pf_len_of(v) - 1) pf_die_oob();
  return pf_heap_ptr(v)[2 + i];
}

pf pf_adt_tag(pf v) {
  pf_expect_kind(v, PF_KIND_ADT);
  return pf_heap_ptr(v)[1];
}

pf pf_adt_huh(pf v) { return PF_BOOL(pf_is_kind(v, PF_KIND_ADT)); }

// (Some 1); nullary constructors are bare: None
static void display_adt(pf v, FILE *out) {
  int64_t nfields = pf_len_of(v) - 1;
  if (nfields == 0) {
    pf_display_value_to(pf_heap_ptr(v)[1], out);
    return;
  }
  fprintf(out, "(");
  pf_display_value_to(pf_heap_ptr(v)[1], out);
  for (int64_t i = 0; i < nfields; i++) {
    fprintf(out, " ");
    pf_display_value_to(pf_heap_ptr(v)[2 + i], out);
  }
  fprintf(out, ")");
}

// structural, like vectors: same constructor, equal? fields (the
// tag is a symbol, so slot-wise pf_equal covers it too)
static pf equal_adt(pf a, pf b) {
  if (pf_len_of(a) != pf_len_of(b)) return PF_FALSE;
  if (pf_heap_ptr(a)[1] != pf_heap_ptr(b)[1]) return PF_FALSE;
  for (int64_t i = 0; i < pf_len_of(a) - 1; i++)
    if (pf_equal(pf_heap_ptr(a)[2 + i], pf_heap_ptr(b)[2 + i]) != PF_TRUE)
      return PF_FALSE;
  return PF_TRUE;
}

void pf_lib_adt_init(void) {
  static const pf_kind_desc desc = { "adt", display_adt, equal_adt };
  pf_register_kind(PF_KIND_ADT, &desc);
}
