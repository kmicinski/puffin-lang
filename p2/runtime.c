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
