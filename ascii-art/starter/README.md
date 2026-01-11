# ASCII Art

**Due**: Tuesday, September 27th, 11:59PM.

In this project, you will parse and render ASCII art diagrams. The
point of this project is to (a) get you used to extending code others
(I) have written, (b) practice with recursion, and (c) to understand
the basic concept of (de)compilation to an intermediate
representation. In this project, we will consume ASCII art diagrams

```
.-----------------------------------------------------------------------------.
 |Es| |F1 |F2 |F3 |F4 |F5 | |F6 |F7 |F8 |F9 |F10|                  C= AMIGA   |
 |__| |___|___|___|___|___| |___|___|___|___|___|                             |
  _____________________________________________     ________    ___________   |
 |~  |! |" |§ |$ |% |& |/ |( |) |= |? |` || |<-|   |Del|Help|  |{ |} |/ |* |  |
 |`__|1_|2_|3_|4_|5_|6_|7_|8_|9_|0_|ß_|´_|\_|__|   |___|____|  |[ |]_|__|__|  |
 |<-  |Q |W |E |R |T |Z |U |I |O |P |Ü |* |   ||               |7 |8 |9 |- |  |
 |->__|__|__|__|__|__|__|__|__|__|__|__|+_|_  ||               |__|__|__|__|  |
 |Ctr|oC|A |S |D |F |G |H |J |K |L |Ö |Ä |^ |<'|               |4 |5 |6 |+ |  |
 |___|_L|__|__|__|__|__|__|__|__|__|__|__|#_|__|       __      |__|__|__|__|  |
 |^    |> |Y |X |C |V |B |N |M |; |: |_ |^     |      |A |     |1 |2 |3 |E |  |
 |_____|<_|__|__|__|__|__|__|__|,_|._|-_|______|    __||_|__   |__|__|__|n |  |
    |Alt|A  |                       |A  |Alt|      |<-|| |->|  |0    |. |t |  |
    |___|___|_______________________|___|___|      |__|V_|__|  |_____|__|e_|  |
                                                                              |
 -----------------------------------------------------------------------------'
```

We will transform this into an "intermediate representation:" a list
of triples, each specifying an X/Y coordinate along with a character
to be printed. For example, the following line:

```
 = . =
```

Is encoded in our representation as:

```
'((0 1 #\=) (0 3 #\.) (0 5 #\=))
```

You will implement a function, `draw-ascii-diagram`, which
subsequently renders these images. We (the instructors) have
implemented a function, `parse-ascii-diagram`, which *reads* ASCII art
pictures into the diagram format. Together, we can think of these as
forming a kind of (de)compiler: `parse-ascii-diagram` reads an ASCII
diagram into our internal format and your `draw-ascii-diagram` then
outputs an equivalent photo. In terms of the following diagram,
`output0` and `output1` must be equivalent.

```
    ASCII Text   ---  displayln --> output0
        |                             ||
parse-ascii-diagram                   ||
        |                            equal?
 draw-ascii-diagram		              ||
        |                             ||
	    +---------- displayln ---> output1
```

You are encouraged to read the beginning of `ascii.rkt` for a more
precise specification of the input format.

## Academic Integrity

The coding on this project is to be completed by you alone, without
help from any other students. You are encouraged to discuss the
project specification at a high level, but should not discuss
specifics or show students your solution code.

# Tasks

You will implement three functions; look for each usage of `TODO`. For
many functions, starter code is provided. You are allowed to change
the implementation (i.e., throw away) of any starter code if you find
it helps you, but the instructors discourage doing so.

- `(draw-ascii-line l)` -- Given an ASCII line (specified as a list of
  triples), draw the line. Assume that all characters are on the same
  line (i.e., ignore the line number). Returns a string, which will be
  printed by the testing infrastructure. This is *very* similar to the
  problem on exercise `e0`, but you must account for the line number
  (which you should ignore).

- `(newlines n)` -- which renders `n` newlines in a row; returns a
  string.

- `draw-ascii-diagram` -- which renders an entire diagram. Your
  solution should make use of the functions you have previously
  defined to accomplish its task. Ensure you handle corner cases like
  empty lines (no testcases will be provided which include trailing
  newlines)

I would start with `newlines`, it is the easiest. Then move on to
`draw-ascii-line`. Finally, read the code carefully and implement
`draw-ascii-diagram`. If confused, consult the in-class examples and
starter code, and ask clarifying questions on Zulip and in class.
	
# Testing

This project has 6 public tests and 5 secret tests. You are encouraged
to test your code piecemeal in the REPL using the public tests. You
are also encouraged to create your own tests, or even (hint) use the
tests provided in the `pictures` folder.

Once your code is working correctly, the `demo` function will work,
unlocking the ability to call `ascii.rkt` directly via the command
line to demo your solution. To do this type:

```
racket ascii.rkt pictures/1.txt
```

We have included a testing corpus of pictures in `pictures/*.txt`. You
may add more pictures, but do not remove or change the ones in those
starter files.

To run the testing infrastructure on your code, use `tester.py`. It is
invoked as follows:

```
[kmicinski] ascii-art % python3 tester.py
---------------------

Running test: public-draw-0
     PASSED
---------------------
...
---------------------

Running test: secret-draw-line-2
     PASSED

===========================
Summary: 11 / 11 tests passed
===========================
```

# Submitting your code for testing

**NOTE** Before you can submit your project for grading you *must* git
add, commit, and push. On a termainal (in your project directory)
type:

```
# Add all files in the directory
git add .
# Make a commit
git commit -m "my commit message here"
# Push to server
git push
```

Once you have done a git commit and push, go to the autograder and
select for your project to be graded.
