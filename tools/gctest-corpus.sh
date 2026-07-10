#!/bin/sh
# Differential oracle for the wasm GC seam (docs/WASM-VM.md §3.3):
# run the full bytecode corpus on BOTH VM builds — the native Boehm VM
# and puffin-vm-gctest (the same VM compiled through the wasm allocator
# seam, wasm/wasm-gc.c behind wasm/include/gc.h, no Boehm). Both must
# report 0 failures; any divergence is an allocator-seam bug. When the
# real §3.3 collector lands in wasm-gc.c, run this under
# PUFFIN_VM_GC_STRESS=1 as the CI gate.
set -e
cd "$(dirname "$0")/.."
make -C src/vm >/dev/null
make -C src/vm gctest >/dev/null
echo "== native Boehm VM =="
racket src/test.rkt -m bytecode
echo "== wasm GC seam (puffin-vm-gctest) =="
PUFFIN_VM_BIN=puffin-vm-gctest racket src/test.rkt -m bytecode
