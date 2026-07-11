#!/bin/bash

# test-xaca-0610-fleet-reporter-refresh.sh
# Regression tests for XACA-0610: update_runtime_helpers must refresh the
# OPERATIVE fleet-monitor/client/fleet-reporter.sh copy on upgrade.
#
# REGRESSION INTENT: fleet-reporter.sh ships to TWO destinations at install
# time — a decorative helper copy at ${WORKING_DIR}/scripts/fleet-reporter.sh
# (via install-shell.sh) and the OPERATIVE copy at
# ${WORKING_DIR}/fleet-monitor/client/fleet-reporter.sh (via
# install-fleet-monitor.sh). The com.aiteamforge.fleet-reporter launchd job
# executes ONLY the second, separate-destination copy. Prior to XACA-0610,
# update_runtime_helpers' scripts/ sweep only walked WORKING_DIR/scripts/,
# refreshing the decorative copy but never reaching fleet-monitor/client/ —
# so upgraded boxes ran a permanently frozen fleet-reporter.sh.
#
# Fix: a tightly-scoped block at the end of update_runtime_helpers (same
# XACA-0677 shape) copies
#   share/scripts/fleet-reporter.sh -> ${WORKING_DIR}/fleet-monitor/client/fleet-reporter.sh
# ONLY when the operative copy already exists (XACA-0673 convention: upgrade
# never materialises absent files — machines that opted out of fleet
# monitoring must stay opted out). Dry-run aware.
#
# Assertions:
#   1. STALE-REFRESH: a stale operative copy IS overwritten by
#      update_runtime_helpers (DRY_RUN=false) — the stale marker is gone after.
#   2. CONTENT-MATCH: the refreshed operative copy matches the shipped
#      share/scripts/fleet-reporter.sh source exactly.
#   3. ABSENT-NOT-MATERIALISED: when no operative copy exists (but scripts/
#      is seeded so the sweep doesn't short-circuit), update_runtime_helpers
#      does NOT create fleet-monitor/client/fleet-reporter.sh.
#   4. DRY-RUN: with DRY_RUN=true and a stale operative copy present, the
#      file is NOT modified (content unchanged).
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
    TEST_TMP_DIR="$(mktemp -d -t xaca0610-test.XXXXXX)"
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
SANDBOX="$TEST_TMP_DIR/xaca0610"
mkdir -p "$SANDBOX"

FR_SRC="$TAP_ROOT/share/scripts/fleet-reporter.sh"
FR_NAME="fleet-reporter.sh"
STALE_MARKER="# OLD-REPORTER-PROBE-STALE — xaca-0610-test"

# Verify the source file exists (precondition for all tests)
if [ ! -f "$FR_SRC" ]; then
    echo "FATAL: $FR_SRC missing — cannot run tests"
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 1: STALE-REFRESH — stale operative copy is overwritten with the shipped source
# ═══════════════════════════════════════════════════════════════════════════
test_start "STALE-REFRESH: update_runtime_helpers overwrites a stale operative copy"

T1_WORKING="$SANDBOX/t1-working"
T1_SCRIPTS="$T1_WORKING/scripts"
T1_FM_CLIENT="$T1_WORKING/fleet-monitor/client"
mkdir -p "$T1_SCRIPTS" "$T1_FM_CLIENT"

# Precondition: plant a stale operative copy (contains the stale marker)
printf '#!/bin/bash\n%s\n# intentionally stale\n' "$STALE_MARKER" \
    > "$T1_FM_CLIENT/$FR_NAME"
chmod +x "$T1_FM_CLIENT/$FR_NAME"

# Also seed a scripts/ sibling so the scripts sweep doesn't short-circuit
printf '#!/bin/bash\n# scripts-sibling\n' > "$T1_SCRIPTS/iterm2_venv_bootstrap.py"
chmod +x "$T1_SCRIPTS/iterm2_venv_bootstrap.py"

# PRECONDITION GUARD: stale marker IS present before the upgrade (non-vacuous)
_before_content="$(cat "$T1_FM_CLIENT/$FR_NAME")"
if [[ "$_before_content" != *"$STALE_MARKER"* ]]; then
    test_fail "PRECONDITION FAILED: stale marker not found before upgrade — test is vacuous"
else
    FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$T1_WORKING" DRY_RUN=false FORCE=false \
        update_runtime_helpers >/dev/null 2>&1
    _after_content="$(cat "$T1_FM_CLIENT/$FR_NAME")"
    # Stale marker must be GONE (content was overwritten)
    if [[ "$_after_content" == *"$STALE_MARKER"* ]]; then
        test_fail "Stale operative copy still contains '$STALE_MARKER' after upgrade — not refreshed"
    else
        test_pass
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 2: CONTENT-MATCH — refreshed operative copy matches shipped source exactly
# ═══════════════════════════════════════════════════════════════════════════
test_start "CONTENT-MATCH: refreshed operative copy matches share/scripts/fleet-reporter.sh"

if [ -f "$T1_FM_CLIENT/$FR_NAME" ]; then
    _expected="$(cat "$FR_SRC")"
    _actual="$(cat "$T1_FM_CLIENT/$FR_NAME")"
    if [ "$_actual" = "$_expected" ]; then
        test_pass
    else
        test_fail "Operative copy content after refresh does not match shipped source"
    fi
else
    test_fail "Operative copy absent after TEST 1 — cannot compare content"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 3: ABSENT-NOT-MATERIALISED — no operative copy means no file created
# ═══════════════════════════════════════════════════════════════════════════
test_start "ABSENT-NOT-MATERIALISED: update_runtime_helpers does NOT create a missing operative copy"

T3_WORKING="$SANDBOX/t3-working"
T3_SCRIPTS="$T3_WORKING/scripts"
mkdir -p "$T3_SCRIPTS"

# Seed a scripts/ sibling so the function runs to the fleet-reporter block
printf '#!/bin/bash\n# scripts-sibling\n' > "$T3_SCRIPTS/iterm2_venv_bootstrap.py"
chmod +x "$T3_SCRIPTS/iterm2_venv_bootstrap.py"

# PRECONDITION GUARD: operative copy is definitely absent (fleet-monitor/client/
# dir itself is also absent — mirrors a box that opted out of fleet monitoring)
if [ -f "$T3_WORKING/fleet-monitor/client/$FR_NAME" ]; then
    test_fail "PRECONDITION FAILED: operative copy already exists in T3 sandbox — cannot test absent path"
else
    FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$T3_WORKING" DRY_RUN=false FORCE=false \
        update_runtime_helpers >/dev/null 2>&1
    assert_file_not_exists "$T3_WORKING/fleet-monitor/client/$FR_NAME" \
        "update_runtime_helpers must NOT materialise fleet-monitor/client/fleet-reporter.sh when absent" \
        && test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 4: DRY-RUN — stale operative copy is NOT modified when DRY_RUN=true
# ═══════════════════════════════════════════════════════════════════════════
test_start "DRY-RUN: stale operative copy is NOT modified when DRY_RUN=true"

T4_WORKING="$SANDBOX/t4-working"
T4_SCRIPTS="$T4_WORKING/scripts"
T4_FM_CLIENT="$T4_WORKING/fleet-monitor/client"
mkdir -p "$T4_SCRIPTS" "$T4_FM_CLIENT"

# Plant a stale operative copy
printf '#!/bin/bash\n%s\n' "$STALE_MARKER" > "$T4_FM_CLIENT/$FR_NAME"
chmod +x "$T4_FM_CLIENT/$FR_NAME"

# Seed scripts/ sibling
printf '#!/bin/bash\n# dry-run-sibling\n' > "$T4_SCRIPTS/iterm2_venv_bootstrap.py"
chmod +x "$T4_SCRIPTS/iterm2_venv_bootstrap.py"

# PRECONDITION GUARD: stale marker IS present
_dry_before="$(cat "$T4_FM_CLIENT/$FR_NAME")"
if [[ "$_dry_before" != *"$STALE_MARKER"* ]]; then
    test_fail "PRECONDITION FAILED: stale marker not found in T4 sandbox before dry-run"
else
    FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$T4_WORKING" DRY_RUN=true FORCE=false \
        update_runtime_helpers >/dev/null 2>&1
    _dry_after="$(cat "$T4_FM_CLIENT/$FR_NAME")"
    if [ "$_dry_after" = "$_dry_before" ]; then
        test_pass
    else
        test_fail "DRY_RUN=true must not modify the stale operative copy (content changed)"
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
