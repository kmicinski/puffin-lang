# The Puffin Standard Library

*Generated from `src/stdlib.rkt` by `src/gen-stdlib-docs.rkt` — do not edit by hand.*

Each primitive below is implemented three times, and the manifest keeps them in lockstep:
in C (`src/runtime/lib/*.c`, called by compiled code), in Racket (the `ref-impl` used by
the reference interpreters and the console REPL), and in JavaScript (the web REPL,
cross-checked against the same goldens).

Compiler *intrinsics* — `+`, `-`, `*`, `eq?`, `<` (and the comparators that shrink to
them: `<=`, `>`, `>=`, `not`) — are open-coded by the backends and are not library calls;
they are listed in `src/irs.rkt`.

| Primitive | Arity | Runtime entry | Description |
|---|---|---|---|
| `read` | 0 | `pf_read_int` | Read an integer from standard input. |
| `println` | 1 | `pf_println` | Display a value followed by a newline; returns void. |
| `display` | 1 | `pf_display` | Display a value (no newline); returns void. |
| `newline` | 0 | `pf_newline` | Print a newline; returns void. |
| `error` | 1 | `pf_error` | Display `error: <value>` and halt the program. |
| `equal?` | 2 | `pf_equal` | Structural equality over pairs, vectors, and strings; identity otherwise. |
| `cons` | 2 | `pf_cons` | Allocate a pair of two values. |
| `car` | 1 | `pf_car` | First component of a pair (checked). |
| `cdr` | 1 | `pf_cdr` | Second component of a pair (checked). |
| `pair?` | 1 | `pf_pair_huh` | Is this value a pair? |
| `null?` | 1 | `pf_null_huh` | Is this value the empty list '()? |
| `make-vector` | 1 | `pf_make_vector` | Allocate a vector of n slots, initialized to 0. |
| `vector-ref` | 2 | `pf_vector_ref` | Fetch a slot (checked: type and bounds; dynamic index). |
| `vector-set!` | 3 | `pf_vector_set` | Store into a slot (checked); returns void. |
| `vector-length` | 1 | `pf_vector_length` | Number of slots in a vector. |
| `vector?` | 1 | `pf_vector_huh` | Is this value a vector? |
| `string?` | 1 | `pf_string_huh` | Is this value a string? |
| `string-length` | 1 | `pf_string_length` | Number of bytes in a string. |
| `string-append` | 2 | `pf_string_append` | Concatenate two strings. |
| `string=?` | 2 | `pf_string_equal_huh` | Are two strings byte-equal? |
| `symbol->string` | 1 | `pf_symbol_to_string` | The name of a symbol, as a fresh string. |
| `string->symbol` | 1 | `pf_string_to_symbol` | Intern a string as a symbol. |
| `quotient` | 2 | `pf_quotient` | Integer division truncated toward zero (checked: nonzero divisor). |
| `remainder` | 2 | `pf_remainder` | Integer remainder (checked: nonzero divisor). |
| `hash` | 0 | `pf_ihash_empty` | The empty immutable hash. (hash k v ...) builds one by chained hash-set. |
| `hash-set` | 3 | `pf_ihash_set` | A new immutable hash: like the input, with key mapped to value. |
| `hash-remove` | 2 | `pf_ihash_remove` | A new immutable hash: like the input, without the key. |
| `set` | 0 | `pf_iset_empty` | The empty immutable set. (set v ...) builds one by chained set-add. |
| `set-add` | 2 | `pf_iset_add` | A new immutable set: like the input, with the value present. |
| `set-remove` | 2 | `pf_iset_remove` | A new immutable set: like the input, without the value. |
| `make-hash` | 0 | `pf_make_hash` | Allocate an empty MUTABLE key/value map (eq?-keyed, open addressing). |
| `hash-set!` | 3 | `pf_hash_set` | Map key to value (overwrites); returns void. |
| `hash-ref` | 2 | `pf_hash_ref` | Look up a key (immutable or mutable hash); runtime error if absent. |
| `hash-ref/default` | 3 | `pf_hash_ref_default` | Look up a key; return the default if absent. |
| `hash-has-key?` | 2 | `pf_hash_has` | Is this key present? |
| `hash-remove!` | 2 | `pf_hash_remove` | Remove a key if present; returns void. |
| `hash-count` | 1 | `pf_hash_count` | Number of keys present. |
| `hash-keys` | 1 | `pf_hash_keys` | A list of the keys present (unspecified order). |
| `hash?` | 1 | `pf_hash_huh` | Is this value a hash (either flavor)? |
| `make-set` | 0 | `pf_make_set` | Allocate an empty MUTABLE set (eq?-keyed, open addressing). |
| `set-add!` | 2 | `pf_set_add` | Add a value; returns void. |
| `set-member?` | 2 | `pf_set_member` | Is this value present? |
| `set-remove!` | 2 | `pf_set_remove` | Remove a value if present; returns void. |
| `set-count` | 1 | `pf_set_count` | Number of values present. |
| `set->list` | 1 | `pf_set_to_list` | A list of the values present (unspecified order). |
| `set?` | 1 | `pf_set_huh` | Is this value a set (either flavor)? |
| `fixnum?` | 1 | `pf_fixnum_huh` | Is this value an integer? |
| `boolean?` | 1 | `pf_boolean_huh` | Is this value #t or #f? |
| `symbol?` | 1 | `pf_symbol_huh` | Is this value a symbol? |
| `void?` | 1 | `pf_void_huh` | Is this value void? |
| `procedure?` | 1 | `pf_procedure_huh` | Is this value a procedure (closure)? |

## Compiler-internal primitives

| Primitive | Arity | Runtime entry | Description |
|---|---|---|---|
| `make-closure` | 1 | `pf_make_closure` | INTERNAL: allocate a closure record with n slots. |
| `string-const` | 1 | `pf_string_const` | INTERNAL: the i-th string literal in the constant table. |

## Adding a primitive

1. Implement `pf_<name>` in a module under `src/runtime/lib/` (new data structures
   register their heap kind + display/equal handlers via `pf_register_kind`; add the
   module to `lib/stdlib_init.c` and the runtime `Makefile`, then `make -C src/runtime`).
2. Add one `prim-spec` entry to `src/stdlib.rkt` (name, arity, runtime symbol,
   reference implementation, doc line).
3. Regenerate this file. No compiler-pass changes are needed: the IR predicates,
   instruction selection, externs, and interpreters all derive from the manifest.
