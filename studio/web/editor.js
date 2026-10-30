// The program editor: Monaco, served from the repository's web/node_modules
// through its AMD loader, else a textarea. Both offer the same small
// interface:
//   show(key, text)          switch to document `key` (made on first use)
//                            holding `text`; each keeps its undo and view
//   forget(key)
//   get() / set(text)        the shown text; set is an undoable edit and does
//                            not fire onChange
//   edits(list)              apply [{ start, end, text }] (offsets into the
//                            shown text) as one undoable edit
//   selection()              { start, end } offsets of the selection
//   reveal({ line, col })    put the cursor there
//   markers(key, list)       mark document `key`'s diagnostics, each
//                            { line, severity, message }
//   caretBox()               the cursor's box on screen, for menus, or null
//   focus()
//   raw                      { monaco, editor } for Monaco, else null
// Monaco also gets the Puffin language: its tokens, brackets and theme.

import { bindMonaco, bindTextarea } from "./paredit.js";
import { surfacePrimNames } from "./prim-names.js";

export async function createEditor(element, handlers) {
  const monaco = await loadMonaco();
  return monaco ? monacoEditor(monaco, element, handlers) : textareaEditor(element, handlers);
}

function loadMonaco() {
  return new Promise((resolve) => {
    if (typeof window.require !== "function") return resolve(null);
    const timer = setTimeout(() => resolve(null), 10000);
    window.MonacoEnvironment = {
      getWorkerUrl: () => `data:text/javascript;charset=utf-8,${encodeURIComponent(
        `self.MonacoEnvironment={baseUrl:'${location.origin}/'};importScripts('${location.origin}/vs/base/worker/workerMain.js');`)}`,
    };
    window.require.config({ paths: { vs: "/vs" } });
    window.require(
      ["vs/editor/editor.main"],
      () => { clearTimeout(timer); resolve(window.monaco); },
      () => { clearTimeout(timer); resolve(null); },
    );
  });
}

// Solarized light, as the playground (web/src/monaco-setup.js) has it.
const SOL = {
  base3: "fdf6e3", base2: "eee8d5", base1: "93a1a1", base00: "657b83", base01: "586e75",
  yellow: "b58900", orange: "cb4b16", red: "dc322f", magenta: "d33682",
  violet: "6c71c4", blue: "268bd2", cyan: "2aa198", green: "859900",
};

export const KEYWORDS = [
  "define", "define-type", "define-foreign-type", "foreign", "lambda", "λ", "let", "let*", "letrec", "if", "cond",
  "case", "match", "when", "unless", "begin", "while", "set!", "quote", "quasiquote", "unquote", "and", "or", "not",
  "else", "program", "require", "provide", "ann", ":",
];

export const BUILTINS = [...surfacePrimNames(), "list", "vector", "<=", ">", ">=", "<", "eq?", "+", "-", "*", "map", "filter", "foldl", "foldr", "append", "length", "reverse", "format", "apply"];

const PUFFIN = {
  defaultToken: "identifier",
  keywords: KEYWORDS,
  builtins: BUILTINS,
  tokenizer: {
    root: [
      [/;.*$/, "comment"],
      [/"/, "string", "@string"],
      [/#:[^\s()[\];"]+/, "keyword.flag"],
      [/#t\b|#f\b|#true\b|#false\b/, "constant.boolean"],
      [/'[^\s()[\];",'`]+/, "symbol.quoted"],
      [/[+-]?\d+(?=[\s()[\];"]|$)/, "number"],
      // a constructor or type: capitalized
      [/[A-Z][^\s()[\];",'`]*/, "type"],
      [/[()[\]]/, "@brackets"],
      [/,@|[`',]/, "operator.quote"],
      [/[^\s()[\];",'`]+/, { cases: { "@keywords": "keyword", "@builtins": "builtin", "@default": "identifier" } }],
    ],
    string: [
      [/[^\\"]+/, "string"],
      [/\\./, "string.escape"],
      [/"/, "string", "@pop"],
    ],
  },
};

function register(monaco) {
  monaco.languages.register({ id: "puffin" });
  monaco.languages.setMonarchTokensProvider("puffin", PUFFIN);
  monaco.languages.setLanguageConfiguration("puffin", {
    comments: { lineComment: ";" },
    brackets: [["(", ")"], ["[", "]"]],
    wordPattern: /[^\s()[\];",'`]+/,
    autoClosingPairs: [],
  });
  monaco.editor.defineTheme("puffin-solarized", {
    base: "vs",
    inherit: true,
    rules: [
      { token: "comment", foreground: SOL.base1, fontStyle: "italic" },
      { token: "string", foreground: SOL.cyan },
      { token: "string.escape", foreground: SOL.orange },
      { token: "number", foreground: SOL.magenta },
      { token: "constant.boolean", foreground: SOL.magenta },
      { token: "symbol.quoted", foreground: SOL.yellow },
      { token: "type", foreground: SOL.yellow },
      { token: "keyword", foreground: SOL.green, fontStyle: "bold" },
      { token: "keyword.flag", foreground: SOL.orange },
      { token: "builtin", foreground: SOL.blue },
      { token: "identifier", foreground: SOL.base00 },
      { token: "operator.quote", foreground: SOL.orange },
    ],
    colors: {
      "editor.background": `#${SOL.base3}`,
      "editor.foreground": `#${SOL.base00}`,
      "editor.lineHighlightBackground": "#eee8d580",
      "editor.selectionBackground": `#${SOL.base2}`,
      "editorCursor.foreground": `#${SOL.base01}`,
      "editorLineNumber.foreground": `#${SOL.base1}`,
      "editorLineNumber.activeForeground": `#${SOL.base01}`,
      "editorBracketMatch.background": `#${SOL.base2}`,
      "editorBracketMatch.border": `#${SOL.yellow}`,
      "editorBracketHighlight.foreground1": `#${SOL.blue}`,
      "editorBracketHighlight.foreground2": `#${SOL.magenta}`,
      "editorBracketHighlight.foreground3": `#${SOL.cyan}`,
      "editorBracketHighlight.foreground4": `#${SOL.violet}`,
    },
  });
}

function monacoEditor(monaco, element, { onChange, onSave, onEvalForm, onLoadFile, onAssist }) {
  register(monaco);
  const editor = monaco.editor.create(element, {
    language: "puffin",
    theme: "puffin-solarized",
    automaticLayout: true,
    minimap: { enabled: false },
    folding: false,
    quickSuggestions: false,
    scrollBeyondLastLine: false,
    fontFamily: "\"JetBrains Mono\", \"SF Mono\", Menlo, Consolas, monospace",
    fontSize: 14,
    tabSize: 2,
    glyphMargin: false,
    matchBrackets: "always",
    bracketPairColorization: { enabled: true },
    lightbulb: { enabled: "on" },
    padding: { top: 8 },
  });
  const documents = new Map(); // key -> { model, view }
  let shown = null;
  let quiet = false;
  const current = () => editor.getModel();
  const uriOf = (key) => monaco.Uri.from({ scheme: "studio", path: `/${key}` });

  editor.onDidChangeModelContent(() => { if (!quiet) onChange(); });
  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, onSave);
  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter, onEvalForm);
  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.Enter, onLoadFile);
  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Period, onAssist);
  bindMonaco(monaco, editor);

  const range = (start, end) => monaco.Range.fromPositions(current().getPositionAt(start), current().getPositionAt(end));
  return {
    raw: { monaco, editor },
    show(key, text) {
      if (key !== shown) {
        if (documents.has(shown)) documents.get(shown).view = editor.saveViewState();
        if (!documents.has(key)) documents.set(key, { model: monaco.editor.createModel(text, "puffin", uriOf(key)), view: null });
        const { model, view } = documents.get(key);
        quiet = true;
        editor.setModel(model);
        quiet = false;
        if (view) editor.restoreViewState(view);
        shown = key;
      }
      this.set(text);
    },
    forget(key) {
      documents.get(key)?.model.dispose();
      documents.delete(key);
      if (shown === key) shown = null;
    },
    get: () => current().getValue(),
    set(text) {
      if (current().getValue() === text) return;
      const selection = editor.getSelection();
      quiet = true;
      // an edit operation, not setValue, so undo can step back over it
      current().pushEditOperations([], [{ range: current().getFullModelRange(), text }], () => null);
      quiet = false;
      if (selection) editor.setSelection(selection);
    },
    edits(list) {
      editor.pushUndoStop();
      editor.executeEdits("assist", list.map(({ start, end, text }) => ({ range: range(start, end), text, forceMoveMarkers: true })));
      editor.pushUndoStop();
      const last = list.reduce((a, b) => (b.start >= a.start ? b : a), list[0]);
      if (last) editor.revealPositionInCenterIfOutsideViewport(current().getPositionAt(last.start));
    },
    selection() {
      const s = editor.getSelection();
      return { start: current().getOffsetAt(s.getStartPosition()), end: current().getOffsetAt(s.getEndPosition()) };
    },
    reveal({ line, col = 1 }) {
      editor.revealLineInCenter(line);
      editor.setPosition({ lineNumber: line, column: col });
      editor.focus();
    },
    markers(key, list) {
      const model = documents.get(key)?.model;
      if (!model) return;
      const lines = model.getLineCount();
      monaco.editor.setModelMarkers(model, "check", list.map(({ line, severity, message }) => {
        const at = Math.min(Math.max(line || 1, 1), lines);
        return {
          startLineNumber: at,
          startColumn: model.getLineFirstNonWhitespaceColumn(at) || 1,
          endLineNumber: at,
          endColumn: model.getLineMaxColumn(at),
          message,
          severity: severity === "warning" ? monaco.MarkerSeverity.Warning : monaco.MarkerSeverity.Error,
          source: "puffincc",
        };
      }));
    },
    caretBox() {
      const at = editor.getPosition();
      const point = at && editor.getScrolledVisiblePosition(at);
      if (!point) return null;
      const box = editor.getDomNode().getBoundingClientRect();
      return { left: box.left + point.left, top: box.top + point.top, height: point.height };
    },
    focus: () => editor.focus(),
    keyOf: (model) => (model?.uri?.scheme === "studio" ? model.uri.path.slice(1) : null),
  };
}

// The fallback, when Monaco is not installed: a textarea with the same
// keys, and no markers.
function textareaEditor(element, { onChange, onSave, onEvalForm, onLoadFile, onAssist }) {
  const area = document.createElement("textarea");
  area.spellcheck = false;
  area.className = "fallback-editor";
  element.append(area);
  area.addEventListener("input", onChange);
  bindTextarea(area);
  area.addEventListener("keydown", (event) => {
    if (!(event.metaKey || event.ctrlKey)) return;
    const take = (handler) => { event.preventDefault(); handler(); };
    if (event.key === "Enter" && event.shiftKey) take(onLoadFile);
    else if (event.key === "Enter") take(onEvalForm);
    else if (event.key === "s") take(onSave);
    else if (event.key === ".") take(onAssist);
  });
  const texts = new Map();
  let shown = null;
  return {
    raw: null,
    show(key, text) {
      if (shown !== null) texts.set(shown, area.value);
      shown = key;
      if (area.value !== text) area.value = text;
    },
    forget(key) { texts.delete(key); if (shown === key) shown = null; },
    get: () => area.value,
    set(text) {
      if (area.value === text) return;
      const { selectionStart, selectionEnd } = area;
      area.value = text;
      area.setSelectionRange(selectionStart, selectionEnd);
    },
    edits(list) {
      let text = area.value;
      for (const { start, end, text: insert } of [...list].sort((a, b) => b.start - a.start)) {
        text = text.slice(0, start) + insert + text.slice(end);
      }
      area.value = text;
      onChange();
    },
    selection: () => ({ start: area.selectionStart, end: area.selectionEnd }),
    reveal({ line }) {
      const lines = area.value.split("\n");
      const at = lines.slice(0, line - 1).reduce((sum, l) => sum + l.length + 1, 0);
      area.focus();
      area.setSelectionRange(at, at);
    },
    markers() {},
    caretBox() {
      const box = area.getBoundingClientRect();
      return { left: box.left + 20, top: box.top + 20, height: 18 };
    },
    focus: () => area.focus(),
    keyOf: () => null,
  };
}
