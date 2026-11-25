// The lane's call-tree order (lane.js, docs/VIEW.md). Run with
//   docker run --rm -u 1000:1000 -v $PWD:/w -w /w node:22-bookworm sh -c "node --test studio/web/test/*.test.mjs"

import { test } from "node:test";
import assert from "node:assert/strict";
import { laneTree } from "../lane.js";

// the machine demo's step and what it reaches, each list in text order
const USES = {
  step: ["step-eval", "apply-kont", "State"],
  "step-eval": ["env-ref", "store-ref"],
  "apply-kont": ["apply-closure", "bind-and-eval", "zero-value?"],
  "apply-closure": ["bind-and-eval"],
  "bind-and-eval": ["alloc", "env-ref"],
  run: ["step", "final?"],
};
const usesOf = (id) => USES[id] ?? [];
const shape = (rows) => rows.map((r) => `${"  ".repeat(r.depth)}${r.id}<${r.parent}`);

test("what the focus uses comes in the order its text uses it, each followed by what it alone brings", () => {
  // the model's order is not the program's: the tree is
  const rows = laneTree("step", ["env-ref", "apply-kont", "zero-value?", "step-eval"], usesOf);
  assert.deepEqual(shape(rows), [
    "step-eval<step",
    "  env-ref<step-eval",
    "apply-kont<step",
    "  zero-value?<apply-kont",
  ]);
});

test("a piece hangs under the nearest thing that uses it", () => {
  // bind-and-eval is used by apply-kont directly and by apply-closure:
  // it sits under apply-kont, after apply-closure (the text's order)
  const rows = laneTree("step", ["apply-kont", "apply-closure", "bind-and-eval", "alloc"], usesOf);
  assert.deepEqual(shape(rows), [
    "apply-kont<step",
    "  apply-closure<apply-kont",
    "  bind-and-eval<apply-kont",
    "    alloc<bind-and-eval",
  ]);
});

test("what the focus does not reach roots its own tree, a caller before what it calls", () => {
  // focus on apply-kont: step (a caller) and run (step's caller) were pulled
  const rows = laneTree("apply-kont", ["step", "zero-value?", "run", "State"], usesOf);
  assert.deepEqual(shape(rows), [
    "zero-value?<apply-kont",
    "run<null",
    "  step<run",
    "    State<step",
  ]);
});

test("cycles and the focus itself are walked once", () => {
  const cyclic = { a: ["b"], b: ["a", "c"], c: ["b"] };
  const rows = laneTree(null, ["c", "b", "a"], (id) => cyclic[id] ?? []);
  assert.deepEqual(rows.map((r) => r.id).sort(), ["a", "b", "c"]);
  // a fragment that uses the focus does not bring it into the lane
  const back = laneTree("b", ["a", "c"], (id) => cyclic[id] ?? []);
  assert.deepEqual(shape(back), ["a<b", "c<b"]);
});

test("nothing focused: the model's order, trees kept together", () => {
  const rows = laneTree(null, ["env-ref", "step-eval", "alloc"], usesOf);
  assert.deepEqual(shape(rows), ["step-eval<null", "  env-ref<step-eval", "alloc<null"]);
});
