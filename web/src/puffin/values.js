// Puffin value representation (mirrors src/stdlib.rkt's reference
// representation):
//   fixnum   -> BigInt (arbitrary precision, like Racket exact integers)
//   boolean  -> JS boolean
//   void     -> the VOID sentinel
//   '()      -> the NIL sentinel
//   symbol   -> Symbol.for(name)  (interned; eqv? === identity)
//   pair     -> Pair
//   vector   -> JS Array (mutable)
//   string   -> PStr wrapper (identity semantics match Racket's mutable
//               strings: two separately-built strings are not eq?)
//   hash     -> JS Map   (keys compared SameValueZero = eqv? for our reps)
//   set      -> JS Set
//   closure  -> Closure / Native

export class Pair {
  constructor(car, cdr) { this.car = car; this.cdr = cdr; }
}

export class PStr {
  constructor(s) { this.s = s; }
}

export class Closure {
  constructor(params, body, env, name) {
    this.params = params;   // array of JS symbols
    this.body = body;       // array of body forms (implicit begin)
    this.env = env;
    this.name = name || null;
  }
}

export class Native {
  constructor(name, arity, fn) {
    this.name = name; this.arity = arity; this.fn = fn;
  }
}

export const VOID = { puffin: 'void' };
export const NIL = { puffin: 'nil' };

// Immutable collections (the language default; see src/stdlib.rkt and
// src/runtime/lib/hamt.c). Copy-on-write wrappers over Map/Set: each
// hash-set/set-add copies -- O(n) rather than the native HAMT's
// O(log n), acceptable at REPL scale and semantically identical.
export class IHash { constructor(map) { this.map = map; } }
export class ISet { constructor(set) { this.set = set; } }

// (error v) prints and halts the program (like the native exit(1)).
export class PuffinHalt {
  constructor() { this.halt = true; }
}

// Any other runtime error (unbound id, non-procedure application, ...).
export class PuffinError extends Error {
  constructor(msg) { super(msg); this.name = 'PuffinError'; }
}

// eqv? over the reference representation: BigInt/boolean compare by
// value (=== does this for primitives), everything else by identity.
export function eqv(a, b) { return a === b; }

// equal? in Puffin: structural over pairs/vectors/strings, identity
// otherwise (matches puffin-equal? in src/stdlib.rkt).
export function puffinEqual(a, b) {
  if (a === b) return true;
  if (a instanceof Pair && b instanceof Pair)
    return puffinEqual(a.car, b.car) && puffinEqual(a.cdr, b.cdr);
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++)
      if (!puffinEqual(a[i], b[i])) return false;
    return true;
  }
  if (a instanceof PStr && b instanceof PStr) return a.s === b.s;
  // immutable collections are values: compare by contents
  if (a instanceof IHash && b instanceof IHash) {
    if (a.map.size !== b.map.size) return false;
    for (const [k, v] of a.map) {
      if (!b.map.has(k) || !puffinEqual(v, b.map.get(k))) return false;
    }
    return true;
  }
  if (a instanceof ISet && b instanceof ISet) {
    if (a.set.size !== b.set.size) return false;
    for (const k of a.set) if (!b.set.has(k)) return false;
    return true;
  }
  return false;
}

// render-value, byte-for-byte with src/stdlib.rkt.
export function render(v) {
  if (typeof v === 'bigint') return v.toString();
  if (v === true) return '#t';
  if (v === false) return '#f';
  if (v === VOID) return '#<void>';
  if (v === NIL) return '()';
  if (typeof v === 'symbol') return Symbol.keyFor(v) ?? v.description;
  if (v instanceof PStr) return v.s;
  if (v instanceof Pair) {
    let out = '(' + render(v.car);
    let rest = v.cdr;
    for (;;) {
      if (rest instanceof Pair) { out += ' ' + render(rest.car); rest = rest.cdr; }
      else if (rest === NIL) break;
      else { out += ' . ' + render(rest); break; }
    }
    return out + ')';
  }
  if (Array.isArray(v)) return '#(' + v.map(render).join(' ') + ')';
  if (v instanceof Map) return `#<hash:${v.size}>`;
  if (v instanceof Set) return `#<set:${v.size}>`;
  if (v instanceof IHash) return `#<hash:${v.map.size}>`;
  if (v instanceof ISet) return `#<set:${v.set.size}>`;
  return '#<procedure>';
}
