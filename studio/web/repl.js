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
//                           (FILE:POS-END for a selection; ID#N the Nth)
//   ,rename FILE:POS NEW    rename the name at byte POS (F2)
//   ,trace NAME ...         print NAME's calls and returns (its define is
//                           evaluated again, traced); alone, list them
//   ,untrace [NAME ...]     stop tracing NAME (every name, without one)
//   ,pin N                  keep entry N's result as a check in tests.puf
//   ,test                   run tests.puf
//   ,accept #N  ,reject #N  a proposal
//   ,restore vN             a file's version, as its text again
//   ,history                show or hide the shown file's versions
//   ,structured [on|off]    whether typing keeps brackets balanced
//   ,save  ,reset  ,interrupt  ,help
//
//   createRepl({ transcript, prompt, send, commands }) -> { receive, entries, run, insert }
// `commands` holds the handlers for the commands the page carries out
// itself ({ assist(id, file, pos, end), rename(file, pos, name), load(file),
// save(), evalAt(file, line), session(), history(), structured(word),
// reveal(file, line) });
// `renderAsk(entry, node)` is set by assist.js to draw a question's block.
// A run that referenced a name before its definition, which a module
// defines, offers a chip that loads it: `,eval FILE:LINE`. An evaluation of
// one expression that printed a result offers to pin it (`,pin N`); a
// `,test` entry lists its checks, each failure linked to its line. A
// traced call's output (`> (f args)` ... `< value`) is drawn as a call
// tree once its evaluation ends (trace.js).

import { balanced, forms } from "./lexer.js";
import { highlight } from "./markdown.js";
import { bindTextarea } from "./paredit.js";
import { renderOutput } from "./trace.js";

const element = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

const HELP = `,load FILE           evaluate a whole module in the session (⌘⇧↵ in the editor)
,eval FILE:LINE      evaluate the form on LINE, loading first the definitions it needs (⌘↵)
,session             what the session holds of each file: current, stale, results
,assist ID FILE:POS  apply the compiler's assist ID at byte POS (⌘. in the editor);
                     FILE:POS-END for a selection (extract), ID#N for the Nth of one id
,rename FILE:POS NEW rename the name at byte POS (F2 in the editor)
,trace NAME          print NAME's calls and returns here, as a call tree; its define is
                     evaluated again, traced (⌘-click a define's gutter, or right-click)
,trace               list what is traced
,untrace [NAME]      stop tracing NAME (every name, without one)
,pin N               keep entry N's printed result as a check in tests.puf (pin)
,test                run tests.puf as a program: each check's ok or FAIL
,accept #N  ,reject #N   decide a proposal
,history             show or hide the shown file's versions (,restore vN brings one back)
,restore vN          make a version of a file its text again
,structured [on|off] whether typing keeps brackets balanced (on, unless turned off)
,save                write the edited files (⌘S)
,reset               restart the session
,interrupt           stop the running evaluation (Ctrl-C at the prompt)
?? QUESTION          ask the assistant (or Tab on an empty prompt)
⌘↵ in the editor evaluates the form at the cursor. The editor takes Emacs keys: C-k is
paredit-kill (the rest of the line, within the list), kills in a row join, C-y yanks,
M-y cycles the ring, C-SPC marks, C-w / M-w kill / copy the region, C-x C-s saves;
C-M-f / C-M-b move over expressions, C-Right / C-Left slurp / barf.`;

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
        if (!id) return local(text, "usage: ,restore vN (,history lists them)", true);
        send({ t: "restore", id });
        return send({ t: "echo", line: `,restore v${id}` });
      }
      case "accept": return send({ t: "accept", ops: rest.map((id) => Number(id.replace("#", ""))).filter(Boolean) });
      case "reject": return rest.forEach((id) => send({ t: "reject", op: Number(id.replace("#", "")) }));
      case "assist": {
        const match = /^(\S+)\s+(.+):(\d+)(?:-(\d+))?$/.exec(arg);
        if (!match) return local(text, "usage: ,assist ID FILE:POS (or FILE:POS-END)", true);
        return commands.assist(match[1], match[2], Number(match[3]), match[4] === undefined ? null : Number(match[4]));
      }
      case "rename": {
        const match = /^(.+):(\d+)\s+(\S+)$/.exec(arg);
        if (!match) return local(text, "usage: ,rename FILE:POS NEW", true);
        return commands.rename(match[1], Number(match[2]), match[3]);
      }
      case "pin": {
        const id = Number(arg.replace(/^#/, ""));
        if (!id) return local(text, "usage: ,pin N (the transcript entry's number: hover an evaluation for its pin)", true);
        return send({ t: "pin", entry: id });
      }
      case "test": return send({ t: "test" });
      case "trace": {
        const names = rest.filter(Boolean);
        if (names.length) return send({ t: "trace", names, on: true });
        const traced = commands.traced();
        return local(text, traced.length
          ? `traced: ${traced.join(", ")} (,untrace NAME to stop)`
          : "nothing is traced: ,trace NAME prints NAME's calls and returns here");
      }
      case "untrace": return send({ t: "trace", names: rest.filter(Boolean), on: false });
      case "history": return local(text, commands.history());
      case "structured": return local(text, commands.structured(arg));
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
      command(",interrupt");
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
    if (entry.kind === "eval" && (entry.command || (entry.origin === "buffer" && entry.file))) {
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
    const entry = entries.get(id);
    if (follow && entry) (entry.out ??= []).push([stream, text]);
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

  function done({ id, status, error, ms, fixes = [], tests = null }) {
    const known = nodes.get(id);
    if (!known) return;
    const entry = entries.get(id);
    if (entry) Object.assign(entry, { status, error, ms, fixes, tests: tests ?? entry.tests ?? null });
    const was = atBottom();
    known.node.classList.remove("running");
    known.node.classList.toggle("failed", status !== "ok");
    if (ms && known.head) known.head.append(element("span", "ms", ms < 1000 ? `${ms} ms` : `${(ms / 1000).toFixed(1)} s`));
    if (error) {
      const box = known.node.appendChild(element("pre", `error ${status}`, error));
      hooks.error?.(entry, box);
    }
    if (known.out) treeify(known.out);
    if (entry?.kind === "eval" && status === "ok") offerPin(entry, known);
    if (entry?.kind === "test" && entry.tests) showTests(entry.tests, known.node);
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

  // A finished entry's traces, as call trees.
  function treeify(out) {
    for (const pre of [...out.querySelectorAll(":scope > pre.stream.out")]) {
      const tree = renderOutput(pre.textContent);
      if (tree) pre.replaceWith(tree);
    }
  }

  // An evaluation of one expression that printed a result can be pinned.
  function offerPin(entry, known) {
    if (!["prompt", "buffer"].includes(entry.origin) || !(entry.out ?? []).some(([stream]) => stream === "result")) return;
    const found = forms(entry.line.trim());
    if (found.length !== 1 || found[0].head?.startsWith("define")) return;
    const pin = known.head.appendChild(element("button", "pin-action", "pin"));
    pin.title = `,pin ${entry.id}: keep this result as a check in tests.puf (,test runs them)`;
    pin.addEventListener("click", () => {
      run(`,pin ${entry.id}`);
      pin.disabled = true;
      pin.textContent = "pinned";
    });
  }

  // A ,test run: its counts, and each failure linked to its line.
  function showTests(run, node) {
    const box = node.appendChild(element("div", "test-run"));
    const counts = box.appendChild(element("div", "test-counts"));
    counts.append(element("span", "passed", `${run.passed} passed`));
    if (run.failed) counts.append(element("span", "failed", ` · ${run.failed} failed`));
    if (run.not_run) counts.append(element("span", "not-run", ` · ${run.not_run} not run`));
    if (run.stopped) {
      counts.append(element("span", "not-run", " · stopped in "));
      const where = counts.appendChild(element("a", "test-line", `tests.puf:${run.stopped}`));
      where.title = "Show the check the run stopped in: its expression failed, which ends the program";
      where.addEventListener("click", () => commands.reveal("tests.puf", run.stopped));
    }
    for (const result of run.results) {
      const row = box.appendChild(element("div", `test-result ${result.ok ? "ok" : "fail"}`));
      row.append(element("span", "mark", result.ok ? "✓" : "✗"));
      const code = row.appendChild(element("code", "", result.expression));
      if (result.line) {
        const where = row.appendChild(element("a", "test-line", `tests.puf:${result.line}`));
        where.title = "Show the check in tests.puf";
        where.addEventListener("click", () => commands.reveal("tests.puf", result.line));
      }
      if (result.detail) row.append(element("pre", "test-detail", result.detail));
      code.title = result.ok ? "prints as pinned" : "prints otherwise than pinned";
    }
  }

  // What an empty transcript says: where to start.
  function welcome() {
    transcript.append(element("div", "welcome", "Welcome to Puffin — press Run, or type a form here. ⌘↵ in the editor evaluates the form at the cursor; ,help lists the commands."));
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
        if (!list.length) welcome();
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
