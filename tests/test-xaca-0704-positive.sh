#!/bin/bash

# test-xaca-0704-positive.sh
# Regression test for XACA-0704: Positive upgrade path — box ONE VERSION BEHIND
# upgrades successfully, and the installed version ACTUALLY ADVANCES.
#
# REGRESSION INTENT: XACA-0702 fixed two bugs in `aiteamforge upgrade`:
#   1. Untrusted-tap no-op: brew upgrade silently no-ops but upgrade reported
#      success anyway. Fix: detect no-advance (pre==post) → exit 1 + boxed FAILURE.
#   2. Inverted `brew outdated` probe: exit code is opposite of "is outdated" —
#      the old code gated on exit code (wrong). Fix: detect via stdout presence.
#
# This test validates the POSITIVE path: Scenario A from the harness design:
#   - Box is on 0.14.0, formula is outdated
#   - brew upgrade succeeds and advances version to 0.15.0 (state-flip shim)
#   - upgrade exits 0, prints success banner, stamps .installed-version
#
# THREE independent assertions verify the version actually advanced:
#   1. brew list --versions returns 0.15.0 post-upgrade (shim state-flip)
#   2. .installed-version stamp reflects 0.15.0
#   3. get_installed_version() from config.sh returns 0.15.0
#
# NEGATIVE CONTROL: the test also runs without the state-flip (no marker written)
# to prove the assertions FAIL when brew doesn't advance — so the test is not
# vacuous.
#
# ALL tests use a MOCKED `brew` — the real tap is NEVER installed on M3Pro (dev box).
# Per dev-team policy, `brew tap doublenode/aiteamforge` is prohibited on this machine.
#
# PARITY: N/A — upgrade.sh lives only in the tap; there is no parallel canonical
# source in the worktree scripts/ directory. No parity assertion is needed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
CONFIG_SH="$TAP_ROOT/libexec/lib/config.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone test framework (works sourced by test-runner.sh OR invoked directly)
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST -- $1" >&2; }
fi
if ! type -t assert_equal >/dev/null 2>&1; then
    assert_equal() {
        local exp="$1" got="$2" msg="${3:-Expected '$1' but got '$2'}"
        [ "$exp" = "$got" ] || { test_fail "$msg"; return 1; }
    }
fi
if ! type -t assert_not_equal >/dev/null 2>&1; then
    assert_not_equal() {
        local unexp="$1" got="$2" msg="${3:-Expected value to not be '$1'}"
        [ "$unexp" != "$got" ] || { test_fail "$msg"; return 1; }
    }
fi
if ! type -t assert_contains >/dev/null 2>&1; then
    assert_contains() {
        [[ "$1" == *"$2"* ]] || { test_fail "${3:-Expected to find '$2'}"; return 1; }
    }
fi
if ! type -t assert_not_contains >/dev/null 2>&1; then
    assert_not_contains() {
        [[ "$1" != *"$2"* ]] || { test_fail "${3:-Expected NOT to find '$2'}"; return 1; }
    }
fi
if ! type -t assert_file_exists >/dev/null 2>&1; then
    assert_file_exists() { [ -f "$1" ] || { test_fail "${2:-Expected file to exist: $1}"; return 1; }; }
fi
if ! type -t assert_exit_code >/dev/null 2>&1; then
    assert_exit_code() {
        local exp="$1" got="$2" msg="${3:-Expected exit code $1 but got $2}"
        [ "$exp" -eq "$got" ] || { test_fail "$msg"; return 1; }
    }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory — shared with test-runner.sh if provided, own if standalone
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0704pos.XXXXXX)"
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
# Prerequisite: upgrade.sh and config.sh must exist
# ─────────────────────────────────────────────────────────────────────────────
if [ ! -f "$UPGRADE_SH" ]; then
    echo "FATAL: upgrade.sh not found at $UPGRADE_SH" >&2
    exit 1
fi
if [ ! -f "$CONFIG_SH" ]; then
    echo "FATAL: config.sh not found at $CONFIG_SH" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Mock brew infrastructure — file-based state per the harness design (§ Brew
# PATH-Shim Contract).  All state lives under $TEST_TMP_DIR/mock-bin/ so the
# mock brew binary itself is reachable without installing anything real.
# ─────────────────────────────────────────────────────────────────────────────
MOCK_BIN="$TEST_TMP_DIR/mock-bin"
mkdir -p "$MOCK_BIN"

BREW_CALL_LOG="$TEST_TMP_DIR/brew-calls.log"
MOCK_BREW_LIST_OUTPUT_FILE="$TEST_TMP_DIR/brew-list-output"
MOCK_BREW_LIST_VERSIONS_PRE_FILE="$TEST_TMP_DIR/brew-list-versions-pre"
MOCK_BREW_LIST_VERSIONS_POST_FILE="$TEST_TMP_DIR/brew-list-versions-post"
MOCK_BREW_OUTDATED_OUTPUT_FILE="$TEST_TMP_DIR/brew-outdated-output"
MOCK_BREW_UPGRADE_EXIT_FILE="$TEST_TMP_DIR/brew-upgrade-exit"
MOCK_BREW_UPGRADE_DONE_FILE="$TEST_TMP_DIR/brew-upgrade-done"

# Create the mock brew binary.
# State-flip: after "upgrade aiteamforge" is called the shim writes
# MOCK_BREW_UPGRADE_DONE_FILE; subsequent "list --versions" reads the POST file.
# This is what makes pre/post comparison honest — without the flip, both
# sides return 0.14.0 and the no-advance gate fires (exit 1).
cat > "$MOCK_BIN/brew" <<'MOCK_EOF'
#!/bin/bash
# Mock brew shim for XACA-0704 tests.
# Logs every call; returns file-configured outputs.
if [ -n "${BREW_CALL_LOG:-}" ]; then
    printf '%s\n' "$*" >> "$BREW_CALL_LOG"
fi

case "$1 $2" in
    "list aiteamforge")
        # Installed-check guard: exit 0 with any output = formula IS installed.
        cat "${MOCK_BREW_LIST_OUTPUT_FILE:-/dev/null}" 2>/dev/null || true
        ;;
    "list --versions")
        # _brew_installed_version: state-flip after upgrade call.
        if [ -f "${MOCK_BREW_UPGRADE_DONE_FILE:-}" ]; then
            cat "${MOCK_BREW_LIST_VERSIONS_POST_FILE:-/dev/null}" 2>/dev/null || true
        else
            cat "${MOCK_BREW_LIST_VERSIONS_PRE_FILE:-/dev/null}" 2>/dev/null || true
        fi
        ;;
    "outdated aiteamforge")
        # stdout presence = OUTDATED; empty stdout = UP TO DATE.
        cat "${MOCK_BREW_OUTDATED_OUTPUT_FILE:-/dev/null}" 2>/dev/null || true
        ;;
    "upgrade aiteamforge")
        # State-flip: mark upgrade as done so list --versions returns POST value.
        if [ -n "${MOCK_BREW_UPGRADE_DONE_FILE:-}" ]; then
            touch "$MOCK_BREW_UPGRADE_DONE_FILE"
        fi
        exit "$(cat "${MOCK_BREW_UPGRADE_EXIT_FILE:-/dev/null}" 2>/dev/null || echo 0)"
        ;;
    "info aiteamforge")
        # Returns JSON for jq version parse in check_brew_updates.
        # If jq is absent the result is ignored; this is safe.
        echo '[{"versions":{"stable":"0.15.0"}}]'
        ;;
    "trust --tap"*)
        exit 0
        ;;
    "--prefix"*)
        echo "/opt/homebrew"
        ;;
    *)
        exit 0
        ;;
esac
MOCK_EOF
chmod +x "$MOCK_BIN/brew"

export BREW_CALL_LOG
export MOCK_BREW_LIST_OUTPUT_FILE
export MOCK_BREW_LIST_VERSIONS_PRE_FILE
export MOCK_BREW_LIST_VERSIONS_POST_FILE
export MOCK_BREW_OUTDATED_OUTPUT_FILE
export MOCK_BREW_UPGRADE_EXIT_FILE
export MOCK_BREW_UPGRADE_DONE_FILE

# Helper: reset brew call log and upgrade-done marker.
_reset_mock_state() {
    : > "$BREW_CALL_LOG"
    rm -f "$MOCK_BREW_UPGRADE_DONE_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# Sandbox aiteamforge working directory (never the real installation).
# is_configured() checks for $AITEAMFORGE_DIR/.aiteamforge-config.
# All update_* functions check for $FRAMEWORK_DIR/share/... and bail early
# when absent — so no rsync/copy side-effects hit the real filesystem.
# ─────────────────────────────────────────────────────────────────────────────
AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
mkdir -p "$AITEAMFORGE_DIR"

# Minimal config so is_configured() passes without real installation.
touch "$AITEAMFORGE_DIR/.aiteamforge-config"

export AITEAMFORGE_DIR

# ─────────────────────────────────────────────────────────────────────────────
# Run helper: run upgrade.sh in a clean subprocess with the mock on PATH.
# Captures stdout+stderr to a file and the exit code to a variable.
# stdin is /dev/null so prompt_yes_no uses its default "y" (proceeds with upgrade).
#
# Usage: _run_upgrade [extra args]
# Populates: UPGRADE_EXIT, UPGRADE_OUTPUT (text string)
# ─────────────────────────────────────────────────────────────────────────────
_UPGRADE_OUTPUT_FILE="$TEST_TMP_DIR/upgrade-output.txt"

_run_upgrade() {
    _reset_mock_state
    rm -f "$_UPGRADE_OUTPUT_FILE"
    UPGRADE_EXIT=0
    PATH="$MOCK_BIN:$PATH" \
    AITEAMFORGE_DIR="$AITEAMFORGE_DIR" \
    bash "$UPGRADE_SH" "$@" < /dev/null > "$_UPGRADE_OUTPUT_FILE" 2>&1 || UPGRADE_EXIT=$?
    UPGRADE_OUTPUT="$(cat "$_UPGRADE_OUTPUT_FILE" 2>/dev/null || true)"
}

# ═══════════════════════════════════════════════════════════════════════════
# STATIC ASSERTIONS (no runtime execution of upgrade.sh required)
# Run first so source-level regressions surface even if the runtime harness
# has a setup issue.
# ═══════════════════════════════════════════════════════════════════════════

# Read the upgrade script source once for all static assertions.
_upgrade_src="$(cat "$UPGRADE_SH")"

# ASSERT S1: upgrade.sh must NOT use the inverted exit-code probe for brew outdated.
# Regression guard against re-introducing `if brew outdated ...` (inverted gate).
# We grep only non-comment executable lines (lines not starting with optional
# whitespace then '#') so the XACA-0702 explanatory comment that mentions the
# old pattern does NOT trigger a false failure.
test_start "STATIC: upgrade.sh does NOT use inverted exit-code probe 'if brew outdated' (non-comment lines only)"
_inverted_probe_lines="$(grep "if brew outdated" "$UPGRADE_SH" 2>/dev/null | grep -v '^\s*#' || true)"
if [ -n "$_inverted_probe_lines" ]; then
    test_fail "STATIC: upgrade.sh has executable 'if brew outdated' (inverted probe) on non-comment lines: $_inverted_probe_lines"
else
    test_pass
fi

# ASSERT S2: upgrade.sh must use the stdout-presence detection pattern.
test_start "STATIC: upgrade.sh uses _outdated_probe stdout-presence detection"
if [[ "$_upgrade_src" == *"_outdated_probe"* ]]; then
    test_pass
else
    test_fail "STATIC: upgrade.sh must contain '_outdated_probe' stdout-presence pattern (XACA-0702 fix)"
fi

# ASSERT S3: upgrade.sh must contain the no-advance detection block.
# Multi-check test: track local failure so test_pass is not called on partial failure.
test_start "STATIC: upgrade.sh has no-advance detection (pre_version == post_version guard)"
_s3_ok=true
if [[ "$_upgrade_src" != *"pre_version"* ]]; then
    test_fail "STATIC: upgrade.sh must have pre_version snapshot for no-advance detection"
    _s3_ok=false
fi
if [[ "$_upgrade_src" != *"UPGRADE_BREW_FAILED=true"* ]]; then
    test_fail "STATIC: upgrade.sh must set UPGRADE_BREW_FAILED=true on no-advance"
    _s3_ok=false
fi
[ "$_s3_ok" = true ] && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# SCENARIO A SETUP — Positive path: one version behind, upgrades to 0.15.0
# ═══════════════════════════════════════════════════════════════════════════
# Configures mock for: installed=0.14.0, outdated=true, upgrade exits 0,
# post-upgrade list returns 0.15.0 (state-flip via MOCK_BREW_UPGRADE_DONE_FILE).

_setup_scenario_a() {
    # brew list aiteamforge: formula IS installed (exit 0, non-empty output).
    echo "aiteamforge" > "$MOCK_BREW_LIST_OUTPUT_FILE"
    # brew list --versions: PRE-upgrade returns 0.14.0.
    echo "aiteamforge 0.14.0" > "$MOCK_BREW_LIST_VERSIONS_PRE_FILE"
    # brew list --versions: POST-upgrade returns 0.15.0 (after state-flip).
    echo "aiteamforge 0.15.0" > "$MOCK_BREW_LIST_VERSIONS_POST_FILE"
    # brew outdated: non-empty stdout = IS OUTDATED.
    echo "aiteamforge" > "$MOCK_BREW_OUTDATED_OUTPUT_FILE"
    # brew upgrade: exits 0 (success).
    echo "0" > "$MOCK_BREW_UPGRADE_EXIT_FILE"
    # Clear .installed-version from any prior run so assertions start clean.
    rm -f "$AITEAMFORGE_DIR/.installed-version"
}

# ═══════════════════════════════════════════════════════════════════════════
# NEGATIVE CONTROL: prove the assertions ARE real by running Scenario A
# WITHOUT the state-flip (i.e., no MOCK_BREW_UPGRADE_DONE_FILE gets written).
# In this configuration: pre=0.14.0, post=0.14.0 → no-advance gate fires
# → upgrade exits 1 → success assertions would FAIL.
#
# We run this FIRST and verify: (a) exit code is 1, (b) FAILURE banner prints,
# (c) .installed-version is NOT 0.15.0.  Then we restore the state-flip
# mechanism for the real positive tests.
# ═══════════════════════════════════════════════════════════════════════════

_setup_scenario_a_no_flip() {
    # Same as Scenario A but POST file also shows 0.14.0 (no advance).
    echo "aiteamforge" > "$MOCK_BREW_LIST_OUTPUT_FILE"
    echo "aiteamforge 0.14.0" > "$MOCK_BREW_LIST_VERSIONS_PRE_FILE"
    # POST file is same as PRE — upgrade did not advance the version.
    echo "aiteamforge 0.14.0" > "$MOCK_BREW_LIST_VERSIONS_POST_FILE"
    echo "aiteamforge" > "$MOCK_BREW_OUTDATED_OUTPUT_FILE"
    echo "0" > "$MOCK_BREW_UPGRADE_EXIT_FILE"
    rm -f "$AITEAMFORGE_DIR/.installed-version"
}

test_start "NEGATIVE CONTROL: stuck upgrade (no state-flip) must exit 1 and print FAILURE banner"
_setup_scenario_a_no_flip
_run_upgrade
_nc_exit="$UPGRADE_EXIT"
_nc_output="$UPGRADE_OUTPUT"
# The no-advance gate MUST fire: pre==post → UPGRADE_BREW_FAILED=true → exit 1.
if [ "$_nc_exit" -eq 1 ]; then
    test_pass
else
    test_fail "Negative control: expected exit 1 for stuck upgrade (no state-flip), got $_nc_exit. Output: $_nc_output"
fi

test_start "NEGATIVE CONTROL: stuck upgrade output contains 'UPGRADE FAILED' banner"
assert_contains "$_nc_output" "UPGRADE FAILED" \
    "Negative control: stuck upgrade must print 'UPGRADE FAILED' in output" && test_pass

test_start "NEGATIVE CONTROL: stuck upgrade output does NOT contain success message"
assert_not_contains "$_nc_output" "upgraded successfully" \
    "Negative control: stuck upgrade must NOT print 'upgraded successfully'" && test_pass

test_start "NEGATIVE CONTROL: stuck upgrade .installed-version must NOT show 0.15.0"
_nc_stamp="$(cat "$AITEAMFORGE_DIR/.installed-version" 2>/dev/null | tr -d '[:space:]' || true)"
assert_not_equal "0.15.0" "$_nc_stamp" \
    "Negative control: .installed-version must not be stamped 0.15.0 when upgrade was stuck (got '$_nc_stamp')" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# SCENARIO A — Positive upgrade: version advances from 0.14.0 to 0.15.0
# ═══════════════════════════════════════════════════════════════════════════

_setup_scenario_a
_run_upgrade
_pos_exit="$UPGRADE_EXIT"
_pos_output="$UPGRADE_OUTPUT"

# ASSERT 1: Exit code is 0.
test_start "POSITIVE: exit code is 0 on successful version-advancing upgrade"
assert_exit_code 0 "$_pos_exit" \
    "Positive upgrade must exit 0 (got $_pos_exit). Output: $_pos_output" && test_pass

# ASSERT 2a: Output contains success string.
test_start "POSITIVE: output contains 'upgraded successfully'"
assert_contains "$_pos_output" "upgraded successfully" \
    "Success output must contain 'upgraded successfully'" && test_pass

# ASSERT 2b: Output does NOT contain FAILURE banner.
test_start "POSITIVE: output does NOT contain 'UPGRADE FAILED'"
assert_not_contains "$_pos_output" "UPGRADE FAILED" \
    "Success output must NOT contain 'UPGRADE FAILED'" && test_pass

test_start "POSITIVE: output does NOT contain 'NOT UPGRADED'"
assert_not_contains "$_pos_output" "NOT UPGRADED" \
    "Success output must NOT contain 'NOT UPGRADED'" && test_pass

# ASSERT 3: .installed-version stamp reflects 0.15.0 (independent check #2).
test_start "POSITIVE: .installed-version stamp reflects advanced brew version 0.15.0"
_stamped_ver="$(cat "$AITEAMFORGE_DIR/.installed-version" 2>/dev/null | tr -d '[:space:]' || true)"
assert_equal "0.15.0" "$_stamped_ver" \
    ".installed-version must be stamped with 0.15.0 after positive upgrade (got '$_stamped_ver')" && test_pass

# ASSERT 4: self-validating pre/post != check (independent check #1).
# Prove that the pre-upgrade and post-upgrade brew list versions differ,
# so the no-advance detection did NOT fire and the test is not vacuous.
test_start "POSITIVE: pre-upgrade version (0.14.0) differs from post-upgrade (0.15.0) — non-vacuous check"
_pre_ver="$(cat "$MOCK_BREW_LIST_VERSIONS_PRE_FILE" | awk '{print $NF}')"
_post_ver_current="$(PATH="$MOCK_BIN:$PATH" bash -c "
    export MOCK_BREW_UPGRADE_DONE_FILE=\"$MOCK_BREW_UPGRADE_DONE_FILE\"
    export MOCK_BREW_LIST_VERSIONS_PRE_FILE=\"$MOCK_BREW_LIST_VERSIONS_PRE_FILE\"
    export MOCK_BREW_LIST_VERSIONS_POST_FILE=\"$MOCK_BREW_LIST_VERSIONS_POST_FILE\"
    export BREW_CALL_LOG=\"$TEST_TMP_DIR/tmp-call.log\"
    brew list --versions aiteamforge 2>/dev/null | awk '{print \$NF}'
" 2>/dev/null || true)"
# After _run_upgrade, MOCK_BREW_UPGRADE_DONE_FILE was touched (upgrade ran).
# Re-query with the done-file present to confirm the flip produced 0.15.0.
if [ -f "$MOCK_BREW_UPGRADE_DONE_FILE" ]; then
    _post_ver_flipped="$(PATH="$MOCK_BIN:$PATH" brew list --versions aiteamforge 2>/dev/null | awk '{print $NF}' || true)"
else
    _post_ver_flipped="(marker-not-set)"
fi
assert_not_equal "$_pre_ver" "$_post_ver_flipped" \
    "Pre-version ('$_pre_ver') must differ from post-upgrade version ('$_post_ver_flipped') — test is vacuous if they are equal" && test_pass

# ASSERT 5: get_installed_version() returns 0.15.0 (independent check #3).
# Source config.sh with the mock brew still on PATH (MOCK_BREW_UPGRADE_DONE_FILE
# still present so list --versions returns 0.15.0 = source 1 wins).
test_start "POSITIVE: get_installed_version() returns 0.15.0 after upgrade (source 1 or 2)"
_reported_ver="$(
    unset _COMMON_SH_LOADED 2>/dev/null || true
    PATH="$MOCK_BIN:$PATH" \
    AITEAMFORGE_DIR="$AITEAMFORGE_DIR" \
    MOCK_BREW_UPGRADE_DONE_FILE="$MOCK_BREW_UPGRADE_DONE_FILE" \
    MOCK_BREW_LIST_OUTPUT_FILE="$MOCK_BREW_LIST_OUTPUT_FILE" \
    MOCK_BREW_LIST_VERSIONS_PRE_FILE="$MOCK_BREW_LIST_VERSIONS_PRE_FILE" \
    MOCK_BREW_LIST_VERSIONS_POST_FILE="$MOCK_BREW_LIST_VERSIONS_POST_FILE" \
    BREW_CALL_LOG="$TEST_TMP_DIR/giv-calls.log" \
    bash -c "
        source \"$CONFIG_SH\" 2>/dev/null
        get_installed_version
    "
)"
assert_equal "0.15.0" "$_reported_ver" \
    "get_installed_version must report 0.15.0 after positive upgrade (got '$_reported_ver')" && test_pass

# ASSERT 6: brew upgrade aiteamforge was actually called.
test_start "POSITIVE: brew upgrade aiteamforge was invoked (upgrade did not skip brew step)"
if grep -qx "upgrade aiteamforge" "$BREW_CALL_LOG" 2>/dev/null; then
    test_pass
else
    test_fail "brew upgrade aiteamforge was never called. Logged calls: $(cat "$BREW_CALL_LOG" 2>/dev/null || echo '(none)')"
fi

# ASSERT 7: MOCK_BREW_UPGRADE_DONE_FILE exists — confirms state-flip mechanism
# fired.  If the shim never wrote this file, the post-version check would have
# still read from the PRE file (0.14.0) — the negative-control proves that case
# exits 1, so arriving here (exit 0) confirms the flip happened.
test_start "POSITIVE: state-flip marker written — confirms shim advanced the version"
if [ -f "$MOCK_BREW_UPGRADE_DONE_FILE" ]; then
    test_pass
else
    test_fail "MOCK_BREW_UPGRADE_DONE_FILE was not created — upgrade shim did not execute or touch the marker"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone invocation only)
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
fi
exit 0
