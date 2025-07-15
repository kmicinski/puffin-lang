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

# Testcases and our testing methodology

In this project, we evaluate the following passes

- [ ] ANF conversion, via `interp-anf`
- [ ] Explicate control (conversion to C0)
- [ ] Conversion to pseudo-x86 (passes 6-9)
- [ ] Compilation to x86-64, linking, and testing the real binary

There are a number of example programs in the `example-programs`
subdirectory. There are also a number of example inputs in
`example-inputs/`. Each of these inputs is a text file with an integer
on each line: the integer is fed into the program, and unused inputs
are discarded (if a program never calls `(read)`, no inputs are
consumed).

This gives us a large set of things to test: 

[1, isolation] we can test passes in isolation (e.g., the conversion
to ANF) by using an instructor-provided input and running just your
specific functions. This avoids cumulative error, where an error in a
previous pass prevents a later pass from working. We call these tests
"isolation" tests, because they isolate a single pass and call your
code with instructor-provided inputs. The downside of this approach is
that it does not stress the end-to-end completeness of your compiler.

[2, compilation] By contrast, we can imagine running your whole
compiler, generating a binary, and running that binary against the
input stream (directing it to stdin), and we expect that the result is
that we get an output (stream) matching an expected "golden"
(instructor-provided) output. We call these "compilation" tests.

[3, consistency] Does each pass produce an equivalent value, when we
interpret its output?

[4, adheres to predicte?] Does the output of each pass adhere to the
predicates in `irs.rkt`?



# Using test.rkt

racket test.rkt r0-0.scm --in input-files/1.in,input-files/2.in,input-files/3.in --out goldens/r0-0-1.out,goldens/r0-0-1.out,goldens/r0-0-1.out
