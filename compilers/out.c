#include "runtime.h"

int main(int argc, char **argv) {
    print_int64(((5 + 3) + (- (2 + read_int64()))));
}

