// What happened (docs/VOICE.md §3): the trace of a voice session, in the
// left margin the centered editor leaves. Each thing the author said opens
// an exchange (their words, what the router did with them, the reply);
// each builder run is a turn under it, its steps in order as they happen:
// the builder's one-line notes of what it is about to do and why, each
// read, each edit (a click shows the lines; ▾ the new code), each check,
// run, property and lookup, with how it went. The newest turn is open;
// older ones fold to a line, and open again on a click. A live line at
// the foot says what the builder is doing now.

import { markdown } from "./markdown.js";
import { el } from "./dom.js";

const ICON = {
  edit: "✎", write_file: "✎", delete_file: "✕", add_property: "≡", run_properties: "≡",
  check: "✓", get_file: "◱", list_files: "◱", evaluate: "▸", evaluate_program: "▸", trace: "▸",
  research: "⌕", search_docs: "?", read_doc: "?", type_at: "τ", facts_at: "τ", holes: "◌", assists_at: "◇", lint: "◇",
};
const EDITS = new Set(["edit", "write_file", "add_property"]);
const STORE = "puffin-timeline";

const seconds = (ms) => (ms < 1000 ? `${ms} ms` : ms < 60000 ? `${Math.round(ms / 100) / 10}s` : `${Math.floor(ms / 60000)}m ${Math.round((ms % 60000) / 1000)}s`);

export function createTimeline({ host, go }) {
  let collapsed = false;
  try { collapsed = localStorage.getItem(STORE) === "collapsed"; } catch { /* default */ }

  const box = el("div", "timeline voice-float");
  const head = el("div", "timeline-head");
  const title = el("span", "timeline-title", "What happened");
  const fold = el("button", "voice-x", "‹");
  fold.title = "Hide (say “hide history”)";
  fold.addEventListener("click", () => setCollapsed(true));
  head.append(title, fold);
  const list = el("div", "timeline-list");
  const live = el("div", "timeline-live");
  live.hidden = true;
  box.append(head, list, live);
  const tab = el("button", "timeline-tab", "History ›");
  tab.title = "What happened (say “show history”)";
  tab.addEventListener("click", () => {
    if (!room) forced = true;
    setCollapsed(false);
  });
  host.append(box, tab);

  let exchange = null; // the latest thing said: { node, meta }
  const turns = new Map(); // turn -> { node, steps, header, status, counts, open }
  const steps = new Map(); // tool call id -> { row, mark, turn, tool, file }
  const lastEdit = new Map(); // turn -> the step row of its latest edit call
  let any = false;

  // the margin is too narrow to hold it without covering the code: folded
  // to its tab (the author's own choice, open or folded, is kept for when
  // there is room); a click on the tab opens it anyway, until it fits again
  let room = true;
  let forced = false;
  function render() {
    const open = !collapsed && (room || forced);
    box.hidden = !open || !any;
    tab.hidden = open || !any;
  }
  function setCollapsed(value) {
    if (value) forced = false;
    collapsed = value;
    try { localStorage.setItem(STORE, value ? "collapsed" : "open"); } catch { /* fine */ }
    render();
    if (!value) scroll(true);
  }

  // keep the newest in view, unless the author scrolled up to read
  let pinned = true;
  list.addEventListener("scroll", () => { pinned = list.scrollTop + list.clientHeight >= list.scrollHeight - 30; });
  function scroll(force = false) {
    if (force || pinned) list.scrollTop = list.scrollHeight;
  }

  function add(node) {
    any = true;
    list.append(node);
    while (list.childElementCount > 400) list.firstChild.remove();
    render();
    scroll();
    return node;
  }

  // the turn's step list, made if a step came before its turn did
  function turnOf(id) {
    if (!turns.has(id)) startTurn({ turn: id, instructions: [] });
    return turns.get(id);
  }

  function summarize(turn) {
    const { counts } = turn;
    const parts = [];
    if (counts.edits) parts.push(`${counts.edits} edit${counts.edits === 1 ? "" : "s"}`);
    if (counts.steps - counts.edits) parts.push(`${counts.steps - counts.edits} step${counts.steps - counts.edits === 1 ? "" : "s"}`);
    if (counts.failed) parts.push(`${counts.failed} failed`);
    return parts.join(" · ");
  }

  function setOpen(turn, open) {
    turn.open = open;
    turn.node.classList.toggle("open", open);
    turn.summary.textContent = open ? "" : summarize(turn);
  }

  function startTurn({ turn: id, instructions = [], interrupted }) {
    if (turns.has(id)) return turns.get(id);
    // the older turns fold: the newest is the one being watched
    for (const other of turns.values()) if (other.open && other.status.dataset.state !== "running") setOpen(other, false);
    const node = el("div", "timeline-turn open");
    const header = el("button", "timeline-turn-head");
    const automatic = instructions.length === 1 && instructions[0].startsWith("(Automatic");
    const label = automatic ? "fixing the failing properties" : instructions.map((i) => i.split("\n")[0]).join(" · ") || "working";
    header.append(el("span", "timeline-turn-who", "builder"), el("span", "timeline-turn-what", label));
    const status = el("span", "timeline-status running", interrupted ? "redirected" : "working");
    status.dataset.state = "running";
    const summary = el("span", "timeline-summary");
    header.append(status, summary);
    const stepsBox = el("div", "timeline-steps");
    node.append(header, stepsBox);
    const turn = { node, steps: stepsBox, header, status, summary, counts: { steps: 0, edits: 0, failed: 0 }, open: true };
    header.addEventListener("click", () => setOpen(turn, !turn.open));
    turns.set(id, turn);
    add(node);
    return turn;
  }

  function stepRow(turnId, className, icon, text) {
    const turn = turnOf(turnId);
    const row = el("div", `timeline-step ${className}`);
    const mark = el("span", "timeline-mark", icon);
    const body = el("div", "timeline-body");
    const line = el("div", "timeline-line");
    line.append(el("span", "timeline-text", text));
    body.append(line);
    row.append(mark, body);
    turn.steps.append(row);
    any = true;
    render();
    scroll();
    return { row, mark, body, line, turn };
  }

  return {
    // the author said `text`
    you(text, local = false) {
      const node = el("div", `timeline-you${local ? " local" : ""}`);
      node.append(el("span", "timeline-who", "you"), el("span", "timeline-said", text));
      const meta = el("div", "timeline-meta");
      node.append(meta);
      exchange = { node, meta };
      add(node);
      if (local) meta.textContent = "done here";
    },
    // what the router made of it
    routed(did, ms) {
      if (!exchange) return;
      exchange.meta.textContent = `${did.length ? did.join(" · ") : "kept: waiting for the rest"} · ${seconds(ms)}`;
    },
    reply(text, fromBuilder) {
      const node = el("div", `timeline-reply${fromBuilder ? " builder" : ""}`);
      node.append(el("span", "timeline-who", fromBuilder ? "builder" : "studio"), el("span", "timeline-said", text));
      add(node);
    },
    // a navigation's result, as a way back to it
    focus(label, targets, again) {
      if (!exchange) return;
      const link = el("button", "timeline-focus", `→ ${label}${targets.length > 1 ? ` (${targets.length} places)` : ""}`);
      link.addEventListener("click", again);
      exchange.node.append(link);
      scroll();
    },
    error(text) {
      add(el("div", "timeline-error", text));
    },
    turn: startTurn,
    // the builder's note of what it is doing and why
    note(turnId, text) {
      const turn = turnOf(turnId);
      const node = el("div", "timeline-note");
      node.innerHTML = markdown(text);
      turn.steps.append(node);
      any = true;
      render();
      scroll();
    },
    step({ turn: turnId, id, tool, text, file, input }) {
      const made = stepRow(turnId, "running", ICON[tool] ?? "·", text);
      if (input) made.body.append(el("div", "timeline-input", input));
      made.turn.counts.steps++;
      steps.set(id, { ...made, tool, file });
      if (EDITS.has(tool)) lastEdit.set(turnId, id);
    },
    stepDone({ id, ok, summary }) {
      const step = steps.get(id);
      if (!step) return;
      step.row.classList.remove("running");
      step.row.classList.add(ok ? "ok" : "bad");
      if (!ok) step.turn.counts.failed++;
      if (summary) step.body.append(el("div", `timeline-outcome${ok ? "" : " bad"}`, summary));
      if (!step.turn.open) step.turn.summary.textContent = summarize(step.turn);
      scroll();
    },
    // an edit landed: its lines, a way to them, and the code
    edited({ turn: turnId, file, from, to, note, code }) {
      const id = lastEdit.get(turnId);
      let step = id && steps.get(id);
      if (!step || (step.file && step.file !== file) || step.lines) {
        const made = stepRow(turnId ?? 0, "ok", "✎", note || `edited ${file}`);
        made.turn.counts.steps++;
        step = made;
      }
      step.lines = true;
      step.turn.counts.edits++;
      const where = el("button", "timeline-where", `${file}:${from}${to > from ? `–${to}` : ""}`);
      where.title = "Show these lines";
      where.addEventListener("click", () => go(file, from, to));
      step.line.append(where);
      if (code) {
        const more = el("button", "timeline-more", "▾");
        more.title = "The new code";
        const pre = el("pre", "timeline-code", code);
        pre.hidden = true;
        more.addEventListener("click", () => {
          pre.hidden = !pre.hidden;
          more.textContent = pre.hidden ? "▾" : "▴";
        });
        step.line.append(more);
        step.body.append(pre);
      }
      scroll();
    },
    turnEnd({ turn: turnId, ms, outcome }) {
      const turn = turns.get(turnId);
      if (!turn) return;
      turn.status.className = `timeline-status ${outcome}`;
      turn.status.dataset.state = outcome;
      turn.status.textContent = `${{ done: "done", interrupted: "redirected", stopped: "stopped", failed: "failed" }[outcome] ?? outcome} · ${seconds(ms)}`;
      for (const step of steps.values()) {
        if (step.turn === turn && step.row.classList.contains("running")) step.row.classList.replace("running", "cut");
      }
    },
    // what the builder is doing this moment
    activity(a) {
      const state = a?.state ?? "idle";
      live.hidden = state === "idle";
      const words = { starting: "starting…", thinking: "thinking…", working: "working…", talking: "writing a note…", queued: "will do that next", redirecting: "taking the new instruction…" };
      live.textContent = a?.text && state === "working" ? `${a.text}…` : words[state] ?? state;
    },
    clear() {
      list.replaceChildren();
      turns.clear();
      steps.clear();
      lastEdit.clear();
      exchange = null;
      any = false;
      render();
    },
    show() {
      if (!room) forced = true;
      setCollapsed(false);
    },
    hide() { setCollapsed(true); },
    toggle() { setCollapsed(!collapsed); },
    // whether the left margin holds it beside the code
    setRoom(value) {
      if (value === room) return;
      room = value;
      if (room) forced = false;
      render();
    },
    collapsed: () => collapsed,
  };
}
