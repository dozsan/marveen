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
#   uninstall.sh --yes        skip the routine confirmation (NOT the purge gate)
#   uninstall.sh --force      skip the --purge data-deletion gate too (for CI)
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

# Platform service layer (platform_detect, svc_*, stop_pidfile,
# release_channel_pollers, safe_rm, SYSTEMD_DIR / LAUNCHD_DIR). Sourced after the
# identity vars so the lib picks up SLUG / CHANNEL_PROVIDER / INSTALL_DIR.
# shellcheck source=lib/platform.sh
source "$INSTALL_DIR/scripts/lib/platform.sh"

CLAUDE_DIR="$HOME/.claude"

PURGE=0
ASSUME_YES=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --purge)   PURGE=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# ── confirmation ─────────────────────────────────────────────────────────────
echo "${BOT_NAME} uninstall (SLUG=${SLUG}, provider=${CHANNEL_PROVIDER})"
echo "  install dir: $INSTALL_DIR"
[ "$PURGE" = "1" ] && echo "  --purge: WILL ALSO DELETE store/ (memory+kanban DB) and agents/ (the whole fleet)"
[ "$DRY_RUN" = "1" ] && echo "  --dry-run: no changes will be made"
if [ "$DRY_RUN" != "1" ] && [ "$ASSUME_YES" != "1" ] && [ "$FORCE" != "1" ]; then
  printf "Proceed? [y/N] "
  read -r reply
  case "$reply" in
    y|Y|yes|YES) : ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi
# Second, irreversible-data gate for --purge. Deliberately NOT skipped by --yes
# (which only covers the routine uninstall); only --force bypasses it, for CI.
# Without a typed DELETE we downgrade to a normal uninstall and keep the data.
if [ "$PURGE" = "1" ] && [ "$DRY_RUN" != "1" ] && [ "$FORCE" != "1" ]; then
  printf "  --purge deletes store/ + agents/ irreversibly. Type DELETE to confirm: "
  read -r purge_reply
  if [ "$purge_reply" != "DELETE" ]; then
    echo "  purge not confirmed -- keeping store/ and agents/ (proceeding with normal uninstall)."
    PURGE=0
  fi
fi

# ── 1. stop + remove services ────────────────────────────────────────────────
echo "Stopping services..."
PLATFORM="$(platform_detect)"

# Stop, disable and remove each logical service via the platform layer. svc_*
# are no-ops for services absent on the active platform (e.g. morning on macOS).
for logical in dashboard channels morning; do
  svc_stop "$logical"
  svc_disable "$logical"
  svc_remove "$logical"
done

# Platform-specific companions the logical verbs don't cover:
if [ "$PLATFORM" = "linux-systemd" ]; then
  # 'morning' maps to the .timer; its oneshot companion .service needs removing too.
  [ "$DRY_RUN" = "1" ] || systemctl --user stop "${SLUG}-morning.service" 2>/dev/null || true
  safe_rm "$SYSTEMD_DIR/${SLUG}-morning.service"
  svc_daemon_reload
elif [ "$PLATFORM" = "macos" ]; then
  # The channel-coordinator LaunchAgent (no logical service mapping).
  coord_plist="$LAUNCHD_DIR/com.marveen.channel-coordinator.plist"
  if [ -e "$coord_plist" ]; then
    [ "$DRY_RUN" = "1" ] || launchctl unload "$coord_plist" 2>/dev/null || true
    safe_rm "$coord_plist"
  fi
fi

# Tear down the channels tmux session, any leftover pidfile-backed processes,
# and the channel pollers (bot.pid / coordinator.pid) before the channel state
# dir is removed below.
[ "$DRY_RUN" = "1" ] || tmux kill-session -t "${SLUG}-channels" 2>/dev/null || true
stop_pidfile "$INSTALL_DIR/store/dashboard.pid" dashboard
stop_pidfile "$INSTALL_DIR/store/channels.pid" channels
release_channel_pollers

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
