# Planning: the module board, plan mode, and questions

Status, 2026-11-19: built on the `exceptions` branch (it needs
docs/EXCEPTIONS.md: holes must check and run past). Server
`studio/src/board.rs`, page `studio/web/board.js` + `board.css`; the
voice side is the router's `arrange` / `answer` (`voice.rs`) and the
builder's tools `ask` / `arrange` and plan-mode prompt (`voice/builder.rs`).

The idea: when a program is being designed, by talking, the screen should
hold as much of the *design* as it can — and the code only where it is
needed. So the studio shows the program as module signatures with bodies
opaque, plans it with bodies left as typed holes until someone says "dive
in", rearranges itself around what just changed, and, when the builder
hits a question that matters, cuts the program down to just what that
question is about.

## 1. The board

⌘⇧B, the ▦ Board button in the bar, or "show the board" / "back to the
code". One card per module:

```
store   provides 8 of 8  ◌ 4                                  ✕
requires syntax
≡ type Addr = Int
τ type Value = Clo of Var * Expr * Env
ƒ val alloc : Store -> Addr                                   ◌
    a fresh address: deterministic, so runs are reproducible?
ƒ val store-ref : Store * Addr -> Value                       ◌
  3 hidden
```

- **Signatures, ML-style**, from the code: a function's `(: f τ)`
  declaration (`(-> A B C)` reads `A * B -> C`), else its parameters'
  annotations and result type, an untyped parameter shown by its name
  (`val run : e -> _`); `define-type` as `type T = C of A * B | D`;
  aliases and grammars likewise. The comment right above a definition
  shows under it. `◌` marks a body that is only a hole (planned, not
  written); `◌N` a body with N holes.
- **Opaque until asked.** Click a row: its body opens in place
  (colorized), click again to fold. ↗ edits it in the editor; ✕ hides
  the row on its card ("N hidden" brings them back for a look).
- **What a card shows is kept.** Open and hidden rows, and where each
  card sits, are the board's state (`.puffin/board.json`, committed with
  the project), so a card comes back exactly as it was left.
- **Bringing modules out.** Drag a file chip from the bar onto the board
  (or click it while the board shows); ✕ on a card puts it away. A board
  with nothing out lays out every module, in dependency order (a module
  right of what it requires), packed in shelves across the width. Dashed
  wires run from a card to the cards it requires.
- **The spec is a card too.** `properties.puf` shows one row per
  property — its English, and its status from the last run (✓ ✗ !, and
  ◌ for *open*: it reaches a hole, §3).

## 2. Arranging by voice

The router (`voice.rs`) has an `arrange` intent, executed by the studio
itself (`Studio::arrange`, board.rs) — instant, deterministic, no builder:

| said | action |
|---|---|
| "show me the board", "back to the code" | show-board / show-editor |
| "plan mode", "build mode" | plan-mode / build-mode (also local in the tab) |
| "open step", "fold alloc" | open / close |
| "hide the helpers fresh and biggest", "unhide fresh" | hide / unhide |
| "just show step and inject" | only |
| "what does step depend on", "what touches alloc" | slice (§4) |
| "show everything" | clear |
| "bring out the store", "put the syntax away" | bring / put-away |
| "put machine to the right of store" | place |

Opening or unhiding something *pins* it: the automatic hiding (below)
never folds what the author asked for. The builder has the same verbs as
an `arrange` tool, to put what it is talking about in front of the
author.

**Hiding as much as possible.** When a builder turn ends, the board
arranges itself around the edits (`Studio::auto_arrange`): the modules it
touched come out; on each, the definitions it changed and what they use
directly stay, the module's interface (its provides) stays, pinned rows
stay, and the rest of its internals fold into "N hidden" (a card with
five definitions or fewer is left alone). In build mode the bodies just
written open (the last three); in plan mode bodies stay folded — the
signatures are the design.

## 3. Plan mode

The "Plan" toggle in the bar, or "plan mode". The builder's prompt then
says: write the design, not the code — modules with provide lists, data
definitions, a typed signature for every function, and its body a single
typed hole:

```scheme
(: alloc (-> Store Addr))
(define (alloc s) ??)
```

A body is written only when the author says to dive in, implement or
fill in a definition — that one alone. This works because holes no
longer stop anything (docs/EXCEPTIONS.md):

- **The check checks past holes.** Each `??` is replaced, for the
  checker, by `(error "??")` — an expression of any type — so the whole
  plan is type-checked, and positions are mapped back
  (`sexp::stub_holes`, `Toolchain::check`). A program whose only
  shortfall is holes reports one "hole" and passes, holes aside (the
  bar: "◌ 7 holes · the rest checks").
- **Properties run past holes.** The same stubs raise `??` if reached;
  each property runs inside the harness's `prop-guard` (properties.puf is
  rewritten for the run, never on disk), so a property that reaches an
  unwritten definition is **open** — undecided, not failing, not sent
  back to the builder to "fix" — and one that crashes is **crashed** with
  its message, while the others still run.

## 4. Questions and the slice

When a design decision matters and the builder cannot settle it, it
calls `ask` with the question and the definitions it is about:

```
ask { question: "Should alloc be deterministic, so two runs give the same addresses?",
      about: ["alloc"], why: "properties that compare final states depend on it" }
```

The studio computes the **slice** (`board::slice`): the definitions
asked about; what they use (their signatures are the context); what uses
them (the callers that constrain them), one step out each way; and the
properties that mention them. The board switches to the question: the
question card on top, and below it *only* the cards holding the slice,
packed in dependency order, each showing only its slice rows ("5 not in
focus"). The author's own layout is untouched and returns when the focus
clears (✕, Esc, or "show everything"). The question is said aloud.

The author answers by speaking (the router's `answer` intent matches the
words to the open question and resolves "yes" or "the second one" against
it) or by typing into the card. The question is marked answered, the
focus clears, and the builder is told to record the decision: as a
property (`add_property`) when it says what must hold, in the types and
signatures when it says how things are built. Answering questions is how
the spec grows; the questions and their answers stay in `board.json`.

## 5. Notes: decisions and comments on the design

Before any code is written, the author can attach notes to any part of
the design: ✎ on a row (or `n`) for a definition, ✎ on a card's title for
a whole module. A note is as long as it needs to be (it keeps its line
breaks) and stays under what it is about, with a ✎N count on the row:

- **Decision** — binding. Every builder run gets the decisions in its
  prompt as rules to build to and keep true (`board::describe_notes`), so
  in plan mode the signatures it writes honor them.
- **Comment** — context for whoever builds it.
- **Ask the builder** — sent to the builder at once, about its place
  (through the router, like a spoken instruction), and kept as a note.

By voice the router's `arrange` takes `note` and `decide` with the words
in `text`: "decide on alloc: it hands out the next unused integer", "a
note on the store module: this will need a collector later". The builder
can leave comments too (`arrange` `note`, marked "from the builder").

The **decisions card** is the spec ledger: the author's decisions and
the builder's questions — open (?) or decided (✓, with the answer) — one
row each. Like every row it has the lens: hover a decision and wires run
to the definitions it governs. Clicking one puts its slice in front of
you again (an open question comes back with its answer box). It comes out
by itself when the first decision or question arrives; ✕ puts it away.

**Designing on the board.** Under each module's rows, "+ plan a
definition" takes a signature in the board's own ML style and plans it
in the module (`Studio::board_define`, `board::define_from_signature`),
its body a typed hole, the provide list kept current:

| typed | written |
|---|---|
| `val alloc : Store -> Addr` | `(: alloc (-> Store Addr))` `(define (alloc store) ??)` |
| `step : State * Kont -> State` | parameters named after their types: `(step state kont)` |
| `fresh : unit -> Addr` | `(define (fresh) ??)` |
| `val limit : Int` | `(: limit Int)` `(define limit ??)` |
| `type Kont = Done \| Arg of Expr * Env` | `(define-type Kont (Done) (Arg Expr Env))` |
| `type Env = Hash Var Addr` | `(define-type-alias Env (Hash Var Addr))` |

So a design can be sketched, annotated and decided entirely on the board
— checked as it grows, since holes are checked past — before anyone (the
builder, or the author) writes a body.

## 6. Reading the board

- **The lens.** Hover a row (or move the keyboard's cursor to it): wires
  run to everything it uses (blue) and from everything that uses it
  (violet, dashed), across cards; the module wiring dims.
- **The HUD** (top left): modules, types, definitions written / partly
  written / planned (with a bar), the properties' state, plan mode; a
  filter (start typing anywhere on the board, or /; ↵ makes the matches a
  focus) and the zoom (− 100% +, 0 fits, ⌘/ctrl-wheel).
- **Keys.** ↑↓ (j k) rows, ←→ cards, ↵ open or fold, n note, h hide, f
  focus on a definition and what touches it, e edit, t tidy, Esc clears.
- **Liveness.** Rows the builder just wrote or changed glow for a moment;
  cards glide between layouts; a card that grows pushes the ones below it
  down as shown (the saved places are unchanged); clicking a planned
  row's ◌ opens the editor with its hole selected.
- **Tidy** (t, or ⌘K) re-packs the cards for the window at hand. Narrower
  than 700px (a phone) the board stacks its cards in one column.
- **⌘K** finds any command, file or definition (⇧↵: a definition's slice
  on the board). The studio follows the system's light or dark (Solarized
  dark), or the palette's Theme command.

## 7. Not yet

- A slice is one step out each way, by name (the outline's `uses` is
  every top-level name a definition mentions, so a shadowing local
  counts). Transitive or type-directed slices would cut finer.
- The builder chooses what to ask; nothing yet ranks questions or keeps
  more than the current one in focus.
- Cards do not move when the code moves (a renamed module comes back as
  a new card; the old one is dropped when its file is gone from the
  outline).
- Not tested end to end here against the live router and builder (no
  API credentials for the local test studio); the arrange executor, the
  automatic hiding, `ask` and the slice are tested directly
  (studio/src/tests.rs, board.rs).
