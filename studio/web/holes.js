// Typed holes (docs/STUDIO.md §5 item 6): `??` marks a missing expression.
// Every `??` in the shown file is outlined as this tab types, with a
// marker saying its goal, the type the expression there must have, once
// the studio has asked the compiler (studio/src/holes.rs). F8 and ⇧F8 go
// to the next and previous hole, on to the other files when this one has
// no more. ⌘. on a hole offers the compiler's fill-hole candidates.
//
// Outside assists `??` is an unbound name, so the check stops at the first
// hole: nothing past it is checked. The status pill says so.
//
//   createHoles({ editor, files, note, onCount }) -> { refresh, changed, next, count, goalAt, receive }
//   onCount()           the program's holes may have changed in number
//   goalAt(file, pos)   the goal of the hole at UTF-16 offset `pos`, or null

import { tokens } from "./lexer.js";

// The holes of `text`: [{ start, end }] offsets of each `??` word.
export function holesIn(text) {
  return tokens(text)
    .filter((token) => token.kind === "word" && token.end - token.start === 2 && text.slice(token.start, token.end) === "??")
    .map(({ start, end }) => ({ start, end }));
}

// Typing at a hole replaces it: a printable key with the cursor in or at
// a `??`, or with exactly one selected (F8 leaves it so), first deletes
// the hole, so what is typed takes its place -- paredit's `(` opens a
// list there rather than wrapping the hole. Space and `?` are typed as
// they are. Bound before paredit's keys (editor.js), which see the text
// with the hole gone.
export function bindHoles(monaco, editor) {
  editor.onKeyDown((event) => {
    const key = event.browserEvent;
    if (key.key.length !== 1 || key.key === " " || key.key === "?" || key.ctrlKey || key.metaKey || key.altKey || key.isComposing) return;
    const model = editor.getModel();
    const s = editor.getSelection();
    const start = model.getOffsetAt(s.getStartPosition());
    const end = model.getOffsetAt(s.getEndPosition());
    const text = model.getValue();
    if (text[start - 1] !== "?" && text[start] !== "?") return;
    const hole = holesIn(text).find((h) => (start === end ? h.start <= start && start <= h.end : h.start === start && h.end === end));
    if (!hole) return;
    editor.executeEdits("hole", [{ range: monaco.Range.fromPositions(model.getPositionAt(hole.start), model.getPositionAt(hole.end)), text: "" }]);
    editor.setPosition(model.getPositionAt(hole.start));
  });
}

export function createHoles({ editor, files, note, onCount = () => {} }) {
  // file -> { version, items: [{ start, end, pos, line, goal }] } from the studio
  const known = new Map();
  let timer = 0;

  // The studio's goals, when they are for the text shown: by order, as
  // long as the holes are where the studio found them.
  function goalsOf(file, found) {
    const marks = known.get(file);
    if (!marks || marks.version !== files.version(file) || !files.synced(file) || marks.items.length !== found.length) return null;
    return marks.items.every((item, i) => item.start === found[i].start) ? marks.items.map((item) => item.goal) : null;
  }

  // The shown file's outlines and markers.
  function refresh() {
    const file = files.active();
    if (!file) return;
    const found = holesIn(editor.get());
    const goals = goalsOf(file, found);
    const say = (i) => (goals?.[i] ? `hole: goal ${goals[i]}` : "hole: a missing expression (??)");
    editor.decorations(file, "holes", found.map((hole) => ({ ...hole, className: "typed-hole" })));
    editor.markers(file, found.map((hole, i) => ({
      ...hole,
      severity: "hint",
      message: say(i),
      source: "typed hole",
    })), "holes");
    onCount();
  }

  function changed() {
    clearTimeout(timer);
    timer = setTimeout(refresh, 80);
  }

  // Holes per file, as this tab has the texts.
  function count() {
    const texts = files.texts();
    const out = new Map();
    for (const path of files.paths()) {
      if (!/\.(puf|scm)$/.test(path)) continue;
      const n = holesIn(texts[path] ?? "").length;
      if (n) out.set(path, n);
    }
    return out;
  }

  // F8 (dir 1) or ⇧F8 (dir -1): the next hole after the cursor, else the
  // first of the next file with holes, wrapping around.
  function next(dir) {
    const file = files.active();
    if (!file) return;
    const here = holesIn(editor.get());
    const at = editor.offset();
    const ahead = dir > 0 ? here.find((hole) => hole.start > at) : here.findLast((hole) => hole.end < at);
    if (ahead) return editor.select(ahead.start, ahead.end);
    const texts = files.texts();
    const paths = files.paths().filter((path) => /\.(puf|scm)$/.test(path));
    const index = paths.indexOf(file);
    for (let step = 1; step <= paths.length; step++) {
      const path = paths[(index + dir * step + paths.length * step) % paths.length];
      const found = holesIn(texts[path] ?? "");
      if (!found.length) continue;
      const hole = dir > 0 ? found[0] : found.at(-1);
      if (path !== file) files.open(path);
      return editor.select(hole.start, hole.end);
    }
    note("no typed holes (??) in the program");
  }

  function goalAt(file, pos) {
    const found = holesIn(files.texts()[file] ?? "");
    const i = found.findIndex((hole) => hole.start <= pos && pos <= hole.end);
    return i < 0 ? null : (goalsOf(file, found)?.[i] ?? null);
  }

  return {
    refresh,
    changed,
    next,
    count,
    goalAt,
    receive: {
      init(snapshot) {
        known.clear();
        for (const [file, marks] of Object.entries(snapshot.holes ?? {})) known.set(file, marks);
        refresh();
      },
      holes({ file, holes }) {
        if (holes.items.length) known.set(file, holes);
        else known.delete(file);
        if (file === files.active()) refresh();
      },
    },
  };
}
