#!/bin/sh
# Hold `puffin-vm --serve` (docs/STUDIO.md §2.2) to its protocol: a
# long-lived REPL session that forks per evaluation and survives
# runtime errors, interrupts, and bad input.
#
#   tools/test-vm-serve.sh
#
# Checks, against exact expected stdout:
#   - results (\x1fR), terminators (\x1fOK / \x1fERR n / \x1fINT), and
#     program output ordered before its terminator, with a partial
#     line ended before a marker;
#   - the session survives a runtime error, a corrupt or unreadable
#     unit, and an unknown command;
#   - redefinition across units is retroactive; `try` discards its
#     defines; a unit's read-line sees end of input, not protocol;
#   - a burst of commands written at once is read correctly across
#     the fork lineage;
#   - an infinite loop interrupted with SIGINT to the process group
#     (in load and in try) leaves the session intact, and a SIGINT
#     to an idle session is ignored;
#   - 300+ evaluations with allocation-heavy units that collect in
#     every generation keep the session data intact and leave exactly
#     one process in the group (no zombies, no strays).
#
# Needs: build/puffincc (bin/bootstrap), bin/puffin-vm (make -C src/vm).

set -u
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
pid=
cleanup() {
  exec 3>&- 2>/dev/null
  [ -n "$pid" ] && kill -s KILL -- "-$pid" 2>/dev/null
  if [ "$fails" -eq 0 ]; then rm -rf "$tmp"; else echo "kept $tmp"; fi
}
trap cleanup EXIT

fails=0
US=$(printf '\037')

fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# unit NAME LINE...: compile the lines as one REPL unit, $tmp/NAME.pbc
unit() {
  name=$1; shift
  printf '%s\n' "$@" > "$tmp/$name.puf"
  build/puffincc --repl "$tmp/$name.puf" -o "$tmp/$name.pbc" \
    || { echo "cannot compile unit $name"; exit 1; }
}

# The protocol bytes, made visible: \x1f -> '#', \x1e -> '~'.
show() { tr '\037\036' '#~' < "$1"; }

# check NAME EXPECTED-FILE ACTUAL-FILE
check() {
  if show "$3" | diff -u "$2" - > "$tmp/diff"; then
    echo "ok   $1"
  else
    fail "$1"
    cat "$tmp/diff"
  fi
}

# group_count PGID: live processes in the group, zombies counted too
group_count() { ps -A -o pgid= | awk -v g="$1" '$1 == g' | wc -l | tr -d ' '; }

build/puffincc --repl-prelude -o "$tmp/prelude.pbc" || exit 1
unit sqdef '(define (sq x) (* x x))'
unit sq7   '(sq 7)'
unit sq9   '(sq 9)'
unit sq3   '(sq 3)'
unit boom  '(car (ann 5 _))'
unit oops  '(println "before")' '(error "oops")'
unit out   '(println "hi")' '(display "partial")' '(sq 2)' '"a' 'b"' '(display "tail")'
unit fdef1 '(define (f) 1)'
unit gdef  '(define (g) (f))'
unit fdef2 '(define (f) 2)'
unit gcall '(g)'
unit tdef  '(define tval 5)' 'tval'
unit tuse  'tval'
unit rl    '(read-line)'
unit c0    '(define c 0)'
unit cinc  '(define c (+ c 1))'
unit cshow 'c'
unit spin  '(println "spinning")' '(let loop () (loop))'
unit big   '(define big (range 0 100000))'
unit churn '(define (churn k) (if (< k 1) 0 (begin (length (range 0 50000)) (churn (- k 1)))))' \
           '(churn 40)' '(foldl + 0 big)'
printf '(+ 1 2)\n' > "$tmp/v1.puf"
build/puffincc -t bytecode "$tmp/v1.puf" -o "$tmp/v1.pbc" || exit 1
printf 'not a unit' > "$tmp/garbage.pbc"
: > "$tmp/empty.pbc"
head -c 40 "$tmp/sq7.pbc" > "$tmp/trunc.pbc"
mkdir "$tmp/dir.pbc"

# ---- 1. one burst of commands on a pipe -----------------------------
{
  echo "load $tmp/prelude.pbc"
  echo "load $tmp/sqdef.pbc"
  echo "load $tmp/sq7.pbc"
  echo "load $tmp/boom.pbc"
  echo "load $tmp/sq9.pbc"
  echo "load $tmp/oops.pbc"
  echo "try $tmp/sq3.pbc"
  echo "load $tmp/out.pbc"
  echo "load $tmp/fdef1.pbc"
  echo "load $tmp/gdef.pbc"
  echo "load $tmp/gcall.pbc"
  echo "load $tmp/fdef2.pbc"
  echo "load $tmp/gcall.pbc"
  echo "try $tmp/tdef.pbc"
  echo "load $tmp/tuse.pbc"
  echo "load $tmp/rl.pbc"
  echo ""
  echo "frobnicate"
  echo "load $tmp/missing.pbc"
  echo "load $tmp/dir.pbc"
  echo "load $tmp/garbage.pbc"
  echo "load $tmp/empty.pbc"
  echo "try $tmp/trunc.pbc"
  printf 'load %s\r\n' "$tmp/sq3.pbc"
  echo "load $tmp/v1.pbc"
  echo "load $tmp/sq9.pbc"
  echo "quit"
  echo "load $tmp/sq7.pbc"
} > "$tmp/burst.in"
cat > "$tmp/burst.expect" <<'EOF'
#OK
#OK
#R49
#OK
#ERR 255
#R81
#OK
before
error: oops
#ERR 1
#R9
#OK
hi
partial
#R4
#Ra~b
tail
#OK
#OK
#OK
#R1
#OK
#OK
#R2
#OK
#R5
#OK
#ERR 255
#R#f
#OK
#ERR 2
#ERR 2
#ERR 2
#ERR 255
#ERR 255
#ERR 255
#R9
#OK
3
#OK
#R81
#OK
#OK
EOF
# The process the shell started exits once a load succeeds (its child
# carries on as the session), so wait on the pipe, as a server does:
# `| cat` ends when the last session process closes stdout.
bin/puffin-vm --serve < "$tmp/burst.in" 2> "$tmp/burst.err" | cat > "$tmp/burst.out"
check "burst: results, errors, bad input, try, redefinition" "$tmp/burst.expect" "$tmp/burst.out"
grep -q 'tval: undefined' "$tmp/burst.err" || fail "burst: try leaked its define (no tval error)"
grep -q 'unknown command: frobnicate' "$tmp/burst.err" || fail "burst: no unknown-command message"

# End of input ends the session.
echo "load $tmp/prelude.pbc" | bin/puffin-vm --serve 2>&1 | cat > "$tmp/eof.out"
printf '#OK\n' > "$tmp/eof.expect"
check "eof: ends the session" "$tmp/eof.expect" "$tmp/eof.out"

# A session that never handed off exits 0 on quit.
printf 'load %s\nquit\n' "$tmp/boom.pbc" | bin/puffin-vm --serve > "$tmp/quit.out" 2>/dev/null
status=$?
printf '#ERR 255\n#OK\n' > "$tmp/quit.expect"
check "quit: from the first session process" "$tmp/quit.expect" "$tmp/quit.out"
[ $status -eq 0 ] || fail "quit: exit status $status, want 0"

# ---- 2. interrupts, then many evaluations ---------------------------
mkfifo "$tmp/in"
GC_PRINT_STATS=1 bin/puffin-vm --serve < "$tmp/in" > "$tmp/live.out" 2> "$tmp/live.err" &
pid=$!
exec 3> "$tmp/in"
send() { printf '%s\n' "$1" >&3; }

# await N: wait (up to 60 s) until N terminator lines have arrived
await() {
  i=0
  while [ "$(grep -E -c "^${US}(OK|ERR|INT)" "$tmp/live.out")" -lt "$1" ]; do
    i=$((i + 1))
    if [ $i -gt 600 ]; then fail "timeout waiting for terminator $1"; show "$tmp/live.out" | tail -5; exit 1; fi
    sleep 0.1
  done
}
# await_spin N: wait until the Nth "spinning" line (a loop is running)
await_spin() {
  i=0
  while [ "$(grep -c '^spinning$' "$tmp/live.out")" -lt "$1" ]; do
    i=$((i + 1))
    if [ $i -gt 600 ]; then fail "timeout waiting for spin $1"; exit 1; fi
    sleep 0.1
  done
}

send "load $tmp/prelude.pbc"
send "load $tmp/sqdef.pbc"
await 2
wait "$pid" 2>/dev/null   # the first session process exits once a load succeeds
send "load $tmp/spin.pbc"
await_spin 1
kill -s INT -- "-$pid"
await 3
send "load $tmp/sq3.pbc"
await 4
send "try $tmp/spin.pbc"
await_spin 2
kill -s INT -- "-$pid"
await 5
kill -s INT -- "-$pid"    # idle: ignored
sleep 0.2
send "load $tmp/sq9.pbc"
await 6
cat > "$tmp/int.expect" <<'EOF'
#OK
#OK
spinning
#INT
#R9
#OK
spinning
#INT
#R81
#OK
EOF
check "interrupt: load and try loops, idle SIGINT ignored" "$tmp/int.expect" "$tmp/live.out"

# 300+ evaluations: counter loads, failing trys, allocation-heavy
# loads and trys over a retained 100000-element list.
: > "$tmp/many.in"
: > "$tmp/many.expect"
echo "load $tmp/c0.pbc" >> "$tmp/many.in"
echo "load $tmp/big.pbc" >> "$tmp/many.in"
printf '#OK\n#OK\n' >> "$tmp/many.expect"
n=0
i=1
while [ $i -le 210 ]; do
  echo "load $tmp/cinc.pbc" >> "$tmp/many.in"; echo '#OK' >> "$tmp/many.expect"
  if [ $((i % 3)) -eq 0 ]; then
    echo "try $tmp/boom.pbc" >> "$tmp/many.in"; echo '#ERR 255' >> "$tmp/many.expect"
  fi
  if [ $((i % 7)) -eq 0 ]; then
    if [ $((i % 14)) -eq 0 ]; then verb=load; else verb=try; fi
    echo "$verb $tmp/churn.pbc" >> "$tmp/many.in"
    printf '#R0\n#R4999950000\n#OK\n' >> "$tmp/many.expect"
  fi
  if [ $((i % 10)) -eq 0 ]; then
    echo "try $tmp/cshow.pbc" >> "$tmp/many.in"; printf '#R%d\n#OK\n' $i >> "$tmp/many.expect"
  fi
  i=$((i + 1))
done
echo "load $tmp/cshow.pbc" >> "$tmp/many.in"; printf '#R210\n#OK\n' >> "$tmp/many.expect"
total=$(wc -l < "$tmp/many.in" | tr -d ' ')
before=$(wc -c < "$tmp/live.out" | tr -d ' ')
cat "$tmp/many.in" >&3
await $((6 + total))
tail -c +$((before + 1)) "$tmp/live.out" > "$tmp/many.out"
check "many: $total evaluations in one session" "$tmp/many.expect" "$tmp/many.out"
procs=$(group_count "$pid")
[ "$procs" -eq 1 ] || { fail "many: $procs processes in the session group, want 1"; ps -A -o pid,ppid,pgid,stat,command | awk -v g="$pid" '$3 == g'; }
gcs=$(grep -c '^GC #' "$tmp/live.err")
if [ "$gcs" -ge 50 ]; then echo "ok   many: $gcs collections across the fork lineage"; else fail "many: only $gcs collections; the churn units should collect"; fi

send quit
exec 3>&-
i=0
while [ "$(group_count "$pid")" -gt 0 ]; do
  i=$((i + 1))
  if [ $i -gt 100 ]; then fail "quit: the session did not exit"; break; fi
  sleep 0.1
done
tail -n 1 "$tmp/live.out" | tr '\037' '#' | grep -q '^#OK$' || fail "quit: no #OK"
pid=

if [ $fails -ne 0 ]; then
  echo "test-vm-serve: $fails failure(s)"
  exit 1
fi
echo "test-vm-serve: all passed"
