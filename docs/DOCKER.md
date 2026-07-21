# Running Marveen in Docker

A thin-runtime container model: the image carries only the runtime (Node + tmux +
the Claude Code CLI + a native-build toolchain). **Marveen's code and state stay
on the host**, bind-mounted into the container at `/app`. You update Marveen on
the host and restart the container -- no image rebuild, and the host filesystem
stays clean (only the bind-mounted directory is shared; the processes run inside
the container).

This is the deliberate design from the discussion:
- **Code, updatable from outside**: the repo lives on the host, mounted at `/app`.
- **State on the mount**: `store/` (SQLite DBs, `.dashboard-token`,
  `.claude-oauth-token`), `agents/`, `.env`, and the `~/.claude` "dotcloud"
  (under `store/home/`) all persist on the host.
- **Only `node_modules` is container-side**, on a named volume -- see the gotcha
  below.

## Files

| File | Role |
|------|------|
| `Dockerfile` | Thin runtime image. No source baked in. |
| `docker/entrypoint.sh` | Supervisor (replaces systemd): deps + build, starts channels in the background, runs the dashboard in the foreground. |
| `docker-compose.yml` | Bind mount `/app`, `node_modules` volume, published port. |
| `.dockerignore` | Keeps the build context tiny (no source needed at build). |

## Make targets

A `Makefile` wraps the common flows -- run `make help` for the full list. The
essentials:

```bash
make install   # first-time setup from scratch (seed .env, check token, build + start)
make up        # start (already installed)
make update    # git pull + rebuild + restart
make logs      # follow logs
make health    # is the dashboard up?
make down      # stop (host state is kept)
```

The manual `docker compose` flow below is equivalent, if you prefer it.

## Quick start

```bash
# 1. Have the repo on the host (this dir is fine, or set MARVEEN_HOST_DIR).
# 2. Create .env with your channel token + main-agent settings:
cp .env.example .env && $EDITOR .env

# 3. Provide the OAuth setup-token (generate anywhere with a browser):
claude setup-token                     # prints sk-ant-oat01-...
install -m 600 /dev/stdin store/.claude-oauth-token   # paste the token, Ctrl-D
#   (the main channels agent also reads CLAUDE_CODE_OAUTH_TOKEN from .env --
#    keep the two identical, see docs/config-reference for why.)

# 4. Build + start:
docker compose up -d --build

# 5. Dashboard:
open http://localhost:3420
```

## Updating Marveen (no rebuild)

Because the code is the bind mount, updates happen on the host:

```bash
git -C "$MARVEEN_HOST_DIR" pull      # or run update.sh on the host
docker compose restart               # entrypoint rebuilds deps/dist if the
                                     # lockfile or sources changed
```

Rebuild the image itself only when you want a newer Node or a newer Claude Code
CLI: `docker compose build --no-cache`.

## The one critical gotcha: `node_modules`

`better-sqlite3` is a **native module compiled against the container's Node/glibc**.
If a host-built `node_modules` reaches the container, the binding fails to load
(`Could not locate the bindings file`, dashboard `connection refused`).

The compose file prevents this by mounting a dedicated `marveen_node_modules`
volume over `/app/node_modules`, and the entrypoint runs `npm ci` **inside** the
container. **Never** add a bind mount for `node_modules`. If you ever see the
bindings error, rebuild the deps volume:

```bash
docker compose down
docker volume rm "$(docker compose config --volumes | grep node_modules)"
docker compose up -d --build
```

## Running multiple Marveens on one host

One container per Marveen, each with its own bind-mounted repo dir, its own
OAuth token (its own subscription/account), and its own published port:

```bash
MARVEEN_HOST_DIR=/opt/marveen-a MARVEEN_PORT=3420 docker compose -p marveen-a up -d
MARVEEN_HOST_DIR=/opt/marveen-b MARVEEN_PORT=3421 docker compose -p marveen-b up -d
```

The `-p` project name keeps the `node_modules` volumes separate. Each container's
filesystem (and thus each `~/.claude`) is naturally isolated -- no host-side
`CLAUDE_CONFIG_DIR` juggling needed.

## Notes / caveats

- **Root inside the container**: `claude` refuses `--dangerously-skip-permissions`
  as uid 0; the image sets `IS_SANDBOX=1` (same escape hatch as `scripts/start.sh`).
- **tmux lives in the container**: the agents are interactive `claude` processes
  in tmux panes; the tmux server runs inside the container and is torn down on
  `docker compose stop`.
- **Timezone**: set `TZ` (defaults to `Europe/Budapest`) so schedules and logs
  read in local time.
- **Persistence**: everything except `node_modules` is on the host bind mount, so
  `docker compose down` loses nothing. `down -v` only drops the rebuildable
  `node_modules` volume.
- **SQLite**: keep the bind mount on a real local filesystem. Avoid NFS/network
  mounts -- their file locking corrupts the DBs.
