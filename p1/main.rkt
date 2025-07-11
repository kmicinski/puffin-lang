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

(define asm-file (make-parameter "./output.s"))
(define object-file (make-parameter "./output.o"))
(define executable-file (make-parameter "./output"))
(define runtime-file (make-parameter "./runtime.c"))
(define runtime-object-file (make-parameter "./runtime.o"))
(define write-outputs-mode (make-parameter #f))
(define write-json-mode (make-parameter #t))
(define write-stdout-mode (make-parameter #t))
(define verbose-mode (make-parameter #t))
(define debug-server-mode (make-parameter #f))
(define produce-binary-mode (make-parameter #t))

;; Execute a command and get an output
(define (execute-get-output cmd)
  (displayln (format "Executing `~a`." cmd))
  (with-output-to-string (λ () 
                           (system cmd))))

;; Parse the command line
(define file-path
  (command-line 
   #:once-each
   [("-d" "--debug-server") "Run a debug server, which lets you see the results of each pass"
                      (debug-server-mode #t)
                      (write-outputs-mode #f) ;; doesn't work well with web server
                      ]
   [("-o" "--output") "Write outputs of each IR to out.X and out.X.interp"
                      (write-outputs-mode #t)]
   #:args (filename) filename))

;; 
;; Testing / debugging facilities
;;

;; Run a single compiler pass, with an input satisfying some input
;; predicate and an output satisfying some output predicate. Return
;; the value of `(pass input)`.
;; 
;; If `golden-output` is provided, then `interp-output` (an
;; interpreter for the output IR) must be provided, too.
(define (run-pass-expect pass pass-name input input-pred output-pred
                         [golden-input #f]
                         [golden-output #f] [interp-output #f])
  (define output-equal? equal?) ;; for now, just use equal? for output comparison
  (define output (pass input))
  (define h (hash 'input (pretty-format input) 
                  'pass-name pass-name
                  'satisfies-input-predicate (input-pred input)
                  'satisfies-output-predicate (output-pred output)
                  'golden-input (pretty-format golden-input)
                  'pretty-output (if (string? output) output (pretty-format output))
                  'output output))
  (if golden-output
      (let* ([evaled-golden (interp-output golden-output)]
             [evaled-user (interp-output output)]
             [output-matches (output-equal? evaled-user evaled-golden)])
        (hash-set (hash-set (hash-set (hash-set h 'golden-output golden-output)
                            'evaled-golden (pretty-format evaled-golden))
                            'evaled-user evaled-user)
                  'correct
                  output-matches))
      ;; 
      h))

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
;;  - A list of golden inputs (one for each pass), possibly #f--see notes
;;  - A list of golden outputs (one for each pass), possibly #f--see notes
;;  - A list of interpreters which interpret the output of each pass
;; 
;; The function then produces a trace of each pass, which may be
;; rendered to screen, written to file, etc.
(define (run-chain source-tree passes pass-names input-predicates output-predicates
                   golden-inputs golden-outputs interpreters)
  (let loop ([passes      passes]
             [names       pass-names]
             [in-preds    input-predicates]
             [out-preds   output-predicates]
             [gold-ins    golden-inputs]
             [gold-outs   golden-outputs]
             [interps     interpreters]
             [input       source-tree]
             [trace       '()])
    (if (null? passes)
        (reverse trace)
        (let* ([pass       (car passes)]
               [pass-name  (car names)]
               [in-pred    (car in-preds)]
               [out-pred   (car out-preds)]
               [gold-in    (car gold-ins)]
               [gold-out   (car gold-outs)]
               [interp     (car interps)]
               [h          (run-pass-expect pass pass-name input
                                            in-pred out-pred
                                            gold-in gold-out interp)]
               [next-input (pass input)])
          (loop (cdr passes) (cdr names) (cdr in-preds) (cdr out-preds)
                (cdr gold-ins) (cdr gold-outs) (cdr interps)
                next-input (cons h trace))))))

;; Run each of the passes in sequence, building a chain of passes
(define (compile-verbose source-tree [golden-inputs #f] [golden-outputs #f])
  ;; all of these defines used for verbose mode (to record each pass
  ;; and print its value)
  (define goldens-in (if golden-inputs golden-inputs (make-list (length passes) #f)))
  (define goldens-out (if golden-outputs golden-outputs (make-list (length passes) #f)))
  (define interpreters (make-list (length passes) #f))
  (let ([trace (run-chain source-tree
                          passes
                          pass-names
                          input-predicates
                          output-predicates
                          goldens-in
                          goldens-out
                          interpreters)])
    (when (write-stdout-mode)
      (trace->stdout trace))
    (when (write-json-mode)
      (with-output-to-file "compilation.json"
        (λ () (write-json (trace->jsexpr trace)))
        #:exists 'replace))
    #;
    (when (write-outputs-mode)
      (trace->file-tree trace))
    trace))

;; Run the system-level assembler/linker to produce a binary
;; executable
(define (run-assembler-linker source-tree)
  ;; A thin wrapper around compile-verbose
  (define (compile source-tree [verbose #f] [golden-inputs #f] [golden-outputs #f])
    (hash-ref (last (compile-verbose source-tree golden-inputs golden-outputs)) 'output))
  (displayln "Compiling using compile.rkt -> x86_64")
  (define output-string (compile source-tree (verbose-mode)))
  (with-output-to-file (asm-file)
    (λ () (let ([output-text output-string])
            (displayln output-text)))
    #:exists 'replace)
  ;; Assemble the output file
  (displayln "Assembling file to executable...")
  (execute-get-output (format "clang -target x86_64-apple-darwin -c ~a -o ~a " (asm-file) (object-file)))
  (execute-get-output (format "clang -target x86_64-apple-darwin -c ~a -o ~a " (runtime-file) (runtime-object-file)))
  (execute-get-output (format "clang -target x86_64-apple-darwin ~a ~a -o ~a" (object-file) (runtime-object-file) (executable-file)))
  (displayln (format "Executable now at ~a" (executable-file))))

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
  (when (debug-server-mode)
    (serve/servlet start
                 #:servlet-path "/"
                 #:servlet-regexp #rx""   ; accept *any* path, incl. /upload
                 #:launch-browser? #t
                 #:port 8000))
  (define source-tree (with-input-from-file file-path read))
  ;; Run the system-level assembler/linker to produce a binary
  (when (produce-binary-mode)
    (run-assembler-linker source-tree)))

(main)

