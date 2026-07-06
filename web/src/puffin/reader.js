// Puffin s-expression reader.
//
// Produces JS datums:
//   BigInt            fixnums
//   true/false        #t / #f
//   Symbol.for(name)  identifiers (including #:when keywords)
//   PStr              string literals
//   Array             lists ((a b . c) is stored as [a, b] with .tail = c)
//
// Handles ;-to-end-of-line comments and the quote family sugar:
//   'x -> (quote x)   `x -> (quasiquote x)
//   ,x -> (unquote x) ,@x -> (unquote-splicing x)

import { PStr, PuffinError } from './values.js';

export class ReadError extends Error {
  constructor(msg) { super(msg); this.name = 'ReadError'; }
}

const DELIMS = new Set(['(', ')', '[', ']', ';', '"', "'", '`', ',']);

function tokenize(src) {
  const toks = [];
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    if (c === ' ' || c === '\t' || c === '\n' || c === '\r' || c === '\f') { i++; continue; }
    if (c === ';') { while (i < n && src[i] !== '\n') i++; continue; }
    if (c === '(' || c === ')' || c === '[' || c === ']') { toks.push({ t: c }); i++; continue; }
    if (c === "'") { toks.push({ t: 'quote' }); i++; continue; }
    if (c === '`') { toks.push({ t: 'quasiquote' }); i++; continue; }
    if (c === ',') {
      if (src[i + 1] === '@') { toks.push({ t: 'unquote-splicing' }); i += 2; }
      else { toks.push({ t: 'unquote' }); i++; }
      continue;
    }
    if (c === '"') {
      i++;
      let s = '';
      for (;;) {
        if (i >= n) throw new ReadError('unterminated string literal');
        const ch = src[i];
        if (ch === '"') { i++; break; }
        if (ch === '\\') {
          const e = src[i + 1];
          if (e === 'n') s += '\n';
          else if (e === 't') s += '\t';
          else if (e === 'r') s += '\r';
          else if (e === '\\') s += '\\';
          else if (e === '"') s += '"';
          else throw new ReadError(`unknown string escape: \\${e}`);
          i += 2;
        } else { s += ch; i++; }
      }
      toks.push({ t: 'str', v: s });
      continue;
    }
    // atom token: read until delimiter/whitespace
    let j = i;
    while (j < n && !/\s/.test(src[j]) && !DELIMS.has(src[j])) j++;
    const text = src.slice(i, j);
    i = j;
    toks.push({ t: 'atom', v: text });
  }
  return toks;
}

function atomToDatum(text) {
  if (text === '#t' || text === '#true') return true;
  if (text === '#f' || text === '#false') return false;
  if (/^[+-]?[0-9]+$/.test(text)) return BigInt(text);
  if (text.startsWith('#') && !text.startsWith('#:'))
    throw new ReadError(`unsupported # syntax: ${text}`);
  if (text === '.') throw new ReadError('unexpected .');
  return Symbol.for(text);
}

class Parser {
  constructor(toks) { this.toks = toks; this.pos = 0; }
  peek() { return this.toks[this.pos]; }
  next() { return this.toks[this.pos++]; }

  parseDatum() {
    const tok = this.next();
    if (!tok) throw new ReadError('unexpected end of input');
    switch (tok.t) {
      case '(': case '[':
        return this.parseList(tok.t === '(' ? ')' : ']');
      case ')': case ']':
        throw new ReadError(`unexpected ${tok.t}`);
      case 'quote': case 'quasiquote': case 'unquote': case 'unquote-splicing':
        return [Symbol.for(tok.t), this.parseDatum()];
      case 'str':
        return new PStr(tok.v);
      case 'atom':
        return atomToDatum(tok.v);
      default:
        throw new ReadError(`unexpected token: ${tok.t}`);
    }
  }

  parseList(close) {
    const items = [];
    for (;;) {
      const tok = this.peek();
      if (!tok) throw new ReadError('unexpected end of input: missing ' + close);
      if (tok.t === ')' || tok.t === ']') {
        if (tok.t !== close) throw new ReadError(`mismatched bracket: expected ${close}, got ${tok.t}`);
        this.next();
        return items;
      }
      if (tok.t === 'atom' && tok.v === '.') {
        if (items.length === 0) throw new ReadError('unexpected .');
        this.next();
        const tail = this.parseDatum();
        const end = this.next();
        if (!end || (end.t !== ')' && end.t !== ']'))
          throw new ReadError('expected close bracket after dotted tail');
        if (end.t !== close) throw new ReadError(`mismatched bracket: expected ${close}, got ${end.t}`);
        items.tail = tail;
        return items;
      }
      items.push(this.parseDatum());
    }
  }
}

// Read every form in the source text.
export function readAll(src) {
  const p = new Parser(tokenize(src));
  const forms = [];
  while (p.peek() !== undefined) forms.push(p.parseDatum());
  return forms;
}
