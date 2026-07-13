# tests/ffi-demo -- build the FFI demo libraries (docs/FFI.md §8.4).
#
#   make -C tests/ffi-demo            cdemo (C, fat arm64+x86_64)
#   make -C tests/ffi-demo pfregex    the Rust guest (needs cargo)
#
# src/test-ffi.rkt builds cdemo itself before running; the corpus
# never depends on these artifacts (they are gitignored).

CC := clang

all: cdemo/libpfcdemo.dylib

# FAT: the Rosetta x86-64 route dlopens the same file
cdemo/libpfcdemo.dylib: cdemo/cdemo.c
	$(CC) -O2 -Wall -Wextra -arch arm64 -arch x86_64 -dynamiclib -o $@ $<

pfregex:
	cd pfregex && cargo build --release

clean:
	rm -f cdemo/libpfcdemo.dylib
	rm -rf pfregex/target

.PHONY: all clean pfregex
