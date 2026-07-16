#!/bin/sh
# Run the examples/ programs and hold them to their .expect files, on
# both self-hosted routes (native and the bytecode VM). Racket-free,
# like tools/test-corpus.sh.
#
#   tools/test-examples.sh [name ...]     run all examples (or just the
#                                         named ones, e.g. "sudoku")
#
# Examples whose foreign library is absent on this machine are
# SKIPPED, not failed (the z3/ examples need `brew install z3`).
#
# Needs: build/puffincc (bin/bootstrap), bin/puffin-vm (make -C src/vm).
set -u
cd "$(dirname "$0")/.."

CC=build/puffincc
VM=bin/${PUFFIN_VM_BIN:-puffin-vm}
Z3=/opt/homebrew/lib/libz3.dylib

test -x "$CC" || {
  echo "tools/test-examples.sh: $CC not found -- run bin/bootstrap first" >&2
  exit 1
}
test -x "$VM" || make -C src/vm

tmp=$(mktemp -d "${TMPDIR:-/tmp}/puffin-examples.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

pass=0 fail=0 skip=0
for exp in examples/*/*.expect examples/*/*/*.expect; do
  [ -e "$exp" ] || continue
  puf=${exp%.expect}.puf
  name=$(basename "$puf" .puf)
  # module-dir example: the entry is <dir>/main.puf; report the dir name
  [ "$name" = main ] && name=$(basename "$(dirname "$puf")")
  if [ $# -gt 0 ]; then
    keep=0
    for want in "$@"; do [ "$want" = "$name" ] && keep=1; done
    [ $keep = 1 ] || continue
  fi
  case "$puf" in
    examples/z3/*) if [ ! -e "$Z3" ]; then
                     echo "SKIP $name (no $Z3 -- brew install z3)"
                     skip=$((skip + 1)); continue
                   fi ;;
  esac
  ok=1
  "$CC" "$puf" -o "$tmp/$name" >/dev/null 2>&1 &&
    "$tmp/$name" >"$tmp/$name.native.out" 2>&1 &&
    cmp -s "$exp" "$tmp/$name.native.out" || ok=0
  "$CC" -t bytecode "$puf" -o "$tmp/$name.pbc" >/dev/null 2>&1 &&
    "$VM" "$tmp/$name.pbc" >"$tmp/$name.vm.out" 2>&1 &&
    cmp -s "$exp" "$tmp/$name.vm.out" || ok=0
  if [ $ok = 1 ]; then
    echo "ok   $name (native + vm)"
    pass=$((pass + 1))
  else
    echo "FAIL $name"
    for leg in native vm; do
      if [ -f "$tmp/$name.$leg.out" ] && ! cmp -s "$exp" "$tmp/$name.$leg.out"; then
        echo "  $leg diff (expect vs got):"
        diff "$exp" "$tmp/$name.$leg.out" | sed 's/^/    | /' | head -20
      fi
    done
    fail=$((fail + 1))
  fi
done

echo "examples: $pass passed, $fail failed, $skip skipped"
[ $fail = 0 ]
