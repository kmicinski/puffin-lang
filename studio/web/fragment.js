// A fragment (docs/VIEW.md): one definition of the working set, live --
// a small Monaco editor on its file's own model (editor.js `fragment`),
// narrowed to the definition (span.js), its cross-references marked and
// followable (names.js). Typing in it is typing in the file: every other
// view of the file follows as it is typed, and the studio hears it
// through files.js as from the main editor.
//
// It is as wide as its longest line (the widest Monaco has drawn, else
// an estimate), within limits -- `maxWidth()`, the room the board can
// show at reading distance; past that its lines wrap -- and as tall as
// what it shows; it never scrolls, the board's camera is what moves.
// `onResize` says when its size changed, so what sits around it can move.

import { narrow, lineOf } from "./span.js";
import { bindNames } from "./names.js";

const MIN_WIDTH = 360;
export const MAX_WIDTH = 820;

export function createFragment({ editor, model, path, name, maxWidth, find, onPull, onFocusDef, onHover, onFocus, onBlur, onEscape, onEvalForm, onEdit, onResize }) {
  const monaco = editor.raw.monaco;
  const node = document.createElement("div");
  node.className = "frag-code";
  const view = editor.fragment(node, path);
  view.setModel(model);
  const span = narrow(monaco, view, name);
  const names = bindNames(monaco, view, {
    find: (word) => (word === name ? null : find(word)),
    span: () => span.span(),
    onPull,
    onFocus: onFocusDef,
    onHover,
  });

  let gone = false;
  function refresh() {
    gone = !span.refresh();
    node.classList.toggle("gone", gone);
    names.refresh();
    resize();
    requestAnimationFrame(measure);
  }

  let size = { w: 0, h: 0 };
  let drawn = 0;
  function resize() {
    const shown = span.span();
    if (!shown) return;
    const longest = Math.max(20, ...Array.from({ length: shown.end - shown.start + 1 }, (_, i) => model.getLineLength(Math.min(shown.start + i, model.getLineCount()))));
    const char = view.getOption(monaco.editor.EditorOption.fontInfo).typicalHalfwidthCharacterWidth || 7.8;
    const gutter = view.getLayoutInfo().contentLeft;
    const room = Math.min(MAX_WIDTH, maxWidth?.() ?? MAX_WIDTH);
    const w = Math.ceil(Math.min(room, Math.max(MIN_WIDTH, gutter + Math.max(drawn, (longest + 2) * char) + 16)));
    // laid out at its width first: how tall it is depends on what wraps
    if (w !== size.w) view.layout({ width: w, height: Math.max(size.h, 20) });
    const h = view.getContentHeight();
    if (w === size.w && h === size.h) return;
    size = { w, h };
    node.style.width = `${w}px`;
    node.style.height = `${h}px`;
    view.layout({ width: w, height: h });
    // Monaco scrolls to show the cursor; the first line shown is the span's
    view.setScrollTop(0);
    onResize?.(size);
  }

  // the widest line Monaco has drawn (layout pixels: the camera's scale
  // does not change them); drawing comes after a change, so asked again
  function measure() {
    const widest = Math.max(0, ...[...node.querySelectorAll(".view-line > span")].map((line) => line.offsetWidth));
    if (Math.abs(widest - drawn) < 2) return;
    drawn = widest;
    resize();
  }

  let pending = 0;
  const changed = model.onDidChangeContent((event) => {
    // typed here, not in another view of the file: the lines it touched
    if (view.hasTextFocus()) for (const c of event.changes) onEdit?.(c.range.startLineNumber, c.range.startLineNumber + c.text.split("\n").length - 1);
    cancelAnimationFrame(pending);
    pending = requestAnimationFrame(refresh);
  });
  view.onDidFocusEditorText(() => onFocus?.());
  view.onDidBlurEditorText(() => onBlur?.());
  view.onKeyDown((event) => {
    const e = event.browserEvent;
    if (e.key === "Escape" && !document.querySelector(".suggest-widget.visible")) {
      event.preventDefault();
      event.stopPropagation();
      onEscape?.();
    } else if (e.key === "Enter" && (e.metaKey || e.ctrlKey) && !e.shiftKey) {
      event.preventDefault();
      event.stopPropagation();
      onEvalForm?.(model.getOffsetAt(view.getPosition()));
    }
  });

  refresh();
  // the font arrives after the first measure
  document.fonts?.ready.then(() => { view.remeasureFonts?.(); refresh(); });

  return {
    node,
    view,
    refresh,
    gone: () => gone,
    size: () => size,
    // the y (in the fragment's own pixels, from its top) of the first line
    // using `word`, for a wire's start
    yOf(word) {
      const shown = span.span();
      if (!shown) return 0;
      return view.getTopForLineNumber(lineOf(model, shown, word)) - view.getTopForLineNumber(shown.start) + 4 + view.getOption(monaco.editor.EditorOption.lineHeight) / 2;
    },
    focus(at) {
      view.focus();
      const shown = span.span();
      if (at) view.setPosition(at);
      else if (shown) view.setPosition({ lineNumber: shown.start, column: 1 });
    },
    select(range) {
      view.setSelection(range);
      view.focus();
    },
    dispose() {
      cancelAnimationFrame(pending);
      changed.dispose();
      names.dispose();
      span.dispose();
      view.dispose();
      node.remove();
    },
  };
}
