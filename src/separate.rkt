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
         "modules.rkt"
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
;; interface (.pufi) records
;;
;; (interface "<abs path>"
;;   (module-id "<mid>")
;;   (source-sha1 "<hex>")
;;   (flags (target arm64) (optimize 1) (safe #t))
;;   (requires ("<abs dep path>" "<dep interface digest>") ...)
;;   (provides (area fun (fixed 1) area_geometry_3f9a)
;;             (pi val 0))
;;   (globals pfm_globals_geometry_3f9a 1)
;;   (init pfm_init_geometry_3f9a))
;;
;; The interface DIGEST covers only what importers' code depends on
;; (module-id, provides, globals label/count, init) -- NOT the source
;; sha -- so editing a module's bodies reboots only that module.
;; ---------------------------------------------------------------------

;; info: an in-memory hash describing a built module
;;   'path 'mid 'provides 'globals-label 'globals-count 'init
;;   'iface-digest 'o-path
(define (info-iface-digest provides mid globals-label globals-count init)
  (sha1 (open-input-string
         (format "~s" (list mid provides globals-label globals-count init)))))

(define (make-info abs mid provides globals-count o-path)
  (define gl (mid->globals mid))
  (define init (mid->init mid))
  (hash 'path (path-str abs)
        'mid mid
        'provides provides
        'globals-label gl
        'globals-count globals-count
        'init init
        'iface-digest (info-iface-digest provides mid gl globals-count init)
        'o-path (path-str o-path)))

;; the provides table for a module: sorted by name for digest
;; stability. Value defines are numbered by their SOURCE ORDER among
;; value defines -- exactly collect-globals' numbering (every pass up
;; to it preserves top-level define order and shape).
(define (compute-provides body provides-set mid #:mangle? mangle?)
  (define val-slot
    (let loop ([forms body] [i 0] [acc (hash)])
      (match forms
        ['() acc]
        [(cons `(define ,(? symbol? x) ,_) rest)
         (loop rest (add1 i) (hash-set acc x i))]
        [(cons _ rest) (loop rest i acc)])))
  (define by-name
    (for/hash ([f body] #:when (defn-name f)) (values (defn-name f) f)))
  (for/list ([n (sort (set->list provides-set) symbol<?)])
    (define form (hash-ref by-name n #f))
    (unless form
      (module-error "~a: provided name ~a has no definition" mid n))
    (match (defn-arity form)
      ['val `(,n val ,(hash-ref val-slot n))]
      [arity `(,n fun ,arity ,(if mangle? (mangle n mid) n))])))

;; the unit's global count without compiling: collect-globals assigns
;; one slot per top-level value define, in order (every pass before
;; it preserves top-level define order and shape)
(define (count-value-defines body)
  (for/sum ([f body]) (match f [`(define ,(? symbol?) ,_) 1] [_ 0])))

(define (write-pufi! pufi-path abs mid src-sha requires provides globals-count)
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
          (globals ,(mid->globals mid) ,globals-count)
          (init ,(mid->init mid)))))))

(define (read-pufi pufi-path)
  (and (file-exists? pufi-path)
       (with-handlers ([exn:fail? (λ (_) #f)])
         (with-input-from-file pufi-path read))))

;; is the cached build of `abs` still valid?
(define (fresh? pufi-path o-path abs requires)
  (define iface (read-pufi pufi-path))
  (and iface
       (file-exists? o-path)
       (match iface
         [`(interface ,_ (module-id ,_) (source-sha1 ,sha) ,flags
             (requires ,reqs ...) ,_ ...)
          (and (equal? sha (source-sha1 abs))
               (equal? flags (build-flags))
               (equal? reqs requires))]
         [_ #f])))

;; ---------------------------------------------------------------------
;; import resolution (mirrors src/modules.rkt's resolve-modules, but
;; against built dep INTERFACES rather than loaded module bodies)
;; ---------------------------------------------------------------------

(define (provides-names info)
  (map car (hash-ref info 'provides)))

(define (provide-entry info n)
  (assq n (hash-ref info 'provides)))

;; the marker symbol other modules use for `n` exported by dep
(define (marker-for info n)
  (match (provide-entry info n)
    [`(,_ fun ,_ ,label) label]
    [`(,_ val ,_) (mangle n (hash-ref info 'mid))]
    [#f #f]))

;; register the pipeline-facing binding for a marker
(define (marker-binding info n)
  (match (provide-entry info n)
    [`(,_ fun ,_ ,label) `(fun ,label)]
    [`(,_ val ,slot) `(val (ext ,(hash-ref info 'globals-label) ,slot))]))

;; client-side signature ascription against a built interface
(define (check-signature-iface sig-path info from-path)
  (unless (file-exists? sig-path)
    (module-error "~a: signature file not found: ~a" from-path sig-path))
  (define sig
    (match (read-module-forms sig-path)
      [`((signature ,(? symbol? _) ,entries ...)) entries]
      [_ (module-error "~a: expected a single (signature NAME entries...) form" sig-path)]))
  (for ([entry sig])
    (match entry
      [`(val ,(? symbol? n))
       (unless (provide-entry info n)
         (module-error "~a: signature requires val ~a, not provided" (hash-ref info 'path) n))]
      [`(fun ,(? symbol? n) ,(? exact-nonnegative-integer? arity))
       (match (provide-entry info n)
         [`(,_ fun (fixed ,k) ,_)
          (unless (= k arity)
            (module-error "~a: signature fun ~a expects arity ~a, definition has arity ~a"
                          (hash-ref info 'path) n arity k))]
         [`(,_ fun (variadic ,k) ,_)
          (unless (>= arity k)
            (module-error "~a: signature fun ~a expects arity ~a, variadic definition needs >= ~a"
                          (hash-ref info 'path) n arity k))]
         [`(,_ val ,_)
          (module-error "~a: signature fun ~a is not syntactically a function"
                        (hash-ref info 'path) n)]
         [#f (module-error "~a: signature requires fun ~a, not provided"
                           (hash-ref info 'path) n)])]
      [_ (module-error "~a: malformed signature entry: ~a" sig-path entry)])))

;; Resolve module m's body against its deps' interfaces + the prelude.
;; Returns (values resolved-forms ext-funs ext-globals exports).
;;   ren/qual pre-rename own top names (unless entry) and imports to
;;   marker labels; ext-funs/ext-globals give the pipeline bindings.
(define (resolve-body m dep-info-of prelude-info mid #:entry? entry?)
  (define body (mod-body m))
  (define tops (mod-top-names m))
  (define m-path (path-str (mod-path m)))
  (define ren (make-hasheq))
  (define aliases (make-hasheq))       ; alias symbol -> dep info
  (define ext-funs (make-hasheq))      ; name -> label
  (define ext-globals (make-hasheq))   ; name -> (ext <label> <slot>)
  (define (bind-marker! info n)
    (match (marker-binding info n)
      [`(fun ,label) (hash-set! ext-funs (marker-for info n) label)]
      [`(val ,ext) (hash-set! ext-globals (marker-for info n) ext)]))
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
  ;; `append` after this resolution runs)
  (for ([entry (hash-ref prelude-info 'provides)])
    (match entry
      [`(,n fun ,_ ,label)
       (unless (set-member? tops n) (hash-set! ext-funs n label))]
      [`(,n val ,slot)
       (unless (set-member? tops n)
         (hash-set! ext-globals n `(ext ,(hash-ref prelude-info 'globals-label) ,slot)))]))
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
  (values (rename-forms body ren qual)
          (for/hash ([(k v) (in-hash ext-funs)]) (values k v))
          (for/hash ([(k v) (in-hash ext-globals)]) (values k v))
          ;; exported labels for .globl: provided fun labels
          (filter-map (λ (e) (match e [`(,_ fun ,_ ,label) label] [_ #f]))
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
                                #:globals-label globals-label
                                #:what what)
  (unless (eq? (target) 'arm64)
    (error 'separate "separate compilation currently targets arm64 only (got ~a)" (target)))
  (define trace
    (parameterize ([optimize-level (sep-optimize-level)]
                   [entry-symbol-name entry-name]
                   [module-sep-mode sep]
                   [module-ext-funs ext-funs]
                   [module-ext-globals ext-globals]
                   [module-globals-label globals-label]
                   [write-stdout-mode #f]
                   [verbose-mode #f])
      (compile-verbose `(program ,@forms))))
  (define lastp (last trace))
  (unless (and (equal? (hash-ref lastp 'pass-name "?") "render-asm")
               (string? (hash-ref lastp 'output #f)))
    (error 'separate "compiling ~a failed in pass ~a:\n~a"
           what
           (hash-ref lastp 'pass-name "?")
           (hash-ref lastp 'pretty-output "")))
  (assemble-object (hash-ref lastp 'output) o-path what)
  ;; the number of globals collect-globals assigned (for the .pufi)
  (for/or ([h trace])
    (and (equal? (hash-ref h 'pass-name) "collect-globals")
         (hash-ref (second (hash-ref h 'output)) 'globals))))

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
  (define provides (compute-provides body provides-set mid #:mangle? #t))
  (define dir (cache-dir-for abs))
  (define o-path (build-path dir (string-append (file-stem abs) ".o")))
  (define pufi-path (build-path dir (string-append (file-stem abs) ".pufi")))
  (define n-vals (count-value-defines body))
  (define info (make-info abs mid provides n-vals o-path))
  (cond
    [(fresh? pufi-path o-path abs '()) info]
    [else
     (define ren (make-hasheq))
     (for ([n (in-set provides-set)]) (hash-set! ren n (mangle n mid)))
     (define resolved (rename-forms body ren (λ (_) #f)))
     (define n-globals
       (compile-unit-to-object resolved o-path
                               #:entry-name (mid->init mid)
                               #:sep (hash 'kind 'module
                                           'exports (filter-map (λ (e) (match e [`(,_ fun ,_ ,l) l] [_ #f])) provides))
                               #:ext-funs (hash)
                               #:ext-globals (hash)
                               #:globals-label (mid->globals mid)
                               #:what (path-str abs)))
     (unless (= n-globals n-vals)
       (error 'separate "~a: global count drifted (interface ~a, compiled ~a)"
              (path-str abs) n-vals n-globals))
     (write-pufi! pufi-path abs mid (source-sha1 abs) '() provides n-vals)
     (log-rebuild! (path-str abs))
     info]))

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
  (define provides (compute-provides (mod-body m) (mod-provides m) mid #:mangle? #t))
  (define requires (requires-rows m dep-info-of prelude-info))
  (define n-vals (count-value-defines (mod-body m)))
  (define info (make-info abs mid provides n-vals o-path))
  (cond
    [(fresh? pufi-path o-path abs requires) info]
    [else
     ;; make the module's own info resolvable for the exports list
     (hash-set! infos (path-str abs) info)
     (define-values (resolved ext-funs ext-globals exports)
       (resolve-body m dep-info-of prelude-info mid #:entry? #f))
     (define n-globals
       (compile-unit-to-object resolved o-path
                               #:entry-name (mid->init mid)
                               #:sep (hash 'kind 'module 'exports exports)
                               #:ext-funs ext-funs
                               #:ext-globals ext-globals
                               #:globals-label (mid->globals mid)
                               #:what (path-str abs)))
     (unless (= n-globals n-vals)
       (error 'separate "~a: global count drifted (interface ~a, compiled ~a)"
              (path-str abs) n-vals n-globals))
     (write-pufi! pufi-path abs mid (source-sha1 abs) requires provides n-globals)
     (log-rebuild! (path-str abs))
     info]))

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
        (make-info abs mid '() 0 o-path)
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
     (define-values (resolved ext-funs ext-globals _exports)
       (resolve-body m dep-info-of prelude-info mid #:entry? #t))
     (compile-unit-to-object resolved o-path
                             #:entry-name 'main
                             #:sep (hash 'kind 'entry 'exports '() 'init-calls init-calls)
                             #:ext-funs ext-funs
                             #:ext-globals ext-globals
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
