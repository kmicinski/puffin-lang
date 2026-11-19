// The module board (docs/PLANNING.md; the server side is studio/src/board.rs).
//
// The program as module cards, each a module's ML-style signature: one
// row per definition (ƒ function, · value, τ type, ≡ alias, G grammar,
// and the spec's properties), bodies opaque until a row is clicked open.
// The point is to keep as much of the design on the screen as possible,
// so a card shows only what it was left showing: rows hidden stay hidden
// (behind "N hidden"), rows opened stay open, and both come back when the
// card does.
//
//   the HUD (top left): how much of the plan is written, the properties,
//     a filter, the zoom
//   hover a row (or move the cursor to it): the lens -- wires run from it
//     to everything it uses (blue) and from everything that uses it
//     (violet), across cards
//   keys: type or / to filter · ↑↓ rows · ←→ cards · ↵ open/close ·
//     h hide · f just this and what touches it · e edit · Esc clears ·
//     + − 0 zoom (also ⌘/ctrl + wheel)
//   drag a card by its title; drag a file chip from the bar onto the
//     board to bring that module out; ✕ puts a card away
//   rows the builder just wrote or changed glow for a moment
//   a focus (a question's slice, "just show ...") packs only what it
//     names under the question; the author's layout comes back after
//
// The board's state is the server's (Event::Board, .puffin/board.json);
// every change here is sent back whole with `board-set`. The zoom, the
// filter and the cursor are this tab's own.

const KIND = { fun: "ƒ", val: "·", type: "τ", alias: "≡", grammar: "G", property: "?" };
const PROP_MARK = { ok: "✓", fail: "✗", crashed: "!", open: "◌", "not-run": "·", pending: "…" };
const GRID = { x: 28, y: 92, w: 380, gap: 24 };
const FRESH_MS = 2600;
const ZOOM_KEY = "puffin-board-zoom";
const SVG = "http://www.w3.org/2000/svg";

const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};
const svg = (tag, attrs = {}) => {
  const node = document.createElementNS(SVG, tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
  return node;
};

const clone = (value) => JSON.parse(JSON.stringify(value));
const short = (path) => path.replace(/\.puf$/, "");
const keyOf = (path, name) => `${path}\u001f${name}`;
const typing = (target) => target?.closest?.("input, textarea, [contenteditable], .monaco-editor");

export function createBoard({ editor, files, send, stage, onShow }) {
  const monaco = editor.raw?.monaco;
  let board = { view: "editor", mode: "build", cards: [], focus: null, questions: [] };
  let outline = [];
  let propertyStatus = new Map(); // name -> { status, detail } (voice.js)
  const revealed = new Set(); // cards whose hidden rows are shown for now
  let dragging = null;
  let lens = null; // the key of the row the lens is on (hover, or the cursor)
  let cursor = null; // the keyboard's row
  let query = "";
  let seen = null; // key -> what each row was, to see what the builder changed
  const fresh = new Map(); // key -> until when it glows
  let zoom = Number(load(ZOOM_KEY)) || 1;

  function load(key) {
    try { return localStorage.getItem(key); } catch { return null; }
  }
  function store(key, value) {
    try { localStorage.setItem(key, value); } catch { /* private window */ }
  }

  // ---- the page -----------------------------------------------------------------

  const root = el("div", "board");
  root.hidden = true;
  root.tabIndex = -1;
  const sizer = el("div", "board-sizer");
  const canvas = el("div", "board-canvas");
  const wires = svg("svg", { class: "board-wires" });
  const lensLayer = svg("svg", { class: "board-lens" });
  const question = el("div", "board-question");
  question.hidden = true;
  const empty = el("div", "board-empty");
  canvas.append(wires, lensLayer);
  sizer.append(canvas);
  root.append(sizer, empty);

  // the HUD: progress, properties, filter, zoom
  const hud = el("div", "board-hud");
  hud.hidden = true;
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
  zoomLabel.title = "Fit the board to the window (0)";
  const keysHelp = el("button", "board-zoom board-help", "?");
  keysHelp.title = "Keys: type or / filter · ↑↓ rows · ←→ cards · ↵ open · h hide · f focus · e edit · Esc clear · + − 0 zoom";
  const tools = el("div", "board-hud-tools");
  tools.append(filter, zoomOut, zoomLabel, zoomIn, keysHelp);
  hud.append(progress, bar, tools);
  stage.append(root, question, hud);

  // the board appearing (the canvas going, a resize) lets unplaced cards be placed
  let lastWidth = 0;
  new ResizeObserver(() => {
    const width = root.offsetWidth;
    if (width && !lastWidth && shown()) render();
    lastWidth = width;
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

  const moduleOf = (path) => outline.find((m) => m.path === path);
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
    for (const m of outline) {
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
    const order = [...cards].sort((a, b) => depthOf(a.path) - depthOf(b.path) || a.path.localeCompare(b.path));
    const limit = Math.max(root.clientWidth / zoom - GRID.x, GRID.w * 2);
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

  function shown() {
    return board.view === "board";
  }

  function setView(view) {
    if (board.view === view) return;
    change((b) => {
      b.view = view;
      if (view === "board" && !b.cards.length) for (const m of outline) ensureCard(b, m.path);
    });
    if (view === "board") setTimeout(() => root.focus({ preventScroll: true }), 0);
  }

  function render() {
    // nothing out yet: every module, once the outline has arrived
    if (shown() && !board.cards.length && outline.length) {
      const next = clone(board);
      for (const m of outline) ensureCard(next, m.path);
      board = next;
      save();
    }
    root.hidden = !shown();
    hud.hidden = !shown();
    document.body.classList.toggle("board-on", shown());
    onShow?.(shown());
    if (!shown()) {
      question.hidden = true;
      return;
    }
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
    if (placeUnplaced()) return render();
    renderQuestion();
    // A focus (a question's slice, "just show ..."): only the cards it
    // names, packed under the question in dependency order. The author's
    // own layout is untouched and comes back when the focus clears.
    if (focus) {
      const focused = board.cards.filter((c) => (moduleOf(c.path)?.items ?? []).some((i) => focus.has(keyOf(c.path, i.name))));
      for (const card of board.cards) {
        const node = nodeOf(card.path);
        if (node) node.hidden = !focused.includes(card);
      }
      const top = (question.hidden ? 0 : (question.offsetTop + question.offsetHeight) / zoom) + 24;
      for (const [path, spot] of shelves(focused, sizeOf, Math.max(GRID.y, top))) {
        const node = nodeOf(path);
        node.style.left = `${spot.x}px`;
        node.style.top = `${spot.y}px`;
      }
    } else {
      for (const node of canvas.querySelectorAll(".board-card")) node.hidden = false;
    }
    let maxX = 0;
    let maxY = 0;
    for (const node of canvas.querySelectorAll(".board-card:not([hidden])")) {
      maxX = Math.max(maxX, parseFloat(node.style.left) + node.offsetWidth);
      maxY = Math.max(maxY, parseFloat(node.style.top) + node.offsetHeight);
    }
    canvas.style.width = `${maxX + 200}px`;
    canvas.style.height = `${maxY + 200}px`;
    applyZoom();
    renderEmpty();
    renderHud();
    renderWires();
    renderLens();
  }

  function renderEmpty() {
    empty.hidden = board.cards.length > 0;
    empty.replaceChildren();
    if (!empty.hidden) {
      empty.append(
        el("div", "board-empty-title", outline.length ? "Nothing on the board" : "No modules yet"),
        el("div", "board-empty-text", outline.length ? "Drag a module from the bar onto the board, or click it." : "Describe what to build — the design lands here as signatures."),
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
    if (m.path === "properties.puf") {
      const counts = countProperties(m);
      meta.textContent = `${m.items.length} propert${m.items.length === 1 ? "y" : "ies"}`;
      if (counts.ok) meta.append(el("span", "board-meta-ok", ` · ✓ ${counts.ok}`));
      if (counts.bad) meta.append(el("span", "board-meta-bad", ` · ✗ ${counts.bad}`));
      if (counts.open) meta.append(el("span", "board-holes", ` · ◌ ${counts.open}`));
    } else {
      if (m.provides) {
        const exported = m.items.filter((i) => m.provides.includes(i.name)).length;
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
    head.append(title, meta, close);
    head.addEventListener("pointerdown", (event) => startDrag(event, node, card));
    head.addEventListener("dblclick", () => editAt(m.path, 1));
    node.append(head);
    const requires = m.requires.filter((r) => r !== "prop.puf");
    if (requires.length) node.append(el("div", "board-requires", `requires ${requires.map(short).join(", ")}`));

    const hidden = new Set(card.hidden);
    const open = new Set(card.open);
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
      list.append(renderItem(m, item, open.has(item.name), hidden.has(item.name), focused));
    }
    node.append(list);
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

  function renderItem(m, item, isOpen, isHidden, focused) {
    const key = keyOf(m.path, item.name);
    const classes = [
      "board-item",
      `kind-${item.kind}`,
      item.opaque && "opaque",
      isHidden && "is-hidden",
      focused && "focused",
      fresh.has(key) && "fresh",
      cursor === key && "cursor",
    ].filter(Boolean).join(" ");
    const row = el("div", classes);
    row.dataset.key = key;
    const line = el("div", "board-item-line");
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
      hole.addEventListener("click", (event) => { event.stopPropagation(); editAt(m.path, item.line, "??"); });
      line.append(hole);
    } else if (item.holes) {
      const hole = el("span", "board-opaque", `◌${item.holes}`);
      hole.title = `${item.holes} hole${item.holes === 1 ? "" : "s"} left in the body`;
      line.append(hole);
    }
    const actions = el("span", "board-tools");
    const edit = el("button", "", "↗");
    edit.title = "Edit it (e)";
    edit.addEventListener("click", (event) => { event.stopPropagation(); editAt(m.path, item.line); });
    const hide = el("button", "", isHidden ? "◉" : "✕");
    hide.title = isHidden ? "Show it again" : "Hide it on this card (h)";
    hide.addEventListener("click", (event) => { event.stopPropagation(); toggleHidden(m.path, item.name, isHidden); });
    actions.append(edit, hide);
    line.append(actions);
    line.title = [item.doc, `${m.path}:${item.line}`, item.uses.length ? `uses ${item.uses.join(", ")}` : ""].filter(Boolean).join("\n");
    line.addEventListener("click", () => {
      cursor = key;
      toggleOpen(m.path, item.name, isOpen);
    });
    line.addEventListener("pointerenter", () => setLens(key));
    line.addEventListener("pointerleave", () => setLens(null));
    row.append(line);
    if (item.doc) row.append(el("div", "board-doc", item.doc));
    if (isOpen) row.append(body(m, item));
    return row;
  }

  function toggleOpen(path, name, isOpen) {
    change((b) => {
      const card = ensureCard(b, path);
      card.open = isOpen ? card.open.filter((n) => n !== name) : [...card.open, name];
      // what the author opens, the studio's automatic hiding leaves alone
      if (!isOpen && !(card.pinned ?? []).includes(name)) card.pinned = [...(card.pinned ?? []), name];
    });
  }

  function toggleHidden(path, name, isHidden) {
    change((b) => {
      const card = ensureCard(b, path);
      card.hidden = isHidden ? card.hidden.filter((n) => n !== name) : [...card.hidden, name];
      card.open = card.open.filter((n) => n !== name);
      card.pinned = (card.pinned ?? []).filter((n) => n !== name);
    });
  }

  // `val step : State -> State`, the name picked out
  function signature(item) {
    const node = el("span", "board-sig");
    const m = item.sig.match(/^(val|type|grammar) (\S+)(.*)$/s);
    if (!m) {
      node.textContent = item.sig;
      return node;
    }
    node.append(el("span", "board-sig-kw", `${m[1]} `), el("span", "board-sig-name", m[2]), el("span", "board-sig-rest", m[3]));
    return node;
  }

  function body(m, item) {
    const text = files.texts()[m.path] ?? "";
    const source = text.split("\n").slice(item.line - 1, item.end_line).join("\n");
    const pre = el("pre", "board-body");
    pre.textContent = source;
    if (monaco?.editor?.colorize) {
      monaco.editor.colorize(source, "puffin", {}).then((html) => { pre.innerHTML = html; }).catch(() => {});
    }
    pre.title = "Double-click to edit";
    pre.addEventListener("dblclick", () => editAt(m.path, item.line));
    return pre;
  }

  // Into the editor at `line` of `path`; with `find`, at its first
  // occurrence from there (a hole), selected, so typing replaces it.
  function editAt(path, line, find) {
    setView("editor");
    if (files.active() !== path) files.open(path);
    const view = editor.raw?.editor;
    setTimeout(() => {
      if (!view) return editor.reveal?.({ line });
      const model = view.getModel();
      let range = null;
      if (find && model) {
        const found = model.findNextMatch(find, { lineNumber: line, column: 1 }, false, true, null, false);
        if (found) range = found.range;
      }
      view.revealLineInCenter(range ? range.startLineNumber : line);
      if (range) view.setSelection(range);
      else view.setPosition({ lineNumber: line, column: 1 });
      view.focus();
    }, 30);
  }

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
    zoomLabel.textContent = `${Math.round(zoom * 100)}%`;
  }

  // ---- wires: modules, and the lens --------------------------------------------------------

  // lines from each card to the cards of the modules it requires
  function renderWires() {
    wires.replaceChildren();
    wires.setAttribute("width", canvas.style.width);
    wires.setAttribute("height", canvas.style.height);
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
        const bend = Math.max(30, Math.abs(b.x - a.x) / 3) * (right ? 1 : -1);
        wires.append(svg("path", { d: `M ${a.x} ${a.y} C ${a.x + bend} ${a.y} ${b.x - bend} ${b.y} ${b.x} ${b.y}`, class: "board-wire" }));
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
    lensLayer.setAttribute("width", canvas.style.width);
    lensLayer.setAttribute("height", canvas.style.height);
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
      const sameCard = from.card === to.card;
      let d;
      if (sameCard) {
        // a loop out of the card's right edge and back
        const x = from.right + 28;
        d = `M ${from.right} ${from.y} C ${x} ${from.y} ${x} ${to.y} ${to.right} ${to.y}`;
      } else {
        const rightward = to.card.offsetLeft > from.card.offsetLeft;
        const ax = rightward ? from.right : from.left;
        const bx = rightward ? to.left : to.right;
        const bend = Math.max(40, Math.abs(bx - ax) / 2.5) * (rightward ? 1 : -1);
        d = `M ${ax} ${from.y} C ${ax + bend} ${from.y} ${bx - bend} ${to.y} ${bx} ${to.y}`;
      }
      lensLayer.append(svg("path", { d, class: `board-lens-wire ${cls}` }));
      lensLayer.append(svg("circle", { cx: sameCard ? to.right : (to.card.offsetLeft > from.card.offsetLeft ? to.left : to.right), cy: to.y, r: 3, class: `board-lens-dot ${cls}` }));
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
    question.hidden = !shown() || !board.focus;
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

  // ---- zoom ------------------------------------------------------------------------------------

  function applyZoom() {
    canvas.style.transform = `scale(${zoom})`;
    sizer.style.width = `${parseFloat(canvas.style.width || "0") * zoom}px`;
    sizer.style.height = `${parseFloat(canvas.style.height || "0") * zoom}px`;
    zoomLabel.textContent = `${Math.round(zoom * 100)}%`;
  }

  function setZoom(value) {
    zoom = Math.min(2, Math.max(0.35, Math.round(value * 100) / 100));
    store(ZOOM_KEY, String(zoom));
    applyZoom();
    renderLens();
  }

  // the whole board in the window
  function fit() {
    const visible = [...canvas.querySelectorAll(".board-card:not([hidden])")];
    if (!visible.length) return setZoom(1);
    const right = Math.max(...visible.map((n) => parseFloat(n.style.left) + n.offsetWidth)) + GRID.x;
    const bottom = Math.max(...visible.map((n) => parseFloat(n.style.top) + n.offsetHeight)) + 120;
    setZoom(Math.min(1.25, root.clientWidth / right, root.clientHeight / bottom));
    root.scrollTo({ left: 0, top: 0 });
  }

  zoomOut.addEventListener("click", () => setZoom(zoom - 0.1));
  zoomIn.addEventListener("click", () => setZoom(zoom + 0.1));
  zoomLabel.addEventListener("click", fit);
  root.addEventListener("wheel", (event) => {
    if (!(event.ctrlKey || event.metaKey)) return;
    event.preventDefault();
    setZoom(zoom * (event.deltaY > 0 ? 0.92 : 1.08));
  }, { passive: false });

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
    row?.scrollIntoView({ block: "nearest", inline: "nearest" });
    lens = null;
    renderLens();
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
    const open = found?.item && board.cards.find((c) => c.path === found.m.path)?.open.includes(found.item.name);
    const hidden = found?.item && board.cards.find((c) => c.path === found.m.path)?.hidden.includes(found.item.name);
    const act = {
      ArrowDown: () => moveCursor(1),
      ArrowUp: () => moveCursor(-1),
      ArrowRight: () => moveCard(1),
      ArrowLeft: () => moveCard(-1),
      j: () => moveCursor(1),
      k: () => moveCursor(-1),
      Enter: () => found?.item && toggleOpen(found.m.path, found.item.name, open),
      h: () => found?.item && (toggleHidden(found.m.path, found.item.name, hidden), moveCursor(0)),
      e: () => found?.item && editAt(found.m.path, found.item.line),
      f: () => cursor && sliceAt(cursor),
      "/": () => filter.focus(),
      "+": () => setZoom(zoom + 0.1),
      "=": () => setZoom(zoom + 0.1),
      "-": () => setZoom(zoom - 0.1),
      0: () => fit(),
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
    if (event.button !== 0 || event.target.closest("button") || board.focus) return;
    event.preventDefault();
    const start = { x: event.clientX, y: event.clientY, left: card.x, top: card.y };
    dragging = { path: card.path };
    node.classList.add("dragging");
    node.setPointerCapture(event.pointerId);
    lensLayer.replaceChildren();
    const at = (e) => ({
      x: Math.max(0, Math.round(start.left + (e.clientX - start.x) / zoom)),
      y: Math.max(0, Math.round(start.top + (e.clientY - start.y) / zoom)),
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
  root.addEventListener("drop", (event) => {
    root.classList.remove("dropping");
    const path = event.dataTransfer?.getData("text/x-puffin-module");
    if (!path) return;
    event.preventDefault();
    const rect = canvas.getBoundingClientRect();
    const at = { x: Math.max(0, Math.round((event.clientX - rect.left) / zoom - 40)), y: Math.max(0, Math.round((event.clientY - rect.top) / zoom - 12)) };
    change((b) => {
      const card = ensureCard(b, path, at);
      card.x = at.x;
      card.y = at.y;
    });
  });

  window.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && event.shiftKey && event.key.toLowerCase() === "b") {
      event.preventDefault();
      setView(shown() ? "editor" : "board");
    } else if (shown() && event.key === "Escape" && !event.defaultPrevented && !typing(event.target)) {
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
      if (fresh.size) setTimeout(() => shown() && render(), FRESH_MS + 50);
    }
    seen = now;
  }

  return {
    receive({ board: next, outline: modules }) {
      if (next) board = next;
      if (modules) {
        noteChanges(modules);
        outline = modules;
      }
      render();
    },
    shown,
    setView,
    // the properties' latest run (voice.js), shown on the properties card
    setProperties(results) {
      propertyStatus = new Map((results?.properties ?? []).map((p) => [p.name, p]));
      if (shown()) render();
    },
    toggle: () => setView(shown() ? "editor" : "board"),
    mode: () => board.mode,
    setMode: (mode) => change((b) => { b.mode = mode; }),
    // a module brought out (a chip clicked while the board shows)
    bringOut: (path) => change((b) => { ensureCard(b, path); }),
    fit,
    focusFilter: () => { setView("board"); setTimeout(() => filter.focus(), 30); },
    state: () => board,
  };
}
