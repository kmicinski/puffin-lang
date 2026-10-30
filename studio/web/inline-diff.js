// Hunks (hunks.js) drawn in place (ported from Slog Studio) in a Monaco editor whose text stays the
// author's: the lines a change removes are tinted red, the lines it brings
// are green ghost lines in view zones under the line they follow, the forms
// it touches carry a bar in the margin, and the overview ruler lists them.
// The text itself is never touched.
//
// A hunk given to `show` may carry
//   tone      a class colouring its bars (a thread's, or "history")
//   forms     [[from, to]] line ranges to bar in the margin
//   header()  a node for a slim line above the hunk (its controls), or none
//   key       what `reveal` and `next` name it by
// F7 and Shift+F7 move the cursor to the next and previous hunk.

export function createInlineDiff({ monaco, editor }, { onMove = () => {} } = {}) {
  const decorations = editor.createDecorationsCollection([]);
  let zones = [];
  let shown = [];

  function show(list) {
    shown = list;
    const count = editor.getModel()?.getLineCount() ?? 0;
    const lane = monaco.editor.OverviewRulerLane.Left;
    const items = [];
    for (const hunk of list) {
      for (const { line, from, to } of hunk.removed) {
        if (line > count) continue;
        items.push({
          range: new monaco.Range(line, 1, line, 1),
          options: { isWholeLine: true, className: "ip-del", overviewRuler: { color: "rgba(220, 50, 47, 0.7)", position: lane } },
        });
        if (from) items.push({ range: new monaco.Range(line, from, line, to), options: { inlineClassName: "ip-del-chars" } });
      }
      for (const [from, to] of hunk.forms ?? []) {
        items.push({
          range: new monaco.Range(Math.min(from, count), 1, Math.min(to, count), 1),
          options: { isWholeLine: true, linesDecorationsClassName: `ip-form ${hunk.tone}` },
        });
      }
      for (const { after } of hunk.added) {
        const line = Math.max(1, Math.min(after, count));
        items.push({
          range: new monaco.Range(line, 1, line, 1),
          options: { overviewRuler: { color: "rgba(133, 153, 0, 0.8)", position: lane } },
        });
      }
    }
    decorations.set(items);
    editor.changeViewZones((accessor) => {
      for (const id of zones) accessor.removeZone(id);
      zones = [];
      for (const hunk of list) {
        const blocks = hunk.added.map((block) => ({ ...block, header: null }));
        const header = hunk.header?.() ?? null;
        if (header) {
          // a header over lines brought in right where the hunk starts shares their zone
          const above = Math.max(0, hunk.first - 1);
          const block = blocks.find((b) => b.after === above);
          if (block) block.header = header;
          else blocks.unshift({ after: above, lines: [], header });
        }
        for (const block of blocks) zones.push(accessor.addZone(zone(block, hunk.tone)));
      }
    });
  }

  function zone({ after, lines, header }, tone) {
    const { fontFamily, fontSize, lineHeight } = editor.getOption(monaco.editor.EditorOption.fontInfo);
    const dom = element("div", `ip-zone ${tone}`);
    if (header) {
      header.style.height = `${lineHeight + 4}px`;
      dom.append(header);
    }
    for (const { text, from, to } of lines) {
      const line = dom.appendChild(element("div", "ip-add"));
      Object.assign(line.style, { fontFamily, fontSize: `${fontSize}px`, lineHeight: `${lineHeight}px`, height: `${lineHeight}px` });
      if (from) line.append(text.slice(0, from - 1), element("span", "ip-add-chars", text.slice(from - 1, to - 1)), text.slice(to - 1));
      else line.textContent = text || " ";
    }
    const margin = element("div", `ip-zone-margin ${tone}`);
    lines.forEach(() => { margin.appendChild(element("div", "ip-plus", "+")).style.height = `${lineHeight}px`; });
    margin.style.lineHeight = `${lineHeight}px`;
    if (header) margin.style.paddingTop = `${lineHeight + 4}px`;
    return {
      afterLineNumber: after,
      heightInPx: (header ? lineHeight + 4 : 0) + lines.length * lineHeight,
      domNode: dom,
      marginDomNode: margin,
    };
  }

  function reveal(hunk) {
    const count = editor.getModel().getLineCount();
    const line = Math.max(1, Math.min(hunk.first, count));
    editor.revealLinesInCenterIfOutsideViewport(Math.max(1, line - 1), Math.min(count, hunk.last + 2));
    editor.setPosition({ lineNumber: line, column: 1 });
    onMove(hunk);
  }

  // The hunk after (or before) the cursor, round past the end.
  function next(step = 1) {
    if (!shown.length) return null;
    const order = [...shown].sort((a, b) => a.first - b.first);
    const line = editor.getPosition()?.lineNumber ?? 0;
    const hunk = step > 0
      ? order.find((h) => h.first > line) ?? order[0]
      : order.findLast((h) => h.first < line) ?? order.at(-1);
    reveal(hunk);
    return hunk;
  }

  // actions, not commands: a command's key would reach every editor on the page
  editor.addAction({ id: "puffin.next-change", label: "Next change", keybindings: [monaco.KeyCode.F7], run: () => next(1) });
  editor.addAction({
    id: "puffin.previous-change", label: "Previous change",
    keybindings: [monaco.KeyMod.Shift | monaco.KeyCode.F7], run: () => next(-1),
  });

  return {
    show,
    clear: () => show([]),
    reveal(key) {
      const hunk = shown.find((h) => h.key === key);
      if (hunk) reveal(hunk);
      return hunk ?? null;
    },
    next,
    shown: () => shown,
  };
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}
