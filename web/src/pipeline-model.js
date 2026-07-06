// Pure helpers for the compiler-pipeline visualizer.
// No DOM / SolidJS imports so these can be unit-tested under plain node
// (see web/test-pipeline.mjs).

// ---------- layer construction ----------

// Normalize one pass of a trace into a "layer":
//   { name, text, byId: Map<id,{id,start,end,parent}>,
//     children: Map<id,[node...]>, roots: [node...], back: Map<id,prevId> }
// The final render-asm pass has no nodes; we synthesize one node per LINE
// (id = line index) and use lineBack as its back map.
export function buildLayer(pass) {
  let rawNodes = pass.nodes || [];
  let rawBack = pass.back || {};
  if (rawNodes.length === 0 && pass.lineBack) {
    rawNodes = [];
    let off = 0;
    const lines = pass.text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      rawNodes.push([i, off, off + lines[i].length, -1]);
      off += lines[i].length + 1;
    }
    rawBack = pass.lineBack;
  }
  const byId = new Map();
  for (const [id, start, end, parent] of rawNodes) byId.set(id, { id, start, end, parent });
  const children = new Map();
  const roots = [];
  for (const n of byId.values()) {
    if (n.parent !== -1 && byId.has(n.parent)) {
      let arr = children.get(n.parent);
      if (!arr) children.set(n.parent, (arr = []));
      arr.push(n);
    } else {
      roots.push(n);
    }
  }
  // wider spans first when starts coincide, so outer siblings sort before inner
  const cmp = (a, b) => a.start - b.start || b.end - a.end || a.id - b.id;
  roots.sort(cmp);
  for (const arr of children.values()) arr.sort(cmp);
  const back = new Map();
  for (const [k, v] of Object.entries(rawBack)) back.set(Number(k), v);
  return { name: pass.name, text: pass.text, byId, children, roots, back };
}

// ---------- HTML rendering ----------

const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;' };
function esc(s) {
  return s.replace(/[&<>]/g, (c) => ESC[c]);
}

// Render a layer's text as one HTML string of nested <span data-id> elements.
// Built once per layer and cached by the caller; throws if spans overlap
// (they never should — the sanity script proves it for the sample trace).
export function renderLayerHTML(layer) {
  const { text, children, roots, name } = layer;
  const out = [];
  const emit = (n) => {
    out.push(`<span data-id="${n.id}">`);
    let pos = n.start;
    const kids = children.get(n.id);
    if (kids) {
      for (const c of kids) {
        if (c.start < pos || c.end > n.end) {
          throw new Error(
            `overlapping spans in layer ${name}: node ${c.id} [${c.start},${c.end}) inside parent ${n.id} [${n.start},${n.end}) at pos ${pos}`
          );
        }
        if (c.start > pos) out.push(esc(text.slice(pos, c.start)));
        emit(c);
        pos = c.end;
      }
    }
    if (pos < n.end) out.push(esc(text.slice(pos, n.end)));
    out.push('</span>');
  };
  let pos = 0;
  for (const r of roots) {
    if (r.start < pos) {
      throw new Error(`overlapping root spans in layer ${name}: node ${r.id} [${r.start},${r.end}) at pos ${pos}`);
    }
    if (r.start > pos) out.push(esc(text.slice(pos, r.start)));
    emit(r);
    pos = r.end;
  }
  if (pos < text.length) out.push(esc(text.slice(pos)));
  return out.join('');
}

// ---------- provenance ----------

// Node -> previous-layer node id, walking up parents until a back entry is
// found (structural nodes inherit their ancestor's origin). null if none.
export function resolveBack(layer, id) {
  let n = layer.byId.get(id);
  while (n) {
    if (layer.back.has(n.id)) return layer.back.get(n.id);
    n = n.parent === -1 ? null : layer.byId.get(n.parent);
  }
  return null;
}

// Reverse index for a layer: previous-layer node id -> [ids in this layer
// whose OWN back entry targets it]. Computed once per layer and memoized by
// the caller. (Nodes without their own entry inherit an ancestor's, and that
// ancestor's span visually covers them, so own entries suffice.)
export function reverseIndex(layer) {
  const idx = new Map();
  for (const [id, target] of layer.back) {
    let arr = idx.get(target);
    if (!arr) idx.set(target, (arr = []));
    arr.push(id);
  }
  return idx;
}

// "What did this become?" — all right-layer node ids whose back edge lands on
// leftId or any of its descendants in the left layer.
export function collectReverseHits(leftLayer, leftId, revIdx) {
  const hits = [];
  const stack = [leftId];
  while (stack.length) {
    const cur = stack.pop();
    const r = revIdx.get(cur);
    if (r) hits.push(...r);
    const kids = leftLayer.children.get(cur);
    if (kids) for (const k of kids) stack.push(k.id);
  }
  return hits;
}

// Full provenance chain of a node back to the source layer, applying the
// ancestor-walk rule at each step. Returns [{layer, id}, ...] source-first.
export function breadcrumbChain(layers, startIdx, id) {
  const chain = [{ layer: startIdx, id }];
  let cur = id;
  for (let j = startIdx; j > 0; j--) {
    const prev = resolveBack(layers[j], cur);
    if (prev === null || prev === undefined || !layers[j - 1].byId.has(prev)) break;
    chain.push({ layer: j - 1, id: prev });
    cur = prev;
  }
  return chain.reverse();
}

// Short one-line preview of a node's text span, for breadcrumb chips.
export function snippet(layer, id, max = 60) {
  const n = layer.byId.get(id);
  if (!n) return '';
  const s = layer.text.slice(n.start, n.end).replace(/\s+/g, ' ').trim();
  return s.length > max ? s.slice(0, max) + '…' : s;
}
