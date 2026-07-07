# Puffin

The course compiler, grown into a language: **Puffin** lives in
`src/` (compiler, runtime, REPL, tests), `web/` (browser REPL),
`puffincc-src/` (the self-hosted compiler, a Puffin module DAG), and
`bin/puffin` (the CLI). Start with
[docs/DELTA.md](docs/DELTA.md) — "what's the delta from p5?" — then
[docs/LANGUAGE.md](docs/LANGUAGE.md),
[docs/MODULES.md](docs/MODULES.md),
[docs/OPTIMIZER.md](docs/OPTIMIZER.md), and
[docs/STDLIB.md](docs/STDLIB.md).

```
bin/puffin                    # REPL
bin/puffin prog.puf           # compile natively (x86-64 & arm64 backends) + run
bin/puffin -O 2 prog.puf      # with the flow-analysis optimizer
racket src/test.rkt -m all    # the whole corpus, all execution routes
bin/build-puffincc            # stage-1 self-hosted compiler, then:
build/puffincc prog.puf -o prog   # puffincc compiles + links on its own
```

Multi-file programs use the module system ((require "lib.puf") /
(provide ...)); every route — interpreter, both backends, the web
playground, puffincc — resolves them.

---

# Progress

# Jun 10

- Worked on slides a ton for L0/L1
- Not quite done with L1 
# compilers-projects
