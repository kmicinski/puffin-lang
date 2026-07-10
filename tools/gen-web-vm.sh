#!/bin/sh
# Generate the browser VM artifacts into web/public/ (served by vite,
# copied into the build). docs/WASM-VM.md §5.1/§5.2:
#   puffin-vm.wasm       -- the wasm bytecode VM, command model (one
#                           run per instance; from src/vm)
#   puffin-vm-repl.wasm  -- the VM as a wasm reactor: one persistent
#                           instance per REPL session
#   puffincc.pbc         -- the self-hosted compiler, compiled to
#                           bytecode, which runs ON the VM to compile
#                           the editor's source (and typecheck it) in
#                           the browser.
# Both are build artifacts (gitignored); regenerate after touching the
# VM, the runtime, or puffincc-src.
set -e
cd "$(dirname "$0")/.."
make -C src/vm wasm
make -C src/vm wasm-repl
mkdir -p web/public
cp bin/puffin-vm.wasm web/public/puffin-vm.wasm
cp bin/puffin-vm-repl.wasm web/public/puffin-vm-repl.wasm
bin/puffin -c -t bytecode -o web/public/puffincc.pbc puffincc-src/main.puf
echo "wrote web/public/puffin-vm.wasm ($(wc -c < web/public/puffin-vm.wasm) bytes)"
echo "wrote web/public/puffin-vm-repl.wasm ($(wc -c < web/public/puffin-vm-repl.wasm) bytes)"
echo "wrote web/public/puffincc.pbc ($(wc -c < web/public/puffincc.pbc) bytes)"
