// Puffin Studio in the browser: the playground's layout (web/src/App.jsx)
// -- the program's files in the editor, the REPL beside it -- fed by one
// WebSocket to the studio (studio/src/web.rs), with the assistant a Tab
// away at the prompt.

import { createEditor } from "./editor.js";
import { createFiles } from "./files.js";
import { createRepl } from "./repl.js";
import { initAssist } from "./assist.js";
import { createAssists } from "./assists.js";
import { createProposals } from "./proposals.js";
import { createVersions } from "./versions.js";
import { createSession, functionDefine } from "./session.js";
import { createHoles } from "./holes.js";
import { createLint } from "./lint.js";
import { createRename } from "./rename.js";
import { formAt, forms, lineIndex } from "./lexer.js";
import { structured } from "./paredit.js";

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
let holes = null;
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
  },
  onTexts: () => {
    proposals?.refresh();
    session?.changed();
  },
});
// every message waits behind the edits already made, so it sees them
const send = files.send;

// The studio's facts at UTF-16 offset `pos` of `file` (studio/src/facts.rs):
// the type there (a hole's goal) and what runs passed a parameter. The
// hover shows them (assists.js).
const factsWaiting = new Map(); // seq -> resolve
let factsSeq = 0;
function askFacts(file, pos, full = false) {
  files.flush();
  const id = ++factsSeq;
  return new Promise((resolve) => {
    factsWaiting.set(id, resolve);
    send({ t: "facts", seq: id, file, pos, full });
  });
}

const proposals = createProposals({ editor, files, send, bar: $("proposals") });
const versions = createVersions({ panel: $("versions"), files, send });
session = createSession({ editor, files, traced: () => traced, canTrace: () => Boolean(features.trace && features.observe) });
const lint = createLint({ editor, files });
holes = createHoles({ editor, files, note, onCount: () => renderCheck() });
const assists = createAssists({ editor, files, send, note, facts: askFacts });
rename = createRename({ editor, files, send, note });

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
    history: () => versions.toggle(),
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
    quiet.textContent = " · checked up to the first hole";
  }
  const lines = here.map((d) => `${d.severity}: ${d.message}${d.line ? ` [line ${d.line}]` : ""}`);
  if (holeTotal) {
    lines.push(`typed holes (??): ${[...holeCounts].map(([path, n]) => `${path} ${n}`).join(", ")} · F8 goes to the next`);
    if (stopped) lines.push("the checker stops at the first hole, so nothing after it is checked");
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
    document.title = `${snapshot.project} — Puffin`;
    $("project").textContent = snapshot.project;
    $("project").title = snapshot.directory;
    files.receive.init(snapshot);
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
  facts(reply) {
    factsWaiting.get(reply.seq)?.(reply);
    factsWaiting.delete(reply.seq);
  },
  holes: holes.receive.holes,
  lint: lint.receive.lint,
  renamed: rename.receive.renamed,
  traced({ names }) {
    traced = names;
    session.refresh();
  },
  lane: renderLane,
  features: renderFeatures,
  entry: repl.receive.entry,
  "entry-out": repl.receive["entry-out"],
  "entry-done": repl.receive["entry-done"],
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
  notice: ({ message }) => note(message),
};

function connect() {
  socket = new WebSocket(`ws://${location.host}/ws`);
  socket.addEventListener("open", () => renderConnection(true));
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    handlers[message.t]?.(message);
  });
  socket.addEventListener("close", () => {
    renderConnection(false);
    setTimeout(connect, 1000);
  });
}

connect();
$("prompt").focus();
