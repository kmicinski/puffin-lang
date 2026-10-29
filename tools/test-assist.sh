#!/bin/sh
# The assist corpus (docs/STUDIO.md §7): every case in
# src/assist-corpus runs one `puffincc --assist` operation, and every
# assist it offers is applied and re-checked, against the case's
# .expect transcript. gen mode WRITES the .expect files.
#
#   tools/test-assist.sh [gen] [name ...]
#
# Environment: PUFFINCC overrides the compiler (default build/puffincc).
# Needs: build/puffincc (bin/bootstrap), node.

set -u
cd "$(dirname "$0")/.."
exec node tools/assist-corpus.mjs "$@"
