#!/bin/sh
# One Puffin Studio per login (deploy/README.md "Many users").
#
# Runs as root with only CHOWN, DAC_OVERRIDE, FOWNER, SETUID and SETGID,
# and never runs user code itself. For each `login:uid` in PUFFIN_USERS
# it starts, and restarts when it exits, a studio that:
#   - runs as that uid, with no capabilities, no new privileges and an
#     RLIMIT_NPROC (PUFFIN_USER_NPROC);
#   - keeps everything under $PUFFIN_DATA/users/<login>/ (mode 0700:
#     projects/, home/, tmp/ = its TMPDIR, agent-home/ = the claude CLI);
#   - serves the browser ONLY on $PUFFIN_SOCKETS/<login>/studio.sock
#     (directory 0700 and socket 0600, both the login's): a reverse proxy
#     running as root routes each authenticated login to its own socket,
#     and no other uid can open, replace or squat it. The assistant's
#     /mcp listens on loopback behind a random bearer token that only
#     this uid can read.
# Root only ever creates paths that do not exist yet, under directories
# it owns: it never follows into, chowns or deletes inside a tree a user
# controls (a planted symlink must not turn into a root operation).
# The studio's environment is rebuilt from nothing (env -i): the hub's
# own environment never reaches user code. The assistant's credentials
# are PUFFIN_AI_* only -- meant to name a proxy that holds the real
# token (deploy/README.md), never the token itself.
set -eu

: "${PUFFIN_USERS:?PUFFIN_USERS is required: login:uid[,login:uid...]}"
PUFFIN_DATA=${PUFFIN_DATA:-/data}
PUFFIN_SOCKETS=${PUFFIN_SOCKETS:-/run/puffin}
PUFFIN_USER_NPROC=${PUFFIN_USER_NPROC:-512}
PUFFIN_STUDIO_PROJECT=${PUFFIN_STUDIO_PROJECT:-welcome}

entries=$(echo "$PUFFIN_USERS" | tr ',' ' ')
for entry in $entries; do
  login=${entry%%:*} uid=${entry#*:}
  case "$login" in ""|*[!a-z0-9_-]*) echo "hub: bad login '$login'" >&2; exit 1 ;; esac
  case "$uid" in ""|0|*[!0-9]*) echo "hub: bad uid '$uid' for $login" >&2; exit 1 ;; esac
done

mkdir -p "$PUFFIN_DATA/users" "$PUFFIN_SOCKETS"
chown root:root "$PUFFIN_DATA" "$PUFFIN_DATA/users" "$PUFFIN_SOCKETS"
chmod 755 "$PUFFIN_DATA" "$PUFFIN_DATA/users"
chmod 711 "$PUFFIN_SOCKETS"   # traverse, not list

# a directory owned by root (so a user cannot have put anything there)
# gets a new child owned by uid; an existing child is left alone
own_dir() {  # own_dir PATH UID MODE
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then
    mkdir -m "$3" "$1"
    chown -h "$2:$2" "$1"
  fi
}

serve() {
  login=$1 uid=$2
  home="$PUFFIN_DATA/users/$login"
  own_dir "$home" "$uid" 700
  own_dir "$PUFFIN_SOCKETS/$login" "$uid" 700
  while :; do
    setpriv --reuid="$uid" --regid="$uid" --clear-groups \
      --inh-caps=-all --bounding-set=-all --no-new-privs \
      prlimit --nproc="$PUFFIN_USER_NPROC" -- \
      env -i \
        PATH=/usr/local/bin:/usr/bin:/bin \
        LANG=C.UTF-8 \
        TZ="${TZ:-UTC}" \
        USER="$login" \
        HOME="$home/home" \
        TMPDIR="$home/tmp" \
        PUFFIN_ROOT="${PUFFIN_ROOT:-/opt/puffin}" \
        PUFFIN_PROJECTS="$home/projects" \
        PUFFIN_STUDIO_MODEL="${PUFFIN_STUDIO_MODEL:-}" \
        PUFFIN_STUDIO_EFFORT="${PUFFIN_STUDIO_EFFORT:-medium}" \
        CLAUDE_CONFIG_DIR="$home/agent-home" \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
        ANTHROPIC_BASE_URL="${PUFFIN_AI_BASE_URL:-}" \
        CLAUDE_CODE_OAUTH_TOKEN="${PUFFIN_AI_PLACEHOLDER_TOKEN:-}" \
        ANTHROPIC_CUSTOM_HEADERS="X-Puffin-User: $login" \
      sh -c 'mkdir -p "$HOME" "$TMPDIR" "$CLAUDE_CONFIG_DIR" "$PUFFIN_PROJECTS/$1" &&
             exec puffin-studio "$PUFFIN_PROJECTS/$1" --unix "$2" --no-open' \
        studio "$PUFFIN_STUDIO_PROJECT" "$PUFFIN_SOCKETS/$login/studio.sock" \
      2>&1 | sed -u "s/^/[$login] /" || true
    echo "[$login] studio exited; restarting in 3s"
    sleep 3
  done
}

for entry in $entries; do
  serve "${entry%%:*}" "${entry#*:}" &
done
wait
