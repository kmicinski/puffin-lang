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
(lambda (x y) body ...)               ;; or λ; closures are first-class
(set! x e)                            ;; mutation (locals and globals)
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

I/O: `(read)` reads an integer from stdin; `(println e)`,
`(display e)`, `(newline)`; `(error e)` prints `error: <e>` and halts.

Primitives are first-class-ish: naming one in value position
eta-expands it, so `(map car xs)` works.

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
```

The web REPL (`web/`) runs the same language in the browser.

## Sharp edges (current)

- Arithmetic on non-integers is unchecked in compiled code (the
  interpreter errors); the planned gradual type system addresses
  this properly. Heap operations (`car`, `vector-ref`, hash/set ops)
  are always checked.
- Fixnums are 61-bit in compiled code, arbitrary precision in the
  interpreters — stay under ±2^60.
- `set-car!`/`set-cdr!` don't exist (pairs are immutable).
- A REPL define can't shadow a primitive name (files can).
