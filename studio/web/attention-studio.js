// The attention model's view of the studio (docs/ATTENTION.md §5): fold
// the WebSocket's messages into the state attention.js ranks, so a UI need
// only pass its own focus, and its own edits (a tab's edits are not echoed
// back to it).
//
//   const tracker = createTracker();
//   socket messages -> tracker.receive(message)
//   the author types -> tracker.edit(file, fromLine, toLine)
//   attention.rank(tracker.state({ focus }), budget)
//
// What it keeps: the outline and board (init, board), the latest check
// errors (init, diagnostics), the latest property results (voice
// "properties"), who edited what and when (voice "edited" for the
// builder, text from another tab for the author), and what voice
// navigation pointed at (voice "focus"). The board's own focus -- a
// question's slice, "just step and inject" -- becomes the state's context.

import { graph, idOf } from "./attention.js";

const KEEP = 200; // edits and mentions remembered, newest kept

export function createTracker({ now = Date.now } = {}) {
  let outline = [];
  let g = graph(outline);
  let board = {};
  const texts = new Map();
  let errors = [];
  let properties = [];
  let edits = [];
  let voice = [];

  // the definitions of `file` spanning lines from..to, by the latest outline
  const span = (file, from, to) => {
    const m = outline.find((x) => x.path === file);
    return (m?.items ?? []).filter((i) => i.line <= to && from <= (i.end_line ?? i.line)).map((i) => idOf(file, i.name));
  };
  const at = (file, line) => span(file, line, line)[0] ?? null;
  const remember = (list, entries) => [...list, ...entries].slice(-KEEP);

  function setBoard(view) {
    if (view?.outline) {
      outline = view.outline;
      g = graph(outline);
    }
    if (view?.board) board = view.board;
  }

  function setDiagnostics(reports) {
    errors = Object.values(reports ?? {})
      .flatMap((r) => r.diagnostics ?? [])
      .filter((d) => d.severity === "error" && d.file && d.line)
      .map((d) => at(d.file, d.line))
      .filter(Boolean);
  }

  const tracker = {
    receive(message) {
      switch (message.t) {
        case "init":
          setBoard(message.board);
          for (const f of message.files ?? []) texts.set(f.path, f.text);
          setDiagnostics(message.diagnostics);
          break;
        case "board":
          setBoard(message);
          break;
        case "diagnostics":
          setDiagnostics(message.reports);
          break;
        case "text": {
          // another tab (the author elsewhere), or the studio itself (0: an
          // accepted proposal, a restore)
          const [from, to] = changedLines(texts.get(message.file) ?? "", message.text);
          texts.set(message.file, message.text);
          if (from) tracker.edit(message.file, from, to, message.origin === 0 ? "builder" : "author");
          break;
        }
        case "voice":
          if (message.kind === "edited" && message.file) tracker.edit(message.file, message.from ?? 1, message.to ?? message.from ?? 1, "builder");
          if (message.kind === "properties") properties = (message.results?.properties ?? []).map((p) => ({ name: p.name, status: p.status }));
          if (message.kind === "focus") {
            const by = message.from === "builder" ? "builder" : "author";
            const ids = (message.targets ?? []).map((t) => at(t.file, t.line)).filter(Boolean);
            voice = remember(voice, ids.map((id) => ({ id, at: now(), by })));
          }
          break;
      }
    },
    // lines from..to of `file` changed, by the author or the builder;
    // returns the definitions they fall in
    edit(file, from, to, by = "author") {
      const ids = span(file, from, to);
      edits = remember(edits, ids.map((id) => ({ id, at: now(), by })));
      return ids;
    },
    // the definition at a cursor, or null
    at,
    graph: () => g,
    // the model's state; `extra` adds the UI's own: focus, views, a context
    state(extra = {}) {
      const focus = board.focus;
      // a slice's items are [file, name]; a property's name is "@line"
      const context = focus?.items?.length
        ? { ids: focus.items.filter(([, name]) => !name.startsWith("@")).map(([file, name]) => idOf(file, name)), label: focus.question ? `in question #${focus.question}` : focus.label ?? "in focus" }
        : undefined;
      return {
        now: now(), outline, graph: g, edits, properties, errors, voice, context,
        questions: (board.questions ?? []).map((q) => ({ text: q.text, about: q.about ?? [], answered: !!q.answered })),
        ...extra,
      };
    },
  };
  return tracker;
}

// The 1-based first and last line of `after` that differ from `before`
// (common prefix and suffix trimmed); [0, 0] when they are the same.
export function changedLines(before, after) {
  if (before === after) return [0, 0];
  const a = before.split("\n");
  const b = after.split("\n");
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  let end = 0;
  while (end < a.length - start && end < b.length - start && a[a.length - 1 - end] === b[b.length - 1 - end]) end++;
  return [start + 1, Math.max(start + 1, b.length - end)];
}
