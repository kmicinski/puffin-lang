# Puffin examples

Runnable programs showing the language against the real world —
today, that means the FFI (docs/FFI.md): typed `dlopen`'d imports
with blame on every route. Each example has a `.expect` golden;
`tools/test-examples.sh` runs them all on both self-hosted routes
(native and the bytecode VM) and holds the output to the golden.

```
build/puffincc examples/z3/sudoku.puf -o sudoku && ./sudoku
tools/test-examples.sh              # all of them, native + VM
tools/test-examples.sh sudoku       # just one
```

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
