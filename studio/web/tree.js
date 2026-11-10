// The project's files as a tree (files.js holds them): folders that fold,
// a file's unsaved dot and error count, the shown file marked. Hidden in a
// small flat project, where the tabs are the files; shown once a project
// has folders or more than a few files, or when asked (the Files button at
// the tabs' left, ⌘⇧E, `,files`), and the choice is remembered per project.
//
// Everything a project's files need happens here, in place: a new file or
// folder is typed into the tree (or into the tab bar when the tree is
// hidden), a rename is typed over the name (F2, or the menu), a delete asks
// once in the row, and a drag onto a folder moves a file or a folder there.
// The studio does the work (studio/src/studio.rs new_file, move_file,
// delete_file and the folder forms) and every tab's tree follows. `,open`
// without a name opens a file by typing part of its path. No key is bound
// beyond ⌘⇧E (the Command key alone: Control is Emacs's in the editor).
//
//   createTree({ panel, toggle, add, quick, files, editor, note })
//     -> { toggle, show, newFile, quickOpen, receive }

import { basename, dirname, sorted } from "./files.js";

const element = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

// a project this big, or any folder, shows the tree unasked
const MANY = 4;

export function createTree({ panel, toggle, add, quick, files, editor, note }) {
  let project = "";
  let shown = false;
  let chosen = null; // the person's choice for this project, else null
  const collapsed = new Set();
  let editing = null; // { kind: "new-file" | "new-folder" | "rename" | "delete", path, folder }
  let menu = null;
  let focused = null; // the row's path, for the keys

  // ---- Showing and hiding --------------------------------------------------------

  const key = () => `puffin-studio.files.${project}`;

  function wanted() {
    if (chosen !== null) return chosen;
    return files.paths().length > MANY || files.folders().length > 0;
  }

  function show(on, remember = false) {
    shown = on;
    panel.hidden = !on;
    toggle.classList.toggle("on", on);
    if (remember) {
      chosen = on;
      try { localStorage.setItem(key(), on ? "show" : "hide"); } catch { /* private window */ }
    }
    render();
  }

  function renderToggle() {
    const n = files.paths().length;
    toggle.replaceChildren(element("span", "tabs-toggle-word", "Files"), element("span", "tabs-toggle-count", String(n)));
    toggle.title = `The project's ${n === 1 ? "file" : `${n} files`} (⌘⇧E · ,files)`;
  }

  // ---- The tree ----------------------------------------------------------------

  // folders and files as nested { path, dirs: Map, files: [] }
  function build() {
    const root = { path: "", dirs: new Map(), files: [] };
    const ensure = (dir) => {
      if (!dir) return root;
      let node = root;
      let at = "";
      for (const part of dir.split("/")) {
        at = at ? `${at}/${part}` : part;
        if (!node.dirs.has(part)) node.dirs.set(part, { path: at, dirs: new Map(), files: [] });
        node = node.dirs.get(part);
      }
      return node;
    };
    for (const dir of files.folders()) ensure(dir);
    for (const path of sorted(files.paths())) ensure(dirname(path)).files.push(path);
    return root;
  }

  function render() {
    renderToggle();
    if (!shown) {
      if (editing && editing.where === "tabs") renderTabEntry();
      return;
    }
    // a name being typed survives a redraw (an edit's ack can bring one)
    const live = panel.querySelector(".tree-input");
    const typing = live && document.activeElement === live ? { value: live.value, start: live.selectionStart, end: live.selectionEnd } : null;
    panel.replaceChildren();
    const head = panel.appendChild(element("div", "tree-head"));
    head.append(element("span", "tree-title", "Files"));
    const actions = head.appendChild(element("span", "tree-actions"));
    actions.append(
      action("＋", "A new file (,new NAME)", () => startNew("new-file", "")),
      action("⊞", "A new folder", () => startNew("new-folder", "")),
      action("×", "Hide the tree (⌘⇧E)", () => show(false, true)),
    );
    const list = panel.appendChild(element("div", "tree-list"));
    list.setAttribute("role", "tree");
    const root = build();
    renderChildren(list, root, 0);
    if (!files.paths().length && !editing) list.append(element("p", "hint tree-empty", "No files yet. ＋ makes one."));
    dropTarget(list, "", true);
    if (typing) {
      const field = panel.querySelector(".tree-input");
      if (field) {
        field.value = typing.value;
        field.focus();
        field.setSelectionRange(typing.start, typing.end);
      }
    }
  }
  panel.addEventListener("contextmenu", (event) => {
    if (event.target === panel || event.target.classList.contains("tree-list")) {
      event.preventDefault();
      openMenu(event.clientX, event.clientY, rootItems());
    }
  });

  function renderChildren(list, node, depth) {
    if (editing && editing.folder === node.path && (editing.kind === "new-file" || editing.kind === "new-folder")) {
      list.append(entryRow(depth));
    }
    for (const [name, dir] of [...node.dirs].sort((a, b) => a[0].localeCompare(b[0]))) {
      list.append(folderRow(name, dir, depth));
      if (!collapsed.has(dir.path)) renderChildren(list, dir, depth + 1);
    }
    for (const path of node.files) list.append(fileRow(path, depth));
  }

  function row(className, depth, path) {
    const node = element("div", `tree-row ${className}`);
    node.style.paddingLeft = `${8 + depth * 14}px`;
    node.tabIndex = 0;
    node.dataset.path = path;
    node.setAttribute("role", "treeitem");
    node.addEventListener("focus", () => { focused = path; });
    return node;
  }

  function folderRow(name, dir, depth) {
    const node = row(`folder${collapsed.has(dir.path) ? " closed" : ""}`, depth, dir.path);
    if (editing?.kind === "rename" && editing.path === dir.path) return editRow(node, name, (typed) => files.moveFolder(dir.path, join(dirname(dir.path), typed)));
    if (editing?.kind === "delete" && editing.path === dir.path) {
      const n = files.paths().filter((path) => path.startsWith(`${dir.path}/`)).length;
      return confirmRow(node, `Delete ${name}${n ? ` and its ${n} file${n === 1 ? "" : "s"}` : ""}?`, () => files.deleteFolder(dir.path));
    }
    node.append(element("span", "tree-caret"), element("span", "tree-name", name));
    node.title = dir.path;
    node.addEventListener("click", () => { fold(dir.path); });
    node.append(more(() => folderItems(dir.path, name)));
    node.addEventListener("contextmenu", (event) => { event.preventDefault(); event.stopPropagation(); openMenu(event.clientX, event.clientY, folderItems(dir.path, name)); });
    draggable(node, dir.path, "folder");
    dropTarget(node, dir.path);
    return node;
  }

  function fileRow(path, depth) {
    const name = basename(path);
    const node = row(`file${path === files.active() ? " active" : ""}${files.opened().includes(path) ? " open" : ""}`, depth, path);
    if (editing?.kind === "rename" && editing.path === path) return editRow(node, name, (typed) => files.moveFile(path, join(dirname(path), typed)));
    if (editing?.kind === "delete" && editing.path === path) return confirmRow(node, `Delete ${name}?`, () => files.deleteFile(path));
    node.append(element("span", "tree-name", name));
    node.title = path;
    if (files.unsaved(path)) node.append(element("span", "unsaved-dot", "●"));
    const counts = files.counts(path);
    if (counts?.errors) node.append(element("span", "count error", String(counts.errors)));
    else if (counts?.warnings) node.append(element("span", "count warning", String(counts.warnings)));
    node.addEventListener("click", () => files.open(path));
    node.append(more(() => fileItems(path, name)));
    node.addEventListener("contextmenu", (event) => { event.preventDefault(); event.stopPropagation(); openMenu(event.clientX, event.clientY, fileItems(path, name)); });
    draggable(node, path, "file");
    return node;
  }

  function fold(path) {
    if (collapsed.has(path)) collapsed.delete(path);
    else collapsed.add(path);
    render();
  }

  function action(text, title, onClick) {
    const node = element("button", "quiet small tree-action", text);
    node.title = title;
    node.addEventListener("click", (event) => { event.stopPropagation(); onClick(); });
    return node;
  }

  // the ⋯ at a row's end: its menu
  function more(items) {
    const node = element("button", "quiet small tree-more", "⋯");
    node.title = "Rename, delete, …";
    node.tabIndex = -1;
    node.addEventListener("click", (event) => {
      event.stopPropagation();
      const box = node.getBoundingClientRect();
      openMenu(box.left, box.bottom + 2, items());
    });
    return node;
  }

  // ---- Typing in place: a name, or a yes --------------------------------------------

  // Start typing a new file's or folder's name in `folder`: in the tree
  // when shown, else in the tab bar.
  function startNew(kind, folder) {
    closeMenu();
    if (shown) {
      collapsed.delete(folder);
      editing = { kind, folder, where: "tree" };
    } else {
      editing = { kind, folder, where: "tabs" };
    }
    render();
  }

  function entryRow(depth) {
    const node = row(`entry ${editing.kind}`, depth, "");
    const field = node.appendChild(element("input", "tree-input"));
    field.placeholder = editing.kind === "new-file" ? "name.puf" : "folder";
    field.spellcheck = false;
    field.autocomplete = "off";
    bindEntry(field, (typed, was) => {
      const path = join(was.folder, typed);
      if (was.kind === "new-file") files.newFile(path);
      else files.newFolder(path);
    });
    setTimeout(() => field.focus(), 0);
    return node;
  }

  // the tab bar's version: an input where the + was
  function renderTabEntry() {
    const slot = document.getElementById("tab-list");
    const old = slot.querySelector(".tab-entry");
    if (old) return;
    const field = element("input", "tree-input tab-entry");
    field.placeholder = editing.kind === "new-file" ? "new file: name.puf" : "new folder";
    field.spellcheck = false;
    field.autocomplete = "off";
    bindEntry(field, (typed, was) => {
      if (was.kind === "new-file") files.newFile(typed);
      else files.newFolder(typed);
    });
    slot.append(field);
    setTimeout(() => field.focus(), 0);
  }

  // `done(typed, was)` gets the name and what was being edited, which is
  // over by then.
  function bindEntry(field, done) {
    let finished = false;
    const finish = (commit) => {
      if (finished) return;
      finished = true;
      const typed = field.value.trim();
      const was = editing;
      editing = null;
      if (commit && typed) done(typed, was);
      else render();
      editor.focus();
    };
    field.addEventListener("keydown", (event) => {
      if (event.key === "Enter") { event.preventDefault(); finish(true); }
      else if (event.key === "Escape") { event.preventDefault(); finish(false); }
      event.stopPropagation();
    });
    field.addEventListener("blur", () => finish(false));
  }

  function editRow(node, name, done) {
    node.classList.add("editing");
    const field = node.appendChild(element("input", "tree-input"));
    field.value = name;
    field.spellcheck = false;
    field.autocomplete = "off";
    bindEntry(field, (typed) => { if (typed !== name) done(typed); else render(); });
    setTimeout(() => {
      field.focus();
      const stem = name.lastIndexOf(".");
      field.setSelectionRange(0, stem > 0 ? stem : name.length);
    }, 0);
    return node;
  }

  function confirmRow(node, question, done) {
    node.classList.add("confirming");
    node.append(element("span", "tree-question", question));
    const yes = node.appendChild(element("button", "btn small danger", "Delete"));
    const no = node.appendChild(element("button", "quiet small", "Cancel"));
    node.append(element("span", "hint tree-hint", files.tracked() ? "the history keeps it" : "this cannot be undone"));
    const finish = (commit) => {
      editing = null;
      if (commit) done();
      render();
      editor.focus();
    };
    yes.addEventListener("click", (event) => { event.stopPropagation(); finish(true); });
    no.addEventListener("click", (event) => { event.stopPropagation(); finish(false); });
    node.addEventListener("keydown", (event) => {
      if (event.key === "Enter") { event.preventDefault(); finish(true); }
      else if (event.key === "Escape") { event.preventDefault(); finish(false); }
      event.stopPropagation();
    });
    setTimeout(() => yes.focus(), 0);
    return node;
  }

  function startRename(path) {
    closeMenu();
    editing = { kind: "rename", path, where: "tree" };
    if (!shown) show(true);
    else render();
  }

  function startDelete(path) {
    closeMenu();
    editing = { kind: "delete", path, where: "tree" };
    if (!shown) show(true);
    else render();
  }

  // ---- The menu ----------------------------------------------------------------

  const rootItems = () => [
    ["New file", () => startNew("new-file", "")],
    ["New folder", () => startNew("new-folder", "")],
  ];
  const folderItems = (path, name) => [
    [`New file in ${name}`, () => startNew("new-file", path)],
    [`New folder in ${name}`, () => startNew("new-folder", path)],
    ["Rename", () => startRename(path)],
    ["Delete", () => startDelete(path)],
  ];
  const fileItems = (path, name) => [
    ["Open", () => files.open(path)],
    ["Rename", () => startRename(path)],
    [`New file beside ${name}`, () => startNew("new-file", dirname(path))],
    ["Delete", () => startDelete(path)],
  ];

  function openMenu(x, y, items) {
    closeMenu();
    menu = document.body.appendChild(element("div", "tree-menu"));
    for (const [word, run] of items) {
      const item = menu.appendChild(element("button", "tree-menu-item", word));
      item.addEventListener("click", (event) => { event.stopPropagation(); closeMenu(); run(); });
    }
    menu.style.left = `${Math.min(x, window.innerWidth - 200)}px`;
    menu.style.top = `${Math.min(y, window.innerHeight - items.length * 28 - 12)}px`;
    setTimeout(() => menu?.querySelector("button")?.focus(), 0);
  }

  function closeMenu() {
    menu?.remove();
    menu = null;
  }

  document.addEventListener("click", (event) => { if (menu && !menu.contains(event.target)) closeMenu(); });
  document.addEventListener("keydown", (event) => { if (menu && event.key === "Escape") closeMenu(); });

  // ---- Dragging a file onto a folder -------------------------------------------

  let dragging = null; // { path, kind }

  function draggable(node, path, kind) {
    node.draggable = true;
    node.addEventListener("dragstart", (event) => {
      dragging = { path, kind };
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", path);
      node.classList.add("dragging");
    });
    node.addEventListener("dragend", () => { dragging = null; node.classList.remove("dragging"); panel.querySelectorAll(".drop").forEach((n) => n.classList.remove("drop")); });
  }

  function dropTarget(node, folder, isRoot = false) {
    const accepts = () => dragging && dirname(dragging.path) !== folder && !(dragging.kind === "folder" && (folder === dragging.path || folder.startsWith(`${dragging.path}/`)));
    node.addEventListener("dragover", (event) => {
      if (isRoot && event.target !== node) return;
      if (!accepts()) return;
      event.preventDefault();
      event.stopPropagation();
      event.dataTransfer.dropEffect = "move";
      node.classList.add("drop");
    });
    node.addEventListener("dragleave", () => node.classList.remove("drop"));
    node.addEventListener("drop", (event) => {
      if (isRoot && event.target !== node) return;
      if (!accepts()) return;
      event.preventDefault();
      event.stopPropagation();
      node.classList.remove("drop");
      const to = join(folder, basename(dragging.path));
      if (dragging.kind === "folder") files.moveFolder(dragging.path, to);
      else files.moveFile(dragging.path, to);
      dragging = null;
    });
  }

  // ---- Keys in the tree -------------------------------------------------------------

  panel.addEventListener("keydown", (event) => {
    if (editing || focused === null || event.target.tagName === "INPUT") return;
    const rows = [...panel.querySelectorAll(".tree-row")];
    const at = rows.findIndex((r) => r.dataset.path === focused);
    const isFolder = rows[at]?.classList.contains("folder");
    const move = (to) => { rows[Math.max(0, Math.min(rows.length - 1, to))]?.focus(); };
    switch (event.key) {
      case "ArrowDown": event.preventDefault(); move(at + 1); break;
      case "ArrowUp": event.preventDefault(); move(at - 1); break;
      case "ArrowRight": if (isFolder && collapsed.has(focused)) { event.preventDefault(); fold(focused); refocus(); } break;
      case "ArrowLeft": if (isFolder && !collapsed.has(focused)) { event.preventDefault(); fold(focused); refocus(); } break;
      case "Enter": event.preventDefault(); if (isFolder) { fold(focused); refocus(); } else files.open(focused); break;
      case "F2": event.preventDefault(); startRename(focused); break;
      case "Backspace": case "Delete": event.preventDefault(); startDelete(focused); break;
      default: return;
    }
  });
  const refocus = () => panel.querySelector(`.tree-row[data-path="${CSS.escape(focused)}"]`)?.focus();

  // ---- ,open: a file by part of its path -------------------------------------------

  let quickRows = [];
  let quickAt = 0;

  function quickOpen() {
    closeMenu();
    quick.hidden = false;
    quick.replaceChildren();
    const field = quick.appendChild(element("input", "quick-input"));
    field.placeholder = "open a file: type part of its path";
    field.spellcheck = false;
    field.autocomplete = "off";
    const list = quick.appendChild(element("div", "quick-list"));
    const refresh = () => {
      const typed = field.value.trim().toLowerCase();
      quickRows = sorted(files.paths()).filter((path) => matches(path.toLowerCase(), typed)).slice(0, 12);
      quickAt = Math.min(quickAt, Math.max(0, quickRows.length - 1));
      list.replaceChildren(...quickRows.map((path, i) => {
        const node = element("div", `quick-row${i === quickAt ? " on" : ""}`);
        node.append(element("span", "quick-name", basename(path)), element("span", "quick-dir", dirname(path)));
        node.addEventListener("mousedown", (event) => { event.preventDefault(); done(path); });
        return node;
      }));
      if (!quickRows.length) list.append(element("div", "hint quick-none", typed ? "no file matches" : "no files"));
    };
    const done = (path) => {
      quick.hidden = true;
      if (path) files.open(path);
      editor.focus();
    };
    field.addEventListener("input", () => { quickAt = 0; refresh(); });
    field.addEventListener("keydown", (event) => {
      if (event.key === "ArrowDown") { event.preventDefault(); quickAt = Math.min(quickRows.length - 1, quickAt + 1); refresh(); }
      else if (event.key === "ArrowUp") { event.preventDefault(); quickAt = Math.max(0, quickAt - 1); refresh(); }
      else if (event.key === "Enter") { event.preventDefault(); done(quickRows[quickAt]); }
      else if (event.key === "Escape") { event.preventDefault(); done(null); }
      event.stopPropagation();
    });
    field.addEventListener("blur", () => { if (!quick.hidden) done(null); });
    refresh();
    setTimeout(() => field.focus(), 0);
  }

  // every typed character in order, as VS Code's quick open takes it
  function matches(path, typed) {
    let at = 0;
    for (const c of typed) {
      at = path.indexOf(c, at);
      if (at < 0) return false;
      at += 1;
    }
    return true;
  }

  // ---- Wiring -----------------------------------------------------------------------

  toggle.addEventListener("click", () => show(!shown, true));
  add.addEventListener("click", () => startNew("new-file", shown && focused ? folderOf(focused) : ""));
  document.addEventListener("keydown", (event) => {
    if (event.metaKey && !event.ctrlKey && event.shiftKey && event.code === "KeyE") { event.preventDefault(); event.stopPropagation(); show(!shown, true); }
  }, true);
  const folderOf = (path) => (files.folders().includes(path) ? path : dirname(path));

  return {
    // the Files button, ,files: shown or hidden; what the transcript says
    toggle() {
      show(!shown, true);
      return shown ? "the tree shows the project's files (,files again hides it)" : "the tree is hidden; the tabs are the open files";
    },
    show,
    newFile: (path) => (path ? files.newFile(path) : startNew("new-file", "")),
    quickOpen,
    // files.js: the files, the folders, the tabs or what they show changed
    changed() {
      if (editing?.kind === "rename" || editing?.kind === "delete") {
        // the row being edited went (moved or deleted elsewhere): done
        if (!files.paths().includes(editing.path) && !files.folders().includes(editing.path)) editing = null;
      }
      if (chosen === null && !shown && wanted()) show(true);
      else render();
    },
    receive: {
      init(snapshot) {
        project = snapshot.project ?? "";
        try { chosen = { show: true, hide: false }[localStorage.getItem(key())] ?? null; } catch { chosen = null; }
        collapsed.clear();
        show(wanted());
      },
    },
  };
}

const join = (dir, name) => (dir ? `${dir}/${name}` : name);
