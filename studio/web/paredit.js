// Structured editing in the browser: sexp.js's paredit operations bound to
// keys, in the Monaco program editor and in plain textareas (the REPL
// prompt, and the editor's fallback). Ported from Slog Studio's paredit.js.
//
//   bindMonaco(monaco, editor)   the program editor
//   bindTextarea(area)           a textarea; returns its keydown handler,
//                                which says whether it took the key
//   structured                   { on, set(on), listeners }: balanced typing
//                                and the paredit keys, on unless turned off
//   BINDINGS                     [operation, chords, what it does], for help

import { paredit } from "./sexp.js";

export const BINDINGS = [
  ["slurpForward", ["Ctrl-Shift-0", "Ctrl-Right"], "slurp: take the next expression into this list"],
  ["barfForward", ["Ctrl-Shift-]", "Ctrl-Left"], "barf: push this list's last expression out"],
  ["slurpBackward", ["Ctrl-Shift-9", "Ctrl-Alt-Left"], "slurp the previous expression in"],
  ["barfBackward", ["Ctrl-Shift-[", "Ctrl-Alt-Right"], "barf the first expression out"],
  ["splice", ["Alt-S"], "splice: remove this list's brackets"],
  ["raise", ["Alt-R"], "raise: replace this list with the expression here"],
  ["wrap", ["Alt-Shift-9"], "wrap the expression or selection in ( )"],
  ["wrapSquare", ["Alt-["], "wrap the expression or selection in [ ]"],
  ["split", ["Alt-Shift-S"], "split this list or string in two here"],
  ["join", ["Alt-Shift-J"], "join the lists or strings either side"],
  ["kill", ["Ctrl-K"], "delete to the end of this list"],
  ["expandSelection", ["Alt-Up"], "select the enclosing expression"],
  ["contractSelection", ["Alt-Down"], "select back down"],
  ["forwardSexp", ["Ctrl-Alt-F"], "forward over an expression"],
  ["backwardSexp", ["Ctrl-Alt-B"], "backward over an expression"],
  ["upList", ["Ctrl-Alt-U"], "out to this list's opener"],
  ["forwardUpList", ["Ctrl-Alt-N"], "out past this list's closer"],
  ["downList", ["Ctrl-Alt-D"], "into the next list"],
];

const COMMANDS = {
  ...paredit,
  wrapSquare: (text, selection) => paredit.wrap(text, selection, "["),
};

// Typing, in structured mode: key -> (text, selection) -> result or null.
const TYPING = {
  "(": (t, s) => paredit.insertOpen(t, s, "("),
  "[": (t, s) => paredit.insertOpen(t, s, "["),
  ")": paredit.insertClose,
  "]": paredit.insertClose,
  "\"": paredit.insertQuote,
  ";": paredit.insertSemicolon,
  Backspace: paredit.deleteBackward,
  Delete: paredit.deleteForward,
};

const STORED = "puffin-studio.structured";
export const structured = {
  on: (() => { try { return localStorage.getItem(STORED) !== "off"; } catch { return true; } })(),
  listeners: new Set(),
  set(on) {
    this.on = on;
    try { localStorage.setItem(STORED, on ? "on" : "off"); } catch { /* private mode */ }
    for (const listener of this.listeners) listener(on);
  },
};

export const MAC = /Mac|iPhone|iPad/.test(navigator.platform);

// "Ctrl-Alt-F" for a keydown, naming the key by its position.
const PUNCTUATION = { BracketLeft: "[", BracketRight: "]", Slash: "/" };
function chord(event) {
  const key = PUNCTUATION[event.code] ?? event.code.replace(/^Key|^Digit|^Arrow/, "");
  return [event.ctrlKey && "Ctrl", event.altKey && "Alt", event.shiftKey && "Shift", event.metaKey && "Meta", key]
    .filter(Boolean).join("-");
}

// A chord as a Monaco keybinding.
function keybinding(monaco, text) {
  const { KeyMod, KeyCode } = monaco;
  const parts = text.split("-");
  const key = parts.pop();
  const modifiers = { Ctrl: MAC ? KeyMod.WinCtrl : KeyMod.CtrlCmd, Alt: KeyMod.Alt, Shift: KeyMod.Shift };
  const code = /^\d$/.test(key) ? KeyCode[`Digit${key}`]
    : /^[A-Z]$/.test(key) ? KeyCode[`Key${key}`]
      : { "[": KeyCode.BracketLeft, "]": KeyCode.BracketRight, "/": KeyCode.Slash }[key] ?? KeyCode[key] ?? KeyCode[`${key}Arrow`];
  return parts.reduce((binding, part) => binding | modifiers[part], code);
}

// The one replacement turning `before` into `after`: { start, end, insert }.
export function difference(before, after) {
  let start = 0;
  while (start < before.length && start < after.length && before[start] === after[start]) start++;
  let tail = 0;
  while (tail < before.length - start && tail < after.length - start
    && before[before.length - 1 - tail] === after[after.length - 1 - tail]) tail++;
  return { start, end: before.length - tail, insert: after.slice(start, after.length - tail) };
}

const same = (a, b) => a.start === b.start && a.end === b.end;

export function bindMonaco(monaco, editor) {
  const model = () => editor.getModel();
  const offset = (position) => model().getOffsetAt(position);
  const position = (at) => model().getPositionAt(at);
  const current = () => {
    const s = editor.getSelection();
    return { text: model().getValue(), selection: { start: offset(s.getStartPosition()), end: offset(s.getEndPosition()) } };
  };
  const readOnly = () => editor.getOption(monaco.editor.EditorOption.readOnly);
  const apply = (before, result) => {
    if (result.text !== before) {
      if (readOnly()) return;
      const { start, end, insert } = difference(before, result.text);
      editor.pushUndoStop();
      editor.executeEdits("paredit", [{ range: monaco.Range.fromPositions(position(start), position(end)), text: insert }]);
      editor.pushUndoStop();
    }
    editor.setSelection(monaco.Selection.fromPositions(position(result.selection.start), position(result.selection.end)));
    editor.revealPosition(position(result.selection.end));
  };
  const run = (operation) => {
    const { text, selection } = current();
    const result = operation(text, selection);
    if (result) apply(text, result);
    return result;
  };

  const on = editor.createContextKey("puffinStructured", structured.on);
  structured.listeners.add((value) => on.set(value));

  // Growing the selection keeps a history, so shrinking retraces it.
  const grown = [];
  for (const [name, chords, about] of BINDINGS) {
    editor.addAction({
      id: `puffin.${name}`,
      label: `Structure: ${about}`,
      keybindings: chords.map((text) => keybinding(monaco, text)),
      precondition: "puffinStructured",
      run() {
        const { text, selection } = current();
        if (name === "contractSelection" && grown.length && same(grown.at(-1).after, selection)) {
          apply(text, { text, selection: grown.pop().before });
          return;
        }
        const result = COMMANDS[name](text, selection);
        if (name === "expandSelection") grown.push({ before: selection, after: result.selection });
        else if (name !== "contractSelection") grown.length = 0;
        apply(text, result);
      },
    });
  }

  // Enter is newline-and-indent in the program editor only: in the REPL
  // prompt it submits. It stays Monaco's while the completion list is up
  // (Enter takes an item) and with Shift.
  const typingHere = { ...TYPING, Enter: paredit.newline };
  const completing = () => {
    const widget = editor.getDomNode()?.querySelector(".suggest-widget");
    return Boolean(widget) && getComputedStyle(widget).display !== "none";
  };
  editor.onKeyDown((event) => {
    const typing = typingHere[event.browserEvent.key];
    if (!structured.on || !typing || event.ctrlKey || event.metaKey || event.altKey
      || event.browserEvent.isComposing || editor.getSelections().length > 1 || readOnly()) return;
    if (event.browserEvent.key === "Enter" && (event.shiftKey || completing())) return;
    if (!run(typing)) return;
    event.preventDefault();
    event.stopPropagation();
  });
}

// Replace the textarea's text with `result`, as one edit undo can take
// back where the browser allows it.
export function applyTo(area, result) {
  const before = area.value;
  if (result.text !== before) {
    const { start, end, insert } = difference(before, result.text);
    area.setSelectionRange(start, end);
    const done = insert ? document.execCommand("insertText", false, insert) : document.execCommand("delete");
    if (!done || area.value !== result.text) {
      area.value = result.text;
      area.dispatchEvent(new Event("input"));
    }
  }
  area.setSelectionRange(result.selection.start, result.selection.end);
}

// A keydown handler for a textarea's paredit keys, which says whether it
// took the key. Attach it yourself, or let bindTextarea do so.
export function structureKeys(area) {
  const commands = new Map(BINDINGS.flatMap(([name, chords]) => chords.map((text) => [text, name])));
  const grown = [];
  return (event) => {
    if (event.isComposing || !structured.on) return false;
    const text = area.value;
    const selection = { start: area.selectionStart, end: area.selectionEnd };
    const name = commands.get(chord(event));
    let result;
    if (name === "contractSelection" && grown.length && same(grown.at(-1).after, selection)) {
      result = { text, selection: grown.pop().before };
    } else if (name) {
      result = COMMANDS[name](text, selection);
      if (name === "expandSelection") grown.push({ before: selection, after: result.selection });
    } else if (TYPING[event.key] && !event.ctrlKey && !event.metaKey && !event.altKey) {
      result = TYPING[event.key](text, selection);
    }
    if (!result) return false;
    event.preventDefault();
    applyTo(area, result);
    return true;
  };
}

export function bindTextarea(area) {
  const keys = structureKeys(area);
  area.addEventListener("keydown", keys);
  return keys;
}
