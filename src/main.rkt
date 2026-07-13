#lang racket

;; Puffin -- main.rkt: plugs the passes together, records each
;; intermediate output, and drives assembly/linking. Descended from
;; the class p5 main.rkt: run-chain / trace machinery is unchanged
;; in spirit; the pass table is now assembled per *target* (x86-64
;; or arm64), and programs link against the runtime archive
;; (src/runtime/libpuffin.a) instead of a single runtime.o.

(provide (all-defined-out)) ;; for test.rkt

(require racket/runtime-path)
(require "system.rkt")
(require "irs.rkt")
(require "opt/optimize.rkt"
         "modules.rkt"
         "compile.rkt")
(require "interpreters.rkt")
(require "backend-x86.rkt")

(define-runtime-path src-dir ".")

;; ---------------------------------------------------------------------
;; The pass tables: name, input predicate, output predicate,
;; interpreter. The frontend/middle-end is target-independent; the
;; backend four-pass suffix comes from the target's backend module.
;; NOTE: first/last pass names stay in sync with system.rkt's
;; start-pass/end-pass defaults.
;; ---------------------------------------------------------------------

(define frontend-passes
  (list
   `(,desugar                "desugar"                ,puffin-program?               ,core-program?                 ,interpret-puffin)
   `(,shrink                 "shrink"                 ,core-program?                 ,shrunk-program?               ,interpret-puffin)
   `(,uniqueify              "uniqueify"              ,shrunk-program?               ,unique-source-tree?           ,interpret-puffin)
   `(,optimize                "optimize"               ,unique-source-tree?           ,unique-source-tree?           ,interpret-puffin)
   `(,collect-globals        "collect-globals"        ,unique-source-tree?           ,globals-program?              ,interpret-puffin)
   `(,reveal-functions       "reveal-functions"       ,globals-program?              ,revealed-functions-program?   ,interpret-puffin)
   `(,assignment-convert     "assignment-convert"     ,revealed-functions-program?   ,assignment-converted-program? ,interpret-puffin)
   `(,lift-lambdas           "lift-lambdas"           ,assignment-converted-program? ,closure-converted-program?    ,interpret-puffin)
   `(,limit-functions        "limit-functions"        ,closure-converted-program?    ,limited-arity-program?        ,interpret-puffin)
   `(,anf-convert            "anf-convert"            ,limited-arity-program?        ,anf-program?                  ,interpret-puffin)
   `(,explicate-control      "explicate-control"      ,anf-program?                  ,blocks-program?               ,interpret-blocks)
   `(,uncover-locals         "uncover-locals"         ,blocks-program?               ,locals-program?               ,interpret-blocks)))

(define (backend-passes)
  (match (target)
    ['x86-64
     (list
      `(,select-instructions-x86     "select-instructions"    ,locals-program?         ,instr-program?           ,dummy-interp)
      `(,allocate-registers-x86      "allocate-registers"     ,instr-program?          ,homes-assigned-program?  ,dummy-interp)
      `(,patch-instructions-x86      "patch-instructions"     ,homes-assigned-program? ,patched-program-x86?     ,dummy-interp)
      `(,prelude-and-conclusion-x86  "prelude-and-conclusion" ,patched-program-x86?    ,homes-assigned-program?  ,dummy-interp)
      `(,render-x86                  "render-asm"             ,homes-assigned-program? ,string?                  ,dummy-interp))]
    ['arm64
     (define b (dynamic-require (build-path src-dir "backend-arm64.rkt")
                                'arm64-backend-passes
                                (λ () #f)))
     (if b
         (b)
         (error 'backend "the arm64 backend is not available; use --target x86-64"))]
    ['bytecode
     (define b (dynamic-require (build-path src-dir "backend-bytecode.rkt")
                                'bytecode-backend-passes
                                (λ () #f)))
     (if b
         (b)
         (error 'backend "the bytecode backend is not available"))]))

(define (all-passes) (append frontend-passes (backend-passes)))

;; Make each column available
(define (passes)            (map first (all-passes)))
(define (pass-names)        (map second (all-passes)))
(define (input-predicates)  (map third (all-passes)))
(define (output-predicates) (map fourth (all-passes)))
(define (interpreters)      (map fifth (all-passes)))

;;
;; Testing / debugging facilities
;;

;; Run a single compiler pass, with an input satisfying some input
;; predicate and an output satisfying some output predicate. Return
;; the value of `(pass input)`.
(define (run-pass-expect pass pass-name input input-pred output-pred [interp (lambda (x _) x)] [input-stream #f])
  ;; Run the pass
  (define output (with-handlers ([exn:fail? (λ (e) `(error ,(exn-message e)))])
                   (pass input)))
  ;; Compile-only fast path (retain-trace? #f): no pretty-printing,
  ;; no predicates, no per-pass interpretation, no input retention --
  ;; those made the working set ~17 full IRs plus a pretty-printed
  ;; string of each (tens of GB on puffincc-sized programs).
  (cond
    [(not (retain-trace?))
     (if (and (pair? output) (eq? (car output) 'error))
         (hash 'pass-name pass-name 'output output 'error (cadr output))
         (hash 'pass-name pass-name 'output output))]
    [else
     ;; Build an object of metadata
     (define h (hash 'input input
                     'orig-input input
                     'pass-name pass-name
                     'satisfies-input-predicate (input-pred input)
                     'satisfies-output-predicate (output-pred output)
                     'pretty-output (if (string? output) output (pretty-format output))
                     'output output))
     ;; Run the interpreter--the identity interpreter (discards input) is
     ;; used as a default parameter if none is provided
     (match
         ;; see system.rkt
         (with-handlers ([exn:fail? (λ (e) `(error ,(exn-message e)))])
           (run/capture (λ () (interp (hash-ref h 'output) input-stream))))
       [`(error ,e) (hash-set h 'interp (format "!!! Evaluation error !!!: ~a" e))]
       [(cons v stdout)
        (hash-set (hash-set h 'interp v) 'stdout stdout)])]))

;; Write a pass output to stdout
(define (pass-output->stdout h)
  (if (hash-has-key? h 'error)
      (begin
        (displayln "!!! This pass crashed!!! !!!")
        (displayln (hash-ref h 'error)))
      (begin
        (displayln (format "Running pass ~a." (hash-ref h 'pass-name)))
        (when (hash-ref h 'golden-input #f)
          (displayln (format "Golden input:\n~a" (hash-ref h 'golden-input))))
        (displayln "Input:")
        (pretty-print (hash-ref h 'input))
        (displayln (format "Satisfies input predicate: ~a" (yesno (hash-ref h 'satisfies-input-predicate))))
        (displayln "Output:")
        (displayln (hash-ref h 'pretty-output))
        (displayln (format "Satisfies output predicate: ~a" (yesno (hash-ref h 'satisfies-output-predicate))))
        (displayln "Evaluation of your output:")
        (displayln (hash-ref h 'interp "<none>")))))

;; Write a whole trace to stdout
(define (trace->stdout trace)
  (define (print-summary trace)
    (displayln "\nSummary of passes run:\n")
    (for ([elt trace])
      (define evals-to
        ;; Lookup the interpretation
        (match (hash-ref elt 'interp 'none)
          ['none         "<Not run>"]
          [(? string?)   "<string>"]
          [x     x]))
      (define maybe-stdout
        (match (hash-ref elt 'stdout "")
          ["" ""]
          [(? list? x) (format "stdout: \"~a\"" (string-trim (first x)))]
          [x  (format "stdout: \"~a\"" (string-trim x))]))
      (if (hash-has-key? elt 'error)
          (displayln (format "~a: !!! This pass crashed !!! "
                             (~a (hash-ref elt 'pass-name) #:align 'left  #:width 30)))
          (displayln (format "~a: Input (~a) Output (~a) Evaluation~a: ~a ~a"
                             (~a (hash-ref elt 'pass-name) #:align 'left  #:width 30)
                             (yesno (hash-ref elt 'satisfies-input-predicate))
                             (yesno (hash-ref elt 'satisfies-output-predicate))
                             (if (hash-has-key? elt 'error) " (Error!)" "")
                             evals-to
                             maybe-stdout))))
    (define all-stdouts (map (λ (x) (hash-ref x 'stdout))
                             (filter (λ (e) (and (hash-has-key? e 'stdout)
                                                 (not (equal? "" (hash-ref e 'stdout)))))
                                     trace)))
    (define consistent-across-passes?
      (or (null? all-stdouts)
          (andmap (λ (x) (equal? x (car all-stdouts))) (cdr all-stdouts))))
    (displayln (format "Consistent across passes? ~a" (yesno consistent-across-passes?))))
  (for/list ([elt trace])
    (when (verbose-mode)
      (pass-output->stdout elt)))
  (print-summary trace))

;; Walk over a trace and write each pass to a file tree
(define (trace->file-tree trace)
  (for ([trace-element trace])
    (define extension (hash-ref trace-element 'pass-name))
    (with-output-to-file (format "intermediate-outputs/compilation~a" extension)
      (λ () (pretty-print (hash-ref trace-element 'output)))
      #:exists 'replace)))

;; This function `run-chain` is a very general iterator function which
;; walks over a list of passes, while simultaneously (a) checking
;; input/output predicates for each pass, (b) checking consistency
;; with "golden" inputs and outputs.
(define (run-chain source-tree passes pass-names input-predicates output-predicates interps input-stream)
  (let loop ([passes      passes]
             [names       pass-names]
             [in-preds    input-predicates]
             [out-preds   output-predicates]
             [input       source-tree]
             [interps     interps]
             [trace       '()])
    (if (null? passes)
        (reverse trace)
        (let* ([pass       (car passes)]
               [pass-name  (car names)]
               [in-pred    (car in-preds)]
               [out-pred   (car out-preds)]
               [interp     (car interps)]
               [h          (run-pass-expect pass pass-name input
                                            in-pred out-pred interp input-stream)]
               [trace      (if (retain-trace?) trace '())])
          (if (hash-has-key? h 'error)
              (reverse (cons h trace))
              (loop (cdr passes) (cdr names) (cdr in-preds) (cdr out-preds)
                    (hash-ref h 'output) (cdr interps) (cons h trace)))))))

;; Run each of the passes in sequence, building a chain of passes
(define (compile-verbose source-tree)
  ;; return either #f (error) or a cons cell (range)
  (define (get-pass-range start-name end-name)
    (define start-idx (index-of (pass-names) start-name string=?))
    (define end-idx   (index-of (pass-names) end-name   string=?))
    (and start-idx end-idx (<= start-idx end-idx) (cons start-idx end-idx)))
  (define (slice-list lst range)
    (match-define (cons start end) range)
    (take (drop lst start) (add1 (- end start))))
  (define our-range (get-pass-range (start-pass) (end-pass)))
  (unless our-range ;; #f is invalid
    (error (format "Bad start/end pass range name (chose from {~a})" (string-join (pass-names) " "))))
  (define our-input-stream
    (if (input-file)
        (map string->number (file->lines (input-file)))
        (range 100)))
  (define interp-functions (slice-list (interpreters) our-range))
  (define interpreters-to-use
    (if (write-stdout-mode)
        interp-functions
        (map (λ (_) (λ (p in) "skipping interpretation...")) (range (length interp-functions)))))
  (let ([trace (run-chain source-tree
                          (slice-list (passes) our-range)
                          (slice-list (pass-names) our-range)
                          (slice-list (input-predicates) our-range)
                          (slice-list (output-predicates) our-range)
                          interpreters-to-use
                          our-input-stream)])
    (when (write-stdout-mode)
      (trace->stdout trace))
    trace))

;;
;; Code to compile / link on the host machine
;;

(define (target-triple)
  (match* ((host-os) (target))
    [('macosx 'arm64)   "arm64-apple-darwin"]
    [('macosx 'x86-64)  "x86_64-apple-darwin"]
    [('unix   'x86-64)  "x86_64-pc-linux-gnu"]
    [(_       _)        ""]))

(define (flag-list->string flags)
  (string-join (filter (λ (s) (not (string=? s ""))) flags) " "))

;; The runtime archive: build it (cheap no-op when fresh) and return
;; its path.
(define (runtime-archive)
  (define dir (build-path src-dir "runtime"))
  (define archive (build-path dir "libpuffin.a"))
  (execute-get-output (format "make -C ~a" (path->string dir)))
  (unless (file-exists? archive)
    (error 'runtime "could not build ~a" archive))
  (path->string archive))

;; Generate a binary (delete any stale executable first, then verify
;; its creation). Returns either the trace or `(err ,trace).
;;
;; Target 'bytecode short-circuits the toolchain half: the last pass
;; (render-pbc) already produced the unit's bytes, which ARE the
;; output artifact (a .pbc file the VM loads); there is nothing to
;; assemble or link.
(define (run-assembler-linker source-tree)
  (if (eq? (target) 'bytecode)
      (run-bytecode-renderer source-tree)
      (run-native-assembler-linker source-tree)))

(define (run-bytecode-renderer source-tree)
  (define trace
    (parameterize ([end-pass (if (equal? (end-pass) "render-asm") "render-pbc" (end-pass))])
      (compile-verbose source-tree)))
  (cond
    [(and (equal? "render-pbc" (hash-ref (last trace) 'pass-name "unknown"))
          (bytes? (hash-ref (last trace) 'output)))
     (with-output-to-file (executable-file) #:exists 'replace
       (λ () (write-bytes (hash-ref (last trace) 'output))))
     trace]
    [else
     (displayln "Error! Bytecode rendering failed")
     `(err ,trace)]))

(define (run-native-assembler-linker source-tree)
  (displayln (format "Compiling for target ~a ..." (target)))
  ;; delete the ASM file so we can detect if it got generated
  (when (file-exists? (asm-file)) (delete-file (asm-file)))
  (define trace (compile-verbose source-tree))
  ;; last pass generated output
  (if (and (equal? (last (pass-names)) (hash-ref (last trace) 'pass-name  "unknown"))
           ((last (output-predicates)) (hash-ref (last trace) 'output)))
      ((λ ()
         (define asm-text (hash-ref (last trace) 'output))
         (with-output-to-file (asm-file) #:exists 'replace
           (λ () (displayln asm-text)))
         (define tgt  (target-triple))
         (define cc   (or (getenv "CC") "/usr/bin/clang"))
         (define target-flag      (if (string=? tgt "") "" (format "-target ~a" tgt)))
         (define common-cc-flags  "-Wall -O2")
         ;; deep non-tail recursion (a 1M-element map) needs more than
         ;; the default 8MB stack; reserve 1GB of address space (only
         ;; touched pages are committed)
         (define stack-flag (if (eq? (host-os) 'macosx) "-Wl,-stack_size,0x20000000" ""))
         (define linux-extra (if (eq? (host-os) 'unix) "-no-pie" ""))
         (displayln (format "-> Host: ~a/~a  Target: ~a  Entry: ~a"
                            (host-os) (host-arch) (target) (entry-symbol)))
         (define assemble-cmd
           (string-append cc " "
                          (flag-list->string (list target-flag common-cc-flags))
                          " -c " (asm-file) " -o " (object-file)))
         (define link-cmd
           (string-append cc " "
                          (flag-list->string
                           (list target-flag common-cc-flags linux-extra stack-flag))
                          " " (object-file) " " (runtime-archive)
                          " -o " (executable-file)))
         (with-handlers ([exn:fail? (λ (e) (void))]) (delete-file (executable-file)))
         ;; show any assembler/linker diagnostics (don't swallow them)
         (for ([cmd (list assemble-cmd link-cmd)])
           (define out (execute-get-output cmd))
           (unless (string=? (string-trim out) "")
             (displayln out)))
         (if (file-exists? (executable-file))
             (begin
               (displayln (format "Success! Executable produced at: ~a" (executable-file)))
               trace)
             (begin
               (displayln (format "Error! Assembler/linker failed: ~a not produced" (executable-file)))
               `(err ,trace)))))
      (begin
        (displayln "Skipping assembly/linking (either no assembly or intentionally skipped)...")
        `(err ,trace))))

;; ---------------------------------------------------------------------
;; Reading programs: a Puffin file is either a single (program ...)
;; form (class style) or a bare sequence of top-level forms (day-to-
;; day style), which we wrap.
;; ---------------------------------------------------------------------

(define (read-forms file-name)
  (with-input-from-file file-name
    (λ ()
      (let loop ([acc '()])
        (define f (read))
        (if (eof-object? f) (reverse acc) (loop (cons f acc)))))))

;; forms plus each top-level form's line (for diagnostics; the module
;; path reads its own files via modules.rkt read-module-forms+lines)
(define (read-forms+lines file-name)
  (with-input-from-file file-name
    (λ ()
      (port-count-lines! (current-input-port))
      (let loop ([forms '()] [lines '()])
        (define stx (read-syntax file-name (current-input-port)))
        (if (eof-object? stx)
            (values (reverse forms) (reverse lines))
            (loop (cons (syntax->datum stx) forms)
                  (cons (syntax-line stx) lines)))))))

;; The Puffin-written stdlib layer (map/filter/append/...): injected
;; into every program, minus any definition the program supplies
;; itself (class programs with their own `length` are untouched),
;; pruned to the definitions the program transitively mentions --
;; prelude functions are pure, so unreferenced ones can't matter,
;; and pruning keeps binaries and pipeline traces lean.
(define (prelude-forms user-forms)
  ;; a define's name, dotted (variadic) formals included
  (define (defn-name f)
    (match f
      [`(define (,g ,_ ...) ,_ ...) g]
      [`(define (,g . ,_) ,_ ...) g]
      [`(define ,(? symbol? x) ,_) x]
      [_ #f]))   ;; (: name t) declarations and other non-defines
  (define user-names
    (list->set
     (filter-map (λ (f) (match f
                          [`(define ,_ ,_ ...) (defn-name f)]
                          [_ #f]))
                 user-forms)))
  (define candidates
    (filter (λ (f) (not (set-member? user-names (defn-name f))))
            (read-forms (build-path src-dir "prelude.puf"))))
  ;; conservative name-based reachability: any symbol occurring
  ;; anywhere counts as a mention
  (define (mentions form)
    (let walk ([v form] [acc (set)])
      (cond [(symbol? v) (set-add acc v)]
            [(pair? v) (walk (cdr v) (walk (car v) acc))]
            [else acc])))
  (define by-name (for/hash ([f candidates]) (values (defn-name f) f)))
  (define user-mentions
    (foldl (λ (f acc) (set-union acc (mentions f))) (set) user-forms))
  ;; desugared forms reach for helpers the raw text doesn't name:
  ;; unquote-splicing expands into calls to `append`
  (define seeded
    (if (set-member? user-mentions 'unquote-splicing)
        (set-add user-mentions 'append)
        user-mentions))
  (let grow ([needed seeded]
             [included (set)])
    (define new-names
      (filter (λ (n) (and (hash-has-key? by-name n) (not (set-member? included n))))
              (set->list needed)))
    (if (null? new-names)
        ;; a (#%prelude: name t) signature travels with its function
        (filter (λ (f)
                  (match f
                    [`(,(or ': '#%prelude:) ,n ,_) (set-member? included n)]
                    [_ (set-member? included (defn-name f))]))
                candidates)
        (grow (foldl (λ (n acc) (set-union acc (mentions (hash-ref by-name n))))
                     needed new-names)
              (foldl (λ (n acc) (set-add acc n)) included new-names)))))

(define (read-program-file file-name)
  (define-values (raw raw-lines) (read-forms+lines file-name))
  (define base (path->string (file-name-from-path (path->complete-path file-name))))
  (define-values (forms origins)
    (cond
      ;; module system (docs/MODULES.md): any require/provide form
      ;; makes this file the entry module of a require DAG, resolved
      ;; to a flat form list before the pipeline sees it; the resolver
      ;; stashes the flattened (basename . line) origins on the side
      [(module-forms? raw)
       (define fs (resolve-modules file-name))
       (values fs (resolved-origins))]
      [else (match raw
              ;; class-style wrapper: no positions
              [`((program ,inner ...)) (values inner (map (λ (_) #f) inner))]
              [fs (values fs (map (λ (l) (and l (cons base l))) raw-lines))])]))
  ;; REPL units get no prelude: the session loads the prelude once as
  ;; its own REPL unit, and every prelude name late-binds by cell
  ;; (docs/WASM-VM.md §5.2), so user redefinition shadows it. REPL
  ;; evals also carry no positions (docs: diagnostics say [file:line]
  ;; for file programs only).
  (cond
    [(repl-mode?)
     (surface-origins #f)
     `(program ,@forms)]
    [else
     (define pre (prelude-forms forms))
     ;; the prelude's forms carry no positions (puffincc's prelude is
     ;; embedded pre-parsed data -- neither compiler positions it)
     (surface-origins (append (map (λ (_) #f) pre) origins))
     `(program ,@pre ,@forms)]))

;;
;; Main entrypoint
;;

(define (main)
  (define file-name
    (command-line
     #:once-each
     [("-s" "--start-pass") pass "Start at pass <pass>"
                            (start-pass pass)]
     [("-e" "--end-pass") pass "End at pass <pass>"
                          (end-pass pass)]
     [("-f" "--fast") "Skip interpretation / dumping, just compile (implies --lean)"
                      (write-stdout-mode #f)
                      (retain-trace? #f)]
     [("--lean") "Keep no pass history: one IR in memory at a time (the low-memory mode; compile-only CLIs default to it)"
                 (retain-trace? #f)]
     [("-t" "--target") tgt "Target architecture: x86-64 or arm64"
                        (target (string->symbol tgt))]
     [("-O" "--optimize") lvl "Optimization level: 0, 1 (default), 2"
                          (optimize-level (string->number lvl))]
     [("--repl") "Compile one REPL eval's forms as a link-by-name unit (implies -t bytecode -O 0, no prelude; docs/WASM-VM.md §4)"
                 (repl-mode? #t)
                 (target 'bytecode)
                 (optimize-level 0)
                 (write-stdout-mode #f)
                 (retain-trace? #f)]
     [("-o" "--output") out "Executable output path"
                        (executable-file out)]
     #:args leftover
     (match leftover
       ['()        (error 'main "expected a <filename>")]
       [(list f)   f]
       [_          (error 'main "expected at most one <filename>")])))
  (define source-tree (read-program-file file-name))
  (match (run-assembler-linker source-tree)
    [`(err ,trace)
     (displayln "!!! ERROR CAUGHT !!!")
     (trace->stdout trace)]
    ;; all good
    [_ (void)]))

;; Parse the command line
(module+ main
  (main))
