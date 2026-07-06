// lib/sets.c -- mutable sets of values.
//
// Manifest entries: make-set set-add! set-member? set-remove!
//                   set-count set->list set?
//
// Layout (kind PF_KIND_SET):
//   | header | count | capacity | keys block |
// backed by lib/table.c's open-addressing scheme (eq?-keyed).

#include <stdio.h>
#include <inttypes.h>
#include "table.h"

// immutable sets (lib/hamt.c)
extern int pf_iset_is(pf v);
extern int pf_ihash_lookup(pf hv, pf k, pf *out); // same trie layout
extern int64_t pf_hamt_count(pf v);
extern pf pf_hamt_keys(pf v);

pf pf_make_set(void) {
  pf v = pf_alloc(PF_KIND_SET, 3, 3 * 8);
  int64_t *h = pf_heap_ptr(v);
  h[1] = 0;
  h[2] = 8;
  h[3] = (int64_t)(intptr_t)pf_table_alloc_slots(8);
  return v;
}

pf pf_set_add(pf sv, pf key) {
  pf_expect_kind(sv, PF_KIND_SET);
  int64_t *h = pf_heap_ptr(sv);
  if (10 * (h[1] + 1) > 7 * h[2]) pf_table_grow(h, 0);
  int64_t *keys = (int64_t *)(intptr_t)h[3];
  int64_t i = pf_table_probe(keys, h[2], key);
  if (keys[i] == PF_SLOT_EMPTY) { keys[i] = key; h[1]++; }
  return PF_VOID;
}

pf pf_set_member(pf sv, pf key) {
  if (pf_iset_is(sv)) {
    pf out;
    return PF_BOOL(pf_ihash_lookup(sv, key, &out));
  }
  pf_expect_kind(sv, PF_KIND_SET);
  int64_t *h = pf_heap_ptr(sv);
  int64_t *keys = (int64_t *)(intptr_t)h[3];
  return PF_BOOL(keys[pf_table_probe(keys, h[2], key)] != PF_SLOT_EMPTY);
}

pf pf_set_remove(pf sv, pf key) {
  pf_expect_kind(sv, PF_KIND_SET);
  pf_table_remove(pf_heap_ptr(sv), key, 0);
  return PF_VOID;
}

pf pf_set_count(pf sv) {
  if (pf_iset_is(sv)) return PF_FIX(pf_hamt_count(sv));
  pf_expect_kind(sv, PF_KIND_SET);
  return PF_FIX(pf_heap_ptr(sv)[1]);
}

extern pf pf_cons(pf, pf); // lib/pairs.c

pf pf_set_to_list(pf sv) {
  if (pf_iset_is(sv)) return pf_hamt_keys(sv);
  pf_expect_kind(sv, PF_KIND_SET);
  int64_t *h = pf_heap_ptr(sv);
  int64_t *keys = (int64_t *)(intptr_t)h[3];
  pf acc = PF_NIL;
  for (int64_t i = 0; i < h[2]; i++)
    if (keys[i] != PF_SLOT_EMPTY) acc = pf_cons(keys[i], acc);
  return acc;
}

pf pf_set_huh(pf v) { return PF_BOOL(pf_is_kind(v, PF_KIND_SET) || pf_iset_is(v)); }

static void display_set(pf v) {
  printf("#<set:%" PRId64 ">", (int64_t)pf_heap_ptr(v)[1]);
}

void pf_lib_sets_init(void) {
  static const pf_kind_desc desc = { "set", display_set, 0 /* identity */ };
  pf_register_kind(PF_KIND_SET, &desc);
}
