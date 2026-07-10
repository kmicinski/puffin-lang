// engine/index.js -- THE engine interface App and the workers import
// (docs/WASM-VM.md §5).
//
// There is exactly one engine: the real toolchain. puffincc (the
// self-hosting compiler, itself compiled to bytecode) runs ON the wasm
// VM to compile + typecheck editor source, and the VM runs the result;
// the REPL is a persistent reactor session loading link-by-name units
// (§5.2). The hand-written JS interpreter this façade once fronted
// (web/src/puffin/) is deleted (§7.4): one compiler, one typechecker,
// one semantics — browser, native, and REPL alike. Racket src/ remains
// the offline consistency oracle (diff-ir + goldens), not a runtime.
//
// Artifacts (vite serves web/public/): puffin-vm.wasm,
// puffin-vm-repl.wasm, puffincc.pbc — built by tools/gen-web-vm.sh.

import { run as vmRun, Session as VmSession } from './vm-engine.js';

export {
  runUnit as vmRunUnit,
  vmAvailable,
  preloadArtifacts,
  EngineNotReady,
  Session,
} from './vm-engine.js';
export { PuffinAbort } from './wasi-shim.js';

// The editor's builtin-name list derives from the stdlib manifest
// (generated: tools/gen-prim-names.rkt), not from an interpreter.
export { surfacePrimNames } from './prim-names.js';

// run(source, opts): compile + typecheck + run through the real
// compiler. Async: the workers await it.
export async function run(source, opts = {}) {
  const r = await vmRun(source, opts);
  // puffincc's diagnostics carry the "error: " prefix and the app adds
  // its own when displaying — return bare messages.
  if (!r.ok && r.error) r.error = r.error.replace(/^error:\s*/, '');
  return r;
}

// createSession(opts): a persistent VM REPL session (async eval).
export function createSession(opts = {}) {
  return new VmSession(opts);
}

// Kept for the UI badge; the answer no longer varies.
export function engineName() { return 'vm'; }
