#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <inttypes.h>

int64_t read_int64(void) {
  int64_t value;
  if (scanf("%" SCNd64, &value) != 1) {
    /* handle input error as needed */
    printf("Error: expected an integer. Exiting.");
    exit(1);
  }
  return value;
}

void print_int64(int64_t n) {
    printf("%" PRId64 "\n", n);
}

//
// (Heap)-allocated data
// 

// We provide a vector: TinyVecPacked
//
//  | len (8 bytes) | data[0] | data[1] | ... | data[9] |
//     ^ v             ^ v->data
//
typedef struct {
    int64_t len;
    int64_t data[];
} TinyVecPacked;

// Simplest-possible version: *don't* do garbage collection.
// Use libc's `malloc` to grab bytes from the heap.
TinyVecPacked* make_vector(int64_t len) {
  int64_t init_val = 0;
  TinyVecPacked* v = (TinyVecPacked*)malloc(sizeof(TinyVecPacked) + len * sizeof(int64_t));
  v->len = len;
  for (int64_t i = 0; i < len; i++) {
    v->data[i] = init_val;
  }
  return v;
}

// 
// Advice: you should not literally call these functions: function
// calls are relatively heavyweight. I include them to give a
// conceptual idea of how vectors work.
//
// Instead of emitting calls, you should emit the assembly
// equivalents.
static int64_t vector_length(TinyVecPacked *vec) {
  return vec->len;
}

static int64_t unsafe_vector_ref(TinyVecPacked *vec, int64_t idx) {
  return vec->data[idx];
}

static void unsafe_vector_set(TinyVecPacked *vec, int64_t idx, int64_t data) {
  vec->data[idx] = data;
}
