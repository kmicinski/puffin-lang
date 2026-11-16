# Grammar types: s-expressions with types (experimental)

Status: the design implemented on the `experimental` branch. It replaces
docs/TYPES.md §2's "algebraic datatypes as a separate runtime kind,
bridged by constructor-directed quasiquote" with **one runtime world —
plain s-expressions — and types that are grammars over them.**

## 1. Why

Before this change Puffin had two worlds. A `define-type` instance was its
own heap kind, so `(Add (Num 1) (Num 2))` and `'(+ 1 2)` were different
values; anything that arrived as data (quoted code, `read`, the REPL)
needed a hand-written conversion, and printing an object-language term
needed a `show`. Quasiquote bridged the two by rewriting templates whose
head named a constructor (depth 1 only), which made constructor names
unusable as data symbols and silently dropped to `_` at the first
non-constructor head. The self-hosted compiler — the largest Puffin
program — uses over a thousand quasiquote patterns and no `define-type`.

## 2. `define-grammar`

```scheme
(define-grammar Expr
  #:keywords (+ * let lambda)     ; Sym leaves of this grammar exclude these
  Int
  Sym
  (+ Expr Expr)
  (* Expr Expr)
  (let ([Sym Expr] ...) Expr)
  (lambda (Sym ...) Expr)
  (Expr Expr ...))                ; application

(define-grammar (Tree a)          ; parametric
  leaf
  (node (Tree a) a (Tree a)))
```

A grammar is a union of **productions**. A production is written the way
a quasiquote pattern is, with types where the pattern would bind:

| In a production | Means |
|---|---|
| a type: `Int` `Bool` `Sym` `Str` `Void` `_`, a grammar or `define-type` name, a parameter of this grammar, an alias, a foreign type | any value of that type (a *leaf*) |
| a list whose head is a type former or a parametric type name: `(List τ)`, `(Hash Sym Int)`, `(Tree a)`, `(-> Int Int)` | that type |
| any other symbol (`+`, `let`, `leaf`) | that literal symbol |
| a fixnum, string, `#t`/`#f` | that literal |
| `'d` | the literal datum `d` (to write a literal that would otherwise read as a type: `'Int`, `'(List x)`) |
| `(p ...)` | a proper list, element by element |
| `p ...` (an element followed by `...`) | zero or more elements, each `p` — at most one per list level, any fixed elements may follow |

Rules:

- A capitalized symbol that names no type is an error (`unknown type
  Exprr`), so typos are caught; quote it to mean the literal.
- `#:keywords (k ...)`: every `Sym` leaf **of this grammar** excludes the
  listed symbols, so `(+ 1 2)` is not also an application of the
  variable `+`. Only grammars with keywords need it.
- Grammars, `define-type`s and aliases form one mutually recursive group
  per module (as before); type names and value names stay disjoint.
- A grammar is a type name like any other: provided, imported, renamed
  and qualified through the module system, usable in every annotation.
- Dotted productions are not supported.

## 3. `define-type` is a grammar

```scheme
(define-type (Option a) (None) (Some a))
```

is the grammar `None | (Some a)` — literal head symbols in their source
spelling — **plus** constructor functions: `(Some x)` builds the list
`(Some x)`, and the nullary `None` is the symbol `None`. Instances print
exactly as before (`(Some 1)`, `None`). The difference is that `(Some 1)`
and `'(Some 1)` are now the same value: `list?`, `car`, `equal?` and
`match` all see a list, and `read`/quote/quasiquote produce typed data
without conversion. There is no separate ADT heap kind any more.

Constructor patterns `(Some p)` and bare nullary patterns `None` keep
working in `match`; they are list and literal patterns. Two modules that
declare the same constructor name build the same data (types are
structural; §4).

## 4. Types and checking

Grammar types are **structural**: a type is the set of s-expressions it
describes, and two grammars that describe the same set are
interchangeable. The checker gains *inclusion* (`τ ⊆ σ`) between
s-expression types, alongside the existing gradual consistency:

- **A grammar expected**: the value's type must be included in it.
  `'(+ 1 (* 2 3)) : Expr` is checked statically; so is passing a
  `(Num Int)` grammar's value where `Expr` is expected, or a pass typed
  `(-> Lif Lvar)` returning a term of a sublanguage. `_` and type
  variables are consistent with everything, as before.
- **A grammar used where an ordinary type is expected** (`car` on an
  `Expr`, `symbol?` on it): allowed when the two overlap — the gradual
  reading of "this may be a pair". Disjoint is a type error.
- Inclusion is production-by-production with coinduction on grammar
  pairs; it is sound and complete for the grammars people write (a
  production of the smaller grammar must fit inside a single production
  of the larger one).

**Literals and templates are typed by their shape.** `'(+ 1 2)` has the
exact type of that datum; `` `(+ ,a ,b) `` has the type `(+ τa τb)` where
`τa`, `τb` are the holes' types; `,@xs` with `xs : (List τ)` is "zero or
more τ". A shape fits a grammar when one of the grammar's productions
includes it. Nothing is rewritten: quasiquote and quote are data, at
every depth. In messages a shape prints as the datum or template it came
from: `'(- 1 2)`, `` `(+ ,Int ,Expr) ``.

## 5. Match

When the scrutinee's type is a grammar (or a shape), each clause is typed
against the productions it can match:

- A pattern variable's type is what the matching productions put at its
  position (joined across productions; `_` when they disagree). Under an
  ellipsis it is `(List τ)`.

  ```scheme
  (match (ann e Expr)
    [`(let ([,x ,rhs] ...) ,body) ...])   ; x : (List Sym), rhs : (List Expr), body : Expr
  ```
- `(? pred p)` with `fixnum?`/`integer?`, `symbol?`, `string?`,
  `boolean?` narrows `p` to `Int`, `Sym`, `Str`, `Bool`.
- **Exhaustiveness**: a production no unguarded clause can match is
  reported, in declaration order:
  `typecheck warning: match on Expr is not exhaustive: missing (- Expr Expr), Sym`.
  For a `define-type` the report names constructors exactly as before
  (`missing None`). It stays conservative: a clause that matches part of
  a production counts as covering it, and patterns the checker cannot
  analyze (`cons`, `list`, `vector`, unknown predicates) cover
  everything. `--strict-types` makes it an error, as before.
- A `_` scrutinee is exempt (the gradual guarantee).

## 6. Casts

A grammar annotation at a `_` boundary (annotated formal, result, `ann`,
annotated `let`, `(: x τ)`) checks the **whole value** against the
grammar, not just its outermost shape: desugar emits one recognizer
function per grammar and the boundary calls it. Leaves that are ordinary
types are checked first-order as before; type parameters accept
anything. A failure is the usual cast error:

```
puffin runtime error: cast: expected Expr, got (- 1 2) (blame: calc's argument e)
```

Calls between typed functions insert no cast (the value's type is
already known to fit), so recursion over a typed term is check-free.
Pairs are immutable, so a validated term stays valid.

## 7. Studio and assists

Fill-match writes one clause per production: a quasiquote pattern with a
binder per leaf (`` [`(+ ,e1 ,e2) ??] ``), `(? fixnum? n)` / `(? symbol? x)`
for base leaves, and constructor patterns for `define-type`s as before.
Hover shows a binder's production type. REPL units carry
`define-grammar` forms like `define-type` ones.

## 8. Compatibility

- Programs without `define-type`/`define-grammar` compile exactly as
  before (the gradual guarantee).
- `define-type` programs keep their syntax and printed output. What
  changes: instances are lists (`(list? (Some 1))` is `#t`, `adt?` is
  `#f` for them), and a quasiquote template naming a constructor is
  plain data — which is now the same value the constructor builds.
  `` `(M.Add ,a ,b) `` under `#:as M` is the symbol `M.Add`, not a call;
  write `(M.Add a b)`.
- Field and constructor arity errors in templates (`'(Add 1)`) are no
  longer compile errors where the template is unconstrained; they are
  inclusion errors where a grammar is expected.
