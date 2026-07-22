# Puffin examples

Curated, runnable Puffin programs. `lang/` shows the language by
example; `ffi/` and `z3/` show it against the real world through the
typed FFI. Every example ships with a `.expect` golden and is held
to it on both self-hosted routes — native code and the bytecode VM —
so everything on this page runs, verbatim, today.

## Running them

You need the compiler (`bin/bootstrap` builds `build/puffincc`;
no Racket required). Compile and run an example directly, or let the
test script run the whole set:

```
build/puffincc examples/z3/sudoku.puf -o sudoku && ./sudoku
tools/test-examples.sh              # all of them, native + VM
tools/test-examples.sh sudoku       # just one
```

Examples whose foreign library is missing on your machine are
skipped, not failed — the `z3/` examples need `brew install z3`.

## lang/ — the language by example

- **pcf-interp.puf** — an interpreter for PCF, the canonical typed
  toy language: quasiquote patterns in, quasiquote construction out.
- **red-black-tree.puf** — Okasaki red-black insertion; `balance` is
  one four-way match. THE pattern-matching showcase.
- **hindley-milner.puf** — Algorithm W for mini-ML: unification,
  generalization, pretty-printed principal types.
- **zipper.puf** — Huet zippers over binary trees: navigate, edit,
  rebuild, persistently.
- **stack-compiler/** — the classic expr→stack-machine compiler,
  split across three modules (`require`/`provide` in action).

The `lang/` programs share sources with the golden test corpus
(`src/test-programs/`), which also feeds the web playground's
example menu — the playground is the fastest way to try them
without building anything.

## ffi/ — first contact

- **hello-libc.puf** — the system C library through the typed FFI.
  No build step, no binding layer: declare `strlen` at
  `(-> Str Int)` and call it. Shows `(Nullable Str)` quarantining
  C's `NULL`, and a foreign name being an ordinary value
  (`(map c-abs ...)`).

## z3/ — a real library as a Puffin API

`z3.puf` binds the [Z3 SMT solver](https://github.com/Z3Prover/z3)
(`brew install z3`; if your `libz3` isn't at Homebrew's default
path, edit the library path at the top of `z3.puf`). The binding is
deliberately thin — two `define-foreign-type` handles and six
imports, of which `Z3_eval_smtlib2_string` is the workhorse —
because SMT-LIB is s-expressions: queries are quasiquoted **Puffin
data** rendered by `value->string`, and replies are read back into
Puffin data by the ~30-line reader in the same file. `require` it
like any module:

```scheme
(require "z3.puf")
(define ctx (z3-new))
(z3-send* ctx '((declare-const x Int) (assert (> x 41)) (assert (< x 43))))
(z3-check-sat ctx)        ;; => sat
(z3-get-values ctx '(x))  ;; => ((x 42))
(z3-close ctx)
```

- **intro.puf** — the API tour: `z3-send*`, `push`/`pop`,
  model values (negatives normalized).
- **sudoku.puf** — the elaborate one: generates the full Sudoku
  constraint system as data (declarations, row/column/box
  `distinct`s, givens), hands it to Z3, reads the model back, prints
  the solved board — then asserts the negation of the model and gets
  `unsat`, proving the solution unique.

The FFI chapter of the tutorial (`docs/tutorial.html`) walks the
design behind these bindings.

One honest limit: the browser playground has no `dlopen`, so the
FFI and z3 examples compile there but refuse to run at load —
`error: foreign library ... is not available in the browser`.
