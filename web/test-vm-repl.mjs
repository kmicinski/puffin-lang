#!/usr/bin/env node
// REPL parity: the bytecode-VM Session (docs/WASM-VM.md §5.2, M5)
// against the JS interpreter Session, over one transcript.
//
//   node web/test-vm-repl.mjs
//
// The VM Session is the real thing the browser runs: a persistent
// puffin-vm-repl.wasm reactor instance (one heap, one session cell
// table), each eval compiled to a v2 link-by-name unit by
// puffincc-on-the-VM (`puffincc --repl`). The JS Session is the
// parity target. For every step we compare ok, the results array
// (rendered values of non-void top-level forms), and -- when the step
// says so -- the streamed output. Error TEXTS are not compared: the
// engines produce different (both correct) diagnostics, and the VM
// path also typechecks, which the JS interpreter never does.
//
// GATED: needs bin/puffin-vm.wasm + bin/puffin-vm-repl.wasm
// (make -C src/vm wasm wasm-repl) and web/public/puffincc.pbc
// (tools/gen-web-vm.sh). Absent artifacts -> SKIP, exit 0.

import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Session as VmSession, preloadArtifacts } from './src/engine/vm-engine.js';
import { Session as JsSession } from './src/puffin/index.js';

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

// The transcript. Each step: { code, compareOutput }. compareOutput
// is off for steps whose failure diagnostics (necessarily) differ.
const transcript = [
  // define then use
  { code: '(define (sq x) (* x x))', compareOutput: true },
  { code: '(sq 7)', compareOutput: true },
  // redefinition replaces
  { code: '(define (sq x) (* x (* x x)))', compareOutput: true },
  { code: '(sq 2)', compareOutput: true },
  // mutual recursion ACROSS evals: even? calls odd? defined later,
  // resolved at call time
  { code: '(define (even? n) (if (eq? n 0) #t (odd? (- n 1))))', compareOutput: true },
  { code: '(define (odd? n) (if (eq? n 0) #f (even? (- n 1))))', compareOutput: true },
  { code: '(even? 10)', compareOutput: true },
  { code: '(odd? 10)', compareOutput: true },
  // a runtime error must not kill the session (error texts differ:
  // VM = the runtime's pf_fatal, JS = the interpreter's message)
  { code: '(car 5)', compareOutput: false },
  { code: '(sq 3)', compareOutput: true },
  // (error v) prints and halts the eval but the session (and the
  // results contract: ok with results-so-far) survives
  { code: '(+ 1 1) (error 42) (+ 2 2)', compareOutput: true },
  { code: '(sq 4)', compareOutput: true },
  // a typecheck error (VM path; the JS interpreter fails the same
  // step at runtime) must not kill the session either
  { code: '(+ 1 "hi")', compareOutput: false },
  { code: '(sq 5)', compareOutput: true },
  // (read) consumes the session's input stream
  { code: '(read)', compareOutput: true },
  { code: '(+ (read) 1)', compareOutput: true },
  // results array: one rendered value per non-void top-level form,
  // program output interleaved on the output channel
  { code: '(define x 5) (+ x 1) "s" (println 99)', compareOutput: true },
  // set! on a global from an earlier eval
  { code: '(set! x (+ x 1)) x', compareOutput: true },
  // prelude functions late-bind; user redefinition shadows them
  { code: '(map (lambda (n) (* n n)) (list 1 2 3))', compareOutput: true },
  { code: '(define (length xs) 42)', compareOutput: true },
  { code: '(length (list 1 2))', compareOutput: true },
  // quasiquote reaches for the prelude's append
  { code: '(define ys (list 2 3)) `(1 ,@ys 4)', compareOutput: true },
  // cross-eval define-type: constructors, match patterns, and the
  // type itself stay usable in later evals (the session re-plays
  // accumulated define-type forms per unit)
  { code: '(define-type Shape (Circle Int) (Rect Int Int))', compareOutput: true },
  { code: '(define (area [s : Shape]) : Int (match s [(Circle r) (* 3 (* r r))] [(Rect w h) (* w h)]))', compareOutput: true },
  { code: '(area (Circle 3))', compareOutput: true },
  { code: '(area (Rect 2 5))', compareOutput: true },
  // values built in one eval flow through pattern matches in another
  { code: '(define c (Circle 4))', compareOutput: true },
  { code: '(match c [(Circle r) r] [_ 0])', compareOutput: true },
  // redefining a type replaces its earlier form
  { code: '(define-type Pt (Pt2 Int Int))', compareOutput: true },
  { code: '(define-type Pt (Pt2 Int Int) (Pt3 Int Int Int))', compareOutput: true },
  { code: '(match (Pt3 1 2 3) [(Pt3 _ _ z) z] [_ 0])', compareOutput: true },
];

const input = [7, 8, 9, 10, 11];

let vmOut = '';
let jsOut = '';
const vm = new VmSession({ input, onOutput: (s) => { vmOut += s; } });
const js = new JsSession({ input, onOutput: (s) => { jsOut += s; } });

let pass = 0, fail = 0;
for (const step of transcript) {
  vmOut = ''; jsOut = '';
  const rv = await vm.eval(step.code);
  const rj = await js.eval(step.code);
  const problems = [];
  if (rv.ok !== rj.ok) problems.push(`ok: vm=${rv.ok} js=${rj.ok} (vm error: ${rv.error}) (js error: ${rj.error})`);
  if (JSON.stringify(rv.results) !== JSON.stringify(rj.results))
    problems.push(`results: vm=${JSON.stringify(rv.results)} js=${JSON.stringify(rj.results)}`);
  if (step.compareOutput && vmOut !== jsOut)
    problems.push(`output: vm=${JSON.stringify(vmOut)} js=${JSON.stringify(jsOut)}`);
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
