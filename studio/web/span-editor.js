// A span editor (docs/VIEW-CANVAS.md): a live Monaco editor over one
// top-level definition of a file -- or over the whole file -- on the
// file's own model. Every view of a file shares that model, so an edit in
// any of them is an edit to the file, and the others (the other spans, the
// whole-file card) show it as it is typed; the studio hears it through
// files.js as from any editor.
//
// The span is found by name among the file's top-level forms (lexer.js),
// again after every edit, so it grows as the definition does and follows
// it when the lines above it change. The rest of the file is hidden, not
// removed: undo, paredit and the hole keys see the whole model.
//
// The names that are top-level definitions somewhere in the program are
// marked as references; ⌘/ctrl/alt-click on one calls onPull(name), which
// is how the canvas pulls a callee in beside its caller.

import { forms } from "./lexer.js";
import { bindMonaco } from "./paredit.js";
import { bindEmacs } from "./emacs.js";
import { bindHoles } from "./holes.js";
import { bindTex } from "./tex.js";

const WORD = /[^\s()[\];",'`]+/g;
const MAX_WIDTH = 820;
// what a define-like head names (its second element)
const DEFINING = /^(define|define-type|define-grammar|define-type-alias|define-foreign-type)$/;

export function createSpanEditor({ monaco, model, name, line = 1, isRef, onPull, onHoverRef, onFocus, onBlur, onEscape, onEvalForm, onSave, onResize }) {
  const node = document.createElement("div");
  node.className = "span-editor";
  const ed = monaco.editor.create(node, {
    model,
    automaticLayout: false,
    minimap: { enabled: false },
    folding: false,
    glyphMargin: false,
    lineNumbers: "on",
    lineNumbersMinChars: 3,
    lineDecorationsWidth: 6,
    scrollBeyondLastLine: false,
    // the canvas pans on the wheel; the span is always as tall as it is
    scrollbar: { vertical: "hidden", horizontal: "hidden", handleMouseWheel: false, alwaysConsumeMouseWheel: false },
    overviewRulerLanes: 0,
    hideCursorInOverviewRuler: true,
    renderLineHighlight: "none",
    fontFamily: "\"JetBrains Mono\", \"SF Mono\", Menlo, Consolas, monospace",
    fontSize: 13,
    tabSize: 2,
    matchBrackets: "always",
    bracketPairColorization: { enabled: true },
    quickSuggestions: false,
    padding: { top: 4, bottom: 4 },
    fixedOverflowWidgets: true,
  });
  bindHoles(monaco, ed);
  bindTex(monaco, ed);
  bindMonaco(monaco, ed);
  bindEmacs(monaco, ed, { onSave });

  let span = { start: 1, end: model.getLineCount(), from: 0, to: model.getValueLength() };
  const refs = ed.createDecorationsCollection();

  // the definition's lines now: by name, the nearest to where it was
  function locate() {
    const lines = model.getLineCount();
    if (name == null) return { start: 1, end: lines, from: 0, to: model.getValueLength() };
    const text = model.getValue();
    const all = forms(text).filter((f) => f.name === name && (!f.head || DEFINING.test(f.head) || f.head === ":"));
    // a (: name τ) declaration goes with its define
    const defines = all.filter((f) => f.head !== ":");
    const pick = (list) => list.sort((a, b) => Math.abs(a.line - span.start) - Math.abs(b.line - span.start))[0];
    const form = pick(defines.length ? defines : all);
    if (!form) return null;
    const declaration = all.find((f) => f.head === ":" && f.endLine < form.line && form.line - f.endLine <= 1);
    const start = declaration ? declaration.line : form.line;
    return { start, end: form.endLine, from: declaration ? declaration.start : form.start, to: form.end };
  }

  function refresh() {
    const found = locate();
    if (found) span = found;
    const lines = model.getLineCount();
    const hidden = [];
    if (span.start > 1) hidden.push(new monaco.Range(1, 1, span.start - 1, 1));
    if (span.end < lines) hidden.push(new monaco.Range(span.end + 1, 1, lines, 1));
    ed.setHiddenAreas(hidden);
    markRefs();
    resize();
    requestAnimationFrame(measure);
  }

  function markRefs() {
    if (!isRef) return;
    const text = model.getValue();
    const list = [];
    WORD.lastIndex = span.from;
    for (let m = WORD.exec(text); m && m.index < span.to; m = WORD.exec(text)) {
      if (m[0] === name || !isRef(m[0])) continue;
      const from = model.getPositionAt(m.index);
      const to = model.getPositionAt(m.index + m[0].length);
      list.push({ range: monaco.Range.fromPositions(from, to), options: { inlineClassName: "canvas-ref" } });
    }
    refs.set(list);
  }

  // As tall as the span, and as wide as its longest line (the widest
  // Monaco has drawn, else an estimate from its characters), within limits.
  let size = { w: 0, h: 0 };
  let drawnWidth = 0;
  function resize() {
    const lineHeight = ed.getOption(monaco.editor.EditorOption.lineHeight);
    const h = (span.end - span.start + 1) * lineHeight + 8;
    const longest = Math.max(20, ...Array.from({ length: span.end - span.start + 1 }, (_, i) => model.getLineLength(span.start + i)));
    const charWidth = ed.getOption(monaco.editor.EditorOption.fontInfo).typicalHalfwidthCharacterWidth || 7.8;
    const gutter = ed.getLayoutInfo().contentLeft;
    const w = Math.ceil(Math.min(MAX_WIDTH, Math.max(320, gutter + Math.max(drawnWidth, (longest + 2) * charWidth) + 16)));
    if (w === size.w && h === size.h) return;
    size = { w, h };
    node.style.width = `${w}px`;
    node.style.height = `${h}px`;
    ed.layout({ width: w, height: h });
    // Monaco scrolls a span into view; the first line shown is its first
    ed.setScrollTop(0);
    onResize?.(size);
  }

  // the widest line Monaco has drawn (in layout pixels: the camera's
  // scale does not change it); drawing comes after a change, so asked again
  function measure() {
    const widest = Math.max(0, ...[...node.querySelectorAll(".view-line > span")].map((line) => line.offsetWidth));
    if (Math.abs(widest - drawnWidth) < 2) return;
    drawnWidth = widest;
    resize();
  }

  let pending = 0;
  const changed = model.onDidChangeContent(() => {
    cancelAnimationFrame(pending);
    pending = requestAnimationFrame(refresh);
  });

  const wordAt = (position) => {
    const word = position && model.getWordAtPosition(position);
    return word && isRef?.(word.word) && word.word !== name ? word.word : null;
  };
  ed.onMouseDown((event) => {
    const pull = event.event.metaKey || event.event.ctrlKey || event.event.altKey;
    const word = wordAt(event.target.position);
    if (!pull || !word) return;
    event.event.preventDefault();
    event.event.stopPropagation();
    onPull?.(word, event.target.position.lineNumber);
  });
  let hovered = null;
  ed.onMouseMove((event) => {
    const word = wordAt(event.target.position);
    if (word === hovered) return;
    hovered = word;
    node.classList.toggle("ref-hover", Boolean(word));
    onHoverRef?.(word, event.target.position?.lineNumber);
  });
  ed.onMouseLeave(() => {
    if (hovered) onHoverRef?.(null);
    hovered = null;
  });
  ed.onDidFocusEditorText(() => { node.classList.add("editing"); onFocus?.(); });
  ed.onDidBlurEditorText(() => { node.classList.remove("editing"); onBlur?.(); });
  ed.onKeyDown((event) => {
    const { browserEvent: e } = event;
    if (e.key === "Escape" && !document.querySelector(".suggest-widget.visible")) {
      event.preventDefault();
      event.stopPropagation();
      onEscape?.();
    } else if (e.key === "Enter" && (e.metaKey || e.ctrlKey) && !e.shiftKey) {
      event.preventDefault();
      event.stopPropagation();
      onEvalForm?.(model.getOffsetAt(ed.getPosition()));
    }
  });

  refresh();
  // the font arrives after the first measure
  document.fonts?.ready.then(() => { ed.remeasureFonts?.(); refresh(); });

  return {
    node,
    editor: ed,
    name,
    span: () => span,
    refresh,
    // the y (in the editor's own pixels) of a line, for wires
    lineTop: (lineNumber) => ed.getTopForLineNumber(lineNumber) - ed.getTopForLineNumber(span.start) + 4,
    // the first line using `word` within the span, for a wire's start
    lineOf(word) {
      const text = model.getValue().slice(span.from, span.to);
      const at = text.search(new RegExp(`(^|[\\s()\\[\\]'\`,])${word.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?=[\\s()\\[\\]]|$)`));
      return at < 0 ? span.start : model.getPositionAt(span.from + at + 1).lineNumber;
    },
    focus(at) {
      ed.focus();
      if (at) ed.setPosition(at);
      else if (!ed.hasTextFocus()) ed.setPosition({ lineNumber: span.start, column: 1 });
    },
    select(range) {
      ed.setSelection(range);
      ed.focus();
    },
    dispose() {
      cancelAnimationFrame(pending);
      changed.dispose();
      ed.dispose();
      node.remove();
    },
  };
}
