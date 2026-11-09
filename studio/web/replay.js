// Replay: a clock that hovers at the bottom left, and behind it a slider
// over the project's history (history.js, studio/src/project.rs). Drag it,
// or step with ← →, and the studio shows what a person saw at that moment:
// the files as that commit left them, read-only, over the live editor, and
// the transcript as it stood then -- the evaluations, questions and
// answers up to that time -- over the live one. Live goes on underneath,
// untouched; Live (or Esc) returns to it.
//
//   createReplay({ editor, send, history, clock, panel, past, pastTabs, pastTranscript })
//     -> { on, start, goto, receive }

const element = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

const clockText = (at) => new Date(at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
const dateText = (at) => new Date(at).toLocaleDateString([], { weekday: "short", month: "short", day: "numeric", year: "numeric" });
const TRANSCRIPT_KINDS = new Set(["eval", "ask", "test", "echo"]);

export function createReplay({ editor, send, history, clock, panel, past, pastTabs, pastTranscript }) {
  let on = false;
  let moments = []; // history's, oldest first
  let index = -1; // the slider's position among moments
  let seq = 0;
  let shownFile = null;
  const filesAt = new Map(); // commit -> { path: text } once fetched
  const waiting = new Map(); // commit -> seq
  let viewer = null; // the read-only Monaco over the editor, made on first use
  let lastEditFile = null;

  // ---- The clock ------------------------------------------------------------
  const face = clock.appendChild(element("span", "clock-face"));
  clock.title = "Replay: slide through the project's history and see what was on screen (← → step · Esc returns)";
  function tick() {
    if (!on) face.textContent = clockText(Date.now());
  }
  tick();
  setInterval(tick, 1000);
  clock.addEventListener("click", () => (on ? stop() : start()));

  // ---- The slider panel --------------------------------------------------------
  const slider = element("input", "replay-slider");
  slider.type = "range";
  slider.min = 0;
  slider.step = 1;
  const big = element("div", "replay-clock");
  const date = element("div", "replay-date");
  const what = element("div", "replay-what");
  const back = element("button", "quiet small", "◀");
  const forward = element("button", "quiet small", "▶");
  const live = element("button", "btn small", "Live");
  live.title = "Back to now (Esc)";
  const row = element("div", "replay-row");
  row.append(back, slider, forward, live);
  panel.append(big, date, what, row);
  slider.addEventListener("input", () => goto(Number(slider.value)));
  back.addEventListener("click", () => goto(index - 1));
  forward.addEventListener("click", () => goto(index + 1));
  live.addEventListener("click", stop);
  document.addEventListener("keydown", (event) => {
    if (!on) return;
    if (event.key === "Escape") { event.preventDefault(); stop(); }
    else if (event.key === "ArrowLeft" && !inField(event)) { event.preventDefault(); goto(index - 1); }
    else if (event.key === "ArrowRight" && !inField(event)) { event.preventDefault(); goto(index + 1); }
  });
  const inField = (event) => /^(INPUT|TEXTAREA)$/.test(event.target?.tagName) && event.target !== slider;

  function start(at = moments.length - 1) {
    on = true;
    clock.classList.add("on");
    panel.hidden = false;
    past.hidden = false;
    pastTranscript.hidden = false;
    if (!moments.length) {
      what.textContent = "loading the history…";
      history.load();
    }
    goto(at);
  }

  function stop() {
    on = false;
    clock.classList.remove("on");
    panel.hidden = true;
    past.hidden = true;
    pastTranscript.hidden = true;
    tick();
    editor.focus();
  }

  // Show moment `i`: its clock, the files as of its commit, the transcript
  // up to it.
  function goto(i) {
    if (!moments.length) return;
    index = Math.max(0, Math.min(moments.length - 1, i));
    slider.max = moments.length - 1;
    slider.value = index;
    const moment = moments[index];
    face.textContent = clockText(moment.at);
    big.textContent = clockText(moment.at);
    date.textContent = dateText(moment.at);
    what.textContent = `${index + 1} of ${moments.length} · ${history.summary(moment)}`;
    back.disabled = index === 0;
    forward.disabled = index === moments.length - 1;
    // the files: this moment's commit, else the latest commit before it
    const commit = [...moments.slice(0, index + 1)].reverse().find((m) => m.commit)?.commit ?? null;
    lastEditFile = [...moments.slice(0, index + 1)].reverse().find((m) => m.file)?.file ?? lastEditFile;
    renderFiles(commit);
    renderTranscript();
  }

  function renderFiles(commit) {
    if (!commit) {
      pastTabs.replaceChildren(element("span", "hint", "nothing committed yet at this moment"));
      viewerText("");
      return;
    }
    const files = filesAt.get(commit);
    if (!files) {
      if (!waiting.has(commit)) {
        waiting.set(commit, ++seq);
        send({ t: "files-at", seq, commit });
      }
      pastTabs.replaceChildren(element("span", "hint", "loading…"));
      return;
    }
    const paths = Object.keys(files).sort((a, b) => (a === "main.puf" ? -1 : b === "main.puf" ? 1 : a.localeCompare(b)));
    if (!paths.includes(shownFile)) shownFile = paths.includes(lastEditFile) ? lastEditFile : paths[0] ?? null;
    if (lastEditFile && paths.includes(lastEditFile) && moments[index]?.file === lastEditFile) shownFile = lastEditFile;
    pastTabs.replaceChildren(
      element("span", "past-badge", "then"),
      ...paths.map((path) => {
        const tab = element("button", `file-tab${path === shownFile ? " active" : ""}`, path);
        tab.addEventListener("click", () => { shownFile = path; renderFiles(commit); });
        return tab;
      }),
    );
    viewerText(shownFile ? files[shownFile] ?? "" : "");
  }

  // The read-only editor over the live one: Monaco when the live editor is
  // Monaco (same language and theme), else a <pre>.
  function viewerText(text) {
    const raw = editor.raw;
    if (raw && !viewer) {
      const { monaco } = raw;
      viewer = monaco.editor.create(past.querySelector(".past-editor"), {
        value: "",
        language: "puffin",
        theme: "puffin-solarized",
        readOnly: true,
        automaticLayout: true,
        minimap: { enabled: false },
        folding: false,
        scrollBeyondLastLine: false,
        fontFamily: "\"JetBrains Mono\", \"SF Mono\", Menlo, Consolas, monospace",
        fontSize: 14,
        tabSize: 2,
        glyphMargin: true,
        lineDecorationsWidth: 14,
        renderLineHighlight: "none",
        occurrencesHighlight: "off",
        padding: { top: 8 },
        domReadOnly: true,
      });
    }
    if (viewer) {
      if (viewer.getValue() !== text) viewer.setValue(text);
    } else {
      let pre = past.querySelector("pre");
      if (!pre) pre = past.querySelector(".past-editor").appendChild(element("pre", "past-plain"));
      pre.textContent = text;
    }
  }

  // The transcript as it stood: each evaluation, question and gesture up to
  // this moment, the latest last, as the live one draws them.
  function renderTranscript() {
    pastTranscript.replaceChildren();
    const head = pastTranscript.appendChild(element("div", "pane-title past-title"));
    head.append("Output ", element("span", "past-badge", "then"));
    const shown = moments.slice(0, index + 1).filter((m) => TRANSCRIPT_KINDS.has(m.kind));
    if (!shown.length) pastTranscript.append(element("div", "welcome", "Nothing had been evaluated yet."));
    for (const m of shown) {
      const entry = pastTranscript.appendChild(element("div", `entry ${m.kind}${m.origin ? ` ${m.origin}` : ""}${m.status === "error" ? " failed" : ""}`));
      const line = entry.appendChild(element("div", "line"));
      if (m.kind === "ask") line.append(element("span", "ask-mark", "?? "), element("span", "code", m.line ?? ""));
      else line.append(element("span", "code", m.command || m.line || ""));
      line.append(element("span", "ms", clockText(m.at)));
      if (m.out) entry.append(element("pre", m.kind === "ask" ? "answer" : "", m.out));
      if (m.error) entry.append(element("pre", "err", m.error));
    }
    pastTranscript.scrollTop = pastTranscript.scrollHeight;
  }

  return {
    on: () => on,
    start,
    goto,
    stop,
    // history.js gives its moments whenever it has them
    moments(list) {
      moments = list;
      if (on) goto(index < 0 ? list.length - 1 : index);
    },
    receive: {
      "files-at"({ commit, files, error }) {
        waiting.delete(commit);
        filesAt.set(commit, error ? {} : files);
        if (error) what.textContent = error;
        if (on) goto(index);
      },
    },
  };
}
