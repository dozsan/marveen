#!/bin/bash
# Restart main agent services.
#
# Mirrors start.sh / stop.sh conventions (INSTALL_DIR, SLUG from MAIN_AGENT_ID,
# OS detect, systemd-user with nohup/pidfile fallback). Unlike a plain
# stop + start, this does an in-place `systemctl --user restart` and then
# verifies each unit actually came back active, so an operator can recover a
# wedged dashboard/channels session (for example a channel poller stuck on a
# stale provider after a Discord -> Telegram switch) with a single command.
#
# Usage:
#   restart.sh                 restart the long-running services (dashboard, channels)
#   restart.sh dashboard       restart only the dashboard service
#   restart.sh channels        restart only the channels service
#   restart.sh morning         restart the morning timer (see caveat below)
#   restart.sh --list          print the restart inventory and exit (no changes)
#   restart.sh --dry-run       show what would be restarted, without doing it
#
# Timers are NOT restarted by the no-argument form: re-arming a Persistent=true
# timer whose scheduled time has passed makes systemd fire an immediate catch-up
# run. Restart a timer only when you mean to, with an explicit target.
#
# Exit status is non-zero if any targeted unit fails to come back active.

set -uo pipefail

INSTALL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Read only what we need; never `set -a && source .env` -- that leaks
# TELEGRAM_BOT_TOKEN into every tmux session the dashboard spawns (see
# channels.sh for the full rationale).
if [ -f "$INSTALL_DIR/.env" ]; then
  SLUG="$(grep -E '^MAIN_AGENT_ID=' "$INSTALL_DIR/.env" | head -1 | cut -d= -f2-)"
  BOT_NAME="$(grep -E '^BOT_NAME=' "$INSTALL_DIR/.env" | head -1 | cut -d= -f2-)"
  CHANNEL_PROVIDER="$(grep -E '^CHANNEL_PROVIDER=' "$INSTALL_DIR/.env" | head -1 | cut -d= -f2-)"
fi
SLUG="${SLUG:-marveen}"
BOT_NAME="${BOT_NAME:-Marveen}"
CHANNEL_PROVIDER="${CHANNEL_PROVIDER:-telegram}"

# Root VPS / container: claude refuses --dangerously-skip-permissions as uid 0;
# the dashboard and the tmux sessions it spawns hit the same wall, so export the
# sandbox escape hatch for the whole stack when root (harmless for non-root).
[ "$(id -u)" = "0" ] && export IS_SANDBOX=1

# ── Inventory (card 206c5cb6) ────────────────────────────────────────────────
# Restart targets, keyed off SLUG (== SERVICE_ID == MAIN_AGENT_ID for a default
# install; see install-linux.sh). Long-running services get a real restart;
# timers get re-armed. The morning *.service is oneshot/static -- it is driven
# by its timer, so we never restart the service directly.
SERVICES=("${SLUG}-dashboard" "${SLUG}-channels")
TIMERS=("${SLUG}-morning.timer")
# Optional guard timers -- restarted only when actually installed on the host.
OPTIONAL_TIMERS=("channel-watchdog.timer" "disk-space-guard.timer" "stuck-modal-guard.timer")
# Non-systemd fallback: pidfile-backed processes (see start.sh / stop.sh).
PID_PROCS=("dashboard" "channels")
# Channel pollers (card f1fc9501): pid-file-backed processes that can hold a
# wedged inbound connection regardless of systemd -- the plugin's own poller and
# the standalone channel-coordinator. Tearing these down frees a stuck channel.
CHANNEL_DIR="$HOME/.claude/channels/${CHANNEL_PROVIDER}"
BOT_PIDFILE="${CHANNEL_DIR}/bot.pid"
COORD_PIDFILE="$HOME/.claude/channels/${CHANNEL_PROVIDER}-coordinator/coordinator.pid"

DRY_RUN=0
LIST_ONLY=0
TARGETS=()

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --list)    LIST_ONLY=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    dashboard) TARGETS+=("${SLUG}-dashboard") ;;
    channels)  TARGETS+=("${SLUG}-channels") ;;
    morning)   TARGETS+=("${SLUG}-morning.timer") ;;
    *) echo "Unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# unit_exists UNIT -- true if the user unit is known to systemd.
unit_exists() {
  systemctl --user cat "$1" >/dev/null 2>&1
}

print_inventory() {
  echo "${BOT_NAME} restart inventory (SLUG=${SLUG}):"
  echo "  systemd services (restart):"
  for u in "${SERVICES[@]}"; do echo "    - ${u}.service"; done
  echo "  systemd timers (re-arm):"
  for u in "${TIMERS[@]}"; do echo "    - ${u}"; done
  echo "  optional guard timers (restart if installed):"
  for u in "${OPTIONAL_TIMERS[@]}"; do echo "    - ${u}"; done
  echo "  pidfile fallback processes (non-systemd hosts):"
  for p in "${PID_PROCS[@]}"; do echo "    - store/${p}.pid"; done
  echo "  channel pollers (pid-file, freed on a channels restart):"
  echo "    - ${BOT_PIDFILE}"
  echo "    - ${COORD_PIDFILE}"
}

# ── systemd path (card b3834765) ─────────────────────────────────────────────
# restart_unit UNIT -- restart one user unit and verify it is active afterwards.
# Returns 0 on success, 1 on failure. Skips units that are not installed.
restart_unit() {
  local unit="$1"
  if ! unit_exists "$unit"; then
    echo "  - ${unit}: not installed, skipping"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "  - ${unit}: would restart (dry-run)"
    return 0
  fi
  case "$unit" in
    *.timer) echo "  ! ${unit}: re-arming a Persistent timer may fire a missed run immediately" >&2 ;;
  esac
  if ! systemctl --user restart "$unit" 2>/dev/null; then
    echo "  ✗ ${unit}: restart command failed" >&2
    return 1
  fi
  # Give it a moment, then confirm. Timers report active when armed; oneshot
  # services may legitimately be inactive after running, so only hard-fail on
  # the long-running services.
  sleep 1
  if systemctl --user is-active --quiet "$unit" 2>/dev/null; then
    echo "  ✓ ${unit}: active"
    return 0
  fi
  case "$unit" in
    *.timer)
      echo "  ! ${unit}: restarted but not active (timer may be disabled)" >&2
      return 0 ;;
    *)
      echo "  ✗ ${unit}: not active after restart" >&2
      systemctl --user status "$unit" --no-pager -n 5 2>/dev/null | sed 's/^/      /' || true
      return 1 ;;
  esac
}

restart_via_systemd() {
  local rc=0
  systemctl --user daemon-reload 2>/dev/null || true

  # Default (no explicit target) restarts only the long-running services. Timers
  # are deliberately NOT in the blanket set: re-arming a Persistent=true timer
  # whose scheduled time has already passed makes systemd fire an immediate
  # catch-up run (verified with marveen-morning.timer -- a routine restart would
  # otherwise trigger a stray morning briefing). Restart a timer on purpose with
  # `restart.sh morning`.
  local list=()
  if [ "${#TARGETS[@]}" -gt 0 ]; then
    list=("${TARGETS[@]}")
  else
    list=("${SERVICES[@]}")
  fi

  echo "${BOT_NAME}: restarting services..."
  for unit in "${list[@]}"; do
    restart_unit "$unit" || rc=1
  done

  # Doki (8f1886d3): post-restart channel health verification goes here.
  post_restart_channel_check || true
  return $rc
}

# ── pid-process teardown (card f1fc9501) ─────────────────────────────────────
# stop_pidfile FILE LABEL -- stop a pidfile-backed process the reliable way:
# SIGTERM, wait for it to exit, escalate to SIGKILL, then remove the (now stale)
# pidfile. Safe when the file is missing, the pid is malformed, or the process
# is already dead. Honors --dry-run.
stop_pidfile() {
  local pidfile="$1" label="$2" pid
  [ -f "$pidfile" ] || return 0
  pid="$(cat "$pidfile" 2>/dev/null)"
  if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    [ "$DRY_RUN" = "1" ] && { echo "  - ${label}: stale pidfile (no valid pid)"; return 0; }
    rm -f "$pidfile"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "  - ${label} (pid ${pid}): would stop (dry-run)"
    return 0
  fi
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 5 ]; do
      sleep 0.5
      waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
      echo "  ✓ ${label} (pid ${pid}): killed (did not exit on TERM)"
    else
      echo "  ✓ ${label} (pid ${pid}): stopped"
    fi
  else
    echo "  - ${label}: not running (stale pidfile)"
  fi
  rm -f "$pidfile"
}

# release_channel_pollers -- stop the pid-file-backed channel processes that can
# pin a wedged inbound connection: the plugin's own poller (bot.pid) and the
# standalone channel-coordinator (coordinator.pid). Freeing these is what lets a
# stuck channel (e.g. a poller stranded on a stale provider after a
# Discord -> Telegram switch) recover when the channels session relaunches.
release_channel_pollers() {
  echo "${BOT_NAME}: releasing channel pollers (provider=${CHANNEL_PROVIDER})..."
  stop_pidfile "$BOT_PIDFILE" "channel poller (bot.pid)"
  stop_pidfile "$COORD_PIDFILE" "channel-coordinator"
}

# ── non-systemd fallback (pidfile path) ──────────────────────────────────────
# Stop + start for hosts without systemd --user (WSL, containers), mirroring
# start.sh / stop.sh, with the stuck-channel-aware poller teardown of f1fc9501.
restart_pidfile() {
  echo "${BOT_NAME}: systemd --user unavailable, restarting via pidfiles..."
  for svc in "${PID_PROCS[@]}"; do
    stop_pidfile "$INSTALL_DIR/store/${svc}.pid" "$svc"
  done
  # Free the wedged channel pollers, then drop the channels tmux session so the
  # relaunch binds the current provider instead of a stale one.
  release_channel_pollers
  if [ "$DRY_RUN" != "1" ]; then
    tmux kill-session -t "${SLUG}-channels" 2>/dev/null || true
    bash "$INSTALL_DIR/scripts/start.sh"   # canonical relaunch
  else
    echo "  - would kill tmux session ${SLUG}-channels and run scripts/start.sh"
  fi
  post_restart_channel_check || true
}

# ── channel rebind verification hook (card 8f1886d3, Doki) ───────────────────
# Verify the freshly restarted channels session bound the CURRENT provider
# (e.g. Telegram) and is not stuck on a stale Discord connection. No-op for now;
# Doki fills this in.
post_restart_channel_check() {
  return 0
}

# ── main ─────────────────────────────────────────────────────────────────────
if [ "$LIST_ONLY" = "1" ]; then
  print_inventory
  exit 0
fi

OS="$(uname -s)"
if [ "$OS" = "Darwin" ]; then
  echo "${BOT_NAME}: restarting LaunchAgents..."
  for unit in dashboard channels; do
    plist="$HOME/Library/LaunchAgents/com.${SLUG}.${unit}.plist"
    if [ "$DRY_RUN" = "1" ]; then
      echo "  - com.${SLUG}.${unit}: would reload (dry-run)"
    else
      launchctl unload "$plist" 2>/dev/null || true
      launchctl load "$plist" 2>/dev/null && echo "  ✓ com.${SLUG}.${unit}: reloaded" \
        || echo "  ✗ com.${SLUG}.${unit}: reload failed" >&2
    fi
  done
  post_restart_channel_check || true
  exit 0
fi

if pidof systemd >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
  restart_via_systemd
  exit $?
else
  restart_pidfile
  exit $?
fi
