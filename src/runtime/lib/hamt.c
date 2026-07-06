// lib/hamt.c -- persistent (immutable) hashes and sets.
//
// Manifest entries: hash hash-set hash-remove set set-add set-remove
// (the *immutable-by-default* collections; the generic accessors in
// hashes.c / sets.c dispatch here for the immutable kinds)
//
// This module claims kinds from the extension range (see puffin.h):
//   PF_KIND_IHASH = 16   payload: | count | root node (or 0) |
//   PF_KIND_ISET  = 17   payload: | count | root node (or 0) |
//
// The backing structure is a hash array mapped trie (HAMT), CHAMP
// flavor: each node carries two bitmaps over a 64-way fanout --
// `datamap` marks chunks holding an inline entry, `nodemap` marks
// chunks holding a child node. Updates copy the O(log n) path from
// root to leaf; everything else is shared, which is what makes
// `(hash-set h k v)` cheap enough to be the default idiom.
//
// A load-bearing simplification: keys are tagged words compared by
// identity, and the hash is fmix64, a *bijection* on 64-bit words.
// Distinct keys therefore have distinct hashes and can never share
// all eleven 6-bit chunks: no collision buckets exist in this trie.
//
// Removal leaves single-entry nodes uncollapsed (correct, slightly
// sparser than a textbook CHAMP after heavy deletion).
//
// Nodes are raw GC blocks (not tagged heap objects); they are only
// reachable from the root object, and the Boehm GC scans them.

#include <stdio.h>
#include <inttypes.h>
#include "../puffin.h"

#define PF_KIND_IHASH 16
#define PF_KIND_ISET  17

static uint64_t hash_word(uint64_t x) {
  x ^= x >> 33; x *= 0xff51afd7ed558ccdULL;
  x ^= x >> 33; x *= 0xc4ceb9fe1a85ec53ULL;
  x ^= x >> 33;
  return x;
}

// ---------------------------------------------------------------
// Nodes. Layout (all int64 words):
//   [0] datamap   [1] nodemap
//   [2 ..]        2*popcount(datamap) words of inline k,v entries
//   [.. end]      popcount(nodemap) child pointers
// Sets store entries as k,v with v unused (kept identical to hashes
// so all the trie code below is shared).
// ---------------------------------------------------------------

typedef int64_t *node;

static inline int popcnt(uint64_t x) { return __builtin_popcountll(x); }
static inline uint64_t bit_of(uint64_t h, int shift) {
  return 1ULL << ((h >> shift) & 63);
}
static inline int index_of(uint64_t bitmap, uint64_t bit) {
  return popcnt(bitmap & (bit - 1));
}

static inline int n_entries(node n) { return popcnt((uint64_t)n[0]); }
static inline int n_children(node n) { return popcnt((uint64_t)n[1]); }
static inline pf *entry_at(node n, int i) { return (pf *)&n[2 + 2 * i]; }
static inline node *child_at(node n, int i) {
  return (node *)&n[2 + 2 * n_entries(n) + i];
}

static node alloc_node(uint64_t datamap, uint64_t nodemap) {
  int words = 2 + 2 * popcnt(datamap) + popcnt(nodemap);
  node n = (node)pf_alloc_raw(words * 8);
  n[0] = (int64_t)datamap;
  n[1] = (int64_t)nodemap;
  return n;
}

// copy n, growing/shrinking around the edit position as needed
static node copy_node(node n) {
  int words = 2 + 2 * n_entries(n) + n_children(n);
  node m = alloc_node((uint64_t)n[0], (uint64_t)n[1]);
  for (int i = 2; i < words; i++) m[i] = n[i];
  return m;
}

// insert (k,v); *added = 1 if the key is new. Returns the new root.
static node node_insert(node n, uint64_t h, int shift, pf k, pf v, int *added) {
  uint64_t bit = bit_of(h, shift);
  if (n == 0) {
    node m = alloc_node(bit, 0);
    entry_at(m, 0)[0] = k;
    entry_at(m, 0)[1] = v;
    *added = 1;
    return m;
  }
  uint64_t datamap = (uint64_t)n[0], nodemap = (uint64_t)n[1];
  if (datamap & bit) {
    int i = index_of(datamap, bit);
    pf k0 = entry_at(n, i)[0], v0 = entry_at(n, i)[1];
    if (k0 == k) {
      // overwrite in place (copy)
      node m = copy_node(n);
      entry_at(m, i)[1] = v;
      *added = 0;
      return m;
    }
    // two distinct keys in one chunk: push the old entry down a
    // level and retry (their hashes differ, so this terminates)
    uint64_t h0 = hash_word((uint64_t)k0);
    node sub = 0;
    int dummy;
    sub = node_insert(sub, h0, shift + 6, k0, v0, &dummy);
    sub = node_insert(sub, h, shift + 6, k, v, &dummy);
    // new node: entry i removed, child added
    uint64_t ndata = datamap & ~bit;
    uint64_t nnode = nodemap | bit;
    node m = alloc_node(ndata, nnode);
    int ne = popcnt(ndata);
    for (int j = 0, src = 0; j < ne; j++, src++) {
      if (src == i) src++;
      entry_at(m, j)[0] = entry_at(n, src)[0];
      entry_at(m, j)[1] = entry_at(n, src)[1];
    }
    int ci = index_of(nnode, bit);
    int oldc = popcnt(nodemap);
    for (int j = 0, src = 0; j < oldc + 1; j++) {
      if (j == ci) { *child_at(m, j) = sub; continue; }
      *child_at(m, j) = *child_at(n, src++);
    }
    *added = 1;
    return m;
  }
  if (nodemap & bit) {
    int ci = index_of(nodemap, bit);
    node sub = node_insert(*child_at(n, ci), h, shift + 6, k, v, added);
    node m = copy_node(n);
    *child_at(m, ci) = sub;
    return m;
  }
  // empty chunk: add an inline entry
  uint64_t ndata = datamap | bit;
  node m = alloc_node(ndata, nodemap);
  int i = index_of(ndata, bit);
  int ne = popcnt(datamap);
  for (int dst = 0, src = 0; dst < ne + 1; dst++) {
    if (dst == i) {
      entry_at(m, dst)[0] = k;
      entry_at(m, dst)[1] = v;
    } else {
      entry_at(m, dst)[0] = entry_at(n, src)[0];
      entry_at(m, dst)[1] = entry_at(n, src)[1];
      src++;
    }
  }
  for (int j = 0; j < popcnt(nodemap); j++) *child_at(m, j) = *child_at(n, j);
  *added = 1;
  return m;
}

// lookup: returns 1 and writes *out if present
static int node_lookup(node n, uint64_t h, int shift, pf k, pf *out) {
  while (n) {
    uint64_t bit = bit_of(h, shift);
    uint64_t datamap = (uint64_t)n[0], nodemap = (uint64_t)n[1];
    if (datamap & bit) {
      int i = index_of(datamap, bit);
      if (entry_at(n, i)[0] == k) { *out = entry_at(n, i)[1]; return 1; }
      return 0;
    }
    if (!(nodemap & bit)) return 0;
    n = *child_at(n, index_of(nodemap, bit));
    shift += 6;
  }
  return 0;
}

// remove k; *removed set if it was present. (No node collapsing.)
static node node_remove(node n, uint64_t h, int shift, pf k, int *removed) {
  if (n == 0) { *removed = 0; return 0; }
  uint64_t bit = bit_of(h, shift);
  uint64_t datamap = (uint64_t)n[0], nodemap = (uint64_t)n[1];
  if (datamap & bit) {
    int i = index_of(datamap, bit);
    if (entry_at(n, i)[0] != k) { *removed = 0; return n; }
    *removed = 1;
    uint64_t ndata = datamap & ~bit;
    node m = alloc_node(ndata, nodemap);
    int ne = popcnt(datamap);
    for (int j = 0, dst = 0; j < ne; j++) {
      if (j == i) continue;
      entry_at(m, dst)[0] = entry_at(n, j)[0];
      entry_at(m, dst)[1] = entry_at(n, j)[1];
      dst++;
    }
    for (int j = 0; j < popcnt(nodemap); j++) *child_at(m, j) = *child_at(n, j);
    return m;
  }
  if (nodemap & bit) {
    int ci = index_of(nodemap, bit);
    node sub = node_remove(*child_at(n, ci), h, shift + 6, k, removed);
    if (!*removed) return n;
    node m = copy_node(n);
    *child_at(m, ci) = sub;
    return m;
  }
  *removed = 0;
  return n;
}

// fold every entry through a callback
static void node_walk(node n, void (*fn)(pf k, pf v, void *acc), void *acc) {
  if (n == 0) return;
  for (int i = 0; i < n_entries(n); i++) fn(entry_at(n, i)[0], entry_at(n, i)[1], acc);
  for (int i = 0; i < n_children(n); i++) node_walk(*child_at(n, i), fn, acc);
}

// ---------------------------------------------------------------
// Roots (the tagged, user-visible objects)
// ---------------------------------------------------------------

static pf make_root(int kind, int64_t count, node root) {
  pf v = pf_alloc(kind, 2, 2 * 8);
  pf_heap_ptr(v)[1] = count;
  pf_heap_ptr(v)[2] = (int64_t)(intptr_t)root;
  return v;
}

static inline int64_t root_count(pf v) { return pf_heap_ptr(v)[1]; }
static inline node root_node(pf v) { return (node)(intptr_t)pf_heap_ptr(v)[2]; }

int pf_ihash_is(pf v) { return pf_is_kind(v, PF_KIND_IHASH); }
int pf_iset_is(pf v)  { return pf_is_kind(v, PF_KIND_ISET); }

// the empty collections are shared singletons (they're immutable)
static pf empty_hash = 0, empty_set = 0;

pf pf_ihash_empty(void) {
  if (!empty_hash) {
    empty_hash = make_root(PF_KIND_IHASH, 0, 0);
    // keep the singleton alive: the cache cell is in the data
    // segment, which the GC scans
  }
  return empty_hash;
}

pf pf_iset_empty(void) {
  if (!empty_set) empty_set = make_root(PF_KIND_ISET, 0, 0);
  return empty_set;
}

pf pf_ihash_set(pf hv, pf k, pf v) {
  pf_expect_kind(hv, PF_KIND_IHASH);
  int added = 0;
  node root = node_insert(root_node(hv), hash_word((uint64_t)k), 0, k, v, &added);
  return make_root(PF_KIND_IHASH, root_count(hv) + added, root);
}

pf pf_ihash_remove(pf hv, pf k) {
  pf_expect_kind(hv, PF_KIND_IHASH);
  int removed = 0;
  node root = node_remove(root_node(hv), hash_word((uint64_t)k), 0, k, &removed);
  if (!removed) return hv;
  return make_root(PF_KIND_IHASH, root_count(hv) - 1, root);
}

int pf_ihash_lookup(pf hv, pf k, pf *out) {
  return node_lookup(root_node(hv), hash_word((uint64_t)k), 0, k, out);
}

pf pf_iset_add(pf sv, pf k) {
  pf_expect_kind(sv, PF_KIND_ISET);
  int added = 0;
  node root = node_insert(root_node(sv), hash_word((uint64_t)k), 0, k, PF_TRUE, &added);
  if (!added) return sv;
  return make_root(PF_KIND_ISET, root_count(sv) + 1, root);
}

pf pf_iset_remove(pf sv, pf k) {
  pf_expect_kind(sv, PF_KIND_ISET);
  int removed = 0;
  node root = node_remove(root_node(sv), hash_word((uint64_t)k), 0, k, &removed);
  if (!removed) return sv;
  return make_root(PF_KIND_ISET, root_count(sv) - 1, root);
}

int64_t pf_hamt_count(pf v) { return root_count(v); }

extern pf pf_cons(pf, pf); // lib/pairs.c

struct list_acc { pf list; int keys_only; };
static void cons_entry(pf k, pf v, void *a) {
  struct list_acc *acc = (struct list_acc *)a;
  (void)v;
  acc->list = pf_cons(k, acc->list);
}

pf pf_hamt_keys(pf v) {
  struct list_acc acc = { PF_NIL, 1 };
  node_walk(root_node(v), cons_entry, &acc);
  return acc.list;
}

// ---------------------------------------------------------------
// equal? and display handlers
// ---------------------------------------------------------------

struct eq_acc { pf other; int ok; };
static void check_entry_hash(pf k, pf v, void *a) {
  struct eq_acc *acc = (struct eq_acc *)a;
  if (!acc->ok) return;
  pf v2;
  if (!pf_ihash_lookup(acc->other, k, &v2) || pf_equal(v, v2) != PF_TRUE) acc->ok = 0;
}
static pf equal_ihash(pf a, pf b) {
  if (root_count(a) != root_count(b)) return PF_FALSE;
  struct eq_acc acc = { b, 1 };
  node_walk(root_node(a), check_entry_hash, &acc);
  return PF_BOOL(acc.ok);
}

static void check_entry_set(pf k, pf v, void *a) {
  struct eq_acc *acc = (struct eq_acc *)a;
  (void)v;
  if (!acc->ok) return;
  pf dummy;
  if (!node_lookup(root_node(acc->other), hash_word((uint64_t)k), 0, k, &dummy)) acc->ok = 0;
}
static pf equal_iset(pf a, pf b) {
  if (root_count(a) != root_count(b)) return PF_FALSE;
  struct eq_acc acc = { b, 1 };
  node_walk(root_node(a), check_entry_set, &acc);
  return PF_BOOL(acc.ok);
}

static void display_ihash(pf v) { printf("#<hash:%" PRId64 ">", root_count(v)); }
static void display_iset(pf v)  { printf("#<set:%" PRId64 ">", root_count(v)); }

void pf_lib_hamt_init(void) {
  static const pf_kind_desc hdesc = { "hash", display_ihash, equal_ihash };
  static const pf_kind_desc sdesc = { "set", display_iset, equal_iset };
  pf_register_kind(PF_KIND_IHASH, &hdesc);
  pf_register_kind(PF_KIND_ISET, &sdesc);
}
