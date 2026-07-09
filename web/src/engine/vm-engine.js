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

// puffincc, compiled to bytecode: the compiler that runs ON the VM to
// turn editor source into a runnable unit (docs/WASM-VM.md §5.1).
let puffinccBytes = null;
async function puffinccPbc() {
  if (puffinccBytes) return puffinccBytes;
  let resp;
  try { resp = await fetch(PUFFINCC_PBC_URL); }
  catch (e) { throw new EngineNotReady(`cannot fetch ${PUFFINCC_PBC_URL}: ${e.message}`); }
  if (!resp.ok) {
    throw new EngineNotReady(
      `${PUFFINCC_PBC_URL} not found (HTTP ${resp.status}). Generate it: \`tools/gen-web-vm.sh\`.`);
  }
  puffinccBytes = new Uint8Array(await resp.arrayBuffer());
  return puffinccBytes;
}

// Instantiate the VM once against an in-memory FS and run to _start's
// completion. Returns the shim (its .fs holds anything written) plus
// the exit disposition.
async function execUnit({ files, args, stdin, onOutput }) {
  const module = await vmModule();
  const shim = new WasiShim({ stdin, onOutput: onOutput || (() => {}), files, args });
  const instance = await WebAssembly.instantiate(module, shim.imports());
  shim.bindMemory(instance.exports.memory);
  let aborted = false, code = 0;
  try { instance.exports._start(); }
  catch (e) {
    if (e instanceof PuffinAbort) { aborted = true; code = e.code; }
    else throw e;
  }
  return { shim, aborted, code };
}

// ---- the engine interface (§5.1) -------------------------------

// run(source, opts): compile source to bytecode with puffincc-on-the-VM
// (typechecking it), then run the resulting unit -- the endpoint that
// replaces the JS interpreter. Two command-model instances share the
// shim's JS-side FS: no reactor needed (proven by web/test-vm-compile.mjs).
//   opts: { input, stdin, onOutput, files, entry }
export async function run(source, opts = {}) {
  const { input, stdin, onOutput, files, entry } = opts;
  const out = onOutput || (() => {});
  const cc = await puffinccPbc();
  const enc = new TextEncoder();

  // FS: the compiler unit + the program's module file(s).
  const fs = { '/puffincc.pbc': cc };
  let entryPath;
  if (files) {
    for (const [name, src] of Object.entries(files)) fs['/' + name] = enc.encode(src);
    entryPath = '/' + (entry || 'main.puf');
  } else {
    fs['/main.puf'] = enc.encode(source);
    entryPath = '/main.puf';
  }

  // 1. compile + typecheck on the VM. Diagnostics (typecheck/parse
  //    errors) are captured, not streamed as program output, matching
  //    the JS interpreter (errors are returned, not printed).
  let diag = '';
  const compile = await execUnit({
    files: fs,
    args: ['/puffincc.pbc', entryPath, '-t', 'bytecode', '-o', '/out.pbc'],
    stdin: new Uint8Array(0),
    onOutput: (s) => { diag += s; },
  });
  const outPbc = compile.shim.fs.get('/out.pbc');
  if (!outPbc || outPbc.length === 0) {
    return { ok: false, error: diag.trim() || `compiler exited with code ${compile.code}` };
  }

  // 2. run the compiled unit with the user's stdin, streaming output.
  return runUnit(outPbc, { input, stdin, onOutput: out });
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
