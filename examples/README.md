# Puffin examples

Runnable, curated programs — the language by example (`lang/`) and
the language against the real world (`ffi/`, `z3/`). Each example has
a `.expect` golden; `tools/test-examples.sh` runs them all on both
self-hosted routes (native and the bytecode VM) and holds the output
to the golden.

```
build/puffincc examples/z3/sudoku.puf -o sudoku && ./sudoku
tools/test-examples.sh              # all of them, native + VM
tools/test-examples.sh sudoku       # just one
```

How examples relate to tests: they are the same pool, curated at
different doors. The golden corpus (`src/test-programs/`, 309 checks)
doubles as the web playground's example set (`web/src/examples.js`)
and the benchmark sources; the `lang/` entries below are promoted
verbatim from that corpus (each notes its corpus twin), and the
FFI/z3 entries are examples-first (the corpus can't carry them — the
browser route refuses `dlopen`). Everything user-facing is
golden-tested; nothing is documentation-only.

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

## ffi/ — first contact

- **hello-libc.puf** — the system C library through the typed FFI.
  No build step, no binding layer: declare `strlen` at
  `(-> Str Int)` and call it. Shows `(Nullable Str)` quarantining
  C's `NULL`, and a foreign name being an ordinary value
  (`(map c-abs ...)`).

## z3/ — a real library as a Puffin API

`z3.puf` binds the [Z3 SMT solver](https://github.com/Z3Prover/z3)
(`brew install z3`; edit the library path at the top if yours isn't
Homebrew's). The binding is deliberately thin — two
`define-foreign-type` handles and six imports, of which
`Z3_eval_smtlib2_string` is the workhorse — because SMT-LIB is
s-expressions: queries are quasiquoted **Puffin data** rendered by
`value->string`, and replies are read back into Puffin data by the
~30-line reader in the same file. `require` it like any module:

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

The FFI test fixtures (a C library exercising every marshaling row
and error path, and a Rust `cdylib` guest) live in `tests/ffi-demo/`;
the tutorial's FFI chapter (`docs/tutorial.html`) walks the design.

Note the honest limit: the browser playground has no `dlopen`, so
these examples compile there but refuse to run at load —
`error: foreign library ... is not available in the browser`.
