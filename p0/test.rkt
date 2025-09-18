#lang racket

(require "stack-machine.rkt")
(require json)

(define json-mode (make-parameter #f))
(define mode (make-parameter #f))
(define input-file (make-parameter #f))
(define golden (make-parameter #f))

(define modes '("parse-stackprog" "interp-stackprog" "translate-infix"))

;; Interpret a program, starting with the empty stack Assume that p
;; satisfies program?, read inputs (one integer followed by newline)
;; from stdin (i.e., using (read)). Write output using displayln.
;; 
;; Returns stdout
(define (test-interp-cmds p input-file)
  (define in-port (open-input-file input-file))
  (define out-port (open-output-string))
  (parameterize ([current-input-port in-port]
                 [current-output-port out-port])
    (match p
      [`(program ,cmds ...)
       ;; interpret in the empty stack
       (interp-cmds cmds '())]))
  (get-output-string out-port))

;; Convert an infix program into a program? by calling infix->program
;; in stack-machine.rkt. That function 
(define (test-infix ifx input-ints)
  (define p (infix->program ifx))
  (if (program? p)
      (displayln "YES -- translation satisfies program?")
      (displayln "NO -- translation *not* a program?"))
  (pretty-print p)
  (displayln "Interpreting...")
  ;; now, just call test-interp-cmds on the converted program
  (test-interp-cmds p input-ints))

;; parse the command line (using a racket library)
(define prog-file
  (command-line
   #:once-each
   [("-m" "--mode") m "Run tests in mode <m>" (mode m)]
   [("-i" "--in")   input "input file" (input-file input)]
   [("-g" "--gld") g "Golden (expected) output file" (golden g)]
   #:args rest-args (if (empty? rest-args) 'no-file (first rest-args))))

;; get all files in a directory as a list
(define (list-files dir)
  (for/list ([p (in-directory dir)]
             #:when (file-exists? p))
    p))

;; Abstract output to account for possible dumping to JSON

(define (pass message)
  (if (json-mode)
      (jsexpr->string (hash 'status "passed" 'message message))
      (displayln "✅ PASSED")))

(define (fail message)
  (if (json-mode)
      (jsexpr->string (hash 'status "failed" 'message message))
      (displayln message)))

;; Main entrypoint, run a test
(define (tests)
  (cond
    [(not (mode)) (displayln "error: must specify a mode")]
    ;;
    ;; Golden inputs (instructor use--but no reason you cannot read it)
    ;;
    [(equal? (mode) "gengoldens")
     ;; generate goldens for parse-stackprog -- used by the instructor
     (for ([file (list-files "stackprogs")])
       (define parts (string-split (path->string file) "/"))       
       (define fname (last parts))                  
       (define test-prog (first (string-split fname "."))) 
       (define golden-out (parse-stackprog (file->lines file)))
       (define fout (format "goldens/parse-~a.gld" test-prog))
       ;; write the golden for parse-stackprog
       (with-output-to-file fout
         (lambda () (displayln golden-out)) #:exists 'replace)
       ;; write the command line for parsing
       (displayln (format "racket test.rkt -m parse-stackprog -g ~a ~a" fout file))
       ;; for each input stream...
       (for ([input-stream (list-files "input-streams")])
         (define in-stem
           (first (string-split (last (string-split (path->string input-stream) "/")) ".")))
         (define fout (format "goldens/interp-~a-~a.gld" test-prog in-stem))
         (with-output-to-file fout
           (lambda () 
             (call-with-input-file input-stream
               (lambda (in)
                 (parameterize ([current-input-port in])
                   ;; actually *RUN* the program using interp-cmds
                   (match golden-out
                     [`(program ,cmds ...) (interp-cmds cmds '())])))))
           #:exists 'replace)
         ;; generate call to test.rkt for this program/input combination
         (define fmt-string "racket test.rkt -m interp-stackprog -g ~a -i ~a ~a")
         (displayln (format fmt-string fout input-stream file))))
     ;; now, for each infix program...
     (for ([infix-program (list-files "infix-programs")])
       (define in-stem
         (first (string-split (last (string-split (path->string infix-program) "/")) ".")))
       ;; for each input stream...
       (for ([input-stream (list-files "input-streams")])
         (define input-stream-stem
           (first (string-split (last (string-split (path->string input-stream) "/")) ".")))
         (define out-port (open-output-string))
         (define golden-file (format "goldens/infix-interp-~a-~a.gld" in-stem input-stream-stem))
         (displayln (format "racket test.rkt -m translate-infix -g ~a -i ~a ~a" golden-file input-stream infix-program))
         ;; Translate 
         (parameterize ([current-input-port (open-input-file input-stream)]
                        [current-output-port (open-output-file golden-file #:exists 'replace)])
           ;; now run...
           (match (infix->program (file->string infix-program))
             [`(program ,cmds ...)
              (interp-cmds cmds '())]))))]
    ;;
    ;; Parsing tests
    ;; 
    [(equal? (mode) "parse-stackprog")
     (unless prog-file
       (displayln "need a program file (last argument), input, and golden")
       (exit))
     (displayln (format "[test: parse-stackprog] Parsing stackprog ~a" prog-file))
     (let ([p (parse-stackprog (file->lines prog-file))]
           [gold (with-input-from-file (golden) read)])
       (if (equal? gold p)
           (pass "✅ PASSED -- matches golden")
           (fail
            (string-append "❌ FAILED -- does not match golden\n"
                           "You said the answer was:\n"
                           (pretty-format p)
                           "But this is wrong. The answer is:\n"
                           (pretty-print gold)))))]

    ;;
    ;; Interp tests 
    ;;
    [(equal? (mode) "interp-stackprog")
     (unless prog-file
       (displayln "need a program file (last argument), input, and golden")
       (exit))
     ;; INTERP TESTS
     (displayln (format "[test: interp-stackprog] Parsing stackprog ~a, Input file: ~a" prog-file (input-file)))
     (define p (parse-stackprog (file->lines prog-file)))
     (match p
       [`(program ,cmds ...)
        ;; get the program's output
        (define output (map string->number (string-split (test-interp-cmds p (input-file)))))
        ;; and golden output
        (define golden-output (map string->number (file->lines (golden))))
        (if (equal? output golden-output)
            (pass "✅ PASSED")
            (fail (string-append (format "Your output stream: ~a\tGolden output stream:~a"
                                         (pretty-format output)
                                         (pretty-format golden-output)))))])]
    
    ;;
    ;; Compile infix -> .sp mode
    ;;
    [(equal? (mode) "translate-infix")
     (displayln (format "[test: translate-infix] Parsing stackprog ~a, Input file: ~a, Golden: ~a" prog-file (input-file) (golden)))
     ;; Write a tester for your translator--see README.md
     (define p (infix->program (file->string prog-file)))
     ;; Prepend an error if fails predicate
     (define pre 
       (if (program? p)
           ""
           (pretty-format "ERROR: translated program does *not* satisfiy program?\nThe offending program is: ~a\n" p))) 
     (match p
       [`(program ,cmds ...)
        ;; get the program's output
        (define output (map string->number (string-split (test-interp-cmds p (input-file)))))
        ;; and golden output
        (define golden-out (with-input-from-file (golden) (λ () (for/list ([l (in-lines)]) (string->number l)))))
        (if (equal? output golden-out)
            (pass "✅ PASSED")
            (fail (format "~aYour output stream: ~a\tGolden output stream:~a" pre (pretty-format output) (pretty-format golden-out))))])]))

(module+ main (tests))
