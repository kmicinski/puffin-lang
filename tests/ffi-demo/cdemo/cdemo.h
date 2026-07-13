// the C header for cdemo.c -- the #:include cross-check target
// (docs/FFI.md §9.3): puffincc holds every foreign declaration
// against these prototypes with clang -fsyntax-only.
#ifndef CDEMO_H
#define CDEMO_H
#include <stdint.h>
#include <stdbool.h>

int64_t cdemo_add(int64_t a, int64_t b);
int64_t cdemo_big(void);
int32_t cdemo_inc32(int32_t v);
uint8_t cdemo_low8(int64_t v);
int64_t cdemo_double8(int8_t v);
bool cdemo_even(int64_t v);
int64_t cdemo_sum6(int64_t a, int64_t b, int64_t c, int64_t d, int64_t e, int64_t f);
int64_t cdemo_strlen(const char *s);
char *cdemo_greet(const char *name);
void cdemo_free_str(char *p);
const char *cdemo_find(const char *hay, const char *needle);
const char *cdemo_null_str(void);

typedef struct CBox CBox;
CBox *cdemo_box_new(int64_t start);
int64_t cdemo_box_next(CBox *b);
void cdemo_box_free(CBox *b);
CBox *cdemo_box_maybe(int64_t ok);
CBox *cdemo_box_null(void);
#endif
