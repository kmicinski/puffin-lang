// The observation lint (docs/STUDIO.md §3.1; studio/src/holes.rs): a match
// with no catch-all whose parameter the live session saw take a shape no
// clause handles. Each finding is an info marker in the observed style
// (cyan, as everything seen in runs is), never an error: it says what was
// seen so far, not what must be. The lightbulb on it offers the
// add-missing-cases assist with source observed (assists.js).
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

  function refresh() {
    for (const path of files.paths()) {
      editor.markers(path, current(path).map((finding) => ({
        start: finding.start,
        end: finding.end,
        severity: "info",
        message: `observed: ${finding.message}\n(seen so far in this session's runs, not proof; the lightbulb adds the cases)`,
        source: LINT_SOURCE,
      })), "observed");
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
