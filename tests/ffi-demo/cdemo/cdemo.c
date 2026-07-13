// tests/ffi-demo/cdemo -- the FFI demo library (docs/FFI.md §8.4):
// one export per §4 table row, plus every error path the test matrix
// (src/test-ffi.rkt) pins. Built FAT (arm64 + x86_64) by the
// Makefile so the Rosetta x86-64 route can dlopen it too.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ---- Int / widths / Bool ------------------------------------------

int64_t cdemo_add(int64_t a, int64_t b) { return a + b; }

// returns INT64_MAX: must trip the 61-bit boundary loudly (§4.1)
int64_t cdemo_big(void) { return 9223372036854775807LL; }

// callee returning int32_t leaves the register's high bits
// unspecified -- the width-directed mask on our side handles it
int32_t cdemo_inc32(int32_t v) { return v + 1; }
uint8_t cdemo_low8(int64_t v) { return (uint8_t)v; }
int64_t cdemo_double8(int8_t v) { return (int64_t)v * 2; }

_Bool cdemo_even(int64_t v) { return (v & 1) == 0; }

// six integer-class arguments: the packed #%ffi-call6 route
int64_t cdemo_sum6(int64_t a, int64_t b, int64_t c,
                   int64_t d, int64_t e, int64_t f) {
  return a + b + c + d + e + f;
}

// ---- Str: borrow out, copy in, gift, nullable ----------------------

int64_t cdemo_strlen(const char *s) { return (int64_t)strlen(s); }

// malloc'd result: ownership transfers via #:gift "cdemo_free_str"
char *cdemo_greet(const char *name) {
  char *p = (char *)malloc(strlen(name) + 8);
  strcpy(p, "hello ");
  strcat(p, name);
  return p;
}
void cdemo_free_str(char *p) { free(p); }

// NULL or a static string: the (Nullable Str) shape
const char *cdemo_find(const char *hay, const char *needle) {
  return strstr(hay, needle);
}

// always NULL: a Str result without Nullable is a blamed error
const char *cdemo_null_str(void) { return 0; }

// ---- foreign handles (kind 19): lifecycle + error paths ------------

typedef struct { int64_t count; } CBox;

CBox *cdemo_box_new(int64_t start) {
  CBox *b = (CBox *)malloc(sizeof *b);
  b->count = start;
  return b;
}
int64_t cdemo_box_next(CBox *b) { return b->count++; }
void cdemo_box_free(CBox *b) { free(b); }

// NULL or a fresh box: the (Nullable CBox) shape
CBox *cdemo_box_maybe(int64_t ok) { return ok ? cdemo_box_new(7) : 0; }

// always NULL: a handle result without Nullable is a blamed error
CBox *cdemo_box_null(void) { return 0; }
