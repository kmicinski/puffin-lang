#!/bin/bash
set -euo pipefail

# remove any old starter folder
rm -rf starter
mkdir starter

# copy everything except test, goldens, outputs, caches, etc.
rsync -av . starter/ \
  --exclude 'test/' \
  --exclude 'testout' \
  --exclude 'output' \
  --exclude 'output.o' \
  --exclude 'output.s' \
  --exclude 'runtime.o' \
  --exclude '__pycache__/' \
  --exclude '#*#' \
  --exclude 'starter/' \
  --exclude 'bad-programs/' \
  --exclude 'canonical-testcase/' \
  --exclude '#out#' \
  --exclude '.#example.s' \
  --exclude 'compile.rkt' \
  --exclude 'all-tests/' \
  --exclude 'all-tests.sh' \
  --exclude 'old-programs/' \
  --exclude 'ex.o' \
  --exclude 'ex.s' \
  --exclude 'ex0' \
  --exclude 'example.o' \
  --exclude 'exin' \
  --exclude 'out' \
  --exclude 'out1' \
  --exclude 'out1clear' \
  --exclude 'maketests.sh' \
  --exclude 'maketests.sh~' \
  --exclude 'clear' \
  --exclude 'replace.sh' \
  --exclude 'repro.sh' \
  --exclude 'selected-tests.txt' \
  
mv starter/compile-starter.rkt starter/compile.rkt
