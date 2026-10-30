// The token rules of puffincc's reader (puffincc-src/reader.puf), as far as
// the studio needs them: where comments, strings and brackets are, so that a
// bracket inside a string or comment is never taken for structure.
//
//   ;…             a comment, to the end of the line
//   "…"            a string; it may span lines, a backslash escapes the next
//                  character
//   ( ) [ ]        brackets
//   ' ` , ,@       prefixes: quote, quasiquote, unquote, unquote-splicing
//   a word         any other run of non-delimiter characters: a symbol, a
//                  number, #t, #:keyword
//
// A string with no closing quote runs to the end of the text and is marked
// `open`, so a half-typed program still tokenizes.

const SPACE = /\s/;

export const OPENERS = "([";
export const CLOSERS = ")]";
export const closerOf = (open) => CLOSERS[OPENERS.indexOf(open)];

// [{ kind, start, end, open? }], kind one of "comment", "string", "prefix",
// "open", "close" and "word"; whitespace is not a token.
export function tokens(text) {
  const found = [];
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    const start = i;
    if (SPACE.test(c)) {
      i++;
      continue;
    }
    if (c === ";") {
      while (i < text.length && text[i] !== "\n") i++;
      found.push({ kind: "comment", start, end: i });
    } else if (c === "\"") {
      for (i++; i < text.length && text[i] !== "\""; i += text[i] === "\\" ? 2 : 1);
      const closed = i < text.length;
      i = Math.min(i + 1, text.length);
      found.push({ kind: "string", start, end: i, open: !closed });
    } else if (c === "'" || c === "`") {
      found.push({ kind: "prefix", start, end: ++i });
    } else if (c === ",") {
      i += text[i + 1] === "@" ? 2 : 1;
      found.push({ kind: "prefix", start, end: i });
    } else if (OPENERS.includes(c)) {
      found.push({ kind: "open", start, end: ++i });
    } else if (CLOSERS.includes(c)) {
      found.push({ kind: "close", start, end: ++i });
    } else {
      i = wordEnd(text, i);
      found.push({ kind: "word", start, end: i });
    }
  }
  return found;
}

// A word stops at space, a bracket, a quote, or a comment.
function wordEnd(text, i) {
  for (; i < text.length; i++) {
    const c = text[i];
    if (SPACE.test(c) || OPENERS.includes(c) || CLOSERS.includes(c) || c === "\"" || c === ";") break;
  }
  return i;
}

// The top-level forms of `text`: [{ start, end, line, endLine, head, name }],
// offsets into the text, lines 1-based. A prefix starts the form it quotes.
export function forms(text) {
  const lineAt = lineIndex(text);
  const found = [];
  let depth = 0;
  let current = null;
  let prefix = null;
  let child = 0;
  for (const token of tokens(text)) {
    if (token.kind === "comment") continue;
    if (token.kind === "prefix") {
      if (depth === 0 && prefix === null) prefix = token.start;
      continue;
    }
    if (token.kind === "open") {
      if (depth === 0) {
        current = { start: prefix ?? token.start, end: text.length, head: null, name: null };
        prefix = null;
        child = 0;
      } else if (depth === 1) child++;
      depth++;
    } else if (token.kind === "close") {
      if (depth === 0) continue;
      depth--;
      if (depth === 0 && current) {
        current.end = token.end;
        found.push(current);
        current = null;
      }
    } else if (depth === 0) {
      found.push({ start: prefix ?? token.start, end: token.end, head: null, name: null });
      prefix = null;
    } else if (depth === 1 && current) {
      child++;
      const word = text.slice(token.start, token.end);
      if (child === 1) current.head = word;
      else if (child === 2) current.name = word;
    } else if (depth === 2 && current && child === 2 && !current.name) {
      current.name = text.slice(token.start, token.end);
    }
  }
  if (current) found.push(current);
  for (const form of found) {
    form.line = lineAt(form.start).line;
    form.endLine = lineAt(Math.max(form.start, form.end - 1)).line;
  }
  return found;
}

// The form whose span holds `offset`, or ends just before it, or null.
export function formAt(found, offset) {
  return found.find((form) => form.start <= offset && offset <= form.end) ?? null;
}

// offset -> { line, column }, both 1-based.
export function lineIndex(text) {
  const starts = [0];
  for (let i = 0; i < text.length; i++) if (text[i] === "\n") starts.push(i + 1);
  return (offset) => {
    let low = 0;
    let high = starts.length - 1;
    while (low < high) {
      const mid = (low + high + 1) >> 1;
      if (starts[mid] <= offset) low = mid; else high = mid - 1;
    }
    return { line: low + 1, column: offset - starts[low] + 1 };
  };
}

// Brackets outside strings and comments all close, and every string ends.
export function balanced(text) {
  let depth = 0;
  for (const token of tokens(text)) {
    if (token.kind === "open") depth++;
    else if (token.kind === "close" && --depth < 0) return false;
    else if (token.kind === "string" && token.open) return false;
  }
  return depth === 0;
}
