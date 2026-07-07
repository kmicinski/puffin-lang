# Puffin bytecode VM (native build; docs/WASM-VM.md M2).
#
#   make -C src/vm            -> bin/puffin-vm
#
# The VM hosts the existing runtime: it links against libpuffin.a
# (core + lib/* + vendored Boehm), the same archive native programs
# link. The wasm build (wasi-sdk) is M4 and is not wired here.

CC     := clang
CFLAGS := -Wall -Wextra -O2
BIN    := ../../bin/puffin-vm
RUNTIME := ../runtime/libpuffin.a

all: $(BIN)

$(BIN): puffin-vm.c vm-prims.inc ../runtime/puffin.h $(RUNTIME)
	$(CC) $(CFLAGS) puffin-vm.c $(RUNTIME) -o $(BIN)

# the prim table derives from the stdlib manifest
vm-prims.inc: ../stdlib.rkt ../gen-vm-prims.rkt
	racket ../gen-vm-prims.rkt > vm-prims.inc

clean:
	rm -f $(BIN)

.PHONY: all clean
