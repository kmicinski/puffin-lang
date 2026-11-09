// Projects (studio/src/project.rs): the menu under the project's name
// lists the projects in the home, latest first, opens one, and makes a new
// one -- named, or with a short random name when the field is left empty.
// A new project is a git repository from its first moment; opening or
// making one makes the studio serve it, and every tab reloads.
//
//   createProjects({ button, menu, send }) -> { receive }

const element = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

const when = (ms) => {
  if (!ms) return "";
  const date = new Date(ms);
  const today = new Date().toDateString() === date.toDateString();
  return today ? date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : date.toLocaleDateString([], { month: "short", day: "numeric" });
};

export function createProjects({ button, menu, send }) {
  let open = false;
  let seq = 0;
  let listing = { home: "", current: "", projects: [] };

  function show(on) {
    open = on;
    menu.hidden = !on;
    button.setAttribute("aria-expanded", String(on));
    if (on) {
      send({ t: "projects", seq: ++seq });
      render();
    }
  }

  function render() {
    menu.replaceChildren();
    const make = menu.appendChild(element("form", "projects-new"));
    const name = make.appendChild(element("input"));
    name.placeholder = "name (empty: a random one)";
    name.spellcheck = false;
    name.autocomplete = "off";
    const go = make.appendChild(element("button", "btn new small", "New project"));
    go.type = "submit";
    make.addEventListener("submit", (event) => {
      event.preventDefault();
      const typed = name.value.trim();
      send({ t: "new-project", name: typed || null });
      go.disabled = true;
      go.textContent = "making…";
    });
    const list = menu.appendChild(element("div", "projects-list"));
    const { projects, current, home } = listing;
    if (!projects.length) list.append(element("p", "hint", home ? `No projects in ${home} yet.` : "Loading…"));
    for (const project of projects) {
      const here = project.directory === current;
      const row = list.appendChild(element("button", `projects-row${here ? " here" : ""}`));
      row.type = "button";
      row.title = project.directory;
      row.append(element("span", "projects-name", project.name), element("span", "projects-when", here ? "open now" : when(project.modified)));
      row.disabled = here;
      row.addEventListener("click", () => send({ t: "open-project", name: project.name }));
    }
    if (home) menu.append(element("div", "projects-home", home));
    setTimeout(() => name.focus(), 0);
  }

  button.addEventListener("click", (event) => {
    event.stopPropagation();
    show(!open);
  });
  document.addEventListener("click", (event) => {
    if (open && !menu.contains(event.target)) show(false);
  });
  document.addEventListener("keydown", (event) => {
    if (open && event.key === "Escape") show(false);
  });

  return {
    receive: {
      projects(reply) {
        if (reply.seq !== seq) return;
        listing = reply;
        if (open) render();
      },
      // the studio serves another project now
      reopen() {
        location.reload();
      },
    },
  };
}
