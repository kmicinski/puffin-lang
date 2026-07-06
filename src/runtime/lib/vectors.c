// lib/vectors.c -- vectors (fixed-size, heterogeneous).
//
// Manifest entries: make-vector vector-ref vector-set! vector-length
//                   vector?
//
// Layout (kind PF_KIND_VECTOR): | header | slot 0 | ... | slot n-1 |
//
// vector-ref / vector-set! here are the *safe*, user-facing
// operations: full type and bounds checks, dynamic indices. The
// compiler's internal accesses (closure environments, assignment
// boxes, arity-overflow argument vectors) instead emit inline
// unsafe-vector-ref/-set! instructions with literal indices, which
// never need checks; see select-instructions in the backends.

#include <stdio.h>
#include "../puffin.h"

pf pf_make_vector(pf len) {
  if ((len & PF_TAG_MASK) != PF_TAG_FIXNUM || len < 0) pf_die_kind();
  int64_t n = PF_UNFIX(len);
  pf v = pf_alloc(PF_KIND_VECTOR, n, n * 8);
  for (int64_t i = 0; i < n; i++) pf_heap_ptr(v)[1 + i] = PF_FIX(0);
  return v;
}

pf pf_vector_ref(pf v, pf idx) {
  pf_expect_kind(v, PF_KIND_VECTOR);
  if ((idx & PF_TAG_MASK) != PF_TAG_FIXNUM) pf_die_kind();
  int64_t i = PF_UNFIX(idx);
  if (i < 0 || i >= pf_len_of(v)) pf_die_oob();
  return pf_heap_ptr(v)[1 + i];
}

pf pf_vector_set(pf v, pf idx, pf val) {
  pf_expect_kind(v, PF_KIND_VECTOR);
  if ((idx & PF_TAG_MASK) != PF_TAG_FIXNUM) pf_die_kind();
  int64_t i = PF_UNFIX(idx);
  if (i < 0 || i >= pf_len_of(v)) pf_die_oob();
  pf_heap_ptr(v)[1 + i] = val;
  return PF_VOID;
}

pf pf_vector_length(pf v) {
  pf_expect_kind(v, PF_KIND_VECTOR);
  return PF_FIX(pf_len_of(v));
}

pf pf_vector_huh(pf v) { return PF_BOOL(pf_is_kind(v, PF_KIND_VECTOR)); }

static void display_vector(pf v, FILE *out) {
  fprintf(out, "#(");
  for (int64_t i = 0; i < pf_len_of(v); i++) {
    if (i) fprintf(out, " ");
    pf_display_value_to(pf_heap_ptr(v)[1 + i], out);
  }
  fprintf(out, ")");
}

static pf equal_vector(pf a, pf b) {
  if (pf_len_of(a) != pf_len_of(b)) return PF_FALSE;
  for (int64_t i = 0; i < pf_len_of(a); i++)
    if (pf_equal(pf_heap_ptr(a)[1 + i], pf_heap_ptr(b)[1 + i]) != PF_TRUE)
      return PF_FALSE;
  return PF_TRUE;
}

void pf_lib_vectors_init(void) {
  static const pf_kind_desc desc = { "vector", display_vector, equal_vector };
  pf_register_kind(PF_KIND_VECTOR, &desc);
}
