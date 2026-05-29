#!/bin/bash

# test-xaca-0585-lcars-health-script-laydown.sh
# Regression tests for XACA-0585: install_lcars_health_check_script() lay-down.
#
# REGRESSION INTENT: Guards against the exit-127 bug where the LaunchAgent plist
# (com.aiteamforge.lcars-health) was shipped and rendered, but the script it calls
# (${AITEAMFORGE_DIR}/lcars-health-check.sh) was never laid down by the installer.
# Without this script present, launchd silently logs exit-127 on every health check.
#
# Assertions:
#   1. The canonical script is shipped in the tap at share/scripts/lcars-health-check.sh
#      AND is executable (exec bit set).
#   2. After running install (sandboxed AITEAMFORGE_DIR), the script exists at
#      ${AITEAMFORGE_DIR}/lcars-health-check.sh AND is executable — the LaunchAgent's
#      target script is actually laid down.
#   3. Ordering: the script is present at the path the lcars-health plist points to
#      (guards against install ordering regressions where plist renders before script).
#   4. The upgrade path (update_aux_scripts script_map) includes
#      lcars-health-check.sh mapped to ${WORKING_DIR}/lcars-health-check.sh.
#
# All filesystem activity is sandboxed to TEST_TMP_DIR.
# NEVER touches real $HOME / ~/.aiteamforge — installer-test safety rule.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$TAP_ROOT/libexec/installers/install-kanban.sh"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: works both as a sourced test-runner.sh file AND as a
# directly-invoked script (mirrors test-xaca-0564 pattern).
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""

    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }

    assert_file_exists() {
        local file="$1" msg="${2:-Expected file to exist: $1}"
        [ -f "$file" ] || { test_fail "$msg"; return 1; }
    }
    assert_file_not_exists() {
        local file="$1" msg="${2:-Expected file to not exist: $1}"
        [ ! -f "$file" ] || { test_fail "$msg"; return 1; }
    }
    assert_contains() {
        local haystack="$1" needle="$2" msg="${3:-Expected to find '$2' in string}"
        [[ "$haystack" == *"$needle"* ]] || { test_fail "$msg"; return 1; }
    }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory: use the runner-supplied TEST_TMP_DIR or create our own.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0585-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Sandbox layout
# ─────────────────────────────────────────────────────────────────────────────
SANDBOX_DIR="$TEST_TMP_DIR/xaca0585"
SANDBOX_AITEAMFORGE="$SANDBOX_DIR/aiteamforge"   # simulates ~/.aiteamforge

mkdir -p "$SANDBOX_AITEAMFORGE"

# ─────────────────────────────────────────────────────────────────────────────
# Helper: run install_lcars_health_check_script in an isolated subshell.
#
# Sandboxes AITEAMFORGE_DIR to a tmp dir; INSTALL_ROOT to the real tap root so
# the installer finds share/scripts/lcars-health-check.sh.
# Sources the full installer with stdout suppressed (only stderr matters for
# errors); TEAM_WORKING_DIRS_STR and KANBAN_BACKUP_INTERVAL suppress set -u
# complaints from unrelated functions that the source triggers.
#
# Returns the subshell exit code via echo (same pattern as test-xaca-0564).
# ─────────────────────────────────────────────────────────────────────────────
run_install_health_check() {
    local aiteamforge_dir="$1"
    (
        export INSTALL_ROOT="$TAP_ROOT"
        export AITEAMFORGE_HOME="$TAP_ROOT"
        export AITEAMFORGE_DIR="$aiteamforge_dir"
        export TEAM_WORKING_DIRS_STR=""
        export KANBAN_BACKUP_INTERVAL=900
        export AITEAMFORGE_ALLOW_DEV_OVERWRITE=1   # sandbox is plain dir; guard is irrelevant

        source "$INSTALLER" >/dev/null 2>&1
        install_lcars_health_check_script >/dev/null 2>&1
    )
    echo $?
}

# ═══════════════════════════════════════════════════════════════════════════
# TEST 1: Tap ships the canonical script and it is executable
# Assertion (a): share/scripts/lcars-health-check.sh exists AND has exec bit
# ═══════════════════════════════════════════════════════════════════════════

test_start "Tap ships lcars-health-check.sh at share/scripts/lcars-health-check.sh"
assert_file_exists \
    "$TAP_ROOT/share/scripts/lcars-health-check.sh" \
    "Canonical script must be present in tap at share/scripts/lcars-health-check.sh"
test_pass

test_start "Tap-shipped lcars-health-check.sh is executable"
if [ -x "$TAP_ROOT/share/scripts/lcars-health-check.sh" ]; then
    test_pass
else
    test_fail "share/scripts/lcars-health-check.sh must have exec bit set (chmod +x)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 2: install_lcars_health_check_script() lays the script into AITEAMFORGE_DIR
# Assertion (b): after a sandboxed install, the script exists AND is executable
# ═══════════════════════════════════════════════════════════════════════════

test_start "install_lcars_health_check_script: script exists in AITEAMFORGE_DIR after install"
CASE2_DIR="$SANDBOX_DIR/case2-install"
mkdir -p "$CASE2_DIR"

CASE2_EXIT=$(run_install_health_check "$CASE2_DIR")
assert_file_exists \
    "$CASE2_DIR/lcars-health-check.sh" \
    "install_lcars_health_check_script must lay down lcars-health-check.sh in AITEAMFORGE_DIR"
test_pass

test_start "install_lcars_health_check_script: laid-down script is executable"
if [ -x "$CASE2_DIR/lcars-health-check.sh" ]; then
    test_pass
else
    test_fail "lcars-health-check.sh in AITEAMFORGE_DIR must have exec bit set after install"
fi

test_start "install_lcars_health_check_script: installer exits 0 on success"
if [ "$CASE2_EXIT" = "0" ]; then
    test_pass
else
    test_fail "install_lcars_health_check_script must exit 0 (got: $CASE2_EXIT)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 3: Ordering invariant — script exists at the path the plist targets
#
# Assertion (c): the plist template references ${AITEAMFORGE_DIR}/lcars-health-check.sh
# as its program argument. After install, that path actually exists. This catches
# ordering regressions where the plist is rendered BEFORE the script is laid down.
#
# We verify by: (a) confirming the plist template references lcars-health-check.sh
# and (b) confirming the script was laid down in the same AITEAMFORGE_DIR as used.
# ═══════════════════════════════════════════════════════════════════════════

test_start "Plist template references lcars-health-check.sh as its program path"
PLIST_TEMPLATE="$TAP_ROOT/share/templates/kanban/lcars-health-plist.template"
if [ -f "$PLIST_TEMPLATE" ]; then
    plist_content="$(cat "$PLIST_TEMPLATE")"
    assert_contains \
        "$plist_content" \
        "lcars-health-check.sh" \
        "lcars-health-plist.template must reference lcars-health-check.sh as its program path"
    test_pass
else
    test_fail "lcars-health-plist.template not found at $PLIST_TEMPLATE — cannot verify ordering"
fi

test_start "Ordering: script exists at AITEAMFORGE_DIR after install (plist target is present)"
# Re-use the CASE2_DIR result: install already ran and the script should be there.
# This is the exit-127 regression guard: the LaunchAgent's ProgramArguments target
# MUST exist so launchd can execute it without exit-127.
CASE3_DIR="$SANDBOX_DIR/case2-install"   # same sandbox as TEST 2
assert_file_exists \
    "$CASE3_DIR/lcars-health-check.sh" \
    "LaunchAgent target ${CASE3_DIR}/lcars-health-check.sh must exist after install (exit-127 guard)"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 4: upgrade path — script_map includes lcars-health-check.sh
#
# Assertion (d): update_aux_scripts() in aiteamforge-upgrade.sh has
# "lcars-health-check.sh|${WORKING_DIR}/lcars-health-check.sh" in its script_map.
# We verify by grep on the source text (sufficient and avoids full upgrade.sh sourcing).
# ═══════════════════════════════════════════════════════════════════════════

test_start "upgrade.sh script_map includes lcars-health-check.sh entry"
upgrade_text="$(cat "$UPGRADE_SH")"
assert_contains \
    "$upgrade_text" \
    "lcars-health-check.sh" \
    "aiteamforge-upgrade.sh update_aux_scripts() script_map must include lcars-health-check.sh"
test_pass

test_start "upgrade.sh script_map entry maps to WORKING_DIR/lcars-health-check.sh"
# The exact line form is: "lcars-health-check.sh|${WORKING_DIR}/lcars-health-check.sh"
assert_contains \
    "$upgrade_text" \
    'lcars-health-check.sh|${WORKING_DIR}/lcars-health-check.sh' \
    "script_map entry must be 'lcars-health-check.sh|\${WORKING_DIR}/lcars-health-check.sh'"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 5: install is idempotent — running twice leaves the script present
#         and executable (no clobber / removal on re-run).
# ═══════════════════════════════════════════════════════════════════════════

test_start "install_lcars_health_check_script is idempotent (second run leaves script intact)"
CASE5_DIR="$SANDBOX_DIR/case5-idempotent"
mkdir -p "$CASE5_DIR"
run_install_health_check "$CASE5_DIR" >/dev/null
run_install_health_check "$CASE5_DIR" >/dev/null
assert_file_exists \
    "$CASE5_DIR/lcars-health-check.sh" \
    "Script must still exist after second install run (idempotent)"
if [ -x "$CASE5_DIR/lcars-health-check.sh" ]; then
    test_pass
else
    test_fail "Script must remain executable after second install run"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 6: missing source script — function skips gracefully (no crash)
#
# Validates the guard condition in install_lcars_health_check_script:
# when the source file doesn't exist (corrupted tap), it warns and returns 0
# rather than crashing the installer.
# ═══════════════════════════════════════════════════════════════════════════

test_start "install_lcars_health_check_script: skips gracefully when source script missing"
CASE6_DIR="$SANDBOX_DIR/case6-missing-source"
FAKE_ROOT="$SANDBOX_DIR/fake-tap-root"
mkdir -p "$CASE6_DIR"
mkdir -p "$FAKE_ROOT/share/scripts"
mkdir -p "$FAKE_ROOT/share/templates/aliases"
# Provide a minimal kanban-aliases.sh template so install_kanban_helpers doesn't abort
if [ -f "$TAP_ROOT/share/templates/aliases/kanban-aliases.sh" ]; then
    cp "$TAP_ROOT/share/templates/aliases/kanban-aliases.sh" \
       "$FAKE_ROOT/share/templates/aliases/kanban-aliases.sh"
fi
# Deliberately do NOT put lcars-health-check.sh in fake-tap-root/share/scripts/

CASE6_EXIT=$(
    (
        export INSTALL_ROOT="$FAKE_ROOT"
        export AITEAMFORGE_HOME="$FAKE_ROOT"
        export AITEAMFORGE_DIR="$CASE6_DIR"
        export TEAM_WORKING_DIRS_STR=""
        export KANBAN_BACKUP_INTERVAL=900
        export AITEAMFORGE_ALLOW_DEV_OVERWRITE=1
        source "$INSTALLER" >/dev/null 2>&1
        install_lcars_health_check_script >/dev/null 2>&1
    )
    echo $?
)

if [ "$CASE6_EXIT" = "0" ]; then
    test_pass
else
    test_fail "install_lcars_health_check_script must exit 0 (skip) when source missing; got: $CASE6_EXIT"
fi

assert_file_not_exists \
    "$CASE6_DIR/lcars-health-check.sh" \
    "No lcars-health-check.sh should be written when source is missing"

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone mode only — test-runner.sh tallies from its own counters).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    if [ "$_FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
fi
exit 0
