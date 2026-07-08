// engine/index.js -- the ONE engine interface App and the workers
// import (docs/WASM-VM.md §5.1, migration step §7.1).
//
// Today it is a thin façade over the hand-written JS interpreter
// (web/src/puffin/), which stays the DEFAULT and the only implementation
// wired for source `run`/`Session`. This is deliberately a pure
// refactor: every name below is re-exported straight from
// web/src/puffin/index.js, so repointing a consumer from
// '../puffin/index.js' to '../engine/index.js' changes nothing
// observable (the gate for §7.1 is `node web/test-corpus.mjs` staying
// green).
//
// Beside it sits the bytecode-VM engine (vm-engine.js), added but not
// yet default. When milestone M5 lands (VM reactor exports +
// puffincc.pbc + REPL-mode compilation), flipping the default is:
//   1. build the wasm (install wasi-sdk; `make -C src/vm wasm`),
//   2. serve puffin-vm.wasm + puffincc.pbc from web/public/,
//   3. make the workers await the async VM run()/Session and select
//      the engine via engineName() below.
// The JS interpreter then stays selectable for one release as the
// escape hatch (§7.3) before web/src/puffin/ is deleted (§7.4).

// ---- the default (JS interpreter) surface, re-exported verbatim ----
export {
  run,
  Session,
  render,
  defaultInput,
  surfacePrimNames,
  resolveModules,
  moduleForms,
  ModuleError,
  ReadError,
  PuffinError,
} from '../puffin/index.js';

// ---- the VM engine, available but gated (see vm-engine.js) ----
export {
  runUnit as vmRunUnit,
  vmAvailable,
  EngineNotReady,
} from './vm-engine.js';
export { PuffinAbort } from './wasi-shim.js';

// Which engine should this session use? 'js' (default) or 'vm'.
// Sources, in order: an explicit override, the ?engine= query param,
// then the default. Kept trivial now; the settings toggle (§7.2)
// writes the override.
let engineOverride = null;
export function setEngine(name) { engineOverride = name; }
export function engineName() {
  if (engineOverride) return engineOverride;
  if (typeof location !== 'undefined' && location.search) {
    const m = /[?&]engine=(js|vm)\b/.exec(location.search);
    if (m) return m[1];
  }
  return 'js';
}
