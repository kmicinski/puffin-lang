# Project 5: Functions, Lambdas, and Closures

This is the final language that everyone in the class will
implement. We'll implement a language, R4, which includes functions
`(define (f ...) ...)` and `(lambda () ...)`, and application of
user-defined functions `(f ...)`.

## Input Language (R4/R5)

All students must implement the language R4, which extends our
language to include top-level (but not nested) `define`s. Compared to
R3 and the previous languages--where our program was a single
expression--our program now consists of a list of functions, followed
by a single "main" expression. When our program is compiled, we handle
this "main" expression a bit differently (we describe more below):

```racket
defn ::= (define (f x ...) e) ;; Fixed-arity top-level definitions
program ::= (program defn* e)
```

As an example of an R3 program...

```scheme
 (program
              (let* ([x (read)]
                     [i 0]
                     [acc 0])
                (begin
                  (while (< i x)
                         (begin
                           (set! acc (+ acc i))
                           (set! i (+ i 1))))
                  acc)))
```

The major extensions are these:

- We have a new literal, called `(void)`. This is sometimes called the
  "unit value," and carries no computational information, i.e.,
  control-flow never depends on the value of its contents; in an ideal
  world we would eliminate voids entirely via optimization, but their
  inclusion allows us to answer questions like: "what should
  vector-set! return?"

- Programs may allocate vectors using `(make-vector i)`, which zeros
  all entries of the vector. These get translated into calls to an
  allocation function in `runtime.c`.

- Programs may perform vector operations, but these operations are
  limited to constant indices (i.e., we can't compute the index that
  we want to write / read via `vector-ref`/`vector-set!`))--we may
  generalize this in subsequent projects. 

- *All* variables may be mutated via set!, our language is no longer
  pure. We handle this by "boxing" every variable, a process we
  describe below.


- Mutability goes hand-in-hand with loops, in the sense that mutable
  variables are not much fun unless you add loops. So we add a form,
  `(while e-g e-b)`, which continually evaluates the loop guard `e-g`
  and executes the body `e-b` (discarding its result) until the loop
  is finished. `(while ...)` reduces to `(void)`.

## Repository Layout

- `compile.rkt` – Your pass implementations. You will edit functions provided here.
  -> This is the *only* file you will edit! The rest are read-only
- `irs.rkt` – IR definitions and predicates like `anf-program?`, `c1-program?`, etc. (see also typed/shrunk variants)
- `interpreters.rkt` – Reference interpreters for several IRs (used by tests and for your own debugging).
- `system.rkt` – System/ABI configuration, pass names, runtime filenames, output paths, etc.
- `main.rkt` – Driver that runs all passes, can build a binary, and can launch a debug server.
- `test.rkt` – Test harness. Runs isolation tests or end-to-end native tests depending on `-m` mode.
- `runtime.c` – Minimal runtime (`read_int64`, `print_int64`, etc.).
- `test-programs/` – Example programs (`.scm`).
- `input-files/` – Input streams for programs (lines of integers).
- `goldens/` – Instructor goldens (IR snapshots, interpreter outputs, and stdout baselines).

Please do not rename files or directories (grading infra depends on them).

## The Compiler Pipeline (passes)

In this project, I skip typechecking; the compilation simply assumes
the program is type-correct. If the program is not type correct, it
may go wrong (segfault, etc.). Ensuring the program does not go wrong
may be accomplished a variety of ways (type checking, dynamic error
handling, etc.), and we will discuss these trade-offs in class.

You will implement the following passes:

2. `shrink` → remove binary `-`, `and`/`or`, and `<=, >, >=` (desugar to `eq?`/`<`)  
   Input: `R2?` → Output: `shrunk-R2?` → Interp: `interpret-R2`
3. `uniqueify` → ensure each bound identifier is written exactly once  
   Input: `shrunk-R2?` → Output: `unique-source-tree?` → Interp: `interpret-R2`
4. `anf-convert` → ANF conversion (introduce temps; maintain booleans/comparisons)  
   Input: `unique-source-tree?` → Output: `anf-program?` → Interp: `interpret-anf`
5. `explicate-control` → ANF → **C1** (blocks with `(seq (assign …) …)`, `if`/`goto`)  
   Input: `anf-program?` → Output: `c1-program?` → Interp: `interpret-c1`
6. `uncover-locals` → collect locals for stack layout  
   Input: `c1-program?` → Output: `locals-program?` → Interp: `interpret-c1`
7. `select-instructions` → C1 → pseudo-x86 (vars, `cmpq`, `set e|l`, `jmp-if e|l`)  
   Input: `locals-program?` → Output: `instr-program?` → Interp: `interpret-instr`
8. `assign-homes` → map `(var x)` → `(deref (reg rbp) n)`  
   Input: `instr-program?` → Output: `homes-assigned-program?` → Interp: `interpret-instr`
9. `patch-instructions` → fix illegal memory↔memory moves and related cases  
   Input: `homes-assigned-program?` → Output: `patched-program?` → Interp: `interpret-instr`
10. `prelude-and-conclusion` → prologue, print result, return 0  
    Input: `patched-program?` → Output: `x86-64?` → Interp: `interpret-instr`
11. `dump-x86-64` → render assembly text  
    Input: `x86-64?` → Output: `string?` → Interp: `dummy-interp-x86-64`

**What you implement**: All passes in `compile.rkt` are scaffolded.
Your job is to produce outputs that satisfy each predicate in
`irs.rkt` and that remain semantically equivalent (the interpreters
check this).

## Implementing `define`s and applications

The major innovation of this project is to enable functions at the top
level and (optionally) to perform lambda lifting. The most common
change that our compiler will face is this: in our previous IR, we had
an IR like `(program ,info ,code), where info and code got filled in
throughout the compilation to be increasingly lower-level--but at each
pass, we always matched with this pattern. But now, we can't do that
anymore--we need to generalize every pass. This sounds like a lot of
work, but generally it ends up amounting to changing our code from
something like this:

```
(match p
  [`(program ,info ,e)
   `(program ,info ,(process e))))
```

to something like this:

```
(define (per-defn defn)
  (match-defne defn `(define ,info (,f ,formals ...) ,code))
  `(define ,info (,f ,@formals) ,(process code)))
(match p
  [`(program ,info ,defns ...)
   `(program ,info ,(map per-defn defns))])
```

See what we did? We wrote a per-definition handler, `(per-defn ...)`,
which does the bulk of the processing that we did before--then, we
mapped over that per-definition function for each of the
definitions. This trick is very common is the best way to start
transforming your passes to accomodate definitions.

The `shrink` pass now assumes that the program has the structure
`(program (define (f ...) ...) ... e)`, and transforms it so that `e`
is wrapped in a special top-level `main` block (you should use
`(entry-symbol)`, as before). `e` may then call the functions being
defined, and its result is finally printed to the screen.

## "Boxing" and assignment-conversion

In this project we embrace mutability by enabling `set!`, which allows
us to make mutable updates to variables:

```
(program
 (let* ([x (read)]
        [y (read)]
        [tmp 0])
   (begin
     (set! tmp x)
     (set! x y)
     (set! y tmp)
     y)))
```

Notice that we can use `set!`, which mutably updates a variable; this
is not possible in "pure" functional programs, and mutation is simply
not provided in those languages (at least as a builtin). The question
is how to implement `set!`. It may seem like an obvious choice: each
variable becomes a single register-sized (8-byte) value on the
stack. However, this approach starts to fall apart when variables
outlive their stack frames (which will happen when we add functions /
procedures). Instead, we use this as an opportunity to discuss another
necessary challenge to work towards a general-purpose programming
language: heap-allocated data. You likely know about the heap from
programming in C with `malloc` (or C++ with `new`). These procedures
allow us to allocate memory from a large block of available memory
(the heap), with the obligation that we later release ("free") it back
to the operating system.

To enable mutability and `set!`, we will employ a technique called
"boxing." In short, we assume that _all_ data is put in a vector
("box") on the heap. In our case, we will use a very simple
representation of vectors:

```
typedef struct {
    int64_t len;
    int64_t data[];
} TinyVecPacked;
```

In terms of memory representation, a `TinyVecPacked` struct has a very
simple layout: a single 64-bit value representing the length, followed
by a data array of 8-byte values. For example, the vector containing
the sequence `5` followed by `20` (starting at the address `0xAAAA00`)
would be represented as:

```
   lower addresses →                                       higher addresses →
   ┌───────────────────────┬───────────────────────┬───────────────────────┐
   │  len (int64)          │  data[0] (int64)      │  data[1] (int64)      │ 
   │  8 bytes              │  8 bytes              │  8 bytes              │
   ├───────── ─ 0xAAAA00 ──┼────────── 0xAAAA08  ──┼──────── 0xAAAA10  ────┤
   │ e.g., 2               │ e.g., 5               │ e.g., 20              │
   └───────────────────────┴───────────────────────┴───────────────────────┘
```

The length can be used to avoid accesses outside of the buffer: we
don't want to be able to write outside of the bounds of a buffer
because it could contain junk data, we want to be able to write
outside of the bounds of a buffer because we could mess up *other*
data, unrelated to this vector (but still within our same address
space, assuming the OS provides virtual memory). To handle this, we
could take one of three positions:

(a) don't worry about it--just be unsafe, and let the program crash.

(b) check the bound before each access, if a bad access would occur,
jump to an exception handler.

(c) use a static type system to ensure this could never happen.

Each of these approaches has different trade offs: C, C++, and similar
languages opt for (a), which is fast but risky--the program might
crash in a subtle or even exploitable way. Managed languages like
Java, C#, etc. often opt for (b), but can sometimes optimize to avoid
checks if certain conditions are met (e.g., using profiling data and
just-in time compilation). The issue with (b) is that it is slow:
every single access necessitates a branch, compared with (a) which
might just be as simple as `movq`. Languages like Rust use (c), which
enables the benefits of (b) as a zero-cost abstraction, often matching
(or even exceeding) the performance of (a).

In this project we will do (a)/(b): 

## C2 

## IR Predicates and Interpreters

- **Predicates** (`irs.rkt`): Each pass has a precise predicate (e.g.,
  `anf-program?`, `c1-program?`, etc.). Tests check both input and
  output predicates at every step to catch malformed IR early. You
  should read and understand each predicate.

- **Interpreters** (`interpreters.rkt`): For many stages we run the
  interpreter over your IR to check semantic consistency—different IRs
  must compute the same result on the same input stream. The harness
  reports whether outputs match and whether stdout across passes is
  consistent. Please do not modify this file.

## How to Compile and Run

To directly compile a single file using `main.rkt`:

```
racket main.rkt test-programs/<prog>.scm
```

The compiler dumps a long summary of the work done at each pass, and
ultimately yields a program `./output` which it compiles using
system-specific infrastructure (works on Linux/Mac).

Example:

```
$ racket main.rkt test-programs/example.scm
Compiling IR (using *your* compile.rkt) …
'(pushq (reg rbp))
...
🏗️ Now building a binary... 🏗️
-> Host: macosx/x86_64  Target: x86_64-apple-darwin  Entry: main
/usr/bin/clang -target x86_64-apple-darwin -Wall -O2 -c ./output.s -o ./output.o
/usr/bin/clang -target x86_64-apple-darwin -Wall -O2 -c ./runtime.c -o ./runtime.o
/usr/bin/clang -target x86_64-apple-darwin -Wall -O2 ./output.o ./runtime.o -o ./output
Success! Executable produced at: ./output
Done!
$ ./output
42
```

Programs that `(read)` input will prompt or consume stdin. You can use
input redirection:  
`./output < input-files/1.in`

## Debugging Guide

This is a tricky project, and it is really important that you lean
into a debugging methodology that works for you. Let me share with you
some advice I used when I was writing the compiler myself.

- First, I started by writing a single manual test in the top-level of
  `compile.rkt`, so that I could easily just sit at the command line
  (or Dr. Racket) and run `compile.rkt` (with no command-line
  arguments) and see if the test would pass. At the early stages of
  debugging, this is an excellent strategy, since it means
  fully-pushbutton test. For example, I had (appended to
  `compile.rkt`) something like:

```
(displayln ;; or pretty-print 
 (dump-x86-64
  (prelude-and-conclusion
   (patch-instructions
    (assign-homes
     (select-instructions
      (uncover-locals
       (explicate-control
        (anf-convert
         (uniqueify
          (shrink
           (typecheck '(program (let ([a (read)])
                                  (let ([b (read)]) (if (or (> a b) (eq? (+ b 1) 0))
                                                        (+ a b)
                                                        (- b a)))))))))))))))))
```

- I started with a fairly large test in my case--since I was merely
  adding forms not present in my previous implementation. In this
  case, I would often be hitting match failures--this is a *good*
  thing, it allows me to trace down exactly where I need to add match
  cases and handle new behavior. Of course, the issue is that I also
  need to mix that with thinking holistically about the specs of each
  IR.

- After I thought I had each pass of the compiler working, I started
  switching over to `main.rkt`, which will run all passes of the
  compiler and will report their outputs. I also needed to write the
  interpreters (you do not), and so I debugged some of those using
  `main.rkt`.

- Last, once things are acutally working, I used `test.rkt`, which I
  adjusted to account for the possibility of expected type errors in
  malformed inputs.

- My advice to you is similar: start with something where you can
  press "Run" (or continually reinvoke `racket compile.rkt`). It will
  facilitate rapid testing, and it is really important to build some
  skill and intuition for how to accomplish that exercise.

- Remember, debugging is a key concept that you are practicing in this
  class. The worst possible thing you can do is "guess and check"
  debugging (running the tests and hoping they pass)--the issue is
  that doing this gives you very little observability into why the
  code is broken. To fix this, you need to have some way of
  interacting with the code. Experts debug their code using an
  iterative, hypothesis-driven methodology, where they (a) articulate
  a falsifiable hypothesis ("this match pattern never matches
  anything"), (b) change their code to observe the bug ("add a
  displayln at every match handler"), and (c) 

## Tricky Parts of this Project

**BE CAREFUL** of the following:

- In the event of a type error, raise `(error (type-error-tag) "Error here...")`

- In the previous implementation, we had only a single block, and
  `prelude-and-conclusion` sandwiched the generated code between code
  to set up the function and code to print the value and exit the
  function. In this case, that will not work so well. Instead, I
  recommend the following approach: in the `select-instructions` pass,
  assume the existence of a special block named `conclusion`, which
  assumes the return value (to be printed) is in `%rax`, and jump to
  that label. Then, in `prelude-and-conclusion`, add this label to the
  program with the right code to print the value of `%rax`. 

- On Mac OSX, you need to prefix labels for functions, meaning `_main`
  instead of `main`. To facilitate this, I provide a function `(rt-sym
  s)`, which converts a symbol to a system-specific variant (based on
  the OS). However, you only need to worry about this for labels that
  correspond to exported *function* entrypoints, not other labels that
  are internal to the program (e.g., the target of a jump, or even
  `conclusion`). This is important, because you don't want to call
  `(rt-sym ...)` until the *very last pass* (it is ugly to make the
  previous passes OSX/Linux-specific). The issue is this: if you
  naively rename every label from `foo` to `_foo`, then you also need
  to ensure that you clean up jumps so that instead of jumping to
  `foo`, they go to `_foo`. In my implementation, I handled this as
  follows: I simply used `(rt-sym ...)` on the `(entry-symbol)` (i.e.,
  `main`), which is the *only* function in this project.

- Ensure 16-byte stack alignment before `callq`

## Testing Infrastructure

The file `test.rkt` runs a set of formal tests, as in the last
project.

- `frontend` – runs `typecheck` → `anf-convert`, checks ANF via interpreter
- `middleend` – runs `explicate-control` → `uncover-locals`, checks via `interpret-c1`
- `backend` – runs `select-instructions` → `patch-instructions`, checks via `interpret-instr`
- `native` – full compile → build binary → run with stdin → compare stdout to golden

Usage:

```
racket test.rkt -m <mode> -i <comma-separated input files> -g <comma-separated goldens> <program.scm>
```

Example:

```
racket test.rkt -m native -i ./input-files/1.in -g goldens/example_1_uniqueify.stdout test-programs/example.scm
```

## Goldens: What They Are

We use goldens to verify correctness:

1. **Isolation goldens** – for non-native modes:
   - Compare serialized ASTs and interpreter stdout
2. **Native goldens** – for full pipeline:
   - Run your compiled binary, compare stdout

Layout:

- `goldens/<prog>_<n>_<pass>.in-ast`
- `goldens/<prog>_<n>_<pass>.out-ast`
- `goldens/<prog>_<n>_<pass>.interp`
- `goldens/<prog>_<n>_<pass>.stdout`

Instructor-only `gengoldens` mode regenerates these.

## FAQ

- **Do I need register allocation?**  
  No. Stack-based only.

- **Can I write helpers?**  
  Yes—keep pass signatures unchanged.

- **Can I call arbitrary C functions?**  
  No. Only use `read_int64` / `print_int64`.

- **How are inputs fed?**  
  Via stdin; `.in` files are whitespace-separated integers.

## Autograder Tests

The autograder invokes `test.rkt` in JSON mode. Your job is to make
each pass satisfy its predicates and produce semantically equivalent
IRs until final native code passes all tests.
