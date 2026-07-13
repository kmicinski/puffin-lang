#!/bin/sh
# The Racket-free golden corpus harness -- puffincc + the bytecode VM
# as the GOLDEN AUTHORITY.
#
#   tools/test-corpus.sh [prog ...]        check every program (or just
#                                          the named ones) against
#                                          src/goldens
#   tools/test-corpus.sh gen [prog ...]    (re)WRITE the goldens the
#                                          same way
#
# For every program in src/test-programs (plain .scm/.puf files AND
# module directories containing a main.puf) x every src/input-files/*.in:
# compile with build/puffincc -t bytecode, run the unit on
# bin/puffin-vm with the input on stdin, and compare stdout+stderr
# (whitespace-trimmed, exactly like src/test.rkt's check!) against
# src/goldens/<prog>_<input>.golden. Pairs without a golden are
# skipped in check mode, mirroring test.rkt.
#
# Stdin convention (same as test.rkt input-ints): the input file's
# whitespace-separated integers, re-joined by single spaces, plus one
# trailing newline.
#
# gen mode writes the VM's raw stdout+stderr as the golden; programs
# whose compile or run FAILS are skipped with a loud "!! no golden"
# note (mirroring test.rkt's generate-goldens) -- those need
# attention, not silence.
#
# Environment:
#   GOLDENS_DIR    override the goldens directory (read in check mode,
#                  written in gen mode; default src/goldens). Useful
#                  for the differential proof: gen into a fresh dir
#                  and diff -r it against src/goldens.
#   PUFFIN_VM_BIN  name of the VM binary under bin/ (default
#                  puffin-vm; e.g. puffin-vm-gctest exercises the wasm
#                  GC seam natively, as in tools/gctest-corpus.sh).
#
# The Racket reference (racket src/test.rkt -m interp / -m gen) is the
# cross-checking ORACLE for these goldens: regenerating with it and
# diffing IS the differential test between the two implementations.
set -eu
cd "$(dirname "$0")/.."

TESTS=src/test-programs
INPUTS=src/input-files
GOLDENS=${GOLDENS_DIR:-src/goldens}
VM=bin/${PUFFIN_VM_BIN:-puffin-vm}
CC=build/puffincc

mode=check
if [ "${1:-}" = "gen" ]; then mode=gen; shift; fi

test -x "$CC" || {
  echo "tools/test-corpus.sh: $CC not found -- run bin/bootstrap (Racket-free)" >&2
  echo "or bin/build-puffincc (hosted) first" >&2
  exit 1
}
test -x "$VM" || make -C src/vm

# program names, exactly as test.rkt computes them: *.scm / *.puf
# files plus directories with a main.puf, extension stripped, sorted
progs=$(
  for f in "$TESTS"/*; do
    b=$(basename "$f")
    if [ -f "$f" ]; then
      case "$b" in (*.scm|*.puf) printf '%s\n' "${b%.*}" ;; esac
    elif [ -f "$f/main.puf" ]; then
      printf '%s\n' "$b"
    fi
  done | sort
)
# restrict to named programs, test.rkt-style
if [ $# -gt 0 ]; then progs=$(printf '%s\n' "$@"); fi

inputs=$(for f in "$INPUTS"/*.in; do b=$(basename "$f"); printf '%s\n' "${b%.in}"; done | sort)

# resolve a program name to its source path (test.rkt program-path)
prog_path() {
  if   [ -f "$TESTS/$1.scm" ];      then printf '%s' "$TESTS/$1.scm"
  elif [ -f "$TESTS/$1/main.puf" ]; then printf '%s' "$TESTS/$1/main.puf"
  else                                   printf '%s' "$TESTS/$1.puf"
  fi
}

# string-trim: strip leading/trailing whitespace (incl. newlines) from
# a shell value, POSIX parameter expansions only
trim() {
  t=$1
  t=${t#"${t%%[![:space:]]*}"}
  t=${t%"${t##*[![:space:]]}"}
  printf '%s' "$t"
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/puffin-corpus.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

# pre-normalize each input to test.rkt's stdin bytes
for i in $inputs; do
  # shellcheck disable=SC2046
  set -- $(cat "$INPUTS/$i.in")
  printf '%s\n' "$*" > "$tmp/in-$i"
done

checks=0
failures=0
[ "$mode" = gen ] && mkdir -p "$GOLDENS"

for prog in $progs; do
  src=$(prog_path "$prog")
  pbc="$tmp/$prog.pbc"
  if ! "$CC" -t bytecode "$src" -o "$pbc" > "$tmp/cc.out" 2>&1; then
    if [ "$mode" = gen ]; then
      echo "!! no golden (compile error): $prog: $(head -c 100 "$tmp/cc.out")"
    else
      checks=$((checks + 1)); failures=$((failures + 1))
      echo "FAIL [bytecode/compile] $prog/-"
      sed 's/^/  /' "$tmp/cc.out"
    fi
    continue
  fi
  for input in $inputs; do
    golden="$GOLDENS/${prog}_${input}.golden"
    if [ "$mode" = gen ]; then
      if "$VM" "$pbc" < "$tmp/in-$input" > "$tmp/run.out" 2>&1; then
        cat "$tmp/run.out" > "$golden"
      else
        echo "!! no golden (run error): $prog/$input: $(head -c 100 "$tmp/run.out")"
      fi
    else
      [ -f "$golden" ] || continue
      checks=$((checks + 1))
      "$VM" "$pbc" < "$tmp/in-$input" > "$tmp/run.out" 2>&1 || true
      got=$(trim "$(cat "$tmp/run.out")")
      want=$(trim "$(cat "$golden")")
      if [ "$got" != "$want" ]; then
        failures=$((failures + 1))
        echo "FAIL [bytecode] $prog/$input"
        echo "  expected: $want"
        echo "  got:      $got"
      fi
    fi
  done
done

if [ "$mode" = gen ]; then
  echo "goldens written to $GOLDENS ($(printf '%s\n' $progs | wc -l | tr -d ' ') programs x $(printf '%s\n' $inputs | wc -l | tr -d ' ') inputs)"
else
  echo "$checks checks, $failures failures"
  [ "$failures" -eq 0 ] || exit 1
fi
