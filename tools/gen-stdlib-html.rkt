#lang racket

;; Puffin -- gen-stdlib-html.rkt: the styled standard-library
;; reference (docs/stdlib.html + web/public/stdlib.html) is
;; *generated*, so it cannot drift from the implementation:
;;
;;   racket tools/gen-stdlib-html.rkt
;;
;; Single sources of truth:
;;   - src/stdlib.rkt        every surface prim's name/arity/type/doc
;;   - src/prelude.puf       every prelude function's name + trusted
;;                           (#%prelude: ...) signature + `;;>` doc
;;                           comment (the line above each define)
;;   - the intrinsics table below, mirroring src/types.rkt's
;;     non-manifest-prim-types (asserted small; update both together)
;;
;; Docs as tests: EVERY example and recipe on the page is executed
;; against the reference interpreter (the same desugar+interpret the
;; golden corpus trusts, typechecker included) and its shown output
;; is asserted byte-for-byte. A wrong example fails generation.
;; Output comments (";; ..." / ";; prints:") are rendered FROM the
;; verified output, so the page cannot lie.

(require racket/runtime-path)
(require "../src/stdlib.rkt")
(require "../src/main.rkt")         ;; read-program-file
(require "../src/compile.rkt")      ;; desugar (typechecks)
(require "../src/interpreters.rkt") ;; interpret-puffin

(define-runtime-path here ".")
(define prelude-path  (build-path here 'up "src" "prelude.puf"))
(define docs-out      (build-path here 'up "docs" "stdlib.html"))
(define web-out       (build-path here 'up "web" "public" "stdlib.html"))

;; ---------------------------------------------------------------------
;; Intrinsics: open-coded by the backends (src/irs.rkt), typed by
;; src/types.rkt non-manifest-prim-types. Kept here verbatim because
;; types.rkt deliberately exports only the checker; if you touch one
;; table, touch the other.
;; ---------------------------------------------------------------------

(define intrinsics
  `((+   (-> Int Int Int) "Fixnum addition; n-ary in source, associating left.")
    (-   (-> Int Int Int) "Fixnum subtraction; unary (- n) negates.")
    (*   (-> Int Int Int) "Fixnum multiplication; n-ary in source, associating left.")
    (<   (-> Int Int Bool) "Is the first integer strictly smaller?")
    (<=  (-> Int Int Bool) "Is the first integer smaller or equal?")
    (>   (-> Int Int Bool) "Is the first integer strictly larger?")
    (>=  (-> Int Int Bool) "Is the first integer larger or equal?")
    (eq? (-> a b Bool) "Identity equality: fixnums, booleans, symbols, or the same heap object. Use equal? for structural comparison.")
    (not (-> a Bool) "Logical negation: #t exactly when v is #f (only #f is false).")))

;; ---------------------------------------------------------------------
;; Prelude extraction: forms via `read` (signatures + defines), docs
;; via a line scan for `;;>` comments (each applies to the next
;; top-level (#%prelude: ...) or (define ...) at column 0).
;; ---------------------------------------------------------------------

(struct pfun (name type doc) #:transparent)

(define (prelude-functions)
  ;; pass A: semantic -- signature types and define arities, in order
  (define forms
    (with-input-from-file prelude-path
      (λ () (let loop ([acc '()])
              (define f (read))
              (if (eof-object? f) (reverse acc) (loop (cons f acc)))))))
  (define sigs (make-hasheq))
  (define defines '())   ;; (name . derived-type) in order
  (for ([f forms])
    (match f
      [`(#%prelude: ,n ,t) (hash-set! sigs n t)]
      [`(define (,n . ,formals) ,_ ...)
       (define arity (let count ([fs formals] [k 0])
                       (cond [(null? fs) k]
                             [(pair? fs) (count (cdr fs) (+ k 1))]
                             [else (+ k 1)])))  ;; dotted rest arg
       (set! defines (cons (cons n `(-> ,@(make-list arity '_) _)) defines))]
      [`(define ,(? symbol? n) ,_) (set! defines (cons (cons n '_) defines))]
      [_ (void)]))
  (set! defines (reverse defines))
  ;; pass B: docs -- `;;>` line attaches to the next column-0 form
  (define docs (make-hasheq))
  (define pending #f)
  (for ([line (file->lines prelude-path)])
    (cond
      [(regexp-match #rx"^;;> *(.*)$" line)
       => (λ (m) (set! pending (cadr m)))]
      [(and pending (regexp-match #rx"^\\((#%prelude:|define) +\\(? *([^ ()]+)" line))
       => (λ (m)
            (hash-set! docs (string->symbol (caddr m)) pending)
            (set! pending #f))]
      [else (void)]))
  (for/list ([d defines])
    (define n (car d))
    (unless (hash-ref docs n #f)
      (error 'gen-stdlib-html "prelude function ~a has no ;;> doc comment" n))
    (pfun n (hash-ref sigs n (cdr d)) (hash-ref docs n))))

;; ---------------------------------------------------------------------
;; The entries: name -> (source type doc), from the three sources
;; ---------------------------------------------------------------------

(struct entry (name source type doc) #:transparent)  ;; source: intrinsic|prim|prelude

(define all-entries
  (append
   (for/list ([i intrinsics]) (entry (first i) 'intrinsic (second i) (third i)))
   (for/list ([s stdlib-primitives] #:when (prim-spec-surface? s))
     (entry (prim-spec-name s) 'prim
            (or (prim-spec-type s)
                `(-> ,@(make-list (prim-spec-arity s) '_) _))
            (prim-spec-doc s)))
   (for/list ([p (prelude-functions)])
     (entry (pfun-name p) 'prelude (pfun-type p) (pfun-doc p)))))

(define entry-by-name
  (for/hasheq ([e all-entries]) (values (entry-name e) e)))

;; ---------------------------------------------------------------------
;; Categories: every entry appears in exactly one (asserted below).
;; ---------------------------------------------------------------------

(define categories
  `(("Numbers &amp; arithmetic"
     "61-bit fixnums are the numbers (see the <a href=\"tutorial.html\">tutorial</a>): arithmetic compiles to arithmetic, division by zero is checked, and there are no floats, bignums, or rationals."
     (+ - * < <= > >= quotient remainder modulo abs min max add1 sub1
        zero? even? odd? bitwise-and bitwise-ior bitwise-xor arithmetic-shift fixnum?))
    ("Booleans &amp; equality"
     "Only #f is false. eq? is identity; equal? is structural over pairs, vectors, strings, ADT instances, and immutable collections."
     (eq? equal? not boolean?))
    ("Pairs &amp; lists"
     "Pairs are immutable (no set-car!); lists are '()-terminated chains of pairs, and the everyday data structure."
     (cons car cdr pair? null? list? length append reverse
           first second third rest last list-ref take drop range
           member assoc index-of remove))
    ("Higher-order functions"
     "Closures are first-class and so are the intrinsics: (foldl + 0 xs) and (sort xs <) both work."
     (map filter foldl foldr andmap ormap map2 append-map filter-map
          findf partition sort apply))
    ("Vectors"
     "Fixed-length mutable arrays with O(1) checked indexing."
     (make-vector vector-ref vector-set! vector-length vector?
                  list->vector vector->list))
    ("Hashes"
     "The default hash is immutable (a persistent HAMT: hash-set returns a NEW hash in O(log n)); make-hash is the tolerated mutable variant. Keys compare by identity (eq?)."
     (hash hash-set hash-remove hash-ref hash-ref/default hash-has-key?
           hash-count hash-keys hash? make-hash hash-set! hash-remove!))
    ("Sets"
     "Same story as hashes: immutable by default (set-add returns a new set), mutable on request (make-set), identity-keyed."
     (set set-add set-remove set-member? set-count set->list
          list->set set-union set-subtract set-intersect
          set? make-set set-add! set-remove!))
    ("Strings &amp; symbols"
     "Strings are immutable byte strings (ASCII-friendly); symbols are interned, so eq? compares them in O(1)."
     (string? string-length string-append string-concat string-join substring
              string=? string<? string-byte number->string string->number
              format value->string symbol? symbol->string string->symbol symbol<?))
    ("ADTs &amp; matching"
     "define-type declares an algebraic datatype whose constructors work in expressions and in match patterns; see the tutorial for the full story. Constructor instances are their own heap kind, disjoint from vectors."
     (adt?))
    ("I/O &amp; the REPL"
     "println renders any value the way the REPL does. (read) and (read-all) consume standard input (the playground's stdin box feeds them)."
     (println display displayln newline read read-all eprintln
              read-file write-file file-exists? command-line-args system))
    ("Control &amp; misc"
     "Halting, fresh names, and the remaining predicates."
     (error gensym procedure? void?))))

;; assert: perfect 1-1 cover
(let ([cat-names (append-map third categories)])
  (define dup (check-duplicates cat-names))
  (when dup (error 'gen-stdlib-html "name categorized twice: ~a" dup))
  (for ([n cat-names])
    (unless (hash-ref entry-by-name n #f)
      (error 'gen-stdlib-html "categorized name has no entry: ~a" n)))
  (for ([e all-entries])
    (unless (memq (entry-name e) cat-names)
      (error 'gen-stdlib-html "entry has no category: ~a" (entry-name e)))))

;; ---------------------------------------------------------------------
;; Examples: name -> (code expected [#:input ints] [#:err s] [#:note s])
;; ---------------------------------------------------------------------

(struct ex (code expected input err note) #:transparent)
(define (make-ex code expected #:input [input '()] #:err [err ""] #:note [note #f])
  (ex code expected input err note))

(define examples
  (hash
   ;; intrinsics
   '+   (make-ex "(println (+ 1 2 3))" "6\n")
   '-   (make-ex "(println (- 10 4))\n(println (- 5))" "6\n-5\n")
   '*   (make-ex "(println (* 6 7))" "42\n")
   '<   (make-ex "(println (< 1 2))" "#t\n")
   '<=  (make-ex "(println (<= 2 2))" "#t\n")
   '>   (make-ex "(println (> 1 2))" "#f\n")
   '>=  (make-ex "(println (>= 3 2))" "#t\n")
   'eq? (make-ex "(println (eq? 'a 'a))\n(println (eq? (list 1) (list 1)))" "#t\n#f\n")
   'not (make-ex "(println (not #f))" "#t\n")
   ;; numbers
   'quotient  (make-ex "(println (quotient 7 2))\n(println (quotient -7 2))" "3\n-3\n")
   'remainder (make-ex "(println (remainder 7 2))\n(println (remainder -7 2))" "1\n-1\n")
   'modulo    (make-ex "(println (modulo 7 3))\n(println (modulo -7 3))" "1\n2\n")
   'abs   (make-ex "(println (abs (- 7)))" "7\n")
   'min   (make-ex "(println (min 3 9))" "3\n")
   'max   (make-ex "(println (max 3 9))" "9\n")
   'add1  (make-ex "(println (add1 41))" "42\n")
   'sub1  (make-ex "(println (sub1 43))" "42\n")
   'zero? (make-ex "(println (zero? 0))" "#t\n")
   'even? (make-ex "(println (even? 4))" "#t\n")
   'odd?  (make-ex "(println (odd? 4))" "#f\n")
   'bitwise-and (make-ex "(println (bitwise-and 12 10))" "8\n")
   'bitwise-ior (make-ex "(println (bitwise-ior 12 10))" "14\n")
   'bitwise-xor (make-ex "(println (bitwise-xor 12 10))" "6\n")
   'arithmetic-shift (make-ex "(println (arithmetic-shift 1 4))\n(println (arithmetic-shift 16 -2))" "16\n4\n")
   'fixnum? (make-ex "(println (fixnum? 42))\n(println (fixnum? \"42\"))" "#t\n#f\n")
   ;; booleans & equality
   'equal?   (make-ex "(println (equal? (list 1 2) (list 1 2)))" "#t\n")
   'boolean? (make-ex "(println (boolean? #f))" "#t\n")
   ;; pairs & lists
   'cons  (make-ex "(println (cons 1 2))\n(println (cons 1 (cons 2 '())))" "(1 . 2)\n(1 2)\n")
   'car   (make-ex "(println (car (list 1 2 3)))" "1\n")
   'cdr   (make-ex "(println (cdr (list 1 2 3)))" "(2 3)\n")
   'pair? (make-ex "(println (pair? (cons 1 2)))" "#t\n")
   'null? (make-ex "(println (null? '()))\n(println (null? (list 1)))" "#t\n#f\n")
   'list? (make-ex "(println (list? (list 1 2)))\n(println (list? (cons 1 2)))" "#t\n#f\n")
   'length  (make-ex "(println (length (list 'a 'b 'c)))" "3\n")
   'append  (make-ex "(println (append (list 1 2) (list 3 4)))" "(1 2 3 4)\n")
   'reverse (make-ex "(println (reverse (list 1 2 3)))" "(3 2 1)\n")
   'first  (make-ex "(println (first (list 1 2 3)))" "1\n")
   'second (make-ex "(println (second (list 1 2 3)))" "2\n")
   'third  (make-ex "(println (third (list 1 2 3)))" "3\n")
   'rest   (make-ex "(println (rest (list 1 2 3)))" "(2 3)\n")
   'last   (make-ex "(println (last (list 1 2 3)))" "3\n")
   'list-ref (make-ex "(println (list-ref (list 'a 'b 'c) 1))" "b\n")
   'take  (make-ex "(println (take (list 1 2 3 4) 2))" "(1 2)\n")
   'drop  (make-ex "(println (drop (list 1 2 3 4) 2))" "(3 4)\n")
   'range (make-ex "(println (range 0 5))" "(0 1 2 3 4)\n")
   'member (make-ex "(println (member 2 (list 1 2 3)))\n(println (member 9 (list 1 2 3)))" "(2 3)\n#f\n")
   'assoc  (make-ex "(println (assoc 'b (list (cons 'a 1) (cons 'b 2))))" "(b . 2)\n")
   'index-of (make-ex "(println (index-of (list 'a 'b 'c) 'b))" "1\n")
   'remove (make-ex "(println (remove 2 (list 1 2 3 2)))" "(1 3 2)\n")
   ;; higher-order
   'map    (make-ex "(println (map add1 (list 1 2 3)))" "(2 3 4)\n")
   'filter (make-ex "(println (filter even? (range 0 10)))" "(0 2 4 6 8)\n")
   'foldl  (make-ex "(println (foldl + 0 (list 1 2 3 4)))" "10\n")
   'foldr  (make-ex "(println (foldr cons '() (list 1 2 3)))" "(1 2 3)\n")
   'andmap (make-ex "(println (andmap even? (list 2 4 6)))" "#t\n")
   'ormap  (make-ex "(println (ormap odd? (list 2 4 5)))" "#t\n")
   'map2   (make-ex "(println (map2 + (list 1 2 3) (list 10 20 30)))" "(11 22 33)\n")
   'append-map (make-ex "(println (append-map (lambda (x) (list x x)) (list 1 2)))" "(1 1 2 2)\n")
   'filter-map (make-ex "(println (filter-map (lambda (x) (if (even? x) (* x x) #f)) (list 1 2 3 4)))" "(4 16)\n")
   'findf  (make-ex "(println (findf even? (list 1 3 4 5)))" "4\n")
   'partition (make-ex "(println (partition even? (list 1 2 3 4)))" "((2 4) 1 3)\n")
   'sort   (make-ex "(println (sort (list 3 1 2) <))" "(1 2 3)\n")
   'apply  (make-ex "(println (apply max (list 3 9)))" "9\n")
   ;; vectors
   'make-vector (make-ex "(println (make-vector 3))" "#(0 0 0)\n")
   'vector-ref  (make-ex "(println (vector-ref (vector 'a 'b 'c) 1))" "b\n")
   'vector-set! (make-ex "(define v (make-vector 3))\n(vector-set! v 0 7)\n(println v)" "#(7 0 0)\n")
   'vector-length (make-ex "(println (vector-length (vector 1 2 3)))" "3\n")
   'vector?     (make-ex "(println (vector? (vector 1)))" "#t\n")
   'list->vector (make-ex "(println (list->vector (list 1 2 3)))" "#(1 2 3)\n")
   'vector->list (make-ex "(println (vector->list (vector 1 2 3)))" "(1 2 3)\n")
   ;; hashes
   'hash (make-ex "(println (hash-count (hash 'a 1 'b 2)))" "2\n")
   'hash-set (make-ex "(define h0 (hash 'a 1))\n(define h1 (hash-set h0 'b 2))\n(println (hash-count h0))\n(println (hash-count h1))"
                      "1\n2\n" #:note "a NEW hash comes back; h0 is untouched")
   'hash-remove (make-ex "(println (hash-has-key? (hash-remove (hash 'a 1) 'a) 'a))" "#f\n")
   'hash-ref (make-ex "(println (hash-ref (hash 'a 1) 'a))" "1\n")
   'hash-ref/default (make-ex "(println (hash-ref/default (hash) 'missing 0))" "0\n")
   'hash-has-key? (make-ex "(println (hash-has-key? (hash 'a 1) 'a))" "#t\n")
   'hash-count (make-ex "(println (hash-count (hash 'a 1 'b 2)))" "2\n")
   'hash-keys (make-ex "(println (hash-keys (hash 'only 1)))" "(only)\n")
   'hash? (make-ex "(println (hash? (hash)))\n(println (hash? (make-hash)))" "#t\n#t\n")
   'make-hash (make-ex "(define m (make-hash))\n(hash-set! m 'hits 1)\n(println (hash-ref m 'hits))" "1\n")
   'hash-set! (make-ex "(define m (make-hash))\n(hash-set! m 'k 1)\n(hash-set! m 'k 2)\n(println (hash-ref m 'k))" "2\n")
   'hash-remove! (make-ex "(define m (make-hash))\n(hash-set! m 'k 1)\n(hash-remove! m 'k)\n(println (hash-has-key? m 'k))" "#f\n")
   ;; sets
   'set (make-ex "(println (set-count (set 1 2 2 3)))" "3\n")
   'set-add (make-ex "(define s0 (set))\n(define s1 (set-add s0 'x))\n(println (set-count s0))\n(println (set-count s1))"
                     "0\n1\n" #:note "a NEW set comes back; s0 is untouched")
   'set-remove (make-ex "(println (set-member? (set-remove (set 1 2) 1) 1))" "#f\n")
   'set-member? (make-ex "(println (set-member? (set 1 2 3) 2))" "#t\n")
   'set-count (make-ex "(println (set-count (set 'a 'b)))" "2\n")
   'set->list (make-ex "(println (set->list (set-add (set) 7)))" "(7)\n")
   'list->set (make-ex "(println (set-count (list->set (list 1 2 2 3))))" "3\n")
   'set-union (make-ex "(println (set-count (set-union (set 1 2) (set 2 3))))" "3\n")
   'set-subtract (make-ex "(println (set-member? (set-subtract (set 1 2) (set 2)) 2))" "#f\n")
   'set-intersect (make-ex "(println (set->list (set-intersect (set 1 2) (set 2 3))))" "(2)\n")
   'set? (make-ex "(println (set? (set)))\n(println (set? (list 1 2)))" "#t\n#f\n")
   'make-set (make-ex "(define s (make-set))\n(set-add! s 'x)\n(println (set-count s))" "1\n")
   'set-add! (make-ex "(define s (make-set))\n(set-add! s 'x)\n(set-add! s 'x)\n(println (set-count s))" "1\n")
   'set-remove! (make-ex "(define s (make-set))\n(set-add! s 7)\n(set-remove! s 7)\n(println (set-member? s 7))" "#f\n")
   ;; strings & symbols
   'string? (make-ex "(println (string? \"abc\"))" "#t\n")
   'string-length (make-ex "(println (string-length \"puffin\"))" "6\n")
   'string-append (make-ex "(println (string-append \"puf\" \"fin\"))" "puffin\n")
   'string-concat (make-ex "(println (string-concat (list \"a\" \"b\" \"c\")))" "abc\n")
   'string-join (make-ex "(println (string-join (list \"a\" \"b\" \"c\") \", \"))" "a, b, c\n")
   'substring (make-ex "(println (substring \"puffin\" 0 3))" "puf\n")
   'string=? (make-ex "(println (string=? \"abc\" \"abc\"))" "#t\n")
   'string<? (make-ex "(println (string<? \"apple\" \"banana\"))" "#t\n")
   'string-byte (make-ex "(println (string-byte \"A\" 0))" "65\n")
   'number->string (make-ex "(println (string-append \"n = \" (number->string 42)))" "n = 42\n")
   'string->number (make-ex "(println (string->number \"42\"))\n(println (string->number \"nope\"))" "42\n#f\n")
   'format (make-ex "(println (format \"~a + ~a = ~a\" 1 2 3))" "1 + 2 = 3\n")
   'value->string (make-ex "(println (string-length (value->string (list 1 2 3))))" "7\n")
   'symbol? (make-ex "(println (symbol? 'abc))" "#t\n")
   'symbol->string (make-ex "(println (string-length (symbol->string 'hello)))" "5\n")
   'string->symbol (make-ex "(println (eq? (string->symbol \"cat\") 'cat))" "#t\n")
   'symbol<? (make-ex "(println (symbol<? 'apple 'banana))" "#t\n")
   ;; ADTs
   'adt? (make-ex "(define-type Opt (None) (Some Int))\n(println (Some 1))\n(println (adt? (Some 1)))\n(println (adt? (vector 1)))"
                  "(Some 1)\n#t\n#f\n")
   ;; I/O
   'println (make-ex "(println (list 1 'two \"three\"))" "(1 two three)\n")
   'display (make-ex "(display 'answer)\n(display \": \")\n(display 42)\n(newline)" "answer: 42\n")
   'displayln (make-ex "(displayln \"hi\")" "hi\n")
   'newline (make-ex "(display 1)\n(newline)\n(display 2)\n(newline)" "1\n2\n")
   'read (make-ex "(println (+ (read) (read)))" "7\n" #:input '(3 4) #:note "with 3 4 on stdin")
   'read-all (make-ex "(println (string-length (read-all)))" "5\n" #:input '(1 2 3) #:note "with 1 2 3 on stdin")
   'eprintln (make-ex "(eprintln 'warning)" "" #:err "warning\n")
   'read-file (make-ex "(write-file \"note.txt\" \"hello\")\n(println (read-file \"note.txt\"))" "hello\n")
   'write-file (make-ex "(write-file \"out.txt\" \"data\")\n(println (file-exists? \"out.txt\"))" "#t\n")
   'file-exists? (make-ex "(println (file-exists? \"no-such-file.txt\"))" "#f\n")
   'command-line-args (make-ex "(println (command-line-args))" "()\n" #:note "run with no arguments")
   'system (make-ex "(println (system \"exit 3\"))" "3\n")
   ;; control & misc
   'error (make-ex "(error 'boom)" "error: boom\n")
   'gensym (make-ex "(define t (gensym 'tmp))\n(println (symbol? t))" "#t\n" #:note "a fresh name every call")
   ;; NB: deliberately not (procedure? (lambda ...)) — the compiled
   ;; routes answer #t but the reference interpreter's closure records
   ;; answer #f (a known reference/runtime seam); the docs only show
   ;; what every route agrees on.
   'procedure? (make-ex "(println (procedure? 42))\n(println (procedure? 'car))" "#f\n#f\n")
   'void? (make-ex "(println (void? (display \"\")))" "#t\n")))

;; assert: every entry has an example
(for ([e all-entries])
  (unless (hash-ref examples (entry-name e) #f)
    (error 'gen-stdlib-html "entry has no example: ~a" (entry-name e))))

;; ---------------------------------------------------------------------
;; Recipes: the day-to-day idioms, up front. Same verification.
;; ---------------------------------------------------------------------

(struct recipe (title blurb x) #:transparent)

(define recipes
  (list
   (recipe "look things up in an assoc-list environment?"
           "The interpreter-assignment workhorse: an environment is a list of (name . value) pairs; assoc finds the binding, match takes it apart."
           (make-ex
            (string-join
             '("(define env (list (cons 'x 10) (cons 'y 20)))"
               "(define (lookup env k)"
               "  (match (assoc k env)"
               "    [(cons _ v) v]"
               "    [#f (error (list 'unbound k))]))"
               "(println (lookup env 'y))")
             "\n")
            "20\n"))
   (recipe "fold over a tree ADT?"
           "Declare the shape once with define-type; every traversal is a match with one clause per constructor."
           (make-ex
            (string-join
             '("(define-type Tree (Leaf Int) (Node Tree Tree))"
               "(define (tree-sum [t : Tree]) : Int"
               "  (match t"
               "    [(Leaf n) n]"
               "    [(Node l r) (+ (tree-sum l) (tree-sum r))]))"
               "(println (tree-sum (Node (Leaf 1) (Node (Leaf 2) (Leaf 3)))))")
             "\n")
            "6\n"))
   (recipe "write a tail-recursive loop?"
           "A named let is the loop: Puffin has proper tail calls, so a million iterations run in O(1) stack."
           (make-ex
            (string-join
             '("(let loop ([i 0] [acc 0])"
               "  (if (< i 1000000)"
               "      (loop (+ i 1) (+ acc i))"
               "      (println acc)))")
             "\n")
            "499999500000\n"))
   (recipe "build strings?"
           "format renders any value with ~a (and ~% is a newline); string-join and string-concat assemble big strings in linear time."
           (make-ex
            (string-join
             '("(define (describe name n)"
               "  (format \"~a scored ~a point~a\" name n (if (eq? n 1) \"\" \"s\")))"
               "(println (describe 'ada 3))"
               "(println (string-join (map describe2 (list 'a 'b)) \"; \"))")
             "\n")
            "" #:note "placeholder -- replaced below"))
   (recipe "compute graph reachability?"
           "Adjacency as a hash of neighbor lists, a worklist, and an immutable set of visited nodes."
           (make-ex
            (string-join
             '("(define g (hash 'a (list 'b 'c) 'b (list 'd) 'c '() 'd '()))"
               "(define (reachable from)"
               "  (let loop ([todo (list from)] [seen (set)])"
               "    (match todo"
               "      ['() seen]"
               "      [(cons n rest)"
               "       (if (set-member? seen n)"
               "           (loop rest seen)"
               "           (loop (append (hash-ref/default g n '()) rest)"
               "                 (set-add seen n)))])))"
               "(println (sort (map symbol->string (set->list (reachable 'a))) string<?))")
             "\n")
            "(a b c d)\n"))
   (recipe "count occurrences?"
           "A mutable hash plus hash-ref/default is the tally idiom."
           (make-ex
            (string-join
             '("(define counts (make-hash))"
               "(define (tally! k)"
               "  (hash-set! counts k (+ 1 (hash-ref/default counts k 0))))"
               "(map tally! (list 'a 'b 'a 'a))"
               "(println (hash-ref counts 'a))")
             "\n")
            "3\n"))))

;; the string-building recipe, written straight (the quoting above
;; gets noisy with nested string literals)
(set! recipes
      (list-set recipes 3
                (recipe "build strings?"
                        "format renders any value with ~a (and ~% is a newline); string-join and string-concat assemble big strings in linear time."
                        (make-ex
                         (string-append
                          "(define (describe name n)\n"
                          "  (format \"~a scored ~a point~a\" name n (if (eq? n 1) \"\" \"s\")))\n"
                          "(println (describe 'ada 3))\n"
                          "(println (describe 'grace 1))")
                         "ada scored 3 points\ngrace scored 1 point\n"))))

;; ---------------------------------------------------------------------
;; Verification: run every example through the reference interpreter
;; ---------------------------------------------------------------------

(define scratch
  (build-path (find-system-path 'temp-dir)
              (format "puffin-stdlib-doc-~a" (current-milliseconds))))
(make-directory* scratch)

(define (run-example code input)
  (define f (build-path scratch "example.puf"))
  (call-with-output-file f #:exists 'replace
    (λ (o) (display code o) (newline o)))
  (define out (open-output-string))
  (define err (open-output-string))
  (parameterize ([current-output-port out]
                 [current-error-port err]
                 [current-directory scratch])
    (interpret-puffin (desugar (read-program-file f)) input))
  (values (get-output-string out) (get-output-string err)))

(define verified-count 0)
(define failures '())

(define (verify! who x)
  (define-values (out err) (run-example (ex-code x) (ex-input x)))
  (cond
    [(and (equal? out (ex-expected x)) (equal? err (ex-err x)))
     (set! verified-count (+ verified-count 1))]
    [else
     (set! failures
           (cons (format "~a:\n  code:\n~a\n  expected stdout ~s (got ~s)\n  expected stderr ~s (got ~s)"
                         who (ex-code x) (ex-expected x) out (ex-err x) err)
                 failures))]))

(for ([e all-entries]) (verify! (entry-name e) (hash-ref examples (entry-name e))))
(for ([r recipes]) (verify! (recipe-title r) (recipe-x r)))

(unless (null? failures)
  (eprintf "~a example(s) FAILED verification:\n\n~a\n"
           (length failures) (string-join (reverse failures) "\n\n"))
  (exit 1))

;; ---------------------------------------------------------------------
;; Rendering
;; ---------------------------------------------------------------------

(define (html-escape s)
  (regexp-replace* #rx"<" (regexp-replace* #rx"&" s "\\&amp;") "\\&lt;"))

(define (anchor-name n)
  (string-append
   "e-"
   (apply string-append
          (for/list ([c (symbol->string n)])
            (if (or (char-alphabetic? c) (char-numeric? c))
                (string c)
                (format "_~a" (char->integer c)))))))

;; a code block: the example's code with its VERIFIED output rendered
;; as comments (single output line attaches to the last code line;
;; more become a `;; prints:` block)
(define (render-example x)
  (define code-lines (string-split (ex-code x) "\n"))
  (define out-lines (if (string=? (ex-expected x) "")
                        '()
                        (string-split (string-trim (ex-expected x) "\n" #:left? #f) "\n")))
  (define note-line (if (ex-note x) (list (format ";; ~a" (ex-note x))) '()))
  ;; a single output line attaches inline to the last code line when
  ;; that line is visibly the one printing; otherwise a block
  (define inline?
    (and (= (length out-lines) 1)
         (not (string=? (car out-lines) ""))
         (or (= (length code-lines) 1)
             (regexp-match? #rx"^ *\\((println|displayln|display|error)" (last code-lines)))))
  (define body
    (cond
      [inline?
       (append (drop-right code-lines 1)
               (list (format "~a   ;; ~a" (last code-lines) (car out-lines))))]
      [(null? out-lines) code-lines]
      [else (append code-lines
                    (list ";; prints:")
                    (for/list ([l out-lines]) (format ";;   ~a" l)))]))
  (define err-lines
    (if (string=? (ex-err x) "")
        '()
        (for/list ([l (string-split (string-trim (ex-err x) "\n" #:left? #f) "\n")])
          (format ";; on stderr: ~a" l))))
  (format "<pre><code>~a</code></pre>"
          (html-escape (string-join (append note-line body err-lines) "\n"))))

(define (source-badge src)
  (match src
    ['intrinsic "<span class=\"src intr\" title=\"open-coded by the compiler backends\">intrinsic</span>"]
    ['prim      "<span class=\"src prim\" title=\"a runtime primitive (C / reference / VM, kept in lockstep by the manifest)\">primitive</span>"]
    ['prelude   "<span class=\"src prel\" title=\"written in Puffin: src/prelude.puf, injected on mention\">prelude</span>"]))

(define (render-entry e)
  (define x (hash-ref examples (entry-name e)))
  (string-append
   (format "<div class=\"entry\" id=\"~a\">\n" (anchor-name (entry-name e)))
   (format "<div class=\"sighead\"><code class=\"nm\">~a</code> <code class=\"ty\">~a</code>~a</div>\n"
           (html-escape (symbol->string (entry-name e)))
           (html-escape (format "~a" (entry-type e)))
           (source-badge (entry-source e)))
   ;; manifest doc lines use markdown-style `code` spans
   (format "<p class=\"doc\">~a</p>\n"
           (regexp-replace* #rx"`([^`]*)`" (html-escape (entry-doc e)) "<code>\\1</code>"))
   (render-example x)
   "</div>\n"))

(define (cat-anchor i) (format "cat-~a" i))

(define page
  (let ([o (open-output-string)])
    (define (emit fmt . args) (apply fprintf o fmt args))
    (emit #<<HEADER
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>The Puffin Standard Library</title>
<!-- GENERATED by tools/gen-stdlib-html.rkt — DO NOT EDIT BY HAND.
     Sources of truth: src/stdlib.rkt (the manifest), src/prelude.puf
     (signatures + ;;> doc comments), and the examples table in the
     generator. Every example below was executed and asserted against
     the reference interpreter at generation time.
     Regenerate: racket tools/gen-stdlib-html.rkt -->
<style>
:root {
  --surface-1: #fcfcfb; --text-primary: #0b0b0b; --text-secondary: #52514e; --text-muted: #8a8880;
  --accent: #2a78d6; --accent-2: #1baf7a; --racket: #eda100;
  --card: #f6f5f2; --border: #e4e2dc; --grid: #eceae5;
  --win: #0ca30c; --lose: #d03b3b;
}
@media (prefers-color-scheme: dark) { :root {
  --surface-1: #1a1a19; --text-primary: #ffffff; --text-secondary: #c3c2b7; --text-muted: #8a887d;
  --accent: #3987e5; --accent-2: #199e70; --racket: #c98500;
  --card: #232322; --border: #34342f; --grid: #2b2b29;
  --win: #35c235; --lose: #e66767;
} }
:root[data-theme="light"] {
  --surface-1: #fcfcfb; --text-primary: #0b0b0b; --text-secondary: #52514e; --text-muted: #8a8880;
  --accent: #2a78d6; --accent-2: #1baf7a; --racket: #eda100;
  --card: #f6f5f2; --border: #e4e2dc; --grid: #eceae5;
  --win: #0ca30c; --lose: #d03b3b;
}
:root[data-theme="dark"] {
  --surface-1: #1a1a19; --text-primary: #ffffff; --text-secondary: #c3c2b7; --text-muted: #8a887d;
  --accent: #3987e5; --accent-2: #199e70; --racket: #c98500;
  --card: #232322; --border: #34342f; --grid: #2b2b29;
  --win: #35c235; --lose: #e66767;
}
* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
body {
  font: 15px/1.55 -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
  color: var(--text-primary); background: var(--surface-1);
  margin: 0;
}
.layout { max-width: 1160px; margin: 0 auto; padding: 28px 20px 90px;
  display: grid; grid-template-columns: 216px minmax(0, 1fr); gap: 40px; }
nav.toc { position: sticky; top: 22px; align-self: start; font-size: 13.5px;
  max-height: calc(100vh - 44px); overflow-y: auto; }
nav.toc summary { display: none; }
nav.toc a { display: block; color: var(--text-secondary); text-decoration: none;
  padding: 4px 10px; border-left: 2px solid var(--grid); }
nav.toc a:hover { color: var(--text-primary); }
nav.toc a.active { color: var(--accent); border-left-color: var(--accent); font-weight: 600; }
nav.toc .toc-title { font-weight: 650; font-size: 12px; letter-spacing: 0.6px;
  text-transform: uppercase; color: var(--text-muted); margin: 0 0 8px 12px; }
#theme { position: fixed; top: 14px; right: 14px; z-index: 5; font: inherit; font-size: 15px;
  background: var(--card); color: var(--text-secondary); border: 1px solid var(--border);
  border-radius: 999px; width: 34px; height: 34px; cursor: pointer; line-height: 1; }
#theme:hover { color: var(--text-primary); }
main { min-width: 0; }
h1 { font-size: 27px; margin: 0 0 4px; letter-spacing: -0.3px; }
h2 { font-size: 20px; margin: 52px 0 8px; padding-top: 8px; border-top: 1px solid var(--grid); }
h3 { font-size: 16px; margin: 30px 0 4px; }
p, li { color: var(--text-primary); }
.lede, .sub { color: var(--text-secondary); }
.lede { font-size: 16px; }
a { color: var(--accent); }
code { font: 13px/1.5 ui-monospace, "SF Mono", Menlo, monospace;
  background: var(--card); border: 1px solid var(--border); border-radius: 5px; padding: 0 4px; }
pre { background: var(--card); border: 1px solid var(--border); border-radius: 10px;
  padding: 12px 15px; overflow-x: auto; margin: 12px 0; }
pre code { background: none; border: 0; padding: 0; font-size: 12.5px; tab-size: 2; display: block; }
.cm { color: var(--text-muted); font-style: italic; }
.st { color: var(--accent-2); }
.kw { color: var(--accent); }
.note { color: var(--text-secondary); font-size: 13px; }
.badge { display: inline-block; background: var(--card); border: 1px solid var(--border);
  border-radius: 999px; padding: 2px 11px; font-size: 12.5px; color: var(--text-secondary); margin: 2px 6px 2px 0; }
.catlede { color: var(--text-secondary); margin: 4px 0 18px; }
.entry { border: 1px solid var(--border); background: var(--card); border-radius: 10px;
  padding: 12px 16px 4px; margin: 14px 0; }
.entry pre { background: var(--surface-1); margin: 10px 0 12px; }
.entry .doc { margin: 6px 0 0; }
.sighead { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; }
.sighead .nm { font-weight: 700; font-size: 14.5px; color: var(--accent);
  background: none; border: 0; padding: 0; }
.sighead .ty { color: var(--text-muted); background: none; border: 0; padding: 0; font-size: 12.5px; }
.src { margin-left: auto; font-size: 11px; font-weight: 650; letter-spacing: 0.5px;
  text-transform: uppercase; border-radius: 999px; padding: 1px 9px; border: 1px solid var(--border);
  color: var(--text-muted); white-space: nowrap; }
.src.prel { color: var(--accent-2); border-color: var(--accent-2); }
.src.intr { color: var(--racket); border-color: var(--racket); }
.qa { border: 1px solid var(--border); border-left: 4px solid var(--accent);
  background: var(--card); border-radius: 10px; padding: 14px 18px; margin: 28px 0; }
.qa .q { font-weight: 650; margin: 0 0 6px; }
.qa .q::before { content: "How do I "; color: var(--accent); }
.qa p { margin: 8px 0; }
.qa pre { background: var(--surface-1); }
@media (max-width: 960px) {
  .layout { grid-template-columns: 1fr; gap: 12px; }
  nav.toc { position: static; max-height: none; }
  nav.toc summary { display: list-item; cursor: pointer; font-weight: 650; color: var(--text-secondary); }
  nav.toc .toc-title { display: none; }
}
</style>
</head>
<body>
<button id="theme" title="Toggle light/dark">◐</button>
<div class="layout">
<nav class="toc" aria-label="Contents">
  <details id="tocbox" open>
    <summary>Contents</summary>
    <div class="toc-title">Puffin stdlib</div>
    <a href="#hero">The standard library</a>
    <a href="#recipes">How do I…</a>

HEADER
          )
    (for ([c categories] [i (in-naturals)])
      (emit "    <a href=\"#~a\">~a</a>\n" (cat-anchor i) (first c)))
    (emit #<<NAVEND
    <div class="toc-title" style="margin-top:14px">Elsewhere</div>
    <a href="tutorial.html">The tutorial</a>
  </details>
</nav>
<main>

<section id="hero">
<h1>The Puffin Standard Library</h1>

NAVEND
          )
    (define n-entries (length all-entries))
    (emit "<p class=\"lede\">Small but mighty: everything you need for lists, recursion,\nhigher-order functions, pattern matching over ADTs, assoc-list environments,\ngraphs, and interpreters — and deliberately nothing more. ~a functions in\nthree layers: compiler <em>intrinsics</em>, runtime <em>primitives</em> (one C\nimplementation, one reference implementation, one VM implementation, kept in\nlockstep by the manifest), and a <em>prelude written in Puffin itself</em>,\ninjected only when mentioned. New to the language? Start with the\n<a href=\"tutorial.html\">tutorial</a>.</p>\n" n-entries)
    (emit "<p>\n<span class=\"badge\">~a functions</span>\n<span class=\"badge\">~a examples, all machine-verified</span>\n<span class=\"badge\">types as the checker sees them</span>\n</p>\n" n-entries verified-count)
    (emit "<p class=\"note\">This page is <strong>generated</strong> — edit\n<code>tools/gen-stdlib-html.rkt</code>, the manifest doc lines in\n<code>src/stdlib.rkt</code>, or the <code>;;&gt;</code> doc comments in\n<code>src/prelude.puf</code>, never this HTML — and regenerate with\n<code>racket tools/gen-stdlib-html.rkt</code>. Every example was executed\nagainst the reference interpreter (typechecker included) when the page was\nbuilt; the <code>;;</code> output comments are copied from what actually ran.\nEvery snippet pastes straight into the web playground.</p>\n")
    (emit "<p class=\"note\">Types are gradual (see the tutorial): <code>_</code> is\nthe unannotated \"any\" type, lower-case letters are type variables, and\n<code>(-&gt; _ ... _)</code> on an entry means it is untyped — the checker\nderives that shape from the arity. <code>(Mut ...)</code> marks the mutable\ncollection flavors. Special <em>forms</em> — <code>define</code>,\n<code>match</code>, <code>let</code>, <code>define-type</code>,\n<code>quasiquote</code>, … — are the language, not the library:\nsee <code>docs/LANGUAGE.md</code> and the <a href=\"tutorial.html\">tutorial</a>.</p>\n")
    (emit "</section>\n\n<section id=\"recipes\">\n<h2>How do I…</h2>\n<p class=\"sub\">The idioms a PL course leans on daily — each one verified, like everything else on this page.</p>\n")
    (for ([r recipes])
      (emit "<aside class=\"qa\">\n<div class=\"q\">~a</div>\n<p>~a</p>\n~a</aside>\n"
            (html-escape (recipe-title r))
            (html-escape (recipe-blurb r))
            (render-example (recipe-x r))))
    (emit "</section>\n")
    (for ([c categories] [i (in-naturals)])
      (emit "\n<section id=\"~a\">\n<h2>~a</h2>\n<p class=\"catlede\">~a</p>\n" (cat-anchor i) (first c) (second c))
      (for ([n (third c)])
        (emit "~a" (render-entry (hash-ref entry-by-name n)))))
    (emit #<<FOOTER

</main>
</div>
<script>
(function () {
  // --- theme toggle: data-theme overrides prefers-color-scheme ---
  var root = document.documentElement;
  var saved = null;
  try { saved = localStorage.getItem('puffin-tutorial-theme'); } catch (e) {}
  if (saved === 'light' || saved === 'dark') root.dataset.theme = saved;
  document.getElementById('theme').addEventListener('click', function () {
    var dark = root.dataset.theme
      ? root.dataset.theme === 'dark'
      : matchMedia('(prefers-color-scheme: dark)').matches;
    var next = dark ? 'light' : 'dark';
    root.dataset.theme = next;
    try { localStorage.setItem('puffin-tutorial-theme', next); } catch (e) {}
  });

  // --- tiny syntax highlighter (same as tutorial.html) ---
  var KW = {};
  ('define define-type lambda λ match let let* letrec if cond case when unless ' +
   'begin set! quote quasiquote require provide signature ann while and or not ' +
   'else struct').split(' ').forEach(function (w) { KW[w] = 1; });
  function hl(code) {
    var h = code.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    h = h.replace(/"(?:[^"\\]|\\.)*"/g, function (m) { return '' + m + ''; });
    h = h.replace(/(^|[^&\w]);[^\n]*/g, function (m, pre) {
      return pre + '' + m.slice(pre.length) + '';
    });
    h = h.replace(/\(([^\s()\[\]]+)/g, function (m, w) {
      return KW[w] ? '(<span class="kw">' + w + '</span>' : m;
    });
    return h.replace(//g, '<span class="st">').replace(//g, '</span>')
            .replace(//g, '<span class="cm">').replace(//g, '</span>');
  }
  document.querySelectorAll('pre code').forEach(function (c) {
    c.innerHTML = hl(c.textContent);
  });

  // --- TOC: collapse on narrow screens, highlight active section ---
  var tocbox = document.getElementById('tocbox');
  if (window.innerWidth < 960) tocbox.removeAttribute('open');
  var links = Array.prototype.slice.call(document.querySelectorAll('nav.toc a'))
    .filter(function (a) { return a.getAttribute('href').charAt(0) === '#'; });
  var sections = links.map(function (a) {
    return document.getElementById(a.getAttribute('href').slice(1));
  });
  function setActive() {
    var y = window.scrollY + 90, i = 0;
    for (var k = 0; k < sections.length; k++)
      if (sections[k] && sections[k].offsetTop <= y) i = k;
    links.forEach(function (a, k) { a.classList.toggle('active', k === i); });
  }
  addEventListener('scroll', setActive, { passive: true });
  setActive();
})();
</script>
</body>
</html>

FOOTER
          )
    (get-output-string o)))

(call-with-output-file docs-out #:exists 'replace (λ (o) (display page o)))
(call-with-output-file web-out  #:exists 'replace (λ (o) (display page o)))
(printf "wrote ~a and ~a\n" docs-out web-out)
(printf "verified ~a examples (~a entries + ~a recipes), all outputs asserted against the reference interpreter\n"
        verified-count (length all-entries) (length recipes))
