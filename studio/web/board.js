// The board (docs/VIEW.md, docs/PLANNING.md; the server side is
// studio/src/board.rs): the program as one zoomable surface, moved by a
// camera (camera.js), beside the focus pane (view.js).
//
// On it, a card per module: its ML-style signature, one row per
// definition (ƒ function, · value, τ type, ≡ alias, G grammar, and the
// spec's properties). Left of the cards runs the *lane*: the working set,
// the definitions the author is reading beside the focus, live code on
// their files' own models (fragment.js; view.js decides what is in it).
// Close in, the camera frames the lane -- a column of code beside the
// focus; zooming out (the wheel, a pinch, ⌘⇧B, "show the board") glides
// out to the whole program, each fragment wired to its row on its card;
// zooming back in returns to the lane. There is no board mode and no
// editor mode: how close the camera is decides what is drawn (semantic
// zoom: near, code; middling, signatures; far, names).
//
//   the HUD (top left): how much of the plan is written, the properties,
//     a filter, the zoom
//   hover a row (or move the cursor to it): the lens -- wires run from it
//     to everything it uses (blue) and from everything that uses it
//     (violet), across cards
//   click a row: its code into the lane · double-click (or ↗): focus it
//   keys: type or / to filter · ↑↓ rows · ←→ cards · ↵ into the lane ·
//     e focus · ] what it uses next, [ what uses it, into the lane ·
//     h hide · f just this and what touches it · n note · b build ·
//     Esc clears · + − zoom · 0 everything · 1 the lane · t tidy
//   drag a card by its title; drag the board to pan; ⌘/ctrl + wheel zooms
//   rows the builder just wrote or changed glow for a moment
//   a focus (a question's slice, "just show ...") packs only what it
//     names under the question; the author's layout comes back after
//
// The board's state is the server's (Event::Board, .puffin/board.json),
// the working set's membership included (`set`, so voice can pull into
// it); every change here is sent back whole with `board-set`. The camera,
// the filter and the cursor are this tab's own.

import { createCamera } from "./camera.js";
import { svg, curve } from "./wires.js";

const KIND = { fun: "ƒ", val: "·", type: "τ", alias: "≡", grammar: "G", property: "?", decision: "◇" };
// the card of the builder's questions and the author's answers
const DECISIONS = "#decisions";
const PROP_MARK = { ok: "✓", fail: "✗", crashed: "!", open: "◌", "not-run": "·", pending: "…" };
const GRID = { x: 28, y: 92, w: 380, gap: 24 };
const FRESH_MS = 2600;
// the zoom below which code gives way to signatures, and signatures to names
const NEAR = 0.62;
const FAR = 0.38;
// the lane is framed no further out than this: its code is read there
const READABLE = 0.75;
// the room between the lane and the cards
const LANE_GAP = 96;
// narrower than this, the board stacks its cards under the lane (a phone)
const COMPACT = 700;

const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

const clone = (value) => JSON.parse(JSON.stringify(value));

// A click that may be the first of a double-click: `once` waits a moment
// to see (a row's click brings its code in, its double-click focuses it;
// so do the neighbourhood's nodes, view.js).
export function clicks(node, once, twice) {
  let waiting = 0;
  node.addEventListener("click", (event) => {
    clearTimeout(waiting);
    if (event.detail <= 1) waiting = setTimeout(() => once(event), 240);
  });
  node.addEventListener("dblclick", (event) => {
    clearTimeout(waiting);
    twice(event);
  });
}
const short = (path) => path.replace(/\.puf$/, "");
const keyOf = (path, name) => `${path}\u001f${name}`;
const typing = (target) => target?.closest?.("input, textarea, [contenteditable], .monaco-editor");

export function createBoard({ send, stage, onChange }) {
  // what the working set (view.js) does with a row: { pull(path, name),
  // focus(path, line, find), along(path, name, "uses" | "users"),
  // hover(key) }; bound once it exists
  let view = null;
  let board = { mode: "build", cards: [], focus: null, questions: [], set: [] };
  let outline = [];
  let propertyStatus = new Map(); // name -> { status, detail } (voice.js)
  const revealed = new Set(); // cards whose hidden rows are shown for now
  let dragging = null;
  let lens = null; // the key of the row the lens is on (hover, or the cursor)
  let cursor = null; // the keyboard's row
  let query = "";
  let seen = null; // key -> what each row was, to see what the builder changed
  const fresh = new Map(); // key -> until when it glows
  // the note being written: { file, name (null: the module), id (editing
  // one), kind, text }
  let writing = null;
  // the card a signature is being typed on (designing on the board)
  let adding = null;
  let addText = "";
  // rows the builder was asked to build, until their body arrives
  const building = new Set();



  // ---- the page -----------------------------------------------------------------

  const root = el("div", "board");
  root.tabIndex = -1;
  const canvas = el("div", "board-canvas canvas-pan");
  const wires = svg("svg", { class: "board-wires" });
  const lensLayer = svg("svg", { class: "board-lens" });
  // the wires from each fragment in the lane to its row
  const laneLayer = svg("svg", { class: "board-lane-wires" });
  // the working set's column, filled by view.js
  const lane = el("div", "board-lane");
  const question = el("div", "board-question");
  question.hidden = true;
  const empty = el("div", "board-empty");
  canvas.append(wires, laneLayer, lane, lensLayer);
  root.append(canvas, empty);

  // the HUD: progress, properties, filter, zoom
  const hud = el("div", "board-hud");
  const progress = el("div", "board-progress");
  const bar = el("div", "board-bar");
  const filter = el("input", "board-filter");
  filter.placeholder = "Filter  /";
  filter.spellcheck = false;
  filter.title = "Show only the definitions whose name or signature match (/ or just start typing; ↵ focuses them, Esc clears)";
  const zoomOut = el("button", "board-zoom", "−");
  const zoomLabel = el("button", "board-zoom board-zoom-label");
  const zoomIn = el("button", "board-zoom", "+");
  zoomOut.title = "Zoom out (−)";
  zoomIn.title = "Zoom in (+)";
  zoomLabel.title = "The whole program (0, ⌘⇧B); again, back to the code";
  const keysHelp = el("button", "board-zoom board-help", "?");
  keysHelp.title = "Keys: type or / filter · ↑↓ rows · ←→ cards · ↵ into the lane · e focus · ] [ what it uses / what uses it · n note · b build · h hide · f focus · t tidy · Esc clear · + − zoom · 0 everything · 1 the lane";
  const tools = el("div", "board-hud-tools");
  tools.append(filter, zoomOut, zoomLabel, zoomIn, keysHelp);
  hud.append(progress, bar, tools);
  stage.append(root, question, hud);

  // Semantic zoom: the root says how close the camera is, the styles
  // decide what each distance shows. Whatever joins the board to the
  // rest of the screen (view.js's wires) is told of every move.
  const moved = new Set();
  const camera = createCamera({
    viewport: root,
    layer: canvas,
    onChange(z) {
      const level = z >= NEAR ? "z-near" : z >= FAR ? "z-mid" : "z-far";
      // a new level of detail changes the cards' heights: the cards
      // below move up or down
      if (!root.classList.contains(level)) requestAnimationFrame(() => { settle(); renderWires(); renderLaneWires(); });
      root.classList.toggle("z-near", z >= NEAR);
      root.classList.toggle("z-mid", z < NEAR && z >= FAR);
      root.classList.toggle("z-far", z < FAR);
      root.style.setProperty("--unzoom", String(Math.min(3, 1 / z)));
      zoomLabel.textContent = `${Math.round(z * 100)}%`;
    },
    onFrame: () => { for (const f of moved) f(); },
  });

  // the board appearing, or a window of another size: what was framed is
  // framed again for the new size
  let lastWidth = 0;
  let reframe = 0;
  new ResizeObserver(() => {
    const width = root.offsetWidth;
    if (width && !lastWidth) render();
    if (width && lastWidth && Math.abs(width - lastWidth) > 40) {
      clearTimeout(reframe);
      reframe = setTimeout(() => { render(); camera.zoom() >= NEAR ? home(false) : overview(false); }, 120);
    }
    lastWidth = width;
    for (const f of moved) f();
  }).observe(root);

  // ---- state ------------------------------------------------------------------------

  function save() {
    send({ t: "board-set", board });
  }

  function change(f) {
    const next = clone(board);
    f(next);
    board = next;
    render();
    save();
  }

  // the decisions: a card like a module's, one row per question asked;
  // `uses` are the definitions it was about, so the lens shows what an
  // answer shaped
  function decisions() {
    const qs = board.questions ?? [];
    const decided = (board.notes ?? []).filter((n) => n.kind === "decision");
    if (!qs.length && !decided.length) return null;
    return {
      path: DECISIONS,
      requires: [],
      provides: null,
      effects: 0,
      items: qs.map((q) => ({
        name: `#${q.id}`,
        kind: "decision",
        sig: q.text,
        doc: q.answered ? `→ ${q.answer ?? ""}` : q.why ?? "",
        line: 0,
        end_line: 0,
        holes: 0,
        opaque: !q.answered,
        uses: q.about ?? [],
        question: q,
      })).concat(decided.map((n) => ({
        name: `note${n.id}`,
        kind: "decision",
        sig: n.text,
        doc: `on ${n.name ?? `the ${short(n.file)} module`}${n.name ? ` · ${short(n.file)}` : ""}`,
        line: 0,
        end_line: 0,
        holes: 0,
        opaque: false,
        uses: n.name ? [n.name] : [],
        note: n,
      }))),
    };
  }
  const allModules = () => {
    const d = decisions();
    return d ? [...outline, d] : outline;
  };
  const moduleOf = (path) => allModules().find((m) => m.path === path);
  const itemOf = (key) => {
    const [path, name] = key.split("\u001f");
    const m = moduleOf(path);
    return m && { m, item: m.items.find((i) => i.name === name) };
  };

  function focusNames() {
    return board.focus?.items ? new Set(board.focus.items.map(([file, name]) => keyOf(file, name))) : null;
  }

  function matches(m, item) {
    if (!query) return true;
    const hay = `${item.name} ${item.sig} ${short(m.path)}`.toLowerCase();
    return query.toLowerCase().split(/\s+/).filter(Boolean).every((word) => hay.includes(word));
  }

  // what a definition uses, and what uses it, by name across the outline
  function neighbours(name) {
    const uses = new Set();
    const users = new Set();
    for (const m of allModules()) {
      for (const i of m.items) {
        if (i.name === name) for (const u of i.uses) uses.add(u);
        if (i.uses.includes(name) && i.name !== name) users.add(keyOf(m.path, i.name));
      }
    }
    const usesKeys = new Set();
    for (const m of outline) for (const i of m.items) if (uses.has(i.name)) usesKeys.add(keyOf(m.path, i.name));
    return { uses: usesKeys, users };
  }

  // ---- layout -------------------------------------------------------------------------

  // a module's depth in the require graph among the cards out (what it
  // requires comes first): the order layouts read left to right
  function depths(cards) {
    const depth = new Map();
    const depthOf = (path, seenPaths = new Set()) => {
      if (depth.has(path)) return depth.get(path);
      if (seenPaths.has(path)) return 0;
      seenPaths.add(path);
      const m = moduleOf(path);
      const d = m ? Math.max(0, ...m.requires.filter((r) => cards.some((c) => c.path === r)).map((r) => depthOf(r, seenPaths) + 1)) : 0;
      depth.set(path, d);
      return d;
    };
    return depthOf;
  }

  // shelf-pack `cards` (in dependency order) from `top`, wrapping at the
  // board's width; `size(path)` measures; returns path -> {x, y}
  function shelves(cards, size, top) {
    const depthOf = depths(cards);
    // the program in dependency order, then the spec, then the decisions
    const tail = (path) => (path === DECISIONS ? 2 : path === "properties.puf" ? 1 : 0);
    const order = [...cards].sort((a, b) => tail(a.path) - tail(b.path) || depthOf(a.path) - depthOf(b.path) || a.path.localeCompare(b.path));
    const limit = Math.max(root.clientWidth - GRID.x, GRID.w * 2);
    const out = new Map();
    let x = GRID.x;
    let y = top;
    let shelf = 0;
    for (const card of order) {
      const { w, h } = size(card.path);
      if (x > GRID.x && x + w > limit) {
        x = GRID.x;
        y += shelf + GRID.gap;
        shelf = 0;
      }
      out.set(card.path, { x, y });
      x += w + GRID.gap * 1.5;
      shelf = Math.max(shelf, h);
    }
    return out;
  }

  const nodeOf = (path) => canvas.querySelector(`.board-card[data-path="${CSS.escape(path)}"]`);
  const sizeOf = (path) => ({ w: nodeOf(path)?.offsetWidth ?? GRID.w, h: nodeOf(path)?.offsetHeight ?? 120 });

  // Cards without a place, placed now that they have a size. On a fresh
  // board: shelves in dependency order. Otherwise each goes right of the
  // cards already out.
  function placeUnplaced() {
    const unplaced = board.cards.filter((c) => c.x == null || c.y == null);
    // sizes are only real once the board is on screen (not behind the canvas)
    if (!unplaced.length || !root.offsetWidth) return false;
    const next = clone(board);
    const placed = next.cards.filter((c) => c.x != null && c.y != null);
    if (!placed.length) {
      const spots = shelves(next.cards, sizeOf, GRID.y);
      for (const card of next.cards) Object.assign(card, spots.get(card.path));
    } else {
      const x = Math.max(...placed.map((c) => c.x + sizeOf(c.path).w)) + GRID.gap * 2;
      let y = GRID.y;
      for (const card of next.cards.filter((c) => c.x == null || c.y == null)) {
        card.x = x;
        card.y = y;
        y += sizeOf(card.path).h + GRID.gap;
      }
    }
    board = next;
    save();
    return true;
  }

  function ensureCard(b, path, at) {
    let card = b.cards.find((c) => c.path === path);
    if (!card) {
      // no place given: placed once it has been measured (placeUnplaced)
      card = { path, x: at?.x ?? null, y: at?.y ?? null, open: [], hidden: [], pinned: [] };
      b.cards.push(card);
    }
    return card;
  }


  // ---- showing it -----------------------------------------------------------------------

  // "The board" and "the code" are where the camera is (voice.js, the
  // palette, ⌘⇧B): out at the program, or in at the lane.
  function setView(where) {
    if (where === "editor") home();
    else overview();
  }

  // a re-render (the builder's edit arriving) must not take the cursor
  // out of a note being written
  // whether the camera has been put where a focus is laid out
  let focusFramed = false;
  function render() {
    const active = document.activeElement;
    const kind = ["board-note-text-input", "board-add-input"].find((c) => active?.classList?.contains(c));
    const at = kind ? [active.selectionStart, active.selectionEnd] : null;
    renderBoard();
    if (kind) {
      const box = canvas.querySelector(`.${kind}`);
      if (box) {
        box.focus({ preventScroll: true });
        box.setSelectionRange(...at);
      }
    }
  }

  function renderBoard() {
    // nothing out yet: every module, once the outline has arrived
    if (!board.cards.length && outline.length) {
      const next = clone(board);
      for (const m of outline) ensureCard(next, m.path);
      board = next;
      save();
    }
    onChange?.();
    const now = Date.now();
    for (const [key, until] of fresh) if (until < now) fresh.delete(key);
    const focus = focusNames();
    const keep = new Set(board.cards.map((c) => c.path));
    for (const node of [...canvas.querySelectorAll(".board-card")]) if (!keep.has(node.dataset.path)) node.remove();
    for (const card of board.cards) {
      const m = moduleOf(card.path);
      if (!m) continue;
      let node = nodeOf(card.path);
      if (!node) {
        node = el("div", "board-card arriving");
        node.dataset.path = card.path;
        canvas.append(node);
        setTimeout(() => node.classList.remove("arriving"), 50);
      }
      renderCard(node, card, m, focus);
      if (!(dragging && dragging.path === card.path)) {
        // an unplaced card is measured out of sight first
        node.classList.toggle("unplaced", card.x == null);
        node.style.left = card.x == null ? "-9999px" : `${card.x}px`;
        node.style.top = card.y == null ? "0px" : `${card.y}px`;
      }
    }
    if (placeUnplaced()) return renderBoard();
    renderQuestion();
    // A narrow window (a phone): the lane on top, the cards stacked under
    // it in dependency order, whatever their saved places (the saved
    // layout is untouched).
    const compact = root.clientWidth > 0 && root.clientWidth < COMPACT;
    root.classList.toggle("compact", compact);
    placeLane();
    if (compact && !focus) {
      for (const node of canvas.querySelectorAll(".board-card")) node.hidden = false;
      const below = Math.max(GRID.y, parseFloat(lane.style.top) + lane.offsetHeight + GRID.gap * 2);
      for (const [path, spot] of shelves(board.cards.filter((c) => nodeOf(c.path)), sizeOf, below)) {
        const node = nodeOf(path);
        node.style.left = `${spot.x}px`;
        node.style.top = `${spot.y}px`;
      }
    } else if (focus) {
      // A focus (a question's slice, "just show ..."): only the cards it
      // names, packed in dependency order, framed under the question. The
      // author's own layout is untouched and comes back when the focus
      // clears.
      const focused = board.cards.filter((c) => (moduleOf(c.path)?.items ?? []).some((i) => focus.has(keyOf(c.path, i.name))));
      for (const card of board.cards) {
        const node = nodeOf(card.path);
        if (node) node.hidden = !focused.includes(card);
      }
      const spots = shelves(focused, sizeOf, GRID.y);
      for (const [path, spot] of spots) {
        const node = nodeOf(path);
        node.style.left = `${spot.x}px`;
        node.style.top = `${spot.y}px`;
      }
      if (!focusFramed) {
        const under = (question.hidden ? 0 : question.offsetTop + question.offsetHeight) + 16;
        requestAnimationFrame(() => camera.frame(focused.map((c) => canvasBox(nodeOf(c.path))), { min: 0.3, max: 1, top: under - 36, align: "start" }));
      }
      focusFramed = true;
    } else {
      focusFramed = false;
      for (const node of canvas.querySelectorAll(".board-card")) node.hidden = false;
      settle();
    }
    renderEmpty();
    renderHud();
    renderWires();
    renderLaneWires();
    renderLens();
    renderMarks();
    for (const f of moved) f();
  }

  function renderEmpty() {
    empty.hidden = board.cards.length > 0;
    empty.replaceChildren();
    if (!empty.hidden) {
      empty.append(
        el("div", "board-empty-title", outline.length ? "Nothing on the board" : "No modules yet"),
        el("div", "board-empty-text", outline.length ? "Drag a module from the bar onto the board." : "Describe what to build — the design lands here as signatures."),
      );
    }
  }

  function renderCard(node, card, m, focus) {
    node.replaceChildren();
    const inFocus = focus && m.items.some((i) => focus.has(keyOf(m.path, i.name)));
    const anyMatch = m.items.some((i) => matches(m, i));
    node.classList.toggle("faded", (Boolean(focus) && !inFocus) || (Boolean(query) && !anyMatch));
    node.classList.toggle("is-properties", m.path === "properties.puf");
    const head = el("div", "board-card-head");
    const title = el("span", "board-card-title", short(m.path));
    title.title = `${m.path} — drag to move, double-click to edit`;
    const meta = el("span", "board-card-meta");
    const funs = m.items.filter((i) => i.kind === "fun" || i.kind === "val");
    const planned = funs.filter((i) => i.opaque).length;
    if (m.path === DECISIONS) {
      title.textContent = "decisions";
      title.title = "The builder's questions and your answers — drag to move";
      const open = m.items.filter((i) => i.opaque).length;
      meta.textContent = `${m.items.length - open} decided`;
      if (open) meta.append(el("span", "board-holes", ` · ? ${open} open`));
    } else if (m.path === "properties.puf") {
      const counts = countProperties(m);
      meta.textContent = `${m.items.length} propert${m.items.length === 1 ? "y" : "ies"}`;
      if (counts.ok) meta.append(el("span", "board-meta-ok", ` · ✓ ${counts.ok}`));
      if (counts.bad) meta.append(el("span", "board-meta-bad", ` · ✗ ${counts.bad}`));
      if (counts.open) meta.append(el("span", "board-holes", ` · ◌ ${counts.open}`));
    } else {
      if (m.items.some((i) => i.internal)) {
        const exported = m.items.filter((i) => !i.internal).length;
        meta.textContent = `${exported} of ${m.items.length} provided`;
      } else meta.textContent = `${m.items.length} definition${m.items.length === 1 ? "" : "s"}`;
      if (planned) meta.append(el("span", "board-holes", ` · ◌ ${planned} planned`));
    }
    const close = el("button", "board-x", "✕");
    close.title = "Put this card away";
    close.addEventListener("click", (event) => {
      event.stopPropagation();
      change((b) => { b.cards = b.cards.filter((c) => c.path !== m.path); });
    });
    const noteButton = el("button", "board-x board-card-note", "✎");
    noteButton.title = m.path === DECISIONS ? "" : "A decision or comment on the whole module";
    noteButton.addEventListener("click", (event) => { event.stopPropagation(); startNote(m.path, null); });
    if (m.path === DECISIONS) noteButton.hidden = true;
    head.append(title, meta, noteButton, close);
    head.addEventListener("pointerdown", (event) => startDrag(event, node, card));
    node.append(head);
    const requires = m.requires.filter((r) => r !== "prop.puf");
    if (requires.length) node.append(el("div", "board-requires", `requires ${requires.map(short).join(", ")}`));
    const moduleNotes = notesOn(m.path, null);
    if (moduleNotes.length || (writing && writing.file === m.path && writing.name == null)) {
      const block = el("div", "board-module-notes");
      for (const note of moduleNotes) block.append(renderNote(note));
      if (writing && writing.file === m.path && writing.name == null && writing.id == null) block.append(noteEditor());
      node.append(block);
    }

    const hidden = new Set(card.hidden);
    const showHidden = revealed.has(m.path);
    let tucked = 0;
    const list = el("div", "board-items");
    for (const item of m.items) {
      const key = keyOf(m.path, item.name);
      const focused = focus?.has(key);
      const out = focus ? !focused : (hidden.has(item.name) && !showHidden) || !matches(m, item);
      if (out) {
        tucked++;
        continue;
      }
      list.append(renderItem(m, item, hidden.has(item.name), focused));
    }
    node.append(list);
    if (m.path !== DECISIONS && m.path !== "properties.puf" && !focus) node.append(addRow(m));
    if (tucked) {
      const label = focus ? `${tucked} not in focus` : query ? `${tucked} not matching` : `${tucked} hidden`;
      const more = el("button", "board-more", label);
      more.addEventListener("click", () => {
        if (focus || query) return;
        revealed.has(m.path) ? revealed.delete(m.path) : revealed.add(m.path);
        render();
      });
      node.append(more);
    } else if (showHidden && hidden.size) {
      const less = el("button", "board-more", "hide them again");
      less.addEventListener("click", () => { revealed.delete(m.path); render(); });
      node.append(less);
    }
    if (m.effects) node.append(el("div", "board-effects", `+ ${m.effects} top-level expression${m.effects === 1 ? "" : "s"}`));
  }

  function renderItem(m, item, isHidden, focused) {
    const key = keyOf(m.path, item.name);
    const classes = [
      "board-item",
      `kind-${item.kind}`,
      item.opaque && "opaque",
      item.internal && "internal",
      isHidden && "is-hidden",
      focused && "focused",
      fresh.has(key) && "fresh",
      building.has(key) && item.opaque && "building",
      cursor === key && "cursor",
    ].filter(Boolean).join(" ");
    const row = el("div", classes);
    row.dataset.key = key;
    const line = el("div", "board-item-line");
    if (item.kind === "decision" && item.note) {
      const n = item.note;
      line.append(el("span", "board-kind board-decision decided", "◆"));
      line.append(el("span", "board-sig board-statement", item.sig));
      line.title = "Your decision — click to see what it governs";
      line.addEventListener("click", (event) => {
        event.stopImmediatePropagation();
        cursor = key;
        if (n.name) reopenQuestion({ answered: true, text: n.text, answer: "", about: [n.name] });
      });
      line.addEventListener("pointerenter", () => setLens(key));
      line.addEventListener("pointerleave", () => setLens(null));
      row.append(line, el("div", "board-doc", item.doc));
      return row;
    }
    if (item.kind === "decision") {
      const q = item.question;
      line.append(el("span", `board-kind board-decision ${q.answered ? "decided" : "open"}`, q.answered ? "✓" : "?"));
      line.append(el("span", "board-sig board-statement", item.sig));
      line.title = q.answered ? `Decided: ${q.answer ?? ""}` : "Open — click to put the question in front of you again";
      line.addEventListener("click", (event) => {
        event.stopImmediatePropagation();
        cursor = key;
        reopenQuestion(q);
      });
      line.addEventListener("pointerenter", () => setLens(key));
      line.addEventListener("pointerleave", () => setLens(null));
      row.append(line);
      if (item.doc) row.append(el("div", `board-doc${q.answered ? " board-answer-text" : ""}`, item.doc));
      return row;
    }
    if (item.kind === "property") {
      const st = propertyStatus.get(item.name);
      const mark = el("span", `board-kind board-prop ${st?.status ?? "pending"}`, PROP_MARK[st?.status] ?? "?");
      mark.title = st ? `${st.status}${st.detail ? ` — ${st.detail}` : ""}` : "not run yet";
      line.append(mark, el("span", "board-sig board-statement", item.sig));
    } else {
      line.append(el("span", "board-kind", KIND[item.kind] ?? "·"));
      line.append(signature(item));
    }
    if (item.opaque) {
      const hole = el("span", "board-opaque", "◌");
      hole.title = "Planned: the body is a hole (??) — click to write it";
      hole.addEventListener("click", (event) => { event.stopPropagation(); view?.focus(m.path, item.line, "??"); });
      line.append(hole);
    } else if (item.holes) {
      const hole = el("span", "board-opaque", `◌${item.holes}`);
      hole.title = `${item.holes} hole${item.holes === 1 ? "" : "s"} left in the body`;
      line.append(hole);
    }
    const notes = notesOn(m.path, item.name);
    if (notes.length) {
      const badge = el("span", `board-note-count${notes.some((n) => n.kind === "decision") ? " decided" : ""}`, `✎${notes.length}`);
      badge.title = `${notes.length} note${notes.length === 1 ? "" : "s"}`;
      line.append(badge);
    }
    const actions = el("span", "board-tools");
    if (item.opaque || item.holes) {
      const build = el("button", "board-build", "▸");
      build.title = "Build it: the builder writes this body, honoring the decisions on it (b)";
      build.addEventListener("click", (event) => { event.stopPropagation(); buildIt(m.path, item.name); });
      actions.append(build);
    }
    const noteButton = el("button", "", "✎");
    noteButton.title = "A decision or comment on this (n)";
    noteButton.addEventListener("click", (event) => { event.stopPropagation(); startNote(m.path, item.name); });
    actions.append(noteButton);
    const edit = el("button", "", "↗");
    edit.title = "Focus on it, to edit (e, or double-click the row)";
    edit.addEventListener("click", (event) => { event.stopPropagation(); view?.focus(m.path, item.line); });
    const hide = el("button", "", isHidden ? "◉" : "✕");
    hide.title = isHidden ? "Show it again" : "Hide it on this card (h)";
    hide.addEventListener("click", (event) => { event.stopPropagation(); toggleHidden(m.path, item.name, isHidden); });
    actions.append(edit, hide);
    line.append(actions);
    line.title = [item.doc, `${m.path}:${item.line}`, item.uses.length ? `uses ${item.uses.join(", ")}` : "", item.internal ? "internal: not part of the module's interface" : ""].filter(Boolean).join("\n");
    // a click: its code into the lane; a double-click: the focus
    line.addEventListener("click", () => { cursor = key; });
    clicks(line, () => view?.pull(m.path, item.name), () => view?.focus(m.path, item.line));
    line.addEventListener("pointerenter", () => { setLens(key); view?.hover(key); });
    line.addEventListener("pointerleave", () => { setLens(null); view?.hover(null); });
    row.append(line);
    if (item.doc) row.append(el("div", "board-doc", item.doc));
    for (const note of notes) row.append(renderNote(note));
    if (writing && writing.file === m.path && writing.name === item.name && writing.id == null) row.append(noteEditor());
    return row;
  }

  // ---- designing on the board: a signature becomes a planned definition --------------------

  function addRow(m) {
    if (adding !== m.path) {
      const plus = el("button", "board-add", "+ plan a definition");
      plus.title = "Type a signature -- val name : Type -> Type, or type T = A | B of Int -- and it is planned in this module, its body a hole";
      plus.addEventListener("click", (event) => {
        event.stopPropagation();
        adding = m.path;
        addText = "";
        render();
        setTimeout(() => canvas.querySelector(".board-add-input")?.focus(), 20);
      });
      return plus;
    }
    const box = el("div", "board-add-box");
    const input = el("input", "board-add-input");
    input.value = addText;
    input.spellcheck = false;
    input.placeholder = "val name : Type -> Type    ·    type T = A | B of Int";
    input.addEventListener("input", () => { addText = input.value; });
    input.addEventListener("pointerdown", (event) => event.stopPropagation());
    input.addEventListener("keydown", (event) => {
      event.stopPropagation();
      if (event.key === "Enter" && input.value.trim()) {
        send({ t: "board-define", file: m.path, text: input.value.trim() });
        // ready for the next one
        addText = "";
        input.value = "";
      } else if (event.key === "Escape") {
        adding = null;
        render();
        root.focus({ preventScroll: true });
      }
    });
    box.append(el("span", "board-kind", "+"), input);
    box.append(el("div", "board-add-hint", "↵ plans it (its body a hole) · Esc closes · A * B -> C takes two arguments"));
    return box;
  }

  // ---- from plan to code -------------------------------------------------------------------

  // the builder writes one planned body (the author's "dive in")
  function buildIt(file, name) {
    const decided = notesOn(file, name).filter((n) => n.kind === "decision").length;
    send({
      t: "voice",
      text: `Dive into ${name} in ${file}: write its body, replacing the hole${decided ? `, and honor the ${decided === 1 ? "decision" : "decisions"} on it` : ""}. Leave the other planned definitions as they are.`,
      context: { file, hover: null },
    });
    const key = keyOf(file, name);
    building.add(key);
    // the shimmer ends when the body arrives (noteChanges), or gives up
    setTimeout(() => { if (building.delete(key)) render(); }, 180000);
    render();
  }

  // every planned body, in dependency order (the palette's "Build the plan")
  function buildPlan() {
    const planned = outline.filter((m) => m.path !== "properties.puf").flatMap((m) => m.items.filter((i) => i.opaque || i.holes).map((i) => `${i.name} (${m.path})`));
    if (!planned.length) return;
    send({ t: "voice", text: `Build the plan: write the bodies of ${planned.join(", ")}, one at a time in dependency order, honoring every decision; check and run the properties as you go.`, context: {} });
  }

  // ---- notes: the author's decisions and comments on the design --------------------------

  const notesOn = (file, name) => (board.notes ?? []).filter((n) => n.file === file && (n.name ?? null) === (name ?? null));
  const NOTE_KINDS = [
    ["decision", "Decision", "binding: the builder builds to it"],
    ["comment", "Comment", "context for whoever builds it"],
    ["ask", "Ask the builder", "sent to the builder now"],
  ];

  function startNote(file, name, note) {
    writing = note ? { file, name, id: note.id, kind: note.kind, text: note.text } : { file, name: name ?? null, id: null, kind: "decision", text: "" };
    render();
    setTimeout(() => {
      const box = canvas.querySelector(".board-note-editor textarea");
      box?.focus();
      box?.setSelectionRange(box.value.length, box.value.length);
    }, 20);
  }

  function renderNote(note) {
    if (writing?.id === note.id) return noteEditor();
    const node = el("div", `board-note ${note.kind}`);
    const head = el("div", "board-note-head");
    head.append(el("span", "board-note-kind", { decision: "◆ decision", comment: "comment", ask: "asked the builder" }[note.kind] ?? note.kind));
    if (note.by === "builder") head.append(el("span", "board-note-by", "from the builder"));
    const tools = el("span", "board-note-tools");
    const edit = el("button", "", "edit");
    edit.addEventListener("click", (event) => { event.stopPropagation(); startNote(note.file, note.name, note); });
    const drop = el("button", "", "✕");
    drop.title = "Delete this note";
    drop.addEventListener("click", (event) => {
      event.stopPropagation();
      change((b) => { b.notes = (b.notes ?? []).filter((n) => n.id !== note.id); });
    });
    tools.append(edit, drop);
    head.append(tools);
    node.append(head, el("div", "board-note-text", note.text));
    return node;
  }

  function noteEditor() {
    const node = el("div", "board-note-editor");
    node.addEventListener("click", (event) => event.stopPropagation());
    node.addEventListener("pointerdown", (event) => event.stopPropagation());
    const kinds = el("div", "board-note-kinds");
    for (const [kind, label, hint] of NOTE_KINDS) {
      const chip = el("button", `board-note-chip ${kind}${writing.kind === kind ? " on" : ""}`, label);
      chip.title = hint;
      chip.addEventListener("click", () => {
        writing.kind = kind;
        for (const c of kinds.children) c.classList.toggle("on", c === chip);
      });
      kinds.append(chip);
    }
    const box = el("textarea", "board-note-text-input");
    box.value = writing.text;
    box.rows = 3;
    box.placeholder = writing.name ? `About ${writing.name}: what must hold, what to keep in mind, what is still open…` : `About the ${short(writing.file)} module…`;
    const fit = () => {
      box.style.height = "auto";
      box.style.height = `${Math.min(box.scrollHeight + 2, 320)}px`;
    };
    box.addEventListener("input", () => { writing.text = box.value; fit(); });
    setTimeout(fit, 0);
    box.addEventListener("keydown", (event) => {
      event.stopPropagation();
      if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) { event.preventDefault(); saveNote(); }
      else if (event.key === "Escape") { event.preventDefault(); writing = null; render(); root.focus({ preventScroll: true }); }
    });
    const foot = el("div", "board-note-foot");
    const save = el("button", "board-note-save", writing.id == null ? "Add" : "Save");
    save.addEventListener("click", saveNote);
    const cancel = el("button", "board-note-cancel", "Cancel");
    cancel.addEventListener("click", () => { writing = null; render(); });
    foot.append(el("span", "board-note-hint", "⌘↵ to save · Esc to cancel"), cancel, save);
    node.append(kinds, box, foot);
    return node;
  }

  function saveNote() {
    const w = writing;
    if (!w) return;
    const text = w.text.trim();
    writing = null;
    if (!text) return render();
    change((b) => {
      b.notes ??= [];
      if (w.id != null) {
        const n = b.notes.find((x) => x.id === w.id);
        if (n) Object.assign(n, { kind: w.kind, text });
      } else {
        const id = Math.max(0, ...b.notes.map((n) => n.id ?? 0)) + 1;
        b.notes.push({ id, file: w.file, name: w.name, kind: w.kind, text, at: Date.now(), by: "author" });
      }
      if (w.kind === "decision") ensureCard(b, DECISIONS);
    });
    // a question goes to the builder now, about its place
    if (w.kind === "ask" && w.id == null) {
      const place = w.name ? `${w.name} in ${w.file}` : `the module ${w.file}`;
      send({ t: "voice", text: `About ${place}: ${text}`, context: {} });
    }
    root.focus({ preventScroll: true });
  }


  function toggleHidden(path, name, isHidden) {
    // hiding a row is the author saying "show this less"
    if (!isHidden) view?.showLess(path, name);
    change((b) => {
      const card = ensureCard(b, path);
      card.hidden = isHidden ? card.hidden.filter((n) => n !== name) : [...card.hidden, name];
      // what the author unhides, the studio's automatic hiding leaves alone
      card.pinned = isHidden ? [...new Set([...(card.pinned ?? []), name])] : (card.pinned ?? []).filter((n) => n !== name);
    });
  }

  // `val step : State -> State`, the name picked out
  function signature(item) {
    const node = el("span", "board-sig");
    const m = item.sig.match(/^(val|type|abstype|grammar) (\S+)(.*)$/s);
    if (!m) {
      node.textContent = item.sig;
      return node;
    }
    node.append(el("span", "board-sig-kw", `${m[1]} `), el("span", "board-sig-name", m[2]), el("span", "board-sig-rest", m[3]));
    return node;
  }

  // ---- the lane: the working set, on the board ---------------------------------------------

  // The lane is a column left of the cards (above them in a narrow
  // window), so that the working set and the board are one surface: the
  // camera frames the lane to read code, and pulls back to show where
  // each fragment lives. Its contents are view.js's; here it is placed,
  // and each fragment is wired to its row.
  function placeLane() {
    const compact = root.classList.contains("compact");
    lane.classList.toggle("compact", compact);
    lane.style.setProperty("--lane-max", `${laneMax()}px`);
    if (compact) {
      lane.style.left = `${GRID.x}px`;
      lane.style.top = `${GRID.y}px`;
    } else {
      lane.style.left = `${-(lane.offsetWidth + LANE_GAP)}px`;
      lane.style.top = `${GRID.y - 40}px`;
    }
  }

  // the widest a fragment in the lane can be and still be read whole
  const laneMax = () => Math.max(360, (root.clientWidth - 48) / READABLE);

  // The fragments' sizes changed (one arrived, one grew as it was typed
  // in): the lane is placed again, and, if the camera is still where it
  // was put to read the lane, it frames the lane as it is now.
  let laneFrame = 0;
  function laneChanged() {
    cancelAnimationFrame(laneFrame);
    laneFrame = requestAnimationFrame(() => {
      placeLane();
      if (root.classList.contains("compact")) render();
      else {
        renderLaneWires();
        for (const f of moved) f();
      }
      if (atHome) home();
    });
  }

  // a wire from each fragment's head to its row, where the row is out:
  // which module each piece of code in the lane belongs to
  function renderLaneWires() {
    laneLayer.replaceChildren();
    const compact = root.classList.contains("compact");
    for (const frag of lane.querySelectorAll(".frag[data-key]")) {
      const to = anchor(frag.dataset.key);
      if (!to) continue;
      const box = canvasBox(frag.querySelector(".frag-head") ?? frag);
      const from = compact ? { x: box.x + box.w, y: box.y + box.h / 2 } : { x: box.x + box.w, y: box.y + box.h / 2 };
      const cls = frag.classList.contains("offered") ? "offered" : "kept";
      laneLayer.append(svg("path", { d: curve(from, { x: to.left, y: to.y }, compact ? { out: 40 } : {}), class: `wire lane-wire ${cls}` }));
      laneLayer.append(svg("circle", { cx: to.left, cy: to.y, r: 2.5, class: `wire-dot lane-wire ${cls}` }));
    }
  }

  // The rows the working set is about, marked where they sit: in the set,
  // offered beside the focus, the focus itself (view.js says which).
  let marks = new Map();
  function renderMarks() {
    for (const row of canvas.querySelectorAll(".board-item")) {
      const mark = marks.get(row.dataset.key);
      row.classList.toggle("in-set", mark === "set");
      row.classList.toggle("offered", mark === "offered");
      row.classList.toggle("is-focus", mark === "focus");
    }
    for (const node of canvas.querySelectorAll(".board-card")) {
      // a card with nothing of the working set's recedes a little
      node.classList.toggle("unattended", marks.size > 0 && !node.querySelector(".board-item.in-set, .board-item.offered, .board-item.is-focus"));
    }
  }

  // where the camera reads code: the lane, framed near, its top under the
  // HUD (and, given `box`, that fragment brought into view too). It stays
  // "at home" until the author moves it themselves.
  let atHome = false;
  root.addEventListener("wheel", () => { atHome = false; }, { capture: true });
  root.addEventListener("pointerdown", (event) => { if (event.target === root || event.target.classList.contains("canvas-pan")) atHome = false; }, { capture: true });
  function home(animate = true, box = null) {
    atHome = !box;
    const top = canvasBox(lane);
    const head = { ...top, h: Math.min(top.h, root.clientHeight * 0.8) };
    // as close as lets the code be read whole (a long signature line may
    // run off the side)
    const code = Math.max(0, ...[...lane.querySelectorAll(".frag.is-full")].map((f) => f.offsetWidth)) || top.w;
    const z = Math.max(READABLE, Math.min(1, (root.clientWidth - 48) / Math.max(1, code)));
    const v = { x: 24 - head.x * z, y: TOP() - head.y * z, z };
    if (box) {
      // the least move that shows it, at that zoom, clear of what floats
      // over the foot of the screen (the voice pill)
      const bottom = (box.y + box.h) * z + v.y;
      const foot = root.clientHeight - 110;
      if (bottom > foot) v.y -= bottom - foot;
      if (box.y * z + v.y < TOP()) v.y = TOP() - box.y * z;
    }
    camera.set(v, animate);
  }

  // where the camera shows the program: everything, fitted
  function overview(animate = true) {
    atHome = false;
    const boxes = [...canvas.querySelectorAll(".board-card:not([hidden]):not(.unplaced)")].map(canvasBox);
    if (lane.offsetHeight) boxes.push(canvasBox(lane));
    if (!boxes.length) return camera.set({ x: 0, y: 0, z: 1 }, animate);
    camera.frame(boxes, { min: 0.2, max: 1, pad: 24, top: TOP() - 24, animate, align: "start" });
  }

  // the room the HUD (and a question, when one is out) takes over the top
  // of the board
  const TOP = () => Math.max(hud.offsetTop + hud.offsetHeight, question.hidden ? 0 : question.offsetTop + question.offsetHeight) + 14;

  // ⌘⇧B, the zoom label: out to the program, or back in to the code
  const toggle = () => (camera.zoom() >= NEAR ? overview() : home());

  // ---- the HUD -----------------------------------------------------------------------------

  function countProperties(m) {
    const counts = { ok: 0, bad: 0, open: 0 };
    for (const item of m?.items ?? []) {
      const st = propertyStatus.get(item.name)?.status;
      if (st === "ok") counts.ok++;
      else if (st === "open") counts.open++;
      else if (st === "fail" || st === "crashed") counts.bad++;
    }
    return counts;
  }

  function renderHud() {
    const defs = outline.filter((m) => m.path !== "properties.puf").flatMap((m) => m.items.filter((i) => i.kind === "fun" || i.kind === "val"));
    const planned = defs.filter((i) => i.opaque).length;
    const partial = defs.filter((i) => !i.opaque && i.holes).length;
    const written = defs.length - planned - partial;
    const types = outline.flatMap((m) => m.items.filter((i) => ["type", "alias", "grammar"].includes(i.kind))).length;
    const props = countProperties(moduleOf("properties.puf"));
    const nprops = moduleOf("properties.puf")?.items.length ?? 0;
    progress.replaceChildren();
    const modules = outline.filter((m) => m.path !== "properties.puf").length;
    const stat = (n, label, cls = "") => {
      const node = el("span", `board-stat ${cls}`);
      node.append(el("b", "", String(n)), document.createTextNode(` ${label}`));
      return node;
    };
    progress.append(
      stat(modules, modules === 1 ? "module" : "modules"),
      stat(types, types === 1 ? "type" : "types"),
      stat(written, "written", "written"),
    );
    if (partial) progress.append(stat(partial, "partly", "partial"));
    if (planned) progress.append(stat(planned, "planned", "planned"));
    if (nprops) {
      const p = el("span", "board-stat props");
      p.append(el("b", "", String(nprops)), document.createTextNode(` propert${nprops === 1 ? "y" : "ies"}`));
      if (props.ok) p.append(el("span", "board-meta-ok", ` ✓${props.ok}`));
      if (props.bad) p.append(el("span", "board-meta-bad", ` ✗${props.bad}`));
      if (props.open) p.append(el("span", "board-holes", ` ◌${props.open}`));
      progress.append(p);
    }
    if (board.mode === "plan") progress.append(el("span", "board-mode", "plan mode"));
    bar.replaceChildren();
    const total = Math.max(1, defs.length);
    for (const [n, cls] of [[written, "written"], [partial, "partial"], [planned, "planned"]]) {
      if (!n) continue;
      const seg = el("span", `board-bar-seg ${cls}`);
      seg.style.width = `${(100 * n) / total}%`;
      bar.append(seg);
    }
    bar.title = `${written} of ${defs.length} definitions written${planned ? `, ${planned} planned (??)` : ""}${partial ? `, ${partial} with holes left` : ""}`;
  }

  // ---- wires: modules, and the lens --------------------------------------------------------

  // lines from each card to the cards of the modules it requires
  function renderWires() {
    wires.replaceChildren();
    for (const card of board.cards) {
      const m = moduleOf(card.path);
      const from = nodeOf(card.path);
      if (!m || !from || from.hidden) continue;
      for (const required of m.requires) {
        const to = nodeOf(required);
        if (!to || to.hidden) continue;
        const right = to.offsetLeft + to.offsetWidth / 2 > from.offsetLeft + from.offsetWidth / 2;
        const a = { x: right ? from.offsetLeft + from.offsetWidth : from.offsetLeft, y: from.offsetTop + 16 };
        const b = { x: right ? to.offsetLeft : to.offsetLeft + to.offsetWidth, y: to.offsetTop + 16 };
        wires.append(svg("path", { d: curve(a, b), class: "board-wire" }));
      }
    }
  }

  function setLens(key) {
    if (lens === key) return;
    lens = key;
    renderLens();
  }

  // the row's anchor points in canvas coordinates (rows sit in absolutely
  // positioned cards, so offsets chain row -> card)
  function anchor(key) {
    const row = canvas.querySelector(`.board-item[data-key="${CSS.escape(key)}"]`);
    const card = row?.closest(".board-card");
    if (!row || !card || card.hidden) return null;
    const line = row.querySelector(".board-item-line");
    // the line's offsetParent is the card (rows are not positioned)
    const y = card.offsetTop + line.offsetTop + line.offsetHeight / 2;
    return { left: card.offsetLeft + 4, right: card.offsetLeft + card.offsetWidth - 4, y, card };
  }

  function renderLens() {
    lensLayer.replaceChildren();
    for (const node of canvas.querySelectorAll(".lens-src, .lens-uses, .lens-user")) node.classList.remove("lens-src", "lens-uses", "lens-user");
    root.classList.toggle("lensing", false);
    const key = lens ?? cursor;
    if (!key || dragging) return;
    const found = itemOf(key);
    if (!found?.item) return;
    const source = anchor(key);
    if (!source) return;
    const { uses, users } = neighbours(found.item.name);
    if (!uses.size && !users.size) return;
    root.classList.toggle("lensing", true);
    canvas.querySelector(`.board-item[data-key="${CSS.escape(key)}"]`)?.classList.add("lens-src");
    const draw = (from, to, cls) => {
      // within a card: a loop out of its right edge and back
      const sameCard = from.card === to.card;
      const rightward = to.card.offsetLeft > from.card.offsetLeft;
      const a = { x: sameCard || rightward ? from.right : from.left, y: from.y };
      const b = { x: !sameCard && rightward ? to.left : to.right, y: to.y };
      lensLayer.append(svg("path", { d: curve(a, b, sameCard ? { out: 28 } : {}), class: `board-lens-wire ${cls}` }));
      lensLayer.append(svg("circle", { cx: b.x, cy: b.y, r: 3, class: `board-lens-dot ${cls}` }));
    };
    for (const k of uses) {
      const to = anchor(k);
      if (!to) continue;
      canvas.querySelector(`.board-item[data-key="${CSS.escape(k)}"]`)?.classList.add("lens-uses");
      draw(source, to, "uses");
    }
    for (const k of users) {
      const from = anchor(k);
      if (!from) continue;
      canvas.querySelector(`.board-item[data-key="${CSS.escape(k)}"]`)?.classList.add("lens-user");
      draw(from, source, "user");
    }
  }

  // ---- a question, and its slice ----------------------------------------------------------

  function renderQuestion() {
    const q = board.focus?.question ? board.questions.find((x) => x.id === board.focus.question) : null;
    root.classList.toggle("focusing", Boolean(board.focus));
    question.hidden = !board.focus;
    question.classList.toggle("is-question", Boolean(q));
    question.replaceChildren();
    if (!board.focus) return;
    const head = el("div", "board-question-head");
    head.append(el("span", "board-question-mark", q ? "?" : "◎"), el("span", "board-question-text", q ? q.text : board.focus.label || "focus"));
    const dismiss = el("button", "board-x", "✕");
    dismiss.title = q ? "Put the question aside (it stays in the list)" : "Show everything again (Esc)";
    dismiss.addEventListener("click", () => change((b) => { b.focus = null; }));
    head.append(dismiss);
    question.append(head);
    if (q?.why) question.append(el("div", "board-question-why", q.why));
    if (q) {
      const answer = el("input", "board-answer");
      answer.placeholder = "Answer — or just say it";
      answer.addEventListener("keydown", (event) => {
        event.stopPropagation();
        if (event.key === "Enter" && answer.value.trim()) {
          send({ t: "answer", id: q.id, text: answer.value.trim() });
          answer.value = "";
        }
      });
      question.append(answer);
    }
  }

  // Cards grow (a body opened, a note written) into the cards below them:
  // push those down, as shown -- the saved places are not changed, so a
  // card that shrinks again lets them come back.
  function settle() {
    const nodes = [...canvas.querySelectorAll(".board-card:not([hidden])")]
      .filter((n) => !n.classList.contains("unplaced") && !(dragging && n.dataset.path === dragging.path))
      .map((n) => ({ n, x: parseFloat(n.style.left), y: parseFloat(n.style.top), w: n.offsetWidth, h: n.offsetHeight }))
      .sort((a, b) => a.y - b.y || a.x - b.x);
    for (let i = 0; i < nodes.length; i++) {
      const c = nodes[i];
      for (let j = 0; j < i; j++) {
        const p = nodes[j];
        const across = c.x < p.x + p.w + 8 && p.x < c.x + c.w + 8;
        if (across && c.y < p.y + p.h + GRID.gap * 0.6 && c.y + c.h > p.y) c.y = p.y + p.h + GRID.gap * 0.6;
      }
      c.n.style.top = `${c.y}px`;
    }
  }

  // re-pack every card in dependency order for this window (t, the palette)
  function tidy() {
    change((b) => {
      const spots = shelves(b.cards.filter((c) => nodeOf(c.path)), sizeOf, GRID.y);
      for (const card of b.cards) Object.assign(card, spots.get(card.path) ?? {});
    });
    setTimeout(overview, 0);
  }


  // ---- the camera ------------------------------------------------------------------------------

  // the box of a node on the board, in canvas coordinates, from the
  // layout (offsets up to its card or the lane, and where that sits), not
  // from the screen: right during a glide, when the screen is mid-way
  function canvasBox(node) {
    let x = 0;
    let y = 0;
    let at = node;
    while (at && at !== canvas && !at.classList.contains("board-card") && !at.classList.contains("board-lane")) {
      x += at.offsetLeft;
      y += at.offsetTop;
      at = at.offsetParent;
    }
    if (at && at !== canvas) {
      x += parseFloat(at.style.left) || 0;
      y += parseFloat(at.style.top) || 0;
    }
    return { x, y, w: node.offsetWidth, h: node.offsetHeight };
  }

  zoomOut.addEventListener("click", () => camera.zoomBy(1 / 1.25));
  zoomIn.addEventListener("click", () => camera.zoomBy(1.25));
  zoomLabel.addEventListener("click", toggle);

  // ---- filter and keys --------------------------------------------------------------------------

  filter.addEventListener("input", () => {
    query = filter.value.trim();
    render();
  });
  filter.addEventListener("keydown", (event) => {
    event.stopPropagation();
    if (event.key === "Escape") {
      filter.value = "";
      query = "";
      filter.blur();
      root.focus({ preventScroll: true });
      render();
    } else if (event.key === "Enter") {
      focusMatches();
    } else if (event.key === "ArrowDown") {
      event.preventDefault();
      root.focus({ preventScroll: true });
      moveCursor(1);
    }
  });

  // ↵ in the filter: focus on what matches (a focus like "just show ...")
  function focusMatches() {
    if (!query) return;
    const items = outline.flatMap((m) => m.items.filter((i) => matches(m, i)).map((i) => [m.path, i.name]));
    if (!items.length) return;
    const label = `matching “${query}”`;
    filter.value = "";
    query = "";
    change((b) => { b.focus = { items, label, question: null }; });
    root.focus({ preventScroll: true });
  }

  // the rows on screen, in reading order: cards left to right, top to
  // bottom (by where they sit), rows down each card
  function rowsInOrder() {
    const cards = [...canvas.querySelectorAll(".board-card:not([hidden])")].sort((a, b) => {
      const dy = parseFloat(a.style.top) - parseFloat(b.style.top);
      return Math.abs(dy) > 60 ? dy : parseFloat(a.style.left) - parseFloat(b.style.left);
    });
    return cards.map((card) => [...card.querySelectorAll(".board-item")].map((row) => row.dataset.key));
  }

  function moveCursor(delta) {
    const cards = rowsInOrder().filter((rows) => rows.length);
    const flat = cards.flat();
    if (!flat.length) return;
    const at = flat.indexOf(cursor);
    cursor = flat[at < 0 ? 0 : (at + delta + flat.length) % flat.length];
    afterCursor();
  }

  function moveCard(delta) {
    const cards = rowsInOrder().filter((rows) => rows.length);
    if (!cards.length) return;
    const at = cards.findIndex((rows) => rows.includes(cursor));
    const next = cards[at < 0 ? 0 : (at + delta + cards.length) % cards.length];
    cursor = next[0];
    afterCursor();
  }

  function afterCursor() {
    for (const node of canvas.querySelectorAll(".board-item.cursor")) node.classList.remove("cursor");
    const row = canvas.querySelector(`.board-item[data-key="${CSS.escape(cursor)}"]`);
    row?.classList.add("cursor");
    if (row) camera.reveal(canvasBox(row));
    lens = null;
    renderLens();
  }

  // a question back in front of the author: open, its slice; decided,
  // the definitions it was about and what touches them
  function reopenQuestion(q) {
    const keys = new Set();
    for (const name of q.about ?? []) {
      for (const m of outline) for (const i of m.items) if (i.name === name) keys.add(keyOf(m.path, i.name));
      const { uses, users } = neighbours(name);
      for (const k of [...uses, ...users]) if (!k.startsWith(DECISIONS)) keys.add(k);
    }
    const items = [...keys].map((k) => k.split("\u001f"));
    change((b) => {
      b.focus = q.answered
        ? { items, label: `decided: ${q.text} → ${q.answer ?? ""}`, question: null }
        : { items, label: `question #${q.id}`, question: q.id };
    });
  }

  // f on a row: it, what it uses and what uses it (board.rs slice, here)
  function sliceAt(key) {
    const found = itemOf(key);
    if (!found?.item) return;
    const { uses, users } = neighbours(found.item.name);
    const items = [key, ...uses, ...users].map((k) => k.split("\u001f"));
    change((b) => { b.focus = { items, label: `${found.item.name} and what touches it`, question: null }; });
  }


  root.addEventListener("keydown", (event) => {
    if (typing(event.target) || event.metaKey || event.ctrlKey || event.altKey) return;
    const found = cursor && itemOf(cursor);
    const def = found?.item && found.m.path !== DECISIONS ? found : null;
    const hidden = def && board.cards.find((c) => c.path === def.m.path)?.hidden.includes(def.item.name);
    const act = {
      ArrowDown: () => moveCursor(1),
      ArrowUp: () => moveCursor(-1),
      ArrowRight: () => moveCard(1),
      ArrowLeft: () => moveCard(-1),
      j: () => moveCursor(1),
      k: () => moveCursor(-1),
      Enter: () => def && view?.pull(def.m.path, def.item.name),
      e: () => def && view?.focus(def.m.path, def.item.line),
      "]": () => def && view?.along(def.m.path, def.item.name, "uses"),
      "[": () => def && view?.along(def.m.path, def.item.name, "users"),
      h: () => def && (toggleHidden(def.m.path, def.item.name, hidden), moveCursor(0)),
      f: () => cursor && sliceAt(cursor),
      "/": () => filter.focus(),
      "+": () => camera.zoomBy(1.25),
      "=": () => camera.zoomBy(1.25),
      "-": () => camera.zoomBy(1 / 1.25),
      0: () => overview(),
      1: () => home(),
      t: () => tidy(),
      n: () => def && startNote(def.m.path, def.item.name),
      b: () => def && (def.item.opaque || def.item.holes) && buildIt(def.m.path, def.item.name),
    }[event.key];
    if (act) {
      event.preventDefault();
      act();
    } else if (event.key.length === 1 && /[\w?!*<>-]/.test(event.key)) {
      // just start typing: the filter takes it
      filter.focus();
      filter.value += event.key;
      filter.dispatchEvent(new Event("input"));
      event.preventDefault();
    }
  });

  // ---- dragging ------------------------------------------------------------------------------

  function startDrag(event, node, card) {
    if (event.button !== 0 || event.target.closest("button") || board.focus || root.classList.contains("compact")) return;
    event.preventDefault();
    const start = { x: event.clientX, y: event.clientY, left: card.x, top: card.y };
    dragging = { path: card.path };
    node.classList.add("dragging");
    node.setPointerCapture(event.pointerId);
    lensLayer.replaceChildren();
    const at = (e) => ({
      x: Math.round(start.left + (e.clientX - start.x) / camera.zoom()),
      y: Math.round(start.top + (e.clientY - start.y) / camera.zoom()),
    });
    const move = (e) => {
      const p = at(e);
      node.style.left = `${p.x}px`;
      node.style.top = `${p.y}px`;
      renderWires();
    };
    const up = (e) => {
      node.removeEventListener("pointermove", move);
      node.removeEventListener("pointerup", up);
      node.classList.remove("dragging");
      dragging = null;
      const p = at(e);
      change((b) => { const c = ensureCard(b, card.path); c.x = p.x; c.y = p.y; });
    };
    node.addEventListener("pointermove", move);
    node.addEventListener("pointerup", up);
  }

  // a file chip dropped on the board brings its module out there
  root.addEventListener("dragover", (event) => {
    if (event.dataTransfer?.types.includes("text/x-puffin-module")) {
      event.preventDefault();
      event.dataTransfer.dropEffect = "copy";
      root.classList.add("dropping");
    }
  });
  root.addEventListener("dragleave", () => root.classList.remove("dropping"));
  // the signature field closes on a click elsewhere (or Esc), not on a
  // re-render (the definition just planned arriving)
  root.addEventListener("pointerdown", (event) => {
    if (adding && !event.target.closest(".board-add-box") && !event.target.closest(".board-add")) {
      adding = null;
      render();
    }
  });
  root.addEventListener("drop", (event) => {
    root.classList.remove("dropping");
    const path = event.dataTransfer?.getData("text/x-puffin-module");
    if (!path) return;
    event.preventDefault();
    const point = camera.toCanvas(event.clientX, event.clientY);
    const at = { x: Math.round(point.x - 40), y: Math.round(point.y - 12) };
    change((b) => {
      const card = ensureCard(b, path, at);
      card.x = at.x;
      card.y = at.y;
    });
  });

  window.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && event.shiftKey && event.key.toLowerCase() === "b") {
      event.preventDefault();
      toggle();
    } else if (event.key === "Escape" && !event.defaultPrevented && !typing(event.target)) {
      if (board.focus) change((b) => { b.focus = null; });
      else if (cursor) {
        cursor = null;
        afterCursor();
      }
    }
  });

  // ---- what changed: rows the builder just wrote glow -----------------------------------------

  function noteChanges(modules) {
    const now = new Map();
    for (const m of modules) for (const i of m.items) now.set(keyOf(m.path, i.name), `${i.sig}|${i.holes}|${i.opaque}|${i.end_line - i.line}`);
    if (seen) {
      const until = Date.now() + FRESH_MS;
      for (const [key, what] of now) if (seen.get(key) !== what) fresh.set(key, until);
      if (fresh.size) setTimeout(render, FRESH_MS + 50);
    }
    seen = now;
    for (const key of [...building]) {
      const [path, name] = key.split("\u001f");
      const item = modules.find((m) => m.path === path)?.items.find((i) => i.name === name);
      if (!item || !item.opaque) building.delete(key);
    }
  }

  // the last camera request seen (board.rs `look`); null until the first
  let looked = null;
  return {
    receive({ board: next, outline: modules }) {
      const before = board.questions?.length ?? 0;
      const decidedBefore = (board.notes ?? []).filter((n) => n.kind === "decision").length;
      if (next) board = next;
      // a new question brings the decisions card out (once; ✕ puts it away)
      const decided = (board.notes ?? []).filter((n) => n.kind === "decision").length;
      if (((board.questions?.length ?? 0) > before || decided > decidedBefore) && seen && !board.cards.some((c) => c.path === DECISIONS)) {
        const b = clone(board);
        ensureCard(b, DECISIONS);
        board = b;
        save();
      }
      if (modules) {
        noteChanges(modules);
        outline = modules;
      }
      render();
      view?.boardChanged();
      // the voice asked for the board, or the code (board.rs `look`): the
      // camera goes there -- once, and not for the request a reload finds
      if (next) {
        const n = next.look?.n ?? 0;
        if (looked !== null && n !== looked) setTimeout(() => setView(next.look.to === "board" ? "board" : "editor"), 60);
        looked = n;
      }
    },
    setView,
    toggle,
    home,
    overview,
    // the properties' latest run (voice.js), shown on the properties card
    setProperties(results) {
      propertyStatus = new Map((results?.properties ?? []).map((p) => [p.name, p]));
      render();
    },
    mode: () => board.mode,
    setMode: (mode) => change((b) => { b.mode = mode; }),
    fit: overview,
    tidy,
    buildPlan,
    // the welcome's "plan it yourself": the field on `path`'s card, open
    startAdding(path) {
      adding = path;
      addText = "";
      render();
      requestAnimationFrame(() => {
        const box = canvas.querySelector(".board-add-input");
        if (box) camera.frame([canvasBox(box.closest(".board-card"))], { min: 0.7, max: 1, top: TOP() });
        setTimeout(() => box?.focus({ preventScroll: true }), 60);
      });
    },
    outline: () => outline,
    // focus on a definition and what touches it (the palette, f)
    slice: (path, name) => sliceAt(keyOf(path, name)),
    clearFocus: () => change((b) => { b.focus = null; }),
    focusFilter: () => { overview(); setTimeout(() => filter.focus(), 30); },
    state: () => board,
    // ---- for the working set (view.js) ----
    bind(v) { view = v; },
    lane,
    laneChanged,
    // the working set's membership, kept with the board
    set: () => board.set ?? [],
    setSet: (set) => change((b) => { b.set = set; }),
    // view.js's marks on the rows: key -> "set" | "offered" | "focus"
    mark(next) {
      marks = next;
      renderMarks();
    },
    // a row lit from elsewhere (a name hovered in code), or none
    light(key) {
      for (const n of canvas.querySelectorAll(".ref-target")) n.classList.remove("ref-target");
      if (key) canvas.querySelector(`.board-item[data-key="${CSS.escape(key)}"]`)?.classList.add("ref-target");
    },
    zoom: () => camera.zoom(),
    // whether the camera is out at the program (else in at the code)
    out: () => camera.zoom() < NEAR,
    laneMax,
    // a fragment in the lane into view, the camera at reading distance
    reveal: (node) => home(true, canvasBox(node)),
    // `f` is told whenever the board moves under the screen
    onMove: (f) => moved.add(f),
    root,
  };
}
