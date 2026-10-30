// The project's files: the editor's file tabs (as the playground's), and
// the edits each file sends to the studio.
//
// The studio owns every file's text. This tab sends a file's whole text with
// the version it was edited from, and the studio takes it or refuses it with
// the current text. One edit is in flight at a time, and every message sent
// through `send` waits behind it, so each edit's base is a version the studio
// named, and an evaluation sent after typing sees the typing.

const $ = (id) => document.getElementById(id);
const EDIT_DELAY = 150;

// `onOpen(path)` is called when a file is shown in the editor, and
// `onTexts()` whenever a file's text as this tab has it may have changed.
export function createFiles({ editor, transmit, note, onOpen, onTexts }) {
  const state = {
    // path -> { text, version, local, saved }: `text` is the studio's at
    // `version`; `local` is this tab's, which runs ahead while edits are unsent.
    files: new Map(),
    active: null,
    editTimer: null,
    inFlight: null, // { path, text } of the unanswered edit
    held: [], // messages waiting behind it
  };

  function send(message) {
    if (state.inFlight) state.held.push(message);
    else transmit(message);
  }

  // Send the first unsent edit, else whatever was held behind the last one.
  function pump() {
    while (!state.inFlight) {
      const unsent = [...state.files].find(([, file]) => file.local !== file.text);
      if (unsent) {
        const [path, file] = unsent;
        state.inFlight = { path, text: file.local };
        transmit({ t: "edit", file: path, base: file.version, text: file.local });
      } else if (state.held.length) {
        transmit(state.held.shift());
      } else {
        break;
      }
    }
    render();
  }

  function changed() {
    clearTimeout(state.editTimer);
    state.editTimer = setTimeout(flush, EDIT_DELAY);
    renderTabs();
    onTexts();
  }

  // Take the shown file's text now rather than after the edit delay.
  function flush() {
    if (state.editTimer === null) return;
    clearTimeout(state.editTimer);
    state.editTimer = null;
    const file = state.files.get(state.active);
    if (file) file.local = editor.get();
    pump();
  }

  function answered() {
    state.inFlight = null;
    pump();
  }

  function open(path) {
    const file = state.files.get(path);
    if (!file) return;
    flush();
    state.active = path;
    editor.show(path, file.local);
    onOpen(path);
    render();
  }

  // Take the studio's files. A file the studio still has as this tab last
  // knew it keeps this tab's unsent text.
  function load(files) {
    const known = state.files;
    const typing = known.get(state.active);
    if (state.editTimer !== null && typing) typing.local = editor.get();
    clearTimeout(state.editTimer);
    state.editTimer = null;
    state.files = new Map(files.map(({ path, text, version, saved }) =>
      [path, { text, version, local: carried(known.get(path), text), saved }]));
    const kept = [...state.files].filter(([path, file]) => file.local !== file.text && known.get(path)?.text !== file.text).map(([path]) => path);
    if (kept.length) note(`kept this tab's unsaved text for ${kept.join(", ")}; the studio's copy differed`);
    for (const path of known.keys()) if (!state.files.has(path)) editor.forget(path);
    const first = state.files.has("main.puf") ? "main.puf" : [...state.files.keys()][0];
    const active = state.files.has(state.active) ? state.active : first;
    state.active = null;
    if (active) open(active);
    pump();
    onTexts();
  }

  const unsaved = (path, file) =>
    !file.saved || file.local !== file.text || (path === state.active && state.editTimer !== null);

  const render = renderTabs;

  // One tab per file of the project, main.puf first; the shown one is
  // active, an unsaved one carries a dot, one with errors its count.
  function renderTabs() {
    const paths = [...state.files.keys()].sort((a, b) => (a === "main.puf" ? -1 : b === "main.puf" ? 1 : a.localeCompare(b)));
    $("tabs").replaceChildren(...paths.map((path) => {
      const tab = button(`file-tab${path === state.active ? " active" : ""}`, path, () => open(path));
      tab.title = path === state.active && unsaved(path, state.files.get(path)) ? "unsaved (⌘S saves)" : path;
      if (unsaved(path, state.files.get(path))) tab.append(span("unsaved-dot", "●"));
      const diagnostics = counts.get(path);
      if (diagnostics?.errors) tab.append(span("count error", String(diagnostics.errors)));
      else if (diagnostics?.warnings) tab.append(span("count warning", String(diagnostics.warnings)));
      return tab;
    }));
  }

  // Errors and warnings per file, for the tabs.
  const counts = new Map();

  $("new-file").addEventListener("click", () => {
    const path = window.prompt("Name the new file (e.g. lib/vec.puf)");
    if (path) send({ t: "new-file", path });
  });

  const receive = {
    init(snapshot) {
      state.inFlight = null;
      state.held = [];
      load(snapshot.files);
    },
    files({ files }) {
      load(files);
    },
    ack({ file, version }) {
      const known = state.files.get(file);
      if (known && state.inFlight?.path === file) Object.assign(known, { text: state.inFlight.text, version, saved: false });
      answered();
    },
    // our edit lost a race with another tab or the studio; theirs stands
    stale({ file, version, text }) {
      const known = state.files.get(file);
      if (known) Object.assign(known, { text, version, local: text });
      if (file === state.active) editor.set(text);
      note(`${file} changed elsewhere; showing that version`);
      answered();
      onTexts();
    },
    gone({ file }) {
      note(`${file} is no longer in the project; the edit was not kept`);
      answered();
    },
    text({ file, version, text }) {
      const known = state.files.get(file);
      if (!known) return;
      // the studio changed it (an accepted proposal, a restore, disk): an
      // undoable edit in the editor
      Object.assign(known, { text, version, local: text, saved: false });
      if (file === state.active) editor.set(text);
      render();
      onTexts();
    },
    saved({ files }) {
      for (const [path, version] of Object.entries(files)) {
        const known = state.files.get(path);
        if (known?.version === version) known.saved = true;
      }
      render();
    },
  };

  return {
    send,
    changed,
    flush,
    receive,
    open,
    active: () => state.active,
    paths: () => [...state.files.keys()],
    // every file's text as this tab has it, the shown one as in the editor
    texts: () => Object.fromEntries([...state.files].map(([path, file]) => [path, path === state.active ? editor.get() : file.local])),
    // whether the studio has exactly what this tab shows of `path`
    synced: (path) => {
      const file = state.files.get(path);
      return Boolean(file) && file.local === file.text && !(path === state.active && state.editTimer !== null);
    },
    version: (path) => state.files.get(path)?.version,
    setCounts(map) {
      counts.clear();
      for (const [path, value] of map) counts.set(path, value);
      renderTabs();
    },
  };
}

// The text a tab shows for a file the studio sent as `text`: its own
// whenever it holds unsaved work -- typing over the text the studio still
// has, or over one it no longer has (the studio restarted and read the
// disk, another tab saved): what is on screen is the newest work, and
// pump sends it back as an edit. A tab with nothing unsaved takes the
// studio's text.
export function carried(mine, text) {
  if (!mine) return text;
  if (mine.text === text) return mine.local;
  return mine.local !== mine.text || !mine.saved ? mine.local : text;
}

function span(className, text) {
  return Object.assign(document.createElement("span"), { className, textContent: text });
}

function button(className, text, onClick) {
  const node = Object.assign(document.createElement("button"), { className, textContent: text });
  node.addEventListener("click", onClick);
  return node;
}
