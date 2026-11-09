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
import { enclosing, parse } from "./sexp.js";

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

  // The clause patterns the match at UTF-16 offset `pos` still lacks
  // (`--assist complete`): [{ pattern, clause, source }], or [].
  async function complete(file, pos) {
    const reply = await request({ t: "complete", file, pos });
    if (reply.version !== files.version(file) || !files.synced(file)) return [];
    return reply.candidates ?? [];
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
    // Completing a match clause: at a clause's pattern (typing `[` or `(`
    // there, or M-/), the patterns the analysis says the match still
    // lacks -- the type's constructors not yet covered, the shapes the
    // session saw, the shapes the file's call sites pass. Each inserts
    // the pattern and leaves the cursor at the body.
    monaco.languages.registerCompletionItemProvider("puffin", {
      triggerCharacters: ["[", "("],
      async provideCompletionItems(model, position) {
        const file = editor.keyOf(model);
        if (!available || !file || file !== files.active()) return { suggestions: [] };
        const text = model.getValue();
        const pos = model.getOffsetAt(position);
        const slot = clauseSlot(text, pos);
        if (!slot) return { suggestions: [] };
        const version = model.getVersionId();
        const found = await complete(file, pos);
        if (model.getVersionId() !== version) return { suggestions: [] };
        const seen = new Set();
        const range = monaco.Range.fromPositions(model.getPositionAt(slot.start), model.getPositionAt(slot.end));
        const suggestions = [];
        for (const { pattern, clause, source } of found) {
          if (seen.has(pattern)) continue;
          seen.add(pattern);
          const text = slot.inClause ? `${pattern} $0` : `${slot.touching ? " " : ""}${clause[0]}${pattern} $0${clause.at(-1)}`;
          suggestions.push({
            label: pattern,
            kind: monaco.languages.CompletionItemKind.EnumMember,
            detail: badge(source),
            documentation: `a case the match still lacks · ${SOURCE_NOTE[source] ?? source}`,
            insertText: text,
            insertTextRules: monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet,
            filterText: pattern,
            sortText: String(suggestions.length).padStart(3, "0"),
            range,
          });
        }
        return { suggestions };
      },
    });
    // The rest of the match, before it is written: where a whole clause
    // could go (a fresh line in a match, or right after its scrutinee or
    // last clause) every clause the analysis says is still missing is
    // shown as ghost text with ?? for its body. Tab takes them all;
    // typing on, or Escape, declines; typing `[` narrows to the list.
    monaco.languages.registerInlineCompletionsProvider("puffin", {
      async provideInlineCompletions(model, position) {
        const file = editor.keyOf(model);
        if (!available || !file || file !== files.active()) return { items: [] };
        const text = model.getValue();
        const pos = model.getOffsetAt(position);
        const where = restSlot(text, pos);
        if (!where) return { items: [] };
        const version = model.getVersionId();
        const found = await complete(file, pos);
        if (model.getVersionId() !== version) return { items: [] };
        const seen = new Set();
        const clauses = [];
        for (const { pattern, clause } of found) {
          if (seen.has(pattern)) continue;
          seen.add(pattern);
          clauses.push(`${clause[0]}${pattern} ??${clause.at(-1)}`);
        }
        if (!clauses.length) return { items: [] };
        const indent = " ".repeat(where.indent);
        const insertText = (where.newline ? `\n${indent}` : " ".repeat(where.pad)) + clauses.join(`\n${indent}`);
        return { items: [{ insertText, range: monaco.Range.fromPositions(position, position) }] };
      },
      freeInlineCompletions() {},
    });
    // Tab takes the ghost text: paredit.js's Tab, which else re-indents.
    // Monaco asks for ghost text as one types; arriving at such a place by
    // cursor alone asks too, once the cursor rests.
    let resting = null;
    monacoEditor.onDidChangeCursorPosition((event) => {
      clearTimeout(resting);
      if (event.reason !== monaco.editor.CursorChangeReason.Explicit) return;
      const model = monacoEditor.getModel();
      const file = editor.keyOf(model);
      if (!available || !file || file !== files.active()) return;
      const pos = model.getOffsetAt(event.position);
      if (!restSlot(model.getValue(), pos)) return;
      resting = setTimeout(() => {
        if (model.getOffsetAt(monacoEditor.getPosition()) === pos) monacoEditor.trigger("puffin", "editor.action.inlineSuggest.trigger", {});
      }, 250);
    });
    // Paredit inserts a typed bracket itself (paredit.js), so Monaco sees
    // no trigger character: a bracket that opens a clause asks here.
    monacoEditor.onDidChangeModelContent((event) => {
      if (event.isUndoing || event.isRedoing || event.changes.length !== 1) return;
      const { range, text } = event.changes[0];
      if (!["[", "[]", "(", "()"].includes(text)) return;
      const model = monacoEditor.getModel();
      const file = editor.keyOf(model);
      if (!available || !file || file !== files.active()) return;
      const inside = model.getOffsetAt(range.getStartPosition()) + 1;
      if (!clauseSlot(model.getValue(), inside)?.inClause) return;
      setTimeout(() => {
        if (model.getOffsetAt(monacoEditor.getPosition()) === inside) monacoEditor.trigger("puffin", "editor.action.triggerSuggest", {});
      }, 0);
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
    complete,
    setAvailable(on) { available = on; },
    receive: {
      assists(reply) {
        waiting.get(reply.seq)?.({ ...reply, error: reply.error ?? null });
        waiting.delete(reply.seq);
      },
      completions(reply) {
        waiting.get(reply.seq)?.(reply);
        waiting.delete(reply.seq);
      },
      type(reply) {
        waiting.get(reply.seq)?.(reply);
        waiting.delete(reply.seq);
      },
    },
  };
}

const SOURCE_NOTE = {
  type: "the scrutinee's type, from the checker",
  observed: "a shape this session's runs passed",
  "call-site": "a shape a call in this file passes",
  patterns: "the type the match's constructor patterns are of (the scrutinee is untyped)",
  declared: "the one type this program declares (the scrutinee is untyped)",
};

// Where a clause pattern would go at `pos`, or null: inside a clause of a
// match, at or in its first element (`inClause`: the pattern alone goes
// there, replacing [start, end)); or directly in a match after its
// scrutinee, where a whole clause goes (`touching`: right after it,
// with no space yet).
export function clauseSlot(text, pos) {
  const root = parse(text);
  const list = enclosing(root, pos);
  const isMatch = (node) => node.kind === "list" && node.children[0]?.kind === "word" && text.slice(node.children[0].start, node.children[0].end) === "match";
  if (isMatch(list)) {
    const scrutinee = list.children[1];
    return scrutinee && pos >= scrutinee.end ? { start: pos, end: pos, inClause: false, match: list, touching: pos === scrutinee.end } : null;
  }
  const match = list.parent;
  if (!match || !isMatch(match) || match.children.indexOf(list) < 2) return null;
  const first = list.children.find((child) => child.kind !== "comment");
  if (first && pos > first.end) return null;
  const start = list.start + 1;
  const end = first && pos >= first.start ? first.end : pos;
  return { start, end: Math.max(end, pos), inClause: true };
}

// Where the rest of a match could be shown at `pos`, or null: a whole-
// clause slot with nothing but closing brackets after it on the line.
// `indent` is the column the clauses go at; `newline` says they start
// on a new line (the cursor is after the scrutinee or a clause, not on
// a line of its own); else `pad` is the spaces the first clause needs
// to reach that column from the cursor.
export function restSlot(text, pos) {
  const slot = clauseSlot(text, pos);
  if (!slot || slot.inClause) return null;
  const lineStart = text.lastIndexOf("\n", pos - 1) + 1;
  const lineEnd = text.indexOf("\n", pos);
  if (!/^[ \t\])]*$/.test(text.slice(pos, lineEnd < 0 ? text.length : lineEnd))) return null;
  const column = (at) => at - (text.lastIndexOf("\n", at - 1) + 1);
  const before = slot.match.children.filter((child) => child.kind !== "comment" && child.end <= pos);
  const indent = before.length > 2 ? column(before.at(-1).start) : column(slot.match.start) + 2;
  if (!/^[ \t]*$/.test(text.slice(lineStart, pos))) return { indent, newline: true, pad: 0 };
  // on a line of its own: Enter only copied the line above's indent, so
  // the first clause is padded out to the structural one (or kept where
  // a deeper indent was typed on purpose)
  const here = pos - lineStart;
  return { indent: Math.max(indent, here), newline: false, pad: Math.max(0, indent - here) };
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
