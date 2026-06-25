#!/bin/bash
# Platform-agnostic service layer for the main agent's lifecycle scripts
# (restart.sh, uninstall.sh; start.sh / stop.sh may adopt it later). This file
# is SOURCED, never executed.
#
# The caller sets these before sourcing (each falls back to a sane default):
#   SLUG              main agent slug / unit prefix      (default: marveen)
#   CHANNEL_PROVIDER  telegram | slack | discord         (default: telegram)
#   INSTALL_DIR       repo / install root                (default: two dirs up)
#   BOT_NAME          display name for log lines         (default: Marveen)
#   DRY_RUN           "1" to print actions, change nothing (default: 0)
#
# The variation point across platforms is ONLY how long-running services are
# supervised:
#   linux-systemd : systemctl --user
#   macos         : launchctl (LaunchAgents)
#   linux-pidfile : pidfile + nohup (WSL / containers / no user-session systemd;
#                   this is also the Windows path, since the Windows installer is
#                   WSL-based and runs the Linux scripts inside the distro)
# Everything else -- channel state, pid-file pollers, seeded ~/.claude content --
# is identical across platforms and handled by the callers / shared helpers here.

: "${SLUG:=marveen}"
: "${CHANNEL_PROVIDER:=telegram}"
: "${BOT_NAME:=Marveen}"
: "${DRY_RUN:=0}"
: "${INSTALL_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

SYSTEMD_DIR="$HOME/.config/systemd/user"
LAUNCHD_DIR="$HOME/Library/LaunchAgents"

# Channel pollers: pid-file-backed processes that can pin a wedged inbound
# connection regardless of the supervisor (the plugin's own poller and the
# standalone channel-coordinator).
CHANNEL_DIR="$HOME/.claude/channels/${CHANNEL_PROVIDER}"
BOT_PIDFILE="${CHANNEL_DIR}/bot.pid"
COORD_PIDFILE="$HOME/.claude/channels/${CHANNEL_PROVIDER}-coordinator/coordinator.pid"

# ── platform detection ───────────────────────────────────────────────────────
# platform_detect -- echo the active platform id (cached in _PLATFORM).
platform_detect() {
  if [ -n "${_PLATFORM:-}" ]; then echo "$_PLATFORM"; return; fi
  case "$(uname -s)" in
    Darwin) _PLATFORM="macos" ;;
    *)
      if pidof systemd >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
        _PLATFORM="linux-systemd"
      else
        _PLATFORM="linux-pidfile"
      fi ;;
  esac
  echo "$_PLATFORM"
}

# svc_physical LOGICAL -- map a logical service name (dashboard|channels|morning)
# to the platform's physical unit/label. Empty when the platform has no such unit
# (e.g. macOS has no morning timer; the pidfile path has no morning process).
svc_physical() {
  local logical="$1"
  case "$(platform_detect)" in
    linux-systemd)
      case "$logical" in
        dashboard) echo "${SLUG}-dashboard.service" ;;
        channels)  echo "${SLUG}-channels.service" ;;
        morning)   echo "${SLUG}-morning.timer" ;;
      esac ;;
    macos)
      case "$logical" in
        dashboard) echo "com.${SLUG}.dashboard" ;;
        channels)  echo "com.${SLUG}.channels" ;;
      esac ;;
    linux-pidfile)
      case "$logical" in
        dashboard|channels) echo "$logical" ;;
      esac ;;
  esac
}

# svc_exists LOGICAL -- true if the platform unit for this logical name is present.
svc_exists() {
  local unit; unit="$(svc_physical "$1")"
  [ -n "$unit" ] || return 1
  case "$(platform_detect)" in
    linux-systemd) systemctl --user cat "$unit" >/dev/null 2>&1 ;;
    macos)         [ -e "${LAUNCHD_DIR}/${unit}.plist" ] ;;
    linux-pidfile) [ -f "${INSTALL_DIR}/store/${unit}.pid" ] ;;
  esac
}

# svc_is_active LOGICAL -- true if the unit is currently active/loaded.
svc_is_active() {
  local unit; unit="$(svc_physical "$1")"
  [ -n "$unit" ] || return 1
  case "$(platform_detect)" in
    linux-systemd) systemctl --user is-active --quiet "$unit" 2>/dev/null ;;
    macos)         launchctl list "$unit" >/dev/null 2>&1 ;;
    linux-pidfile)
      local pid; pid="$(cat "${INSTALL_DIR}/store/${unit}.pid" 2>/dev/null)"
      [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null ;;
  esac
}

# svc_restart LOGICAL -- restart one service in place. Honors DRY_RUN. Returns
# non-zero if the underlying restart command fails.
svc_restart() {
  local logical="$1" unit; unit="$(svc_physical "$logical")"
  [ -n "$unit" ] || { echo "  - ${logical}: no unit on this platform, skipping"; return 0; }
  if [ "$DRY_RUN" = "1" ]; then echo "  - ${unit}: would restart (dry-run)"; return 0; fi
  case "$(platform_detect)" in
    linux-systemd) systemctl --user restart "$unit" 2>/dev/null ;;
    macos)
      launchctl unload "${LAUNCHD_DIR}/${unit}.plist" 2>/dev/null || true
      launchctl load "${LAUNCHD_DIR}/${unit}.plist" 2>/dev/null ;;
    linux-pidfile)
      stop_pidfile "${INSTALL_DIR}/store/${unit}.pid" "$logical"
      return 0 ;;  # relaunch is the caller's job (start.sh)
  esac
}

# svc_stop / svc_disable / svc_remove -- uninstall-side verbs. All honor DRY_RUN.
svc_stop() {
  local unit; unit="$(svc_physical "$1")"; [ -n "$unit" ] || return 0
  case "$(platform_detect)" in
    linux-systemd) [ "$DRY_RUN" = "1" ] && { echo "  - would stop: $unit"; return 0; }; systemctl --user stop "$unit" 2>/dev/null || true ;;
    macos)         [ "$DRY_RUN" = "1" ] && { echo "  - would unload: $unit"; return 0; }; launchctl unload "${LAUNCHD_DIR}/${unit}.plist" 2>/dev/null || true ;;
    linux-pidfile) stop_pidfile "${INSTALL_DIR}/store/${unit}.pid" "$1" ;;
  esac
}

svc_disable() {
  local unit; unit="$(svc_physical "$1")"; [ -n "$unit" ] || return 0
  [ "$(platform_detect)" = "linux-systemd" ] || return 0
  [ "$DRY_RUN" = "1" ] && { echo "  - would disable: $unit"; return 0; }
  systemctl --user disable "$unit" 2>/dev/null || true
}

# svc_remove LOGICAL -- remove the on-disk unit/plist file (systemd / launchd).
svc_remove() {
  local unit; unit="$(svc_physical "$1")"; [ -n "$unit" ] || return 0
  case "$(platform_detect)" in
    linux-systemd) safe_rm "${SYSTEMD_DIR}/${unit}" ;;
    macos)         safe_rm "${LAUNCHD_DIR}/${unit}.plist" ;;
  esac
}

# svc_daemon_reload -- reload the supervisor's unit cache (systemd only).
svc_daemon_reload() {
  [ "$(platform_detect)" = "linux-systemd" ] || return 0
  [ "$DRY_RUN" = "1" ] || systemctl --user daemon-reload 2>/dev/null || true
}

# ── shared helpers ───────────────────────────────────────────────────────────
# stop_pidfile FILE LABEL -- stop a pidfile-backed process the reliable way:
# SIGTERM, wait, escalate to SIGKILL, verify, then remove the stale pidfile.
# Safe on missing file / malformed pid / already-dead process. Honors DRY_RUN.
stop_pidfile() {
  local pidfile="$1" label="$2" pid
  [ -f "$pidfile" ] || return 0
  pid="$(cat "$pidfile" 2>/dev/null)"
  if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    [ "$DRY_RUN" = "1" ] && { echo "  - ${label}: stale pidfile (no valid pid)"; return 0; }
    rm -f "$pidfile"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then echo "  - ${label} (pid ${pid}): would stop (dry-run)"; return 0; fi
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
# standalone channel-coordinator (coordinator.pid). Freeing these lets a stuck
# channel (e.g. a poller stranded on a stale provider after a Discord -> Telegram
# switch) recover when the channels session relaunches.
release_channel_pollers() {
  echo "${BOT_NAME}: releasing channel pollers (provider=${CHANNEL_PROVIDER})..."
  stop_pidfile "$BOT_PIDFILE" "channel poller (bot.pid)"
  stop_pidfile "$COORD_PIDFILE" "channel-coordinator"
}

# safe_rm PATH -- remove a path with guard rails: refuses empty, "/", $HOME, the
# install dir, and anything outside $HOME / $INSTALL_DIR. Honors DRY_RUN.
safe_rm() {
  local path="$1"
  [ -e "$path" ] || [ -L "$path" ] || return 0
  case "$path" in
    ""|"/"|"$HOME"|"$HOME/"|"$INSTALL_DIR"|"$INSTALL_DIR/")
      echo "  ✗ refusing to remove protected path: $path" >&2; return 1 ;;
  esac
  case "$path" in
    "$HOME"/*|"$INSTALL_DIR"/*) : ;;
    *) echo "  ✗ refusing to remove out-of-scope path: $path" >&2; return 1 ;;
  esac
  if [ "$DRY_RUN" = "1" ]; then
    echo "  - would remove: $path"
  else
    rm -rf "$path" && echo "  ✓ removed: $path"
  fi
}
