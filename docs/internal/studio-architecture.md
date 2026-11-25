# Puffin Studio: how the server is put together

Internal notes for working on `studio/src/`. What the studio *does* is
docs/STUDIO.md (the REPL, assists, observations, the assistant),
docs/VOICE.md (voice mode, excursions, properties) and docs/PLANNING.md
(the module board). This is the map of the code that does it: which file
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
| `board.rs` | The module board: the outline (ML-style signatures), the board's view state, arrangements, the slicer. |
| `tests.rs` | End-to-end tests over the real compiler and VM (skipped when they are not built; set `PUFFIN_ROOT` to a checkout that has them). |

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
