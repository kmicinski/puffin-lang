// The board's camera (docs/VIEW.md): where the board is looked at from,
// and how far out. The layer is moved, never scrolled -- one
// transform, `translate(x, y) scale(z)` -- so a glide is a CSS transition
// and anything on the layer (cards, live editors, wires) moves as one.
//
//   two-finger scroll or the wheel pans; ⌘/ctrl + wheel (a trackpad's
//   pinch) zooms about the pointer; dragging the empty board pans; on a
//   touch screen, two fingers pinch
//   frame(boxes)   glide so the boxes (canvas coordinates) fill the view,
//                  no closer than `max` and no further than `min`
//   fitting(boxes) the zoom at which they would just fit
//   toCanvas(x, y) a point on screen, in canvas coordinates
//
// `onChange(z, moved)` is called after every change; `moved` is false while
// a glide is still under way, then true once it lands. `onFrame()` is
// called after every move and on every frame of a glide, for what is
// drawn over the board from outside it (wires into the focus pane), which
// must follow the board as it moves on the screen.

const GLIDE_MS = 420;

export function createCamera({ viewport, layer, onChange, onFrame, min = 0.2, max = 1.6 }) {
  let x = 0;
  let y = 0;
  let z = 1;
  let gliding = 0;
  let until = 0;

  // every frame until the glide lands
  function frames() {
    onFrame?.();
    if (performance.now() < until) requestAnimationFrame(frames);
  }

  function apply(animate) {
    clearTimeout(gliding);
    layer.classList.toggle("gliding", Boolean(animate));
    layer.style.transform = `translate(${x}px, ${y}px) scale(${z})`;
    onChange?.(z, !animate);
    if (animate) {
      const running = performance.now() < until;
      until = performance.now() + GLIDE_MS + 40;
      if (!running) requestAnimationFrame(frames);
      gliding = setTimeout(() => {
        layer.classList.remove("gliding");
        onChange?.(z, true);
      }, GLIDE_MS);
    } else onFrame?.();
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

  // the zoom at which the boxes would just fit
  function fitting(boxes, { pad = 36, top: above = 0 } = {}) {
    const w = Math.max(...boxes.map((b) => b.x + b.w)) - Math.min(...boxes.map((b) => b.x));
    const h = Math.max(...boxes.map((b) => b.y + b.h)) - Math.min(...boxes.map((b) => b.y));
    return Math.min((viewport.clientWidth - pad * 2) / w, (viewport.clientHeight - pad * 2 - above) / h);
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
      if (pinch || (!moved && Math.hypot(e.clientX - start.px, e.clientY - start.py) < 3)) return;
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

  // Two fingers on a touch screen: a pinch zooms about their middle, and
  // the middle carries the board with it (the trackpad's pinch arrives as
  // a ctrl-wheel, above).
  const touches = new Map();
  let pinch = null;
  const fingers = () => {
    const [a, b] = [...touches.values()];
    return { d: Math.hypot(a.x - b.x, a.y - b.y) || 1, mx: (a.x + b.x) / 2, my: (a.y + b.y) / 2 };
  };
  viewport.addEventListener("pointerdown", (event) => {
    if (event.pointerType !== "touch") return;
    touches.set(event.pointerId, { x: event.clientX, y: event.clientY });
    if (touches.size === 2) pinch = { ...fingers(), x, y, z };
  }, { capture: true });
  viewport.addEventListener("pointermove", (event) => {
    if (!touches.has(event.pointerId)) return;
    touches.set(event.pointerId, { x: event.clientX, y: event.clientY });
    if (!pinch || touches.size !== 2) return;
    event.preventDefault();
    event.stopPropagation();
    const now = fingers();
    const box = viewport.getBoundingClientRect();
    const to = clamp((pinch.z * now.d) / pinch.d);
    // the board's point that was under the fingers' middle stays under it
    const cx = (pinch.mx - box.left - pinch.x) / pinch.z;
    const cy = (pinch.my - box.top - pinch.y) / pinch.z;
    x = now.mx - box.left - cx * to;
    y = now.my - box.top - cy * to;
    z = to;
    apply(false);
  }, { capture: true });
  const lift = (event) => {
    touches.delete(event.pointerId);
    if (touches.size < 2) pinch = null;
  };
  viewport.addEventListener("pointerup", lift, { capture: true });
  viewport.addEventListener("pointercancel", lift, { capture: true });

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
    fitting,
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
