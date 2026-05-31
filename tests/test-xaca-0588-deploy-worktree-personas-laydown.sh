#!/bin/bash

# test-xaca-0588-deploy-worktree-personas-laydown.sh
# Regression tests for XACA-0588: install_worktree_personas_script() lay-down.
#
# REGRESSION INTENT: Guards against the class of bug where deploy-worktree-personas.sh
# is referenced by the wt-new hook (via the -x "$_dwp" guard) but was never seeded
# into $AITEAMFORGE_DIR/scripts/ by the installer. Without this file present, the
# hook silently skips persona deployment on every worktree creation — the tap-machine
# worktree persona deployment feature (XACA-0588) is a complete silent no-op.
# Mirrors the structure of test-xaca-0585-lcars-health-script-laydown.sh.
#
# Assertions:
#   1. The canonical script is shipped in the tap at share/scripts/deploy-worktree-personas.sh
#      AND is executable (exec bit set).
#   2. After running install (sandboxed AITEAMFORGE_DIR), the script exists at
#      ${AITEAMFORGE_DIR}/scripts/deploy-worktree-personas.sh AND is executable — the
#      wt-new hook's -x target is actually laid down.
#   3. The upgrade path (update_aux_scripts script_map) includes
#      deploy-worktree-personas.sh mapped to ${WORKING_DIR}/scripts/deploy-worktree-personas.sh.
#   4. install is idempotent — running twice leaves the script present and executable.
#   5. Missing source script — function skips gracefully (no crash, exit 0).
#
# All filesystem activity is sandboxed to TEST_TMP_DIR.
# NEVER touches real $HOME / ~/.aiteamforge — installer-test safety rule.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$TAP_ROOT/libexec/installers/install-kanban.sh"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: works both as a sourced test-runner.sh file AND as a
# directly-invoked script (mirrors test-xaca-0585 pattern).
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
    TEST_TMP_DIR="$(mktemp -d -t xaca0588-test.XXXXXX)"
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
SANDBOX_DIR="$TEST_TMP_DIR/xaca0588"
SANDBOX_AITEAMFORGE="$SANDBOX_DIR/aiteamforge"   # simulates ~/.aiteamforge

mkdir -p "$SANDBOX_AITEAMFORGE"

# ─────────────────────────────────────────────────────────────────────────────
# Helper: run install_worktree_personas_script in an isolated subshell.
#
# Sandboxes AITEAMFORGE_DIR to a tmp dir; INSTALL_ROOT to the real tap root so
# the installer finds share/scripts/deploy-worktree-personas.sh.
# Sources the full installer with stdout suppressed (only stderr matters for
# errors); TEAM_WORKING_DIRS_STR and KANBAN_BACKUP_INTERVAL suppress set -u
# complaints from unrelated functions that the source triggers.
#
# Returns the subshell exit code via echo (same pattern as test-xaca-0585).
# ─────────────────────────────────────────────────────────────────────────────
run_install_worktree_personas() {
    local aiteamforge_dir="$1"
    (
        export INSTALL_ROOT="$TAP_ROOT"
        export AITEAMFORGE_HOME="$TAP_ROOT"
        export AITEAMFORGE_DIR="$aiteamforge_dir"
        export TEAM_WORKING_DIRS_STR=""
        export KANBAN_BACKUP_INTERVAL=900
        export AITEAMFORGE_ALLOW_DEV_OVERWRITE=1   # sandbox is plain dir; guard is irrelevant

        source "$INSTALLER" >/dev/null 2>&1
        install_worktree_personas_script >/dev/null 2>&1
    )
    echo $?
}

# ═══════════════════════════════════════════════════════════════════════════
# TEST 1: Tap ships the canonical script and it is executable
# Assertion (a): share/scripts/deploy-worktree-personas.sh exists AND has exec bit
# ═══════════════════════════════════════════════════════════════════════════

test_start "Tap ships deploy-worktree-personas.sh at share/scripts/deploy-worktree-personas.sh"
assert_file_exists \
    "$TAP_ROOT/share/scripts/deploy-worktree-personas.sh" \
    "Canonical script must be present in tap at share/scripts/deploy-worktree-personas.sh"
test_pass

test_start "Tap-shipped deploy-worktree-personas.sh is executable"
if [ -x "$TAP_ROOT/share/scripts/deploy-worktree-personas.sh" ]; then
    test_pass
else
    test_fail "share/scripts/deploy-worktree-personas.sh must have exec bit set (chmod +x)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 2: install_worktree_personas_script() lays the script into AITEAMFORGE_DIR/scripts/
# Assertion (b): after a sandboxed install, the script exists AND is executable
# ═══════════════════════════════════════════════════════════════════════════

test_start "install_worktree_personas_script: script exists in AITEAMFORGE_DIR/scripts/ after install"
CASE2_DIR="$SANDBOX_DIR/case2-install"
mkdir -p "$CASE2_DIR"

CASE2_EXIT=$(run_install_worktree_personas "$CASE2_DIR")
assert_file_exists \
    "$CASE2_DIR/scripts/deploy-worktree-personas.sh" \
    "install_worktree_personas_script must lay down deploy-worktree-personas.sh in AITEAMFORGE_DIR/scripts/"
test_pass

test_start "install_worktree_personas_script: laid-down script is executable"
if [ -x "$CASE2_DIR/scripts/deploy-worktree-personas.sh" ]; then
    test_pass
else
    test_fail "deploy-worktree-personas.sh in AITEAMFORGE_DIR/scripts/ must have exec bit set after install"
fi

test_start "install_worktree_personas_script: installer exits 0 on success"
if [ "$CASE2_EXIT" = "0" ]; then
    test_pass
else
    test_fail "install_worktree_personas_script must exit 0 (got: $CASE2_EXIT)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 3: wt-new hook guard target — the installed path matches the -x guard
#
# The wt-new hook uses: [ -x "$_dwp" ] where $_dwp = $AITEAMFORGE_DIR/scripts/deploy-worktree-personas.sh
# This test confirms the EXACT path the hook tests is the path we lay down.
# Guards against regressions where the script is installed at the wrong subpath
# (e.g. AITEAMFORGE_DIR/deploy-worktree-personas.sh vs AITEAMFORGE_DIR/scripts/...).
# ═══════════════════════════════════════════════════════════════════════════

test_start "Hook guard target: script is at AITEAMFORGE_DIR/scripts/ (not root of AITEAMFORGE_DIR)"
CASE3_DIR="$SANDBOX_DIR/case2-install"   # re-use case 2 install result
# Verify the script is in scripts/ subdirectory
if [ -f "$CASE3_DIR/scripts/deploy-worktree-personas.sh" ]; then
    test_pass
else
    test_fail "deploy-worktree-personas.sh must be at AITEAMFORGE_DIR/scripts/ (wt-new hook guard target)"
fi

test_start "Hook guard: script is NOT at AITEAMFORGE_DIR root (wrong install path)"
assert_file_not_exists \
    "$CASE3_DIR/deploy-worktree-personas.sh" \
    "Script must NOT be at AITEAMFORGE_DIR root — wt-new -x guard uses AITEAMFORGE_DIR/scripts/ path"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 4: upgrade path — script_map includes deploy-worktree-personas.sh
#
# Assertion (c): update_aux_scripts() in aiteamforge-upgrade.sh has
# "deploy-worktree-personas.sh|${WORKING_DIR}/scripts/deploy-worktree-personas.sh"
# in its script_map. We verify by grep on the source text (sufficient and avoids
# full upgrade.sh sourcing).
# ═══════════════════════════════════════════════════════════════════════════

test_start "upgrade.sh script_map includes deploy-worktree-personas.sh entry"
upgrade_text="$(cat "$UPGRADE_SH")"
assert_contains \
    "$upgrade_text" \
    "deploy-worktree-personas.sh" \
    "aiteamforge-upgrade.sh update_aux_scripts() script_map must include deploy-worktree-personas.sh"
test_pass

test_start "upgrade.sh script_map entry maps to WORKING_DIR/scripts/deploy-worktree-personas.sh"
# The exact line form is: "deploy-worktree-personas.sh|${WORKING_DIR}/scripts/deploy-worktree-personas.sh"
assert_contains \
    "$upgrade_text" \
    'deploy-worktree-personas.sh|${WORKING_DIR}/scripts/deploy-worktree-personas.sh' \
    "script_map entry must be 'deploy-worktree-personas.sh|\${WORKING_DIR}/scripts/deploy-worktree-personas.sh'"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 5: install is idempotent — running twice leaves the script present
#         and executable (no clobber / removal on re-run).
# ═══════════════════════════════════════════════════════════════════════════

test_start "install_worktree_personas_script is idempotent (second run leaves script intact)"
CASE5_DIR="$SANDBOX_DIR/case5-idempotent"
mkdir -p "$CASE5_DIR"
run_install_worktree_personas "$CASE5_DIR" >/dev/null
run_install_worktree_personas "$CASE5_DIR" >/dev/null
assert_file_exists \
    "$CASE5_DIR/scripts/deploy-worktree-personas.sh" \
    "Script must still exist after second install run (idempotent)"
if [ -x "$CASE5_DIR/scripts/deploy-worktree-personas.sh" ]; then
    test_pass
else
    test_fail "Script must remain executable after second install run"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 6: missing source script — function skips gracefully (no crash)
#
# Validates the guard condition in install_worktree_personas_script:
# when the source file doesn't exist (corrupted tap), it warns and returns 0
# rather than crashing the installer.
# ═══════════════════════════════════════════════════════════════════════════

test_start "install_worktree_personas_script: skips gracefully when source script missing"
CASE6_DIR="$SANDBOX_DIR/case6-missing-source"
FAKE_ROOT="$SANDBOX_DIR/fake-tap-root-0588"
mkdir -p "$CASE6_DIR"
mkdir -p "$FAKE_ROOT/share/scripts"
mkdir -p "$FAKE_ROOT/share/templates/aliases"
# Provide a minimal kanban-aliases.sh template so install_kanban_helpers doesn't abort
if [ -f "$TAP_ROOT/share/templates/aliases/kanban-aliases.sh" ]; then
    cp "$TAP_ROOT/share/templates/aliases/kanban-aliases.sh" \
       "$FAKE_ROOT/share/templates/aliases/kanban-aliases.sh"
fi
# Deliberately do NOT put deploy-worktree-personas.sh in fake-tap-root/share/scripts/

CASE6_EXIT=$(
    (
        export INSTALL_ROOT="$FAKE_ROOT"
        export AITEAMFORGE_HOME="$FAKE_ROOT"
        export AITEAMFORGE_DIR="$CASE6_DIR"
        export TEAM_WORKING_DIRS_STR=""
        export KANBAN_BACKUP_INTERVAL=900
        export AITEAMFORGE_ALLOW_DEV_OVERWRITE=1
        source "$INSTALLER" >/dev/null 2>&1
        install_worktree_personas_script >/dev/null 2>&1
    )
    echo $?
)

if [ "$CASE6_EXIT" = "0" ]; then
    test_pass
else
    test_fail "install_worktree_personas_script must exit 0 (skip) when source missing; got: $CASE6_EXIT"
fi

assert_file_not_exists \
    "$CASE6_DIR/scripts/deploy-worktree-personas.sh" \
    "No deploy-worktree-personas.sh should be written when source is missing"

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
