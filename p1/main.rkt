#lang racket

;; Please do not change (or at least, ask before you do)

;; This file contains code to plug each pass of the compiler together
;; and record each intermediate output. The goal is to be able to log
;; and expose this intermediate output for the purposes of debugging,
;; testing, etc. You do not necessarily need to understand this file,
;; though I do recommend reading it to understand how grading and
;; debugging work.
(require racket/system)
(require json)
(require "irs.rkt")
(require "compile.rkt")

;; For hosting the debug server
(require web-server/servlet
         web-server/servlet-env
         web-server/http)

;; Information specific to the project
(define passes (list uniqueify anf-convert explicate-control uncover-locals
                     select-instructions assign-homes patch-instructions
                     prelude-and-conclusion dump-x86-64))

(define pass-names (list "uniqueify" "anf-convert" "explicate-control" "uncover-locals"
                         "select-instructions" "assign-homes" "patch-instructions"
                         "prelude-and-conclusion" "render-x86"))

(define (pass-name->extension name)
  (match name
    ["uniqueify" ".uniq"]
    ["anf-convert" ".anf"] 
    ["explicate-control" ".c0"]
    ["uncover-locals" ".c0-lcl"]
    ["select-instructions" ".instrs"]
    ["assign-homes" ".homes"]
    ["patch-instructions" ".patched"]
    ["prelude-and-conclusion" ".prelude"]
    ["render-x86" ".S"]))

(define input-predicates
  (list R1? unique-source-tree? anf-program? c0-program? locals-program?
        instr-program? homes-assigned-program? patched-program?
        x86-64?))

(define output-predicates
  (list unique-source-tree? anf-program? c0-program? locals-program?
        instr-program? homes-assigned-program? patched-program? x86-64?
        string?)) 

(define-runtime-path here-dir ".")         ; path to folder containing this file

(define asm-file (make-parameter "./output.s"))
(define object-file (make-parameter "./output.o"))
(define executable-file (make-parameter "./output"))
(define runtime-file (make-parameter "./runtime.c"))
(define runtime-object-file (make-parameter "./runtime.o"))
(define run-test-mode (make-parameter #f))
(define write-json-mode (make-parameter #t))
(define write-stdout-mode (make-parameter #t))
(define debug-server-mode (make-parameter #f))
(define produce-binary-mode (make-parameter #t))
(define scheme-files (make-parameter (build-path here-dir "example-programs")))
(define input-files (make-parameter #f))
(define output-files (make-parameter #f))
(define intermediate-ir (make-parameter #f))
(define test-mode (make-parameter "native"))

;; Execute a command and get an output
(define (execute-get-output cmd)
  (displayln (format "Executing `~a`." cmd))
  (with-output-to-string (λ () 
                           (system cmd))))

;; Parse the command line
(define file-path
  (command-line 
   #:once-each
   [("-t" "--run-test") "Run a test"
                        (run-test-mode #t)]
   [("-d" "--debug-server") "Run a debug server, which lets you see the results of each pass"
                      (debug-server-mode #t)
                      (write-outputs-mode #f) ;; doesn't work well with web server
                      ]
   [("-o" "--output") "Write outputs of each IR to out.X and out.X.interp"
                      (write-outputs-mode #t)]
   [("-i" "--inputs") i "Provide a list of comma-separated input files for testing"
                      (input-files (string-split i ","))]
   [("-g" "--goldens") g "Provide a list of golden (answer) outputs"
                       (output-files (string-split g ","))]
   [("-m" "--mode") mode "Set the test mode (anf, c0, instrs, native)"
                    (test-mode mode)]
   [("--use-intermediate-ir") ir "Use an instructor-provided intermediate IR"
                              (intermediate-ir ir)]
   #:args (filename) filename))

;; 
;; Testing / debugging facilities
;;
;; racket main.rkt example-programs/r0-2.scm -i example-inputs/1.in,example-inputs/1.in

;; Run a single compiler pass, with an input satisfying some input
;; predicate and an output satisfying some output predicate. Return
;; the value of `(pass input)`.
(define (run-pass-expect pass pass-name input input-pred output-pred)
  (define output (pass input))
  (hash 'input (pretty-format input)
                  'pass-name pass-name
                  'satisfies-input-predicate (input-pred input)
                  'satisfies-output-predicate (output-pred output)
                  'pretty-output (if (string? output) output (pretty-format output))
                  'output output))

(define (yesno x) (if x "✅" "❌"))

;; Write a pass output to stdout
(define (pass-output->stdout h)
  (when (hash-ref h 'golden-input #f)
      (displayln (format "Golden input:\n~a" (hash-ref h 'golden-input))))
  (displayln "Input:")
  (displayln (hash-ref h 'output))
  (displayln (format "Satsifes input predicate: ~a" (yesno (hash-ref h 'satisfies-input-predicate))))
  (displayln (format "Ran pass ~a. Output:" (hash-ref h 'pass-name)))
  (displayln (hash-ref h 'pretty-output))
  (displayln (format "Satisfies output predicate: ~a" (yesno (hash-ref h 'satisfies-output-predicate))))
  (when (hash-ref h 'golden-output #f)
    (displayln (format "Golden (instructor-provided) output:\n~a" (hash-ref h 'golden-input)))
    (displayln (format "Evaluation of golden output: ~a" (hash-ref h 'evaled-golden)))
    (displayln (format "Evaluation of your output: ~a" (hash-ref h 'evaled-user)))
    (displayln (format "Yours correct? ~a" (yesno (hash-ref h 'correct))))))

;; Write a whole trace to stdout
(define (trace->stdout trace)
  (define (print-summary trace)
    (displayln "\nSummary of passes run:\n\n")
    (for ([elt trace])
      (displayln (format "~a: Input (~a) Output (~a)"
                         (~a (hash-ref elt 'pass-name) #:align 'left  #:width 30)
                         (yesno (hash-ref elt 'satisfies-input-predicate))
                         (yesno (hash-ref elt 'satisfies-output-predicate))))))
  (for ([elt trace])
    (pass-output->stdout elt))
  (print-summary trace))

;; Walk over a trace and write each pass to a file tree 
(define (trace->file-tree trace)
  (for ([trace-element trace])
    (define extension (pass-name->extension (hash-ref trace-element 'pass-name)))
    (with-output-to-file (format "intermediate-outputs/compilation~a" extension)
      (λ () (pretty-print (hash-ref trace-element 'output)))
      #:exists 'replace)))

;; Walk over a trace and write it to a JSON expression
(define (trace->jsexpr trace)
  (map (λ (trace-element)
         (hash-set trace-element 'output (pretty-format (hash-ref trace-element 'output))))
       trace))

;; This function `run-chain` is a very general iterator function which
;; walks over a list of passes, while simultaneously (a) checking
;; input/output predicates for each pass, (b) checking consistency
;; with "golden" inputs and outputs. Golden inputs / outputs are
;; instructor-provided inputs / outputs which will be validated by the
;; test scripts.
;; 
;; The function accepts the following inputs:
;;  - The input source tree
;;  - A list of passes
;;  - A list of pass names for each pass
;;  - A list of input and output predicates for each pass
;; 
;; The function then produces a trace of each pass, which may be
;; rendered to screen, written to file, etc.
(define (run-chain source-tree passes pass-names input-predicates output-predicates)
  (let loop ([passes      passes]
             [names       pass-names]
             [in-preds    input-predicates]
             [out-preds   output-predicates]
             [input       source-tree]
             [trace       '()])
    (if (null? passes)
        (reverse trace)
        (let* ([pass       (car passes)]
               [pass-name  (car names)]
               [in-pred    (car in-preds)]
               [out-pred   (car out-preds)]
               [h          (run-pass-expect pass pass-name input
                                            in-pred out-pred)]
               [next-input (pass input)])
          (loop (cdr passes) (cdr names) (cdr in-preds) (cdr out-preds)
                next-input (cons h trace))))))

;; Run each of the passes in sequence, building a chain of passes
(define (compile-verbose source-tree)
  ;; all of these defines used for verbose mode (to record each pass
  ;; and print its value)
  (let ([trace (run-chain source-tree
                          passes
                          pass-names
                          input-predicates
                          output-predicates)])
    (when (write-stdout-mode)
      (trace->stdout trace))
    (when (write-json-mode)
      (with-output-to-file "compilation.json"
        (λ () (write-json (trace->jsexpr trace)))
        #:exists 'replace))
    trace))

(define (test-ir-range* start-pass-name
                        end-pass-name
                        source-tree
                        interpreter                 ; (IR × input → output)
                        input-streams               ; listof (listof integer)
                        expected-streams)           ; same length as above
  (unless (= (length input-streams) (length expected-streams))
    (error 'test-ir-range*
           "input-streams and expected-streams must be the same length"))

  ;; --- slice -----------------------------------------------------------------
  (define start-idx (index-of pass-names start-pass-name))
  (define end-idx   (index-of pass-names end-pass-name))
  (unless (and start-idx end-idx (<= start-idx end-idx))
    (error 'test-ir-range*
           "Bad pass names/order: ~a → ~a" start-pass-name end-pass-name))

  (define slice-len (+ 1 (- end-idx start-idx)))
  (define passes*    (take (list-tail passes             start-idx) slice-len))
  (define names*     (take (list-tail pass-names         start-idx) slice-len))
  (define in-preds*  (take (list-tail input-predicates   start-idx) slice-len))
  (define out-preds* (take (list-tail output-predicates  start-idx) slice-len))

  ;; --- compile once ----------------------------------------------------------
  (define trace
    (run-chain source-tree passes* names* in-preds* out-preds*))
  (define final-ir (hash-ref (last trace) 'output))

  ;; --- run every test case ---------------------------------------------------
  (define results
    (for/list ([in   input-streams]
               [exp  expected-streams]
               [idx  (in-naturals 0)])
      (define act (interpreter final-ir in))
      (define ok? (equal? act exp))
      (displayln
       (format "Case ~a:\n  input     = ~a\n  expected  = ~a\n  actual    = ~a\n  result    = ~a\n"
               idx in exp act (if ok? "✅ ok" "❌ mismatch")))
      (hash 'case      idx
            'input     in
            'expected  exp
            'actual    act
            'correct?  ok?)))

  (hash 'trace        trace
        'cases        results
        'all-correct? (andmap (λ (h) (hash-ref h 'correct?)) results)))

;; 
;; Code to compile / link on the host machine
;;
(define (target-triple os arch)
  ;; Only add -target when we *must* cross-compile; otherwise rely on
  ;; clang’s normal “host triple” detection.
  (match* (os arch)
    [('macosx 'aarch64)  "arm64-apple-darwin"]
    [('macosx 'x86_64)   "x86_64-apple-darwin"]
    [('unix   'x86_64)   "x86_64-pc-linux-gnu"]
    [(_       _)         ""]))

(define (flag-list->string flags)
  (string-join (filter (λ (s) (not (string=? s ""))) flags) " "))

;; Generate a binary
(define (run-assembler-linker source-tree)
  (displayln "Compiling IR (compile.rkt) …")
  (define asm-text
    (hash-ref (last (compile-verbose source-tree)) 'output))
  (with-output-to-file (asm-file)
    #:exists 'replace
    (λ () (displayln asm-text)))
  ;; Choose host-specific settings
  (define os    (host-os))
  (define arch  (host-arch))
  (define tgt   (target-triple os arch))
  (define entry (entry-symbol os))
  (define cc    (or (getenv "CC") "clang"))
  (define target-flag      (if (string=? tgt "") "" (format "-target ~a" tgt)))
  (define common-cc-flags  "-Wall -O2")
  ;; Some Linux distros default to PIE binaries; disable if your
  ;; hand-written assembly has its own _start and no PIC support.
  (define linux-extra      (if (eq? os 'unix) "-no-pie" ""))
  (displayln (format "→ Host: ~a/~a  Target: ~a  Entry: ~a"
                     os arch (if (string=? tgt "") "default" tgt) entry))
  ;; —– 3. Assemble & link —–––––––––––––––––––––––––––––––––––––
  (define assemble-cmd
    (string-append cc " "
                   (flag-list->string (list target-flag common-cc-flags))
                   " -c " (asm-file) " -o " (object-file)))

  (define assemble-runtime-cmd
    (string-append cc " "
                   (flag-list->string (list target-flag common-cc-flags))
                   " -c " (runtime-file) " -o " (runtime-object-file)))

  (define link-cmd
    (string-append cc " "
                   (flag-list->string
                    (list target-flag common-cc-flags linux-extra))
                   " " (object-file) " " (runtime-object-file)
                   " -o " (executable-file)))
  ;; Execute each command
  (for ([cmd (list assemble-cmd assemble-runtime-cmd link-cmd)])
    (displayln cmd)
    (void (system cmd)))
  (displayln (format "✔ Executable produced at: ~a" (executable-file))))

(define test-modes
  (hash
   "anf"        `(mode-config "uniqueify"           "anf-convert"        ,interp-anf)
   "c0"         (mode-config "explicate-control"   "uncover-locals"     ,interp-c0)
   "pseudo-x86" (mode-config "select-instructions" "patch-instructions" interp-px86  px86-tests)
   "x86-64"     (mode-config #f                   #f                   #f           native-tests))) ; handled specially

;; Run a rest and return its value, either 'pass or 'fail, print results to stdout
(define (toplevel-execute-test)
  )

;; 
;; Debug server infrastructure
;;
(define index-page (file->string "./index.html")) ;; our frontend code (JS)
 
(define (index _req)
  (response/full
   200                                  ; status
   #"OK"                                ; message
   (current-seconds)                    ; date
   #"text/html; charset=utf-8"          ; MIME type
   (list (header #"Content-Type" #"text/html; charset=utf-8"))
   (list (string->bytes/utf-8 index-page)))) ; body

(define (upload req)
  (define raw (request-post-data/raw req))
  (unless raw (error 'upload "POST had no plain-text body"))
  (define sexpr (read (open-input-string (bytes->string/utf-8 raw))))
  (define response
    (if (R1? sexpr)
        ;; valid program, compile it
        (let ([compilation-trace (compile-verbose sexpr)])
          (trace->jsexpr compilation-trace))
        (hasheq "error" "Input does not match R1? (see irs.rkt)"))) 
  (response/full
   200 #"OK" (current-seconds)
   #"application/json"
   (list (header #"Content-Type" #"application/json"))
   (list (jsexpr->bytes response))))

;; Entrypoint handler for the debug server
(define (start req)
  (define method (request-method req))
  (define uri    (url->string (request-uri req)))
  (cond [(and (equal? method #"POST") (string=? uri "/"))  ; we post to "/"
         (upload req)]
        ;; Serve the index page to any other request
        [else
         (displayln "here")
         (index  req)]))

;;
;; Main entrypoint
;;
(define (main)
  (define source-tree (with-input-from-file file-path read))
  (cond
    ;; Start a debug server
    [(debug-server-mode)
     (serve/servlet start
                    #:servlet-path "/"
                    #:servlet-regexp #rx""   ; accept *any* path, incl. /upload
                    #:launch-browser? #t
                    #:port 8000)]
    ;; Run a test
    [(run-test-)]
)
  (when (produce-binary-mode)
    (run-assembler-linker source-tree)))

(main)






