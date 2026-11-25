// Cross-references in code (docs/VIEW.md): in any view of a file -- the
// focus pane, a fragment of the working set -- the names that are
// top-level definitions of the program are marked (a dotted underline),
// and following one is a click away:
//
//   ⌘/ctrl/alt-click   pull its definition into the working set
//   ⌘⇧-click           focus it
//   hover              its row lights on the board, wherever it is
//
// `find(word)` says which definition a word names, seen from this view
// (null: not one of the program's, or the definition shown here itself);
// `span()` the part of the file this view shows, where names are marked.

// a word of code, as far as a name can run (view.js reads them too)
export const WORD = /[^\s()[\];",'`]+/;
const WORDS = new RegExp(WORD.source, "g");

export function bindNames(monaco, view, { find, span, onPull, onFocus, onHover }) {
  const marks = view.createDecorationsCollection();
  const underline = view.createDecorationsCollection();

  // the references in what the view shows, marked
  function refresh() {
    const model = view.getModel();
    const shown = span();
    if (!model || !shown) return marks.clear();
    const text = model.getValue();
    const list = [];
    WORDS.lastIndex = shown.from;
    for (let m = WORDS.exec(text); m && m.index < shown.to; m = WORDS.exec(text)) {
      if (!find(m[0])) continue;
      const range = monaco.Range.fromPositions(model.getPositionAt(m.index), model.getPositionAt(m.index + m[0].length));
      list.push({ range, options: { inlineClassName: "code-ref" } });
    }
    marks.set(list);
  }

  const defAt = (position) => {
    const word = position && view.getModel()?.getWordAtPosition(position);
    return word ? { def: find(word.word), word } : null;
  };

  view.onMouseDown((event) => {
    const e = event.event;
    if (!(e.metaKey || e.ctrlKey || e.altKey) || event.target.type !== monaco.editor.MouseTargetType.CONTENT_TEXT) return;
    const at = defAt(event.target.position);
    if (!at?.def) return;
    e.preventDefault();
    e.stopPropagation();
    const line = event.target.position.lineNumber;
    // after Monaco's own handling of the click
    setTimeout(() => (e.shiftKey ? onFocus(at.def) : onPull(at.def, line)), 0);
  });

  let hovered = null;
  view.onMouseMove((event) => {
    const e = event.event;
    const at = defAt(event.target.position);
    const def = at?.def ?? null;
    if (def !== hovered) {
      hovered = def;
      onHover?.(def);
    }
    // with the modifier held, the name under the pointer says what a click does
    if (!def || !(e.metaKey || e.ctrlKey || e.altKey)) return underline.clear();
    const line = event.target.position.lineNumber;
    underline.set([{ range: new monaco.Range(line, at.word.startColumn, line, at.word.endColumn), options: { inlineClassName: "code-ref-armed" } }]);
  });
  view.onMouseLeave(() => {
    underline.clear();
    if (hovered) onHover?.(null);
    hovered = null;
  });
  view.onKeyUp(() => underline.clear());

  return { refresh, dispose: () => { marks.clear(); underline.clear(); } };
}
