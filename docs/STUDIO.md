# Puffin Studio: a REPL you co-develop a program with

Status, 2026-10-29: the design of record, M0-M2 built and M3
under way. Run it with `bin/puffin-studio [PROJECT_DIR]` (default
port 7360; it prints the URL to open; `studio/demo/` is a short
tour). Built: the span reader (`puffincc-src/syntax.puf`);
`puffincc --assist` with `check`, `forms`, `type-at`, `facts`,
`lint`, and assists 1 to 9 (`assist.puf`; 7 for layers 1 and 4);
`--repl --observe` and the session observer (§3.1); the assist
corpus; `puffin-vm --serve`; the Emacs commands `puffin-assist`
(C-c C-a) and `puffin-type-at-point` (C-c C-t); and the studio
(`studio/`, Rust + vanilla JS): editor with structured editing, live
checks, the assist menu, the live REPL lane, ask mode with checked
proposals, and per-file versions. §9 lists where the studio differs
from this design.

Puffin Studio replaces the console REPL (`src/repl.rkt`, the Racket
interpreter loop) with a local web workbench: an editor over the
program's modules, a REPL transcript backed by a live VM session,
compiler-driven intelligent edits, and an assistant mode one key
away. The interaction model follows Slog Studio
(`../slog/studio`); the semantics all live in puffincc.

## 1. Principles

These are Slog's (`../slog/docs/repl-ux.md`), kept unchanged where
they apply.

- **Every gesture is a command.** A key or click performs a command
  a person could type, and the transcript echoes it. Transcripts are
  replayable scripts.
- **The compiler is the only source of meaning.** The client parses
  s-expressions for paredit and highlighting only. Types, scopes,
  constructor sets, and generated code come from puffincc.
- **Nothing an agent writes reaches the program by fiat.** The
  assistant proposes; you accept. A proposal that fails the check
  cannot be accepted.
- **Agents never mutate your session.** The assistant evaluates on a
  preview session. Its reads of the live session are allowlisted.
- **Deterministic edits beat generated ones.** When the compiler can
  produce the code (match clauses, templates, stubs), it does, and
  the assistant calls the same operation as a tool instead of
  writing it.
- **Say where a suggestion came from.** A clause from an ADT is
  certain; one from observed values is "seen so far"; one from flow
  analysis over-approximates. The UI and the assistant both see the
  label.

## 2. Processes

One local server, written in Rust (adapted from Slog Studio's
`studio/src`), owns the program text and runs four lanes. A lane is
a process plus its serialized request queue.

| Lane | Process | Role |
|---|---|---|
| live | `puffin-vm` session | Your REPL state. Units from the transcript and from eval-from-buffer load here. |
| assist | `puffincc --assist`, one process per request | Check, forms, types at a point, and every intelligent edit. |
| preview | a throwaway `puffin-vm` session | Evaluating assistant proposals and what-if forks. |
| analysis | `puffincc --assist`, background | Slow whole-program layers (flow shapes). Cancellable; never on the keystroke path. |

The browser talks to the server over one WebSocket. The editor is
Monaco (from `web/`), with Slog Studio's paredit, inline-diff, and
proposal components ported over.

The live lane is a VM session in the existing sense
(docs/WASM-VM.md §5.2): each eval compiles as one `--repl` unit, its
top-level defines bind named cells, and redefinition is retroactive.
Eval-from-buffer sends a form from a module to the same session.

### 2.1 `puffincc --assist`

Puffin has no exception handling: a reader error or a type error
calls `error`, which exits the process. A long-running server would
die on the first half-typed buffer. So the assist lane runs one
puffincc process per request, and a fatal error becomes an error
reply. This is cheap: reading, resolving, checking, and desugaring
a 1,000-line module takes about 50 ms natively (`build/puffincc`,
`puffincc-src/types.puf`), and a one-line file about 13 ms.

The server writes the program's files to a scratch directory and
runs one operation; puffincc prints one JSON object on stdout and
exits 0. A fatal error (reader, resolver, type error) instead prints
puffincc's usual `error: ...` text and exits non-zero; its
`[file:line]` suffix locates it. Typecheck warnings go to stderr as
`typecheck warning: ... [file:line]`. Positions are byte offsets
into the file.

```
puffincc --assist check FILE
  -> {"ok":true}
puffincc --assist forms FILE
  -> {"forms":[{"key":"define:eval-expr","start":0,"end":212,"line":3}, ...]}
puffincc --assist type-at FILE POS
  -> {"type":"Expr"}  |  {"type":null}
puffincc --assist assists FILE POS
  -> one JSON object per line, each an assist:
     {"id":"fill-match","title":"Fill match on Expr","source":"type",
      "edits":[{"start":40,"end":40,"text":"..."}]}
     ...
     {"done":true}
```

`assists` prints every assist that applies at POS with its edits
already computed, so the client shows a menu and applies one
without a second round trip. It prints them as it finds them: a
type error elsewhere in the file can stop the checker part way, and
the assists already printed stand (the error text follows; a client
ignores stdout lines that are not JSON). `source` says where the
knowledge came from: `type` (the checker), `observed` (the live
session, §3.1), `patterns` (other matches and quasiquote templates in
the file), `call-site`, or `syntax`. The studio lists them in that
order.

### 2.2 `puffin-vm --serve`

The live and preview lanes are VM sessions that must survive a
runtime error, which today calls `exit`. `--serve` forks per
evaluation: the child runs the unit; if it fails or is interrupted
the parent is still the intact session, and if it succeeds the
child carries on as the session and the parent exits. The process
group is fixed at startup (`setpgid(0, 0)`), so the server
interrupts with SIGINT to the group; the waiting session ignores
it. The server watches its pipes, not the pid, since the pid it
spawned exits after the first successful evaluation.

Commands, one per line on stdin:

```
load PATH     run a .pbc unit (v1 or v2) as the next session state
try PATH      run it against the current state, then discard the result
quit
```

Blank lines are ignored; `PATH` is everything after the first
space; a trailing `\r` is stripped; end of input exits.

Program output passes through on stdout and stderr. In serve mode
each REPL result is one stdout line `\x1fR` + the rendered value,
with any newline inside the value written as `\x1e` so the result
stays one line. Every command ends with exactly one stdout line,
after all of that evaluation's output:

- `\x1fOK`
- `\x1fERR <n>`: the evaluation exited with status n (1 for
  `error`, 255 for a runtime fault or a malformed unit; 2 for an
  unknown command or an unreadable path, with a message on stderr)
- `\x1fERR signal <n>`: killed by a signal other than SIGINT
- `\x1fINT`: interrupted

A marker always starts a line: when program output left a partial
line, serve mode writes a newline first, so a client can look for
`\x1f` at line starts. Units cannot read the command stream: their
stdin is `/dev/null`. Fork is sound because the process is single
threaded (the bundled Boehm GC is built without threads); a foreign
library that starts threads would break that.

REPL units compile with `puffincc --repl IN.puf -o OUT.pbc` (about
6 ms natively); the prelude unit with `puffincc --repl-prelude -o
OUT.pbc`. Each unit is checked alone, so a later unit does not know
an earlier unit's `define-type`: the server keeps the session's
type declarations and prepends them to each unit it compiles.

Every assist returns plain text edits (§4), never a new AST. This
requires a **span-preserving reader**: today only each top-level
form's line survives reading, and the assist lane needs byte spans
for every node so it can find the form at the cursor and replace
it. Assists need a balanced buffer; the editor's structured
(paredit) mode keeps it balanced while you type.

**Types at a point** come from a probe, not from threading spans
through the checker. The assist lane wraps the target expression in
an internal `(#%probe k e)` form, runs the checker over the module,
and reads back the type and environment it recorded for `k`. Typed
holes use the same mechanism with `(#%hole k)`.

## 3. Incremental analysis layers

Assists ask a fact store what is known at a point. Analyses push
facts into it as they finish, so an assist gets more specific as
better facts arrive. Facts are keyed by top-level form (its
`forms` key and content hash) and invalidated by dependency.

| Layer | Source | When | Contributes |
|---|---|---|---|
| 0 | span reader | every edit | structure; the enclosing `match`; binders in scope |
| 1 | resolver | per form | constructors, functions, imports |
| 2 | type checker | per form | scrutinee types; ADT constructor sets; field types |
| 3 | flow analysis (`aam.puf` with a shape domain) | whole program, background | shapes reaching an untyped scrutinee |
| 4 | live session observations | as you evaluate | values that actually reached a parameter or scrutinee |
| 5 | assistant | on request | names, intent, what no analysis can see |

Facts are relation-shaped, for example `type-at(point, τ)` and
`shape-at(point, pattern, source)`, so a later move of the heavy
layers to Slog changes the engine, not the design.

Layer 4 requires an observing compile mode for REPL units: function
entry records a bounded sample of argument shapes into a side table
the server can query. That touches `--repl` compilation, which both
compiler sources implement identically, so the Racket side moves in
lockstep.

### 3.1 Observations (layer 4)

`puffincc --repl --observe IN -o OUT` compiles a REPL unit whose
top-level fixed-arity function defines report their arguments on
entry: `(define (f a b) body ...)` runs `(#%observe 'f (list a b))`
first. The observer (`studio/observe.puf`, loaded once right after
the prelude) keeps, per function, a call count and per argument the
distinct depth-one shapes it received (at most 16):

```
Int Str Bool Void Nil Vec Hash Set Proc Pair Other
(sym S)        the symbol S
(list H N)     a proper list headed by the symbol H, N long (#f: long)
(adt C)        an instance of constructor C
```

`try` of a unit holding `(#%observations)` prints the whole record
as one result, `((f CALLS ((shape ...) ...)) ...)`. The studio keeps
it in a file and passes `--observed FILE` to `puffincc --assist`, so
the compiler, not the client, turns shapes into code:

```
puffincc --assist assists FILE POS --observed OBS
  -> also fill-match / add-missing-cases with "source":"observed"
     (cases from the shapes a parameter received), and
     "annotate" (insert (: f τ) from the observed argument types)
puffincc --assist lint FILE --observed OBS
  -> one JSON object per line, then {"done":true}: each match with no
     catch-all clause whose parameter the session saw take a shape no
     clause handles -- {"start","end","line","source":"observed",
     "message":"e was seen as lam, Sym in this session, and no clause
     matches it"}
puffincc --assist facts FILE POS [--observed OBS]
  -> {"type":"Expr"|null,
      "observed":null | {"function":"f","param":"e","index":0,
                         "calls":12,"shapes":["(list add 3)", ...],
                         "patterns":["`(add ,a ,b)", ...]}}
```

Observing costs a shape computation per call (a list walk is
bounded at 16 elements), and observed calls are not tail calls of
the observer, but the function body keeps its own tail position.

## 4. Edits

There is one edit representation for people, assists, and the
assistant: `{file, old, new, note}`, anchored by exact text (`old`
must occur exactly once in `file`), as in Slog's `review.rs`.
Anchors need no positions, so unrelated edits elsewhere leave a
proposal applicable.

- **Your edits** are whole-file text with a base version; the server
  refuses an edit against a superseded version.
- **Assist edits** are your gestures. They apply immediately and are
  undoable like typing. The transcript echoes them as commands
  (`fill-match main.puf:812`).
- **Assistant edits** are proposals. They stay out of the text until
  accepted and are drawn as inline hunks with Accept and Reject.
  Each one is checked by the assist lane against the program as the
  change would leave it, across every module.

The assistant works at four scopes: a selection, a form, a module,
or the whole program. The scope is enforced by the server: a
selection-scoped proposal that touches text outside the selection
is refused.

Accepting records a version. Versions form a graph keyed by which
forms changed (`main.puf:define:eval-expr`), so restoring is a new
version, never a rewrite of history.

## 5. Intelligent edits

Each is an assist-lane operation, a keybinding, a typed command, and
an assistant tool. In planned order:

1. **Match from type.** List the constructors in declaration order,
   with binders named from field types (`n` for `Int`, `e1 e2` for
   two `Expr` fields).
2. **Add missing cases.** The exhaustiveness check
   (`puffincc-src/types.puf`, `check-match-exhaustiveness`) already
   computes them; this turns the warning into an edit.
3. **Case-split a binder.** On `a` in `[(Add a b) ...]`, replace the
   clause with one clause per constructor of `a`'s type.
4. **Structural-recursion template.** A `define` over an ADT whose
   body is a match with recursive calls placed on recursive fields.
5. **Stub an unbound function** from a call site, with its arity and
   argument names taken from the call.
6. **Typed holes.** `??` marks a missing expression. Built: at a
   hole, the goal type comes from where it sits (an operator's
   formal, or the function's declared result through tail
   positions), and the assist offers the locals that fit it (exact
   types first), the recursive call when the goal is the function's
   own result, and, for an ADT goal, each constructor applied to new
   holes. Outside assists `??` is an unbound name, so a program with
   a hole does not compile.
7. **Matches for untyped data**, from quasiquote patterns already
   used on the same value (layer 1), flow shapes (layer 3), and
   observed values (layer 4), each labelled with its source. Built
   for layer 1: a match whose scrutinee is not an ADT is offered the
   cases of the file's other matches that share a case with it (or
   all of them, when it is empty), and the shapes of the quasiquote
   templates the file builds. Clause patterns are copied verbatim, so
   binder names and ellipses survive.
8. **Identity traversal.** For an ADT or a family of quasiquote
   patterns, the pass that rebuilds every case unchanged, ready to
   change one. Built for ADTs (`traversal`, offered in a define-type
   next to the template).
9. **Insert `(: f τ)`** from synthesized or observed types. Built
   from observations (`annotate`): each argument's type is the one
   all its observed shapes share (constructors resolve to their
   type), else `_`; the result stays `_`.
10. **Pin a transcript entry as a test.**

Built beyond the list: `extract` (with a selection, `assists FILE
POS END`: the selection becomes a new top-level function whose
parameters are its free locals, in order of first mention), and
`did-you-mean` (on a name nothing binds: the closest names in scope
and the surface prims, by edit distance). `facts` at a hole reports
its `goal`; `type-at` and `facts` at an annotated binder report its
declared type.

**Rename** is its own operation, since it takes a parameter:

```
puffincc --assist rename FILE POS NEW
  -> {"edits":[{"start","end","text"}, ...]} | {"error":"..."}
```

A scope resolver ties every name occurrence in the file to its
binder (formals, let/let*/letrec and named let, internal defines,
match binders and guards, quasiquote unquotes; quoted data, case
datums, and annotation types are not names), so rename changes
exactly the occurrences of one binder, a top-level name's `(: f ...)`
and `provide` included. Then it resolves the renamed text again: if
any occurrence would now refer to a different binder (a capture, or
a name freed), the rename is refused. Names nothing in the file
binds -- prims, imports -- are not renamed; neither are other
modules' uses of a provided name.
11. **Promote an s-expression language to a `define-type`** inferred
    from its quasiquote patterns.

## 6. The assistant

Tab on an empty REPL prompt, or `??` at its start, switches the
prompt to ask mode; Esc returns. Questions and answers interleave in
the transcript. Each turn runs a headless `claude -p` subprocess
whose only tools are the server's MCP endpoint (no Bash, Write, or
Edit), as in Slog Studio's `agent.rs`. The context it starts with is
the focused form or selection, the scope, recent transcript entries,
and diagnostics; it reads the rest through tools.

Tools:

- `get_program`, `get_form`: text, with this thread's pending
  proposals applied.
- `type_at`, `facts_at`: layered facts with their sources.
- every §5 assist, returning the edit it would make.
- `propose_edit`, `propose_changes`: proposals, checked at propose
  time.
- `evaluate`: run the forked program or an expression on the
  preview lane.
- `repl`: an allowlisted read of the live session (inspect a value,
  list definitions), never a definition or an effect.
- `search_docs`, `read_doc`: `docs/` and a tested Puffin reference.

Commands the assistant suggests appear as chips. Run sends the same
message typing does.

## 7. Testing

Assists are corpus-tested like diagnostics. An assist corpus holds
programs with a marked point and an operation, and a golden of the
edit puffincc produces. Facts from layers 0 to 3 are goldenable the
same way. The server's protocol has a plain, scriptable mode so
transcripts can be goldens too.

## 8. Phases

- **M0.** Span reader; `puffincc --assist` with `check`, `forms`,
  and `type-at` via probe; the assist corpus.
- **M1.** Assists 1 to 5, usable headless and from `puffin-mode.el`.
- **M2.** The server and web client: live transcript,
  eval-from-buffer, ask mode, checked proposals, versions.
- **M3.** Observations and flow shapes; assists 6 to 9. Layer 3's
  first cut is built: call-site shapes (a function's literal-argument
  calls in the file give the shapes of its parameters, in the
  observation record's form), feeding the same match assists (source
  `call-site`) and the lint. Shape-based match assists, observed or
  call-site, apply only to unannotated parameters. Built:
  observations, the observation lint, assists 6, 8 (ADTs), and 9
  (observed); in the studio, session awareness, observed assists and
  hovers, and the Facts panel. Not yet: flow shapes (layer 3, `aam.puf` with a shape
  domain), the fact store's dependency invalidation.
- **M4.** Multi-module changesets, rewind, a co-author socket.

## 9. Where the built studio differs

- **Tool names.** The assistant's tools are `list_files`, `get_file`
  (this thread's pending proposals applied), `check`, `assists_at`,
  `apply_assist`, `type_at`, `propose_edit` (an empty `old` appends
  or creates a file), `get_proposals`, `evaluate` (via `try`),
  `evaluate_program` (a throwaway VM, 10 s), `read_doc`, and
  `search_docs`, and `facts_at` (the checker's type and the session's
  observations at a point). `propose_changes` and an allowlisted
  `repl` read are not built.
- **`evaluate` refuses effects outside the session**: `system`,
  `write-file`, stdin reads, and the FFI forms, since `try` can
  discard session state but not a written file.
- **Buffer forms bring their module's types.** Evaluating a form from
  a buffer also sends the `define-type` forms of its module and the
  modules it requires, on top of the session's own (§2.2).
- **Versions are per file and in memory**, each recording the forms
  it changed; not yet the forms-keyed graph of §4.
- **Before `--serve`** the live lane can replay `--session` with
  every unit so far (effects repeat). It is a fallback only.
- **Session awareness** (`studio/src/session.rs`). The studio records,
  per file, each top-level form the session loaded and the text it
  was loaded with, keyed like `forms`. The gutter marks forms current,
  stale (edited since loaded), redefined from the prompt, or an
  evaluated expression (hover: its last result). ⌘↵ is `,eval
  FILE:LINE` and is dependency-aware: it also loads, first, the
  module's missing or stale definitions the form mentions,
  transitively. An `X: undefined` error offers "Load X from FILE".
  `,session` lists what is loaded.
- **Observations.** While the session observes, every unit compiles
  with `--observe`, the prompt's included. The record is refreshed by
  a quiet `try` 300 ms after evaluations pause and passed as
  `--observed`. A failing evaluation's observations are lost with its
  fork; replay mode never refreshes.
- **Facts panel and hover** both come from `facts`: one section per
  layer (syntax, checker, session, observed), each labelled.
- **Tokens.** The launch token is kept in `~/.puffin-studio/token`
  (mode 0600) so open tabs reconnect after a restart; `/mcp` has its
  own per-run bearer token.
