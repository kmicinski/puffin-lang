// An excursion (docs/VOICE.md §5; the server side is studio/src/excursion.rs):
// a panel docked at the right, the editor moved aside to make room, that
// holds the fragments of code being explained -- the one it started on,
// then each one pulled in as the explanation needed it -- and the thread of
// questions and answers under them. The fragments are marked in the editor
// too, and each answer moves the view to the lines it centers on.
//
// It is opened and grown by voice ("explain the fix clause", "and what does
// apply-fn do?"); ✕ or "close the excursion" ends it.

import { markdown } from "./markdown.js";
import { el } from "./dom.js";

const escape = (text) => text.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

export function createExcursion({ host, view, monaco, files, go, close }) {
  const card = el("div", "voice-excursion voice-float");
  card.hidden = true;
  const head = el("div", "voice-card-head");
  const title = el("span", "voice-excursion-title", "Excursion");
  const x = el("button", "voice-x", "✕");
  x.title = "Close the excursion (say “close the excursion”)";
  x.addEventListener("click", () => close());
  head.append(title, x);
  const body = el("div", "voice-excursion-body");
  const pieces = el("div", "voice-excursion-fragments");
  const thread = el("div", "voice-excursion-thread");
  body.append(pieces, thread);
  card.append(head, body);
  host.prepend(card);

  let current = null; // the excursion as last shown
  let ticker = 0;
  const decorations = new Map(); // model -> decoration ids

  // ---- the editor: the fragments marked where they are ----------------------------
  function mark() {
    const model = view?.getModel();
    if (!model || !monaco) return;
    const file = files.active();
    const ranges = (current?.fragments ?? []).filter((f) => f.file === file);
    const last = model.getLineCount();
    const next = ranges.map((f) => ({
      range: new monaco.Range(Math.min(f.from, last), 1, Math.min(f.to, last), 1),
      options: { isWholeLine: true, className: "voice-excursion-range", linesDecorationsClassName: "voice-excursion-gutter" },
    }));
    decorations.set(model, model.deltaDecorations(decorations.get(model) ?? [], next));
  }
  function unmarkAll() {
    for (const [model, ids] of decorations) {
      if (!model.isDisposed?.()) model.deltaDecorations(ids, []);
    }
    decorations.clear();
  }
  // the shown file can change under it
  let shownFile = null;
  setInterval(() => {
    if (current && files.active() !== shownFile) {
      shownFile = files.active();
      mark();
    }
  }, 700);

  // ---- the panel -------------------------------------------------------------------
  async function code(fragment, highlight) {
    const box = el("div", "voice-excursion-code");
    const lines = fragment.text.split("\n");
    let html = lines.map(escape);
    try {
      if (monaco?.editor?.colorize) {
        const colored = await monaco.editor.colorize(fragment.text, "puffin", { tabSize: 2 });
        const split = colored.split(/<br\/?>/);
        if (split.length >= lines.length) html = split.slice(0, lines.length);
      }
    } catch { /* plain text, then */ }
    html.forEach((line, i) => {
      const n = fragment.from + i;
      const row = el("div", "voice-excursion-line");
      if (highlight && highlight.file === fragment.file && n >= highlight.from && n <= highlight.to) row.classList.add("hot");
      const number = el("span", "voice-excursion-n", String(n));
      const text = el("span", "voice-excursion-src");
      text.innerHTML = line || "&nbsp;";
      row.append(number, text);
      row.addEventListener("click", () => go(fragment.file, n, n));
      box.append(row);
    });
    return box;
  }

  async function render(excursion, { replaying = false } = {}) {
    const before = current;
    current = excursion;
    document.body.classList.toggle("excursion-open", Boolean(excursion));
    if (!excursion) {
      card.hidden = true;
      unmarkAll();
      clearInterval(ticker);
      ticker = 0;
      return;
    }
    card.hidden = false;
    const isNew = !before || before.id !== excursion.id;
    const known = new Set(isNew ? [] : (before.fragments ?? []).map((f) => `${f.file}:${f.from}`));
    const exchanges = excursion.thread ?? [];
    const latest = exchanges[exchanges.length - 1];
    const highlight = [...exchanges].reverse().find((e) => e.highlight)?.highlight ?? null;
    title.textContent = excursion.fragments?.[0]?.label ? `Excursion · ${excursion.fragments[0].label}` : "Excursion";

    // the fragments, the newest last, each a way to its lines
    const made = await Promise.all((excursion.fragments ?? []).map(async (f) => {
      const box = el("div", "voice-excursion-fragment");
      if (!known.has(`${f.file}:${f.from}`) && !isNew) box.classList.add("arrived");
      const where = el("button", "voice-excursion-where");
      where.append(el("span", "voice-excursion-label", f.label), el("span", "voice-excursion-place", `${f.file}:${f.from}${f.to > f.from ? `–${f.to}` : ""}`));
      where.title = "Show these lines in the editor";
      where.addEventListener("click", () => go(f.file, f.from, f.to));
      box.append(where);
      if (f.why) box.append(el("div", "voice-excursion-why", `pulled in: ${f.why}`));
      box.append(await code(f, highlight));
      return box;
    }));
    if (current !== excursion) return; // a newer one arrived while colouring
    pieces.replaceChildren(...made);

    // the thread
    thread.replaceChildren(...exchanges.map((e) => {
      const node = el("div", "voice-excursion-exchange");
      node.append(el("div", "voice-excursion-q", e.question));
      if (e.answer == null) {
        const waiting = el("div", "voice-excursion-wait", "thinking…");
        node.append(waiting);
      } else {
        const a = el("div", `voice-excursion-a${e.failed ? " bad" : ""}`);
        a.innerHTML = markdown(e.answer);
        // `file:line` in an answer: a way there
        a.querySelectorAll("code").forEach((c) => {
          const m = c.textContent.match(/^([\w./-]+\.puf):(\d+)(?:[-–](\d+))?$/);
          if (!m) return;
          c.classList.add("voice-excursion-cite");
          c.title = "Show it";
          c.addEventListener("click", () => go(m[1], Number(m[2]), Number(m[3] ?? m[2])));
        });
        node.append(a);
      }
      return node;
    }));

    // a running clock on the question being answered
    clearInterval(ticker);
    ticker = 0;
    if (latest && latest.answer == null) {
      const started = Date.now();
      ticker = setInterval(() => {
        const wait = thread.querySelector(".voice-excursion-wait");
        if (wait) wait.textContent = `thinking… ${Math.floor((Date.now() - started) / 1000)}s`;
      }, 1000);
    }

    mark();
    if (replaying) return;
    // the newest question in view, and the answer's lines in the editor
    const lastNode = thread.lastElementChild;
    if (lastNode) body.scrollTop = Math.max(0, lastNode.offsetTop - body.offsetTop - 8);
    const answeredNow = latest?.answer != null && before?.thread?.[exchanges.length - 1]?.answer == null && !isNew;
    const startedNow = isNew || (before?.thread?.length ?? 0) < exchanges.length;
    if (answeredNow && latest.highlight) go(latest.highlight.file, latest.highlight.from, latest.highlight.to);
    else if (startedNow) {
      const f = excursion.fragments?.[excursion.fragments.length - 1];
      if (f) go(f.file, f.from, f.to);
    }
  }

  return {
    receive: (excursion, replaying) => render(excursion ?? null, { replaying }),
    open: () => Boolean(current),
  };
}
