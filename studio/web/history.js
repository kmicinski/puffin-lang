// The project's history (studio/src/project.rs): everything that happened,
// in order and timestamped -- each settled edit (with the commit's diff a
// click away), every evaluation and its result, every question to the
// assistant and its answer, test runs, gestures, sessions. Hidden until
// asked for (the History button, `,history`); it reads the project's git
// log, so it is the whole story, not this tab's.
//
//   createHistory({ panel, send, onMoments, onJump })
//     -> { toggle, changed, load, summary, receive }
// `onMoments(list)` gets every timeline received (replay.js slides over
// it); `onJump(index)` is a click on a row's time.

const element = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

// what each kind of moment is called, and the filter it falls under
const KINDS = {
  edit: { word: "edit", group: "edits" },
  accept: { word: "accepted", group: "edits" },
  restore: { word: "restored", group: "edits" },
  disk: { word: "changed on disk", group: "edits" },
  eval: { word: "eval", group: "evals" },
  ask: { word: "asked", group: "asks" },
  test: { word: "tests", group: "evals" },
  echo: { word: "", group: "gestures" },
  session: { word: "session", group: "sessions" },
  project: { word: "project", group: "sessions" },
  commit: { word: "commit", group: "edits" },
};
const FILTERS = [
  ["all", "All"],
  ["edits", "Edits"],
  ["evals", "Evals & tests"],
  ["asks", "Asks"],
  ["gestures", "Gestures"],
  ["sessions", "Sessions"],
];

const time = (at) => new Date(at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
const day = (at) => new Date(at).toLocaleDateString([], { weekday: "short", year: "numeric", month: "short", day: "numeric" });
const formName = (key) => key.split(":").slice(2).join(":") || key.split(":").slice(1).join(":");

export function createHistory({ panel, send, onMoments, onJump }) {
  let open = false;
  let seq = 0;
  let filter = "all";
  let moments = [];
  let tracked = true;
  let error = null;
  const diffs = new Map(); // commit -> diff text, once fetched
  const expanded = new Set(); // moment indexes shown in full
  let refreshTimer = 0;

  function show(on) {
    open = on;
    panel.hidden = !on;
    if (on) request();
  }

  function request() {
    if (!open) return;
    load();
  }

  function load() {
    send({ t: "history", seq: ++seq });
  }

  // one line for a moment: what it was
  function summary(moment) {
    switch (moment.kind) {
      case "edit": {
        const forms = (moment.forms ?? []).map(formName).filter(Boolean);
        const what = forms.length ? forms.join(", ") : "text";
        return `${moment.new ? "new file " : ""}${moment.file}: ${what}`;
      }
      case "accept": return `proposal ${moment.label} into ${moment.file}`;
      case "restore": return `${moment.label} of ${moment.file}`;
      case "disk": return moment.file;
      case "eval": return moment.command || moment.line;
      case "ask": return moment.line;
      case "test": {
        const t = moment.tests;
        return t ? `${t.passed} passed${t.failed ? `, ${t.failed} failed` : ""}${t.not_run ? `, ${t.not_run} not run` : ""}` : moment.line;
      }
      case "echo": return moment.line;
      case "session": return "studio opened";
      case "project": return moment.adopted ? `${moment.name} tracked from here on` : `${moment.name} made`;
      case "commit": return moment.subject;
      default: return moment.line ?? "";
    }
  }

  function render() {
    panel.replaceChildren();
    const head = panel.appendChild(element("div", "history-head"));
    head.append(element("span", "", "History"));
    const filters = head.appendChild(element("span", "history-filters"));
    for (const [key, word] of FILTERS) {
      const chip = filters.appendChild(element("button", `chip${filter === key ? " on" : ""}`, word));
      chip.addEventListener("click", () => { filter = key; render(); });
    }
    const x = head.appendChild(element("button", "quiet small", "×"));
    x.addEventListener("click", () => show(false));
    if (error) panel.append(element("p", "hint", error));
    if (!tracked) {
      panel.append(element("p", "hint", "This project is not a repository of its own, so only this run is here. A project made from the Projects menu keeps its whole history in git."));
    }
    const shown = moments.map((m, i) => [m, i]).filter(([m]) => filter === "all" || KINDS[m.kind]?.group === filter);
    if (!shown.length) panel.append(element("p", "hint", "Nothing yet."));
    const list = panel.appendChild(element("div", "history-list"));
    let lastDay = null;
    const pending = moments.filter((m) => !m.commit).length;
    for (const [moment, index] of shown.reverse()) {
      const today = day(moment.at);
      if (today !== lastDay) {
        list.append(element("div", "history-day", today));
        lastDay = today;
      }
      const row = list.appendChild(element("div", `history-row ${moment.kind}${moment.status === "error" || moment.error ? " failed" : ""}`));
      const when = row.appendChild(element("span", "history-when", time(moment.at)));
      if (onJump) {
        when.title = "Replay: see what was on screen at this moment";
        when.classList.add("jump");
        when.addEventListener("click", (event) => { event.stopPropagation(); onJump(index); });
      }
      row.append(element("span", `history-kind ${moment.kind}`, KINDS[moment.kind]?.word ?? moment.kind));
      const what = row.appendChild(element("span", "history-what", summary(moment)));
      what.title = moment.commit ? `commit ${moment.commit.slice(0, 7)}` : "not committed yet";
      if (!moment.commit) row.append(element("span", "history-pending", "pending"));
      const detail = detailOf(moment);
      if (detail !== null) {
        row.classList.add("has-detail");
        row.addEventListener("click", () => {
          if (expanded.has(index)) expanded.delete(index);
          else {
            expanded.add(index);
            if (moment.kind === "edit" && moment.commit && !diffs.has(moment.commit)) send({ t: "history-diff", seq: ++seq, commit: moment.commit });
          }
          render();
        });
        if (expanded.has(index)) list.append(detail);
      }
    }
    if (pending) {
      panel.append(element("p", "hint", `${pending} moment${pending === 1 ? "" : "s"} not committed yet: edits settle for a moment first.`));
    }
  }

  // what a row opens to: an edit's diff, an evaluation's output, an answer
  function detailOf(moment) {
    if (moment.kind === "edit" || moment.kind === "accept" || moment.kind === "restore" || moment.kind === "commit") {
      if (!moment.commit) return null;
      const box = element("div", "history-detail");
      const diff = diffs.get(moment.commit);
      if (diff === undefined) box.append(element("span", "hint", "loading the diff…"));
      else if (!diff.trim()) box.append(element("span", "hint", "no change to the files"));
      else {
        const pre = box.appendChild(element("pre", "version-diff"));
        for (const line of diff.split("\n")) {
          if (line.startsWith("diff --git") || line.startsWith("index ") || line.startsWith("---") || line.startsWith("+++")) {
            if (line.startsWith("+++")) pre.append(element("div", "diff-file", line.slice(4).replace(/^b\//, "")));
            continue;
          }
          const kind = line.startsWith("+") ? "add" : line.startsWith("-") ? "del" : line.startsWith("@@") ? "hunk" : "same";
          pre.append(element("div", `diff-${kind}`, line));
        }
      }
      box.append(element("div", "history-commit", `commit ${moment.commit}`));
      return box;
    }
    if (moment.kind === "eval" || moment.kind === "ask" || moment.kind === "test" || moment.kind === "echo") {
      if (!moment.out && !moment.error && !moment.command) return null;
      const box = element("div", "history-detail");
      if (moment.kind === "ask") box.append(element("div", "history-question", moment.line));
      else if (moment.command && moment.command !== moment.line) box.append(element("div", "history-question", moment.line));
      if (moment.out) box.append(element("pre", "history-out", moment.out));
      if (moment.error) box.append(element("div", "history-error", moment.error));
      if (moment.ms) box.append(element("div", "hint", `${moment.ms} ms${moment.origin ? ` · from the ${moment.origin}` : ""}`));
      return box;
    }
    return null;
  }

  return {
    // the History button, ,history: shown or hidden; what the transcript says
    toggle() {
      show(!open);
      return open ? "History shows everything that happened in this project (,history again hides it)" : "History hidden";
    },
    // something happened: refresh, a little later, if shown
    changed() {
      if (!open) return;
      clearTimeout(refreshTimer);
      refreshTimer = setTimeout(request, 700);
    },
    load,
    summary,
    receive: {
      history(reply) {
        if (reply.seq !== seq) return;
        moments = reply.moments ?? [];
        tracked = reply.tracked;
        error = reply.error ?? null;
        onMoments?.(moments);
        if (open) render();
      },
      "history-diff"({ commit, diff, error: failed }) {
        diffs.set(commit, failed ? `(${failed})` : diff);
        render();
      },
    },
  };
}
