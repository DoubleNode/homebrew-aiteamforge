#!/bin/bash

# test-xaca-0704-negative.sh
# Regression tests for XACA-0704 — negative cases for the upgrade acceptance gate.
# Covers the XACA-0702 regression: a stuck/untrusted-tap upgrade must NOT report
# "upgraded successfully!" — it must exit 1 and print the boxed FAILURE banner.
#
# THREE CASES:
#   Case A — no-op / stuck brew upgrade (pre-version == post-version after upgrade)
#             aiteamforge upgrade must: exit 1, print FAILURE banner, NOT print success
#   Case B — untrusted-tap refusal (tap_load_refused returns true after ensure_tap_trusted)
#             aiteamforge upgrade must: exit 1, print FAILURE banner, NOT print success
#   Case C — current box under --non-interactive (brew outdated returns empty stdout)
#             aiteamforge upgrade must: exit 0, NOT print FAILURE banner (no false-fail)
#
# ALL tests mock 'brew' via a PATH-shim — the real tap is NEVER installed on M3Pro.
# Per dev-team policy, 'brew tap doublenode/aiteamforge' is prohibited on this machine.
#
# INVOCATION APPROACH: upgrade.sh is executed as a subprocess via
#   env <vars> bash "$UPGRADE_SH" [args] < /dev/null
# NOT sourced. Sourcing breaks BASH_SOURCE[0]-based SCRIPT_DIR resolution (the
# script resolves to the outer caller's path, missing lib files). As a subprocess,
# BASH_SOURCE[0] resolves correctly. stdin is /dev/null so prompt_yes_no auto-answers
# with the call-site default ("y") when the read gets EOF.
#
# Assertions:
#   N1  Case A: exit code is 1 (stuck/no-op must exit 1)
#   N2  Case A: output contains 'UPGRADE FAILED' (boxed failure banner)
#   N3  Case A: output contains 'NOT UPGRADED' (boxed failure banner)
#   N4  Case A: output does NOT contain 'upgraded successfully' (no false success)
#   N5  Case A: .installed-version stamp does NOT advance to 0.15.0
#   N6  Case B: exit code is 1 (untrusted-tap must exit 1)
#   N7  Case B: output contains 'UPGRADE FAILED' (FAILURE banner present)
#   N8  Case B: output does NOT contain 'upgraded successfully' (no false success)
#   N9  Case C: exit code is 0 (current box under --non-interactive must NOT false-fail)
#   N10 Case C: output does NOT contain 'UPGRADE FAILED' (no false FAILURE banner)
#   STATIC: upgrade.sh uses stdout-presence detection for 'brew outdated' (not exit-code)
#
# Anti-vacuity guards per Cadet Master standards:
#   - Captured output is asserted non-empty before grepping each case
#   - Case B sets MOCK_BREW_INFO_UNTRUSTED_FILE so the brew shim returns refused-tap
#     text for 'brew info', distinguishing it from Case A's clean info response
#   - Each case resets shim state files so Case A's upgrade-done marker cannot leak
#     into Case C's --non-interactive re-probe path

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"

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
        local unexp="$1" got="$2" msg="${3:-Expected value to not be '$1' but got '$2'}"
        [ "$unexp" != "$got" ] || { test_fail "$msg"; return 1; }
    }
fi
if ! type -t assert_contains >/dev/null 2>&1; then
    assert_contains() {
        local haystack="$1" needle="$2" msg="${3:-Expected to find '$2'}"
        [[ "$haystack" == *"$needle"* ]] || { test_fail "$msg"; return 1; }
    }
fi
if ! type -t assert_not_contains >/dev/null 2>&1; then
    assert_not_contains() {
        local haystack="$1" needle="$2" msg="${3:-Expected NOT to find '$2'}"
        [[ "$haystack" != *"$needle"* ]] || { test_fail "$msg"; return 1; }
    }
fi
if ! type -t assert_not_empty >/dev/null 2>&1; then
    assert_not_empty() {
        local val="$1" msg="${2:-Expected value to not be empty}"
        [ -n "$val" ] || { test_fail "$msg"; return 1; }
    }
fi
if ! type -t assert_exit_code >/dev/null 2>&1; then
    assert_exit_code() {
        local expected="$1" actual="$2" msg="${3:-Expected exit $1 but got $2}"
        [ "$expected" -eq "$actual" ] || { test_fail "$msg"; return 1; }
    }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0704neg.XXXXXX)"
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
# Verify source files exist (fast-fail before any test runs)
# ─────────────────────────────────────────────────────────────────────────────
if [ ! -f "$UPGRADE_SH" ]; then
    echo "FATAL: upgrade.sh not found at $UPGRADE_SH" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Environment scaffolding: AITEAMFORGE_DIR sandbox
# ─────────────────────────────────────────────────────────────────────────────
_AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
# Empty fake framework dir — all update_* functions check for subdirs (share/templates,
# share/lcars-ui, etc.) and return early with a warning when they don't exist.
_AITEAMFORGE_HOME="$TEST_TMP_DIR/framework"
mkdir -p "$_AITEAMFORGE_DIR" "$_AITEAMFORGE_HOME"

# .aiteamforge-config: config.sh::is_configured() checks for this file.
# Presence = "configured". Content is irrelevant to the upgrade flow.
touch "$_AITEAMFORGE_DIR/.aiteamforge-config"

# ─────────────────────────────────────────────────────────────────────────────
# Mock brew infrastructure
#
# The mock brew script is written to TEST_TMP_DIR/mock-bin/ and prepended to
# PATH via the env call. Each test case writes its own state files to control
# shim behavior across a single upgrade run.
#
# State files (all under TEST_TMP_DIR):
#   brew-list-output        : stdout for 'brew list aiteamforge' (non-empty = installed)
#   brew-list-versions-file : stdout for 'brew list --versions aiteamforge' (pre-upgrade ver)
#   brew-list-versions-post : stdout for 'brew list --versions' AFTER upgrade-done marker
#   brew-outdated-output    : stdout for 'brew outdated aiteamforge'
#                             (empty = up-to-date; non-empty = outdated, stdout-presence detect)
#   brew-upgrade-exit       : exit code for 'brew upgrade aiteamforge'
#   brew-upgrade-done       : marker file touched by shim on 'upgrade' call (enables post-flip)
#   brew-info-untrusted     : when present, 'brew info' returns refused-tap error text
#   brew-calls.log          : appended with "$@" on every shim invocation
# ─────────────────────────────────────────────────────────────────────────────
_MOCK_BIN="$TEST_TMP_DIR/mock-bin"
mkdir -p "$_MOCK_BIN"

BREW_CALL_LOG="$TEST_TMP_DIR/brew-calls.log"
MOCK_BREW_LIST_OUTPUT_FILE="$TEST_TMP_DIR/brew-list-output"
MOCK_BREW_LIST_VERSIONS_FILE="$TEST_TMP_DIR/brew-list-versions-file"
MOCK_BREW_LIST_VERSIONS_POST_FILE="$TEST_TMP_DIR/brew-list-versions-post"
MOCK_BREW_OUTDATED_OUTPUT_FILE="$TEST_TMP_DIR/brew-outdated-output"
MOCK_BREW_UPGRADE_EXIT_FILE="$TEST_TMP_DIR/brew-upgrade-exit"
MOCK_BREW_UPGRADE_DONE_FILE="$TEST_TMP_DIR/brew-upgrade-done"
MOCK_BREW_INFO_UNTRUSTED_FILE="$TEST_TMP_DIR/brew-info-untrusted"

# Write the mock brew script.
# shellcheck disable=SC2016  # single-quoted heredoc — $ is intentional for the shim
cat > "$_MOCK_BIN/brew" <<'MOCK_EOF'
#!/bin/bash
# Mock brew shim — logs every call, returns file-based configured outputs.

if [ -n "${BREW_CALL_LOG:-}" ]; then
    printf '%s\n' "$*" >> "$BREW_CALL_LOG"
fi

case "$1 $2" in
    "list aiteamforge")
        # Non-empty stdout = formula IS installed.
        if [ -f "${MOCK_BREW_LIST_OUTPUT_FILE:-}" ]; then
            cat "${MOCK_BREW_LIST_OUTPUT_FILE}"
        fi
        exit 0
        ;;
    "list --versions")
        # _brew_installed_version: returns "aiteamforge <ver>" token.
        # Post-upgrade flip: if upgrade-done marker exists AND post-file set, return post ver.
        if [ -f "${MOCK_BREW_UPGRADE_DONE_FILE:-}" ] && \
           [ -f "${MOCK_BREW_LIST_VERSIONS_POST_FILE:-}" ]; then
            cat "${MOCK_BREW_LIST_VERSIONS_POST_FILE}"
        elif [ -f "${MOCK_BREW_LIST_VERSIONS_FILE:-}" ]; then
            cat "${MOCK_BREW_LIST_VERSIONS_FILE}"
        fi
        exit 0
        ;;
    "outdated aiteamforge")
        # XACA-0702 stdout-presence detection: empty = up-to-date; non-empty = outdated.
        if [ -f "${MOCK_BREW_OUTDATED_OUTPUT_FILE:-}" ]; then
            cat "${MOCK_BREW_OUTDATED_OUTPUT_FILE}"
        fi
        exit 0
        ;;
    "upgrade aiteamforge")
        # Touch the upgrade-done marker so _brew_installed_version can flip post-upgrade.
        if [ -n "${MOCK_BREW_UPGRADE_DONE_FILE:-}" ]; then
            touch "${MOCK_BREW_UPGRADE_DONE_FILE}"
        fi
        exit "$(cat "${MOCK_BREW_UPGRADE_EXIT_FILE:-}" 2>/dev/null || echo 0)"
        ;;
    "info aiteamforge"*)
        # Case B: MOCK_BREW_INFO_UNTRUSTED_FILE present → simulate refused-tap.
        # tap_load_refused() greps this output for "untrusted tap|refus(e|ing) to load".
        if [ -f "${MOCK_BREW_INFO_UNTRUSTED_FILE:-}" ]; then
            echo "Error: Refusing to load formula aiteamforge from untrusted tap doublenode/aiteamforge"
            exit 1
        fi
        # Normal: valid JSON for the available-version parse in check_brew_updates.
        echo '[{"versions":{"stable":"0.15.0"}}]'
        exit 0
        ;;
    "trust --tap"*)
        # ensure_tap_trusted: return success so tap_load_refused gate determines failure.
        exit 0
        ;;
    "--prefix"*)
        # get_framework_dir fallback (AITEAMFORGE_HOME is set in these tests — not reached).
        echo "/opt/homebrew"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
MOCK_EOF
chmod +x "$_MOCK_BIN/brew"

# ─────────────────────────────────────────────────────────────────────────────
# _reset_shim: clear all shim state files between cases.
# Prevents Case A's upgrade-done marker from leaking into Case C's
# --non-interactive re-probe path (which must NOT see a prior upgrade call).
# ─────────────────────────────────────────────────────────────────────────────
_reset_shim() {
    : > "$BREW_CALL_LOG"
    python3 -c "
import os
files = [
    '$MOCK_BREW_LIST_OUTPUT_FILE',
    '$MOCK_BREW_LIST_VERSIONS_FILE',
    '$MOCK_BREW_LIST_VERSIONS_POST_FILE',
    '$MOCK_BREW_OUTDATED_OUTPUT_FILE',
    '$MOCK_BREW_UPGRADE_EXIT_FILE',
    '$MOCK_BREW_UPGRADE_DONE_FILE',
    '$MOCK_BREW_INFO_UNTRUSTED_FILE',
    '$_AITEAMFORGE_DIR/.installed-version',
]
[os.remove(f) for f in files if os.path.exists(f)]
"
}

# ─────────────────────────────────────────────────────────────────────────────
# _run_upgrade: execute upgrade.sh as a subprocess via 'env bash upgrade.sh'.
# Using subprocess (not source) so BASH_SOURCE[0] resolves correctly inside
# upgrade.sh, enabling its own 'source libexec/lib/common.sh' etc. to work.
# stdin is /dev/null so prompt_yes_no auto-answers with the call-site default.
#
# Usage: _run_upgrade [args...]
# Sets after return: UPGRADE_OUTPUT (combined stdout+stderr), UPGRADE_EXIT
# ─────────────────────────────────────────────────────────────────────────────
_UPGRADE_OUTPUT_FILE="$TEST_TMP_DIR/upgrade-output.txt"
UPGRADE_OUTPUT=""
UPGRADE_EXIT=0

_run_upgrade() {
    UPGRADE_EXIT=0
    : > "$_UPGRADE_OUTPUT_FILE"

    env \
        AITEAMFORGE_DIR="$_AITEAMFORGE_DIR" \
        AITEAMFORGE_HOME="$_AITEAMFORGE_HOME" \
        WORKING_DIR="$_AITEAMFORGE_DIR" \
        AITEAMFORGE_SKIP_LAUNCHCTL=1 \
        PATH="$_MOCK_BIN:$PATH" \
        BREW_CALL_LOG="$BREW_CALL_LOG" \
        MOCK_BREW_LIST_OUTPUT_FILE="$MOCK_BREW_LIST_OUTPUT_FILE" \
        MOCK_BREW_LIST_VERSIONS_FILE="$MOCK_BREW_LIST_VERSIONS_FILE" \
        MOCK_BREW_LIST_VERSIONS_POST_FILE="$MOCK_BREW_LIST_VERSIONS_POST_FILE" \
        MOCK_BREW_OUTDATED_OUTPUT_FILE="$MOCK_BREW_OUTDATED_OUTPUT_FILE" \
        MOCK_BREW_UPGRADE_EXIT_FILE="$MOCK_BREW_UPGRADE_EXIT_FILE" \
        MOCK_BREW_UPGRADE_DONE_FILE="$MOCK_BREW_UPGRADE_DONE_FILE" \
        MOCK_BREW_INFO_UNTRUSTED_FILE="$MOCK_BREW_INFO_UNTRUSTED_FILE" \
        bash "$UPGRADE_SH" "$@" < /dev/null > "$_UPGRADE_OUTPUT_FILE" 2>&1
    UPGRADE_EXIT=$?

    UPGRADE_OUTPUT="$(cat "$_UPGRADE_OUTPUT_FILE")"
}

# ═══════════════════════════════════════════════════════════════════════════
# CASE A: No-op / stuck upgrade (version does not advance)
#
# Mock: brew list = installed, pre-version = 0.14.0, outdated = true,
#       brew upgrade exits 0 but version NEVER flips (no post-upgrade file).
# Expected: check_brew_updates detects pre==post → UPGRADE_BREW_FAILED=true
#           → final summary exits 1 + FAILURE banner + no success text.
# ═══════════════════════════════════════════════════════════════════════════

_reset_shim

# Setup: formula installed, old version, outdated; upgrade exits 0 but no version flip.
# No MOCK_BREW_LIST_VERSIONS_POST_FILE → _brew_installed_version always returns 0.14.0.
echo "aiteamforge"       > "$MOCK_BREW_LIST_OUTPUT_FILE"
echo "aiteamforge 0.14.0" > "$MOCK_BREW_LIST_VERSIONS_FILE"
echo "aiteamforge"       > "$MOCK_BREW_OUTDATED_OUTPUT_FILE"
echo "0"                 > "$MOCK_BREW_UPGRADE_EXIT_FILE"

_run_upgrade   # no --non-interactive: standard path; prompt_yes_no auto-answers via /dev/null

# ASSERT N1: exit code is 1
test_start "Case A — N1: stuck upgrade exits 1"
assert_exit_code 1 "$UPGRADE_EXIT" "Stuck/no-op upgrade must exit 1 (got $UPGRADE_EXIT)" && test_pass

# Anti-vacuity: captured output must be non-empty before any content assertions.
test_start "Case A — anti-vacuity: output is non-empty"
assert_not_empty "$UPGRADE_OUTPUT" "Upgrade output must not be empty (check subprocess invocation)" && test_pass

# ASSERT N2: output contains 'UPGRADE FAILED'
test_start "Case A — N2: FAILURE banner contains 'UPGRADE FAILED'"
assert_contains "$UPGRADE_OUTPUT" "UPGRADE FAILED" \
    "Stuck upgrade must print 'UPGRADE FAILED' (boxed banner)" && test_pass

# ASSERT N3: output contains 'NOT UPGRADED'
test_start "Case A — N3: FAILURE banner contains 'NOT UPGRADED'"
assert_contains "$UPGRADE_OUTPUT" "NOT UPGRADED" \
    "Stuck upgrade must print 'NOT UPGRADED' (boxed banner)" && test_pass

# ASSERT N4: output does NOT contain 'upgraded successfully'
test_start "Case A — N4: no false success message"
assert_not_contains "$UPGRADE_OUTPUT" "upgraded successfully" \
    "Stuck upgrade must NOT print 'upgraded successfully'" && test_pass

# ASSERT N5: .installed-version stamp does NOT advance to 0.15.0
test_start "Case A — N5: .installed-version stamp not advanced to 0.15.0"
_stamped="$(cat "$_AITEAMFORGE_DIR/.installed-version" 2>/dev/null | tr -d '[:space:]')"
# The stamp may be absent (fine) or 0.14.0 (also fine) — what it MUST NOT be is 0.15.0.
assert_not_equal "0.15.0" "$_stamped" \
    ".installed-version must NOT be 0.15.0 on stuck upgrade (got '$_stamped')" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# CASE B: Untrusted-tap refusal path
#
# Mock: brew list = installed, version = 0.14.0, outdated = true,
#       brew info returns refused-tap error text (MOCK_BREW_INFO_UNTRUSTED_FILE set).
# Expected: tap_load_refused() returns true → UPGRADE_BREW_FAILED=true early return
#           → final summary exits 1 + FAILURE banner.
# ═══════════════════════════════════════════════════════════════════════════

_reset_shim

# Setup: formula installed, old version, outdated, tap is untrusted.
# MOCK_BREW_INFO_UNTRUSTED_FILE presence triggers refused-tap text in brew info shim arm.
echo "aiteamforge"        > "$MOCK_BREW_LIST_OUTPUT_FILE"
echo "aiteamforge 0.14.0" > "$MOCK_BREW_LIST_VERSIONS_FILE"
echo "aiteamforge"        > "$MOCK_BREW_OUTDATED_OUTPUT_FILE"
echo "0"                  > "$MOCK_BREW_UPGRADE_EXIT_FILE"
touch "$MOCK_BREW_INFO_UNTRUSTED_FILE"

_run_upgrade   # no --non-interactive

# ASSERT N6: exit code is 1
test_start "Case B — N6: untrusted-tap refusal exits 1"
assert_exit_code 1 "$UPGRADE_EXIT" "Untrusted-tap must exit 1 (got $UPGRADE_EXIT)" && test_pass

# Anti-vacuity: output non-empty
test_start "Case B — anti-vacuity: output is non-empty"
assert_not_empty "$UPGRADE_OUTPUT" "Case B upgrade output must not be empty (check subprocess invocation)" && test_pass

# ASSERT N7: output contains FAILURE banner
test_start "Case B — N7: FAILURE banner present for untrusted-tap"
assert_contains "$UPGRADE_OUTPUT" "UPGRADE FAILED" \
    "Untrusted-tap must print 'UPGRADE FAILED'" && test_pass

# ASSERT N8: output does NOT contain success message
test_start "Case B — N8: no false success for untrusted-tap"
assert_not_contains "$UPGRADE_OUTPUT" "upgraded successfully" \
    "Untrusted-tap must NOT print 'upgraded successfully'" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# CASE C: Current box under --non-interactive must NOT false-fail
#
# Mock: brew list = installed, version = 0.15.0 (already current),
#       brew outdated = EMPTY stdout (up-to-date per stdout-presence detection).
# The upgrade-done marker is NOT present (fresh _reset_shim) — the
# --non-interactive path calls 'brew outdated' directly without a prior
# 'brew upgrade' call, so _still_outdated captures empty stdout.
#
# Expected: _still_outdated empty → UPGRADE_BREW_FAILED stays false → exit 0.
#
# INVERTED-PROBE REGRESSION GUARD: before the XACA-0702 fix (commit 2e2fe1a),
# the --non-interactive re-probe used exit code instead of stdout presence.
# 'brew outdated' exits 0 when UP-TO-DATE — the old code misread exit-0 as
# "is outdated" → false FAILURE. The fix detects via non-empty stdout, which
# is direction-unambiguous. This case proves the fixed behavior persists.
# ═══════════════════════════════════════════════════════════════════════════

_reset_shim
# Explicit guard: no upgrade-done marker should exist after _reset_shim.
# The --non-interactive path must NOT see a prior upgrade call's side-effects.
# (python3 in _reset_shim removed it; assert it's gone before setting up Case C)

# Setup: formula installed, already on latest version, NOT outdated.
echo "aiteamforge"        > "$MOCK_BREW_LIST_OUTPUT_FILE"
echo "aiteamforge 0.15.0" > "$MOCK_BREW_LIST_VERSIONS_FILE"
# EMPTY file = empty stdout from brew outdated = up to date (stdout-presence detection)
: > "$MOCK_BREW_OUTDATED_OUTPUT_FILE"
# No upgrade-exit-file needed — --non-interactive skips 'brew upgrade'
# No post-version-file needed — no upgrade call is made

_run_upgrade --non-interactive

# ASSERT N9: exit code is 0 (no false-fail)
test_start "Case C — N9: current box --non-interactive exits 0 (no false-fail)"
assert_exit_code 0 "$UPGRADE_EXIT" \
    "--non-interactive on current box must exit 0 (no false-fail), got $UPGRADE_EXIT" && test_pass

# Anti-vacuity: output non-empty
test_start "Case C — anti-vacuity: output is non-empty"
assert_not_empty "$UPGRADE_OUTPUT" "Case C upgrade output must not be empty (check subprocess invocation)" && test_pass

# ASSERT N10: output does NOT contain FAILURE banner
test_start "Case C — N10: no FAILURE banner for current box under --non-interactive"
assert_not_contains "$UPGRADE_OUTPUT" "UPGRADE FAILED" \
    "--non-interactive on current box must NOT print 'UPGRADE FAILED'" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# STATIC SOURCE ASSERTIONS
# Guard against re-introducing the inverted exit-code probe that XACA-0702 fixed.
# ═══════════════════════════════════════════════════════════════════════════

# STATIC 1: upgrade.sh uses _outdated_probe variable (stdout-presence detection)
test_start "STATIC: upgrade.sh uses _outdated_probe stdout-presence detection"
if grep -q "_outdated_probe" "$UPGRADE_SH"; then
    test_pass
else
    test_fail "upgrade.sh does not use _outdated_probe — inverted exit-code probe may have been re-introduced"
fi

# STATIC 2: upgrade.sh does NOT use inverted 'if brew outdated' exit-code gate
# The old broken pattern: 'if brew outdated aiteamforge; then ...' or 'if brew outdated ...'
# Exclude comment lines (lines that have only optional whitespace + '#' before content).
test_start "STATIC: upgrade.sh does NOT use inverted 'if brew outdated' exit-code check"
_non_comment_lines="$(grep -v '^\s*#' "$UPGRADE_SH")"
if echo "$_non_comment_lines" | grep -qE 'if.*brew outdated'; then
    test_fail "upgrade.sh contains 'if brew outdated' exit-code gate — inverted probe pattern detected (XACA-0702 regression)"
else
    test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# PARITY NOTE: upgrade.sh lives ONLY in the tap (homebrew-tap/libexec/commands/).
# There is no canonical source copy in scripts/ outside the tap.
# Parity assertion is N/A — no parallel worktree copy to compare against.
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone invocation only)
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
fi
exit 0
