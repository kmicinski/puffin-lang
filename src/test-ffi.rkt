#lang racket
;; The FFI contract (docs/FFI.md §8.4): every §4 marshaling row and
;; every §5 blame/load error, EXACT-TEXT, on every route that can
;; produce it — reference interp, reference native (host target,
;; plus x86-64 under Rosetta on a mac), reference bytecode + VM,
;; puffincc native, and puffincc bytecode + VM. The wasm refusal leg
;; lives in web/test-vm-compile.mjs (the wasm VM runs under node).
;;
;;   racket src/test-ffi.rkt          (from the repo root)
;;
;; Builds tests/ffi-demo/cdemo first (clang, fat arm64+x86_64).
;; Mirrors test-arith.rkt's 4-route exact-text shape.

(define here (path-only (path->complete-path (find-system-path 'run-file))))
(define repo-root (simplify-path (build-path here 'up)))
(current-directory repo-root)   ;; relative lib paths resolve here

(unless (system "make -C tests/ffi-demo >/dev/null")
  (error 'test-ffi "could not build tests/ffi-demo (clang needed)"))

(define puffincc (and (file-exists? "build/puffincc") "build/puffincc"))
(define on-mac? (equal? (system-type 'os) 'macosx))

(define failures 0)
(define checks 0)
(define (fail! route file what expected got)
  (set! failures (add1 failures))
  (printf "FAIL [~a] ~a (~a)\n  expected: ~a\n  got:      ~a\n"
          route file what expected got))

(define (run/capture cmd . args)
  ;; -> (values stdout stderr)
  (define-values (proc out in err) (apply subprocess #f #f #f cmd args))
  (close-output-port in)
  (define out-t (port->string out))
  (define err-t (port->string err))
  (subprocess-wait proc)
  (values out-t err-t))

(define (trim s) (string-trim s))

;; ---------------------------------------------------------------------
;; success cases: exact stdout on every route
;; ---------------------------------------------------------------------

(define ok-cases
  ;; (file expected-stdout-lines)
  (list
   (list "tests/ffi-demo/cdemo/basics.puf"
         '("42" "16" "hello kris" "#t" "#f" "in a haystack" "nothing"))
   (list "tests/ffi-demo/cdemo/widths.puf" '("42" "44" "-10"))
   (list "tests/ffi-demo/cdemo/pack6.puf" '("21"))
   (list "tests/ffi-demo/cdemo/handles.puf"
         '("10" "11" "#t" "#f" "#f" "#f" "#f" "7" "no"
           "#<CBox closed>" "#<CBox closed>"))
   (list "tests/ffi-demo/cdemo/eta.puf" '("#t" "(#f #t #f #t)" "6"))
   (list "tests/ffi-demo/cdemo/mod/main.puf"
         '("100" "42" "101" "#<CBox closed>"))))

;; ---------------------------------------------------------------------
;; runtime error cases: stderr contains the exact blame line
;; ---------------------------------------------------------------------

(define err-cases
  (list
   (list "tests/ffi-demo/cdemo/err-arg.puf"
         "puffin runtime error: cast: expected Int, got #t (blame: foreign cdemo-add's argument 2 [err-arg.puf:2])")
   (list "tests/ffi-demo/cdemo/err-big.puf"
         "puffin runtime error: cast: expected Int (61-bit), got 9223372036854775807 (blame: foreign cdemo-big's result [err-big.puf:2])")
   (list "tests/ffi-demo/cdemo/err-null-str.puf"
         "puffin runtime error: foreign cdemo-null-str: result is NULL (blame: foreign cdemo-null-str's result [err-null-str.puf:2])")
   (list "tests/ffi-demo/cdemo/err-null-handle.puf"
         "puffin runtime error: foreign box-null: result is NULL (blame: foreign box-null's result [err-null-handle.puf:3])")
   (list "tests/ffi-demo/cdemo/err-closed.puf"
         "puffin runtime error: foreign box-next: CBox handle is closed (blame: foreign box-next's argument 1 [err-closed.puf:3])")
   (list "tests/ffi-demo/cdemo/err-dblclose.puf"
         "puffin runtime error: foreign box-close: CBox handle is closed (blame: foreign box-close's argument 1 [err-dblclose.puf:3])")
   ;; the handle's address is nondeterministic: match up to it
   (list "tests/ffi-demo/cdemo/err-brand.puf"
         "puffin runtime error: cast: expected Other, got #<CBox 0x")
   (list "tests/ffi-demo/cdemo/err-width-arg.puf"
         "puffin runtime error: cast: expected I8, got 300 (blame: foreign cdemo-double8's argument 1 [err-width-arg.puf:2])")
   (list "tests/ffi-demo/cdemo/err-nul.puf"
         "puffin runtime error: foreign cdemo-strlen: argument 1 contains an embedded NUL (blame: foreign cdemo-strlen's argument 1 [err-nul.puf:2])")
   (list "tests/ffi-demo/cdemo/err-nosym.puf"
         "puffin runtime error: foreign cdemo-missing: symbol cdemo_missing not found in ./libpfcdemo.dylib")
   (list "tests/ffi-demo/cdemo/err-nolib.puf"
         "puffin runtime error: foreign library ./no-such-dir/libnope.dylib: cannot load")
   ;; the leak-detector backstop (§6.2/§13 Q4): stderr warning, exit 0
   (list "tests/ffi-demo/cdemo/leak.puf"
         "puffin ffi warning: 1 foreign handle left open at exit: #<CBox>")))

;; ---------------------------------------------------------------------
;; compile-time rejections (§5.1 negative matrix): byte-identical on
;; both compilers. The reference errors to stderr; puffincc's pf_error
;; prints to stdout (golden-parity design) — compare accordingly.
;; ---------------------------------------------------------------------

(define reject-cases
  ;; (source expected-message)
  (list
   (list "(foreign \"libx.dylib\" (: f Int #:c-name \"f\"))"
         "typecheck: foreign f: declared type must be a concrete (-> ...) arrow, got Int")
   (list "(foreign \"libx.dylib\" (: f (-> (List Int) Int) #:c-name \"f\"))"
         "typecheck: foreign f: argument type (List Int) is not marshallable")
   (list "(foreign \"libx.dylib\" (: f (-> Int (Vec Int)) #:c-name \"f\"))"
         "typecheck: foreign f: result type (Vec Int) is not marshallable")
   (list "(foreign \"libx.dylib\" (: f (-> _ Int) #:c-name \"f\"))"
         "typecheck: foreign f: argument type _ is not marshallable")
   (list "(foreign \"libx.dylib\" (: f (-> Int Int Int Int Int Int Int Int) #:c-name \"f\"))"
         "typecheck: foreign f: arity 7 exceeds the FFI limit of 6")
   (list "(foreign \"libx.dylib\" (: poke! (-> Int Int)))"
         "typecheck: foreign poke!: needs #:c-name (the name has no default C spelling)")
   (list "(foreign \"libx.dylib\" (: f (-> Int Int) #:c-name \"f\" #:gift \"g\"))"
         "typecheck: foreign f: #:gift requires a Str or (Nullable Str) result")
   (list "(foreign \"libx.dylib\" (: f (-> Int Void) #:c-name \"f\" #:consumes))"
         "typecheck: foreign f: #:consumes requires exactly one foreign-handle argument")
   (list "(foreign \"libx.dylib\" (: f (-> Regex Int) #:c-name \"f\"))"
         "typecheck: foreign f: argument type Regex is not marshallable")
   (list "(define-foreign-type Int)"
         "typecheck: define-foreign-type cannot redefine built-in type Int")
   (list "(define-foreign-type R) (define-type R (MkR))"
         "typecheck: type R defined twice")
   (list "(define f 1) (foreign \"libx.dylib\" (: f (-> Int Int) #:c-name \"f\"))"
         "typecheck: foreign f: duplicate declaration")))

;; ---------------------------------------------------------------------
;; the runner
;; ---------------------------------------------------------------------

(define tmp (find-system-path 'temp-dir))

(define (compile-ref file exe target)
  (run/capture "bin/puffin" "-c" "-t" target "-o" exe file))
(define (compile-ref-pbc file pbc)
  (run/capture "bin/puffin" "-c" "-t" "bytecode" "-o" pbc file))
(define (compile-pcc file exe)
  (run/capture puffincc file "-o" exe))
(define (compile-pcc-pbc file pbc)
  (run/capture puffincc file "-t" "bytecode" "-o" pbc))

;; routes: name + (file -> (values stdout stderr))
(define (route-runners file tag)
  (define exe (path->string (build-path tmp (format "ffi-~a-~a" tag (current-milliseconds)))))
  (append
   (list (list "interp" (λ () (run/capture "bin/puffin" "-i" file))))
   (list (list "native"
               (λ () (compile-ref file exe "arm64") (run/capture exe))))
   (if on-mac?
       (list (list "x86-64"
                   (λ () (compile-ref file (string-append exe "-x86") "x86-64")
                       (run/capture (string-append exe "-x86")))))
       '())
   (list (list "vm"
               (λ () (compile-ref-pbc file (string-append exe ".pbc"))
                   (run/capture "bin/puffin-vm" (string-append exe ".pbc")))))
   (if puffincc
       (list (list "pcc-native"
                   (λ () (compile-pcc file (string-append exe "-pcc"))
                       (run/capture (string-append exe "-pcc"))))
             (list "pcc-vm"
                   (λ () (compile-pcc-pbc file (string-append exe "-pcc.pbc"))
                       (run/capture "bin/puffin-vm" (string-append exe "-pcc.pbc")))))
       '())))

(for ([c ok-cases])
  (match-define (list file expected-lines) c)
  (define expected (string-join expected-lines "\n"))
  (for ([r (route-runners file "ok")])
    (match-define (list name thunk) r)
    (set! checks (add1 checks))
    (define-values (out err) (thunk))
    (unless (equal? (trim out) expected)
      (fail! name file "stdout" expected (trim out)))))

(for ([c err-cases])
  (match-define (list file expected) c)
  (for ([r (route-runners file "err")])
    (match-define (list name thunk) r)
    (set! checks (add1 checks))
    (define-values (out err) (thunk))
    (unless (string-contains? err expected)
      (fail! name file "stderr" expected (trim err)))))

;; compile-time rejects: both compilers, byte-identical message
(for ([c reject-cases] [i (in-naturals)])
  (match-define (list src expected) c)
  (define f (build-path tmp (format "ffi-reject-~a.puf" i)))
  (call-with-output-file f #:exists 'replace (λ (p) (displayln src p)))
  (set! checks (add1 checks))
  (define-values (o1 e1) (run/capture "bin/puffin" "-i" (path->string f)))
  ;; the reference CLI surfaces the typecheck error on stderr (via -i)
  (unless (or (string-contains? e1 expected) (string-contains? o1 expected))
    (fail! "ref-typecheck" src "message" expected (trim (string-append o1 e1))))
  (when puffincc
    (set! checks (add1 checks))
    (define-values (o2 e2) (run/capture puffincc (path->string f) "-o" "/dev/null"))
    (unless (or (string-contains? o2 expected) (string-contains? e2 expected))
      (fail! "pcc-typecheck" src "message" expected (trim (string-append o2 e2))))))

;; ---------------------------------------------------------------------
;; phase 4: the #:include clang cross-check (docs/FFI.md §9.3) and
;; the #:static seam stub -- both compilers.
;; ---------------------------------------------------------------------

;; include-ok compiles + runs (the header agrees)
(set! checks (add1 checks))
(let-values ([(o e) (run/capture "bin/puffin" "-i" "tests/ffi-demo/cdemo/include-ok.puf")])
  (unless (equal? (trim o) "42")
    (fail! "interp" "include-ok.puf" "stdout" "42" (trim (string-append o e)))))
(when puffincc
  (set! checks (add1 checks))
  (let-values ([(o e) (run/capture puffincc "tests/ffi-demo/cdemo/include-ok.puf"
                                   "-t" "bytecode" "-o" "/tmp/ffi-inc.pbc")])
    (define-values (o2 e2) (run/capture "bin/puffin-vm" "/tmp/ffi-inc.pbc"))
    (unless (equal? (trim o2) "42")
      (fail! "pcc-vm" "include-ok.puf" "stdout" "42" (trim (string-append o2 e2))))))
;; include-bad: a lying declaration dies at compile time, same line
(define inc-bad-expected "foreign: header cross-check failed for ./libpfcdemo.dylib against tests/ffi-demo/cdemo/cdemo.h")
(set! checks (add1 checks))
(let-values ([(o e) (run/capture "bin/puffin" "-i" "tests/ffi-demo/cdemo/include-bad.puf")])
  (unless (string-contains? (string-append o e) inc-bad-expected)
    (fail! "ref" "include-bad.puf" "message" inc-bad-expected (trim (string-append o e)))))
(when puffincc
  (set! checks (add1 checks))
  (let-values ([(o e) (run/capture puffincc "tests/ffi-demo/cdemo/include-bad.puf" "-o" "/dev/null")])
    (unless (string-contains? (string-append o e) inc-bad-expected)
      (fail! "pcc" "include-bad.puf" "message" inc-bad-expected (trim (string-append o e))))))
;; #:static: the designed seam errors identically on both compilers
(define static-expected "foreign libx.dylib: #:static linking is a designed seam, not yet implemented (docs/FFI.md §10)")
(define static-f (build-path tmp "ffi-static.puf"))
(call-with-output-file static-f #:exists 'replace
  (λ (p) (displayln "(foreign \"libx.dylib\" #:static (: f (-> Int) #:c-name \"f\"))" p)))
(set! checks (add1 checks))
(let-values ([(o e) (run/capture "bin/puffin" "-i" (path->string static-f))])
  (unless (string-contains? (string-append o e) static-expected)
    (fail! "ref" "static stub" "message" static-expected (trim (string-append o e)))))
(when puffincc
  (set! checks (add1 checks))
  (let-values ([(o e) (run/capture puffincc (path->string static-f) "-o" "/dev/null")])
    (unless (string-contains? (string-append o e) static-expected)
      (fail! "pcc" "static stub" "message" static-expected (trim (string-append o e))))))

;; ---------------------------------------------------------------------
;; phase 3 (docs/FFI.md §12): the Rust guest end-to-end + typed
;; .pufs/.pufi interplay. Gated on cargo having built the crate.
;; ---------------------------------------------------------------------

(define pfregex-lib "tests/ffi-demo/pfregex/target/release/libpfregex.dylib")
(when (not (file-exists? pfregex-lib))
  (void (system "make -C tests/ffi-demo pfregex >/dev/null 2>&1")))

(cond
  [(file-exists? pfregex-lib)
   (define pfregex-expected
     (string-join '("compiled" "#t" "#f" "pufffin" "3" "rejected" "3" "#<Regex closed>") "\n"))
   ;; the Rust library is arm64-only (cargo's host target): skip the
   ;; x86-64 leg for these
   (for ([r (route-runners "tests/ffi-demo/pfregex/puf/main.puf" "pfregex")])
     (match-define (list name thunk) r)
     (unless (equal? name "x86-64")
       (set! checks (add1 checks))
       (define-values (out err) (thunk))
       (unless (equal? (trim out) pfregex-expected)
         (fail! name "pfregex/main.puf" "stdout" pfregex-expected (trim out)))))
   ;; typed .pufs ascription over the FFI face, both compilers
   (set! checks (add1 checks))
   (define-values (so se) (run/capture "bin/puffin" "-i" "tests/ffi-demo/pfregex/puf/sig-main.puf"))
   (unless (equal? (trim so) "#t")
     (fail! "interp" "pfregex/sig-main.puf" "stdout" "#t" (trim so)))
   (when puffincc
     (set! checks (add1 checks))
     (define-values (o2 e2) (run/capture puffincc "tests/ffi-demo/pfregex/puf/sig-main.puf"
                                         "-t" "bytecode" "-o" "/tmp/ffi-sig-pcc.pbc"))
     (define-values (o3 e3) (run/capture "bin/puffin-vm" "/tmp/ffi-sig-pcc.pbc"))
     (unless (equal? (trim o3) "#t")
       (fail! "pcc-vm" "pfregex/sig-main.puf" "stdout" "#t" (trim o3))))
   ;; a WRONG stated type is rejected with the same message on both
   (define sig-reject "signature fun regex-match? states type (-> Int Str Bool), module declares (-> Regex Str Bool)")
   (set! checks (add1 checks))
   (define-values (bo be) (run/capture "bin/puffin" "-i" "tests/ffi-demo/pfregex/puf/badsig-main.puf"))
   (unless (string-contains? (string-append bo be) sig-reject)
     (fail! "ref-sig" "pfregex/badsig-main.puf" "message" sig-reject (trim (string-append bo be))))
   (when puffincc
     (set! checks (add1 checks))
     (define-values (po pe) (run/capture puffincc "tests/ffi-demo/pfregex/puf/badsig-main.puf" "-o" "/dev/null"))
     (unless (string-contains? (string-append po pe) sig-reject)
       (fail! "pcc-sig" "pfregex/badsig-main.puf" "message" sig-reject (trim (string-append po pe)))))
   ;; SEPARATE compilation (Racket-side; docs/MODULES.md §3): the FFI
   ;; face compiles to .o + typed .pufi; the client links against it,
   ;; runs identically, and a typed misuse is rejected cross-unit
   (define sep-dir (build-path tmp (format "ffi-sep-~a" (current-milliseconds))))
   (make-directory* sep-dir)
   (parameterize ([current-directory (current-directory)])
     (void (system "rm -rf build-cache"))
     (set! checks (add1 checks))
     (define-values (co ce)
       (run/capture "bin/puffin" "-c" "--separate" "-o" "/tmp/ffi-sep-main"
                    "tests/ffi-demo/pfregex/puf/main.puf"))
     (define-values (ro re) (run/capture "/tmp/ffi-sep-main"))
     (unless (equal? (trim ro) pfregex-expected)
       (fail! "separate" "pfregex/main.puf" "stdout" pfregex-expected
              (trim (string-append ro "\n-- compile stderr: " ce))))
     ;; cross-unit typed misuse: the .pufi's recorded arrow rejects it
     (define misuse (build-path sep-dir "misuse.puf"))
     (call-with-output-file misuse #:exists 'replace
       (λ (p)
         (fprintf p "(require \"~a/tests/ffi-demo/pfregex/puf/regex.puf\")\n"
                  (path->string (current-directory)))
         (displayln "(println (regex-match? 7 \"hay\"))" p)))
     (set! checks (add1 checks))
     (define-values (mo me)
       (run/capture "bin/puffin" "-c" "--separate" "-o" "/tmp/ffi-sep-misuse"
                    (path->string misuse)))
     (define misuse-expected "typecheck: regex-match?: argument has type Int, expected Regex")
     (unless (string-contains? (string-append mo me) misuse-expected)
       (fail! "separate" "misuse.puf" "message" misuse-expected (trim (string-append mo me)))))]
  [else
   (printf "note: cargo/rustc unavailable or pfregex not built; skipped the Rust phase-3 legs\n")])

(unless puffincc
  (printf "note: build/puffincc not present; skipped the puffincc routes\n"))
(if (zero? failures)
    (printf "ffi tests: all passed (~a checks)\n" checks)
    (begin (printf "~a failures\n" failures) (exit 1)))
