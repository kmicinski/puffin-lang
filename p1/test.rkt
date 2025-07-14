#lang racket
(require racket/match
         racket/string
         racket/port
         json
         "main.rkt"
         "system.rkt"
         "irs.rkt"
         "compile.rkt"
         "interpreters.rkt")

;; ───── command-line parsing ─────
(define mode (make-parameter "native"))
(define in-files (make-parameter ""))
(define goldens (make-parameter ""))
(define tests-dir (make-parameter "./test-programs/"))

(define prog-file
  (command-line
   #:once-each
   [("-m" "--mode") m "Run tests in mode <m>" (mode m)]
   [("-i" "--in")   input "Comma-separated list of input files"
                    (in-files input)]
   [("-g" "--gld") files "Comma-separated list of golden (output) files"
                   (goldens files)]
   #:args rest-args (if (empty? rest-args) 'no-file (first rest-args))))

;; ───── mode → metadata ─────
(define modes
  (hash
   "frontend"    (list "uniqueify"          "anf-convert"       anf-program?          interpret-anf)
   "middleend"   (list "explicate-control"  "uncover-locals"    locals-program?       interpret-c0)
   "backend"     (list "select-instructions" "patch-instructions" patched-program?    interpret-instr)
   "native"      #f))

(define mode-entry
  (hash-ref modes mode (λ () #f)))

;; ───── set pass range parameters (first 3 modes) ─────
(when mode-entry
  (match-define (list sp ep _ _) mode-entry)
  (start-pass sp)
  (end-pass   ep))

;; ───── load & validate program ─────
(define program (if (equal? prog-file 'no-file) 'no-file (with-input-from-file prog-file read)))

(when (and mode-entry (not (equal? mode "native")))
  (match-define (list _ _ pred _) mode-entry)
  (unless (pred program)
    (error 'test (format "program does not satisfy predicate for mode ~a" mode))))

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
   (format "\r\tTest type: native, Input: (~a, ...),  Your output: ~a,  Golden output: ~a Matches golden? ~a                         "
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
  (define (input-files) (directory-list "./input-files/"))
  (define n 1)
  (define total (* (length (directory-list (tests-dir))) (length (hash-keys modes)) (length (input-files))))
  (for ([tp (in-list (directory-list (tests-dir)))])
    (define test-program (path->string tp))
    (define program (with-input-from-file (format "test-programs/~a" test-program) read))
    (define program-name
      ;; assume suffix of .scm
      (substring test-program 0 (- (string-length test-program) 4))) 
    (for ([mode (hash-keys modes)])
      (for ([if (input-files)])
        (define input-file (path->string if))
        (printf (format "\r\tGenerating test [~a/~a]: ~a, ~a, ~a" n total test-program mode input-file))
        (set! n (add1 n))
        ;; compile the program and get a trace
        (define trace
          (parameterize ([current-output-port (open-output-nowhere)])
            (run-assembler-linker program)))
        (for ([elt trace])
          (define astfile (format "~a/~a_~a_~a.ast"
                                  base-path
                                  program-name
                                  (substring input-file 0 (- (string-length input-file) 3))
                                  (hash-ref elt 'pass-name)))
          (define interp (format "~a/~a_~a_~a.interp"
                                  base-path
                                  program-name
                                  (substring input-file 0 (- (string-length input-file) 3))
                                  (hash-ref elt 'pass-name)))
          (define stdout (format "~a/~a_~a_~a.stdout"
                                  base-path
                                  program-name
                                  (substring input-file 0 (- (string-length input-file) 3))
                                  (hash-ref elt 'pass-name)))
          (with-output-to-file astfile (λ () (pretty-print (hash-ref elt 'output))) #:exists 'replace)
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
     (displayln "Compiling silently... Program:")
     (pretty-print program)
     (define trace
       (parameterize ([current-output-port (open-output-nowhere)])
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
     (match-define (list _ _ _ interp) mode-entry)
     (for ([in inputs] [idx (in-naturals 1)])
       (define-values (val stdout)
         (run/capture (λ () (interp program in))))
       (displayln (format "Test ~a — input: ~a" idx in))
       (displayln (format "⇒ result: ~a" val))
       (unless (equal? "" stdout)
         (displayln (format "stdout: \"~a\"" (string-trim stdout)))))]))

(module+ main (tests))
