#!/bin/bash
# Restart main agent services.
#
# In-place restart of the long-running services (dashboard, channels) with
# per-service status verification, plus a channel-poller release so a wedged
# inbound connection (e.g. a poller stuck on a stale provider after a
# Discord -> Telegram switch) recovers with a single command. The platform
# service layer (systemd / launchd / pidfile) lives in scripts/lib/platform.sh.
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
# Exit status is non-zero if any targeted service fails to come back active.

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
DRY_RUN=0

# Root VPS / container: claude refuses --dangerously-skip-permissions as uid 0;
# the dashboard and the tmux sessions it spawns hit the same wall, so export the
# sandbox escape hatch for the whole stack when root (harmless for non-root).
[ "$(id -u)" = "0" ] && export IS_SANDBOX=1

# Platform service layer (platform_detect, svc_*, stop_pidfile,
# release_channel_pollers, safe_rm). Sourced after the identity vars so the lib
# picks up SLUG / CHANNEL_PROVIDER / INSTALL_DIR.
# shellcheck source=lib/platform.sh
source "$INSTALL_DIR/scripts/lib/platform.sh"

LIST_ONLY=0
TARGETS=()   # logical service names: dashboard | channels | morning
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --list)    LIST_ONLY=1 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    dashboard) TARGETS+=("dashboard") ;;
    channels)  TARGETS+=("channels") ;;
    morning)   TARGETS+=("morning") ;;
    *) echo "Unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

print_inventory() {
  echo "${BOT_NAME} restart inventory (SLUG=${SLUG}, platform=$(platform_detect)):"
  echo "  long-running services (restarted by default):"
  for s in dashboard channels; do echo "    - ${s} -> $(svc_physical "$s" || true)"; done
  echo "  on-demand timer (restart.sh morning):"
  echo "    - morning -> $(svc_physical morning || true)"
  echo "  channel pollers (pid-file, freed on a channels restart):"
  echo "    - ${BOT_PIDFILE}"
  echo "    - ${COORD_PIDFILE}"
}

# restart_service LOGICAL -- restart one service and verify it came back active.
# Returns 0 on success, 1 on failure. Skips services absent on this platform.
restart_service() {
  local logical="$1"
  if ! svc_exists "$logical"; then
    echo "  - ${logical}: not installed on this platform, skipping"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    svc_restart "$logical"   # prints "would restart (dry-run)"
    return 0
  fi
  case "$logical" in
    morning) echo "  ! morning: re-arming a Persistent timer may fire a missed run immediately" >&2 ;;
  esac
  if ! svc_restart "$logical"; then
    echo "  ✗ ${logical}: restart command failed" >&2
    return 1
  fi
  # Give it a moment, then confirm. Timers report active when armed.
  sleep 1
  if svc_is_active "$logical"; then
    echo "  ✓ $(svc_physical "$logical"): active"
    return 0
  fi
  case "$logical" in
    morning)
      echo "  ! morning: restarted but not active (timer may be disabled)" >&2
      return 0 ;;
    *)
      echo "  ✗ ${logical}: not active after restart" >&2
      if [ "$(platform_detect)" = "linux-systemd" ]; then
        systemctl --user status "$(svc_physical "$logical")" --no-pager -n 5 2>/dev/null | sed 's/^/      /' || true
      fi
      return 1 ;;
  esac
}

# In-place restart for supervised platforms (systemd, launchd).
restart_supervised() {
  local rc=0
  svc_daemon_reload
  # Default (no explicit target) restarts only the long-running services. Timers
  # are deliberately NOT in the blanket set: re-arming a Persistent=true timer
  # whose time has passed makes systemd fire an immediate catch-up run (verified
  # with marveen-morning.timer). Restart a timer on purpose with `restart.sh morning`.
  local list=()
  if [ "${#TARGETS[@]}" -gt 0 ]; then list=("${TARGETS[@]}"); else list=("dashboard" "channels"); fi

  echo "${BOT_NAME}: restarting services..."
  for logical in "${list[@]}"; do
    restart_service "$logical" || rc=1
  done
  post_restart_channel_check || true
  return $rc
}

# Teardown + relaunch for hosts without a per-user supervisor (WSL, containers).
# There is no in-place restart: stop the pidfile processes, free the wedged
# channel pollers, drop the channels tmux session, then relaunch via start.sh.
restart_pidfile() {
  echo "${BOT_NAME}: no per-user supervisor, restarting via pidfiles..."
  svc_stop dashboard
  svc_stop channels
  release_channel_pollers
  if [ "$DRY_RUN" != "1" ]; then
    tmux kill-session -t "${SLUG}-channels" 2>/dev/null || true
    bash "$INSTALL_DIR/scripts/start.sh"   # canonical relaunch
  else
    echo "  - would kill tmux session ${SLUG}-channels and run scripts/start.sh"
  fi
  post_restart_channel_check || true
}

# ── channel rebind verification (card 8f1886d3) ──────────────────────────────
# Verify the freshly restarted channels session bound the CURRENT provider (from
# .env) and is not stuck on a stale one (e.g. Discord after a switch to Telegram).
# Advisory: callers invoke it with `|| true`, so a mismatch warns but does not
# fail the restart. The provider is read at channels.sh startup, hence the check.
post_restart_channel_check() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "  - would verify channel provider rebind (dry-run)"
    return 0
  fi
  local expected="$CHANNEL_PROVIDER" actual
  sleep 2   # give the relaunched session a moment to bind
  actual="$(running_channel_provider)"
  if [ -z "$actual" ]; then
    echo "  ! channel rebind: running provider undetermined (session not up yet?)" >&2
    return 0
  fi
  if [ "$actual" = "$expected" ]; then
    echo "  ✓ channel rebind: bound to ${actual} (matches .env)"
    return 0
  fi
  echo "  ✗ channel rebind: bound to ${actual} but .env says ${expected} -- stale provider" >&2
  echo "    note: the dashboard caches CHANNEL_PROVIDER at startup; restart it too if it respawns the wrong one" >&2
  return 1
}

# ── main ─────────────────────────────────────────────────────────────────────
if [ "$LIST_ONLY" = "1" ]; then
  print_inventory
  exit 0
fi

if [ "$(platform_detect)" = "linux-pidfile" ]; then
  restart_pidfile
  exit $?
else
  restart_supervised
  exit $?
fi
