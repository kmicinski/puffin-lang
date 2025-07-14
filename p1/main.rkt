#lang racket

;; Please do not change (or at least, ask before you do)

(provide (all-defined-out)) ;; for test.rkt

;; This file contains code to plug each pass of the compiler together
;; and record each intermediate output. The goal is to be able to log
;; and expose this intermediate output for the purposes of debugging,
;; testing, etc. You do not necessarily need to understand this file,
;; though I do recommend reading it to understand how grading and
;; debugging work.
(require json)
(require "system.rkt") ;; list of passes, system-relevant details, etc.
(require "irs.rkt")
(require "compile.rkt")
(require "interpreters.rkt")

;; For hosting the debug server
(require web-server/servlet
         web-server/servlet-env
         web-server/http)

;; Lists of all of the passes, their names, input predicates, output predicates, and interpreters
;; NOTE: first/lass pass has to stay in sync with the parameters in system.rkt
(define all-passes
  (list `(,uniqueify              "uniqueify"           ,R1?                       ,unique-source-tree?     ,interpret-R1)
        `(,anf-convert            "anf-convert"         ,unique-source-tree?       ,anf-program?            ,interpret-anf)
        `(,explicate-control      "explicate-control"   ,anf-program?              ,c0-program?             ,interpret-c0)
        `(,uncover-locals         "uncover-locals"      ,c0-program?               ,locals-program?         ,interpret-c0)
        `(,select-instructions    "select-instructions" ,locals-program?           ,instr-program?          ,interpret-instr)
        `(,assign-homes           "assign-homes"        ,instr-program?            ,homes-assigned-program? ,interpret-instr)
        `(,patch-instructions     "patch-instructions"  ,homes-assigned-program?   ,patched-program?        ,interpret-instr)
        `(,prelude-and-conclusion "prelude-and-conclusion" ,patched-program?       ,x86-64?                 ,interpret-instr)
        `(,dump-x86-64            "render-x86"             ,x86-64?                ,string?                 ,dummy-interp-x86-64)))

;; Make each column available
(match-define (list passes
                    pass-names
                    input-predicates
                    output-predicates
                    interpreters)
  (apply map list all-passes))

;; 
;; Testing / debugging facilities
;;

;; Run a single compiler pass, with an input satisfying some input
;; predicate and an output satisfying some output predicate. Return
;; the value of `(pass input)`.
(define (run-pass-expect pass pass-name input input-pred output-pred [interp (lambda (x _) x)] [input-stream #f])
  ;; Run the pass
  (define output (pass input))
  ;; Build an object of metadata 
  (define h (hash 'input (pretty-format input)
                  'pass-name pass-name
                  'satisfies-input-predicate (input-pred input)
                  'satisfies-output-predicate (output-pred output)
                  'pretty-output (if (string? output) output (pretty-format output))
                  'output output))
  ;; Run the interpreter--the identity interpreter (discards input) is
  ;; used as a default parameter if none is provided
  (match (run/capture (λ () (interp (hash-ref h 'output) input-stream))) ;; see system.rkt
    [(cons v stdout)
     (hash-set (hash-set h 'interp v) 'stdout stdout)]))

;; Generate a pretty emoji for the terminal
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
  (displayln "Evaluation of your output:")
  (pretty-print (hash-ref h 'interp)))

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
          [x  (format "stdout: \"~a\"" (string-trim x))]))
      (displayln (format "~a: Input (~a) Output (~a) Evaluation: ~a ~a" 
                         (~a (hash-ref elt 'pass-name) #:align 'left  #:width 30)
                         (yesno (hash-ref elt 'satisfies-input-predicate))
                         (yesno (hash-ref elt 'satisfies-output-predicate))
                         evals-to
                         maybe-stdout))))
  (for ([elt trace])
    (pass-output->stdout elt))
  (print-summary trace))

;; Walk over a trace and write each pass to a file tree 
(define (trace->file-tree trace)
  (for ([trace-element trace])
    (define extension (hash-ref trace-element 'pass-name))
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
               [next-input (pass input)])
          (loop (cdr passes) (cdr names) (cdr in-preds) (cdr out-preds)
                next-input (cdr interps) (cons h trace))))))

;; Run each of the passes in sequence, building a chain of passes
(define (compile-verbose source-tree)
  ;; return either #f (error) or a cons cell (range)
  (define (get-pass-range start-name end-name)
    (define start-idx (index-of pass-names start-name string=?))
    (define end-idx   (index-of pass-names end-name   string=?))
    (and start-idx end-idx (<= start-idx end-idx) (cons start-idx end-idx)))
  (define (slice-list lst range)
    (match-define (cons start end) range)
    (take (drop lst start) (add1 (- end start))))
  (define our-range (get-pass-range start-pass end-pass))
  (unless our-range ;; #f is invalid
    (error (format "Bad start/end pass range name (chose from {~a})" (string-join pass-names " "))))
  (define our-input-stream
    (if (input-file) 
         (map string->number (file->lines (input-file)))
         (range 100)))
  ;; all of these defines used for verbose mode (to record each pass
  ;; and print its value)
  (let ([trace (run-chain source-tree
                          (slice-list passes our-range)
                          (slice-list pass-names our-range)
                          (slice-list input-predicates our-range)
                          (slice-list output-predicates our-range)
                          (slice-list interpreters our-range)
                          our-input-stream)])
    (when (write-stdout-mode)
      (trace->stdout trace))
    trace))

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

;; Generate a binary (delete any stale executable first, then verify its creation)
(define (run-assembler-linker source-tree)
  (displayln "Compiling IR (using *your* compile.rkt) …")
  (define trace    (compile-verbose source-tree))
  (define asm-text (hash-ref (last trace) 'output))

  ;; (a) ensure we start clean
  (when (file-exists? (executable-file))
    (delete-file (executable-file)))

  (displayln "🏗️ Now building a binary... 🏗️")
  (with-output-to-file (asm-file) #:exists 'replace
    (λ () (displayln asm-text)))

  ;; host-specific settings
  (define os   (host-os))
  (define arch 'x86_64)
  (define tgt  (target-triple os arch))
  (define cc   (or (getenv "CC") "clang"))
  (define target-flag      (if (string=? tgt "") "" (format "-target ~a" tgt)))
  (define common-cc-flags  "-Wall -O2")

  (define linux-extra (if (eq? os 'unix) "-no-pie" ""))

  (displayln (format "→ Host: ~a/~a  Target: ~a  Entry: ~a"
                     os arch (if (string=? tgt "") "default" tgt) (entry-symbol)))
  ;; assemble & link
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
  (let loop ([cmds (list assemble-cmd assemble-runtime-cmd link-cmd)])
    (match cmds
      ['() (error 'run-assembler-linker "linker failed: ~a not produced" (executable-file))]
      [(cons cmd rest)
       (execute-get-output cmd)
       (if (file-exists? (executable-file))
           (begin
             (displayln (format "✔ Executable produced at: ~a" (executable-file)))
             trace)
           (loop rest))])))

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
         (index  req)]))

;;
;; Main entrypoint
;;
(define (main)
  (define file-path
    (command-line
     #:once-each
     [("-d" "--debug-server") "Run a debug server, which lets you see the results of each pass"
                              (debug-server-mode #t)]
     [("-s" "--start-pass") pass "Start at pass <pass>"
                            (start-pass pass)]
     [("-e" "--end-pass") pass "End at pass <pass>"
                          (end-pass pass)]
     #:args (filename) filename))
  (define source-tree (with-input-from-file file-path read))
  (cond
    ;; Start a debug server
    [(debug-server-mode)
     (serve/servlet start
                    #:servlet-path "/"
                    #:servlet-regexp #rx""   ; accept *any* path, incl. /upload
                    #:launch-browser? #t
                    #:port 8000)]
    [else
     ;; Else, build the binary
     (run-assembler-linker source-tree)
     (displayln "Done!")]))

;; Parse the command line
(module+ main
  (main))
