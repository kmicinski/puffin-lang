// vm-engine.js -- the bytecode-VM implementation of the engine
// interface (docs/WASM-VM.md §5.1/§5.2). It runs the REAL compiler's
// output on the wasm VM instead of the hand-written JS interpreter.
//
// Three artifacts (built by tools/gen-web-vm.sh into web/public/ and
// bin/):
//   - puffin-vm.wasm      -- the VM, command model: one _start per
//                            whole-program run (run(), runUnit(), and
//                            each per-eval compiler invocation)
//   - puffin-vm-repl.wasm -- the VM, reactor model: ONE persistent
//                            instance per REPL Session (make -C
//                            src/vm wasm-repl)
//   - puffincc.pbc        -- puffincc compiled to bytecode; runs ON
//                            the VM to compile editor source
//
// run(): compile + typecheck user source with puffincc-on-the-VM,
// then run the produced unit -- two command instances sharing the
// shim's JS-side FS. Session: a persistent reactor instance loading
// one v2 link-by-name unit per eval (docs/WASM-VM.md §5.2); defines
// persist as named session cells, redefinition replaces, results
// arrive via the puffin.repl_result import. Missing artifacts throw
// EngineNotReady so the façade cleanly falls back to the JS engine.

import { WasiShim, PuffinAbort } from './wasi-shim.js';

export class EngineNotReady extends Error {
  constructor(msg) { super(msg); this.name = 'EngineNotReady'; }
}

// Where the built artifacts will live once the wasm build is on.
// (vite serves web/public/ at the root; the Makefile's install step
// will drop puffin-vm.wasm + puffincc.pbc there.)
const VM_WASM_URL = '/puffin-vm.wasm';
const VM_REPL_WASM_URL = '/puffin-vm-repl.wasm';
const PUFFINCC_PBC_URL = '/puffincc.pbc';

let compiledModule = null;     // cached WebAssembly.Module (command)
let compiledReplModule = null; // cached WebAssembly.Module (reactor)

// Test seam: node harnesses (web/test-vm-*.mjs) have no fetch of
// vite-served paths; they hand the artifact bytes in directly.
export function preloadArtifacts({ vmWasm, vmReplWasm, puffincc } = {}) {
  if (vmWasm) compiledModule = new WebAssembly.Module(vmWasm);
  if (vmReplWasm) compiledReplModule = new WebAssembly.Module(vmReplWasm);
  if (puffincc) puffinccBytes = puffincc;
}

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

// The reactor build (persistent REPL sessions; docs/WASM-VM.md §5.2).
async function vmReplModule() {
  if (compiledReplModule) return compiledReplModule;
  let resp;
  try {
    resp = await fetch(VM_REPL_WASM_URL);
  } catch (e) {
    throw new EngineNotReady(`cannot fetch ${VM_REPL_WASM_URL}: ${e.message}`);
  }
  if (!resp.ok) {
    throw new EngineNotReady(
      `${VM_REPL_WASM_URL} not found (HTTP ${resp.status}). Build it: \`make -C src/vm wasm-repl\` and copy bin/puffin-vm-repl.wasm to web/public/.`);
  }
  compiledReplModule = await WebAssembly.compileStreaming(resp);
  return compiledReplModule;
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

// ---- the REPL Session (§5.2, milestone M5) ----------------------
//
// A persistent session = ONE reactor VM instance (one heap, one
// symbol table, one session cell table) loading MANY v2 units:
//
//   boot:  compile the embedded prelude to a REPL unit with
//          puffincc-on-the-VM (command instance; cached), instantiate
//          puffin-vm-repl.wasm, pvm_boot, load+run the prelude unit;
//   eval:  compile the eval's forms with `puffincc --repl` (a fresh
//          command instance sharing nothing but bytes), then
//          pvm_load_run the v2 unit in the session instance --
//          defines persist as named cells, redefinition replaces,
//          cross-eval calls resolve at call time, results arrive via
//          the puffin.repl_result import (one per non-void form);
//   errors: (error v) prints through onOutput and exits 1 -- the
//          eval still reports ok (JS Session parity: PuffinHalt keeps
//          results-so-far); pf_fatal exits 255 with the message on
//          stderr -> { ok: false, error }. Either way the abort only
//          unwinds wasm frames: the engine restores __stack_pointer
//          and the session (heap, cells, symbols) lives on.

// the prelude REPL unit, compiled once per page (pure function of
// puffincc.pbc)
let preludeReplBytes = null;
async function preludeReplPbc() {
  if (preludeReplBytes) return preludeReplBytes;
  const cc = await puffinccPbc();
  let diag = '';
  const r = await execUnit({
    files: { '/puffincc.pbc': cc },
    args: ['/puffincc.pbc', '--repl-prelude', '-o', '/prelude.pbc'],
    stdin: new Uint8Array(0),
    onOutput: (s) => { diag += s; },
  });
  const out = r.shim.fs.get('/prelude.pbc');
  if (!out || out.length === 0) {
    throw new EngineNotReady(`REPL prelude compile failed: ${diag.trim() || `exit ${r.code}`}`);
  }
  preludeReplBytes = out;
  return out;
}

export class Session {
  // opts: { input: number[], stdin: string|Uint8Array, onOutput }
  constructor({ input, stdin, onOutput } = {}) {
    this.onOutput = onOutput || (() => {});
    this._stdin = stdin != null
      ? (typeof stdin === 'string' ? new TextEncoder().encode(stdin) : stdin)
      : defaultInputBytes(input);
    this._results = null; // the current eval's results sink
    this._errText = '';
    this._ready = this._boot();
    this._ready.catch(() => {}); // surfaced per-eval; avoid unhandled rejection
  }

  async _boot() {
    const prelude = await preludeReplPbc();
    const module = await vmReplModule();
    this._shim = new WasiShim({
      stdin: this._stdin,
      onOutput: (s) => this.onOutput(s),
      onStderr: (s) => { this._errText += s; },
      onReplResult: (s) => { if (this._results) this._results.push(s); },
      files: {},
      args: ['repl'],
    });
    this._instance = await WebAssembly.instantiate(module, this._shim.imports());
    const ex = this._instance.exports;
    this._shim.bindMemory(ex.memory);
    ex._initialize();
    ex.pvm_boot();
    // the shadow-stack pointer at rest: restored before every eval,
    // because an abort unwinds the wasm frames without unwinding it
    this._sp0 = ex.__stack_pointer.value;
    const r = this._loadRun(prelude);
    if (r.code !== 0) {
      throw new EngineNotReady(`REPL prelude unit failed: ${this._errText.trim() || `code ${r.code}`}`);
    }
  }

  // Load + run one unit in the persistent instance. Returns { code }:
  // 0 = clean, 1 = (error v) (already printed), 255 = pf_fatal.
  _loadRun(bytes) {
    const ex = this._instance.exports;
    ex.__stack_pointer.value = this._sp0;
    const ptr = ex.pvm_alloc(bytes.length);
    new Uint8Array(ex.memory.buffer, ptr, bytes.length).set(bytes);
    try {
      ex.pvm_load_run(ptr, bytes.length);
      return { code: 0 };
    } catch (e) {
      if (e instanceof PuffinAbort) return { code: e.code };
      throw e;
    }
  }

  // eval(text) -> { ok, results: string[], error? }  (async; the JS
  // Session's surface, awaited by repl-worker.js)
  async eval(code) {
    try {
      await this._ready;
    } catch (e) {
      return { ok: false, error: String((e && e.message) || e), results: [] };
    }
    // 1. compile this eval's forms to a v2 unit (fresh compiler
    //    instance; diagnostics are returned, not streamed)
    const cc = await puffinccPbc();
    let diag = '';
    const compile = await execUnit({
      files: { '/puffincc.pbc': cc, '/eval.puf': new TextEncoder().encode(code) },
      args: ['/puffincc.pbc', '--repl', '/eval.puf', '-o', '/out.pbc'],
      stdin: new Uint8Array(0),
      onOutput: (s) => { diag += s; },
    });
    const unit = compile.shim.fs.get('/out.pbc');
    if (!unit || unit.length === 0) {
      return { ok: false, error: diag.trim() || `puffincc exited with code ${compile.code}`, results: [] };
    }
    // 2. run it in the session
    this._results = [];
    this._errText = '';
    const r = this._loadRun(unit);
    const results = this._results;
    this._results = null;
    // (error v) = exit 1: printed through onOutput already; the eval
    // itself reports ok with results-so-far (JS Session parity).
    if (r.code === 0 || r.code === 1) return { ok: true, results };
    return { ok: false, error: this._errText.trim() || `program exited with code ${r.code}`, results };
  }
}

export { PUFFINCC_PBC_URL };
