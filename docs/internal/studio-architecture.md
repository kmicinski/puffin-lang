# Puffin Studio: how the server is put together

Internal notes for working on `studio/src/`. What the studio *does* is
docs/STUDIO.md (the REPL, assists, observations, the assistant),
docs/VOICE.md (voice mode, excursions, properties), docs/PLANNING.md
(the module board) and docs/VIEW.md (the code view the page is built
around). This is the map of the code that does it: which file
holds what, and how a keystroke, an evaluation, a question or a spoken
phrase travels through it.

## The shape of it

```
 browser tab(s)                    puffin-studio (one process, one project)
 ─────────────                     ─────────────────────────────────────────
 studio/web/*.js  ── /ws ──────▶  web.rs ── Request ──▶ Studio (studio.rs)
                  ◀─ Event / Reply ─┘                       │
                                                            ├─ toolchain.rs ─▶ puffincc  (one process a request)
                                                            ├─ lane.rs ──────▶ puffin-vm --serve  (the live session)
                                                            ├─ agent.rs ┐
                                                            ├─ voice/builder.rs ┴─ claude_cli.rs ─▶ claude -p
                                                            │                        │
                                                            │      /mcp ◀────────────┘ (its only tools)
                                                            │       mcp.rs
                                                            └─ claude_api.rs ─▶ Messages API (router, explainer, research)
```

- **One `Studio` per open project** (studio.rs). It owns the text of every
  file, the transcript, the review, the board, the voice state, and a
  broadcast channel of `Event`s. Every open tab subscribes to it; nothing
  a tab sees comes from anywhere else. Opening another project makes a new
  `Studio` (web.rs `Web::switch`) and tells the tabs to reload.
- **Tabs talk over one WebSocket** (web.rs). A tab sends `Request`s (JSON,
  tagged `t`, kebab-case); the server answers that tab alone with a `Reply`
  when there is something only it asked for (an assist menu, a hover), and
  everything that changes shared state goes out to every tab as an `Event`.
  Requests that run a process are spawned as their own task, so the same
  tab can still interrupt them.
- **The compiler and VM are black boxes**, run as processes and probed for
  what they can do (toolchain.rs). The compiler runs once per request over
  a scratch copy of the program; the live session is one long-lived VM
  (lane.rs).
- **Agents are MCP clients of this same server.** The assistant (agent.rs)
  and the voice builder (voice/builder.rs) are `claude -p` runs
  (claude_cli.rs) whose only tools are the studio's `/mcp` (mcp.rs), with a
  bearer token and a header saying whom the call is for: a thread id (the
  assistant: writes become proposals, review.rs) or the voice header (the
  builder: writes apply at once). The quick one-request calls -- routing an
  utterance, explaining a fragment, researching a source -- go straight to
  the Messages API (claude_api.rs).

Offsets: the server works in **byte offsets**; the editor counts **UTF-16
units**. Conversion happens at the edge -- web.rs (`point`,
`edits_in_utf16`) and holes.rs -- and nowhere else.

## The files

| File | Its one responsibility |
| --- | --- |
| `main.rs` | The command line: pick the project, listen (TCP or a Unix socket), serve. |
| `lib.rs` | The module list, and three small helpers (the MCP token, the repository root, an operator `setting`). |
| `web.rs` | HTTP and the WebSocket: the page and assets, `Request` → `Studio` method, `Reply`, the `/mcp` route. |
| `studio.rs` | The open project: files' texts and versions, edits, the checks after edits pause, the transcript, the views tabs are sent. |
| `studio/files.rs` | Files and folders on disk: make, move (pointing `require`s anew), delete, save, the scan, the disk watch. |
| `studio/journal.rs` | The project's history as committed: records of what happened, the settle-then-commit loop, the timeline. |
| `project.rs` | Projects under the home, and git: adopt, commit, log, diff, files at a commit. |
| `versions.rs` | Each file's in-memory versions (the Versions panel), and which forms an edit changed. |
| `toolchain.rs` | Running puffincc: the probes, the check (holes stubbed and checked past), assists, the live and preview lanes' compiles, whole-program runs. |
| `sexp.rs` | Puffin text as forms, the way puffincc's reader sees it: spans, names, requires, holes, constructors, offsets. |
| `lane.rs` | The live session: `puffin-vm --serve` (or a replaying fallback), its framed output, interrupt and reset. |
| `repl.rs` | Evaluating in the live session: units from the prompt, a buffer or a file, their compile and run, the observation record. |
| `session.rs` | What the live session holds of the program, form by form, and the observation record's reader. |
| `holes.rs` | Typed holes with their goals, and the observation lint, kept per file. |
| `facts.rs` | Everything known at a point, layer by layer (the hover, the Facts panel, `facts_at`). |
| `trace.rs` | `,trace` / `,untrace`, and the assistant's one-off `trace`. |
| `pin.rs` | Pinned tests in `tests.puf`, and `,test`. |
| `props.rs` | Properties (`properties.puf` + the `prop.puf` harness) and their runs. |
| `review.rs` | Proposals: threads, changesets, ops, scopes, forks; applying a change. |
| `ask.rs` | The assistant's side in the studio: asking, a question's scope and preamble, the proposal and accept gates. |
| `agent.rs` | The assistant's runs: what they are told, and their stream as a thread's transcript. |
| `claude_cli.rs` | Running `claude -p`: the MCP config file, the flags, its stream-json taken apart into `Part`s, stopping it. |
| `claude_api.rs` | Direct Messages API calls: credentials, structured output, server-side web research. |
| `mcp.rs` | `POST /mcp`: JSON-RPC, the assistant's tools and their dispatch; the plumbing the builder's tools share. |
| `knowledge.rs` | What agents know of Puffin: the reference in their system prompt, `search_docs`, `read_doc`. |
| `voice.rs` | Voice mode's state and events, hearing a phrase, the controls, and the router. |
| `voice/builder.rs` | The voice builder: its runs, its stream, its tools, its questions to the author, the properties it is held to. |
| `voice/places.rs` | Places navigation moves the view to: definitions by spoken name, uses, lines, files, text. |
| `excursion.rs` | Excursions: explaining fragments of the program by voice, pulling in more as they go. |
| `board.rs` | The module board: the outline (ML-style signatures), the board's view state (cards, the working set `set`, the camera request `look`), arrangements, the slicer. |
| `tests.rs` | End-to-end tests over the real compiler and VM (skipped when they are not built; set `PUFFIN_ROOT` to a checkout that has them). |

## The page (studio/web)

Plain ES modules, no build step: the server bundles every file named in
web.rs's `assets!` list (a new file goes there too) and serves it under
`/static/`; `PUFFIN_STUDIO_WEB=<dir>` serves a directory's copies instead,
for editing without rebuilding. Monaco comes from the repository's
`web/node_modules` (`/vs/...`).

`main.js` makes every panel with a `create*` function, handing each the
few things it needs (the editor, the files, `send`, the DOM nodes it
owns, and the other panels it works with), and routes each message from
the socket by its `t` to a panel's `receive` table: message kinds to
handlers. What a panel offers the others it returns. Voice mode is the
one panel made of panels: voice.js makes its own timeline, progress card
and excursion.

The house helpers, used rather than written again:

- `dom.js`: `el(tag, className, text)` for every element, `button(className,
  text, onClick, title)`, `nameField(className, placeholder)` for a field
  the browser must not spell-check, and `debounce(fn, ms)` for "after the
  typing pauses".
- `words.js`: what more than one panel says -- `plural(n, noun)`,
  `timeOfDay(at)`, `dateOf(at)`, a builder run's `turnLabel` and
  `outcomeWord`.
- `requests.js`: a question to the studio answered by `seq`
  (`requests(files).ask(message)` → a promise of the reply).
- `stored.js`: `recall`, `recallJSON` and `remember` for what the browser
  keeps between visits (localStorage, which a private window may refuse).
- `markdown.js`'s `escape` and `highlight` for any HTML made from text.
- The tokens of Solarized light and dark are defined once, at the top of
  studio.css, each as `light-dark(light, dark)`; the other style sheets
  only use them.

| File | Its one responsibility |
| --- | --- |
| `index.html` | The page's skeleton: header, editor pane, output pane; loads the style sheets, Monaco's loader and main.js. |
| `main.js` | Wiring: makes the panels, owns the socket, routes messages, the header's buttons, the check pill, the palette's commands. |
| `dom.js` | Building elements, buttons and name fields; `debounce`. |
| `words.js` | Counts, times of day and dates, and the builder's runs, said one way. |
| `requests.js` | A request answered by `seq`, behind the edits in flight. |
| `stored.js` | What the browser remembers between visits. |
| `editor.js` | The program editor: Monaco (or a textarea) behind one small interface, the Puffin language definition and Solarized themes. |
| `files.js` | The project's files in this tab: the tabs, each file's text and version, the one edit in flight that every `send` waits behind. |
| `tree.js` | The files as a tree: folders, new / rename / delete typed in place, drag to move, `,open`'s quick open. |
| `projects.js` | The menu under the project's name: open another project, make a new one. |
| `lexer.js` | puffincc's token rules: comments, strings, brackets, prefixes; top-level forms and balance. |
| `sexp.js` | Text as S-expressions, and paredit's operations as pure functions over text and selection. |
| `paredit.js` | Those operations bound to keys, in Monaco and in textareas; structured typing on or off. |
| `emacs.js` | Emacs keys and a kill ring in the editor. |
| `tex.js` | `\lambda` ⌥↵ → λ, in the editor and the prompt. |
| `repl.js` | The transcript and the prompt: evaluation, the `,` commands, pins and test runs, prompt history. |
| `trace.js` | A traced run's output as a call tree. |
| `session.js` | What the live session holds, form by form: the gutter's dots and trace marks, `,session`. |
| `holes.js` | Typed holes: outlines, goals, F8 between them. |
| `lint.js` | The observation lint's markers. |
| `assists.js` | The compiler's assists: the ⌘. menu, the lightbulb, the hover's facts, match completions. |
| `rename.js` | F2: renaming the name at the cursor through the compiler. |
| `assist.js` | The assistant at the prompt: ask mode, threads, answers streamed into the transcript with their chips. |
| `markdown.js` | The assistant's Markdown, as escaped HTML; Puffin code coloured as the editor colours it. |
| `hunks.js` | Pure: line diffs, hunks, and proposals placed on a file's text. |
| `inline-diff.js` | Hunks drawn in Monaco: removed lines tinted, added ones as ghost lines. |
| `proposals.js` | The assistant's proposals reviewed in place: the bar, each change's Accept and Reject, the transcript's chip. |
| `versions.js` | The shown file's versions: compare and restore. |
| `history.js` | The project's history from git: every moment, filtered, with diffs and outputs. |
| `replay.js` | The clock and its slider: the files and transcript as they were at a moment. |
| `gist.js` | The Gist button: the files as a GitHub gist, from the browser. |
| `palette.js` | ⌘K: every command and definition, matched by letters in order. |
| `focus.js` | The focused layout: the editor alone and centered, everything else floating in when used; the empty canvas. |
| `board.js` | The module board: modules as signature cards, the lens, plan mode. |
| `voice.js` | Voice mode: listening, the pill, the caption, places found, properties, and the studio's voice events. |
| `progress.js` | The card over the pill: was it heard, and what the builder is doing. |
| `timeline.js` | What happened: the voice session's exchanges and builder runs, step by step. |
| `excursion.js` | An excursion's card: the fragments being explained and the questions about them. |
| `attention.js` | The attention model: which definitions to show and how much of each (pure; tested in node). |
| `attention-studio.js` | The socket's messages folded into the attention model's state. |
| `attention.html` | The attention model's demo page: a project's definitions, what the model would show, its weights. |
| `studio.css` | The tokens (light and dark), the chrome, the editor pane, the transcript, the panels. |
| `diff.css` | Proposals and diffs: the bar, the inline hunks, the chips. |
| `assist.css` | Ask mode, answers, the assists menu. |
| `voice.css` | Voice mode, the focused layout's floats, the timeline, progress, excursions. |
| `board.css` | The module board. |

## How things travel

**An edit.** The tab sends `edit` with the whole text and the version it
edited (`Studio::edit`); a stale base is refused with the current text.
The new text goes to the other tabs as `Event::Text`, the file is marked
for checking, and the journal is woken. About 400 ms after edits pause
(`watch_edits`) the edited files and every program that requires them are
checked (`check_files` → `Toolchain::check`), and `Diagnostics`, `Holes`
and `Lint` events follow. Once edits settle the journal saves and commits
(studio/journal.rs).

**An evaluation.** `eval` / `eval-form` → repl.rs: the text becomes a
*unit* (with the session's types ahead of it, and for a form the
definitions it needs that the session lacks), compiled for the session
(observing, traced) and run in the lane. Output streams to the transcript
entry as `EntryOut`; `EntryDone` ends it, and on success the session view
(`Event::Session`) and, a moment later, the observation record are
refreshed.

**A question to the assistant.** `ask` → ask.rs works out the scope and
the preamble, opens a changeset on the thread, and starts `agent::run`.
The run reads and checks through `/mcp`; `propose_edit` and
`apply_assist` become ops in review.rs only if the thread's program as
they leave it passes the check and stays in scope. Progress is
`Event::Agent`; proposals are `Event::Review`, with each op's acceptance
kept current in the background (`watch_proposals`). Accepting applies the
ops (and the earlier ones they build on) through `Studio::replace`.

**A spoken phrase.** `voice` → `Studio::hear`: the router
(`route`, one structured Messages API call) decides what the words are
for, and `act` does each part at once -- `navigate` (voice/places.rs),
`arrange` and `answer` (board.rs), `explain` (excursion.rs), a control, or
an instruction for the builder, which queues behind or interrupts its run
(voice/builder.rs `instruct` → `drive` → `build`). The builder's edits land
at once (`land`), each checked and shown as `Event::Voice`; when a run
ends the properties run, and failing ones send it back.

## The page's code view

The page (`studio/web/`, plain modules, no build step) is laid out
around one code view (docs/VIEW.md). Its pieces, so a change lands in
one place:

| file | holds |
|---|---|
| `view.js` | the focus (the main editor narrowed to a definition), the working set and its ranking, the lane's fragments, the wires across the panes, what is told to the attention model |
| `neighbourhood.js` | under the focus: what uses it, what it uses, its properties and module, as key stops |
| `board.js` | the board: module cards and rows (`renderItem`), notes, decisions, questions, plan mode, the HUD, the lens; the lane's place on it; the camera's `home` (the code) and `overview` (the program) |
| `camera.js` | the board's pan and zoom, and its glides |
| `fragment.js` · `span.js` · `names.js` · `wires.js` | a live view of one definition · a definition's lines and narrowing a view to them · cross-references and ⌘-click · the curves |
| `attention.js` · `attention-studio.js` | the attention model (docs/ATTENTION.md) and its view of the socket's messages |
| `editor.js` · `files.js` | one Monaco model per file, any number of views of it; edits from any view to the studio |

The working set and the camera requests are the board's state
(`board.json`'s `set` and `look`), so `Studio::arrange` can change them
by voice; the focus and its history are each tab's own.

## Adding to it

- **A request from the page:** a `Request` variant in web.rs and its arm
  in `handle`; a reply only that tab needs is a `Reply` variant, anything
  shared an `Event` variant in studio.rs. Keep JSON names kebab-case tags
  with snake_case fields, as the existing ones are.
- **A tool for the assistant:** its schema in `mcp::tools` (with `tool`),
  its arm in `mcp::call`. For the voice builder, `builder::tools` and
  `voice_call`; a read the builder should share is listed in
  `builder::tools`' `READS`.
- **A compiler feature:** a `Probe` in `Toolchain`, an `*_available` that
  calls `probe_puffincc` with a one-file program, and, if the page should
  know, a field of `Features`.
- **Something that waits for things to settle:** a `watch_*` started from
  `Studio::start`, holding a `Weak` to the studio where it can, so it
  ends with it.
- **An agent run:** build a `claude_cli::Run` (with an `McpConfig` naming
  whom its calls are for) and read its stream; its system prompt is
  `knowledge::system_prompt(root, ROLE)`, fixed per role so its cache holds.
