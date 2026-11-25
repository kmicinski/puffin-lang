// A definition's span in a file, and a Monaco view narrowed to it
// (docs/VIEW.md). Every view of a file in the studio is a view of the
// same Monaco model (editor.js `model`): the focus pane's editor, each
// fragment in the working set. Narrowing hides the rest of the file
// rather than cutting the definition out of it, so an edit anywhere is an
// edit to the file -- undo, paredit, the hole keys, the check's
// squiggles and the session's marks all see the whole model.

import { forms, balanced } from "./lexer.js";

// the forms that define a name the outline knows
export const DEFINES = new Set(["define", "define-type", "define-type-alias", "define-grammar", "define-foreign-type", "check-property", "check-example"]);

// The lines a definition spans in `text`: its form, the `(: name τ)`
// right before it, and the comment lines right above those.
export function spanOf(text, name) {
  const all = forms(text);
  const at = all.findIndex((f) => f.name === name && DEFINES.has(f.head));
  if (at < 0) return null;
  let start = all[at].line;
  let from = all[at].start;
  const before = all[at - 1];
  if (before?.head === ":" && before.name === name) [start, from] = [before.line, before.start];
  const lines = text.split("\n");
  while (start > 1 && /^\s*;/.test(lines[start - 2])) start--;
  return { start, end: all[at].endLine, from, to: all[at].end };
}

// The definition whose form (or declaration) holds `line` of `text`, by
// name, or null.
export function nameAt(text, line) {
  const form = forms(text).find((f) => f.line <= line && line <= f.endLine && f.name && (DEFINES.has(f.head) || f.head === ":"));
  return form?.name ?? null;
}

// Narrow `view` to the definition `name` (null: the whole file) and keep
// it there as the text changes: the span is found again by name whenever
// the text reads (it grows as the definition does, and follows it when
// the lines above it change); while the brackets are unbalanced, a
// tracked range carries it. `refresh()` returns the span, or null when
// the definition is gone (renamed, deleted).
export function narrow(monaco, view, name) {
  const tracked = view.createDecorationsCollection();
  let span = null;
  function refresh() {
    const model = view.getModel();
    if (!model) return null;
    const lines = model.getLineCount();
    if (name == null) {
      view.setHiddenAreas([]);
      span = { start: 1, end: lines, from: 0, to: model.getValueLength() };
      return span;
    }
    const text = model.getValue();
    let found = balanced(text) ? spanOf(text, name) : null;
    if (!found) {
      const range = tracked.getRange(0);
      found = range && !balanced(text) ? { start: range.startLineNumber, end: range.endLineNumber, from: model.getOffsetAt(range.getStartPosition()), to: model.getOffsetAt(range.getEndPosition()) } : null;
    }
    span = found;
    if (!span) return null;
    const start = Math.min(span.start, lines);
    const end = Math.min(Math.max(span.end, start), lines);
    tracked.set([{ range: new monaco.Range(start, 1, end, model.getLineMaxColumn(end)), options: { stickiness: monaco.editor.TrackedRangeStickiness.AlwaysGrowsWhenTypingAtEdges } }]);
    const hidden = [];
    if (start > 1) hidden.push(new monaco.Range(1, 1, start - 1, 1));
    if (end < lines) hidden.push(new monaco.Range(end + 1, 1, lines, 1));
    view.setHiddenAreas(hidden);
    return span;
  }
  return {
    refresh,
    span: () => span,
    name: () => name,
    // narrow to another definition (the focus moving), or none (the whole
    // file); the same one again is just a refresh (the range it tracks
    // is what carries it while the text is unbalanced)
    to(next) {
      if (next !== name) {
        name = next;
        tracked.clear();
      }
      return refresh();
    },
    dispose: () => tracked.clear(),
  };
}

// The first line within `span` of `model` that uses `word`, for a wire's
// start; the span's first line if none does.
export function lineOf(model, span, word) {
  const text = model.getValue().slice(span.from, span.to);
  const at = text.search(new RegExp(`(^|[\\s()\\[\\]'\`,])${word.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?=[\\s()\\[\\]]|$)`));
  return at < 0 ? span.start : model.getPositionAt(span.from + at + 1).lineNumber;
}
