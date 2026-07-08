# Puffin bytecode VM (docs/WASM-VM.md).
#
#   make -C src/vm            -> bin/puffin-vm        (native, M2)
#   make -C src/vm wasm       -> bin/puffin-vm.wasm   (wasi-sdk, M4)
#
# NATIVE build: the VM hosts the existing runtime -- it links against
# libpuffin.a (core + lib/* + vendored Boehm), the same archive native
# programs link. This is the primary development target.
#
# WASM build: the SAME C sources (core.c, lib/*.c, puffin-vm.c) compile
# for wasm32-wasi UNCHANGED. Only three things differ, and each is a
# separate file, not an #ifdef in the runtime (docs/WASM-VM.md §3.2):
#   - the allocator: wasm/wasm-gc.c replaces Boehm behind the
#     GC_MALLOC/GC_MALLOC_ATOMIC/GC_add_roots ABI, resolved through
#     wasm/include/gc.h instead of vendor/gc/include/gc.h;
#   - the error boundary: wasm/wasm-host.c intercepts exit() via
#     -Wl,--wrap=exit and calls the host_abort import (§3.4);
#   - the host: stdin/stdout/files come from wasi-libc talking to the
#     JS shim (web/src/engine/wasi-shim.js, §3.5).
#
# The wasm target is GATED on installing wasi-sdk -- it is not present
# in this environment. `make wasm` prints the install command if the
# SDK is missing. Everything is wired so that once the SDK is at
# $(WASI_SDK), `make -C src/vm wasm` produces bin/puffin-vm.wasm.

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

# ---------------------------------------------------------------
# WASM build (docs/WASM-VM.md §3, milestone M4). Gated on wasi-sdk.
# ---------------------------------------------------------------

# Install location of wasi-sdk (override on the command line if you
# put it elsewhere: `make wasm WASI_SDK=/path/to/wasi-sdk`).
WASI_SDK    ?= /opt/wasi-sdk
WASM_CC     := $(WASI_SDK)/bin/clang
WASM_SYSROOT := $(WASI_SDK)/share/wasi-sysroot
WASM_BIN    := ../../bin/puffin-vm.wasm

# exec-model: `command` (has _start, runs main from argv) is right for
# the native-parity Node smoke test at M2/M4. The browser engine wants
# `reactor` + explicit --export=s once §5's boundary lands; flip with
# `make wasm WASM_EXEC_MODEL=reactor`.
WASM_EXEC_MODEL ?= command

# The runtime + VM sources compiled for wasm. Note: NO Boehm archive;
# wasm/wasm-gc.c provides the allocation ABI, and wasm/include is put
# FIRST on the include path so core.c's `#include <gc.h>` resolves to
# the shim, not the vendored Boehm header.
WASM_SRCS := \
	puffin-vm.c \
	wasm/wasm-gc.c \
	wasm/wasm-host.c \
	../runtime/core.c \
	../runtime/lib/pairs.c ../runtime/lib/vectors.c ../runtime/lib/strings.c \
	../runtime/lib/table.c ../runtime/lib/hashes.c ../runtime/lib/sets.c \
	../runtime/lib/hamt.c ../runtime/lib/arith.c ../runtime/lib/predicates.c \
	../runtime/lib/io.c ../runtime/lib/stdlib_init.c

WASM_CFLAGS := -Wall -Wextra -O2 \
	--target=wasm32-wasi --sysroot=$(WASM_SYSROOT) \
	-mexec-model=$(WASM_EXEC_MODEL) \
	-I wasm/include -I ../runtime

# --wrap=exit routes the runtime's exit() to __wrap_exit -> host_abort
# (§3.4). --initial-memory/--max-memory keep the heap under the wasm32
# ceiling; the frame stack + heap share the 4 GB space (§9). Adjust as
# the collector's budget is tuned.
WASM_LDFLAGS := \
	-Wl,--wrap=exit \
	-Wl,--initial-memory=16777216 \
	-Wl,--max-memory=1073741824 \
	-Wl,--stack-first

wasm: vm-prims.inc $(WASM_CC)-check
	$(WASM_CC) $(WASM_CFLAGS) $(WASM_LDFLAGS) $(WASM_SRCS) -o $(WASM_BIN)
	@echo "built $(WASM_BIN)"
	@ls -la $(WASM_BIN)

# Fail with the exact install instructions if the SDK is absent,
# rather than a confusing "clang: not found".
$(WASM_CC)-check:
	@test -x "$(WASM_CC)" || { \
	  echo ""; \
	  echo "wasi-sdk not found at $(WASI_SDK) (expected clang at $(WASM_CC))."; \
	  echo ""; \
	  echo "Install it (macOS arm64 / Apple Silicon):"; \
	  echo "  V=33 ; curl -L -o /tmp/wasi-sdk.tar.gz \\"; \
	  echo "    https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-\$$V/wasi-sdk-\$$V.0-arm64-macos.tar.gz"; \
	  echo "  sudo mkdir -p /opt && sudo tar xf /tmp/wasi-sdk.tar.gz -C /opt"; \
	  echo "  sudo mv /opt/wasi-sdk-\$$V.0-arm64-macos /opt/wasi-sdk"; \
	  echo ""; \
	  echo "Then re-run: make -C src/vm wasm"; \
	  echo ""; \
	  exit 1; \
	}

clean:
	rm -f $(BIN) $(WASM_BIN)

.PHONY: all clean wasm $(WASM_CC)-check
