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
#include <stdlib.h>
#include <string.h>
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

// Printing a hash, either flavor (lib/hamt.c uses these too):
//   {k1 ↦ v1, k2 ↦ v2}   entries sorted by the key's printed text
//   ∅                    the empty hash
// Sorting makes the output independent of each runtime's storage order,
// so the reference interpreter (stdlib.rkt render-value) prints a hash
// byte-for-byte like this. strcmp on UTF-8 is codepoint order, which is
// Racket's string<?.
struct pf_hash_entry_text { char *key, *val; };
struct pf_hash_printer { struct pf_hash_entry_text *e; int64_t n, cap; };

static char *display_to_string(pf v) {
  char *buf = NULL;
  size_t len = 0;
  FILE *mem = open_memstream(&buf, &len);
  pf_display_value_to(v, mem);
  fclose(mem);
  return buf;
}

void *pf_hash_printer_new(void) { return calloc(1, sizeof(struct pf_hash_printer)); }

void pf_hash_printer_add(pf k, pf v, void *printer) {
  struct pf_hash_printer *p = printer;
  if (p->n == p->cap) {
    p->cap = p->cap ? 2 * p->cap : 8;
    p->e = realloc(p->e, (size_t)p->cap * sizeof *p->e);
  }
  p->e[p->n].key = display_to_string(k);
  p->e[p->n].val = display_to_string(v);
  p->n++;
}

static int by_key_text(const void *a, const void *b) {
  return strcmp(((const struct pf_hash_entry_text *)a)->key, ((const struct pf_hash_entry_text *)b)->key);
}

void pf_hash_printer_finish(void *printer, FILE *out) {
  struct pf_hash_printer *p = printer;
  if (p->n == 0) {
    fputs("\u2205", out);
  } else {
    qsort(p->e, (size_t)p->n, sizeof *p->e, by_key_text);
    fputc('{', out);
    for (int64_t i = 0; i < p->n; i++) {
      if (i) fputs(", ", out);
      fprintf(out, "%s \u21a6 %s", p->e[i].key, p->e[i].val);
      free(p->e[i].key);
      free(p->e[i].val);
    }
    fputc('}', out);
  }
  free(p->e);
  free(p);
}

static void display_hash(pf v, FILE *out) {
  int64_t *h = pf_heap_ptr(v);
  int64_t *keys = (int64_t *)(intptr_t)h[3], *vals = (int64_t *)(intptr_t)h[4];
  void *p = pf_hash_printer_new();
  for (int64_t i = 0; i < h[2]; i++)
    if (keys[i] != PF_SLOT_EMPTY) pf_hash_printer_add(keys[i], vals[i], p);
  pf_hash_printer_finish(p, out);
}

void pf_lib_hashes_init(void) {
  static const pf_kind_desc desc = { "hash", display_hash, 0 /* identity */ };
  pf_register_kind(PF_KIND_HASH, &desc);
}
