#lang racket

;; Puffin -- modules.rkt: the module front pass (docs/MODULES.md).
;;
;; A file is a module. `(provide name ...)` declares exports (no
;; provide form = everything top-level); `(require "path.puf")`
;; imports another module's provided names, with the Racket
;; conveniences (#:as M for qualified M.name access, #:only, #:rename)
;; and optional signature ascription against a .pufs file.
;;
;; This pass runs BEFORE desugar and is invisible to the rest of the
;; pipeline: `(resolve-modules entry-path)` loads the require DAG,
;; gives every non-entry module's top-level names a deterministic
;; mangled spelling, rewrites each module's forms accordingly, and
;; returns one flat list of top-level forms in depth-first postorder
;; (each module once, entry last) -- an ordinary single-file program.
;;
;; Renaming discipline: a symbol is renamed UNIFORMLY throughout its
;; module (binders and references alike), which preserves binding
;; structure without scope analysis -- local shadowing of an imported
;; or module-level name shadows its renamed spelling instead, which
;; binds identically. The walker only has to know where symbols are
;; *data* rather than names: quoted datums, quasiquote outside
;; unquotes, match-pattern structure (constructor heads, quoted and
;; quasiquoted datums), and case-clause datums are left untouched.

(require "system.rkt")  ;; module-demangle-* (diagnostic rendering)
(require "types.rkt")   ;; consistent? -- typed signature entries

(provide resolve-modules
         module-forms?
         read-module-forms
         ;; shared with the separate-compilation driver (separate.rkt):
         ;; the DAG loader, the renamer, and the small pieces both
         ;; resolution styles agree on
         load-modules
         (struct-out mod)
         (struct-out req)
         rename-forms
         check-signature
         keyword-names
         defn-name
         defn-names
         defn-arity
         consistent?   ;; re-export (types.rkt): typed signature entries
         fnv1a-32
         module-error)

;; ---------------------------------------------------------------------
;; reading
;; ---------------------------------------------------------------------

;; read a file's top-level forms plus each form's (1-based) line --
;; read-syntax instead of read, so the reader itself records where
;; every top-level form starts (same datums; positions on the side)
(define (read-module-forms+lines file-name)
  (with-input-from-file file-name
    (λ ()
      (port-count-lines! (current-input-port))
      (let loop ([forms '()] [lines '()])
        (define stx (read-syntax file-name (current-input-port)))
        (if (eof-object? stx)
            (values (reverse forms) (reverse lines))
            (loop (cons (syntax->datum stx) forms)
                  (cons (syntax-line stx) lines)))))))

(define (read-module-forms file-name)
  (define-values (forms _lines) (read-module-forms+lines file-name))
  forms)

;; a path's basename, as rendered in diagnostics ("main.puf")
(define (path-basename p)
  (path->string (file-name-from-path p)))

(define (require-form? f) (match f [`(require ,_ ...) #t] [_ #f]))
(define (provide-form? f) (match f [`(provide ,_ ...) #t] [_ #f]))

;; does this list of top-level forms use the module system at all?
(define (module-forms? forms)
  (ormap (λ (f) (or (require-form? f) (provide-form? f))) forms))

;; ---------------------------------------------------------------------
;; small pieces
;; ---------------------------------------------------------------------

;; deterministic 32-bit FNV-1a over a string (stable across runs and
;; machines, unlike equal-hash-code)
(define (fnv1a-32 s)
  (for/fold ([h 2166136261])
            ([b (in-bytes (string->bytes/utf-8 s))])
    (bitwise-and (* (bitwise-xor h b) 16777619) #xFFFFFFFF)))

(define (module-error fmt . args)
  (apply error 'modules fmt args))

;; a define's name, or #f
(define (defn-name f)
  (match f
    [`(define (,g ,_ ...) ,_ ...) g]
    [`(define (,g . ,_) ,_ ...) g]
    [`(define ,(? symbol? x) ,_) x]
    [_ #f]))

;; every top-level name a form binds: defines bind one; define-type
;; binds its type name AND each constructor (docs/TYPES.md) -- all of
;; them provide/mangle like ordinary top-level names
(define (defn-names f)
  (match f
    [`(define-type ,head ,ctors ...)
     (cons (match head [`(,n ,_ ...) n] [n n])
           (filter-map (λ (c) (match c [`(,cn ,_ ...) cn] [_ #f])) ctors))]
    [_ (let ([n (defn-name f)]) (if n (list n) '()))]))

;; a define's arity for signature checking:
;;   (fixed n)     exactly n arguments
;;   (variadic n)  n or more
;;   val           not syntactically a function
(define (defn-arity f)
  (define (formals-arity formals)
    (let loop ([fo formals] [n 0])
      (cond [(null? fo) `(fixed ,n)]
            [(symbol? fo) `(variadic ,n)]
            [(pair? fo) (loop (cdr fo) (add1 n))]
            [else 'val])))
  (match f
    [`(define (,_ . ,formals) ,_ ...) (formals-arity formals)]
    [`(define ,_ (,(or 'lambda 'λ) ,formals ,_ ...))
     (if (list? formals) `(fixed ,(length formals)) (formals-arity formals))]
    [`(define ,_ ,_) 'val]
    [_ 'val]))

;; a constructor's "definition form" for arity checking: a synthetic
;; define whose formals mirror its fields (defn-arity then reports
;; (fixed <field count>)); 'val for a nullary constructor (a value)
(define (ctor-arity-form n forms)
  (or (for/or ([f forms])
        (match f
          [`(define-type ,_ ,cs ...)
           (for/or ([c cs])
             (match c
               [`(,cn ,fts ...) #:when (eq? cn n)
                (if (null? fts)
                    `(define ,n 0)
                    `(define (,n ,@(map (λ (_) '_) fts)) 0))]
               [_ #f]))]
          [_ #f]))
      `(define ,n 0)))

;; names that would change meaning if spliced in unqualified: special
;; form keywords and pattern/clause syntax. Importing one of these
;; unqualified is an error (use #:as or #:rename); stdlib primitives
;; are checked separately so the message can say so.
(define keyword-names
  (seteq 'define-type 'ann ':
         'define 'lambda 'λ 'let 'let* 'letrec 'begin 'if 'cond 'case
         'when 'unless 'match 'set! 'while 'quote 'quasiquote 'unquote
         'unquote-splicing 'and 'or 'else '_ '... 'require 'provide
         'signature '#%rest 'nil 'void 'read))

;; ---------------------------------------------------------------------
;; the module record
;; ---------------------------------------------------------------------

(struct mod (path      ; absolute simplified path
             id        ; mangle suffix string, #f for the entry module
             body      ; top-level forms minus require/provide
             top-names ; seteq of top-level defined names
             provides  ; seteq of exported (source) names
             reqs      ; list of req, in source order
             lines)    ; per-body-form source line (or #f), parallel to body
  #:transparent)

(struct req (path alias only renames sig-path line) #:transparent)

;; the spelling other modules see for `name` exported by `m`
(define (mangled m name)
  (if (mod-id m)
      (string->symbol (format "~a_~a" name (mod-id m)))
      name))

;; ---------------------------------------------------------------------
;; parsing module forms
;; ---------------------------------------------------------------------

;; (require "path" [#:as M] [#:only (n ...)] [#:rename ((old new) ...)]
;;          [#:sig "path.pufs"])
;; `line` is the require form's source line or #f (positional, not an
;; optional argument: optional/keyword arguments cost module-load
;; gensyms -- see system.rkt's GENSYM-BUDGET note)
(define (parse-require f base-dir line)
  (define (bad) (module-error "malformed require: ~a" f))
  (match f
    [`(require ,(? string? path) ,opts ...)
     (let loop ([opts opts] [alias #f] [only #f] [renames #f] [sig #f])
       (match opts
         ['()
          (when (and alias (or only renames))
            (module-error "require ~a: #:as cannot be combined with #:only/#:rename" path))
          (req (simplify-path (path->complete-path path base-dir) #f)
               alias only renames
               (and sig (simplify-path (path->complete-path sig base-dir) #f))
               line)]
         [`(#:as ,(? symbol? m) . ,rest) (loop rest m only renames sig)]
         [`(#:only (,(? symbol? ns) ...) . ,rest) (loop rest alias ns renames sig)]
         [`(#:rename ([,(? symbol? olds) ,(? symbol? news)] ...) . ,rest)
          (loop rest alias only (map cons olds news) sig)]
         [`(#:sig ,(? string? s) . ,rest) (loop rest alias only renames s)]
         [_ (bad)]))]
    [_ (bad)]))

;; (provide n ...) or (provide #:sig "path.pufs"); a module's provide
;; forms are unioned, sig ascription must be the only provide
(define (parse-provides forms base-dir top-names path lines)
  (define ls (if (and lines (= (length lines) (length forms))) lines (map (λ (_) #f) forms)))
  ;; boxed so #f lines survive the filter-map (gensym budget: no
  ;; parallel-clause for forms here)
  (define provide-lines
    (map unbox (filter-map (λ (f l) (and (provide-form? f) (box l))) forms ls)))
  (define provide-forms (filter provide-form? forms))
  (define sig-forms
    (filter (λ (f) (match f [`(provide #:sig ,_) #t] [_ #f])) provide-forms))
  (cond
    [(pair? sig-forms)
     (unless (and (null? (cdr sig-forms)) (= (length provide-forms) 1))
       (module-error "~a: (provide #:sig ...) must be the module's only provide form" path))
     (match-define `(provide #:sig ,(? string? sig-path)) (car sig-forms))
     (check-signature (simplify-path (path->complete-path sig-path base-dir) #f)
                      forms top-names path)]
    [(null? provide-forms)
     ;; no provide form at all: everything top-level is provided
     top-names]
    [else
     ;; single-clause for/fold over zipped pairs (gensym budget; see
     ;; the note in load-modules)
     (for/fold ([acc (seteq)]) ([pp (map cons provide-forms provide-lines)])
       (define pf (car pp))
       (define pl (cdr pp))
       (match pf
         [`(provide ,(? symbol? ns) ...)
          (for ([n ns])
            (unless (set-member? top-names n)
              (module-error "~a provides ~a, which it does not define~a" path n
                            (if pl (format " [~a:~a]" (path-basename path) pl) ""))))
          (for/fold ([a acc]) ([n ns]) (set-add a n))]
         [_ (module-error "malformed provide in ~a: ~a" path pf)]))]))

;; signature ascription: every sig name defined, fun arities match,
;; and the export set narrows to exactly the signature.
;;
;; TYPED entries (docs/MODULES.md §2): (val n τ), (fun n (-> ...)),
;; (fun n (->* ...)), and (type n). A typed fun entry's arrow supplies
;; the arity check; when the module DECLARES a type for the name
;; ((: n τ') or a define-type head), the stated type must additionally
;; be consistent with the declared one -- an undeclared (inferred or
;; dynamic) name satisfies any stated type, gradually. The deep
;; check across compilation units lives on the separate-compilation
;; path (separate.rkt check-signature-iface, against the .pufi's
;; recorded types, synthesized ones included).
(define (check-signature sig-path forms top-names mod-path)
  (unless (file-exists? sig-path)
    (module-error "~a: signature file not found: ~a" mod-path sig-path))
  (define sig
    (match (read-module-forms sig-path)
      [`((signature ,(? symbol? _) ,entries ...)) entries]
      [_ (module-error "~a: expected a single (signature NAME entries...) form" sig-path)]))
  (define by-name
    (for/hasheq ([f forms] #:when (defn-name f))
      (values (defn-name f) f)))
  (define type-heads
    (for/seteq ([f forms]
                #:when (match f [`(define-type ,_ ,_ ...) #t] [_ #f]))
      (match f
        [`(define-type (,n ,_ ...) ,_ ...) n]
        [`(define-type ,n ,_ ...) n])))
  (define declared   ;; (: n τ) declarations, for typed-entry checks
    (for/hasheq ([f forms]
                 #:when (match f [`(: ,(? symbol?) ,_) #t] [_ #f]))
      (match f [`(: ,n ,t) (values n t)])))
  (define (check-declared! kind n stated)
    (define dt (hash-ref declared n '_))
    (unless (consistent? dt stated)
      (module-error "~a: signature ~a ~a states type ~a, module declares ~a"
                    mod-path kind n stated dt)))
  (define (check-fun-arity! n arity)
    (match (defn-arity (hash-ref by-name n
                                 ;; a constructor (bound by define-type,
                                 ;; not a define): its field count is
                                 ;; its arity
                                 (λ () (ctor-arity-form n forms))))
      [`(fixed ,k)
       (unless (= k arity)
         (module-error "~a: signature fun ~a expects arity ~a, definition has arity ~a"
                       mod-path n arity k))]
      [`(variadic ,k)
       (unless (>= arity k)
         (module-error "~a: signature fun ~a expects arity ~a, variadic definition needs >= ~a"
                       mod-path n arity k))]
      ['val
       (module-error "~a: signature fun ~a is not syntactically a function" mod-path n)]))
  (define (require-defined! kind n)
    (unless (set-member? top-names n)
      (module-error "~a: signature requires ~a ~a, not defined" mod-path kind n)))
  (for/fold ([acc (seteq)]) ([entry sig])
    (match entry
      [`(val ,(? symbol? n))
       (require-defined! 'val n)
       (set-add acc n)]
      [`(val ,(? symbol? n) ,t)
       (require-defined! 'val n)
       (check-declared! 'val n t)
       (set-add acc n)]
      [`(fun ,(? symbol? n) ,(? exact-nonnegative-integer? arity))
       (require-defined! 'fun n)
       (check-fun-arity! n arity)
       (set-add acc n)]
      [`(fun ,(? symbol? n) (-> ,ts ... ,_))
       (require-defined! 'fun n)
       (check-fun-arity! n (length ts))
       (check-declared! 'fun n (last entry))
       (set-add acc n)]
      [`(fun ,(? symbol? n) (->* ,_ ,_ ,_))
       (require-defined! 'fun n)
       (check-declared! 'fun n (last entry))
       (set-add acc n)]
      [`(type ,(? symbol? n))
       (unless (set-member? type-heads n)
         (module-error "~a: signature requires type ~a, not defined" mod-path n))
       (set-add acc n)]
      [_ (module-error "~a: malformed signature entry: ~a" sig-path entry)])))

;; ---------------------------------------------------------------------
;; loading the DAG
;; ---------------------------------------------------------------------

(define (load-modules entry-path)
  (define entry-abs (simplify-path (path->complete-path entry-path) #f))
  (define entry-dir (path-only entry-abs))
  (define loaded (make-hash))   ; abs path (string) -> mod
  (define postorder '())        ; reversed accumulation
  (define ids (make-hash))      ; id string -> path, collision check
  (define (module-id abs)
    (define rel
      (let ([r (find-relative-path entry-dir abs)])
        (if (path? r) (path->string r) (path->string abs))))
    (define stem
      (regexp-replace* #rx"[^a-zA-Z0-9]" (path->string (path-replace-extension (file-name-from-path abs) "")) "_"))
    (define id (format "~a_~a" stem (number->string (fnv1a-32 rel) 16)))
    (when (and (hash-has-key? ids id) (not (equal? (hash-ref ids id) abs)))
      (module-error "module id collision between ~a and ~a" (hash-ref ids id) abs))
    (hash-set! ids id abs)
    id)
  (define (visit abs stack from-line)
    (define key (path->string abs))
    (cond
      [(member key (map path->string stack))
       (module-error "require cycle: ~a"
                     (string-join (append (reverse (map path->string stack)) (list key)) " -> "))]
      [(hash-ref loaded key #f) => values]
      [else
       (unless (file-exists? abs)
         (module-error "required module not found: ~a~a~a"
                       abs
                       (if (null? stack) "" (format " (from ~a)" (path->string (car stack))))
                       (if (and from-line (pair? stack))
                           (format " [~a:~a]" (path-basename (car stack)) from-line)
                           "")))
       (define-values (raw raw-lines) (read-module-forms+lines abs))
       (define-values (forms form-lines)
         (match raw
           ;; class-style wrapper: inner forms carry no positions
           [`((program ,inner ...)) (values inner (map (λ (_) #f) inner))]
           [fs (values fs raw-lines)]))
       ;; GENSYM-BUDGET NOTE: this file's loop-form census is
       ;; deliberately unchanged from before position tracking (one
       ;; for/list here, one for/fold in parse-provides; zipping via
       ;; map cons instead of adding parallel clauses) -- for/list
       ;; costs 2 module-load gensyms and for/fold 1, and the budget
       ;; must stay put for whole-program byte-identity (system.rkt).
       (define reqs
         (for/list ([p (map cons forms form-lines)]
                    #:when (require-form? (car p)))
           (parse-require (car p) (path-only abs) (cdr p))))
       ;; load dependencies first (postorder)
       (for ([r reqs]) (visit (req-path r) (cons abs stack) (req-line r)))
       (define body+lines
         (filter-map (λ (f l) (and (not (or (require-form? f) (provide-form? f)))
                                   (cons f l)))
                     forms form-lines))
       (define body (map car body+lines))
       (define body-lines (map cdr body+lines))
       (define top-names
         (for/fold ([acc (seteq)]) ([f body])
           (for/fold ([a acc]) ([n (defn-names f)]) (set-add a n))))
       (define provides (parse-provides forms (path-only abs) top-names abs form-lines))
       (define m (mod abs
                      (if (equal? abs entry-abs) #f (module-id abs))
                      body top-names provides reqs body-lines))
       (hash-set! loaded key m)
       (set! postorder (cons m postorder))
       m]))
  (visit entry-abs '() #f)
  (values (reverse postorder) loaded))

;; ---------------------------------------------------------------------
;; the renamer: uniform symbol substitution, data-position aware
;; ---------------------------------------------------------------------

;; ren: hasheq name -> new-name; qual: (symbol-with-dot -> symbol or #f)
(define (rename-forms forms ren qual)
  (define (sym s)
    (cond [(hash-ref ren s #f) => values]
          [(qual s) => values]
          [else s]))
  ;; quasiquote template: symbols are data; descend only into escapes
  (define (qq q depth)
    (match q
      [(list 'unquote e)
       (list 'unquote (if (= depth 1) (expr e) (qq e (sub1 depth))))]
      [(list 'quasiquote e) (list 'quasiquote (qq e (add1 depth)))]
      [(cons (list 'unquote-splicing e) rest)
       (cons (list 'unquote-splicing (if (= depth 1) (expr e) (qq e (sub1 depth))))
             (qq rest depth))]
      [(cons a rest) (cons (qq a depth) (qq rest depth))]
      [_ q]))
  ;; match patterns: variables rename (uniformly with their uses),
  ;; constructor heads and datums do not
  (define (pat p)
    (match p
      ['_ p]
      [(? symbol? x) (sym x)]
      [(list 'quote _) p]
      [(list 'quasiquote q) (list 'quasiquote (qq-pat q))]
      [(list 'cons p0 p1) (list 'cons (pat p0) (pat p1))]
      [(list-rest 'list ps) (cons 'list (map pat ps))]
      [(list-rest 'vector ps) (cons 'vector (map pat ps))]
      [(list '? pred p0) (list '? (sym pred) (pat p0))]
      ;; ADT constructor patterns: the head is a top-level name
      ;; (renamed like any other), the rest are subpatterns
      [(cons (? symbol? head) (? list? ps)) (cons (sym head) (map pat ps))]
      [_ p]))
  (define (qq-pat q)
    (match q
      [(list 'unquote p) (list 'unquote (pat p))]
      [(cons a rest) (cons (qq-pat a) (qq-pat rest))]
      [_ q]))
  (define (match-clause cl)
    (match cl
      [`[,p #:when ,guard ,body ...]
       `[,(pat p) #:when ,(expr guard) ,@(map expr body)]]
      [`[,p ,body ...]
       `[,(pat p) ,@(map expr body)]]
      [_ cl]))
  (define (case-clause cl)
    (match cl
      [`[else ,body ...] `[else ,@(map expr body)]]
      [`[(,ds ...) ,body ...] `[(,@ds) ,@(map expr body)]]
      [_ cl]))
  (define (expr e)
    (match e
      [(? symbol? x) (sym x)]
      [(list 'quote _) e]
      [(list 'quasiquote q) (list 'quasiquote (qq q 1))]
      [`(match ,subj ,clauses ...)
       `(match ,(expr subj) ,@(map match-clause clauses))]
      [`(case ,k ,clauses ...)
       `(case ,(expr k) ,@(map case-clause clauses))]
      [(cons a d) (cons (expr a) (expr d))]
      [_ e]))
  (map expr forms))

;; ---------------------------------------------------------------------
;; resolve-modules: the entry point
;; ---------------------------------------------------------------------

(define (resolve-modules entry-path)
  (define-values (mods loaded) (load-modules entry-path))
  ;; fresh demangling table for this program: every mangled spelling
  ;; maps back to its source spelling, for diagnostic rendering only
  (module-demangle-reset!)
  (define (lookup abs) (hash-ref loaded (path->string abs)))
  ;; every symbol mentioned anywhere, for the mangled-name collision check
  (define all-mentions
    (for/fold ([acc (seteq)]) ([m mods])
      (let walk ([v (mod-body m)] [acc acc])
        (cond [(symbol? v) (set-add acc v)]
              [(pair? v) (walk (cdr v) (walk (car v) acc))]
              [else acc]))))
  (define flat
    (for/list ([m mods])
      ;; import maps for this module
      (define ren (make-hasheq))
      (define aliases (make-hasheq))  ; alias symbol -> mod
      (define (add-import! local target from)
        (when (set-member? keyword-names local)
          (module-error "~a: cannot import ~a unqualified (reserved word); use #:as or #:rename"
                        (mod-path m) local))
        (when (set-member? (mod-top-names m) local)
          (module-error "~a: import ~a from ~a collides with a local top-level definition"
                        (mod-path m) local from))
        (when (and (hash-ref ren local #f)
                   (not (eq? (hash-ref ren local) target)))
          (module-error "~a: name ~a imported from two different modules" (mod-path m) local))
        (hash-set! ren local target))
      (for ([r (mod-reqs m)])
        (define dep (lookup (req-path r)))
        ;; belt-and-braces client-side ascription: re-check the dep
        ;; against a signature at the use site
        (when (req-sig-path r)
          (check-signature (req-sig-path r) (mod-body dep) (mod-top-names dep) (mod-path dep)))
        (cond
          [(req-alias r) (hash-set! aliases (req-alias r) dep)]
          [else
           (define names
             (cond [(req-only r)
                    (for ([n (req-only r)])
                      (unless (set-member? (mod-provides dep) n)
                        (module-error "~a: #:only name ~a is not provided by ~a"
                                      (mod-path m) n (mod-path dep))))
                    (req-only r)]
                   [else (set->list (mod-provides dep))]))
           (define rename-map (or (req-renames r) '()))
           (for ([(old new) (in-dict rename-map)]
                 #:unless (member old names))
             (module-error "~a: #:rename of ~a, which is not imported from ~a"
                           (mod-path m) old (mod-path dep)))
           (for ([n names])
             (define local (cond [(assq n rename-map) => cdr] [else n]))
             (add-import! local (mangled dep n) (mod-path dep)))]))
      ;; own top-level names (non-entry modules get mangled spellings)
      (when (mod-id m)
        (for ([n (in-set (mod-top-names m))])
          (define mn (mangled m n))
          (when (set-member? all-mentions mn)
            (module-error "~a: source uses ~a, which collides with a mangled module name"
                          (mod-path m) mn))
          (module-demangle-register! mn n)
          (hash-set! ren n mn)))
      ;; qualified M.name resolution (split at the first dot; only
      ;; when the prefix is a module alias)
      (define (qual s)
        (define str (symbol->string s))
        (define i (for/first ([c (in-string str)] [k (in-naturals)] #:when (char=? c #\.)) k))
        (and i (> i 0) (< (add1 i) (string-length str))
             (let* ([prefix (string->symbol (substring str 0 i))]
                    [dep (hash-ref aliases prefix #f)])
               (and dep
                    (let ([n (string->symbol (substring str (add1 i)))])
                      (unless (set-member? (mod-provides dep) n)
                        (module-error "~a: ~a is not provided by ~a (via ~a)"
                                      (mod-path m) n (mod-path dep) s))
                      (mangled dep n))))))
      (rename-forms (mod-body m) ren qual)))
  ;; the renamer is 1:1 per form, so each module's body-lines map
  ;; straight onto its renamed forms; stash the flattened origins for
  ;; read-program-file (see system.rkt: resolved-origins)
  (resolved-origins-set!
   (append-map (λ (m)
                 (define base (path-basename (mod-path m)))
                 (map (λ (l) (and l (cons base l))) (mod-lines m)))
               mods))
  (apply append flat))
