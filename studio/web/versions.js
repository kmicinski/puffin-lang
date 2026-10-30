// A file's versions (studio/src/versions.rs): the History panel lists the
// shown file's, newest first, with the forms each changed. Compare shows a
// version's difference to the text now; Restore makes it the text again, as
// a new version.

import { lineDiff } from "./hunks.js";

const element = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

const ORIGINS = { open: "opened", save: "saved", accept: "accepted", disk: "changed on disk", restore: "restored" };

export function createVersions({ panel, toggle, files, send }) {
  let open = false;
  let compare = null; // { id, file, text }

  function show(on) {
    open = on;
    panel.hidden = !on;
    toggle.setAttribute("aria-pressed", String(on));
    if (on) request();
  }
  toggle.addEventListener("click", () => show(!open));

  function request() {
    const file = files.active();
    if (open && file) files.send({ t: "versions", file });
  }

  function render(file, versions) {
    panel.replaceChildren();
    const head = panel.appendChild(element("div", "versions-head"));
    head.append(element("span", "", `History of ${file}`));
    const x = head.appendChild(element("button", "quiet small", "×"));
    x.addEventListener("click", () => show(false));
    if (!versions.length) panel.append(element("p", "hint", "No versions yet."));
    for (const version of [...versions].reverse()) {
      const row = panel.appendChild(element("div", "version-row"));
      const when = new Date(version.created).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
      row.append(element("span", "version-id", `v${version.id}`), element("span", `version-origin ${version.origin}`, ORIGINS[version.origin] ?? version.origin));
      row.append(element("span", "version-when", when));
      const what = row.appendChild(element("span", "version-what", version.label || version.forms_changed.map((f) => f.split(":").slice(1).join(":")).join(", ")));
      what.title = version.forms_changed.join("\n");
      const diff = row.appendChild(element("button", "quiet small", "Compare"));
      diff.addEventListener("click", () => send({ t: "version-text", id: version.id }));
      const restore = row.appendChild(element("button", "secondary small", "Restore"));
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
    const box = panel.appendChild(element("div", "version-compare"));
    const head = box.appendChild(element("div", "versions-head"));
    head.append(element("span", "", `v${compare.id} → now`));
    const x = head.appendChild(element("button", "quiet small", "×"));
    x.addEventListener("click", () => { compare = null; request(); });
    const pre = box.appendChild(element("pre", "version-diff"));
    const diff = lineDiff(compare.text.split("\n"), now.split("\n"));
    if (!diff.some((d) => d.kind !== "same")) pre.append(element("span", "same", "the same as now"));
    diff.forEach((line, i) => {
      const near = diff.slice(Math.max(0, i - 2), i + 3).some((d) => d.kind !== "same");
      if (line.kind === "same" && !near) return;
      pre.append(element("div", `diff-${line.kind}`, `${line.kind === "add" ? "+" : line.kind === "del" ? "-" : " "} ${line.text}`));
    });
  }

  return {
    opened: request,
    changed: request,
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
