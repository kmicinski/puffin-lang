#!/usr/bin/env node
// The assist corpus driver (tools/test-assist.sh runs it; see there).
//
// A case is src/assist-corpus/NAME.puf, or a directory NAME/ whose
// entry is main.puf. The entry's first line says what to run:
//
//   ;; assist: OP                        (check, forms)
//   ;; assist: OP @ "NEEDLE" [+K]        (type-at, assists, facts):
//                                        the cursor is K bytes past
//                                        the first NEEDLE after line 1
//   ... [observed=FILE]                  pass --observed FILE (a
//                                        session observation record,
//                                        docs/STUDIO.md §3.1)
//
// The transcript compared against NAME.expect is the operation's
// stdout and stderr, then, for every assist it offered, the entry
// with that assist's edits applied and `check` run on the result --
// so a generated edit that does not compile shows up as a diff.
//
//   node tools/assist-corpus.mjs [gen] [NAME ...]

import { readFileSync, writeFileSync, readdirSync, statSync, existsSync, mkdtempSync, cpSync, rmSync } from 'node:fs';
import { join, basename } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';

const root = new URL('..', import.meta.url).pathname;
const corpus = join(root, 'src/assist-corpus');
const puffincc = process.env.PUFFINCC || join(root, 'build/puffincc');

const args = process.argv.slice(2);
const gen = args[0] === 'gen';
const only = gen ? args.slice(1) : args;

function run(cmdArgs, cwd) {
  const r = spawnSync(puffincc, cmdArgs, { cwd, encoding: 'utf8' });
  return { stdout: r.stdout, stderr: r.stderr, status: r.status };
}

// the cursor directive on the entry's first line
function directive(text) {
  const first = text.split('\n')[0];
  const m = first.match(/^;; assist: (\S+)(?: @ "((?:[^"\\]|\\.)*)"(?: \+(\d+))?)?(?: observed=(\S+))?\s*$/);
  if (!m) throw new Error(`bad directive: ${first}`);
  const [, op, needle, k, observed] = m;
  if (needle === undefined) return { op, pos: null, observed };
  const bytes = Buffer.from(text, 'utf8');
  const lineEnd = bytes.indexOf(10);
  const at = bytes.indexOf(Buffer.from(JSON.parse(`"${needle}"`), 'utf8'), lineEnd);
  if (at < 0) throw new Error(`needle not found: ${needle}`);
  return { op, pos: at + Number(k || 0), observed };
}

// apply byte-offset edits, last first so earlier offsets stay valid
function applyEdits(text, edits) {
  let bytes = Buffer.from(text, 'utf8');
  for (const e of [...edits].sort((a, b) => b.start - a.start)) {
    bytes = Buffer.concat([bytes.subarray(0, e.start), Buffer.from(e.text, 'utf8'), bytes.subarray(e.end)]);
  }
  return bytes.toString('utf8');
}

function section(title, body) {
  return `== ${title}\n${body.endsWith('\n') || body === '' ? body : body + '\n'}`;
}

function transcript(caseDir, entryName) {
  const entry = join(caseDir, entryName);
  const text = readFileSync(entry, 'utf8');
  const { op, pos, observed } = directive(text);
  const opArgs = ['--assist', op, entryName, ...(pos === null ? [] : [String(pos)]),
                  ...(observed ? ['--observed', observed] : [])];
  const r = run(opArgs, caseDir);
  let out = section(`${op}${pos === null ? '' : ' @ ' + pos} (exit ${r.status})`, '');
  out += section('stdout', r.stdout) + section('stderr', r.stderr);
  if (op !== 'assists') return out;
  const assists = r.stdout.split('\n').filter((l) => l.startsWith('{"id"')).map((l) => JSON.parse(l));
  assists.forEach((a, i) => {
    const work = mkdtempSync(join(tmpdir(), 'assist-'));
    try {
      cpSync(caseDir, work, { recursive: true });
      const edited = applyEdits(text, a.edits);
      writeFileSync(join(work, entryName), edited);
      const c = run(['--assist', 'check', entryName], work);
      out += section(`apply ${i + 1}: ${a.id}`, edited);
      out += section(`check (exit ${c.status})`, c.stdout + c.stderr);
    } finally {
      rmSync(work, { recursive: true, force: true });
    }
  });
  return out;
}

const names = readdirSync(corpus)
  .filter((f) => f.endsWith('.puf') || statSync(join(corpus, f)).isDirectory())
  .map((f) => f.replace(/\.puf$/, ''))
  .filter((n) => only.length === 0 || only.includes(n))
  .sort();

let failures = 0;
for (const name of names) {
  const isDir = statSync(join(corpus, existsSync(join(corpus, name + '.puf')) ? name + '.puf' : name)).isDirectory();
  // single files run from a private copy so the check output's
  // [file:line] names are stable
  let got;
  if (isDir) {
    got = transcript(join(corpus, name), 'main.puf');
  } else {
    const work = mkdtempSync(join(tmpdir(), 'assist-case-'));
    try {
      cpSync(join(corpus, name + '.puf'), join(work, basename(name) + '.puf'));
      got = transcript(work, basename(name) + '.puf');
    } finally {
      rmSync(work, { recursive: true, force: true });
    }
  }
  const expectPath = join(corpus, name + '.expect');
  if (gen) {
    writeFileSync(expectPath, got);
    console.log(`wrote ${name}.expect`);
  } else if (!existsSync(expectPath)) {
    failures++;
    console.log(`FAIL ${name}: no .expect (run gen)`);
  } else if (readFileSync(expectPath, 'utf8') !== got) {
    failures++;
    console.log(`FAIL ${name}`);
    const want = readFileSync(expectPath, 'utf8').split('\n');
    const have = got.split('\n');
    for (let i = 0; i < Math.max(want.length, have.length); i++) {
      if (want[i] !== have[i]) {
        console.log(`  line ${i + 1}:\n    expected: ${JSON.stringify(want[i])}\n    got:      ${JSON.stringify(have[i])}`);
        break;
      }
    }
  } else {
    console.log(`ok   ${name}`);
  }
}
if (!gen) console.log(`\n${names.length} assist cases, ${failures} failures`);
process.exit(failures ? 1 : 0);
