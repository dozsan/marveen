#!/bin/bash
# Uninstall the main agent -- the reverse of install.sh / install-linux.sh
# (and the macOS LaunchAgents from install-macos.sh).
#
# Conservative by default:
#   - Stops and removes the systemd user units (Linux) or LaunchAgents (macOS).
#   - Removes the channel state dir and the install-dir .env (secrets).
#   - Removes ONLY the ~/.claude content THIS repo seeds (skill-factory + seed
#     skills, the scaffolded/seeded scheduled tasks, the bumblebee threat-intel
#     catalogs) -- the list is computed from the repo, so anything you authored
#     yourself under ~/.claude is left untouched.
#   - PRESERVES user data by default: store/ (the SQLite DB with memory + kanban),
#     agents/, and the repo checkout itself.
#   - Does NOT touch shared Claude Code state: ~/.local/bin/claude, ~/.claude.json,
#     ~/.claude/settings.json, your shell rc, the installed channel plugin, or
#     loginctl linger. Those are printed as manual follow-ups.
#
# Usage:
#   uninstall.sh              remove services + seeded content (keeps your data)
#   uninstall.sh --purge      ALSO remove store/, agents/, node_modules, dist
#   uninstall.sh --dry-run    print what would be removed, change nothing
#   uninstall.sh --yes        skip the interactive confirmation
#
set -uo pipefail

INSTALL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# See channels.sh for why we grep instead of `set -a && source .env`.
if [ -f "$INSTALL_DIR/.env" ]; then
  SLUG="$(grep -E '^MAIN_AGENT_ID=' "$INSTALL_DIR/.env" | head -1 | cut -d= -f2-)"
  CHANNEL_PROVIDER="$(grep -E '^CHANNEL_PROVIDER=' "$INSTALL_DIR/.env" | head -1 | cut -d= -f2-)"
  BOT_NAME="$(grep -E '^BOT_NAME=' "$INSTALL_DIR/.env" | head -1 | cut -d= -f2-)"
fi
SLUG="${SLUG:-marveen}"
CHANNEL_PROVIDER="${CHANNEL_PROVIDER:-telegram}"
BOT_NAME="${BOT_NAME:-Marveen}"

DRY_RUN=0
PURGE=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --purge)   PURGE=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

SYSTEMD_DIR="$HOME/.config/systemd/user"
CLAUDE_DIR="$HOME/.claude"

# Guard against ever rm -rf'ing a dangerous path. Every removal goes through
# this: it refuses empty, "/", $HOME and the install dir itself, and only acts
# on paths under $HOME or $INSTALL_DIR.
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

# ── confirmation ─────────────────────────────────────────────────────────────
echo "${BOT_NAME} uninstall (SLUG=${SLUG}, provider=${CHANNEL_PROVIDER})"
echo "  install dir: $INSTALL_DIR"
[ "$PURGE" = "1" ] && echo "  --purge: WILL ALSO DELETE store/ (memory+kanban DB) and agents/"
[ "$DRY_RUN" = "1" ] && echo "  --dry-run: no changes will be made"
if [ "$DRY_RUN" != "1" ] && [ "$ASSUME_YES" != "1" ]; then
  printf "Proceed? [y/N] "
  read -r reply
  case "$reply" in
    y|Y|yes|YES) : ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

# ── 1. stop + remove services ────────────────────────────────────────────────
echo "Stopping services..."
OS="$(uname -s)"
if [ "$OS" = "Darwin" ]; then
  for unit in dashboard channels channel-coordinator; do
    plist="$HOME/Library/LaunchAgents/com.${SLUG}.${unit}.plist"
    [ "$unit" = "channel-coordinator" ] && plist="$HOME/Library/LaunchAgents/com.marveen.channel-coordinator.plist"
    if [ -e "$plist" ]; then
      [ "$DRY_RUN" = "1" ] || launchctl unload "$plist" 2>/dev/null || true
      safe_rm "$plist"
    fi
  done
else
  UNITS=("${SLUG}-dashboard.service" "${SLUG}-channels.service" "${SLUG}-morning.service" "${SLUG}-morning.timer")
  if pidof systemd >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
    for unit in "${UNITS[@]}"; do
      if systemctl --user cat "$unit" >/dev/null 2>&1; then
        if [ "$DRY_RUN" = "1" ]; then
          echo "  - would stop/disable: $unit"
        else
          systemctl --user stop "$unit" 2>/dev/null || true
          systemctl --user disable "$unit" 2>/dev/null || true
          echo "  ✓ stopped/disabled: $unit"
        fi
      fi
    done
  fi
  for unit in "${UNITS[@]}"; do
    safe_rm "$SYSTEMD_DIR/$unit"
  done
  [ "$DRY_RUN" = "1" ] || systemctl --user daemon-reload 2>/dev/null || true
fi

# Tear down the channels tmux session and any pidfile-backed fallback processes.
if [ "$DRY_RUN" != "1" ]; then
  tmux kill-session -t "${SLUG}-channels" 2>/dev/null || true
fi
for svc in dashboard channels; do
  pidfile="$INSTALL_DIR/store/${svc}.pid"
  if [ -f "$pidfile" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      echo "  - would stop pidfile process: $pidfile"
    else
      kill "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null || true
      rm -f "$pidfile"
    fi
  fi
done

# ── 2. channel state + secrets ───────────────────────────────────────────────
echo "Removing channel state and secrets..."
safe_rm "$CLAUDE_DIR/channels/$CHANNEL_PROVIDER"
safe_rm "$INSTALL_DIR/.env"

# ── 3. seeded ~/.claude content (repo-derived, so user content is untouched) ──
echo "Removing seeded ~/.claude content..."

# skills: skill-factory + everything under seed-skills/
safe_rm "$CLAUDE_DIR/skills/skill-factory"
if [ -d "$INSTALL_DIR/seed-skills" ]; then
  for d in "$INSTALL_DIR/seed-skills"/*/; do
    [ -d "$d" ] || continue
    safe_rm "$CLAUDE_DIR/skills/$(basename "$d")"
  done
fi

# scheduled tasks: scaffolded (templates/) + seeded (seed-scheduled-tasks/),
# matching the install loops. bumblebee-hygiene-scan is never seeded as a task.
for seed_root in "$INSTALL_DIR/templates/scheduled-tasks" "$INSTALL_DIR/seed-scheduled-tasks"; do
  [ -d "$seed_root" ] || continue
  for d in "$seed_root"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    [ "$name" = "bumblebee-hygiene-scan" ] && continue
    safe_rm "$CLAUDE_DIR/scheduled-tasks/$name"
  done
done

# bumblebee threat-intel catalogs
safe_rm "$CLAUDE_DIR/tools/bumblebee-threat-intel"

# ── 4. data + build artifacts (only with --purge) ────────────────────────────
if [ "$PURGE" = "1" ]; then
  echo "Purging user data and build artifacts..."
  safe_rm "$INSTALL_DIR/store"
  safe_rm "$INSTALL_DIR/agents"
  safe_rm "$INSTALL_DIR/node_modules"
  safe_rm "$INSTALL_DIR/dist"
  safe_rm "$HOME/.local/bin/bumblebee"
else
  echo "Keeping user data (store/, agents/). Use --purge to remove it."
fi

# ── manual follow-ups (shared / risky -- never auto-removed) ──────────────────
cat <<NOTE

Done. The following were left in place on purpose -- remove by hand if you want
a full teardown:
  - Claude Code itself:        ~/.local/bin/claude
  - Channel plugin:            claude plugin uninstall ${CHANNEL_PROVIDER}@claude-plugins-official
  - Shared Claude config:      ~/.claude.json and ~/.claude/settings.json
                               (install merged plugin/MCP entries into these)
  - Shell PATH line:           the 'export PATH="\$HOME/.local/bin:\$PATH"' entry
                               added to your ~/.bashrc / ~/.zshrc
  - Boot persistence (Linux):  sudo loginctl disable-linger "$USER"
  - The repo checkout:         $INSTALL_DIR
NOTE
