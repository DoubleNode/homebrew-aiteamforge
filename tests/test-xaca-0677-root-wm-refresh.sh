#!/bin/bash

# test-xaca-0677-root-wm-refresh.sh
# Regression tests for XACA-0677: update_runtime_helpers must refresh the
# ROOT-LEVEL iterm2_window_manager.py copy on upgrade.
#
# REGRESSION INTENT: open_lcars_tab (lcars-launch-helpers.sh) invokes
# ${WORKING_DIR}/iterm2_window_manager.py directly — NOT the scripts/ copy.
# install_iterm2_window_manager() lays the root copy down via plain `cp` at
# install time.  Prior to XACA-0677, update_runtime_helpers only swept into
# WORKING_DIR/scripts/, leaving upgraded boxes with a stale root copy missing
# the XACA-0652 iterm2_venv_bootstrap re-exec — so the LCARS web cockpit tab
# failed to create on upgraded machines.
#
# Fix: a tightly-scoped block at the end of update_runtime_helpers copies
#   share/scripts/iterm2_window_manager.py → ${WORKING_DIR}/iterm2_window_manager.py
# ONLY when the root copy already exists (XACA-0673 convention: upgrade never
# materialises absent files).  Dry-run aware.
#
# Assertions:
#   1. STALE-REFRESH: a stale root copy IS overwritten by update_runtime_helpers
#      (DRY_RUN=false) and afterwards matches the shipped source and contains
#      'import iterm2_venv_bootstrap'.
#   2. ABSENT-NOT-MATERIALISED: when no root copy exists, update_runtime_helpers
#      does NOT create one.
#   3. DRY-RUN: with DRY_RUN=true and a stale root copy present, the file is
#      NOT modified (content unchanged).
#   4. BOOTSTRAP-IMPORT: the refreshed root copy contains the bootstrap import
#      (the mechanism that fixes "iterm2 module not found" on upgraded boxes).
#
# Non-vacuous precondition guards (feedback_parity_test_wrong_shell_passes_vacuously):
#   Each test asserts the precondition state BEFORE running the function, then
#   asserts the expected post-state.  A vacuous green is impossible.
#
# All filesystem activity is sandboxed to TEST_TMP_DIR.
# NEVER touches real $HOME / ~/.aiteamforge — installer-test safety rule.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (works sourced by test-runner.sh OR invoked directly).
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
fi
if ! type -t assert_file_exists >/dev/null 2>&1; then
    assert_file_exists() { [ -f "$1" ] || { test_fail "${2:-Expected file to exist: $1}"; return 1; }; }
fi
if ! type -t assert_file_not_exists >/dev/null 2>&1; then
    assert_file_not_exists() { [ ! -f "$1" ] || { test_fail "${2:-Expected file to not exist: $1}"; return 1; }; }
fi
if ! type -t assert_contains >/dev/null 2>&1; then
    assert_contains() { [[ "$1" == *"$2"* ]] || { test_fail "${3:-Expected to find '$2' in content}"; return 1; }; }
fi
if ! type -t assert_not_contains >/dev/null 2>&1; then
    assert_not_contains() { [[ "$1" != *"$2"* ]] || { test_fail "${3:-Expected NOT to find '$2' in content}"; return 1; }; }
fi

# print_* stubs used by the extracted function.
for _p in print_section print_info print_success print_warning print_error; do
    if ! declare -f "$_p" >/dev/null 2>&1; then eval "${_p}() { :; }"; fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory (runner-supplied or our own).
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0677-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Extract the functions under test from upgrade.sh without sourcing the whole
# script (its main body has side effects). Each captured from `name() {`
# through the first column-0 `}`.
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$UPGRADE_SH"
}
for _fn in _xaca0608_render_team_script _xaca0608_aux_script_map \
           _xaca0608_aux_scriptdir_basenames _xaca0673_mandatory_materialize_basenames \
           update_runtime_helpers; do
    _src="$(_extract_fn "$_fn")"
    if [ -z "$_src" ]; then echo "FATAL: could not extract $_fn from upgrade.sh"; exit 1; fi
    eval "$_src"
    declare -f "$_fn" >/dev/null || { echo "FATAL: $_fn not defined after extraction"; exit 1; }
done

# ─────────────────────────────────────────────────────────────────────────────
# Shared sandbox layout.
# ─────────────────────────────────────────────────────────────────────────────
SANDBOX="$TEST_TMP_DIR/xaca0677"
mkdir -p "$SANDBOX"

ROOT_WM_SRC="$TAP_ROOT/share/scripts/iterm2_window_manager.py"
ROOT_WM_NAME="iterm2_window_manager.py"
STALE_MARKER="# OLD-VENV-PROBE-STALE — xaca-0677-test"

# Verify the source file exists (precondition for all tests)
if [ ! -f "$ROOT_WM_SRC" ]; then
    echo "FATAL: $ROOT_WM_SRC missing — cannot run tests"
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 1: STALE-REFRESH — stale root copy is overwritten with the shipped source
# ═══════════════════════════════════════════════════════════════════════════
test_start "STALE-REFRESH: update_runtime_helpers overwrites a stale root copy"

T1_WORKING="$SANDBOX/t1-working"
T1_SCRIPTS="$T1_WORKING/scripts"
mkdir -p "$T1_SCRIPTS"

# Precondition: plant a stale root copy (contains the stale marker, NOT bootstrap import)
printf '#!/usr/bin/env python3\n%s\n# intentionally missing iterm2_venv_bootstrap\n' "$STALE_MARKER" \
    > "$T1_WORKING/$ROOT_WM_NAME"
chmod +x "$T1_WORKING/$ROOT_WM_NAME"

# Also seed a scripts/ sibling so the scripts sweep doesn't short-circuit
printf '#!/usr/bin/env python3\n# scripts-sibling\n' > "$T1_SCRIPTS/iterm2_venv_bootstrap.py"
chmod +x "$T1_SCRIPTS/iterm2_venv_bootstrap.py"

# PRECONDITION GUARD: stale marker IS present before the upgrade (non-vacuous)
_before_content="$(cat "$T1_WORKING/$ROOT_WM_NAME")"
if [[ "$_before_content" != *"$STALE_MARKER"* ]]; then
    test_fail "PRECONDITION FAILED: stale marker not found before upgrade — test is vacuous"
else
    FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$T1_WORKING" DRY_RUN=false FORCE=false \
        update_runtime_helpers >/dev/null 2>&1
    _after_content="$(cat "$T1_WORKING/$ROOT_WM_NAME")"
    # Stale marker must be GONE (content was overwritten)
    if [[ "$_after_content" == *"$STALE_MARKER"* ]]; then
        test_fail "Stale root copy still contains '$STALE_MARKER' after upgrade — not refreshed"
    else
        test_pass
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 2: CONTENT-MATCH — refreshed root copy matches shipped source exactly
# ═══════════════════════════════════════════════════════════════════════════
test_start "CONTENT-MATCH: refreshed root copy matches share/scripts/iterm2_window_manager.py"

if [ -f "$T1_WORKING/$ROOT_WM_NAME" ]; then
    _expected="$(cat "$ROOT_WM_SRC")"
    _actual="$(cat "$T1_WORKING/$ROOT_WM_NAME")"
    if [ "$_actual" = "$_expected" ]; then
        test_pass
    else
        test_fail "Root copy content after refresh does not match shipped source"
    fi
else
    test_fail "Root copy absent after TEST 1 — cannot compare content"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 3: BOOTSTRAP-IMPORT — refreshed copy contains iterm2_venv_bootstrap import
# ═══════════════════════════════════════════════════════════════════════════
test_start "BOOTSTRAP-IMPORT: refreshed root copy contains 'import iterm2_venv_bootstrap'"

if [ -f "$T1_WORKING/$ROOT_WM_NAME" ]; then
    _refreshed_content="$(cat "$T1_WORKING/$ROOT_WM_NAME")"
    assert_contains "$_refreshed_content" "import iterm2_venv_bootstrap" \
        "Refreshed root copy must contain 'import iterm2_venv_bootstrap' (XACA-0652 bootstrap)" \
        && test_pass
else
    test_fail "Root copy absent — cannot check bootstrap import"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 4: ABSENT-NOT-MATERIALISED — no root copy means no file created
# ═══════════════════════════════════════════════════════════════════════════
test_start "ABSENT-NOT-MATERIALISED: update_runtime_helpers does NOT create a missing root copy"

T4_WORKING="$SANDBOX/t4-working"
T4_SCRIPTS="$T4_WORKING/scripts"
mkdir -p "$T4_SCRIPTS"

# Seed a scripts/ sibling so the function runs to the root-wm block
printf '#!/usr/bin/env python3\n# scripts-sibling\n' > "$T4_SCRIPTS/iterm2_venv_bootstrap.py"
chmod +x "$T4_SCRIPTS/iterm2_venv_bootstrap.py"

# PRECONDITION GUARD: root copy is definitely absent
if [ -f "$T4_WORKING/$ROOT_WM_NAME" ]; then
    test_fail "PRECONDITION FAILED: root copy already exists in T4 sandbox — cannot test absent path"
else
    FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$T4_WORKING" DRY_RUN=false FORCE=false \
        update_runtime_helpers >/dev/null 2>&1
    assert_file_not_exists "$T4_WORKING/$ROOT_WM_NAME" \
        "update_runtime_helpers must NOT materialise root iterm2_window_manager.py when absent" \
        && test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 5: DRY-RUN — stale root copy is NOT modified when DRY_RUN=true
# ═══════════════════════════════════════════════════════════════════════════
test_start "DRY-RUN: stale root copy is NOT modified when DRY_RUN=true"

T5_WORKING="$SANDBOX/t5-working"
T5_SCRIPTS="$T5_WORKING/scripts"
mkdir -p "$T5_SCRIPTS"

# Plant a stale root copy
printf '#!/usr/bin/env python3\n%s\n' "$STALE_MARKER" > "$T5_WORKING/$ROOT_WM_NAME"
chmod +x "$T5_WORKING/$ROOT_WM_NAME"

# Seed scripts/ sibling
printf '#!/usr/bin/env python3\n# dry-run-sibling\n' > "$T5_SCRIPTS/iterm2_venv_bootstrap.py"
chmod +x "$T5_SCRIPTS/iterm2_venv_bootstrap.py"

# PRECONDITION GUARD: stale marker IS present
_dry_before="$(cat "$T5_WORKING/$ROOT_WM_NAME")"
if [[ "$_dry_before" != *"$STALE_MARKER"* ]]; then
    test_fail "PRECONDITION FAILED: stale marker not found in T5 sandbox before dry-run"
else
    FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$T5_WORKING" DRY_RUN=true FORCE=false \
        update_runtime_helpers >/dev/null 2>&1
    _dry_after="$(cat "$T5_WORKING/$ROOT_WM_NAME")"
    if [ "$_dry_after" = "$_dry_before" ]; then
        test_pass
    else
        test_fail "DRY_RUN=true must not modify the stale root copy (content changed)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone only).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
fi
exit 0
