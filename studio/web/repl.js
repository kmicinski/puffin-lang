// The REPL: the transcript of everything evaluated, every gesture echoed as
// the command it is, and the prompt.
//
// Enter evaluates the prompt once its brackets balance (Shift+Enter adds a
// line); the arrows walk the history. A line starting with `,` is a studio
// command, the same one a gesture echoes, so a transcript is a script:
//   ,load FILE              evaluate a whole module in the session
//   ,eval FILE:LINE         evaluate the form on LINE, with the definitions
//                           it needs that the session lacks (⌘↵)
//   ,session                what the session holds of each file
//   ,assist ID FILE:POS     apply the compiler's assist ID at byte POS
//   ,accept #N  ,reject #N  a proposal
//   ,restore vN             a file's version, as its text again
//   ,save  ,reset  ,interrupt  ,help
//
//   createRepl({ transcript, prompt, send, commands }) -> { receive, entries, run, insert }
// `commands` holds the handlers for the commands the page carries out
// itself ({ assist(id, file, pos), load(file), save(), evalAt(file, line),
// session() }); `renderAsk(entry, node)` is set by assist.js to draw a
// question's block. A run that referenced a name before its definition,
// which a module defines, offers a chip that loads it: `,eval FILE:LINE`.

import { balanced } from "./lexer.js";
import { highlight } from "./markdown.js";
import { bindTextarea } from "./paredit.js";

const element = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

const HELP = `,load FILE           evaluate a whole module in the session (⌘⇧↵ in the editor)
,eval FILE:LINE      evaluate the form on LINE, loading first the definitions it needs (⌘↵)
,session             what the session holds of each file: current, stale, results
,assist ID FILE:POS  apply the compiler's assist ID at byte POS (⌘. in the editor)
,accept #N  ,reject #N   decide a proposal
,restore vN          make a version of a file its text again (History lists them)
,save                write the edited files (⌘S)
,reset               restart the session
,interrupt           stop the running evaluation (Ctrl-C at the prompt)
?? QUESTION          ask the assistant (or Tab on an empty prompt)
⌘↵ in the editor evaluates the form at the cursor.`;

export function createRepl({ transcript, prompt, send, commands }) {
  const nodes = new Map(); // entry id -> { node, out }
  const entries = new Map(); // entry id -> entry
  const hooks = { renderAsk: null, entry: null };

  // ---- History ------------------------------------------------------------

  const history = {
    key: "puffin-studio.history",
    lines: [],
    index: 0,
    load() {
      try { this.lines = JSON.parse(localStorage.getItem(this.key)) ?? []; } catch { this.lines = []; }
      this.index = this.lines.length;
    },
    push(line) {
      if (this.lines.at(-1) !== line) this.lines.push(line);
      this.lines = this.lines.slice(-500);
      this.index = this.lines.length;
      try { localStorage.setItem(this.key, JSON.stringify(this.lines)); } catch { /* private mode */ }
    },
  };
  history.load();

  // ---- The prompt -----------------------------------------------------------

  const structure = bindTextarea(prompt);
  prompt.removeEventListener("keydown", structure);
  const fit = () => { prompt.rows = Math.min(12, prompt.value.split("\n").length); };

  // What typing `line` at the prompt does.
  function run(line) {
    const text = line.trim();
    if (!text) return;
    history.push(text);
    if (text.startsWith(",")) command(text);
    else send({ t: "eval", text, source: "prompt" });
  }

  function command(text) {
    const [verb, ...rest] = text.slice(1).trim().split(/\s+/);
    const arg = rest.join(" ");
    switch (verb) {
      case "load": return commands.load(arg || null);
      case "eval": {
        const match = /^(.+):(\d+)$/.exec(arg);
        if (!match) return local(text, "usage: ,eval FILE:LINE", true);
        return commands.evalAt(match[1], Number(match[2]));
      }
      case "session": return local(text, commands.session());
      case "reset": return send({ t: "reset" });
      case "interrupt":
        send({ t: "echo", line: text });
        return send({ t: "interrupt" });
      case "save":
        send({ t: "echo", line: text });
        return commands.save();
      case "restore": {
        const id = Number(arg.replace(/^v/, ""));
        if (!id) return local(text, "usage: ,restore vN (the History panel lists them)", true);
        send({ t: "restore", id });
        return send({ t: "echo", line: `,restore v${id}` });
      }
      case "accept": return send({ t: "accept", ops: rest.map((id) => Number(id.replace("#", ""))).filter(Boolean) });
      case "reject": return rest.forEach((id) => send({ t: "reject", op: Number(id.replace("#", "")) }));
      case "assist": {
        const match = /^(\S+)\s+(.+):(\d+)$/.exec(arg);
        if (!match) return local(text, "usage: ,assist ID FILE:POS", true);
        return commands.assist(match[1], match[2], Number(match[3]));
      }
      case "help": return local(text, HELP);
      default: return local(text, `unknown command ,${verb}: ,help lists them`, true);
    }
  }

  // An entry this tab alone shows.
  function local(line, text, error = false) {
    const node = transcript.appendChild(element("div", "entry echo"));
    node.append(element("div", "line", line));
    node.append(element("pre", error ? "error" : "lines", text));
    scroll(true);
  }

  prompt.addEventListener("keydown", (event) => {
    if (prompt.dataset.mode === "ask") return; // a question (assist.js)
    const text = prompt.value;
    if (event.key === "Enter" && !event.shiftKey && (balanced(text) || text.trim().startsWith(","))) {
      event.preventDefault();
      run(text);
      prompt.value = "";
      fit();
    } else if (event.key === "c" && event.ctrlKey && prompt.selectionStart === prompt.selectionEnd) {
      event.preventDefault();
      send({ t: "interrupt" });
    } else if (event.key === "ArrowUp" && !text.slice(0, prompt.selectionStart).includes("\n")) {
      if (history.index === 0) return;
      event.preventDefault();
      prompt.value = history.lines[--history.index];
      fit();
    } else if (event.key === "ArrowDown" && !text.slice(prompt.selectionEnd).includes("\n")) {
      if (history.index >= history.lines.length) return;
      event.preventDefault();
      prompt.value = history.lines[++history.index] ?? "";
      fit();
    } else {
      structure(event);
    }
  });
  prompt.addEventListener("input", fit);

  // ---- The transcript -------------------------------------------------------

  const atBottom = () => transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 60;
  function scroll(was) {
    if (was) transcript.scrollTop = transcript.scrollHeight;
  }

  function show(entry) {
    entries.set(entry.id, entry);
    const was = atBottom();
    const node = element("div", `entry ${entry.kind}${entry.origin ? ` ${entry.origin}` : ""}`);
    if (entry.kind === "ask") {
      transcript.append(node);
      nodes.set(entry.id, { node });
      hooks.renderAsk?.(entry, node);
      return scroll(true);
    }
    const head = node.appendChild(element("div", "line"));
    if (entry.kind === "eval" && entry.origin === "buffer" && entry.file) {
      const where = head.appendChild(element("span", "where", `${entry.command || entry.file} `));
      if (entry.command) where.title = "The command this gesture is: typed at the prompt, it does the same";
    }
    const code = head.appendChild(element("span", "code"));
    code.innerHTML = entry.kind === "eval" && !entry.line.startsWith(",") ? highlight(entry.line) : escapeText(entry.line);
    if (entry.kind === "eval") {
      code.title = "Click to put it in the prompt";
      code.addEventListener("click", () => insert(entry.line));
    }
    if (entry.also?.length) node.append(element("div", "also", `also loaded: ${entry.also.join(", ")}`));
    const out = node.appendChild(element("div", "out"));
    nodes.set(entry.id, { node, out, head });
    for (const [stream, text] of entry.out ?? []) output(entry.id, stream, text, false);
    if (entry.status) done(entry);
    else if (entry.kind === "eval") node.classList.add("running");
    transcript.append(node);
    hooks.entry?.(entry, node);
    scroll(was);
  }

  function output(id, stream, text, follow = true) {
    const known = nodes.get(id);
    if (!known?.out) return;
    const was = follow && atBottom();
    if (stream === "result") {
      const result = known.out.appendChild(element("div", "result"));
      result.innerHTML = highlight(text);
    } else {
      const last = known.out.lastElementChild;
      if (last?.dataset.stream === stream) last.textContent += text;
      else {
        const pre = known.out.appendChild(element("pre", `stream ${stream}`, text));
        pre.dataset.stream = stream;
      }
    }
    scroll(was);
  }

  function done({ id, status, error, ms, fixes = [] }) {
    const known = nodes.get(id);
    if (!known) return;
    const entry = entries.get(id);
    if (entry) Object.assign(entry, { status, error, ms, fixes });
    const was = atBottom();
    known.node.classList.remove("running");
    known.node.classList.toggle("failed", status !== "ok");
    if (ms && known.head) known.head.append(element("span", "ms", ms < 1000 ? `${ms} ms` : `${(ms / 1000).toFixed(1)} s`));
    if (error) {
      const box = known.node.appendChild(element("pre", `error ${status}`, error));
      hooks.error?.(entry, box);
    }
    if (fixes.length) {
      const chips = known.node.appendChild(element("div", "fix-chips"));
      for (const fix of fixes) {
        const command = `,eval ${fix.file}:${fix.line}`;
        const chip = chips.appendChild(element("button", "small fix-chip", `Load ${fix.name} from ${fix.file}`));
        chip.title = `${command}: ${fix.name} is defined there and the session lacks it`;
        chip.addEventListener("click", () => {
          run(command);
          chip.disabled = true;
        });
      }
    }
    scroll(was);
  }

  function insert(text) {
    prompt.value = text;
    fit();
    prompt.focus();
    prompt.setSelectionRange(text.length, text.length);
  }

  return {
    run,
    insert,
    hooks,
    local,
    scroll: () => scroll(true),
    entries: () => [...entries.values()],
    nodeOf: (id) => nodes.get(id)?.node,
    receive: {
      init({ transcript: list }) {
        transcript.replaceChildren();
        nodes.clear();
        entries.clear();
        for (const entry of list) show(entry);
        scroll(true);
      },
      entry: show,
      "entry-out": ({ id, stream, text }) => output(id, stream, text),
      "entry-done": done,
    },
  };
}

function escapeText(text) {
  return text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" })[c]);
}
