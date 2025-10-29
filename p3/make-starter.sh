#!/bin/bash
set -euo pipefail

# remove any old starter folder
rm -rf starter
mkdir starter

# copy everything except test, goldens, outputs, caches, etc.
rsync -av . starter/ \
  --exclude 'test/' \
  --exclude 'selected-tests.txt' \ 
  --exclude 'testout' \
  --exclude 'output' \
  --exclude 'output.o' \
  --exclude 'output.s' \
  --exclude 'runtime.o' \
  --exclude '__pycache__/' \
  --exclude '#*#' \
  --exclude 'starter/' 

mv starter/compile-starter.rkt starter/compile.rkt
