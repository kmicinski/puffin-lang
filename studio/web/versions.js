// A file's versions (studio/src/versions.rs): the Versions panel
// (,versions) lists the shown file's, newest first, with the forms each
// changed; the project's whole history is history.js.
// Compare shows a version's difference to the text now; Restore makes it
// the text again, as a new version.

import { lineDiff } from "./hunks.js";
import { el } from "./dom.js";
import { timeOfDay } from "./words.js";

const ORIGINS = { open: "opened", save: "saved", accept: "accepted", disk: "changed on disk", restore: "restored" };

export function createVersions({ panel, files, send }) {
  let open = false;
  let compare = null; // { id, file, text }

  function show(on) {
    open = on;
    panel.hidden = !on;
    if (on) request();
  }

  function request() {
    const file = files.active();
    if (open && file) files.send({ t: "versions", file });
  }

  function render(file, versions) {
    panel.replaceChildren();
    const head = panel.appendChild(el("div", "versions-head"));
    head.append(el("span", "", `Versions of ${file}`));
    const x = head.appendChild(el("button", "quiet small", "×"));
    x.addEventListener("click", () => show(false));
    if (!versions.length) panel.append(el("p", "hint", "No versions yet."));
    for (const version of [...versions].reverse()) {
      const row = panel.appendChild(el("div", "version-row"));
      row.append(el("span", "version-id", `v${version.id}`), el("span", `version-origin ${version.origin}`, ORIGINS[version.origin] ?? version.origin));
      row.append(el("span", "version-when", timeOfDay(version.created)));
      const what = row.appendChild(el("span", "version-what", version.label || version.forms_changed.map((f) => f.split(":").slice(1).join(":")).join(", ")));
      what.title = version.forms_changed.join("\n");
      const diff = row.appendChild(el("button", "quiet small", "Compare"));
      diff.addEventListener("click", () => send({ t: "version-text", id: version.id }));
      const restore = row.appendChild(el("button", "secondary small", "Restore"));
      restore.title = "Make this the file's text again, as a new version (undo takes it back)";
      restore.addEventListener("click", () => {
        files.flush();
        send({ t: "restore", id: version.id });
        send({ t: "echo", line: `,restore v${version.id}` });
      });
    }
    if (compare) renderCompare();
  }

  function renderCompare() {
    const now = files.texts()[compare.file] ?? "";
    const box = panel.appendChild(el("div", "version-compare"));
    const head = box.appendChild(el("div", "versions-head"));
    head.append(el("span", "", `v${compare.id} → now`));
    const x = head.appendChild(el("button", "quiet small", "×"));
    x.addEventListener("click", () => { compare = null; request(); });
    const pre = box.appendChild(el("pre", "version-diff"));
    const diff = lineDiff(compare.text.split("\n"), now.split("\n"));
    if (!diff.some((d) => d.kind !== "same")) pre.append(el("span", "same", "the same as now"));
    diff.forEach((line, i) => {
      const near = diff.slice(Math.max(0, i - 2), i + 3).some((d) => d.kind !== "same");
      if (line.kind === "same" && !near) return;
      pre.append(el("div", `diff-${line.kind}`, `${line.kind === "add" ? "+" : line.kind === "del" ? "-" : " "} ${line.text}`));
    });
  }

  return {
    opened: request,
    changed: request,
    // ,history: the panel, shown or hidden; what it says in the transcript
    toggle() {
      show(!open);
      return open ? `the Versions panel lists ${files.active()}'s versions (,versions again hides it)` : "Versions hidden";
    },
    receive: {
      versions({ file, versions }) {
        if (open && file === files.active()) render(file, versions);
      },
      "version-text"({ id, file, text }) {
        compare = { id, file, text };
        request();
      },
      version({ version }) {
        if (open && version.file === files.active()) request();
      },
    },
  };
}
