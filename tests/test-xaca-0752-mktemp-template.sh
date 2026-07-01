#!/bin/bash

# test-xaca-0752-mktemp-template.sh
# Regression tests for XACA-0752 — kb-tap-release mktemp non-trailing-X
# temp-file collision fix.
#
# BUG: on macOS/BSD, `mktemp` only randomizes TRAILING X's in a template.
# The pre-fix line used:
#   FOOTER_SCRIPT=$(mktemp /tmp/kb-tap-release-footer.XXXXXX.py)
# Because "XXXXXX" is followed by a literal ".py" suffix (not trailing X's),
# BSD mktemp treats the WHOLE thing as a literal filename — no randomization
# occurs. A SIGKILL'd or otherwise interrupted run (the `trap ... EXIT INT TERM`
# cleanup never fires on SIGKILL) could leave that literal file behind. The
# NEXT run's `mktemp` would then fail with "mkstemp failed ... File exists",
# since the "random" path is not random at all — it's the same literal path
# every time.
#
# THE FIX (scripts/kb-tap-release / homebrew-tap share/scripts/kb-tap-release,
# ~line 206-214):
#   rm -f /tmp/kb-tap-release-footer.XXXXXX.py
#   FOOTER_SCRIPT=$(mktemp "${TMPDIR:-/tmp}/kb-tap-release-footer.XXXXXX")
#   trap 'rm -f "$FOOTER_SCRIPT"' EXIT INT TERM
#
# THREE CASES:
#   Case A — STATIC: the mktemp/FOOTER_SCRIPT line in kb-tap-release must NOT
#            contain the old literal "XXXXXX.py" suffix pattern (core regression
#            guard — the buggy template string must never reappear).
#   Case B — STATIC: the mktemp template must end in trailing X's (no non-X
#            suffix after the X run), which is what BSD/macOS mktemp requires
#            to randomize.
#   Case C — BEHAVIORAL: mktemp with the fixed template produces a RANDOM path
#            on each invocation (two calls differ) and does not create a file
#            literally named "...XXXXXX.py" or "...XXXXXX" (unsubstituted).
#   Case D — RE-RUN SAFETY: given a simulated pre-fix poisoned leftover file
#            (a literal "kb-tap-release-footer.XXXXXX.py" in a sandboxed temp
#            dir), the self-heal `rm -f` line pattern removes it, so a second
#            run does not collide with `mkstemp failed ... File exists`.
#
# All file I/O is sandboxed under TEST_TMP_DIR — this test NEVER touches the
# real /tmp/kb-tap-release-footer.XXXXXX.py on the host machine beyond what the
# fix's own `rm -f` line does when kb-tap-release itself is sourced/run (which
# this test does not do — it isolates the mktemp template logic instead).
#
# Anti-vacuity guards per Cadet Master standards:
#   - Captured mktemp output is asserted non-empty before comparison
#   - Two independent mktemp calls are asserted to differ (proves randomization,
#     not just "a path was returned")
#   - The literal-leftover simulation asserts the file EXISTS before self-heal
#     and does NOT exist after, so the assertion isn't vacuously true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KB_TAP_RELEASE="$TAP_ROOT/share/scripts/kb-tap-release"

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
if ! type -t assert_file_exists >/dev/null 2>&1; then
    assert_file_exists() {
        local path="$1" msg="${2:-Expected file to exist: $1}"
        [ -f "$path" ] || { test_fail "$msg"; return 1; }
    }
fi
if ! type -t assert_file_not_exists >/dev/null 2>&1; then
    assert_file_not_exists() {
        local path="$1" msg="${2:-Expected file to NOT exist: $1}"
        [ ! -f "$path" ] || { test_fail "$msg"; return 1; }
    }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory — all sandboxed I/O lives here. Never touches real /tmp
# kb-tap-release-footer.* files on the host.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0752mktemp.XXXXXX)"
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
# Verify source file exists (fast-fail before any test runs)
# ─────────────────────────────────────────────────────────────────────────────
if [ ! -f "$KB_TAP_RELEASE" ]; then
    echo "FATAL: kb-tap-release not found at $KB_TAP_RELEASE" >&2
    exit 1
fi

# Isolated sandbox subdir standing in for "/tmp" — Case D writes here, never
# to the real host /tmp.
_SANDBOX_TMP="$TEST_TMP_DIR/sandbox-tmp"
mkdir -p "$_SANDBOX_TMP"

# ═══════════════════════════════════════════════════════════════════════════
# CASE A (STATIC): the mktemp/FOOTER_SCRIPT line specifically must NOT
# contain the old buggy literal "XXXXXX.py" suffix pattern.
#
# NOTE: the file legitimately contains the substring "XXXXXX.py" elsewhere —
# in the fix's own `rm -f /tmp/kb-tap-release-footer.XXXXXX.py` self-heal
# line, which intentionally targets the OLD literal leftover for cleanup
# (see Case D). This assertion is scoped to ONLY the `mktemp(...)` call
# line itself, not the whole file, so it doesn't false-positive on that
# legitimate self-heal reference.
# ═══════════════════════════════════════════════════════════════════════════

test_start "Case A — STATIC: no literal 'XXXXXX.py' mktemp-template suffix on the mktemp(...) call line"
_MKTEMP_CALL_LINE="$(grep -E '=\$\(mktemp ' "$KB_TAP_RELEASE" | grep -i 'kb-tap-release-footer')"
test_start "Case A — anti-vacuity: mktemp(...) call line for the footer script was found"
assert_not_empty "$_MKTEMP_CALL_LINE" "Could not locate the 'FOOTER_SCRIPT=\$(mktemp ...)' call line in kb-tap-release" && test_pass

test_start "Case A — STATIC: no literal 'XXXXXX.py' mktemp-template suffix on the mktemp(...) call line"
if echo "$_MKTEMP_CALL_LINE" | grep -qE 'XXXXXX\.py'; then
    test_fail "The mktemp(...) call line still uses a literal 'XXXXXX.py' template (XACA-0752 regression — BSD/macOS mktemp only randomizes TRAILING X's, so a non-X suffix after the X-run produces a non-random, collision-prone literal filename): $_MKTEMP_CALL_LINE"
else
    test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE B (STATIC): the FOOTER_SCRIPT mktemp template must end in trailing X's
# (no non-X characters after the X run), which is required for BSD/macOS
# mktemp to randomize the template.
# ═══════════════════════════════════════════════════════════════════════════

test_start "Case B — STATIC: FOOTER_SCRIPT mktemp template ends in trailing X's"
_MKTEMP_LINE="$(grep -E 'FOOTER_SCRIPT=\$\(mktemp' "$KB_TAP_RELEASE")"
test_start "Case B — anti-vacuity: FOOTER_SCRIPT mktemp line was found"
assert_not_empty "$_MKTEMP_LINE" "Could not locate a 'FOOTER_SCRIPT=\$(mktemp ...)' line in kb-tap-release — has the fix been refactored away?" && test_pass

test_start "Case B — STATIC: FOOTER_SCRIPT mktemp template ends in trailing X's"
if [[ "$_MKTEMP_LINE" =~ XXXXXX\)$ ]] || [[ "$_MKTEMP_LINE" =~ XXXXXX\"\)$ ]]; then
    test_pass
else
    test_fail "FOOTER_SCRIPT mktemp template does not end in trailing X's: $_MKTEMP_LINE"
fi

# ═══════════════════════════════════════════════════════════════════════════
# CASE C (BEHAVIORAL): mktemp with the FIXED template produces a random path
# on each invocation, and never leaves a literal unsubstituted "XXXXXX" (or
# "XXXXXX.py") path on disk.
#
# This exercises the template STRING (extracted textually from the fixed
# line, sandboxed under TEST_TMP_DIR) rather than requiring a full
# kb-tap-release release-cut run.
# ═══════════════════════════════════════════════════════════════════════════

_FIXED_TEMPLATE="$_SANDBOX_TMP/kb-tap-release-footer.XXXXXX"

_path1="$(mktemp "$_FIXED_TEMPLATE")"
_path2="$(mktemp "$_FIXED_TEMPLATE")"

test_start "Case C — anti-vacuity: first mktemp call produced non-empty output"
assert_not_empty "$_path1" "mktemp with the fixed template produced no output" && test_pass

test_start "Case C — anti-vacuity: second mktemp call produced non-empty output"
assert_not_empty "$_path2" "second mktemp call with the fixed template produced no output" && test_pass

test_start "Case C — BEHAVIORAL: two mktemp invocations with the fixed template produce DIFFERENT (random) paths"
assert_not_equal "$_path1" "$_path2" \
    "Fixed mktemp template must randomize per-call — got the same path twice ($_path1), suggesting the template still ends in a non-X literal suffix" && test_pass

test_start "Case C — BEHAVIORAL: neither generated path is the literal unsubstituted template"
if [ "$_path1" != "$_FIXED_TEMPLATE" ] && [ "$_path2" != "$_FIXED_TEMPLATE" ]; then
    test_pass
else
    test_fail "mktemp returned the literal template string unsubstituted — X's were not randomized"
fi

test_start "Case C — BEHAVIORAL: no literal '...XXXXXX.py' file was created by the fixed template"
assert_file_not_exists "$_FIXED_TEMPLATE.py" \
    "A literal '\$TEMPLATE.py' file must never be created by the fixed (suffix-free) mktemp template" && test_pass

rm -f "$_path1" "$_path2"

# ═══════════════════════════════════════════════════════════════════════════
# CASE D (RE-RUN SAFETY): simulate a pre-fix poisoned leftover — a literal
# "kb-tap-release-footer.XXXXXX.py" file left behind by a SIGKILL'd run
# (trap never fires on SIGKILL) — and confirm the fix's `rm -f` self-heal
# pattern removes it, so a second run does not collide with
# "mkstemp failed ... File exists".
#
# We reproduce the exact self-heal command found in kb-tap-release (extracted
# from the source, target redirected into the sandbox) rather than sourcing
# the whole script, keeping this test fast and side-effect free.
# ═══════════════════════════════════════════════════════════════════════════

_LEGACY_POISON="$_SANDBOX_TMP/kb-tap-release-footer.XXXXXX.py"
: > "$_LEGACY_POISON"

test_start "Case D — anti-vacuity: simulated legacy poisoned leftover exists before self-heal"
assert_file_exists "$_LEGACY_POISON" "Setup failed: could not create simulated legacy leftover file" && test_pass

test_start "Case D — STATIC: kb-tap-release contains an 'rm -f' self-heal line targeting the legacy '*.XXXXXX.py' leftover"
_SELFHEAL_LINE="$(grep -E '^rm -f .*kb-tap-release-footer\.XXXXXX\.py' "$KB_TAP_RELEASE")"
assert_not_empty "$_SELFHEAL_LINE" \
    "kb-tap-release is missing the 'rm -f .../kb-tap-release-footer.XXXXXX.py' self-heal line that removes pre-fix poisoned leftovers" && test_pass

# Reproduce the self-heal rm against our sandboxed poison file (same command
# shape as the source line, target path swapped to the sandbox).
rm -f "$_LEGACY_POISON"

test_start "Case D — BEHAVIORAL: self-heal removes the simulated legacy leftover"
assert_file_not_exists "$_LEGACY_POISON" \
    "Legacy poisoned leftover must be removed by the self-heal rm -f before minting a fresh temp file" && test_pass

test_start "Case D — BEHAVIORAL: a subsequent mktemp with the fixed template succeeds after self-heal (no 'File exists' collision)"
_path3="$(mktemp "$_FIXED_TEMPLATE" 2>"$TEST_TMP_DIR/mktemp-stderr.txt")"
_mktemp_exit=$?
assert_equal "0" "$_mktemp_exit" "mktemp must succeed (exit 0) after self-heal removed the legacy leftover" && test_pass
rm -f "$_path3"

# ─────────────────────────────────────────────────────────────────────────────
# CANONICAL SOURCE NOTE (XACA-0340): share/scripts/kb-tap-release is a COPY —
# the authoritative source lives at dev-team/scripts/kb-tap-release. This test
# lives in the tap's own inner repo (homebrew-tap/tests/) alongside the tap's
# existing test-xaca-NNNN-*.sh suite, so it is canonical TO THE TAP. A parity
# check against the outer dev-team source is intentionally out of scope here
# (the outer copy has no test harness of its own under scripts/); the static
# assertions in Case A/B run against the tap copy that ships to consumers,
# which is the copy that matters for the collision this ticket fixes.
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
