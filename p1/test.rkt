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

(define prog-file
  (command-line
   #:once-each
   [("-m" "--mode") m "Run tests in mode <m>" (mode m)]
   [("-i" "--in") files "Comma-separated list of input files"
                  (in-files files)]
   [("-g" "--gld") files "Comma-separated list of golden (output) files"
                   (goldens files)]
   #:args (file) file))

;; ───── mode → metadata ─────
(define modes
  (hash
   "frontend"    (list "uniqueify"          "anf-convert"       anf-program?          interpret-anf)
   "middleend"   (list "explicate-control"  "uncover-locals"    locals-program?       interpret-c0)
   "backend"     (list "select-instructions" "patch-instructions" patched-program?    interpret-instr)
   "consistency" #f
   "native"      #f))

(define mode-entry
  (hash-ref modes mode (λ () #f)))

;; ───── set pass range parameters (first 3 modes) ─────
(when mode-entry
  (match-define (list sp ep _ _) mode-entry)
  (start-pass sp)
  (end-pass   ep))

;; ───── load & validate program ─────
(define program (with-input-from-file prog-file read))

(when (and mode-entry (not (equal? mode "native")))
  (match-define (list _ _ pred _) mode-entry)
  (unless (pred program)
    (error 'test (format "program does not satisfy predicate for mode ~a" mode))))

(define (input-paths) (string-split (in-files) ","))

(define (file->ints p)
  (map string->number (file->lines (string-trim p))))

(define inputs
  (if (null? (input-paths))
      (list (range 100))
      (map file->ints (input-paths))))

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
   (format "Test type: native, Input: (~a, ...),  Your output: ~a,  Golden output: ~a Matches golden? ~a"
           (string-join (map number->string (take input-nums 3)) ", ")
           program-out
           golden-out
           (yesno match?)))
  (if match? 'passed 'failed))

;; ───── execute tests ─────
(define (tests)
  (cond
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
       (displayln infile)
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







