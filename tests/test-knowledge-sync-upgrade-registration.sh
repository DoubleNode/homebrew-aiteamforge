#!/bin/bash
# test-knowledge-sync-upgrade-registration.sh
#
# XACA-0761 (003/004): structural anti-regression guard, mirroring the XACA-0751
# lesson (see test-xaca-0751-upgrade-knowledge-repo.sh U9/U10).
#
# install_knowledge_sync_launchagent() (XACA-0761-003) materializes the
# knowledge-sync LaunchAgent, but its ONLY call site is install_kanban_system()
# — reached on a fresh `aiteamforge setup`, NEVER on `aiteamforge upgrade`.
# Without a SEPARATE upgrade-side call, every already-installed fleet machine
# would upgrade to a knowledge-sync-carrying release and never receive the
# LaunchAgent — the exact defect class XACA-0751 fixed for ~/knowledge itself
# (a defined-but-never-called update_* function ships green because the only
# tests that existed covered fresh-install states, not the upgrade run
# sequence). This suite is the "would have caught the original bug" guard:
# it fails if update_knowledge_sync is merely DEFINED but not CALLED in the
# run sequence.
#
# Checks (source-text / structural only — no functional plist rendering here,
# that lives in the install-kanban.sh installer tests):
#   T1  update_knowledge_sync() is defined in aiteamforge-upgrade.sh
#   T2  update_knowledge_sync is CALLED (bare line) in the run sequence
#   T3  update_knowledge_sync is called AFTER update_knowledge_repo (so
#       ~/knowledge is provisioned before the daemon-install gate checks it)
#   T4  update_knowledge_sync REUSES install_knowledge_sync_launchagent (no
#       reimplementation) — sources install-kanban.sh + calls the function
#   T5  com.aiteamforge.knowledge-sync is NOT added to update_launchagents's
#       `agents=()` array — that array SKIPS any agent not already installed
#       (`if [ ! -f "$target" ]; then continue`), so adding it there would
#       silently exclude every existing fleet machine from ever receiving the
#       plist (the exact wrong-fix this ticket exists to prevent)
#
# Pure source-text assertions against the real files — no sourcing, no
# sandboxed execution, no launchctl, no $HOME mutation. Safe under
# TEST_TMP_DIR (declared for house-style consistency; unused since this suite
# does no filesystem writes of its own).
#
# Runs standalone (`bash tests/test-knowledge-sync-upgrade-registration.sh`)
# OR via test-runner.sh. Exit 0 = all pass, exit 1 = any fail.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
INSTALLER="$TAP_ROOT/libexec/installers/install-kanban.sh"

for _need in "$UPGRADE_SH" "$INSTALLER"; do
    if [ ! -f "$_need" ]; then
        echo "FATAL: required file not found: $_need" >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: no-op-compatible stubs when test-runner.sh has not
# exported the real harness (mirrors test-xaca-0751 / test-xaca-0651 pattern).
# ─────────────────────────────────────────────────────────────────────────────
if ! type -t test_start >/dev/null 2>&1; then
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

# TEST_TMP_DIR-safe: use the runner-supplied dir if present, else our own
# (unused for writes — declared to satisfy the sandbox convention / any future
# extension of this suite that needs scratch space).
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0761-knowledge-sync-upgrade.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then
        find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════
# T1 — update_knowledge_sync() is defined
# ═══════════════════════════════════════════════════════════════════════════
test_start "T1: update_knowledge_sync() is defined in aiteamforge-upgrade.sh"
if grep -qE '^update_knowledge_sync\(\) \{' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "no 'update_knowledge_sync() {' definition found in $UPGRADE_SH"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T2 — STRUCTURAL: update_knowledge_sync is CALLED in the run sequence.
# This is the assertion that would have caught the XACA-0751-class bug: the
# function may exist but must be INVOKED as a bare call near the bottom of
# the file, not merely defined.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T2: update_knowledge_sync is invoked (bare call) in the upgrade run sequence"
if grep -qE '^update_knowledge_sync$' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "aiteamforge-upgrade.sh run sequence must call update_knowledge_sync (bare line) — a defined-but-never-called function means EXISTING fleet machines never receive the knowledge-sync LaunchAgent on upgrade (XACA-0751 lesson)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T3 — update_knowledge_sync's bare call appears AFTER update_knowledge_repo's.
# ~/knowledge must be provisioned (or soft-skipped) before the daemon-install
# fail-soft gate checks whether it's a real clone.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T3: update_knowledge_sync call is ordered AFTER update_knowledge_repo call"
_REPO_LINE=$(grep -nE '^update_knowledge_repo$' "$UPGRADE_SH" | head -1 | cut -d: -f1)
_SYNC_LINE=$(grep -nE '^update_knowledge_sync$' "$UPGRADE_SH" | head -1 | cut -d: -f1)
if [ -n "$_REPO_LINE" ] && [ -n "$_SYNC_LINE" ] && [ "$_SYNC_LINE" -gt "$_REPO_LINE" ]; then
    test_pass
else
    test_fail "expected update_knowledge_sync (line ${_SYNC_LINE:-MISSING}) to be called after update_knowledge_repo (line ${_REPO_LINE:-MISSING})"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T4 — update_knowledge_sync REUSES install_knowledge_sync_launchagent (no
# reimplementation), same idiom as update_knowledge_repo reusing
# install_knowledge_repo (source install-kanban.sh in a subshell, then call).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T4: update_knowledge_sync reuses install_knowledge_sync_launchagent (no reimplementation)"
UPD_FN_SRC="$TEST_TMP_DIR/update_knowledge_sync.extracted.sh"
awk '
  /^update_knowledge_sync\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$UPGRADE_SH" > "$UPD_FN_SRC"
if [ -s "$UPD_FN_SRC" ] \
    && grep -q "install-kanban.sh" "$UPD_FN_SRC" \
    && grep -qE '(^|[^_])install_knowledge_sync_launchagent\b' "$UPD_FN_SRC"; then
    test_pass
else
    test_fail "extracted update_knowledge_sync must source install-kanban.sh AND call install_knowledge_sync_launchagent"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T5 — com.aiteamforge.knowledge-sync must NOT be added to update_launchagents's
# `agents=()` array. That loop SKIPS any agent whose plist is not already on
# disk (`if [ ! -f "$target" ]; then continue`) — it is a refresh-existing
# mechanism, not a materialize-new one. Adding the plist there would silently
# exclude every pre-XACA-0761 fleet machine from ever receiving the daemon,
# which is the exact wrong-fix this ticket exists to prevent.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T5: com.aiteamforge.knowledge-sync is NOT in update_launchagents's skip-if-absent array"
AGENTS_FN_SRC="$TEST_TMP_DIR/update_launchagents.extracted.sh"
awk '
  /^update_launchagents\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "$UPGRADE_SH" > "$AGENTS_FN_SRC"
if [ -s "$AGENTS_FN_SRC" ] && ! grep -q "com.aiteamforge.knowledge-sync" "$AGENTS_FN_SRC"; then
    test_pass
else
    test_fail "com.aiteamforge.knowledge-sync must not appear inside update_launchagents() — its skip-if-absent loop would strand existing fleet machines without the daemon"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Standalone summary + exit code (no-op under test-runner.sh, which owns totals)
# ═══════════════════════════════════════════════════════════════════════════
if [ -n "${_PASS_COUNT+x}" ]; then
    echo ""
    echo "XACA-0761 knowledge-sync-upgrade-registration tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
