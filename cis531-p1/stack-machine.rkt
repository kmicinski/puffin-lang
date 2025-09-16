#lang racket

(require parser-tools/lex)
(require (prefix-in : parser-tools/lex-sre))
(provide (all-defined-out))

(define (command? c)
  (match c
    [`(push ,(? integer?)) #t]
    ['pop #t]
    ['mul #t]
    ['add #t]
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
  (define cmds
    'todo)
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
  'todo)

;; Write a translator which parses an infix program (see the
;; README.md) for the acceptable grammar and translates the program
;; into a program in the stackprog `.sp` language. Your output should
;; be written to stdout, and it should be able to be run with some
;; input stream (examples are in `input-streams/`) to produce some
;; output stream.
;; 
;; Please *also* note that part of your grade is developing test
;; infrastructure in main.rkt. See the readme for the requirements. 

;; I will provide a lexer for you--my solution builds a
;; recursive-descent parser which pulls from this token stream. You
;; may also consider using racket's yacc. However, I strongly
;; recommend writing a basic recursive-descent parser (I will cover
;; the tricks in class) for this assignment.
;;
;; You should simply use my lexer by calling the function
;; tokenize-string, which will return a list of tokens.

(define-lex-abbrev WS     (:+ (char-set " \t\r\n")))
(define-lex-abbrev DIGITS (:+ numeric))

(define expr-lexer
  (lexer
    [WS        (expr-lexer input-port)]
    ["+"       'PLUS]
    ["-"       'MINUS]
    ["*"       'TIMES]
    ["("       'LPAREN]
    [")"       'RPAREN]
    ["read"    'READ]
    ["print"   'PRINT]
    [DIGITS    `(INT ,(string->number lexeme))]
    [(eof)     'EOF]))

(define (tokenize-port in-port)
  (let loop ([acc '()])
    (define t (expr-lexer in-port))
    (if (eq? t 'EOF)
        (reverse (cons t acc))
        (loop (cons t acc)))))

;; Tokenize the string, turning it into a list of tokens.
(define (tokenize-string str) (tokenize-port (open-input-string str)))

;; (pretty-print (tokenize-port (open-input-string "3 + 3 * 5")))
;; (pretty-print (tokenize-string "3 + 3 * 5"))

;; Primary ::= INT | "(read)" | "(" "print" Expr ")" | "(" Expr ")"
(define (parse-Primary stream)
  'todo)

;; Unary ::= "-" Unary | Primary
(define (parse-Unary stream)
  'todo)

;; Product and Sum (left associate!)

;; Prod ::= Unary ( ("*" | "/") Unary )*
(define (parse-Prod stream)
  'todo)

;; Sum ::= Prod ( ("+" | "-") Prod )*
(define (parse-Sum stream)
  'todo)

(define (parse-Expr stream) (parse-Sum stream))

(define (parse-infix input-string)
  (define toks (tokenize-string input-string))
  ;; now call parse-Expr on it, etc..
  'todo)

;; Convert a string? written in the infix style 
(define (infix->program infix-string)
  ;; I recommend writing a function here, h, which translates the
  ;; result of parsing and lineraizes that into a sequence of
  ;; commands. Basic idea: for an operator like (+ e0 e1), generate a
  ;; list where you append the translation of e0 (a list of commands)
  ;; to the translation of e1, followed by an add instruction (which
  ;; consumes the previous two).
  (define (h expr)
    (match expr
      [(? number? n)
       `((push ,n))]
      [`(- ,expr)
       'todo]
      ;; other cases here...
      ))
  ;; Parse the infix program, which results in some intermediate
  ;; S-expression (like (+ 2 (* 3 4))) and then uses h to translate it
  ;; into a list of commands...
  `(program ,@(h (parse-infix infix-string))))
