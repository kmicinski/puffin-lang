// The compiler's assists at the cursor (docs/STUDIO.md §2.1, §5): ⌘. opens
// a menu of every assist that applies there, each labelled with where its
// knowledge came from (type, observed, patterns, call-site, in that order:
// the studio sorts them); the lightbulb offers the same as Monaco code
// actions. With a selection the compiler also offers `extract` (the
// selection as a new top-level function). Applying one is an ordinary
// undoable edit, echoed into the transcript as the command it is
// (`,assist fill-match main.puf:812`, `,assist extract main.puf:812-840`
// for a selection, `,assist fill-hole#2 main.puf:90` for the second of
// several with one id), which typed at the prompt does the same. On an
// observation lint marker the lightbulb leads with the observed cases.
//
// Hovering shows the facts at a point (facts.js): the type, from the
// checker, and what the session saw a parameter receive, from runs.
//
//   createAssists({ editor, files, send, note, facts }) -> { open, run, receive, setAvailable }
//   facts(file, pos, full)   the studio's facts at a point (facts.js)

import { LINT_SOURCE } from "./lint.js";

const element = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

const SOURCES = {
  type: "from the type (the checker)",
  observed: "from values this session's runs passed (seen so far, not proof)",
  patterns: "from patterns in the file",
  "call-site": "from the call site",
  syntax: "from the syntax",
};

// How a source is badged in the menu.
const BADGES = { observed: "▶ seen" };
export const badge = (source) => BADGES[source] ?? source;

export function createAssists({ editor, files, send, note, facts }) {
  const waiting = new Map(); // seq -> resolve
  let seq = 0;
  let available = false;
  const menu = document.body.appendChild(element("div", "assist-menu"));
  menu.hidden = true;
  let shown = null; // { file, assists, index }

  // Ask the studio, behind any edit still in flight.
  function request(message) {
    files.flush();
    const id = ++seq;
    return new Promise((resolve) => {
      waiting.set(id, resolve);
      files.send({ ...message, seq: id });
    });
  }

  // The assists at UTF-16 offset `pos` of `file` (for the selection [pos,
  // end) when `end` is given), or { error }.
  async function at(file, pos, end = null) {
    const reply = await request({ t: "assists", file, pos, ...(end !== null && end > pos ? { end } : {}) });
    if (reply.version !== files.version(file) || !files.synced(file)) {
      return { error: "the text changed while the compiler looked; try again", assists: [] };
    }
    return reply;
  }

  // ⌘.: the menu at the cursor.
  async function open() {
    const file = files.active();
    if (!file) return;
    if (!available) return note("assists unavailable: this puffincc has no --assist yet");
    const { start, end } = editor.selection();
    // F8 selects a hole: that is a point to fill, not a selection to extract
    const point = start === end || editor.get().slice(start, end).trim() === "??";
    const reply = point ? await at(file, start === end ? end : start) : await at(file, start, end);
    if (!reply.assists?.length) return note(reply.error ? `no assists: ${reply.error}` : "no assist applies here");
    shown = { file, assists: reply.assists, index: 0, stopped: reply.error };
    renderMenu();
  }

  function renderMenu() {
    menu.replaceChildren();
    menu.append(element("div", "assist-menu-head", "Assists from the compiler"));
    shown.assists.forEach((assist, i) => {
      const item = menu.appendChild(element("button", `assist-item${i === shown.index ? " chosen" : ""}`));
      item.append(element("span", "title", assist.title), element("span", `source source-${assist.source}`, badge(assist.source)));
      item.title = SOURCES[assist.source] ?? assist.source;
      item.addEventListener("mousedown", (event) => { event.preventDefault(); choose(i); });
    });
    if (shown.stopped) menu.append(element("div", "assist-menu-foot", "the checker stopped early; there may be more"));
    const box = editor.caretBox();
    menu.hidden = false;
    if (box) {
      menu.style.left = `${Math.min(box.left, innerWidth - menu.offsetWidth - 12)}px`;
      const below = box.top + box.height + 4;
      menu.style.top = `${below + menu.offsetHeight > innerHeight ? box.top - menu.offsetHeight - 4 : below}px`;
    }
  }

  function close() {
    shown = null;
    menu.hidden = true;
  }

  function choose(i) {
    const { file, assists } = shown;
    close();
    apply(file, assists[i], assists);
    editor.focus();
  }

  // Make `assist`'s edits in `file` (shown), and echo the command.
  function apply(file, assist, list = null) {
    if (files.active() !== file) files.open(file);
    editor.edits(assist.edits.map(({ start, end, text }) => ({ start, end, text })));
    send({ t: "echo", line: commandOf(file, assist, list) });
  }

  document.addEventListener("keydown", (event) => {
    if (!shown) return;
    const keys = {
      ArrowDown: () => { shown.index = (shown.index + 1) % shown.assists.length; renderMenu(); },
      ArrowUp: () => { shown.index = (shown.index + shown.assists.length - 1) % shown.assists.length; renderMenu(); },
      Enter: () => choose(shown.index),
      Tab: () => choose(shown.index),
      Escape: close,
    };
    const handle = keys[event.key];
    if (handle) {
      event.preventDefault();
      event.stopPropagation();
      handle();
    } else if (!["Shift", "Meta", "Control", "Alt"].includes(event.key)) close();
  }, { capture: true });
  document.addEventListener("pointerdown", (event) => { if (shown && !menu.contains(event.target)) close(); });

  // `,assist ID FILE:POS` (or FILE:POS-END) typed at the prompt: byte
  // offsets; ID#N is the Nth assist with that id.
  async function run(label, file, bytes, endBytes = null) {
    if (!files.paths().includes(file)) return note(`no file ${file}`);
    if (files.active() !== file) files.open(file);
    const text = files.texts()[file] ?? "";
    const reply = await at(file, utf16Of(text, bytes), endBytes === null ? null : utf16Of(text, endBytes));
    const [, id, nth] = /^(.*?)(?:#(\d+))?$/.exec(label);
    const assist = (reply.assists ?? []).filter((a) => a.id === id)[(Number(nth) || 1) - 1];
    if (!assist) return note(`no assist ${label} applies at ${file}:${bytes}${reply.error ? ` (${reply.error})` : ""}`);
    apply(file, assist, reply.assists);
  }

  // ---- Monaco: the lightbulb and the hover ---------------------------------

  if (editor.raw) {
    const { monaco, editor: monacoEditor } = editor.raw;
    const echo = monacoEditor.addCommand(0, (_, line) => send({ t: "echo", line }));
    monaco.languages.registerCodeActionProvider("puffin", {
      async provideCodeActions(model, range, context) {
        const file = editor.keyOf(model);
        if (!available || !file || file !== files.active()) return { actions: [], dispose() {} };
        const version = model.getVersionId();
        const from = model.getOffsetAt(range.getStartPosition());
        const to = model.getOffsetAt(range.getEndPosition());
        const point = from === to || model.getValue().slice(from, to).trim() === "??";
        const reply = point ? await at(file, from) : await at(file, from, to);
        // an observation lint marker here: the observed cases, from inside its match
        const seen = (context?.markers ?? []).filter((marker) => marker.source === LINT_SOURCE);
        const fixes = [];
        for (const marker of seen) {
          const inside = model.getOffsetAt({ lineNumber: marker.startLineNumber, column: marker.startColumn }) + 1;
          const found = await at(file, inside);
          for (const assist of found.assists ?? []) {
            if (["observed", "call-site"].includes(assist.source) && assist.id === "add-missing-cases") fixes.push({ assist, marker });
          }
        }
        if (model.getVersionId() !== version) return { actions: [], dispose() {} };
        const action = (assist, list, marker = null) => ({
          title: `${assist.title}  ·  ${badge(assist.source)}`,
          kind: "quickfix",
          isPreferred: Boolean(marker),
          diagnostics: marker ? [marker] : undefined,
          edit: {
            edits: assist.edits.map(({ start, end, text }) => ({
              resource: model.uri,
              versionId: version,
              textEdit: { range: monaco.Range.fromPositions(model.getPositionAt(start), model.getPositionAt(end)), text },
            })),
          },
          command: { id: echo, title: "echo", arguments: [commandOf(file, assist, list)] },
        });
        const listed = reply.assists ?? [];
        const actions = [
          ...fixes.map(({ assist, marker }) => action(assist, [assist], marker)),
          ...listed.filter((assist) => !fixes.some(({ assist: fix }) => sameEdits(fix, assist))).map((assist) => action(assist, listed)),
        ];
        return { actions, dispose() {} };
      },
    });
    monaco.languages.registerHoverProvider("puffin", {
      async provideHover(model, position) {
        const file = editor.keyOf(model);
        if (!available || !file || file !== files.active() || !files.synced(file)) return null;
        const word = model.getWordAtPosition(position);
        if (!word) return null;
        const version = model.getVersionId();
        const reply = await facts(file, model.getOffsetAt(position), false);
        if (model.getVersionId() !== version) return null;
        const contents = hover(word.word, reply.facts);
        if (!contents.length) return null;
        return { range: new monaco.Range(position.lineNumber, word.startColumn, position.lineNumber, word.endColumn), contents };
      },
    });
  }

  return {
    open,
    run,
    at,
    setAvailable(on) { available = on; },
    receive: {
      assists(reply) {
        waiting.get(reply.seq)?.({ ...reply, error: reply.error ?? null });
        waiting.delete(reply.seq);
      },
      type(reply) {
        waiting.get(reply.seq)?.(reply);
        waiting.delete(reply.seq);
      },
    },
  };
}

// The command applying `assist` in `file` is: `,assist ID FILE:POS`, with
// `-END` for a selection and `#N` when `list` (what the menu offered) has
// several with its id.
export function commandOf(file, assist, list = null) {
  const same = (list ?? []).filter((a) => a.id === assist.id && a.pos === assist.pos);
  const nth = same.length > 1 ? `#${same.indexOf(assist) + 1}` : "";
  return `,assist ${assist.id}${nth} ${file}:${assist.pos}${assist.end !== undefined ? `-${assist.end}` : ""}`;
}

const sameEdits = (a, b) => a.id === b.id && JSON.stringify(a.edits) === JSON.stringify(b.edits);

// A hover's parts from the facts at a point, each saying where it came
// from: the type from the checker (a hole's goal), the shapes from runs.
export function hover(word, facts) {
  const contents = [];
  if (facts?.goal) contents.push({ value: `\`${word}\` — a typed hole, goal \`${facts.goal}\`\n\n*from the checker · ⌘. for its candidates · F8 the next hole*` });
  else if (facts?.type) contents.push({ value: `\`${word} : ${facts.type}\`\n\n*from the checker*` });
  const seen = facts?.observed;
  if (seen && (seen.patterns?.length || seen.shapes?.length)) {
    const calls = `${seen.calls} call${seen.calls === 1 ? "" : "s"}`;
    const list = seen.patterns?.length ? seen.patterns : seen.shapes;
    const fence = "```";
    contents.push({
      value: `**${seen.function}**'s argument \`${seen.param}\` — seen in ${calls}:\n\n${fence}\n${list.join("\n")}\n${fence}\n\n*observed in this session${seen.patterns?.length ? "" : " (shapes)"}*`,
    });
  }
  return contents;
}

// The UTF-16 offset of UTF-8 byte offset `bytes` into `text`.
export function utf16Of(text, bytes) {
  const encoder = new TextEncoder();
  let seen = 0;
  let i = 0;
  for (const c of text) {
    if (seen >= bytes) return i;
    seen += encoder.encode(c).length;
    i += c.length;
  }
  return text.length;
}
