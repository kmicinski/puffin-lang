// Wires (docs/VIEW.md): the curves that say "this uses that" on the
// screen -- from the line of code that uses a name to the fragment holding
// its definition, from a fragment to its row on its module's card, from a
// caller to the focus in the neighbourhood, from a row to what it uses
// under the lens. One shape for all of them, so they read as one language.

const SVG = "http://www.w3.org/2000/svg";

export const svg = (tag, attrs = {}) => {
  const node = document.createElementNS(SVG, tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
  return node;
};

// A curve from a to b leaving and arriving horizontally (`down`:
// vertically). `out` sends a wire whose ends are on the same side back
// round that side (a = the right edge of one box, b = the right edge of
// another below it).
export function curve(a, b, { down = false, out = 0 } = {}) {
  if (out) {
    const x = Math.max(a.x, b.x) + out;
    return `M ${a.x} ${a.y} C ${x} ${a.y} ${x} ${b.y} ${b.x} ${b.y}`;
  }
  if (down) {
    const my = (a.y + b.y) / 2;
    return `M ${a.x} ${a.y} C ${a.x} ${my} ${b.x} ${my} ${b.x} ${b.y}`;
  }
  const bend = Math.max(30, Math.abs(b.x - a.x) / 2.2) * (b.x >= a.x ? 1 : -1);
  return `M ${a.x} ${a.y} C ${a.x + bend} ${a.y} ${b.x - bend} ${b.y} ${b.x} ${b.y}`;
}

// A wire with a dot at each end, into `layer` (an <svg>).
export function wire(layer, a, b, cls, options) {
  layer.append(svg("path", { d: curve(a, b, options), class: `wire ${cls}` }));
  layer.append(svg("circle", { cx: a.x, cy: a.y, r: 3, class: `wire-dot ${cls}` }));
  layer.append(svg("circle", { cx: b.x, cy: b.y, r: 3, class: `wire-dot ${cls}` }));
}

// An <svg> over `host`, for wires between things on the screen that live
// in different places (the focus pane and the board): its coordinates are
// `host`'s, taken from the screen when drawn, so a caller redraws it
// whenever what it joins moves (a glide redraws every frame).
export function overlay(host, className) {
  const layer = svg("svg", { class: `wire-overlay ${className}` });
  host.append(layer);
  return {
    layer,
    // the point of a screen position in the overlay's coordinates
    point(x, y) {
      const box = host.getBoundingClientRect();
      return { x: x - box.left, y: y - box.top };
    },
    clear: () => layer.replaceChildren(),
  };
}
