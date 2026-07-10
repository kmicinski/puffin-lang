#!/usr/bin/env node
// Compile-then-run through the wasm VM (docs/WASM-VM.md §5.1) — the
// full browser Run pipeline, driven from node:
//
//   1. puffincc.pbc runs ON the VM, compiling /main.puf -> /out.pbc
//      (reading source + writing bytecode through the WASI shim's
//      in-memory FS), typechecking as it goes;
//   2. a second VM instance runs /out.pbc, stdout captured.
//
// This proves the real self-hosted compiler + typechecker executes in
// the wasm VM and produces runnable bytecode — no JS interpreter.
//
// GATED on bin/puffin-vm.wasm + web/public/puffincc.pbc.

import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WasiShim, PuffinAbort } from './src/engine/wasi-shim.js';

const here = dirname(fileURLToPath(import.meta.url));
const wasmPath = join(here, '..', 'bin', 'puffin-vm.wasm');
const puffinccPath = join(here, 'public', 'puffincc.pbc');

if (!existsSync(wasmPath) || !existsSync(puffinccPath)) {
  console.log('SKIP: needs bin/puffin-vm.wasm (make -C src/vm wasm) and web/public/puffincc.pbc.');
  process.exit(0);
}

const module = await WebAssembly.compile(readFileSync(wasmPath));
const puffincc = new Uint8Array(readFileSync(puffinccPath));

// Run one .pbc unit on a fresh VM instance against a shared FS.
// Returns { output, files, aborted }.
async function runUnit({ files, args, stdin = '' }) {
  let output = '';
  const shim = new WasiShim({
    onOutput: (s) => { output += s; },
    files,
    args,
    stdin: new TextEncoder().encode(stdin),
  });
  const instance = await WebAssembly.instantiate(module, shim.imports());
  shim.bindMemory(instance.exports.memory);
  let aborted = false;
  try {
    instance.exports._start();
  } catch (e) {
    if (e instanceof PuffinAbort) aborted = true;
    else throw e;
  }
  // surface the shim's FS back out (fd_write updated it in place)
  const out = {};
  for (const [k, v] of shim.fs) out[k] = v;
  return { output, files: out, aborted };
}

// Compile `source` with puffincc-on-the-VM, then run the result.
async function compileAndRun(source, stdin = '') {
  const compile = await runUnit({
    files: { '/puffincc.pbc': puffincc, '/main.puf': new TextEncoder().encode(source) },
    args: ['/puffincc.pbc', '/main.puf', '-t', 'bytecode', '-o', '/out.pbc'],
  });
  const outPbc = compile.files['/out.pbc'];
  if (!outPbc || outPbc.length === 0) {
    return { compileOutput: compile.output, ran: false };
  }
  const run = await runUnit({ files: { '/out.pbc': outPbc }, args: ['/out.pbc'], stdin });
  return { compileOutput: compile.output, ran: true, output: run.output };
}

const cases = [
  { name: 'fact',   src: '(define (fact [n : Int]) : Int (if (eq? n 0) 1 (* n (fact (- n 1)))))\n(println (fact 10))\n', expect: '3628800' },
  { name: 'adts',   src: '(define-type Expr (Num Int) (Plus Expr Expr))\n(define (ev [e : Expr]) : Int (match e [(Num n) n] [(Plus a b) (+ (ev a) (ev b))]))\n(println (ev (Plus (Num 20) (Num 22))))\n', expect: '42' },
  { name: 'reject', src: '(define-type Expr (Num Int) (Plus Expr Expr))\n(println (Plus 5 5))\n', expectError: 'typecheck: Plus' },
  // an UNBOUND name must be a compile-time rejection, not a runaway
  // program: it used to compile into a 0-seeded cell that CALLI
  // dispatched as function index 0 = the entry, so the program
  // re-entered main until the control stack died (the browser printed
  // its own output over and over)
  { name: 'unbound', src: '(define-type Expr (Num Int) (Add Expr Expr))\n(define (ev [e : Expr]) : Int (match e [(Num n) n] [(Add a b) (+ (ev a) (ev b))]))\n(println (ev (Add (Num 1) (Num 2))))\n(ev (Plus 20 20))\n', expectError: 'unbound variable Plus' },
];

let pass = 0, fail = 0;
for (const c of cases) {
  const r = await compileAndRun(c.src);
  if (c.expectError) {
    if (!r.ran && r.compileOutput.includes(c.expectError)) { pass++; console.log(`ok   ${c.name} (rejected: ${r.compileOutput.trim()})`); }
    else { fail++; console.log(`FAIL ${c.name}: expected compile error containing ${JSON.stringify(c.expectError)}; got ran=${r.ran} out=${JSON.stringify(r.compileOutput)}`); }
  } else {
    if (r.ran && r.output.trim() === c.expect) { pass++; console.log(`ok   ${c.name} -> ${r.output.trim()}`); }
    else { fail++; console.log(`FAIL ${c.name}: expected ${JSON.stringify(c.expect)}; got ran=${r.ran} out=${JSON.stringify(r.output)} compileOut=${JSON.stringify(r.compileOutput)}`); }
  }
}
console.log(`\n${pass}/${pass + fail} compile-then-run cases pass`);
process.exit(fail ? 1 : 0);
