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

import { createTimeline } from "./timeline.js";
import { createProgress } from "./progress.js";

const STORE = "puffin-voice";
// after the author moves the view, the builder's edits do not pull it away
const USER_HOLD_MS = 8000;
const HOVER_FRESH_MS = 15000;
// how long a caption or a reply stays on screen
const CAPTION_MS = 7000;
// replies are read, not heard: they stay longer
const REPLY_MS = 15000;
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

export function createVoice({ editor, files, send, note, button, stage, layout, board, run }) {
  const saved = load();
  // replies are written, not spoken, unless asked for (its own key: an
  // older `speak` was the old default, on)
  const settings = { speak: saved.aloud ?? false, follow: saved.follow ?? true };
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

  // the pill at the foot: the microphone, the caption, the builder while it works
  const pill = el("div", "voice-pill");
  const mic = el("button", "voice-mic");
  mic.innerHTML = '<svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><path fill="currentColor" d="M12 15a3 3 0 0 0 3-3V6a3 3 0 0 0-6 0v6a3 3 0 0 0 3 3Zm5-3a5 5 0 0 1-10 0H5a7 7 0 0 0 6 6.92V21h2v-2.08A7 7 0 0 0 19 12h-2Z"/></svg>';
  mic.addEventListener("click", () => (listening ? stopListening() : startListening()));
  const caption = el("div", "voice-caption");
  // a text area that grows with what is written (up to a few lines, then
  // it scrolls), so nothing typed is ever cut off; Enter sends, Shift+Enter
  // starts a new line
  const typed = el("textarea", "voice-typed");
  typed.rows = 1;
  typed.spellcheck = true;
  typed.placeholder = "Describe what you want to build";
  // one line when empty (the placeholder too), growing with the text
  const fit = () => {
    if (!typed.value) {
      typed.style.height = "";
      return;
    }
    typed.style.height = "auto";
    typed.style.height = `${Math.min(typed.scrollHeight, 200)}px`;
  };
  typed.addEventListener("input", fit);
  typed.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      const text = typed.value.trim();
      if (!text) return;
      utter(text);
      typed.value = "";
      fit();
    }
    if (event.key === "Escape") {
      typed.blur();
      closeCards();
    }
    event.stopPropagation();
  });
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
  pill.append(mic, caption, typed, stopButton, more);
  // did it hear, and is anything happening: a card above the pill, only
  // while something said is in flight (progress.js)
  const progress = createProgress({ host: pill });

  // the badge lives in the focused layout's bar (focus.js)
  layout.slot.append(badge);
  // on the canvas the pill asks for a description; after, for anything
  // a welcome example: into the text box, to send or edit first
  layout.onExample = (text) => {
    typed.value = text;
    fit();
    typed.focus();
    typed.setSelectionRange(text.length, text.length);
  };
  layout.onCanvas = (mode) => {
    const talk = listening ? "" : " — or click the mic and talk";
    typed.placeholder = mode ? `Describe what you want to build${talk}` : `Speak, or type here${talk}`;
  };
  const layer = el("div", "voice-layer");
  layer.hidden = true;
  // the right-hand rail: what has accumulated, stacked
  const rail = el("div", "voice-rail");
  rail.append(propCard, lensCard);
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
    item("What happened", () => timeline.toggle(), !timeline.collapsed());
    item("Start a new conversation", () => control("new-conversation"));
    item("Show all panes", () => toggle(false));
  }

  function setFollow(value) {
    settings.follow = value;
    store({ ...load(), follow: value });
  }
  function setSpeak(value) {
    settings.speak = value;
    store({ ...load(), aloud: value });
    if (!value) window.speechSynthesis?.cancel();
  }

  // A line under the editor: what was heard, what came back. It fades.
  function show(text, kind = "", ms = CAPTION_MS) {
    caption.textContent = text;
    caption.className = `voice-caption ${kind}`;
    clearTimeout(captionTimer);
    if (text) captionTimer = setTimeout(() => { caption.textContent = ""; caption.className = "voice-caption"; }, ms);
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
    board?.setProperties(properties);
    const list = properties.properties ?? [];
    // open: it reaches a definition not written yet (??) -- undecided, not failing
    const failing = list.filter((p) => !["ok", "pending", "open"].includes(p.status));
    const open = list.filter((p) => p.status === "open");
    badge.hidden = !list.length && !properties.error;
    badge.className = `voice-badge${failing.length || properties.error ? " bad" : ""}`;
    badge.textContent = properties.error
      ? "properties don't run"
      : failing.length
        ? `✗ ${failing.length} of ${list.length} ${list.length === 1 ? "property" : "properties"} failing`
        : open.length
          ? `✓ ${list.length - open.length} · ◌ ${open.length} open`
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
      const mark = { ok: "✓", fail: "✗", crashed: "!", open: "◌", "not-run": "·", pending: "…" }[property.status] ?? "?";
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

  // ---- What happened (timeline.js) -------------------------------------------------------

  const timeline = createTimeline({
    host: layer,
    go: (file, from, to) => {
      lastUserMove = Date.now();
      go(file, from, to, "voice-edit");
    },
  });

  // ---- Nothing floats over the pill ----------------------------------------------------
  //
  // The pill and the progress card above it are where the eye is while
  // talking; the history, the rail, the menu and the output keep clear of
  // them. Each float that shares columns with the pill (a narrow window, a
  // tall caption, a big card) ends above it instead of under it; one that
  // does not keeps its own place. Measured, since the pill grows and moves
  // (the canvas centers it).
  const CLEAR_GAP = 12;
  const TIMELINE_MIN = 260; // voice.css .timeline
  function keepClear() {
    if (!on) return;
    const zone = pill.getBoundingClientRect();
    let top = zone.top;
    const card = progress.node.getBoundingClientRect();
    if (!progress.node.hidden && card.height) top = Math.min(top, card.top);
    const host = layer.getBoundingClientRect();
    document.body.style.setProperty("--pill-clear", `${Math.max(0, host.bottom - top + CLEAR_GAP)}px`);
    document.body.style.setProperty("--pill-clear-fixed", `${Math.max(0, window.innerHeight - top + CLEAR_GAP)}px`);
    // the history needs the left margin to itself (TIMELINE_MIN wide)
    const column = document.querySelector(".editor-column")?.getBoundingClientRect();
    if (column?.width) timeline.setRoom(column.left - host.left >= 16 + TIMELINE_MIN + CLEAR_GAP);
    const floats = [...layer.querySelectorAll(".timeline, .voice-rail, .voice-menu"), document.querySelector(".right-pane")];
    for (const node of floats) {
      if (!node) continue;
      const box = node.getBoundingClientRect();
      // hidden, or not in the pill's columns: its own place
      const shares = box.width > 0 && box.left < zone.right + CLEAR_GAP && box.right > zone.left - CLEAR_GAP;
      node.classList.toggle("clear-pill", shares);
    }
  }
  const watcher = new ResizeObserver(keepClear);
  watcher.observe(pill);
  watcher.observe(progress.node);
  window.addEventListener("resize", keepClear);
  // floats come and go by many paths: look again now and then (cheap)
  setInterval(keepClear, 500);

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
    // what it is doing is the progress card's (progress.js); the pill keeps Stop
    stopButton.hidden = !busy;
  }

  // ---- Listening ---------------------------------------------------------------------------

  const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;

  function renderMic() {
    store({ ...load(), listening });
    layout.onCanvas?.(layout.canvasMode());
    mic.classList.toggle("live", listening);
    mic.title = listening ? "Listening — click to stop (or say “stop listening”)" : "Click to talk";
  }

  // The microphone's level, drawn as a ring around the button, so the
  // author sees the browser hears them before any words come back.
  let meter = null; // { stream, context, frame }
  async function startMeter() {
    if (meter || !navigator.mediaDevices?.getUserMedia) return;
    // made in the click itself: an audio context made later starts
    // suspended (the browser's autoplay rule) and hears only silence
    const context = new (window.AudioContext || window.webkitAudioContext)();
    context.resume?.();
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      if (!listening) {
        stream.getTracks().forEach((track) => track.stop());
        context.close();
        return;
      }
      const analyser = context.createAnalyser();
      analyser.fftSize = 512;
      context.createMediaStreamSource(stream).connect(analyser);
      const samples = new Uint8Array(analyser.fftSize);
      meter = { stream, context, frame: 0 };
      const draw = () => {
        analyser.getByteTimeDomainData(samples);
        let sum = 0;
        for (const s of samples) sum += ((s - 128) / 128) ** 2;
        const level = Math.min(1, Math.sqrt(sum / samples.length) * 6);
        mic.style.setProperty("--level", level.toFixed(3));
        meter.frame = requestAnimationFrame(draw);
      };
      draw();
    } catch (error) {
      context.close();
      const why = error?.name === "NotAllowedError" ? "The microphone is blocked: allow it for this site (the icon in the address bar), then click the mic."
        : error?.name === "NotFoundError" ? "No microphone was found."
        : `The microphone could not start: ${error?.message ?? error}`;
      show(why, "bad", 30000);
    }
  }
  function stopMeter() {
    if (!meter) return;
    cancelAnimationFrame(meter.frame);
    meter.stream.getTracks().forEach((track) => track.stop());
    meter.context.close();
    meter = null;
    mic.style.removeProperty("--level");
  }

  const ERRORS = {
    "not-allowed": "The microphone is blocked: allow it for this site (the icon in the address bar), then click the mic.",
    "service-not-allowed": "This browser will not run speech recognition here (Safari: turn on Siri / Dictation in System Settings).",
    "audio-capture": "No microphone was found.",
    network: "Speech recognition could not reach its service (Chrome sends the audio to Google): check the connection.",
    "language-not-supported": "Speech recognition does not support this browser's language.",
  };
  let failures = 0;

  function startListening() {
    if (!Recognition) {
      show("This browser has no speech recognition (Chrome, Edge and Safari do; Firefox does not): type instead.", "bad", 30000);
      typed.focus();
      return;
    }
    listening = true;
    failures = 0;
    renderMic();
    startMeter();
    if (!recognition) {
      recognition = new Recognition();
      recognition.continuous = true;
      recognition.interimResults = true;
      recognition.lang = navigator.language || "en-US";
      recognition.onstart = () => {
        if (!caption.textContent || caption.classList.contains("quiet")) show("Listening…", "quiet", 4000);
      };
      recognition.onresult = (event) => {
        failures = 0;
        let interim = "";
        for (let i = event.resultIndex; i < event.results.length; i++) {
          const result = event.results[i];
          if (result.isFinal) utter(result[0].transcript.trim());
          else interim += result[0].transcript;
        }
        if (interim) show(interim, "interim");
      };
      recognition.onerror = (event) => {
        // silence and our own stops are not failures
        if (event.error === "no-speech" || event.error === "aborted") return;
        failures++;
        show(ERRORS[event.error] ?? `Speech recognition failed: ${event.error}`, "bad", 30000);
        if (event.error in ERRORS || failures >= 3) stopListening();
      };
      // recognizers stop on silence: start again while listening (after a
      // pause when something went wrong, so a failure cannot spin)
      recognition.onend = () => {
        if (listening && !speaking) setTimeout(restart, failures ? 1500 : 0);
      };
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
    stopMeter();
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
    if (/^(show (the )?(conversation|history|trace)|what happened|what did you do)$/.test(said)) return timeline.show(), true;
    if (/^(hide (the )?(conversation|history|trace))$/.test(said)) return timeline.hide(), true;
    if (/^(show (the )?properties)$/.test(said)) return (propCard.hidden = false), true;
    // the module board (board.js)
    if (board && /^(show (me )?(the )?board|board( view)?|show (me )?(the )?(modules|signatures|design))$/.test(said)) return board.setView("board"), true;
    if (board && /^(show (me )?(the )?(editor|code|source)|editor( view)?|back to (the )?(editor|code))$/.test(said)) return board.setView("editor"), true;
    if (board && /^(plan mode|planning mode|let'?s plan|start planning)$/.test(said)) return board.setMode("plan"), true;
    if (board && /^(build mode|building mode|stop planning|let'?s build)$/.test(said)) return board.setMode("build"), true;
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
    for (const card of [lensCard, propCard, menu]) card.hidden = true;
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
    progress.starting(text);
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
      timeline.you(text, true);
      return;
    }
    if (layout.canvasMode() === "new") {
      startProject(text);
      return;
    }
    // whatever is said now is work in this project: the canvas never
    // again offers a new one in this tab
    layout.started();
    files.flush?.();
    progress.asked(text);
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
        timeline.you(event.text);
        progress.asked(event.text, event.at);
        break;
      case "routed":
        timeline.routed(event.did ?? [], event.ms ?? 0);
        progress.routed(event, replaying);
        break;
      case "reply":
        timeline.reply(event.text, event.from === "builder");
        if (!replaying) {
          show(event.text, "reply", REPLY_MS);
          if (event.speak) speak(event.text);
        }
        break;
      case "builder":
        timeline.note(event.turn ?? 0, event.text);
        progress.note(event);
        break;
      case "turn":
        timeline.turn(event);
        progress.turn(event);
        break;
      case "step":
        timeline.step(event);
        progress.step(event);
        break;
      case "step-done":
        timeline.stepDone(event);
        progress.stepDone(event);
        break;
      case "turn-end":
        timeline.turnEnd(event);
        progress.turnEnd(event, replaying);
        break;
      case "error":
        timeline.error(event.message);
        if (!replaying) {
          show(event.message, "bad");
          progress.error(event.message);
        } else progress.settled();
        break;
      case "focus":
        if (event.from !== "builder") timeline.focus(event.label, event.targets, () => focus(event.label, event.targets, false));
        if (!replaying) focus(event.label, event.targets, event.from === "builder");
        break;
      case "edited":
        if (!event.file) break;
        timeline.edited(event);
        progress.edited(event);
        if (replaying) break;
        layout.changed();
        if (settings.follow && Date.now() - lastUserMove > USER_HOLD_MS) go(event.file, event.from, event.to, "voice-edit");
        else if (files.active() === event.file) flash(event.from, event.to, "voice-edit");
        break;
      case "activity":
        renderActivity(event);
        timeline.activity(event);
        progress.activity(event);
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
    timeline.clear();
    progress.reset();
    for (const event of state.log ?? []) {
      // the past, into the trace, without moving the view or speaking again
      if (["client", "properties"].includes(event.kind)) continue;
      receive(event, true);
    }
    timeline.activity(state.activity);
    properties = state.properties ?? { properties: [] };
    // what failed before this tab opened is not news
    failingBefore = new Set((properties.properties ?? []).filter((p) => p.status !== "ok").map((p) => p.name));
    renderProperties();
    renderActivity(state.activity);
    // a run the log no longer shows the end of, or words never answered:
    // what the studio says now is what counts
    if ((state.activity?.state ?? "idle") === "idle") progress.reset();
    else progress.activity(state.activity);
    if (state.unavailable) show(state.unavailable, "bad");
    // the description that made this project: now it can be built
    let pending = null;
    try {
      pending = sessionStorage.getItem(PENDING);
      sessionStorage.removeItem(PENDING);
    } catch { /* none */ }
    if (pending) {
      files.flush?.();
      progress.asked(pending);
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
