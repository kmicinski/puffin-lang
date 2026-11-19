// The focused layout (docs/VOICE.md §3): the editor alone, centered, about
// 105 characters wide, and everything else a floating component that
// appears when it is used.
//
// - The top bar, aligned with the editor: the project, the files as chips
//   (one file: just its name), + for a new module, double-click a name to
//   rename it; on the right, the check (only when it fails), the session's
//   state, Run. It fades until the mouse comes near.
// - The output: the REPL pane, floating, shown when something runs (an
//   entry arrives) or when asked; ✕ or Esc hides it.
// - Hovering a top-level form shows a chip beside it: ▸ evaluates the
//   form, REPL opens the prompt (with `(f ` for a function).
// - The canvas: a project with no code yet shows no editor at all, only
//   the pill, centered, waiting for a description; the editor fades in
//   when the first code lands. A new visit (a tab that has not been here)
//   to a project that has code starts on the canvas too, with a way back
//   to that project: the first description then makes a new project.
//
// The header's own pieces (project menu, check, lane, Stop) are moved into
// the bar while focused, and put back when the full layout returns.

import { forms } from "./lexer.js";
import { sorted } from "./files.js";

const COLUMNS = 105;
// files the studio keeps for itself, not shown as modules
const HIDDEN = new Set(["prop.puf"]);

const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

// A tab that has been here before (this session): it reloads into its work.
const SEEN = "puffin-tab";
function firstVisit() {
  try {
    const seen = sessionStorage.getItem(SEEN);
    sessionStorage.setItem(SEEN, "1");
    return !seen;
  } catch {
    return false;
  }
}

// Whether a file holds code: anything but comments and blank space.
const hasCode = (text) => text.split("\n").some((line) => line.replace(/;.*$/, "").trim() !== "");

export function createFocus({ editor, files, run, evalAt, stage }) {
  const view = editor.raw?.editor;
  const monaco = editor.raw?.monaco;
  let on = false;
  // a new visit: the canvas, even over a project with code, until left
  let fresh = firstVisit();
  const moved = []; // [node, parent, nextSibling]

  // ---- The top bar ---------------------------------------------------------------

  const bar = el("div", "focus-bar");
  bar.hidden = true;
  const left = el("div", "focus-left");
  const chips = el("div", "focus-files");
  const right = el("div", "focus-right");
  const slot = el("span", "focus-slot"); // voice mode's badge
  // the module board (board.js) and plan mode
  let board = null;
  const boardButton = el("button", "focus-board", "▦ Board");
  boardButton.title = "The module board: signatures, bodies opaque (⌘⇧B, or say “show the board”)";
  boardButton.addEventListener("click", () => board?.toggle());
  const modeButton = el("button", "focus-mode", "Plan");
  modeButton.title = "Plan mode: the builder writes signatures and leaves bodies as holes (say “plan mode” / “build mode”)";
  modeButton.addEventListener("click", () => board?.setMode(board.mode() === "plan" ? "build" : "plan"));
  const runButton = el("button", "focus-run", "▸ Run");
  runButton.title = "Run the shown file (⇧⌘↵, or say “run it”)";
  runButton.addEventListener("click", () => { run(); });
  left.append(chips);
  right.append(slot, modeButton, boardButton, runButton);
  bar.append(left, right);
  stage.append(bar);

  let editing = null; // { kind: "new" | "rename", path }

  function renderFiles() {
    chips.replaceChildren();
    const active = files.active();
    const paths = sorted(files.paths()).filter((path) => !HIDDEN.has(path));
    for (const path of paths) {
      if (editing?.kind === "rename" && editing.path === path) {
        chips.append(nameInput(path.replace(/\.puf$/, ""), (name) => files.moveFile(path, name)));
        continue;
      }
      const chip = el("button", `focus-file${path === active ? " current" : ""}`, path);
      chip.title = path === active ? "Double-click to rename · drag onto the board" : `Open ${path} · drag onto the board`;
      // on the board a click brings the module out; else it opens it
      chip.addEventListener("click", () => {
        if (board?.shown()) board.bringOut(path);
        else if (path !== active) files.open(path);
      });
      chip.draggable = true;
      chip.addEventListener("dragstart", (event) => {
        event.dataTransfer.setData("text/x-puffin-module", path);
        event.dataTransfer.effectAllowed = "copy";
      });
      chip.addEventListener("dblclick", () => { editing = { kind: "rename", path }; renderFiles(); });
      chips.append(chip);
    }
    if (editing?.kind === "new") {
      chips.append(nameInput("", (name) => files.newFile(name), "new module"));
    } else {
      const add = el("button", "focus-add", "+");
      add.title = "A new module (or say “make a module called …”)";
      add.addEventListener("click", () => { editing = { kind: "new" }; renderFiles(); });
      chips.append(add);
    }
  }

  function nameInput(value, done, placeholder = "") {
    const input = el("input", "focus-name");
    input.value = value;
    input.placeholder = placeholder;
    input.size = Math.max(10, value.length + 2);
    let finished = false;
    const finish = (commit) => {
      if (finished) return;
      finished = true;
      const name = input.value.trim();
      editing = null;
      if (commit && name && name !== value) done(name);
      // after the event that ended it: a blur can come mid-render
      setTimeout(renderFiles, 0);
    };
    input.addEventListener("keydown", (event) => {
      event.stopPropagation();
      if (event.key === "Enter") finish(true);
      if (event.key === "Escape") finish(false);
    });
    input.addEventListener("input", () => { input.size = Math.max(10, input.value.length + 2); });
    input.addEventListener("blur", () => finish(true));
    setTimeout(() => { input.focus(); input.select(); }, 0);
    return input;
  }

  // ---- The output -------------------------------------------------------------------

  const pane = document.querySelector(".right-pane");
  const close = el("button", "focus-close", "✕");
  close.title = "Hide the output (Esc, or say “hide the output”)";
  close.addEventListener("click", () => showOutput(false));
  pane.querySelector(".pane-title")?.append(close);

  function showOutput(value = true) {
    document.body.classList.toggle("focus-output", value);
    if (value) {
      const transcript = document.getElementById("transcript");
      if (transcript) transcript.scrollTop = transcript.scrollHeight;
    }
  }
  const outputShown = () => document.body.classList.contains("focus-output");

  // ---- The chip beside a hovered form -------------------------------------------------

  const chip = el("div", "focus-chip");
  chip.hidden = true;
  const evalButton = el("button", "", "▸");
  evalButton.title = "Evaluate this form (⌘↵)";
  const replButton = el("button", "", "REPL");
  replButton.title = "Open the REPL to try it";
  chip.append(evalButton, replButton);
  stage.append(chip);
  let hovered = null; // { file, line, name, define }
  let cache = { model: null, version: -1, found: [] };
  let hoverTimer = 0;

  function formsOf(model) {
    const version = model.getVersionId();
    if (cache.model !== model || cache.version !== version) cache = { model, version, found: forms(model.getValue()) };
    return cache.found;
  }

  function placeChip(form) {
    const top = view.getTopForLineNumber(form.line) - view.getScrollTop();
    const box = view.getDomNode().getBoundingClientRect();
    const host = stage.getBoundingClientRect();
    if (top < 0 || top > box.height - 20) return (chip.hidden = true);
    chip.style.top = `${box.top - host.top + top}px`;
    chip.style.left = `${box.right - host.left + 8}px`;
    chip.hidden = false;
  }

  if (view) {
    view.onMouseMove((event) => {
      if (!on) return;
      const position = event.target?.position;
      clearTimeout(hoverTimer);
      if (!position) return;
      hoverTimer = setTimeout(() => {
        const model = view.getModel();
        const form = forms && model && formsOf(model).find((f) => f.line <= position.lineNumber && position.lineNumber <= f.endLine);
        if (!form) return (chip.hidden = true);
        const text = model.getValue().slice(form.start, form.end);
        const define = /^\(define\s+\(/.test(text);
        hovered = { file: files.active(), line: form.line, name: form.name, define };
        placeChip(form);
      }, 250);
    });
    view.onDidScrollChange(() => { chip.hidden = true; });
    // leaving the editor for anywhere but the chip itself hides it
    view.onMouseLeave((event) => {
      const to = event.event?.browserEvent?.relatedTarget;
      clearTimeout(hoverTimer);
      if (!(to && chip.contains(to))) chip.hidden = true;
    });
  }
  stage.addEventListener("mouseleave", () => { chip.hidden = true; });
  evalButton.addEventListener("click", () => {
    if (!hovered) return;
    evalAt(hovered.file, { line: hovered.line });
  });
  replButton.addEventListener("click", () => {
    showOutput(true);
    const prompt = document.getElementById("prompt");
    if (!prompt) return;
    if (hovered?.define && hovered.name && !prompt.value.trim()) prompt.value = `(${hovered.name} `;
    prompt.focus();
    prompt.setSelectionRange(prompt.value.length, prompt.value.length);
  });

  // ---- The editor's width ------------------------------------------------------------

  function measure() {
    if (!view || !monaco) return;
    const info = view.getOption(monaco.editor.EditorOption.fontInfo);
    const layout = view.getLayoutInfo();
    const width = Math.round(COLUMNS * info.typicalHalfwidthCharacterWidth + layout.contentLeft + 24);
    document.body.style.setProperty("--focus-width", `${width}px`);
    view.layout();
  }

  // ---- The canvas ----------------------------------------------------------------------

  const away = el("button", "focus-continue");
  away.addEventListener("click", () => { fresh = false; update(); });
  stage.append(away);

  function empty() {
    return !Object.entries(files.texts()).some(([path, text]) => !HIDDEN.has(path) && hasCode(text ?? ""));
  }

  // "new": a description makes a new project; "here": it builds in this
  // one; null: not on the canvas
  function canvasMode() {
    if (!on) return null;
    if (empty()) return "here";
    return fresh ? "new" : null;
  }

  // while the canvas shows, look again each second: code can arrive by
  // any of several events, in any order
  setInterval(() => { if (document.body.classList.contains("focus-canvas")) update(); }, 1000);

  function update() {
    const mode = canvasMode();
    document.body.classList.toggle("focus-canvas", Boolean(mode));
    const project = document.getElementById("project")?.textContent.trim();
    away.hidden = mode !== "new";
    away.textContent = `or continue ${project || "the open project"} →`;
    if (!mode) setTimeout(() => view?.layout(), 0);
    api.onCanvas?.(mode);
  }

  // ---- On and off --------------------------------------------------------------------

  // the header's pieces that live in the bar while focused
  const PIECES = [["project", "left"], ["projects-menu", "left"], ["check", "right"], ["lane", "right"], ["interrupt", "right"], ["connection", "right"]];

  function enter() {
    if (on) return;
    on = true;
    bar.hidden = false;
    for (const [id, side] of PIECES) {
      const node = document.getElementById(id);
      if (!node) continue;
      moved.push([node, node.parentNode, node.nextSibling]);
      if (side === "left") left.insertBefore(node, chips);
      else right.insertBefore(node, slot);
    }
    renderFiles();
    update();
    setTimeout(measure, 0);
  }

  function leave() {
    if (!on) return;
    on = false;
    bar.hidden = true;
    chip.hidden = true;
    for (const [node, parent, next] of moved.reverse()) parent.insertBefore(node, next);
    moved.length = 0;
    showOutput(false);
    document.body.classList.remove("focus-canvas");
    document.body.style.removeProperty("--focus-width");
    setTimeout(() => view?.layout(), 0);
  }

  window.addEventListener("keydown", (event) => {
    if (on && event.key === "Escape" && outputShown() && !event.defaultPrevented) showOutput(false);
  });
  window.addEventListener("resize", () => on && setTimeout(() => view?.layout(), 0));

  const api = {
    onCanvas: null,
    enter,
    leave,
    slot,
    showOutput,
    // a transcript entry began: something ran, so the output shows
    entry() { if (on) showOutput(true); },
    // the files, their text, or the shown file changed
    changed() {
      if (!on) return;
      if (!editing) renderFiles();
      update();
    },
    canvasMode,
    attachBoard(b) { board = b; },
    // the board showed or went: the bar's buttons say so
    boardShown(shown) {
      boardButton.classList.toggle("on", shown);
      modeButton.classList.toggle("on", board?.mode() === "plan");
      modeButton.textContent = board?.mode() === "plan" ? "Plan ✓" : "Plan";
    },
    // the author asked to build something new: off the canvas once it lands
    started() { fresh = false; },
    on: () => on,
  };
  return api;
}
