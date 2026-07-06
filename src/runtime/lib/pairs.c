// lib/pairs.c -- pairs and proper lists.
//
// Manifest entries (stdlib.rkt): cons car cdr pair? null?
//
// Layout (kind PF_KIND_PAIR): | header | car | cdr |
// The empty list is the immediate PF_NIL; a "list" is nil or a pair
// whose cdr is a list. display prints proper and improper lists the
// way Racket's display does: (1 2 3) and (1 . 2).

#include <stdio.h>
#include "../puffin.h"

pf pf_cons(pf a, pf d) {
  pf v = pf_alloc(PF_KIND_PAIR, 2, 16);
  pf_heap_ptr(v)[1] = a;
  pf_heap_ptr(v)[2] = d;
  return v;
}

pf pf_car(pf v) { pf_expect_kind(v, PF_KIND_PAIR); return pf_heap_ptr(v)[1]; }
pf pf_cdr(pf v) { pf_expect_kind(v, PF_KIND_PAIR); return pf_heap_ptr(v)[2]; }
pf pf_pair_huh(pf v) { return PF_BOOL(pf_is_kind(v, PF_KIND_PAIR)); }
pf pf_null_huh(pf v) { return PF_BOOL(v == PF_NIL); }

static void display_pair(pf v, FILE *out) {
  fprintf(out, "(");
  pf_display_value_to(pf_heap_ptr(v)[1], out);
  pf rest = pf_heap_ptr(v)[2];
  while (pf_is_kind(rest, PF_KIND_PAIR)) {
    fprintf(out, " ");
    pf_display_value_to(pf_heap_ptr(rest)[1], out);
    rest = pf_heap_ptr(rest)[2];
  }
  if (rest != PF_NIL) {
    fprintf(out, " . ");
    pf_display_value_to(rest, out);
  }
  fprintf(out, ")");
}

static pf equal_pair(pf a, pf b) {
  return PF_BOOL(pf_equal(pf_heap_ptr(a)[1], pf_heap_ptr(b)[1]) == PF_TRUE &&
                 pf_equal(pf_heap_ptr(a)[2], pf_heap_ptr(b)[2]) == PF_TRUE);
}

void pf_lib_pairs_init(void) {
  static const pf_kind_desc desc = { "pair", display_pair, equal_pair };
  pf_register_kind(PF_KIND_PAIR, &desc);
}
