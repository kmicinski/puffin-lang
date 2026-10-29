#!/bin/sh
# Hold the span-preserving reader (puffincc-src/syntax.puf) to the
# compiler's reader over every Puffin source in the tree: the
# compiler, the prelude, the golden and error corpora, and examples/.
# See puffincc-src/tests/test-syntax.puf for what is checked.
#
#   tools/test-syntax.sh
#
# Needs: build/puffincc (bin/bootstrap), bin/puffin-vm (make -C src/vm).

set -u
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

build/puffincc -t bytecode puffincc-src/tests/test-syntax.puf -o "$tmp/ts.pbc" || exit 1

# the error corpus's reader-* cases are meant not to read
# shellcheck disable=SC2046
bin/puffin-vm "$tmp/ts.pbc" puffincc-src/*.puf src/prelude.puf \
  $(find src/test-programs src/errors-corpus examples \( -name '*.puf' -o -name '*.scm' \) \
      ! -name 'reader-*' | sort) \
  > "$tmp/out" 2>&1
status=$?
grep -v '^ok ' "$tmp/out"
exit $status
