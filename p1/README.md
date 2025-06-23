# Project 1: LVar -> x86_64

This project is based on the text "Essentials of Compilation." Though
this project is spiritually very similar to the EoC book, the projects
have been completely reimplemented by me (mostly so that I could
prepare to teach the class and calibrate difficulty). I have made many
simplifications versus IU's infrastructure, which I will try to point
out. This is all to say: things may be slightly different than the
book, please read the whole README.

In this project, you will compile straight-line arithmetic (and user
input) to x86_64 assembly code.

# Input Language: LVar

The input language goes by several names: LVar and R1. It is a very
simple language:

```
;; The R1 language--the source language which will be the input to
;; your project.
(define (R1-exp? e)
  (match e
    [(? fixnum? n) #t]
    [`(read) #t]    
    [`(- ,(? R1-exp? e)) #t]
    [`(+ ,(? R1-exp? e0) ,(? R1-exp? e1)) #t]
    [(? symbol? var) #t]
    [`(let ([,(? symbol? x) ,(? R1-exp? e)]) ,(? R1-exp? e-body)) #t]
    [_ #f]))

;; An R1 program is an R1 expression
(define (R1? e)
  (match e
    [`(program ,(? R1-exp? exp)) #t]
    [_ #f]))
```




