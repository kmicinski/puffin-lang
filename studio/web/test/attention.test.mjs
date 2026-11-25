// The attention model's tests (docs/ATTENTION.md). Run them with
//   docker run --rm -u 1000:1000 -v $PWD:/w -w /w node:22-bookworm node --test studio/web/test/
// The fixture is the outline the studio computes for studio/demo/machine
// (board.rs `outline`, as the init message carries it).

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import {
  DEFAULT_WEIGHTS, HALF_LIFE, LEARNED, SUPPRESS_MS, THRESHOLDS,
  agreement, createAttention, explain, features, graph, idOf, learn, preferences, rank, scoreAll,
} from "../attention.js";
import { changedLines, createTracker } from "../attention-studio.js";
import { AUTHORS, simulate } from "./simulate.mjs";

const outline = JSON.parse(fs.readFileSync(new URL("./machine-outline.json", import.meta.url)));
const now = 1e12;
const at = (state) => ({ now, outline, ...state });
const STEP = "machine.puf::step";
const byId = (list) => new Map(list.map((x) => [x.id, x]));

// ---- the graph

test("uses resolve across modules, and callers are the reverse", () => {
  const g = graph(outline);
  // its body's names, and the types of its `(: step (-> State State))`
  assert.deepEqual(g.nodes.get(STEP).uses.sort(), ["machine.puf::State", "machine.puf::apply-kont", "machine.puf::step-eval"]);
  assert.ok(g.nodes.get("store.puf::alloc").usedBy.includes("machine.puf::bind-and-eval"));
  // a property is a node whose uses are what it mentions
  assert.deepEqual(g.nodes.get("properties.puf::closed-terminates").uses.sort(), ["lang.puf::expr-size", "machine.puf::run"]);
  // a constructor names its type
  assert.equal(g.resolve("Clo", "machine.puf"), "store.puf::Value");
});

// ---- scoring

test("the focus is shown in full, first, with its reason", () => {
  const [first] = rank(at({ focus: STEP }));
  assert.equal(first.id, STEP);
  assert.equal(first.detail, "full");
  assert.equal(first.reasons[0], "you are here");
});

test("what the focus calls decays with distance", () => {
  const f = (id) => features(at({ focus: STEP }), id);
  assert.equal(f("machine.puf::apply-kont").uses, 1);
  assert.equal(f("machine.puf::bind-and-eval").uses, 0.5);
  assert.equal(f("store.puf::alloc").uses, 0.25);
  const shown = byId(rank(at({ focus: STEP })));
  assert.equal(shown.get("machine.puf::apply-kont").detail, "full");
  assert.ok(shown.get("machine.puf::apply-kont").score > shown.get("machine.puf::bind-and-eval").score);
  assert.ok(shown.get("machine.puf::bind-and-eval").score > shown.get("store.puf::alloc").score);
  assert.equal(shown.get("machine.puf::bind-and-eval").reasons[0], "step uses it, through apply-kont");
});

test("callers count, and types are not walked through", () => {
  const f = features(at({ focus: "store.puf::alloc" }), "machine.puf::bind-and-eval");
  assert.equal(f.usedBy, 1);
  // step and inject both mention State; that does not make them neighbors
  assert.equal(features(at({ focus: STEP }), "machine.puf::inject").usedBy, 0);
});

test("the types in the focus's signature come as one folded line", () => {
  const state = at({ focus: "machine.puf::bind-and-eval" });
  for (const type of ["lang.puf::Var", "store.puf::Value", "store.puf::Env", "store.puf::Store", "machine.puf::Kont", "machine.puf::State"]) {
    assert.equal(features(state, type).sigType, 1, type);
  }
  const shown = byId(rank(state));
  assert.equal(shown.get("store.puf::Value").detail, "folded");
  assert.ok(shown.get("store.puf::Value").reasons.includes("in bind-and-eval's signature"));
});

test("a failing property lifts itself, and what it mentions a little less", () => {
  const state = at({ focus: STEP, properties: [{ name: "closed-terminates", status: "fail" }] });
  assert.equal(features(state, "properties.puf::closed-terminates").failing, 1);
  assert.equal(features(state, "lang.puf::expr-size").failing, 0.7);
  const shown = byId(rank(state));
  assert.ok(shown.get("lang.puf::expr-size").reasons.includes("in failing property closed-terminates"));
  assert.ok(!byId(rank(at({ focus: STEP }))).has("lang.puf::expr-size"));
});

test("the builder's edit fades by its half-life, and faster once looked at", () => {
  const edit = (age, views = []) => features(at({ edits: [{ id: "store.puf::alloc", at: now - age, by: "builder" }], views }), "store.puf::alloc").builderEdit;
  assert.equal(edit(0), 1);
  assert.equal(edit(HALF_LIFE.builderEdit), 0.5);
  assert.equal(edit(0, [{ id: "store.puf::alloc", at: now + 1, ms: 5000 }]), 0.3);
  // a glance does not count as looking
  assert.equal(edit(0, [{ id: "store.puf::alloc", at: now + 1, ms: 500 }]), 1);
});

test("an open question and the board's slice bring their definitions", () => {
  const state = at({ questions: [{ text: "Should alloc be deterministic?", about: ["alloc"] }] });
  const [first] = rank(state);
  assert.equal(first.id, "store.puf::alloc");
  assert.match(first.reasons[0], /^asked about: Should alloc/);
  const answered = at({ questions: [{ text: "?", about: ["alloc"], answered: true }] });
  assert.equal(features(answered, "store.puf::alloc").question, 0);
  const sliced = at({ context: { ids: ["store.puf::alloc"], label: "in question #1" } });
  assert.equal(features(sliced, "store.puf::alloc").context, 1);
  assert.equal(features(sliced, "machine.puf::bind-and-eval").context, 0.5);
});

test("a dismissal hides, then lowers, and an edit since brings it back", () => {
  const id = "machine.puf::apply-kont";
  const dismissed = (age) => at({ focus: STEP, dismissed: [{ id, at: now - age }] });
  assert.ok(!byId(rank(dismissed(60e3))).has(id));
  assert.match(explain(dismissed(60e3), id).verdict, /dismissed/);
  const later = byId(rank(dismissed(SUPPRESS_MS + 60e3)));
  assert.ok(later.has(id));
  assert.ok(later.get(id).score < byId(rank(at({ focus: STEP }))).get(id).score);
  const edited = at({ focus: STEP, dismissed: [{ id, at: now - 60e3 }], edits: [{ id, at: now - 1000, by: "builder" }] });
  assert.ok(byId(rank(edited)).has(id));
});

test("pins are shown whatever they score", () => {
  const state = at({ focus: STEP, pins: ["main.puf::examples"] });
  const shown = byId(rank(state, { lines: 8 }));
  assert.ok(["folded", "signature"].includes(shown.get("main.puf::examples").detail));
  assert.ok(shown.get("main.puf::examples").pinned);
});

// ---- the working set: scored, not special-cased

test("the set's members are always shown, their detail by their score", () => {
  const examples = "main.puf::examples";
  const fresh = byId(rank(at({ focus: STEP, set: [{ id: examples, at: now }] })));
  // unrelated to step, but just brought in: its folded row
  assert.equal(fresh.get(examples).detail, "folded");
  assert.ok(fresh.get(examples).kept);
  assert.equal(fresh.get(examples).reasons[0], "you brought it in");
  // an hour on, still there, as a line
  const old = byId(rank(at({ focus: STEP, set: [{ id: examples, at: now - 3600e3 }] })));
  assert.equal(old.get(examples).detail, "signature");
  // what the focus uses comes out in full, kept or not
  const callee = byId(rank(at({ focus: STEP, set: [{ id: "machine.puf::apply-kont", at: now - 3600e3 }] })));
  assert.equal(callee.get("machine.puf::apply-kont").detail, "full");
  // pinned: enough for its code
  const pinned = byId(rank(at({ focus: STEP, set: [{ id: examples, at: now - 3600e3, pinned: true }] }), { lines: 200 }));
  assert.equal(pinned.get(examples).detail, "full");
});

test("the set is ordered by score among the rest, not put first", () => {
  const shown = rank(at({ focus: STEP, set: [{ id: "main.puf::examples", at: now - 3600e3 }] }), { lines: 200 });
  const ids = shown.map((s) => s.id);
  assert.ok(ids.indexOf("machine.puf::apply-kont") < ids.indexOf("main.puf::examples"));
  for (let i = 2; i < shown.length; i++) assert.ok(shown[i - 1].score >= shown[i].score);
});

test("short of room, the set's lines are kept for it", () => {
  const set = ["main.puf::examples", "main.puf::answers", "lang.puf::free-vars"].map((id) => ({ id, at: now - 3600e3 }));
  const tight = rank(at({ focus: STEP, set }), { lines: 9 });
  for (const { id } of set) assert.ok(tight.some((s) => s.id === id), id);
  assert.ok(tight.reduce((sum, s) => sum + s.cost, 0) <= 9);
  // step-eval, which outscores them, had to give up its code for them
  assert.notEqual(byId(tight).get("machine.puf::step-eval")?.detail, "full");
});

test("what the author put in the set teaches the learner nothing", () => {
  const pairs = preferences([
    { t: "shown", imp: "k", at: 1, items: [
      { id: "a", rank: 1, kept: true, f: { kept: 1 } },
      { id: "b", rank: 2, f: { uses: 1 } },
    ] },
    { t: "edit", imp: "k", id: "a", f: { kept: 1 } },
  ]);
  assert.equal(pairs.length, 0);
  assert.ok(!LEARNED.includes("kept") && !LEARNED.includes("pinned"));
});

// ---- the budget

test("the budget holds: lines, items, and how many in full", () => {
  for (const budget of [{ lines: 12 }, { lines: 30, items: 6 }, { lines: 200, full: 1 }]) {
    const shown = rank(at({ focus: STEP, properties: [{ name: "closed-terminates", status: "fail" }] }), budget);
    if (budget.lines) assert.ok(shown.reduce((sum, s) => sum + s.cost, 0) <= budget.lines, JSON.stringify(budget));
    if (budget.items) assert.ok(shown.length <= budget.items);
    if (budget.full) assert.ok(shown.filter((s) => s.detail === "full" && !s.focus).length <= budget.full);
  }
});

test("short of room, detail is given up before definitions are", () => {
  const roomy = byId(rank(at({ focus: STEP }), { lines: 200 }));
  const tight = byId(rank(at({ focus: STEP }), { lines: 14 }));
  assert.equal(roomy.get("machine.puf::step-eval").detail, "full");
  assert.notEqual(tight.get("machine.puf::step-eval").detail, "full");
});

test("nothing under the floor is shown, however much room", () => {
  for (const s of rank(at({ focus: STEP }), { lines: 1000, items: 1000 })) assert.ok(s.focus || s.score >= THRESHOLDS.signature, s.id);
  assert.match(explain(at({ focus: STEP }), "main.puf::examples").verdict, /^not shown: it scores/);
});

test("ranking is deterministic", () => {
  const state = at({ focus: STEP, edits: [{ id: "store.puf::alloc", at: now - 5000, by: "author" }] });
  assert.deepEqual(rank(state), rank(structuredClone(state)));
});

// ---- the session and its log

test("a session logs what changed on screen and what the author did with it", () => {
  const log = [];
  let t = now;
  const session = createAttention({ write: (rs) => log.push(...rs), now: () => t, session: "s" });
  session.rank(at({ focus: STEP }));
  session.rank(at({ focus: STEP }));
  assert.equal(log.filter((r) => r.t === "shown").length, 1, "the same screen is one impression");
  const shown = log[0];
  assert.equal(shown.imp, "s:1");
  assert.equal(shown.items[0].focus, true);
  assert.ok(shown.pool.length > 0);
  session.observe({ type: "pull", id: "main.puf::answers" });
  const pull = log.at(-1);
  assert.equal(pull.imp, "s:1");
  assert.ok(pull.f.interface === 0.5 && !("uses" in pull.f), "features are logged, zeros left out");
  t += 1000;
  session.showLess("machine.puf::apply-kont");
  assert.ok(!session.rank(at({ focus: STEP, now: t })).some((s) => s.id === "machine.puf::apply-kont"));
  assert.match(session.why("machine.puf::apply-kont").verdict, /dismissed/);
});

test("preferences: skip-above, confirmation, pulls and dismissals", () => {
  const f = (k) => ({ [k]: 1 });
  const shown = { t: "shown", imp: "a", at: 1, items: [
    { id: "F", rank: 1, focus: true, f: f("focus") }, { id: "x", rank: 2, f: f("uses") }, { id: "y", rank: 3, f: f("usedBy") }, { id: "z", rank: 4, f: f("voice") },
  ], pool: [{ id: "p", f: f("looked") }] };
  const pairs = (events) => preferences([shown, ...events.map((e) => ({ imp: "a", ...e }))]);
  // opened y: y over x above it, and over z below at half strength
  const opened = pairs([{ t: "open", id: "y", f: f("usedBy") }]);
  assert.deepEqual(opened.map((p) => [Object.keys(p.a)[0], Object.keys(p.b)[0]]), [["usedBy", "uses"], ["usedBy", "voice"]]);
  assert.equal(opened[0].weight, 2 * opened[1].weight);
  assert.ok(Math.abs(opened[0].weight + opened[1].weight - 0.7) < 1e-9, "an event's pairs share its strength");
  // pulled q, unshown: over every idle shown item
  assert.equal(pairs([{ t: "pull", id: "q", f: f("sameModule") }]).length, 3);
  // dismissed x: the best unshown and the idle items below it are better
  const dismissed = pairs([{ t: "dismiss", id: "x", f: f("uses") }]);
  assert.deepEqual(dismissed.map((p) => Object.keys(p.a)[0]).sort(), ["looked", "usedBy", "voice"]);
  // the focus is never a lesson
  assert.equal(pairs([{ t: "focus", id: "F", f: f("focus") }]).length, 0);
});

// ---- learning

test("too little to go on: the defaults stand", () => {
  const result = learn([]);
  assert.equal(result.used, false);
  assert.deepEqual(result.weights, DEFAULT_WEIGHTS);
});

test("the learned weights stay within the band, signs kept", () => {
  // an author who only ever wants what the focus does NOT use
  const log = [];
  for (let i = 0; i < 200; i++) {
    log.push({ t: "shown", imp: `i${i}`, at: i, items: [{ id: "a", rank: 1, f: { uses: 1, interface: 1 } }, { id: "b", rank: 2, f: { dismissed: 1 } }], pool: [] });
    log.push({ t: "pull", imp: `i${i}`, id: "b", f: { dismissed: 1 } });
  }
  const { weights } = learn(log, { margin: -1 });
  for (const k of LEARNED) {
    const [lo, hi] = [DEFAULT_WEIGHTS[k] / 3, DEFAULT_WEIGHTS[k] * 3].sort((x, y) => x - y);
    assert.ok(weights[k] >= lo - 0.01 && weights[k] <= hi + 0.01, `${k} ${weights[k]}`);
  }
  // pushed as far as the band lets them (the weights are kept to two places)
  assert.ok(Math.abs(weights.uses - DEFAULT_WEIGHTS.uses / 3) < 0.01, `uses ${weights.uses}`);
  assert.ok(Math.abs(weights.dismissed - DEFAULT_WEIGHTS.dismissed / 3) < 0.01, `dismissed ${weights.dismissed}`);
  assert.equal(weights.focus, DEFAULT_WEIGHTS.focus);
});

test("an author with a hidden preference is learned", () => {
  for (const [name, hidden, up, down] of [["callers", AUTHORS.callers, "usedBy", "uses"], ["follower", AUTHORS.follower, "builderEdit", "usedBy"]]) {
    const run = simulate({ hidden });
    assert.ok(run.result.used, name);
    assert.ok(run.weights[up] > DEFAULT_WEIGHTS[up] * 1.5, `${name}: ${up} ${run.weights[up]}`);
    assert.ok(run.weights[down] < DEFAULT_WEIGHTS[down] * 0.8, `${name}: ${down} ${run.weights[down]}`);
    assert.ok(run.after >= run.before + 0.1, `${name}: precision ${run.before} -> ${run.after}`);
    assert.ok(run.result.agreement.learned > run.result.agreement.prior);
  }
});

test("an author who wants the defaults keeps them", () => {
  const run = simulate({ hidden: AUTHORS.defaults });
  assert.ok(run.after >= 0.95, `precision ${run.after}`);
});

test("noise cannot do much harm: the guard refuses it, and the band bounds it", () => {
  const guarded = simulate({ hidden: AUTHORS.defaults, chaos: 1 });
  assert.equal(guarded.result.used, false);
  const unguarded = simulate({ hidden: AUTHORS.defaults, chaos: 1, options: { margin: -1 } });
  assert.ok(unguarded.after >= 0.6, `precision with the guard off ${unguarded.after}`);
});

test("agreement counts the share of pairs ordered right", () => {
  const pairs = [{ a: { uses: 1 }, b: { usedBy: 1 }, weight: 3 }, { a: { usedBy: 1 }, b: { uses: 1 }, weight: 1 }];
  assert.equal(agreement(pairs, DEFAULT_WEIGHTS), 0.75);
});

// ---- the studio's messages

test("changed lines: the differing span of the new text", () => {
  assert.deepEqual(changedLines("a\nb\nc", "a\nb\nc"), [0, 0]);
  assert.deepEqual(changedLines("a\nb\nc", "a\nB\nc"), [2, 2]);
  assert.deepEqual(changedLines("a\nc", "a\nb1\nb2\nc"), [2, 3]);
  assert.deepEqual(changedLines("a\nb\nc", "a\nc"), [2, 2]);
});

test("the tracker folds the studio's messages into a state", () => {
  let t = now;
  const tracker = createTracker({ now: () => t });
  const board = { focus: { items: [["store.puf", "alloc"], ["properties.puf", "@6"]], question: 1 }, questions: [{ id: 1, text: "Deterministic?", about: ["alloc"], answered: false }] };
  tracker.receive({ t: "init", board: { outline, board }, files: [], diagnostics: { "main.puf": { ok: false, diagnostics: [{ file: "store.puf", line: 27, severity: "error", message: "x" }] } } });
  tracker.receive({ t: "voice", kind: "edited", file: "machine.puf", from: 78, to: 80 });
  tracker.receive({ t: "voice", kind: "properties", results: { properties: [{ name: "closed-terminates", status: "open" }] } });
  tracker.receive({ t: "voice", kind: "focus", targets: [{ file: "machine.puf", line: 42 }] });
  const state = tracker.state({ focus: STEP });
  assert.deepEqual(state.errors, ["store.puf::alloc"]);
  assert.deepEqual(state.edits, [{ id: "machine.puf::bind-and-eval", at: t, by: "builder" }]);
  assert.deepEqual(state.voice.map((v) => v.id), [STEP]);
  assert.deepEqual(state.context, { ids: ["store.puf::alloc"], label: "in question #1" });
  const why = byId(scoreAll(state));
  assert.ok(why.get("store.puf::alloc").reasons.some((r) => r.text === "it has a check error"));
  assert.ok(why.get("machine.puf::run").reasons.some((r) => r.text === "property closed-terminates waits on it"));
  assert.equal(tracker.at("machine.puf", 43), STEP);
  assert.deepEqual(tracker.edit("store.puf", 26, 31), ["store.puf::alloc", "store.puf::env-ref"]);
  assert.equal(idOf("a.puf", "f"), "a.puf::f");
});

test("a type in focus brings the types its constructors carry", () => {
  const state = at({ focus: "machine.puf::Kont" });
  assert.equal(features(state, "store.puf::Env").sigType, 1);
  assert.equal(features(state, "lang.puf::Expr").sigType, 1);
  // and what mentions it, through the graph
  assert.equal(features(state, "machine.puf::apply-kont").usedBy, 1);
});
