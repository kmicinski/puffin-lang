#lang racket

(provide (all-defined-out))

(define (command? c)
  (match c
    [`(push ,(? integer?)) #t]
    ['pop #t]
    ['mul #t]
    ['add #t]
    ['idiv #t]
    ['sub #t]
    ['neg #t]
    ['print #t]
    ['read #t]
    [_ #f]))

(define (program? p)
  (match p
    [`(program ,(? command?) ...) #t]
    [_ #f]))

;; Parses a string representation of the program (containing newlines)
;; and translate it into a program? for subsequent interpretation.
;; 
;; listof string? -> program?
;; 
;; Assume the program is well formed--no need to handle error states
(define (parse-stackprog p)
  (define cmds 'todo)
  `(program ,@cmds))

;; Given a list of remaining commands, and a stack, run each of the
;; commands, possibly reading from stdin (via (read)) and writing to
;; stdout (via displayln).
;;
;; Hint: write this function in a tail-recursive style, meaning that
;; you first match on cmds: when there are no commands left, the
;; program is done and you should exit (no output needed) by returning
;; #t from this function.
(define (interp-cmds cmds stack)
  (if (empty? cmds)
        #t
        (match (first cmds)
          [`(push ,i)
           (interp-cmds (rest cmds) (cons i stack))]
          ['pop
           'todo]
          ['mul
           'todo]
          ['add
           'todo]
          ['idiv
           'todo]
          ['sub
           'todo]
          ['neg
           'todo]
          ['print
           (displayln (first stack)) ;; print the top of the stack
           (interp-cmds (rest cmds) stack)]
          ['read
           'todo])))

;; Write a translator which parses an infix program (see the
;; README.md) for the acceptable grammar and translates the program
;; into a program in the stackprog `.sp` language. Your output should
;; be written to stdout, and it should be able to be run with some
;; input stream (examples are in `input-streams/`) to produce some
;; output stream.
;; 
;; Please *also* note that part of your grade is developing test
;; infrastructure in main.rkt. See the readme for the requirements. 
(define (infix->program infix-string)
  'todo)



