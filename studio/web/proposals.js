// What the assistant proposes, reviewed where it would land: in the editor,
// on the shown file's text (inline-diff.js), each change with its own
// Accept and Reject, coloured by the thread that proposed it. Around that:
// - the proposal bar over the editor, shown only while something is
//   pending: how many changes and in which files, stepping between them
//   (F7), Accept all and Reject all of the current one's changeset, and
//   the changes that no longer apply;
// - the chip an answer in the transcript shows for its turn's proposals.
// Accepting goes through the studio, which checks the program accepting
// leaves and records a version: each change says whether it checks
// ("✓ checks"), what it takes along (the earlier changes of its thread it
// builds on), or why it cannot be accepted. Ported from Slog Studio.

import { groupHunk, place } from "./hunks.js";
import { forms } from "./lexer.js";
import { createInlineDiff } from "./inline-diff.js";

const TONES = 5;
export const toneOf = (thread) => `tone-${(thread - 1) % TONES}`;

const node = (tag, className, text) => {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined) element.textContent = text;
  return element;
};

export function createProposals({ editor, files, send, bar, onChange = () => {} }) {
  const state = {
    view: { threads: [], changesets: [], ops: [] },
    groups: [], // the shown file's
    unplaced: [], // every file's ops that no longer apply
    current: null, // the key (first op id) of the change last stepped to
  };
  const inline = editor.raw && createInlineDiff(editor.raw, {
    onMove(hunk) {
      state.current = hunk.key;
      renderBar();
    },
  });
  if (editor.raw) {
    let timer = null;
    editor.raw.editor.onDidChangeModelContent(() => {
      clearTimeout(timer);
      timer = setTimeout(refresh, 120);
    });
    editor.raw.editor.onDidChangeModel(() => setTimeout(refresh, 0));
  }

  const opOf = (id) => state.view.ops.find((op) => op.id === id);
  const threadOf = (id) => state.view.threads.find((t) => t.id === id);
  const changesetOf = (id) => state.view.changesets.find((c) => c.id === id);
  const pending = () => state.view.ops.filter((op) => op.status === "pending");
  // the files with pending changes that apply, and how many each
  function byFile() {
    const texts = files.texts();
    const out = new Map();
    state.unplaced = [];
    for (const path of new Set(pending().map((op) => op.file))) {
      const { groups, unplaced } = place(texts[path] ?? "", state.view.ops, path);
      if (groups.length) out.set(path, groups);
      state.unplaced.push(...unplaced);
    }
    return out;
  }

  function refresh() {
    const shown = files.active();
    const all = byFile();
    state.groups = all.get(shown) ?? [];
    state.files = all;
    draw(shown);
    renderBar();
    onChange();
  }

  // ---- In the editor ----------------------------------------------------

  function draw(shown) {
    if (!inline) return;
    const text = files.texts()[shown] ?? "";
    const found = forms(text);
    inline.show(state.groups.map((group) => {
      const hunk = groupHunk(text, group);
      const lines = hunk.removed.map((r) => r.line);
      return {
        ...hunk,
        key: group.ids[0],
        tone: toneOf(group.thread),
        forms: found.filter((f) => lines.some((l) => f.line <= l && l <= f.endLine)).map((f) => [f.line, f.endLine]),
        header: () => header(group),
      };
    }));
  }

  // The slim line over a change: whose it is, what for, and its controls.
  function header(group) {
    const ops = group.ids.map(opOf);
    const line = node("div", `ip-head ${toneOf(group.thread)}`);
    line.append(node("span", "ip-dot"));
    const title = threadOf(group.thread)?.title ?? `thread ${group.thread}`;
    line.append(node("span", "ip-who", `✦ ${title} · ${group.ids.map((id) => `#${id}`).join(" ")}`));
    const note = ops.map((op) => op?.note).filter(Boolean).join("; ");
    if (note) line.append(node("span", "ip-note", note));
    const rivals = conflictsOf(group);
    if (rivals.length) line.append(node("span", "ip-flag", `conflicts with ${rivals.join(", ")}`));
    const check = checkOf(group);
    if (check.state === "ok") line.append(node("span", "ip-checks", "✓ checks"));
    if (check.state === "checking") line.append(node("span", "ip-checking", "checking…"));
    if (check.state === "fails") {
      const flag = line.appendChild(node("span", "ip-flag", "fails the check"));
      flag.title = check.reason;
    }
    const accept = line.appendChild(node("button", "ip-accept", check.with.length ? `Accept with ${ids(check.with)}` : "Accept"));
    accept.disabled = rivals.length > 0 || check.state === "fails";
    accept.title = rivals.length ? "Reject one side of the conflict first"
      : check.state === "fails" ? check.reason
      : check.with.length ? `It builds on ${ids(check.with)}, which are accepted with it, as one new version`
      : "Make this change, as a new version";
    accept.addEventListener("click", () => acceptIds(group.ids));
    const reject = line.appendChild(node("button", "ip-reject", "Reject"));
    reject.addEventListener("click", () => rejectIds(group.ids));
    return line;
  }

  function conflictsOf(group) {
    const others = new Set(group.ids.flatMap((id) => opOf(id)?.conflicts ?? []));
    const threads = new Set([...others].map((id) => opOf(id)?.thread));
    return [...threads].map((t) => `“${threadOf(t)?.title ?? `thread ${t}`}”`);
  }

  // Whether a change's ops pass the check accepted: "ok", "fails" (with the
  // reason) or "checking", and the earlier ops they take along.
  function checkOf(group) {
    const checks = group.ids.map((id) => opOf(id)?.check);
    const failed = checks.find((check) => check && !check.ok);
    const taken = [...new Set(checks.flatMap((check) => check?.with ?? []))].filter((id) => !group.ids.includes(id));
    if (failed) return { state: "fails", reason: failed.reason, with: [] };
    if (checks.some((check) => !check)) return { state: "checking", with: taken };
    return { state: "ok", with: taken };
  }

  const ids = (list) => list.map((id) => `#${id}`).join(", ");

  function acceptIds(list) {
    files.flush(); // the studio applies it to the text as typed
    send({ t: "accept", ops: list });
  }

  function rejectIds(list) {
    for (const id of [...list].reverse()) send({ t: "reject", op: id });
  }

  // Show a change in the editor, opening its file.
  function focus(path, key) {
    if (files.active() !== path) files.open(path);
    refresh();
    state.current = key ?? state.groups[0]?.ids[0] ?? null;
    if (state.current) inline?.reveal(state.current);
    editor.focus();
    renderBar();
  }

  function step(direction) {
    if (!state.groups.length) {
      const [path] = state.files.keys();
      if (path) focus(path);
      return;
    }
    inline?.next(direction);
  }

  // ---- The bar ----------------------------------------------------------

  function renderBar() {
    const total = [...(state.files?.values() ?? [])].reduce((n, groups) => n + groups.length, 0);
    bar.hidden = !total && !state.unplaced.length;
    if (bar.hidden) return;
    bar.replaceChildren();
    const threads = [...new Set(pending().map((op) => op.thread))];
    for (const t of threads) {
      const dot = bar.appendChild(node("span", `ip-dot ${toneOf(t)}`));
      dot.title = threadOf(t)?.title ?? "";
    }
    const group = state.groups.find((g) => g.ids[0] === state.current) ?? state.groups[0] ?? null;
    const what = bar.appendChild(node("span", "ip-what", `${total} proposed change${total === 1 ? "" : "s"}`));
    if (group) what.append(node("span", "ip-of", ` · ${changesetOf(group.changeset)?.title ?? ""}`));
    for (const [path, groups] of state.files) {
      if (path === files.active()) continue;
      const show = bar.appendChild(node("button", "secondary small", `${path} (${groups.length})`));
      show.title = `Show the changes to ${path}`;
      show.addEventListener("click", () => focus(path));
    }
    if (state.unplaced.length) {
      const gone = bar.appendChild(node("button", "quiet small", `${state.unplaced.length} no longer applies`));
      gone.title = `${ids(state.unplaced)}: their text changed since they were proposed. Click to reject them.`;
      gone.addEventListener("click", () => rejectIds(state.unplaced));
    }
    if (state.groups.length) {
      const nav = bar.appendChild(node("span", "ip-nav"));
      const previous = nav.appendChild(node("button", "quiet small", "‹"));
      previous.title = "Previous change (Shift+F7)";
      previous.addEventListener("click", () => step(-1));
      nav.append(node("span", "ip-index", `${state.groups.indexOf(group) + 1}/${state.groups.length}`));
      const next = nav.appendChild(node("button", "quiet small", "›"));
      next.title = "Next change (F7)";
      next.addEventListener("click", () => step(1));
    }
    const changeset = group?.changeset ?? pending()[0]?.changeset;
    if (changeset) {
      const open = pending().filter((op) => op.changeset === changeset);
      const title = changesetOf(changeset)?.title ?? "";
      const all = bar.appendChild(node("button", "primary small", "Accept all"));
      const failing = open.find((op) => op.check && !op.check.ok);
      all.disabled = Boolean(failing) || open.some((op) => op.stale);
      all.title = failing ? `#${failing.id}: ${failing.check.reason}` : `Accept every change of “${title}”, as one version per file`;
      all.addEventListener("click", () => {
        files.flush();
        send({ t: "accept-changeset", changeset });
      });
      const none = bar.appendChild(node("button", "secondary small", "Reject all"));
      none.title = `Reject every change of “${title}”`;
      none.addEventListener("click", () => rejectIds(open.map((op) => op.id)));
    }
  }

  // ---- The chip on an answer ----------------------------------------------

  // "Proposed 3 changes · view · accept" for the ops a turn proposed.
  function chip(list) {
    const ops = list.map(opOf).filter(Boolean);
    if (!ops.length) return null;
    const open = ops.filter((op) => op.status === "pending");
    const counts = ["accepted", "rejected"].map((status) => [status, ops.filter((op) => op.status === status).length])
      .filter(([, n]) => n).map(([status, n]) => (n === ops.length ? status : `${n} ${status}`));
    const stale = open.filter((op) => op.stale).length;
    const words = [`Proposed ${ops.length} change${ops.length === 1 ? "" : "s"}`, ...counts, ...(stale ? [`${stale} no longer applies`] : [])];
    const button = node("button", `proposal-chip ${toneOf(ops[0].thread)}${open.length ? "" : " done"}`);
    button.append(node("span", "ip-dot"), node("span", "", words.join(" · ")));
    const files_ = [...new Set(ops.map((op) => op.file))];
    button.append(node("span", "chip-files", files_.join(", ")));
    if (open.length) {
      button.append(node("span", "chip-view", "view"));
      button.title = "Show them in the editor";
    }
    button.addEventListener("click", () => {
      const first = open.find((op) => !op.stale);
      if (first) focus(first.file, first.id);
    });
    if (open.length && open.every((op) => op.check?.ok && !op.stale)) {
      const link = button.appendChild(node("span", "chip-view", "accept"));
      link.title = "Accept them, as a new version";
      link.addEventListener("click", (event) => {
        event.stopPropagation();
        acceptIds(open.map((op) => op.id));
      });
    }
    return button;
  }

  return {
    update(view) {
      state.view = view;
      refresh();
    },
    refresh,
    chip,
    pending: () => pending().length,
  };
}
