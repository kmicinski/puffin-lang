// The project's files: the editor's tabs, and the edits each file sends to
// the studio. The tabs are the files open in this tab of the browser, not
// every file of the project: a small project opens with all of its files
// as tabs, a larger one with main.puf, and the tree (tree.js) lists the
// rest. A tab closes with its ×; the file stays in the project.
//
// The studio owns every file's text. This tab sends a file's whole text with
// the version it was edited from, and the studio takes it or refuses it with
// the current text. One edit is in flight at a time, and every message sent
// through `send` waits behind it, so each edit's base is a version the studio
// named, and an evaluation sent after typing sees the typing.

const $ = (id) => document.getElementById(id);
const EDIT_DELAY = 150;
// a project with this many files, or any folder, opens with main.puf alone
const ALL_OPEN = 4;

export const basename = (path) => path.slice(path.lastIndexOf("/") + 1);
export const dirname = (path) => (path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "");

// `onOpen(path)` is called when a file is shown in the editor, `onTexts()`
// whenever a file's text as this tab has it may have changed, and
// `onFiles()` when the set of files or folders, the open tabs, or what the
// tabs show of them changed (the tree redraws).
export function createFiles({ editor, transmit, note, onOpen, onTexts, onFiles }) {
  const state = {
    // path -> { text, version, local, saved }: `text` is the studio's at
    // `version`; `local` is this tab's, which runs ahead while edits are unsent.
    files: new Map(),
    folders: [],
    tracked: false,
    project: "",
    opened: [], // the tabs, in order
    active: null,
    editTimer: null,
    inFlight: null, // { path, text } of the unanswered edit
    held: [], // messages waiting behind it
    // what the next files message should do: open a file this tab made,
    // or follow a file it moved
    expected: null,
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
    render();
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
    if (!state.opened.includes(path)) state.opened.push(path);
    state.active = path;
    editor.show(path, file.local);
    onOpen(path);
    render();
  }

  // Close the tab of `path`; the file stays. The neighbouring tab shows.
  function close(path) {
    const at = state.opened.indexOf(path);
    if (at < 0) return;
    flush();
    state.opened.splice(at, 1);
    if (state.active === path) {
      const next = state.opened[Math.min(at, state.opened.length - 1)];
      state.active = null;
      if (next) open(next);
      else showNothing();
    }
    render();
  }

  function showNothing() {
    state.active = null;
    editor.show("", state.files.size ? ";; no file is open: pick one in the tree, or ⌘P\n" : ";; the project has no files: + makes one\n");
    render();
  }

  // Take the studio's files. A file the studio still has as this tab last
  // knew it keeps this tab's unsent text.
  function load(files, folders = state.folders) {
    const known = state.files;
    const typing = known.get(state.active);
    if (state.editTimer !== null && typing) typing.local = editor.get();
    clearTimeout(state.editTimer);
    state.editTimer = null;
    const first = known.size === 0;
    state.files = new Map(files.map(({ path, text, version, saved }) =>
      [path, { text, version, local: carried(known.get(path), text), saved }]));
    state.folders = folders ?? [];
    const kept = [...state.files].filter(([path, file]) => file.local !== file.text && known.get(path)?.text !== file.text).map(([path]) => path);
    if (kept.length) note(`kept this tab's unsaved text for ${kept.join(", ")}; the studio's copy differed`);
    const expected = state.expected;
    state.expected = null;
    // a file this tab moved keeps its tab, and its place
    for (const [from, to] of expected?.moves ?? []) {
      if (state.files.has(to) && !state.files.has(from)) {
        const at = state.opened.indexOf(from);
        if (at >= 0) state.opened[at] = to;
        if (state.active === from) state.active = to;
        const mine = known.get(from);
        if (mine) state.files.get(to).local = carried(mine, state.files.get(to).text);
      }
    }
    state.opened = state.opened.filter((path) => state.files.has(path));
    if (first) state.opened = remembered() ?? openAtFirst();
    const main = state.files.has("main.puf") ? "main.puf" : [...state.files.keys()][0];
    let active = state.files.has(state.active) ? state.active : state.opened[0] ?? main;
    if (expected?.open && state.files.has(expected.open)) active = expected.open;
    state.active = null;
    if (active) open(active);
    else showNothing();
    // after the editor has moved on: disposing the shown model upsets Monaco
    for (const path of known.keys()) if (!state.files.has(path)) editor.forget(path);
    pump();
    onTexts();
  }

  // The tabs a project opens with: every file of a small flat one, else
  // main.puf (or the first).
  function openAtFirst() {
    const paths = sorted([...state.files.keys()]);
    if (paths.length <= ALL_OPEN && !state.folders.length) return paths;
    return paths.includes("main.puf") ? ["main.puf"] : paths.slice(0, 1);
  }

  // The tabs this browser last had open on the project, those still here.
  const tabsKey = () => `puffin-studio.tabs.${state.project}`;
  function remembered() {
    try {
      const kept = JSON.parse(localStorage.getItem(tabsKey()) ?? "null");
      if (!Array.isArray(kept?.opened)) return null;
      const opened = kept.opened.filter((path) => state.files.has(path));
      if (kept.active && state.files.has(kept.active)) state.active = kept.active;
      return opened.length ? opened : null;
    } catch {
      return null;
    }
  }
  function remember() {
    try { localStorage.setItem(tabsKey(), JSON.stringify({ opened: state.opened, active: state.active })); } catch { /* private window */ }
  }

  const unsaved = (path, file) =>
    !file.saved || file.local !== file.text || (path === state.active && state.editTimer !== null);

  function render() {
    renderTabs();
    remember();
    onFiles?.();
  }

  // One tab per open file; the shown one is active, an unsaved one carries
  // a dot, one with errors its count. A tab shows the file's name, or its
  // path when another open tab has the same name.
  function renderTabs() {
    const names = new Map();
    for (const path of state.opened) names.set(basename(path), (names.get(basename(path)) ?? 0) + 1);
    $("tab-list").replaceChildren(...state.opened.map((path) => {
      const file = state.files.get(path);
      const label = names.get(basename(path)) > 1 ? path : basename(path);
      const tab = button(`file-tab${path === state.active ? " active" : ""}`, label, () => open(path));
      tab.title = path === state.active && unsaved(path, file) ? `${path} · unsaved (⌘S saves)` : path;
      if (unsaved(path, file)) tab.append(span("unsaved-dot", "●"));
      const diagnostics = counts.get(path);
      if (diagnostics?.errors) tab.append(span("count error", String(diagnostics.errors)));
      else if (diagnostics?.warnings) tab.append(span("count warning", String(diagnostics.warnings)));
      const x = tab.appendChild(span("close", "×"));
      x.title = "Close the tab (the file stays)";
      x.addEventListener("click", (event) => { event.stopPropagation(); close(path); });
      tab.addEventListener("auxclick", (event) => { if (event.button === 1) close(path); });
      return tab;
    }));
  }

  // Errors and warnings per file, for the tabs and the tree.
  const counts = new Map();

  const receive = {
    init(snapshot) {
      state.inFlight = null;
      state.held = [];
      state.tracked = Boolean(snapshot.tracked);
      state.project = snapshot.project ?? "";
      load(snapshot.files, snapshot.folders ?? []);
    },
    files({ files, folders }) {
      load(files, folders);
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
    close,
    active: () => state.active,
    paths: () => [...state.files.keys()],
    folders: () => [...state.folders],
    opened: () => [...state.opened],
    tracked: () => state.tracked,
    unsaved: (path) => Boolean(state.files.get(path)) && unsaved(path, state.files.get(path)),
    counts: (path) => counts.get(path),
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
      render();
    },
    // ---- The tree's requests, each after the edits made so far ----------
    newFile(path) {
      flush();
      state.expected = { open: withSuffix(path) };
      send({ t: "new-file", path });
    },
    newFolder(path) {
      send({ t: "new-folder", path });
    },
    moveFile(from, to) {
      flush();
      state.expected = { moves: [[from, withSuffix(to)]], open: state.active === from ? withSuffix(to) : null };
      send({ t: "move-file", from, to });
    },
    moveFolder(from, to) {
      flush();
      const moves = [...state.files.keys()].filter((path) => path.startsWith(`${from}/`)).map((path) => [path, `${to}${path.slice(from.length)}`]);
      state.expected = { moves };
      send({ t: "move-folder", from, to });
    },
    deleteFile(path) {
      send({ t: "delete-file", path });
    },
    deleteFolder(path) {
      send({ t: "delete-folder", path });
    },
  };
}

// The studio names a new file with a Puffin suffix when none was typed.
const withSuffix = (path) => (/\.(puf|pufs|scm)$/.test(path) ? path : `${path}.puf`);

// Paths in the order the tabs and the tree show them: main.puf first, then
// by name.
export function sorted(paths) {
  return [...paths].sort((a, b) => (a === "main.puf" ? -1 : b === "main.puf" ? 1 : a.localeCompare(b)));
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
