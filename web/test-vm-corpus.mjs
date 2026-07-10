#!/usr/bin/env node
// Full-corpus parity for the wasm VM path (docs/WASM-VM.md M4 gate;
// the Phase 3 "deletion gate" for retiring web/src/puffin/):
// every program in src/test-programs (including module dirs) is
// compiled by puffincc RUNNING ON THE WASM VM, then the compiled unit
// runs on the VM against every src/input-files/N.in, and trimmed
// output is compared to src/goldens/<prog>_<N>.golden — exactly the
// checks web/test-corpus.mjs makes of the JS interpreter, but through
// the real self-hosted compiler + VM.
//
//   node web/test-vm-corpus.mjs           run all
//   node web/test-vm-corpus.mjs r4-7      restrict to named programs
//
// Needs bin/puffin-vm.wasm + web/public/puffincc.pbc (tools/gen-web-vm.sh).

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WasiShim, PuffinAbort } from './src/engine/wasi-shim.js';

const here = dirname(fileURLToPath(import.meta.url));
const srcDir = join(here, '..', 'src');
const testsDir = join(srcDir, 'test-programs');
const inputsDir = join(srcDir, 'input-files');
const goldensDir = join(srcDir, 'goldens');
const wasmPath = join(here, '..', 'bin', 'puffin-vm.wasm');
const puffinccPath = join(here, 'public', 'puffincc.pbc');

if (!existsSync(wasmPath) || !existsSync(puffinccPath)) {
  console.log('SKIP: needs bin/puffin-vm.wasm and web/public/puffincc.pbc (run tools/gen-web-vm.sh).');
  process.exit(0);
}

const module = await WebAssembly.compile(readFileSync(wasmPath));
const puffincc = new Uint8Array(readFileSync(puffinccPath));
const enc = new TextEncoder();

const only = process.argv.slice(2);

const programs = readdirSync(testsDir)
  .filter((f) => f.endsWith('.scm') || f.endsWith('.puf')
    || (statSync(join(testsDir, f)).isDirectory() && existsSync(join(testsDir, f, 'main.puf'))))
  .map((f) => f.replace(/\.(scm|puf)$/, ''))
  .filter((p) => only.length === 0 || only.includes(p))
  .sort();

const inputs = readdirSync(inputsDir)
  .filter((f) => f.endsWith('.in'))
  .map((f) => f.replace(/\.in$/, ''))
  .sort();

// One VM instance, run to _start completion; returns captured output
// (stdout+stderr interleaved, like the reference harness) + shim FS.
async function exec({ files, args, stdin }) {
  let output = '';
  const shim = new WasiShim({
    onOutput: (s) => { output += s; },
    files, args,
    stdin: stdin ?? new Uint8Array(0),
  });
  const instance = await WebAssembly.instantiate(module, shim.imports());
  shim.bindMemory(instance.exports.memory);
  try { instance.exports._start(); }
  catch (e) { if (!(e instanceof PuffinAbort)) throw e; }
  return { output, fs: shim.fs };
}

let checks = 0, failures = 0, compileFailures = 0;

for (const prog of programs) {
  // assemble the program's file map (module dirs = many files)
  const fs = { '/puffincc.pbc': puffincc };
  let entry;
  const progDir = join(testsDir, prog);
  if (existsSync(join(progDir, 'main.puf'))) {
    for (const f of readdirSync(progDir))
      if (f.endsWith('.puf') || f.endsWith('.pufs'))
        fs['/' + f] = enc.encode(readFileSync(join(progDir, f), 'utf8'));
    entry = '/main.puf';
  } else {
    const p = existsSync(join(testsDir, `${prog}.scm`))
      ? join(testsDir, `${prog}.scm`) : join(testsDir, `${prog}.puf`);
    fs['/main.puf'] = enc.encode(readFileSync(p, 'utf8'));
    entry = '/main.puf';
  }

  // compile once per program (bytecode is input-independent)
  const compile = await exec({
    files: fs,
    args: ['/puffincc.pbc', entry, '-t', 'bytecode', '-o', '/out.pbc'],
  });
  const outPbc = compile.fs.get('/out.pbc');
  if (!outPbc || outPbc.length === 0) {
    compileFailures++;
    console.log(`FAIL ${prog}: compile (puffincc-on-VM): ${JSON.stringify(compile.output.trim())}`);
    // count each golden this program would have checked as a failure
    for (const input of inputs)
      if (existsSync(join(goldensDir, `${prog}_${input}.golden`))) { checks++; failures++; }
    continue;
  }

  for (const input of inputs) {
    const goldenPath = join(goldensDir, `${prog}_${input}.golden`);
    if (!existsSync(goldenPath)) continue;
    const golden = readFileSync(goldenPath, 'utf8');
    checks++;
    const run = await exec({
      files: { '/out.pbc': outPbc },
      args: ['/out.pbc'],
      stdin: readFileSync(join(inputsDir, `${input}.in`)),
    });
    if (run.output.trim() !== golden.trim()) {
      failures++;
      console.log(`FAIL ${prog}/${input}`);
      console.log(`  expected: ${JSON.stringify(golden.trim())}`);
      console.log(`  got:      ${JSON.stringify(run.output.trim())}`);
    }
  }
}

console.log(`${checks} checks, ${failures} failures${compileFailures ? ` (${compileFailures} compile failures)` : ''}`);
process.exit(failures === 0 ? 0 : 1);
