# Exceptions

Status, 2026-11-18: built on the `exceptions` branch. `raise`,
`with-handlers` and catchable runtime errors work on the reference
interpreter, both compilers' bytecode target, the VM and the browser
(wasm) VM. The native backends refuse a program that catches (§5).

Before this, every failure in Puffin ended the process: `(error v)`
printed and exited 1, a runtime error (a bad index, `car` of a number,
a failed cast) printed and exited 255. That still happens when nothing
catches the failure — byte for byte, on every route — but a program can
now catch it.

## 1. The surface

```scheme
(raise v)                       ; raise any value

(with-handlers ([pred handler] ...)
  body ...)                     ; body's value, or a handler's

(error v)                       ; raises an exn of kind 'error
(exn? v)                        ; was v raised by error or a runtime error?
(exn-message e)                 ; Str: the runtime error's text, or the
                                ;   value given to error, as display shows it
(exn-kind e)                    ; 'error or 'runtime
```

`with-handlers` is Racket's. The body runs; if it raises a value `v`,
the clauses are tried in order and the first whose `pred` holds of `v`
has its `handler` called on `v`, and that is the `with-handlers`
form's value. If no `pred` holds, `v` goes on to the next
`with-handlers` out. A handler runs *outside* its own `with-handlers`:
an exception it raises goes outward, never back to itself. The `pred`
and `handler` expressions are evaluated once, before the body.

```scheme
(: parse (-> Str Int))
(define (parse s)
  (with-handlers ([exn? (lambda (e) -1)])
    (let ([n (string->number s)])
      (if n n (error (string-append "not a number: " s))))))

(with-handlers ([symbol? (lambda (s) (list 'raised s))]
                [exn? (lambda (e) (list (exn-kind e) (exn-message e)))])
  (vector-ref (vector 1 2) 7))
;; => (runtime index out of range)
```

What is catchable: anything `raise`d, `(error v)`, and every runtime
error — arithmetic on a non-number, division by zero, an index out of
range, a primitive applied to the wrong kind of value, a failed cast
(gradual typing's blame errors), a failed `match`, applying a
non-procedure, file I/O errors, FFI blame errors. What is not: the
VM's own faults (a malformed unit, an illegal opcode, frame-stack
overflow) and a foreign library that cannot load.

An exn displays as `#<exn: MESSAGE>`. It is an ordinary value: it can
be kept, compared with `eq?`, and raised again.

## 2. Uncaught exceptions

An uncaught exception ends the program the way the failure always did:

| raised by | prints | exit |
|---|---|---|
| `(error v)` | stdout `error: v` | 1 |
| a runtime error | stderr `puffin runtime error: MESSAGE` | 255 |
| a file I/O error | stderr `error: MESSAGE` | 1 |
| `(raise v)`, `v` not an exn | stdout `uncaught exception: v` | 1 |

Each exn remembers which of these it is (its *style*), so an exn caught
and raised again ends the program exactly as it would have the first
time. The reference interpreter keeps its documented difference: it
prints `error: v` and stops with exit 0 (golden parity, the errors
corpus's `interp-exit-ok`).

## 3. One primitive

`with-handlers` is expanded by **both typecheckers**, first thing
(`expand-with-handlers` in src/types.rkt and puffincc-src/types.puf), so
every route and every assist sees only the primitive
`call-with-handler`:

```scheme
(with-handlers ([P H] ...) BODY ...)
=> (let ([#%wh-p0 P] [#%wh-h0 H] ...)
     (call-with-handler
       (lambda () BODY ...)
       (lambda (#%wh-e)
         (cond [(#%wh-p0 #%wh-e) (#%wh-h0 #%wh-e)] ...
               [else (raise #%wh-e)]))))
```

A `P` or `H` that is a name or a lambda is used in place, without a
binding. The binders are fixed names, not gensyms, so the two
compilers' gensym counters (and their byte-identical output) are
untouched. Quoted data is never expanded; a quasiquote template only
under `unquote` / `unquote-splicing`.

`call-with-handler : (-> (-> a) (-> _ a) a)` and `raise : (-> a _)`
are ordinary manifest primitives (src/stdlib.rkt, appended so the
committed seed's primitive ids keep their meaning), with `exn?`,
`exn-message` and `exn-kind`. No compiler pass between the typechecker
and the backends knows about exceptions:

- the optimizer is sound as it is: closures passed to a primitive
  escape (the flow analysis assumes they are called, with any
  arguments), and `raise` / `call-with-handler` are not in the
  droppable-when-unused `pure-prims` set. As before exceptions, -O1
  may drop an unused pure primitive call that would have failed
  (`(begin (car 5) 1)`); inside a `with-handlers` that now shows as
  the handler not running.
- the bytecode backend emits `call-with-handler` as an ordinary `PRIM`
  instruction; the VM intercepts it. The bytecode format is unchanged.

## 4. The runtime and the VM

**The C runtime** (src/runtime/lib/exn.c) owns a heap kind,
`PF_KIND_EXN` (20): `| kind | payload | style |`. Every failure ends in
`pf_raise_value`: `raise`; `pf_error`; `pf_fatal`, which arithmetic,
cast, index, kind and match errors already reached; the file I/O errors
(`pf_fail`); and the FFI's blame errors. If `pf_raise_hook` is set,
the value goes to it and it never returns; otherwise the exception is
uncaught (§2). `pf_fatal` and `pf_error` look at the hook before
allocating anything, so with no handler installed they behave exactly
as before.

**The VM** (src/vm/puffin-vm.c) keeps a handler stack beside its
control stack. `call-with-handler` pushes a record — the depth of the
calling frame, the `PRIM`'s destination slot and return point, and the
slot holding the handler closure — sets `pf_raise_hook`, and calls the
thunk in a new frame marked as a *catcher*. When that frame returns
(by `RET`; a tail call keeps the mark) the record is popped and the
thunk's value is the `PRIM`'s result. A raise anywhere inside —
in a primitive's C code or in the dispatch loop — `longjmp`s to the
recovery point at the top of `vm_run`, which pops the innermost record,
frees every frame above the caller, and calls the handler with the
raised value as if the caller had called it at the `PRIM`.

The handler closure is not copied into the handler stack: it stays in
the caller's staging slot, which nothing writes while the caller waits,
so the control stack still holds no Puffin values and the collector
needs no new roots.

**The reference interpreters** (src/interpreters.rkt) implement
`call-with-handler` with a Racket exception carrying the raised value
(`puffin-raise`) and a depth counter: at depth 0 a failure prints and
stops as before, inside a handler it raises. A Racket-level failure of
a primitive's reference implementation (`car` of a number) is caught
as a runtime exn too, with the runtime's wording for index and kind
errors (`racket-failure-message`); other messages are Racket's (the
interpreter's documented variance, `*.expect.interp`). The blocks
interpreter now tag-checks arithmetic like the source interpreter, so
`+: expected Int, got two` reads the same on every route.

## 5. Native backends

`-t x86-64` and `-t arm64` refuse a program that uses `with-handlers` or
`call-with-handler`, at compile time, in both compilers
(`reject-native-handlers!`):

```
error: with-handlers needs the bytecode target (-t bytecode): the native
backends do not support exceptions yet (docs/EXCEPTIONS.md)
```

`raise`, `error`, `exn?` and friends work natively; nothing can catch,
so every exception is uncaught (§2). Natively, catching needs a
`setjmp`-based `pf_call_with_handler` in the runtime and a small
trampoline per backend to call a Puffin closure from C. The x86-64
backend links and runs on Linux, so that one can be tested on sonic;
arm64 needs the Mac.

The golden corpus runner (src/test.rkt) skips a program that catches
on its native legs (`native-capable?`); every other route runs it.

## 6. The browser VM

The browser VM catches with the same code as the native VM. LLVM lowers
C `setjmp`/`longjmp` on wasm onto the wasm exception-handling feature,
so the wasm builds (src/vm/Makefile `WASM_SJLJ`) compile with
`-DPUFFIN_WASM_SJLJ -mllvm -wasm-enable-sjlj
-mllvm -wasm-use-legacy-eh=true` and link wasi-libc's `-lsetjmp`.

**Decision (2026-11-18):** depend on the feature. This is a deliberate
exception to docs/WASM-VM.md's principle 4 ("no wasm proposals that
aren't universally shipped"), because this one now is: the *legacy*
encoding (try/catch) the build uses has shipped in Chrome 95, Firefox
100 and Safari 15.2 since 2022, and in Node 17. The newer `exnref`
encoding (2025) is not required. The alternative that kept principle 4
-- a second, resumable dispatch loop that unwinds through a JS
exception and an exported `pvm_resume` -- would have been a separate
implementation of catching that only the browser runs.

The existing error boundary is unaffected: an uncaught failure still
calls `host_abort`, whose JS exception passes through the setjmp
lowering (it catches only its own longjmp tag) and unwinds every wasm
frame as before.

A wasm VM built without `-DPUFFIN_WASM_SJLJ` still works; at a
`call-with-handler` it says

```
puffin runtime error: call-with-handler: this VM build cannot catch exceptions (the browser VM; docs/EXCEPTIONS.md)
```

## 7. Tests

- `src/test-programs/puffin-exceptions.puf` — the semantics above, on
  the interpreter, every pass of the chain, Racket→VM and puffincc→VM
  (goldens in src/goldens).
- `src/errors-corpus/rt-raise-*.puf` — uncaught raises: a bare
  `raise`, a handler that raises again, an error no clause matches.
- `web/` (`npm test`, `node test-errors.mjs`) runs both through the
  wasm VMs.

## 8. Not yet

- Native catching (§5).
- `dynamic-wind` / `finally`: a handler runs after the frames are gone,
  with nothing run on the way out.
- Exn subtypes or fields beyond kind and message; user code makes its
  own exception values with `raise` of any value (an ADT works well).
- puffincc-src itself must not use `with-handlers` until the committed
  seed (boot/puffincc.pbc) is refreshed from a compiler that expands it
  (docs/BOOTSTRAP.md "Seed freshness").
