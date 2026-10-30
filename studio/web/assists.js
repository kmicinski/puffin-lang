// The compiler's assists at the cursor (docs/STUDIO.md §2.1, §5): ⌘. opens
// a menu of every assist that applies there, each labelled with where its
// knowledge came from (type, patterns, call-site); the lightbulb offers the
// same as Monaco code actions; hovering shows the type at a point. Applying
// one is an ordinary undoable edit, echoed into the transcript as the
// command it is (`,assist fill-match main.puf:812`), which typed at the
// prompt does the same.
//
//   createAssists({ editor, files, send, note }) -> { open, run, receive, setAvailable }

const element = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

const SOURCES = { type: "from the type", patterns: "from patterns in the file", "call-site": "from the call site", syntax: "from the syntax" };

export function createAssists({ editor, files, send, note }) {
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

  // The assists at UTF-16 offset `pos` of `file`, or { error }.
  async function at(file, pos) {
    const reply = await request({ t: "assists", file, pos });
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
    const pos = editor.selection().end;
    const reply = await at(file, pos);
    if (!reply.assists?.length) return note(reply.error ? `no assists: ${reply.error}` : "no assist applies here");
    shown = { file, assists: reply.assists, index: 0, stopped: reply.error };
    renderMenu();
  }

  function renderMenu() {
    menu.replaceChildren();
    menu.append(element("div", "assist-menu-head", "Assists from the compiler"));
    shown.assists.forEach((assist, i) => {
      const item = menu.appendChild(element("button", `assist-item${i === shown.index ? " chosen" : ""}`));
      item.append(element("span", "title", assist.title), element("span", `source source-${assist.source}`, assist.source));
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
    apply(file, assists[i]);
    editor.focus();
  }

  // Make `assist`'s edits in `file` (shown), and echo the command.
  function apply(file, assist) {
    if (files.active() !== file) files.open(file);
    editor.edits(assist.edits.map(({ start, end, text }) => ({ start, end, text })));
    send({ t: "echo", line: `,assist ${assist.id} ${file}:${assist.pos}` });
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

  // `,assist ID FILE:POS` typed at the prompt: POS is a byte offset.
  async function run(id, file, bytes) {
    if (!files.paths().includes(file)) return note(`no file ${file}`);
    if (files.active() !== file) files.open(file);
    const text = files.texts()[file] ?? "";
    const pos = utf16Of(text, bytes);
    const reply = await at(file, pos);
    const assist = reply.assists?.find((a) => a.id === id);
    if (!assist) return note(`no assist ${id} applies at ${file}:${bytes}${reply.error ? ` (${reply.error})` : ""}`);
    apply(file, assist);
  }

  // ---- Monaco: the lightbulb and the hover ---------------------------------

  if (editor.raw) {
    const { monaco, editor: monacoEditor } = editor.raw;
    const echo = monacoEditor.addCommand(0, (_, line) => send({ t: "echo", line }));
    monaco.languages.registerCodeActionProvider("puffin", {
      async provideCodeActions(model, range) {
        const file = editor.keyOf(model);
        if (!available || !file || file !== files.active()) return { actions: [], dispose() {} };
        const version = model.getVersionId();
        const reply = await at(file, model.getOffsetAt(range.getEndPosition()));
        if (model.getVersionId() !== version) return { actions: [], dispose() {} };
        const actions = (reply.assists ?? []).map((assist) => ({
          title: `${assist.title}  ·  ${assist.source}`,
          kind: "quickfix",
          edit: {
            edits: assist.edits.map(({ start, end, text }) => ({
              resource: model.uri,
              versionId: version,
              textEdit: { range: monaco.Range.fromPositions(model.getPositionAt(start), model.getPositionAt(end)), text },
            })),
          },
          command: { id: echo, title: "echo", arguments: [`,assist ${assist.id} ${file}:${assist.pos}`] },
        }));
        return { actions, dispose() {} };
      },
    });
    monaco.languages.registerHoverProvider("puffin", {
      async provideHover(model, position) {
        const file = editor.keyOf(model);
        if (!available || !file || file !== files.active() || !files.synced(file)) return null;
        const word = model.getWordAtPosition(position);
        if (!word) return null;
        const reply = await request({ t: "type-at", file, pos: model.getOffsetAt(position) });
        if (!reply.type) return null;
        return {
          range: new monaco.Range(position.lineNumber, word.startColumn, position.lineNumber, word.endColumn),
          contents: [{ value: `\`${word.word} : ${reply.type}\`` }],
        };
      },
    });
  }

  return {
    open,
    run,
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
