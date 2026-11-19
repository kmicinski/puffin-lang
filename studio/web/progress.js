// The answer to "did it hear me, and is anything happening?" (docs/VOICE.md
// §3): a small card that rides just above the pill, there only while
// something the author said is in flight, and gone when it is not.
//
//   heard        the phrase, at once: "understanding…", a clock running
//   routed       what the studio made of it, in its own words: "On it: …",
//                "after the current work: …", or -- for words that were
//                not yet a whole request -- "go on…" (they are kept, and
//                read with what comes next: voice.rs `fragments`)
//   builder      while it works: what it is doing now (its latest note or
//                step), the last few steps faint under it, how long, how
//                many edits
//   end          "done · 1m 12s · 4 edits", a moment, then gone
//
// On the canvas (no code to watch yet) it is the whole show: the welcome
// steps aside and the card is larger, with the steps as they come. Off the
// canvas it is one line, since the edits themselves are on screen.

const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

const clock = (ms) => {
  const s = Math.max(0, Math.floor(ms / 1000));
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, "0")}s`;
};

const firstSentence = (text) => {
  const plain = String(text ?? "").replace(/[`*_#>]/g, "").replace(/\s+/g, " ").trim();
  const m = plain.match(/^(.{12,160}?[.!?])(\s|$)/);
  return m ? m[1] : plain.slice(0, 160) + (plain.length > 160 ? "…" : "");
};

const WORDS = {
  starting: "starting the builder…",
  thinking: "thinking…",
  talking: "writing…",
  working: "working…",
  queued: "will do that next",
  redirecting: "taking the new instruction…",
};

// how long words that were not yet a request say "go on"
const GO_ON_MS = 6000;
// how long the end of a run stays
const DONE_MS = 5000;
// the router answers in a couple of seconds; past this, say it is slow
const SLOW_ROUTE_MS = 6000;

export function createProgress({ host }) {
  const card = el("div", "voice-progress");
  card.hidden = true;
  const head = el("div", "voice-progress-head");
  const dot = el("span", "voice-progress-dot");
  const title = el("span", "voice-progress-title");
  const time = el("span", "voice-progress-time");
  head.append(dot, title, time);
  const said = el("div", "voice-progress-said");
  const now = el("div", "voice-progress-now");
  const past = el("div", "voice-progress-past");
  card.append(head, said, now, past);
  host.append(card);

  // what is in flight
  let asking = null; // { text, since } -- said, not yet routed
  let turn = null; // { id, label, since, edits, steps: [] }
  let flash = null; // { kind, title, line, until } -- a passing message
  let doing = ""; // the builder's current line
  let noted = ""; // the builder's latest note of what it is about to do
  let ticker = 0;
  let hideTimer = 0;

  function render() {
    const at = Date.now();
    if (flash && at > flash.until) flash = null;
    let state = null;
    if (turn) {
      state = { kind: "working", title: turn.label, said: noted, line: doing || WORDS.starting, since: turn.since, past: turn.steps.slice(-3, -1) };
      const counts = [];
      if (turn.edits) counts.push(`${turn.edits} edit${turn.edits === 1 ? "" : "s"}`);
      state.extra = counts.join(" · ");
      // something said while it works: shown on top of the run
      if (asking) state.line = at - asking.since > SLOW_ROUTE_MS ? "understanding (slow)…" : `understanding “${clip(asking.text, 60)}”…`;
      else if (flash) state.line = flash.title;
    } else if (asking) {
      state = { kind: "asking", title: asking.text, line: asking.line ?? (at - asking.since > SLOW_ROUTE_MS ? "understanding — this is taking a while…" : "understanding…"), since: asking.since };
    } else if (flash) {
      state = { kind: flash.kind, title: flash.title, line: flash.line ?? "", since: null };
    }
    document.body.classList.toggle("voice-working", Boolean(state) && state.kind !== "done" && state.kind !== "bad");
    if (!state) {
      card.hidden = true;
      clearInterval(ticker);
      ticker = 0;
      return;
    }
    card.hidden = false;
    card.className = `voice-progress ${state.kind}`;
    title.textContent = state.title;
    title.title = state.title;
    said.textContent = state.said ?? "";
    said.hidden = !state.said;
    now.textContent = state.line;
    now.hidden = !state.line;
    time.textContent = [state.extra, state.since ? clock(at - state.since) : ""].filter(Boolean).join(" · ");
    past.replaceChildren(...(state.past ?? []).map((s) => {
      const row = el("div", `voice-progress-step ${s.ok === false ? "bad" : ""}`, s.text);
      return row;
    }));
    if (!ticker) ticker = setInterval(render, 1000);
  }

  function clip(text, n) {
    const t = String(text ?? "").replace(/\s+/g, " ").trim();
    return t.length > n ? `${t.slice(0, n - 1)}…` : t;
  }

  function passing(kind, titleText, line, ms) {
    flash = { kind, title: titleText, line, until: Date.now() + ms };
    clearTimeout(hideTimer);
    hideTimer = setTimeout(render, ms + 20);
    render();
  }

  return {
    // the phrase is on its way to the studio
    asked(text, at = Date.now()) {
      asking = { text: clip(text, 220), since: at };
      flash = null;
      render();
    },
    // the studio decided; `did` as voice.rs act lists it
    routed({ did = [], decision = {} }, replaying = false) {
      asking = null;
      if (replaying) return render();
      const build = decision.build ?? {};
      const instruction = String(build.instruction ?? "").split("\n")[0];
      if (did.length === 0 && !decision.reply) {
        // not yet a request: kept, and read with the next words
        passing("waiting", "go on…", "", GO_ON_MS);
      } else if (instruction && build.urgency !== "none") {
        if (turn && build.urgency === "queue") passing("queued", `next: ${clip(instruction, 90)}`, "", 4000);
        else if (!turn) passing("starting", `On it: ${clip(instruction, 160)}`, WORDS.starting, 60000);
        else render();
      } else {
        render();
      }
    },
    // the builder took up the instructions
    turn({ turn: id, instructions = [], at }) {
      const automatic = instructions.length === 1 && instructions[0].startsWith("(Automatic");
      const label = automatic ? "fixing the failing properties" : instructions.map((i) => i.split("\n")[0]).join(" · ") || "working";
      turn = { id, label: clip(label, 200), since: at ?? Date.now(), edits: 0, steps: [] };
      doing = "";
      noted = "";
      flash = null;
      render();
    },
    note({ turn: id, text }) {
      if (!turn || turn.id !== id) return;
      noted = firstSentence(text);
      render();
    },
    step({ turn: id, id: callId, text }) {
      if (!turn || turn.id !== id) return;
      turn.steps.push({ id: callId, text });
      if (turn.steps.length > 20) turn.steps.shift();
      doing = `${text}…`;
      render();
    },
    stepDone({ id, ok }) {
      const step = turn?.steps.find((s) => s.id === id);
      if (step) step.ok = ok;
      render();
    },
    edited({ turn: id }) {
      if (turn && (id === undefined || turn.id === id)) turn.edits++;
      render();
    },
    activity(a) {
      const state = a?.state ?? "idle";
      // queued: the routed flash says it; the run's own line stays
      if (state === "idle" || state === "queued") return;
      if (state === "working" && a.text) doing = `${a.text}…`;
      else if (state !== "working") doing = WORDS[state] ?? state;
      render();
    },
    turnEnd({ turn: id, ms, outcome }, replaying = false) {
      if (!turn || turn.id !== id) return;
      const edits = turn.edits;
      turn = null;
      doing = "";
      if (replaying) return render();
      const word = { done: "done", interrupted: "redirected", stopped: "stopped", failed: "failed" }[outcome] ?? outcome;
      const parts = [word, clock(ms ?? 0)];
      if (edits) parts.push(`${edits} edit${edits === 1 ? "" : "s"}`);
      passing(outcome === "failed" ? "bad" : "done", parts.join(" · "), "", DONE_MS);
    },
    // nothing to route after all (a local command, an error)
    settled() {
      asking = null;
      render();
    },
    error(message) {
      asking = null;
      passing("bad", clip(message, 200), "", 12000);
    },
    // a new project is being made for the words
    starting(text) {
      asking = { text: clip(text, 220), since: Date.now(), line: "making a new project for it…" };
      render();
    },
    // the studio's state, freshly: nothing is in flight but what it says
    reset() {
      asking = null;
      turn = null;
      flash = null;
      doing = "";
      render();
    },
    running: () => Boolean(turn),
    node: card,
  };
}
