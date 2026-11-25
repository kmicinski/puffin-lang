// Focus and context (docs/VIEW-FOCUS.md): one definition in focus, the
// code it is read with beside it, and its neighbourhood of the board
// always in view -- three views of the same text, kept current as it
// changes, with no mode between them.
//
// - The focus: the editor itself, showing one definition (its comment
//   and `(: name τ)` above it included) and the rest of its file hidden,
//   so editing it is editing the file. "≡ whole file" (⌥O) shows the
//   rest; the focus then follows the cursor, and ⌥O narrows again.
// - The working set: definitions beside the focus, from any file, each a
//   small live editor on the same text (an edit in one is an edit to its
//   file, seen everywhere at once). ⌘-click a name in any of the code, or
//   ⌥. at it, pulls its definition in (⌥. again, or ⌘⇧-click, focuses
//   it); a node of the neighbourhood likewise. Under what the author
//   pulled in, the attention model (attention.js, docs/ATTENTION.md)
//   offers what it ranks next -- dashed, in full or as a signature line,
//   each saying why -- in the room left; using one takes it, ✕ on one is
//   "show this less". Short of room, the set's fragments shrink to their
//   signature line by the model's score (plus a little for what was
//   touched lately), and only a fragment arriving sends the least wanted
//   to the shelf below, a click from coming back. Pinned ones stay. A
//   fragment the model would no longer show fades.
// - The neighbourhood, under the focus: the board around it -- what uses
//   it on the left, what it uses on the right, wired; its module's other
//   definitions and the properties that mention it. Click a node: pulled in; ⌘-click or
//   double-click: focused. "▦ board" (⌘⇧B) grows it into the whole board
//   beside the focus; a row's ↗ there focuses that row.
// - Focusing keeps a history (‹ ›, ⌥← ⌥→ or ⌥,), and the definition left
//   behind goes to the top of the working set: a jump never loses where
//   it came from. F6 walks the focus and the fragments.
// - What the author does -- pulls (the model's misses), opens, edits,
//   focuses, dwells, dismissals, pins -- is logged for the model to learn
//   this author's weights from (attention.js `learnFrom`).
//
// What is out, focused and pinned is this browser's, per project.

import { forms, balanced } from "./lexer.js";
import { createAttention, httpLog, idOf } from "./attention.js";
import { createTracker } from "./attention-studio.js";

const KIND = { fun: "ƒ", val: "·", type: "τ", alias: "≡", grammar: "G", property: "?" };
// the forms that define a name the outline knows
const DEFINES = new Set(["define", "define-type", "define-type-alias", "define-grammar", "define-foreign-type", "check-property", "check-example"]);
// a fragment just touched counts this much more than its score, fading by
// half every five minutes: what the author is working with stays out
const FRESH = 3;
const FRESH_HALF_LIFE = 5 * 60e3;
// a fragment's line, as the attention model's budget counts lines
const LINE = 17;
// a fragment's body is at most this tall before it scrolls
const BODY_MAX = 300;
const HEAD = 30;
const COLLAPSED = 34;
// a file this short is shown whole when nothing is focused yet
const SHORT_FILE = 60;
const NODES_MAX = 10;
// a phone: one column that scrolls, so nothing is short of room
const PHONE = window.matchMedia("(max-width: 700px)");
// the focus is never wider than this many columns
const WIDEST = 100;
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
  if (!monaco || !main) return { changed() {}, navigate: () => false, setOn() {}, opened() {}, boardShown() {}, receive() {} };

  // What deserves the room (docs/ATTENTION.md): the model ranks, offers
  // and explains; what the author does with what it offered teaches it.
  const tracker = createTracker();
  const log = httpLog();
  const attention = createAttention({ write: log.write });
  log.read().then((records) => attention.learnFrom(records)).catch(() => {});
  const idFor = (def) => idOf(def.path, def.name);
  // the model's word on one definition: { score, detail, reasons: [{ text }] }
  const verdict = (def) => attention.why(idFor(def)) ?? null;

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

  // ---- the page -----------------------------------------------------------------------

  const column = stage.querySelector(".editor-column");
  const head = el("div", "ws-head");
  column.prepend(head);
  const side = el("div", "ws-side");
  const setPane = el("div", "ws-set");
  const setList = el("div", "ws-list");
  const shelfRow = el("div", "ws-shelf");
  setPane.append(setList, shelfRow);
  // the neighbourhood sits under the focus: the two are read together
  const graph = el("div", "ws-graph");
  column.append(graph);
  side.append(setPane);
  stage.append(side);
  const wrap = column.querySelector("#editor-wrap");

  // the column's room changed: fit the set again, redraw the wires, and
  // tell the board where the focus ends (it grows over the side)
  const observer = new ResizeObserver(() => {
    if (!on) return;
    fit();
    sizeFocus();
    drawWires();
    stage.style.setProperty("--ws-left", `${column.getBoundingClientRect().right - stage.getBoundingClientRect().left + 8}px`);
  });
  observer.observe(side);
  observer.observe(column);

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
    const span = focus && !whole && files.active() === focus.path ? spanOf(main.getModel().getValue(), focus.name) : null;
    if (span) narrowView(main, spans, span);
    else main.setHiddenAreas([]);
    widen(span);
  }

  // The focus is as tall as its definition, as far as the neighbourhood
  // under it leaves room (the whole file: most of the column).
  function sizeFocus() {
    if (!on) return;
    // (on a phone the page scrolls: the focus has most of a screen)
    const room = PHONE.matches ? window.innerHeight * 0.9 : column.clientHeight - head.offsetHeight - 46 - 84;
    const neighbourhood = Math.min(graph.scrollHeight, room * (whole ? 0.3 : 0.5));
    const content = whole ? Infinity : main.getContentHeight() + 12;
    wrap.style.flex = `0 0 ${Math.max(60, Math.min(content, room - neighbourhood))}px`;
  }
  main.onDidContentSizeChange(() => requestAnimationFrame(sizeFocus));

  // The focus takes the width its lines need (the rest goes to the set
  // beside it): a two-line helper does not hold 100 columns of blank.
  function widen(span) {
    const model = main.getModel();
    if (!model) return;
    const lines = model.getLinesContent().slice(span ? span.start - 1 : 0, span ? span.end : undefined);
    const longest = Math.max(60, ...lines.map((line) => line.length));
    const char = main.getOption(monaco.editor.EditorOption.fontInfo).typicalHalfwidthCharacterWidth;
    const width = Math.round(Math.min(longest + 6, WIDEST) * char + main.getLayoutInfo().contentLeft + 24);
    document.body.style.setProperty("--ws-focus-width", `${width}px`);
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
    attention.observe({ type: "focus", id: idFor(def) });
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

  // The model's ranking for this moment: what it shows beyond the focus
  // and the set is offered, in its order, at its detail, in the room the
  // set leaves (the set's own lines come off the budget).
  function offer() {
    let ranked = [];
    if (focus?.name && !whole) {
      const room = PHONE.matches ? 80 : Math.floor(setList.clientHeight / LINE);
      const taken = set.reduce((sum, f) => sum + (f.collapsed ? 3 : Math.ceil((f.height + HEAD) / LINE)), 0);
      const members = new Set(set.map(idFor));
      ranked = attention.rank(tracker.state({ focus: idFor(focus), pins: set.filter((f) => f.pinned).map(idFor) }), { lines: Math.max(room - taken, 6), items: 12, full: 4 })
        .filter((s) => !s.focus && !members.has(s.id));
    }
    const kept = [];
    for (const s of ranked) {
      const fragment = offered.find((f) => idFor(f) === s.id) ?? make({ path: s.path, name: s.name }, { offered: true });
      if (!fragment) continue;
      Object.assign(fragment, { detail: s.detail, reasons: s.reasons });
      kept.push(fragment);
    }
    for (const fragment of offered) if (!kept.includes(fragment)) dispose(fragment);
    offered = kept;
  }

  // an offered fragment the author used: one of the set now
  function take(fragment) {
    if (!fragment.offered) return;
    fragment.offered = false;
    offered = offered.filter((f) => f !== fragment);
    attention.observe({ type: "open", id: idFor(fragment), detail: fragment.detail });
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
      crowding = true;
      // the model did not offer it: its miss, and the lesson that teaches most
      if (!cameFrom) attention.observe({ type: "pull", id: idFor(def) });
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
    noteEdits(view, fragment);
    // the time it held the author, past a couple of seconds
    let since = 0;
    node.addEventListener("mouseenter", () => { since = Date.now(); });
    node.addEventListener("mouseleave", () => {
      const ms = Date.now() - since;
      if (since && ms > 2000) attention.observe({ type: "dwell", id: idFor(fragment), ms });
    });
    // the lens: its node in the neighbourhood lights while the mouse is on it
    const lit = (value) => graph.querySelector(`.ws-node[data-key="${CSS.escape(key(fragment))}"]`)?.classList.toggle("lit", value);
    node.addEventListener("mouseenter", () => lit(true));
    node.addEventListener("mouseleave", () => lit(false));
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
    // not laid out yet (no width: every character would wrap)
    if (!fragment.body.clientWidth) return;
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

  // Fit the set to its column: the most wanted get their bodies, the rest
  // their signature line. Only a fragment arriving pushes others to the
  // shelf: a window resized, or the page loading, never sets anything
  // aside (the column scrolls instead).
  let crowding = false;
  function fit() {
    const evict = crowding;
    crowding = false;
    const room = PHONE.matches ? Infinity : setList.clientHeight;
    if (!room) return;
    // the model's score, and a little more for what was touched lately
    const wanted = (f) => (f.pinned ? Infinity : (verdict(f)?.score ?? 0) + FRESH * 0.5 ** ((Date.now() - f.touched) / FRESH_HALF_LIFE));
    // one not measured yet counts by its lines
    const lineHeight = main.getOption(monaco.editor.EditorOption.lineHeight) * 0.9;
    for (const fragment of [...set, ...offered]) {
      if (fragment.height) continue;
      const span = fragment.collection.getRange(0);
      fragment.height = Math.min(BODY_MAX, span ? (span.endLineNumber - span.startLineNumber + 1) * lineHeight + 8 : 60);
    }
    // every one gets its signature line, least wanted first to the shelf
    // when even those do not fit; then the most wanted get their bodies
    const order = [...set].sort((a, b) => wanted(b) - wanted(a));
    const decided = new Map(order.map((f) => [f, "collapsed"]));
    let left = room - order.length * (COLLAPSED + 10);
    for (const fragment of [...order].reverse()) {
      if (left >= 0 || fragment.pinned || !evict) break;
      decided.set(fragment, "shelf");
      left += COLLAPSED + 10;
    }
    for (const fragment of order) {
      const more = fragment.height + HEAD - COLLAPSED;
      if (decided.get(fragment) === "collapsed" && more <= left) {
        decided.set(fragment, "full");
        left -= more;
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
    // what is offered fills what room is left, in the model's order: in
    // full if it said full and that fits, else its signature line
    for (const fragment of offered) {
      const full = fragment.detail === "full" && HEAD + fragment.height + 10 <= left;
      const fits = full || COLLAPSED + 10 <= left;
      if (fits) left -= full ? HEAD + fragment.height + 10 : COLLAPSED + 10;
      fragment.collapsed = !full;
      fragment.node.classList.toggle("collapsed", !full);
      fragment.body.style.height = full ? `${fragment.height}px` : "0px";
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
    // in order, top first, moving only what moved -- and gliding there
    // from where it was (the arriving one slides in at the top)
    const before = new Map(all.filter((f) => f.node.isConnected).map((f) => [f, f.node.getBoundingClientRect().top]));
    all.forEach((fragment, i) => {
      if (setList.children[i] !== fragment.node) setList.insertBefore(fragment.node, setList.children[i] ?? null);
    });
    for (const [fragment, top] of before) {
      const moved = top - fragment.node.getBoundingClientRect().top;
      if (!moved) continue;
      fragment.node.animate([{ transform: `translateY(${moved}px)` }, { transform: "none" }], { duration: 280, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)" });
    }
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
    // why it is here, in the model's words (all of them on hover)
    const why = verdict(fragment);
    const reasons = (fragment.offered ? fragment.reasons : why?.reasons?.map((r) => r.text)) ?? [];
    if (reasons.length) {
      const badge = el("span", `ws-rel${fragment.offered ? " offered" : ""}`, reasons[0].replace(/;.*$/, ""));
      badge.title = `${fragment.offered ? "offered" : "kept"} because: ${reasons.join("; ")}${why ? `\nscore ${why.score.toFixed(2)}` : ""}`;
      top.append(badge);
    }
    top.append(el("span", "ws-sig", fragment.collapsed || !reasons.length ? (item?.sig.replace(/^(val|type|grammar) \S+\s*/, "") ?? "") : ""));
    const tools = el("span", "ws-tools");
    const pin = el("button", `ws-icon${fragment.pinned ? " on" : ""}`, "⊙");
    pin.title = fragment.pinned ? "Unpin" : "Pin: kept, whatever else needs the room";
    pin.addEventListener("click", () => {
      fragment.pinned = !fragment.pinned;
      (fragment.pinned ? attention.pin : attention.unpin)(idFor(fragment));
      if (fragment.offered) take(fragment);
      else render();
    });
    const up = el("button", "ws-icon", "↑");
    up.title = "Focus on it";
    up.addEventListener("click", () => show(fragment));
    const close = el("button", "ws-icon", "✕");
    close.title = fragment.offered ? "Show this less (it was offered: the model learns from this)" : "Put it away";
    close.addEventListener("click", () => {
      if (fragment.offered) attention.showLess(idFor(fragment));
      drop(fragment);
    });
    tools.append(pin, up, close);
    top.append(tools);
    top.ondblclick = (event) => { if (!event.target.closest("button")) { fragment.collapsed = !fragment.collapsed; fragment.touched = Date.now(); render(); } };
    // stale: the model would not show it now (it scores under a signature's worth)
    fragment.node.classList.toggle("distant", !fragment.pinned && !fragment.offered && Boolean(focus?.name) && !whole && (why?.score ?? 0) < 1.5);
    fragment.node.classList.toggle("pinned", fragment.pinned);
    fragment.node.classList.toggle("offered", fragment.offered);
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

  // The author typing in a view (the focus or a fragment): the lines go to
  // the tracker, and the definition is an edit, told once in a while
  const told = new Map(); // id -> when
  function noteEdits(view, def) {
    view.onDidChangeModelContent((event) => {
      if (!on || !view.hasTextFocus()) return;
      const path = def === null ? files.active() : def.path;
      for (const change of event.changes) tracker.edit(path, change.range.startLineNumber, change.range.endLineNumber + change.text.split("\n").length - 1);
      const target = def ?? focus;
      if (!target?.name) return;
      const id = idFor({ path, name: target.name });
      if (Date.now() - (told.get(id) ?? 0) < 10000) return;
      told.set(id, Date.now());
      attention.observe({ type: "edit", id });
    });
  }
  noteEdits(main, null);

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
    const body = el("div", "ws-graph-body");
    const map = el("div", "ws-map");
    const aside = el("div", "ws-aside");
    body.append(map, aside);
    graph.append(body);
    if (item) {
      const { uses, users } = neighbours(focus);
      const callers = users.filter((d) => d.item.kind !== "property");
      const properties = users.filter((d) => d.item.kind === "property");
      const group = (role, list, label) => {
        const part = el("div", `ws-part ${role}`);
        part.append(el("div", "ws-row-label", label), nodes(list, role));
        return part;
      };
      const middle = el("div", "ws-part focus");
      middle.append(node(focus, "focus"));
      map.append(group("caller", callers, callers.length ? "used by" : "used by nothing"), middle, group("callee", uses, uses.length ? "uses" : "uses nothing of the program's"));
      if (properties.length) {
        aside.append(el("div", "ws-section", "properties"));
        const list = el("div", "ws-props");
        for (const def of properties) list.append(node(def, "property"));
        aside.append(list);
      }
      map.append(wires);
    }
    // the focus's module: its other definitions, a click away
    const m = focus && outline().find((mm) => mm.path === focus.path);
    if (m) {
      aside.append(el("div", "ws-section", `${short(m.path)}${m.requires.length ? ` · requires ${m.requires.map(short).join(", ")}` : ""}`));
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
      aside.append(card);
    }
    requestAnimationFrame(() => {
      sizeFocus();
      drawWires();
    });
  }

  // curves from each caller to the focus, and from it to each callee:
  // left to right, or top to bottom when the map is stacked (narrow)
  function drawWires() {
    if (!wires.isConnected) return;
    const map = wires.parentNode;
    const box = map.getBoundingClientRect();
    const across = getComputedStyle(map).flexDirection === "row";
    wires.setAttribute("width", box.width);
    wires.setAttribute("height", map.scrollHeight);
    wires.replaceChildren();
    const center = map.querySelector(".ws-node.focus")?.getBoundingClientRect();
    if (!center) return;
    // the point a wire leaves (end) or enters a box
    const point = (r, end) => (across
      ? [(end ? r.right : r.left) - box.left, r.top + r.height / 2 - box.top]
      : [r.left + r.width / 2 - box.left, (end ? r.bottom : r.top) - box.top]);
    for (const chip of map.querySelectorAll(".ws-node.caller, .ws-node.callee")) {
      const r = chip.getBoundingClientRect();
      const caller = chip.classList.contains("caller");
      const [x1, y1] = caller ? point(r, true) : point(center, true);
      const [x2, y2] = caller ? point(center, false) : point(r, false);
      const path = document.createElementNS(SVG, "path");
      const mx = (x1 + x2) / 2;
      const my = (y1 + y2) / 2;
      path.setAttribute("d", across ? `M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}` : `M${x1},${y1} C${x1},${my} ${x2},${my} ${x2},${y2}`);
      path.setAttribute("class", `ws-wire ${caller ? "caller" : "callee"}`);
      wires.append(path);
    }
  }

  // ---- all of it -----------------------------------------------------------------------------

  function render() {
    if (!on) return;
    offer();
    renderHead();
    renderSet();
    renderGraph();
    save();
  }

  // things fade (an edit's news, a dismissal): rank again now and then
  let reranking = 0;
  setInterval(() => { if (on && !document.hidden) render(); }, 30000);

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

  // ⌥. (Emacs's M-.) on a name: its definition beside the focus, and
  // pressed again, focused; ⌥, (M-,) back
  function nameAtCursor() {
    const view = [main, ...set.map((f) => f.view)].find((v) => v.hasTextFocus());
    const word = view?.getModel()?.getWordAtPosition(view.getPosition());
    return word ? find(word.word) : null;
  }

  window.addEventListener("keydown", (event) => {
    if (!on || event.metaKey || event.ctrlKey) return;
    const take = () => { event.preventDefault(); event.stopPropagation(); };
    if (event.altKey && event.key === "ArrowLeft") { take(); back(-1); }
    else if (event.altKey && event.key === "ArrowRight") { take(); back(1); }
    else if (event.altKey && event.code === "Comma" && !event.shiftKey) { take(); back(-1); }
    else if (event.altKey && event.code === "Period" && !event.shiftKey) {
      take();
      const def = nameAtCursor();
      if (def) (set.some((f) => same(f, def)) ? show(def) : pull(def));
    }
    else if (event.altKey && event.code === "KeyO") { take(); setWhole(!whole); }
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
      // a definition is read whole: its long lines wrap in the narrowed column
      main.updateOptions({ wordWrap: on ? "on" : "off", wrappingIndent: "deepIndent" });
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
    // every socket message: the model's view of the studio (edits by the
    // builder, failing properties, errors, voice) -- and a moment later,
    // the ranking again
    receive(message) {
      tracker.receive(message);
      if (on && ["voice", "diagnostics", "text"].includes(message.t)) {
        clearTimeout(reranking);
        reranking = setTimeout(render, 400);
      }
    },
    // the board came out beside the focus: fitted to the room it has there
    boardShown(shown) {
      if (on && shown) setTimeout(() => board.fit(), 360);
    },
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
