// lib/table.c -- shared open-addressing table guts (see table.h).

#include "table.h"

static uint64_t hash_word(uint64_t x) {
  // fmix64 from MurmurHash3
  x ^= x >> 33; x *= 0xff51afd7ed558ccdULL;
  x ^= x >> 33; x *= 0xc4ceb9fe1a85ec53ULL;
  x ^= x >> 33;
  return x;
}

int64_t *pf_table_alloc_slots(int64_t cap) {
  int64_t *slots = (int64_t *)pf_alloc_raw(cap * 8);
  for (int64_t i = 0; i < cap; i++) slots[i] = PF_SLOT_EMPTY;
  return slots;
}

int64_t pf_table_probe(int64_t *keys, int64_t cap, pf key) {
  int64_t i = (int64_t)(hash_word((uint64_t)key) & (uint64_t)(cap - 1));
  while (keys[i] != PF_SLOT_EMPTY && keys[i] != key) i = (i + 1) & (cap - 1);
  return i;
}

void pf_table_grow(int64_t *h, int has_vals) {
  int64_t cap = h[2], newcap = cap * 2;
  int64_t *keys = (int64_t *)(intptr_t)h[3];
  int64_t *vals = has_vals ? (int64_t *)(intptr_t)h[4] : 0;
  int64_t *nk = pf_table_alloc_slots(newcap);
  int64_t *nv = has_vals ? pf_table_alloc_slots(newcap) : 0;
  for (int64_t i = 0; i < cap; i++) {
    if (keys[i] == PF_SLOT_EMPTY) continue;
    int64_t j = pf_table_probe(nk, newcap, keys[i]);
    nk[j] = keys[i];
    if (has_vals) nv[j] = vals[i];
  }
  h[2] = newcap;
  h[3] = (int64_t)(intptr_t)nk;
  if (has_vals) h[4] = (int64_t)(intptr_t)nv;
}

// Removal by rehash-the-cluster: delete the key, then re-insert
// every entry in the probe cluster after it (the simplest correct
// scheme for linear probing).
void pf_table_remove(int64_t *h, pf key, int has_vals) {
  int64_t cap = h[2];
  int64_t *keys = (int64_t *)(intptr_t)h[3];
  int64_t *vals = has_vals ? (int64_t *)(intptr_t)h[4] : 0;
  int64_t i = pf_table_probe(keys, cap, key);
  if (keys[i] == PF_SLOT_EMPTY) return;
  keys[i] = PF_SLOT_EMPTY;
  if (has_vals) vals[i] = PF_SLOT_EMPTY;
  h[1]--;
  int64_t j = (i + 1) & (cap - 1);
  while (keys[j] != PF_SLOT_EMPTY) {
    pf k = keys[j], v = has_vals ? vals[j] : 0;
    keys[j] = PF_SLOT_EMPTY;
    if (has_vals) vals[j] = PF_SLOT_EMPTY;
    int64_t dst = pf_table_probe(keys, cap, k);
    keys[dst] = k;
    if (has_vals) vals[dst] = v;
    j = (j + 1) & (cap - 1);
  }
}
