# Puffin Studio as a Linux container (docs/STUDIO.md), for serving the
# studio behind an authenticating reverse proxy.
#
#   docker build -f deploy/Dockerfile -t puffin-studio .
#   docker run -p 127.0.0.1:7360:7360 -v "$PWD/data:/data" puffin-studio
#
# The studio has NO login of its own and evaluates whatever its users
# type (including `system` and the FFI), so never publish it without a
# proxy that authenticates every request. See deploy/README.md.
#
# Linux differs from the mac bootstrap (bin/bootstrap) in one place: the
# native backends emit Mach-O assembly, so there is no native
# build/puffincc. Instead puffincc runs as bytecode on the VM, through
# the build/puffincc wrapper written below -- the studio only ever asks
# it for bytecode and --assist/--repl services, never native code.

# ---- runtime + VM + puffincc as bytecode --------------------------------
FROM debian:bookworm-slim AS toolchain
RUN apt-get update && apt-get install -y --no-install-recommends clang make libgc-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/puffin
COPY . .
# runtime (system Boehm folded in: src/runtime/Makefile's Linux branch),
# then the VM (the committed vm-prims.inc)
RUN make -C src/runtime && make -C src/vm
# stage 1: the committed seed compiles puffincc-src; stage 2: that
# compiler compiles itself, so the shipped puffincc is current puffincc
# compiled by current puffincc (a few minutes each, on the VM)
RUN mkdir -p build \
    && bin/puffin-vm boot/puffincc.pbc puffincc-src/main.puf -t bytecode -o build/stage1.pbc \
    && bin/puffin-vm build/stage1.pbc puffincc-src/main.puf -t bytecode -o build/puffincc.pbc \
    && rm build/stage1.pbc \
    && printf '#!/bin/sh\nexec /opt/puffin/bin/puffin-vm /opt/puffin/build/puffincc.pbc "$@"\n' > build/puffincc \
    && chmod 755 build/puffincc \
    && printf '(println (+ 40 2))\n' > /tmp/smoke.puf \
    && build/puffincc -t bytecode -o /tmp/smoke.pbc /tmp/smoke.puf \
    && test "$(bin/puffin-vm /tmp/smoke.pbc)" = 42

# ---- the studio server ---------------------------------------------------
FROM rust:1.88-bookworm AS studio
WORKDIR /opt/puffin
COPY studio studio
# the page's assets are compiled in (web.rs), prim-names.js among them
COPY web/src/engine/prim-names.js web/src/engine/prim-names.js
RUN cd studio && cargo build --release --locked

# ---- Monaco (the editor; without it the studio falls back to a textarea) --
FROM node:22-bookworm-slim AS web
WORKDIR /opt/puffin/web
COPY web/package.json web/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts

# ---- runtime image ---------------------------------------------------------
FROM debian:bookworm-slim
# git: projects are git repositories; libgc: none needed (static);
# ca-certificates: the assistant's `claude` CLI talks HTTPS
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/puffin
COPY . .
COPY --from=toolchain /opt/puffin/bin/puffin-vm bin/puffin-vm
COPY --from=toolchain /opt/puffin/build build
COPY --from=studio /opt/puffin/studio/target/release/puffin-studio /usr/local/bin/puffin-studio
COPY --from=web /opt/puffin/web/node_modules web/node_modules
COPY deploy/entrypoint.sh /usr/local/bin/puffin-studio-entrypoint
ENV PUFFIN_ROOT=/opt/puffin \
    PUFFIN_PROJECTS=/data/projects \
    HOME=/data/home \
    PUFFIN_STUDIO_PORT=7360 \
    PUFFIN_STUDIO_PROJECT=welcome
VOLUME /data
EXPOSE 7360
ENTRYPOINT ["/usr/local/bin/puffin-studio-entrypoint"]
