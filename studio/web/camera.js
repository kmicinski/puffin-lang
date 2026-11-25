// The canvas camera (docs/VIEW-CANVAS.md): where the canvas is looked at
// from, and how far out. The layer is moved, never scrolled -- one
// transform, `translate(x, y) scale(z)` -- so a glide is a CSS transition
// and anything on the layer (cards, live editors, wires) moves as one.
//
//   two-finger scroll or the wheel pans; ⌘/ctrl + wheel (a pinch) zooms
//   about the pointer; dragging the empty canvas pans
//   frame(boxes)   glide so the boxes (canvas coordinates) fill the view,
//                  no closer than `max` and no further than `min`
//   toCanvas(x, y) a point on screen, in canvas coordinates
//
// `onChange(z, moved)` is called after every change; `moved` is false while
// a glide is still under way, then true once it lands.

const GLIDE_MS = 420;

export function createCamera({ viewport, layer, onChange, min = 0.2, max = 1.6 }) {
  let x = 0;
  let y = 0;
  let z = 1;
  let gliding = 0;

  function apply(animate) {
    clearTimeout(gliding);
    layer.classList.toggle("gliding", Boolean(animate));
    layer.style.transform = `translate(${x}px, ${y}px) scale(${z})`;
    onChange?.(z, !animate);
    if (animate) {
      gliding = setTimeout(() => {
        layer.classList.remove("gliding");
        onChange?.(z, true);
      }, GLIDE_MS);
    }
  }

  const clamp = (value) => Math.min(max, Math.max(min, value));

  // zoom to `next` keeping the canvas point under (sx, sy) where it is
  function zoomAbout(next, sx, sy, animate = false) {
    const box = viewport.getBoundingClientRect();
    const px = sx - box.left;
    const py = sy - box.top;
    const to = clamp(next);
    x = px - ((px - x) * to) / z;
    y = py - ((py - y) * to) / z;
    z = to;
    apply(animate);
  }

  // (`top`: room kept clear above, for what floats over the view)
  function frame(boxes, { min: least = 0.7, max: most = 1, pad = 36, top: above = 0, animate = true, align = "center" } = {}) {
    const list = boxes.filter(Boolean);
    if (!list.length) return;
    const left = Math.min(...list.map((b) => b.x));
    const top = Math.min(...list.map((b) => b.y));
    const right = Math.max(...list.map((b) => b.x + b.w));
    const bottom = Math.max(...list.map((b) => b.y + b.h));
    const w = viewport.clientWidth - pad * 2;
    const h = viewport.clientHeight - pad * 2 - above;
    z = clamp(Math.max(least, Math.min(most, w / (right - left), h / (bottom - top))));
    // what does not fit at the closest allowed zoom: keep its top left in view
    const fitsX = (right - left) * z <= w;
    const fitsY = (bottom - top) * z <= h;
    x = pad + (fitsX && align === "center" ? (w - (right - left) * z) / 2 : 0) - left * z;
    y = pad + above + (fitsY && align === "center" ? Math.min((h - (bottom - top) * z) / 2, h * 0.12) : 0) - top * z;
    apply(animate);
  }

  // a box in canvas coordinates, entirely on screen if it can be: the
  // least movement that shows it (the zoom unchanged)
  function reveal(box, { pad = 36, animate = true } = {}) {
    const w = viewport.clientWidth;
    const h = viewport.clientHeight;
    const sx = box.x * z + x;
    const sy = box.y * z + y;
    let dx = 0;
    let dy = 0;
    if (sx < pad) dx = pad - sx;
    else if (sx + box.w * z > w - pad) dx = Math.max(pad - sx, w - pad - (sx + box.w * z));
    if (sy < pad) dy = pad - sy;
    else if (sy + box.h * z > h - pad) dy = Math.max(pad - sy, h - pad - (sy + box.h * z));
    if (!dx && !dy) return;
    x += dx;
    y += dy;
    apply(animate);
  }

  viewport.addEventListener("wheel", (event) => {
    // an editor that can still scroll keeps the wheel (Monaco stops it)
    event.preventDefault();
    if (event.ctrlKey || event.metaKey) {
      zoomAbout(z * Math.exp(-event.deltaY * 0.0025), event.clientX, event.clientY);
    } else {
      x -= event.deltaX;
      y -= event.deltaY;
      apply(false);
    }
  }, { passive: false });

  // dragging the canvas itself (not a card, not an editor) pans
  viewport.addEventListener("pointerdown", (event) => {
    if (event.button !== 0 || event.target !== viewport && !event.target.classList?.contains("canvas-pan")) return;
    const start = { px: event.clientX, py: event.clientY, x, y };
    let moved = false;
    const move = (e) => {
      if (!moved && Math.hypot(e.clientX - start.px, e.clientY - start.py) < 3) return;
      moved = true;
      viewport.classList.add("panning");
      x = start.x + e.clientX - start.px;
      y = start.y + e.clientY - start.py;
      apply(false);
    };
    const up = () => {
      viewport.classList.remove("panning");
      removeEventListener("pointermove", move);
      removeEventListener("pointerup", up);
    };
    addEventListener("pointermove", move);
    addEventListener("pointerup", up);
  });

  return {
    zoom: () => z,
    view: () => ({ x, y, z }),
    set(view, animate = true) {
      ({ x, y } = view);
      z = clamp(view.z);
      apply(animate);
    },
    zoomBy(factor, animate = true) {
      const box = viewport.getBoundingClientRect();
      zoomAbout(z * factor, box.left + box.width / 2, box.top + box.height / 2, animate);
    },
    zoomAbout,
    frame,
    reveal,
    toCanvas(sx, sy) {
      const box = viewport.getBoundingClientRect();
      return { x: (sx - box.left - x) / z, y: (sy - box.top - y) / z };
    },
    // the box of an element on the layer, in canvas coordinates
    boxOf(node) {
      const box = viewport.getBoundingClientRect();
      const r = node.getBoundingClientRect();
      return { x: (r.left - box.left - x) / z, y: (r.top - box.top - y) / z, w: r.width / z, h: r.height / z };
    },
  };
}
