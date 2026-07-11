#lang racket

;; Puffin -- stdlib.rkt: the standard library manifest.
;;
;; This file is the single source of truth for Puffin's library
;; primitives. Every entry declares:
;;
;;   name      the source-level identifier, e.g. hash-set!
;;   arity     number of arguments (fixed; no optionals in the core)
;;   rt-sym    the C entry point in src/runtime/lib/*.c, e.g. pf_hash_set
;;   surface?  usable in user programs? (#f = compiler-internal)
;;   ref-impl  the *reference semantics*: a Racket procedure over the
;;             interpreters' value representation (see below); or one
;;             of the special markers 'read / 'error, which the
;;             interpreters handle themselves (input threading /
;;             control flow)
;;   doc       one-line documentation (docs/STDLIB.md is generated
;;             from these)
;;
;; Derived automatically from this table:
;;   - the prim?/arity predicates used by every IR in irs.rkt
;;   - instruction selection (each prim becomes a call to rt-sym with
;;     arguments in the argument registers; see the backends)
;;   - the .extern declarations in emitted assembly
;;   - the behavior of every interpreter in interpreters.rkt
;;   - docs/STDLIB.md
;;
;; To add a library feature: implement pf_* in a (possibly new)
;; module under src/runtime/lib/, add one entry here, and rebuild
;; libpuffin.a. No compiler pass changes.
;;
;; NOT in this table: compiler intrinsics (+ - * eq? < and the
;; unsafe-vector ops), which the backends open-code, and control
;; forms. Those are the compiler's own vocabulary, not the library's.
;;
;; Reference value representation (shared by all interpreters and
;; the REPL): fixnum -> Racket exact integer; booleans -> booleans;
;; (void) -> (void); '() -> '(); symbols -> symbols; pairs -> pairs;
;; vectors -> mutable Racket vectors; strings -> strings;
;; hashes -> Racket mutable hasheqv; sets -> Racket mutable seteqv;
;; closures -> the interpreters' own closure records.

(require racket/set)
(provide (all-defined-out))

(struct prim-spec (name arity rt-sym surface? ref-impl doc) #:transparent)

;; ---------------------------------------------------------------------
;; ADT constructor instances (docs/TYPES.md §2): the reference-side
;; representation of a define-type constructor instance. A dedicated
;; struct -- NOT a vector -- mirroring the C runtime's dedicated heap
;; kind (src/runtime/lib/adt.c, kind 18): (vector? (Some 1)) is #f,
;; adt? is the disjoint surface predicate. tag is the constructor's
;; (module-mangled) symbol; fields is a mutable Racket vector, set
;; once by the desugar-emitted adt-set! calls and read by adt-ref.
;; ---------------------------------------------------------------------

(struct adt-value (tag fields))

;; ---------------------------------------------------------------------
;; Reference display / equality -- must render *exactly* like the C
;; runtime's pf_display_value / pf_equal (core.c dispatching through
;; the kind registry). Golden tests compare these byte-for-byte.
;; ---------------------------------------------------------------------

(define (render-value v)
  (define out (open-output-string))
  (let render ([v v])
    (cond
      [(exact-integer? v) (write v out)]
      [(boolean? v)       (display (if v "#t" "#f") out)]
      [(void? v)          (display "#<void>" out)]
      [(null? v)          (display "()" out)]
      [(symbol? v)        (display v out)]
      [(string? v)        (display v out)]
      [(pair? v)
       (display "(" out)
       (render (car v))
       (let loop ([rest (cdr v)])
         (cond [(pair? rest) (display " " out) (render (car rest)) (loop (cdr rest))]
               [(null? rest) (void)]
               [else (display " . " out) (render rest)]))
       (display ")" out)]
      [(vector? v)
       (display "#(" out)
       (for ([x v] [i (in-naturals)])
         (when (positive? i) (display " " out))
         (render x))
       (display ")" out)]
      ;; ADT instances: (Some 1); nullary constructors print bare: None
      [(adt-value? v)
       (define fs (adt-value-fields v))
       (cond
         [(zero? (vector-length fs)) (display (adt-value-tag v) out)]
         [else
          (display "(" out)
          (display (adt-value-tag v) out)
          (for ([x fs]) (display " " out) (render x))
          (display ")" out)])]
      [(hash? v)          (display (format "#<hash:~a>" (hash-count v)) out)]
      [(or (set-mutable? v) (set? v))
                          (display (format "#<set:~a>" (set-count v)) out)]
      [else               (display "#<procedure>" out)]))
  (get-output-string out))

;; equal? in Puffin: structural over pairs/vectors/strings, identity
;; for everything else (including hashes and sets).
(define (puffin-equal? a b)
  (cond
    [(eqv? a b) #t]
    [(and (pair? a) (pair? b))
     (and (puffin-equal? (car a) (car b)) (puffin-equal? (cdr a) (cdr b)))]
    [(and (vector? a) (vector? b))
     (and (= (vector-length a) (vector-length b))
          (for/and ([x a] [y b]) (puffin-equal? x y)))]
    ;; ADT instances: same constructor, equal? fields
    [(and (adt-value? a) (adt-value? b))
     (and (eq? (adt-value-tag a) (adt-value-tag b))
          (= (vector-length (adt-value-fields a)) (vector-length (adt-value-fields b)))
          (for/and ([x (adt-value-fields a)] [y (adt-value-fields b)])
            (puffin-equal? x y)))]
    [(and (string? a) (string? b)) (string=? a b)]
    ;; immutable collections are values: compare by contents
    ;; (mutable ones stay identity-compared)
    [(and (hash? a) (hash? b) (immutable? a) (immutable? b))
     (and (= (hash-count a) (hash-count b))
          (for/and ([(k v) (in-hash a)])
            (and (hash-has-key? b k) (puffin-equal? v (hash-ref b k)))))]
    ;; note: Racket's set? counts *lists* as generic sets; exclude
    ;; them or a list could compare equal? to a set (C never would)
    [(and (set? a) (set? b) (not (list? a)) (not (list? b))
          (not (set-mutable? a)) (not (set-mutable? b)))
     (and (= (set-count a) (set-count b))
          (for/and ([k (in-set a)]) (set-member? b k)))]
    [else #f]))

;; The interpreters catch this to stop the program the way the
;; native runtime's exit(1) does.
(struct puffin-error-stop ())

(define (puffin-error-impl v)
  (display (format "error: ~a\n" (render-value v)))
  (raise (puffin-error-stop)))

;; ---------------------------------------------------------------------
;; The manifest
;; ---------------------------------------------------------------------

(define stdlib-primitives
  (list
   ;; ---- I/O (core.c) -------------------------------------------------
   (prim-spec 'read     0 'pf_read_int #t 'read
              "Read an integer from standard input.")
   (prim-spec 'println  1 'pf_println #t (λ (v) (display (render-value v)) (newline) (void))
              "Display a value followed by a newline; returns void.")
   (prim-spec 'display  1 'pf_display #t (λ (v) (display (render-value v)) (void))
              "Display a value (no newline); returns void.")
   (prim-spec 'newline  0 'pf_newline #t (λ () (newline) (void))
              "Print a newline; returns void.")
   (prim-spec 'error    1 'pf_error #t puffin-error-impl
              "Display `error: <value>` and halt the program.")

   ;; ---- generic equality (core.c) ------------------------------------
   (prim-spec 'equal?   2 'pf_equal #t puffin-equal?
              "Structural equality over pairs, vectors, and strings; identity otherwise.")

   ;; ---- pairs and lists (lib/pairs.c) --------------------------------
   (prim-spec 'cons     2 'pf_cons #t cons
              "Allocate a pair of two values.")
   (prim-spec 'car      1 'pf_car #t car
              "First component of a pair (checked).")
   (prim-spec 'cdr      1 'pf_cdr #t cdr
              "Second component of a pair (checked).")
   (prim-spec 'pair?    1 'pf_pair_huh #t pair?
              "Is this value a pair?")
   (prim-spec 'null?    1 'pf_null_huh #t null?
              "Is this value the empty list '()?")

   ;; ---- vectors (lib/vectors.c) --------------------------------------
   (prim-spec 'make-vector 1 'pf_make_vector #t (λ (n) (make-vector n 0))
              "Allocate a vector of n slots, initialized to 0.")
   (prim-spec 'vector-ref  2 'pf_vector_ref #t vector-ref
              "Fetch a slot (checked: type and bounds; dynamic index).")
   (prim-spec 'vector-set! 3 'pf_vector_set #t (λ (v i x) (vector-set! v i x) (void))
              "Store into a slot (checked); returns void.")
   (prim-spec 'vector-length 1 'pf_vector_length #t vector-length
              "Number of slots in a vector.")
   (prim-spec 'vector?  1 'pf_vector_huh #t vector?
              "Is this value a vector?")

   ;; ---- strings (lib/strings.c) --------------------------------------
   (prim-spec 'string?  1 'pf_string_huh #t string?
              "Is this value a string?")
   (prim-spec 'string-length 1 'pf_string_length #t string-length
              "Number of bytes in a string.")
   (prim-spec 'string-append 2 'pf_string_append #t string-append
              "Concatenate two strings.")
   (prim-spec 'string=? 2 'pf_string_equal_huh #t string=?
              "Are two strings byte-equal?")
   (prim-spec 'symbol->string 1 'pf_symbol_to_string #t symbol->string
              "The name of a symbol, as a fresh string.")
   (prim-spec 'string->symbol 1 'pf_string_to_symbol #t string->symbol
              "Intern a string as a symbol.")

   ;; ---- arithmetic helpers (lib/arith.c) ------------------------------
   (prim-spec 'quotient  2 'pf_quotient #t quotient
              "Integer division truncated toward zero (checked: nonzero divisor).")
   (prim-spec 'remainder 2 'pf_remainder #t remainder
              "Integer remainder (checked: nonzero divisor).")

   ;; ---- immutable hashes and sets (lib/hamt.c) --------------------------
   ;; The DEFAULT collections: persistent HAMTs (path-copying trie,
   ;; 64-way fanout; extension kinds 16/17). `hash-set` returns a new
   ;; hash; the input is untouched. Mutability is tolerated, not
   ;; default: see make-hash / make-set below.
   (prim-spec 'hash     0 'pf_ihash_empty #t (λ () (hasheqv))
              "The empty immutable hash. (hash k v ...) builds one by chained hash-set.")
   (prim-spec 'hash-set 3 'pf_ihash_set #t hash-set
              "A new immutable hash: like the input, with key mapped to value.")
   (prim-spec 'hash-remove 2 'pf_ihash_remove #t hash-remove
              "A new immutable hash: like the input, without the key.")
   (prim-spec 'set      0 'pf_iset_empty #t (λ () (seteqv))
              "The empty immutable set. (set v ...) builds one by chained set-add.")
   (prim-spec 'set-add  2 'pf_iset_add #t set-add
              "A new immutable set: like the input, with the value present.")
   (prim-spec 'set-remove 2 'pf_iset_remove #t set-remove
              "A new immutable set: like the input, without the value.")

   ;; ---- mutable hashes (lib/hashes.c) -----------------------------------
   (prim-spec 'make-hash 0 'pf_make_hash #t (λ () (make-hasheqv))
              "Allocate an empty MUTABLE key/value map (eq?-keyed, open addressing).")
   (prim-spec 'hash-set! 3 'pf_hash_set #t (λ (h k v) (hash-set! h k v) (void))
              "Map key to value (overwrites); returns void.")
   (prim-spec 'hash-ref  2 'pf_hash_ref #t (λ (h k) (hash-ref h k (λ () (puffin-error-impl 'hash-ref-key-not-found))))
              "Look up a key (immutable or mutable hash); runtime error if absent.")
   (prim-spec 'hash-ref/default 3 'pf_hash_ref_default #t (λ (h k d) (hash-ref h k d))
              "Look up a key; return the default if absent.")
   (prim-spec 'hash-has-key? 2 'pf_hash_has #t (λ (h k) (hash-has-key? h k))
              "Is this key present?")
   (prim-spec 'hash-remove! 2 'pf_hash_remove #t (λ (h k) (hash-remove! h k) (void))
              "Remove a key if present; returns void.")
   (prim-spec 'hash-count 1 'pf_hash_count #t hash-count
              "Number of keys present.")
   (prim-spec 'hash-keys 1 'pf_hash_keys #t (λ (h) (hash-keys h))
              "A list of the keys present (unspecified order).")
   (prim-spec 'hash?    1 'pf_hash_huh #t hash?
              "Is this value a hash (either flavor)?")

   ;; ---- mutable sets (lib/sets.c) ----------------------------------------
   (prim-spec 'make-set 0 'pf_make_set #t (λ () (mutable-seteqv))
              "Allocate an empty MUTABLE set (eq?-keyed, open addressing).")
   (prim-spec 'set-add! 2 'pf_set_add #t (λ (s v) (set-add! s v) (void))
              "Add a value; returns void.")
   (prim-spec 'set-member? 2 'pf_set_member #t (λ (s v) (set-member? s v))
              "Is this value present?")
   (prim-spec 'set-remove! 2 'pf_set_remove #t (λ (s v) (set-remove! s v) (void))
              "Remove a value if present; returns void.")
   (prim-spec 'set-count 1 'pf_set_count #t set-count
              "Number of values present.")
   (prim-spec 'set->list 1 'pf_set_to_list #t (λ (s) (set->list s))
              "A list of the values present (unspecified order).")
   (prim-spec 'set?     1 'pf_set_huh #t (λ (v) (or (set-mutable? v)
                                                    (and (set? v) (not (list? v)))))
              "Is this value a set (either flavor)?")

   ;; ---- type predicates over immediates (lib/predicates.c) -------------
   (prim-spec 'fixnum?  1 'pf_fixnum_huh #t exact-integer?
              "Is this value an integer?")
   (prim-spec 'boolean? 1 'pf_boolean_huh #t boolean?
              "Is this value #t or #f?")
   (prim-spec 'symbol?  1 'pf_symbol_huh #t symbol?
              "Is this value a symbol?")
   (prim-spec 'void?    1 'pf_void_huh #t void?
              "Is this value void?")
   (prim-spec 'procedure? 1 'pf_procedure_huh #t (λ (v) (procedure? v))
              "Is this value a procedure (closure)?")

   ;; ---- bootstrap batch (see docs/BOOTSTRAP.md) --------------------------
   (prim-spec 'gensym   1 'pf_gensym #t (λ (s) (gensym s))
              "A fresh symbol whose name extends the given one.")
   (prim-spec 'value->string 1 'pf_to_string #t render-value
              "Render any value exactly as display would, into a string.")
   (prim-spec 'read-all 0 'pf_read_all #t 'read-all
              "The rest of standard input, as one string.")
   (prim-spec 'substring 3 'pf_substring #t substring
              "Bytes [i, j) of a string (checked).")
   (prim-spec 'string<? 2 'pf_string_lt #t string<?
              "Lexicographic byte order on strings.")
   (prim-spec 'string-byte 2 'pf_string_byte #t (λ (s i) (char->integer (string-ref s i)))
              "The byte at an index (checked; strings are byte strings, ASCII-friendly).")
   (prim-spec 'number->string 1 'pf_number_to_string #t number->string
              "Decimal rendering of an integer.")
   (prim-spec 'string->number 1 'pf_string_to_number #t
              (λ (s) (let ([n (string->number s)]) (if (exact-integer? n) n #f)))
              "The integer a string spells, or #f.")
   (prim-spec 'bitwise-and 2 'pf_bitwise_and #t bitwise-and
              "Bitwise AND of two integers.")
   (prim-spec 'bitwise-ior 2 'pf_bitwise_ior #t bitwise-ior
              "Bitwise inclusive OR of two integers.")
   (prim-spec 'bitwise-xor 2 'pf_bitwise_xor #t bitwise-xor
              "Bitwise exclusive OR of two integers.")
   (prim-spec 'arithmetic-shift 2 'pf_arith_shift #t arithmetic-shift
              "Shift left (positive count) or right (negative count).")
   (prim-spec 'modulo   2 'pf_modulo #t modulo
              "Integer modulus; the result's sign follows the divisor (checked).")

   ;; ---- io: files, argv, subprocesses (lib/io.c) -------------------------
   ;; What a self-contained compiler driver needs: puffincc reads its
   ;; input modules, writes assembly, and shells out to the assembler.
   (prim-spec 'string-concat 1 'pf_string_concat #t
              (λ (xs) (apply string-append xs))
              "Concatenate a list of strings in one allocation (linear; string-join's backbone).")
   (prim-spec 'read-file 1 'pf_read_file #t
              (λ (p) (file->string p))
              "The named file's bytes, as a string (exits with an error if unreadable).")
   (prim-spec 'write-file 2 'pf_write_file #t
              (λ (p s) (call-with-output-file p #:exists 'replace (λ (o) (display s o))) (void))
              "(Re)write the named file with the string's bytes.")
   (prim-spec 'file-exists? 1 'pf_file_exists_huh #t
              (λ (p) (file-exists? p))
              "Whether the named file exists and is readable.")
   (prim-spec 'command-line-args 0 'pf_command_line_args #t
              (λ () (vector->list (current-command-line-arguments)))
              "The program's command-line arguments (a list of strings, argv[0] excluded).")
   (prim-spec 'system 1 'pf_system #t
              (λ (cmd) (system/exit-code cmd))
              "Run a shell command; its exit code.")

   ;; ---- compiler-internal ----------------------------------------------
   ;; make-closure allocates a closure record (kind 4): slot 0 holds
   ;; the code pointer, the rest capture the environment. Only
   ;; lift-lambdas emits it; user code cannot name it.
   (prim-spec 'make-closure 1 'pf_make_closure #f (λ (n) (make-vector n 0))
              "INTERNAL: allocate a closure record with n slots.")
   ;; string-const materializes the i-th string literal; only the
   ;; desugared form (string-lit s) lowers to it.
   (prim-spec 'string-const 1 'pf_string_const #f #f
              "INTERNAL: the i-th string literal in the constant table.")
   ;; bytes->string builds a byte string from a list of byte values
   ;; (0-255): the char-free way to EMIT binary output, used by the
   ;; bytecode backend's render-pbc to assemble a .pbc unit. The
   ;; inverse of string-byte. Appended to the manifest, so every
   ;; existing prim id (a manifest index) is unchanged -- .pbc bytes
   ;; for programs that never call it are byte-identical.
   (prim-spec 'bytes->string 1 'pf_bytes_to_string #f
              (λ (lst) (list->string (map integer->char lst)))
              "INTERNAL: a byte string from a list of byte values 0-255.")

   ;; ---- ADT constructor instances (lib/adt.c) ---------------------------
   ;; The dedicated heap kind for define-type constructor instances
   ;; (docs/TYPES.md §2, kind 18). Only the desugar lowering emits the
   ;; internal four -- construction (adt-alloc + adt-set!, mirroring
   ;; how (vector ...) lowers) and match compilation (adt-tag +
   ;; adt-ref) -- so user code cannot forge an instance. adt? is the
   ;; surface predicate, disjoint from vector?. Appended to the
   ;; manifest: every existing prim id (a manifest index) is unchanged.
   (prim-spec 'adt-alloc 2 'pf_adt_alloc #f
              (λ (tag n) (adt-value tag (make-vector n 0)))
              "INTERNAL: a constructor instance with the tag symbol and n zeroed fields.")
   (prim-spec 'adt-set! 3 'pf_adt_set #f
              (λ (a i x) (vector-set! (adt-value-fields a) i x) (void))
              "INTERNAL: initialize field i of a constructor instance; returns void.")
   (prim-spec 'adt-ref 2 'pf_adt_ref #f
              (λ (a i) (vector-ref (adt-value-fields a) i))
              "INTERNAL: field i of a constructor instance (checked).")
   (prim-spec 'adt-tag 1 'pf_adt_tag #f
              adt-value-tag
              "INTERNAL: the constructor symbol of an instance.")
   (prim-spec 'adt? 1 'pf_adt_huh #t
              adt-value?
              "Is this value a define-type constructor instance?")))

;; ---------------------------------------------------------------------
;; Derived views (used by irs.rkt, the backends, and interpreters.rkt)
;; ---------------------------------------------------------------------

(define (stdlib-prim? op)
  (for/or ([s stdlib-primitives]) (equal? (prim-spec-name s) op)))

(define (surface-stdlib-prim? op)
  (for/or ([s stdlib-primitives]) (and (prim-spec-surface? s) (equal? (prim-spec-name s) op))))

(define (stdlib-spec op)
  (findf (λ (s) (equal? (prim-spec-name s) op)) stdlib-primitives))

(define (stdlib-prims-of-arity n)
  (map prim-spec-name (filter (λ (s) (= (prim-spec-arity s) n)) stdlib-primitives)))

(define (stdlib-rt-sym op)  (prim-spec-rt-sym (stdlib-spec op)))
(define (stdlib-arity op)   (prim-spec-arity (stdlib-spec op)))
(define (stdlib-ref-impl op) (prim-spec-ref-impl (stdlib-spec op)))

;; All runtime entry points the generated assembly may reference
;; (externs for the dump passes).
(define (stdlib-extern-symbols)
  (append '(pf_init pf_print_result pf_die_oob pf_die_kind pf_die_arith)
          (map prim-spec-rt-sym stdlib-primitives)))
