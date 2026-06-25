#!/bin/bash
# E2E / contract tests for scripts/restart.sh, scripts/uninstall.sh and
# scripts/lib/platform.sh. Designed to run in a throwaway container.
# Run: bash scripts/__tests__/restart-uninstall.test.sh
#
# Isolation: every test uses a temp HOME and a temp INSTALL_DIR with a distinct
# SLUG (marveentest), so it never touches a real install, the real ~/.claude, or
# the real agent's systemd units. The portable tests (functions, dry-run,
# pidfile path, uninstall reverse) run anywhere. The real systemd-unit exercise
# is opt-in (RUN_SYSTEMD_TESTS=1) and only ever creates/removes a throwaway
# dummy unit -- never a marveen* unit.

set -u

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
assert_eq()    { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
assert_has()   { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }
assert_no()    { case "$2" in *"$3"*) fail "$1 (unexpected '$3')" ;; *) pass "$1" ;; esac; }
assert_exists(){ if [ -e "$2" ]; then pass "$1"; else fail "$1 ($2 missing)"; fi; }
assert_gone()  { if [ -e "$2" ]; then fail "$1 ($2 still present)"; else pass "$1"; fi; }

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
REAL_HOME="$HOME"   # captured before the per-test temp HOME override; systemd
                    # --user is user-bound (not HOME-bound), so the opt-in real
                    # systemd exercise must use the real user unit dir.
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------------------
# Build an isolated install tree + fake ~/.claude under a temp HOME.
# Echoes nothing; sets globals INSTALL_DIR / HOME for the duration.
# ---------------------------------------------------------------------------
make_install() {
  local id="$TMPROOT/install" home="$TMPROOT/home"
  rm -rf "$id" "$home"
  mkdir -p "$id/scripts/lib" "$id/store" "$id/agents" \
           "$id/seed-skills/seeded-skill-a" \
           "$id/seed-scheduled-tasks/seeded-task-b" \
           "$id/seed-scheduled-tasks/bumblebee-hygiene-scan/threat-intel" \
           "$id/templates/scheduled-tasks/tpl-task-c"
  cp "$REPO/scripts/restart.sh" "$REPO/scripts/uninstall.sh" "$id/scripts/"
  cp "$REPO/scripts/lib/platform.sh" "$id/scripts/lib/"
  { echo "MAIN_AGENT_ID=marveentest"; echo "CHANNEL_PROVIDER=telegram"; echo "BOT_NAME=MarveenTest"; } > "$id/.env"
  : > "$id/store/claudeclaw.db"          # fake user data (must survive default uninstall)
  : > "$id/agents/.keep"

  mkdir -p "$home/.claude/skills/seeded-skill-a" \
           "$home/.claude/skills/skill-factory" \
           "$home/.claude/skills/my-own-skill" \
           "$home/.claude/scheduled-tasks/seeded-task-b" \
           "$home/.claude/scheduled-tasks/tpl-task-c" \
           "$home/.claude/scheduled-tasks/my-own-task" \
           "$home/.claude/channels/telegram" \
           "$home/.claude/tools/bumblebee-threat-intel"
  echo "999999" > "$home/.claude/channels/telegram/bot.pid"   # dead pid (stale)
  : > "$home/.claude/channels/telegram/.env"

  INSTALL_DIR="$id"; HOME="$home"; export HOME
}

echo "restart.sh / uninstall.sh / platform.sh tests"
echo "============================================="

# ===========================================================================
echo ""; echo "(1) platform.sh -- unit mapping + helpers"
make_install
# shellcheck disable=SC2034  # consumed by the sourced platform.sh below
SLUG=marveentest CHANNEL_PROVIDER=telegram BOT_NAME=MarveenTest DRY_RUN=0
# shellcheck source=/dev/null
source "$INSTALL_DIR/scripts/lib/platform.sh"

_PLATFORM=linux-systemd
assert_eq "svc_physical dashboard (systemd)" "marveentest-dashboard.service" "$(svc_physical dashboard)"
assert_eq "svc_physical morning (systemd)"   "marveentest-morning.timer"     "$(svc_physical morning)"
_PLATFORM=macos
assert_eq "svc_physical dashboard (macos)"   "com.marveentest.dashboard"     "$(svc_physical dashboard)"
assert_eq "svc_physical morning (macos)"      ""                             "$(svc_physical morning)"
_PLATFORM=linux-pidfile
assert_eq "svc_physical channels (pidfile)"  "channels"                      "$(svc_physical channels)"
unset _PLATFORM

# stop_pidfile
sleep 60 & LIVE=$!; echo "$LIVE" > "$TMPROOT/live.pid"
stop_pidfile "$TMPROOT/live.pid" live >/dev/null
kill -0 "$LIVE" 2>/dev/null && fail "stop_pidfile stops a live process" || pass "stop_pidfile stops a live process"
assert_gone "stop_pidfile removes the pidfile" "$TMPROOT/live.pid"
echo "999999" > "$TMPROOT/dead.pid"; stop_pidfile "$TMPROOT/dead.pid" dead >/dev/null
assert_gone "stop_pidfile cleans a stale pidfile" "$TMPROOT/dead.pid"
stop_pidfile "$TMPROOT/none.pid" none >/dev/null && pass "stop_pidfile no-op on missing file" || fail "stop_pidfile missing-file"

# safe_rm guards
victim="$INSTALL_DIR/store/victim"; : > "$victim"
safe_rm "$victim" >/dev/null; assert_gone "safe_rm removes in-scope path" "$victim"
out="$(safe_rm "/" 2>&1)"; assert_has "safe_rm refuses /" "$out" "refusing"
out="$(safe_rm "$HOME" 2>&1)"; assert_has "safe_rm refuses \$HOME" "$out" "refusing"
out="$(safe_rm "/etc/passwd-nope" 2>&1)"; assert_eq "safe_rm no-op on missing out-of-scope" "" "$out"

# ===========================================================================
echo ""; echo "(2) restart.sh -- list + dry-run"
RST="$INSTALL_DIR/scripts/restart.sh"
out="$(bash "$RST" --list 2>&1)"
assert_has "list shows dashboard mapping" "$out" "dashboard ->"
assert_has "list shows channel pollers"   "$out" "bot.pid"
out="$(bash "$RST" --dry-run 2>&1)"
# In isolation the marveentest units are not registered with the real systemd,
# so each target is reported as "skipping"; on a container where they ARE
# installed it is "would restart". Either way the target is processed and
# nothing destructive happens.
assert_has "dry-run processes the dashboard target" "$out" "dashboard"
assert_no  "dry-run changes nothing (no '✓ ')" "$out" "✓ "
# force the pidfile path with a fake failing systemctl
fakebin="$TMPROOT/fakebin"; mkdir -p "$fakebin"; printf '#!/bin/bash\nexit 1\n' > "$fakebin/systemctl"; chmod +x "$fakebin/systemctl"
out="$(PATH="$fakebin:$PATH" bash "$RST" --dry-run 2>&1)"
assert_has "pidfile-path dry-run releases pollers" "$out" "releasing channel pollers"

# ===========================================================================
echo ""; echo "(3) uninstall.sh -- dry-run leaves everything in place"
UNI="$INSTALL_DIR/scripts/uninstall.sh"
out="$(bash "$UNI" --dry-run 2>&1)"
assert_has "dry-run would remove seeded skill"    "$out" "skills/seeded-skill-a"
assert_has "dry-run would remove channel state"   "$out" "channels/telegram"
assert_no  "dry-run keeps user-authored skill"    "$out" "skills/my-own-skill"
assert_exists "dry-run did NOT remove seeded skill" "$HOME/.claude/skills/seeded-skill-a"
assert_exists "dry-run did NOT remove data DB"      "$INSTALL_DIR/store/claudeclaw.db"

# ===========================================================================
echo ""; echo "(4) uninstall.sh -- real run: reverse + preserve + idempotent"
bash "$UNI" --yes >/dev/null 2>&1
assert_gone   "removes seeded skill"            "$HOME/.claude/skills/seeded-skill-a"
assert_gone   "removes skill-factory"           "$HOME/.claude/skills/skill-factory"
assert_gone   "removes seeded scheduled task"   "$HOME/.claude/scheduled-tasks/seeded-task-b"
assert_gone   "removes scaffolded task"         "$HOME/.claude/scheduled-tasks/tpl-task-c"
assert_gone   "removes channel state"           "$HOME/.claude/channels/telegram"
assert_gone   "removes threat-intel"            "$HOME/.claude/tools/bumblebee-threat-intel"
assert_gone   "removes install .env"            "$INSTALL_DIR/.env"
assert_exists "PRESERVES user-authored skill"   "$HOME/.claude/skills/my-own-skill"
assert_exists "PRESERVES user-authored task"    "$HOME/.claude/scheduled-tasks/my-own-task"
assert_exists "PRESERVES data DB (no --purge)"  "$INSTALL_DIR/store/claudeclaw.db"
assert_exists "PRESERVES agents/ (no --purge)"  "$INSTALL_DIR/agents"
# idempotent: a second run must not error
if bash "$UNI" --yes >/dev/null 2>&1; then pass "second uninstall run is idempotent (exit 0)"; else fail "second uninstall run errored"; fi

# ===========================================================================
echo ""; echo "(5) uninstall.sh --purge removes data"
make_install
bash "$INSTALL_DIR/scripts/uninstall.sh" --purge --yes >/dev/null 2>&1
assert_gone "purge removes store/"  "$INSTALL_DIR/store"
assert_gone "purge removes agents/" "$INSTALL_DIR/agents"

# ===========================================================================
echo ""; echo "(6) real systemd dummy-unit exercise (opt-in: RUN_SYSTEMD_TESTS=1)"
if [ "${RUN_SYSTEMD_TESTS:-0}" = "1" ] && pidof systemd >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
  UNITDIR="${XDG_CONFIG_HOME:-$REAL_HOME/.config}/systemd/user"; mkdir -p "$UNITDIR"
  cat > "$UNITDIR/marveentest-dummy.service" <<UNIT
[Unit]
Description=marveen e2e throwaway dummy
[Service]
Type=simple
ExecStart=/bin/sh -c 'while :; do sleep 3600; done'
UNIT
  systemctl --user daemon-reload
  systemctl --user start marveentest-dummy.service
  if systemctl --user is-active --quiet marveentest-dummy.service; then pass "dummy unit started"; else fail "dummy unit start"; fi
  systemctl --user restart marveentest-dummy.service
  if systemctl --user is-active --quiet marveentest-dummy.service; then pass "dummy unit restarts"; else fail "dummy unit restart"; fi
  systemctl --user stop marveentest-dummy.service
  systemctl --user disable marveentest-dummy.service 2>/dev/null || true
  rm -f "$UNITDIR/marveentest-dummy.service"; systemctl --user daemon-reload
  pass "dummy unit cleaned up"
else
  echo "  SKIP: set RUN_SYSTEMD_TESTS=1 on a host with a user systemd to run this"
fi

# ===========================================================================
echo ""
echo "============================================="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
