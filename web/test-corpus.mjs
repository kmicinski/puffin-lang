#!/usr/bin/env node
// Cross-check the web interpreter against the reference goldens:
// every program in src/test-programs/*.scm x every src/input-files/N.in,
// trimmed output compared against src/goldens/<prog>_<N>.golden.
//
//   node web/test-corpus.mjs            run all
//   node web/test-corpus.mjs r4-7       restrict to named programs

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { run } from './src/puffin/index.js';

const here = dirname(fileURLToPath(import.meta.url));
const srcDir = join(here, '..', 'src');
const testsDir = join(srcDir, 'test-programs');
const inputsDir = join(srcDir, 'input-files');
const goldensDir = join(srcDir, 'goldens');

const only = process.argv.slice(2);

const programs = readdirSync(testsDir)
  .filter((f) => f.endsWith('.scm') || f.endsWith('.puf'))
  .map((f) => f.replace(/\.(scm|puf)$/, ''))
  .filter((p) => only.length === 0 || only.includes(p))
  .sort();

const inputs = readdirSync(inputsDir)
  .filter((f) => f.endsWith('.in'))
  .map((f) => f.replace(/\.in$/, ''))
  .sort();

function inputInts(name) {
  return readFileSync(join(inputsDir, `${name}.in`), 'utf8')
    .split(/\s+/)
    .filter((s) => s !== '')
    .map((s) => Number(s));
}

let checks = 0;
let failures = 0;

for (const prog of programs) {
  const source = readFileSync(
    existsSync(join(testsDir, `${prog}.scm`))
      ? join(testsDir, `${prog}.scm`)
      : join(testsDir, `${prog}.puf`),
    'utf8');
  for (const input of inputs) {
    const goldenPath = join(goldensDir, `${prog}_${input}.golden`);
    if (!existsSync(goldenPath)) continue;
    const golden = readFileSync(goldenPath, 'utf8');
    checks++;
    let out = '';
    const res = run(source, { input: inputInts(input), onOutput: (s) => { out += s; } });
    if (!res.ok) out += `ERROR: ${res.error}`;
    if (out.trim() !== golden.trim()) {
      failures++;
      console.log(`FAIL ${prog}/${input}`);
      console.log(`  expected: ${JSON.stringify(golden.trim())}`);
      console.log(`  got:      ${JSON.stringify(out.trim())}`);
    }
  }
}

console.log(`${checks} checks, ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
