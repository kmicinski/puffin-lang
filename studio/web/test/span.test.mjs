// The spans the code view narrows to (span.js, docs/VIEW.md). Run with
//   docker run --rm -u 1000:1000 -v $PWD:/w -w /w node:22-bookworm sh -c "node --test studio/web/test/*.test.mjs"

import { test } from "node:test";
import assert from "node:assert/strict";
import { spanOf, nameAt } from "../span.js";

const FILE = `(require "lang.puf")

;; one transition
;; of the machine
(: step (-> State State))
(define (step st)
  (match st
    [(Eval e env s k) (step-eval e env s k)]))

(define limit 10)
`;

test("a definition's span takes its declaration and the comment above it", () => {
  const span = spanOf(FILE, "step");
  assert.deepEqual([span.start, span.end], [3, 8]);
  assert.equal(FILE.slice(span.from, span.to).split("\n")[0], "(: step (-> State State))");
  assert.ok(FILE.slice(span.from, span.to).endsWith("(step-eval e env s k)]))"));
  assert.deepEqual([spanOf(FILE, "limit").start, spanOf(FILE, "limit").end], [10, 10]);
  assert.equal(spanOf(FILE, "no-such"), null);
});

test("the definition at a line is found by its form or its declaration", () => {
  assert.equal(nameAt(FILE, 5), "step");
  assert.equal(nameAt(FILE, 7), "step");
  assert.equal(nameAt(FILE, 10), "limit");
  // a comment above, or a blank line, is in no definition
  assert.equal(nameAt(FILE, 3), null);
  assert.equal(nameAt(FILE, 9), null);
});
