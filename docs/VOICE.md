# Voice mode: building a program by talking

Status, 2026-11-18: an experimental MVP on the `voice` branch (built on
`experimental`, so grammar types are there; the voice code is its own
modules and touches the rest of the studio only at the seams listed in
§6). Turn it on with the 🎙 Voice button in Puffin Studio's header, or
⌘⇧V.

The idea: the author talks, continuously, hands off the keyboard, and the
studio keeps up. They say what to build ("scaffold me the CESK* machine
from Van Horn and Might"), what must be true of it ("a property: running
a closed term never gets stuck"), and where to look ("where is step
used", "line 40", "show me inject"); an agent writes the code as they
talk, the view follows its edits, and the properties are checked on every
change. Being interrupted is normal: a correction mid-build ("actually,
use a hash for the store") redirects the work at once.

## 1. Two paths for every phrase

The browser's speech recognizer (the Web Speech API: Chrome, Edge,
Safari; elsewhere, type in the dock) turns speech into text phrase by
phrase. Each finished phrase goes to the studio with what the author is
looking at: the shown file, the cursor's line, the word under the mouse
and its line, the selection, the visible lines.

1. **Instant, in the tab** (`studio/web/voice.js` `local`): "line N",
   "next", "previous", "back", "stop", "undo", "scroll up/down", "mute",
   "stop listening". These never leave the browser.
2. **The router** (`studio/src/voice.rs` `route`): one Messages API call
   to a fast model (`claude-haiku-5-5`, structured output, ~1.5-2.5 s)
   that sees the phrase, the files and their top-level definitions, the
   author's view, the builder's state, the properties and the recent
   conversation, and answers in one schema:
   - `navigate`: definition / usages / line / file / text search / next /
     previous / back, with the name or line resolved ("this function"
     means the one under the mouse, then the cursor). The studio resolves
     it against the program's text (definitions by `sexp::forms`, uses by
     atoms outside comments and strings) — navigation never waits on the
     builder.
   - `build`: the phrase rewritten as a self-contained instruction (every
     "this" resolved to a name, file and line), with an urgency:
     `interrupt` (it changes or corrects the work in progress) or `queue`
     (more work, after the current).
   - `control`: stop, undo, run the properties, a new conversation, mute,
     sleep, follow/unfollow.
   - `reply`: a few words the studio says aloud (empty for pure
     navigation: the view moving is the answer; empty for talk that is
     not meant for the studio).

   Phrases are routed one at a time, in order. The recognizer ends a
   phrase at every pause, so a request often arrives in pieces ("so
   let's build out" … "a checker for the simply typed lambda calculus").
   Words the router does nothing with are kept (`fragments`, 45 s) and
   given to the router with the next phrase, to read as one utterance;
   the first phrase that does something clears them.

## 2. The builder

A long-running `claude -p` agent (`claude-opus-5-5` by default,
`PUFFIN_VOICE_MODEL` / `PUFFIN_VOICE_EFFORT` to change), resumed across
instructions so it keeps the conversation. Its only tools are the
studio's MCP endpoint, reached with an `X-Studio-Voice` header that gives
it voice tools (`voice.rs` `tools`):

- the assistant's reads and checks (get_file, check, type_at, facts_at,
  evaluate, evaluate_program, trace, search_docs, ...);
- `edit` / `write_file` / `delete_file`, which apply **at once** (no
  proposal, no review — the author is watching each land, and every one is
  a commit in the project's history and undoable by voice); each answers
  with the changed lines and the program's check afterwards;
- `add_property` / `run_properties` (§4);
- `research`: a question answered with the API's server-side web search
  and fetch (`claude-opus-5-5`), so a paper or a spec can be read from a
  studio with no route to the web of its own;
- `say`: one sentence spoken aloud to the author; `show`: move their view.

Interruption: an `interrupt` instruction kills the run in flight and
resumes the same session with the new words and a note that it was cut
off; what it had applied stays. A `queue` instruction waits for the run
to end. When a run ends with properties failing, the builder is sent back
to fix them, at most twice per instruction from the author.

## 3. What the author sees

No fixed layout: the editor, alone and centered (about 105 characters
wide, near full height), and components that float in when they are used
(`studio/web/focus.js`, `voice.js`). This is how the studio opens; the
microphone waits for a click. "Show all panes" in ⋯ brings back the
classic layout (tree, tabs, REPL), remembered per browser.

- **The canvas**: a project with no code yet shows no editor at all —
  only the pill, centered, asking what to build; the editor fades in when
  the first code lands. A new visit (a browser tab new to the studio)
  starts there too, over a project that has code, with "or continue
  PROJECT"; the first description then makes a new project named from
  its words (`cesk-star-machine`), and is given to the builder there.
  Reloading a tab returns to its work.
- **What happened**, in the left margin: every exchange — what was said,
  what the router did with it and how long it took, the reply — and under
  it each builder turn, step by step as it happens: the builder's
  one-line notes of what it is about to do and why, each read, edit
  (file:lines, a click to show them, ▾ for the new code), check, run,
  property and lookup, with how it went; a live line at its foot. Older
  turns fold to a summary line. "show history" / "hide history", or ‹.
- **Progress** (`studio/web/progress.js`), a card just above the pill,
  there only while something said is in flight: the phrase at once with
  "understanding…" and a running clock; then what the router made of it
  ("On it: <the instruction>", "next: …" when queued, or a faint "go on…"
  for words kept as the start of a sentence); then, while the builder
  works, its latest note, what it is doing now, the last steps and the
  edits so far; at the end "done · 1m 12s · 4 edits", for a moment. On the
  canvas, where there is no code to watch yet, it is larger and the
  welcome steps aside; over code it is one line, since the edits are on
  screen.
- **The microphone** button in the pill: red while listening, with a ring
  as loud as the microphone hears, so it is plain the browser hears you;
  every recognition error is written out (blocked, no microphone, no
  network, no recognizer in this browser).
- **The bar** above the editor, faint until the mouse comes near: the
  project (its menu opens or makes others), the files as chips (one file:
  just its name), **+** for a new module, a double-click on a name to
  rename it; on the right the check (only when it fails), the properties
  badge (once there are any), and ▸ Run.
- **The output**: the REPL, floating, appears when something runs (Run,
  an evaluation, "run it") or when asked ("show the output", ⋯); ✕ or Esc
  hides it.
- **Beside a hovered form**: ▸ evaluates it; REPL opens the prompt, with
  `(f ` already typed for a function.
- **The pill**, at the foot: the microphone (red while listening) and one
  line — what is being heard, then the reply — that fades. While the
  builder works, what it is doing and a Stop. Type into it to do what
  speaking does. Behind ⋯: follow, speak aloud, undo, run the program or
  the properties, the output, the conversation, show all panes.
- **Places**, when a navigation finds more than one (a definition and its
  uses, search matches): a card of one line each, grouped by file, so an
  abstraction that spans modules reads as one picture. "next" /
  "previous" step through; it closes on Esc, "close", or when unused.
- **Properties**: the list opens by itself only when one starts failing,
  with the English statement and the counterexample.
- **Follow**: each builder edit moves the view to the changed lines and
  flashes them, unless the author moved the view in the last 8 seconds.

## 4. Properties

The spec is `properties.puf`. Each property is a form, with the English it
came from in a comment above it:

```scheme
(require "prop.puf")
(require "machine.puf")

;; @property id-id-is-lambda: the identity applied to itself evaluates to a lambda
(check-example 'id-id-is-lambda (lambda? (eval-cesk '((lambda (x) x) (lambda (y) y)))))

;; @property sort-sorted: sort-list always returns a sorted list
(check-property 'sort-sorted
  (for-all (list (gen-list gen-int)) (lambda (xs) (sorted? (sort-list xs)))))
```

`prop.puf` is the harness (`studio/src/prop.puf`, written beside the
properties by the studio): a seeded generator (Puffin has no random
primitive), generators that are functions of a size (`gen-int`,
`gen-list`, `gen-one-of`, `gen-frequency`, `gen-sized`, ...), and
`check-property`, which tries 100 cases at growing sizes so the first
counterexample found tends to be small. The studio runs the properties
1.5 s after any change settles (the author's or the builder's), and the
builder after each of its runs. A run that crashes marks the property it
was in.

## 5. Running it

The studio needs Claude API credentials in its environment for the router
and research: `ANTHROPIC_API_KEY`, or `CLAUDE_CODE_OAUTH_TOKEN` (with
`ANTHROPIC_BASE_URL` / `ANTHROPIC_CUSTOM_HEADERS` as the CLI reads them —
the deployment's `puffin-ai` broker works unchanged), and `claude` on
`PATH` for the builder. Speech recognition in Chrome sends audio to
Google's recognizer; Safari's runs on the device. The page must be served
over https (or localhost) for the microphone.

## 6. Where it touches the rest of the studio

- `studio/src/voice.rs`, `props.rs`, `prop.puf`, `claude_api.rs`;
  `studio/web/voice.js`, `voice.css` — all new.
- `studio.rs`: an `Event::Voice` variant, a `voice` field, and
  `watch_properties` started with the other watchers.
- `mcp.rs`: calls carrying `X-Studio-Voice` go to `voice_call`.
- `web.rs`: the `voice`, `voice-control` and `voice-state` requests; the
  two new assets.
- `sexp.rs`: `atoms`, every atom's span.
- `index.html` / `main.js`: the button, the stylesheet, two handlers.

## 7. Planning

The module board (signatures with bodies opaque, arranged by voice),
plan mode (bodies left as typed holes, checked and run past), and the
builder's questions with their slices are docs/PLANNING.md.

## 8. Not yet

- Navigation by binding: usages are by name (every atom spelled the
  same), not by the compiler's scopes; a local that shadows a top-level
  name counts too.
- Selecting and editing a region by voice ("wrap this in a let") goes
  through the builder; there are no deterministic structural edits by
  voice yet (paredit by voice).
- Interim speech is only shown, not routed early; the router waits for
  the recognizer to finish the phrase.
- The builder's edits and the author's typing in the same file can race
  (the later write wins; the tab is told and catches up).
- No shrinking of counterexamples beyond trying small sizes first.
