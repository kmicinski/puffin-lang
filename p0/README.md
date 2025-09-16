# CIS531 -- Project 1 -- Stack Machine

In this project, we will not use the Autograder. It is due Sep 23,
2025. Please have your team (CC team members) submit to me via
email. Projects up to 3 days late incur a -15%; Projects up to the end
of the semester incur a -25%. Please submit promptly--I request you do
not get behind quite yet.

In this project, you will implement an interpreter for a
stack-oriented language. A program is an A-expression, giving a list
of commands wrapped in a '(program ...) block. The list of commands
enumerates a straight-line sequence of actions to be taken on a
_stack_, a LIFO data structure that is used for processing.

Stack-oriented languages have been common throughout the history of
computing, offering a simple alternative to named variables. Notable
examples include JVM bytecode, PostScript (used to generate graphics),
and Forth. Our language will have the following commands:

```
push i     # i is an integer
pop        # remove the top item from the stack
dup        # duplicate the last item on the stack
mul        # multiply the top two elements of the stack
add        # add the top two elements of the stack
sub        # subtract the second-to-top element from the top element
neg        # negate the top stack element
print      # print the top stack element to stdout
read       # read an integer into the top stack element
```

## Part 1 [20%] -- Parse files of these instructions to S-expressions

In this first part, you will take a file like this

```
push 5
push 7
mul
push 8
sub
print
read
read
mul
print
```

And you should turn them into S-expressions that correspond to the
`program?` predicate defined.

Grading: based on equal? with golden outputs. See `all-tests.sh`.


## Part 2 [40%] -- Stack-based interperter of `program?`

For this part, you will implement the `interp-cmds` function. This
function takes a list of commands, along with a current stack. The
stack is a Racket list, such that the top of the stack is the first
element of the list, and so on. Thus, you can always use `car` (or
`first`) to inspect the first element of the stack, and `cdr` or
`rest` to pop the first element. This function should be written to
(a) if the list of commands is empty, simply return `#t`, (b) if the
list of commands is *not* empty, then the function should execute one
command and then recursively call itself to handle the rest.

This function should be implemented in a tail-recursive style. In
other words, to make changes to the stack, you do not make any
mutations: instead, you use pure functions to construct a *new* stack
(e.g., the restult of `(rest ...)`) as a *parameter* passed to a
recursive invocation of the `interp-cmds` function. The *final* return
value will be `#t`, but the side effect will be reading from stdin/out
(by calling `(read)` and `(displayln ...)`).

Grading: Completely based on objective tests, given in `all-tests.sh`

## Part 3 [40%] -- Open-ended: Compiling infix programs to stack programs. 

In this last part, you will build a parser which accepts infix strings
as its input and returns valid `program?`s as its output. You will
also build testing infrastructure to convince me of the correctness of
your solution.

The input grammar is as follows:

```
Primary ::= INT | "(read)" | "(" "print" Expr ")" | "(" Expr ")"
Unary   ::= "-" Unary | Primary
# Important: *left* associativity for Prod/Sum (see class for trick)
Prod    ::= Unary ( "*" Unary )*
Sum     ::= Prod ( ("+" | "-") Prod )*
Expr    ::= Sum
```

Your job is to write a function: `(infix->program infix-string)` which:

- Accepts a `string?` as input, written in the infix language
  described above (see `infix-programs` for details).

- Produces a `program?`, which can easily be rendered to the .sp
  language

I have provided testcases for this part, which may be invoked via
test.rkt (see notes below). There are example infix test programs in
the `infix-programs/` subdirectory. 

Note that Prod and Sum need to left associate, i.e., `5 - 2 - 3` is
`(5 - 2) - 3` rather than `5 - (2 - 3)`. This is one place where LL(k)
parsers do not excel, and so the typical solution is to use a hack:
recognize a *list* of subordinate atoms (e.g., `("*" Unary )*`) and
then--once you have the list--build the right syntax tree. Ask if you
are confused about this, please.


## Testing your code

There is a file, test.rkt, which can be called at the command line in
one of three modes:

```
(define modes '("parse-stackprog" "interp-stackprog" "translate-infix"))
```

### Testing Part 1 (Parsing `.sp` files)

To test parsing, you use `parse-stackprog`, like this:

```
racket test.rkt -m parse-stackprog -g goldens/parse-pop-behavior.gld stackprogs/pop-behavior.sp
```

The `-m` flag specifies the parsing mode. The `-g` flag specifies the
*golden* (instructor-provided) output, and the last argument is the
program to test.

### Testing Part 2 (Interpreting `program?`)

To test interpretation, you also need an *input stream*, which is
basically an `stdin` that will be fed into the program. This is
important because our programs can `read` input. 

To test interpretation, you do this:

```
racket test.rkt -m interp-stackprog -g goldens/interp-sum-then-mul-5.gld -i input-streams/5.in stackprogs/sum-then-mul.sp
```

Here, the `-g` flag specifies the golden (in this case, the *expected*
output of the program) and the `-i` the requisite input stream,
followed by the program.

### Testing Part 3 (Translating Infix -> program?)

For this part, you need to specify an infix file. Examples are given
in the `infix-programs` directory. 

### Run all tests

Run the file `all-tests.sh`, which is simply a shell script which runs
each test with an expected golden input, etc.

## Submitting your solution

- Please use GitHub -- PRIVATE REPOS ONLY. You can collaborate with each other on GitHub.

- Please send me a .zip file containing your solution, and also
  showing the results of your testcases.

- Grading will be based on tests, using `alltests.sh`.

- I reserve the right to use my own tests (e.g., for due diligence
  purposes), but do not plan to add any extras at this time.

- Email me: kkmicins@syr.edu

## Hints and Advice

- I have tried to make the project testable, debuggable, etc. But it
  is the first time I have given it out. If you are concerned there is
  a bug, feel free to email me early, I can look into it.


