// vm-engine.js -- the bytecode-VM implementation of the engine
// interface (docs/WASM-VM.md §5.1). It runs the REAL compiler's
// output on puffin-vm.wasm instead of the hand-written JS interpreter.
//
// STATUS: scaffold, GATED. Nothing here can run until two artifacts
// exist, both produced only once wasi-sdk is installed and the wasm
// build is turned on (src/vm/Makefile `wasm`):
//   - puffin-vm.wasm   -- the VM (src/vm/*.c compiled for wasm32-wasi)
//   - puffincc.pbc     -- puffincc compiled to bytecode (for run()/Session)
//
// What IS implemented and ready to run the instant puffin-vm.wasm
// exists: runUnit(), which loads a precompiled .pbc and runs it on the
// VM through the WASI shim. That is exactly the browser smoke test the
// .pbc fixtures (web/src/engine/fixtures/) are for -- it exercises the
// whole wasm + shim path without needing puffincc.pbc.
//
// The full engine-interface run()/Session -- compiling user source to
// bytecode *in the browser* via puffincc-on-the-VM (§5.1/§5.2) --
// additionally needs the VM built as a wasm "reactor" that exports
// load/run entry points (so compile-then-run is two calls into one
// heap) plus the REPL-mode compilation flag (§4). Those are the M5
// boundary; until then run()/Session throw EngineNotReady so the
// façade cleanly falls back to the JS interpreter.

import { WasiShim, PuffinAbort } from './wasi-shim.js';

export class EngineNotReady extends Error {
  constructor(msg) { super(msg); this.name = 'EngineNotReady'; }
}

// Where the built artifacts will live once the wasm build is on.
// (vite serves web/public/ at the root; the Makefile's install step
// will drop puffin-vm.wasm + puffincc.pbc there.)
const VM_WASM_URL = '/puffin-vm.wasm';
const PUFFINCC_PBC_URL = '/puffincc.pbc';

let compiledModule = null; // cached WebAssembly.Module

// Fetch + compile the VM module once. Throws EngineNotReady with an
// actionable message if the asset is absent (the gated state).
async function vmModule() {
  if (compiledModule) return compiledModule;
  let resp;
  try {
    resp = await fetch(VM_WASM_URL);
  } catch (e) {
    throw new EngineNotReady(`cannot fetch ${VM_WASM_URL}: ${e.message}`);
  }
  if (!resp.ok) {
    throw new EngineNotReady(
      `${VM_WASM_URL} not found (HTTP ${resp.status}). Build it: install wasi-sdk, then \`make -C src/vm wasm\` and copy bin/puffin-vm.wasm to web/public/.`);
  }
  compiledModule = await WebAssembly.compileStreaming(resp);
  return compiledModule;
}

// Has the VM asset been built and served? Lets the UI decide whether
// to offer the ?engine=vm toggle.
export async function vmAvailable() {
  try { await vmModule(); return true; } catch { return false; }
}

function defaultInputBytes(input) {
  // The app passes input as number[]; the runtime's scanf-based read
  // wants whitespace-separated text (§3.5). An empty box -> 0..99,
  // matching the JS interpreter's defaultInput().
  const nums = input && input.length ? input : Array.from({ length: 100 }, (_, i) => i);
  return new TextEncoder().encode(nums.join(' ') + '\n');
}

// Run a precompiled unit (.pbc bytes) on the VM. This is the runnable
// core: it needs only puffin-vm.wasm (a WASI *command* module, which
// is what src/vm/Makefile builds today).
//
//   runUnit(pbcBytes, { input, stdin, onOutput, files }) -> { ok, value, error }
export async function runUnit(pbcBytes, { input, stdin, onOutput, files } = {}) {
  const out = onOutput || (() => {});
  const module = await vmModule();
  const shim = new WasiShim({
    stdin: stdin != null
      ? (typeof stdin === 'string' ? new TextEncoder().encode(stdin) : stdin)
      : defaultInputBytes(input),
    onOutput: out,
    files: { ...(files || {}), '/prog.pbc': pbcBytes },
    args: ['/prog.pbc'],
  });
  const instance = await WebAssembly.instantiate(module, shim.imports());
  shim.bindMemory(instance.exports.memory);
  try {
    // command module: _start runs main(argv) -> loads /prog.pbc, runs it.
    instance.exports._start();
    return { ok: true, value: null };
  } catch (e) {
    if (e instanceof PuffinAbort) {
      // code 0 = normal proc_exit; nonzero = (error v)/pf_fatal, whose
      // message already streamed through onOutput (golden parity §3.4).
      return e.code === 0 ? { ok: true, value: null } : { ok: false, error: `program exited with code ${e.code}` };
    }
    return { ok: false, error: `internal VM error: ${e && e.message}` };
  }
}

// ---- the engine interface (§5.1) -------------------------------

// run(source, opts): compile source to bytecode on the VM, then run
// it -- the endpoint that retires the JS interpreter. Gated on the
// reactor-style VM + puffincc.pbc (M5).
export async function run(_source, _opts = {}) {
  await vmModule(); // surface the "wasm missing" gate first
  throw new EngineNotReady(
    'VM run(): in-browser compilation needs the reactor-style VM exports and puffincc.pbc (docs/WASM-VM.md §5.1, milestone M5). ' +
    'Precompiled units run today via runUnit(); the façade falls back to the JS interpreter for source.');
}

// Session: REPL over link-by-name units (§5.2). Gated on REPL-mode
// compilation + reactor exports (M5).
export class Session {
  constructor() {
    throw new EngineNotReady(
      'VM Session: the REPL needs link-by-name units + REPL-mode compilation (docs/WASM-VM.md §5.2, milestone M5).');
  }
}

export { PUFFINCC_PBC_URL };
