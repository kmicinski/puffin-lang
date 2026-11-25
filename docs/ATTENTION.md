# Attention: what to show, when

Status, 2026-11-25: built on the `view-relevance` branch. The model is
`studio/web/attention.js` (pure: no DOM, no network, no clock), its
view of the studio `studio/web/attention-studio.js`, the log
`studio/src/attention.rs` (`/attention/log`), a demo page at
`/attention`, tests in `studio/web/test/`. No UI uses it yet: the
unified code+board views (one zoomable canvas; a focused editor with a
working set) are the intended callers, and §3 is the contract they
integrate against.

The question it answers: *of every definition in the program, which
should be on the screen now, and how much of each* — so that, by
default, what the author needs next is already there, and what is
there can say why.

The answer is deliberately small: a dozen named features of a
definition, each a number in [0, 1], times a weight; the sum buys a
level of detail; a greedy pass fits the best into a budget of screen
lines. Every number has a name and a sentence, so every ranking is
explainable ("shown because: step uses it, through apply-kont; the
builder changed it 2 min ago, not yet seen"), deterministic (the time
is part of the state; the same state ranks the same), and cheap enough
to rerun on every keystroke. The weights start as the defaults below
and can be tuned to one author by what they do (§4) — within limits
that keep the defaults' behavior as a floor.

## 1. What it sees

The program graph is the module board's outline (board.rs `outline`,
docs/PLANNING.md): modules, their definitions (`fun`, `val`, `type`,
`alias`, `grammar`, and each `property` in properties.puf), each
definition's signature, holes, comment and the top-level names it
uses. `graph(outline)` resolves those names — in the definition's own
module first, then the modules it requires, then anywhere — adds the
types its signature names (a `(: f (-> A B))` declaration does not put
`A` among `f`'s uses), maps each constructor to its type, and keeps
the reverse edges (callers).

The rest is the moment (`state`; all optional but `now` and
`outline`). Ids are `path::name`; a bare name resolves like a use.

| field | what | from |
|---|---|---|
| `focus` | the definition the author is in | the UI: cursor, selected row |
| `context` | `{ ids, label }`: a secondary set | the board's focus (a question's slice, "just step and inject"), a working set |
| `edits` | `[{ id, at, by: "author" \| "builder" }]` | voice `edited`; another tab's `text`; the UI's own edits |
| `properties` | `[{ name, status }]` (props.rs statuses) | voice `properties` |
| `errors` | definitions holding a check error | `diagnostics` |
| `questions` | `[{ text, about, answered }]` | the board's questions |
| `voice` | `[{ id, at }]`: just mentioned | voice `focus` targets |
| `views` | `[{ id, at, ms }]`: what the author read, how long | the session (§3) |
| `pins`, `dismissed` | `[id]`, `[{ id, at }]` | the session (§3) |

`createTracker()` (attention-studio.js) folds the WebSocket's messages
into all of this but the UI's own focus and edits.

## 2. The model

### Features and default weights

| feature | value | weight | why |
|---|---|---|---|
| `focus` | 1 for the focus | 10 | you are here: always shown, in full. Structural, never learned. |
| `uses` | ½^(d−1) for what the focus uses, d ≤ 3 steps | 4.5 | needed to read the focus; a direct callee in the same module comes out in full |
| `usedBy` | ½^(d−1) for what uses the focus, d ≤ 2 | 3 | the callers constrain it, and are what a change breaks |
| `sigType` | 1 for a type in the focus's signature | 2.5 | its one line (`type Kont = Done \| Arg of ...`) says a lot, cheaply |
| `context` | 1 in the context set, ½ next to it | 3 | the question being asked, what voice pointed at |
| `failing` | 1 for a failing or crashed property itself or a check error; 0.7 for what a failing property mentions | 4 | the thing to fix, and the suspects |
| `question` | 1 if an open question is about it | 3 | a design decision is waiting on it |
| `builderEdit` | fades, half-life 10 min; ×0.3 once looked at (≥ 2 s) since | 3 | the builder's change is news until the author has seen it |
| `authorEdit` | fades, half-life 15 min | 1.5 | what the author is working on (the focus mostly says this already) |
| `voice` | fades, half-life 3 min | 2.5 | "where is alloc", or the builder saying it |
| `looked` | 1 − e^(−3x), x = minutes read in the last hour or so (each view's time capped at one, fading by half each 30 min) | 1 | what the author keeps coming back to |
| `unfinished` | 1 if planned (body `??`) or has holes | 0.5 | the work still to do; in plan mode, the work list |
| `propertyOpen` | 1 if an *open* property (one that reaches a hole) mentions it | 0.5 | the hole that keeps a property undecided |
| `sameModule` | 1 beside the focus | 0.8 | locality |
| `interface` | 1 if its module provides it, ½ if the module provides everything | 0.6 | public definitions are the ones others need |
| `dismissed` | fades, half-life 20 min | −4 | "show this less" |

Why linear, and why these: each weight is a sentence the author can
argue with ("a caller matters less than a callee") and change; the
reasons shown are just the largest products, so the explanation *is*
the model, not a story about it. The values were set by reading the
rankings they give on studio/demo/machine and asking, row by row, "is
this what I would want open?" — the tests pin the judgements that
matter (direct callees of the focus in full, distance decays, a
signature's types folded, failures and the builder's unseen changes
lifted, a dismissal hidden and then lowered).

### Detail and the budget

A definition's score buys the most detail it reaches: **full** (its
code) at 5, **folded** (its signature row with its comment) at 3, a
**signature** line at 1.5; under that it is not shown however much room
there is — the model answers "what deserves attention", not "what
exists" (the board shows what exists). A type is never more than
folded unless it is the focus: its folded row is its definition. Each
detail costs screen lines: a signature 1, folded 1 + its comment (≤ 2),
full its lines + its comment.

`rank` then goes down the list — the focus, then pins, then by score
(ties by place in the program, so the order is stable) — giving each
the detail its score buys and *cheapening* it (full → folded →
signature) until it fits what is left of the budget `{ lines, items,
full }` (defaults 60 lines, 24 definitions, 4 in full besides the
focus). Short of room, detail goes before definitions do. The focus and
pins always get at least a line. A definition dismissed less than ten
minutes ago is not shown at all, unless it is the focus, pinned, or
edited since; after that, `dismissed` keeps it lower for a while.

On the demo, focused on `step`, with the builder having just changed
`bind-and-eval` and the property `closed-terminates` failing:

```
full       10.6  step            you are here
full       5.85  bind-and-eval   the builder changed it just now, not yet seen; step uses it, through apply-kont
full        5.3  step-eval       step uses it; beside step in machine.puf
full        5.3  apply-kont      step uses it; beside step in machine.puf
folded      4.7  run             in failing property closed-terminates; ...; planned, not written
folded      4.0  closed-terminates  property closed-terminates fails
folded      3.9  State           in step's signature; ...
folded      3.4  expr-size       in failing property closed-terminates; ...
signature  2.85  add-values      step uses it, through apply-kont; ...
```

## 3. The contract the UIs call

```js
import { createAttention, httpLog } from "./attention.js";
import { createTracker } from "./attention-studio.js";

const tracker = createTracker();          // socket.onmessage: tracker.receive(message)
const log = httpLog();                    // POSTs to /attention/log, batched; sendBeacon on hide
const attention = createAttention({ write: log.write });
attention.learnFrom(await log.read());    // once, on open: this project's tuned weights

// whenever anything changes (and every 30 s or so: things fade)
const shown = attention.rank(tracker.state({ focus }), { lines, items, full });
//   -> [{ id, name, path, kind, detail: "full" | "folded" | "signature",
//         score, cost, reasons: [string], pinned, focus }]

// what the author does with it
attention.observe({ type: "open", id, detail });  // asked for more of a shown one
attention.observe({ type: "pull", id });          // brought in one not shown (a clicked reference, a search)
attention.observe({ type: "edit", id });          // and tracker.edit(file, fromLine, toLine)
attention.observe({ type: "focus", id });         // moved into it
attention.observe({ type: "dwell", id, ms });     // it held the author ms (in view, hovered, open)
attention.showLess(id);                           // the "show this less" button
attention.pin(id); attention.unpin(id);           // "keep this"
attention.why(id, budget);                        // -> { verdict, score, detail, reasons: [{feature, weight, text}], features }
```

Notes for integrators:

- `rank` is cheap — a quarter of a millisecond for the demo's 34
  definitions, about 2 ms for 540 — so call it freely; the tracker's
  state carries the graph, built once per outline. It logs an impression only when what
  is on the screen changes, and only a non-empty one.
- `observe` is what the learning is made of. `pull` is the strongest
  and most valuable signal — it is the model's *miss* — so report it
  wherever the author brings in something the model did not offer: A's
  materialized cross-reference, B's pulled-in fragment, a search.
  `open` is for a raise in detail of something shown. `dwell` should be
  real attention (in view and the window focused, or hovered), and
  only reported past a couple of seconds.
- `why(id)` answers for anything, shown or not ("not shown: no room
  (it ranks 14 of 34)", "not shown: it scores 0.6, under 1.5", "hidden:
  you dismissed it"), so a "why isn't X here?" affordance is one call.
- The model is UI-agnostic about *placement*: A can lay the ranked list
  out around the focus on the canvas (full = expanded row, folded = the
  row, signature = a chip), B can take it as the working set's default
  contents; both keep their own explicit choices as pins.
- Ids are `path::name`; a property is `properties.puf::<name>`.

## 4. Learning the author's preferences

### Why not literally RLHF

RLHF fits a *reward model* to human comparisons of whole outputs, then
optimizes a *policy* (an LLM) against it with reinforcement learning.
Neither half fits here. There is no generative policy to optimize: the
"policy" is a ranking function with sixteen weights. And the author
never compares two screens; they *act on one* — open this, pull in
that, ignore the rest. That is the classic setting of **learning to
rank from implicit feedback** (search-engine clicks; Joachims 2002),
which is itself a **contextual bandit**: the context is the moment, the
action is the screen shown, and the reward is only observed for what
was shown. The right tools are pairwise preference models and
counterfactual care, not PPO.

### From the log to preferences

Each impression and the interactions tied to it yield pairs `a ≻ b`
of feature vectors (`preferences(log)`):

- **skip-above**: engaged with *x* while *y* sat above it, untouched:
  *x* ≻ *y*;
- **confirmation**: engaged with *x* while *y* sat below it, untouched:
  *x* ≻ *y* at half strength. Skip-above alone only ever argues
  *against* the current order (the author clicking the top item yields
  no pair at all), so a learner fed only that drifts away from a good
  default; this is Joachims' "click > skip next" in spirit;
- **pull**: brought in *x*, not shown: *x* ≻ every untouched item
  shown — it should have had one of their places;
- **dismissal**: "show this less" on *y*: the best few unshown
  candidates (logged with every impression as its `pool`), and every
  untouched item below *y*, ≻ *y*.

Interactions weigh `pull` 1, `edit` 1, `open` 0.7, `focus` 0.5, `dwell`
(≥ 4 s) 0.3, and one event's pairs share its weight, so a pull among
twenty items counts what a pull among two does. The focus and pins are
never lessons: they are there because the author put them there.
Every record carries the feature vectors involved, so the log alone is
enough to learn from — the program it was about may have changed since.

### The update, and why it cannot do much harm

A pairwise logistic (Bradley–Terry / RankNet) model: for each pair,
`w += η · weight · σ(−w·(a−b)) · (a−b)`, plus a pull back toward the
defaults (an L2 prior), 50 passes over the pairs in time order.
Three guards keep the defaults as a floor:

1. **Too little data, no change**: under 20 preferences the defaults
   stand.
2. **A band**: every weight stays between a third of its default and
   three times it, and never changes sign — the author can teach "callers
   matter more to me than callees", not "failures don't matter". `focus`
   is not learned at all.
3. **A held-out check**: the weights are first trained on the older
   80% of the pairs and kept only if they order the newest 20% better
   than the defaults do (by a 0.02 margin of weighted pairwise
   agreement); otherwise the defaults stand and the report says why.

It is per project (the log is the project's), recomputed from the whole
log when the page opens (milliseconds), and `learnFrom` returns a report
(`used`, `why`, the agreement of defaults and tuned weights on the
held-out pairs) for a UI to show.

### What the simulation shows

`studio/web/test/simulate.mjs` makes a random four-module program and,
round after round, a random moment in a session; a simulated author
wants what a *hidden* weight vector says (with Gumbel noise), opens what
they want if it is shown, pulls it in if not, now and then dismisses
what they least want; the model relearns every 60 rounds. Judged by how
many of the model's top 5 are among the author's own top 5, on fresh
moments (`node studio/web/test/simulate.mjs`):

| author | before | after 360 rounds | the weights |
|---|---|---|---|
| reads callers (usedBy 8, uses 2) | 0.73 | 0.91 | usedBy 3 → 5.7, uses 4.5 → 2.8 |
| follows the builder (builderEdit 8) | 0.71 | 0.89 | builderEdit 3 → 5.6, usedBy 3 → 1.7 |
| wants the defaults | 1.00 | 1.00 | unchanged (the held-out check finds nothing better) |
| acts at random | 1.00 | 1.00 | refused by the held-out check; with the check off, the band holds the damage to ≈ 0.8 |

The tests assert these directions.

### Honest limits, and what would make it better

- **Position and selection bias.** The author can only engage with what
  is shown, and more with what is higher. Skip-above pairs partly
  correct for position; pulls are the only window onto what was never
  shown, which is why they matter most. Proper counterfactual learning
  (inverse propensity weighting) would need *randomization* — e.g.
  occasionally swapping two adjacent items and logging the
  probability — which buys unbiasedness with a small, deliberate cost
  in screen quality. Not done: the model is deterministic by design;
  it is a one-line change in `allocate` plus a `p` in the log when
  wanted.
- **Feature drift.** The log records `v` (LOG_VERSION). A future change
  of a feature's meaning should bump it and have `preferences` skip old
  records.
- **Data that would help**, roughly in order: explicit pulls from every
  UI (the misses); dwell measured as visible-and-focused time; *why* a
  dismissal ("not now" vs "never for this"); the author's task mode
  (plan / build / debug — a per-mode weight vector is the natural next
  step, and the band and check apply unchanged); and, across projects,
  a per-author prior (the log stays local; a learned weight vector is
  sixteen numbers and could travel with the author's settings).
- **Not learned**: thresholds, half-lives, the depth of the walk.
  They could be, but each would cost legibility; the weights alone have
  given the simulated authors most of what they wanted.

## 5. An LLM as a re-ranker, for voice

The linear model knows structure and recency; it does not know what a
sentence *means*. When the author says "why does the machine get
stuck on let?", the router (voice.rs) already resolves names, and the
builder knows what it is about to talk about. The cheap, robust way to
bring that in is as *features*, not as a replacement ranking:

- names the router or builder resolves become `voice` mentions (the
  tracker does this for voice `focus` events) or a `context` set
  (`{ ids, label: "you asked about let" }`) — the model's own reasons
  then say why;
- for a request the router cannot resolve to names, a re-ranking call
  (Haiku-class, ~100 tokens out) gets the utterance and the model's top
  ~20 with their signatures and reasons, and returns the few ids it
  thinks the author means; those enter as `context`. Because it can
  only *add* context, a wrong guess costs a few lines of screen, never
  the focus or a pin, and the explanation stays honest ("in context:
  you asked about let").

This keeps the LLM off the hot path (no call per keystroke), keeps the
ranking deterministic given its inputs, and lets the log learn how much
to trust it (`context`'s weight) like any other feature.

## 6. The log, the demo page, the tests

- **The log** is `.puffin/attention-log.jsonl` in the project: one JSON
  record a line — `shown` (the impression: items with rank, detail and
  features; the best unshown `pool`), then `open`, `pull`, `edit`,
  `focus`, `dwell`, `dismiss`, `pin`, `unpin`, each with the impression
  it answers (`imp`) and the target's features. It is the author's
  behavior, not the program's, so it never leaves the machine and is
  never committed: `attention.rs` lists it in the repository's own
  `.git/info/exclude` before the first write (not in `.gitignore`,
  which is committed). Bounded at 2 MB; past that the older half goes.
  `GET /attention/log` reads it, `POST` appends (lines that are not a
  JSON object with a `t` are dropped); both only from the studio's own
  pages (Origin, Sec-Fetch-Site).
- **The demo page**, `/attention` on a running studio: the open
  project's definitions on the left (click one to focus it; on hover,
  make the builder or the author edit it, ask about it, fail a
  property), what the model shows in the middle with its reasons, a
  budget slider, `more` / `less` / `pin` / `why` on each, and the
  weights on the right with "learn from the log". Try it on the demo:
  `puffin-studio studio/demo/machine` (a copy: the studio makes a
  project a git repository), then open `/attention`.
- **The tests**: `node --test studio/web/test/attention.test.mjs` (in
  `node:22-bookworm`), over the outline the studio computes for
  `studio/demo/machine` (`test/machine-outline.json`; regenerate it from
  the `init` message when the outline's shape changes), and `cargo
  test attention` for the log's bounds and exclusion.
