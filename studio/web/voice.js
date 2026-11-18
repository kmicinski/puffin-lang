// Voice mode (docs/VOICE.md; the server side is studio/src/voice.rs).
//
// The browser listens continuously (the Web Speech API: Chrome, Edge,
// Safari) and sends each finished phrase to the studio, with what the author
// is looking at: the shown file, the cursor, the word under the mouse. The
// studio routes it (navigate, build, control) and answers with events:
//   heard / routed / reply   the conversation, spoken replies aloud
//   focus                    places to look: the editor moves there
//   edited                   the builder changed lines: the view follows
//   activity                 what the builder is doing now
//   properties               the spec's status
//   client                   a command for this tab (next, mute, sleep, ...)
// A few phrases never leave the tab, so they are instant: "line 40",
// "next", "previous", "back", "stop", "undo", "scroll down".
//
// The screen is the editor, alone and centered. Everything else shows only
// while it matters: the caption while something is being said, the
// builder's status while it works, the places a search found while there
// is more than one, the properties once there are any (opened by
// themselves only when one starts failing). The rest -- the conversation,
// the toggles -- is behind the ⋯ menu.

import { markdown } from "./markdown.js";

const STORE = "puffin-voice";
// after the author moves the view, the builder's edits do not pull it away
const USER_HOLD_MS = 8000;
const HOVER_FRESH_MS = 15000;
// how long a caption or a reply stays on screen
const CAPTION_MS = 7000;
// how long a list of places stays without being used
const LENS_IDLE_MS = 45000;

function load() {
  try { return JSON.parse(localStorage.getItem(STORE) || "{}"); } catch { return {}; }
}
function store(value) {
  try { localStorage.setItem(STORE, JSON.stringify(value)); } catch { /* private window */ }
}

const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

// A word of Puffin at `column` of `line`: an atom's characters.
function wordAt(line, column) {
  const atom = /[^\s()[\]{}"';`,]/;
  let start = column - 1;
  let end = column - 1;
  if (!atom.test(line[start] ?? "")) start = end = column - 2;
  if (!atom.test(line[start] ?? "")) return "";
  while (start > 0 && atom.test(line[start - 1])) start--;
  while (end < line.length - 1 && atom.test(line[end + 1])) end++;
  return line.slice(start, end + 1);
}

export function createVoice({ editor, files, send, note, button, stage, layout, run }) {
  const saved = load();
  const settings = { speak: saved.speak ?? true, follow: saved.follow ?? true };
  let on = false;
  let listening = false;
  let speaking = false;
  let recognition = null;
  let lastUserMove = 0;
  let hover = null; // { file, line, word, at }
  let lens = { label: "", targets: [], index: -1 };
  let lensTimer = 0;
  let backStack = [];
  let properties = { properties: [] };
  let failingBefore = new Set();
  let busy = false;
  let captionTimer = 0;

  // ---- What is on the screen ---------------------------------------------------------

  // the properties: a badge once there are any, a list when asked or failing
  const badge = el("button", "voice-badge");
  badge.hidden = true;
  const propCard = el("div", "voice-props voice-float");
  propCard.hidden = true;
  badge.addEventListener("click", () => { propCard.hidden = !propCard.hidden; });

  // the places a search found, when there is more than one
  const lensCard = el("div", "voice-lens voice-float");
  lensCard.hidden = true;

  // the conversation, only when asked for
  const talkCard = el("div", "voice-talk voice-float");
  talkCard.hidden = true;
  const talkList = el("div", "voice-talk-list");
  const talkHead = el("div", "voice-card-head");
  const talkClose = el("button", "voice-x", "✕");
  talkClose.addEventListener("click", () => { talkCard.hidden = true; });
  talkHead.append(el("span", "", "Conversation"), talkClose);
  talkCard.append(talkHead, talkList);

  // the pill at the foot: the microphone, the caption, the builder while it works
  const pill = el("div", "voice-pill");
  const mic = el("button", "voice-mic");
  mic.addEventListener("click", () => (listening ? stopListening() : startListening()));
  const caption = el("div", "voice-caption");
  const typed = el("input", "voice-typed");
  typed.placeholder = "Describe what you want to build";
  typed.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && typed.value.trim()) {
      utter(typed.value.trim());
      typed.value = "";
    }
    if (event.key === "Escape") {
      typed.blur();
      closeCards();
    }
    event.stopPropagation();
  });
  const activity = el("div", "voice-activity");
  activity.hidden = true;
  const stopButton = el("button", "voice-stop", "Stop");
  stopButton.hidden = true;
  stopButton.title = "Stop the builder (say “stop”)";
  stopButton.addEventListener("click", () => control("stop"));
  const more = el("button", "voice-more", "⋯");
  more.title = "More";
  const menu = el("div", "voice-menu voice-float");
  menu.hidden = true;
  more.addEventListener("click", (event) => {
    event.stopPropagation();
    menu.hidden = !menu.hidden;
    if (!menu.hidden) renderMenu();
  });
  document.addEventListener("click", (event) => {
    if (!menu.contains(event.target)) menu.hidden = true;
  });
  pill.append(mic, caption, typed, activity, stopButton, more);

  // the badge lives in the focused layout's bar (focus.js)
  layout.slot.append(badge);
  // on the canvas the pill asks for a description; after, for anything
  layout.onCanvas = (mode) => {
    const talk = listening ? "" : " (click ○ to talk)";
    typed.placeholder = mode ? `Describe what you want to build${talk}` : `Speak, or type here${talk}`;
  };
  const layer = el("div", "voice-layer");
  layer.hidden = true;
  // the right-hand rail: what has accumulated, stacked
  const rail = el("div", "voice-rail");
  rail.append(propCard, lensCard, talkCard);
  layer.append(rail, menu, pill);
  stage.append(layer);

  function renderMenu() {
    menu.replaceChildren();
    const item = (label, action, checked) => {
      const row = el("button", `voice-menu-item${checked ? " checked" : ""}`, label);
      row.addEventListener("click", () => { menu.hidden = true; action(); });
      menu.append(row);
    };
    item("Follow the builder's edits", () => setFollow(!settings.follow), settings.follow);
    item("Speak replies aloud", () => setSpeak(!settings.speak), settings.speak);
    item("Undo the builder's last edit", () => control("undo"));
    item("Run the program", () => run());
    item("Output", () => layout.showOutput(true));
    item("Run the properties", () => control("run-properties"));
    item("Conversation", () => { talkCard.hidden = false; talkList.scrollTop = talkList.scrollHeight; });
    item("Start a new conversation", () => control("new-conversation"));
    item("Show all panes", () => toggle(false));
  }

  function setFollow(value) {
    settings.follow = value;
    store({ ...load(), follow: value });
  }
  function setSpeak(value) {
    settings.speak = value;
    store({ ...load(), speak: value });
    if (!value) window.speechSynthesis?.cancel();
  }

  // A line under the editor: what was heard, what came back. It fades.
  function show(text, kind = "") {
    caption.textContent = text;
    caption.className = `voice-caption ${kind}`;
    clearTimeout(captionTimer);
    if (text) captionTimer = setTimeout(() => { caption.textContent = ""; caption.className = "voice-caption"; }, CAPTION_MS);
  }

  // ---- The editor: hover, flashes, moving the view --------------------------------

  const monaco = editor.raw?.monaco;
  const view = editor.raw?.editor;
  if (view) {
    view.onMouseMove((event) => {
      const position = event.target?.position;
      if (!position) return;
      const model = view.getModel();
      const text = model.getLineContent(position.lineNumber);
      hover = { file: files.active(), line: position.lineNumber, word: wordAt(text, position.column), at: Date.now() };
    });
    // the author's own moves hold the view for a while
    view.onMouseDown(() => { lastUserMove = Date.now(); });
    view.onKeyDown(() => { lastUserMove = Date.now(); });
  }

  function flash(from, to, className = "voice-flash") {
    if (!view || !monaco) return;
    const model = view.getModel();
    if (!model) return;
    const last = model.getLineCount();
    const range = new monaco.Range(Math.min(from, last), 1, Math.min(Math.max(to, from), last), 1);
    const ids = model.deltaDecorations([], [{ range, options: { isWholeLine: true, className, linesDecorationsClassName: `${className}-gutter` } }]);
    setTimeout(() => model.deltaDecorations(ids, []), 2600);
  }

  function here() {
    return { file: files.active(), line: view?.getPosition()?.lineNumber ?? 1 };
  }

  // Show `file` at `line`, with a flash where it landed.
  function go(file, line, to = line, className) {
    if (!files.paths().includes(file)) return note(`no file ${file}`);
    if (files.active() !== file) files.open(file);
    if (view) {
      view.revealLineInCenter(line);
      view.setPosition({ lineNumber: line, column: 1 });
    } else {
      editor.reveal({ line });
    }
    flash(line, to, className);
  }

  // ---- The places a search found ----------------------------------------------------------

  function renderLens() {
    clearTimeout(lensTimer);
    lensCard.hidden = lens.targets.length < 2;
    if (lensCard.hidden) return;
    lensTimer = setTimeout(() => { lensCard.hidden = true; }, LENS_IDLE_MS);
    lensCard.replaceChildren();
    const head = el("div", "voice-card-head");
    const close = el("button", "voice-x", "✕");
    close.title = "Close (Esc)";
    close.addEventListener("click", () => { lensCard.hidden = true; });
    head.append(el("span", "", `${lens.label} · ${lens.index + 1} of ${lens.targets.length}`), close);
    lensCard.append(head);
    const list = el("div", "voice-lens-list");
    let lastFile = null;
    lens.targets.forEach((target, index) => {
      if (target.file !== lastFile) {
        list.append(el("div", "voice-lens-file", target.file));
        lastFile = target.file;
      }
      const row = el("button", `voice-lens-row ${target.role ?? ""}${index === lens.index ? " current" : ""}`);
      row.append(el("span", "voice-lens-n", String(target.line)), el("span", "voice-lens-code", target.text ?? ""));
      row.addEventListener("click", () => step(index - lens.index, true));
      list.append(row);
    });
    lensCard.append(list, el("div", "voice-card-hint", "“next” · “previous” · “back”"));
    list.querySelector(".current")?.scrollIntoView({ block: "nearest" });
  }

  function focus(label, targets, fromBuilder) {
    if (!targets?.length) return;
    backStack.push(here());
    if (backStack.length > 50) backStack.shift();
    lens = { label, targets, index: 0 };
    if (!fromBuilder) lastUserMove = Date.now();
    renderLens();
    go(targets[0].file, targets[0].line, targets[0].line, "voice-focus");
  }

  function step(delta, user = true) {
    if (!lens.targets.length) return;
    lens.index = (lens.index + delta + lens.targets.length) % lens.targets.length;
    if (user) lastUserMove = Date.now();
    const target = lens.targets[lens.index];
    renderLens();
    go(target.file, target.line, target.line, "voice-focus");
  }

  function back() {
    const place = backStack.pop();
    if (place) {
      lastUserMove = Date.now();
      go(place.file, place.line);
    }
  }

  // ---- Properties ---------------------------------------------------------------------

  function renderProperties() {
    const list = properties.properties ?? [];
    const failing = list.filter((p) => p.status !== "ok" && p.status !== "pending");
    badge.hidden = !list.length && !properties.error;
    badge.className = `voice-badge${failing.length || properties.error ? " bad" : ""}`;
    badge.textContent = properties.error
      ? "properties don't run"
      : failing.length
        ? `✗ ${failing.length} of ${list.length} ${list.length === 1 ? "property" : "properties"} failing`
        : `✓ ${list.length} ${list.length === 1 ? "property" : "properties"}`;
    badge.title = "The properties (say “run the properties”)";
    propCard.replaceChildren();
    const head = el("div", "voice-card-head");
    const close = el("button", "voice-x", "✕");
    close.addEventListener("click", () => { propCard.hidden = true; });
    head.append(el("span", "", "Properties"), close);
    propCard.append(head);
    if (properties.error) propCard.append(el("div", "voice-prop-error", properties.error));
    for (const property of list) {
      const row = el("button", `voice-prop ${property.status}`);
      const mark = { ok: "✓", fail: "✗", crashed: "!", "not-run": "·", pending: "…" }[property.status] ?? "?";
      const line = el("span", "voice-prop-top");
      line.append(el("span", "voice-prop-mark", mark), el("span", "voice-prop-text", property.statement || property.name));
      row.append(line);
      if (property.detail && property.status !== "ok") row.append(el("span", "voice-prop-detail", property.detail));
      row.title = property.name;
      row.addEventListener("click", () => property.line && go("properties.puf", property.line));
      propCard.append(row);
    }
    // open by itself only when something starts failing
    const now = new Set(failing.map((p) => p.name));
    if ([...now].some((name) => !failingBefore.has(name)) || (properties.error && !failingBefore.has("#error"))) propCard.hidden = false;
    if (!failing.length && !properties.error) propCard.hidden = true;
    failingBefore = properties.error ? new Set([...now, "#error"]) : now;
  }

  // ---- The conversation (behind ⋯) -------------------------------------------------------

  function log(kind, text, extra) {
    const row = el("div", `voice-line ${kind}`);
    const who = { author: "you", studio: "studio", builder: "builder", error: "!", local: "you" }[kind] ?? "";
    if (who) row.append(el("span", "voice-who", who));
    const body = el(kind === "builder" ? "div" : "span", "voice-text");
    // the builder writes Markdown (names in backticks, short lists)
    if (kind === "builder") body.innerHTML = markdown(text);
    else body.textContent = text;
    row.append(body);
    if (extra) row.append(el("span", "voice-extra", extra));
    talkList.append(row);
    while (talkList.childElementCount > 300) talkList.firstChild.remove();
    talkList.scrollTop = talkList.scrollHeight;
  }

  function speak(text) {
    if (!settings.speak || !window.speechSynthesis || !text) return;
    const words = new SpeechSynthesisUtterance(text);
    words.rate = 1.1;
    speaking = true;
    // the microphone would hear it: pause listening while the studio talks
    recognition?.abort();
    words.onend = words.onerror = () => {
      speaking = false;
      if (listening) restart();
    };
    speechSynthesis.speak(words);
  }

  function renderActivity(a) {
    const state = a?.state ?? "idle";
    busy = state !== "idle";
    activity.hidden = !busy;
    stopButton.hidden = !busy;
    const words = { starting: "starting", thinking: "thinking", working: "working", talking: "writing", queued: "queued", redirecting: "redirecting" };
    activity.textContent = a?.text || words[state] || state;
    activity.className = `voice-activity ${state}`;
  }

  // ---- Listening ---------------------------------------------------------------------------

  const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;

  function renderMic() {
    store({ ...load(), listening });
    layout.onCanvas?.(layout.canvasMode());
    mic.classList.toggle("live", listening);
    mic.title = listening ? "Listening — click to pause (or say “stop listening”)" : "Paused — click to listen";
  }

  function startListening() {
    if (!Recognition) {
      show("No speech recognition in this browser (Chrome, Edge or Safari have it): type instead.", "quiet");
      typed.focus();
      return;
    }
    listening = true;
    renderMic();
    if (!recognition) {
      recognition = new Recognition();
      recognition.continuous = true;
      recognition.interimResults = true;
      recognition.lang = navigator.language || "en-US";
      recognition.onresult = (event) => {
        let interim = "";
        for (let i = event.resultIndex; i < event.results.length; i++) {
          const result = event.results[i];
          if (result.isFinal) utter(result[0].transcript.trim());
          else interim += result[0].transcript;
        }
        if (interim) show(interim, "interim");
      };
      recognition.onerror = (event) => {
        if (event.error === "not-allowed" || event.error === "service-not-allowed") {
          stopListening();
          show("The microphone is blocked: allow it for this site, then click the dot.", "bad");
        }
      };
      // recognizers stop on silence: start again while listening
      recognition.onend = () => { if (listening && !speaking) restart(); };
    }
    restart();
  }

  function restart() {
    if (!listening || speaking || !recognition) return;
    try { recognition.start(); } catch { /* already started */ }
  }

  function stopListening() {
    listening = false;
    renderMic();
    recognition?.abort();
  }

  // ---- An utterance ---------------------------------------------------------------------

  const NUMBERS = { one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10, for: 4, to: 2, too: 2 };

  // what never needs the server
  function local(text) {
    const said = text.toLowerCase().replace(/[.,!?]/g, "").trim();
    let m = said.match(/^(?:go to |jump to |show )?line (\w+)$/);
    if (m) {
      const n = Number(m[1]) || NUMBERS[m[1]];
      if (n) {
        lastUserMove = Date.now();
        backStack.push(here());
        go(files.active(), n, n, "voice-focus");
        return true;
      }
    }
    if (/^(next|next one|next usage|next result)$/.test(said)) return step(1), true;
    if (/^(previous|previous one|back one|last one)$/.test(said)) return step(-1), true;
    if (/^(go back|back)$/.test(said)) return back(), true;
    if (/^(stop|stop it|stop building|cancel|hold on)$/.test(said)) return control("stop"), true;
    if (/^(undo|undo that)$/.test(said)) return control("undo"), true;
    if (/^(stop listening|go to sleep|sleep)$/.test(said)) return stopListening(), true;
    if (/^(mute|be quiet|quiet)$/.test(said)) return setSpeak(false), true;
    if (/^(unmute|talk to me)$/.test(said)) return setSpeak(true), true;
    if (/^(close|close that|dismiss|clear)$/.test(said)) return closeCards(), true;
    if (/^(show (the )?conversation|what did you say)$/.test(said)) return (talkCard.hidden = false), true;
    if (/^(show (the )?properties)$/.test(said)) return (propCard.hidden = false), true;
    if (/^(run|run it|run the program|run this)$/.test(said)) return run(), true;
    if (/^(show (the )?(output|repl))$/.test(said)) return layout.showOutput(true), true;
    if (/^(hide (the )?(output|repl)|close (the )?(output|repl))$/.test(said)) return layout.showOutput(false), true;
    m = said.match(/^scroll (up|down)$/);
    if (m && view) {
      const lines = view.getVisibleRanges()[0];
      const height = lines ? lines.endLineNumber - lines.startLineNumber : 30;
      view.setScrollTop(view.getScrollTop() + (m[1] === "down" ? 1 : -1) * height * 0.6 * 19);
      lastUserMove = Date.now();
      return true;
    }
    return false;
  }

  function closeCards() {
    for (const card of [lensCard, propCard, talkCard, menu]) card.hidden = true;
  }

  function context() {
    const position = view?.getPosition();
    const selection = view?.getSelection();
    const model = view?.getModel();
    const selected = selection && model && !selection.isEmpty() ? model.getValueInRange(selection).slice(0, 2000) : null;
    const visible = view?.getVisibleRanges()?.[0];
    return {
      file: files.active(),
      line: position?.lineNumber,
      hover: hover && Date.now() - hover.at < HOVER_FRESH_MS ? { file: hover.file, line: hover.line, word: hover.word } : null,
      selection: selected,
      visible: visible ? [visible.startLineNumber, visible.endLineNumber] : null,
    };
  }

  // A name for a project from what it was described as: its few telling
  // words ("scaffold me a CESK star machine" -> cesk-star-machine).
  const FILLER = new Set("a an the me my us we i you it this that these please can could would will should let lets let's make build write create scaffold start set up give implement implements implementing project program app application thing something which with from for of in on to and or by using use like want need some simple small little new called named".split(" "));
  function projectName(text) {
    const words = text.toLowerCase().replace(/[^a-z0-9\s-]/g, " ").split(/\s+/).filter((w) => w && !FILLER.has(w));
    return words.slice(0, 3).join("-").slice(0, 32) || null;
  }

  // the description that is making a new project, said again once it is open
  const PENDING = "puffin-voice-pending";
  let naming = null; // the name asked for, while the studio makes the project

  function startProject(text) {
    try { sessionStorage.setItem(PENDING, text); } catch { /* no session storage: it is said again by hand */ }
    naming = projectName(text);
    layout.started();
    show("Starting a new project…", "reply");
    send({ t: "new-project", name: naming });
  }

  // a name already taken: a random one instead
  function notice(message) {
    if (naming && /exists already/.test(message)) {
      naming = null;
      send({ t: "new-project", name: null });
    }
  }

  function utter(text) {
    if (!text) return;
    show(text, "heard");
    if (local(text)) {
      log("local", text, "here");
      return;
    }
    if (layout.canvasMode() === "new") {
      startProject(text);
      return;
    }
    files.flush?.();
    send({ t: "voice", text, context: context() });
  }

  function control(command) {
    send({ t: "voice-control", command });
  }

  // ---- The studio's events -------------------------------------------------------------

  function receive(event, replaying = false) {
    // a tab not in voice mode keeps its view: another tab is the one talking
    if (!on && ["focus", "edited", "client"].includes(event.kind)) return;
    switch (event.kind) {
      case "heard":
        log("author", event.text);
        break;
      case "routed": {
        const did = (event.did ?? []).join(" · ");
        const last = talkList.lastElementChild;
        if (last?.classList.contains("author")) last.append(el("span", "voice-extra", `${did || "—"} · ${event.ms} ms`));
        break;
      }
      case "reply":
        log(event.from === "builder" ? "builder" : "studio", event.text);
        if (!replaying) {
          show(event.text, "reply");
          if (event.speak) speak(event.text);
        }
        break;
      case "builder":
        log("builder", event.text);
        break;
      case "error":
        log("error", event.message);
        if (!replaying) show(event.message, "bad");
        break;
      case "focus":
        focus(event.label, event.targets, event.from === "builder");
        break;
      case "edited":
        if (!event.file) break;
        layout.changed();
        if (settings.follow && Date.now() - lastUserMove > USER_HOLD_MS) go(event.file, event.from, event.to, "voice-edit");
        else if (files.active() === event.file) flash(event.from, event.to, "voice-edit");
        break;
      case "activity":
        renderActivity(event);
        break;
      case "properties":
        properties = event.results ?? { properties: [] };
        renderProperties();
        break;
      case "client":
        clientCommand(event.command);
        break;
      default:
        break;
    }
  }

  function clientCommand(command) {
    switch (command) {
      case "next": return step(1, false);
      case "previous": return step(-1, false);
      case "back": return back();
      case "mute": return setSpeak(false);
      case "unmute": return setSpeak(true);
      case "sleep": return stopListening();
      case "follow": return setFollow(true);
      case "unfollow": return setFollow(false);
      case "run": return run();
      case "show-output": return layout.showOutput(true);
      case "hide-output": return layout.showOutput(false);
      default: return undefined;
    }
  }

  function receiveState(state) {
    talkList.replaceChildren();
    for (const event of state.log ?? []) {
      // the past, without moving the view or speaking again
      if (["focus", "edited", "client", "properties"].includes(event.kind)) continue;
      receive(event, true);
    }
    properties = state.properties ?? { properties: [] };
    // what failed before this tab opened is not news
    failingBefore = new Set((properties.properties ?? []).filter((p) => p.status !== "ok").map((p) => p.name));
    renderProperties();
    renderActivity(state.activity);
    if (state.unavailable) show(state.unavailable, "bad");
    // the description that made this project: now it can be built
    let pending = null;
    try {
      pending = sessionStorage.getItem(PENDING);
      sessionStorage.removeItem(PENDING);
    } catch { /* none */ }
    if (pending) {
      files.flush?.();
      send({ t: "voice", text: pending, context: context() });
    }
  }

  // ---- On and off ----------------------------------------------------------------------

  // `listen`: start the microphone too (a click does; opening the page
  // starts it only if it was listening when the page was left)
  function toggle(value = !on, listen = true) {
    on = value;
    document.body.classList.toggle("voice-on", on);
    layer.hidden = !on;
    button.classList.toggle("on", on);
    // remembered under its own name: an older "voice off" (`on`) predates
    // the focused layout being the default, and does not count
    store({ ...load(), layout: on ? "focus" : "panes" });
    if (on) {
      layout.enter();
      send({ t: "voice-state" });
      if (listen) startListening();
    } else {
      stopListening();
      closeCards();
      layout.leave();
      window.speechSynthesis?.cancel();
    }
    // the editor's box changed: let it measure again
    setTimeout(() => view?.layout(), 0);
  }

  button.addEventListener("click", () => toggle());
  window.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && event.shiftKey && event.key.toLowerCase() === "v") {
      event.preventDefault();
      toggle();
    } else if (on && event.key === "Escape") {
      closeCards();
    }
  });
  window.addEventListener("resize", () => on && view?.layout());
  // the focused editor is how the studio opens; "Show all panes" in ⋯
  // (or the 🎙 button) brings the rest back, and is remembered
  if (saved.layout !== "panes") setTimeout(() => toggle(true, saved.listening ?? false), 0);

  return {
    receive: (event) => receive(event),
    notice,
    // the socket is (again) open: what voice mode has said so far
    connected() { if (on) send({ t: "voice-state" }); },
    receiveState,
    toggle,
    on: () => on,
  };
}
