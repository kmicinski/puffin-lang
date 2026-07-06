// lib/strings.c -- immutable byte strings.
//
// Manifest entries: string? string-length string-append string=?
//                   symbol->string string->symbol
//
// Layout (kind PF_KIND_STRING): | header | bytes ... NUL |
// (length counts bytes, excluding the trailing NUL; allocated
// atomically so the GC never scans string payloads)

#include <stdio.h>
#include <string.h>
#include "../puffin.h"

pf pf_string_from_bytes(const char *bytes, int64_t n) {
  pf v = pf_alloc_atomic(PF_KIND_STRING, n, n + 1);
  memcpy((char *)(pf_heap_ptr(v) + 1), bytes, n);
  ((char *)(pf_heap_ptr(v) + 1))[n] = '\0';
  return v;
}

pf pf_string_length(pf v) {
  pf_expect_kind(v, PF_KIND_STRING);
  return PF_FIX(pf_len_of(v));
}

pf pf_string_append(pf a, pf b) {
  pf_expect_kind(a, PF_KIND_STRING);
  pf_expect_kind(b, PF_KIND_STRING);
  int64_t la = pf_len_of(a), lb = pf_len_of(b);
  pf v = pf_alloc_atomic(PF_KIND_STRING, la + lb, la + lb + 1);
  memcpy((char *)(pf_heap_ptr(v) + 1), pf_heap_ptr(a) + 1, la);
  memcpy((char *)(pf_heap_ptr(v) + 1) + la, pf_heap_ptr(b) + 1, lb);
  ((char *)(pf_heap_ptr(v) + 1))[la + lb] = '\0';
  return v;
}

static pf equal_string(pf a, pf b) {
  return PF_BOOL(pf_len_of(a) == pf_len_of(b) &&
                 memcmp(pf_heap_ptr(a) + 1, pf_heap_ptr(b) + 1, pf_len_of(a)) == 0);
}

pf pf_string_equal_huh(pf a, pf b) {
  pf_expect_kind(a, PF_KIND_STRING);
  pf_expect_kind(b, PF_KIND_STRING);
  return equal_string(a, b);
}

pf pf_string_huh(pf v) { return PF_BOOL(pf_is_kind(v, PF_KIND_STRING)); }

pf pf_symbol_to_string(pf v) {
  if ((v & PF_TAG_MASK) != PF_TAG_SYMBOL) pf_die_kind();
  const char *s = pf_symbol_name(v);
  return pf_string_from_bytes(s, strlen(s));
}

pf pf_string_to_symbol(pf v) {
  pf_expect_kind(v, PF_KIND_STRING);
  return (pf_intern_symbol((char *)(pf_heap_ptr(v) + 1)) << 3) | PF_TAG_SYMBOL;
}

static void display_string(pf v) {
  printf("%s", (char *)(pf_heap_ptr(v) + 1));
}

void pf_lib_strings_init(void) {
  static const pf_kind_desc desc = { "string", display_string, equal_string };
  pf_register_kind(PF_KIND_STRING, &desc);
}
