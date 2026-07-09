#!/bin/sh
# Generate the browser VM artifacts into web/public/ (served by vite,
# copied into the build). docs/WASM-VM.md §5.1:
#   puffin-vm.wasm  -- the wasm bytecode VM (wasi-sdk; from src/vm)
#   puffincc.pbc    -- the self-hosted compiler, compiled to bytecode,
#                      which runs ON the VM to compile the editor's
#                      source (and typecheck it) in the browser.
# Both are build artifacts (gitignored); regenerate after touching the
# VM, the runtime, or puffincc-src.
set -e
cd "$(dirname "$0")/.."
make -C src/vm wasm
mkdir -p web/public
cp bin/puffin-vm.wasm web/public/puffin-vm.wasm
bin/puffin -c -t bytecode -o web/public/puffincc.pbc puffincc-src/main.puf
echo "wrote web/public/puffin-vm.wasm ($(wc -c < web/public/puffin-vm.wasm) bytes)"
echo "wrote web/public/puffincc.pbc ($(wc -c < web/public/puffincc.pbc) bytes)"
