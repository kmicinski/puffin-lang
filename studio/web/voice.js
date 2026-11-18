// Voice mode (docs/VOICE.md; the server side is studio/src/voice.rs).
//
// The browser listens continuously (the Web Speech API: Chrome, Edge,
// Safari) and sends each finished phrase to the studio, with what the author
// is looking at: the shown file, the cursor, the word under the mouse. The
// studio routes it (navigate, build, control) and answers with events:
//   heard / routed / reply   the conversation, spoken replies aloud
//   focus                    places to look: the lens, the editor moves there
//   edited                   the builder changed lines: the view follows
//   activity                 what the builder is doing now
//   properties               the spec's status
//   client                   a command for this tab (next, mute, sleep, ...)
// A few phrases never leave the tab, so they are instant: "line 40",
// "next", "previous", "back", "stop", "undo", "scroll down".

import { markdown } from "./markdown.js";

const STORE = "puffin-voice";
// after the author moves the view, the builder's edits do not pull it away
const USER_HOLD_MS = 8000;
const HOVER_FRESH_MS = 15000;

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

export function createVoice({ editor, files, send, note, button, wrap, column }) {
  const saved = load();
  const settings = { speak: saved.speak ?? true, follow: saved.follow ?? true };
  let on = false;
  let listening = false;
  let speaking = false;
  let recognition = null;
  let lastUserMove = 0;
  let hover = null; // { file, line, word, at }
  let lens = { label: "", targets: [], index: -1 };
  let backStack = [];
  let properties = { properties: [] };
  let flashes = [];

  // ---- The panel and the dock -------------------------------------------------

  const panel = el("aside", "voice-panel");
  panel.id = "voice-panel";
  panel.hidden = true;
  const lensBox = el("section", "voice-section voice-lens");
  const lensHead = el("div", "voice-head");
  const lensTitle = el("span", "", "Focus");
  const lensList = el("div", "voice-lens-list");
  lensHead.append(lensTitle);
  lensBox.append(lensHead, lensList);

  const propBox = el("section", "voice-section voice-props");
  const propHead = el("div", "voice-head");
  const propTitle = el("span", "", "Properties");
  const propRun = el("button", "quiet small", "Run");
  propRun.title = "Run every property (or say “run the properties”)";
  propRun.addEventListener("click", () => send({ t: "voice-control", command: "run-properties" }));
  propHead.append(propTitle, propRun);
  const propList = el("div", "voice-prop-list");
  propBox.append(propHead, propList);

  const talkBox = el("section", "voice-section voice-talk");
  const talkHead = el("div", "voice-head");
  talkHead.append(el("span", "", "Conversation"));
  const fresh = el("button", "quiet small", "New");
  fresh.title = "Forget the builder's conversation and start a new one";
  fresh.addEventListener("click", () => send({ t: "voice-control", command: "new-conversation" }));
  talkHead.append(fresh);
  const talkList = el("div", "voice-talk-list");
  talkBox.append(talkHead, talkList);
  panel.append(lensBox, propBox, talkBox);
  wrap.append(panel);

  const dock = el("div", "voice-dock");
  dock.hidden = true;
  const mic = el("button", "voice-mic", "●");
  mic.title = "Listening: click to pause (or say “stop listening”)";
  mic.addEventListener("click", () => (listening ? stopListening() : startListening()));
  const caption = el("div", "voice-caption");
  const activity = el("div", "voice-activity");
  const typed = el("input", "voice-typed");
  typed.placeholder = "…or type to the studio";
  typed.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && typed.value.trim()) {
      utter(typed.value.trim());
      typed.value = "";
    }
    event.stopPropagation();
  });
  const stopButton = el("button", "small secondary", "Stop");
  stopButton.title = "Stop the builder (say “stop”)";
  stopButton.addEventListener("click", () => control("stop"));
  const undoButton = el("button", "small secondary", "Undo");
  undoButton.title = "Undo the builder's last edit (say “undo”)";
  undoButton.addEventListener("click", () => control("undo"));
  const followButton = el("button", "small secondary voice-toggle-btn");
  followButton.addEventListener("click", () => setFollow(!settings.follow));
  const speakButton = el("button", "small secondary voice-toggle-btn");
  speakButton.addEventListener("click", () => setSpeak(!settings.speak));
  dock.append(mic, caption, activity, typed, stopButton, undoButton, followButton, speakButton);
  column.append(dock);

  function renderToggles() {
    followButton.textContent = settings.follow ? "Follow ✓" : "Follow";
    followButton.title = "Move the view to each edit the builder makes (say “follow” / “don't follow”)";
    followButton.classList.toggle("on", settings.follow);
    speakButton.textContent = settings.speak ? "Voice ✓" : "Voice";
    speakButton.title = "Speak replies aloud (say “mute” / “unmute”)";
    speakButton.classList.toggle("on", settings.speak);
  }
  function setFollow(value) {
    settings.follow = value;
    store({ ...load(), follow: value });
    renderToggles();
  }
  function setSpeak(value) {
    settings.speak = value;
    store({ ...load(), speak: value });
    if (!value) speechSynthesis?.cancel();
    renderToggles();
  }
  renderToggles();

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
    flashes.push({ model, ids });
    setTimeout(() => {
      model.deltaDecorations(ids, []);
      flashes = flashes.filter((f) => f.ids !== ids);
    }, 2600);
  }

  function here() {
    return { file: files.active(), line: view?.getPosition()?.lineNumber ?? 1 };
  }

  // Show `file` at `line`, the way the voice does: no keyboard focus taken
  // from the dock, a flash where it landed.
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

  // ---- The lens: the places a focus showed ------------------------------------------

  function excerpt(target) {
    const text = files.texts()[target.file] ?? "";
    const lines = text.split("\n");
    const from = Math.max(1, target.line - 1);
    const to = Math.min(lines.length, target.line + 2);
    const out = [];
    for (let n = from; n <= to; n++) out.push({ n, text: lines[n - 1] ?? "", here: n === target.line });
    return out;
  }

  function renderLens() {
    lensTitle.textContent = lens.targets.length ? `Focus · ${lens.label} · ${lens.index + 1}/${lens.targets.length}` : "Focus";
    lensList.replaceChildren();
    if (!lens.targets.length) {
      lensList.append(el("div", "hint", "Say “where is eval used”, “show me the definition of step”, “line 40”…"));
      return;
    }
    // grouped by file: a multi-file abstraction reads as one picture
    let lastFile = null;
    lens.targets.forEach((target, index) => {
      if (target.file !== lastFile) {
        lensList.append(el("div", "voice-lens-file", target.file));
        lastFile = target.file;
      }
      const card = el("button", `voice-lens-card ${target.role ?? ""}${index === lens.index ? " current" : ""}`);
      for (const line of excerpt(target)) {
        const row = el("div", `voice-lens-line${line.here ? " here" : ""}`);
        row.append(el("span", "voice-lens-n", String(line.n)), el("span", "voice-lens-code", line.text));
        card.append(row);
      }
      card.title = `${target.file}:${target.line}${target.role ? ` (${target.role})` : ""}`;
      card.addEventListener("click", () => step(index - lens.index, true));
      lensList.append(card);
    });
    lensList.querySelector(".current")?.scrollIntoView({ block: "nearest" });
  }

  function focus(label, targets, fromBuilder) {
    if (!targets?.length) return;
    backStack.push(here());
    if (backStack.length > 50) backStack.shift();
    lens = { label, targets, index: 0 };
    if (!fromBuilder) lastUserMove = Date.now();
    renderLens();
    const first = targets[0];
    go(first.file, first.line, first.line, "voice-focus");
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
    const passing = list.filter((p) => p.status === "ok").length;
    propTitle.textContent = list.length ? `Properties · ${passing}/${list.length} pass` : "Properties";
    propBox.classList.toggle("failing", list.some((p) => p.status !== "ok" && p.status !== "pending"));
    propList.replaceChildren();
    if (properties.error) propList.append(el("div", "voice-prop-error", properties.error));
    if (!list.length) {
      propList.append(el("div", "hint", "State what the program must do: “it should always…”, “a property: …”"));
      return;
    }
    for (const property of list) {
      const row = el("button", `voice-prop ${property.status}`);
      const mark = { ok: "✓", fail: "✗", crashed: "!", "not-run": "·", pending: "…" }[property.status] ?? "?";
      const top = el("span", "voice-prop-top");
      top.append(el("span", "voice-prop-mark", mark), el("span", "voice-prop-name", property.name));
      row.append(top);
      if (property.statement) row.append(el("span", "voice-prop-statement", property.statement));
      if (property.detail && property.status !== "ok") row.append(el("span", "voice-prop-detail", property.detail));
      row.title = `${property.status}${property.detail ? `: ${property.detail}` : ""}`;
      row.addEventListener("click", () => property.line && go("properties.puf", property.line));
      propList.append(row);
    }
  }

  // ---- The conversation ----------------------------------------------------------------

  function say(kind, text, extra) {
    const row = el("div", `voice-line ${kind}`);
    const who = { author: "you", studio: "studio", builder: "builder", error: "!", local: "you", routed: "" }[kind] ?? "";
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
    activity.className = `voice-activity ${state}`;
    const words = { idle: "builder idle", starting: "starting", thinking: "thinking", working: "working", talking: "writing", queued: "queued", redirecting: "redirecting" };
    activity.textContent = [words[state] ?? state, a?.text].filter(Boolean).join(" · ");
    stopButton.disabled = state === "idle";
  }

  // ---- Listening ---------------------------------------------------------------------------

  const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;

  function startListening() {
    if (!Recognition) {
      caption.textContent = "This browser has no speech recognition (use Chrome, Edge or Safari) — type below instead.";
      return;
    }
    listening = true;
    mic.classList.add("live");
    mic.title = "Listening: click to pause (or say “stop listening”)";
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
        caption.textContent = interim;
        caption.classList.toggle("interim", Boolean(interim));
      };
      recognition.onerror = (event) => {
        if (event.error === "not-allowed" || event.error === "service-not-allowed") {
          stopListening();
          caption.textContent = "The microphone is blocked: allow it for this site, then click ●.";
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
    mic.classList.remove("live");
    mic.title = "Paused: click to listen";
    recognition?.abort();
    caption.textContent = "";
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

  function utter(text) {
    if (!text) return;
    if (local(text)) {
      say("local", text, "↵ here");
      return;
    }
    files.flush?.();
    send({ t: "voice", text, context: context() });
  }

  function control(command) {
    send({ t: "voice-control", command });
  }

  // ---- The studio's events -------------------------------------------------------------

  function receive(event) {
    // a tab not in voice mode keeps its view: another tab is the one talking
    if (!on && ["focus", "edited", "client"].includes(event.kind)) return;
    switch (event.kind) {
      case "heard":
        say("author", event.text);
        break;
      case "routed": {
        const did = (event.did ?? []).join(" · ");
        const last = talkList.lastElementChild;
        if (last?.classList.contains("author")) last.append(el("span", "voice-extra", `${did || "—"} · ${event.ms} ms`));
        break;
      }
      case "reply":
        say(event.from === "builder" ? "builder" : "studio", event.text);
        if (event.speak) speak(event.text);
        break;
      case "builder":
        say("builder", event.text);
        break;
      case "error":
        say("error", event.message);
        break;
      case "focus":
        focus(event.label, event.targets, event.from === "builder");
        break;
      case "edited":
        if (!event.file) break;
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
      default: return undefined;
    }
  }

  function receiveState(state) {
    talkList.replaceChildren();
    for (const event of state.log ?? []) {
      // the past, without moving the view or speaking again
      if (["focus", "edited", "client"].includes(event.kind)) continue;
      receive({ ...event, speak: false });
    }
    properties = state.properties ?? { properties: [] };
    renderProperties();
    renderActivity(state.activity);
    if (state.unavailable) say("error", state.unavailable);
  }

  // ---- On and off ----------------------------------------------------------------------

  function toggle(value = !on) {
    on = value;
    document.body.classList.toggle("voice-on", on);
    panel.hidden = !on;
    dock.hidden = !on;
    button.classList.toggle("on", on);
    store({ ...load(), on });
    if (on) {
      send({ t: "voice-state" });
      renderLens();
      startListening();
    } else {
      stopListening();
      speechSynthesis?.cancel();
    }
    view?.layout();
  }

  button.addEventListener("click", () => toggle());
  window.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && event.shiftKey && event.key.toLowerCase() === "v") {
      event.preventDefault();
      toggle();
    }
  });
  if (saved.on) setTimeout(() => toggle(true), 0);

  return {
    receive,
    receiveState,
    toggle,
    on: () => on,
  };
}
