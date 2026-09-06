#!/bin/bash
# test-xaca-1097-launchagent-disabled-autofix.sh
#
# XACA-1097 defect 1: _val_check_launchagents() in
# libexec/lib/validate-install.sh (lines ~545-556) "auto-fixes" an unloaded
# LaunchAgent by calling `_aitf_launchctl load "$plist"` and treats a ZERO
# exit code as proof the agent is now running:
#
#     elif launchctl list 2>/dev/null | grep -q "$agent"; then
#         _val_pass "${agent} loaded"
#     else
#         # Auto-fix: load the plist instead of just warning
#         if _aitf_launchctl load "$plist" 2>/dev/null; then
#             _val_pass "${agent} loaded (was unloaded — auto-fixed)"
#         else
#             _val_warn "${agent} plist exists but could not load" \
#                 "Run: launchctl load '${plist}'"
#         fi
#     fi
#
# Measured real macOS behavior (darren-m1pro-mbp, 2026-09-04) when the
# service is DISABLED (`launchctl print-disabled gui/501` lists it):
#
#     $ launchctl load ~/Library/LaunchAgents/com.aiteamforge.lcars-health.plist
#       Load failed: 5: Input/output error
#     $ echo $?                                -> 0
#     $ launchctl list | grep -c lcars-health   -> 0
#
# `load` on a disabled service exits 0 (success) while never actually
# registering the job. The code above only inspects the exit code, never
# the disabled state (it does not call `launchctl print-disabled` at all),
# so it records a _val_pass(... "auto-fixed") for a service that is STILL
# not loaded — a false PASS a human or CI would read as "healthy".
#
# This test injects a FAKE `launchctl` on PATH that reproduces the measured
# behavior faithfully (load/unload/bootstrap all report the I/O error 5 but
# load/unload still exit 0, exactly like the real binary; list never emits
# the label because the job was genuinely never registered) and proves
# _val_check_launchagents records that false pass.
#
# AITEAMFORGE_SKIP_LAUNCHCTL IS DELIBERATELY LEFT UNSET. Setting it to "1"
# would make the _aitf_launchctl wrapper (libexec/lib/common.sh) return 0
# WITHOUT EVER CALLING launchctl — the fake binary above would never run
# and this test would go vacuously green, exercising nothing. See
# test-xaca-0683-skip-launchctl.sh for that wrapper's own (correct, narrow)
# contract — this ticket is not testing that wrapper's skip behavior, it is
# testing what happens when the wrapper DOES pass through.
#
# Verified against unfixed code at 1e502d3 (homebrew-tap detached HEAD,
# XACA-1097 worktree) — this test FAILS today. That failure IS the
# reproduction; the fix must make it pass.
#
# Designed to run standalone OR via test-runner.sh (matches the
# test-xaca-1095-017-helpers-drift-check.sh convention).

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATE_LIB="$TAP_ROOT/libexec/lib/validate-install.sh"

AGENT_LABEL="com.aiteamforge.lcars-health"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: fallbacks ONLY when test-runner.sh hasn't already
# exported test_start/test_pass/test_fail. A bare initializer with an
# unconditional trailing echo would be the vacuous-green shape this ticket
# exists to eliminate, so the standalone summary below gates its exit code
# on the _FAIL counter, never on presence of output alone.
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
_PASS=0
_FAIL=0
_CURRENT_TEST=""

if ! declare -F test_start &>/dev/null; then
    _STANDALONE=true
    test_start() { _CURRENT_TEST="$1"; printf "TEST: %s\n" "$1"; }
    test_pass()  { _PASS=$((_PASS + 1)); printf "  PASS: %s\n" "$_CURRENT_TEST"; }
    test_fail()  { _FAIL=$((_FAIL + 1)); printf "  FAIL: %s -- %s\n" "$_CURRENT_TEST" "${1:-}" >&2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# XACA-1097-007 hardening (Problem 2): neither our own standalone fallback
# above nor test-runner.sh's exported test_pass() gates on whether test_fail
# already fired for the current block (test-runner.sh's test_pass()
# unconditionally increments PASSED_TESTS). A bare trailing `test_pass()`
# after a failing assertion therefore prints BOTH a FAIL and a PASS line for
# the same test name, making the PASS tally meaningless — the same class of
# defect this whole ticket is about (a harness recording a result it never
# verified). Route every assertion through _block_note_fail() and end the
# block with _block_end() instead of a bare test_pass().
# ─────────────────────────────────────────────────────────────────────────────
_BLOCK_FAILED=false

_block_start() {
    _BLOCK_FAILED=false
    test_start "$1"
}

_block_note_fail() {
    _BLOCK_FAILED=true
    test_fail "$1"
}

_block_end() {
    if [ "$_BLOCK_FAILED" = false ]; then
        test_pass
    fi
}

assert_eq() {
    local got="$1" expected="$2" msg="${3:-Expected [$2], got [$1]}"
    [ "$got" = "$expected" ] || _block_note_fail "$msg"
}
assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-Expected to find [$2] in output}"
    [[ "$haystack" == *"$needle"* ]] || _block_note_fail "$msg"
}
assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-Expected NOT to find [$2] in output}"
    [[ "$haystack" != *"$needle"* ]] || _block_note_fail "$msg"
}

if [ ! -f "$VALIDATE_LIB" ]; then
    echo "FATAL: libexec/lib/validate-install.sh not found at: $VALIDATE_LIB" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Fixture sandbox
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1097-launchagent-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi

_cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap _cleanup EXIT INT TERM

SANDBOX="$TEST_TMP_DIR/xaca1097-launchagent"
MOCK_BIN="$SANDBOX/mockbin"
FAKE_HOME="$SANDBOX/home"
mkdir -p "$MOCK_BIN" "$FAKE_HOME/Library/LaunchAgents"

# Fake launchctl emulating a DISABLED LaunchAgent. Faithful to the measured
# real binary: load/unload/bootstrap report the I/O error 5 that a disabled
# service produces; load/unload still exit 0 (matching real launchctl —
# only bootstrap surfaces a nonzero exit for this failure mode); list NEVER
# emits the label, because the job genuinely never registered.
cat > "$MOCK_BIN/launchctl" <<'FAKE'
#!/bin/bash
case "$1" in
    load)
        echo "Load failed: 5: Input/output error" >&2
        exit 0
        ;;
    unload)
        echo "Unload failed: 5: Input/output error" >&2
        exit 0
        ;;
    bootstrap)
        echo "Bootstrap failed: 5: Input/output error" >&2
        exit 1
        ;;
    list)
        exit 0
        ;;
    print-disabled)
        echo "com.aiteamforge.lcars-health => disabled"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
FAKE
chmod +x "$MOCK_BIN/launchctl"

cat > "$FAKE_HOME/Library/LaunchAgents/${AGENT_LABEL}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist><dict><key>Label</key><string>${AGENT_LABEL}</string></dict></plist>
PLIST

# ─────────────────────────────────────────────────────────────────────────────
# Run the actual seam under /bin/bash (macOS system bash 3.2) — the shipped
# scripts run under 3.2, not whatever bash 5.x happens to lead PATH on this
# machine. Sourced fresh in a child process per XACA-1097 case; no
# AITEAMFORGE_SKIP_LAUNCHCTL is set (see header note above).
# ─────────────────────────────────────────────────────────────────────────────
_block_start "disabled LaunchAgent auto-fix must not record a false PASS (XACA-1097)"

CHECK_OUTPUT="$(
    HOME="$FAKE_HOME" \
    PATH="$MOCK_BIN:/usr/bin:/bin" \
    /bin/bash -c "
        unset AITEAMFORGE_SKIP_LAUNCHCTL
        source '$VALIDATE_LIB'
        _val_check_launchagents
        echo '___COUNTERS___'
        echo \"PASS=\${_VAL_PASS}\"
    " 2>&1
)"

PASS_COUNT="$(printf '%s\n' "$CHECK_OUTPUT" | grep '^PASS=' | sed -E 's/PASS=([0-9]+).*/\1/')"

# XACA-1097-007 hardening (defense in depth, same class as Problem 1 in the
# doctor-phantom-deps suite even though this file's own assertions are
# already positive/exact — assert_contains + assert_eq, not
# assert_not_contains — so this specific file was not vulnerable to the
# vacuous-empty-haystack hole. Still: prove the fixture genuinely invoked
# _val_check_launchagents() rather than silently no-op'ing (e.g. `source`
# failing) by requiring its unconditional _val_section("LaunchAgents")
# header to be present.
assert_contains "$CHECK_OUTPUT" "LaunchAgents" \
    "expected the unconditional _val_section(\"LaunchAgents\") header — its absence means _val_check_launchagents() never actually ran (source failed or function missing)"

# Sanity check FIRST: confirm, via the SAME fake launchctl, that the agent
# really is still absent from the loaded-jobs list. This guards against the
# fake itself being a silent no-op (the exact AITEAMFORGE_SKIP_LAUNCHCTL
# trap called out in this ticket) — if this assertion ever fails, the test
# fixture is broken, not the production code.
ACTUALLY_LOADED="$(PATH="$MOCK_BIN:/usr/bin:/bin" /bin/bash -c "launchctl list 2>/dev/null | grep -c '${AGENT_LABEL}'" || true)"
assert_eq "$ACTUALLY_LOADED" "0" \
    "sanity: fake launchctl must confirm the agent is still NOT in the loaded-jobs list (fixture broken if nonzero)"

# XACA-1097-020 hardening (review finding on PR #824): a bare
# `assert_contains "$CHECK_OUTPUT" "auto-fixed"` DISCRIMINATES NOTHING — the
# fixed code's disabled-service warning message is literally "...cannot be
# auto-fixed...", which contains "auto-fixed" as a substring just as
# certainly as the ORIGINAL buggy code's false-pass message "...was
# unloaded — auto-fixed". Both old and new code satisfy that assertion; it
# would keep "passing" even if this suite's fix were reverted. Replaced with
# two assertions that actually differ between the two: the fixed code must
# emit the disabled-service warning verbatim, and must NOT emit the old
# false-success phrase at all.
assert_contains "$CHECK_OUTPUT" "cannot be auto-fixed" \
    "expected the disabled-service warning (\"...is disabled — cannot be auto-fixed...\") -- current code did not classify the service as disabled before attempting to load it"
assert_not_contains "$CHECK_OUTPUT" "was unloaded — auto-fixed" \
    "current code claims the auto-fix succeeded (\"was unloaded — auto-fixed\") even though the service never registered -- this is the exact false-PASS phrase the original defect emitted"
assert_eq "$PASS_COUNT" "0" \
    "must NOT record a _val_pass for an agent that launchctl load could not actually register (recorded ${PASS_COUNT})"

_block_end

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone mode only — test-runner.sh tallies pass/fail from its
# OWN exported functions' output).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "──────────────────────────────────────────────"
    echo "  launchagent disabled-autofix test:  PASS=$_PASS  FAIL=$_FAIL"
    echo "──────────────────────────────────────────────"
    [ "$_FAIL" -eq 0 ] || exit 1
fi
exit 0
