#lang racket

;; Please do not change (or at least, ask before you do)

(provide (all-defined-out)) ;; for test.rkt

;; This file contains code to plug each pass of the compiler together
;; and record each intermediate output. The goal is to be able to log
;; and expose this intermediate output for the purposes of debugging,
;; testing, etc. You do not necessarily need to understand this file,
;; though I do recommend reading it to understand how grading and
;; debugging work.
(require "system.rkt") ;; list of passes, system-relevant details, etc.
(require "irs.rkt")
(require "compile.rkt")
(require "interpreters.rkt")

 ;; Lists of all of the passes, their names, input predicates, output predicates, and interpreters
 ;; NOTE: first/last pass has to stay in sync with the parameters in system.rkt
 (define all-passes
   (list 
    `(,shrink                 "shrink"                 ,R3?                           ,shrunk-R3?                    ,interpret-R3)
    `(,uniqueify              "uniqueify"              ,shrunk-R3?                    ,unique-source-tree?           ,interpret-R3)
    `(,assignment-convert     "assignment-convert"     ,unique-source-tree?           ,assignment-converted-program? ,interpret-R3)
    `(,anf-convert            "anf-convert"            ,assignment-converted-program? ,anf-program?                  ,interpret-R3)
    `(,explicate-control      "explicate-control"      ,anf-program?                  ,c2-program?                   ,interpret-c2)
    `(,uncover-locals         "uncover-locals"         ,c2-program?                   ,locals-program?               ,interpret-c2)
    `(,select-instructions    "select-instructions"    ,locals-program?               ,instr-program?                ,interpret-instr)
    `(,assign-homes           "assign-homes"           ,instr-program?                ,homes-assigned-program?       ,interpret-instr)
    `(,patch-instructions     "patch-instructions"     ,homes-assigned-program?       ,patched-program?              ,interpret-instr)
    `(,prelude-and-conclusion "prelude-and-conclusion" ,patched-program?              ,x86-64?                       ,interpret-instr)
    `(,dump-x86-64            "render-x86"             ,x86-64?                       ,string?                       ,dummy-interp-x86-64)))

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
  (define output (with-handlers ([exn:fail? (λ (e) `(error ,(exn-message e)))])
                   (pass input)))
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
     (hash-set (hash-set h 'interp v) 'stdout stdout)]))

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
        (displayln (format "Satsifes input predicate: ~a" (yesno (hash-ref h 'satisfies-input-predicate))))
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

;; Walk over a trace and write it to a JSON expression
(define (trace->jsexpr trace)
  (map (λ (trace-element)
         (foldl (lambda (k a) (let ([v (hash-ref trace-element k)])
                                (if (string? v) a (hash-set a k (pretty-format v)))))
                trace-element
                (hash-keys trace-element)))
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
          (if (hash-has-key? h 'error)
              (reverse (cons h trace))
              (loop (cdr passes) (cdr names) (cdr in-preds) (cdr out-preds)
                    next-input (cdr interps) (cons h trace)))))))

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
  (define our-range (get-pass-range (start-pass) (end-pass)))
  (unless our-range ;; #f is invalid
    (error (format "Bad start/end pass range name (chose from {~a})" (string-join pass-names " "))))
  (define our-input-stream
    (if (input-file)
        (map string->number (file->lines (input-file)))
        (range 100)))
  (define interp-functions (slice-list interpreters our-range))
  (define interpreters-to-use
    (if (write-stdout-mode)
        interp-functions
        (map (λ (_) (λ (p in) "skipping interpretation...")) (range (length interp-functions))))) 
  ;; all of these defines used for verbose mode (to record each pass
  ;; and print its value)
  (let ([trace (run-chain source-tree
                          (slice-list passes our-range)
                          (slice-list pass-names our-range)
                          (slice-list input-predicates our-range)
                          (slice-list output-predicates our-range)
                          interpreters-to-use
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
;;
;; Returns either the trace or `(err ,trace) to indicate a trace that
;; failed in some fashion.
(define (run-assembler-linker source-tree)
  (displayln "Compiling IR (using *your* compile.rkt) …")
  ;; delete the ASM file so we can detect if it got generated
  (when (file-exists? (asm-file)) (delete-file (asm-file)))
  (define trace    (compile-verbose source-tree))
  ;; last pass generated output
  (if (and (equal? (last pass-names) (hash-ref (last trace) 'pass-name  "unknown"))
           ((last output-predicates) (hash-ref (last trace) 'output)))
      ((λ ()
         (define asm-text (hash-ref (last trace) 'output))
         ;; (a) ensure we start clean
         (with-output-to-file (asm-file) #:exists 'replace
           (λ () (displayln asm-text)))
         (displayln "BUILD BUILD BUILD  Now building a binary... BUILD BUILD BUILD ️")
         ;; host-specific settings
         (define os   (host-os))
         (define arch 'x86_64)
         (define tgt  (target-triple os arch))
         (define cc   (or (getenv "CC") "/usr/bin/clang"))
         (define target-flag      (if (string=? tgt "") "" (format "-target ~a" tgt)))
         (define common-cc-flags  "-Wall -O2")
         (define linux-extra (if (eq? os 'unix) "-no-pie" ""))
         (displayln (format "-> Host: ~a/~a  Target: ~a  Entry: ~a"
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
         (with-handlers ([exn:fail? (λ (e) (void))]) (delete-file (executable-file)))
         ;; execute each command
         (let loop ([cmds (list assemble-cmd assemble-runtime-cmd link-cmd)])
           (match cmds
             ['()
              ;; got to end of cmds, no executable...
              (begin (displayln (format "Error! Linker failed: ~a not produced" (executable-file)))
                     `(err ,trace))]
             [(cons cmd rest)
              (execute-get-output cmd)
              (if (file-exists? (executable-file))
                  (begin
                    (displayln (format "Success! Executable produced at: ~a" (executable-file)))
                    trace)
                  (loop rest))]))))
      (begin
        (displayln "Skipping assembly/linking (either no assembly or intentionally skipped)...")
        `(err ,trace))))

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
  [("-f" "--fast") "Skip interpretation / dumping, just compile"
                   (write-stdout-mode #f)]
  #:args leftover
  (match leftover
    ['()        (error 'main "expected a <filename>")]    
    [(list f)   f]
    [_          (error 'main "expected at most one <filename>")])))
  ;; run the assembler / linker
  (define source-tree (with-input-from-file file-name read))
  (match (run-assembler-linker source-tree)
    [`(err ,trace)
     (displayln "!!! ERROR CAUGHT !!!")
     (trace->stdout trace)]
    ;; all good
    [_ (void)]))

;; Parse the command line
(module+ main
  (main))
