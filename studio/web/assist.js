// The assistant at the prompt (docs/STUDIO.md §6; studio/src/ask.rs), its
// mode mechanics ported from Slog Studio's assist.js.
//
// Ask mode: `??` at the start of the prompt, or Tab on an empty one, turns
// the prompt into a question for the assistant; Esc turns it back. The
// scope selector beside the prompt says what the answer may change: the
// selection, the form at the cursor (the default), the module, or the
// whole program. Answers stream into the transcript, where the expressions
// they suggest (```repl blocks) become chips to run or to insert into the
// prompt, and the changes they propose a chip to view and accept. Each
// question is a thread, so questions asked before leaving ask mode follow
// up on it.
//
//   initAssist({ prompt, scopeSelect, send, repl, context, proposalChip })
//     -> { receive, ask }
//   context()          { file, selection, cursor } of the editor
//   proposalChip(ids)  the chip for proposals (proposals.js)

import { markdown } from "./markdown.js";
import { balanced } from "./lexer.js";

// The question, when `text` asks for ask mode: `??` and what follows.
export function asking(text) {
  const match = text.match(/^\s*\?\?\s?([\s\S]*)$/);
  return match ? match[1] : null;
}

// A ```repl block's expressions: one a line, or several lines while
// brackets stay open, each with its `;` comment as a note.
export function steps(text) {
  const out = [];
  let open = null;
  for (const raw of text.split("\n")) {
    const [command, note] = comment(raw);
    if (open) {
      open.command += `\n${command}`;
      if (note) open.note = [open.note, note].filter(Boolean).join(" ");
    } else if (command.trim()) {
      open = { command: command.trim(), note };
    } else continue;
    if (balanced(open.command)) {
      out.push(open);
      open = null;
    }
  }
  if (open) out.push(open);
  return out;
}

// The `;` comment ending a line, outside strings: [code, comment].
function comment(line) {
  for (let i = 0; i < line.length; i++) {
    if (line[i] === "\"") {
      for (i++; i < line.length && line[i] !== "\""; i++) if (line[i] === "\\") i++;
    } else if (line[i] === ";") {
      return [line.slice(0, i).trimEnd(), line.slice(i).replace(/^;+\s*/, "").trim()];
    }
  }
  return [line.trimEnd(), ""];
}

const element = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

// What a tool call did, in a few words.
function describe(data) {
  const input = data.input ?? {};
  const at = input.file ? `${input.file}${input.line ? `:${input.line}` : input.pos !== undefined ? `@${input.pos}` : ""}` : "";
  switch (data.name) {
    case "list_files": return "listed the files";
    case "get_file": return `read ${input.file ?? ""}`;
    case "check": return "checked the program";
    case "assists_at": return `asked the compiler for assists at ${at}`;
    case "apply_assist": return `proposed assist ${input.id ?? ""} at ${at}${data.op ? ` (#${data.op})` : ""}`;
    case "type_at": return `asked the type at ${at}`;
    case "facts_at": return `read the facts at ${at}`;
    case "propose_edit": return `proposed a change to ${input.file ?? ""}${data.op ? ` (#${data.op})` : ""}`;
    case "get_proposals": return "looked at its proposals";
    case "evaluate": return `evaluated ${(input.expr ?? "").split("\n")[0].slice(0, 80)}`;
    case "evaluate_program": return `ran ${input.file ?? "the program"}`;
    case "search_docs": return `searched the docs for “${input.query ?? ""}”`;
    case "read_doc": return `read ${input.path ?? ""}`;
    default: return data.name ?? "tool";
  }
}

const PHASES = { thinking: "Thinking…", replying: "Writing…" };

export function initAssist({ prompt, scopeSelect, send, repl, context, proposalChip }) {
  const row = prompt.closest(".prompt-row");
  const caret = row.querySelector(".caret");
  const plainPlaceholder = prompt.placeholder;
  const tag = row.appendChild(element("button", "assist-tag"));
  tag.type = "button";

  const state = {
    mode: "puffin",
    thread: null,         // the thread a question follows up on
    threads: new Map(),   // id -> { id, title, messages, running }
    blocks: new Map(),    // `${thread}:${turn}` -> the turn's block
    drafts: new Map(),    // thread -> the reply streaming in
    phases: new Map(),    // thread -> what it is doing
    asked: [],
    askedIndex: 0,
  };

  // ---- Modes ----------------------------------------------------------------

  function setMode(mode, { keepThread = false } = {}) {
    state.mode = mode;
    prompt.dataset.mode = mode === "ask" ? "ask" : "";
    row.classList.toggle("ask", mode === "ask");
    caret.textContent = mode === "ask" ? "✦" : "›";
    scopeSelect.hidden = mode !== "ask";
    prompt.placeholder = mode === "ask"
      ? "Ask about the program, an error, what to write next. Enter asks · Esc back to Puffin"
      : plainPlaceholder;
    if (mode === "puffin" && !keepThread) state.thread = null;
    renderTag();
  }

  function renderTag() {
    tag.hidden = state.mode !== "ask";
    const title = state.thread ? state.threads.get(state.thread)?.title : null;
    tag.textContent = state.thread ? `follow-up: ${title ?? "this thread"} ×` : "new question";
    tag.title = state.thread ? "Ask a new question instead" : "Esc returns to Puffin";
  }
  tag.addEventListener("click", () => {
    state.thread = null;
    renderTag();
    prompt.focus();
  });

  function setPrompt(text) {
    prompt.value = text;
    prompt.dispatchEvent(new Event("input"));
  }

  // Open ask mode, following up on `thread`, with `text` to send.
  function ask({ text = "", thread = null } = {}) {
    setMode("ask");
    state.thread = thread;
    renderTag();
    setPrompt(text);
    prompt.focus();
    prompt.setSelectionRange(0, text.length);
  }

  // `??` switches; the question is what follows it.
  prompt.addEventListener("input", () => {
    if (state.mode !== "puffin") return;
    const question = asking(prompt.value);
    if (question !== null) {
      setMode("ask", { keepThread: true });
      prompt.value = question;
    }
  }, { capture: true });

  prompt.addEventListener("keydown", (event) => {
    if (event.isComposing) return;
    const empty = !prompt.value.trim();
    if (event.key === "Tab" && !event.shiftKey && empty && !event.ctrlKey && !event.altKey && !event.metaKey) {
      event.preventDefault();
      event.stopImmediatePropagation();
      setMode(state.mode === "ask" ? "puffin" : "ask", { keepThread: true });
      return;
    }
    if (state.mode === "puffin") return;
    // ask mode: the prompt's Puffin keys stand aside
    event.stopImmediatePropagation();
    if (event.key === "Escape") {
      event.preventDefault();
      setMode("puffin");
    } else if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      submit();
    } else if (event.key === "ArrowUp" && !prompt.value.slice(0, prompt.selectionStart).includes("\n") && state.askedIndex > 0) {
      event.preventDefault();
      setPrompt(state.asked[--state.askedIndex]);
    } else if (event.key === "ArrowDown" && !prompt.value.slice(prompt.selectionEnd).includes("\n") && state.askedIndex < state.asked.length) {
      event.preventDefault();
      setPrompt(state.asked[++state.askedIndex] ?? "");
    }
  }, { capture: true });

  // the scope: remembered, and a selection preferred when there is one
  try { scopeSelect.value = localStorage.getItem("puffin-studio.scope") || "form"; } catch { /* private mode */ }
  scopeSelect.addEventListener("change", () => {
    try { localStorage.setItem("puffin-studio.scope", scopeSelect.value); } catch { /* private mode */ }
    prompt.focus();
  });

  function submit() {
    const message = prompt.value.trim();
    if (!message) return;
    state.asked = [...state.asked.filter((asked) => asked !== message), message].slice(-100);
    state.askedIndex = state.asked.length;
    const focus = context();
    let scope = scopeSelect.value;
    if (scope === "selection" && !(focus.selection && focus.selection[0] !== focus.selection[1])) scope = "form";
    send({ t: "ask", thread: state.thread, message, context: { ...focus, scope } });
    setPrompt("");
  }

  // ---- Answers in the transcript ----------------------------------------------

  // A thread's messages split into turns, each beginning with the question.
  function turnsOf(thread) {
    const turns = [];
    for (const message of thread?.messages ?? []) {
      if (message.role === "user" || !turns.length) turns.push([]);
      turns.at(-1).push(message);
    }
    return turns;
  }

  // Draw the block of transcript entry `entry` (kind "ask") into `node`.
  function mount(entry, node) {
    const key = `${entry.thread}:${entry.turn}`;
    const block = {
      node,
      thread: entry.thread,
      turn: entry.turn,
      line: node.appendChild(element("div", "line", entry.line)),
      body: node.appendChild(element("div", "md assist-body")),
      activity: node.appendChild(element("div", "assist-activity")),
      foot: node.appendChild(element("div", "assist-foot")),
    };
    node.classList.add("assist");
    if (entry.turn > 0) node.classList.add("follow");
    state.blocks.set(key, block);
    render(block);
  }

  function render(block) {
    const thread = state.threads.get(block.thread);
    const turns = turnsOf(thread);
    const messages = (turns[block.turn] ?? []).slice(1);
    const last = block.turn === turns.length - 1;
    const running = Boolean(thread?.running) && last;
    const done = !running;
    const was = nearBottom();
    const texts = messages.filter((m) => m.role === "assistant").map((m) => m.text);
    const draft = running ? state.drafts.get(block.thread) ?? "" : "";
    // markdown() escapes all of the model's text
    block.body.innerHTML = markdown([...texts, draft].filter(Boolean).join("\n\n"));
    const calls = messages.filter((m) => m.role === "tool").map((m) => m.data ?? {});
    if (calls.length) {
      const list = element("details", "assist-calls");
      const failed = calls.filter((call) => call.status === "error").length;
      list.append(element("summary", "", `${calls.length} step${calls.length === 1 ? "" : "s"}${failed ? ` · ${failed} refused or failed` : ""}`));
      for (const call of calls) {
        const item = list.appendChild(element("div", `assist-call ${call.status ?? ""}`));
        item.append(element("span", "mark", call.status === "error" ? "✗" : call.status === "running" ? "…" : "✓"), element("span", "", describe(call)));
        if (call.result) item.title = call.result;
      }
      block.body.prepend(list);
    }
    if (done) chips(block);
    const proposed = [...new Set(calls.filter((call) => call.op && call.status === "ok").map((call) => call.op))];
    const chip = proposed.length && proposalChip(proposed);
    if (chip) block.body.append(chip);
    for (const message of messages.filter((m) => m.role === "error" || m.role === "notice")) {
      block.body.append(element("div", message.role === "error" ? "error" : "note", message.text));
    }
    block.activity.hidden = done;
    block.activity.textContent = state.phases.get(block.thread) ?? "Asking…";
    block.foot.replaceChildren();
    if (running) {
      const stop = block.foot.appendChild(element("a", "", "Stop"));
      stop.addEventListener("click", () => send({ t: "stop-thread", thread: block.thread }));
    } else {
      const turn = messages.find((m) => m.role === "turn")?.data;
      const parts = [turn?.ms ? `${(turn.ms / 1000).toFixed(1)} s` : "", turn?.cost ? `$${Number(turn.cost).toFixed(3)}` : ""];
      block.foot.append(element("span", "", parts.filter(Boolean).join(" · ")));
      const follow = block.foot.appendChild(element("a", "", "Follow up"));
      follow.addEventListener("click", () => ask({ thread: block.thread }));
    }
    if (was) repl.scroll?.();
  }

  const nearBottom = () => {
    const t = document.getElementById("transcript");
    return t.scrollHeight - t.scrollTop - t.clientHeight < 60;
  };

  // An answer's ```repl blocks as chips.
  function chips(block) {
    for (const code of block.body.querySelectorAll(".code-block")) {
      const lang = code.querySelector(".code-lang")?.textContent;
      if (lang !== "repl") continue;
      const list = steps(code.querySelector("pre").textContent);
      if (!list.length) continue;
      const box = element("div", "assist-chips");
      for (const step of list) box.append(chip(step));
      code.replaceWith(box);
    }
  }

  function chip(step) {
    const item = element("div", "assist-step");
    const code = item.appendChild(element("code", "", step.command));
    code.title = "Insert into the prompt to edit";
    code.addEventListener("click", () => insert(step.command));
    const run = item.appendChild(element("button", "small primary", "Run"));
    run.title = "Run it at the prompt, as typing it would";
    run.addEventListener("click", () => {
      repl.run(step.command);
      item.classList.add("done");
    });
    const edit = item.appendChild(element("button", "small secondary", "Insert"));
    edit.title = "Put it in the prompt to edit";
    edit.addEventListener("click", () => insert(step.command));
    if (step.note) item.append(element("div", "note", step.note));
    return item;
  }

  // Into the prompt, in Puffin mode: a follow-up question stays possible.
  function insert(command) {
    setMode("puffin", { keepThread: true });
    repl.insert(command);
  }

  function rerender(thread) {
    for (const block of state.blocks.values()) if (block.thread === thread) render(block);
  }

  // "Ask why" on an evaluation's error.
  repl.hooks.error = (entry, box) => {
    if (!entry || entry.kind !== "eval") return;
    const why = box.appendChild(element("a", "assist-why", "✦ ask why"));
    why.title = "Ask the assistant why this failed";
    why.addEventListener("click", () => ask({ text: `Why did \`${entry.line.split("\n")[0].slice(0, 80)}\` fail, and how do I fix it?` }));
  };
  repl.hooks.renderAsk = mount;

  return {
    ask,
    receive: {
      review({ threads }) {
        for (const thread of threads) state.threads.set(thread.id, thread);
        for (const thread of threads) rerender(thread.id);
        renderTag();
      },
      agent({ thread, kind, text = "", index, entry }) {
        const known = state.threads.get(thread);
        if (kind === "delta") state.drafts.set(thread, (state.drafts.get(thread) ?? "") + text);
        else if (kind === "phase") state.phases.set(thread, PHASES[text] ?? (text.startsWith("tool ") ? "Working…" : "Working…"));
        else if (kind === "entry" && known && entry) {
          known.messages[index] = entry;
          if (entry.role === "assistant") state.drafts.set(thread, "");
          if (entry.role === "tool" && entry.data?.status === "running") state.phases.set(thread, `${describe(entry.data)}…`);
        } else if (kind === "start") {
          state.drafts.set(thread, "");
          if (known) known.running = true;
        } else if (kind === "done") {
          state.drafts.delete(thread);
          if (known) known.running = false;
        } else return;
        rerender(thread);
      },
      asked({ thread, error }) {
        if (error) {
          repl.local?.("?? …", error, true);
          return;
        }
        if (state.mode === "ask") state.thread = thread;
        renderTag();
      },
    },
  };
}
