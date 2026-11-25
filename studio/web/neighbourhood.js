// The neighbourhood (docs/VIEW.md): under the focus, the board around
// it, from the outline -- what uses it on the left, what it uses on the
// right, wired; the properties that mention it; its module's rows. Every
// node is a key stop: the arrow keys walk them by where they sit on the
// screen, ↵ brings a node's definition into the working set, ⇧↵ focuses
// it, ] and [ bring what it uses or what uses it, Esc goes back to the
// code. A click is ↵, a double-click ⇧↵.

import { KIND, clicks } from "./board.js";
import { svg, curve } from "./wires.js";
import { el } from "./dom.js";

const NODES_MAX = 10;

const short = (path) => path.replace(/\.puf$/, "");
const keyOf = (path, name) => `${path}\u001f${name}`;

// `outline()` the board's; `itemOf(def)`, `neighbours(def)` its lookups;
// `inSet(def)` whether the working set holds it; `pull`, `focus`, `along`,
// `hover`, `back` what the view does with a node.
export function createNeighbourhood({ outline, itemOf, neighbours, inSet, pull, focus: show, along, hover, back }) {
  const graph = el("div", "view-graph");
  const wires = svg("svg", { class: "view-graph-wires" });
  let focus = null;

  function node(def, role) {
    const item = itemOf(def);
    const chip = el("button", `view-node ${role}`);
    chip.dataset.key = keyOf(def.path, def.name);
    chip.dataset.role = role;
    chip.append(el("span", "view-kind", KIND[item?.kind] ?? "·"), el("span", "view-node-name", item?.kind === "property" ? item.sig : def.name));
    if (def.path !== focus?.path && role !== "focus" && item?.kind !== "property") chip.append(el("span", "view-module", short(def.path)));
    if (inSet(def)) chip.classList.add("in-set");
    if (item?.opaque) chip.classList.add("planned");
    chip.title = `${item?.sig ?? def.name}${item?.doc ? `\n${item.doc}` : ""}\nclick or ↵: into the lane · double-click or ⇧↵: focus on it`;
    if (role !== "focus") clicks(chip, (event) => (event.metaKey || event.ctrlKey || event.shiftKey ? show(def) : pull(def)), () => show(def));
    const key = keyOf(def.path, def.name);
    chip.addEventListener("pointerenter", () => hover(key));
    chip.addEventListener("pointerleave", () => hover(null));
    chip.addEventListener("focus", () => hover(key));
    chip.addEventListener("blur", () => hover(null));
    chip.addEventListener("keydown", (event) => keys(event, def, chip));
    return chip;
  }

  function nodes(list, role) {
    const row = el("div", `view-row ${role}`);
    const sorted = [...list].sort((a, b) => (a.path === focus.path ? 0 : 1) - (b.path === focus.path ? 0 : 1) || a.path.localeCompare(b.path) || a.name.localeCompare(b.name));
    for (const def of sorted.slice(0, NODES_MAX)) row.append(node(def, role));
    if (sorted.length > NODES_MAX) row.append(el("span", "view-more", `+${sorted.length - NODES_MAX}`));
    return row;
  }

  // the neighbourhood of `def` (null: no definition in focus, just its module)
  function render(def, path) {
    focus = def;
    const had = graph.contains(document.activeElement) ? document.activeElement.dataset.key : null;
    graph.replaceChildren();
    const item = def && itemOf(def);
    const body = el("div", "view-graph-body");
    const map = el("div", "view-map");
    const aside = el("div", "view-aside");
    body.append(map, aside);
    graph.append(body);
    if (item) {
      const { uses, users } = neighbours(def);
      const callers = users.filter((d) => itemOf(d)?.kind !== "property");
      const properties = users.filter((d) => itemOf(d)?.kind === "property");
      const group = (role, list, label) => {
        const part = el("div", `view-part ${role}`);
        part.append(el("div", "view-row-label", label), nodes(list, role));
        return part;
      };
      const middle = el("div", "view-part focus");
      middle.append(node(def, "focus"));
      map.append(group("caller", callers, callers.length ? "used by" : "used by nothing"), middle, group("callee", uses, uses.length ? "uses" : "uses nothing of the program's"));
      map.append(wires);
      if (properties.length) {
        aside.append(el("div", "view-section", "properties"));
        const list = el("div", "view-props");
        for (const p of properties) list.append(node(p, "property"));
        aside.append(list);
      }
    }
    // the focus's module: its other definitions, a click away
    const m = outline().find((mm) => mm.path === (def?.path ?? path));
    if (m) {
      aside.append(el("div", "view-section", `${short(m.path)}${m.requires.length ? ` · requires ${m.requires.map(short).join(", ")}` : ""}`));
      const card = el("div", "view-card");
      for (const i of m.items) {
        const row = node({ path: m.path, name: i.name }, "row");
        row.replaceChildren(el("span", "view-kind", KIND[i.kind] ?? "·"), el("span", "view-card-sig", i.kind === "property" ? i.sig : i.sig.replace(/^val /, "")));
        row.classList.toggle("current", i.name === def?.name);
        card.append(row);
      }
      aside.append(card);
    }
    if (had) graph.querySelector(`.view-node[data-key="${CSS.escape(had)}"]`)?.focus({ preventScroll: true });
    requestAnimationFrame(drawWires);
  }

  // curves from each caller to the focus, and from it to each callee:
  // left to right, or top to bottom when the map is stacked (narrow)
  function drawWires() {
    if (!wires.isConnected) return;
    const map = wires.parentNode;
    const box = map.getBoundingClientRect();
    const down = getComputedStyle(map).flexDirection !== "row";
    wires.replaceChildren();
    const center = map.querySelector(".view-node.focus")?.getBoundingClientRect();
    if (!center) return;
    // the point a wire leaves (end) or enters a box
    const point = (r, end) => (down
      ? { x: r.left + r.width / 2 - box.left, y: (end ? r.bottom : r.top) - box.top }
      : { x: (end ? r.right : r.left) - box.left, y: r.top + r.height / 2 - box.top });
    for (const chip of map.querySelectorAll(".view-node.caller, .view-node.callee")) {
      const r = chip.getBoundingClientRect();
      const caller = chip.classList.contains("caller");
      const [a, b] = caller ? [point(r, true), point(center, false)] : [point(center, true), point(r, false)];
      wires.append(svg("path", { d: curve(a, b, { down }), class: `wire ${caller ? "caller" : "callee"}` }));
    }
  }

  // Arrow keys go to the nearest node that way (nearer along it than
  // across it); ↵ and the rest act on the node.
  function keys(event, def, chip) {
    const go = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[event.key];
    if (go) {
      event.preventDefault();
      const from = chip.getBoundingClientRect();
      const cx = from.left + from.width / 2;
      const cy = from.top + from.height / 2;
      let best = null;
      for (const other of graph.querySelectorAll(".view-node")) {
        if (other === chip) continue;
        const r = other.getBoundingClientRect();
        const dx = r.left + r.width / 2 - cx;
        const dy = r.top + r.height / 2 - cy;
        const ahead = dx * go[0] + dy * go[1];
        const aside = Math.abs(dx * go[1]) + Math.abs(dy * go[0]);
        if (ahead <= 2) continue;
        const cost = ahead + aside * 2.5;
        if (!best || cost < best.cost) best = { other, cost };
      }
      best?.other.focus();
      return;
    }
    const act = {
      Enter: () => (event.shiftKey || event.metaKey || event.ctrlKey ? show(def) : chip.dataset.role === "focus" ? back() : pull(def)),
      "]": () => along(def, "uses"),
      "[": () => along(def, "users"),
      Escape: back,
    }[event.key];
    if (act) {
      event.preventDefault();
      event.stopPropagation();
      act();
    }
  }

  return {
    node: graph,
    render,
    drawWires,
    // the node showing `key` lit (hover elsewhere), or none
    light(key) {
      for (const n of graph.querySelectorAll(".view-node.lit")) n.classList.remove("lit");
      if (key) graph.querySelector(`.view-node[data-key="${CSS.escape(key)}"]`)?.classList.add("lit");
    },
    // the keyboard into it (F6): the focus's node, else the first
    enter: () => graph.querySelector(".view-node.focus, .view-node")?.focus(),
    has: () => graph.contains(document.activeElement),
  };
}
