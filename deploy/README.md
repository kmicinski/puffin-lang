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
authenticates every request. A single studio (the default entrypoint)
is shared by everyone who gets through: one open project, one live
session, one assistant.

## Many users: one studio per login (`deploy/hub.sh`)

Run the image with entrypoint `/usr/local/bin/puffin-studio-hub` as root,
`PUFFIN_USERS=login:uid,...`, capabilities limited to `CHOWN
DAC_OVERRIDE FOWNER SETUID SETGID` and `no-new-privileges`. Each login
gets its own studio:

- under its own uid, with no capabilities and an RLIMIT_NPROC, its
  environment rebuilt from nothing (`env -i`);
- data in `/data/users/<login>/` (0700): projects, home, TMPDIR, the
  claude CLI's state;
- the page and WebSocket ONLY on `/run/puffin/<login>/studio.sock`
  (`puffin-studio --unix`; 0700 directory, 0600 socket). Share
  `/run/puffin` with a root reverse proxy that maps the authenticated
  login to its socket. TCP carries only the assistant's `/mcp`, on
  loopback, behind a random bearer token only that uid can read.

Root only creates paths that do not exist yet, under directories it
owns, so a symlink a user plants never becomes a root operation.

**Keep the AI token out of the container.** Users can read anything
their own uid can, including the environment their studio passes to
`claude`. Set `PUFFIN_AI_BASE_URL` to a proxy that holds the real token
and `PUFFIN_AI_PLACEHOLDER_TOKEN` to a dummy: the CLI sends the dummy,
and the proxy replaces it (it needs only `POST /v1/messages`; each
request carries `X-Puffin-User: <login>`). Put the studio container on
an internal network whose only other member is that proxy, so user code
reaches nothing else: not your LAN, not other services that trust
proxy-auth headers, not the internet.

Environment: `PUFFIN_STUDIO_PROJECT` (default `welcome`),
`PUFFIN_STUDIO_PORT` (7360), `PUFFIN_STUDIO_MODEL` /
`PUFFIN_STUDIO_EFFORT` (the assistant), plus whatever the `claude` CLI
needs to authenticate if you mount it at `/usr/local/bin/claude`.
