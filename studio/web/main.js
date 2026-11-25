// Puffin Studio in the browser: the playground's layout (web/src/App.jsx)
// -- the program's files in the editor, the REPL beside it -- fed by one
// WebSocket to the studio (studio/src/web.rs), with the assistant a Tab
// away at the prompt.

import { createEditor } from "./editor.js";
import { createFiles } from "./files.js";
import { createTree } from "./tree.js";
import { createRepl } from "./repl.js";
import { initAssist } from "./assist.js";
import { createAssists } from "./assists.js";
import { createProposals } from "./proposals.js";
import { createVersions } from "./versions.js";
import { createHistory } from "./history.js";
import { initGist } from "./gist.js";
import { createProjects } from "./projects.js";
import { createReplay } from "./replay.js";
import { createSession, functionDefine } from "./session.js";
import { createHoles } from "./holes.js";
import { createLint } from "./lint.js";
import { createRename } from "./rename.js";
import { createVoice } from "./voice.js";
import { createFocus } from "./focus.js";
import { createBoard } from "./board.js";
import { createPalette } from "./palette.js";
import { createView } from "./view.js";
import { formAt, forms, lineIndex } from "./lexer.js";
import { structured } from "./paredit.js";
import { requests } from "./requests.js";
import { remember } from "./stored.js";

const $ = (id) => document.getElementById(id);

let socket = null;
const transmit = (message) => {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
};

// A brief message over the editor's foot.
let noticeTimer = 0;
function note(message) {
  const box = $("notice");
  box.textContent = message;
  box.hidden = false;
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => { box.hidden = true; }, 5000);
}

// made once the files are: the editor's events may come first
let session = null;
// the focused layout (focus.js), made once the files are
let focus = null;
let holes = null;
// the code view: the focus, its neighbourhood, the working set (view.js)
let view = null;
let rename = null;
// the traced function names, and what the toolchain can do (the studio's)
let traced = [];
let features = {};

const editor = await createEditor($("editor"), {
  onChange: () => {
    files.changed();
    session?.changed();
    holes?.changed();
  },
  onRename: () => rename?.open(),
  onHole: (dir) => holes?.next(dir),
  onCursor: () => {},
  onOtherChange: (path, text) => files.edited(path, text),
  onSave: save,
  onEvalForm: evalForm,
  onLoadFile: () => load(null),
  onAssist: () => assists.open(),
  onTrace: toggleTrace,
});

const files = createFiles({
  editor,
  transmit,
  note,
  onOpen(path) {
    transmit({ t: "focus", file: path });
    showDiagnostics();
    session?.refresh();
    holes?.refresh();
    lint?.refresh();
    proposals?.refresh();
    versions?.opened();
    focus?.changed();
    view?.opened(path);
  },
  onTexts: () => {
    proposals?.refresh();
    session?.changed();
    focus?.changed();
  },
  onFiles: () => {
    tree?.changed();
    focus?.changed();
  },
});
// every message waits behind the edits already made, so it sees them
const send = files.send;
const tree = createTree({ panel: $("files"), toggle: $("files-toggle"), add: $("new-file"), quick: $("quick-open"), files, editor, note });

// The studio's facts at UTF-16 offset `pos` of `file` (studio/src/facts.rs):
// the type there (a hole's goal) and what runs passed a parameter. The
// hover shows them (assists.js).
const facts = requests(files);
const askFacts = (file, pos, full = false) => facts.ask({ t: "facts", file, pos, full });

const proposals = createProposals({ editor, files, send, bar: $("proposals") });
const versions = createVersions({ panel: $("versions"), files, send });
const history = createHistory({
  panel: $("history-panel"),
  send,
  onMoments: (list) => replay.moments(list),
  onJump: (index) => replay.start(index),
});
const replay = createReplay({
  editor,
  send,
  history,
  clock: $("clock"),
  panel: $("replay"),
  past: $("past"),
  pastTabs: $("past-tabs"),
  pastTranscript: $("past-transcript"),
});
const projects = createProjects({ button: $("project"), menu: $("projects-menu"), send });
$("history").addEventListener("click", () => history.toggle());
initGist({ button: $("gist"), texts: () => files.texts(), project: () => $("project").textContent.trim(), note });
session = createSession({ editor, files, traced: () => traced, canTrace: () => Boolean(features.trace && features.observe) });
const lint = createLint({ editor, files });
holes = createHoles({ editor, files, note, onCount: () => renderCheck() });
const assists = createAssists({ editor, files, send, note, facts: askFacts });
rename = createRename({ editor, files, send, note });
focus = createFocus({ editor, files, run: () => load(null), evalAt, stage: document.querySelector(".editor-pane") });
// the board and the working set are one surface beside the focus (docs/VIEW.md)
const board = createBoard({ send, stage: document.querySelector(".board-pane"), onChange: () => focus?.boardChanged() });
focus.attachBoard(board);
view = createView({ editor, files, board, stage: document.querySelector(".editor-pane"), onEvalAt: evalAt });
// the welcome's other path: design on the board, plan mode, the first
// module's "+ plan a definition" open
focus.onPlanHere = () => {
  board.setMode("plan");
  const first = files.paths().filter((p) => /\.puf$/.test(p) && !["prop.puf", "properties.puf"].includes(p)).sort()[0];
  if (first) setTimeout(() => board.startAdding(first), 350);
};
const voice = createVoice({ editor, files, send, note, button: $("voice-toggle"), stage: document.querySelector(".editor-pane"), layout: focus, board, run: () => load(null) });

// ⌘K: every action, every file, every definition
const KIND_ICON = { fun: "ƒ", val: "·", type: "τ", alias: "≡", grammar: "G", property: "?" };
const palette = createPalette({
  commands() {
    const list = [];
    const add = (group, title, run, extra = {}) => list.push({ group, title, run, ...extra });
    add("Board", board.out() ? "Back to the code: the working set beside the focus" : "Show the board: glide out to the whole program", () => board.toggle(), { icon: "▦", keys: "⌘⇧B", rank: 1 });
    add("Board", board.mode() === "plan" ? "Leave plan mode (build)" : "Plan mode: signatures first, bodies as holes", () => board.setMode(board.mode() === "plan" ? "build" : "plan"), { icon: "◌", rank: 1 });
    const planned = board.outline().flatMap((m) => m.items.filter((i) => i.opaque)).length;
    if (planned) add("Board", `Build the plan: write the ${planned} planned bod${planned === 1 ? "y" : "ies"}`, () => board.buildPlan(), { icon: "▸", keywords: "implement fill holes dive in", rank: 1 });
    add("Board", "Tidy the board: re-pack the cards for this window", () => board.tidy(), { icon: "▤", keys: "t", keywords: "arrange layout pack" });
    add("Board", "Filter the board", () => board.focusFilter(), { icon: "⌕", keys: "/" });
    if (board.state().focus) add("Board", "Show everything (clear the focus)", () => board.clearFocus(), { icon: "◎", keys: "Esc" });
    add("Run", "Run the shown file", () => load(null), { icon: "▸", keys: "⇧⌘↵", rank: 1 });
    add("Run", "Run the properties", () => send({ t: "voice-control", command: "run-properties" }), { icon: "✓" });
    add("Run", "Show the output and REPL", () => focus.showOutput(true), { icon: "›" });
    add("Run", "Reset the session", () => $("reset").click(), { icon: "↺" });
    add("Project", "Open another project…", () => $("project").click(), { icon: "⌂" });
    const setTheme = (theme) => {
      if (theme) document.documentElement.dataset.theme = theme;
      else delete document.documentElement.dataset.theme;
      remember("puffin-theme", theme ?? null);
    };
    const theme = document.documentElement.dataset.theme ?? "system";
    add("Appearance", `Theme: dark${theme === "dark" ? " ✓" : ""}`, () => setTheme("dark"), { icon: "◐", keywords: "dark mode night solarized" });
    add("Appearance", `Theme: light${theme === "light" ? " ✓" : ""}`, () => setTheme("light"), { icon: "○", keywords: "light mode day solarized" });
    add("Appearance", `Theme: match the system${theme === "system" ? " ✓" : ""}`, () => setTheme(null), { icon: "◑", keywords: "auto theme" });
    add("Project", "History of this project", () => history.toggle(), { icon: "◷" });
    add("Project", "New module…", () => (focus.on() ? focus.newModule() : tree.newFile()), { icon: "+" });
    add("Voice", voice.on() ? "Show all panes (leave the focused layout)" : "Focused layout with voice", () => voice.toggle(), { icon: "◉", keys: "⌘⇧V" });
    add("Voice", "Undo the builder's last edit", () => send({ t: "voice-control", command: "undo" }), { icon: "↶" });
    add("Voice", "Start a new conversation with the builder", () => send({ t: "voice-control", command: "new-conversation" }), { icon: "✦" });
    for (const path of files.paths().filter((p) => p !== "prop.puf")) {
      add("Files", path, () => files.open(path), { icon: "▤", detail: path === files.active() ? "shown" : "", rank: 3 });
    }
    for (const m of board.outline()) {
      for (const item of m.items) {
        add("Definitions", item.kind === "property" ? item.sig : item.name, () => view.focusAt(m.path, item.line), {
          icon: KIND_ICON[item.kind] ?? "·",
          detail: item.kind === "property" ? m.path : `${item.sig.replace(/^(val|type|grammar) \S+\s*/, "")} — ${m.path.replace(/\.puf$/, "")}${item.opaque ? " ◌" : ""}`,
          keywords: `${item.sig} ${item.doc ?? ""}`,
          alt: () => board.slice(m.path, item.name),
          hiddenUntilTyped: true,
          rank: 4,
        });
      }
    }
    return list;
  },
});

const repl = createRepl({
  transcript: $("transcript"),
  prompt: $("prompt"),
  send,
  commands: {
    load,
    save,
    evalAt: (file, line) => evalAt(file, { line }),
    session: () => session.listing(),
    traced: () => traced,
    assist: (id, file, pos, end) => assists.run(id, file, pos, end),
    rename: (file, pos, name) => rename.run(file, pos, name),
    history: () => history.toggle(),
    versions: () => versions.toggle(),
    files: () => tree.toggle(),
    newFile: (path) => tree.newFile(path),
    open(file) {
      if (!file) return tree.quickOpen();
      if (!files.paths().includes(file)) return note(`no file ${file}`);
      files.open(file);
    },
    structured(word) {
      if (word === "on" || word === "off") structured.set(word === "on");
      return `structured editing is ${structured.on ? "on: brackets stay balanced (,structured off to type freely)" : "off (,structured on keeps brackets balanced)"}`;
    },
    reveal(file, line) {
      if (!files.paths().includes(file)) return note(`no file ${file}`);
      if (files.active() !== file) files.open(file);
      editor.reveal({ line });
    },
  },
});

const assist = initAssist({
  prompt: $("prompt"),
  scopeSelect: $("scope"),
  send,
  repl,
  proposalChip: (ids) => proposals.chip(ids),
  context() {
    const file = files.active();
    const { start, end } = editor.selection();
    return { file, selection: start !== end ? [start, end] : null, cursor: end };
  },
});

// ---- Gestures -------------------------------------------------------------

function save() {
  files.flush();
  send({ t: "save" });
}

// ⌘↵: the top-level form at the cursor, with the definitions it needs
// that the session lacks (`,eval FILE:LINE`); a selection, as it is.
function evalForm() {
  const file = files.active();
  if (!file) return;
  const text = editor.get();
  const { start, end } = editor.selection();
  if (start === end) {
    const form = formAt(forms(text), start) ?? forms(text).findLast((f) => f.end <= start);
    if (!form) return note("no form at the cursor");
    return evalAt(file, { pos: form.start });
  }
  const line = lineIndex(text)(start).line;
  files.flush();
  send({ t: "eval", text: text.slice(start, end), source: "buffer", file, line });
}

// The form of `file` at { pos } (a UTF-16 offset) or { line }.
function evalAt(file, at) {
  if (!files.paths().includes(file)) return note(`no file ${file}`);
  files.flush();
  send({ t: "eval-form", file, ...at });
}

// The function define at { line } or { pos } of the shown file, traced or
// untraced by the command a person would type: `,trace f`.
function toggleTrace(at) {
  const file = files.active();
  if (!file) return;
  if (!(features.trace && features.observe)) return note("this puffincc cannot trace (--repl --trace): bin/bootstrap builds one that can");
  const text = editor.get();
  const all = forms(text);
  const form = at.pos !== undefined ? formAt(all, at.pos) : all.find((f) => f.line <= at.line && at.line <= f.endLine);
  if (!form || !functionDefine(text, form)) return note("tracing is for function defines: (define (f a ...) ...)");
  repl.run(`${traced.includes(form.name) ? ",untrace" : ",trace"} ${form.name}`);
}

// Run, or ⇧⌘↵, or ,load: a whole module, as one unit.
function load(file) {
  const target = file ?? files.active();
  if (!target) return;
  if (!files.paths().includes(target)) return note(`no file ${target}`);
  files.flush();
  send({ t: "eval", text: "", source: "file", file: target });
}

$("load").addEventListener("click", () => load(null));
$("interrupt").addEventListener("click", () => {
  send({ t: "echo", line: ",interrupt" });
  send({ t: "interrupt" });
});
$("reset").addEventListener("click", () => send({ t: "reset" }));

// Ctrl-` moves between the editor and the prompt.
document.addEventListener("keydown", (event) => {
  if (event.ctrlKey && event.key === "`") {
    event.preventDefault();
    if (document.activeElement === $("prompt")) editor.focus();
    else $("prompt").focus();
  }
});

// The divider resizes the editor against the REPL.
$("divider").addEventListener("pointerdown", (event) => {
  const main = document.querySelector("main");
  const pane = document.querySelector(".editor-pane");
  const move = (e) => {
    const box = main.getBoundingClientRect();
    const width = Math.min(box.width - 320, Math.max(240, e.clientX - box.left));
    pane.style.flex = `0 0 ${width}px`;
  };
  const up = () => { removeEventListener("pointermove", move); removeEventListener("pointerup", up); };
  addEventListener("pointermove", move);
  addEventListener("pointerup", up);
  event.preventDefault();
});

// ---- Diagnostics ------------------------------------------------------------

// A check that stops at a typed hole reports it as a hole, not an error
// (studio/src/toolchain.rs): the holes are outlined where they are
// (holes.js), and the check's word says that the check went only that far.
let reports = {};
let byFile = new Map();
function showDiagnostics() {
  byFile = new Map();
  for (const report of Object.values(reports)) {
    for (const d of report.diagnostics) {
      const list = byFile.get(d.file) ?? [];
      if (!list.some((k) => k.line === d.line && k.message === d.message)) list.push(d);
      byFile.set(d.file, list);
    }
  }
  const counts = new Map();
  for (const path of files.paths()) {
    const list = (byFile.get(path) ?? []).filter((d) => d.severity !== "hole");
    editor.markers(path, list);
    counts.set(path, { errors: list.filter((d) => d.severity === "error").length, warnings: list.filter((d) => d.severity === "warning").length });
  }
  files.setCounts(counts);
  renderCheck();
}

function renderCheck() {
  const active = files.active();
  const here = (byFile.get(active) ?? []).filter((d) => d.severity !== "hole");
  const stopped = [...byFile.values()].flat().some((d) => d.severity === "hole");
  const holeCounts = holes?.count() ?? new Map();
  const holeTotal = [...holeCounts.values()].reduce((a, b) => a + b, 0);
  const errors = here.filter((d) => d.severity === "error");
  const status = $("check");
  // holes only elsewhere: this file checks, and the word says where they are
  const holesHere = holeCounts.get(active) ?? 0;
  const elsewhere = [...holeCounts.keys()].filter((path) => path !== active);
  const holed = holeTotal ? `◌ ${holeTotal} hole${holeTotal === 1 ? "" : "s"}${holesHere ? "" : ` in ${elsewhere.join(", ")}`}` : "";
  status.className = `check ${errors.length ? "bad" : holesHere ? "hole" : here.length ? "warn" : "good"}`;
  const head = errors.length ? `✗ ${errors.length} error${errors.length === 1 ? "" : "s"}` : here.length ? `⚠ ${here.length} warning${here.length === 1 ? "" : "s"}` : holesHere ? "" : "✓ checks";
  status.replaceChildren(document.createTextNode([head, holed].filter(Boolean).join(" · ")));
  if (stopped && holesHere && !errors.length) {
    const quiet = status.appendChild(document.createElement("span"));
    quiet.className = "pill-quiet";
    quiet.textContent = " · the rest checks";
  }
  const lines = here.map((d) => `${d.severity}: ${d.message}${d.line ? ` [line ${d.line}]` : ""}`);
  if (holeTotal) {
    lines.push(`typed holes (??): ${[...holeCounts].map(([path, n]) => `${path} ${n}`).join(", ")} · F8 goes to the next`);
    if (stopped) lines.push("everything around the holes checks; each hole is an unwritten expression");
  }
  status.title = lines.join("\n") || `${active ?? ""} passes the check`;
  // an error with no line in the shown file still shows
  const loose = (byFile.get("") ?? []).map((d) => d.message);
  if (loose.length) status.title += `\n${loose.join("\n")}`;
}
$("check").addEventListener("click", () => {
  const first = Object.values(reports).flatMap((r) => r.diagnostics).find((d) => d.file === files.active() && d.line && d.severity !== "hole");
  if (first) editor.reveal({ line: first.line });
  else if (holes.count().size) holes.next(1);
});

// ---- The header's right side -------------------------------------------------

function renderLane(lane) {
  const indicator = $("lane");
  const words = { starting: "starting the session…", busy: "running…", failed: "the session failed" };
  const word = words[lane.state];
  indicator.hidden = !word;
  indicator.className = `running-indicator${lane.state === "failed" ? " failed" : ""}`;
  indicator.querySelector(".text").textContent = word ?? "";
  indicator.title = lane.detail || "";
  $("interrupt").hidden = lane.state !== "busy";
}

function renderFeatures(next) {
  const before = features;
  features = next;
  assists.setAvailable(features.assist);
  rename.setAvailable(features.rename);
  if (before.assist !== features.assist && !features.assist) {
    note("this puffincc has no --assist: no types, holes or assists (bin/bootstrap builds one that has)");
  }
  session.refresh();
}

function renderConnection(on) {
  $("connection").hidden = on;
}

// ---- The socket -------------------------------------------------------------------

const handlers = {
  init(snapshot) {
    // (re)connected: voice mode asks for its state now that it can
    setTimeout(() => voice.connected(), 0);
    document.title = `${snapshot.project} — Puffin`;
    $("project").textContent = snapshot.project;
    $("project").title = snapshot.directory;
    files.receive.init(snapshot);
    if (snapshot.board) board.receive(snapshot.board);
    tree.receive.init(snapshot);
    reports = snapshot.diagnostics;
    proposals.update(snapshot.review);
    assist.receive.review(snapshot.review);
    repl.receive.init(snapshot);
    traced = snapshot.traced ?? [];
    session.receive.init(snapshot);
    holes.receive.init(snapshot);
    lint.receive.init(snapshot);
    showDiagnostics();
    renderLane(snapshot.lane);
    renderFeatures(snapshot.features);
    if (snapshot.agent_unavailable) note(`the assistant is unavailable: ${snapshot.agent_unavailable}`);
  },
  ack: files.receive.ack,
  stale: files.receive.stale,
  gone: files.receive.gone,
  text: files.receive.text,
  files: files.receive.files,
  saved: files.receive.saved,
  diagnostics({ reports: latest }) {
    reports = latest;
    showDiagnostics();
  },
  session: session.receive.session,
  facts: facts.answer,
  holes: holes.receive.holes,
  lint: lint.receive.lint,
  renamed: rename.receive.renamed,
  traced({ names }) {
    traced = names;
    session.refresh();
  },
  lane: renderLane,
  features: renderFeatures,
  entry(entry) {
    repl.receive.entry(entry);
    focus?.entry(entry);
  },
  "entry-out": repl.receive["entry-out"],
  "entry-done"(message) {
    repl.receive["entry-done"](message);
    history.changed();
    if (replay.on()) history.load();
  },
  journal: () => { history.changed(); if (replay.on()) history.load(); },
  agent: assist.receive.agent,
  asked: assist.receive.asked,
  review(view) {
    // the answers' chips read the proposals' view
    proposals.update(view);
    assist.receive.review(view);
  },
  assists: assists.receive.assists,
  completions: assists.receive.completions,
  type: assists.receive.type,
  versions: versions.receive.versions,
  "version-text": versions.receive["version-text"],
  version: versions.receive.version,
  history: history.receive.history,
  "history-diff": history.receive["history-diff"],
  "files-at": replay.receive["files-at"],
  projects: projects.receive.projects,
  reopen: projects.receive.reopen,
  notice: ({ message }) => {
    note(message);
    voice.notice(message);
  },
  voice: (event) => voice.receive(event),
  board: (message) => board.receive(message),
  "voice-state": (state) => voice.receiveState(state),
};

function connect() {
  socket = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`);
  socket.addEventListener("open", () => renderConnection(true));
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    // the attention model's tracker sees each message before anything
    // that ranks with it (view.js)
    view?.receive(message);
    handlers[message.t]?.(message);
  });
  socket.addEventListener("close", () => {
    renderConnection(false);
    setTimeout(connect, 1000);
  });
}

connect();
$("prompt").focus();
