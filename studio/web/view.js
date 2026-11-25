// The view (docs/VIEW.md): the studio's one code view. The board and the
// code are not two modes but one screen, kept current with each other:
//
// - The focus (left, top): the editor itself, narrowed to one definition
//   -- its comment and `(: name τ)` included -- with the lines around it
//   dimmed where there is room, so editing it is editing the file. ‹ ›
//   walk the focus history; "≡ whole file" widens it to the whole file,
//   and the focus then follows the cursor.
// - The neighbourhood (under it): the board around the focus -- what uses
//   it, what it uses, wired; the properties that mention it; its module's
//   rows. Arrow keys walk the nodes.
// - The board (right, board.js): one zoomable surface holding the
//   program's module cards and, left of them, the lane: the working set
//   -- other definitions, from any file, as live code (fragment.js) --
//   wired from the very line in the focus that uses each one. Close in,
//   the lane is a column of code beside the focus; zoom out and it is
//   the whole program, each fragment wired to its row.
//
// What is in the lane is one call to the attention model (attention.js,
// docs/ATTENTION.md): the author's set -- what they pulled in, each a
// fragment until they put it away -- and what the model offers beside
// it (dashed, with its reason), ranked together, each at the detail its
// score buys (its code, its folded row, or its signature line). The lane
// reorders only when something arrives or the author is idle, never
// under their eyes. Everything the author does with it -- a pull (the
// model's miss), taking an offer, an edit, a focus, a dwell, "show this
// less", a pin -- is told to the model, which learns this author's
// weights from the project's log.
//
// Following a name: ⌘/ctrl/alt-click (or ⌥.) pulls its definition into
// the lane, ⌘⇧-click focuses it; focusing leaves the definition you were
// in in the lane, so a jump never loses where it came from.

import { forms } from "./lexer.js";
import { DEFINES, nameAt, narrow, lineOf } from "./span.js";
import { bindNames } from "./names.js";
import { createFragment } from "./fragment.js";
import { overlay, wire, svg, curve } from "./wires.js";
import { createAttention, httpLog, idOf } from "./attention.js";
import { createTracker } from "./attention-studio.js";
import { NEAR } from "./board.js";

const KIND = { fun: "ƒ", val: "·", type: "τ", alias: "≡", grammar: "G", property: "?" };
// the set holds at most this many; an arrival beyond sends the least
// wanted to the shelf
const SET_LIMIT = 8;
// what the model may offer beside the set
const OFFER_LIMIT = 5;
// a line of the lane, as the model's budget counts lines
const LINE = 19;
// the lane reorders when the author has been still this long
const IDLE_MS = 2500;
// a file this short is shown whole when nothing is focused yet
const SHORT_FILE = 60;
// the focus is never wider than this many columns
const WIDEST = 100;
const NODES_MAX = 10;
const PHONE = window.matchMedia("(max-width: 700px)");

const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};
const short = (path) => path.replace(/\.puf$/, "");
const same = (a, b) => Boolean(a && b) && a.path === b.path && a.name === b.name;
const keyOf = (path, name) => `${path}\u001f${name}`;
const idFor = (def) => idOf(def.path, def.name);
const defOf = (id) => {
  const at = id.indexOf("::");
  return { path: id.slice(0, at), name: id.slice(at + 2) };
};
const bareSig = (item) => item?.sig.replace(/^(val|type|grammar) \S+\s*/, "") ?? "";

export function createView({ editor, files, board, stage, onEvalAt }) {
  const monaco = editor.raw?.monaco;
  const main = editor.raw?.editor;
  // without Monaco (no node_modules): the plain editor and the board
  if (!monaco || !main) return { boardChanged() {}, opened() {}, receive() {}, focusAt: () => false };

  // What deserves the room (docs/ATTENTION.md): the tracker folds the
  // socket's messages into the model's state; the log of what the author
  // does with what it shows tunes it to them.
  const tracker = createTracker();
  const log = httpLog();
  const attention = createAttention({ write: log.write });
  log.read().then((records) => attention.learnFrom(records)).catch(() => {});

  let focus = null; // { path, name } (name null: a file with no definition at the cursor)
  let whole = false; // the focus pane shows the whole file
  let past = []; // the focus history
  let at = -1;
  let restored = false;
  let moving = false; // the focus is being moved here: the cursor's events are ours
  const touched = new Map(); // id -> when the author last touched it here
  let shelf = []; // ids set aside for want of room, newest first
  let lastInput = 0;

  // ---- the outline (board.rs), by name -----------------------------------------------

  const outline = () => board.outline();
  const itemOf = (def) => outline().find((m) => m.path === def.path)?.items.find((i) => i.name === def.name);
  // the definition `word` names seen from `path`: its own module's, then a
  // module it requires, then any (a property is not a name in code)
  function find(word, path = focus?.path) {
    const holders = outline().filter((m) => m.items.some((i) => i.name === word && i.kind !== "property"));
    const from = outline().find((m) => m.path === path);
    const m = holders.find((h) => h.path === path) ?? holders.find((h) => from?.requires.includes(h.path)) ?? holders[0];
    return m ? { path: m.path, name: word } : null;
  }
  // what `def` uses and what uses it
  function neighbours(def) {
    const uses = (itemOf(def)?.uses ?? []).map((n) => find(n, def.path)).filter((d) => d && !same(d, def));
    const users = [];
    for (const m of outline()) for (const i of m.items) if (i.uses.includes(def.name) && !(m.path === def.path && i.name === def.name)) users.push({ path: m.path, name: i.name });
    return { uses, users };
  }

  // ---- the page -----------------------------------------------------------------------

  const column = stage.querySelector(".editor-column");
  const head = el("div", "view-head");
  column.prepend(head);
  const graph = el("div", "view-graph");
  column.append(graph);
  const wrap = column.querySelector("#editor-wrap");
  const lane = board.lane;
  // the wires from a line of code to the fragment it uses, across the panes
  const across = overlay(stage, "view-wires");
  document.body.classList.add("view");
  // a definition is read whole: its long lines wrap in the focus, and no
  // sticky scroll pins the lines above it (they are context, or hidden)
  main.updateOptions({ wordWrap: "on", wrappingIndent: "deepIndent", stickyScroll: { enabled: false } });

  new ResizeObserver(() => { sizeFocus(); drawGraphWires(); drawWires(); }).observe(column);
  // the board's room changed: the lane's code fits it again
  let boardWidth = 0;
  new ResizeObserver(() => {
    if (Math.abs(board.root.clientWidth - boardWidth) < 8) return;
    boardWidth = board.root.clientWidth;
    for (const f of frags.values()) f.fragment?.refresh();
  }).observe(board.root);
  board.onMove(() => drawWires());
  main.onDidScrollChange(() => drawWires());

  // the author is busy (the lane holds still while they are)
  for (const type of ["keydown", "pointerdown", "wheel"]) window.addEventListener(type, () => { lastInput = Date.now(); }, true);
  let inLane = false;
  lane.addEventListener("pointerenter", () => { inLane = true; });
  lane.addEventListener("pointerleave", () => { inLane = false; settleSoon(); });

  // ---- the focus ------------------------------------------------------------------------

  const focused = narrow(monaco, main, null);
  // the lines around the definition, dimmed: context, a click away from being the focus
  const context = main.createDecorationsCollection();
  const mainNames = bindNames(monaco, main, {
    find: (word) => {
      const def = find(word);
      return def && !same(def, focus) ? def : null;
    },
    span: () => focused.span(),
    onPull: (def) => pull(def),
    onFocus: (def) => show(def),
    onHover: (def) => hover(def && keyOf(def.path, def.name)),
  });

  // Narrow the focus pane to the focused definition, with as many lines
  // of the file around it as the room it is given leaves (dimmed: there,
  // not the focus); the whole file when widened.
  let shownFrom = 0;
  function narrowFocus() {
    const narrowed = focus?.name && !whole && files.active() === focus.path;
    let span = focused.to(narrowed ? focus.name : null);
    if (narrowed && !span) span = focused.to(null);
    context.clear();
    if (!narrowed) shownFrom = 0;
    else if (span && focused.name()) around(span);
    mainNames.refresh();
    widen(narrowed ? span : null);
    sizeFocus();
  }

  // The lines around `span`: a third of the spare room above, the rest
  // below, given back a line at a time while the text (wrapped lines
  // count) is taller than the room.
  function around(span) {
    const model = main.getModel();
    const lines = model.getLineCount();
    const lineHeight = main.getOption(monaco.editor.EditorOption.lineHeight);
    const target = room().focusMin;
    const spare = Math.max(0, Math.floor((target - (span.end - span.start + 1) * lineHeight - 16) / lineHeight));
    let above = Math.min(span.start - 1, Math.floor(spare / 3));
    let below = Math.min(lines - span.end, spare - above);
    const show = () => {
      const start = span.start - above;
      const end = span.end + below;
      const hidden = [];
      if (start > 1) hidden.push(new monaco.Range(1, 1, start - 1, 1));
      if (end < lines) hidden.push(new monaco.Range(end + 1, 1, lines, 1));
      main.setHiddenAreas(hidden);
      return start;
    };
    let start = show();
    while ((above || below) && main.getContentHeight() > target) {
      if (below) below--;
      else above--;
      start = show();
    }
    const dim = [];
    if (above) dim.push(new monaco.Range(start, 1, span.start - 1, 1));
    if (below) dim.push(new monaco.Range(span.end + 1, 1, span.end + below, 1));
    context.set(dim.map((range) => ({ range, options: { isWholeLine: true, className: "focus-context", inlineClassName: "focus-context-text" } })));
    // a new place: shown from its top, not where Monaco last scrolled
    if (start !== shownFrom) requestAnimationFrame(() => main.setScrollTop(0));
    shownFrom = start;
  }

  // The room in the column: the focus gets what its definition needs, at
  // least `focusMin` (filled with the lines around it) and at most most of
  // the column; the neighbourhood the rest.
  function room() {
    const total = PHONE.matches ? window.innerHeight * 0.9 : column.clientHeight - head.offsetHeight - 24;
    return { total, focusMin: total * (whole ? 0.7 : 0.42), focusMax: total * (whole ? 0.8 : 0.66) };
  }
  function sizeFocus() {
    const { focusMin, focusMax } = room();
    const content = main.getContentHeight() + 4;
    wrap.style.flex = `0 0 ${Math.round(Math.max(Math.min(content, focusMax), Math.min(focusMin, content), 80))}px`;
  }
  main.onDidContentSizeChange(() => requestAnimationFrame(sizeFocus));

  // The focus takes the width its lines need (the rest goes to the board
  // beside it): a two-line helper does not hold 100 columns of blank.
  function widen(span) {
    const model = main.getModel();
    if (!model) return;
    const lines = model.getLinesContent().slice(span ? span.start - 1 : 0, span ? span.end : undefined);
    const longest = Math.max(60, ...lines.map((line) => line.length));
    const char = main.getOption(monaco.editor.EditorOption.fontInfo).typicalHalfwidthCharacterWidth;
    const width = Math.round(Math.min(longest + 6, WIDEST) * char + main.getLayoutInfo().contentLeft + 24);
    document.body.style.setProperty("--view-focus-width", `${width}px`);
  }

  // Focus `def`: the editor shows it (opening its file), the history
  // gains it, and the definition left behind goes into the set.
  function show(def, { push = true, select = null } = {}) {
    if (!def) return;
    const before = focus;
    const leaving = before?.name && !same(before, def) && push && !whole ? before : null;
    focus = { path: def.path, name: def.name };
    whole = false;
    if (push && !same(past[at], focus)) {
      past = past.slice(0, at + 1);
      past.push(focus);
      at = past.length - 1;
    }
    // focused, it is no longer beside itself; where it came from is
    editSet((set) => {
      const next = set.filter((s) => s.id !== idFor(def));
      if (leaving && !next.some((s) => s.id === idFor(leaving))) next.unshift({ id: idFor(leaving), at: Date.now() });
      return next;
    }, leaving && idFor(leaving));
    moving = true;
    if (files.active() !== def.path) files.open(def.path);
    narrowFocus();
    attention.observe({ type: "focus", id: idFor(def) });
    const span = focused.span();
    if (span && focused.name()) {
      if (select) main.setSelection(select);
      else main.setPosition({ lineNumber: Math.min(span.start + (span.end > span.start ? 1 : 0), span.end), column: 1 });
    }
    moving = false;
    main.focus();
    render({ arrived: leaving && idFor(leaving) });
  }

  function setWhole(value) {
    whole = value;
    if (!whole && focus) {
      // narrowing: to the definition the cursor is in, if any
      const name = nameAt(main.getModel().getValue(), main.getPosition()?.lineNumber ?? 1);
      if (name && name !== focus.name) return show({ path: files.active(), name });
    }
    narrowFocus();
    if (whole && focus?.name) {
      const span = focused.span();
      const def = forms(main.getModel().getValue()).find((f) => f.name === focus.name && DEFINES.has(f.head));
      if (span && def) main.revealLineNearTop(def.line);
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
  // palette, a hole, the voice, the arrows, a click in the dimmed lines
  // around it): the focus follows. With the whole file shown, the focus is
  // just where the cursor is.
  main.onDidChangeCursorPosition((event) => {
    if (moving || !focus) return;
    const path = files.active();
    const model = main.getModel();
    if (!path || !model) return;
    const line = event.position.lineNumber;
    const name = nameAt(model.getValue(), line);
    if (whole) {
      if (name && !(focus.path === path && focus.name === name)) {
        focus = { path, name };
        render();
      }
      return;
    }
    const span = path === focus.path && focused.name() ? focused.span() : null;
    if (span && span.start <= line && line <= span.end) return;
    if (name) show({ path, name });
    else setWhole(true);
  });

  // The editor showed another file by other means (a chip, the tree): the
  // focus goes with it, the whole file.
  function opened(path) {
    if (moving || !restored) return;
    if (focus?.path === path) return narrowFocus();
    const name = nameAt(main.getModel().getValue(), main.getPosition()?.lineNumber ?? 1);
    focus = { path, name };
    whole = true;
    narrowFocus();
    render();
  }

  // the text changed: the focus stays on its definition, the lane's code on theirs
  main.onDidChangeModelContent(() => requestAnimationFrame(() => {
    if (focus?.name && !whole && files.active() === focus.path) narrowFocus();
  }));

  // ---- the header ---------------------------------------------------------------------------

  function renderHead() {
    head.replaceChildren();
    const nav = el("span", "view-nav");
    const prev = el("button", "view-icon", "‹");
    prev.title = "Back to the previous focus (⌥←, ⌥,)";
    prev.disabled = at <= 0;
    prev.addEventListener("click", () => back(-1));
    const next = el("button", "view-icon", "›");
    next.title = "Forward (⌥→)";
    next.disabled = at >= past.length - 1;
    next.addEventListener("click", () => back(1));
    nav.append(prev, next);
    head.append(nav);
    const item = focus?.name && itemOf(focus);
    if (whole || !item) {
      head.append(el("span", "view-title", focus ? short(focus.path) : ""), el("span", "view-sub", whole ? "whole file" : ""));
      if (item) head.append(el("span", "view-sig", `· at ${focus.name}`));
    } else {
      head.append(el("span", "view-kind", KIND[item.kind] ?? "·"), el("span", "view-title", focus.name), el("span", "view-module", short(focus.path)));
      head.append(el("span", "view-sig", bareSig(item)));
    }
    const grow = el("button", "view-toggle", whole ? `◎ ${item ? `just ${focus.name}` : "a definition"}` : "≡ whole file");
    grow.title = whole ? "Narrow to the definition at the cursor (⌥O)" : "Widen the focus to the whole file (⌥O)";
    grow.disabled = whole && !item;
    grow.addEventListener("click", () => setWhole(!whole));
    const out = el("button", "view-toggle", board.zoom() >= NEAR ? "▦ the board" : "◧ the code");
    out.title = "Glide out to the whole program, or back in to the code (⌘⇧B, or say “show the board”)";
    out.addEventListener("click", () => board.toggle());
    head.append(grow, out);
  }
  board.onMove(() => {
    const label = board.zoom() >= NEAR ? "▦ the board" : "◧ the code";
    const button = head.querySelector(".view-toggle:last-child");
    if (button && button.textContent !== label) button.textContent = label;
  });

  // ---- the set: kept with the board -----------------------------------------------------------

  const setOf = () => board.set().filter((s) => itemOf(defOf(s.id)));
  // change the set (`arrived`: the id that just came, the one never sent
  // to the shelf); sent to the board, which keeps it
  function editSet(f, arrived = null) {
    let next = f(setOf().map((s) => ({ ...s })));
    if (arrived && next.length > SET_LIMIT) {
      // the least wanted of the rest go to the shelf
      const score = new Map(lastRank.map((s) => [s.id, s.score]));
      const going = next
        .filter((s) => !s.pinned && s.id !== arrived && s.id !== idFor(past[at - 1] ?? {}))
        .sort((a, b) => (score.get(a.id) ?? 0) - (score.get(b.id) ?? 0))
        .slice(0, next.length - SET_LIMIT)
        .map((s) => s.id);
      shelf = [...going, ...shelf.filter((id) => !going.includes(id))].slice(0, 12);
      next = next.filter((s) => !going.includes(s.id));
    }
    shelf = shelf.filter((id) => !next.some((s) => s.id === id));
    board.setSet(next);
  }

  // Pull `def` into the set: a fragment in the lane, the camera on it.
  function pull(def) {
    if (!def?.name || same(def, focus)) return;
    const id = idFor(def);
    touched.set(id, Date.now());
    const offered = frags.get(id)?.offered;
    if (!setOf().some((s) => s.id === id)) {
      // the model did not offer it: its miss, the lesson that teaches most
      attention.observe({ type: offered ? "open" : "pull", id });
      editSet((set) => [...set, { id, at: Date.now() }], id);
    }
    render({ arrived: id });
  }

  function putAway(id) {
    const f = frags.get(id);
    if (f?.offered) attention.showLess(id);
    editSet((set) => set.filter((s) => s.id !== id));
    render();
  }

  function pin(id) {
    const member = setOf().find((s) => s.id === id);
    const pinned = !member?.pinned;
    (pinned ? attention.pin : attention.unpin)(id);
    if (!member) attention.observe({ type: "open", id });
    editSet((set) => (member ? set.map((s) => (s.id === id ? { ...s, pinned } : s)) : [...set, { id, at: Date.now(), pinned }]), id);
    render();
  }

  // ] and [ (the board, the neighbourhood): the next of what `def` uses, or
  // of what uses it, that is not out yet -- functions before types -- so
  // ]]] brings out what a definition calls, one after another
  function along(def, direction) {
    const { uses, users } = neighbours(def);
    const out = (d) => same(d, focus) || frags.has(idFor(d));
    const rank = (d) => (["fun", "val"].includes(itemOf(d)?.kind) ? 0 : 1);
    const next = (direction === "uses" ? uses : users).filter((d) => !out(d)).sort((a, b) => rank(a) - rank(b))[0];
    if (next) pull(next);
  }

  // ---- the ranking: what the lane holds, at what detail ------------------------------------

  let lastRank = [];
  function ranking() {
    const now = Date.now();
    const set = setOf().map((s) => ({ ...s, at: Math.max(s.at ?? 0, touched.get(s.id) ?? 0) || now }));
    const lines = Math.max(30, Math.floor((board.root.clientHeight / 0.85) / LINE));
    const state = tracker.state({ focus: focus?.name ? idFor(focus) : undefined, set });
    lastRank = attention.rank(state, { lines, items: set.length + OFFER_LIMIT, full: 5 });
    return lastRank;
  }

  // ---- the lane: fragments ---------------------------------------------------------------

  // id -> { def, node, head, body, fragment (its live code, made when it
  // first shows in full), offered, detail, reasons }
  const frags = new Map();
  let order = []; // the lane's ids, top first, as shown

  function makeFrag(def) {
    const node = el("section", "frag arriving");
    node.dataset.key = keyOf(def.path, def.name);
    const top = el("div", "frag-head");
    const doc = el("div", "frag-doc");
    const body = el("div", "frag-body");
    node.append(top, doc, body);
    const f = { def, node, head: top, doc, body, fragment: null, offered: false, detail: null, reasons: [] };
    // the time it held the author, past a couple of seconds
    let since = 0;
    node.addEventListener("pointerenter", () => { since = Date.now(); lit(def, true); });
    node.addEventListener("pointerleave", () => {
      lit(def, false);
      const ms = Date.now() - since;
      if (since && ms > 2000) attention.observe({ type: "dwell", id: idFor(def), ms });
    });
    requestAnimationFrame(() => requestAnimationFrame(() => node.classList.remove("arriving")));
    return f;
  }

  // its live code, once it is first shown in full
  function code(f) {
    if (f.fragment) return f.fragment;
    const { path, name } = f.def;
    const id = idFor(f.def);
    let focusedAt = 0;
    const edited = new Set();
    f.fragment = createFragment({
      editor,
      model: editor.model(path, files.texts()[path] ?? ""),
      path,
      name,
      maxWidth: board.laneMax,
      find: (word) => find(word, path),
      onPull: (def) => pull(def),
      onFocusDef: (def) => show(def),
      onHover: (def) => hover(def && keyOf(def.path, def.name)),
      onFocus() {
        focusedAt = Date.now();
        edited.clear();
        touched.set(id, focusedAt);
        f.node.classList.add("editing");
        take(f);
      },
      onBlur() {
        f.node.classList.remove("editing");
        if (Date.now() - focusedAt > 2000) attention.observe({ type: "dwell", id, ms: Date.now() - focusedAt });
        settleSoon();
      },
      onEscape: () => main.focus(),
      onEvalForm: (pos) => onEvalAt?.(path, { pos }),
      onEdit(from, to) {
        // each definition typed in is one edit to the model, per visit
        for (const each of tracker.edit(path, from, to)) {
          if (edited.has(each)) continue;
          edited.add(each);
          attention.observe({ type: "edit", id: each });
        }
      },
      onResize: () => { board.laneChanged(); drawWires(); },
    });
    f.body.append(f.fragment.node);
    return f.fragment;
  }

  // an offered fragment the author used: one of the set now
  function take(f) {
    if (!f.offered) return;
    f.offered = false;
    attention.observe({ type: "open", id: idFor(f.def), detail: f.detail });
    editSet((set) => [...set, { id: idFor(f.def), at: Date.now() }], idFor(f.def));
  }

  function renderFrag(f) {
    const { def } = f;
    const item = itemOf(def);
    const id = idFor(def);
    const member = setOf().find((s) => s.id === id);
    f.head.replaceChildren();
    const name = el("button", "frag-name", def.name);
    name.title = "Focus on it (⌘⇧-click a name does the same)";
    name.addEventListener("click", () => show(def));
    f.head.append(el("span", "frag-kind", KIND[item?.kind] ?? "·"), name, el("span", "frag-module", short(def.path)));
    // why it is here, in the model's words (all of them on hover)
    const reasons = f.reasons.filter((r) => f.offered || r !== "you brought it in");
    if (reasons.length) {
      const badge = el("span", `frag-why${f.offered ? " offered" : ""}`, reasons[0]);
      badge.title = `${f.offered ? "offered" : "kept"} because: ${f.reasons.join("; ")}`;
      f.head.append(badge);
    }
    f.head.append(el("span", "frag-sig", f.detail === "full" ? "" : bareSig(item)));
    const tools = el("span", "frag-tools");
    const pinButton = el("button", `view-icon${member?.pinned ? " on" : ""}`, "⊙");
    pinButton.title = member?.pinned ? "Unpin" : "Pin: kept in full, whatever else wants the room";
    pinButton.addEventListener("click", () => pin(id));
    const close = el("button", "view-icon", "✕");
    close.title = f.offered ? "Show this less (it was offered: the model learns from this)" : "Put it away";
    close.addEventListener("click", () => putAway(id));
    tools.append(pinButton, close);
    f.head.append(tools);
    // the head of a folded one opens it; of an offered one, takes it
    f.head.ondblclick = (event) => { if (!event.target.closest("button")) pull(def); };
    f.doc.textContent = f.detail === "folded" ? item?.doc ?? "" : "";
    if (f.detail === "full") code(f);
    f.node.classList.toggle("offered", f.offered);
    f.node.classList.toggle("pinned", Boolean(member?.pinned));
    for (const d of ["full", "folded", "signature"]) f.node.classList.toggle(`is-${d}`, f.detail === d);
  }

  // Lay the ranking out in the lane. Arrivals (and an idle author) let it
  // reorder and change detail; otherwise what is there holds still, and
  // only what is new comes in, at its place.
  function layLane({ arrived = null } = {}) {
    const shown = ranking();
    const focusId = focus?.name ? idFor(focus) : null;
    const set = shown.filter((s) => s.kept && s.id !== focusId);
    const offered = shown.filter((s) => !s.kept && !s.focus).slice(0, OFFER_LIMIT);
    const want = [...set, ...offered];
    const calm = arrived || (Date.now() - lastInput > IDLE_MS && !inLane && !lane.querySelector(".frag.editing"));
    const ids = want.map((s) => s.id);
    if (calm) order = ids;
    else {
      // what is there stays put; what is new goes in where it ranks
      order = order.filter((id) => ids.includes(id));
      ids.forEach((id, i) => { if (!order.includes(id)) order.splice(Math.min(i, order.length), 0, id); });
    }
    for (const [id, f] of frags) {
      if (order.includes(id)) continue;
      f.fragment?.dispose();
      f.node.remove();
      frags.delete(id);
    }
    const byId = new Map(want.map((s) => [s.id, s]));
    const before = new Map([...frags].map(([id, f]) => [id, f.node.getBoundingClientRect().top]));
    order.forEach((id, i) => {
      const s = byId.get(id);
      let f = frags.get(id);
      if (!f) frags.set(id, (f = makeFrag(defOf(id))));
      f.offered = !s.kept;
      f.reasons = s.reasons;
      // detail changes wait for calm too, unless it is new or just arrived
      if (calm || !f.detail || id === arrived) f.detail = s.detail;
      renderFrag(f);
      if (lane.children[i] !== f.node) lane.insertBefore(f.node, lane.children[i] ?? null);
    });
    lane.querySelector(".lane-hint")?.remove();
    lane.querySelector(".lane-shelf")?.remove();
    if (!order.length) lane.append(el("div", "lane-hint", "⌘-click a name in the code, or click a row or a node, to read its definition here beside the focus."));
    renderShelf();
    // what moved glides there from where it was
    for (const [id, top] of before) {
      const f = frags.get(id);
      const moved = f && top - f.node.getBoundingClientRect().top;
      if (moved) f.node.animate([{ transform: `translateY(${moved / Math.max(board.zoom(), 0.2)}px)` }, { transform: "none" }], { duration: 280, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)" });
    }
    if (!calm) settleSoon();
    board.mark(new Map([
      ...offered.map((s) => [keyOf(s.path, s.name), "offered"]),
      ...set.map((s) => [keyOf(s.path, s.name), "set"]),
      ...(focusId ? [[keyOf(focus.path, focus.name), "focus"]] : []),
    ]));
    board.laneChanged();
    if (arrived && frags.has(arrived)) {
      const f = frags.get(arrived);
      flash(f.node);
      requestAnimationFrame(() => requestAnimationFrame(() => board.reveal(f.node)));
    }
  }

  // once the author is still, the lane takes the ranking's order
  let settling = 0;
  function settleSoon() {
    clearTimeout(settling);
    settling = setTimeout(() => {
      if (Date.now() - lastInput < IDLE_MS || inLane) return settleSoon();
      layLane();
      drawWires();
    }, IDLE_MS);
  }

  function renderShelf() {
    shelf = shelf.filter((id) => itemOf(defOf(id)) && !frags.has(id));
    if (!shelf.length) return;
    const row = el("div", "lane-shelf");
    row.append(el("span", "lane-shelf-label", "set aside"));
    for (const id of shelf.slice(0, 12)) {
      const def = defOf(id);
      const chip = el("button", "lane-chip", def.name);
      chip.title = `${short(def.path)} · bring it back`;
      chip.addEventListener("click", () => pull(def));
      row.append(chip);
    }
    lane.append(row);
  }

  function flash(node) {
    node.classList.remove("flash");
    void node.offsetWidth;
    node.classList.add("flash");
  }

  // hovering a name, a node, a row: everything showing that definition lights
  function hover(key) {
    board.light(key);
    for (const n of document.querySelectorAll(".frag.lit, .view-node.lit")) n.classList.remove("lit");
    if (!key) return;
    lane.querySelector(`.frag[data-key="${CSS.escape(key)}"]`)?.classList.add("lit");
    graph.querySelector(`.view-node[data-key="${CSS.escape(key)}"]`)?.classList.add("lit");
  }
  const lit = (def, on) => hover(on ? keyOf(def.path, def.name) : null);

  // ---- wires: from the line that uses a name to its fragment ------------------------------

  // Each fragment of the set at its code or row is wired from the first
  // line in the focus that uses it, else from the first fragment above it
  // that does -- so the lane reads as the focus's reading list, each item
  // tied to the place it is needed.
  function drawWires() {
    across.clear();
    if (board.zoom() < NEAR || !focus?.name) return;
    const pane = board.root.getBoundingClientRect();
    const editorBox = main.getDomNode()?.getBoundingClientRect();
    // only when the board is beside the focus (on a phone it is below it)
    if (!editorBox || pane.left < editorBox.right - 4) return;
    const span = focused.span();
    const model = main.getModel();
    const lineHeight = main.getOption(monaco.editor.EditorOption.lineHeight);
    for (const id of order) {
      const f = frags.get(id);
      if (!f || f.offered || f.detail === "signature") continue;
      const target = f.head.getBoundingClientRect();
      if (target.bottom < pane.top || target.top > pane.bottom || target.left > pane.right) continue;
      const to = across.point(target.left, target.top + target.height / 2);
      let from = null;
      if (span && focused.name() && itemOf(focus)?.uses.includes(f.def.name)) {
        const line = lineOf(model, span, f.def.name);
        const y = editorBox.top + main.getTopForLineNumber(line) - main.getScrollTop() + lineHeight / 2;
        if (y > editorBox.top && y < editorBox.bottom) from = across.point(editorBox.right - 6, y);
      } else {
        // a fragment above it that uses it
        for (const other of order.slice(0, order.indexOf(id))) {
          const g = frags.get(other);
          if (!g?.fragment || g.detail !== "full" || !itemOf(g.def)?.uses.includes(f.def.name)) continue;
          const box = g.fragment.node.getBoundingClientRect();
          const scale = box.height / Math.max(1, g.fragment.node.offsetHeight);
          from = across.point(box.right, box.top + g.fragment.yOf(f.def.name) * scale);
          wire(across.layer, from, across.point(target.right, target.top + target.height / 2), "use", { out: 26 });
          from = null;
          break;
        }
      }
      if (from) wire(across.layer, from, to, "use");
    }
  }

  // ---- the neighbourhood ---------------------------------------------------------------------

  const graphWires = svg("svg", { class: "view-graph-wires" });

  function node(def, role) {
    const item = itemOf(def);
    const chip = el("button", `view-node ${role}`);
    chip.dataset.key = keyOf(def.path, def.name);
    chip.dataset.role = role;
    chip.append(el("span", "view-kind", KIND[item?.kind] ?? "·"), el("span", "view-node-name", item?.kind === "property" ? item.sig : def.name));
    if (def.path !== focus?.path && role !== "focus" && item?.kind !== "property") chip.append(el("span", "view-module", short(def.path)));
    if (frags.has(idFor(def)) && !frags.get(idFor(def)).offered) chip.classList.add("in-set");
    if (item?.opaque) chip.classList.add("planned");
    chip.title = `${item?.sig ?? def.name}${item?.doc ? `\n${item.doc}` : ""}\nclick or ↵: into the lane · double-click or ⇧↵: focus on it`;
    if (role !== "focus") {
      chip.addEventListener("click", (event) => (event.metaKey || event.ctrlKey || event.shiftKey ? show(def) : pull(def)));
      chip.addEventListener("dblclick", () => show(def));
    }
    chip.addEventListener("pointerenter", () => lit(def, true));
    chip.addEventListener("pointerleave", () => lit(def, false));
    chip.addEventListener("focus", () => lit(def, true));
    chip.addEventListener("blur", () => lit(def, false));
    chip.addEventListener("keydown", (event) => graphKey(event, def, chip));
    return chip;
  }

  function nodes(list, role) {
    const row = el("div", `view-row ${role}`);
    const sorted = [...list].sort((a, b) => (a.path === focus.path ? 0 : 1) - (b.path === focus.path ? 0 : 1) || a.path.localeCompare(b.path) || a.name.localeCompare(b.name));
    for (const def of sorted.slice(0, NODES_MAX)) row.append(node(def, role));
    if (sorted.length > NODES_MAX) row.append(el("span", "view-more", `+${sorted.length - NODES_MAX}`));
    return row;
  }

  function renderGraph() {
    const had = graph.contains(document.activeElement) ? document.activeElement.dataset.key : null;
    graph.replaceChildren();
    const item = focus?.name && itemOf(focus);
    const body = el("div", "view-graph-body");
    const map = el("div", "view-map");
    const aside = el("div", "view-aside");
    body.append(map, aside);
    graph.append(body);
    if (item) {
      const { uses, users } = neighbours(focus);
      const callers = users.filter((d) => itemOf(d)?.kind !== "property");
      const properties = users.filter((d) => itemOf(d)?.kind === "property");
      const group = (role, list, label) => {
        const part = el("div", `view-part ${role}`);
        part.append(el("div", "view-row-label", label), nodes(list, role));
        return part;
      };
      const middle = el("div", "view-part focus");
      middle.append(node(focus, "focus"));
      map.append(group("caller", callers, callers.length ? "used by" : "used by nothing"), middle, group("callee", uses, uses.length ? "uses" : "uses nothing of the program's"));
      map.append(graphWires);
      if (properties.length) {
        aside.append(el("div", "view-section", "properties"));
        const list = el("div", "view-props");
        for (const def of properties) list.append(node(def, "property"));
        aside.append(list);
      }
    }
    // the focus's module: its other definitions, a click away
    const m = focus && outline().find((mm) => mm.path === focus.path);
    if (m) {
      aside.append(el("div", "view-section", `${short(m.path)}${m.requires.length ? ` · requires ${m.requires.map(short).join(", ")}` : ""}`));
      const card = el("div", "view-card");
      for (const i of m.items) {
        const def = { path: m.path, name: i.name };
        const row = node(def, "row");
        row.replaceChildren(el("span", "view-kind", KIND[i.kind] ?? "·"), el("span", "view-card-sig", i.kind === "property" ? i.sig : i.sig.replace(/^val /, "")));
        row.classList.toggle("current", i.name === focus.name);
        card.append(row);
      }
      aside.append(card);
    }
    if (had) graph.querySelector(`.view-node[data-key="${CSS.escape(had)}"]`)?.focus({ preventScroll: true });
    requestAnimationFrame(() => {
      sizeFocus();
      drawGraphWires();
    });
  }

  // curves from each caller to the focus, and from it to each callee:
  // left to right, or top to bottom when the map is stacked (narrow)
  function drawGraphWires() {
    if (!graphWires.isConnected) return;
    const map = graphWires.parentNode;
    const box = map.getBoundingClientRect();
    const down = getComputedStyle(map).flexDirection !== "row";
    graphWires.replaceChildren();
    const center = map.querySelector(".view-node.focus")?.getBoundingClientRect();
    if (!center) return;
    // the point a wire leaves (end) or enters a box
    const point = (r, end) => (down
      ? { x: r.left + r.width / 2 - box.left, y: (end ? r.bottom : r.top) - box.top }
      : { x: (end ? r.right : r.left) - box.left, y: r.top + r.height / 2 - box.top });
    for (const chip of map.querySelectorAll(".view-node.caller, .view-node.callee")) {
      const r = chip.getBoundingClientRect();
      const caller = chip.classList.contains("caller");
      const [a, b] = caller ? [point(r, true), point(center, false)] : [point(center, true), point(r, false)];
      graphWires.append(svg("path", { d: curve(a, b, { down }), class: `wire ${caller ? "caller" : "callee"}` }));
    }
  }

  // Arrow keys walk the neighbourhood's nodes by where they are on the
  // screen (the nearest one that way); ↵ pulls the node's definition into
  // the lane, ⇧↵ or ⌘↵ focuses it, ] and [ pull what it uses or what uses
  // it, Esc goes back to the code.
  function graphKey(event, def, chip) {
    const go = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[event.key];
    if (go) {
      event.preventDefault();
      const from = chip.getBoundingClientRect();
      const cx = from.left + from.width / 2;
      const cy = from.top + from.height / 2;
      let best = null;
      for (const other of graph.querySelectorAll(".view-node")) {
        if (other === chip) continue;
        const r = other.getBoundingClientRect();
        const dx = r.left + r.width / 2 - cx;
        const dy = r.top + r.height / 2 - cy;
        // that way, and nearer that way than across it
        const along = dx * go[0] + dy * go[1];
        const off = Math.abs(dx * go[1]) + Math.abs(dy * go[0]);
        if (along <= 2) continue;
        const cost = along + off * 2.5;
        if (!best || cost < best.cost) best = { other, cost };
      }
      best?.other.focus();
      return;
    }
    const act = {
      Enter: () => (event.shiftKey || event.metaKey || event.ctrlKey ? show(def) : chip.dataset.role === "focus" ? main.focus() : pull(def)),
      "]": () => along(def, "uses"),
      "[": () => along(def, "users"),
      Escape: () => main.focus(),
    }[event.key];
    if (act) {
      event.preventDefault();
      event.stopPropagation();
      act();
    }
  }

  // ---- all of it -----------------------------------------------------------------------------

  function render({ arrived = null } = {}) {
    if (!restored) return;
    renderHead();
    layLane({ arrived });
    renderGraph();
    save();
    requestAnimationFrame(drawWires);
  }

  // things fade (an edit's news, a dismissal): rank again now and then
  setInterval(() => { if (!document.hidden) { layLane(); drawWires(); } }, 30000);

  // ---- kept per project, in this browser -------------------------------------------------

  const storeKey = () => `puffin-view.${document.getElementById("project")?.textContent.trim() ?? ""}`;
  function save() {
    if (!restored) return;
    try {
      localStorage.setItem(storeKey(), JSON.stringify({ focus, whole, past: past.slice(-30), at: Math.min(at, 29), shelf }));
    } catch { /* private window */ }
  }

  // Once the outline is in: what this browser had in focus, else the
  // first screen -- the shown file whole if it is short (a script like
  // main.puf reads best whole), else its first definition focused.
  function restore() {
    restored = true;
    let kept = null;
    try { kept = JSON.parse(localStorage.getItem(storeKey()) ?? "null"); } catch { /* none */ }
    const known = (d) => d?.name && itemOf(d);
    shelf = (kept?.shelf ?? []).filter((id) => itemOf(defOf(id)));
    past = (kept?.past ?? []).filter(known);
    at = Math.min(kept?.at ?? past.length - 1, past.length - 1);
    if (known(kept?.focus) && !kept.whole) return show(kept.focus, { push: false });
    const path = kept?.focus?.path && files.paths().includes(kept.focus.path) ? kept.focus.path : files.active();
    moving = true;
    if (path && files.active() !== path) files.open(path);
    moving = false;
    const text = main.getModel()?.getValue() ?? "";
    const first = forms(text).find((f) => DEFINES.has(f.head) && f.name);
    const name = kept?.focus?.name ?? first?.name ?? null;
    if (!kept && name && text.split("\n").length > SHORT_FILE) return show({ path, name });
    focus = { path, name };
    whole = true;
    narrowFocus();
    render();
    requestAnimationFrame(() => board.home(false));
  }

  // ---- keys ------------------------------------------------------------------------------

  // the definition named at the cursor of whichever code has the keyboard
  function nameAtCursor() {
    const views = [main, ...[...frags.values()].map((f) => f.fragment?.view).filter(Boolean)];
    const view = views.find((v) => v.hasTextFocus());
    const word = view?.getModel()?.getWordAtPosition(view.getPosition());
    return word ? find(word.word) : null;
  }

  window.addEventListener("keydown", (event) => {
    if (event.metaKey || event.ctrlKey) return;
    const take = () => { event.preventDefault(); event.stopPropagation(); };
    if (event.altKey && event.key === "ArrowLeft") { take(); back(-1); }
    else if (event.altKey && event.key === "ArrowRight") { take(); back(1); }
    else if (event.altKey && event.code === "Comma" && !event.shiftKey) { take(); back(-1); }
    else if (event.altKey && event.code === "Period" && !event.shiftKey) {
      // ⌥. (Emacs's M-.): its definition into the lane; again, focused
      take();
      const def = nameAtCursor();
      if (def) (frags.has(idFor(def)) && !frags.get(idFor(def)).offered ? show(def) : pull(def));
    } else if (event.altKey && event.code === "KeyO") { take(); setWhole(!whole); }
    else if (event.key === "F6") {
      // the focus, the neighbourhood, then each fragment's code in turn
      event.preventDefault();
      const stops = [main, { focus: () => graph.querySelector(".view-node.focus, .view-node")?.focus(), hasTextFocus: () => graph.contains(document.activeElement) }, ...order.map((id) => frags.get(id)?.fragment?.view).filter(Boolean)];
      const now = stops.findIndex((v) => v.hasTextFocus());
      const next = stops[(now + (event.shiftKey ? -1 : 1) + stops.length) % stops.length];
      next.focus();
      const f = [...frags.values()].find((x) => x.fragment?.view === next);
      if (f) board.reveal(f.node);
    }
  }, true);

  let reranking = 0;
  const api = {
    // the board or the outline changed (board.js `receive`)
    boardChanged() {
      if (!restored && outline().length) return restore();
      // a member that arrived from elsewhere (the voice): brought into view
      const now = new Set(setOf().map((s) => s.id));
      const came = [...now].find((id) => !frags.has(id) || frags.get(id).offered);
      render({ arrived: came && !order.includes(came) ? came : null });
    },
    opened,
    // every socket message: the model's view of the studio -- and a moment
    // later, the ranking again
    receive(message) {
      tracker.receive(message);
      if (["voice", "diagnostics", "text"].includes(message.t)) {
        clearTimeout(reranking);
        reranking = setTimeout(() => { layLane(); drawWires(); }, 400);
      }
    },
    // a row's ↗, the palette's definitions, a hole: focus the definition at
    // `line` of `path` (with `find`, its first match from there selected)
    focusAt(path, line, findText) {
      if (files.active() !== path) {
        moving = true;
        files.open(path);
        moving = false;
      }
      const name = nameAt(main.getModel().getValue(), line);
      if (!name) return false;
      let select = null;
      if (findText) {
        const found = main.getModel().findNextMatch(findText, { lineNumber: line, column: 1 }, false, true, null, false);
        if (found) select = found.range;
      }
      show({ path, name }, { select });
      board.home();
      return true;
    },
    // ---- what the board does with a row (board.js `bind`) ----
    pull: (path, name) => pull({ path, name }),
    focus: (path, line, findText) => api.focusAt(path, line, findText),
    along: (path, name, direction) => along({ path, name }, direction),
    hover,
    showLess: (path, name) => attention.showLess(idOf(path, name)),
  };
  board.bind(api);
  return api;
}
