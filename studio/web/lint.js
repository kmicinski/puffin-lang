// The observation lint (docs/STUDIO.md §3.1; studio/src/holes.rs): a match
// with no catch-all whose parameter the live session saw take a shape no
// clause handles. Each finding is an info marker in the observed style
// (cyan, as everything seen in runs is), never an error: it says what was
// seen so far, not what must be. A match the file's own call sites pass an
// unhandled shape is marked the same way, in the same marker. The lightbulb
// on it offers the add-missing-cases assist with source observed, or
// call-site (assists.js).
//
//   createLint({ editor, files }) -> { refresh, within, receive }
//   within(file, start, end)  the findings inside [start, end) of `file`,
//                             when they are for the text shown

export const LINT_SOURCE = "observed in this session";

export function createLint({ editor, files }) {
  // file -> { version, items: [{ start, end, pos, line, source, message }] }
  const known = new Map();

  const current = (file) => {
    const marks = known.get(file);
    return marks && marks.version === files.version(file) && files.synced(file) ? marks.items : [];
  };

  // One marker a match: what the session saw, and what the file's own call
  // sites pass, each said once.
  function refresh() {
    for (const path of files.paths()) {
      const byMatch = new Map();
      for (const finding of current(path)) {
        const list = byMatch.get(finding.start) ?? [];
        if (!list.some((known) => known.message === finding.message)) list.push(finding);
        byMatch.set(finding.start, list);
      }
      editor.markers(path, [...byMatch.values()].map((list) => {
        list.sort((a, b) => (a.source === "observed" ? 0 : 1) - (b.source === "observed" ? 0 : 1));
        const lines = list.map((finding) => (finding.source === "observed"
          ? `observed: ${finding.message} (seen so far in runs, not proof)`
          : `call site: ${finding.message}`));
        return {
          start: list[0].start,
          end: list[0].end,
          severity: "info",
          message: `${lines.join("\n")}\nThe lightbulb adds the cases.`,
          source: LINT_SOURCE,
        };
      }), "observed");
    }
  }

  return {
    refresh,
    within: (file, start, end) => current(file).filter((finding) => finding.start < end && finding.end > start),
    receive: {
      init(snapshot) {
        known.clear();
        for (const [file, marks] of Object.entries(snapshot.lint ?? {})) known.set(file, marks);
        refresh();
      },
      lint({ file, lint }) {
        if (lint.items.length) known.set(file, lint);
        else known.delete(file);
        refresh();
      },
    },
  };
}
