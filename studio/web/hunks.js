// Changes to a text as the editor shows them (ported from Slog Studio): which of its lines go, and
// which new lines come in after which line. Pure, so the browser's two uses
// share it and the tests can run it:
// - an agent's proposals (review.rs ops) placed on the text being edited,
//   where they apply by finding their old text, as the studio does;
// - the difference between two versions of a file.
//
// A hunk is { first, last, removed: [{ line, from?, to? }], added: [{ after,
// lines: [{ text, from?, to? }] }] }: 1-based lines of the text shown; a
// removed line's `from`/`to` (1-based columns, `to` exclusive) and an added
// line's mark the characters that differ from the line it replaces.

// The line diff of two arrays of lines, as [{ kind: "same" | "del" | "add",
// text }]: a longest common subsequence, after the common ends are set aside
// so that only the changed middle costs quadratic time.
export function lineDiff(a, b) {
  let head = 0;
  while (head < a.length && head < b.length && a[head] === b[head]) head++;
  let tail = 0;
  while (tail < a.length - head && tail < b.length - head && a[a.length - 1 - tail] === b[b.length - 1 - tail]) tail++;
  const x = a.slice(head, a.length - tail);
  const y = b.slice(head, b.length - tail);
  const lengths = Array.from({ length: x.length + 1 }, () => new Uint32Array(y.length + 1));
  for (let i = x.length - 1; i >= 0; i--) {
    for (let j = y.length - 1; j >= 0; j--) {
      lengths[i][j] = x[i] === y[j] ? lengths[i + 1][j + 1] + 1 : Math.max(lengths[i + 1][j], lengths[i][j + 1]);
    }
  }
  const out = a.slice(0, head).map((text) => ({ kind: "same", text }));
  let i = 0;
  let j = 0;
  while (i < x.length || j < y.length) {
    if (i < x.length && j < y.length && x[i] === y[j]) { out.push({ kind: "same", text: x[i] }); i++; j++; }
    else if (i < x.length && (j === y.length || lengths[i + 1][j] >= lengths[i][j + 1])) out.push({ kind: "del", text: x[i++] });
    else out.push({ kind: "add", text: y[j++] });
  }
  for (const text of a.slice(a.length - tail)) out.push({ kind: "same", text });
  return out;
}

// The hunks turning `before` into `after`, both whole texts, as lines of
// `before` (whose first line is line `first`).
export function hunks(before, after, first = 1) {
  const found = [];
  let line = first;
  let current = null;
  let dels = []; // the run of removed lines the next added ones replace
  const open = () => (current ??= { first: line, last: line, removed: [], added: [] });
  for (const { kind, text } of lineDiff(before.split("\n"), after.split("\n"))) {
    if (kind === "same") {
      if (current) found.push(close(current));
      current = null;
      dels = [];
      line++;
    } else if (kind === "del") {
      open().removed.push({ line, text });
      dels.push(current.removed.at(-1));
      line++;
    } else {
      const hunk = open();
      const after = line - 1;
      let block = hunk.added.at(-1);
      if (block?.after !== after) hunk.added.push(block = { after, lines: [] });
      const added = { text };
      // pair it with the removed line it stands in for, to mark what differs
      const replaced = dels[block.lines.length];
      if (replaced) emphasize(replaced, added);
      block.lines.push(added);
    }
  }
  if (current) found.push(close(current));
  return found;
}

function close(hunk) {
  const lines = [...hunk.removed.map((r) => r.line), ...hunk.added.map((a) => a.after + 1)];
  hunk.first = Math.min(...lines);
  hunk.last = Math.max(...hunk.removed.map((r) => r.line), ...hunk.added.map((a) => a.after), hunk.first);
  for (const removed of hunk.removed) delete removed.text;
  return hunk;
}

// Mark the differing middles of a line and its replacement, when they share
// a start or an end worth keeping.
function emphasize(removed, added) {
  const a = removed.text;
  const b = added.text;
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  let end = 0;
  while (end < a.length - start && end < b.length - start && a[a.length - 1 - end] === b[b.length - 1 - end]) end++;
  if (start + end === 0) return;
  removed.from = start + 1;
  removed.to = a.length - end + 1;
  added.from = start + 1;
  added.to = b.length - end + 1;
}

// ---- Proposals --------------------------------------------------------------

// `text` with `op` ({ old, new }; an empty `old` appends) made, or null when
// it cannot be: review.rs `apply`.
export function apply(text, op) {
  if (!op.old) {
    if (!op.new.trim()) return null;
    const out = text.trimEnd();
    return `${out}${out ? "\n\n" : ""}${op.new.trimEnd()}\n`;
  }
  const at = text.indexOf(op.old);
  if (at < 0 || text.indexOf(op.old, at + 1) >= 0) return null;
  return text.slice(0, at) + op.new + text.slice(at + op.old.length);
}

// The pending ops of every thread for `file`, placed on its `text` as
// groups: { thread, changeset, ids, start, end, replacement } replacing
// text[start, end) (an append: at the end). An op built on an earlier
// pending op of its thread, changing text only that op brings, joins its
// group, and is accepted with it. Ops that cannot be placed come back as
// `unplaced` ids.
export function place(text, ops, file) {
  const groups = [];
  const unplaced = [];
  for (const op of ops.filter((op) => op.status === "pending" && op.file === file).sort((a, b) => a.id - b.id)) {
    const own = groups.filter((group) => group.thread === op.thread).reverse();
    if (!op.old) {
      if (!op.new.trim()) unplaced.push(op.id);
      else groups.push({ thread: op.thread, changeset: op.changeset, ids: [op.id], start: text.length, end: text.length, replacement: op.new.trimEnd(), append: true });
      continue;
    }
    const at = text.indexOf(op.old);
    if (at >= 0 && text.indexOf(op.old, at + 1) < 0) {
      groups.push({ thread: op.thread, changeset: op.changeset, ids: [op.id], start: at, end: at + op.old.length, replacement: op.new });
      continue;
    }
    const base = own.find((group) => apply(group.replacement, op) !== null);
    if (base) {
      base.replacement = apply(base.replacement, op);
      base.ids.push(op.id);
    } else {
      unplaced.push(op.id);
    }
  }
  return { groups, unplaced };
}

// A group's hunk on `text`. An edit is widened to whole lines so that its
// lines diff against what they become; an append is new lines after the
// last, set off by a blank one.
export function groupHunk(text, group) {
  if (group.append) {
    const lines = text.split("\n");
    let after = lines.length;
    while (after > 1 && !lines[after - 1].trim()) after--;
    const added = [...(lines[after - 1]?.trim() ? [""] : []), ...group.replacement.split("\n")];
    return { first: after + 1, last: after + 1, removed: [], added: [{ after, lines: added.map((text) => ({ text })) }] };
  }
  const from = text.lastIndexOf("\n", group.start - 1) + 1;
  // the end of the line holding the old text's last character
  const last = group.end > group.start && text[group.end - 1] !== "\n" ? group.end - 1 : group.end;
  const newline = text.indexOf("\n", last);
  const to = newline < 0 ? text.length : newline;
  const before = text.slice(from, to);
  const after = text.slice(from, group.start) + group.replacement + text.slice(group.end, to);
  const first = text.slice(0, from).split("\n").length;
  const found = hunks(before, after, first);
  if (!found.length) return { first, last: first, removed: [], added: [] };
  // one group is one hunk however its lines interleave
  return {
    first: Math.min(...found.map((h) => h.first)),
    last: Math.max(...found.map((h) => h.last)),
    removed: found.flatMap((h) => h.removed),
    added: found.flatMap((h) => h.added),
  };
}
