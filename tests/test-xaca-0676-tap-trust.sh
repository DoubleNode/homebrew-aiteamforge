#!/bin/bash

# test-xaca-0676-tap-trust.sh
# Regression tests for XACA-0676: Homebrew untrusted-tap gate silently breaks
# aiteamforge auto-upgrade fleet-wide.
#
# REGRESSION INTENT: Recent Homebrew refuses to load formulae from an untrusted
# third-party tap when $HOMEBREW_REQUIRE_TAP_TRUST is set, making `brew outdated`/
# `brew upgrade` silently no-op. The fix adds:
#   - _aitf_tap_name()      — resolves tap name with env-var override
#   - tap_load_refused()    — detects the refused-load condition via `brew info`
#   - ensure_tap_trusted()  — idempotently runs `brew trust --tap <tap>`
# and wires them into upgrade.sh, doctor.sh, setup.sh, and auto-upgrade.sh.
#
# ALL tests use a MOCKED `brew` — the real tap is NEVER installed on M3Pro (dev box).
# Per dev-team policy, `brew tap doublenode/aiteamforge` is prohibited on this machine.
#
# Assertions:
#   1.  tap_load_refused returns TRUE (0) when `brew info` output contains "untrusted tap"
#   2.  tap_load_refused returns TRUE (0) when output contains "Refusing to load"
#   3.  tap_load_refused returns FALSE (1) when output is clean (no refused-load text)
#   4.  tap_load_refused returns FALSE (1) when brew is not on PATH
#   5.  tap_load_refused returns FALSE (1) when formula is simply not found (unrelated error)
#   6.  ensure_tap_trusted invokes `brew trust --tap doublenode/aiteamforge` (exact argv)
#   7.  ensure_tap_trusted returns 0 when brew trust succeeds
#   8.  ensure_tap_trusted returns non-zero when brew trust fails (without aborting)
#   9.  ensure_tap_trusted returns 0 (no-op success) when brew is not on PATH
#  10.  _aitf_tap_name returns the AITF_TAP_NAME override when set
#  11.  _aitf_tap_name falls back to AITF_TAP_NAME_DEFAULT when AITF_TAP_NAME unset
#  12.  _aitf_tap_name falls back to hardcoded "doublenode/aiteamforge" when both unset
#  STATIC SOURCE ASSERTIONS:
#  13.  setup.sh calls ensure_tap_trusted
#  14.  upgrade.sh check_brew_updates calls ensure_tap_trusted
#  15.  upgrade.sh check_brew_updates has loud-warn-and-return on still-refused tap
#       (tap_load_refused check AFTER ensure_tap_trusted, not fall-through to "up to date")
#  16.  doctor.sh has check_tap_trust function wired to "tap-trust" component dispatch
#  17.  doctor.sh check_tap_trust is also called in the "all" dispatch
#  18.  auto-upgrade.sh runs `brew trust --tap` BEFORE `brew update`
#  19.  auto-upgrade.sh exits 1 with a notify on a still-refused formula (after trusting)
#  PARITY:
#  20.  worktree scripts/auto-upgrade.sh is byte-identical to
#       homebrew-tap/share/scripts/auto-upgrade.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_SH="$TAP_ROOT/libexec/lib/common.sh"
CONSTANTS_SH="$TAP_ROOT/libexec/lib/constants.sh"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
DOCTOR_SH="$TAP_ROOT/libexec/commands/aiteamforge-doctor.sh"
SETUP_SH="$TAP_ROOT/bin/aiteamforge-setup.sh"
TAP_AUTO_UPGRADE_SH="$TAP_ROOT/share/scripts/auto-upgrade.sh"

# Resolve worktree root: the canonical dev-team worktree for this feature branch.
# Prefer the running worktree path, fall back to sibling detection.
if [ -n "${BASH_SOURCE[0]}" ]; then
    _this_real="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # tests/ is inside homebrew-tap/ which is inside the worktree
    # worktree path: <worktree>/homebrew-tap/tests/
    _wt_candidate="$(cd "$_this_real/../../../" && pwd)"
    if [ -f "$_wt_candidate/scripts/auto-upgrade.sh" ]; then
        WORKTREE_ROOT="$_wt_candidate"
    fi
fi
# Fallback: use the known worktree path for xaca-0676
if [ -z "${WORKTREE_ROOT:-}" ]; then
    WORKTREE_ROOT="/Users/darrenehlers/dev-team/worktrees/xaca-0676"
fi
WORKTREE_AUTO_UPGRADE_SH="$WORKTREE_ROOT/scripts/auto-upgrade.sh"

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
if ! type -t assert_contains >/dev/null 2>&1; then
    assert_contains() { [[ "$1" == *"$2"* ]] || { test_fail "${3:-Expected to find '$2'}"; return 1; }; }
fi
if ! type -t assert_file_exists >/dev/null 2>&1; then
    assert_file_exists() { [ -f "$1" ] || { test_fail "${2:-Expected file to exist: $1}"; return 1; }; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0676-test.XXXXXX)"
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
# Load the tap-trust helpers from common.sh and constants.sh into this shell.
# We source constants.sh first so AITF_TAP_NAME_DEFAULT is set, then common.sh
# for the three helpers under test. Stubs for print_* are provided so common.sh
# does not crash without the rest of the UI stack.
# ─────────────────────────────────────────────────────────────────────────────
for _p in print_section print_info print_success print_warning print_error header warn warning; do
    if ! declare -f "$_p" >/dev/null 2>&1; then eval "${_p}() { :; }"; fi
done

# Unset the guard so we can re-source common.sh cleanly in this test shell.
unset _COMMON_SH_LOADED

# Source constants.sh to get AITF_TAP_NAME_DEFAULT
# (unset readonly first in case a prior source set it — gracefully ignore)
if [ -f "$CONSTANTS_SH" ]; then
    # readonly variables can't be unset in bash; source inside a subshell to
    # extract only the value we need.
    _default_tap_name="$(
        bash -c "source \"$CONSTANTS_SH\" 2>/dev/null; echo \"\${AITF_TAP_NAME_DEFAULT:-doublenode/aiteamforge}\""
    )"
fi
AITF_TAP_NAME_DEFAULT="${_default_tap_name:-doublenode/aiteamforge}"
export AITF_TAP_NAME_DEFAULT

# Source common.sh to define the helpers
source "$COMMON_SH" 2>/dev/null || { echo "FATAL: could not source $COMMON_SH"; exit 1; }
for _fn in _aitf_tap_name tap_load_refused ensure_tap_trusted; do
    declare -f "$_fn" >/dev/null 2>&1 || { echo "FATAL: $COMMON_SH did not define $_fn"; exit 1; }
done

# ─────────────────────────────────────────────────────────────────────────────
# Mock brew infrastructure
# The mock brew binary is written to TEST_TMP_DIR/mock-bin/ and prepended to
# PATH. Tests configure mock behavior via:
#   MOCK_BREW_INFO_OUTPUT — what `brew info aiteamforge` emits
#   MOCK_BREW_TRUST_EXIT  — exit code for `brew trust --tap ...`
#   BREW_CALL_LOG         — appended to with argv on every invocation
# ─────────────────────────────────────────────────────────────────────────────
MOCK_BIN="$TEST_TMP_DIR/mock-bin"
mkdir -p "$MOCK_BIN"
BREW_CALL_LOG="$TEST_TMP_DIR/brew-calls.log"

# Create the mock brew script
cat > "$MOCK_BIN/brew" <<'MOCK_EOF'
#!/bin/bash
# Mock brew — logs every invocation, returns configurable outputs.
# State files:
#   $BREW_CALL_LOG              — appended with "$@" on each call
#   $MOCK_BREW_INFO_OUTPUT      — stdout for `brew info aiteamforge`
#   $MOCK_BREW_TRUST_EXIT       — exit code for `brew trust --tap ...`

# Log the call
if [ -n "${BREW_CALL_LOG:-}" ]; then
    printf '%s\n' "$*" >> "$BREW_CALL_LOG"
fi

case "$1" in
    info)
        echo "${MOCK_BREW_INFO_OUTPUT:-aiteamforge: stable 0.14.0}"
        exit 0
        ;;
    trust)
        exit "${MOCK_BREW_TRUST_EXIT:-0}"
        ;;
    *)
        exit 0
        ;;
esac
MOCK_EOF
chmod +x "$MOCK_BIN/brew"

# Prepend the mock bin to PATH for the duration of this test file.
# Real brew is still reachable by its absolute path if needed outside tests.
REAL_PATH="$PATH"
PATH="$MOCK_BIN:$PATH"
export PATH BREW_CALL_LOG

# Helper: reset the call log before each test that inspects it
_reset_brew_log() {
    : > "$BREW_CALL_LOG"
}

# Helper: check that exactly one line in the brew call log matches the expected argv string
_brew_was_called_with() {
    local expected="$1"
    grep -qxF "$expected" "$BREW_CALL_LOG"
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 1: tap_load_refused
# ═══════════════════════════════════════════════════════════════════════════

# TEST 1: returns TRUE when output contains "untrusted tap"
test_start "tap_load_refused: TRUE when brew info contains 'untrusted tap'"
MOCK_BREW_INFO_OUTPUT="Error: Refusing to load formula aiteamforge from untrusted tap doublenode/aiteamforge"
export MOCK_BREW_INFO_OUTPUT
_rc=0
tap_load_refused || _rc=$?
if [ "$_rc" -eq 0 ]; then
    test_pass
else
    test_fail "Expected exit 0 (true) but got exit $_rc"
fi

# TEST 2: returns TRUE when output contains "Refusing to load"
test_start "tap_load_refused: TRUE when brew info contains 'Refusing to load'"
MOCK_BREW_INFO_OUTPUT="Error: Refusing to load aiteamforge from tap"
export MOCK_BREW_INFO_OUTPUT
_rc=0
tap_load_refused || _rc=$?
if [ "$_rc" -eq 0 ]; then
    test_pass
else
    test_fail "Expected exit 0 (true) but got exit $_rc"
fi

# TEST 3: returns FALSE when output is clean
test_start "tap_load_refused: FALSE when brew info output is clean"
MOCK_BREW_INFO_OUTPUT="aiteamforge: stable 0.14.0 (bottled)
From: https://github.com/doublenode/homebrew-aiteamforge"
export MOCK_BREW_INFO_OUTPUT
_rc=0
tap_load_refused || _rc=$?
if [ "$_rc" -ne 0 ]; then
    test_pass
else
    test_fail "Expected exit non-0 (false) but got exit 0"
fi

# TEST 4: returns FALSE when brew is absent from PATH
test_start "tap_load_refused: FALSE when brew is not on PATH"
_saved_path="$PATH"
PATH="$TEST_TMP_DIR/no-such-dir"
_rc=0
tap_load_refused || _rc=$?
PATH="$_saved_path"
if [ "$_rc" -ne 0 ]; then
    test_pass
else
    test_fail "Expected exit non-0 (false) when brew absent, got exit 0"
fi

# TEST 5: returns FALSE when formula is simply not found (unrelated error)
test_start "tap_load_refused: FALSE when formula is not found (unrelated brew error)"
MOCK_BREW_INFO_OUTPUT="Error: No available formula with the name \"aiteamforge\"."
export MOCK_BREW_INFO_OUTPUT
_rc=0
tap_load_refused || _rc=$?
if [ "$_rc" -ne 0 ]; then
    test_pass
else
    test_fail "Expected exit non-0 (false) for unrelated brew error, got exit 0"
fi

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 2: ensure_tap_trusted
# ═══════════════════════════════════════════════════════════════════════════

# TEST 6: invokes `brew trust --tap doublenode/aiteamforge` with exact argv
test_start "ensure_tap_trusted: invokes 'brew trust --tap doublenode/aiteamforge'"
unset AITF_TAP_NAME
_reset_brew_log
MOCK_BREW_TRUST_EXIT=0
export MOCK_BREW_TRUST_EXIT
ensure_tap_trusted >/dev/null 2>&1 || true
if _brew_was_called_with "trust --tap doublenode/aiteamforge"; then
    test_pass
else
    test_fail "brew was not called with 'trust --tap doublenode/aiteamforge'. Logged calls: $(cat "$BREW_CALL_LOG")"
fi

# TEST 7: returns 0 when brew trust succeeds
test_start "ensure_tap_trusted: returns 0 on mock brew trust success"
_reset_brew_log
MOCK_BREW_TRUST_EXIT=0
export MOCK_BREW_TRUST_EXIT
_rc=99
ensure_tap_trusted >/dev/null 2>&1
_rc=$?
if [ "$_rc" -eq 0 ]; then
    test_pass
else
    test_fail "Expected exit 0 but got exit $_rc"
fi

# TEST 8: returns non-zero when brew trust fails (without aborting)
test_start "ensure_tap_trusted: returns non-zero on mock brew trust failure (no abort)"
_reset_brew_log
MOCK_BREW_TRUST_EXIT=1
export MOCK_BREW_TRUST_EXIT
_rc=0
ensure_tap_trusted >/dev/null 2>&1 || _rc=$?
MOCK_BREW_TRUST_EXIT=0
export MOCK_BREW_TRUST_EXIT
if [ "$_rc" -ne 0 ]; then
    test_pass
else
    test_fail "Expected non-zero exit on trust failure but got 0"
fi

# TEST 9: returns 0 (no-op success) when brew is absent from PATH
test_start "ensure_tap_trusted: returns 0 (no-op) when brew is not on PATH"
_saved_path="$PATH"
PATH="$TEST_TMP_DIR/no-such-dir"
_rc=99
ensure_tap_trusted >/dev/null 2>&1
_rc=$?
PATH="$_saved_path"
if [ "$_rc" -eq 0 ]; then
    test_pass
else
    test_fail "Expected exit 0 (no-op) when brew absent, got exit $_rc"
fi

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 3: _aitf_tap_name resolution
# ═══════════════════════════════════════════════════════════════════════════

# TEST 10: honors AITF_TAP_NAME override
test_start "_aitf_tap_name: honors AITF_TAP_NAME env override"
AITF_TAP_NAME="myfork/aiteamforge"
export AITF_TAP_NAME
_result="$(_aitf_tap_name)"
unset AITF_TAP_NAME
assert_equal "myfork/aiteamforge" "$_result" \
    "_aitf_tap_name should return AITF_TAP_NAME override, got '$_result'" && test_pass

# TEST 11: falls back to AITF_TAP_NAME_DEFAULT when AITF_TAP_NAME unset
test_start "_aitf_tap_name: falls back to AITF_TAP_NAME_DEFAULT"
unset AITF_TAP_NAME
AITF_TAP_NAME_DEFAULT="testorg/aiteamforge"
export AITF_TAP_NAME_DEFAULT
_result="$(_aitf_tap_name)"
AITF_TAP_NAME_DEFAULT="doublenode/aiteamforge"
export AITF_TAP_NAME_DEFAULT
assert_equal "testorg/aiteamforge" "$_result" \
    "_aitf_tap_name should fall back to AITF_TAP_NAME_DEFAULT, got '$_result'" && test_pass

# TEST 12: falls back to hardcoded "doublenode/aiteamforge" when both unset
test_start "_aitf_tap_name: falls back to hardcoded 'doublenode/aiteamforge' when both vars unset"
unset AITF_TAP_NAME
unset AITF_TAP_NAME_DEFAULT
_result="$(_aitf_tap_name)"
AITF_TAP_NAME_DEFAULT="doublenode/aiteamforge"
export AITF_TAP_NAME_DEFAULT
assert_equal "doublenode/aiteamforge" "$_result" \
    "_aitf_tap_name should fall back to 'doublenode/aiteamforge', got '$_result'" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 4: Static source assertions
# ═══════════════════════════════════════════════════════════════════════════

# TEST 13: setup.sh calls ensure_tap_trusted
test_start "STATIC: setup.sh calls ensure_tap_trusted"
assert_file_exists "$SETUP_SH" "setup.sh must exist at $SETUP_SH"
if grep -q "ensure_tap_trusted" "$SETUP_SH"; then
    test_pass
else
    test_fail "setup.sh does not call ensure_tap_trusted — XACA-0676 fix missing"
fi

# TEST 14: upgrade.sh check_brew_updates calls ensure_tap_trusted
test_start "STATIC: upgrade.sh check_brew_updates calls ensure_tap_trusted"
assert_file_exists "$UPGRADE_SH" "upgrade.sh must exist at $UPGRADE_SH"
# Extract the check_brew_updates function body and verify ensure_tap_trusted is called within it
_cbr_body="$(awk '/^check_brew_updates\(\) \{/{capture=1} capture{print} capture && /^\}$/{exit}' "$UPGRADE_SH")"
if [ -z "$_cbr_body" ]; then
    test_fail "could not extract check_brew_updates function from upgrade.sh"
elif echo "$_cbr_body" | grep -q "ensure_tap_trusted"; then
    test_pass
else
    test_fail "check_brew_updates does not call ensure_tap_trusted — XACA-0676 fix missing"
fi

# TEST 15: upgrade.sh has loud-warn-and-return on still-refused tap
# (tap_load_refused check AFTER ensure_tap_trusted, then return — not fall-through to "up to date")
test_start "STATIC: upgrade.sh check_brew_updates warns loudly and returns when tap still refused"
_cbr_body_15="$(awk '/^check_brew_updates\(\) \{/{capture=1} capture{print} capture && /^\}$/{exit}' "$UPGRADE_SH")"
# The function must: call tap_load_refused (post-trust check), then return without
# reaching the "up to date" path. We verify: (a) tap_load_refused appears AFTER
# ensure_tap_trusted in the function body, and (b) a BLOCKED/refused warning is present.
_has_refused_check=false
_has_loud_warn=false
if echo "$_cbr_body_15" | grep -q "tap_load_refused"; then
    _has_refused_check=true
fi
if echo "$_cbr_body_15" | grep -qiE "UNTRUSTED|REFUSING|BLOCKED|refused|block"; then
    _has_loud_warn=true
fi
# Verify ordering: ensure_tap_trusted must appear before tap_load_refused in the body
_trust_line="$(echo "$_cbr_body_15" | grep -n "ensure_tap_trusted" | head -1 | cut -d: -f1)"
_refused_line="$(echo "$_cbr_body_15" | grep -n "tap_load_refused" | head -1 | cut -d: -f1)"
_order_ok=false
if [ -n "$_trust_line" ] && [ -n "$_refused_line" ] && [ "$_trust_line" -lt "$_refused_line" ]; then
    _order_ok=true
fi
if [ "$_has_refused_check" = true ] && [ "$_has_loud_warn" = true ] && [ "$_order_ok" = true ]; then
    test_pass
else
    test_fail "check_brew_updates missing post-trust tap_load_refused check or loud warning. refused_check=$_has_refused_check loud_warn=$_has_loud_warn order_ok=$_order_ok"
fi

# TEST 16: doctor.sh has check_tap_trust wired to "tap-trust" component dispatch
test_start "STATIC: doctor.sh routes 'tap-trust' component to check_tap_trust"
assert_file_exists "$DOCTOR_SH" "doctor.sh must exist at $DOCTOR_SH"
# The case statement must have a "tap-trust)" arm that calls check_tap_trust
if grep -A2 "tap-trust)" "$DOCTOR_SH" | grep -q "check_tap_trust"; then
    test_pass
else
    test_fail "doctor.sh does not route 'tap-trust' to check_tap_trust — XACA-0676 fix missing"
fi

# TEST 17: doctor.sh check_tap_trust is also called in the "all" dispatch
test_start "STATIC: doctor.sh 'all' dispatch calls check_tap_trust"
# The all) arm uses 2-space indentation. Extract from 'all)' through the closing ';;'.
# Use grep to find the line number of the all) arm, then read lines until ';;'.
_all_start="$(grep -n '^\s*all\s*)' "$DOCTOR_SH" | tail -1 | cut -d: -f1)"
if [ -z "$_all_start" ]; then
    test_fail "could not find 'all)' arm in doctor.sh case statement"
else
    _all_body="$(awk "NR>=$_all_start" "$DOCTOR_SH" | awk '/^\s*;;/{exit} {print}')"
    if echo "$_all_body" | grep -q "check_tap_trust"; then
        test_pass
    else
        test_fail "doctor.sh 'all' dispatch does not call check_tap_trust — XACA-0676 fix missing"
    fi
fi

# TEST 18: auto-upgrade.sh runs `brew trust --tap` BEFORE `brew update`
test_start "STATIC: auto-upgrade.sh runs 'brew trust --tap' before 'brew update'"
assert_file_exists "$TAP_AUTO_UPGRADE_SH" "tap auto-upgrade.sh must exist"
# Match only non-comment executable lines. The actual code uses `$BREW trust` and
# `$BREW update` via log_cmd_output — grep for the actual invocation patterns,
# NOT the comment/log lines that describe what the script does.
_trust_ln="$(grep -n '^\s*if.*trust\|log_cmd_output.*trust' "$TAP_AUTO_UPGRADE_SH" | head -1 | cut -d: -f1)"
_update_ln="$(grep -n '^\s*if.*update\|log_cmd_output.*update' "$TAP_AUTO_UPGRADE_SH" | head -1 | cut -d: -f1)"
if [ -z "$_trust_ln" ]; then
    test_fail "auto-upgrade.sh does not have an executable 'trust' call (log_cmd_output or if)"
elif [ -z "$_update_ln" ]; then
    test_fail "auto-upgrade.sh does not have an executable 'update' call (log_cmd_output or if)"
elif [ "$_trust_ln" -lt "$_update_ln" ]; then
    test_pass
else
    test_fail "brew trust (line $_trust_ln) appears AFTER brew update (line $_update_ln) — wrong order"
fi

# TEST 19: auto-upgrade.sh exits 1 with a notify on still-refused formula
test_start "STATIC: auto-upgrade.sh exits 1 with notify on still-refused formula (after trusting)"
# Must have: the refused-load grep check, a log ERROR, notify, and exit 1
_has_refused_grep=false
_has_exit_1=false
_has_notify=false
if grep -qiE "untrusted tap|refus(e|ing) to load" "$TAP_AUTO_UPGRADE_SH"; then
    _has_refused_grep=true
fi
# exit 1 should appear near the refused-tap detection block
# Find the line of the refused-load grep and check that exit 1 appears shortly after
_refused_ln="$(grep -n "untrusted tap\|Refus" "$TAP_AUTO_UPGRADE_SH" | head -1 | cut -d: -f1)"
if [ -n "$_refused_ln" ]; then
    # Check for exit 1 within 10 lines after the detection
    _block="$(awk "NR>=$_refused_ln && NR<=$((_refused_ln+12))" "$TAP_AUTO_UPGRADE_SH")"
    if echo "$_block" | grep -q "exit 1"; then
        _has_exit_1=true
    fi
    if echo "$_block" | grep -q "notify"; then
        _has_notify=true
    fi
fi
if [ "$_has_refused_grep" = true ] && [ "$_has_exit_1" = true ] && [ "$_has_notify" = true ]; then
    test_pass
else
    test_fail "auto-upgrade.sh missing refused-tap detection+exit1+notify block. refused_grep=$_has_refused_grep exit1=$_has_exit_1 notify=$_has_notify"
fi

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 5: Parity assertion
# ═══════════════════════════════════════════════════════════════════════════

# TEST 20: worktree scripts/auto-upgrade.sh is byte-identical to tap share copy
test_start "PARITY: worktree scripts/auto-upgrade.sh is byte-identical to homebrew-tap/share/scripts/auto-upgrade.sh"
if [ ! -f "$WORKTREE_AUTO_UPGRADE_SH" ]; then
    test_fail "Worktree copy not found at $WORKTREE_AUTO_UPGRADE_SH — cannot verify parity"
elif [ ! -f "$TAP_AUTO_UPGRADE_SH" ]; then
    test_fail "Tap share copy not found at $TAP_AUTO_UPGRADE_SH — cannot verify parity"
elif diff -q "$WORKTREE_AUTO_UPGRADE_SH" "$TAP_AUTO_UPGRADE_SH" >/dev/null 2>&1; then
    test_pass
else
    test_fail "Files differ! Worktree: $WORKTREE_AUTO_UPGRADE_SH vs Tap: $TAP_AUTO_UPGRADE_SH. Diff follows:$(diff "$WORKTREE_AUTO_UPGRADE_SH" "$TAP_AUTO_UPGRADE_SH" | head -20)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Restore PATH (belt-and-suspenders — trap EXIT cleanup handles tmp dir)
# ─────────────────────────────────────────────────────────────────────────────
PATH="$REAL_PATH"
export PATH

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone invocation only)
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
fi
exit 0
