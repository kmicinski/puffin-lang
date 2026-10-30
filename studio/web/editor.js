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
//   markers(key, list, owner)  mark document `key`'s diagnostics, each
//                            { line, severity, message } or with { start,
//                            end } offsets; severity "error", "warning",
//                            "info" (the observation lint) or "hint" (a
//                            hole). Each owner's markers stand apart.
//   decorations(key, name, list)  mark spans of document `key`, each
//                            { start, end, className, hover }; each name's
//                            stand apart
//   glyphs(key, list)        mark lines of document `key` in the gutter,
//                            each { line, className, hover }
//   lineMarks(key, name, list)  mark lines of document `key` in the lane
//                            beside the line numbers, each { line,
//                            className, hover }; each name's stand apart
//   offset()                 the cursor's offset
//   setRenameAvailable(on)   whether F2 renames
//   caretBox()               the cursor's box on screen, for menus, or null
//   focus()
//   raw                      { monaco, editor } for Monaco, else null
// Monaco also gets the Puffin language: its tokens, brackets and theme.
// Keys: ⌘S save, ⌘↵ eval form, ⇧⌘↵ load file, ⌘. assists, F2 rename (when
// puffincc can), F8 and ⇧F8 the next and previous typed hole; Emacs keys
// with a kill ring (emacs.js) and paredit's (paredit.js). Tracing:
// ⌘-click in the gutter of a line, a click on a trace mark, or the context
// menu's "Trace" calls onTrace({ line }) or onTrace({ pos }).

import { bindMonaco, bindTextarea } from "./paredit.js";
import { bindEmacs } from "./emacs.js";
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
      // info marks only the observation lint: cyan, as observed things are
      "editorInfo.foreground": `#${SOL.cyan}`,
      "editorHint.foreground": `#${SOL.magenta}`,
      // the rest of a match, shown before it is written (assists.js)
      "editorGhostText.foreground": `#${SOL.base1}`,
    },
  });
}

const SEVERITY = { warning: "Warning", info: "Info", hint: "Hint" };

function monacoEditor(monaco, element, { onChange, onSave, onEvalForm, onLoadFile, onAssist, onCursor, onRename, onHole, onTrace }) {
  register(monaco);
  const editor = monaco.editor.create(element, {
    language: "puffin",
    theme: "puffin-solarized",
    automaticLayout: true,
    minimap: { enabled: false },
    folding: false,
    quickSuggestions: false,
    // ghost text: the rest of a match (assists.js); Tab takes it
    inlineSuggest: { enabled: true, showToolbar: "never" },
    scrollBeyondLastLine: false,
    fontFamily: "\"JetBrains Mono\", \"SF Mono\", Menlo, Consolas, monospace",
    fontSize: 14,
    tabSize: 2,
    // the session's marks on each top-level form (session.js)
    glyphMargin: true,
    // the trace marks beside the line numbers (session.js)
    lineDecorationsWidth: 14,
    matchBrackets: "always",
    bracketPairColorization: { enabled: true },
    lightbulb: { enabled: "on" },
    padding: { top: 8 },
  });
  const documents = new Map(); // key -> { model, view, glyphs }
  let shown = null;
  let quiet = false;
  const current = () => editor.getModel();
  const uriOf = (key) => monaco.Uri.from({ scheme: "studio", path: `/${key}` });

  editor.onDidChangeModelContent(() => { if (!quiet) onChange(); });
  editor.onDidChangeCursorPosition(() => onCursor?.());
  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, onSave);
  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter, onEvalForm);
  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.Enter, onLoadFile);
  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Period, onAssist);
  // F2 is the compiler's rename only when it has one; else Monaco's own
  const renames = editor.createContextKey("puffinRename", false);
  editor.addAction({ id: "puffin.rename", label: "Rename (the compiler's)", keybindings: [monaco.KeyCode.F2], precondition: "puffinRename", run: () => onRename?.() });
  // F8 walks the typed holes, not Monaco's problems: a hole is the next thing to do
  editor.addAction({ id: "puffin.next-hole", label: "Next typed hole", keybindings: [monaco.KeyCode.F8], run: () => onHole?.(1) });
  editor.addAction({ id: "puffin.previous-hole", label: "Previous typed hole", keybindings: [monaco.KeyMod.Shift | monaco.KeyCode.F8], run: () => onHole?.(-1) });
  // tracing a function: the context menu, ⌘-click in the gutter, or a click on its mark
  editor.addAction({
    id: "puffin.trace",
    label: "Trace or untrace this function (,trace)",
    contextMenuGroupId: "navigation",
    contextMenuOrder: 0,
    run: () => onTrace?.({ pos: current().getOffsetAt(editor.getPosition()) }),
  });
  const { MouseTargetType } = monaco.editor;
  editor.onMouseDown((event) => {
    const { type, position, element: target } = event.target;
    const gutter = [MouseTargetType.GUTTER_GLYPH_MARGIN, MouseTargetType.GUTTER_LINE_NUMBERS, MouseTargetType.GUTTER_LINE_DECORATIONS].includes(type);
    if (!gutter || !position) return;
    const mark = type === MouseTargetType.GUTTER_LINE_DECORATIONS && target?.classList.contains("trace-mark");
    if (mark || event.event.metaKey || event.event.ctrlKey) {
      event.event.preventDefault();
      onTrace?.({ line: position.lineNumber });
    }
  });
  bindMonaco(monaco, editor);
  bindEmacs(monaco, editor, { onSave });

  const range = (start, end) => monaco.Range.fromPositions(current().getPositionAt(start), current().getPositionAt(end));
  return {
    raw: { monaco, editor },
    show(key, text) {
      if (key !== shown) {
        if (documents.has(shown)) documents.get(shown).view = editor.saveViewState();
        if (!documents.has(key)) documents.set(key, { model: monaco.editor.createModel(text, "puffin", uriOf(key)), view: null, glyphs: [], spans: new Map() });
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
    markers(key, list, owner = "check") {
      const model = documents.get(key)?.model;
      if (!model) return;
      const lines = model.getLineCount();
      monaco.editor.setModelMarkers(model, owner, list.map(({ line, start, end, severity, message, source }) => {
        const severityOf = monaco.MarkerSeverity[SEVERITY[severity] ?? "Error"];
        if (start !== undefined) {
          const from = model.getPositionAt(start);
          const to = model.getPositionAt(end ?? start);
          return {
            startLineNumber: from.lineNumber, startColumn: from.column, endLineNumber: to.lineNumber, endColumn: to.column,
            message, severity: severityOf, source: source ?? "puffincc",
          };
        }
        const at = Math.min(Math.max(line || 1, 1), lines);
        return {
          startLineNumber: at,
          startColumn: model.getLineFirstNonWhitespaceColumn(at) || 1,
          endLineNumber: at,
          endColumn: model.getLineMaxColumn(at),
          message,
          severity: severityOf,
          source: source ?? "puffincc",
        };
      }));
    },
    decorations(key, name, list) {
      const document = documents.get(key);
      if (!document) return;
      const model = document.model;
      const made = model.deltaDecorations(document.spans.get(name) ?? [], list.map(({ start, end, className, hover }) => ({
        range: monaco.Range.fromPositions(model.getPositionAt(start), model.getPositionAt(end)),
        options: {
          inlineClassName: className,
          hoverMessage: hover ? { value: hover } : undefined,
          stickiness: monaco.editor.TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges,
        },
      })));
      document.spans.set(name, made);
    },
    glyphs(key, list) {
      const document = documents.get(key);
      if (!document) return;
      const lines = document.model.getLineCount();
      document.glyphs = document.model.deltaDecorations(document.glyphs, list.map(({ line, className, hover }) => ({
        range: new monaco.Range(Math.min(line, lines), 1, Math.min(line, lines), 1),
        options: {
          glyphMarginClassName: className,
          glyphMarginHoverMessage: { value: hover },
          stickiness: monaco.editor.TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges,
        },
      })));
    },
    lineMarks(key, name, list) {
      const document = documents.get(key);
      if (!document) return;
      const lines = document.model.getLineCount();
      const made = document.model.deltaDecorations(document.spans.get(`lines:${name}`) ?? [], list.map(({ line, className, hover }) => ({
        range: new monaco.Range(Math.min(line, lines), 1, Math.min(line, lines), 1),
        options: {
          linesDecorationsClassName: className,
          linesDecorationsTooltip: hover,
          stickiness: monaco.editor.TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges,
        },
      })));
      document.spans.set(`lines:${name}`, made);
    },
    caretBox() {
      const at = editor.getPosition();
      const point = at && editor.getScrolledVisiblePosition(at);
      if (!point) return null;
      const box = editor.getDomNode().getBoundingClientRect();
      return { left: box.left + point.left, top: box.top + point.top, height: point.height };
    },
    focus: () => editor.focus(),
    offset: () => current().getOffsetAt(editor.getPosition()),
    // put the cursor at `offset` (and select to `end`)
    select(offset, end = offset) {
      const from = current().getPositionAt(offset);
      const to = current().getPositionAt(end);
      editor.setSelection(monaco.Selection.fromPositions(from, to));
      editor.revealPositionInCenterIfOutsideViewport(from);
      editor.focus();
    },
    setRenameAvailable: (on) => renames.set(Boolean(on)),
    keyOf: (model) => (model?.uri?.scheme === "studio" ? model.uri.path.slice(1) : null),
  };
}

// The fallback, when Monaco is not installed: a textarea with the same
// keys, and no markers.
function textareaEditor(element, { onChange, onSave, onEvalForm, onLoadFile, onAssist, onCursor, onRename, onHole }) {
  const area = document.createElement("textarea");
  area.spellcheck = false;
  area.className = "fallback-editor";
  element.append(area);
  area.addEventListener("input", onChange);
  for (const kind of ["keyup", "click"]) area.addEventListener(kind, () => onCursor?.());
  bindTextarea(area);
  let renames = false;
  area.addEventListener("keydown", (event) => {
    if (event.key === "F8") {
      event.preventDefault();
      return onHole?.(event.shiftKey ? -1 : 1);
    }
    if (event.key === "F2" && renames) {
      event.preventDefault();
      return onRename?.();
    }
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
    decorations() {},
    glyphs() {},
    lineMarks() {},
    caretBox() {
      const box = area.getBoundingClientRect();
      return { left: box.left + 20, top: box.top + 20, height: 18 };
    },
    focus: () => area.focus(),
    offset: () => area.selectionEnd,
    select(offset, end = offset) {
      area.focus();
      area.setSelectionRange(offset, end);
    },
    setRenameAvailable: (on) => { renames = Boolean(on); },
    keyOf: () => null,
  };
}
