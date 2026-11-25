// The attention model (docs/ATTENTION.md): which definitions to show, and
// how much of each, so that what the author needs is on the screen when
// they need it. UI-agnostic and pure: no DOM, no network, no clock of its
// own -- the time is part of the state -- so a ranking can be replayed and
// explained, and the tests run in node.
//
// A definition's score is a weighted sum of a few named features, each a
// number in [0, 1] that says one thing about it ("the focus uses it",
// "the builder changed it a minute ago"). The weights are the defaults
// below until the author's own interactions have taught better ones
// (`learn`), and even then they stay within a band around the defaults.
// The score buys a level of detail -- a signature line, the folded row
// with its comment, or the whole code -- and a greedy pass fits the best
// of them into a budget of screen lines.
//
//   rank(state, budget, weights)      -> [{ id, detail, score, reasons, ... }]
//   explain(state, id, weights)       -> why one definition is (not) shown
//   createAttention({ write, ... })   -> a session: rank, observe, pin, showLess, why
//   learn(log, { prior })             -> weights tuned to this author, and a report

// ---- Features and their default weights ------------------------------------------
//
// The order is the order reasons are listed in when two contribute alike.
// `focus` is structural (the definition the author is in is always shown
// in full) and never learned; every other weight is.

export const FEATURES = [
  "focus", "uses", "usedBy", "sigType", "context", "failing", "question",
  "builderEdit", "authorEdit", "voice", "looked", "unfinished", "propertyOpen",
  "sameModule", "interface", "dismissed",
];

export const DEFAULT_WEIGHTS = Object.freeze({
  focus: 10, // you are here
  uses: 4.5, // what the focus calls: needed to read it
  usedBy: 3, // what calls the focus: what constrains it
  sigType: 2.5, // a type in the focus's signature: its one line says a lot
  context: 3, // in the open question, the voice focus, the working set
  failing: 4, // a failing property or a check error is about it
  question: 3, // an open question is about it
  builderEdit: 3, // changed by the builder, and not yet looked at
  authorEdit: 1.5, // the author's own recent edit
  voice: 2.5, // just mentioned, by voice or by the builder
  looked: 1, // the author has been reading it
  unfinished: 0.5, // planned or has holes: the work still to do
  propertyOpen: 0.5, // a property waits on it (it reaches a hole)
  sameModule: 0.8, // beside the focus
  interface: 0.6, // provided by its module: public, so more often wanted
  dismissed: -6, // the author said "show this less"
});

// Half-lives, in milliseconds, of the features that fade.
export const HALF_LIFE = Object.freeze({
  builderEdit: 10 * 60e3,
  authorEdit: 15 * 60e3,
  voice: 3 * 60e3,
  looked: 30 * 60e3,
  dismissed: 30 * 60e3,
});

// A definition dismissed less than this long ago is not shown at all
// (unless it is the focus or pinned, or has been edited since).
export const SUPPRESS_MS = 10 * 60e3;

// Graph distance: a definition d steps from the focus scores DECAY^(d-1);
// callees are followed this far out, callers this far up.
const DECAY = 0.5;
const CALLEE_DEPTH = 3;
const CALLER_DEPTH = 2;

// The score each level of detail needs (below FLOOR: not shown at all).
export const THRESHOLDS = Object.freeze({ full: 5, folded: 3, signature: 1.5 });

export const DEFAULT_BUDGET = Object.freeze({ lines: 60, items: 24, full: 4 });

const DETAILS = ["full", "folded", "signature"];
const TYPE_KINDS = new Set(["type", "alias", "grammar"]);

// ---- The program graph ---------------------------------------------------------
//
// From the board's outline (board.rs `outline`): modules, their
// definitions, and the bare names each definition uses. Names resolve
// in the definition's own module first, then the modules it requires,
// then anywhere; a constructor name resolves to its type, so a function
// that builds `(Ret v s k)` uses `State`.

export const idOf = (path, name) => `${path}::${name}`;

export function graph(outline) {
  const nodes = new Map();
  const byName = new Map();
  const modules = new Map();
  const add = (name, id) => {
    if (!byName.has(name)) byName.set(name, []);
    byName.get(name).push(id);
  };
  for (const m of outline ?? []) {
    modules.set(m.path, m);
    for (const item of m.items ?? []) {
      const id = idOf(m.path, item.name);
      nodes.set(id, {
        id, path: m.path, name: item.name, kind: item.kind, sig: item.sig ?? "", doc: item.doc ?? "",
        line: item.line, endLine: item.end_line ?? item.line, holes: item.holes ?? 0, opaque: !!item.opaque,
        provided: m.provides == null ? null : m.provides.includes(item.name),
        names: item.uses ?? [], uses: [], usedBy: [],
      });
      add(item.name, id);
      if (TYPE_KINDS.has(item.kind)) for (const c of constructors(item.sig)) add(c, id);
    }
  }
  const resolve = (name, path) => {
    const ids = byName.get(name);
    if (!ids) return null;
    const required = new Set((modules.get(path)?.requires ?? []).map((r) => joinPath(path, r)));
    return ids.find((id) => nodes.get(id).path === path) ?? ids.find((id) => required.has(nodes.get(id).path)) ?? ids[0];
  };
  for (const node of nodes.values()) {
    for (const name of node.names) {
      const used = resolve(name, node.path);
      if (used && used !== node.id && !node.uses.includes(used)) node.uses.push(used);
    }
  }
  for (const node of nodes.values()) for (const used of node.uses) nodes.get(used).usedBy.push(node.id);
  return { nodes, resolve, modules };
}

// `type Value = Num of Int | Clo of Var * Expr * Env` -> Num, Clo
function constructors(sig) {
  const body = sig.split("=").slice(1).join("=");
  return body ? body.split("|").map((c) => c.trim().split(/\s+/)[0]).filter((c) => /^[A-Z]/.test(c)) : [];
}

// "machine/step.puf" requiring "../lang.puf" -> "lang.puf"
function joinPath(from, relative) {
  const parts = from.split("/").slice(0, -1);
  for (const part of relative.split("/")) {
    if (part === "..") parts.pop();
    else if (part !== ".") parts.push(part);
  }
  return parts.join("/");
}

// The capitalized names in a signature: the types it mentions.
const typeNames = (sig) => (sig.split(":").slice(1).join(":").match(/[A-Z][\w?!*<>=/-]*/g) ?? []);

// Breadth-first from `start` along `edge`: id -> { d, via }, where `via` is
// the id one step nearer the start (null for its direct neighbors).
// Types are not walked through unless the start is one: that `step` and
// `inject` both mention `State` does not make them neighbors (the focus's
// own types come in by `sigType`).
function reach(g, start, edge, depth) {
  const seen = new Map([[start, { d: 0, via: null }]]);
  const walk = TYPE_KINDS.has(g.nodes.get(start)?.kind) ? () => true : (n) => !TYPE_KINDS.has(g.nodes.get(n).kind);
  let frontier = [start];
  for (let d = 1; d <= depth && frontier.length; d++) {
    const next = [];
    for (const id of frontier) {
      for (const n of g.nodes.get(id)?.[edge] ?? []) {
        if (seen.has(n) || !walk(n)) continue;
        seen.set(n, { d, via: d === 1 ? null : id });
        next.push(n);
      }
    }
    frontier = next;
  }
  seen.delete(start);
  return seen;
}

// ---- The state ---------------------------------------------------------------
//
// Everything is optional but `outline` and `now`. Ids are idOf(path, name);
// where a UI has only a bare name (a question's `about`, a name heard by
// voice) it may pass that instead, and it resolves like a use does.
//
//   now          ms since the epoch
//   outline      the board's outline
//   focus        the definition the author is in (cursor, selected row)
//   context      { ids, label }: a secondary set -- the open question's
//                slice, the voice focus, a working set the UI keeps
//   edits        [{ id, at, by: "author" | "builder" }]
//   properties   [{ name, status, mentions: [id] }] (status as props.rs)
//   errors       [id]: definitions with a check error in them
//   questions    [{ text, about: [id], answered }]
//   voice        [{ id, at, by }]: mentioned by voice or the builder
//   views        [{ id, at, ms }]: what the author looked at, how long
//   pins         [id]
//   dismissed    [{ id, at }]

function prepare(state) {
  const g = state.graph ?? graph(state.outline);
  const lookup = (ref) => (g.nodes.has(ref) ? ref : g.resolve(String(ref).split("::").pop(), state.focus?.split("::")[0]));
  const ids = (refs) => (refs ?? []).map(lookup).filter(Boolean);
  const focus = state.focus ? lookup(state.focus) : null;
  const latest = (events, by) => {
    const out = new Map();
    for (const e of events ?? []) {
      const id = lookup(e.id);
      if (id && (!by || e.by === by) && !(out.get(id) >= e.at)) out.set(id, e.at);
    }
    return out;
  };
  const failing = new Map();
  const open = new Map();
  // A property is a definition in the outline too (kind "property", its
  // uses what it mentions): a failing one is itself shown as failing, and
  // so is everything it mentions.
  for (const p of state.properties ?? []) {
    const into = p.status === "fail" || p.status === "crashed" ? failing : p.status === "open" ? open : null;
    if (!into) continue;
    const self = [...g.nodes.values()].find((n) => n.kind === "property" && n.name === p.name);
    if (self) into.set(self.id, { name: p.name, self: true });
    for (const id of p.mentions ? ids(p.mentions) : self?.uses ?? []) if (!into.has(id)) into.set(id, { name: p.name });
  }
  const questions = new Map();
  for (const q of state.questions ?? []) if (!q.answered) for (const id of ids(q.about)) if (!questions.has(id)) questions.set(id, q.text ?? "");
  const looked = new Map();
  for (const v of state.views ?? []) {
    const id = lookup(v.id);
    if (!id) continue;
    const amount = Math.min(v.ms ?? 0, 60e3) / 60e3 * fade(state.now - v.at, HALF_LIFE.looked);
    looked.set(id, (looked.get(id) ?? 0) + amount);
  }
  const lastLook = latest((state.views ?? []).filter((v) => (v.ms ?? 0) >= 2000));
  const contextIds = new Set(ids(state.context?.ids));
  const near = new Map(); // a context definition's direct neighbors
  for (const id of contextIds) for (const n of [...g.nodes.get(id).uses, ...g.nodes.get(id).usedBy]) if (!contextIds.has(n)) near.set(n, id);
  return {
    g, now: state.now, focus,
    down: focus ? reach(g, focus, "uses", CALLEE_DEPTH) : new Map(),
    up: focus ? reach(g, focus, "usedBy", CALLER_DEPTH) : new Map(),
    sigTypes: new Set(focus ? typeNames(g.nodes.get(focus).sig).map((n) => g.resolve(n, g.nodes.get(focus).path)).filter(Boolean) : []),
    context: contextIds, near, contextLabel: state.context?.label ?? "in context",
    builderEdits: latest(state.edits, "builder"), authorEdits: latest(state.edits, "author"),
    voice: latest(state.voice), looked, lastLook, failing, open,
    errors: new Set(ids(state.errors)), questions,
    pins: new Set(ids(state.pins)), dismissed: latest(state.dismissed),
  };
}

const fade = (age, halfLife) => (age < 0 ? 1 : 2 ** (-age / halfLife));

// The feature vector of one definition, and the facts its reasons quote.
function featuresOf(p, id) {
  const node = p.g.nodes.get(id);
  const f = Object.fromEntries(FEATURES.map((k) => [k, 0]));
  const why = {};
  if (id === p.focus) f.focus = 1;
  const down = p.down.get(id);
  if (down) [f.uses, why.uses] = [DECAY ** (down.d - 1), down];
  const up = p.up.get(id);
  if (up) [f.usedBy, why.usedBy] = [DECAY ** (up.d - 1), up];
  if (p.sigTypes.has(id)) f.sigType = 1;
  if (p.context.has(id)) f.context = 1;
  else if (p.near.has(id)) [f.context, why.context] = [0.5, p.near.get(id)];
  // a failing property itself, fully; what it mentions, a little less
  const fails = p.failing.get(id);
  if (fails) [f.failing, why.failing] = [fails.self ? 1 : 0.7, fails.self ? `property ${fails.name} fails` : `in failing property ${fails.name}`];
  else if (p.errors.has(id)) [f.failing, why.failing] = [1, "it has a check error"];
  if (p.questions.has(id)) [f.question, why.question] = [1, p.questions.get(id)];
  const built = p.builderEdits.get(id);
  if (built != null) {
    // once the author has looked at the change, it is no longer news
    const seen = (p.lastLook.get(id) ?? -Infinity) > built;
    [f.builderEdit, why.builderEdit] = [fade(p.now - built, HALF_LIFE.builderEdit) * (seen ? 0.3 : 1), { at: built, seen }];
  }
  const edited = p.authorEdits.get(id);
  if (edited != null) [f.authorEdit, why.authorEdit] = [fade(p.now - edited, HALF_LIFE.authorEdit), edited];
  const said = p.voice.get(id);
  if (said != null) [f.voice, why.voice] = [fade(p.now - said, HALF_LIFE.voice), said];
  if (p.looked.has(id)) f.looked = 1 - Math.exp(-3 * p.looked.get(id));
  if (node.opaque || node.holes > 0) f.unfinished = 1;
  if (p.open.has(id)) [f.propertyOpen, why.propertyOpen] = [1, p.open.get(id).name];
  if (p.focus && id !== p.focus && node.path === p.g.nodes.get(p.focus).path) f.sameModule = 1;
  if (node.kind !== "property") f.interface = node.provided == null ? 0.5 : node.provided ? 1 : 0;
  const dismissedAt = p.dismissed.get(id);
  if (dismissedAt != null) [f.dismissed, why.dismissed] = [fade(p.now - dismissedAt, HALF_LIFE.dismissed), dismissedAt];
  return { f, why };
}

export const dot = (f, w) => FEATURES.reduce((sum, k) => sum + (f[k] ?? 0) * (w[k] ?? 0), 0);

// ---- Reasons: why it is shown, in the studio's plain words ------------------------

const ago = (ms) => (ms < 60e3 ? "just now" : ms < 3600e3 ? `${Math.round(ms / 60e3)} min ago` : `${Math.round(ms / 3600e3)} h ago`);
const clip = (text, n) => (text.length > n ? `${text.slice(0, n - 1)}…` : text);

function phrase(k, p, node, why) {
  const name = (id) => p.g.nodes.get(id)?.name ?? id;
  const focus = p.focus ? name(p.focus) : "";
  switch (k) {
    case "focus": return "you are here";
    case "uses": return why.uses.via ? `${focus} uses it, through ${name(why.uses.via)}` : `${focus} uses it`;
    case "usedBy": return why.usedBy.via ? `it leads to ${focus}, through ${name(why.usedBy.via)}` : `it uses ${focus}`;
    case "sigType": return `in ${focus}'s signature`;
    case "context": return why.context ? `next to ${name(why.context)}, ${p.contextLabel}` : p.contextLabel;
    case "failing": return why.failing;
    case "question": return `asked about: ${clip(why.question, 48)}`;
    case "builderEdit": return `the builder changed it ${ago(p.now - why.builderEdit.at)}${why.builderEdit.seen ? "" : ", not yet seen"}`;
    case "authorEdit": return `you edited it ${ago(p.now - why.authorEdit)}`;
    case "voice": return `mentioned ${ago(p.now - why.voice)}`;
    case "looked": return "you have been reading it";
    case "unfinished": return node.opaque ? "planned, not written" : `${node.holes} hole${node.holes === 1 ? "" : "s"} left`;
    case "propertyOpen": return `property ${why.propertyOpen} waits on it`;
    case "sameModule": return `beside ${focus} in ${node.path}`;
    case "interface": return `part of ${node.path}'s interface`;
    case "dismissed": return `you dismissed it ${ago(p.now - why.dismissed)}`;
  }
  return k;
}

// The contributions worth saying, largest first: positive ones as reasons,
// negative ones too (a dismissal is a reason something sits low).
function reasonsOf(p, node, f, why, w) {
  return FEATURES
    .map((k) => ({ feature: k, weight: f[k] * w[k] }))
    .filter((c) => Math.abs(c.weight) >= 0.3)
    .sort((a, b) => Math.abs(b.weight) - Math.abs(a.weight))
    .map((c) => ({ ...c, weight: round(c.weight), text: phrase(c.feature, p, node, why) }));
}

const round = (x) => Math.round(x * 100) / 100;

// ---- Ranking under a budget ---------------------------------------------------

// Screen lines each level of detail costs.
export function cost(node, detail) {
  const doc = node.doc ? Math.min(node.doc.split("\n").length, 2) : 0;
  if (detail === "signature") return 1;
  if (detail === "folded") return 1 + doc;
  return node.endLine - node.line + 1 + doc;
}

// The most a definition's score buys. A type's one line (`type Kont = Done
// | Arg of ...`) is all of it worth showing unless it is the focus.
function wanted(node, score, isFocus) {
  if (isFocus) return "full";
  const by = score >= THRESHOLDS.full ? "full" : score >= THRESHOLDS.folded ? "folded" : score >= THRESHOLDS.signature ? "signature" : null;
  return by === "full" && TYPE_KINDS.has(node.kind) ? "folded" : by;
}

// Every definition scored, best first; `hidden` says why one cannot be
// shown however it scores (a recent dismissal).
export function scoreAll(state, weights = DEFAULT_WEIGHTS) {
  const p = prepare(state);
  const out = [];
  for (const node of p.g.nodes.values()) {
    const { f, why } = featuresOf(p, node.id);
    const score = round(dot(f, weights));
    const dismissedAt = p.dismissed.get(node.id);
    const editedSince = Math.max(p.builderEdits.get(node.id) ?? -Infinity, p.authorEdits.get(node.id) ?? -Infinity) > (dismissedAt ?? Infinity);
    const suppressed = dismissedAt != null && p.now - dismissedAt < SUPPRESS_MS && node.id !== p.focus && !p.pins.has(node.id) && !editedSince;
    out.push({
      id: node.id, name: node.name, path: node.path, kind: node.kind, score, features: f,
      pinned: p.pins.has(node.id), focus: node.id === p.focus, suppressed,
      reasons: reasonsOf(p, node, f, why, weights),
      node,
    });
  }
  // the focus, then pins, then by score; ties by place in the program, so the order is stable
  return out.sort((a, b) => b.focus - a.focus || b.pinned - a.pinned || b.score - a.score || a.path.localeCompare(b.path) || a.node.line - b.node.line);
}

// rank(state, budget) -> the definitions to show, best first:
//   { id, name, path, kind, detail, score, cost, reasons, pinned, focus }
// `budget`: { lines, items, full } -- screen lines in all, how many
// definitions at most, how many shown in full besides the focus.
// Greedy, in score order: each gets the detail its score buys, cheapened
// until it fits; the focus and pins come first and always get at least a
// signature line.
export function rank(state, budget = DEFAULT_BUDGET, weights = DEFAULT_WEIGHTS) {
  return allocate(scoreAll(state, weights), { ...DEFAULT_BUDGET, ...budget }).shown;
}

function allocate(scored, budget) {
  let lines = budget.lines;
  let full = 0;
  const shown = [];
  const rest = [];
  for (const s of scored) {
    const must = s.focus || s.pinned;
    let detail = s.suppressed ? null : wanted(s.node, s.score, s.focus) ?? (must ? "signature" : null);
    if (!detail || (!must && shown.length >= budget.items)) {
      rest.push(s);
      continue;
    }
    if (detail === "full" && !s.focus && full >= budget.full) detail = "folded";
    let i = DETAILS.indexOf(detail);
    while (i < DETAILS.length - 1 && cost(s.node, DETAILS[i]) > lines) i++;
    detail = DETAILS[i];
    const c = cost(s.node, detail);
    if (c > lines && !must) {
      rest.push(s);
      continue;
    }
    lines -= c;
    if (detail === "full" && !s.focus) full++;
    shown.push(present(s, detail, c));
  }
  return { shown, rest };
}

const present = (s, detail, c) => ({
  id: s.id, name: s.name, path: s.path, kind: s.kind, detail, score: s.score, cost: c,
  reasons: s.reasons.map((r) => r.text), pinned: s.pinned, focus: s.focus,
});

// Why one definition is or is not shown: its score, the detail it got (or
// null), every feature's contribution, and what it would need.
export function explain(state, id, budget = DEFAULT_BUDGET, weights = DEFAULT_WEIGHTS) {
  const scored = scoreAll(state, weights);
  const s = scored.find((x) => x.id === id || x.name === id);
  if (!s) return null;
  const { shown } = allocate(scored, { ...DEFAULT_BUDGET, ...budget });
  const placed = shown.find((x) => x.id === s.id);
  const position = scored.indexOf(s) + 1;
  const verdict = placed
    ? `shown ${placed.detail === "full" ? "in full" : placed.detail === "folded" ? "folded" : "as its signature"}`
    : s.suppressed ? "hidden: you dismissed it"
    : s.score < THRESHOLDS.signature ? `not shown: it scores ${s.score}, under ${THRESHOLDS.signature}`
    : `not shown: no room (it ranks ${position} of ${scored.length})`;
  return { id: s.id, score: s.score, detail: placed?.detail ?? null, verdict, reasons: s.reasons, features: s.features };
}

// ---- A session: the model with a memory, and a log ------------------------------
//
// What a UI holds. It remembers what the author pinned, dismissed and
// looked at (merged into every state it ranks), logs every ranking that
// changed what is on the screen (an *impression*) and every interaction
// with it (`observe`), each stamped with the feature vectors involved so
// that the log alone is enough to learn from -- the program it was about
// may long since have changed.
//
// `write(records)` receives the log records to keep (see httpLog below);
// `now()` the clock.

export const LOG_VERSION = 1;

// Interactions, and how strongly each says "I wanted this".
export const SIGNALS = Object.freeze({ pull: 1, edit: 1, open: 0.7, focus: 0.5, dwell: 0.3 });
const DWELL_MS = 4000;
const POOL = 8; // unshown candidates logged with each impression

export function createAttention({ write = () => {}, now = Date.now, weights = DEFAULT_WEIGHTS, session } = {}) {
  let w = { ...weights };
  const tag = session ?? Math.random().toString(36).slice(2, 8);
  const memory = { pins: [], dismissed: [], views: [] };
  let impressions = 0;
  let last = null; // { imp, state, signature }

  const merged = (state) => ({
    ...state,
    now: state.now ?? now(),
    pins: [...(state.pins ?? []), ...memory.pins],
    dismissed: [...(state.dismissed ?? []), ...memory.dismissed],
    views: [...(state.views ?? []), ...memory.views],
  });

  function rankAndLog(state, budget = DEFAULT_BUDGET) {
    const full = merged(state);
    const scored = scoreAll(full, w);
    const { shown, rest } = allocate(scored, { ...DEFAULT_BUDGET, ...budget });
    const signature = shown.map((s) => `${s.id}:${s.detail}`).join("|");
    if (signature !== last?.signature) {
      const imp = `${tag}:${++impressions}`;
      const byId = new Map(scored.map((s) => [s.id, s]));
      write([{
        t: "shown", v: LOG_VERSION, at: full.now, imp, focus: full.focus ?? null,
        items: shown.map((s, i) => ({ id: s.id, detail: s.detail, rank: i + 1, pinned: s.pinned || undefined, focus: s.focus || undefined, f: compact(byId.get(s.id).features) })),
        pool: rest.filter((s) => !s.suppressed).slice(0, POOL).map((s) => ({ id: s.id, f: compact(s.features) })),
      }]);
      last = { imp, signature };
    }
    last.state = full;
    return shown;
  }

  // observe({ type, id, ms?, detail? }): an interaction. `type` is one of
  // SIGNALS' (pull: brought in something not shown; open: asked for more
  // of it; edit; focus: moved into it; dwell: it held the author `ms`) or
  // dismiss, pin, unpin.
  function observe(event) {
    const at = event.at ?? now();
    const id = event.id;
    if (event.type === "pin") memory.pins.push(id);
    if (event.type === "unpin") memory.pins = memory.pins.filter((p) => p !== id);
    if (event.type === "dismiss") memory.dismissed.push({ id, at });
    if (event.type === "dwell" || event.type === "focus") memory.views.push({ id, at, ms: event.ms ?? 0 });
    const f = last?.state ? features(last.state, id) : null;
    write([{ t: event.type, v: LOG_VERSION, at, imp: last?.imp ?? null, id, ms: event.ms, detail: event.detail, f: f && compact(f) }]);
  }

  return {
    rank: rankAndLog,
    observe,
    pin: (id) => observe({ type: "pin", id }),
    unpin: (id) => observe({ type: "unpin", id }),
    // "show this less": hidden for a while, lower for longer, and a lesson
    showLess: (id) => observe({ type: "dismiss", id }),
    why: (id, budget) => (last?.state ? explain(last.state, id, budget, w) : null),
    weights: () => ({ ...w }),
    setWeights: (next) => { w = { ...DEFAULT_WEIGHTS, ...next }; last = last && { ...last, signature: null }; },
    // tune the weights to this project's log (see learn); returns the report
    learnFrom(log, options) {
      const result = learn(log, options);
      this.setWeights(result.weights);
      return result;
    },
  };
}

// One definition's features under `state`.
export function features(state, id) {
  const p = prepare(state);
  const resolved = p.g.nodes.has(id) ? id : p.g.resolve(String(id).split("::").pop(), p.focus?.split("::")[0]);
  return resolved ? featuresOf(p, resolved).f : null;
}

// Zeros left out: the log stays small.
const compact = (f) => Object.fromEntries(Object.entries(f).filter(([, x]) => x !== 0).map(([k, x]) => [k, round(x)]));

// The studio's log route (web.rs, attention.rs): records are appended to
// the project's `.puffin/attention-log.jsonl`, which never leaves the
// machine and is never committed. Batched; flushed on page hide with
// sendBeacon, which survives the tab closing.
export function httpLog(url = "/attention/log", { delay = 2000 } = {}) {
  let queue = [];
  let timer = null;
  const flush = (beacon = false) => {
    clearTimeout(timer);
    timer = null;
    if (!queue.length) return;
    const body = queue.map((r) => JSON.stringify(r)).join("\n");
    queue = [];
    if (beacon && navigator.sendBeacon?.(url, body)) return;
    fetch(url, { method: "POST", body, keepalive: true }).catch(() => {});
  };
  if (typeof document !== "undefined") document.addEventListener("visibilitychange", () => document.visibilityState === "hidden" && flush(true));
  return {
    write(records) {
      queue.push(...records);
      timer ??= setTimeout(flush, delay);
    },
    flush,
    async read() {
      const text = await fetch(url).then((r) => (r.ok ? r.text() : ""));
      return parseLog(text);
    },
  };
}

export const parseLog = (text) => text.split("\n").filter((l) => l.trim()).flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });

// ---- Learning from the log ----------------------------------------------------
//
// Not RLHF (docs/ATTENTION.md §4): there is no reward model to fit and no
// policy gradient; the author's interactions are *implicit pairwise
// preferences* over a ranking they were shown, the classic setting of
// learning to rank from clicks. Each impression yields pairs (a ≻ b):
//
// - engaged with x (pulled, opened, edited, moved into, dwelt on) while
//   y sat above it unengaged: x ≻ y ("skip above");
// - engaged with x while y sat below it unengaged: x ≻ y, at half
//   strength -- the confirmation that keeps a good default from drifting
//   away just because skip-above pairs only ever argue against the order;
// - pulled in x that was not shown: x ≻ each unengaged shown item (the
//   space it should have had);
// - dismissed y: each of the best unshown candidates, and each unengaged
//   item below y, ≻ y.
//
// An event's pairs share its strength (SIGNALS), so one pull among twenty
// items weighs what a pull among two does. The weights then take a few
// passes of a pairwise logistic (Bradley-Terry) update, pulled back
// toward the defaults each step (an L2 prior), and are clamped to a band
// around them (a third to three times each default; the sign never
// flips). And they are kept only if they order a held-out, most recent
// fifth of the pairs at least as well as the defaults do.

export const LEARNED = FEATURES.filter((k) => k !== "focus");

export const LEARNING = Object.freeze({ rate: 0.05, epochs: 30, prior: 0.02, band: 3, minPairs: 20, holdout: 0.2 });

export function preferences(log) {
  const impressions = new Map();
  const events = [];
  for (const r of log) {
    if (r.t === "shown") impressions.set(r.imp, { ...r, engaged: new Map(), dismissed: [] });
    else if (r.imp && impressions.has(r.imp)) events.push(r);
  }
  for (const e of events) {
    const imp = impressions.get(e.imp);
    const strength = e.t === "dwell" ? ((e.ms ?? 0) >= DWELL_MS ? SIGNALS.dwell : 0) : SIGNALS[e.t] ?? 0;
    if (strength > (imp.engaged.get(e.id)?.strength ?? 0) && e.f) imp.engaged.set(e.id, { strength, f: e.f });
    if (e.t === "dismiss" && e.f) imp.dismissed.push(e);
  }
  const pairs = [];
  const push = (a, b, weight, at) => pairs.push({ a, b, weight, at });
  for (const imp of impressions.values()) {
    const structural = (s) => s.pinned || s.focus;
    const idle = imp.items.filter((s) => !structural(s) && !imp.engaged.has(s.id) && !imp.dismissed.some((d) => d.id === s.id));
    for (const [id, { strength, f }] of imp.engaged) {
      const placed = imp.items.find((s) => s.id === id);
      if (placed && structural(placed)) continue;
      const above = placed ? idle.filter((s) => s.rank < placed.rank) : idle;
      const below = placed ? idle.filter((s) => s.rank > placed.rank) : [];
      const total = above.length + below.length / 2;
      for (const s of above) push(f, s.f, strength / total, imp.at);
      for (const s of below) push(f, s.f, strength / 2 / total, imp.at);
    }
    for (const d of imp.dismissed) {
      const rank = imp.items.find((s) => s.id === d.id)?.rank ?? Infinity;
      const better = [...(imp.pool ?? []).slice(0, 3), ...idle.filter((s) => s.rank > rank)];
      for (const s of better) push(s.f, d.f, 1 / better.length, imp.at);
    }
  }
  return pairs;
}

const sigmoid = (x) => 1 / (1 + Math.exp(-x));

function bounds(prior, band) {
  const lo = {};
  const hi = {};
  for (const k of LEARNED) {
    const p = prior[k];
    [lo[k], hi[k]] = p > 0 ? [p / band, p * band] : p < 0 ? [p * band, p / band] : [-1, 1];
  }
  return { lo, hi };
}

function train(pairs, prior, o) {
  const w = { ...prior };
  const { lo, hi } = bounds(prior, o.band);
  for (let epoch = 0; epoch < o.epochs; epoch++) {
    for (const { a, b, weight } of pairs) {
      const d = LEARNED.map((k) => (a[k] ?? 0) - (b[k] ?? 0));
      const margin = LEARNED.reduce((sum, k, i) => sum + w[k] * d[i], 0);
      const push = o.rate * weight * sigmoid(-margin);
      LEARNED.forEach((k, i) => {
        w[k] += push * d[i] - o.rate * o.prior * (w[k] - prior[k]);
        w[k] = Math.min(hi[k], Math.max(lo[k], w[k]));
      });
    }
  }
  return w;
}

// The weighted share of pairs a weight vector orders right.
export function agreement(pairs, w) {
  let right = 0;
  let all = 0;
  for (const { a, b, weight } of pairs) {
    const margin = dot(a, w) - dot(b, w);
    right += weight * (margin > 0 ? 1 : margin === 0 ? 0.5 : 0);
    all += weight;
  }
  return all ? right / all : 0;
}

// learn(log, { prior, ...LEARNING }) -> { weights, used, pairs, why,
// agreement: { prior, learned } } -- `used` false (and the prior returned)
// when there is too little to go on or the held-out pairs say no.
export function learn(log, options = {}) {
  const o = { ...LEARNING, ...options };
  const prior = { ...DEFAULT_WEIGHTS, ...(options.prior ?? {}) };
  const pairs = preferences(log).sort((x, y) => x.at - y.at);
  const keep = (why, extra = {}) => ({ weights: prior, used: false, pairs: pairs.length, why, ...extra });
  if (pairs.length < o.minPairs) return keep(`only ${pairs.length} preferences: the defaults stand`);
  const cut = Math.floor(pairs.length * (1 - o.holdout));
  const trial = train(pairs.slice(0, cut), prior, o);
  const held = pairs.slice(cut);
  const score = { prior: round(agreement(held, prior)), learned: round(agreement(held, trial)) };
  if (score.learned < score.prior) return keep("the tuned weights did worse on recent behavior", { agreement: score });
  const weights = train(pairs, prior, o);
  for (const k of LEARNED) weights[k] = round(weights[k]);
  return { weights, used: true, pairs: pairs.length, agreement: score, why: `tuned on ${pairs.length} preferences` };
}
