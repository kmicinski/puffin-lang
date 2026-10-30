// Puffin Studio in the browser: the project's files and editor, the REPL
// transcript and prompt, the assistant, and the status strip, all fed by
// one WebSocket to the studio (studio/src/web.rs).

import { createEditor } from "./editor.js";
import { createFiles } from "./files.js";
import { createRepl } from "./repl.js";
import { initAssist } from "./assist.js";
import { createAssists } from "./assists.js";
import { createProposals } from "./proposals.js";
import { createVersions } from "./versions.js";
import { formAt, forms, lineIndex } from "./lexer.js";
import { structured } from "./paredit.js";

const $ = (id) => document.getElementById(id);
// the launch token, carried in the page's fragment
const token = location.hash.slice(1);

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

const editor = await createEditor($("editor"), {
  onChange: () => files.changed(),
  onSave: save,
  onEvalForm: evalForm,
  onLoadFile: () => load(null),
  onAssist: () => assists.open(),
});

const files = createFiles({
  editor,
  transmit,
  note,
  onOpen(path) {
    transmit({ t: "focus", file: path });
    showDiagnostics();
    proposals?.refresh();
    versions?.opened();
  },
  onTexts: () => proposals?.refresh(),
});
// every message waits behind the edits already made, so it sees them
const send = files.send;

const proposals = createProposals({ editor, files, send, bar: $("proposals") });
const versions = createVersions({ panel: $("versions"), toggle: $("history"), files, send });
const assists = createAssists({ editor, files, send, note });

const repl = createRepl({
  transcript: $("transcript"),
  prompt: $("prompt"),
  send,
  commands: {
    load,
    save,
    assist: (id, file, pos) => assists.run(id, file, pos),
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

// ⌘↵: the selection, else the top-level form at the cursor, in the session.
function evalForm() {
  const file = files.active();
  if (!file) return;
  const text = editor.get();
  const { start, end } = editor.selection();
  let from = start;
  let to = end;
  if (start === end) {
    const form = formAt(forms(text), start) ?? forms(text).findLast((f) => f.end <= start);
    if (!form) return note("no form at the cursor");
    from = form.start;
    to = form.end;
  }
  const line = lineIndex(text)(from).line;
  files.flush();
  send({ t: "eval", text: text.slice(from, to), source: "buffer", file, line });
}

// ⇧⌘↵ or ,load: a whole module, as one unit.
function load(file) {
  const target = file ?? files.active();
  if (!target) return;
  if (!files.paths().includes(target)) return note(`no file ${target}`);
  files.flush();
  send({ t: "eval", text: "", source: "file", file: target });
}

$("load").addEventListener("click", () => load(null));
$("interrupt").addEventListener("click", () => send({ t: "interrupt" }));
$("reset").addEventListener("click", () => send({ t: "reset" }));
const structuredButton = $("structured");
const renderStructured = () => {
  structuredButton.setAttribute("aria-pressed", String(structured.on));
  structuredButton.title = structured.on
    ? "Structured editing is on: brackets stay balanced. Click to type freely."
    : "Structured editing is off. Click to keep brackets balanced.";
};
structuredButton.addEventListener("click", () => { structured.set(!structured.on); renderStructured(); });
renderStructured();

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
  const top = $("editor").getBoundingClientRect().top;
  const move = (e) => document.documentElement.style.setProperty("--editor-height", `${Math.max(80, e.clientY - top)}px`);
  const up = () => { removeEventListener("pointermove", move); removeEventListener("pointerup", up); };
  addEventListener("pointermove", move);
  addEventListener("pointerup", up);
  event.preventDefault();
});

// ---- Diagnostics ------------------------------------------------------------

let reports = {};
function showDiagnostics() {
  const byFile = new Map();
  for (const report of Object.values(reports)) {
    for (const d of report.diagnostics) {
      const list = byFile.get(d.file) ?? [];
      if (!list.some((k) => k.line === d.line && k.message === d.message)) list.push(d);
      byFile.set(d.file, list);
    }
  }
  const counts = new Map();
  for (const path of files.paths()) {
    const list = byFile.get(path) ?? [];
    editor.markers(path, list);
    counts.set(path, { errors: list.filter((d) => d.severity === "error").length, warnings: list.filter((d) => d.severity === "warning").length });
  }
  files.setCounts(counts);
  const active = files.active();
  const here = byFile.get(active) ?? [];
  const errors = here.filter((d) => d.severity === "error");
  const status = $("check");
  status.className = `pill ${errors.length ? "bad" : here.length ? "warn" : "good"}`;
  status.textContent = errors.length ? `✗ ${errors.length} error${errors.length === 1 ? "" : "s"}` : here.length ? `⚠ ${here.length} warning${here.length === 1 ? "" : "s"}` : "✓ checks";
  status.title = here.map((d) => `${d.severity}: ${d.message}${d.line ? ` [line ${d.line}]` : ""}`).join("\n") || `${active ?? ""} passes the check`;
  // an error with no line in the shown file still shows
  const loose = (byFile.get("") ?? []).map((d) => d.message);
  if (loose.length) status.title += `\n${loose.join("\n")}`;
}
$("check").addEventListener("click", () => {
  const first = Object.values(reports).flatMap((r) => r.diagnostics).find((d) => d.file === files.active() && d.line);
  if (first) editor.reveal({ line: first.line });
});

// ---- The status strip -----------------------------------------------------------

function renderLane(lane) {
  const pill = $("lane");
  const words = { idle: "session: not started", starting: "session: starting…", ready: "session: ready", busy: "session: running…", failed: "session: failed" };
  pill.textContent = `${words[lane.state] ?? lane.state}${lane.mode === "replay" ? " (replay)" : ""}`;
  pill.className = `pill lane-${lane.state}`;
  pill.title = lane.detail || (lane.mode === "serve" ? "puffin-vm --serve: one live session" : "");
  $("interrupt").disabled = lane.state !== "busy";
}

function renderFeatures({ assist: hasAssist, serve }) {
  assists.setAvailable(hasAssist);
  const pill = $("features");
  pill.textContent = hasAssist ? "assists ✓" : "assists unavailable";
  pill.className = `pill ${hasAssist ? "good" : "quiet"}`;
  pill.title = `${hasAssist ? "puffincc --assist answers: ⌘. at a point, and the lightbulb" : "this puffincc has no --assist: checks are bytecode compiles, and assists wait for it"}\n${serve ? "puffin-vm --serve runs the live session" : "puffin-vm has no --serve: the session replays its units on each evaluation"}`;
}

function renderConnection(on) {
  const pill = $("connection");
  pill.textContent = on ? "connected" : "reconnecting…";
  pill.className = `pill ${on ? "good" : "bad"}`;
}

// ---- The socket -------------------------------------------------------------------

const handlers = {
  init(snapshot) {
    document.title = `${snapshot.project} — Puffin Studio`;
    $("project").textContent = snapshot.project;
    $("project").title = snapshot.directory;
    files.receive.init(snapshot);
    reports = snapshot.diagnostics;
    proposals.update(snapshot.review);
    assist.receive.review(snapshot.review);
    repl.receive.init(snapshot);
    showDiagnostics();
    renderLane(snapshot.lane);
    renderFeatures(snapshot.features);
    $("agent").hidden = !snapshot.agent_unavailable;
    $("agent").title = snapshot.agent_unavailable ?? "";
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
  type: assists.receive.type,
  versions: versions.receive.versions,
  "version-text": versions.receive["version-text"],
  version: versions.receive.version,
  notice: ({ message }) => note(message),
};

function connect() {
  socket = new WebSocket(`ws://${location.host}/ws?token=${encodeURIComponent(token)}`);
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

if (!token) {
  note("This page needs the address puffin-studio printed (it carries the launch token).");
}
connect();
$("prompt").focus();
