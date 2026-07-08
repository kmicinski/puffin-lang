;; ANSWER KEY

#lang racket
(provide (all-defined-out))

;;
;; CIS352 (Fall '22) Project 1 -- ASCII Art
;; 

;; To see the demo, invoke using:
;;     racket ascii.rkt <ascii-art>.txt

;; READ, DON'T EDIT

;; A point is specified as a list of length three containing an (0)
;; X-column-index, (1) Y-column-index, and (2) character to draw at
;; the specified X/Y coordinate position.
;;
;; For example, '(5 4 #\+) specifies the point at (5,4) in the diagram
;; is #\+.
(define (point-spec? pt)
  (match pt
    ;; points are lists of size three specifying a line, column, and
    ;; character to be printed
    [`(,(? nonnegative-integer? line) ,(? nonnegative-integer? column) ,(? char? char)) #t]
    [_ #f]))

;; a digram is a list of valid point-spec?s
(define (diagram-spec? l)
  (and (list? l) (andmap (lambda (x) (point-spec? x)) l)))

;; Takes a list of strings, returns an (ordered) diagram-spec?
;;
;; The basic idea is to walk over each line using a recursive function
;; which tracks a counter for the line number. Within that function,
;; we split up the string into its constituent characters using
;; string->list and use a *second* recursive walk over each character,
;; tracking the column number.
(define (parse-ascii-diagram lines)
  ;; parse a single line, characters is a list of char?s line-no
  ;; is current line number.
  (define (parse-line characters line-no)
    ;; for each character, chars is a list of char?s, col-no is
    ;; the number of the current column.
    (define (for-each-char chars col-no)
      (cond [(empty? chars) '()] ;; done, return
            [(equal? (first chars) #\space)
             ;; if the char is a space, skip it
             (for-each-char (rest chars) (add1 col-no))]
            [else
             (cons (list line-no col-no (first chars))
                   (for-each-char (rest chars) (add1 col-no)))]))
    (for-each-char characters 0))
  ;; for each line, lines-list is the rest of the lines, line-no is
  ;; current line number.
  (define (for-each-line lines-list line-no)
    (if (empty? lines-list)
        ;; we're done, return
        '()
        (let ([characters (string->list (first lines-list))]
              [rest-lines (rest lines-list)])
          (append (parse-line characters line-no)
                  (for-each-line rest-lines (add1 line-no))))))
  (for-each-line lines 0))

;; YOUR CODE HERE -- EDIT BEYOND THIS

;; helper: generate n spaces
(define (spaces n) (make-string n #\space))

;; Note: this is slightly different than the version in exercise e0,
;; but only superficially, a line number (which you should ignore) is
;; added.
;; 
;; Assume `l` is a (length-3) list of points (defined above) whose
;; first element is a line number, second element is the column
;; position, and third element is the character to be rendered at that
;; line/column pair. You will return a string representing the line.
;; 
;; Assume that all characters are on the same line--another function
;; will wrap this function.
;; 
;; Example:
;;    (draw-ascii-line '((3 3 #\=) (3 4 #\=) (3 5 #\=) (3 7 . #\.)
;;                       (3 9 #\=) (3 10 #\=) (3 11 #\=)))
;; > "   === . ==="
(define (draw-ascii-line l)
  ;; for each point
  (define (h l cur-pos)
    (if (empty? l)
      ""
      ;; else
      (let ([next-index (second (first l))]
            [next-char  (third (first l))]
            [rest-list  (rest l)])
        (string-append (spaces (- next-index cur-pos))
                       (make-string 1 next-char)
                       (h rest-list (add1 next-index))))))
  ;; assume input is sorted ascending on column number
  (h l 0))

;; Given a list of points, return the number of the next line. Assume
;; the list l is nonempty (calling this function on an empty list is
;; an error)
(define (line-number l)
  (first (first l)))

;; Given a list of points, grab the next "line" from the input, return
;; (a) the next line and (b) the rest of the input.
(define (grab-next-line points)
  ;; conceptually: recur over l, consing on the next element as long
  ;; as it is on the next line
  (define (h lst)
    (match lst
      ['() (cons '() '())]
      [`(,hd . ,rest) (if (equal? (first hd) (line-number points)) 
                          (let ([rest-ans (h rest)])
                            (cons (cons hd (car rest-ans)) (cdr rest-ans)))
                          (cons '() rest))]))
  (h points))

;; generate a string of n newlines in a row
(define (newlines n)
  (match n
    [0 ""]
    [n (string-append "\n" (newlines (- n 1)))]))

;; Draw a whole ASCII diagram, given as a list of point
;; specifications.
(define (draw-ascii-diagram diagram)
  (define (do-lines lst line-no)
    (if (empty? lst)
        ""
        (let* ([parsed-line (grab-next-line lst)]
           [next-line (car parsed-line)]
           [rest-list (cdr parsed-line)]
           [next-line-no (line-number next-line)])
          (string-append (newlines (- next-line-no line-no))
                         (draw-ascii-line next-line)
                         (do-lines rest-list next-line-no)))))
  (do-lines diagram 0))

;; DO NOT EDIT BELOW HERE 

(define (demo file)
  (define lines (file->lines file))
  (define input (string-join lines "\n"))
  (define diagram (parse-ascii-diagram lines))
  (define answer (draw-ascii-diagram diagram))
  (displayln "The input is:")
  (displayln input)
  (displayln "The decompiled diagram is:")
  (pretty-print diagram)
  (displayln "Rendering this diagram produces the following:")
  (displayln (draw-ascii-diagram diagram))) 

(define file
  (command-line
   #:program "ascii.rkt"
   #:args ([filename ""])
   filename))

;; if called with a single argument, this racket program will execute
;; the demo.
(if (not (equal? file "")) (demo file) (void)) 
