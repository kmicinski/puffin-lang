// The lane's order (docs/VIEW.md §1): a call tree, read top to bottom.
//
// What the lane holds is the attention model's choice (view.js); where
// each piece sits is the program's. The definitions the focus uses come
// first, in the order its text uses them, each followed by what it
// alone brings in (indented under it); then whatever the focus does not
// reach -- a caller pulled in, a type offered -- each the root of its
// own small tree, the ones nothing else here uses first. So the lane
// reads like the code beside it, every wire from a line runs down to
// something below it, and an arrival goes in where it is needed without
// moving the rest.
//
//   laneTree(root, ids, usesOf)
//     root    the focus's id (null: nothing focused)
//     ids     what the lane holds, in the model's order (its tie-break)
//     usesOf  id -> the ids it uses, in the order its text uses them
//   -> [{ id, parent, depth }] in reading order; `parent` is the id
//      (or `root`) whose line the piece is wired from, null for a tree's
//      own root
//
// Each piece hangs under the nearest thing that uses it (breadth first,
// so one the focus uses directly is never buried under a fragment that
// also uses it), and appears once whatever the cycles.

export function laneTree(root, ids, usesOf) {
  const want = new Set(ids);
  const placed = new Map(); // id -> { parent, depth }
  const children = new Map(); // id -> ids hung under it, in text order

  // hang under `from` (at `depth`) what it reaches that is not hung yet
  function claim(from, depth) {
    const queue = [[from, depth]];
    while (queue.length) {
      const [at, d] = queue.shift();
      for (const used of usesOf(at)) {
        if (!want.has(used) || placed.has(used) || used === root) continue;
        placed.set(used, { parent: at, depth: d });
        if (!children.has(at)) children.set(at, []);
        children.get(at).push(used);
        queue.push([used, d + 1]);
      }
    }
  }

  const out = [];
  const walk = (id) => {
    for (const child of children.get(id) ?? []) {
      out.push({ id: child, ...placed.get(child) });
      walk(child);
    }
  };

  if (root != null) {
    claim(root, 0);
    walk(root);
  }
  // the rest: roots of their own trees -- first those that nothing left
  // over uses (a caller before what it calls), then any in a cycle
  const left = ids.filter((id) => !placed.has(id) && id !== root);
  const usedByLeft = (id) => left.some((other) => other !== id && usesOf(other).includes(id));
  for (const id of [...left.filter((id) => !usedByLeft(id)), ...left]) {
    if (placed.has(id)) continue;
    placed.set(id, { parent: null, depth: 0 });
    out.push({ id, parent: null, depth: 0 });
    claim(id, 1);
    walk(id);
  }
  return out;
}
