#lang racket

;; Puffin -- separate.rkt: separate compilation (docs/MODULES.md §3).
;;
;; `bin/puffin -c --module foo.puf` compiles ONE module to
;;   build-cache/<pathhash>/foo.o     native code, module-level names
;;                                    mangled (name_<stem>_<fnv1a32 of
;;                                    the absolute path>)
;;   build-cache/<pathhash>/foo.pufi  the interface (source sha1,
;;                                    requires, provides with mangled
;;                                    symbols + arities/slots, the
;;                                    init symbol)
;; building missing/stale dependencies first (a built-in make: a
;; module is stale when its source sha1 changed, its build flags
;; changed, or a dependency's INTERFACE digest changed -- dep body
;; changes alone never recompile downstream).
;;
;; `bin/puffin -c --separate main.puf -o prog` compiles every module
;; in the require DAG separately (cached as above), compiles the
;; entry, and links all the .o's with the runtime archive. The
;; entry's prelude calls every module's init in require-DAG
;; postorder (after pf_init), so top-level effects run in exactly
;; the whole-program order; each init also carries a run-once guard.
;;
;; The prelude (src/prelude.puf) compiles as ONE implicitly-required
;; module (unpruned -- it carries everything any module needs) with
;; mangled labels, and every module imports it by source name via
;; module-ext-funs (desugar introduces names like `append` after
;; resolution, so prelude imports cannot be pre-renamed).
;;
;; arm64 only for now (the x86 backend has not grown the sep-mode
;; literal machinery).

(provide build-module
         build-separate
         build-cache-root
         modules-rebuilt-log)

(require racket/runtime-path
         file/sha1)
(require "system.rkt"
         "irs.rkt"
         "modules.rkt"  ;; re-exports consistent? for typed .pufs entries
         "main.rkt")

(define-runtime-path src-dir ".")

;; where the cache lives (tests point this at a temp dir)
(define build-cache-root (make-parameter "build-cache"))

;; when a box, every module compiled (path string) is logged --
;; the staleness tests key off this
(define modules-rebuilt-log (make-parameter #f))

(define (log-rebuild! path-str)
  (when (modules-rebuilt-log)
    (set-box! (modules-rebuilt-log)
              (cons path-str (unbox (modules-rebuilt-log))))))

;; ---------------------------------------------------------------------
;; naming
;; ---------------------------------------------------------------------

(define (abs-of p) (simplify-path (path->complete-path p) #f))
(define (path-str p) (if (path? p) (path->string p) p))
(define (file-stem abs)
  (path->string (path-replace-extension (file-name-from-path abs) "")))
(define (sanitize-stem s) (regexp-replace* #rx"[^a-zA-Z0-9]" s "_"))
(define (path-hash abs) (number->string (fnv1a-32 (path-str abs)) 16))

;; the module id: <stem>_<fnv1a32(abs path)>. Unlike whole-program
;; resolution (entry-relative), separate compilation hashes the
;; ABSOLUTE path so a module's .o/.pufi are entry-independent.
(define (module-mid abs) (format "~a_~a" (sanitize-stem (file-stem abs)) (path-hash abs)))

(define (mid->init mid)    (string->symbol (format "pfm_init_~a" mid)))
(define (mid->globals mid) (string->symbol (format "pfm_globals_~a" mid)))
(define (mangle name mid)
  (define mn (string->symbol (format "~a_~a" name mid)))
  ;; diagnostics never show the mangled spelling (system.rkt)
  (module-demangle-register! mn name)
  mn)

(define (cache-dir-for abs) (build-path (build-cache-root) (path-hash abs)))

(define (source-sha1 abs)
  (call-with-input-file abs sha1))

(define (build-flags)
  `(flags (target ,(target)) (optimize ,(sep-optimize-level)) (safe ,(safe-mode))))

;; modules compile at most at -O1: the -O2 AAM layer assumes a
;; closed program (it drops flow-dead top-level defines, which a
;; provided-but-locally-unused function looks like)
(define (sep-optimize-level) (min (optimize-level) 1))

;; ---------------------------------------------------------------------
;; interface (.pufi) records -- TYPED (docs/MODULES.md §3.2)
;;
;; (interface "<abs path>"
;;   (module-id "<mid>")
;;   (source-sha1 "<hex>")
;;   (flags (target arm64) (optimize 1) (safe #t))
;;   (requires ("<abs dep path>" "<dep interface digest>") ...)
;;   (provides (area fun (fixed 1) area_geometry_3f9a
;;                   (-> Shape_shapes_9ab Int))
;;             (pi val 0 Int)
;;             (Shape type Shape_shapes_9ab))
;;   (types (Shape_shapes_9ab Shape ()
;;           (((Point_shapes_9ab Point))
;;            ((Circle_shapes_9ab Circle) Int)
;;            ((Rect_shapes_9ab Rect) Int Int))))
;;   (globals pfm_globals_geometry_3f9a 1)
;;   (init pfm_init_geometry_3f9a))
;;
;; provides rows carry the exported name's gradual type -- from a
;; (: ...) declaration, inline annotations, or the checker's
;; SYNTHESIZED type for an unannotated value define ( `_` when even
;; that is dynamic). A provided define-type head is a `type` row; its
;; full definition lives in the (types ...) section: mangled + source
;; spellings for head and constructors, the type parameters, and each
;; constructor's field types. The mangled constructor names ARE the
;; runtime tags (adt-alloc quotes them in the exporting unit), so an
;; importer's cast descs and match compilation agree with the .o.
;; The types section is CLOSED: it also embeds any ADT (own-private
;; or from a transitive dep) that a provided signature or an embedded
;; row's fields mention, so the importing checker can register every
;; name it will encounter without reading anything but this file.
;; All type spellings are the exporting units' mangled ones -- those
;; are the type identities, and they agree across independently
;; compiled units because sep-mode mangling hashes the absolute path.
;;
;; The interface DIGEST covers what importers' code depends on
;; (module-id, provides, types, globals label/count, init) -- NOT the
;; source sha -- so editing a module's bodies rebuilds only that
;; module, while a signature change (a type changed, a provide
;; added/removed, an ADT's constructors changed) rebuilds dependents.
;; ---------------------------------------------------------------------

;; info: an in-memory hash describing a built module
;;   'path 'mid 'provides 'types 'globals-label 'globals-count 'init
;;   'iface-digest 'o-path
(define (info-iface-digest provides types mid globals-label globals-count init)
  (sha1 (open-input-string
         (format "~s" (list mid provides types globals-label globals-count init)))))

(define (make-info abs mid provides types globals-count o-path)
  (define gl (mid->globals mid))
  (define init (mid->init mid))
  (hash 'path (path-str abs)
        'mid mid
        'provides provides
        'types types
        'globals-label gl
        'globals-count globals-count
        'init init
        'iface-digest (info-iface-digest provides types mid gl globals-count init)
        'o-path (path-str o-path)))

;; the unit's value-define names in collect-globals slot order.
;; Desugar expands a define-type IN PLACE, and each NULLARY
;; constructor becomes a value define (its singleton instance), so
;; slot numbering must interleave them; (:)/(#%prelude:) forms vanish
;; and contribute nothing. Every pass between desugar and
;; collect-globals preserves top-level define order and shape.
(define (value-define-names body)
  (append*
   (for/list ([f body])
     ;; a foreign form expands to one VALUE define per declaration
     ;; (docs/FFI.md §8.1 -- the let+lambda closure), in declaration
     ;; order; define-foreign-type contributes nothing. (Plain pair
     ;; tests: module-load gensym budget.)
     (cond
       [(and (pair? f) (eq? (car f) 'foreign)) (foreign-decl-names f)]
       [(and (pair? f) (eq? (car f) 'define-foreign-type)) '()]
       [else
        (match f
          [`(define-type ,_ ,cs ...)
           (filter-map (λ (c) (match c [`(,cn) cn] [_ #f])) cs)]
          [`(define ,(? symbol? x) ,_) (list x)]
          [_ '()])]))))

;; the provides table for a module: sorted by name for digest
;; stability. Three row shapes (types appended after typechecking by
;; enrich-provides): value defines and nullary constructors are `val`
;; rows carrying their globals slot; function defines and n-ary
;; constructors are `fun` rows carrying arity + mangled label; a
;; define-type head is a `type` row pointing at its (types ...) entry.
;; (mangle? is positional, not #:mangle? -- a keyword-accepting
;; function costs one gensym at instantiation, and the load-time
;; gensym budget is pinned by whole-program byte-identity; the
;; reference closure structs in stdlib.rkt spent this file's slack.)
(define (compute-provides body provides-set mid mangle?)
  (define (mangled n) (if mangle? (mangle n mid) n))
  (define val-slot
    (for/hash ([x (value-define-names body)] [i (in-naturals)]) (values x i)))
  (define by-name
    (for*/hash ([f body] [n (defn-names f)]) (values n f)))
  (for/list ([n (sort (set->list provides-set) symbol<?)])
    (define form (hash-ref by-name n #f))
    (unless form
      (module-error "~a: provided name ~a has no definition" mid n))
    (if (and (pair? form) (eq? (car form) 'define-foreign-type))
        ;; a foreign handle type: a type row, backed by a
        ;; foreign-marked (types ...) entry (docs/FFI.md §6); its
        ;; imports themselves are ordinary val rows (the lowering
        ;; makes them value defines)
        `(,n type ,(mangled n))
    (match form
      [`(define-type ,head ,cs ...)
       (define type-name (match head [`(,tn ,_ ...) tn] [tn tn]))
       (cond
         [(eq? n type-name) `(,n type ,(mangled n))]
         [else
          ;; a constructor: nullary = the singleton value (a slot);
          ;; n-ary = a builder function desugar defines in this unit
          (match (assq n (map (λ (c) (cons (car c) (length (cdr c)))) cs))
            [(cons _ 0) `(,n val ,(hash-ref val-slot n))]
            [(cons _ k) `(,n fun (fixed ,k) ,(mangled n))])])]
      [_
       (match (defn-arity form)
         ['val `(,n val ,(hash-ref val-slot n))]
         [arity `(,n fun ,arity ,(mangled n))])]))))

;; append each provide row's type, from the checker's deposited
;; top-level environment (keys are the CHECKED spellings = the
;; mangled labels). `type` rows carry no type of their own.
;; NB deliberately no keyword argument: each keyword-accepting
;; function costs one gensym at module instantiation, which would
;; shift every gensym-numbered label in whole-program output (the
;; byte-identity guarantee).
(define (enrich-provides provides top-types mid mangle?)
  (define (mangled n) (if mangle? (string->symbol (format "~a_~a" n mid)) n))
  (define (type-of n) (hash-ref top-types (mangled n) '_))
  (for/list ([row provides])
    (match row
      [`(,n type ,mn) `(,n type ,mn)]
      [`(,n val ,slot) `(,n val ,slot ,(type-of n))]
      [`(,n fun ,arity ,label) `(,n fun ,arity ,label ,(type-of n))])))

;; ---------------------------------------------------------------------
;; the (types ...) section: every ADT an importer may need to know,
;; each row (mangled source (param ...) (((ctor-mangled ctor-source)
;; field-type ...) ...)). Own rows come from the RESOLVED (renamed)
;; define-type forms; foreign mentions resolve against the direct
;; deps' rows (closed by induction), and the whole section is the
;; reachable closure from the provided names' rows + signatures.
;; ---------------------------------------------------------------------

(define builtin-type-names
  (seteq 'Int 'Bool 'Sym 'Str 'Void '_ '-> '->* 'List 'Vec 'Hash 'Set 'Pairof 'Mut))

(define (tyvar-name? s)
  (and (symbol? s)
       (let ([str (symbol->string s)])
         (and (> (string-length str) 0)
              (char-lower-case? (string-ref str 0))))))

;; ADT head symbols mentioned in a type expression
(define (type-mentions t)
  (cond [(symbol? t)
         (if (or (set-member? builtin-type-names t) (tyvar-name? t)) '() (list t))]
        [(pair? t) (append (type-mentions (car t)) (append-map type-mentions (cdr t)))]
        [else '()]))

(define (type-row-of form)
  ;; a foreign handle type: zero params, the marker symbol `foreign`
  ;; where an ADT row carries its constructor list -- the importer
  ;; splices #%extern-foreign-type for it (docs/FFI.md §6)
  (if (and (pair? form) (eq? (car form) 'define-foreign-type)
           (pair? (cdr form)) (symbol? (cadr form)))
      (list (cadr form) (module-demangle (cadr form)) '() 'foreign)
  (match form
    [`(define-type ,head ,cs ...)
     (define-values (n ps) (match head [`(,n ,ps ...) (values n ps)] [n (values n '())]))
     `(,n ,(module-demangle n) ,ps
       ,(for/list ([c cs])
          (match c
            [`(,cn ,fts ...) `((,cn ,(module-demangle cn)) ,@fts)])))]
    [_ #f])))

(define (row-mentions row)
  ;; foreign-marked rows (opaque handle types) mention nothing
  (if (eq? (list-ref row 3) 'foreign)
      '()
      (match row
        [`(,_ ,_ ,ps (,ctor-rows ...))
         (remove* ps (append-map (λ (c) (append-map type-mentions (cdr c))) ctor-rows))])))

;; the closed types section for a unit: own rows (from the resolved
;; body) + foreign rows (from dep infos), restricted to what the
;; enriched provides reach, transitively. Sorted by head for digest
;; stability.
(define (compute-type-rows resolved-forms provides dep-types)
  (define own (make-hasheq))
  (for ([f resolved-forms])
    (define row (type-row-of f))
    (when row (hash-set! own (car row) row)))
  (define (row-for h)
    (or (hash-ref own h #f) (hash-ref dep-types h #f)))
  ;; roots: provided type rows + every head a provided signature mentions
  (define roots
    (append (filter-map (λ (r) (match r [`(,_ type ,mn) mn] [_ #f])) provides)
            (append-map (λ (r) (match r
                                 [`(,_ ,(or 'val 'fun) ,_ ... ,t) (type-mentions t)]
                                 [_ '()]))
                        provides)))
  (define included (make-hasheq))
  (let visit ([hs roots])
    (for ([h hs])
      (unless (hash-has-key? included h)
        (define row (row-for h))
        (when row
          (hash-set! included h row)
          (visit (row-mentions row))))))
  (sort (hash-values included) symbol<? #:key car))

;; union of the deps' types rows, head -> row (identical duplicates
;; collapse; a real conflict cannot happen -- mangling is
;; deterministic over the absolute path)
(define (dep-type-rows dep-infos)
  (define acc (make-hasheq))
  (for* ([info dep-infos] [row (hash-ref info 'types '())])
    (define prev (hash-ref acc (car row) #f))
    (when (and prev (not (equal? prev row)))
      (error 'separate "interface type ~a has two conflicting definitions" (car row)))
    (hash-set! acc (car row) row))
  acc)

(define (write-pufi! pufi-path abs mid src-sha requires provides types globals-count)
  (make-directory* (path-only pufi-path))
  (with-output-to-file pufi-path #:exists 'replace
    (λ ()
      (pretty-write
       `(interface ,(path-str abs)
          (module-id ,mid)
          (source-sha1 ,src-sha)
          ,(build-flags)
          (requires ,@requires)
          (provides ,@provides)
          (types ,@types)
          (globals ,(mid->globals mid) ,globals-count)
          (init ,(mid->init mid)))))))

(define (read-pufi pufi-path)
  (and (file-exists? pufi-path)
       (with-handlers ([exn:fail? (λ (_) #f)])
         (with-input-from-file pufi-path read))))

;; a cached interface, parsed: #f unless it exists, matches the
;; current source/flags/requires, and its .o is present -- in which
;; case the info is rebuilt from the FILE (the recorded provides
;; carry the types the last compile's checker produced; recomputing
;; them would need a full typecheck)
(define (fresh-info pufi-path o-path abs requires mid)
  (define iface (read-pufi pufi-path))
  (and iface
       (file-exists? o-path)
       (match iface
         [`(interface ,_ (module-id ,fmid) (source-sha1 ,sha) ,flags
             (requires ,reqs ...) (provides ,provides ...) (types ,types ...)
             (globals ,_ ,n-globals) (init ,_))
          (and (equal? sha (source-sha1 abs))
               (equal? flags (build-flags))
               (equal? reqs requires)
               (equal? fmid mid)
               (make-info abs mid provides types n-globals o-path))]
         [_ #f])))

;; ---------------------------------------------------------------------
;; import resolution (mirrors src/modules.rkt's resolve-modules, but
;; against built dep INTERFACES rather than loaded module bodies)
;; ---------------------------------------------------------------------

(define (provides-names info)
  (map car (hash-ref info 'provides)))

(define (provide-entry info n)
  (assq n (hash-ref info 'provides)))

;; the marker symbol other modules use for `n` exported by dep.
;; Rows may or may not carry their trailing type yet (skeleton vs
;; enriched), so the patterns leave the tail open.
(define (marker-for info n)
  (match (provide-entry info n)
    [`(,_ fun ,_ ,label ,_ ...) label]
    [`(,_ type ,mn ,_ ...) mn]
    [`(,_ val ,_ ,_ ...) (mangle n (hash-ref info 'mid))]
    [#f #f]))

;; register the pipeline-facing binding for a marker (a type name has
;; no runtime artifact: its definition arrives as a #%extern-type)
(define (marker-binding info n)
  (match (provide-entry info n)
    [`(,_ fun ,_ ,label ,_ ...) `(fun ,label)]
    [`(,_ type ,_ ,_ ...) #f]
    [`(,_ val ,slot ,_ ...) `(val (ext ,(hash-ref info 'globals-label) ,slot))]))

;; a provide row's recorded type, rendered back to SOURCE spellings
;; (for comparison against a signature file's, which are source-side)
(define (provide-entry-type info n)
  (define (demangle-type t)
    (cond [(symbol? t) (module-demangle t)]
          [(pair? t) (cons (demangle-type (car t)) (demangle-type (cdr t)))]
          [else t]))
  (match (provide-entry info n)
    [`(,_ val ,_ ,t) (demangle-type t)]
    [`(,_ fun ,_ ,_ ,t) (demangle-type t)]
    [_ '_]))

;; client-side signature ascription against a built interface.
;; Entries: (val n) / (fun n arity) as always; typed entries
;; (val n τ) / (fun n (-> ...)) / (fun n (->* ...)) additionally check
;; the recorded interface type CONSISTENT with the stated one (`_`
;; where nothing was recorded, so an untyped module satisfies any
;; typed signature -- gradual all the way down); (type n) requires the
;; dep to provide the type name.
(define (check-signature-iface sig-path info from-path)
  (unless (file-exists? sig-path)
    (module-error "~a: signature file not found: ~a" from-path sig-path))
  (define sig
    (match (read-module-forms sig-path)
      [`((signature ,(? symbol? _) ,entries ...)) entries]
      [_ (module-error "~a: expected a single (signature NAME entries...) form" sig-path)]))
  ;; signature files are written in SOURCE spellings; recorded
  ;; interface types carry mangled ones -- demangle for comparison
  ;; (plain walk: gensym budget)
  (define (demangle-type t)
    (cond [(symbol? t) (module-demangle t)]
          [(pair? t) (cons (demangle-type (car t)) (demangle-type (cdr t)))]
          [else t]))
  (define (check-type! kind n stated)
    (define recorded (demangle-type (provide-entry-type info n)))
    (unless (consistent? recorded stated)
      (module-error "~a: signature ~a ~a states type ~a, interface records ~a"
                    (hash-ref info 'path) kind n stated recorded)))
  ;; a val row whose recorded type is an arrow holds a function --
  ;; (define f (lambda ...)) and foreign imports (docs/FFI.md §8.1)
  ;; both provide that way; its arrow fixes the arity
  (define (val-arrow-arity entry)
    (define t (and (pair? entry) (pair? (cddr entry))
                   (pair? (cdddr entry)) (cadddr entry)))
    (and (pair? t) (eq? (car t) '->) (- (length t) 2)))
  (define (check-fun-arity! n arity)
    (match (provide-entry info n)
      [`(,_ fun (fixed ,k) ,_ ,_ ...)
       (unless (= k arity)
         (module-error "~a: signature fun ~a expects arity ~a, definition has arity ~a"
                       (hash-ref info 'path) n arity k))]
      [`(,_ fun (variadic ,k) ,_ ,_ ...)
       (unless (>= arity k)
         (module-error "~a: signature fun ~a expects arity ~a, variadic definition needs >= ~a"
                       (hash-ref info 'path) n arity k))]
      [`(,_ val ,_ ,_ ...)
       (define k (val-arrow-arity (provide-entry info n)))
       (cond
         [(not k)
          (module-error "~a: signature fun ~a is not syntactically a function"
                        (hash-ref info 'path) n)]
         [(not (= k arity))
          (module-error "~a: signature fun ~a expects arity ~a, definition has arity ~a"
                        (hash-ref info 'path) n arity k)]
         [else (void)])]
      [`(,_ type ,_ ,_ ...)
       (module-error "~a: signature fun ~a names a type" (hash-ref info 'path) n)]
      [#f (module-error "~a: signature requires fun ~a, not provided"
                        (hash-ref info 'path) n)]))
  (for ([entry sig])
    (match entry
      [`(val ,(? symbol? n))
       (unless (provide-entry info n)
         (module-error "~a: signature requires val ~a, not provided" (hash-ref info 'path) n))]
      [`(val ,(? symbol? n) ,t)
       (unless (provide-entry info n)
         (module-error "~a: signature requires val ~a, not provided" (hash-ref info 'path) n))
       (check-type! 'val n t)]
      [`(fun ,(? symbol? n) ,(? exact-nonnegative-integer? arity))
       (check-fun-arity! n arity)]
      [`(fun ,(? symbol? n) (-> ,ts ... ,_))
       (check-fun-arity! n (length ts))
       (check-type! 'fun n (last entry))]
      [`(fun ,(? symbol? n) (->* ,_ ,_ ,_))
       (unless (provide-entry info n)
         (module-error "~a: signature requires fun ~a, not provided" (hash-ref info 'path) n))
       (check-type! 'fun n (last entry))]
      [`(type ,(? symbol? n))
       (match (provide-entry info n)
         [`(,_ type ,_ ,_ ...) (void)]
         [#f (module-error "~a: signature requires type ~a, not provided"
                           (hash-ref info 'path) n)]
         [_ (module-error "~a: signature type ~a is not a type" (hash-ref info 'path) n)])]
      [_ (module-error "~a: malformed signature entry: ~a" sig-path entry)])))

;; Resolve module m's body against its deps' interfaces + the prelude.
;; Returns (values resolved-forms ext-funs ext-globals ext-types exports).
;;   ren/qual pre-rename own top names (unless entry) and imports to
;;   marker labels; ext-funs/ext-globals give the pipeline bindings;
;;   ext-types (system.rkt module-ext-types) gives the checker the
;;   imports' interface types. resolved-forms open with one
;;   #%extern-type per ADT the deps' interfaces carry, so the checker
;;   and desugar register imported types/constructors up front.
(define (resolve-body m dep-info-of prelude-info mid #:entry? entry?)
  (define body (mod-body m))
  (define tops (mod-top-names m))
  (define m-path (path-str (mod-path m)))
  (define ren (make-hasheq))
  (define aliases (make-hasheq))       ; alias symbol -> dep info
  (define ext-funs (make-hasheq))      ; name -> label
  (define ext-globals (make-hasheq))   ; name -> (ext <label> <slot>)
  (define ext-types (make-hasheq))     ; marker/prelude name -> interface type
  (define extern-rows (make-hasheq))   ; ADT head -> .pufi types row
  (define (row-type-of entry)
    (match entry
      [`(,_ val ,_ ,t) t]
      [`(,_ fun ,_ ,_ ,t) t]
      [_ '_]))
  ;; everything a dep's interface teaches the checker: type rows
  ;; (deduped -- two deps may embed the same transitive ADT), the
  ;; demangle table (diagnostics say Shape, never Shape_shapes_9ab),
  ;; and each provide's type under its marker spelling
  (define (consume-dep-interface! info)
    (for ([row (hash-ref info 'types '())])
      (match-define `(,mn ,src ,_ ,ctor-rows) row)
      (define prev (hash-ref extern-rows mn #f))
      (when (and prev (not (equal? prev row)))
        (error 'separate "interface type ~a has two conflicting definitions" mn))
      (hash-set! extern-rows mn row)
      (module-demangle-register! mn src)
      ;; foreign-marked rows carry the marker symbol, not ctor rows
      (unless (eq? ctor-rows 'foreign)
        (for ([c ctor-rows])
          (match-define `((,cm ,cs) ,_ ...) c)
          (module-demangle-register! cm cs))))
    (for ([entry (hash-ref info 'provides)])
      (define n (car entry))
      (define marker (marker-for info n))
      (module-demangle-register! marker n)
      (define t (row-type-of entry))
      (unless (eq? t '_) (hash-set! ext-types marker t))))
  (define (bind-marker! info n)
    (match (marker-binding info n)
      [`(fun ,label) (hash-set! ext-funs (marker-for info n) label)]
      [`(val ,ext) (hash-set! ext-globals (marker-for info n) ext)]
      [#f (void)]))   ;; a type: no runtime artifact
  (define (add-import! local target from)
    (when (set-member? keyword-names local)
      (module-error "~a: cannot import ~a unqualified (reserved word); use #:as or #:rename"
                    m-path local))
    (when (set-member? tops local)
      (module-error "~a: import ~a from ~a collides with a local top-level definition"
                    m-path local from))
    (when (and (hash-ref ren local #f)
               (not (eq? (hash-ref ren local) target)))
      (module-error "~a: name ~a imported from two different modules" m-path local))
    (hash-set! ren local target))
  (for ([r (mod-reqs m)])
    (define dep (dep-info-of (path-str (req-path r))))
    (when (req-sig-path r)
      (check-signature-iface (req-sig-path r) dep m-path))
    (consume-dep-interface! dep)
    (cond
      [(req-alias r)
       (hash-set! aliases (req-alias r) dep)
       ;; every provided name is reachable via the alias
       (for ([n (provides-names dep)]) (bind-marker! dep n))]
      [else
       (define names
         (cond [(req-only r)
                (for ([n (req-only r)])
                  (unless (provide-entry dep n)
                    (module-error "~a: #:only name ~a is not provided by ~a"
                                  m-path n (hash-ref dep 'path))))
                (req-only r)]
               [else (provides-names dep)]))
       (define rename-map (or (req-renames r) '()))
       (for ([(old new) (in-dict rename-map)]
             #:unless (member old names))
         (module-error "~a: #:rename of ~a, which is not imported from ~a"
                       m-path old (hash-ref dep 'path)))
       (for ([n names])
         (define local (cond [(assq n rename-map) => cdr] [else n]))
         (add-import! local (marker-for dep n) (hash-ref dep 'path))
         (bind-marker! dep n))]))
  ;; the implicit prelude: every prelude export the module doesn't
  ;; define itself, keyed by SOURCE name (desugar reaches for e.g.
  ;; `append` after this resolution runs). Its (#%prelude: ...)
  ;; signatures travel as the rows' types, so separate-mode checking
  ;; of prelude calls matches whole-program checking.
  (for ([entry (hash-ref prelude-info 'provides)])
    (match entry
      [`(,n fun ,_ ,label ,_ ...)
       (unless (set-member? tops n)
         (hash-set! ext-funs n label)
         (let ([t (row-type-of entry)])
           (unless (eq? t '_) (hash-set! ext-types n t))))]
      [`(,n val ,slot ,_ ...)
       (unless (set-member? tops n)
         (hash-set! ext-globals n `(ext ,(hash-ref prelude-info 'globals-label) ,slot))
         (let ([t (row-type-of entry)])
           (unless (eq? t '_) (hash-set! ext-types n t))))]))
  ;; own top-level names mangle uniformly (never for the entry)
  (unless entry?
    (for ([n (in-set tops)])
      (hash-set! ren n (mangle n mid))))
  ;; qualified M.name (split at the first dot when M is an alias)
  (define (qual s)
    (define str (symbol->string s))
    (define i (for/first ([c (in-string str)] [k (in-naturals)] #:when (char=? c #\.)) k))
    (and i (> i 0) (< (add1 i) (string-length str))
         (let* ([prefix (string->symbol (substring str 0 i))]
                [dep (hash-ref aliases prefix #f)])
           (and dep
                (let ([n (string->symbol (substring str (add1 i)))])
                  (unless (provide-entry dep n)
                    (module-error "~a: ~a is not provided by ~a (via ~a)"
                                  m-path n (hash-ref dep 'path) s))
                  (marker-for dep n))))))
  ;; imported ADTs, registered up front: one #%extern-type per row
  ;; (typecheck-program and desugar treat it as a define-type that
  ;; defines nothing; the tags/labels live in the exporting .o)
  (define extern-forms
    (for/list ([row (sort (hash-values extern-rows) symbol<? #:key car)])
      (if (eq? (list-ref row 3) 'foreign)
          ;; an imported foreign handle type (docs/FFI.md §6): the
          ;; checker registers it opaque, desugar's cast-descs brand it
          (list '#%extern-foreign-type (car row))
      (match-let ([`(,mn ,_ ,ps ,ctor-rows) row])
        `(#%extern-type ,(if (null? ps) mn (cons mn ps))
                        ,@(for/list ([c ctor-rows])
                            (match-let ([`((,cm ,_) ,fts ...) c])
                              `(,cm ,@fts))))))))
  (values (append extern-forms (rename-forms body ren qual))
          (for/hash ([(k v) (in-hash ext-funs)]) (values k v))
          (for/hash ([(k v) (in-hash ext-globals)]) (values k v))
          (for/hash ([(k v) (in-hash ext-types)]) (values k v))
          ;; exported labels for .globl: provided fun labels
          (filter-map (λ (e) (match e [`(,_ fun ,_ ,label ,_ ...) label] [_ #f]))
                      (hash-ref (dep-info-of m-path) 'provides))))

;; ---------------------------------------------------------------------
;; compiling one unit to an object file
;; ---------------------------------------------------------------------

(define (assemble-object asm-text o-path what)
  (define tmp-s (build-path (find-system-path 'temp-dir)
                            (format "puffin-sep-~a-~a.s" (current-milliseconds) (path-hash o-path))))
  (with-output-to-file tmp-s #:exists 'replace (λ () (displayln asm-text)))
  (make-directory* (path-only o-path))
  (define cc (or (getenv "CC") "/usr/bin/clang"))
  (define tgt (target-triple))
  (define cmd (string-append cc " "
                             (flag-list->string
                              (list (if (string=? tgt "") "" (format "-target ~a" tgt))
                                    "-Wall -O2"))
                             " -c " (path-str tmp-s) " -o " (path-str o-path)))
  (define out (execute-get-output cmd))
  (delete-file tmp-s)
  (unless (file-exists? o-path)
    (error 'separate "assembling ~a failed:\n~a" what out)))

(define (compile-unit-to-object forms o-path
                                #:entry-name entry-name
                                #:sep sep
                                #:ext-funs ext-funs
                                #:ext-globals ext-globals
                                #:ext-types ext-types
                                #:top-sink top-sink
                                #:globals-label globals-label
                                #:what what)
  (unless (eq? (target) 'arm64)
    (error 'separate "separate compilation currently targets arm64 only (got ~a)" (target)))
  (define n-globals-box (box #f))
  (define trace
    (parameterize ([optimize-level (sep-optimize-level)]
                   [entry-symbol-name entry-name]
                   [module-sep-mode sep]
                   [module-ext-funs ext-funs]
                   [module-ext-globals ext-globals]
                   [module-ext-types ext-types]
                   [typecheck-top-sink top-sink]
                   [module-globals-label globals-label]
                   [globals-count-sink n-globals-box]
                   ;; compile-only: no per-pass interps/pretty IRs --
                   ;; and a failing pass (e.g. a type error at a typed
                   ;; interface boundary) surfaces its message instead
                   ;; of cascading through later passes
                   [retain-trace? #f]
                   [write-stdout-mode #f]
                   [verbose-mode #f])
      (compile-verbose `(program ,@forms))))
  (define lastp (last trace))
  (unless (and (equal? (hash-ref lastp 'pass-name "?") "render-asm")
               (string? (hash-ref lastp 'output #f)))
    (error 'separate "compiling ~a failed in pass ~a:\n~a"
           what
           (hash-ref lastp 'pass-name "?")
           (hash-ref lastp 'error
                     (λ () (hash-ref lastp 'pretty-output "")))))
  (assemble-object (hash-ref lastp 'output) o-path what)
  ;; the number of globals collect-globals assigned (for the .pufi)
  (unbox n-globals-box))

;; ---------------------------------------------------------------------
;; building modules (recursive, cached)
;; ---------------------------------------------------------------------

;; build the prelude as an implicitly-required module (no deps, all
;; top-level names provided, labels mangled like any other module)
(define (ensure-prelude!)
  (define abs (abs-of (build-path src-dir "prelude.puf")))
  (define mid (module-mid abs))
  (define body (read-module-forms abs))
  (define provides-set
    (for/seteq ([f body] #:when (defn-name f)) (defn-name f)))
  (define skeleton (compute-provides body provides-set mid #t))
  (define dir (cache-dir-for abs))
  (define o-path (build-path dir (string-append (file-stem abs) ".o")))
  (define pufi-path (build-path dir (string-append (file-stem abs) ".pufi")))
  (define n-vals (length (value-define-names body)))
  (cond
    [(fresh-info pufi-path o-path abs '() mid)]
    [else
     (define ren (make-hasheq))
     (for ([n (in-set provides-set)]) (hash-set! ren n (mangle n mid)))
     (define resolved (rename-forms body ren (λ (_) #f)))
     (define sink (box (hash)))
     (define n-globals
       (compile-unit-to-object resolved o-path
                               #:entry-name (mid->init mid)
                               #:sep (hash 'kind 'module
                                           'exports (filter-map (λ (e) (match e [`(,_ fun ,_ ,l) l] [_ #f])) skeleton))
                               #:ext-funs (hash)
                               #:ext-globals (hash)
                               #:ext-types (hash)
                               #:top-sink sink
                               #:globals-label (mid->globals mid)
                               #:what (path-str abs)))
     (unless (= n-globals n-vals)
       (error 'separate "~a: global count drifted (interface ~a, compiled ~a)"
              (path-str abs) n-vals n-globals))
     ;; the prelude's (#%prelude: ...) signatures ride along as the
     ;; provides' types (its own spellings mention no ADTs, so its
     ;; types section is empty)
     (define provides (enrich-provides skeleton (unbox sink) mid #t))
     (write-pufi! pufi-path abs mid (source-sha1 abs) '() provides '() n-vals)
     (log-rebuild! (path-str abs))
     (make-info abs mid provides '() n-vals o-path)]))

;; the (requires ...) rows for module m: the prelude plus each direct
;; dep, with its CURRENT interface digest
(define (requires-rows m dep-info-of prelude-info)
  (cons (list (hash-ref prelude-info 'path) (hash-ref prelude-info 'iface-digest))
        (for/list ([r (mod-reqs m)])
          (define dep (dep-info-of (path-str (req-path r))))
          (list (hash-ref dep 'path) (hash-ref dep 'iface-digest)))))

;; build one non-entry module (deps must already be built into infos)
(define (ensure-module! m infos prelude-info)
  (define abs (mod-path m))
  (define mid (module-mid abs))
  (define dir (cache-dir-for abs))
  (define o-path (build-path dir (string-append (file-stem abs) ".o")))
  (define pufi-path (build-path dir (string-append (file-stem abs) ".pufi")))
  (define (dep-info-of p) (hash-ref infos p (λ () (error 'separate "dependency not built: ~a" p))))
  (define skeleton (compute-provides (mod-body m) (mod-provides m) mid #t))
  (define requires (requires-rows m dep-info-of prelude-info))
  (define n-vals (length (value-define-names (mod-body m))))
  (cond
    [(fresh-info pufi-path o-path abs requires mid)]
    [else
     ;; make the module's own SKELETON info resolvable for the exports
     ;; list (labels/slots only; the types arrive after the compile)
     (hash-set! infos (path-str abs) (make-info abs mid skeleton '() n-vals o-path))
     (define-values (resolved ext-funs ext-globals ext-types exports)
       (resolve-body m dep-info-of prelude-info mid #:entry? #f))
     (define sink (box (hash)))
     (define n-globals
       (compile-unit-to-object resolved o-path
                               #:entry-name (mid->init mid)
                               #:sep (hash 'kind 'module 'exports exports)
                               #:ext-funs ext-funs
                               #:ext-globals ext-globals
                               #:ext-types ext-types
                               #:top-sink sink
                               #:globals-label (mid->globals mid)
                               #:what (path-str abs)))
     (unless (= n-globals n-vals)
       (error 'separate "~a: global count drifted (interface ~a, compiled ~a)"
              (path-str abs) n-vals n-globals))
     ;; typed interface: enrich the provides with the checker's types,
     ;; then close the (types ...) section over everything they mention
     (define provides (enrich-provides skeleton (unbox sink) mid #t))
     (define types
       (compute-type-rows resolved provides
                          (dep-type-rows
                           (cons prelude-info
                                 (for/list ([r (mod-reqs m)])
                                   (dep-info-of (path-str (req-path r))))))))
     (write-pufi! pufi-path abs mid (source-sha1 abs) requires provides types n-globals)
     (log-rebuild! (path-str abs))
     (make-info abs mid provides types n-globals o-path)]))

;; build the entry unit: main + its own top-level effects, calling
;; every init (prelude first, then require-DAG postorder) after
;; pf_init. Cached under <stem>.entry.{o,rec}; the record adds the
;; init-call list (a transitive dep changes it without touching the
;; entry's source or its direct deps' interfaces).
(define (ensure-entry! m infos prelude-info init-calls)
  (define abs (mod-path m))
  (define mid (module-mid abs))
  (define dir (cache-dir-for abs))
  (define o-path (build-path dir (string-append (file-stem abs) ".entry.o")))
  (define rec-path (build-path dir (string-append (file-stem abs) ".entry.rec")))
  (define (dep-info-of p)
    (if (equal? p (path-str abs))
        ;; the entry provides nothing (nothing may require it)
        (make-info abs mid '() '() 0 o-path)
        (hash-ref infos p)))
  (define requires
    ;; the entry depends on EVERY module's interface (init labels)
    (cons (list (hash-ref prelude-info 'path) (hash-ref prelude-info 'iface-digest))
          (for/list ([(p i) (in-hash infos)] #:unless (equal? p (path-str abs)))
            (list p (hash-ref i 'iface-digest)))))
  (define rec `(entry-record ,(path-str abs)
                             (source-sha1 ,(source-sha1 abs))
                             ,(build-flags)
                             (requires ,@(sort requires string<? #:key car))
                             (init-calls ,@init-calls)))
  (define cached (and (file-exists? o-path)
                      (with-handlers ([exn:fail? (λ (_) #f)])
                        (with-input-from-file rec-path read))))
  (cond
    [(equal? cached rec) (path-str o-path)]
    [else
     (define-values (resolved ext-funs ext-globals ext-types _exports)
       (resolve-body m dep-info-of prelude-info mid #:entry? #t))
     (compile-unit-to-object resolved o-path
                             #:entry-name 'main
                             #:sep (hash 'kind 'entry 'exports '() 'init-calls init-calls)
                             #:ext-funs ext-funs
                             #:ext-globals ext-globals
                             #:ext-types ext-types
                             #:top-sink #f
                             #:globals-label (mid->globals mid)
                             #:what (path-str abs))
     (make-directory* dir)
     (with-output-to-file rec-path #:exists 'replace (λ () (pretty-write rec)))
     (log-rebuild! (path-str abs))
     (path-str o-path)]))

;; ---------------------------------------------------------------------
;; entry points
;; ---------------------------------------------------------------------

;; load the DAG rooted at `path`, build every module bottom-up.
;; Returns (values postorder-mods infos prelude-info entry-mod).
(define (build-dag path)
  (define abs (abs-of path))
  (define-values (mods _loaded) (load-modules abs))
  (define prelude-info (ensure-prelude!))
  (define infos (make-hash))
  (define entry-m (last mods))
  (for ([m mods] #:unless (eq? m entry-m))
    (hash-set! infos (path-str (mod-path m)) (ensure-module! m infos prelude-info)))
  (values mods infos prelude-info entry-m))

;; `puffin -c --module foo.puf`: build foo (and, recursively, its
;; stale/missing deps) into the cache; returns the info
(define (build-module path)
  (define-values (mods infos prelude-info entry-m) (build-dag path))
  ;; the root is a MODULE here, not an entry
  (define info (ensure-module! entry-m infos prelude-info))
  (hash-set! infos (path-str (mod-path entry-m)) info)
  info)

;; `puffin -c --separate main.puf -o prog`
(define (build-separate path out)
  (define-values (mods infos prelude-info entry-m) (build-dag path))
  (define init-calls
    (cons (hash-ref prelude-info 'init)
          (for/list ([m mods] #:unless (eq? m entry-m))
            (hash-ref (hash-ref infos (path-str (mod-path m))) 'init))))
  (define entry-o (ensure-entry! entry-m infos prelude-info init-calls))
  (define objects
    (cons entry-o
          (append (for/list ([m mods] #:unless (eq? m entry-m))
                    (hash-ref (hash-ref infos (path-str (mod-path m))) 'o-path))
                  (list (hash-ref prelude-info 'o-path)))))
  (define cc (or (getenv "CC") "/usr/bin/clang"))
  (define tgt (target-triple))
  (define stack-flag (if (eq? (host-os) 'macosx) "-Wl,-stack_size,0x20000000" ""))
  (define linux-extra (if (eq? (host-os) 'unix) "-no-pie" ""))
  (define cmd
    (string-append cc " "
                   (flag-list->string
                    (list (if (string=? tgt "") "" (format "-target ~a" tgt))
                          "-Wall -O2" linux-extra stack-flag))
                   " " (string-join objects " ")
                   " " (runtime-archive)
                   " -o " out))
  (with-handlers ([exn:fail? (λ (_) (void))]) (delete-file out))
  (define link-out (execute-get-output cmd))
  (unless (file-exists? out)
    (error 'separate "linking failed:\n~a" link-out))
  out)
