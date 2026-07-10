# Puffin web

The browser playground for Puffin — and it runs the **real toolchain**:
puffincc (the self-hosting compiler, `../puffincc-src/`, compiled to
bytecode) executes on a WebAssembly build of the bytecode VM
(`../src/vm/`), compiling **and typechecking** editor source in the
browser, then running the result on the same VM. There is no
JavaScript reimplementation of the language — one compiler, one
typechecker, one semantics, identical to `puffincc` on the command
line. (docs/WASM-VM.md is the design; the old hand-written JS
interpreter was retired at §7.4.)

## Artifacts

The engine loads three build artifacts from `public/` (gitignored),
produced by `../tools/gen-web-vm.sh` (needs wasi-sdk; the Makefile
prints install instructions if it's missing):

- `puffin-vm.wasm` — the VM, command model (whole-program runs and
  each per-eval compiler invocation)
- `puffin-vm-repl.wasm` — the VM, reactor model (one persistent
  instance per REPL session)
- `puffincc.pbc` — puffincc compiled to bytecode by `bin/puffin -c -t
  bytecode`

Regenerate after touching the VM, the runtime, or `puffincc-src/`.

## Run

```sh
npm install
../tools/gen-web-vm.sh   # build the engine artifacts into public/
npm run dev              # dev server (http://localhost:5173)
npm run build            # production build into dist/
npm run preview          # serve the production build
```

## Tests

```sh
npm test                 # all four suites below
node test-vm-corpus.mjs  # FULL golden corpus through the wasm engine:
                         # every src/test-programs/ program compiled by
                         # puffincc-on-the-VM, run per input, compared
                         # against src/goldens (300 checks)
node test-vm-repl.mjs    # REPL session semantics vs repl-golden.json
                         # (expectations frozen from the retired JS
                         # Session: persistence, redefinition, cross-
                         # eval mutual recursion + define-type, errors
                         # not killing the session, (read), …)
node test-vm-compile.mjs # compile-then-run smoke (incl. a typecheck
                         # rejection)
node test-vm-smoke.mjs   # precompiled fixtures through the WASI shim
```

## Notes

- **Run** compiles the editor source with puffincc-on-the-VM (two
  command-model instances sharing the shim's in-memory FS: the first
  writes `/out.pbc`, the second runs it). Typecheck/parse errors
  surface in the output pane; Cmd/Ctrl+Enter runs.
- **Modules** (docs/MODULES.md): "+ file" adds a module tab;
  `(require "lib1.puf")` from `main.puf` imports its provided names.
  The file map is materialized into the shim FS and resolved by
  puffincc's own module resolver.
- **The REPL** (bottom right) is a persistent VM session
  (docs/WASM-VM.md §5.2): each eval is compiled by `puffincc --repl`
  to a link-by-name unit and loaded into one reactor instance —
  defines persist, redefinition replaces, cross-eval mutual recursion
  and `define-type` work, until **Reset session**.
- The **stdin** box supplies whitespace-separated integers to
  `(read)`; when empty, the input stream is `0 1 2 …`.
- **Pipeline** mode is unchanged: it talks to the Racket trace server
  (`racket ../src/ir-server.rkt`) in dev, with a bundled sample trace
  as fallback.
- `src/engine/prim-names.js` (editor autocomplete) is generated from
  the stdlib manifest: `racket ../tools/gen-prim-names.rkt`.
