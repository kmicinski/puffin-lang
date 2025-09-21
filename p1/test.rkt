#lang racket

(require racket/match
         racket/string
         racket/port
         racket/pretty
         racket/serialize
         json
         "main.rkt"
         "system.rkt"
         "irs.rkt"
         "interpreters.rkt")

;; ───── command-line parsing ─────
(define mode (make-parameter "native"))
(define in-files (make-parameter ""))
(define goldens (make-parameter ""))
(define tests-dir (make-parameter "./test-programs/"))
(define verbose-mode (make-parameter #f))
(define cfg-file (make-parameter #f))
(define repro-file (make-parameter "./repro.sh"))

(define prog-file
  (command-line
   #:once-each
   [("-m" "--mode") m "Run tests in mode <m>" (mode m)]
   [("-i" "--in")   input "Comma-separated list of input files <in>"
                    (in-files input)]
   [("-g" "--gld") files "Comma-separated list of golden (output) files"
                   (goldens files)]
   [("-v" "--verbose") "Verbose mode"
                       (verbose-mode #t)]
   [("-c" "--cfg") cfg "Specify an input cfg file <cfg> (for Autograder testing)"
                   (cfg-file cfg)]
   #:args rest-args (if (empty? rest-args) 'no-file (first rest-args))))

;; ───── mode → metadata ─────
(define modes
  (hash
   "frontend"    (list "uniqueify"           "anf-convert"        R1?              interpret-anf)
   "middleend"   (list "explicate-control"   "uncover-locals"     locals-program?  interpret-c0)
   "backend"     (list "select-instructions" "patch-instructions" patched-program? interpret-instr)
   "native"      (list "uniqueify"           "render-x86"         string?          dummy-interp-x86-64)))

(define (file->ints p)
  (map string->number (file->lines p)))

(define (run-native-test infile golden)
  (define (path->trimmed-string p) (file->string p))
  (define (read-input-list p)
    (map string->number
         (filter (λ (s) (not (string=? s "")))
                 (regexp-split #px"\\s+" (path->trimmed-string p)))))
  (define exe (executable-file))
  (displayln (format "Running test (input file ~a, golden file ~a)" infile golden))
  (unless (file-exists? exe) 
    (displayln "Error: attempting to run native test, but no executable present; failing test.")
    'failed)
  (define input-nums (read-input-list infile))
  (define-values (proc out-port in-port err-port)
    (subprocess #f #f #f exe))
  ;; send input to stdin and flush it
  (fprintf in-port "~a\n"
           (string-join (map number->string input-nums) " "))
  (close-output-port in-port)
  (define program-out (port->string out-port))
  (define golden-out  (path->trimmed-string golden))
  (define match? (string=? (string-trim program-out) (string-trim golden-out)))
  ;; ── pretty console report ─────────────────────────────────────────────
  (define report (format "\r\tInput: (~a, ...),  Your output: ~a,  Golden output: ~a Matches golden? ~a                         "
                         (string-join (map number->string (take input-nums 3)) ", ")
                         program-out
                         golden-out
                         (yesno match?)))
  (displayln report)
  (if match? 'passed 'failed))

;; Run a test with a specific mode, input file, input-paths
;; (comma-separated list), and goldens. 
;; -> {'passed, 'failed}
;; Note: the output printed by run-test is captured by
;; run/capture
(define (run-test mode prog-file input-paths goldens)
  (call/cc
   (lambda (return)
     (match mode
       ["native"
        (define program (with-input-from-file prog-file read))
        (displayln "Compiling...")
        (define output-string (open-output-string))
        (define trace
          (parameterize (;;[current-output-port output-string]
                         [start-pass (first  (hash-ref modes mode))]
                         [end-pass   (second (hash-ref modes mode))])
            (match (run-assembler-linker program)
              [`(err ,trace)
               ;;(displayln (get-output-string output-string))
               (return 'failed)]
              ;; succes
              [trace trace])))
        (unless (file-exists? (executable-file))
          (error (format "Executable ~a not found; did the build fail?" (executable-file))))
        (displayln (format "Executable ~a found, running native tests..." (executable-file)))
        (define all-passed? #t)
        (for ([infile (string-split input-paths ",")]
              [golden (string-split goldens ",")])
          ;; run the test
          (set! all-passed? (and all-passed? (equal? 'passed (run-native-test infile golden)))))
        (if all-passed? 'passed 'failed)]
       [_ ;; one of "frontend", "middleend" or "backend"
        (match-define (list start-pass-name end-pass-name entry-pred out-interp)
          (hash-ref modes mode #f))
        (define passed #t)
        ;; Compare each output to each golden
        (for ([in-file (string-split input-paths ",")]
              [golden (map file->string (string-split goldens ","))]
              [idx (in-naturals 1)])
          (displayln "Compiling...")
          (define ints (file->ints in-file))
          (define program (with-input-from-file prog-file (λ () (deserialize (read)))))
          (define output-string (open-output-string))
          (define trace
            (parameterize (;;[current-output-port output-string]
                           [start-pass (first  (hash-ref modes mode))]
                           [end-pass   (second (hash-ref modes mode))]
                           [input-file in-file])
              (compile-verbose program)))
          (match-define (cons val stdout)
            (run/capture (λ () (out-interp (hash-ref (last trace) 'output) ints))))
          (displayln (format "Test — input: ~a ..."
                             (string-join (map (λ (x) (format "~a" x)) (take ints 3))  ",")))
          (displayln (format "=> result: ~a stdout: ~a" val (pretty-format stdout)))
          (define matches? (equal? (string-trim stdout) (string-trim golden)))
          (set! passed (and passed matches?))
          (displayln (format "Test passes? ~a ~a"
                             (yesno matches?)
                             (if matches? "" (format "expected ~a" golden)))))
        (if passed 'passed 'failed)]))))

;; assume compile.rkt is correct
;; For each...
;; - file in test-programs/
;;   - possible testing mode
;;     - possible input files (specified via --in)
;;       -> Generate a golden input
;;       -> Write (to stdout) a call to this script that compares with that golden
(define (generate-goldens)
  (define base-path "goldens")
  (define (input-files) (map (λ (x) (format "./input-files/~a" x)) (directory-list "./input-files/")))
  (define n 1)
  (define total (* (length (directory-list (tests-dir))) (length (hash-keys modes)) (length (input-files))))
  (for ([tp (in-list (directory-list (tests-dir)))])
    (define test-program (path->string tp))
    (define program (with-input-from-file (format "test-programs/~a" test-program) read))
    (define program-name
      ;; assume suffix of .scm
      (substring test-program 0 (- (string-length test-program) 4)))
    (for ([mode (hash-keys modes)])
      (for ([cur-input-file (input-files)])
        (printf (format "\r\tGenerating test [~a/~a]: ~a, ~a, ~a                                        " n total test-program mode cur-input-file))
        ;; lookup the number from the file, assume files named X.in
        (define (number x) (substring x (- (string-length x) 4) (- (string-length x) 3)))

        ;; The relevant AST file will be written, predict what it is and emit it so we can reproduce this
        (define relevant-ast-file
          (if (equal? mode "native")
              (format "test-programs/~a"  test-program)
              (format "~a/~a_~a_~a.in-ast"
                      base-path
                      program-name
                      (number cur-input-file)
                      (first (hash-ref modes mode)))))
        (define relevant-golden
          (format "~a/~a_~a_~a.stdout"
                  base-path
                  program-name
                  (number cur-input-file)
                  (first pass-names)))
        (define repro
          (format "racket test.rkt -m ~a -i ~a -g ~a ~a" mode cur-input-file relevant-golden relevant-ast-file))
        (define repro-list (list mode relevant-ast-file cur-input-file relevant-golden)) 
        ;; create a folder encoding the testcase in the test/
        ;; subdirectory move all the files over from
        ;; canonical-testcase/ to this new subdirectory. Then write a
        ;; new file in that directory `testdata.cfg`, which is simply
        ;; repro-list above
        (define testcase-dir (format "test/~a_~a_~a" program-name mode (number cur-input-file)))
        (make-directory* testcase-dir)
        (for ([src (directory-list "canonical-testcase")])
          (define-values (parent name _) (split-path src))
          (copy-file (format "canonical-testcase/~a" src) (build-path testcase-dir name) #:exists-ok? #t))
        ;; now write testdata.cfg, which is run by the relevant script
        (with-output-to-file (build-path testcase-dir "testdata.cfg")
          (λ () (write repro-list)) #:exists 'replace)
        ;; also write in a .sh file for simplicity
        (with-output-to-file (repro-file)
          (λ ()
            (displayln repro))
          #:exists 'append)
        (set! n (add1 n))
        ;; compile the program and get a trace
        (define trace
          (parameterize ([current-output-port (open-output-nowhere)]
                         [input-file          cur-input-file])
            (run-assembler-linker program)))
        ;; write each IR level
        (for ([elt trace])
          (define infile (format "~a/~a_~a_~a.in-ast"
                                 base-path
                                 program-name
                                 (number cur-input-file)
                                 (hash-ref elt 'pass-name)))
          (define astfile (format "~a/~a_~a_~a.out-ast"
                                  base-path
                                  program-name
                                  (number cur-input-file)
                                  (hash-ref elt 'pass-name)))
          (define interp (format "~a/~a_~a_~a.interp"
                                 base-path
                                 program-name
                                 (number cur-input-file)
                                 (hash-ref elt 'pass-name)))
          (define stdout (format "~a/~a_~a_~a.stdout"
                                 base-path
                                 program-name
                                 (number cur-input-file)
                                 (hash-ref elt 'pass-name)))
          (with-output-to-file infile  (λ () (write (serialize (hash-ref elt 'orig-input)))) #:exists 'replace)
          (with-output-to-file astfile (λ () (write (serialize (hash-ref elt 'output))))     #:exists 'replace)
          (with-output-to-file interp (λ () (displayln (hash-ref elt 'interp))) #:exists 'replace)
          (with-output-to-file stdout (λ () (displayln (hash-ref elt 'stdout ""))) #:exists 'replace))))))

;; ───── execute tests ─────
(define (tests)
  (unless (equal? (mode) "gengoldens")
    (displayln "Error: must provide (at least) an input file (last argument to test.rkt); see README.md for instructions.")
    (exit 1))
  (cond
    [(equal? (mode) "json") ;; JSON mode is used by the autograder
     (define cfg (with-input-from-file prog-file read)) ;; use prog-file for cfg
     (match cfg
       [(list mode prog-file input-files goldens)
        ;; run testcase...
        (match (run/capture (λ () (run-test mode prog-file input-files goldens)))
          [(cons 'passed stdout) (display (jsexpr->string (hash 'status "passed" 'message stdout)))]
          [(cons 'failed stdout) (display (jsexpr->string (hash 'status "failed" 'message stdout)))]
          [_ (display (jsexpr->string (hash 'status "failed" 'message "")))])]
       [_ (error "Bad configuration file, contact your instructor.")])]
    [(equal? (mode) "gengoldens")
     ;; intended for instructor use
     (generate-goldens)]
    [else
     (run-test (mode) prog-file (in-files) (goldens))]))

(module+ main (tests))
