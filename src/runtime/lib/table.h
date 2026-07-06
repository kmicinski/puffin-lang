// lib/table.h -- the open-addressing table shared by hashes and sets.
//
// Not part of the public ABI (puffin.h); this is lib-internal
// machinery. Keys are tagged Puffin words compared by identity
// (eq?), which is the right notion for fixnums, booleans, and
// interned symbols--the common key types. Linear probing over a
// power-of-two capacity, growing at 70% load.
//
// Both hashes and sets embed the same payload prefix:
//   [1] count  [2] capacity  [3] keys block  ([4] vals block, hashes only)

#ifndef PUFFIN_TABLE_H
#define PUFFIN_TABLE_H

#include "../puffin.h"

// The empty-slot marker: an immediate no user value can ever be
// (tag 010 with payload bits shared by no real immediate... we use
// 6, which is (0<<3)|6 -- not a valid tag pattern for user data).
#define PF_SLOT_EMPTY 6

int64_t *pf_table_alloc_slots(int64_t cap);
int64_t  pf_table_probe(int64_t *keys, int64_t cap, pf key);
void     pf_table_grow(int64_t *payload, int has_vals);
void     pf_table_remove(int64_t *payload, pf key, int has_vals);

#endif // PUFFIN_TABLE_H
