# Serving Puffin Studio from a Linux host

`deploy/Dockerfile` builds a container that serves the studio on port
7360 for one project under `/data/projects` (mount `/data` to keep
projects, the assistant's state and history).

What differs from the mac setup (`bin/bootstrap`):

- `src/runtime/Makefile` has a Linux branch: host architecture only,
  the system Boehm GC (`libgc-dev`) folded into `libpuffin.a`.
- The native backends emit Mach-O assembly, so there is no native
  `build/puffincc`. The image runs puffincc as bytecode on the VM via a
  `build/puffincc` wrapper (stage 2: current puffincc compiled by
  itself). The studio only asks it for bytecode and `--assist`/`--repl`
  services, which take milliseconds this way.
- `puffin-studio --bind 0.0.0.0` listens beyond loopback, and the
  WebSocket's same-origin check accepts `https://` origins (a TLS proxy
  passing the original `Host` through).

**Security.** The studio has no login and runs whatever its users
evaluate (`system`, the FFI), so publish it only behind a proxy that
authenticates every request. Everyone who gets through shares one
studio: one open project, one live session, one assistant.

Environment: `PUFFIN_STUDIO_PROJECT` (default `welcome`),
`PUFFIN_STUDIO_PORT` (7360), `PUFFIN_STUDIO_MODEL` /
`PUFFIN_STUDIO_EFFORT` (the assistant), plus whatever the `claude` CLI
needs to authenticate if you mount it at `/usr/local/bin/claude`.
