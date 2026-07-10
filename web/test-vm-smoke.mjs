#!/usr/bin/env node
// Smoke test for the wasm VM + WASI shim (docs/WASM-VM.md §3.5/§5.1).
//
//   node web/test-vm-smoke.mjs
//
// GATED: it needs bin/puffin-vm.wasm, which only exists after wasi-sdk
// is installed and `make -C src/vm wasm` is run. Absent the wasm, it
// prints SKIP and exits 0 (so it is safe to wire into CI now and it
// simply activates the day the wasm lands).
//
// When the wasm exists this runs each real-compiler-produced fixture
// (web/src/engine/fixtures/*.pbc) on the VM through the SAME WasiShim
// the browser uses, and checks stdout against the fixture's .out --
// the end-to-end proof that the wasm path matches the native VM.

import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WasiShim, PuffinAbort } from './src/engine/wasi-shim.js';

const here = dirname(fileURLToPath(import.meta.url));
const wasmPath = join(here, '..', 'bin', 'puffin-vm.wasm');
const fixturesDir = join(here, 'src', 'engine', 'fixtures');

if (!existsSync(wasmPath)) {
  console.log('SKIP: bin/puffin-vm.wasm not built.');
  console.log('      Install wasi-sdk, then: make -C src/vm wasm');
  process.exit(0);
}

const module = await WebAssembly.compile(readFileSync(wasmPath));

const fixtures = readdirSync(fixturesDir).filter((f) => f.endsWith('.pbc'));
let pass = 0, fail = 0;

for (const f of fixtures) {
  const name = f.replace(/\.pbc$/, '');
  const pbc = new Uint8Array(readFileSync(join(fixturesDir, f)));
  const expected = readFileSync(join(fixturesDir, `${name}.out`), 'utf8');

  let output = '';
  const shim = new WasiShim({
    onOutput: (s) => { output += s; },
    files: { '/prog.pbc': pbc },
    args: ['/prog.pbc'],
    stdin: new TextEncoder().encode(Array.from({ length: 100 }, (_, i) => i).join(' ') + '\n'),
  });
  const instance = await WebAssembly.instantiate(module, shim.imports());
  shim.bindMemory(instance.exports.memory);
  try {
    instance.exports._start();
  } catch (e) {
    if (!(e instanceof PuffinAbort)) { console.error(`${name}: crash ${e.message}`); fail++; continue; }
  }
  if (output.trimEnd() === expected.trimEnd()) { pass++; console.log(`ok   ${name}`); }
  else { fail++; console.log(`FAIL ${name}\n  expected: ${JSON.stringify(expected)}\n  got:      ${JSON.stringify(output)}`); }
}

console.log(`\n${pass}/${pass + fail} fixtures pass`);
process.exit(fail ? 1 : 0);
