// Emacs keys in the program editor, with a kill ring: consecutive kills
// (C-k, C-w, M-d, M-Backspace, M-w) grow one entry, C-y yanks it and M-y
// after a yank brings the earlier ones round. C-k is paredit-kill when
// structured editing is on (sexp.js kill: the rest of the line, within the
// enclosing list), kill-line otherwise.
//
//   C-f C-b C-n C-p  C-a C-e  M-f M-b  M-< M->  C-v M-v  C-l    motion
//   C-SPC set mark (motion then extends the selection)  C-g cancel
//   C-x C-x exchange point and mark   C-x h select all
//   C-d  M-d  M-Backspace  C-k  C-w  M-w  C-y  M-y  C-t  M-u M-l
//   C-/ C-_ C-x u undo   C-s C-r find   M-% replace   C-x C-s save
//   M-/ complete (a match clause's missing patterns)
// C-M-f, C-M-b, C-M-u, C-M-d, C-M-n are paredit.js's expression motions.
// Every kill also goes to the system clipboard.
//
//   bindEmacs(monaco, editor, { onSave })

import { paredit } from "./sexp.js";
import { structured, difference } from "./paredit.js";

const RING = 60;
const WORD = /[A-Za-z0-9_]/;

export function bindEmacs(monaco, editor, { onSave }) {
  const model = () => editor.getModel();
  const text = () => model().getValue();
  const offsetOf = (position) => model().getOffsetAt(position);
  const positionOf = (offset) => model().getPositionAt(Math.max(0, Math.min(offset, model().getValueLength())));
  const point = () => offsetOf(editor.getPosition());
  const selection = () => {
    const s = editor.getSelection();
    return { start: offsetOf(s.getStartPosition()), end: offsetOf(s.getEndPosition()) };
  };

  const ring = []; // kills, newest last
  let mark = null; // an offset while the mark is active
  let last = null; // "kill" | "yank" | null: what the previous command was
  let yanked = null; // { start, end, index } of the last yank, for M-y
  let prefix = false; // C-x was pressed

  // ---- Motion -----------------------------------------------------------------

  function goTo(offset, extend = mark !== null) {
    const position = positionOf(offset);
    if (extend) editor.setSelection(monaco.Selection.fromPositions(positionOf(mark), position));
    else editor.setPosition(position);
    editor.revealPosition(position);
  }

  const lineStart = () => offsetOf({ lineNumber: editor.getPosition().lineNumber, column: 1 });
  const lineEnd = () => {
    const { lineNumber } = editor.getPosition();
    return offsetOf({ lineNumber, column: model().getLineMaxColumn(lineNumber) });
  };
  function wordForward(from) {
    const t = text();
    let i = from;
    while (i < t.length && !WORD.test(t[i])) i++;
    while (i < t.length && WORD.test(t[i])) i++;
    return i;
  }
  function wordBackward(from) {
    const t = text();
    let i = from;
    while (i > 0 && !WORD.test(t[i - 1])) i--;
    while (i > 0 && WORD.test(t[i - 1])) i--;
    return i;
  }
  function page(direction) {
    editor.trigger("emacs", mark !== null ? (direction > 0 ? "cursorPageDownSelect" : "cursorPageUpSelect") : (direction > 0 ? "cursorPageDown" : "cursorPageUp"), null);
  }

  // ---- Editing ------------------------------------------------------------------

  function replace(start, end, insert) {
    editor.pushUndoStop();
    editor.executeEdits("emacs", [{ range: monaco.Range.fromPositions(positionOf(start), positionOf(end)), text: insert }]);
    editor.pushUndoStop();
  }
  function remember(piece, backward) {
    if (last === "kill" && ring.length) ring[ring.length - 1] = backward ? piece + ring.at(-1) : ring.at(-1) + piece;
    else ring.push(piece);
    if (ring.length > RING) ring.shift();
    navigator.clipboard?.writeText(ring.at(-1)).catch(() => {});
  }
  // Kill [start, end): into the ring, joined to the last kill when this one
  // follows it directly; `backward` kills go on the front.
  function kill(start, end, backward = false) {
    if (start < end) {
      remember(text().slice(start, end), backward);
      replace(start, end, "");
    }
    mark = null;
    goTo(start, false);
    return "kill";
  }
  function killLine() {
    const here = point();
    if (structured.on) {
      const result = paredit.kill(text(), { start: here, end: here });
      if (result && result.text !== text()) {
        const { start, end } = difference(text(), result.text);
        return kill(start, end);
      }
      if (result) return "kill"; // refused: the list is unbalanced
    }
    const end = lineEnd();
    return kill(here, end === here ? here + 1 : end);
  }
  function killRegion(copy) {
    const { start, end } = selection();
    if (start === end) return mark === null ? null : (mark = null, goTo(start, false), "kill");
    if (!copy) return kill(start, end);
    remember(text().slice(start, end), false);
    mark = null;
    goTo(end, false);
    return "kill";
  }
  function yank() {
    if (!ring.length) return null;
    const { start, end } = selection();
    const piece = ring.at(-1);
    replace(start, end, piece);
    yanked = { start, end: start + piece.length, index: ring.length - 1 };
    mark = null;
    goTo(yanked.end, false);
    return "yank";
  }
  function yankPop() {
    if (last !== "yank" || !yanked || ring.length < 2) return null;
    const index = (yanked.index - 1 + ring.length) % ring.length;
    const piece = ring[index];
    replace(yanked.start, yanked.end, piece);
    yanked = { start: yanked.start, end: yanked.start + piece.length, index };
    goTo(yanked.end, false);
    return "yank";
  }
  function deleteForward() {
    const here = point();
    if (structured.on) {
      const result = paredit.deleteForward(text(), { start: here, end: here });
      if (result) {
        if (result.text !== text()) {
          const { start, end, insert } = difference(text(), result.text);
          replace(start, end, insert);
        }
        goTo(result.selection.start, false);
        return "edit";
      }
    }
    if (here < text().length) replace(here, here + 1, "");
    return "edit";
  }
  function transpose() {
    const here = point();
    const t = text();
    if (here === 0 || here >= t.length) return "edit";
    replace(here - 1, here + 1, t[here] + t[here - 1]);
    goTo(here + 1, false);
    return "edit";
  }
  function caseWord(change) {
    const here = point();
    const end = wordForward(here);
    replace(here, end, change(text().slice(here, end)));
    goTo(end, false);
    return "edit";
  }
  function selectAll() {
    mark = 0;
    goTo(text().length);
    return "mark";
  }
  function exchange() {
    if (mark === null) return null;
    const here = point();
    const there = mark;
    mark = here;
    goTo(there);
    return "mark";
  }
  function cancel() {
    mark = null;
    prefix = false;
    goTo(point(), false);
    return null;
  }

  // ---- Keys ---------------------------------------------------------------------

  // code -> command, for Control; for Meta (Option); for C-x then a key
  const control = {
    KeyF: () => goTo(point() + 1),
    KeyB: () => goTo(point() - 1),
    KeyN: () => editor.trigger("emacs", mark !== null ? "cursorDownSelect" : "cursorDown", null),
    KeyP: () => editor.trigger("emacs", mark !== null ? "cursorUpSelect" : "cursorUp", null),
    KeyA: () => goTo(lineStart()),
    KeyE: () => goTo(lineEnd()),
    KeyV: () => page(1),
    KeyL: () => editor.revealPositionInCenter(editor.getPosition()),
    KeyD: deleteForward,
    KeyK: killLine,
    KeyW: () => killRegion(false),
    KeyY: yank,
    KeyT: transpose,
    Space: () => { mark = point(); return "mark"; },
    KeyG: cancel,
    KeyS: () => editor.getAction("actions.find")?.run(),
    KeyR: () => editor.getAction("actions.find")?.run(),
    Slash: () => editor.trigger("emacs", "undo", null),
    Minus: (event) => (event.shiftKey ? editor.trigger("emacs", "undo", null) : null),
    KeyX: () => { prefix = true; return "prefix"; },
  };
  const meta = {
    KeyF: () => goTo(wordForward(point())),
    KeyB: () => goTo(wordBackward(point())),
    KeyD: () => kill(point(), wordForward(point())),
    Backspace: () => kill(wordBackward(point()), point(), true),
    Delete: () => kill(wordBackward(point()), point(), true),
    KeyV: () => page(-1),
    KeyW: () => killRegion(true),
    KeyY: yankPop,
    KeyU: () => caseWord((word) => word.toUpperCase()),
    KeyL: () => caseWord((word) => word.toLowerCase()),
    Comma: (event) => (event.shiftKey ? goTo(0) : null),
    Period: (event) => (event.shiftKey ? goTo(text().length) : null),
    Digit5: (event) => (event.shiftKey ? editor.getAction("editor.action.startFindReplaceAction")?.run() : null),
    // M-/: complete here (a match clause's missing patterns, assists.js)
    Slash: () => editor.trigger("emacs", "editor.action.triggerSuggest", null),
  };
  const afterX = {
    KeyS: (event) => (event.ctrlKey ? onSave?.() : null),
    KeyX: (event) => (event.ctrlKey ? exchange() : null),
    KeyH: selectAll,
    KeyU: () => editor.trigger("emacs", "undo", null),
    KeyG: cancel,
  };

  const MODIFIERS = new Set(["ShiftLeft", "ShiftRight", "ControlLeft", "ControlRight", "AltLeft", "AltRight", "MetaLeft", "MetaRight", "CapsLock"]);

  editor.onKeyDown((event) => {
    const key = event.browserEvent;
    if (MODIFIERS.has(key.code) || key.isComposing) return;
    let command = null;
    if (prefix) {
      prefix = false;
      command = afterX[key.code];
      if (!command) return (last = null);
    } else if (key.ctrlKey && !key.altKey && !key.metaKey) {
      command = control[key.code];
    } else if (key.altKey && !key.ctrlKey && !key.metaKey) {
      command = meta[key.code];
    }
    if (!command) {
      // any other key ends a run of kills, and a yank's turn
      last = null;
      return;
    }
    const kind = command(key);
    if (kind === null) return; // not this chord after all (e.g. unshifted M-,)
    event.preventDefault();
    event.stopPropagation();
    last = kind === "kill" || kind === "yank" ? kind : kind === "prefix" ? last : null;
  });
  editor.onMouseDown(() => { mark = null; last = null; });
}
