// Focus and context (docs/VIEW-FOCUS.md): one definition in focus, the
// code it is read with beside it, and its neighbourhood of the board
// always in view -- three views of the same text, kept current as it
// changes, with no mode between them.
//
// - The focus: the editor itself, showing one definition (its comment
//   and `(: name τ)` above it included) and the rest of its file hidden,
//   so editing it is editing the file. "≡ whole file" (⌥O) shows the
//   rest; the focus then follows the cursor, and ⌥O narrows again.
// - The working set: definitions pulled in beside the focus, from any
//   file, each a small live editor on the same text (an edit in one is an
//   edit to its file, seen everywhere at once). ⌘-click a name in any of
//   the code pulls its definition in; ⌘⇧-click focuses it. When the
//   column is full the least wanted first shrink to their signature, then
//   go to the shelf below it, a click from coming back: wanted is pinned
//   (always kept), then fresh (touched lately), and a neighbour of the
//   focus counts as two minutes fresher. Fragments with no edge to the
//   focus fade.
// - The neighbourhood: the board around the focus -- what uses it above,
//   what it uses below, its module's other definitions and the
//   properties that mention it. Click a node: pulled in; ⌘-click or
//   double-click: focused. "▦ board" (⌘⇧B) grows it into the whole board
//   beside the focus; a row's ↗ there focuses that row.
// - Focusing keeps a history (‹ ›, ⌥← ⌥→), and the definition left
//   behind goes to the top of the working set: a jump never loses where
//   it came from.
//
// What is out, focused and pinned is this browser's, per project.

import { forms, balanced } from "./lexer.js";

const KIND = { fun: "ƒ", val: "·", type: "τ", alias: "≡", grammar: "G", property: "?" };
// the forms that define a name the outline knows
const DEFINES = new Set(["define", "define-type", "define-type-alias", "define-grammar", "define-foreign-type", "check-property", "check-example"]);
// a neighbour of the focus counts as this much fresher when space is short
const NEAR = 120000;
// a fragment's body is at most this tall before it scrolls
const BODY_MAX = 300;
const HEAD = 30;
const COLLAPSED = 48;
// a file this short is shown whole when nothing is focused yet
const SHORT_FILE = 60;
const NODES_MAX = 10;
const SVG = "http://www.w3.org/2000/svg";

const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};
const short = (path) => path.replace(/\.puf$/, "");
const same = (a, b) => Boolean(a && b) && a.path === b.path && a.name === b.name;
const key = (def) => `${def.path}\u001f${def.name}`;

// The lines a definition spans in `text`: its form, the `(: name τ)`
// right before it, and the comment lines right above those.
export function spanOf(text, name) {
  const all = forms(text);
  const at = all.findIndex((f) => f.name === name && DEFINES.has(f.head));
  if (at < 0) return null;
  let start = all[at].line;
  const before = all[at - 1];
  if (before?.head === ":" && before.name === name) start = before.line;
  const lines = text.split("\n");
  while (start > 1 && /^\s*;/.test(lines[start - 2])) start--;
  return { start, end: all[at].endLine };
}

// The definition whose form holds `line` of `text`, by name, or null.
function nameAt(text, line) {
  const form = forms(text).find((f) => f.line <= line && line <= f.endLine && f.name && (DEFINES.has(f.head) || f.head === ":"));
  return form?.name ?? null;
}

export function createWorkset({ editor, files, board, stage, layout }) {
  const monaco = editor.raw?.monaco;
  const main = editor.raw?.editor;
  if (!monaco || !main) return { changed() {}, navigate: () => false, setOn() {} };

  let on = false;
  let focus = null; // { path, name }
  let whole = false; // the focus pane shows the whole file
  let past = []; // focus history
  let at = -1;
  let set = []; // the working set, top first: { path, name, pinned, touched, from, node, view, ... }
  let shelf = []; // set aside for want of room: { path, name }
  // offered: what the focus uses (then what uses it), shown in the room the
  // set leaves free until taken -- clicked into, pinned -- or the focus moves
  let offered = [];
  let restored = false;
  let moving = false; // the focus is being moved here: the cursor's events are ours

  // ---- the outline (board.rs), by name -----------------------------------------------

  const outline = () => board.outline();
  function find(name) {
    for (const m of outline()) {
      const item = m.items.find((i) => i.name === name);
      if (item) return { path: m.path, name, item, module: m };
    }
    return null;
  }
  const itemOf = (def) => outline().find((m) => m.path === def.path)?.items.find((i) => i.name === def.name);
  // what `def` uses and what uses it, as defs
  function neighbours(def) {
    const item = itemOf(def);
    const uses = (item?.uses ?? []).map(find).filter(Boolean).filter((d) => !same(d, def));
    const users = [];
    for (const m of outline()) for (const i of m.items) if (i.uses.includes(def.name) && !(m.path === def.path && i.name === def.name)) users.push({ path: m.path, name: i.name, item: i, module: m });
    return { uses, users };
  }
  function related(a, b) {
    if (!a || !b) return false;
    const ia = itemOf(a);
    const ib = itemOf(b);
    return Boolean(ia?.uses.includes(b.name) || ib?.uses.includes(a.name));
  }

  // ---- the page -----------------------------------------------------------------------

  const column = stage.querySelector(".editor-column");
  const head = el("div", "ws-head");
  column.prepend(head);
  const side = el("div", "ws-side");
  const setPane = el("div", "ws-set");
  const setList = el("div", "ws-list");
  const shelfRow = el("div", "ws-shelf");
  setPane.append(setList, shelfRow);
  const graph = el("div", "ws-graph");
  side.append(setPane, graph);
  stage.append(side);

  // the column's room changed: fit the set again, redraw the wires, and
  // tell the board where the focus ends (it grows over the side)
  new ResizeObserver(() => {
    if (!on) return;
    fit();
    drawWires();
    stage.style.setProperty("--ws-left", `${column.getBoundingClientRect().right - stage.getBoundingClientRect().left + 8}px`);
  }).observe(side);

  // ---- the focus ------------------------------------------------------------------------

  const spans = main.createDecorationsCollection();

  // Hide all of `view`'s model but `span`, kept by `collection` (a tracked
  // range, so it moves with edits while the text is unbalanced).
  function narrowView(view, collection, span) {
    const model = view.getModel();
    if (!model) return;
    const lines = model.getLineCount();
    const start = Math.min(span.start, lines);
    const end = Math.min(Math.max(span.end, start), lines);
    collection.set([{ range: new monaco.Range(start, 1, end, model.getLineMaxColumn(end)), options: { stickiness: monaco.editor.TrackedRangeStickiness.AlwaysGrowsWhenTypingAtEdges } }]);
    const areas = [];
    if (start > 1) areas.push(new monaco.Range(1, 1, start - 1, 1));
    if (end < lines) areas.push(new monaco.Range(end + 1, 1, lines, 1));
    view.setHiddenAreas(areas);
  }

  // The span of `name` in `view`'s text now: found again when the text
  // reads, else where the tracked range has moved to.
  function currentSpan(view, collection, name) {
    const text = view.getModel().getValue();
    const found = balanced(text) ? spanOf(text, name) : null;
    if (found) return found;
    const range = collection.getRange(0);
    return range ? { start: range.startLineNumber, end: range.endLineNumber } : null;
  }

  function narrowFocus() {
    if (!focus || whole || files.active() !== focus.path) {
      main.setHiddenAreas([]);
      return;
    }
    const span = spanOf(main.getModel().getValue(), focus.name);
    if (!span) return main.setHiddenAreas([]);
    narrowView(main, spans, span);
  }

  // Focus `def`: the editor shows it (opening its file), the history
  // gains it, and the definition left behind joins the working set.
  function show(def, { push = true, select = null } = {}) {
    if (!def) return;
    const before = focus;
    if (!same(before, def) && before && push && !whole) pull(before, { from: def.name, quiet: true, cameFrom: true });
    focus = { path: def.path, name: def.name };
    whole = false;
    if (push && !same(past[at], focus)) {
      past = past.slice(0, at + 1);
      past.push(focus);
      at = past.length - 1;
    }
    // focused, it is no longer beside itself
    const there = set.find((f) => same(f, focus));
    if (there) drop(there, { quiet: true });
    shelf = shelf.filter((d) => !same(d, focus));
    moving = true;
    if (files.active() !== def.path) files.open(def.path);
    narrowFocus();
    offer();
    const span = spanOf(main.getModel().getValue(), def.name);
    if (span) {
      main.setScrollTop(0);
      if (select) main.setSelection(select);
      else main.setPosition({ lineNumber: Math.min(span.start + (span.end > span.start ? 1 : 0), span.end), column: 1 });
    }
    moving = false;
    main.focus();
    render();
  }

  function setWhole(value) {
    whole = value;
    if (!whole && focus) {
      // narrowing: to the definition the cursor is in, if any
      const name = nameAt(main.getModel().getValue(), main.getPosition()?.lineNumber ?? 1);
      if (name && name !== focus.name) return show({ path: files.active(), name });
    }
    narrowFocus();
    if (whole && focus) {
      const span = spanOf(main.getModel().getValue(), focus.name);
      if (span) main.revealLineNearTop(span.start);
    }
    render();
  }

  function back(delta) {
    const next = at + delta;
    if (next < 0 || next >= past.length) return;
    at = next;
    show(past[at], { push: false });
  }

  // The cursor left the focused definition (someone navigated: the
  // palette, a hole, the voice, the arrows): the focus follows it. With
  // the whole file shown, the focus is just where the cursor is.
  main.onDidChangeCursorPosition((event) => {
    if (!on || moving || !focus) return;
    const path = files.active();
    const model = main.getModel();
    if (!path || !model) return;
    const line = event.position.lineNumber;
    if (whole) {
      const name = nameAt(model.getValue(), line);
      if (name && !(focus.path === path && focus.name === name)) {
        focus = { path, name };
        render();
      }
      return;
    }
    const span = path === focus.path ? currentSpan(main, spans, focus.name) : null;
    if (span && span.start <= line && line <= span.end) return;
    const name = nameAt(model.getValue(), line);
    if (name) show({ path, name });
    else setWhole(true);
  });

  // The editor showed another file by other means (a chip, the tree): the
  // focus goes with it, the whole file.
  function opened(path) {
    if (!on || moving) return;
    if (focus?.path === path) return narrowFocus();
    const name = nameAt(main.getModel().getValue(), main.getPosition()?.lineNumber ?? 1);
    focus = name ? { path, name } : { path, name: null };
    whole = true;
    narrowFocus();
    render();
  }

  // the text changed: keep each narrowed view on its definition
  let pending = 0;
  function textChanged() {
    cancelAnimationFrame(pending);
    pending = requestAnimationFrame(() => {
      if (!on) return;
      if (focus && !whole && files.active() === focus.path) {
        const span = currentSpan(main, spans, focus.name);
        if (span) narrowView(main, spans, span);
      }
      for (const fragment of [...set, ...offered]) refit(fragment);
    });
  }
  main.onDidChangeModelContent(textChanged);

  // ---- the header ---------------------------------------------------------------------------

  function renderHead() {
    head.replaceChildren();
    const nav = el("span", "ws-nav");
    const prev = el("button", "ws-icon", "‹");
    prev.title = "Back to the previous focus (⌥←)";
    prev.disabled = at <= 0;
    prev.addEventListener("click", () => back(-1));
    const next = el("button", "ws-icon", "›");
    next.title = "Forward (⌥→)";
    next.disabled = at >= past.length - 1;
    next.addEventListener("click", () => back(1));
    nav.append(prev, next);
    head.append(nav);
    const item = focus && itemOf(focus);
    if (whole || !item) {
      head.append(el("span", "ws-title", focus ? short(focus.path) : ""), el("span", "ws-sub", whole ? "whole file" : ""));
      if (item) head.append(el("span", "ws-sig", `· at ${focus.name}`));
    } else {
      head.append(el("span", "ws-kind", KIND[item.kind] ?? "·"), el("span", "ws-title", focus.name), el("span", "ws-module", short(focus.path)));
      head.append(el("span", "ws-sig", item.sig.replace(/^(val|type|grammar) \S+\s*/, "")));
    }
    const grow = el("button", "ws-toggle", whole ? `◎ ${item && focus.name ? `just ${focus.name}` : "a definition"}` : "≡ whole file");
    grow.title = whole ? "Narrow to the definition at the cursor (⌥O)" : "Show the rest of the file (⌥O)";
    grow.disabled = whole && !item;
    grow.addEventListener("click", () => setWhole(!whole));
    head.append(grow);
  }

  // ---- the working set -------------------------------------------------------------------

  function offer() {
    for (const fragment of offered) dispose(fragment);
    offered = [];
    if (!focus?.name || whole) return;
    const { uses, users } = neighbours(focus);
    const code = (d) => ["fun", "val"].includes(d.item?.kind) && !set.some((f) => same(f, d));
    for (const def of [...uses.filter(code), ...users.filter(code)].slice(0, 6)) {
      const fragment = make(def, { offered: true });
      if (fragment) offered.push(fragment);
    }
  }

  // an offered fragment the author used: one of the set now
  function take(fragment) {
    if (!fragment.offered) return;
    fragment.offered = false;
    offered = offered.filter((f) => f !== fragment);
    // last of the set: just where it is on the screen
    set.push(fragment);
    render();
  }

  function dispose(fragment) {
    fragment.view.dispose();
    fragment.node.remove();
  }

  // Pull `def` in beside the focus (or bring it to the top if it is in).
  function pull(def, { from = focus?.name, quiet = false, cameFrom = false } = {}) {
    // (the definition the focus is leaving is still the focus, just)
    if (!def?.name || (same(def, focus) && !cameFrom)) return;
    shelf = shelf.filter((d) => !same(d, def));
    const waiting = offered.find((f) => same(f, def));
    if (waiting) return take(waiting);
    let fragment = set.find((f) => same(f, def));
    if (fragment) {
      set = [fragment, ...set.filter((f) => f !== fragment)];
      fragment.touched = Date.now();
      fragment.node.classList.remove("flash");
      void fragment.node.offsetWidth;
      fragment.node.classList.add("flash");
    } else {
      fragment = make(def, { from, cameFrom });
      if (!fragment) return;
      set.unshift(fragment);
    }
    if (!quiet) render();
  }

  function make(def, { from, cameFrom, pinned = false, offered = false }) {
    const text = files.texts()[def.path];
    if (text === undefined) return null;
    const model = editor.model(def.path, text);
    const node = el("section", "ws-frag arriving");
    const top = el("div", "ws-frag-head");
    const body = el("div", "ws-frag-body");
    node.append(top, body);
    const view = editor.fragment(body, def.path);
    if (!view) return null;
    const fragment = { path: def.path, name: def.name, pinned, touched: Date.now(), from, cameFrom, offered, node, top, body, view, collection: view.createDecorationsCollection(), height: 0, gone: false };
    view.setModel(model);
    view.onDidContentSizeChange(() => size(fragment));
    view.onDidFocusEditorText(() => {
      fragment.touched = Date.now();
      node.classList.add("editing");
      take(fragment);
    });
    view.onDidBlurEditorText(() => node.classList.remove("editing"));
    view.onKeyDown((event) => {
      if (event.keyCode === monaco.KeyCode.Escape && !event.shiftKey) {
        main.focus();
      }
    });
    bindNames(view, fragment);
    refit(fragment);
    requestAnimationFrame(() => requestAnimationFrame(() => node.classList.remove("arriving")));
    return fragment;
  }

  // keep the fragment on its definition as the text moves
  function refit(fragment) {
    const span = currentSpan(fragment.view, fragment.collection, fragment.name);
    fragment.gone = !span;
    if (span) narrowView(fragment.view, fragment.collection, span);
    fragment.node.classList.toggle("gone", fragment.gone);
  }

  let refitting = 0;
  function size(fragment) {
    const height = Math.min(BODY_MAX, fragment.view.getContentHeight());
    if (height === fragment.height) return;
    fragment.height = height;
    if (!fragment.collapsed) fragment.body.style.height = `${fragment.height}px`;
    cancelAnimationFrame(refitting);
    refitting = requestAnimationFrame(fit);
  }

  function drop(fragment, { quiet = false } = {}) {
    set = set.filter((f) => f !== fragment);
    offered = offered.filter((f) => f !== fragment);
    dispose(fragment);
    if (!quiet) render();
  }

  // Fit the set to its column: the most wanted get their bodies, the next
  // their signature line, the rest the shelf.
  function fit() {
    const room = setList.clientHeight;
    if (!room) return;
    const wanted = (f) => (f.pinned ? Infinity : f.touched + (related(f, focus) ? NEAR : 0));
    let left = room;
    const decided = new Map();
    for (const fragment of [...set].sort((a, b) => wanted(b) - wanted(a))) {
      const full = HEAD + fragment.height + 10;
      if (full <= left) {
        decided.set(fragment, "full");
        left -= full;
      } else if (COLLAPSED <= left || fragment.pinned) {
        decided.set(fragment, "collapsed");
        left -= COLLAPSED;
      } else {
        decided.set(fragment, "shelf");
      }
    }
    for (const [fragment, how] of decided) {
      if (how === "shelf") {
        shelf.unshift({ path: fragment.path, name: fragment.name });
        drop(fragment, { quiet: true });
        continue;
      }
      fragment.collapsed = how === "collapsed";
      fragment.node.classList.toggle("collapsed", fragment.collapsed);
      fragment.body.style.height = fragment.collapsed ? "0px" : `${fragment.height}px`;
    }
    // what is offered fills what room is left, in order, whole or not at all
    for (const fragment of offered) {
      const full = HEAD + fragment.height + 10;
      const fits = full <= left;
      if (fits) left -= full;
      // kept laid out at the column's width, out of sight: it measures
      fragment.node.classList.toggle("unfit", !fits);
    }
    if ([...decided.values()].includes("shelf")) renderShelf();
    save();
  }

  function renderSet() {
    side.classList.toggle("empty", !set.length && !shelf.length);
    const all = [...set, ...offered];
    for (const fragment of all) renderFragment(fragment);
    // in order, top first, moving only what moved
    all.forEach((fragment, i) => {
      if (setList.children[i] !== fragment.node) setList.insertBefore(fragment.node, setList.children[i] ?? null);
    });
    if (!all.length) {
      setList.replaceChildren(el("div", "ws-hint", "⌘-click a name in the code, or click a node in the neighbourhood, to read its definition here beside the focus."));
    } else {
      setList.querySelector(".ws-hint")?.remove();
    }
    renderShelf();
    requestAnimationFrame(fit);
  }

  function renderFragment(fragment) {
    const item = itemOf(fragment);
    const top = fragment.top;
    top.replaceChildren();
    const kind = el("span", "ws-kind", KIND[item?.kind] ?? "·");
    const name = el("button", "ws-frag-name", fragment.name);
    name.title = "Focus on it (⌘-click a name does the same)";
    name.addEventListener("click", () => show(fragment));
    top.append(kind, name, el("span", "ws-module", short(fragment.path)));
    // how it stands to the focus
    const relation = relationTo(fragment);
    if (relation) top.append(el("span", `ws-rel ${relation.kind}`, fragment.offered ? `${relation.text} · offered` : relation.text));
    top.append(el("span", "ws-sig", fragment.collapsed || !relation ? (item?.sig.replace(/^(val|type|grammar) \S+\s*/, "") ?? "") : ""));
    const tools = el("span", "ws-tools");
    const pin = el("button", `ws-icon${fragment.pinned ? " on" : ""}`, "⊙");
    pin.title = fragment.pinned ? "Unpin" : "Pin: kept, whatever else needs the room";
    pin.addEventListener("click", () => {
      fragment.pinned = !fragment.pinned;
      if (fragment.offered) take(fragment);
      else render();
    });
    const up = el("button", "ws-icon", "↑");
    up.title = "Focus on it";
    up.addEventListener("click", () => show(fragment));
    const close = el("button", "ws-icon", "✕");
    close.title = "Put it away";
    close.addEventListener("click", () => drop(fragment));
    tools.append(pin, up, close);
    top.append(tools);
    top.ondblclick = (event) => { if (!event.target.closest("button")) { fragment.collapsed = !fragment.collapsed; fragment.touched = Date.now(); render(); } };
    fragment.node.classList.toggle("distant", !fragment.pinned && Boolean(focus?.name) && !related(fragment, focus));
    fragment.node.classList.toggle("pinned", fragment.pinned);
    fragment.node.classList.toggle("offered", fragment.offered);
  }

  function relationTo(def) {
    if (!focus?.name) return null;
    const mine = itemOf(def);
    const theirs = itemOf(focus);
    if (theirs?.uses.includes(def.name)) return { kind: "callee", text: `${focus.name} uses it` };
    if (mine?.uses.includes(focus.name)) return { kind: "caller", text: `uses ${focus.name}` };
    return null;
  }

  function renderShelf() {
    shelfRow.replaceChildren();
    shelf = shelf.filter((d) => find(d.name));
    if (!shelf.length) return;
    shelfRow.append(el("span", "ws-shelf-label", "set aside"));
    for (const def of shelf.slice(0, 12)) {
      const chip = el("button", "ws-chip", def.name);
      chip.title = `${short(def.path)} · bring it back`;
      chip.addEventListener("click", () => pull(def));
      shelfRow.append(chip);
    }
  }

  // ---- names in the code: ⌘-click pulls in, ⌘⇧-click focuses --------------------------------

  function bindNames(view) {
    const underline = view.createDecorationsCollection();
    const defAt = (position) => {
      const word = position && view.getModel()?.getWordAtPosition(position)?.word;
      return word ? find(word) : null;
    };
    view.onMouseDown((event) => {
      const browser = event.event;
      if (!(browser.metaKey || browser.ctrlKey) || event.target.type !== monaco.editor.MouseTargetType.CONTENT_TEXT) return;
      const def = defAt(event.target.position);
      if (!def || same(def, focus) && !browser.shiftKey) return;
      browser.preventDefault();
      browser.stopPropagation();
      // after Monaco's own handling of the click
      setTimeout(() => (browser.shiftKey ? show(def) : pull(def)), 0);
    });
    view.onMouseMove((event) => {
      const browser = event.event;
      const def = (browser.metaKey || browser.ctrlKey) && on ? defAt(event.target.position) : null;
      if (!def) return underline.clear();
      const word = view.getModel().getWordAtPosition(event.target.position);
      const line = event.target.position.lineNumber;
      underline.set([{ range: new monaco.Range(line, word.startColumn, line, word.endColumn), options: { inlineClassName: "ws-xref", hoverMessage: { value: `\`${itemOf(def)?.sig ?? def.name}\` — click: beside the focus · ⇧-click: focus on it` } } }]);
    });
    view.onMouseLeave(() => underline.clear());
    view.onKeyUp(() => underline.clear());
  }
  bindNames(main);

  // ---- the neighbourhood ---------------------------------------------------------------------

  const wires = document.createElementNS(SVG, "svg");
  wires.classList.add("ws-wires");

  function node(def, role) {
    const item = def.item ?? itemOf(def);
    const chip = el("button", `ws-node ${role}`);
    chip.dataset.key = key(def);
    chip.append(el("span", "ws-kind", KIND[item?.kind] ?? "·"), el("span", "ws-node-name", item?.kind === "property" ? item.sig : def.name));
    if (def.path !== focus?.path && role !== "focus" && item?.kind !== "property") chip.append(el("span", "ws-module", short(def.path)));
    if (set.some((f) => same(f, def))) chip.classList.add("in-set");
    if (item?.opaque) chip.classList.add("planned");
    chip.title = `${item?.sig ?? def.name}${item?.doc ? `\n${item.doc}` : ""}\nclick: beside the focus · ⌘-click or double-click: focus on it`;
    if (role !== "focus") {
      chip.addEventListener("click", (event) => (event.metaKey || event.ctrlKey ? show(def) : pull(def)));
      chip.addEventListener("dblclick", () => show(def));
    }
    chip.addEventListener("mouseenter", () => set.find((f) => same(f, def))?.node.classList.add("lit"));
    chip.addEventListener("mouseleave", () => set.find((f) => same(f, def))?.node.classList.remove("lit"));
    return chip;
  }

  function nodes(list, role) {
    const row = el("div", `ws-row ${role}`);
    const sorted = [...list].sort((a, b) => (a.path === focus.path ? 0 : 1) - (b.path === focus.path ? 0 : 1) || a.path.localeCompare(b.path) || a.name.localeCompare(b.name));
    for (const def of sorted.slice(0, NODES_MAX)) row.append(node(def, role));
    if (sorted.length > NODES_MAX) row.append(el("span", "ws-more", `+${sorted.length - NODES_MAX}`));
    return row;
  }

  function renderGraph() {
    graph.replaceChildren();
    const top = el("div", "ws-graph-head");
    top.append(el("span", "ws-graph-title", "Neighbourhood"));
    const grow = el("button", "ws-toggle", "▦ board");
    grow.title = "The whole board beside the focus (⌘⇧B)";
    grow.addEventListener("click", () => board.setView("board"));
    top.append(grow);
    graph.append(top);
    const item = focus?.name && itemOf(focus);
    const map = el("div", "ws-map");
    graph.append(map);
    if (item) {
      const { uses, users } = neighbours(focus);
      const callers = users.filter((d) => d.item.kind !== "property");
      const properties = users.filter((d) => d.item.kind === "property");
      map.append(el("div", "ws-row-label", callers.length ? "used by" : "used by nothing"));
      map.append(nodes(callers, "caller"));
      const middle = el("div", "ws-row focus");
      middle.append(node(focus, "focus"));
      map.append(middle);
      map.append(nodes(uses, "callee"));
      map.append(el("div", "ws-row-label", uses.length ? "uses" : "uses nothing of the program's"));
      if (properties.length) {
        graph.append(el("div", "ws-section", "properties"));
        const list = el("div", "ws-props");
        for (const def of properties) list.append(node(def, "property"));
        graph.append(list);
      }
      map.append(wires);
    }
    // the focus's module: its other definitions, a click away
    const m = focus && outline().find((mm) => mm.path === focus.path);
    if (m) {
      graph.append(el("div", "ws-section", `${short(m.path)}${m.requires.length ? ` · requires ${m.requires.map(short).join(", ")}` : ""}`));
      const card = el("div", "ws-card");
      for (const i of m.items) {
        const row = el("button", `ws-card-row${i.name === focus.name ? " current" : ""}${set.some((f) => same(f, { path: m.path, name: i.name })) ? " in-set" : ""}`);
        row.append(el("span", "ws-kind", KIND[i.kind] ?? "·"), el("span", "ws-card-sig", i.kind === "property" ? i.sig : i.sig.replace(/^val /, "")));
        row.title = `${i.doc || i.sig}\nclick: beside the focus · ⌘-click or double-click: focus on it`;
        const def = { path: m.path, name: i.name };
        row.addEventListener("click", (event) => (event.metaKey || event.ctrlKey ? show(def) : pull(def)));
        row.addEventListener("dblclick", () => show(def));
        card.append(row);
      }
      graph.append(card);
    }
    requestAnimationFrame(drawWires);
  }

  // curves from each caller down to the focus, and from it to each callee
  function drawWires() {
    if (!wires.isConnected) return;
    const map = wires.parentNode;
    const box = map.getBoundingClientRect();
    wires.setAttribute("width", box.width);
    wires.setAttribute("height", map.scrollHeight);
    wires.replaceChildren();
    const center = map.querySelector(".ws-node.focus")?.getBoundingClientRect();
    if (!center) return;
    const point = (r, bottom) => [r.left + r.width / 2 - box.left, (bottom ? r.bottom : r.top) - box.top];
    for (const chip of map.querySelectorAll(".ws-node.caller, .ws-node.callee")) {
      const r = chip.getBoundingClientRect();
      const caller = chip.classList.contains("caller");
      const [x1, y1] = caller ? point(r, true) : point(center, true);
      const [x2, y2] = caller ? point(center, false) : point(r, false);
      const mid = (y1 + y2) / 2;
      const path = document.createElementNS(SVG, "path");
      path.setAttribute("d", `M${x1},${y1} C${x1},${mid} ${x2},${mid} ${x2},${y2}`);
      path.setAttribute("class", `ws-wire ${caller ? "caller" : "callee"}`);
      wires.append(path);
    }
  }

  // ---- all of it -----------------------------------------------------------------------------

  function render() {
    if (!on) return;
    renderHead();
    renderSet();
    renderGraph();
    save();
  }

  // ---- kept per project, in this browser -------------------------------------------------

  const storeKey = () => `puffin-workset.${document.getElementById("project")?.textContent.trim() ?? ""}`;
  function save() {
    if (!restored) return;
    try {
      localStorage.setItem(storeKey(), JSON.stringify({
        focus, whole, past: past.slice(-30), at: Math.min(at, 29),
        set: set.map((f) => ({ path: f.path, name: f.name, pinned: f.pinned })),
        shelf,
      }));
    } catch { /* private window */ }
  }

  // Once the outline is in: what this browser had out, else the default
  // screen -- the shown file whole if it is short, else the definition at
  // its cursor.
  function restore() {
    restored = true;
    let kept = null;
    try { kept = JSON.parse(localStorage.getItem(storeKey()) ?? "null"); } catch { /* none */ }
    for (const d of kept?.set ?? []) {
      if (!find(d.name)) continue;
      const fragment = make(d, { pinned: d.pinned });
      if (fragment) set.push(fragment);
    }
    shelf = (kept?.shelf ?? []).filter((d) => find(d.name));
    past = (kept?.past ?? []).filter((d) => d.name && find(d.name));
    at = Math.min(kept?.at ?? past.length - 1, past.length - 1);
    if (kept?.focus?.name && find(kept.focus.name) && !kept.whole) return show(kept.focus, { push: false });
    const path = kept?.focus?.path && files.paths().includes(kept.focus.path) ? kept.focus.path : files.active();
    if (path && files.active() !== path) files.open(path);
    const text = main.getModel()?.getValue() ?? "";
    const first = forms(text).find((f) => DEFINES.has(f.head) && f.name);
    const name = kept?.focus?.name ?? first?.name ?? null;
    if (!kept && name && text.split("\n").length > SHORT_FILE) return show({ path, name });
    focus = { path, name };
    whole = true;
    narrowFocus();
    render();
  }

  // ---- keys ------------------------------------------------------------------------------

  window.addEventListener("keydown", (event) => {
    if (!on || event.metaKey || event.ctrlKey) return;
    if (event.altKey && event.key === "ArrowLeft") { event.preventDefault(); back(-1); }
    else if (event.altKey && event.key === "ArrowRight") { event.preventDefault(); back(1); }
    else if (event.altKey && event.code === "KeyO") { event.preventDefault(); setWhole(!whole); }
    else if (event.key === "F6") {
      // the focus, then each fragment in turn
      event.preventDefault();
      const views = [main, ...set.filter((f) => !f.collapsed).map((f) => f.view)];
      const now = views.findIndex((v) => v.hasTextFocus());
      views[(now + (event.shiftKey ? -1 : 1) + views.length) % views.length].focus();
    }
  }, true);

  return {
    // the focused layout came or went
    setOn(value) {
      on = value;
      document.body.classList.toggle("ws-on", on);
      if (!on) {
        main.setHiddenAreas([]);
        return;
      }
      if (!restored && outline().length) restore();
      else { narrowFocus(); render(); }
    },
    // the outline or the board changed
    changed() {
      if (!on) return;
      if (!restored && outline().length) return restore();
      render();
    },
    opened,
    // a row of the board (its ↗, the palette's definitions) asked for
    // `line` of `path`: focus the definition there, the board staying
    navigate(path, line, find) {
      if (!on) return false;
      if (files.active() !== path) {
        moving = true;
        files.open(path);
        moving = false;
      }
      const name = nameAt(main.getModel().getValue(), line);
      if (!name) return false;
      let select = null;
      if (find) {
        const found = main.getModel().findNextMatch(find, { lineNumber: line, column: 1 }, false, true, null, false);
        if (found) select = found.range;
      }
      show({ path, name }, { select });
      return true;
    },
  };
}
