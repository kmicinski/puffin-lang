#!/bin/sh
# Differential oracle for the wasm GC seam (docs/WASM-VM.md §3.3):
# run the full bytecode corpus on the native Boehm VM, on
# puffin-vm-gctest (the same VM compiled through the wasm allocator
# seam: the §3.3 mark-sweep collector in wasm/wasm-gc.c behind
# wasm/include/gc.h, no Boehm), and on puffin-vm-gctest under
# PUFFIN_VM_GC_STRESS=1 -- which collects at EVERY safepoint and
# poisons freed blocks (0xAB), so a missed root or a premature free
# fails loudly instead of silently. All three legs must report 0
# failures; any divergence is a collector bug. The stress leg is the
# CI gate the §3.3 design demands.
set -e
cd "$(dirname "$0")/.."
make -C src/vm >/dev/null
make -C src/vm gctest >/dev/null
echo "== native Boehm VM =="
racket src/test.rkt -m bytecode
echo "== wasm GC seam (puffin-vm-gctest) =="
PUFFIN_VM_BIN=puffin-vm-gctest racket src/test.rkt -m bytecode
echo "== wasm GC seam under stress (collect at every safepoint) =="
PUFFIN_VM_GC_STRESS=1 PUFFIN_VM_BIN=puffin-vm-gctest racket src/test.rkt -m bytecode
