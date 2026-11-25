// The command palette (⌘K / ctrl-K): every action of the studio and every
// definition of the program, in one list you type into. A definition goes
// to its place in the editor (↵) or to its slice on the board (⇧↵).
//
// Matching is by letters in order (as VS Code's quick open), scored so a
// match at the start of a word, or of the whole title, ranks first.

import { el, nameField } from "./dom.js";

// a score for `typed` in `text` (higher is better), or -1
function score(text, typed) {
  if (!typed) return 0;
  const hay = text.toLowerCase();
  const direct = hay.indexOf(typed);
  if (direct === 0) return 1000 - hay.length;
  if (direct > 0) return 600 - direct + (/[\s/:(-]/.test(hay[direct - 1]) ? 200 : 0);
  let at = 0;
  let total = 0;
  let last = -2;
  let first = -1;
  for (const c of typed) {
    const found = hay.indexOf(c, at);
    if (found < 0) return -1;
    if (first < 0) first = found;
    total += found === last + 1 ? 8 : 1;
    if (found === 0 || /[\s/:(-]/.test(hay[found - 1])) total += 6;
    last = found;
    at = found + 1;
  }
  // letters strewn across the whole title are not a match
  if (last - first + 1 > typed.length * 3) return -1;
  return total;
}

export function createPalette({ stage, commands }) {
  const shade = el("div", "palette-shade");
  shade.hidden = true;
  const box = el("div", "palette");
  const field = nameField("palette-input", "Type a command, a file, or a definition");
  const list = el("div", "palette-list");
  const foot = el("div", "palette-foot");
  foot.append(el("span", "", "↑↓ choose"), el("span", "", "↵ run"), el("span", "", "⇧↵ definition on the board"), el("span", "", "Esc close"));
  box.append(field, list, foot);
  shade.append(box);
  (stage ?? document.body).append(shade);

  let all = [];
  let shown = [];
  let at = 0;
  let returnFocus = null;

  function refresh() {
    const typed = field.value.trim().toLowerCase();
    shown = all
      .map((c) => ({ c, s: Math.max(score(c.title, typed), score(`${c.group} ${c.title}`, typed) - 50, c.keywords ? score(c.keywords, typed) - 80 : -1) }))
      .filter((x) => x.s >= 0)
      .sort((a, b) => b.s - a.s || (a.c.rank ?? 5) - (b.c.rank ?? 5))
      .slice(0, 60)
      .map((x) => x.c);
    if (!typed) shown = all.filter((c) => !c.hiddenUntilTyped).slice(0, 60);
    at = Math.min(at, Math.max(0, shown.length - 1));
    list.replaceChildren();
    let group = null;
    shown.forEach((c, i) => {
      if (!typed && c.group !== group) {
        list.append(el("div", "palette-group", c.group));
        group = c.group;
      }
      const row = el("div", `palette-row${i === at ? " on" : ""}`);
      const icon = el("span", "palette-icon", c.icon ?? "›");
      const title = el("span", "palette-title", c.title);
      row.append(icon, title);
      if (c.detail) row.append(el("span", "palette-detail", c.detail));
      if (c.keys) row.append(el("kbd", "palette-keys", c.keys));
      row.addEventListener("mousedown", (event) => {
        event.preventDefault();
        run(c, event.shiftKey);
      });
      row.addEventListener("mousemove", () => {
        if (at !== i) {
          at = i;
          paint();
        }
      });
      list.append(row);
    });
    if (!shown.length) list.append(el("div", "palette-none", "Nothing matches"));
  }

  function paint() {
    list.querySelectorAll(".palette-row").forEach((row, i) => row.classList.toggle("on", i === at));
    list.querySelector(".palette-row.on")?.scrollIntoView({ block: "nearest" });
  }

  function run(c, alt) {
    close();
    setTimeout(() => (alt && c.alt ? c.alt() : c.run()), 0);
  }

  function open(prefill = "") {
    returnFocus = document.activeElement;
    all = commands();
    field.value = prefill;
    at = 0;
    shade.hidden = false;
    refresh();
    setTimeout(() => field.focus(), 0);
  }

  function close() {
    if (shade.hidden) return;
    shade.hidden = true;
    returnFocus?.focus?.();
  }

  field.addEventListener("input", () => {
    at = 0;
    refresh();
  });
  field.addEventListener("keydown", (event) => {
    event.stopPropagation();
    if (event.key === "ArrowDown") { event.preventDefault(); at = Math.min(shown.length - 1, at + 1); paint(); }
    else if (event.key === "ArrowUp") { event.preventDefault(); at = Math.max(0, at - 1); paint(); }
    else if (event.key === "Enter") { event.preventDefault(); if (shown[at]) run(shown[at], event.shiftKey); }
    else if (event.key === "Escape") { event.preventDefault(); close(); }
  });
  shade.addEventListener("mousedown", (event) => { if (event.target === shade) close(); });
  window.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && !event.shiftKey && event.key.toLowerCase() === "k") {
      event.preventDefault();
      event.stopPropagation();
      shade.hidden ? open() : close();
    }
  }, true);

  return { open, close };
}
