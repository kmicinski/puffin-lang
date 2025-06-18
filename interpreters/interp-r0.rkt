#lang racket

;; 
;; CIS531 Fall '25 -- Interpreter for R0
;; Kris Micinski
;; 
;; Used in Lecture L1

(require racket/cmdline)

(provide (all-defined-out))

(define (e-R0? e)
  (match e
    [(? fixnum?) #t]
    ['(read) #t]
    [`(- ,(? e-R0? e)) #t]
    [`(+ ,(? e-R0? e0) ,(? e-R0? e1)) #t]
    [_ #f]))

(define (R0? e)
  (match e
    [`(program ,(? e-R0? e+)) #t]
    [_ #f]))

(define (interp-R0 e)
  (define (interp e)
    (match e
      [(? fixnum? n) n]
      ['(read) (read)]
      [`(- ,e+) (- (interp e+))]
      [`(+ ,e0 ,e1) (+ (interp e0) (interp e1))]))
  (match e
    [`(program ,e+) (interp e+)]))

(define file-path
  (command-line #:args (filename) filename))

(define source-tree
  (with-input-from-file file-path read))

(define (run-interp)
  (if (R0? source-tree)
      `(result ,(interp-R0 source-tree))
      `(error "not a valid source tree")))



