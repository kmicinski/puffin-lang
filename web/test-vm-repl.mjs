#!/usr/bin/env node
// REPL regression for the bytecode-VM Session (docs/WASM-VM.md §5.2)
// against web/repl-golden.json — a transcript of ok/results/output
// expectations frozen from the JS interpreter Session at retirement
// time (§7.4), so REPL semantics can't drift even though the JS
// engine is gone.
//
//   node web/test-vm-repl.mjs
//
// The VM Session is the real thing the browser runs: a persistent
// puffin-vm-repl.wasm reactor instance (one heap, one session cell
// table), each eval compiled to a v2 link-by-name unit by
// puffincc-on-the-VM (`puffincc --repl`). For every step we compare
// ok, the results array (rendered values of non-void top-level
// forms), and -- when the step says so -- the streamed output. Steps
// with compareOutput:false are ones whose failure diagnostics
// (necessarily) differ from the frozen JS ones: the VM path
// typechecks (the JS interpreter never did) and its runtime errors
// are pf_fatal texts.
//
// GATED: needs bin/puffin-vm.wasm + bin/puffin-vm-repl.wasm
// (make -C src/vm wasm wasm-repl) and web/public/puffincc.pbc
// (tools/gen-web-vm.sh). Absent artifacts -> SKIP, exit 0.

import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Session as VmSession, preloadArtifacts } from './src/engine/vm-engine.js';

const here = dirname(fileURLToPath(import.meta.url));
const vmWasmPath = join(here, '..', 'bin', 'puffin-vm.wasm');
const replWasmPath = join(here, '..', 'bin', 'puffin-vm-repl.wasm');
const puffinccPath = join(here, 'public', 'puffincc.pbc');

if (!existsSync(vmWasmPath) || !existsSync(replWasmPath) || !existsSync(puffinccPath)) {
  console.log('SKIP: needs bin/puffin-vm.wasm + bin/puffin-vm-repl.wasm (make -C src/vm wasm wasm-repl)');
  console.log('      and web/public/puffincc.pbc (tools/gen-web-vm.sh).');
  process.exit(0);
}

preloadArtifacts({
  vmWasm: readFileSync(vmWasmPath),
  vmReplWasm: readFileSync(replWasmPath),
  puffincc: new Uint8Array(readFileSync(puffinccPath)),
});

const golden = JSON.parse(readFileSync(join(here, 'repl-golden.json'), 'utf8'));
const input = [7, 8, 9, 10, 11]; // must match the transcript's freeze run

let vmOut = '';
const vm = new VmSession({ input, onOutput: (s) => { vmOut += s; } });

let pass = 0, fail = 0;
for (const step of golden) {
  vmOut = '';
  const rv = await vm.eval(step.code);
  const problems = [];
  if (rv.ok !== step.ok) problems.push(`ok: vm=${rv.ok} golden=${step.ok} (vm error: ${rv.error})`);
  if (JSON.stringify(rv.results) !== JSON.stringify(step.results))
    problems.push(`results: vm=${JSON.stringify(rv.results)} golden=${JSON.stringify(step.results)}`);
  if (step.compareOutput && vmOut !== step.output)
    problems.push(`output: vm=${JSON.stringify(vmOut)} golden=${JSON.stringify(step.output)}`);
  if (problems.length === 0) {
    pass++;
    console.log(`ok   ${step.code.length > 48 ? step.code.slice(0, 45) + '...' : step.code}`);
  } else {
    fail++;
    console.log(`FAIL ${step.code}`);
    for (const p of problems) console.log(`     ${p}`);
  }
}

console.log(`\n${pass}/${pass + fail} REPL parity steps pass`);
process.exit(fail ? 1 : 0);
