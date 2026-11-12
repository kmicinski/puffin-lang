#!/bin/sh
# Open (making it if need be) the project PUFFIN_STUDIO_PROJECT under
# PUFFIN_PROJECTS and serve the studio on 0.0.0.0:PUFFIN_STUDIO_PORT --
# inside the container; publish the port only behind an authenticating
# proxy (deploy/README.md).
set -e
mkdir -p "$HOME" "$PUFFIN_PROJECTS/$PUFFIN_STUDIO_PROJECT"
exec puffin-studio "$PUFFIN_PROJECTS/$PUFFIN_STUDIO_PROJECT" \
  --bind 0.0.0.0 --port "$PUFFIN_STUDIO_PORT" --no-open "$@"
