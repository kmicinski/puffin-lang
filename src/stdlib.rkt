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
;;   type      OPTIONAL (#:type, default #f): the prim's gradual type
;;             (docs/TYPES.md), consumed by both typecheckers
;;             (src/types.rkt and, via gen-puffincc-tables.rkt,
;;             puffincc-src/types.puf). #f means untyped: the
;;             checkers derive (-> _ ... _) from the arity. Asserted
;;             against the arity at load time below.
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

;; The struct carries the type as a 7th field; `prim-spec` itself is a
;; thin constructor whose #:type keyword defaults to #f, so entries
;; (and future appended entries) may omit it.
(struct prim-spec-data (name arity rt-sym surface? ref-impl doc type) #:transparent)
(define (prim-spec name arity rt-sym surface? ref-impl doc #:type [type #f])
  (prim-spec-data name arity rt-sym surface? ref-impl doc type))
(define prim-spec-name     prim-spec-data-name)
(define prim-spec-arity    prim-spec-data-arity)
(define prim-spec-rt-sym   prim-spec-data-rt-sym)
(define prim-spec-surface? prim-spec-data-surface?)
(define prim-spec-ref-impl prim-spec-data-ref-impl)
(define prim-spec-doc      prim-spec-data-doc)
(define prim-spec-type     prim-spec-data-type)

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
;; Closures, reference-side (the procedure? contract). The C runtime
;; and the bytecode VM answer (procedure? v) with "is v's heap kind
;; CLOSURE" -- #t for lambdas, top-level functions used as values,
;; eta-expanded prims, and ADT constructor builders; #f for
;; everything else (a nullary constructor INSTANCE included: it is an
;; ADT value, not a function). The reference interpreters must agree,
;; so their closure representations live here, next to adt-value:
;;
;;   clo            the source-level interpreter's closure record
;;                  (interpreters.rkt eval-puffin-exp; repl.rkt)
;;   closure-record post-closure-convert IRs: (make-closure n)
;;                  allocates one -- a WRAPPED vector, so that
;;                  (vector? <closure>) and (procedure? <closure>)
;;                  answer like the runtime's dedicated kind, not
;;                  like the vector the class compiler used to leak.
;;                  unsafe-vector-ref/set! unwrap it (interpreters).
;;
;; The blocks-level interpreter represents a top-level function value
;; as its (fun-ref label) rhs; procedure? recognizes that spelling
;; too. (A user datum '(fun-ref x) would be indistinguishable at that
;; one IR level -- the source-level routes are unaffected.)
;; ---------------------------------------------------------------------

(struct clo (xs body env) #:transparent)
(struct closure-record (vec))

(define (procedure-value? v)
  (or (procedure? v)
      (clo? v)
      (closure-record? v)
      (match v [`(fun-ref ,(? symbol?)) #t] [_ #f])))

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
      ;; foreign handles: #<Regex 0x104a3c200>, #<Regex closed> --
      ;; exactly like lib/foreign.c's display_handle
      [(foreign-handle? v) (foreign-handle-render v out)]
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

;; ---------------------------------------------------------------------
;; Foreign handles, reference-side (docs/FFI.md §6): the C runtime's
;; kind 19 -- a branded, unforgeable wrapper around a raw C pointer.
;; ptr is an integer (the address), brand the (module-mangled)
;; define-foreign-type symbol, shown its source spelling (display),
;; closed? flips on #:consumes (null-on-close: use-after-close and
;; double-close are loud blamed errors). Only the FFI ref-impls below
;; construct one; equal? is identity (eqv? on the struct).
;; ---------------------------------------------------------------------

;; The struct itself lives in src/ffi-ref.rkt (the lazily-loaded FFI
;; module -- see the FFI section below), which installs its operations
;; here when it loads. Until then no handle can exist, so the
;; predicate answers #f without loading anything. Plain defines + a
;; box: zero module-load gensyms (the GENSYM-BUDGET note, system.rkt).
;;   ops vector: 0 predicate | 1 render(v out) | 2 brand | 3 closed?

(define ffi-handle-ops (box #f))
(define (foreign-handle? v)
  (define ops (unbox ffi-handle-ops))
  (if ops ((vector-ref ops 0) v) #f))
(define (foreign-handle-render v out) ((vector-ref (unbox ffi-handle-ops) 1) v out))
(define (foreign-handle-brand v) ((vector-ref (unbox ffi-handle-ops) 2) v))

;; The interpreters catch this to stop the program the way the
;; native runtime's exit(1) does.
(struct puffin-error-stop ())

(define (puffin-error-impl v)
  (display (format "error: ~a\n" (render-value v)))
  (raise (puffin-error-stop)))

;; ---------------------------------------------------------------------
;; FFI reference implementations (docs/FFI.md §8.3): the manifest
;; entries #%ffi-register / #%ffi-call0..6 carry ffi/unsafe-backed
;; ref-impls, so the reference interpreter is a REAL route -- every
;; §4/§5 check re-implemented byte-identically to lib/foreign.c. The
;; machinery lives in src/ffi-ref.rkt and is loaded LAZILY (a
;; dynamic-require on the first registration): a program that never
;; declares a foreign library never loads it, so the module-load
;; gensym budget -- and with it whole-program byte-identity -- is
;; untouched (see the GENSYM-BUDGET note in system.rkt).
;; ---------------------------------------------------------------------

(define (ffi-ref-path)
  ;; resolved lazily, at the first foreign registration (a
  ;; define-runtime-path here would cost a module-load gensym)
  (build-path (path-only (resolved-module-path-name
                          (variable-reference->resolved-module-path
                           (#%variable-reference))))
              "ffi-ref.rkt"))
(define ffi-ref-cache (make-hasheq))
(define (ffi-ref name)
  (or (hash-ref ffi-ref-cache name #f)
      (let ([v (dynamic-require (ffi-ref-path) name)])
        (hash-set! ffi-ref-cache name v)
        v)))
(define (ffi-register-impl rpath spath cname desc)
  ((ffi-ref 'ffi-register-impl) rpath spath cname desc))
(define (ffi-call-impl idx argv)
  ((ffi-ref 'ffi-call-impl) idx argv))

;; ---------------------------------------------------------------------
;; The manifest
;; ---------------------------------------------------------------------

(define stdlib-primitives
  (list
   ;; ---- I/O (core.c) -------------------------------------------------
   (prim-spec 'read     0 'pf_read_int #t 'read
              "Read an integer from standard input."
              #:type '(-> Int))
   (prim-spec 'println  1 'pf_println #t (λ (v) (display (render-value v)) (newline) (void))
              "Display a value followed by a newline; returns void."
              #:type '(-> a Void))
   (prim-spec 'display  1 'pf_display #t (λ (v) (display (render-value v)) (void))
              "Display a value (no newline); returns void."
              #:type '(-> a Void))
   (prim-spec 'newline  0 'pf_newline #t (λ () (newline) (void))
              "Print a newline; returns void."
              #:type '(-> Void))
   (prim-spec 'error    1 'pf_error #t puffin-error-impl
              "Display `error: <value>` and halt the program."
              #:type '(-> a _))

   ;; ---- generic equality (core.c) ------------------------------------
   (prim-spec 'equal?   2 'pf_equal #t puffin-equal?
              "Structural equality over pairs, vectors, and strings; identity otherwise."
              #:type '(-> a b Bool))

   ;; ---- pairs and lists (lib/pairs.c) --------------------------------
   (prim-spec 'cons     2 'pf_cons #t cons
              "Allocate a pair of two values."
              #:type '(-> a b (Pairof a b)))
   (prim-spec 'car      1 'pf_car #t car
              "First component of a pair (checked)."
              #:type '(-> (Pairof a b) a))
   (prim-spec 'cdr      1 'pf_cdr #t cdr
              "Second component of a pair (checked)."
              #:type '(-> (Pairof a b) b))
   (prim-spec 'pair?    1 'pf_pair_huh #t pair?
              "Is this value a pair?"
              #:type '(-> a Bool))
   (prim-spec 'null?    1 'pf_null_huh #t null?
              "Is this value the empty list '()?"
              #:type '(-> a Bool))

   ;; ---- vectors (lib/vectors.c) --------------------------------------
   (prim-spec 'make-vector 1 'pf_make_vector #t (λ (n) (make-vector n 0))
              "Allocate a vector of n slots, initialized to 0."
              #:type '(-> Int (Mut (Vec _))))
   (prim-spec 'vector-ref  2 'pf_vector_ref #t vector-ref
              "Fetch a slot (checked: type and bounds; dynamic index)."
              #:type '(-> (Vec a) Int a))
   (prim-spec 'vector-set! 3 'pf_vector_set #t (λ (v i x) (vector-set! v i x) (void))
              "Store into a slot (checked); returns void."
              #:type '(-> (Mut (Vec a)) Int a Void))
   (prim-spec 'vector-length 1 'pf_vector_length #t vector-length
              "Number of slots in a vector."
              #:type '(-> (Vec a) Int))
   (prim-spec 'vector?  1 'pf_vector_huh #t vector?
              "Is this value a vector?"
              #:type '(-> a Bool))

   ;; ---- strings (lib/strings.c) --------------------------------------
   (prim-spec 'string?  1 'pf_string_huh #t string?
              "Is this value a string?"
              #:type '(-> a Bool))
   (prim-spec 'string-length 1 'pf_string_length #t string-length
              "Number of bytes in a string."
              #:type '(-> Str Int))
   (prim-spec 'string-append 2 'pf_string_append #t string-append
              "Concatenate two strings."
              #:type '(-> Str Str Str))
   (prim-spec 'string=? 2 'pf_string_equal_huh #t string=?
              "Are two strings byte-equal?"
              #:type '(-> Str Str Bool))
   (prim-spec 'symbol->string 1 'pf_symbol_to_string #t symbol->string
              "The name of a symbol, as a fresh string."
              #:type '(-> Sym Str))
   (prim-spec 'string->symbol 1 'pf_string_to_symbol #t string->symbol
              "Intern a string as a symbol."
              #:type '(-> Str Sym))

   ;; ---- arithmetic helpers (lib/arith.c) ------------------------------
   (prim-spec 'quotient  2 'pf_quotient #t quotient
              "Integer division truncated toward zero (checked: nonzero divisor)."
              #:type '(-> Int Int Int))
   (prim-spec 'remainder 2 'pf_remainder #t remainder
              "Integer remainder (checked: nonzero divisor)."
              #:type '(-> Int Int Int))

   ;; ---- immutable hashes and sets (lib/hamt.c) --------------------------
   ;; The DEFAULT collections: persistent HAMTs (path-copying trie,
   ;; 64-way fanout; extension kinds 16/17). `hash-set` returns a new
   ;; hash; the input is untouched. Mutability is tolerated, not
   ;; default: see make-hash / make-set below.
   ;;
   ;; Keyed STRUCTURALLY (by equal?): heap values -- lists, vectors,
   ;; ADTs, computed strings, nested collections -- are valid keys and
   ;; elements, deduped by content (lib/hamt.c uses pf_hash + pf_equal;
   ;; the interpreter mirrors this with Racket's equal?-based (hash) /
   ;; (set), NOT hasheqv / seteqv, so interp and compiled agree).
   (prim-spec 'hash     0 'pf_ihash_empty #t (λ () (hash))
              "The empty immutable hash (keyed by equal?). (hash k v ...) builds one by chained hash-set."
              #:type '(-> (Hash _ _)))
   (prim-spec 'hash-set 3 'pf_ihash_set #t hash-set
              "A new immutable hash: like the input, with key mapped to value."
              #:type '(-> (Hash k v) k v (Hash k v)))
   (prim-spec 'hash-remove 2 'pf_ihash_remove #t hash-remove
              "A new immutable hash: like the input, without the key."
              #:type '(-> (Hash k v) k (Hash k v)))
   (prim-spec 'set      0 'pf_iset_empty #t (λ () (set))
              "The empty immutable set (keyed by equal?). (set v ...) builds one by chained set-add."
              #:type '(-> (Set _)))
   (prim-spec 'set-add  2 'pf_iset_add #t set-add
              "A new immutable set: like the input, with the value present."
              #:type '(-> (Set a) a (Set a)))
   (prim-spec 'set-remove 2 'pf_iset_remove #t set-remove
              "A new immutable set: like the input, without the value."
              #:type '(-> (Set a) a (Set a)))

   ;; ---- mutable hashes (lib/hashes.c) -----------------------------------
   (prim-spec 'make-hash 0 'pf_make_hash #t (λ () (make-hasheqv))
              "Allocate an empty MUTABLE key/value map (eq?-keyed, open addressing)."
              #:type '(-> (Mut (Hash _ _))))
   (prim-spec 'hash-set! 3 'pf_hash_set #t (λ (h k v) (hash-set! h k v) (void))
              "Map key to value (overwrites); returns void."
              #:type '(-> (Mut (Hash k v)) k v Void))
   (prim-spec 'hash-ref  2 'pf_hash_ref #t (λ (h k) (hash-ref h k (λ () (puffin-error-impl 'hash-ref-key-not-found))))
              "Look up a key (immutable or mutable hash); runtime error if absent."
              #:type '(-> (Hash k v) k v))
   (prim-spec 'hash-ref/default 3 'pf_hash_ref_default #t (λ (h k d) (hash-ref h k d))
              "Look up a key; return the default if absent."
              #:type '(-> (Hash k v) k v v))
   (prim-spec 'hash-has-key? 2 'pf_hash_has #t (λ (h k) (hash-has-key? h k))
              "Is this key present?"
              #:type '(-> (Hash k v) k Bool))
   (prim-spec 'hash-remove! 2 'pf_hash_remove #t (λ (h k) (hash-remove! h k) (void))
              "Remove a key if present; returns void."
              #:type '(-> (Mut (Hash k v)) k Void))
   (prim-spec 'hash-count 1 'pf_hash_count #t hash-count
              "Number of keys present."
              #:type '(-> (Hash k v) Int))
   (prim-spec 'hash-keys 1 'pf_hash_keys #t (λ (h) (hash-keys h))
              "A list of the keys present (unspecified order)."
              #:type '(-> (Hash k v) (List k)))
   (prim-spec 'hash?    1 'pf_hash_huh #t hash?
              "Is this value a hash (either flavor)?"
              #:type '(-> a Bool))

   ;; ---- mutable sets (lib/sets.c) ----------------------------------------
   (prim-spec 'make-set 0 'pf_make_set #t (λ () (mutable-seteqv))
              "Allocate an empty MUTABLE set (eq?-keyed, open addressing)."
              #:type '(-> (Mut (Set _))))
   (prim-spec 'set-add! 2 'pf_set_add #t (λ (s v) (set-add! s v) (void))
              "Add a value; returns void."
              #:type '(-> (Mut (Set a)) a Void))
   (prim-spec 'set-member? 2 'pf_set_member #t (λ (s v) (set-member? s v))
              "Is this value present?"
              #:type '(-> (Set a) a Bool))
   (prim-spec 'set-remove! 2 'pf_set_remove #t (λ (s v) (set-remove! s v) (void))
              "Remove a value if present; returns void."
              #:type '(-> (Mut (Set a)) a Void))
   (prim-spec 'set-count 1 'pf_set_count #t set-count
              "Number of values present."
              #:type '(-> (Set a) Int))
   (prim-spec 'set->list 1 'pf_set_to_list #t (λ (s) (set->list s))
              "A list of the values present (unspecified order)."
              #:type '(-> (Set a) (List a)))
   (prim-spec 'set?     1 'pf_set_huh #t (λ (v) (or (set-mutable? v)
                                                    (and (set? v) (not (list? v)))))
              "Is this value a set (either flavor)?"
              #:type '(-> a Bool))

   ;; ---- type predicates over immediates (lib/predicates.c) -------------
   (prim-spec 'fixnum?  1 'pf_fixnum_huh #t exact-integer?
              "Is this value an integer?"
              #:type '(-> a Bool))
   (prim-spec 'boolean? 1 'pf_boolean_huh #t boolean?
              "Is this value #t or #f?"
              #:type '(-> a Bool))
   (prim-spec 'symbol?  1 'pf_symbol_huh #t symbol?
              "Is this value a symbol?"
              #:type '(-> a Bool))
   (prim-spec 'void?    1 'pf_void_huh #t void?
              "Is this value void?"
              #:type '(-> a Bool))
   ;; the ref-impl recognizes the interpreters' closure
   ;; representations (see procedure-value? above), so every route --
   ;; interp, native, VM -- answers (procedure? (lambda (x) x)) => #t
   (prim-spec 'procedure? 1 'pf_procedure_huh #t procedure-value?
              "Is this value a procedure (closure)?"
              #:type '(-> a Bool))

   ;; ---- bootstrap batch (see docs/BOOTSTRAP.md) --------------------------
   (prim-spec 'gensym   1 'pf_gensym #t (λ (s) (gensym s))
              "A fresh symbol whose name extends the given one."
              #:type '(-> Sym Sym))
   (prim-spec 'value->string 1 'pf_to_string #t render-value
              "Render any value exactly as display would, into a string."
              #:type '(-> a Str))
   (prim-spec 'read-all 0 'pf_read_all #t 'read-all
              "The rest of standard input, as one string."
              #:type '(-> Str))
   (prim-spec 'substring 3 'pf_substring #t substring
              "Bytes [i, j) of a string (checked)."
              #:type '(-> Str Int Int Str))
   (prim-spec 'string<? 2 'pf_string_lt #t string<?
              "Lexicographic byte order on strings."
              #:type '(-> Str Str Bool))
   (prim-spec 'string-byte 2 'pf_string_byte #t (λ (s i) (char->integer (string-ref s i)))
              "The byte at an index (checked; strings are byte strings, ASCII-friendly)."
              #:type '(-> Str Int Int))
   (prim-spec 'number->string 1 'pf_number_to_string #t number->string
              "Decimal rendering of an integer."
              #:type '(-> Int Str))
   (prim-spec 'string->number 1 'pf_string_to_number #t
              (λ (s) (let ([n (string->number s)]) (if (exact-integer? n) n #f)))
              "The integer a string spells, or #f."
              #:type '(-> Str _))
   (prim-spec 'bitwise-and 2 'pf_bitwise_and #t bitwise-and
              "Bitwise AND of two integers."
              #:type '(-> Int Int Int))
   (prim-spec 'bitwise-ior 2 'pf_bitwise_ior #t bitwise-ior
              "Bitwise inclusive OR of two integers."
              #:type '(-> Int Int Int))
   (prim-spec 'bitwise-xor 2 'pf_bitwise_xor #t bitwise-xor
              "Bitwise exclusive OR of two integers."
              #:type '(-> Int Int Int))
   (prim-spec 'arithmetic-shift 2 'pf_arith_shift #t arithmetic-shift
              "Shift left (positive count) or right (negative count)."
              #:type '(-> Int Int Int))
   (prim-spec 'modulo   2 'pf_modulo #t modulo
              "Integer modulus; the result's sign follows the divisor (checked)."
              #:type '(-> Int Int Int))

   ;; ---- io: files, argv, subprocesses (lib/io.c) -------------------------
   ;; What a self-contained compiler driver needs: puffincc reads its
   ;; input modules, writes assembly, and shells out to the assembler.
   (prim-spec 'string-concat 1 'pf_string_concat #t
              (λ (xs) (apply string-append xs))
              "Concatenate a list of strings in one allocation (linear; string-join's backbone)."
              #:type '(-> (List Str) Str))
   (prim-spec 'read-file 1 'pf_read_file #t
              (λ (p) (file->string p))
              "The named file's bytes, as a string (exits with an error if unreadable)."
              #:type '(-> Str Str))
   (prim-spec 'write-file 2 'pf_write_file #t
              (λ (p s) (call-with-output-file p #:exists 'replace (λ (o) (display s o))) (void))
              "(Re)write the named file with the string's bytes."
              #:type '(-> Str Str Void))
   (prim-spec 'file-exists? 1 'pf_file_exists_huh #t
              (λ (p) (file-exists? p))
              "Whether the named file exists and is readable."
              #:type '(-> Str Bool))
   (prim-spec 'command-line-args 0 'pf_command_line_args #t
              (λ () (vector->list (current-command-line-arguments)))
              "The program's command-line arguments (a list of strings, argv[0] excluded)."
              #:type '(-> (List Str)))
   (prim-spec 'system 1 'pf_system #t
              (λ (cmd) (system/exit-code cmd))
              "Run a shell command; its exit code."
              #:type '(-> Str Int))

   ;; ---- compiler-internal ----------------------------------------------
   ;; make-closure allocates a closure record (kind 4): slot 0 holds
   ;; the code pointer, the rest capture the environment. Only
   ;; lift-lambdas emits it; user code cannot name it. The reference
   ;; representation is a WRAPPED vector (closure-record above), so
   ;; procedure?/vector? answer like the runtime's dedicated kind.
   (prim-spec 'make-closure 1 'pf_make_closure #f
              (λ (n) (closure-record (make-vector n 0)))
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

   ;; ---- diagnostics (core.c) ---------------------------------------------
   ;; eprintln is the typecheckers' non-fatal diagnostics channel
   ;; (exhaustiveness warnings must not pollute stdout, which the
   ;; golden harnesses compare). Appended to the manifest, so every
   ;; existing prim id (a manifest index) is unchanged.
   (prim-spec 'eprintln 1 'pf_eprintln #t
              (λ (v) (displayln (render-value v) (current-error-port)) (void))
              "Display a value followed by a newline on standard error; returns void."
              #:type '(-> a Void))

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
              "Is this value a define-type constructor instance?"
              #:type '(-> a Bool))

   ;; ---- transient casts (lib/cast.c) -------------------------------------
   ;; The dynamic half of the gradual types (docs/TYPES.md §4): both
   ;; desugars guard every DECLARED annotation boundary with a
   ;; cast-check call. FIRST-ORDER: only the value's outermost shape
   ;; is validated against desc (a symbol for base kinds and heap
   ;; shapes; (adt <type> tag ...) for define-types); blame is a
   ;; compile-time string naming the boundary. On failure the C side
   ;; pf_fatal's -- this reference impl prints the IDENTICAL line to
   ;; stderr and exits 255, so the two are byte-for-byte comparable.
   ;; Appended to the manifest: existing prim ids (manifest indices)
   ;; are unchanged. Deliberately in NO purity table (src/opt/*,
   ;; puffincc-src/{contract,aam}.puf): a cast can abort, so it must
   ;; never be dropped or folded.
   (prim-spec 'cast-check 3 'pf_cast_check #f
              (λ (v desc blame)
                (define ok?
                  (cond
                    [(symbol? desc)
                     (case desc
                       [(Int)    (exact-integer? v)]
                       [(Bool)   (boolean? v)]
                       [(Sym)    (symbol? v)]
                       [(Str)    (string? v)]
                       [(Void)   (void? v)]
                       [(Pairof) (pair? v)]
                       [(List)   (or (null? v) (pair? v))]
                       [(Vec)    (vector? v)]
                       [(Hash)   (hash? v)]
                       ;; Racket's generic set? is #t for lists and
                       ;; hashes too; exclude them (C never would)
                       [(Set)    (or (set-mutable? v)
                                     (and (set? v) (not (pair? v))
                                          (not (null? v)) (not (hash? v))))]
                       [else #t])]
                    [(and (pair? desc) (eq? (car desc) 'adt))
                     (and (adt-value? v)
                          (memq (adt-value-tag v) (cddr desc)) #t)]
                    ;; (fptr <shown> <brand>): a define-foreign-type
                    ;; annotation -- kind 19 + brand (docs/FFI.md §6.1)
                    [(and (pair? desc) (eq? (car desc) 'fptr))
                     (and (foreign-handle? v)
                          (eq? (foreign-handle-brand v) (caddr desc)))]
                    [else #t]))
                (cond
                  [ok? v]
                  [else
                   (define shown
                     (if (and (pair? desc) (memq (car desc) '(adt fptr))) (cadr desc) desc))
                   (flush-output)
                   (fprintf (current-error-port)
                            "puffin runtime error: cast: expected ~a, got ~a (blame: ~a)\n"
                            (render-value shown) (render-value v) (render-value blame))
                   (exit 255)]))
              "INTERNAL: first-order transient cast: v unless its outermost shape violates desc; fatal cast error naming blame otherwise.")

   ;; ---- the FFI (lib/foreign.c; docs/FFI.md) ----------------------------
   ;; A `foreign` declaration lowers in desugar to ordinary code over
   ;; these internal prims: one #%ffi-register at module load (dlopen
   ;; + dlsym; a missing library/symbol is a load-time error), one
   ;; #%ffi-calln per call (the type-directed generic caller: check +
   ;; convert each argument per the desc, call, construct the result).
   ;; #%ffi-call6 takes its six arguments PACKED in a vector (the
   ;; import index occupies one of the six prim argument registers).
   ;; foreign-ptr? is the disjoint surface predicate for heap kind 19.
   ;; Appended to the manifest: every existing prim id is unchanged.
   (prim-spec '#%ffi-register 4 'pf_ffi_register #f
              ffi-register-impl
              "INTERNAL: dlopen+dlsym a foreign import per its desc; returns the import's index.")
   (prim-spec '#%ffi-call0 1 'pf_ffi_call0 #f
              (λ (i) (ffi-call-impl i '()))
              "INTERNAL: call foreign import i with no arguments.")
   (prim-spec '#%ffi-call1 2 'pf_ffi_call1 #f
              (λ (i a) (ffi-call-impl i (list a)))
              "INTERNAL: call foreign import i with 1 argument.")
   (prim-spec '#%ffi-call2 3 'pf_ffi_call2 #f
              (λ (i a b) (ffi-call-impl i (list a b)))
              "INTERNAL: call foreign import i with 2 arguments.")
   (prim-spec '#%ffi-call3 4 'pf_ffi_call3 #f
              (λ (i a b c) (ffi-call-impl i (list a b c)))
              "INTERNAL: call foreign import i with 3 arguments.")
   (prim-spec '#%ffi-call4 5 'pf_ffi_call4 #f
              (λ (i a b c d) (ffi-call-impl i (list a b c d)))
              "INTERNAL: call foreign import i with 4 arguments.")
   (prim-spec '#%ffi-call5 6 'pf_ffi_call5 #f
              (λ (i a b c d e) (ffi-call-impl i (list a b c d e)))
              "INTERNAL: call foreign import i with 5 arguments.")
   (prim-spec '#%ffi-call6 2 'pf_ffi_call6 #f
              (λ (i argv) (ffi-call-impl i (vector->list argv)))
              "INTERNAL: call foreign import i with 6 arguments, packed in a vector.")
   (prim-spec 'foreign-ptr? 1 'pf_foreign_ptr_huh #t
              foreign-handle?
              "Is this value a foreign handle (an opaque pointer from a foreign library)?"
              #:type '(-> a Bool))))

;; manifest self-agreement: a typed prim's arrow arity must equal its
;; declared arity (the type field cannot drift from the manifest it
;; lives in). ->* types never appear here: manifest prims have fixed
;; arity by construction.
(for ([s stdlib-primitives])
  (define t (prim-spec-type s))
  (when t
    (match t
      [`(-> ,args ... ,_)
       (unless (= (prim-spec-arity s) (length args))
         (error 'stdlib "manifest type arity mismatch for ~a: arity ~a, type ~a"
                (prim-spec-name s) (prim-spec-arity s) t))]
      [_ (error 'stdlib "manifest type for ~a is not an arrow: ~a"
                (prim-spec-name s) t)])))

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
(define (stdlib-type op)    (prim-spec-type (stdlib-spec op)))  ;; #f = untyped

;; All runtime entry points the generated assembly may reference
;; (externs for the dump passes).
(define (stdlib-extern-symbols)
  (append '(pf_init pf_print_result pf_die_oob pf_die_kind pf_die_arith)
          (map prim-spec-rt-sym stdlib-primitives)))
