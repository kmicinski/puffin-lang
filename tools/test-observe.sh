#!/bin/sh
# Observations (docs/STUDIO.md §3.1) end to end: `puffincc --repl
# --observe` units report their arguments to studio/observe.puf in a
# `puffin-vm --serve` session, and `(#%observations)` reads back the
# record the studio hands to `puffincc --assist --observed`.
#
#   tools/test-observe.sh
#
# Checks the record's shapes, that an observed function keeps its own
# tail calls (a million-iteration observed loop runs in constant
# space), that annotated and internal-define bodies survive the
# rewrite, that variadic defines are left alone, and that `--trace
# NAME` prints nested calls and returns (from the same runtime).
#
# Needs: build/puffincc (bin/bootstrap), bin/puffin-vm (make -C src/vm).

set -u
cd "$(dirname "$0")/.."
CC=${PUFFINCC:-build/puffincc}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

cat > "$tmp/types.puf" <<'PUF'
(define-type Shape (Circle Int) (Sq Int))
PUF
# each unit is checked alone, so a unit annotating with Shape carries
# its define-type, as the studio does (docs/STUDIO.md §2.2)
cat > "$tmp/defs.puf" <<'PUF'
(define-type Shape (Circle Int) (Sq Int))
(define (interp e env) (if (pair? e) (car e) e))
(define (area [s : Shape]) : Int
  (define (sq x) (* x x))
  (match s [(Circle r) (* 3 (sq r))] [(Sq k) (sq k)]))
(define (count-down n) (if (eq? n 0) 'done (count-down (- n 1))))
(define (sum . xs) (foldl + 0 xs))
PUF
cat > "$tmp/calls.puf" <<'PUF'
(interp '(add 1 2) '())
(interp 'x '((x . 1)))
(interp 42 '())
(interp "s" (list 1 2))
(area (Circle 2))
(area (Sq 3))
(count-down 1000000)
(sum 1 2 3)
PUF
echo '(#%observations)' > "$tmp/dump.puf"
cat > "$tmp/traced.puf" <<'PUF'
(define (fact n) (if (eq? n 0) 1 (* n (fact (- n 1)))))
PUF
echo '(fact 2)' > "$tmp/trace-call.puf"

"$CC" --repl-prelude -o "$tmp/prelude.pbc" &&
"$CC" --repl studio/observe.puf -o "$tmp/observer.pbc" &&
"$CC" --repl "$tmp/types.puf" -o "$tmp/types.pbc" &&
"$CC" --repl --observe "$tmp/defs.puf" -o "$tmp/defs.pbc" &&
"$CC" --repl "$tmp/calls.puf" -o "$tmp/calls.pbc" &&
"$CC" --repl "$tmp/dump.puf" -o "$tmp/dump.pbc" &&
"$CC" --repl --trace fact "$tmp/traced.puf" -o "$tmp/traced.pbc" &&
"$CC" --repl "$tmp/trace-call.puf" -o "$tmp/trace-call.pbc" || { echo "FAIL: compile"; exit 1; }

printf 'load %s\nload %s\nload %s\nload %s\nload %s\ntry %s\nload %s\nload %s\nquit\n' \
  "$tmp/prelude.pbc" "$tmp/observer.pbc" "$tmp/types.pbc" "$tmp/defs.pbc" \
  "$tmp/calls.pbc" "$tmp/dump.pbc" "$tmp/traced.pbc" "$tmp/trace-call.pbc" | bin/puffin-vm --serve 2>&1 | cat > "$tmp/out"
# (through cat: the process the shell waits on exits after the first
# successful load -- its child carries on as the session -- so only
# the pipe's last writer closing means the session is done)

check() {   # name, expected text (grep -F)
  if grep -qF -- "$2" "$tmp/out"; then echo "ok   $1"; else echo "FAIL $1: no '$2'"; fail=1; fi
}
check "results" "Rdone"
check "annotated body with internal define" "R12"
check "variadic define still runs" "R6"
check "interp shapes" "(interp 4 (((list add 3) (sym x) Int Str) (Nil Pair)))"
check "constructor shapes" "(area 2 (((adt Circle) (adt Sq))))"
check "a tail-recursive observed loop" "(count-down 1000001 ((Int)))"
check "trace: a call" "> (fact 2)"
check "trace: nested" "| | > (fact 0)"
check "trace: returns" "< 2"
if grep -q "(sum " "$tmp/out"; then echo "FAIL variadic define was observed"; fail=1; else echo "ok   variadic define not observed"; fi
if grep -q "ERR" "$tmp/out"; then echo "FAIL an evaluation failed:"; cat "$tmp/out"; fail=1; fi

[ $fail = 0 ] && echo "test-observe: all passed"
[ $fail = 0 ] || { echo "--- session output:"; cat -v "$tmp/out"; }
exit $fail
