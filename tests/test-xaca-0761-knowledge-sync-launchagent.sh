#!/bin/bash

# test-xaca-0761-knowledge-sync-launchagent.sh
#
# XACA-0761 (005): tap-sandbox functional coverage for the knowledge-sync
# LaunchAgent installer (install_knowledge_sync_launchagent() in
# install-kanban.sh, XACA-0761-003) and the upgrade-path registration guard
# (XACA-0761-004). Every case runs entirely under TEST_TMP_DIR — NO real
# ~/knowledge, NO real ~/Library/LaunchAgents, NO real launchctl, NO network.
#
# Cases:
#   1. Fail-soft: no clone at all (root path never existed) — installer
#      skips, exit 0, no plist rendered.
#   1b. Fail-soft: no clone — a non-git husk directory in the way (root
#       exists but has no .git) — same gate, same outcome.
#   2. Fail-soft: no auth, end-to-end chain — install_knowledge_repo() is run
#      FIRST against an unreachable/bogus remote (simulating the XACA-0750
#      deploy-key auth gate never having been granted on this box), which
#      soft-skips and leaves ~/knowledge absent (XACA-0747 T4 behavior);
#      install_knowledge_sync_launchagent() is then run against that same
#      root and must ALSO soft-skip — verifying the fail-soft contract holds
#      across the whole install_kanban_system call chain, not just when the
#      launchagent installer is invoked in isolation.
#   3. Idempotent re-run: a REAL git clone root, ran through the installer
#      twice back-to-back — both runs exit 0, both render byte-identical
#      plists, the script is copied both times, no errors either run.
#   4. Upgrade-path registration guard (XACA-0761-004 lesson, XACA-0751-class
#      regression): the sibling structural suite
#      tests/test-knowledge-sync-upgrade-registration.sh exists and passes
#      standalone — asserting update_knowledge_sync is CALLED (not merely
#      defined) in aiteamforge-upgrade.sh's run sequence, so an
#      already-installed fleet machine actually receives the daemon on
#      `brew upgrade`, not just a fresh `aiteamforge setup`.
#
# Runs standalone (`bash tests/test-xaca-0761-knowledge-sync-launchagent.sh`)
# OR via test-runner.sh (which exports test_start/test_pass/test_fail +
# TEST_TMP_DIR + the assert_* helpers). Exit 0 = all pass, exit 1 = any fail.
#
# Requires: bash, git.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$TAP_ROOT/libexec/installers/install-kanban.sh"
UPGRADE_REGISTRATION_SUITE="$SCRIPT_DIR/test-knowledge-sync-upgrade-registration.sh"

for _need in "$INSTALLER" "$UPGRADE_REGISTRATION_SUITE"; do
    if [ ! -f "$_need" ]; then
        echo "FATAL: required file not found: $_need" >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: no-op-compatible stubs when test-runner.sh has not
# exported the real harness (mirrors test-xaca-0747-knowledge-repo.sh).
# ─────────────────────────────────────────────────────────────────────────────
if ! type -t test_start >/dev/null 2>&1; then
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory: runner-supplied TEST_TMP_DIR or our own.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0761-sync-launchagent.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
WORK_DIR="$TEST_TMP_DIR/xaca0761-launchagent"
mkdir -p "$WORK_DIR"

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

_next_home() { mktemp -d "$WORK_DIR/home-XXXXXX"; }

# ─────────────────────────────────────────────────────────────────────────────
# Run install_knowledge_sync_launchagent() in a sandboxed bash subshell.
# Usage: _run_sync_launchagent <home_dir> <global_root>
# Stdout/stderr captured to $R_STDOUT / $R_STDERR; echoes the exit code.
#
# launchctl is stubbed as a bash function (never on PATH, never the real
# binary) so `launchctl list` unconditionally reports the label as
# registered — the same pattern test-xaca-0651-consumer-doctor-gaps.sh uses
# for install_backup_launchagent's functional case. No real launchd is ever
# touched.
# ─────────────────────────────────────────────────────────────────────────────
R_STDOUT="$WORK_DIR/r-stdout.txt"
R_STDERR="$WORK_DIR/r-stderr.txt"
_run_sync_launchagent() {
    local home_dir="$1" global_root="$2"
    (
        set -uo pipefail
        export INSTALL_ROOT="$TAP_ROOT"
        export AITEAMFORGE_HOME="$TAP_ROOT"
        export AITEAMFORGE_DIR="$home_dir/aiteamforge"
        export HOME="$home_dir"
        export KB_KNOWLEDGE_GLOBAL_ROOT="$global_root"
        mkdir -p "$AITEAMFORGE_DIR" "$home_dir/Library/LaunchAgents"

        # Stub launchctl: record calls but never touch real launchd.
        launchctl() {
            if [ "${1:-}" = "list" ]; then
                echo "com.aiteamforge.knowledge-sync"
            fi
            return 0
        }
        export -f launchctl

        source "$INSTALLER" >"$R_STDOUT" 2>"$R_STDERR"
        install_knowledge_sync_launchagent >>"$R_STDOUT" 2>>"$R_STDERR"
    )
    echo $?
}

# Same as above but for install_knowledge_repo() (used in Case 2's chain).
_run_knowledge_repo() {
    local home_dir="$1" global_root="$2" repo_url="$3"
    (
        set -uo pipefail
        export INSTALL_ROOT="$TAP_ROOT"
        export AITEAMFORGE_HOME="$TAP_ROOT"
        export AITEAMFORGE_DIR="$home_dir/aiteamforge"
        export HOME="$home_dir"
        export KB_KNOWLEDGE_GLOBAL_ROOT="$global_root"
        export KB_KNOWLEDGE_REPO_URL="$repo_url"
        export DRY_RUN=false
        export TEAM_WORKING_DIRS_STR=""
        export KANBAN_BACKUP_INTERVAL=900
        mkdir -p "$AITEAMFORGE_DIR"
        export GIT_CONFIG_GLOBAL="$home_dir/.gitconfig"
        git config --file "$GIT_CONFIG_GLOBAL" user.email test@example.com
        git config --file "$GIT_CONFIG_GLOBAL" user.name "Sandbox"

        launchctl() { return 0; }
        export -f launchctl

        source "$INSTALLER" >"$R_STDOUT" 2>"$R_STDERR"
        install_knowledge_repo >>"$R_STDOUT" 2>>"$R_STDERR"
    )
    echo $?
}
_r_out() { cat "$R_STDOUT" 2>/dev/null; }

_plist_dest_for() { echo "$1/Library/LaunchAgents/com.aiteamforge.knowledge-sync.plist"; }

# ═══════════════════════════════════════════════════════════════════════════
# CASE 1 — fail-soft: no clone at all (root path never existed)
# ═══════════════════════════════════════════════════════════════════════════
test_start "Case 1 — fail-soft/no-clone: root path never existed → skip, exit 0, no plist"
C1_HOME=$(_next_home); C1_ROOT="$C1_HOME/knowledge"
C1_RC=$(_run_sync_launchagent "$C1_HOME" "$C1_ROOT")
C1_PLIST="$(_plist_dest_for "$C1_HOME")"
C1_OUT="$(_r_out)"
if [ "$C1_RC" = "0" ] && [ ! -f "$C1_PLIST" ] && echo "$C1_OUT" | grep -qi "not a git clone"; then
    test_pass
else
    test_fail "rc=$C1_RC plist_exists=$([ -f "$C1_PLIST" ] && echo y || echo n); out_tail=$(echo "$C1_OUT" | tail -5)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE 1b — fail-soft: no clone — non-git husk directory in the way
# ═══════════════════════════════════════════════════════════════════════════
test_start "Case 1b — fail-soft/no-clone: non-git husk directory → same gate, skip, no plist"
C1B_HOME=$(_next_home); C1B_ROOT="$C1B_HOME/knowledge"
mkdir -p "$C1B_ROOT/agents"
echo "husk, not a real clone" > "$C1B_ROOT/agents/INDEX.md"
C1B_RC=$(_run_sync_launchagent "$C1B_HOME" "$C1B_ROOT")
C1B_PLIST="$(_plist_dest_for "$C1B_HOME")"
C1B_OUT="$(_r_out)"
if [ "$C1B_RC" = "0" ] && [ ! -f "$C1B_PLIST" ] \
    && [ -f "$C1B_ROOT/agents/INDEX.md" ] \
    && echo "$C1B_OUT" | grep -qi "not a git clone"; then
    test_pass
else
    test_fail "rc=$C1B_RC plist_exists=$([ -f "$C1B_PLIST" ] && echo y || echo n) husk_intact=$([ -f "$C1B_ROOT/agents/INDEX.md" ] && echo y || echo n); out_tail=$(echo "$C1B_OUT" | tail -5)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE 2 — fail-soft: no auth, end-to-end chain (install_knowledge_repo's
# auth gate fails first, THEN the launchagent installer runs against the
# same untouched root — mirrors the real install_kanban_system call order).
# ═══════════════════════════════════════════════════════════════════════════
test_start "Case 2 — fail-soft/no-auth (chained): auth-gate failure leaves root absent, launchagent installer also skips"
C2_HOME=$(_next_home); C2_ROOT="$C2_HOME/knowledge"
C2_BOGUS_URL="file://$WORK_DIR/no-such-repo-unauthorized.git"

C2_REPO_RC=$(_run_knowledge_repo "$C2_HOME" "$C2_ROOT" "$C2_BOGUS_URL")
test_start "Case 2 — anti-vacuity: install_knowledge_repo itself soft-skipped (root still absent)"
if [ "$C2_REPO_RC" = "0" ] && [ ! -e "$C2_ROOT" ]; then
    test_pass
else
    test_fail "Setup failed: expected install_knowledge_repo to soft-skip with root absent; rc=$C2_REPO_RC root_exists=$([ -e "$C2_ROOT" ] && echo y || echo n)"
fi

C2_RC=$(_run_sync_launchagent "$C2_HOME" "$C2_ROOT")
C2_PLIST="$(_plist_dest_for "$C2_HOME")"
C2_OUT="$(_r_out)"
test_start "Case 2 — fail-soft/no-auth (chained): launchagent installer skips, exit 0, no plist"
if [ "$C2_RC" = "0" ] && [ ! -f "$C2_PLIST" ] && echo "$C2_OUT" | grep -qi "not a git clone"; then
    test_pass
else
    test_fail "rc=$C2_RC plist_exists=$([ -f "$C2_PLIST" ] && echo y || echo n); out_tail=$(echo "$C2_OUT" | tail -5)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE 3 — idempotent re-run over a real git clone: two back-to-back runs,
# both succeed, both render byte-identical plists, no errors either run.
# ═══════════════════════════════════════════════════════════════════════════
test_start "Case 3 — idempotent re-run: real clone root, ran twice, identical rendered plist both times"
C3_HOME=$(_next_home); C3_ROOT="$C3_HOME/knowledge"
mkdir -p "$C3_ROOT"
(
    cd "$C3_ROOT"
    git init -q
    git config user.email test@example.com
    git config user.name "Sandbox"
    echo "knowledge fixture" > INDEX.md
    git add -A
    git commit -q -m "fixture commit"
) || true

C3_RC1=$(_run_sync_launchagent "$C3_HOME" "$C3_ROOT")
C3_PLIST="$(_plist_dest_for "$C3_HOME")"
C3_SCRIPT_DEST="$C3_HOME/aiteamforge/scripts/kb-knowledge-sync.sh"
C3_OUT1="$(_r_out)"
C3_RENDERED_1="$(cat "$C3_PLIST" 2>/dev/null)"

test_start "Case 3 — first run: exit 0, plist rendered, script installed, success logged"
if [ "$C3_RC1" = "0" ] && [ -f "$C3_PLIST" ] && [ -f "$C3_SCRIPT_DEST" ] \
    && echo "$C3_OUT1" | grep -qi "LaunchAgent installed"; then
    test_pass
else
    test_fail "rc=$C3_RC1 plist=$([ -f "$C3_PLIST" ] && echo y || echo n) script=$([ -f "$C3_SCRIPT_DEST" ] && echo y || echo n); out_tail=$(echo "$C3_OUT1" | tail -5)"
fi

test_start "Case 3 — first run: rendered plist has no unsubstituted {{placeholder}} tokens"
if [ -n "$C3_RENDERED_1" ] && ! echo "$C3_RENDERED_1" | grep -q '{{'; then
    test_pass
else
    test_fail "Rendered plist is empty or still contains a {{placeholder}} token"
fi

C3_RC2=$(_run_sync_launchagent "$C3_HOME" "$C3_ROOT")
C3_OUT2="$(_r_out)"
C3_RENDERED_2="$(cat "$C3_PLIST" 2>/dev/null)"

test_start "Case 3 — second (idempotent) run: exit 0, no errors"
if [ "$C3_RC2" = "0" ] && [ -z "$(cat "$R_STDERR" 2>/dev/null)" ]; then
    test_pass
else
    test_fail "rc=$C3_RC2 stderr=$(cat "$R_STDERR" 2>/dev/null | tail -5)"
fi

test_start "Case 3 — second (idempotent) run: rendered plist byte-identical to the first run"
if [ "$C3_RENDERED_1" = "$C3_RENDERED_2" ] && [ -n "$C3_RENDERED_2" ]; then
    test_pass
else
    test_fail "Rendered plist changed between runs (not idempotent)"
fi

test_start "Case 3 — second (idempotent) run: script still present and installed again cleanly"
if [ -f "$C3_SCRIPT_DEST" ] && echo "$C3_OUT2" | grep -qi "LaunchAgent installed"; then
    test_pass
else
    test_fail "script_present=$([ -f "$C3_SCRIPT_DEST" ] && echo y || echo n); out_tail=$(echo "$C3_OUT2" | tail -5)"
fi

if command -v plutil >/dev/null 2>&1; then
    test_start "Case 3 — rendered plist is well-formed (plutil -lint)"
    if plutil -lint "$C3_PLIST" >/dev/null 2>&1; then
        test_pass
    else
        test_fail "plutil -lint failed on the rendered plist"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE 4 — upgrade-path registration guard (XACA-0761-004 / XACA-0751 lesson):
# the sibling structural suite must exist and pass standalone. This is
# deliberately a thin pass-through rather than a re-implementation — the
# actual T1-T5 structural assertions (defined-but-called, ordering, reuse,
# not-in-skip-array) live in test-knowledge-sync-upgrade-registration.sh and
# should not be duplicated here.
# ═══════════════════════════════════════════════════════════════════════════
test_start "Case 4 — upgrade-path registration guard: sibling structural suite passes standalone"
# Deliberately force the sibling suite down its OWN standalone-framework path
# (its "if ! type -t test_start" branch) rather than silently inheriting this
# suite's test_start/test_pass/test_fail via bash's function-export
# mechanism. When run under the real tests/test-runner.sh harness, those
# functions ARE exported (export -f) and DO propagate into a plain `bash
# <file>` child — which would make the sibling script skip its own
# _PASS_COUNT/_FAIL_COUNT bookkeeping entirely and fall through to its final
# unconditional `exit 0`, turning this assertion into a vacuous pass no
# matter what T1-T5 actually did. `unset -f` strips the inherited exports
# before invoking bash, so the sibling suite reliably self-reports via its
# own summary line ("N passed, M failed") regardless of which harness this
# suite itself is running under.
C4_OUT="$(
    unset -f test_start test_pass test_fail print_verbose print_success print_error print_warning print_info 2>/dev/null
    bash "$UPGRADE_REGISTRATION_SUITE" 2>&1
)"
C4_RC=$?
if [ "$C4_RC" = "0" ] && echo "$C4_OUT" | grep -qE "0 failed"; then
    test_pass
else
    test_fail "sibling suite did not pass cleanly: rc=$C4_RC; out_tail=$(echo "$C4_OUT" | tail -10)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Standalone summary + exit code (no-op under test-runner.sh, which owns totals)
# ═══════════════════════════════════════════════════════════════════════════
if [ -n "${_PASS_COUNT+x}" ]; then
    echo ""
    echo "XACA-0761 knowledge-sync-launchagent tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
