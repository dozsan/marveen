#!/usr/bin/env bash
# Marveen container entrypoint / supervisor.
#
# Replaces systemd/launchd inside the container. Mirrors the direct-launch path
# of scripts/start.sh (the "systemd not available (container)" branch):
#   1. ensure state dirs + container-built native deps + a fresh dist/ build
#   2. start the channel bridge (creates the agent tmux server) in the background
#   3. exec the dashboard in the FOREGROUND so it becomes the container's main
#      process -- if it dies, Docker's restart policy brings the container back.
#
# Code + state come from the /app bind mount; only node_modules is a
# container-side volume (native binding must match this image's Node/glibc).
set -euo pipefail

cd /app

export IS_SANDBOX=1
: "${HOME:=/app/store/home}"
export HOME
mkdir -p "$HOME" store

log() { echo "[entrypoint] $*"; }

# --- .env is required (bring your bot token + OAuth token on the mount) --------
if [ ! -f /app/.env ]; then
  log "FATAL: /app/.env is missing."
  log "Create it on the host (copy .env.example) before starting the container."
  exit 1
fi

# --- Native deps: build INSIDE the container, never trust a host node_modules --
# Rebuild when the lockfile changed or the marker is absent. This is the fix for
# the better-sqlite3 "Could not locate the bindings file" class -- the module is
# compiled here, against this image's Node.
NM_MARKER="node_modules/.docker-built"
if [ ! -f "$NM_MARKER" ] || [ package-lock.json -nt "$NM_MARKER" ]; then
  log "Installing node_modules (container-native build)..."
  npm ci
  touch "$NM_MARKER"
else
  log "node_modules up to date (marker newer than lockfile)."
fi

# --- TypeScript build (dist/) -------------------------------------------------
if [ ! -f dist/index.js ] || [ -n "$(find src -newer dist/index.js -name '*.ts' -print -quit 2>/dev/null)" ]; then
  log "Building dist/ ..."
  npm run build
else
  log "dist/ up to date."
fi

# --- Clean shutdown: kill the background channels + tmux server on stop -------
shutdown() {
  log "Shutting down..."
  [ -n "${CHAN_PID:-}" ] && kill "$CHAN_PID" 2>/dev/null || true
  tmux kill-server 2>/dev/null || true
  exit 0
}
trap shutdown SIGTERM SIGINT

# --- Channel bridge (spawns the agent tmux session) in the background ---------
log "Starting channel bridge..."
bash scripts/channels.sh > store/channels.log 2>&1 &
CHAN_PID=$!

# --- Dashboard in the foreground = container lifecycle ------------------------
log "Starting dashboard on :${WEB_PORT:-3420} ..."
exec node dist/index.js
