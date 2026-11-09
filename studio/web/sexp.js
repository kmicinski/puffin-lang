// Puffin text as a tree of S-expressions, and the paredit operations over
// it. Ported from Slog Studio's sexp.js: Puffin has `;` comments, no refs,
// and quote prefixes, which motion skips as it skips comments.
//
// The tree is built from lexer.js's tokens and keeps exact offsets. It
// tolerates unbalanced text, since an editor is mid-edit most of the time:
// a list missing its closer runs to the end of the text, a closer with no
// opener is a "stray", and every such defect counts as a fault.
//
// Each operation is a pure function (text, selection) -> { text, selection }
// on offsets, a selection being { start, end } with start <= end. It returns
// null when the editor's own behaviour is right (a plain character in a
// word), and the text unchanged when it refuses. None adds a fault: an edit
// that would unbalance the text is refused.

import { closerOf, forms, tokens } from "./lexer.js";

// Node: { kind, start, end, parent }, kind one of
//   "root", "list"           with `children`; a list also has `closed`, and
//                            `mismatched` when its closer is of another kind
//   "word", "string"         the S-expressions that are not lists; a string
//                            has `open` when no quote closes it
//   "comment", "prefix", "stray"  none: skipped by motion
// The root has `faults`: unclosed lists, strays, closers of the wrong kind,
// and unterminated strings.
export function parse(text) {
  const root = { kind: "root", start: 0, end: text.length, parent: null, children: [], faults: 0 };
  let list = root;
  for (const token of tokens(text)) {
    const { kind, start, end } = token;
    if (kind === "open") {
      const node = { kind: "list", start, end: text.length, parent: list, children: [], closed: false };
      list.children.push(node);
      list = node;
    } else if (kind === "close" && list === root) {
      root.children.push({ kind: "stray", start, end, parent: root });
      root.faults++;
    } else if (kind === "close") {
      const mismatched = text[start] !== closerOf(text[list.start]);
      if (mismatched) root.faults++;
      Object.assign(list, { end, closed: true, mismatched });
      list = list.parent;
    } else if (kind === "string") {
      list.children.push({ kind, start, end, parent: list, open: token.open });
      if (token.open) root.faults++;
    } else {
      list.children.push({ kind, start, end, parent: list });
    }
  }
  for (; list !== root; list = list.parent) root.faults++;
  return root;
}

const isSexp = (node) => node.kind !== "comment" && node.kind !== "stray" && node.kind !== "prefix";
const sexps = (list) => list.children.filter(isSexp);
const empty = (list) => list.children.length === 0;
// A list whose brackets match: the only kind paredit rearranges.
const closed = (node) => node.kind === "list" && node.closed && !node.mismatched;

// The innermost list whose inside contains `pos` (just after its opener up
// to just before its closer), or the root.
export function enclosing(root, pos) {
  for (let list = root; ;) {
    const inner = list.children.find((child) =>
      child.kind === "list" && child.start < pos && (child.closed ? pos < child.end : pos <= child.end));
    if (!inner) return list;
    list = inner;
  }
}

// The string or comment that `pos` is inside, where typing is text and
// not structure, or null. The end of a comment is inside it: a character
// typed there joins the comment.
export function leafAt(root, pos) {
  return enclosing(root, pos).children.find((child) => {
    if (child.kind === "comment") return child.start < pos && pos <= child.end;
    if (child.kind === "string") {
      return child.start < pos && (pos < child.end || (pos === child.end && child.open));
    }
    return false;
  }) ?? null;
}

// The S-expression of `list` at `pos`: the one `pos` is in or starts, else
// the one ending at `pos`, else the next one; or null.
export function sexpAt(list, pos) {
  const all = sexps(list);
  return all.find((s) => s.start <= pos && pos < s.end)
    ?? all.find((s) => s.end === pos)
    ?? all.find((s) => s.start > pos)
    ?? null;
}

// Whether `start`..`end` holds whole S-expressions, so it can be deleted or
// wrapped without breaking any.
export function balancedRegion(text, start, end, root = parse(text)) {
  return !leafAt(root, start) && !leafAt(root, end) && parse(text.slice(start, end)).faults === 0;
}

// Edits ------------------------------------------------------------------

// Apply non-overlapping changes [{ start, end, insert, push }] (offsets into
// `text`) and map `selection` through them: a position in a replaced range
// moves to its start, and a position where text is inserted stays before
// the text, unless the insertion `push`es it past.
function change(text, changes, selection) {
  const sorted = [...changes].sort((a, b) => a.start - b.start);
  const map = (pos) => {
    let shift = 0;
    for (const { start, end, insert = "", push } of sorted) {
      if (pos < start || (pos === start && !(push && start === end))) break;
      if (pos < end) return start + shift;
      shift += insert.length - (end - start);
    }
    return pos + shift;
  };
  let out = text;
  for (const { start, end, insert = "" } of [...sorted].reverse()) out = out.slice(0, start) + insert + out.slice(end);
  return { text: out, selection: { start: map(selection.start), end: map(selection.end) } };
}

const cursor = (pos) => ({ start: pos, end: pos });
const same = (text, selection) => ({ text, selection });

// Where a character typed at `pos` lands: in "code", in "text" (a string
// or comment, where brackets are plain characters), or "nowhere": between a
// backslash and the character it escapes.
function landing(text, root, pos) {
  const leaf = leafAt(root, pos);
  if (!leaf) return "code";
  const split = leaf.kind !== "comment" && escapeAt(text, leaf, pos - 1)?.start === pos - 1;
  return split ? "nowhere" : "text";
}

// The escape sequence (a backslash and the character after it) of the
// string `leaf` that holds the character at `at`, or null.
function escapeAt(text, leaf, at) {
  for (let i = leaf.start + 1; i < leaf.end && i <= at; i++) {
    if (text[i] !== "\\") continue;
    if (at < i + 2) return { start: i, end: i + 2 };
    i++;
  }
  return null;
}

// Typing ----------------------------------------------------------------

// `insert` in place of the selection, the cursor `at` characters into it.
const typed = (text, { start, end }, insert, at = insert.length) =>
  ({ text: text.slice(0, start) + insert + text.slice(end), selection: cursor(start + at) });

// A pair of brackets or quotes typed at `pos`, with the spaces it needs to
// stay a separate token: after a word, a closer or a closing quote, but not
// after a prefix (`'`, `,@`, `#`); and before anything but space or a closer.
function pair(text, pos, open, close) {
  const before = pos > 0 && !/[\s(['`,@#]/.test(text[pos - 1]) ? " " : "";
  const after = pos < text.length && !/[\s)\]]/.test(text[pos]) ? " " : "";
  return typed(text, cursor(pos), before + open + close + after, before.length + 1);
}

// `(` or `[`: a balanced pair, or the selection wrapped in one.
function insertOpen(text, selection, open) {
  const where = landing(text, parse(text), selection.start);
  if (where !== "code") return where === "text" ? null : same(text, selection);
  if (selection.start !== selection.end) return wrap(text, selection, open);
  return pair(text, selection.start, open, closerOf(open));
}

// `)` or `]`: move past the enclosing list's closer, dropping the space
// before it; close a list that has no closer; refuse at the top level.
function insertClose(text, selection) {
  const root = parse(text);
  const pos = selection.end;
  const where = landing(text, root, pos);
  if (where !== "code") return where === "text" ? null : same(text, selection);
  const list = enclosing(root, pos);
  if (list === root) return same(text, selection);
  if (!list.closed) return typed(text, cursor(pos), closerOf(text[list.start]));
  const closer = list.end - 1;
  const last = list.children.at(-1);
  const from = !last ? list.start + 1 : last.kind === "comment" ? closer : last.end;
  if (pos < from || !/^\s*$/.test(text.slice(from, closer))) return same(text, cursor(list.end));
  return change(text, [{ start: from, end: closer }], cursor(list.end));
}

// `"`: a balanced pair in code, or the selection quoted; the closing quote
// typed over; an escaped quote inside a string.
function insertQuote(text, selection) {
  const root = parse(text);
  const { start, end } = selection;
  const where = landing(text, root, start);
  if (where === "nowhere") return same(text, selection);
  if (where === "text") {
    const leaf = leafAt(root, start);
    if (leaf.kind !== "string" || leaf.open) return null;
    if (start === leaf.end - 1) return same(text, cursor(start + 1));
    return typed(text, selection, "\\\"");
  }
  if (start === end) return pair(text, start, "\"", "\"");
  const inner = text.slice(start, end);
  if (/["\\\n]/.test(inner) || !balancedRegion(text, start, end, root)) return same(text, selection);
  return { ...typed(text, selection, `"${inner}"`), selection: { start: start + 1, end: end + 1 } };
}

// `;` in code starts a comment, which would swallow the rest of the line;
// if the rest holds structure it moves to the next line.
function insertSemicolon(text, selection) {
  const root = parse(text);
  const where = landing(text, root, selection.start);
  if (where !== "code") return where === "text" ? null : same(text, selection);
  return parse(typed(text, selection, ";").text).faults <= root.faults ? null : typed(text, selection, ";\n", 1);
}

// Deleting -----------------------------------------------------------------

// Backspace (direction -1) or Delete (+1).
function remove(text, selection, direction) {
  const root = parse(text);
  const { start, end } = selection;
  if (start !== end) return balancedRegion(text, start, end, root) ? null : same(text, selection);
  const pos = start;
  const target = direction < 0 ? pos - 1 : pos;
  if (target < 0 || target >= text.length) return null;
  // the plain deletion, left to the editor unless it adds a fault
  const plain = () =>
    parse(text.slice(0, target) + text.slice(target + 1)).faults <= root.faults ? null : same(text, selection);
  const deleteNode = (node) => change(text, [{ start: node.start, end: node.end }], cursor(node.start));

  const leaf = leafAt(root, pos);
  if (leaf?.kind === "comment") return plain();
  if (leaf) {
    if (target === leaf.start || (!leaf.open && target === leaf.end - 1)) {
      if (leaf.open) return plain();
      return leaf.end - leaf.start === 2 ? deleteNode(leaf) : same(text, selection);
    }
    const escape = escapeAt(text, leaf, target);
    return escape ? change(text, [escape], cursor(escape.start)) : null;
  }

  // The list or string whose delimiter is the character deleted: the
  // enclosing list itself, or one of its children.
  const list = enclosing(root, pos);
  const node = [list, ...list.children].find((n) => {
    if (n.kind === "list") return n.start === target || (n.closed && n.end - 1 === target);
    return n.kind === "string" && (n.start === target || n.end - 1 === target);
  });
  if (!node || (node.kind === "list" ? !closed(node) : node.open)) return plain();
  if (node.kind === "list" ? empty(node) : node.end - node.start === 2) return deleteNode(node);
  // toward the node's inside the cursor moves in; the other way, nothing
  const into = direction < 0 ? target === node.end - 1 : target === node.start;
  return same(text, into ? cursor(pos + direction) : selection);
}

const deleteBackward = (text, selection) => remove(text, selection, -1);
const deleteForward = (text, selection) => remove(text, selection, +1);

// Slurp and barf ---------------------------------------------------------

// The S-expression after (direction +1) or before (-1) `node` among its
// siblings, or null.
function sibling(node, direction) {
  const all = sexps(node.parent);
  return all[all.indexOf(node) + direction] ?? null;
}

// The list at `pos` with a neighbour to take in, and that neighbour,
// climbing out of lists that have none: (a ((b|)) c) slurps c into ((b)).
function slurpable(root, pos, direction) {
  for (let list = enclosing(root, pos); list !== root; list = list.parent) {
    if (!closed(list)) return null;
    const next = sibling(list, direction);
    if (next) return { list, next };
  }
  return null;
}

// Move the closer past the next S-expression: (a|) b -> (a| b).
function slurpForward(text, selection) {
  const found = slurpable(parse(text), selection.start, +1);
  if (!found) return same(text, selection);
  const { list, next } = found;
  const closer = list.end - 1;
  // an empty list takes the S-expression without the space before it
  const from = empty(list) && /^\s*$/.test(text.slice(list.end, next.start)) ? next.start : list.end;
  return change(text, [{ start: closer, end: from }, { start: next.end, end: next.end, insert: text[closer] }], selection);
}

// Move the opener before the previous S-expression: a (|b) -> (a |b).
function slurpBackward(text, selection) {
  const found = slurpable(parse(text), selection.start, -1);
  if (!found) return same(text, selection);
  const { list, next: previous } = found;
  const from = empty(list) && /^\s*$/.test(text.slice(previous.end, list.start)) ? previous.end : list.start;
  return change(text, [
    { start: previous.start, end: previous.start, insert: text[list.start] },
    { start: from, end: list.start + 1 },
  ], selection);
}

// Move the closer before the last S-expression: (a |b) -> (a |) b.
function barfForward(text, selection) {
  const list = enclosing(parse(text), selection.start);
  const all = closed(list) ? sexps(list) : [];
  if (!all.length) return same(text, selection);
  const close = text[list.end - 1];
  const drop = { start: list.end - 1, end: list.end };
  if (all.length > 1) return change(text, [{ start: all.at(-2).end, end: all.at(-2).end, insert: close }, drop], selection);
  // the last one out leaves an empty list and a space before it
  const space = all[0].start === list.start + 1 ? " " : "";
  return change(text, [{ start: list.start + 1, end: list.start + 1, insert: close + space }, drop], selection);
}

// Move the opener after the first S-expression: (a |b) -> a (|b).
function barfBackward(text, selection) {
  const list = enclosing(parse(text), selection.start);
  const all = closed(list) ? sexps(list) : [];
  if (!all.length) return same(text, selection);
  const open = text[list.start];
  const drop = { start: list.start, end: list.start + 1 };
  if (all.length > 1) return change(text, [drop, { start: all[1].start, end: all[1].start, insert: open }], selection);
  // the last one out leaves an empty list, the cursor still inside it
  const closer = list.end - 1;
  const space = all[0].end === closer ? " " : "";
  return change(text, [drop, { start: closer, end: closer, insert: space + open, push: true }], selection);
}

// Splice, raise, wrap, split, join, kill ---------------------------------

// Remove the enclosing list's brackets: (a (b| c) d) -> (a b| c d).
function splice(text, selection) {
  const list = enclosing(parse(text), selection.start);
  if (!closed(list)) return same(text, selection);
  return change(text, [{ start: list.start, end: list.start + 1 }, { start: list.end - 1, end: list.end }], selection);
}

// Replace the enclosing list with the S-expression at the cursor:
// (a (b |c d)) -> (a |c).
function raise(text, selection) {
  const list = enclosing(parse(text), selection.start);
  const node = closed(list) ? sexpAt(list, selection.start) : null;
  if (!node) return same(text, selection);
  const offset = Math.max(0, Math.min(selection.start, node.end) - node.start);
  return {
    text: text.slice(0, list.start) + text.slice(node.start, node.end) + text.slice(list.end),
    selection: cursor(list.start + offset),
  };
}

// Wrap the selection, or the S-expression at the cursor, in a new list:
// |a -> (|a).
function wrap(text, selection, open = "(") {
  const root = parse(text);
  const close = closerOf(open);
  const { start, end } = selection;
  if (start !== end) {
    if (!balancedRegion(text, start, end, root)) return same(text, selection);
    return { text: text.slice(0, start) + open + text.slice(start, end) + close + text.slice(end), selection: { start: start + 1, end: end + 1 } };
  }
  if (leafAt(root, start)?.kind === "comment") return same(text, selection);
  const node = sexpAt(enclosing(root, start), start);
  if (!node) return pair(text, start, open, close);
  return { text: text.slice(0, node.start) + open + text.slice(node.start, node.end) + close + text.slice(node.end), selection: cursor(node.start + 1) };
}

// Split the enclosing list, or string, at the cursor:
// (a b| c) -> (a b)| (c), "ab|c" -> "ab"| "c".
function split(text, selection) {
  const root = parse(text);
  const pos = selection.start;
  const leaf = leafAt(root, pos);
  if (leaf) {
    const splittable = leaf.kind === "string" && !leaf.open && escapeAt(text, leaf, pos - 1)?.start !== pos - 1;
    return splittable ? { text: text.slice(0, pos) + "\" \"" + text.slice(pos), selection: cursor(pos + 1) } : same(text, selection);
  }
  const list = enclosing(root, pos);
  if (!closed(list)) return same(text, selection);
  let from = pos;
  let to = pos;
  while (/[ \t]/.test(text[from - 1])) from--;
  while (/[ \t]/.test(text[to])) to++;
  const open = text[list.start];
  return { text: text.slice(0, from) + closerOf(open) + " " + open + text.slice(to), selection: cursor(from + 1) };
}

// Join the lists, or strings, either side of the cursor:
// (a b)| (c) -> (a b| c), "ab"| "c" -> "ab|c".
function join(text, selection) {
  const root = parse(text);
  const pos = selection.start;
  if (leafAt(root, pos)) return same(text, selection);
  const all = sexps(enclosing(root, pos));
  const before = all.findLast((s) => s.end <= pos);
  const after = all.find((s) => s.start >= pos);
  if (!before || !after) return same(text, selection);
  const gap = text.slice(before.end, after.start);
  const joined = cursor(before.end - 1);
  if (closed(before) && closed(after) && text[before.start] === text[after.start]) {
    return change(text, [{ start: before.end - 1, end: before.end }, { start: after.start, end: after.start + 1, insert: gap ? "" : " " }], joined);
  }
  if (before.kind === "string" && after.kind === "string" && !before.open && !after.open && /^\s*$/.test(gap)) {
    return change(text, [{ start: before.end - 1, end: after.start + 1 }], joined);
  }
  return same(text, selection);
}

// Emacs's paredit-kill: delete to the end of the line, respecting
// delimiters. Inside a list the kill stops at the list's closer, so C-k on
// one match clause takes that clause and never the clauses below it; an
// S-expression that starts on the line and runs past it goes whole; in a
// string, to the end of the line but never past the closing quote; a
// comment, to its end. At the end of a line, the newline.
function kill(text, selection) {
  const root = parse(text);
  // inside an escape, from its first character
  const pos = selection.start - (landing(text, root, selection.start) === "nowhere" ? 1 : 0);
  const leaf = leafAt(root, pos);
  const list = enclosing(root, pos);
  const newline = text.indexOf("\n", pos);
  let end = newline < 0 ? text.length : newline;
  if (leaf) {
    const close = leaf.kind === "comment" || leaf.open ? leaf.end : leaf.end - 1;
    end = Math.min(end, close);
  } else {
    if (list !== root) {
      if (!closed(list)) return same(text, selection);
      end = Math.min(end, list.end - 1);
    }
    for (const child of list.children) {
      const whole = child.kind === "list" ? closed(child) : !child.open;
      if (whole && child.start >= pos && child.start < end) end = Math.max(end, child.end);
    }
  }
  if (end === pos && text[pos] === "\n") end++;
  return change(text, [{ start: pos, end: Math.max(pos, end) }], cursor(pos));
}

// Selection and motion -----------------------------------------------------

// The ranges around a selection: each node holding it, a list's inside
// besides the whole list, the top-level form, and the whole text.
function rangesAround(text, root, { start, end }) {
  const ranges = [];
  for (let list = root; ;) {
    const child = list.children.find((c) => c.start <= start && end <= c.end && c.kind !== "stray");
    if (!child) break;
    ranges.push(child);
    if (child.kind !== "list") break;
    if (child.children.length) ranges.push({ start: child.children[0].start, end: child.children.at(-1).end });
    list = child;
  }
  const form = forms(text).find((f) => f.start <= start && end <= f.end);
  if (form) ranges.push({ start: form.start, end: form.end });
  ranges.push({ start: 0, end: text.length });
  return ranges;
}

// Select the smallest S-expression, list inside or form strictly larger
// than the selection.
function expandSelection(text, selection) {
  const { start, end } = selection;
  const larger = rangesAround(text, parse(text), selection)
    .filter((r) => r.start <= start && end <= r.end && r.end - r.start > end - start)
    .sort((a, b) => (a.end - a.start) - (b.end - b.start));
  return same(text, larger.length ? { start: larger[0].start, end: larger[0].end } : selection);
}

// The step back from expandSelection, without its history: a list to its
// inside, several S-expressions to the first, anything else to its start.
function contractSelection(text, selection) {
  const { start, end } = selection;
  if (start === end) return same(text, selection);
  const list = enclosing(parse(text), start);
  const covered = list.children.filter((c) => isSexp(c) && start <= c.start && c.end <= end);
  const [first] = covered;
  if (covered.length === 1 && first.start === start && first.end === end && first.kind === "list" && first.children.length) {
    return same(text, { start: first.children[0].start, end: first.children.at(-1).end });
  }
  if (covered.length > 1) return same(text, { start: first.start, end: first.end });
  return same(text, cursor(start));
}

// To the end of the next S-expression, or out past the enclosing closer.
function forwardSexp(text, selection) {
  const pos = selection.end;
  const list = enclosing(parse(text), pos);
  const next = sexps(list).find((s) => s.end > pos);
  if (next) return same(text, cursor(next.end));
  return same(text, closed(list) ? cursor(list.end) : selection);
}

// To the start of the previous S-expression, or out before the opener.
function backwardSexp(text, selection) {
  const pos = selection.start;
  const list = enclosing(parse(text), pos);
  const previous = sexps(list).findLast((s) => s.start < pos);
  if (previous) return same(text, cursor(previous.start));
  return same(text, list.parent ? cursor(list.start) : selection);
}

// Out to before the enclosing list's opener.
function upList(text, selection) {
  const list = enclosing(parse(text), selection.start);
  return same(text, list.parent ? cursor(list.start) : selection);
}

// Out to after the enclosing list's closer.
function forwardUpList(text, selection) {
  const list = enclosing(parse(text), selection.end);
  return same(text, list.parent && list.closed ? cursor(list.end) : selection);
}

// Into the next list, just after its opener.
function downList(text, selection) {
  const pos = selection.end;
  const next = enclosing(parse(text), pos).children.find((c) => c.kind === "list" && c.start >= pos);
  return same(text, next ? cursor(next.start + 1) : selection);
}

// Indentation --------------------------------------------------------------

// Forms whose body goes two in from the opener however the first line is
// laid out: (define (f x)\n  body), (match e\n  [..]), (let (..)\n  body).
const BODY_FORMS = new Set([
  "define", "define-type", "define-type-alias", "define-foreign-type", "lambda", "λ", "let", "let*", "letrec",
  "match", "when", "unless", "cond", "case", "begin", "do",
]);

// The column a line starting at `pos` takes, Lisp's way, from the list
// `pos` is in: nothing before it there, one in from the opener; a body
// form's head, two in; a head with an argument beside it, under that
// argument; else under the head (one in from the opener).
export function indentation(text, pos, root = parse(text)) {
  const list = enclosing(root, pos);
  if (list === root) return 0;
  const column = (at) => at - (text.lastIndexOf("\n", at - 1) + 1);
  const before = sexps(list).filter((s) => s.end <= pos);
  if (!before.length) return column(list.start) + 1;
  const [head, second] = before;
  if (head.kind === "word" && BODY_FORMS.has(text.slice(head.start, head.end))) return column(list.start) + 2;
  const sameLine = (a, b) => text.lastIndexOf("\n", a.start - 1) === text.lastIndexOf("\n", b.start - 1);
  if (head.kind === "word" && second && sameLine(head, second)) return column(second.start);
  return column(head.start);
}

// Enter: a newline, indented for where it starts. The blanks either side
// of the cut go: the new line is indented afresh and the old one keeps no
// trailing ones. Inside a string or a comment the editor's own Enter is
// right.
function newline(text, selection) {
  const root = parse(text);
  if (leafAt(root, selection.start) || leafAt(root, selection.end)) return null;
  let from = selection.start;
  while (from > 0 && (text[from - 1] === " " || text[from - 1] === "\t")) from--;
  let to = selection.end;
  while (to < text.length && (text[to] === " " || text[to] === "\t")) to++;
  const indent = " ".repeat(indentation(text, from, root));
  return { text: `${text.slice(0, from)}\n${indent}${text.slice(to)}`, selection: cursor(from + 1 + indent.length) };
}

// Tab: the line re-indented for where it starts, the cursor keeping its
// place in it. A line inside a string is the editor's own.
function indentLine(text, selection) {
  const pos = selection.start;
  const lineStart = text.lastIndexOf("\n", pos - 1) + 1;
  let content = lineStart;
  while (content < text.length && (text[content] === " " || text[content] === "\t")) content++;
  const root = parse(text);
  if (leafAt(root, lineStart)?.kind === "string") return null;
  const indent = " ".repeat(indentation(text, content, root));
  const current = text.slice(lineStart, content);
  if (current === indent) return same(text, selection);
  const at = pos < content ? lineStart + indent.length : pos + indent.length - current.length;
  return { text: text.slice(0, lineStart) + indent + text.slice(content), selection: cursor(at) };
}

// The operations, by name ------------------------------------------------

export const unguarded = {
  insertOpen, insertClose, insertQuote, insertSemicolon, deleteBackward, deleteForward, newline, indentLine,
  slurpForward, slurpBackward, barfForward, barfBackward,
  splice, raise, wrap, split, join, kill,
  expandSelection, contractSelection, forwardSexp, backwardSexp, upList, forwardUpList, downList,
};

// Each operation, guarded: a result that would add a fault is refused. The
// operations are written not to produce one (the tests check `unguarded`);
// the guard is what makes "never unbalances" hold on text that is already
// unbalanced in ways they do not foresee, such as a string left open across
// the closer an operation moves.
export const paredit = Object.fromEntries(Object.entries(unguarded).map(([name, op]) => [name, (text, selection, ...args) => {
  const result = op(text, selection, ...args);
  if (!result || result.text === text || parse(result.text).faults <= parse(text).faults) return result;
  return same(text, selection);
}]));
