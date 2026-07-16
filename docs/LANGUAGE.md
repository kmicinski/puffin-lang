# The Puffin Language

A compact reference for writing Puffin day to day. For how it's
implemented (and what changed vs the class p5 compiler), see
[DELTA.md](DELTA.md); for the library, see [STDLIB.md](STDLIB.md).

## Programs

A `.puf`/`.scm` file is a sequence of top-level forms — function
defines, value defines, and expressions — evaluated in order. The
last expression's value is printed (unless it's void). The class
`(program ...)` wrapper is also accepted.

```scheme
(define greeting 'hello)              ;; a top-level value
(define (shout s) (list s s s))       ;; a function
(println (shout greeting))            ;; an effect
(shout 'done)                         ;; the result: printed
```

Top-level defines are mutually recursive; value defines are
initialized in source order (a function may mention a later global —
it's read at call time). Top-level definitions shadow standard-library
primitives, so old class programs that define their own `cons` run
unchanged.

## Modules

A file is a module (docs/MODULES.md has the full story). `(provide
name ...)` declares its exports — no provide form means everything
top-level is exported. `(require "path.puf")` imports another file's
provided names; paths resolve relative to the requiring file.

```scheme
(require "vec.puf")                     ;; unqualified: dot, norm2
(require "matrix.puf" #:as M)           ;; qualified: M.transpose
(require "util.puf" #:only (twice) #:rename ((twice do-twice)))
(provide area)
(define pi 314159)                      ;; private unless provided
(define (area r) (* pi (* r r)))
```

Requires must form a DAG (cycles are compile-time errors); each
module's top-level effects run once, in depth-first postorder.
Signature files (`.pufs`) optionally constrain a module's exports:
`(provide #:sig "ring.pufs")` checks names and arities and narrows
the export set to exactly the signature. Import collisions — two
modules providing the same name, or an import colliding with a local
define or a reserved word — are compile-time errors; disambiguate
with `#:as` or `#:rename`. Everything (the reference compiler, the
web playground's file tabs, and puffincc) understands modules; a file
with no require/provide compiles exactly as before.

## Values

Fixnums (61-bit), booleans `#t`/`#f`, `(void)`, symbols `'foo`, the
empty list `'()`, pairs/lists, vectors, strings `"..."`, hashes, sets,
and procedures. Only `#f` is false. `eq?` is identity (fine for
fixnums, booleans, symbols); `equal?` is structural over pairs,
vectors, and strings.

## Expressions

Binding & functions:

```scheme
(let ([x 1] [y 2]) body ...)          ;; parallel
(let* ([x 1] [y (+ x 1)]) body ...)   ;; sequential
(let loop ([i 0]) ... (loop (+ i 1))) ;; named let; tail calls run in O(1) stack
(letrec ([odd? ...] [even? ...]) ...) ;; mutual recursion
(define (f a b . rest) ...)           ;; variadic: rest binds a list
(lambda args ...)                     ;; all-rest lambda
(lambda (x y) body ...)               ;; or λ; closures are first-class
(set! x e)                            ;; mutation (locals and globals)
```

Bodies support **internal defines**, scoped letrec\*-style over the
whole body — inner helpers can be mutually recursive:

```scheme
(define (outer n)
  (define (ev? k) (if (eq? k 0) #t (od? (- k 1))))
  (define (od? k) (if (eq? k 0) #f (ev? (- k 1))))
  (list (ev? n) (od? n)))
```

Control:

```scheme
(if g t f)
(cond [g body ...] ... [else body ...])
(when g body ...)   (unless g body ...)
(case e [(a b) body ...] [else body ...])
(begin e ...)
(while g body ...)
(and e ...) (or e ...) (not e)        ;; `or` returns its first truthy value
```

Arithmetic & comparison: n-ary `+ - *`; `quotient`/`remainder`
(checked division); `< <= > >=` (binary); `eq?`, `equal?`.

Data:

```scheme
'(a 1 (b 2))                          ;; quoted data (symbols, ints, lists)
`(let ([,x ,e]) ,@body)               ;; quasiquote CONSTRUCTION, with splicing
(gensym 'tmp)                         ;; fresh interned symbols
(list 1 2 3)  (cons 1 '())  (car p) (cdr p) (pair? p) (null? p)
(vector 1 2 3) (make-vector n) (vector-ref v i) (vector-set! v i x) (vector-length v)
(hash k v ...)      an immutable hash; the default. eq?-keyed.
(hash-set h k v)    a NEW hash with the mapping added (h untouched)
(hash-remove h k)   a NEW hash without the key
(hash-ref h k) (hash-ref/default h k d) (hash-has-key? h k)
(hash-count h) (hash-keys h)            work on BOTH flavors
(set v ...) (set-add s v) (set-remove s v)   immutable sets, same story
(set-member? s v) (set-count s) (set->list s)

(make-hash) (hash-set! h k v) (hash-remove! h k)   the tolerated
(make-set) (set-add! s v) (set-remove! s v)        MUTABLE variants

"strings"   (string-append a b) (string=? a b) (string-length s)
            (symbol->string x) (string->symbol s)
```

**Puffin is immutable by design.** Pairs, strings, and symbols are
immutable; hashes and sets are immutable *by default* — `hash-set`
returns a new hash sharing structure with the old (a persistent HAMT
in the native runtime, so it's O(log n), not a copy), and immutable
collections compare by value under `equal?`. Mutability is tolerated
where you ask for it: `set!`, vectors (the raw mutable building
block), and the `make-hash`/`hash-set!` family, which are identity-
compared and eq?-keyed open-addressing tables. Keys in either flavor
are compared by identity — the right notion for fixnums, booleans,
and (interned) symbols.

Predicates: `fixnum? boolean? symbol? void? procedure? pair? null?
vector? string? hash? set?`.

I/O: `(read)` reads an integer from stdin; `(read-all)` the rest of
stdin as a string; `(println e)`, `(display e)`, `(newline)`,
`(displayln e)`; `(error e)` prints `error: <e>` and halts.

For writing compilers (see docs/BOOTSTRAP.md): `value->string`,
`(format "~a ~a" (list x y))`, `number->string`, `string->number`,
`substring`, `string-byte`, `string<?`, `string-join`, `sort`,
`symbol<?`, `apply` (≤5 args), `map2`, set algebra
(`set-union`/`set-subtract`/`set-intersect`/`list->set`),
`bitwise-and/ior/xor`, `arithmetic-shift`, `modulo`.

Primitives are first-class-ish: naming one in value position
eta-expands it, so `(map car xs)` works.

## Foreign functions

The `foreign` form imports typed C functions from a shared library
(docs/FFI.md has the full design; the tutorial has a worked section):

```scheme
(define-foreign-type Regex)              ;; an opaque handle type
(foreign "vendor/libpfregex.dylib"       ;; dlopen'd at module load
  (: regex-compile (-> Str (Nullable Regex)) #:c-name "pfregex_compile")
  (: regex-match?  (-> Regex Str Bool)       #:c-name "pfregex_is_match")
  (: regex-close   (-> Regex Void)           #:c-name "pfregex_free"
                                             #:consumes))
```

Each declaration is the ordinary `(: name τ)` form; the declared type
generates the marshaling, the checker types call sites with it, and
every crossing is checked at run time with blame naming the import.
Marshallable types: `Int` (plus the width spellings `I8`..`U64`),
`Bool`, `Str`, `Void` results, declared handle types, and
`(Nullable τ)` results (C `NULL` becomes `#f`). A foreign name is an
ordinary binding — it provides, eta-passes, and `procedure?` answers
`#t`. Library paths containing `/` resolve relative to the declaring
module's file. The browser playground compiles FFI programs but
refuses to run them at load (`error: foreign library ... is not
available in the browser`).

Runnable examples live in `examples/` — `ffi/hello-libc.puf` (the
system C library, no build step) and `z3/` (the Z3 SMT solver bound
as a Puffin API, with a solve-and-prove-unique Sudoku showcase);
`tools/test-examples.sh` holds them to their goldens.

## Pattern matching

```scheme
(match e
  [42 ...]                     ;; literals: fixnum, boolean, string
  ['sym ...]                   ;; a symbol
  [x ...]                      ;; variable: binds
  [_ ...]                      ;; wildcard
  [(cons hd tl) ...]           ;; pairs
  [(list a b c) ...]           ;; exactly three elements
  [(vector x y) ...]           ;; vectors by length
  [(? fixnum? n) ...]          ;; predicate guard around a subpattern
  [`(add ,a ,b) ...]           ;; quasiquote: literal structure + unquote holes
  [`(lambda (,xs ...) ,body) ...]  ;; ellipsis: xs collects a sublist
  [`(program (define (,ns ,ps ...) ,bs) ...) ...]  ;; nested ellipsis: per-element lists
  [p #:when guard ...]         ;; clause guards
  )
```

Ellipsis in quasiquote patterns is Racket-style: the repeated
pattern matches each element of a middle segment (fixed-shape
patterns may follow it), and each variable under the `...` collects
a list of its per-element matches — the idiom the Puffin compiler
itself is written in, ready for bootstrapping.

No clause matching raises `error: match-failure`. Quasiquote patterns
make ASTs pleasant to work with:

```scheme
(define (eval-expr e)
  (match e
    [`(add ,a ,b) (+ (eval-expr a) (eval-expr b))]
    [`(mul ,a ,b) (* (eval-expr a) (eval-expr b))]
    [(? fixnum? n) n]))
```

## Running

```
bin/puffin                      # REPL (,help ,env ,quit)
bin/puffin prog.puf             # compile natively + run
bin/puffin -i prog.puf          # interpret
bin/puffin -c prog.puf -o prog  # compile only
bin/puffin -t x86-64 prog.puf   # cross-target (runs under Rosetta)
bin/puffin -O 0 prog.puf        # optimization level (default -O1)
```

Module programs work everywhere a single file does: point any of the
above at the entry file and the require DAG is resolved from disk.
The self-hosted compiler is a standalone driver with the same shape:

```
build/puffincc prog.puf -o prog   # compile + assemble + link, no scripts
build/puffincc -O 2 -t x86-64 prog.puf -o prog.s
```

The web REPL (`web/`) runs the same language in the browser; the
playground's "+ file" tab turns the editor into a module DAG.

## Sharp edges (current)

- Fixnums are 61-bit in compiled code, arbitrary precision in the
  interpreters — stay under ±2^60.
- `set-car!`/`set-cdr!` don't exist (pairs are immutable).
- A REPL define can't shadow a primitive name (files can).
- `main` is reserved for the program entry point (defining it is a
  clear compile-time error).
- `apply` handles at most 5 arguments (the register-argument budget);
  `format` is fully variadic.
