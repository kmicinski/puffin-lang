// Puffin interpreter -- public API (pure ESM, no DOM dependencies).
//
//   run(source, {input, onOutput})  run a whole program
//   new Session({input, onOutput})  incremental REPL evaluation
//   render(value)                   the reference display format
//   defaultInput()                  0..99, the reference test default

import { readAll, ReadError } from './reader.js';
import {
  Frame, evalExpr, evalProgram, unwrapProgram, isFunDefine, isValDefine,
  surfacePrimNames,
} from './interp.js';
import { VOID, PuffinHalt, PuffinError, render, Closure, splitFormals } from './values.js';
import { preludeSource } from './prelude.js';
import { resolveModules, moduleForms, ModuleError } from './modules.js';

export { resolveModules, moduleForms, ModuleError };

// The Puffin-written stdlib layer: injected into every program,
// minus any name the program defines itself (mirrors main.rkt's
// read-program-file).
let preludeFormsCache = null;
function preludeFormsFor(userForms) {
  if (!preludeFormsCache) preludeFormsCache = readAll(preludeSource);
  const userNames = new Set();
  for (const f of userForms) {
    if (isFunDefine(f)) userNames.add(f[1][0]);
    else if (isValDefine(f)) userNames.add(f[1]);
  }
  return preludeFormsCache.filter((f) =>
    !(isFunDefine(f) ? userNames.has(f[1][0]) : isValDefine(f) ? userNames.has(f[1]) : false));
}

export { render, ReadError, PuffinError, surfacePrimNames };

// The reference interpreter's default input stream (test.rkt uses
// explicit input files; the browser default with an empty stdin box
// is 0,1,2,... like (range 100)).
export function defaultInput() {
  return Array.from({ length: 100 }, (_, i) => i);
}

function makeCtx(input, onOutput) {
  return {
    input: input.map((n) => BigInt(n)),
    inputPos: 0,
    out: onOutput,
  };
}

// Run a whole program. Output (println/display/error) streams through
// onOutput; the final value is printed too unless it is void (like the
// reference's display-return). Returns:
//   { ok: true,  value: string | null }   value = rendered result (null if void)
//   { ok: false, error: string }          read or runtime error
export function run(source, { input, onOutput, files, entry } = {}) {
  const out = onOutput || (() => {});
  try {
    // module programs (docs/MODULES.md): a virtual file map + entry
    // path resolves the require DAG to a flat form list; a lone
    // source that uses require/provide resolves against itself
    let userForms;
    if (files) {
      userForms = resolveModules(files, entry || 'main.puf');
    } else {
      const raw = readAll(source);
      userForms = moduleForms(raw)
        ? resolveModules({ 'main.puf': source }, 'main.puf')
        : unwrapProgram(raw);
    }
    const forms = [...preludeFormsFor(userForms), ...userForms];
    const ctx = makeCtx(input && input.length ? input : defaultInput(), out);
    const global = new Frame(null);
    let result = VOID;
    try {
      result = evalProgram(forms, global, ctx);
    } catch (e) {
      if (e instanceof PuffinHalt) result = VOID; // (error v): already printed
      else throw e;
    }
    if (result !== VOID) {
      const rendered = render(result);
      out(rendered + '\n');
      return { ok: true, value: rendered };
    }
    return { ok: true, value: null };
  } catch (e) {
    if (e instanceof ReadError || e instanceof PuffinError)
      return { ok: false, error: e.message };
    throw e;
  }
}

// A persistent REPL session: top-level defines persist across evals.
export class Session {
  constructor({ input, onOutput } = {}) {
    this.global = new Frame(null);
    this.ctx = makeCtx(input && input.length ? input : defaultInput(), onOutput || (() => {}));
    // preload the Puffin-written stdlib layer (silently)
    for (const f of preludeFormsFor([])) {
      if (isFunDefine(f)) {
        this.global.define(
          f[1][0],
          (() => { const { fixed, rest } = splitFormals(f[1], 1);
                   return new Closure(fixed, f.slice(2), this.global, Symbol.keyFor(f[1][0]), rest); })());
      }
    }
  }

  // Evaluate one or more forms. Returns
  //   { ok: true,  results: string[] }  rendered values of non-void expressions
  //   { ok: false, error: string, results: string[] }
  eval(text) {
    const results = [];
    try {
      const forms = unwrapProgram(readAll(text));
      for (const f of forms) {
        if (isFunDefine(f)) {
          const name = f[1][0];
          this.global.define(
            name,
            (() => { const { fixed, rest } = splitFormals(f[1], 1);
                     return new Closure(fixed, f.slice(2), this.global, Symbol.keyFor(name), rest); })());
        } else if (isValDefine(f)) {
          this.global.define(f[1], evalExpr(f[2], this.global, this.ctx));
        } else {
          const v = evalExpr(f, this.global, this.ctx);
          if (v !== VOID) results.push(render(v));
        }
      }
      return { ok: true, results };
    } catch (e) {
      if (e instanceof PuffinHalt) return { ok: true, results }; // error already printed
      if (e instanceof ReadError || e instanceof PuffinError)
        return { ok: false, error: e.message, results };
      throw e;
    }
  }
}
