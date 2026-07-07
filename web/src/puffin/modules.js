// Puffin module resolution (docs/MODULES.md) — the JS mirror of
// src/modules.rkt, over the reader's datum representation (Arrays
// with optional .tail, Symbol.for identifiers, PStr strings).
//
// resolveModules(files, entry) takes a virtual file map
// { "path.puf": source, ... } and an entry path, loads the require
// DAG, mangles each non-entry module's top-level names, uniformly
// renames each module's forms (data positions — quoted datums,
// quasiquote templates outside unquotes, match-pattern structure,
// case datums — are left untouched), and returns one flat array of
// top-level forms in depth-first postorder, entry last.

import { readAll } from './reader.js';
import { PStr, PuffinError } from './values.js';

const S = Symbol.for;
const REQUIRE = S('require');
const PROVIDE = S('provide');
const SIGNATURE = S('signature');

export class ModuleError extends PuffinError {
  constructor(msg) { super(`modules: ${msg}`); this.name = 'ModuleError'; }
}

const KEYWORD_NAMES = new Set([
  'define-type', 'ann', ':',
  'define', 'lambda', 'λ', 'let', 'let*', 'letrec', 'begin', 'if', 'cond',
  'case', 'when', 'unless', 'match', 'set!', 'while', 'quote', 'quasiquote',
  'unquote', 'unquote-splicing', 'and', 'or', 'else', '_', '...',
  'require', 'provide', 'signature', '#%rest', 'nil', 'void', 'read',
]);

const isSym = (v) => typeof v === 'symbol';
const isList = (v) => Array.isArray(v);
const symName = (s) => Symbol.keyFor(s);

export function isRequireForm(f) { return isList(f) && f[0] === REQUIRE; }
export function isProvideForm(f) { return isList(f) && f[0] === PROVIDE; }

// does this list of top-level forms use the module system at all?
export function moduleForms(forms) {
  return forms.some((f) => isRequireForm(f) || isProvideForm(f));
}

// deterministic 32-bit FNV-1a (matches src/modules.rkt)
function fnv1a32(str) {
  let h = 2166136261;
  const bytes = new TextEncoder().encode(str);
  for (const b of bytes) h = Math.imul(h ^ b, 16777619) >>> 0;
  return h >>> 0;
}

// ---- virtual paths ---------------------------------------------------

function dirOf(path) {
  const i = path.lastIndexOf('/');
  return i < 0 ? '' : path.slice(0, i);
}

// resolve `rel` against directory `base`, normalizing ./ and ../
function joinPath(base, rel) {
  const parts = (base === '' ? [] : base.split('/')).concat(rel.split('/'));
  const out = [];
  for (const p of parts) {
    if (p === '' || p === '.') continue;
    else if (p === '..') { if (out.length) out.pop(); }
    else out.push(p);
  }
  return out.join('/');
}

// ---- defines ---------------------------------------------------------

function defnName(f) {
  if (!isList(f) || f[0] !== S('define') || f.length < 2) return null;
  const head = f[1];
  if (isSym(head)) return head;                     // (define x e)
  if (isList(head) && isSym(head[0])) return head[0]; // (define (f ...) ...), maybe dotted
  return null;
}

// every top-level name a form binds: defines bind one; define-type
// binds its type name AND each constructor (docs/TYPES.md) — all of
// them provide/mangle like ordinary top-level names
function defnNames(f) {
  if (isList(f) && f[0] === S('define-type') && f.length >= 2) {
    const names = [];
    const head = f[1];
    if (isSym(head)) names.push(head);
    else if (isList(head) && isSym(head[0])) names.push(head[0]);
    for (const c of f.slice(2)) if (isList(c) && isSym(c[0])) names.push(c[0]);
    return names;
  }
  const n = defnName(f);
  return n === null ? [] : [n];
}

// (fixed n) | (variadic n) | 'val'
function defnArity(f) {
  const formalsArity = (formals) => {
    if (isSym(formals)) return { kind: 'variadic', n: 0 };
    if (!isList(formals)) return { kind: 'val' };
    return formals.tail !== undefined
      ? { kind: 'variadic', n: formals.length }
      : { kind: 'fixed', n: formals.length };
  };
  const head = f[1];
  if (isList(head)) {
    // (define (f a b . r) ...): args are head[1..], tail = rest name
    const args = head.slice(1);
    if (head.tail !== undefined) return { kind: 'variadic', n: args.length };
    return { kind: 'fixed', n: args.length };
  }
  const body = f[2];
  if (isList(body) && (body[0] === S('lambda') || body[0] === S('λ')))
    return formalsArity(body[1]);
  return { kind: 'val' };
}

// ---- parsing module forms --------------------------------------------

function parseRequire(f, baseDir, path) {
  const bad = () => { throw new ModuleError(`malformed require in ${path}: ${formToString(f)}`); };
  if (!(f[1] instanceof PStr)) bad();
  const target = joinPath(baseDir, f[1].s);
  let alias = null, only = null, renames = null, sig = null;
  let i = 2;
  while (i < f.length) {
    const kw = f[i];
    if (kw === S('#:as') && isSym(f[i + 1])) { alias = f[i + 1]; i += 2; }
    else if (kw === S('#:only') && isList(f[i + 1]) && f[i + 1].every(isSym)) { only = f[i + 1]; i += 2; }
    else if (kw === S('#:rename') && isList(f[i + 1])) {
      renames = f[i + 1].map((pr) => {
        if (!isList(pr) || pr.length !== 2 || !isSym(pr[0]) || !isSym(pr[1])) bad();
        return [pr[0], pr[1]];
      });
      i += 2;
    } else if (kw === S('#:sig') && f[i + 1] instanceof PStr) { sig = joinPath(baseDir, f[i + 1].s); i += 2; }
    else bad();
  }
  if (alias && (only || renames))
    throw new ModuleError(`require ${target}: #:as cannot be combined with #:only/#:rename`);
  return { target, alias, only, renames, sig };
}

function readSignature(files, sigPath, modPath) {
  if (!(sigPath in files))
    throw new ModuleError(`${modPath}: signature file not found: ${sigPath}`);
  const forms = readAll(files[sigPath]);
  if (forms.length !== 1 || !isList(forms[0]) || forms[0][0] !== SIGNATURE || !isSym(forms[0][1]))
    throw new ModuleError(`${sigPath}: expected a single (signature NAME entries...) form`);
  return forms[0].slice(2);
}

// ascription: every sig name defined, fun arities match; returns the
// narrowed export set
function checkSignature(files, sigPath, body, topNames, modPath) {
  const byName = new Map();
  for (const f of body) {
    const n = defnName(f);
    if (n) byName.set(n, f);
  }
  const provides = new Set();
  for (const entry of readSignature(files, sigPath, modPath)) {
    if (isList(entry) && entry[0] === S('val') && isSym(entry[1]) && entry.length === 2) {
      if (!topNames.has(entry[1]))
        throw new ModuleError(`${modPath}: signature requires val ${symName(entry[1])}, not defined`);
      provides.add(entry[1]);
    } else if (isList(entry) && entry[0] === S('fun') && isSym(entry[1])
               && typeof entry[2] === 'bigint' && entry.length === 3) {
      const n = entry[1], arity = Number(entry[2]);
      if (!topNames.has(n))
        throw new ModuleError(`${modPath}: signature requires fun ${symName(n)}, not defined`);
      const a = defnArity(byName.get(n));
      if (a.kind === 'fixed' && a.n !== arity)
        throw new ModuleError(`${modPath}: signature fun ${symName(n)} expects arity ${arity}, definition has arity ${a.n}`);
      if (a.kind === 'variadic' && arity < a.n)
        throw new ModuleError(`${modPath}: signature fun ${symName(n)} expects arity ${arity}, variadic definition needs >= ${a.n}`);
      if (a.kind === 'val')
        throw new ModuleError(`${modPath}: signature fun ${symName(n)} is not syntactically a function`);
      provides.add(n);
    } else {
      throw new ModuleError(`${sigPath}: malformed signature entry: ${formToString(entry)}`);
    }
  }
  return provides;
}

function parseProvides(files, forms, body, topNames, path) {
  const provideForms = forms.filter(isProvideForm);
  const sigForms = provideForms.filter((f) => f[1] === S('#:sig'));
  if (sigForms.length > 0) {
    if (sigForms.length !== 1 || provideForms.length !== 1)
      throw new ModuleError(`${path}: (provide #:sig ...) must be the module's only provide form`);
    const f = sigForms[0];
    if (!(f[2] instanceof PStr))
      throw new ModuleError(`malformed provide in ${path}: ${formToString(f)}`);
    return checkSignature(files, joinPath(dirOf(path), f[2].s), body, topNames, path);
  }
  if (provideForms.length === 0) return new Set(topNames); // everything
  const provides = new Set();
  for (const pf of provideForms) {
    for (const n of pf.slice(1)) {
      if (!isSym(n)) throw new ModuleError(`malformed provide in ${path}: ${formToString(pf)}`);
      if (!topNames.has(n))
        throw new ModuleError(`${path} provides ${symName(n)}, which it does not define`);
      provides.add(n);
    }
  }
  return provides;
}

// crude printer for error messages only
function formToString(f) {
  if (isSym(f)) return symName(f);
  if (f instanceof PStr) return JSON.stringify(f.s);
  if (typeof f === 'bigint') return String(f);
  if (isList(f)) return `(${f.map(formToString).join(' ')}${f.tail !== undefined ? ` . ${formToString(f.tail)}` : ''})`;
  return String(f);
}

// ---- loading the DAG --------------------------------------------------

function loadModules(files, entryPath) {
  const loaded = new Map();     // path -> mod
  const postorder = [];
  const ids = new Map();        // id -> path (collision check)
  const moduleId = (path) => {
    const stem = path.replace(/^.*\//, '').replace(/\.[^.]*$/, '').replace(/[^a-zA-Z0-9]/g, '_');
    const id = `${stem}_${fnv1a32(path).toString(16)}`;
    if (ids.has(id) && ids.get(id) !== path)
      throw new ModuleError(`module id collision between ${ids.get(id)} and ${path}`);
    ids.set(id, path);
    return id;
  };
  const visit = (path, stack) => {
    if (stack.includes(path))
      throw new ModuleError(`require cycle: ${[...stack, path].join(' -> ')}`);
    if (loaded.has(path)) return loaded.get(path);
    if (!(path in files)) {
      const from = stack.length ? ` (from ${stack[stack.length - 1]})` : '';
      throw new ModuleError(`required module not found: ${path}${from}`);
    }
    let forms = readAll(files[path]);
    if (forms.length === 1 && isList(forms[0]) && forms[0][0] === S('program'))
      forms = forms[0].slice(1); // tolerate class-style wrapper
    const reqs = forms.filter(isRequireForm).map((f) => parseRequire(f, dirOf(path), path));
    for (const r of reqs) visit(r.target, [...stack, path]);
    const body = forms.filter((f) => !isRequireForm(f) && !isProvideForm(f));
    const topNames = new Set();
    for (const f of body) for (const n of defnNames(f)) topNames.add(n);
    const provides = parseProvides(files, forms, body, topNames, path);
    const m = {
      path,
      id: path === entryPath ? null : moduleId(path),
      body, topNames, provides, reqs,
    };
    loaded.set(path, m);
    postorder.push(m);
    return m;
  };
  visit(entryPath, []);
  return { mods: postorder, loaded };
}

function mangled(m, name) {
  return m.id ? S(`${symName(name)}_${m.id}`) : name;
}

// ---- the renamer -------------------------------------------------------

const QUOTE = S('quote');
const QQ = S('quasiquote');
const UNQ = S('unquote');
const UNQS = S('unquote-splicing');
const MATCH = S('match');
const CASE = S('case');
const ELSE = S('else');
const WHEN_KW = S('#:when');

function renameForms(forms, ren, qual) {
  const sym = (s) => ren.get(s) ?? qual(s) ?? s;
  const list = (f, items) => {
    const out = items;
    if (f.tail !== undefined) out.tail = walkTail(f.tail);
    return out;
  };
  const walkTail = (t) => (isSym(t) ? sym(t) : isList(t) ? expr(t) : t);

  // quasiquote template: symbols are data; descend only into escapes
  const qq = (q, depth) => {
    if (isList(q)) {
      if (q.length === 2 && q[0] === UNQ)
        return list(q, [UNQ, depth === 1 ? expr(q[1]) : qq(q[1], depth - 1)]);
      if (q.length === 2 && q[0] === QQ)
        return list(q, [QQ, qq(q[1], depth + 1)]);
      return list(q, q.map((e) =>
        (isList(e) && e.length === 2 && e[0] === UNQS)
          ? [UNQS, depth === 1 ? expr(e[1]) : qq(e[1], depth - 1)]
          : qq(e, depth)));
    }
    return q;
  };

  // match patterns: variables rename uniformly; constructor heads,
  // quoted datums and quasiquote data do not
  const pat = (p) => {
    if (p === S('_')) return p;
    if (isSym(p)) return sym(p);
    if (!isList(p)) return p;
    if (p[0] === QUOTE) return p;
    if (p[0] === QQ && p.length === 2) return [QQ, qqPat(p[1])];
    if (p[0] === S('cons') && p.length === 3) return [p[0], pat(p[1]), pat(p[2])];
    if (p[0] === S('list') || p[0] === S('vector'))
      return [p[0], ...p.slice(1).map(pat)];
    if (p[0] === S('?') && p.length === 3) return [p[0], sym(p[1]), pat(p[2])];
    // ADT constructor patterns: the head is a top-level name
    // (renamed like any other), the rest are subpatterns
    if (isSym(p[0]) && p.tail === undefined)
      return [sym(p[0]), ...p.slice(1).map(pat)];
    return p;
  };
  const qqPat = (q) => {
    if (isList(q)) {
      if (q.length === 2 && q[0] === UNQ) return [UNQ, pat(q[1])];
      return list(q, q.map(qqPat));
    }
    return q;
  };
  const matchClause = (cl) => {
    if (!isList(cl) || cl.length === 0) return cl;
    if (cl.length >= 3 && cl[1] === WHEN_KW)
      return [pat(cl[0]), WHEN_KW, expr(cl[2]), ...cl.slice(3).map(expr)];
    return [pat(cl[0]), ...cl.slice(1).map(expr)];
  };
  const caseClause = (cl) => {
    if (!isList(cl) || cl.length === 0) return cl;
    if (cl[0] === ELSE) return [ELSE, ...cl.slice(1).map(expr)];
    return [cl[0], ...cl.slice(1).map(expr)]; // datums untouched
  };

  const expr = (e) => {
    if (isSym(e)) return sym(e);
    if (!isList(e)) return e;
    if (e[0] === QUOTE) return e;
    if (e[0] === QQ && e.length === 2) return list(e, [QQ, qq(e[1], 1)]);
    if (e[0] === MATCH && e.length >= 2)
      return list(e, [MATCH, expr(e[1]), ...e.slice(2).map(matchClause)]);
    if (e[0] === CASE && e.length >= 2)
      return list(e, [CASE, expr(e[1]), ...e.slice(2).map(caseClause)]);
    return list(e, e.map(expr));
  };
  return forms.map(expr);
}

// ---- resolve-modules ---------------------------------------------------

export function resolveModules(files, entryPath) {
  const { mods, loaded } = loadModules(files, entryPath);
  // every symbol mentioned anywhere (mangled-name collision check)
  const allMentions = new Set();
  for (const m of mods) {
    const walk = (v) => {
      if (isSym(v)) allMentions.add(v);
      else if (isList(v)) { v.forEach(walk); if (v.tail !== undefined) walk(v.tail); }
    };
    m.body.forEach(walk);
  }
  const flat = [];
  for (const m of mods) {
    const ren = new Map();
    const aliases = new Map();
    const addImport = (local, target, from) => {
      if (KEYWORD_NAMES.has(symName(local)))
        throw new ModuleError(`${m.path}: cannot import ${symName(local)} unqualified (reserved word); use #:as or #:rename`);
      if (m.topNames.has(local))
        throw new ModuleError(`${m.path}: import ${symName(local)} from ${from} collides with a local top-level definition`);
      if (ren.has(local) && ren.get(local) !== target)
        throw new ModuleError(`${m.path}: name ${symName(local)} imported from two different modules`);
      ren.set(local, target);
    };
    for (const r of m.reqs) {
      const dep = loaded.get(r.target);
      if (r.sig) checkSignature(files, r.sig, dep.body, dep.topNames, dep.path);
      if (r.alias) { aliases.set(r.alias, dep); continue; }
      let names;
      if (r.only) {
        for (const n of r.only) {
          if (!dep.provides.has(n))
            throw new ModuleError(`${m.path}: #:only name ${symName(n)} is not provided by ${dep.path}`);
        }
        names = r.only;
      } else {
        names = [...dep.provides];
      }
      const renamePairs = r.renames ?? [];
      for (const [old] of renamePairs) {
        if (!names.includes(old))
          throw new ModuleError(`${m.path}: #:rename of ${symName(old)}, which is not imported from ${dep.path}`);
      }
      for (const n of names) {
        const pair = renamePairs.find(([old]) => old === n);
        addImport(pair ? pair[1] : n, mangled(dep, n), dep.path);
      }
    }
    if (m.id) {
      for (const n of m.topNames) {
        const mn = mangled(m, n);
        if (allMentions.has(mn))
          throw new ModuleError(`${m.path}: source uses ${symName(mn)}, which collides with a mangled module name`);
        ren.set(n, mn);
      }
    }
    const qual = (s) => {
      const str = symName(s);
      const i = str.indexOf('.');
      if (i <= 0 || i >= str.length - 1) return null;
      const dep = aliases.get(S(str.slice(0, i)));
      if (!dep) return null;
      const n = S(str.slice(i + 1));
      if (!dep.provides.has(n))
        throw new ModuleError(`${m.path}: ${symName(n)} is not provided by ${dep.path} (via ${str})`);
      return mangled(dep, n);
    };
    flat.push(...renameForms(m.body, ren, qual));
  }
  return flat;
}
