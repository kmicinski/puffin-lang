#lang racket
(require racket/match
         racket/string
         racket/port
         racket/pretty
         racket/serialize
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
(define repro-file (make-parameter "./repro.sh"))

(define prog-file
  (command-line
   #:once-each
   [("-m" "--mode") m "Run tests in mode <m>" (mode m)]
   [("-i" "--in")   input "Comma-separated list of input files"
                    (in-files input)]
   [("-g" "--gld") files "Comma-separated list of golden (output) files"
                   (goldens files)]
   [("-v" "--verbose") "Verbose mode"
                       (verbose-mode #t)]
   #:args rest-args (if (empty? rest-args) 'no-file (first rest-args))))

;; ───── mode → metadata ─────
(define modes
  (hash
   "frontend"    (list "uniqueify"           "anf-convert"        R1?              interpret-anf)
   "middleend"   (list "explicate-control"   "uncover-locals"     locals-program?  interpret-c0)
   "backend"     (list "select-instructions" "patch-instructions" patched-program? interpret-instr)
   "native"      (list "uniqueify"           "render-x86"         string?          dummy-interp-x86-64)))

(define mode-entry (hash-ref modes (mode) #f))

(define (input-paths) (string-split (in-files) ","))

(define (file->ints p)
  (map string->number (file->lines (string-trim p))))

(define inputs (map file->ints (input-paths)))

(define (run-native-test infile golden)
  (define (yesno b?) (if b? "✅" "❌"))
  (define (path->trimmed-string p)
    (string-trim (file->string p)))
  (define (read-input-list p)
    (map string->number
         (filter (λ (s) (not (string=? s "")))
                 (regexp-split #px"\\s+" (path->trimmed-string p)))))
  (define exe (executable-file))
  (displayln (format "Running test (input file ~a, golden file ~a)" infile golden))
  (unless (file-exists? exe)
    (error 'run-native-test
           "Executable ~a not found; build it with run-assembler-linker first"
           exe))
  (define input-nums (read-input-list infile))
  (define-values (proc out-port in-port err-port)
    (subprocess #f #f #f exe))

  ;; send input to stdin and flush it
  (fprintf in-port "~a\n"
           (string-join (map number->string input-nums) " "))
  (close-output-port in-port)
  (define program-out (string-trim (port->string out-port)))
  (define golden-out  (path->trimmed-string golden))
  (define match? (string=? program-out golden-out))
  ;; ── pretty console report ─────────────────────────────────────────────
  (displayln
   (format "\r\tInput: (~a, ...),  Your output: ~a,  Golden output: ~a Matches golden? ~a                         "
           (string-join (map number->string (take input-nums 3)) ", ")
           program-out
           golden-out
           (yesno match?)))
  (if match? 'passed 'failed))

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
          (with-output-to-file stdout (λ () (displayln (hash-ref elt 'stdout))) #:exists 'replace))))))

;; ───── execute tests ─────
(define (tests)
  (cond
    [(equal? (mode) "gengoldens")
     ;; intended for instructor use
     (generate-goldens)]
    [(equal? (mode) "native")
     ;; run the full compiler once
     (define program (with-input-from-file prog-file read))
     (displayln "Compiling silently...")
     (define trace
       (parameterize ([current-output-port (open-output-nowhere)]
                      [start-pass (first  (hash-ref modes (mode)))]
                      [end-pass   (second (hash-ref modes (mode)))])
         (run-assembler-linker program)))
     (unless (file-exists? (executable-file))
       (error 'run-one-native-test
              "Executable ~a not found; did the build fail?"
              (executable-file)))
     (displayln (format "Executable ~a found, running native tests..." (executable-file)))
     (displayln (input-paths))
     (for ([infile (input-paths)]
           [golden (string-split (goldens) ",")])
       ;; run the test
       (run-native-test infile golden))]
    [else
     (match-define (list start-pass-name end-pass-name entry-pred out-interp) mode-entry)
     ;; Compare each output to each golden
     (for ([in-file (input-paths)]
           [golden (map file->string (string-split (goldens) ","))] 
           [idx (in-naturals 1)])
       (displayln "Compiling silently (for this input)...")
       (define ints (file->ints in-file))
       (define program (with-input-from-file prog-file (λ () (deserialize (read)))))
       (define trace
         (parameterize ([current-output-port (open-output-nowhere)]
                        [start-pass (first  (hash-ref modes (mode)))]
                        [end-pass   (second (hash-ref modes (mode)))]
                        [input-file in-file])
           (run-assembler-linker program)))
       (match-define (cons val stdout)
         (run/capture (λ () (out-interp (hash-ref (last trace) 'output) ints))))
       (displayln (format "Test — input: ~a ..."
                          (string-join (map (λ (x) (format "~a" x)) (take ints 3))  ",")))
       (displayln (format "⇒ result: ~a stdout: ~a" val (pretty-format stdout)))
       (define matches? (equal? (string-trim stdout) (string-trim golden)))
       (displayln (format "Test passes? ~a ~a"
                          (yesno matches?)
                          (if matches? "" (format "expected ~a" golden)))))]))

(module+ main (tests))
