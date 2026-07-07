// Puffin surface-language interpreter.
//
// Interprets the full surface language (match/cond/case/when/unless/
// named let/let*/while/set!/lambda/quote/n-ary ops/...) directly,
// with behavior matching the reference pipeline (desugar +
// eval-puffin-exp in src/compile.rkt + src/interpreters.rkt):
//
//  - Racket-style truthiness: only #f is false.
//  - Scope-aware primitives: top-level defines and local bindings
//    shadow stdlib primitives; a primitive used as a bare variable
//    eta-expands (here: resolves to a Native function value).
//  - + - * and/or/not are intrinsic forms (never shadowed in operator
//    position, matching desugar); comparators, list/vector and the
//    stdlib prims respect shadowing.
//  - Proper tail calls: the evaluator loops on every tail position.
//  - (error v) prints "error: <v>" and halts the program (PuffinHalt).

import {
  Pair, PStr, Closure, Native, VOID, NIL,
  PuffinHalt, PuffinError, eqv, puffinEqual, render,
  IHash, ISet,
  splitFormals,
} from './values.js';

const S = Symbol.for;

const S_QUOTE = S('quote');
const S_QUASIQUOTE = S('quasiquote');
const S_LETREC = S('letrec');
const S_UNQUOTE_SPLICING = S('unquote-splicing');
const S_UNQUOTE = S('unquote');
const S_IF = S('if');
const S_COND = S('cond');
const S_WHEN = S('when');
const S_UNLESS = S('unless');
const S_CASE = S('case');
const S_MATCH = S('match');
const S_LET = S('let');
const S_LETSTAR = S('let*');
const S_LAMBDA = S('lambda');
const S_LAMBDA2 = S('λ');
const S_BEGIN = S('begin');
const S_WHILE = S('while');
const S_SET = S('set!');
const S_AND = S('and');
const S_OR = S('or');
const S_NOT = S('not');
const S_ADD = S('+');
const S_SUB = S('-');
const S_MUL = S('*');
const S_LT = S('<');
const S_LE = S('<=');
const S_GT = S('>');
const S_GE = S('>=');
const S_EQ = S('eq?');
const S_LIST = S('list');
const S_HASH = S('hash');
const S_SETC = S('set');
const S_VECTOR = S('vector');
const S_VOIDF = S('void');
const S_READ = S('read');
const S_ELSE = S('else');
const S_DEFINE = S('define');
const S_PROGRAM = S('program');
const S_CONS = S('cons');
const S_PRED = S('?');
const S_WILD = S('_');
const S_KW_WHEN = S('#:when');

// ---------------------------------------------------------------------
// Environments: chained frames of symbol -> box ({v})
// ---------------------------------------------------------------------

export class Frame {
  constructor(parent) { this.vars = new Map(); this.parent = parent; }
  lookup(sym) {
    let f = this;
    while (f) {
      const b = f.vars.get(sym);
      if (b !== undefined) return b;
      f = f.parent;
    }
    return undefined;
  }
  define(sym, value) {
    let b = this.vars.get(sym);
    if (b === undefined) { b = { v: value }; this.vars.set(sym, b); }
    else b.v = value;
    return b;
  }
}

// ---------------------------------------------------------------------
// The stdlib manifest (from src/stdlib.rkt). fn(args, ctx) -> value.
// ---------------------------------------------------------------------

function halt(ctx, v) {
  ctx.out(`error: ${render(v)}\n`);
  throw new PuffinHalt();
}

function wantInt(v, who) {
  if (typeof v !== 'bigint') throw new PuffinError(`${who}: expected an integer, got ${render(v)}`);
  return v;
}
function wantPair(v, who) {
  if (!(v instanceof Pair)) throw new PuffinError(`${who}: expected a pair, got ${render(v)}`);
  return v;
}
function wantVector(v, who) {
  if (!Array.isArray(v)) throw new PuffinError(`${who}: expected a vector, got ${render(v)}`);
  return v;
}
function wantString(v, who) {
  if (!(v instanceof PStr)) throw new PuffinError(`${who}: expected a string, got ${render(v)}`);
  return v;
}
function wantSymbol(v, who) {
  if (typeof v !== 'symbol') throw new PuffinError(`${who}: expected a symbol, got ${render(v)}`);
  return v;
}
function wantHash(v, who) {
  if (!(v instanceof Map)) throw new PuffinError(`${who}: expected a hash, got ${render(v)}`);
  return v;
}
function wantSet(v, who) {
  if (!(v instanceof Set)) throw new PuffinError(`${who}: expected a set, got ${render(v)}`);
  return v;
}

function readInput(ctx) {
  if (ctx.inputPos >= ctx.input.length)
    throw new PuffinError('input exhausted for (read)');
  return ctx.input[ctx.inputPos++];
}

export const PRIMS = new Map();
function defprim(name, arity, fn) { PRIMS.set(S(name), { name, arity, fn }); }

// ---- I/O --------------------------------------------------------------
defprim('read', 0, (a, ctx) => readInput(ctx));
defprim('println', 1, (a, ctx) => { ctx.out(render(a[0]) + '\n'); return VOID; });
defprim('display', 1, (a, ctx) => { ctx.out(render(a[0])); return VOID; });
defprim('newline', 0, (a, ctx) => { ctx.out('\n'); return VOID; });
defprim('error', 1, (a, ctx) => halt(ctx, a[0]));

// ---- generic equality ---------------------------------------------------
defprim('equal?', 2, (a) => puffinEqual(a[0], a[1]));

// ---- pairs and lists ----------------------------------------------------
defprim('cons', 2, (a) => new Pair(a[0], a[1]));
defprim('car', 1, (a) => wantPair(a[0], 'car').car);
defprim('cdr', 1, (a) => wantPair(a[0], 'cdr').cdr);
defprim('pair?', 1, (a) => a[0] instanceof Pair);
defprim('null?', 1, (a) => a[0] === NIL);

// ---- vectors ------------------------------------------------------------
defprim('make-vector', 1, (a) => {
  const n = wantInt(a[0], 'make-vector');
  if (n < 0n) throw new PuffinError(`make-vector: expected a nonnegative size, got ${n}`);
  return new Array(Number(n)).fill(0n);
});
defprim('vector-ref', 2, (a) => {
  const v = wantVector(a[0], 'vector-ref');
  const i = wantInt(a[1], 'vector-ref');
  if (i < 0n || i >= BigInt(v.length))
    throw new PuffinError(`vector-ref: index ${i} out of bounds for vector of length ${v.length}`);
  return v[Number(i)];
});
defprim('vector-set!', 3, (a) => {
  const v = wantVector(a[0], 'vector-set!');
  const i = wantInt(a[1], 'vector-set!');
  if (i < 0n || i >= BigInt(v.length))
    throw new PuffinError(`vector-set!: index ${i} out of bounds for vector of length ${v.length}`);
  v[Number(i)] = a[2];
  return VOID;
});
defprim('vector-length', 1, (a) => BigInt(wantVector(a[0], 'vector-length').length));
defprim('vector?', 1, (a) => Array.isArray(a[0]));

// ---- strings --------------------------------------------------------------
defprim('string?', 1, (a) => a[0] instanceof PStr);
defprim('string-length', 1, (a) => BigInt(wantString(a[0], 'string-length').s.length));
defprim('string-append', 2, (a) =>
  new PStr(wantString(a[0], 'string-append').s + wantString(a[1], 'string-append').s));
defprim('string=?', 2, (a) =>
  wantString(a[0], 'string=?').s === wantString(a[1], 'string=?').s);
defprim('symbol->string', 1, (a) =>
  new PStr(Symbol.keyFor(wantSymbol(a[0], 'symbol->string'))));
defprim('string->symbol', 1, (a) => S(wantString(a[0], 'string->symbol').s));

// ---- arithmetic helpers -----------------------------------------------------
defprim('quotient', 2, (a) => {
  const x = wantInt(a[0], 'quotient'), y = wantInt(a[1], 'quotient');
  if (y === 0n) throw new PuffinError('quotient: division by zero');
  return x / y; // BigInt division truncates toward zero, like Racket quotient
});
defprim('remainder', 2, (a) => {
  const x = wantInt(a[0], 'remainder'), y = wantInt(a[1], 'remainder');
  if (y === 0n) throw new PuffinError('remainder: division by zero');
  return x % y; // BigInt % has the dividend's sign, like Racket remainder
});

// ---- hashes -------------------------------------------------------------------
// read-only accessors take either flavor (like Racket's hash-ref)
function hashView(v, who) {
  if (v instanceof Map) return v;
  if (v instanceof IHash) return v.map;
  throw new PuffinError(`${who}: expected a hash`);
}
function setView(v, who) {
  if (v instanceof Set) return v;
  if (v instanceof ISet) return v.set;
  throw new PuffinError(`${who}: expected a set`);
}

// immutable-by-default collections (copy-on-write; see values.js)
defprim('hash', 0, () => new IHash(new Map()));
defprim('hash-set', 3, (a) => {
  if (!(a[0] instanceof IHash)) throw new PuffinError('hash-set: expected an immutable hash');
  return new IHash(new Map(a[0].map).set(a[1], a[2]));
});
defprim('hash-remove', 2, (a) => {
  if (!(a[0] instanceof IHash)) throw new PuffinError('hash-remove: expected an immutable hash');
  if (!a[0].map.has(a[1])) return a[0];
  const m = new Map(a[0].map);
  m.delete(a[1]);
  return new IHash(m);
});
defprim('set', 0, () => new ISet(new Set()));
defprim('set-add', 2, (a) => {
  if (!(a[0] instanceof ISet)) throw new PuffinError('set-add: expected an immutable set');
  if (a[0].set.has(a[1])) return a[0];
  return new ISet(new Set(a[0].set).add(a[1]));
});
defprim('set-remove', 2, (a) => {
  if (!(a[0] instanceof ISet)) throw new PuffinError('set-remove: expected an immutable set');
  if (!a[0].set.has(a[1])) return a[0];
  const s = new Set(a[0].set);
  s.delete(a[1]);
  return new ISet(s);
});

defprim('make-hash', 0, () => new Map());
defprim('hash-set!', 3, (a) => { wantHash(a[0], 'hash-set!').set(a[1], a[2]); return VOID; });
defprim('hash-ref', 2, (a, ctx) => {
  const h = hashView(a[0], 'hash-ref');
  if (!h.has(a[1])) return halt(ctx, S('hash-ref-key-not-found'));
  return h.get(a[1]);
});
defprim('hash-ref/default', 3, (a) => {
  const h = hashView(a[0], 'hash-ref/default');
  return h.has(a[1]) ? h.get(a[1]) : a[2];
});
defprim('hash-has-key?', 2, (a) => hashView(a[0], 'hash-has-key?').has(a[1]));
defprim('hash-remove!', 2, (a) => { wantHash(a[0], 'hash-remove!').delete(a[1]); return VOID; });
defprim('hash-count', 1, (a) => BigInt(hashView(a[0], 'hash-count').size));
defprim('hash-keys', 1, (a) => {
  let acc = NIL;
  const keys = [...hashView(a[0], 'hash-keys').keys()];
  for (let i = keys.length - 1; i >= 0; i--) acc = new Pair(keys[i], acc);
  return acc;
});
defprim('hash?', 1, (a) => a[0] instanceof Map || a[0] instanceof IHash);

// ---- sets -----------------------------------------------------------------------
defprim('make-set', 0, () => new Set());
defprim('set-add!', 2, (a) => { wantSet(a[0], 'set-add!').add(a[1]); return VOID; });
defprim('set-member?', 2, (a) => setView(a[0], 'set-member?').has(a[1]));
defprim('set-remove!', 2, (a) => { wantSet(a[0], 'set-remove!').delete(a[1]); return VOID; });
defprim('set-count', 1, (a) => BigInt(setView(a[0], 'set-count').size));
defprim('set->list', 1, (a) => {
  let acc = NIL;
  const vals = [...setView(a[0], 'set->list').values()];
  for (let i = vals.length - 1; i >= 0; i--) acc = new Pair(vals[i], acc);
  return acc;
});
defprim('set?', 1, (a) => a[0] instanceof Set || a[0] instanceof ISet);

// ---- bootstrap batch (see docs/BOOTSTRAP.md) --------------------------------
let gensymCounter = 0;
defprim('gensym', 1, (a) => {
  if (typeof a[0] !== 'symbol') throw new PuffinError('gensym: expected a symbol');
  return Symbol.for(`${Symbol.keyFor(a[0])}${++gensymCounter}\u2063`); // invisible separator: fresh vs source symbols
});
defprim('value->string', 1, (a) => new PStr(render(a[0])));
defprim('read-all', 0, (a, ctx) => {
  const rest = ctx.input.slice(ctx.inputPos).map((n) => n.toString()).join(' ');
  ctx.inputPos = ctx.input.length;
  return new PStr(rest);
});

// ---- io: files, argv, subprocesses (browser: virtual file map) --------
// The native runtime reads the real filesystem (lib/io.c); here the
// optional ctx.files map plays the filesystem, so file-driven
// programs (like puffincc) still run in the sandbox.
defprim('read-file', 1, (a, ctx) => {
  const p = wantString(a[0], 'read-file').s;
  if (ctx.files && p in ctx.files) return new PStr(ctx.files[p]);
  throw new PuffinError(`read-file: cannot open ${p} (no filesystem in the web interpreter)`);
});
defprim('write-file', 2, (a, ctx) => {
  if (!ctx.files) throw new PuffinError('write-file: no filesystem in the web interpreter');
  ctx.files[wantString(a[0], 'write-file').s] = wantString(a[1], 'write-file').s;
  return VOID;
});
defprim('file-exists?', 1, (a, ctx) =>
  Boolean(ctx.files && wantString(a[0], 'file-exists?').s in ctx.files));
defprim('command-line-args', 0, (a, ctx) => {
  let l = NIL;
  const args = ctx.args || [];
  for (let i = args.length - 1; i >= 0; i--) l = new Pair(new PStr(args[i]), l);
  return l;
});
defprim('system', 1, () => {
  throw new PuffinError('system: no subprocesses in the web interpreter');
});
defprim('substring', 3, (a) => {
  const s = wantString(a[0], 'substring').s;
  const i = Number(wantInt(a[1], 'substring')), j = Number(wantInt(a[2], 'substring'));
  if (i < 0 || j < i || j > s.length) throw new PuffinError('substring: index out of range');
  return new PStr(s.slice(i, j));
});
defprim('string<?', 2, (a) =>
  wantString(a[0], 'string<?').s < wantString(a[1], 'string<?').s);
defprim('string-byte', 2, (a) => {
  const s = wantString(a[0], 'string-byte').s;
  const i = Number(wantInt(a[1], 'string-byte'));
  if (i < 0 || i >= s.length) throw new PuffinError('string-byte: index out of range');
  return BigInt(s.charCodeAt(i));
});
defprim('number->string', 1, (a) => new PStr(wantInt(a[0], 'number->string').toString()));
defprim('string->number', 1, (a) => {
  const s = wantString(a[0], 'string->number').s;
  return /^-?[0-9]+$/.test(s) ? BigInt(s) : false;
});
defprim('bitwise-and', 2, (a) => wantInt(a[0], 'bitwise-and') & wantInt(a[1], 'bitwise-and'));
defprim('bitwise-ior', 2, (a) => wantInt(a[0], 'bitwise-ior') | wantInt(a[1], 'bitwise-ior'));
defprim('bitwise-xor', 2, (a) => wantInt(a[0], 'bitwise-xor') ^ wantInt(a[1], 'bitwise-xor'));
defprim('arithmetic-shift', 2, (a) => {
  const n = wantInt(a[0], 'arithmetic-shift'), k = wantInt(a[1], 'arithmetic-shift');
  return k >= 0n ? n << k : n >> -k;
});
defprim('modulo', 2, (a) => {
  const x = wantInt(a[0], 'modulo'), y = wantInt(a[1], 'modulo');
  if (y === 0n) throw new PuffinError('modulo: division by zero');
  let r = x % y;
  if (r !== 0n && (r < 0n) !== (y < 0n)) r += y;
  return r;
});

// ---- type predicates ----------------------------------------------------------------
defprim('fixnum?', 1, (a) => typeof a[0] === 'bigint');
defprim('boolean?', 1, (a) => typeof a[0] === 'boolean');
defprim('symbol?', 1, (a) => typeof a[0] === 'symbol');
defprim('void?', 1, (a) => a[0] === VOID);
defprim('procedure?', 1, (a) => a[0] instanceof Closure || a[0] instanceof Native);

// Primitive names that do NOT eta-expand as bare variables (desugar
// excludes list/vector/not; they aren't stdlib prims at all).
const NON_ETA = new Set([S_LIST, S_VECTOR, S_NOT]);

// Comparator sugar handled as forms when unshadowed.
const CMPS = new Set([S_EQ, S_LT, S_LE, S_GT, S_GE]);

// One shared Native per prim (eta-expansion of a bare prim name).
const NATIVE = new Map();
for (const [sym, p] of PRIMS) NATIVE.set(sym, new Native(p.name, p.arity, p.fn));
// Compiler intrinsics eta-expand too, at their intrinsic arities
// (desugar uses prim-arity: binary + * eq? <, unary -).
NATIVE.set(S_ADD, new Native('+', 2, (a) => wantOpInt(S_ADD, a[0]) + wantOpInt(S_ADD, a[1])));
NATIVE.set(S_MUL, new Native('*', 2, (a) => wantOpInt(S_MUL, a[0]) * wantOpInt(S_MUL, a[1])));
NATIVE.set(S_SUB, new Native('-', 1, (a) => -wantOpInt(S_SUB, a[0])));
NATIVE.set(S_EQ, new Native('eq?', 2, (a) => eqv(a[0], a[1])));
NATIVE.set(S_LT, new Native('<', 2, (a) => wantOpInt(S_LT, a[0]) < wantOpInt(S_LT, a[1])));

export function surfacePrimNames() {
  return [...PRIMS.values()].map((p) => p.name);
}

// ---------------------------------------------------------------------
// quoted datum -> value (desugar's quote->expr semantics)
// ---------------------------------------------------------------------

function datumToValue(d) {
  if (typeof d === 'symbol') return d;
  if (typeof d === 'bigint' || typeof d === 'boolean') return d;
  if (Array.isArray(d)) {
    let acc = d.tail !== undefined ? datumToValue(d.tail) : NIL;
    for (let i = d.length - 1; i >= 0; i--) acc = new Pair(datumToValue(d[i]), acc);
    return acc;
  }
  throw new PuffinError(`unsupported quoted datum: ${d instanceof PStr ? JSON.stringify(d.s) : String(d)}`);
}

// ---------------------------------------------------------------------
// The evaluator. Tail positions update expr/env and loop.
// ---------------------------------------------------------------------

function isTaggedList(e, tag) {
  return Array.isArray(e) && e.length > 0 && e[0] === tag && e.tail === undefined;
}

function lookupVariable(x, env) {
  const box = env.lookup(x);
  if (box !== undefined) return box.v;
  const nat = !NON_ETA.has(x) && NATIVE.get(x);
  if (nat) return nat;
  throw new PuffinError(`unbound id ${Symbol.keyFor(x)}`);
}

function truthy(v) { return v !== false; }

function arith(op, args, env, ctx) {
  if (args.length === 0) throw new PuffinError(`${Symbol.keyFor(op)} expects arguments`);
  if (args.length === 1) {
    const v = evalExpr(args[0], env, ctx);
    if (op === S_SUB) return -wantOpInt(op, v);
    return v; // (+ x) / (* x) pass through unchanged, like desugar
  }
  let acc = wantOpInt(op, evalExpr(args[0], env, ctx));
  for (let i = 1; i < args.length; i++) {
    const v = wantOpInt(op, evalExpr(args[i], env, ctx));
    if (op === S_ADD) acc += v;
    else if (op === S_MUL) acc *= v;
    else acc -= v;
  }
  return acc;
}
function wantOpInt(op, v) {
  if (typeof v !== 'bigint')
    throw new PuffinError(`${Symbol.keyFor(op)}: expected an integer, got ${render(v)}`);
  return v;
}

export function evalExpr(expr0, env0, ctx) {
  let expr = expr0;
  let env = env0;

  for (;;) {
    // ---- atoms ----
    const t = typeof expr;
    if (t === 'bigint' || t === 'boolean') return expr;
    if (t === 'symbol') return lookupVariable(expr, env);
    if (expr instanceof PStr) return expr; // string literals are shared (like (string-lit s))
    if (!Array.isArray(expr)) throw new PuffinError(`bad expression: ${String(expr)}`);
    if (expr.tail !== undefined) throw new PuffinError('bad expression: dotted form');
    if (expr.length === 0) throw new PuffinError('bad expression: ()');

    const head = expr[0];

    if (typeof head === 'symbol') {
      switch (head) {
        case S_QUOTE:
          return datumToValue(expr[1]);

        case S_IF: {
          if (expr.length !== 4) throw new PuffinError('if: bad syntax');
          expr = truthy(evalExpr(expr[1], env, ctx)) ? expr[2] : expr[3];
          continue;
        }

        case S_COND: {
          let chosen = null;
          for (let i = 1; i < expr.length; i++) {
            const clause = expr[i];
            if (clause[0] === S_ELSE || truthy(evalExpr(clause[0], env, ctx))) {
              chosen = clause; break;
            }
          }
          if (chosen === null || chosen.length < 2) return VOID;
          expr = bodyToExpr(chosen.slice(1));
          continue;
        }

        case S_WHEN: case S_UNLESS: {
          const g = truthy(evalExpr(expr[1], env, ctx));
          const take = head === S_WHEN ? g : !g;
          if (!take || expr.length < 3) return VOID;
          expr = bodyToExpr(expr.slice(2));
          continue;
        }

        case S_CASE: {
          const k = evalExpr(expr[1], env, ctx);
          let chosen = null;
          for (let i = 2; i < expr.length; i++) {
            const clause = expr[i];
            if (clause[0] === S_ELSE) { chosen = clause; break; }
            // datums compared with eq? against freshly built data
            if (clause[0].some((d) => eqv(k, datumToValue(d)))) { chosen = clause; break; }
          }
          if (chosen === null || chosen.length < 2) return VOID;
          expr = bodyToExpr(chosen.slice(1));
          continue;
        }

        case S_MATCH: {
          const subject = evalExpr(expr[1], env, ctx);
          let done = false;
          for (let i = 2; i < expr.length && !done; i++) {
            const clause = expr[i];
            const pat = clause[0];
            let guard = null, bodyStart = 1;
            if (clause.length > 2 && clause[1] === S_KW_WHEN) { guard = clause[2]; bodyStart = 3; }
            const binds = new Map();
            if (!tryMatch(pat, subject, binds, env, ctx)) continue;
            const frame = new Frame(env);
            for (const [x, v] of binds) frame.vars.set(x, { v });
            if (guard !== null && !truthy(evalExpr(guard, frame, ctx))) continue;
            for (let j = bodyStart; j < clause.length - 1; j++) evalExpr(clause[j], frame, ctx);
            env = frame;
            expr = clause[clause.length - 1];
            done = true;
          }
          if (done) continue;
          return halt(ctx, S('match-failure'));
        }

        case S_LET: {
          if (typeof expr[1] === 'symbol') {
            // named let: a self-referential closure
            const loopName = expr[1];
            const bindings = expr[2];
            const params = bindings.map((b) => b[0]);
            const args = bindings.map((b) => evalExpr(b[1], env, ctx));
            const defFrame = new Frame(env);
            const clo = new Closure(params, expr.slice(3), defFrame, Symbol.keyFor(loopName));
            defFrame.vars.set(loopName, { v: clo });
            const frame = new Frame(defFrame);
            for (let i = 0; i < params.length; i++) frame.vars.set(params[i], { v: args[i] });
            env = frame;
            expr = bodyToExpr(clo.body);
            continue;
          }
          // parallel let: rhs left-to-right, then bind
          const bindings = expr[1];
          const vals = bindings.map((b) => evalExpr(b[1], env, ctx));
          const frame = new Frame(env);
          for (let i = 0; i < bindings.length; i++) frame.vars.set(bindings[i][0], { v: vals[i] });
          env = frame;
          expr = bodyToExpr(expr.slice(2));
          continue;
        }

        case S_LETSTAR: {
          const bindings = expr[1];
          let frame = env;
          for (const b of bindings) {
            const v = evalExpr(b[1], frame, ctx);
            frame = new Frame(frame);
            frame.vars.set(b[0], { v });
          }
          env = frame;
          expr = bodyToExpr(expr.slice(2));
          continue;
        }

        case S_LAMBDA: case S_LAMBDA2: {
          const { fixed, rest } = splitFormals(expr[1]);
          return new Closure(fixed, expr.slice(2), env, undefined, rest);
        }

        case S_QUASIQUOTE:
          return evalQuasiExpr(expr[1], 1, env, ctx);

        case S_LETREC: {
          const frame = new Frame(env);
          for (const b of expr[1]) frame.vars.set(b[0], { v: VOID });
          for (const b of expr[1]) frame.vars.get(b[0]).v = evalExpr(b[1], frame, ctx);
          env = frame;
          expr = bodyToExpr(expr.slice(2));
          continue;
        }

        case S_BEGIN: {
          if (expr.length === 1) return VOID;
          // internal defines: letrec*-scoped over the whole body
          // (mirrors desugar's body->expr)
          if (expr.some((f, i) => i > 0 && (isFunDefine(f) || isValDefine(f)))) {
            const frame = new Frame(env);
            for (let i = 1; i < expr.length; i++) {
              const f = expr[i];
              if (isFunDefine(f)) frame.vars.set(f[1][0], { v: VOID });
              else if (isValDefine(f)) frame.vars.set(f[1], { v: VOID });
            }
            let last = VOID;
            for (let i = 1; i < expr.length; i++) {
              const f = expr[i];
              if (isFunDefine(f)) {
                {
                  const { fixed, rest } = splitFormals(f[1], 1);
                  frame.vars.get(f[1][0]).v =
                    new Closure(fixed, f.slice(2), frame, Symbol.keyFor(f[1][0]), rest);
                }
                last = VOID;
              } else if (isValDefine(f)) {
                frame.vars.get(f[1]).v = evalExpr(f[2], frame, ctx);
                last = VOID;
              } else {
                last = evalExpr(f, frame, ctx);
              }
            }
            return last;
          }
          for (let i = 1; i < expr.length - 1; i++) evalExpr(expr[i], env, ctx);
          expr = expr[expr.length - 1];
          continue;
        }

        case S_WHILE: {
          while (truthy(evalExpr(expr[1], env, ctx))) {
            for (let i = 2; i < expr.length; i++) evalExpr(expr[i], env, ctx);
          }
          return VOID;
        }

        case S_SET: {
          const box = env.lookup(expr[1]);
          if (box === undefined) throw new PuffinError(`unbound id ${Symbol.keyFor(expr[1])}`);
          box.v = evalExpr(expr[2], env, ctx);
          return VOID;
        }

        case S_AND: {
          if (expr.length === 1) return true;
          for (let i = 1; i < expr.length - 1; i++) {
            if (!truthy(evalExpr(expr[i], env, ctx))) return false;
          }
          expr = expr[expr.length - 1];
          continue;
        }

        case S_OR: {
          if (expr.length === 1) return false;
          for (let i = 1; i < expr.length - 1; i++) {
            const v = evalExpr(expr[i], env, ctx);
            if (truthy(v)) return v;
          }
          expr = expr[expr.length - 1];
          continue;
        }

        case S_NOT: {
          if (expr.length !== 2) throw new PuffinError('not: expects 1 argument');
          return evalExpr(expr[1], env, ctx) === false;
        }

        case S_ADD: case S_SUB: case S_MUL:
          return arith(head, expr.slice(1), env, ctx);

        case S_VOIDF:
          if (expr.length === 1) return VOID; // (void) is a form, never shadowed
          break; // (void x): falls through to application (unbound)

        case S_READ:
          if (expr.length === 1) return readInput(ctx); // like (void), unconditional
          break;
      }

      // comparators (shadowable)
      if (CMPS.has(head) && env.lookup(head) === undefined) {
        if (expr.length !== 3)
          throw new PuffinError(`${Symbol.keyFor(head)} expects 2 arguments, got ${expr.length - 1}`);
        const a = evalExpr(expr[1], env, ctx);
        const b = evalExpr(expr[2], env, ctx);
        if (head === S_EQ) return eqv(a, b);
        if (typeof a !== 'bigint' || typeof b !== 'bigint')
          throw new PuffinError(`${Symbol.keyFor(head)}: expected integers, got ${render(a)} and ${render(b)}`);
        switch (head) {
          case S_LT: return a < b;
          case S_LE: return a <= b;
          case S_GT: return a > b;
          case S_GE: return a >= b;
        }
      }

      // n-ary (hash k v ...) / (set v ...) constructors (shadowable);
      // 0-ary calls fall through to the ordinary prims
      if (head === S_HASH && expr.length > 1 && env.lookup(S_HASH) === undefined) {
        if ((expr.length - 1) % 2 !== 0)
          throw new PuffinError('(hash ...) expects an even number of arguments');
        const m = new Map();
        for (let i = 1; i < expr.length; i += 2) {
          const k = evalExpr(expr[i], env, ctx);
          m.set(k, evalExpr(expr[i + 1], env, ctx));
        }
        return new IHash(m);
      }
      if (head === S_SETC && expr.length > 1 && env.lookup(S_SETC) === undefined) {
        const s = new Set();
        for (let i = 1; i < expr.length; i++) s.add(evalExpr(expr[i], env, ctx));
        return new ISet(s);
      }

      // (list ...) / (vector ...) constructors (shadowable)
      if (head === S_LIST && env.lookup(S_LIST) === undefined) {
        const vals = [];
        for (let i = 1; i < expr.length; i++) vals.push(evalExpr(expr[i], env, ctx));
        let acc = NIL;
        for (let i = vals.length - 1; i >= 0; i--) acc = new Pair(vals[i], acc);
        return acc;
      }
      if (head === S_VECTOR && env.lookup(S_VECTOR) === undefined) {
        const v = [];
        for (let i = 1; i < expr.length; i++) v.push(evalExpr(expr[i], env, ctx));
        return v;
      }

      // stdlib prims in operator position (when not shadowed)
      const prim = PRIMS.get(head);
      if (prim !== undefined && env.lookup(head) === undefined) {
        if (expr.length - 1 !== prim.arity)
          throw new PuffinError(
            `${prim.name} expects ${prim.arity} argument${prim.arity === 1 ? '' : 's'}, got ${expr.length - 1}`);
        const args = [];
        for (let i = 1; i < expr.length; i++) args.push(evalExpr(expr[i], env, ctx));
        return prim.fn(args, ctx);
      }
    }

    // ---- application ----
    const f = evalExpr(head, env, ctx);
    const args = [];
    for (let i = 1; i < expr.length; i++) args.push(evalExpr(expr[i], env, ctx));

    if (f instanceof Closure) {
      if (f.rest ? args.length < f.params.length : f.params.length !== args.length)
        throw new PuffinError(
          `arity mismatch: procedure of ${f.rest ? 'at least ' : ''}${f.params.length} argument${f.params.length === 1 ? '' : 's'} applied to ${args.length}`);
      const frame = new Frame(f.env);
      for (let i = 0; i < f.params.length; i++) frame.vars.set(f.params[i], { v: args[i] });
      if (f.rest) {
        let lst = NIL;
        for (let i = args.length - 1; i >= f.params.length; i--) lst = new Pair(args[i], lst);
        frame.vars.set(f.rest, { v: lst });
      }
      env = frame;
      expr = bodyToExpr(f.body);
      continue;
    }
    if (f instanceof Native) {
      if (f.arity !== args.length)
        throw new PuffinError(`${f.name} expects ${f.arity} argument${f.arity === 1 ? '' : 's'}, got ${args.length}`);
      return f.fn(args, ctx);
    }
    throw new PuffinError(`application of a non-procedure: ${render(f)}`);
  }
}

// A multi-form body becomes (begin ...); single forms evaluate directly.
const BODY_BEGIN = new Map(); // cache: body array -> begin form
function bodyToExpr(body) {
  if (body.length === 1) return body[0];
  let cached = BODY_BEGIN.get(body);
  if (cached === undefined) {
    cached = [S_BEGIN, ...body];
    BODY_BEGIN.set(body, cached);
  }
  return cached;
}

// Apply a value in a non-tail context (used by (? pred p) patterns).
export function applyProcedure(f, args, ctx) {
  if (f instanceof Closure) {
    if (f.rest ? args.length < f.params.length : f.params.length !== args.length)
      throw new PuffinError(
        `arity mismatch: procedure of ${f.rest ? 'at least ' : ''}${f.params.length} arguments applied to ${args.length}`);
    const frame = new Frame(f.env);
    for (let i = 0; i < f.params.length; i++) frame.vars.set(f.params[i], { v: args[i] });
    if (f.rest) {
      let lst = NIL;
      for (let i = args.length - 1; i >= f.params.length; i--) lst = new Pair(args[i], lst);
      frame.vars.set(f.rest, { v: lst });
    }
    return evalExpr(bodyToExpr(f.body), frame, ctx);
  }
  if (f instanceof Native) {
    if (f.arity !== args.length)
      throw new PuffinError(`${f.name} expects ${f.arity} arguments, got ${args.length}`);
    return f.fn(args, ctx);
  }
  throw new PuffinError(`application of a non-procedure: ${render(f)}`);
}

// ---------------------------------------------------------------------
// match patterns (semantics of compile-pattern / compile-quasi)
// ---------------------------------------------------------------------

function tryMatch(pat, v, binds, env, ctx) {
  if (pat === S_WILD) return true;
  if (typeof pat === 'symbol') { binds.set(pat, v); return true; }
  if (typeof pat === 'bigint' || typeof pat === 'boolean') return eqv(v, pat);
  if (pat instanceof PStr) return v instanceof PStr && v.s === pat.s;
  if (Array.isArray(pat)) {
    const head = pat[0];
    if (head === S_QUOTE) {
      const d = pat[1];
      if (typeof d === 'symbol') return eqv(v, d);
      return puffinEqual(v, datumToValue(d));
    }
    if (head === S_QUASIQUOTE) return matchQuasi(pat[1], v, binds, env, ctx);
    if (head === S_CONS && pat.length === 3) {
      return v instanceof Pair
        && tryMatch(pat[1], v.car, binds, env, ctx)
        && tryMatch(pat[2], v.cdr, binds, env, ctx);
    }
    if (head === S_LIST) {
      let cur = v;
      for (let i = 1; i < pat.length; i++) {
        if (!(cur instanceof Pair)) return false;
        if (!tryMatch(pat[i], cur.car, binds, env, ctx)) return false;
        cur = cur.cdr;
      }
      return cur === NIL;
    }
    if (head === S_VECTOR) {
      if (!Array.isArray(v) || v.length !== pat.length - 1) return false;
      for (let i = 1; i < pat.length; i++) {
        if (!tryMatch(pat[i], v[i - 1], binds, env, ctx)) return false;
      }
      return true;
    }
    if (head === S_PRED && pat.length === 3) {
      const predSym = pat[1];
      // resolve like a variable (bound names shadow prims)
      const box = env.lookup(predSym);
      let pred;
      if (box !== undefined) pred = box.v;
      else {
        pred = !NON_ETA.has(predSym) && NATIVE.get(predSym);
        if (!pred) throw new PuffinError(`unbound id ${Symbol.keyFor(predSym)}`);
      }
      if (!truthy(applyProcedure(pred, [v], ctx))) return false;
      return tryMatch(pat[2], v, binds, env, ctx);
    }
  }
  throw new PuffinError(`unsupported match pattern: ${renderDatum(pat)}`);
}

// quasiquote EXPRESSIONS: build runtime data with unquote holes
// (depth-aware, splicing at depth 1; mirrors desugar's qq->expr)
function evalQuasiExpr(q, depth, env, ctx) {
  if (Array.isArray(q)) {
    if (q.length === 2 && q[0] === S_UNQUOTE && q.tail === undefined) {
      if (depth === 1) return evalExpr(q[1], env, ctx);
      return new Pair(S_UNQUOTE, new Pair(evalQuasiExpr(q[1], depth - 1, env, ctx), NIL));
    }
    if (q.length === 2 && q[0] === S_QUASIQUOTE && q.tail === undefined) {
      return new Pair(S_QUASIQUOTE, new Pair(evalQuasiExpr(q[1], depth + 1, env, ctx), NIL));
    }
    // evaluate elements LEFT-TO-RIGHT (unquote side effects must run
    // in source order, matching the reference's cons-chain expansion),
    // then build the list back-to-front from the computed values
    const parts = [];   // {splice: bool, value}
    for (let i = 0; i < q.length; i++) {
      const el = q[i];
      if (Array.isArray(el) && el.length === 2 && el[0] === S_UNQUOTE_SPLICING && el.tail === undefined) {
        if (depth === 1) {
          parts.push({ splice: true, value: evalExpr(el[1], env, ctx) });
        } else {
          parts.push({ splice: false,
            value: new Pair(S_UNQUOTE_SPLICING,
                            new Pair(evalQuasiExpr(el[1], depth - 1, env, ctx), NIL)) });
        }
      } else {
        parts.push({ splice: false, value: evalQuasiExpr(el, depth, env, ctx) });
      }
    }
    let acc = q.tail !== undefined ? evalQuasiExpr(q.tail, depth, env, ctx) : NIL;
    for (let i = parts.length - 1; i >= 0; i--) {
      if (parts[i].splice) {
        const items = [];
        let cur = parts[i].value;
        while (cur instanceof Pair) { items.push(cur.car); cur = cur.cdr; }
        for (let j = items.length - 1; j >= 0; j--) acc = new Pair(items[j], acc);
      } else {
        acc = new Pair(parts[i].value, acc);
      }
    }
    return acc;
  }
  if (q instanceof PStr) return q;
  return q; // symbols, bigints, booleans are self-representing data
}

function matchQuasi(q, v, binds, env, ctx) {
  if (Array.isArray(q)) {
    if (q.length === 2 && q[0] === S_UNQUOTE && q.tail === undefined)
      return tryMatch(q[1], v, binds, env, ctx);
    return matchQuasiList(q, 0, v, binds, env, ctx);
  }
  if (typeof q === 'symbol' || typeof q === 'bigint' || typeof q === 'boolean')
    return eqv(v, q);
  throw new PuffinError(`unsupported quasiquote pattern: ${renderDatum(q)}`);
}

// pattern variables of a (quasi) pattern -- needed so zero-element
// ellipsis segments still bind their variables to '()
function quasiPatternVars(q, acc) {
  if (Array.isArray(q)) {
    if (q.length === 2 && q[0] === S_UNQUOTE && q.tail === undefined) {
      patternVarsOf(q[1], acc);
    } else {
      for (const x of q) quasiPatternVars(x, acc);
      if (q.tail !== undefined) quasiPatternVars(q.tail, acc);
    }
  }
  return acc;
}
function patternVarsOf(pat, acc) {
  if (pat === S_WILD) return acc;
  if (typeof pat === 'symbol') { acc.add(pat); return acc; }
  if (!Array.isArray(pat)) return acc;
  const head = pat[0];
  if (head === S_QUOTE) return acc;
  if (head === S_QUASIQUOTE) return quasiPatternVars(pat[1], acc);
  if (head === S_PRED) return patternVarsOf(pat[2], acc);
  for (let i = 1; i < pat.length; i++) patternVarsOf(pat[i], acc);
  return acc;
}

const S_ELLIPSIS = S('...');

function matchQuasiList(q, i, v, binds, env, ctx) {
  if (i === q.length) {
    if (q.tail !== undefined) return matchQuasi(q.tail, v, binds, env, ctx);
    return v === NIL;
  }
  // general ellipsis (Racket-style, mirroring desugar's compile-quasi):
  // q[i] matches each element of a middle segment, its variables
  // collecting per-element lists; fixed-shape patterns after the ...
  // match the tail end. The whole span must be a proper list.
  if (i + 1 < q.length && q[i + 1] === S_ELLIPSIS) {
    const mid = q[i];
    const k = q.length - (i + 2);
    const elems = [];
    let cur = v;
    while (cur instanceof Pair) { elems.push(cur.car); cur = cur.cdr; }
    if (cur !== NIL) return false;
    if (elems.length < k) return false;
    const take = elems.length - k;
    const vars = [...quasiPatternVars(mid, new Set())];
    const acc = new Map(vars.map((x) => [x, []]));
    for (let j = 0; j < take; j++) {
      const tmp = new Map();
      if (!matchQuasi(mid, elems[j], tmp, env, ctx)) return false;
      for (const x of vars) acc.get(x).push(tmp.get(x));
    }
    for (const x of vars) {
      let lst = NIL;
      const collected = acc.get(x);
      for (let j = collected.length - 1; j >= 0; j--) lst = new Pair(collected[j], lst);
      binds.set(x, lst);
    }
    for (let j = 0; j < k; j++) {
      if (!matchQuasi(q[i + 2 + j], elems[take + j], binds, env, ctx)) return false;
    }
    return true;
  }
  return v instanceof Pair
    && matchQuasi(q[i], v.car, binds, env, ctx)
    && matchQuasiList(q, i + 1, v.cdr, binds, env, ctx);
}

// render an AST datum for error messages
function renderDatum(d) {
  if (typeof d === 'symbol') return Symbol.keyFor(d);
  if (typeof d === 'bigint') return d.toString();
  if (typeof d === 'boolean') return d ? '#t' : '#f';
  if (d instanceof PStr) return JSON.stringify(d.s);
  if (Array.isArray(d)) {
    const items = d.map(renderDatum).join(' ');
    return d.tail !== undefined ? `(${items} . ${renderDatum(d.tail)})` : `(${items})`;
  }
  return String(d);
}

// ---------------------------------------------------------------------
// Top-level program driver
// ---------------------------------------------------------------------

export function isFunDefine(f) {
  return isTaggedList(f, S_DEFINE) && Array.isArray(f[1]);
}
export function isValDefine(f) {
  return isTaggedList(f, S_DEFINE) && typeof f[1] === 'symbol';
}

// Bare form sequences, or a single (program forms ...) wrapper.
export function unwrapProgram(forms) {
  if (forms.length === 1 && isTaggedList(forms[0], S_PROGRAM)) return forms[0].slice(1);
  return forms;
}

// Two-pass top level (matching interpret-puffin): cells for every
// top-level name first (function cells filled with their closures
// before anything runs; value cells start at 0), then forms run in
// source order. Returns the last top-level *expression*'s value.
export function evalProgram(forms, global, ctx) {
  for (const f of forms) {
    if (isFunDefine(f)) {
      if (!global.vars.has(f[1][0])) global.define(f[1][0], VOID);
    } else if (isValDefine(f)) {
      if (!global.vars.has(f[1])) global.define(f[1], 0n);
    }
  }
  for (const f of forms) {
    if (isFunDefine(f)) {
      const name = f[1][0];
      {
        const { fixed, rest } = splitFormals(f[1], 1);
        global.define(name, new Closure(fixed, f.slice(2), global, Symbol.keyFor(name), rest));
      }
    }
  }
  let last = VOID;
  for (const f of forms) {
    if (isFunDefine(f)) continue; // closure already installed; `last` unchanged
    if (isValDefine(f)) {
      global.define(f[1], evalExpr(f[2], global, ctx));
      last = VOID;
    } else {
      last = evalExpr(f, global, ctx);
    }
  }
  return last;
}
