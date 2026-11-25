// A simulated author for the attention learner's tests (and for trying
// out changes to it): random programs, random moments in a session, and
// an author who wants what a hidden weight vector says they want.
//
//   node studio/web/test/simulate.mjs   prints a run for each author

import { DEFAULT_WEIGHTS, LEARNED, createAttention, learn, scoreAll, idOf } from "../attention.js";

// mulberry32: a small seeded generator, so every run is the same run
export function random(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const pick = (rand, xs) => xs[Math.floor(rand() * xs.length)];

// Four modules of eight functions and two types; each function uses one
// to three others, mostly in its own module, and mentions a type or two.
export function program(rand, modules = 4, funs = 8) {
  const outline = [];
  for (let m = 0; m < modules; m++) {
    const path = `m${m}.puf`;
    const types = [`T${m}a`, `T${m}b`];
    const items = types.map((name, i) => ({ name, kind: "type", line: 1 + i * 3, end_line: 2 + i * 3, sig: `type ${name} = ${name}C of Int`, holes: 0, opaque: false, uses: [] }));
    for (let i = 0; i < funs; i++) {
      const name = `f${m}_${i}`;
      const line = 10 + i * 8;
      const length = 2 + Math.floor(rand() * 10);
      const t = pick(rand, types);
      items.push({ name, kind: "fun", line, end_line: line + length, sig: `val ${name} : ${t} -> ${pick(rand, types)}`, holes: rand() < 0.15 ? 1 : 0, opaque: false, uses: [t], doc: rand() < 0.5 ? "what it does" : "" });
    }
    outline.push({ path, requires: m ? [`m${m - 1}.puf`] : [], provides: items.filter(() => rand() < 0.5).map((i) => i.name), items });
  }
  const all = outline.flatMap((m) => m.items.filter((i) => i.kind === "fun").map((i) => ({ m, i })));
  for (const { m, i } of all) {
    const count = 1 + Math.floor(rand() * 3);
    for (let k = 0; k < count; k++) {
      const local = rand() < 0.7;
      const other = local ? pick(rand, m.items.filter((x) => x.kind === "fun" && x !== i)) : pick(rand, all).i;
      if (other !== i && !i.uses.includes(other.name)) i.uses.push(other.name);
    }
  }
  return outline;
}

// A moment: a focus, a few recent edits by each, a check error or two,
// something just said, something looked at.
export function moment(rand, outline, now) {
  const ids = outline.flatMap((m) => m.items.filter((i) => i.kind === "fun").map((i) => idOf(m.path, i.name)));
  const some = (n, make) => Array.from({ length: Math.floor(rand() * (n + 1)) }, make);
  return {
    now,
    outline,
    focus: pick(rand, ids),
    edits: [
      ...some(3, () => ({ id: pick(rand, ids), at: now - rand() * 20 * 60e3, by: "builder" })),
      ...some(3, () => ({ id: pick(rand, ids), at: now - rand() * 30 * 60e3, by: "author" })),
    ],
    errors: rand() < 0.3 ? [pick(rand, ids)] : [],
    voice: some(1, () => ({ id: pick(rand, ids), at: now - rand() * 5 * 60e3 })),
    views: some(3, () => ({ id: pick(rand, ids), at: now - rand() * 60 * 60e3, ms: rand() * 60e3 })),
  };
}

// An author's hidden wants: the default weights with some changed.
export const AUTHORS = {
  // reads callers to understand a function, cares little for its own edits
  callers: { ...DEFAULT_WEIGHTS, usedBy: 8, uses: 2, authorEdit: 0.3 },
  // follows the builder: what it just changed, first
  follower: { ...DEFAULT_WEIGHTS, builderEdit: 8, uses: 2.5, usedBy: 1.5 },
  // wants what the defaults want
  defaults: { ...DEFAULT_WEIGHTS },
};

// What the author wants of a ranked list: the precision of the model's
// top k against the author's own top k, the focus aside.
export function precision(state, weights, hidden, k = 5) {
  const top = (w) => scoreAll(state, w).filter((s) => !s.focus).slice(0, k).map((s) => s.id);
  const want = new Set(top(hidden));
  return top(weights).filter((id) => want.has(id)).length / k;
}

// Sessions with the author: each round the model ranks a moment, the
// author engages with the definition they most want (opening it if it
// is shown, pulling it in if not), now and then dismisses the shown one
// they least want, and every `every` rounds the model relearns from the
// whole log. `noise` blurs the author's judgement (a Gumbel scale);
// `chaos` is the share of rounds they act at random.
export function simulate({ hidden, seed = 1, rounds = 360, every = 60, noise = 0.5, chaos = 0, budget = { lines: 30, items: 10 }, options } = {}) {
  const rand = random(seed);
  const log = [];
  let t = 1e12;
  const session = createAttention({ write: (rs) => log.push(...rs), now: () => t, session: "sim" });
  const outline = program(rand);
  let result = { weights: DEFAULT_WEIGHTS, used: false };
  for (let round = 1; round <= rounds; round++) {
    t += 60e3;
    const state = moment(rand, outline, t);
    const shown = session.rank(state, budget);
    const scored = scoreAll({ ...state, dismissed: [] }, hidden).filter((s) => !s.focus);
    const gumbel = () => -Math.log(-Math.log(rand() + 1e-12) + 1e-12) * noise;
    const wanted = rand() < chaos ? pick(rand, scored) : scored.map((s) => ({ s, u: s.score + gumbel() })).sort((a, b) => b.u - a.u)[0].s;
    const isShown = shown.some((s) => s.id === wanted.id);
    session.observe({ type: isShown ? (rand() < 0.3 ? "edit" : "open") : "pull", id: wanted.id });
    if (rand() < 0.3) {
      const utility = new Map(scored.map((s) => [s.id, s.score]));
      const worst = shown.filter((s) => !s.focus).sort((a, b) => utility.get(a.id) - utility.get(b.id))[0];
      if (worst && worst.id !== wanted.id && utility.get(worst.id) < 1) session.showLess(worst.id);
    }
    if (round % every === 0) result = session.learnFrom(log, options);
  }
  // judged on fresh moments of the same program
  const test = random(seed + 1000);
  const moments = Array.from({ length: 150 }, (_, i) => moment(test, outline, t + i * 60e3));
  const mean = (w) => moments.reduce((sum, m) => sum + precision(m, w, hidden), 0) / moments.length;
  return { log, result, weights: result.weights, before: mean(DEFAULT_WEIGHTS), after: mean(result.weights) };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  for (const [name, hidden] of Object.entries(AUTHORS)) {
    const run = simulate({ hidden });
    const changed = LEARNED.filter((k) => Math.abs(run.weights[k] - DEFAULT_WEIGHTS[k]) > 0.05).map((k) => `${k} ${DEFAULT_WEIGHTS[k]} -> ${run.weights[k]}`);
    console.log(`${name}: precision@5 ${run.before.toFixed(2)} -> ${run.after.toFixed(2)}; ${run.result.why}; agreement ${JSON.stringify(run.result.agreement)}`);
    console.log(`  ${changed.join(", ") || "weights unchanged"}`);
  }
  const chaos = simulate({ hidden: AUTHORS.defaults, chaos: 1 });
  console.log(`random author: precision@5 ${chaos.before.toFixed(2)} -> ${chaos.after.toFixed(2)}; ${chaos.result.why}`);
}
