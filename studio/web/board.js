// The module board (docs/PLANNING.md; the server side is studio/src/board.rs).
//
// The program as module cards, each a module's ML-style signature: one
// row per definition (ƒ function, · value, τ type, ≡ alias, G grammar),
// bodies opaque until a row is clicked open. The point is to keep as much
// of the design on the screen as possible, so a card shows only what it
// was left showing: rows hidden stay hidden (behind "N hidden"), rows
// opened stay open, and both come back when the card does.
//
//   drag a card by its title to move it; drag a file chip from the bar
//   onto the board to bring that module out; ✕ puts a card away
//   click a row: open / close its body; ✕ on a row hides it; ↗ edits it
//   a focus (a question's slice, or "just show ...") fades everything
//   it does not name
//
// The board's state is the server's (Event::Board, .puffin/board.json);
// every change here is sent back whole with `board-set`.

const KIND = { fun: "ƒ", val: "·", type: "τ", alias: "≡", grammar: "G", property: "?" };
const PROP_MARK = { ok: "✓", fail: "✗", crashed: "!", open: "◌", "not-run": "·", pending: "…" };
const GRID = { x: 28, y: 64, w: 380, gap: 24 };

const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

const clone = (value) => JSON.parse(JSON.stringify(value));
const short = (path) => path.replace(/\.puf$/, "");

export function createBoard({ editor, files, send, stage, onShow }) {
  const monaco = editor.raw?.monaco;
  let board = { view: "editor", mode: "build", cards: [], focus: null, questions: [] };
  let outline = [];
  let propertyStatus = new Map(); // name -> { status, detail } (voice.js)
  const revealed = new Set(); // cards whose hidden rows are shown for now
  let dragging = null;

  const root = el("div", "board");
  root.hidden = true;
  const canvas = el("div", "board-canvas");
  const wires = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  wires.classList.add("board-wires");
  const question = el("div", "board-question");
  question.hidden = true;
  const empty = el("div", "board-empty", "Drag a module from the bar onto the board, or say “show the board”.");
  canvas.append(wires);
  root.append(canvas, empty);
  // the question floats over the board, outside its scrolling
  stage.append(root, question);
  // the board appearing (the canvas going, a resize) lets unplaced cards be placed
  let lastWidth = 0;
  new ResizeObserver(() => {
    const width = root.offsetWidth;
    if (width && !lastWidth && shown()) render();
    lastWidth = width;
  }).observe(root);

  // ---- state ------------------------------------------------------------------

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
  const cardOf = (path) => board.cards.find((c) => c.path === path);

  function focusNames() {
    return board.focus?.items ? new Set(board.focus.items.map(([file, name]) => `${file}\u0000${name}`)) : null;
  }

  // a module's depth in the require graph among the cards out (what it
  // requires comes first): the order layouts read left to right
  function depths(cards) {
    const depth = new Map();
    const depthOf = (path, seen = new Set()) => {
      if (depth.has(path)) return depth.get(path);
      if (seen.has(path)) return 0;
      seen.add(path);
      const m = moduleOf(path);
      const d = m ? Math.max(0, ...m.requires.filter((r) => cards.some((c) => c.path === r)).map((r) => depthOf(r, seen) + 1)) : 0;
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

  // Cards without a place, placed now that they have a size. On a fresh
  // board: by dependency depth, left to right (a module right of what it
  // requires), stacked within a column. Otherwise each goes right of the
  // cards already out.
  function placeUnplaced() {
    const unplaced = board.cards.filter((c) => c.x == null || c.y == null);
    // sizes are only real once the board is on screen (not behind the canvas)
    if (!unplaced.length || !root.offsetWidth) return false;
    const size = (path) => {
      const node = canvas.querySelector(`.board-card[data-path="${CSS.escape(path)}"]`);
      return { w: node?.offsetWidth ?? GRID.w, h: node?.offsetHeight ?? 120 };
    };
    const next = clone(board);
    const placed = next.cards.filter((c) => c.x != null && c.y != null);
    if (!placed.length) {
      // shelves in dependency order: dense, and read left to right
      const spots = shelves(next.cards, size, GRID.y);
      for (const card of next.cards) Object.assign(card, spots.get(card.path));
    } else {
      let x = Math.max(...placed.map((c) => c.x + size(c.path).w)) + GRID.gap * 2;
      let y = GRID.y;
      for (const card of next.cards.filter((c) => c.x == null || c.y == null)) {
        card.x = x;
        card.y = y;
        y += size(card.path).h + GRID.gap;
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

  // ---- showing it ---------------------------------------------------------------

  function shown() {
    return board.view === "board";
  }

  function setView(view) {
    if (board.view === view) return;
    change((b) => {
      b.view = view;
      // the first time: every module out
      if (view === "board" && !b.cards.length) for (const m of outline) ensureCard(b, m.path);
    });
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
    document.body.classList.toggle("board-on", shown());
    onShow?.(shown());
    if (!shown()) {
      question.hidden = true;
      return;
    }
    const focus = focusNames();
    const keep = new Set(board.cards.map((c) => c.path));
    for (const node of [...canvas.querySelectorAll(".board-card")]) if (!keep.has(node.dataset.path)) node.remove();
    let maxX = 0;
    let maxY = 0;
    for (const card of board.cards) {
      const m = moduleOf(card.path);
      if (!m) continue;
      let node = canvas.querySelector(`.board-card[data-path="${CSS.escape(card.path)}"]`);
      if (!node) {
        node = el("div", "board-card");
        node.dataset.path = card.path;
        canvas.append(node);
      }
      renderCard(node, card, m, focus);
      if (!(dragging && dragging.path === card.path)) {
        // an unplaced card is measured out of sight first
        node.style.left = card.x == null ? "-9999px" : `${card.x}px`;
        node.style.top = card.y == null ? "0px" : `${card.y}px`;
      }
      maxX = Math.max(maxX, card.x + node.offsetWidth);
      maxY = Math.max(maxY, card.y + node.offsetHeight);
    }
    if (placeUnplaced()) return render();
    // A focus (a question's slice, "just show ..."): only the cards it
    // names, packed under the question in dependency order. The author's
    // own layout is untouched and comes back when the focus clears.
    if (focus) {
      renderQuestion();
      const focused = board.cards.filter((c) => (moduleOf(c.path)?.items ?? []).some((i) => focus.has(`${c.path}\u0000${i.name}`)));
      const nodeOf = (path) => canvas.querySelector(`.board-card[data-path="${CSS.escape(path)}"]`);
      for (const card of board.cards) {
        const node = nodeOf(card.path);
        if (node) node.hidden = !focused.includes(card);
      }
      const top = (question.hidden ? 0 : question.offsetTop + question.offsetHeight) + 24;
      const spots = shelves(focused, (path) => ({ w: nodeOf(path)?.offsetWidth ?? GRID.w, h: nodeOf(path)?.offsetHeight ?? 120 }), Math.max(GRID.y, top));
      maxX = 0;
      maxY = 0;
      for (const [path, spot] of spots) {
        const node = nodeOf(path);
        node.style.left = `${spot.x}px`;
        node.style.top = `${spot.y}px`;
        maxX = Math.max(maxX, spot.x + node.offsetWidth);
        maxY = Math.max(maxY, spot.y + node.offsetHeight);
      }
    } else {
      for (const node of canvas.querySelectorAll(".board-card")) node.hidden = false;
    }
    canvas.style.width = `${maxX + 200}px`;
    canvas.style.height = `${maxY + 200}px`;
    empty.hidden = board.cards.length > 0;
    renderWires();
    renderQuestion();
  }

  function renderCard(node, card, m, focus) {
    node.replaceChildren();
    const inFocus = focus && m.items.some((i) => focus.has(`${m.path}\u0000${i.name}`));
    node.classList.toggle("faded", Boolean(focus) && !inFocus);
    const head = el("div", "board-card-head");
    const title = el("span", "board-card-title", short(m.path));
    title.title = `${m.path} — drag to move, double-click to edit`;
    const holes = m.items.reduce((n, i) => n + i.holes, 0);
    const meta = el("span", "board-card-meta");
    if (m.provides) {
      const exported = m.items.filter((i) => m.provides.includes(i.name)).length;
      meta.textContent = `provides ${exported} of ${m.items.length}`;
    }
    if (holes) meta.append(el("span", "board-holes", ` ◌ ${holes}`));
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
      const key = `${m.path}\u0000${item.name}`;
      const focused = focus?.has(key);
      const out = focus ? !focused : hidden.has(item.name) && !showHidden;
      if (out) {
        tucked++;
        continue;
      }
      list.append(renderItem(m, item, open.has(item.name), hidden.has(item.name), focused));
    }
    node.append(list);
    if (tucked) {
      const more = el("button", "board-more", focus ? `${tucked} not in focus` : `${tucked} hidden`);
      more.addEventListener("click", () => {
        if (focus) return;
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
    const row = el("div", `board-item kind-${item.kind}${item.opaque ? " opaque" : ""}${isHidden ? " is-hidden" : ""}${focused ? " focused" : ""}`);
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
    if (item.opaque) line.append(el("span", "board-opaque", "◌"));
    else if (item.holes) line.append(el("span", "board-opaque", `◌${item.holes}`));
    const tools = el("span", "board-tools");
    const edit = el("button", "", "↗");
    edit.title = "Edit it";
    edit.addEventListener("click", (event) => { event.stopPropagation(); editAt(m.path, item.line); });
    const hide = el("button", "", isHidden ? "◉" : "✕");
    hide.title = isHidden ? "Show it again" : "Hide it on this card";
    hide.addEventListener("click", (event) => {
      event.stopPropagation();
      change((b) => {
        const card = ensureCard(b, m.path);
        card.hidden = isHidden ? card.hidden.filter((n) => n !== item.name) : [...card.hidden, item.name];
        card.open = card.open.filter((n) => n !== item.name);
        card.pinned = (card.pinned ?? []).filter((n) => n !== item.name);
      });
    });
    tools.append(edit, hide);
    line.append(tools);
    line.title = [item.doc, `${m.path}:${item.line}`, item.uses.length ? `uses ${item.uses.join(", ")}` : ""].filter(Boolean).join("\n");
    line.addEventListener("click", () => {
      change((b) => {
        const card = ensureCard(b, m.path);
        card.open = isOpen ? card.open.filter((n) => n !== item.name) : [...card.open, item.name];
        // what the author opens, the studio's automatic hiding leaves alone
        if (!isOpen && !(card.pinned ?? []).includes(item.name)) card.pinned = [...(card.pinned ?? []), item.name];
      });
    });
    row.append(line);
    if (item.doc) row.append(el("div", "board-doc", item.doc));
    if (isOpen) row.append(body(m, item));
    return row;
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
    const lines = text.split("\n").slice(item.line - 1, item.end_line);
    const source = lines.join("\n");
    const pre = el("pre", "board-body");
    pre.textContent = source;
    if (monaco?.editor?.colorize) {
      monaco.editor.colorize(source, "puffin", {}).then((html) => { pre.innerHTML = html; }).catch(() => {});
    }
    pre.addEventListener("dblclick", () => editAt(m.path, item.line));
    return pre;
  }

  function editAt(path, line) {
    setView("editor");
    if (files.active() !== path) files.open(path);
    const view = editor.raw?.editor;
    setTimeout(() => {
      if (view) {
        view.revealLineInCenter(line);
        view.setPosition({ lineNumber: line, column: 1 });
        view.focus();
      } else editor.reveal?.({ line });
    }, 30);
  }

  // lines from each card to the cards of the modules it requires
  function renderWires() {
    wires.replaceChildren();
    wires.setAttribute("width", canvas.style.width);
    wires.setAttribute("height", canvas.style.height);
    const box = (path) => canvas.querySelector(`.board-card[data-path="${CSS.escape(path)}"]`);
    for (const card of board.cards) {
      const m = moduleOf(card.path);
      const from = box(card.path);
      if (!m || !from || from.hidden) continue;
      for (const required of m.requires) {
        const to = box(required);
        if (!to || to.hidden) continue;
        // from the side of the requiring card that faces the required one
        const right = to.offsetLeft + to.offsetWidth / 2 > from.offsetLeft + from.offsetWidth / 2;
        const a = { x: right ? from.offsetLeft + from.offsetWidth : from.offsetLeft, y: from.offsetTop + 16 };
        const b = { x: right ? to.offsetLeft : to.offsetLeft + to.offsetWidth, y: to.offsetTop + 16 };
        const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
        const bend = Math.max(30, Math.abs(b.x - a.x) / 3) * (right ? 1 : -1);
        path.setAttribute("d", `M ${a.x} ${a.y} C ${a.x + bend} ${a.y} ${b.x - bend} ${b.y} ${b.x} ${b.y}`);
        path.classList.add("board-wire");
        wires.append(path);
      }
    }
  }

  // ---- a question, and its slice ------------------------------------------------

  function renderQuestion() {
    const q = board.focus?.question ? board.questions.find((x) => x.id === board.focus.question) : null;
    root.classList.toggle("focusing", Boolean(board.focus));
    question.hidden = !shown() || (!q && !board.focus);
    question.replaceChildren();
    if (!board.focus) return;
    const head = el("div", "board-question-head");
    head.append(el("span", "board-question-mark", q ? "?" : "◎"), el("span", "board-question-text", q ? q.text : board.focus.label || "focus"));
    const dismiss = el("button", "board-x", "✕");
    dismiss.title = q ? "Put the question aside (it stays in the list)" : "Show everything again";
    dismiss.addEventListener("click", () => change((b) => { b.focus = null; }));
    head.append(dismiss);
    question.append(head);
    if (q?.why) question.append(el("div", "board-question-why", q.why));
    if (q) {
      const answer = el("input", "board-answer");
      answer.placeholder = "Answer (or just say it)";
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

  // ---- dragging ---------------------------------------------------------------------

  function startDrag(event, node, card) {
    if (event.button !== 0 || event.target.closest("button") || board.focus) return;
    event.preventDefault();
    const start = { x: event.clientX, y: event.clientY, left: card.x, top: card.y };
    dragging = { path: card.path };
    node.classList.add("dragging");
    node.setPointerCapture(event.pointerId);
    const move = (e) => {
      node.style.left = `${Math.max(0, start.left + e.clientX - start.x)}px`;
      node.style.top = `${Math.max(0, start.top + e.clientY - start.y)}px`;
      renderWires();
    };
    const up = (e) => {
      node.removeEventListener("pointermove", move);
      node.removeEventListener("pointerup", up);
      node.classList.remove("dragging");
      dragging = null;
      const x = Math.max(0, Math.round(start.left + e.clientX - start.x));
      const y = Math.max(0, Math.round(start.top + e.clientY - start.y));
      change((b) => { const c = ensureCard(b, card.path); c.x = x; c.y = y; });
    };
    node.addEventListener("pointermove", move);
    node.addEventListener("pointerup", up);
  }

  // a file chip dropped on the board brings its module out there
  root.addEventListener("dragover", (event) => {
    if (event.dataTransfer?.types.includes("text/x-puffin-module")) {
      event.preventDefault();
      event.dataTransfer.dropEffect = "copy";
    }
  });
  root.addEventListener("drop", (event) => {
    const path = event.dataTransfer?.getData("text/x-puffin-module");
    if (!path) return;
    event.preventDefault();
    const rect = canvas.getBoundingClientRect();
    const at = { x: Math.max(0, Math.round(event.clientX - rect.left - 40)), y: Math.max(0, Math.round(event.clientY - rect.top - 12)) };
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
    } else if (shown() && event.key === "Escape" && board.focus && !event.defaultPrevented) {
      change((b) => { b.focus = null; });
    }
  });

  return {
    receive({ board: next, outline: modules }) {
      if (next) board = next;
      if (modules) outline = modules;
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
    state: () => board,
  };
}
