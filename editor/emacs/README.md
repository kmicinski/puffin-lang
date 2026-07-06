# Puffin Emacs mode

`puffin-mode` for `.puf` files: font-lock, scheme-style indentation,
run/interpret commands, an inferior REPL, and eglot integration with
`bin/puffin-lsp`.

Requires Emacs 28.1+ (for `lisp-data-mode`).

## Install

```elisp
(use-package puffin-mode
  :load-path "~/projects/puffin-lang/editor/emacs"   ; adjust to your checkout
  :mode "\\.puf\\'"
  :hook (puffin-mode . eglot-ensure))
```

`puffin-mode` registers `bin/puffin-lsp` with eglot automatically (it
finds the repo root via `locate-dominating-file`), so `eglot-ensure`
is all the hookup needed. Without `use-package`:

```elisp
(add-to-list 'load-path "~/projects/puffin-lang/editor/emacs")
(require 'puffin-mode)
(add-hook 'puffin-mode-hook #'eglot-ensure)
```

## Keys

| Key       | Command                  | What                                |
|-----------|--------------------------|-------------------------------------|
| `C-c C-c` | `puffin-run-buffer`      | compile + run natively (bin/puffin) |
| `C-c C-i` | `puffin-interp-buffer`   | interpret (bin/puffin -i)           |
| `C-c C-z` | `run-puffin`             | the REPL, in comint                 |
| `C-c C-r` | `puffin-send-region`     | send region to the REPL             |
| `C-M-x`   | `puffin-send-definition` | send top-level form to the REPL     |

## Regenerating the builtin list

The `puffin-stdlib-builtins` defconst is generated from the stdlib
manifest. After adding primitives to `src/stdlib.rkt`:

```sh
racket tools/lsp/gen-el-keywords.rkt
```

and paste the output over the generated section in `puffin-mode.el`.
