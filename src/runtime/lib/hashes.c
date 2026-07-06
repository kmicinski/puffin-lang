// lib/hashes.c -- mutable key/value maps.
//
// Manifest entries: make-hash hash-set! hash-ref hash-ref/default
//                   hash-has-key? hash-remove! hash-count hash-keys
//                   hash?
//
// Layout (kind PF_KIND_HASH):
//   | header | count | capacity | keys block | vals block |
// backed by lib/table.c's open-addressing scheme (eq?-keyed).

#include <stdio.h>
#include <inttypes.h>
#include "table.h"

// immutable hashes (lib/hamt.c): the generic accessors below accept
// both flavors, mirroring Racket's hash-ref & friends
extern int pf_ihash_is(pf v);
extern int pf_ihash_lookup(pf hv, pf k, pf *out);
extern int64_t pf_hamt_count(pf v);
extern pf pf_hamt_keys(pf v);

pf pf_make_hash(void) {
  pf v = pf_alloc(PF_KIND_HASH, 4, 4 * 8);
  int64_t *h = pf_heap_ptr(v);
  h[1] = 0;
  h[2] = 8;
  h[3] = (int64_t)(intptr_t)pf_table_alloc_slots(8);
  h[4] = (int64_t)(intptr_t)pf_table_alloc_slots(8);
  return v;
}

pf pf_hash_set(pf hv, pf key, pf val) {
  pf_expect_kind(hv, PF_KIND_HASH);
  int64_t *h = pf_heap_ptr(hv);
  if (10 * (h[1] + 1) > 7 * h[2]) pf_table_grow(h, 1);
  int64_t *keys = (int64_t *)(intptr_t)h[3], *vals = (int64_t *)(intptr_t)h[4];
  int64_t i = pf_table_probe(keys, h[2], key);
  if (keys[i] == PF_SLOT_EMPTY) { keys[i] = key; h[1]++; }
  vals[i] = val;
  return PF_VOID;
}

pf pf_hash_ref(pf hv, pf key) {
  if (pf_ihash_is(hv)) {
    pf out;
    if (!pf_ihash_lookup(hv, key, &out)) pf_fatal("hash-ref: key not found");
    return out;
  }
  pf_expect_kind(hv, PF_KIND_HASH);
  int64_t *h = pf_heap_ptr(hv);
  int64_t *keys = (int64_t *)(intptr_t)h[3], *vals = (int64_t *)(intptr_t)h[4];
  int64_t i = pf_table_probe(keys, h[2], key);
  if (keys[i] == PF_SLOT_EMPTY) pf_fatal("hash-ref: key not found");
  return vals[i];
}

pf pf_hash_ref_default(pf hv, pf key, pf dflt) {
  if (pf_ihash_is(hv)) {
    pf out;
    return pf_ihash_lookup(hv, key, &out) ? out : dflt;
  }
  pf_expect_kind(hv, PF_KIND_HASH);
  int64_t *h = pf_heap_ptr(hv);
  int64_t *keys = (int64_t *)(intptr_t)h[3], *vals = (int64_t *)(intptr_t)h[4];
  int64_t i = pf_table_probe(keys, h[2], key);
  return keys[i] == PF_SLOT_EMPTY ? dflt : vals[i];
}

pf pf_hash_has(pf hv, pf key) {
  if (pf_ihash_is(hv)) {
    pf out;
    return PF_BOOL(pf_ihash_lookup(hv, key, &out));
  }
  pf_expect_kind(hv, PF_KIND_HASH);
  int64_t *h = pf_heap_ptr(hv);
  int64_t *keys = (int64_t *)(intptr_t)h[3];
  return PF_BOOL(keys[pf_table_probe(keys, h[2], key)] != PF_SLOT_EMPTY);
}

pf pf_hash_remove(pf hv, pf key) {
  pf_expect_kind(hv, PF_KIND_HASH);
  pf_table_remove(pf_heap_ptr(hv), key, 1);
  return PF_VOID;
}

pf pf_hash_count(pf hv) {
  if (pf_ihash_is(hv)) return PF_FIX(pf_hamt_count(hv));
  pf_expect_kind(hv, PF_KIND_HASH);
  return PF_FIX(pf_heap_ptr(hv)[1]);
}

extern pf pf_cons(pf, pf); // lib/pairs.c

pf pf_hash_keys(pf hv) {
  if (pf_ihash_is(hv)) return pf_hamt_keys(hv);
  pf_expect_kind(hv, PF_KIND_HASH);
  int64_t *h = pf_heap_ptr(hv);
  int64_t *keys = (int64_t *)(intptr_t)h[3];
  pf acc = PF_NIL;
  for (int64_t i = 0; i < h[2]; i++)
    if (keys[i] != PF_SLOT_EMPTY) acc = pf_cons(keys[i], acc);
  return acc;
}

pf pf_hash_huh(pf v) { return PF_BOOL(pf_is_kind(v, PF_KIND_HASH) || pf_ihash_is(v)); }

static void display_hash(pf v, FILE *out) {
  fprintf(out, "#<hash:%" PRId64 ">", (int64_t)pf_heap_ptr(v)[1]);
}

void pf_lib_hashes_init(void) {
  static const pf_kind_desc desc = { "hash", display_hash, 0 /* identity */ };
  pf_register_kind(PF_KIND_HASH, &desc);
}
