#!/bin/sh
# The DIFFERENTIAL ERROR CORPUS -- rejection behavior, corpus-tested.
#
# The golden corpus (tools/test-corpus.sh) contains only PASSING
# programs, so the routes could silently disagree about ERROR
# behavior (the class of bug behind the runaway `#<unknown:0>`
# incident: unbound variables compiled into 0-seeded cells that the
# VM dispatched as function index 0). This harness is the systematic
# net: every must-fail program in src/errors-corpus/ is driven down
# EVERY route, and the diagnostic bytes must agree.
#
#   tools/test-errors.sh [case ...]        check every case (or just the
#                                          named ones)
#   tools/test-errors.sh gen [case ...]    capture .expect files from the
#                                          routes' AGREED output; refuses
#                                          when the routes disagree (that
#                                          IS the differential test firing)
#
# Case layout (src/errors-corpus/):
#   NAME.puf              a single-file must-fail program
#   NAME/                 a module-DAG must-fail program (entry main.puf)
#   NAME.expect           the exact expected diagnostic text (the entire
#                         stdout+stderr of a route, trimmed + normalized)
#   NAME.expect.<route>   per-route override for a TRIAGED, documented
#                         divergence (see "Known route variance" below);
#                         routes: interp rkt-vm pcc-vm rkt-native
#                         pcc-native pcc
#   NAME.flags            optional directives, one per line:
#                           strict          pass --strict-types everywhere
#                                           (warning-promotion cases)
#                           interp-exit-ok  accept exit 0 from the
#                                           reference interpreter (the
#                                           (error ...) class: the interp
#                                           prints the error and exits 0
#                                           by golden-parity design)
#
# A case is CLASSIFIED by compiling it with both compilers (bytecode
# target). Both reject -> a compile-time case; both accept -> a
# runtime case; they disagree -> the case FAILS loudly (a compiler
# admitted a program the other rejects -- the headline differential).
#
# Compile-time case legs (must all exit nonzero):
#   interp       bin/puffin -i          message on stderr   [text+exit]
#   rkt-bc       bin/puffin -c -t bytecode                  [exit only]
#   rkt-native   bin/puffin -c                              [exit only]
#   pcc-bc       build/puffincc -t bytecode  msg on stdout  [text+exit]
#   pcc-native   build/puffincc              msg on stdout  [text+exit]
# The two rkt compile legs are exit-only because the bin/puffin -c
# CLI swallows the front end's error text (src/puffin.rkt compile-to
# drops the (err ...) payload -- a known CLI bug); the SAME front end
# (read-program-file + desugar/typecheck) runs under -i, so the
# message bytes are asserted there. `racket src/main.rkt` was also
# investigated: it surfaces the text but exits 0 on caught pass
# errors, so it cannot anchor the exit assertion either.
#
# Runtime case legs (each must print the expected bytes and exit
# nonzero -- interp exit 0 tolerated only under interp-exit-ok):
#   interp       bin/puffin -i prog.puf
#   rkt-vm       bin/puffin -c -t bytecode + bin/puffin-vm
#   pcc-vm       build/puffincc -t bytecode + bin/puffin-vm
#   rkt-native   bin/puffin -c + run the binary
#   pcc-native   build/puffincc + run the binary
#
# Text comparison: a route's stdout and stderr are CONCATENATED
# (compile errors land on stderr for the Racket CLI but on stdout for
# puffincc -- pf_error prints to stdout by design, for golden parity;
# the message BYTES are what must agree), trimmed of trailing
# whitespace, and normalized by stripping the absolute repo-root
# prefix (the Racket resolver absolutizes module paths in messages;
# puffincc spells them as given -- relative to the repo root, which
# is where this harness runs everything, puffincc's --runtime default
# requires it). After that ONE normalization the comparison is
# byte-exact against the whole .expect file.
#
# Known route variance the overrides carry (each is a caught, triaged
# divergence -- see the .expect.interp files):
#   * the reference interpreter leaks raw Racket contract errors for
#     most prim contract violations (car/vector-ref/quotient/...)
#     where all four compiled routes share pf_fatal's
#     "puffin runtime error: ..." text;
#   * interp renders fatal errors raised via Racket exceptions with an
#     "error: " prefix and exit 1 where compiled routes say
#     "puffin runtime error: ..." with exit 255 (division by zero);
#   * the two READERS spell syntax errors differently (Racket
#     read-syntax positions vs puffincc's reader-unexpected-closer);
#   * the (error ...) class (match-failure, user error) prints on
#     stdout everywhere but the interp exits 0 (interp-exit-ok).
#
# Overlap note: this corpus deliberately subsumes cases from
# src/test-types.rkt (checker verdicts, Racket-only), src/test-casts.rkt
# (cast blame), src/test-arith.rkt (checked arithmetic) and
# src/test-modules.rkt (resolver errors) -- those suites remain and
# still run; this harness adds the systematic every-case-every-route
# matrix. REPL error behavior is OUT OF SCOPE here (REPL units are
# link-by-name, late-bound; web/repl-golden.json pins that surface).
#
# Needs: build/puffincc (bin/bootstrap or bin/build-puffincc),
# bin/puffin-vm (make -C src/vm), and Racket for the oracle legs.
set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)

CASES=src/errors-corpus
VM=bin/${PUFFIN_VM_BIN:-puffin-vm}
CC=build/puffincc
PUF=bin/puffin

mode=check
if [ "${1:-}" = "gen" ]; then mode=gen; shift; fi

test -x "$CC" || {
  echo "tools/test-errors.sh: $CC not found -- run bin/bootstrap (Racket-free)" >&2
  echo "or bin/build-puffincc (hosted) first" >&2
  exit 1
}
test -x "$VM" || make -C src/vm

tmp=$(mktemp -d "${TMPDIR:-/tmp}/puffin-errors.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

# ---------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------

# remove every occurrence of "$ROOT/" (exact string) from stdin
strip_root() {
  awk -v pat="$ROOT/" '{
    out=""; s=$0
    while ((i = index(s, pat)) > 0) { out = out substr(s,1,i-1); s = substr(s, i+length(pat)) }
    print out s
  }'
}

# run a leg: run_leg <prefix> <cmd...>; captures out/err/exit code
run_leg() {
  _pfx=$1; shift
  "$@" >"$_pfx.out" 2>"$_pfx.err" </dev/null
  echo $? >"$_pfx.ec"
}

leg_text() { cat "$1.out" "$1.err" | strip_root; }
leg_ec()   { cat "$1.ec"; }

# expect_file <case> <route> -> path of the governing .expect ("" if none)
expect_file() {
  if   [ -f "$CASES/$1.expect.$2" ]; then printf '%s' "$CASES/$1.expect.$2"
  elif [ -f "$CASES/$1.expect" ];    then printf '%s' "$CASES/$1.expect"
  fi
}

has_flag() { [ -f "$CASES/$1.flags" ] && grep -qx "$2" "$CASES/$1.flags"; }

# case list: *.puf files + directories with a main.puf, sorted
all_cases() {
  for f in "$CASES"/*; do
    b=$(basename "$f")
    if [ -f "$f" ]; then
      case "$b" in (*.puf) printf '%s\n' "${b%.puf}" ;; esac
    elif [ -f "$f/main.puf" ]; then
      printf '%s\n' "$b"
    fi
  done | sort
}

case_src() {
  if [ -f "$CASES/$1.puf" ]; then printf '%s' "$CASES/$1.puf"
  else printf '%s' "$CASES/$1/main.puf"; fi
}

cases=$(all_cases)
[ $# -gt 0 ] && cases=$(printf '%s\n' "$@")

legs_total=0
legs_failed=0
cases_failed=0
gen_refused=0

# per-leg check: text (against expect file) and exit-nonzero
#   check_leg <case> <legname> <prefix> <route-key> <text?> <exit0ok?>
# appends " name:mark" to $marks; mark: ok / ok~ (override) / ox (exit
# only) / FAIL
check_leg() {
  _case=$1; _leg=$2; _p=$3; _route=$4; _text=$5; _exit0ok=$6
  legs_total=$((legs_total + 1))
  _ec=$(leg_ec "$_p")
  _mark=ok
  _fail=""
  if [ "$_ec" -eq 0 ] && [ "$_exit0ok" != yes ]; then
    _fail="expected a nonzero exit, got 0"
  fi
  if [ -z "$_fail" ] && [ "$_text" = yes ]; then
    _ef=$(expect_file "$_case" "$_route")
    if [ -z "$_ef" ]; then
      _fail="no .expect file (run gen mode)"
    else
      _got=$(leg_text "$_p")
      _want=$(cat "$_ef")
      if [ "$_got" != "$_want" ]; then
        _fail="text mismatch"
      elif [ "$_ef" != "$CASES/$_case.expect" ]; then
        _mark="ok~"
      fi
    fi
  fi
  [ "$_text" = yes ] || _mark=ox
  if [ -n "$_fail" ]; then
    legs_failed=$((legs_failed + 1))
    _mark=FAIL
    case_bad=1
    {
      echo "  FAIL [$_leg] $_case: $_fail (exit $_ec)"
      if [ "$_fail" = "text mismatch" ]; then
        echo "    expected ($_ef):"
        sed 's/^/    | /' "$_ef"
        echo "    got:"
        leg_text "$_p" | sed 's/^/    | /'
      else
        leg_text "$_p" | head -5 | sed 's/^/    | /'
      fi
    } >>"$tmp/case-report"
  fi
  marks="$marks $_leg:$_mark"
}

# gen: collect a text leg into the agreement set unless overridden
#   gen_leg <case> <legname> <prefix> <route-key>
gen_leg() {
  _case=$1; _leg=$2; _p=$3; _route=$4
  if [ -f "$CASES/$_case.expect.$_route" ]; then
    echo "  note: $_leg keeps its hand-written override ($_case.expect.$_route)"
    return
  fi
  leg_text "$_p" >"$tmp/gen-$_leg"
  gen_set="$gen_set $_leg"
}

# ---------------------------------------------------------------------
# the drive loop
# ---------------------------------------------------------------------

for c in $cases; do
  src=$(case_src "$c")
  if [ ! -f "$src" ]; then
    echo "?? no such case: $c" >&2
    cases_failed=$((cases_failed + 1))
    continue
  fi
  t="$tmp/$c"; mkdir -p "$t"
  : >"$tmp/case-report"
  case_bad=0
  marks=""
  STRICT=""
  has_flag "$c" strict && STRICT="--strict-types"
  interp_ok0=no
  has_flag "$c" interp-exit-ok && interp_ok0=yes

  # classify: both compilers, bytecode target
  # shellcheck disable=SC2086
  run_leg "$t/rkt-bc" "$PUF" $STRICT -c -t bytecode -o "$t/rkt.pbc" "$src"
  # shellcheck disable=SC2086
  run_leg "$t/pcc-bc" "$CC" $STRICT "$src" -t bytecode -o "$t/pcc.pbc"
  rkt_ec=$(leg_ec "$t/rkt-bc"); pcc_ec=$(leg_ec "$t/pcc-bc")

  if [ "$rkt_ec" -ne 0 ] && [ "$pcc_ec" -ne 0 ]; then
    kind=compile
  elif [ "$rkt_ec" -eq 0 ] && [ "$pcc_ec" -eq 0 ]; then
    kind=runtime
  else
    # THE headline differential: the compilers disagree on acceptance
    cases_failed=$((cases_failed + 1))
    [ "$mode" = gen ] && gen_refused=$((gen_refused + 1))
    printf '%-28s %s\n' "$c" "FAIL: compilers DISAGREE on acceptance (rkt exit $rkt_ec, pcc exit $pcc_ec)"
    echo "    racket compile output:";   leg_text "$t/rkt-bc" | sed 's/^/    | /'
    echo "    puffincc compile output:"; leg_text "$t/pcc-bc" | sed 's/^/    | /'
    continue
  fi

  # the remaining legs
  # shellcheck disable=SC2086
  run_leg "$t/interp" "$PUF" $STRICT -i "$src"
  if [ "$kind" = compile ]; then
    # shellcheck disable=SC2086
    run_leg "$t/rkt-native" "$PUF" $STRICT -c -o "$t/rkt.exe" "$src"
    # shellcheck disable=SC2086
    run_leg "$t/pcc-native" "$CC" $STRICT "$src" -o "$t/pcc.exe"
  else
    # shellcheck disable=SC2086
    run_leg "$t/rkt-cc" "$PUF" $STRICT -c -o "$t/rkt.exe" "$src"
    # shellcheck disable=SC2086
    run_leg "$t/pcc-cc" "$CC" $STRICT "$src" -o "$t/pcc.exe"
    run_leg "$t/rkt-vm" "$VM" "$t/rkt.pbc"
    run_leg "$t/pcc-vm" "$VM" "$t/pcc.pbc"
    if [ "$(leg_ec "$t/rkt-cc")" -eq 0 ]; then
      run_leg "$t/rkt-native" "$t/rkt.exe"
    else
      cp "$t/rkt-cc.out" "$t/rkt-native.out"; cp "$t/rkt-cc.err" "$t/rkt-native.err"
      echo 0 >"$t/rkt-native.ec"   # force a "compile rejected" failure below
      echo "runtime case but the racket NATIVE compile rejected it" >>"$t/rkt-native.err"
    fi
    if [ "$(leg_ec "$t/pcc-cc")" -eq 0 ]; then
      run_leg "$t/pcc-native" "$t/pcc.exe"
    else
      cp "$t/pcc-cc.out" "$t/pcc-native.out"; cp "$t/pcc-cc.err" "$t/pcc-native.err"
      echo 0 >"$t/pcc-native.ec"
      echo "runtime case but the puffincc NATIVE compile rejected it" >>"$t/pcc-native.err"
    fi
  fi

  if [ "$mode" = gen ]; then
    gen_set=""
    echo "$c [$kind]"
    if [ "$kind" = compile ]; then
      gen_leg "$c" interp     "$t/interp"     interp
      gen_leg "$c" pcc-bc     "$t/pcc-bc"     pcc
      gen_leg "$c" pcc-native "$t/pcc-native" pcc
      # exits must already be failures
      for l in interp rkt-bc rkt-native pcc-bc pcc-native; do
        if [ "$(leg_ec "$t/$l")" -eq 0 ]; then
          echo "  REFUSED: leg $l exited 0 -- this case does not fail there"
          gen_refused=$((gen_refused + 1)); gen_set=""; break
        fi
      done
    else
      gen_leg "$c" interp     "$t/interp"     interp
      gen_leg "$c" rkt-vm     "$t/rkt-vm"     rkt-vm
      gen_leg "$c" pcc-vm     "$t/pcc-vm"     pcc-vm
      gen_leg "$c" rkt-native "$t/rkt-native" rkt-native
      gen_leg "$c" pcc-native "$t/pcc-native" pcc-native
      for l in rkt-vm pcc-vm rkt-native pcc-native; do
        if [ "$(leg_ec "$t/$l")" -eq 0 ]; then
          echo "  REFUSED: leg $l exited 0 -- this case does not fail there"
          gen_refused=$((gen_refused + 1)); gen_set=""; break
        fi
      done
      if [ -n "$gen_set" ] && [ "$(leg_ec "$t/interp")" -eq 0 ] && [ "$interp_ok0" != yes ]; then
        echo "  REFUSED: interp exited 0; if this is the (error ...) class, add"
        echo "           'interp-exit-ok' to $CASES/$c.flags and re-gen"
        gen_refused=$((gen_refused + 1)); gen_set=""
      fi
    fi
    # agreement across the un-overridden text legs
    if [ -n "$gen_set" ]; then
      ref=""
      agreed=yes
      for l in $gen_set; do
        if [ -z "$ref" ]; then ref=$l
        elif ! cmp -s "$tmp/gen-$ref" "$tmp/gen-$l"; then agreed=no; fi
      done
      if [ -z "$ref" ]; then
        echo "  note: every text leg is overridden; nothing to gen"
      elif [ "$agreed" = yes ]; then
        cat "$tmp/gen-$ref" >"$CASES/$c.expect"
        # cat of an empty capture writes an empty file; keep the
        # trailing newline convention for non-empty expectations
        [ -s "$CASES/$c.expect" ] && [ "$(tail -c1 "$CASES/$c.expect")" != "" ] && echo >>"$CASES/$c.expect"
        echo "  wrote $CASES/$c.expect (legs agreed:$gen_set)"
      else
        gen_refused=$((gen_refused + 1))
        echo "  REFUSED: the routes DISAGREE -- the differential test is firing."
        echo "  Investigate; if the divergence is triaged as known variance,"
        echo "  hand-write $CASES/$c.expect.<route> from the observed text below:"
        for l in $gen_set; do
          echo "    --- $l"
          sed 's/^/    | /' "$tmp/gen-$l"
        done
      fi
    fi
    continue
  fi

  # check mode: assert each leg
  if [ "$kind" = compile ]; then
    check_leg "$c" interp     "$t/interp"     interp yes no
    check_leg "$c" rkt-bc     "$t/rkt-bc"     -      no  no
    check_leg "$c" rkt-native "$t/rkt-native" -      no  no
    check_leg "$c" pcc-bc     "$t/pcc-bc"     pcc    yes no
    check_leg "$c" pcc-native "$t/pcc-native" pcc    yes no
  else
    check_leg "$c" interp     "$t/interp"     interp     yes "$interp_ok0"
    check_leg "$c" rkt-vm     "$t/rkt-vm"     rkt-vm     yes no
    check_leg "$c" pcc-vm     "$t/pcc-vm"     pcc-vm     yes no
    check_leg "$c" rkt-native "$t/rkt-native" rkt-native yes no
    check_leg "$c" pcc-native "$t/pcc-native" pcc-native yes no
  fi
  if [ "$case_bad" -ne 0 ]; then
    cases_failed=$((cases_failed + 1))
    printf '%-28s %-8s%s\n' "$c" "$kind" "$marks"
    cat "$tmp/case-report"
  else
    printf '%-28s %-8s%s\n' "$c" "$kind" "$marks"
  fi
done

echo
if [ "$mode" = gen ]; then
  if [ "$gen_refused" -eq 0 ]; then
    echo "gen: all expectations written from agreed route output"
  else
    echo "gen: $gen_refused case(s) REFUSED (routes disagree or unexpected success)"
    exit 1
  fi
else
  n=$(printf '%s\n' $cases | wc -l | tr -d ' ')
  echo "error corpus: $n cases, $legs_total legs, $legs_failed leg failures ($cases_failed cases failed)"
  echo "legend: ok text+exit asserted | ok~ per-route override | ox exit-only (bin/puffin -c swallows text)"
  [ "$legs_failed" -eq 0 ] && [ "$cases_failed" -eq 0 ] || exit 1
fi
