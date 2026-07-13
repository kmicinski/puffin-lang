#!/usr/bin/env node
// The differential ERROR corpus through the wasm VM (the browser
// pipeline): every single-file case in src/errors-corpus is compiled
// by puffincc-ON-the-wasm-VM exactly like the playground's Run
// (docs/WASM-VM.md §5.1) and must fail with the SAME BYTES the native
// routes pinned in its .expect file (tools/test-errors.sh is the
// authority; run it first).
//
// Scope (the bounded, justified subset):
//   * ALL single-file compile-time cases run -- a compile rejection is
//     one cheap puffincc pass on the VM, and compile-time rejection is
//     exactly the class the `#<unknown:0>` incident came from;
//   * runtime cases run through compile-then-run on the VM; they are
//     equally cheap, so they ALL run too;
//   * module-directory cases (mod-*) are SKIPPED: the shim FS could
//     host them, but every path in their expected messages would need
//     rewriting to the virtual /-rooted spellings -- the native
//     five-route matrix in tools/test-errors.sh already pins those
//     messages, and the wasm VM runs the same puffincc bytes.
//
// Path convention: the editor's program is always /main.puf in the
// browser, so positioned diagnostics say [main.puf:N]; the .expect
// files (captured from native runs) say [NAME.puf:N]. The harness
// rewrites NAME.puf -> main.puf in the expectation -- the only
// transformation applied.
//
// Expectation choice per case: NAME.expect.pcc (compile-time) or
// NAME.expect.pcc-vm (runtime) when a triaged per-route override
// exists, else NAME.expect -- i.e. the same file the native puffincc
// legs are held to.
//
// GATED on bin/puffin-vm.wasm (make -C src/vm wasm) +
// web/public/puffincc.pbc (tools/gen-web-vm.sh).

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WasiShim, PuffinAbort } from './src/engine/wasi-shim.js';

const here = dirname(fileURLToPath(import.meta.url));
const wasmPath = join(here, '..', 'bin', 'puffin-vm.wasm');
const puffinccPath = join(here, 'public', 'puffincc.pbc');
const corpusDir = join(here, '..', 'src', 'errors-corpus');

if (!existsSync(wasmPath) || !existsSync(puffinccPath)) {
  console.log('SKIP: needs bin/puffin-vm.wasm (make -C src/vm wasm) and web/public/puffincc.pbc.');
  process.exit(0);
}

const module = await WebAssembly.compile(readFileSync(wasmPath));
const puffincc = new Uint8Array(readFileSync(puffinccPath));

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
  const out = {};
  for (const [k, v] of shim.fs) out[k] = v;
  return { output, files: out, aborted };
}

// discover single-file cases + their flags/expectations
const cases = readdirSync(corpusDir)
  .filter((f) => f.endsWith('.puf'))
  .map((f) => f.slice(0, -'.puf'.length))
  .sort();

function flagsOf(name) {
  const p = join(corpusDir, `${name}.flags`);
  return existsSync(p) ? readFileSync(p, 'utf8').split('\n').filter(Boolean) : [];
}

function expectationFor(name, route) {
  for (const p of [join(corpusDir, `${name}.expect.${route}`), join(corpusDir, `${name}.expect`)]) {
    if (existsSync(p)) {
      // the one transformation: the browser's program path is /main.puf
      return readFileSync(p, 'utf8').replaceAll(`${name}.puf`, 'main.puf').trimEnd();
    }
  }
  return null;
}

let pass = 0, fail = 0;
for (const name of cases) {
  const src = readFileSync(join(corpusDir, `${name}.puf`), 'utf8');
  const strict = flagsOf(name).includes('strict');
  const args = ['/puffincc.pbc'];
  if (strict) args.push('--strict-types');
  args.push('/main.puf', '-t', 'bytecode', '-o', '/out.pbc');
  const compile = await runUnit({
    files: { '/puffincc.pbc': puffincc, '/main.puf': new TextEncoder().encode(src) },
    args,
  });
  const outPbc = compile.files['/out.pbc'];
  let route, got, ranNote;
  if (!outPbc || outPbc.length === 0) {
    route = 'pcc';                       // compile-time rejection
    got = compile.output.trimEnd();
    ranNote = 'compile';
  } else {
    route = 'pcc-vm';                    // runtime failure
    const run = await runUnit({ files: { '/out.pbc': outPbc }, args: ['/out.pbc'] });
    got = run.output.trimEnd();
    ranNote = 'runtime';
    if (!run.aborted && got === '' ) {
      fail++;
      console.log(`FAIL ${name}: expected a failing run on the wasm VM; it succeeded silently`);
      continue;
    }
  }
  const want = expectationFor(name, route);
  if (want === null) {
    fail++;
    console.log(`FAIL ${name}: no expectation on disk (run tools/test-errors.sh gen)`);
    continue;
  }
  if (got === want) {
    pass++;
    console.log(`ok   ${name} [${ranNote}]`);
  } else {
    fail++;
    console.log(`FAIL ${name} [${ranNote}]:\n  expected: ${JSON.stringify(want)}\n  got:      ${JSON.stringify(got)}`);
  }
}
console.log(`\n${pass}/${pass + fail} error-corpus cases match through the wasm VM`);
process.exit(fail ? 1 : 0);
