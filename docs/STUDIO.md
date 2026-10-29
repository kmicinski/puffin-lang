# Puffin Studio: a REPL you co-develop a program with

Status: design, 2026-10-29. Nothing here is built yet except where a
section says so. The phases at the end are the plan of record.

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
runs one operation; puffincc prints one s-expression reply on
stdout.

```
puffincc --assist check   main.puf      -> (ok) | (error file line msg)
puffincc --assist forms   main.puf      -> ((key "define:eval-expr" start end hash) ...)
puffincc --assist type-at main.puf POS  -> (type τ) | (unknown)
puffincc --assist fill-match main.puf POS
                                        -> (edit file start end "new text" source)
```

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
6. **Typed holes.** The goal type and the in-scope names that fit it.
7. **Matches for untyped data**, from quasiquote patterns already
   used on the same value (layer 1), flow shapes (layer 3), and
   observed values (layer 4), each labelled with its source.
8. **Identity traversal.** For an ADT or a family of quasiquote
   patterns, the pass that rebuilds every case unchanged, ready to
   change one.
9. **Insert `(: f τ)`** from synthesized or observed types.
10. **Pin a transcript entry as a test.**
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
- **M3.** Observations and flow shapes; assists 6 to 9.
- **M4.** Multi-module changesets, rewind, a co-author socket.
