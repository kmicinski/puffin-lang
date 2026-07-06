# Puffin web

A browser-based interpreter + REPL for the Puffin language. The
interpreter (`src/puffin/`) is pure ESM with no DOM dependencies and
matches the reference implementation in `../src/` (interpreters.rkt /
stdlib.rkt / compile.rkt's surface language) byte-for-byte on the
golden corpus.

## Run

```sh
npm install
npm run dev        # dev server (http://localhost:5173)
npm run build      # production build into dist/
npm run preview    # serve the production build
```

## Cross-check against the reference goldens

```sh
node test-corpus.mjs           # all 56 programs x 3 inputs = 168 checks
node test-corpus.mjs r4-7      # restrict to named programs
```

Runs every program in `../src/test-programs/` against every input in
`../src/input-files/` and compares trimmed output with
`../src/goldens/`.

## Notes

- Programs run in a Web Worker; **Run** cancels any in-flight run
  (Cmd/Ctrl+Enter in the editor also runs).
- The REPL (bottom right) evaluates forms in a persistent session —
  top-level defines stick around until **Reset session**.
- The **stdin** box supplies whitespace-separated integers to
  `(read)`; when empty, the input stream is `0 1 2 …` (the reference
  test default).
