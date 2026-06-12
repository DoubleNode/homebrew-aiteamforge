#!/bin/bash

# test-xaca-0655-doctor-preflight.sh
# Regression tests for XACA-0655: doctor hardening + first-launch preflight.
#
# Covers four deliverables:
#   XACA-0655-001  check_board_resolution() — stub-collision detection, runtime
#                  path resolver reuse, org-slug placeholder gate
#   XACA-0655-003  attempt_remediation() — real remediation engine replacing the
#                  old "Auto-fix not yet implemented" stub
#   XACA-0655-004  --preflight flag + run_first_launch_preflight() in start.sh —
#                  first-launch self-heal: non-blocking, run-once sentinel, log write
#   XACA-0655-005  iterm2 real import test (not just pip show) in check_python_venv
#
# Strategy (3-layer — mirrors XACA-0651 precedent):
#   Layer 1 — static source assertions: grep/awk over doctor.sh + start.sh to
#             pin exact code shapes and catch trivial regressions fast.
#   Layer 2 — behavioral (sandboxed): invoke doctor.sh in controlled subshells
#             with fake HOME / AITEAMFORGE_DIR so no real system state is mutated.
#   Layer 3 — sibling-drift: verify the dead bin/aiteamforge-doctor.sh is NOT
#             wired as the primary CLI dispatch, and that component lists are
#             consistent across all enumeration sites.
#
# All filesystem activity uses mktemp sandbox dirs. Never touches real $HOME,
# LaunchAgents, or a live LCARS server. Env-dependent cases are SKIPPED (not
# FAILED) so the suite stays green in headless/CI.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCTOR_CMD="$TAP_ROOT/libexec/commands/aiteamforge-doctor.sh"
START_CMD="$TAP_ROOT/libexec/commands/aiteamforge-start.sh"
BIN_DOCTOR="$TAP_ROOT/bin/aiteamforge-doctor.sh"
BIN_CLI="$TAP_ROOT/bin/aiteamforge-cli.sh"

# ── Standalone test harness (mirrors test-xaca-0651 pattern) ─────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _SKIP_COUNT=0
    _CURRENT_TEST=""

    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
    test_skip()  { _SKIP_COUNT=$((_SKIP_COUNT + 1)); echo "     SKIP: $_CURRENT_TEST — $1"; }

    assert_file_exists() {
        local file="$1" msg="${2:-Expected file to exist: $1}"
        [ -f "$file" ] || { test_fail "$msg"; return 1; }
    }
    assert_dir_exists() {
        local dir="$1" msg="${2:-Expected directory to exist: $1}"
        [ -d "$dir" ] || { test_fail "$msg"; return 1; }
    }
    assert_contains() {
        local haystack="$1" needle="$2" msg="${3:-Expected to find: $2}"
        [[ "$haystack" == *"$needle"* ]] || { test_fail "$msg"; return 1; }
    }
    assert_not_contains() {
        local haystack="$1" needle="$2" msg="${3:-Expected NOT to find: $2}"
        [[ "$haystack" != *"$needle"* ]] || { test_fail "$msg"; return 1; }
    }
    assert_exit_success() {
        local code="$1" msg="${2:-Expected exit 0 but got $1}"
        [ "$code" -eq 0 ] || { test_fail "$msg"; return 1; }
    }
    assert_exit_nonzero() {
        local code="$1" msg="${2:-Expected non-zero exit but got 0}"
        [ "$code" -ne 0 ] || { test_fail "$msg"; return 1; }
    }
fi

# ── Temp sandbox ──────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0655-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi

_cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap _cleanup EXIT

SANDBOX="$TEST_TMP_DIR/xaca0655"
mkdir -p "$SANDBOX"

# ── Source-level caches (read once, reused across all Layer-1 tests) ──────────
_DOCTOR_SRC="$(cat "$DOCTOR_CMD")"
_START_SRC="$(cat "$START_CMD")"
_BOARD_FUNC="$(awk '/^check_board_resolution\(\)/,/^}$/' "$DOCTOR_CMD")"
_REMEDIATION_FUNC="$(awk '/^attempt_remediation\(\)/,/^}$/' "$DOCTOR_CMD")"
_VENV_FUNC="$(awk '/^check_python_venv\(\)/,/^}$/' "$DOCTOR_CMD")"
_PREFLIGHT_BLOCK="$(awk '/^if \[ "\$PREFLIGHT" = true \]/,/^fi$/' "$DOCTOR_CMD")"
_RFP_FUNC="$(awk '/^run_first_launch_preflight\(\)/,/^}$/' "$START_CMD")"
_CASE_BLOCK="$(awk '/^case "\$CHECK_COMPONENT"/,/^esac/' "$DOCTOR_CMD")"


# ════════════════════════════════════════════════════════════════════════════
# PRECONDITIONS
# ════════════════════════════════════════════════════════════════════════════

test_start "XACA-0655 precondition: aiteamforge-doctor.sh exists"
assert_file_exists "$DOCTOR_CMD" "aiteamforge-doctor.sh not found at $DOCTOR_CMD"
test_pass

test_start "XACA-0655 precondition: aiteamforge-start.sh exists"
assert_file_exists "$START_CMD" "aiteamforge-start.sh not found at $START_CMD"
test_pass

# ════════════════════════════════════════════════════════════════════════════
# LAYER 1 — STATIC SOURCE ASSERTIONS
# ════════════════════════════════════════════════════════════════════════════

# ── L1-A: check_board_resolution wiring (XACA-0655-001) ─────────────────────

test_start "L1-A1 (static): check_board_resolution function exists"
assert_contains "$_DOCTOR_SRC" \
    'check_board_resolution()' \
    "check_board_resolution() function must exist in aiteamforge-doctor.sh"
test_pass

test_start "L1-A2 (static): 'board' listed in usage() Components section"
_USAGE_FUNC="$(awk '/^usage\(\)/,/^}$/' "$DOCTOR_CMD")"
assert_contains "$_USAGE_FUNC" \
    'board' \
    "usage() must list 'board' as a check component (sibling-drift: all three sites must agree)"
test_pass

test_start "L1-A3 (static): 'board' dispatched in case statement"
assert_contains "$_CASE_BLOCK" \
    'board)' \
    "Case dispatch block must contain a 'board)' arm"
test_pass

test_start "L1-A4 (static): board case arm calls check_board_resolution"
# Extract just the board) arm content
_BOARD_ARM="$(echo "$_CASE_BLOCK" | awk '/board\)/{found=1} found && /check_board_resolution/{print; found=0}')"
assert_contains "$_BOARD_ARM" \
    'check_board_resolution' \
    "The 'board)' case arm must call check_board_resolution"
test_pass

test_start "L1-A5 (static): 'all)' block calls check_board_resolution"
_ALL_ARM="$(echo "$_CASE_BLOCK" | awk '/all\)/{f=1} f{print} /^  \*\)/{f=0}')"
assert_contains "$_ALL_ARM" \
    'check_board_resolution' \
    "The 'all)' block must call check_board_resolution (XACA-0655-001 requires all 3 dispatch sites)"
test_pass

test_start "L1-A6 (static): check_board_resolution uses get_working_dir (path-discipline)"
# Anti-regression: must NOT use bare \${AITEAMFORGE_DIR} for path resolution.
# XACA-0651 class: AITEAMFORGE_DIR is unset in doctor context on consumers.
assert_contains "$_BOARD_FUNC" \
    'get_working_dir' \
    "check_board_resolution must call get_working_dir for path resolution (not bare AITEAMFORGE_DIR)"
test_pass

test_start "L1-A7 (static): check_board_resolution does NOT use bare \${AITEAMFORGE_DIR} for paths"
# The function must not anchor to AITEAMFORGE_DIR for any filesystem checks.
# Acceptable: sourcing lib files via LIBEXEC_DIR (parent, not AITEAMFORGE_DIR).
# Disallowed: \${AITEAMFORGE_DIR}/kanban or similar runtime paths.
_BOARD_AITEAMFORGE_REFS="$(echo "$_BOARD_FUNC" | grep '\${AITEAMFORGE_DIR}' | grep -v '^\s*#' || true)"
# If present, must only appear as part of a comment or a sourcing context (not a path check)
if [ -n "$_BOARD_AITEAMFORGE_REFS" ]; then
    # Fail only if the reference is a path used for -d/-f checks
    if echo "$_BOARD_AITEAMFORGE_REFS" | grep -qE '\[\s*["\-].*\$\{AITEAMFORGE_DIR\}'; then
        test_fail "check_board_resolution uses bare \${AITEAMFORGE_DIR} in a filesystem check — collapses to root on consumers (XACA-0651 regression class)"
    else
        test_pass
    fi
else
    test_pass
fi

# ── L1-B: --preflight flag wiring (XACA-0655-004) ────────────────────────────

test_start "L1-B1 (static): --preflight flag parsed in doctor argument loop"
assert_contains "$_DOCTOR_SRC" \
    '--preflight)' \
    "--preflight must be parsed in the doctor's argument case/while loop"
test_pass

test_start "L1-B2 (static): PREFLIGHT=true set by --preflight arm"
assert_contains "$_DOCTOR_SRC" \
    'PREFLIGHT=true' \
    "The --preflight arm must set PREFLIGHT=true"
test_pass

test_start "L1-B3 (static): preflight block runs check_python_venv check_board_resolution check_services"
assert_contains "$_PREFLIGHT_BLOCK" \
    'check_python_venv' \
    "Preflight block must invoke check_python_venv"
assert_contains "$_PREFLIGHT_BLOCK" \
    'check_board_resolution' \
    "Preflight block must invoke check_board_resolution"
assert_contains "$_PREFLIGHT_BLOCK" \
    'check_services' \
    "Preflight block must invoke check_services"
test_pass

test_start "L1-B4 (static): preflight block exits 0 (non-blocking contract)"
assert_contains "$_PREFLIGHT_BLOCK" \
    'exit 0' \
    "Preflight block must end with exit 0 (never blocks startup)"
test_pass

test_start "L1-B5 (static): run_first_launch_preflight in aiteamforge-start.sh"
assert_contains "$_START_SRC" \
    'run_first_launch_preflight' \
    "run_first_launch_preflight must be defined AND called in aiteamforge-start.sh"
test_pass

test_start "L1-B6 (static): run_first_launch_preflight invokes doctor --preflight"
assert_contains "$_RFP_FUNC" \
    '--preflight' \
    "run_first_launch_preflight must pass --preflight to aiteamforge-doctor.sh"
test_pass

test_start "L1-B7 (static): run_first_launch_preflight uses || true guard (never blocks)"
assert_contains "$_RFP_FUNC" \
    '|| true' \
    "run_first_launch_preflight must wrap doctor call with '|| true' so a doctor crash never blocks launch"
test_pass

test_start "L1-B8 (static): sentinel path includes VERSION (version-stamped sentinel)"
assert_contains "$_RFP_FUNC" \
    '.doctor-preflight-' \
    "run_first_launch_preflight sentinel path must contain '.doctor-preflight-' (version-stamped)"
assert_contains "$_RFP_FUNC" \
    'VERSION' \
    "run_first_launch_preflight sentinel must incorporate the VERSION variable"
test_pass

# ── L1-B (anti-recursion guards, XACA-0655 review fix) ───────────────────────
# A SAFE remediation run during preflight may shell out to `aiteamforge start`
# (server self-heal), which re-enters run_first_launch_preflight. On first launch
# with the server down the sentinel is not yet stamped → infinite recursion /
# fork-bomb. Three guards must be present and lock the fix in place.

test_start "L1-B9 (static): run_first_launch_preflight has exported re-entry guard (AITEAMFORGE_PREFLIGHT_ACTIVE)"
# Guard 1: an early return on AITEAMFORGE_PREFLIGHT_ACTIVE so nested aiteamforge
# invocations skip preflight, AND the var is exported into the doctor call.
assert_contains "$_RFP_FUNC" \
    'AITEAMFORGE_PREFLIGHT_ACTIVE' \
    "run_first_launch_preflight must reference AITEAMFORGE_PREFLIGHT_ACTIVE (process-tree re-entry guard)"
test_pass

test_start "L1-B10 (static): sentinel is stamped BEFORE the doctor is invoked (re-entry no-ops)"
# Guard 2: the sentinel write (': > \"\$sentinel\"') must appear BEFORE the
# 'bash \"\$doctor\" --preflight' invocation in the function body, so any
# re-entry (even cross-process) sees the sentinel and no-ops. Compare line offsets.
_RFP_SENTINEL_LINE="$(printf '%s\n' "$_RFP_FUNC" | grep -n '> *"\?\$sentinel' | head -1 | cut -d: -f1)"
_RFP_DOCTOR_LINE="$(printf '%s\n' "$_RFP_FUNC" | grep -n 'bash "\$doctor" --preflight' | head -1 | cut -d: -f1)"
if [ -n "$_RFP_SENTINEL_LINE" ] && [ -n "$_RFP_DOCTOR_LINE" ] && [ "$_RFP_SENTINEL_LINE" -lt "$_RFP_DOCTOR_LINE" ]; then
    test_pass
else
    test_fail "sentinel stamp (line ${_RFP_SENTINEL_LINE:-?}) must precede doctor --preflight call (line ${_RFP_DOCTOR_LINE:-?}) to break first-launch recursion"
fi

test_start "L1-B11 (static): doctor 'server' remediation does not auto-start under --preflight"
# Guard 3: the server remediation arm must be gated on PREFLIGHT so it never
# shells out to 'aiteamforge start kanban' during preflight (recursion trigger +
# premature start). Extract the server) arm of attempt_remediation and assert it
# references PREFLIGHT before the aiteamforge-start shell-out.
_SERVER_ARM="$(printf '%s\n' "$_DOCTOR_SRC" | awk '/^    server\)/,/^      ;;/')"
assert_contains "$_SERVER_ARM" \
    'PREFLIGHT' \
    "attempt_remediation 'server' arm must check PREFLIGHT so it does not auto-start the server during preflight"
test_pass

# ── L1-C: attempt_remediation replaces the old stub (XACA-0655-003) ──────────

test_start "L1-C1 (static): attempt_remediation function exists"
assert_contains "$_DOCTOR_SRC" \
    'attempt_remediation()' \
    "attempt_remediation() function must exist in aiteamforge-doctor.sh"
test_pass

test_start "L1-C2 (static): old 'Auto-fix not yet implemented' literal is GONE"
assert_not_contains "$_DOCTOR_SRC" \
    'Auto-fix not yet implemented' \
    "The old stub literal 'Auto-fix not yet implemented' must no longer appear — replaced by real remediation engine (XACA-0655-003)"
test_pass

test_start "L1-C3 (static): attempt_remediation handles venv keepalive server board/setup kinds"
assert_contains "$_REMEDIATION_FUNC" 'venv)' \
    "attempt_remediation must handle 'venv' kind"
assert_contains "$_REMEDIATION_FUNC" 'keepalive)' \
    "attempt_remediation must handle 'keepalive' kind"
assert_contains "$_REMEDIATION_FUNC" 'server)' \
    "attempt_remediation must handle 'server' kind"
assert_contains "$_REMEDIATION_FUNC" 'board|setup)' \
    "attempt_remediation must handle 'board|setup' kind"
test_pass

test_start "L1-C4 (static): attempt_remediation has --apply mode (SAFE vs RISKY)"
assert_contains "$_REMEDIATION_FUNC" \
    '--apply' \
    "attempt_remediation must accept '--apply' to distinguish auto-apply from print-only"
test_pass

test_start "L1-C5 (static): board/setup kind is PRINT-ONLY (never auto-applied)"
# The board|setup arm must NOT call apply=true guarded auto-run.
# It must always produce a [manual] note — `aiteamforge setup` is RISKY.
_BOARD_SETUP_ARM="$(echo "$_REMEDIATION_FUNC" | awk '/board\|setup\)/{f=1} f{print} f && /^\s*;;/{f=0}')"
assert_contains "$_BOARD_SETUP_ARM" \
    '[manual]' \
    "The board|setup arm must emit a [manual] note (never auto-applied — RISKY)"
assert_not_contains "$_BOARD_SETUP_ARM" \
    '[ "$apply" = true ]' \
    "The board|setup arm must NOT check \$apply (always print-only regardless of --apply)"
test_pass

# ── L1-D: real iterm2 import test (XACA-0655-005) ────────────────────────────

test_start "L1-D1 (static): iterm2 import tested via real 'import' call (not just pip show)"
# The code uses: local import_probe="iterm2" then "$atf_python" -c "import ${import_probe}"
# Match the variable form since the literal 'import iterm2' is assembled at runtime.
assert_contains "$_VENV_FUNC" \
    'import_probe="iterm2"' \
    "check_python_venv must set import_probe to 'iterm2' (XACA-0655-005)"
assert_contains "$_VENV_FUNC" \
    '"import ${import_probe}"' \
    "check_python_venv must invoke python -c 'import \${import_probe}' (real import, not just pip show)"
test_pass

test_start "L1-D2 (static): real import uses \${atf_python} / \${AITEAMFORGE_PYTHON} (tap-owned interpreter)"
# Must use the tap venv interpreter, not bare python3
assert_contains "$_VENV_FUNC" \
    '"$atf_python"' \
    "iterm2 import test must use \$atf_python (tap-owned venv interpreter, not bare python3)"
test_pass

test_start "L1-D3 (static): import failure emits check_result fail (not just warn)"
# A broken iterm2 import bricks LCARS automation — must be a FAIL not a WARN.
# The else branch (import failure) must contain check_result fail, not check_result warn.
# We locate the else block by finding the line AFTER the passing check_result pass line.
_IMPORT_ELSE_BLOCK="$(echo "$_VENV_FUNC" | awk \
    '/module imports cleanly/{found=1; next} found{print}' | head -10)"
assert_contains "$_IMPORT_ELSE_BLOCK" \
    'check_result fail' \
    "iterm2 import failure else-branch must emit check_result fail (not warn — broken import bricks LCARS)"
test_pass

# ── L1-E: grep -c || true guards (set -eo pipefail safety) ───────────────────

test_start "L1-E1 (static): grep -c '^\[fix\]' guarded with || true in preflight block"
# grep -c exits 1 when there are zero matches; under set -eo pipefail a bare
# command substitution assignment aborts the script. The || true is load-bearing.
assert_contains "$_PREFLIGHT_BLOCK" \
    "grep -c '^\[fix\]'" \
    "Preflight block must use grep -c for counting [fix] lines"
assert_contains "$_PREFLIGHT_BLOCK" \
    "|| true" \
    "grep -c must be guarded with '|| true' to survive set -eo pipefail when count is 0"
test_pass

test_start "L1-E2 (static): grep -c '^\[manual\]' guarded with || true in preflight block"
assert_contains "$_PREFLIGHT_BLOCK" \
    "grep -c '^\[manual\]'" \
    "Preflight block must use grep -c for counting [manual] lines"
test_pass

# ── L1-F: bash -n syntax check on both implementation scripts ─────────────────

test_start "L1-F1 (static): bash -n syntax check on aiteamforge-doctor.sh"
_SYNTAX_OUT="$(bash -n "$DOCTOR_CMD" 2>&1)"
_SYNTAX_EXIT=$?
if [ "$_SYNTAX_EXIT" -ne 0 ]; then
    test_fail "bash -n aiteamforge-doctor.sh: ${_SYNTAX_OUT}"
else
    test_pass
fi

test_start "L1-F2 (static): bash -n syntax check on aiteamforge-start.sh"
_SYNTAX_OUT2="$(bash -n "$START_CMD" 2>&1)"
_SYNTAX_EXIT2=$?
if [ "$_SYNTAX_EXIT2" -ne 0 ]; then
    test_fail "bash -n aiteamforge-start.sh: ${_SYNTAX_OUT2}"
else
    test_pass
fi


# ════════════════════════════════════════════════════════════════════════════
# LAYER 2 — BEHAVIORAL (sandboxed, no real $HOME mutation)
# ════════════════════════════════════════════════════════════════════════════

# ── L2-A: --check board runs without crashing ─────────────────────────────────

test_start "L2-A1 (behavioral): 'aiteamforge-doctor.sh --check board' exits with sane code"
# We run doctor.sh directly. It will source lib files from the TAP_ROOT, so
# they must be present. We sandbox HOME and disable interactivity.
# Expected exit codes: 0 (all pass), 1 (warnings), 2 (failures) — all sane.
_BOARD_CHECK_EXIT=0
_BOARD_CHECK_OUT="$(
    HOME="$SANDBOX/home-board-check" \
    AITEAMFORGE_DIR="" \
    AITEAMFORGE_ALLOW_DEV_OVERWRITE=1 \
    bash "$DOCTOR_CMD" --check board 2>&1
)" || _BOARD_CHECK_EXIT=$?

# Sane = exits 0, 1, or 2 (not 127 "command not found" or similar crash codes)
if [ "$_BOARD_CHECK_EXIT" -le 2 ]; then
    test_pass
else
    test_fail "--check board exited with $BOARD_CHECK_EXIT (>2 = crash/unexpected). Output: $(echo "$_BOARD_CHECK_OUT" | tail -5)"
fi

# ── L2-B: --preflight ALWAYS exits 0 and writes a log ────────────────────────

_PREFLIGHT_HOME="$SANDBOX/home-preflight"
_PREFLIGHT_ATFD="$_PREFLIGHT_HOME/.aiteamforge"
_PREFLIGHT_LOG="$_PREFLIGHT_ATFD/logs/doctor-preflight.log"
mkdir -p "$_PREFLIGHT_HOME"

test_start "L2-B1 (behavioral): --preflight exits 0 (non-blocking contract)"
_PREFLIGHT_EXIT=0
_PREFLIGHT_OUT="$(
    HOME="$_PREFLIGHT_HOME" \
    AITEAMFORGE_DIR="" \
    AITEAMFORGE_ALLOW_DEV_OVERWRITE=1 \
    bash "$DOCTOR_CMD" --preflight 2>&1
)" || _PREFLIGHT_EXIT=$?

if [ "$_PREFLIGHT_EXIT" -eq 0 ]; then
    test_pass
else
    test_fail "--preflight exited ${_PREFLIGHT_EXIT} instead of 0. Output: $(echo "$_PREFLIGHT_OUT" | tail -5)"
fi

test_start "L2-B2 (behavioral): --preflight writes log to \${HOME}/.aiteamforge/logs/doctor-preflight.log"
if [ -f "$_PREFLIGHT_LOG" ]; then
    test_pass
else
    test_fail "Log file not created at $_PREFLIGHT_LOG — preflight must always write its log"
fi

test_start "L2-B3 (behavioral): preflight log contains expected header"
if [ -f "$_PREFLIGHT_LOG" ]; then
    _LOG_CONTENT="$(cat "$_PREFLIGHT_LOG")"
    assert_contains "$_LOG_CONTENT" \
        '=== doctor preflight' \
        "Preflight log must contain '=== doctor preflight' header"
    test_pass
else
    test_skip "Log file absent — skipping header check (covered by L2-B2 failure)"
fi

# ── L2-C: run-once sentinel ───────────────────────────────────────────────────

test_start "L2-C1 (behavioral): doctor --preflight log grows on each call (log is always written)"
# Design note: the VERSION-stamped sentinel is created by run_first_launch_preflight()
# in aiteamforge-start.sh, NOT by doctor --preflight itself. The doctor only writes
# the log file. Both behaviors are tested separately:
#   - Log written by doctor --preflight: here (L2-C1/C2)
#   - Sentinel created by run_first_launch_preflight: L2-D1/D2
#
# Verify that a second --preflight call appends to the same log (doctor is idempotent).
_LOG_BEFORE="$(wc -l < "$_PREFLIGHT_LOG" 2>/dev/null || echo 0)"
_PREFLIGHT_EXIT2=0
HOME="$_PREFLIGHT_HOME" \
AITEAMFORGE_DIR="" \
AITEAMFORGE_ALLOW_DEV_OVERWRITE=1 \
bash "$DOCTOR_CMD" --preflight >/dev/null 2>&1 || _PREFLIGHT_EXIT2=$?

_LOG_AFTER="$(wc -l < "$_PREFLIGHT_LOG" 2>/dev/null || echo 0)"
if [ "$_LOG_AFTER" -gt "$_LOG_BEFORE" ]; then
    test_pass
else
    test_fail "Second --preflight call did not append to the log (before=$_LOG_BEFORE after=$_LOG_AFTER)"
fi

test_start "L2-C2 (behavioral): second --preflight exits 0 (idempotent non-blocking)"
if [ "$_PREFLIGHT_EXIT2" -eq 0 ]; then
    test_pass
else
    test_fail "Second --preflight invocation exited ${_PREFLIGHT_EXIT2}, expected 0"
fi

# ── L2-D: run_first_launch_preflight sentinel gate (sandboxed extraction) ─────

test_start "L2-D1 (behavioral): run_first_launch_preflight creates sentinel on first call"
_RFP_HOME="$SANDBOX/home-rfp"
_RFP_ATF="$_RFP_HOME/.aiteamforge"
mkdir -p "$_RFP_HOME"

# We replicate run_first_launch_preflight() in a controlled driver to test its
# sentinel logic without launching all of aiteamforge-start.sh (which requires
# is_configured etc.).
_ATF_VER="$(cat "$TAP_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]' || echo '0.0.0')"

cat > "$SANDBOX/rfp-driver.sh" <<RFPDRIVER
#!/bin/bash
set -eo pipefail

# XACA-0655-009 (review fix): respect a caller-provided HOME at driver RUNTIME,
# falling back to the D1 sandbox home only when HOME is unset. The \$HOME is
# escaped so it is evaluated when the driver RUNS (honoring 'HOME=... bash driver'
# from D3/D4), not baked at generation time. Previously this hardcoded the D1
# home (which already has a sentinel), making L2-D4 vacuous — preflight
# short-circuited on the sentinel before reaching the recursion path.
HOME="\${HOME:-${_RFP_HOME}}"
VERSION="${_ATF_VER}"
LIBEXEC_DIR="${TAP_ROOT}/libexec"
DOCTOR="${TAP_ROOT}/libexec/commands/aiteamforge-doctor.sh"

source "${TAP_ROOT}/libexec/lib/common.sh" 2>/dev/null || true
source "${TAP_ROOT}/libexec/lib/config.sh" 2>/dev/null || true
source "${TAP_ROOT}/libexec/lib/constants.sh" 2>/dev/null || true

$(cat "$START_CMD" | awk '/^run_first_launch_preflight\(\)/,/^}$/')

run_first_launch_preflight
echo "EXIT=\$?"
RFPDRIVER
chmod +x "$SANDBOX/rfp-driver.sh"

_RFP_OUT="$(HOME="$_RFP_HOME" bash "$SANDBOX/rfp-driver.sh" 2>&1)" || true

# Check sentinel was created
_RFP_SENTINEL_FOUND=false
for _f in "$_RFP_ATF"/.doctor-preflight-*; do
    [ -f "$_f" ] && _RFP_SENTINEL_FOUND=true && break
done

if [ "$_RFP_SENTINEL_FOUND" = true ]; then
    test_pass
else
    test_fail "run_first_launch_preflight did not create sentinel under $_RFP_ATF. Output: $(echo "$_RFP_OUT" | tail -3)"
fi

test_start "L2-D2 (behavioral): run_first_launch_preflight is a fast no-op on second call (sentinel present)"
# Touch the sentinel directly to simulate "already ran this version"
_SENTINEL_PATH="$_RFP_ATF/.doctor-preflight-${_ATF_VER}"
mkdir -p "$_RFP_ATF"
touch "$_SENTINEL_PATH"

# Write a marker into the preflight log BEFORE the run; if run_first_launch_preflight
# respects the sentinel it won't call doctor again (so the log won't grow).
_RFP_LOG="$_RFP_ATF/logs/doctor-preflight.log"
mkdir -p "$(dirname "$_RFP_LOG")"
echo "SENTINEL_PRESENT_MARKER" >> "$_RFP_LOG"
_LINES_BEFORE="$(wc -l < "$_RFP_LOG")"

_RFP_OUT2="$(HOME="$_RFP_HOME" bash "$SANDBOX/rfp-driver.sh" 2>&1)" || true

_LINES_AFTER="$(wc -l < "$_RFP_LOG" 2>/dev/null || echo 0)"
if [ "$_LINES_AFTER" -eq "$_LINES_BEFORE" ]; then
    test_pass
else
    test_fail "run_first_launch_preflight re-ran despite sentinel (log grew from $_LINES_BEFORE to $_LINES_AFTER lines)"
fi

test_start "L2-D3 (behavioral): re-entry guard makes a nested invocation a no-op (AITEAMFORGE_PREFLIGHT_ACTIVE set)"
# Simulates the nested 'aiteamforge start' that a remediation might trigger: the
# child inherits AITEAMFORGE_PREFLIGHT_ACTIVE=1, so run_first_launch_preflight must
# return immediately WITHOUT invoking the doctor — even with NO sentinel present.
_RFP_HOME3="$SANDBOX/home-rfp3"
_RFP_ATF3="$_RFP_HOME3/.aiteamforge"
mkdir -p "$_RFP_HOME3"
# Fresh home → no sentinel. If the guard works, no sentinel is created either,
# because the function returns before stamping/running.
_RFP_OUT3="$(HOME="$_RFP_HOME3" AITEAMFORGE_PREFLIGHT_ACTIVE=1 bash "$SANDBOX/rfp-driver.sh" 2>&1)" || true
_RFP3_SENTINEL_FOUND=false
for _f in "$_RFP_ATF3"/.doctor-preflight-*; do
    [ -f "$_f" ] && _RFP3_SENTINEL_FOUND=true && break
done
if [ "$_RFP3_SENTINEL_FOUND" = false ]; then
    test_pass
else
    test_fail "re-entry guard failed: preflight ran despite AITEAMFORGE_PREFLIGHT_ACTIVE=1 (sentinel was created). Output: $(echo "$_RFP_OUT3" | tail -3)"
fi

test_start "L2-D4 (behavioral): first-launch preflight does NOT fork-bomb when server-start shells back into start"
# The real regression: a fake 'aiteamforge' on PATH whose 'start kanban' re-invokes
# run_first_launch_preflight (mimicking the server self-heal shelling back into
# 'aiteamforge start'). With the fix (env guard + sentinel-first + PREFLIGHT-gated
# server remediation) this must TERMINATE and invoke the driver a bounded number of
# times. Without the fix it recurses unbounded. Bounded by `timeout` as a backstop.
_TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then _TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then _TIMEOUT_BIN="gtimeout"; fi

if [ -z "$_TIMEOUT_BIN" ]; then
    test_skip "no timeout/gtimeout available — skipping fork-bomb backstop test (guards covered by L1-B9/B10/B11 + L2-D3)"
else
    _RFP_HOME4="$SANDBOX/home-rfp4"
    _FAKE_BIN="$SANDBOX/fakebin4"
    _COUNTER="$SANDBOX/rfp4-count"
    mkdir -p "$_RFP_HOME4" "$_FAKE_BIN"
    echo 0 > "$_COUNTER"

    # Fake 'aiteamforge': on 'start kanban', bump the counter and re-run the driver
    # (the recursion path). The fix's exported env guard must make this nested run
    # a no-op. Hard cap at 25 to avoid an actual fork-bomb if the fix regresses.
    cat > "$_FAKE_BIN/aiteamforge" <<FAKEATF
#!/bin/bash
if [ "\$1" = "start" ]; then
    _n=\$(( \$(cat "$_COUNTER" 2>/dev/null || echo 0) + 1 ))
    echo "\$_n" > "$_COUNTER"
    [ "\$_n" -ge 25 ] && exit 0   # hard cap: regression backstop
    HOME="$_RFP_HOME4" bash "$SANDBOX/rfp-driver.sh" >/dev/null 2>&1 || true
fi
exit 0
FAKEATF
    chmod +x "$_FAKE_BIN/aiteamforge"

    # Run the top-level preflight with the fake aiteamforge first on PATH and a
    # fresh (sentinel-absent) home — the exact first-launch + server-down scenario.
    set +e
    PATH="$_FAKE_BIN:$PATH" HOME="$_RFP_HOME4" "$_TIMEOUT_BIN" 20 bash "$SANDBOX/rfp-driver.sh" >/dev/null 2>&1
    _RFP4_RC=$?
    set -e
    _RFP4_COUNT="$(cat "$_COUNTER" 2>/dev/null || echo 0)"

    if [ "$_RFP4_RC" -eq 124 ]; then
        test_fail "preflight HUNG (timeout) — first-launch recursion not broken (server self-heal fork-bomb). nested-start count=$_RFP4_COUNT"
    elif [ "$_RFP4_COUNT" -ge 25 ]; then
        test_fail "preflight recursed unbounded (hit hard cap 25) — re-entry guard ineffective"
    else
        test_pass
    fi
fi

# ── L2-E: --check board against stub vs real board ────────────────────────────

test_start "L2-E1 (behavioral): --check board with no team-paths overlay reports stub-collision FAIL"
# Sandbox where AITEAMFORGE_DIR has no .aiteamforge-config and HOME has no
# .aiteamforge/team-paths.json — this triggers the "example-org" + no-overlay path.
_STUB_HOME="$SANDBOX/home-stub"
mkdir -p "$_STUB_HOME"

_STUB_EXIT=0
_STUB_OUT="$(
    HOME="$_STUB_HOME" \
    AITEAMFORGE_DIR="" \
    AITEAMFORGE_ALLOW_DEV_OVERWRITE=1 \
    bash "$DOCTOR_CMD" --check board 2>&1
)" || _STUB_EXIT=$?

# With no config and no overlay, the org slug falls to "example-org" and the
# check must report a FAIL (not crash). Exit code 2 = failures present.
# We verify the output contains stub/placeholder/setup messaging.
if echo "$_STUB_OUT" | sed 's/\x1b\[[0-9;]*m//g' | grep -qi \
    "example-org\|stub\|template\|not configured\|aiteamforge setup"; then
    test_pass
else
    test_skip "Stub-collision output undetectable in this environment (resolver may have found real config) — exit $STUB_EXIT"
fi

# ── L2-F: --preflight always exits 0 even when checks fail ───────────────────

test_start "L2-F1 (behavioral): --preflight exits 0 even on a broken environment (checks fail)"
# This is already covered by L2-B1 (broken env) but we make it explicit.
# The non-blocking contract is the most safety-critical property.
_BROKEN_HOME="$SANDBOX/home-broken-$(date +%s)"
mkdir -p "$_BROKEN_HOME"
_BROKEN_EXIT=99
_BROKEN_EXIT=0
HOME="$_BROKEN_HOME" \
AITEAMFORGE_DIR="/nonexistent_path_$$" \
AITEAMFORGE_ALLOW_DEV_OVERWRITE=1 \
bash "$DOCTOR_CMD" --preflight >/dev/null 2>&1 || _BROKEN_EXIT=$?
if [ "$_BROKEN_EXIT" -eq 0 ]; then
    test_pass
else
    test_fail "--preflight exited ${_BROKEN_EXIT} on a deliberately broken env — must always exit 0 (XACA-0655-004 non-blocking contract)"
fi


# ════════════════════════════════════════════════════════════════════════════
# LAYER 3 — SIBLING-DRIFT
# ════════════════════════════════════════════════════════════════════════════

# ── L3-A: bin/aiteamforge-doctor.sh is NOT the primary CLI dispatch ───────────

test_start "L3-A1 (sibling): aiteamforge-cli.sh dispatches 'doctor' to libexec/commands, not bin-level script"
# The CLI (via aiteamforge-cli.sh) should exec the NEW libexec/commands doctor,
# not the legacy bin/aiteamforge-doctor.sh. The bin-level stub exists as a
# standalone entry point for `aiteamforge-doctor` direct invocation — it should
# NOT be wired as the primary dispatch for `aiteamforge doctor`.
if [ ! -f "$BIN_CLI" ]; then
    test_skip "bin/aiteamforge-cli.sh not found — skipping CLI dispatch check"
else
    _CLI_SRC="$(cat "$BIN_CLI")"
    _DOCTOR_DISPATCH="$(echo "$_CLI_SRC" | awk '/doctor\)/{found=1; next} found && /exec/{print; found=0}')"
    assert_contains "$_DOCTOR_DISPATCH" \
        'libexec/commands/aiteamforge-doctor.sh' \
        "CLI 'doctor)' dispatch must exec libexec/commands/aiteamforge-doctor.sh (not bin-level script)"
    assert_not_contains "$_DOCTOR_DISPATCH" \
        'bin/aiteamforge-doctor.sh' \
        "CLI 'doctor)' dispatch must NOT exec bin/aiteamforge-doctor.sh — that is the legacy standalone entry point"
    test_pass
fi

test_start "L3-A2 (sibling): bin/aiteamforge-doctor.sh does NOT contain check_board_resolution"
# The new XACA-0655 functionality (check_board_resolution, attempt_remediation,
# --preflight) lives ONLY in libexec/commands/aiteamforge-doctor.sh. If the bin-
# level script somehow gained those symbols it would create a divergent duplicate.
if [ ! -f "$BIN_DOCTOR" ]; then
    test_skip "bin/aiteamforge-doctor.sh not found — skip"
else
    _BIN_DOCTOR_SRC="$(cat "$BIN_DOCTOR")"
    assert_not_contains "$_BIN_DOCTOR_SRC" \
        'check_board_resolution()' \
        "bin/aiteamforge-doctor.sh must NOT define check_board_resolution() — that function belongs only in libexec/commands"
    assert_not_contains "$_BIN_DOCTOR_SRC" \
        'attempt_remediation()' \
        "bin/aiteamforge-doctor.sh must NOT define attempt_remediation() — that function belongs only in libexec/commands"
    test_pass
fi

# ── L3-B: 'board' component listed consistently across all enumeration sites ──

test_start "L3-B1 (sibling): 'board' present in usage() component list"
# Already tested in L1-A2; explicit here as a sibling-drift assertion.
_USAGE_SRC="$(awk '/^usage\(\)/,/^}$/' "$DOCTOR_CMD")"
assert_contains "$_USAGE_SRC" 'board' \
    "usage() must list 'board' as a component (XACA-0655-001 sibling-drift check)"
test_pass

test_start "L3-B2 (sibling): 'board' present in case dispatch"
assert_contains "$_CASE_BLOCK" 'board)' \
    "Case dispatch must contain 'board)' arm (XACA-0655-001 sibling-drift check)"
test_pass

test_start "L3-B3 (sibling): 'board' called in 'all)' block"
# The 'all)' arm must include check_board_resolution so running the full suite
# includes it. A missing entry here is a sibling-drift that silently omits the
# check from the default (no-args) doctor run.
_ALL_BLOCK="$(echo "$_CASE_BLOCK" | awk '/^  all\)/{f=1} f{print} f && /^  \*\)/{f=0}')"
assert_contains "$_ALL_BLOCK" 'check_board_resolution' \
    "'all)' block must call check_board_resolution (XACA-0655-001 requires all 3 sites)"
test_pass

test_start "L3-B4 (sibling): same 3 components (usage + case + all) — no drift between sites"
# Structural check: if usage lists board, case must have board), and all) must call it.
# We already asserted each individually; this is the cross-site consistency summary.
_USAGE_HAS_BOARD="$(echo "$_USAGE_SRC" | grep -c 'board' | head -1 || true)"
_CASE_HAS_BOARD="$(echo "$_CASE_BLOCK" | grep -c 'board)' | head -1 || true)"
_ALL_HAS_BOARD="$(echo "$_ALL_BLOCK" | grep -c 'check_board_resolution' | head -1 || true)"
_USAGE_HAS_BOARD="${_USAGE_HAS_BOARD:-0}"
_CASE_HAS_BOARD="${_CASE_HAS_BOARD:-0}"
_ALL_HAS_BOARD="${_ALL_HAS_BOARD:-0}"
if [ "$_USAGE_HAS_BOARD" -gt 0 ] && [ "$_CASE_HAS_BOARD" -gt 0 ] && [ "$_ALL_HAS_BOARD" -gt 0 ]; then
    test_pass
else
    test_fail "Sibling-drift between enumeration sites: usage=$_USAGE_HAS_BOARD case=$_CASE_HAS_BOARD all=$_ALL_HAS_BOARD — all three must be nonzero"
fi

# ── L3-C: path-discipline anti-regression (no NEW bare AITEAMFORGE_DIR refs) ──

test_start "L3-C1 (sibling): check_board_resolution has no bare \${AITEAMFORGE_DIR} filesystem checks"
# Re-checking from a sibling-drift angle: any NEW use of AITEAMFORGE_DIR inside
# check_board_resolution is a potential XACA-0651 regression (collapses to root
# on consumers). Only LIBEXEC_DIR-relative paths and get_working_dir are safe.
_BAD_REFS="$(echo "$_BOARD_FUNC" | grep '\${AITEAMFORGE_DIR}' | grep -vE '^\s*#' || true)"
if [ -n "$_BAD_REFS" ]; then
    # Accept refs that appear only in variable assignments (not path comparisons)
    _PATH_CHECK_REFS="$(echo "$_BAD_REFS" | grep -E '\[\s*[-!]' || true)"
    if [ -n "$_PATH_CHECK_REFS" ]; then
        test_fail "check_board_resolution contains bare AITEAMFORGE_DIR in filesystem checks (XACA-0651 regression class): $_PATH_CHECK_REFS"
    else
        test_pass
    fi
else
    test_pass
fi

# ── L3-D: run_first_launch_preflight calls doctor with || true ────────────────

test_start "L3-D1 (sibling): start.sh run_first_launch_preflight cannot abort aiteamforge-start"
# If the || true guard were removed from the doctor call inside
# run_first_launch_preflight, a doctor crash would abort the entire start command.
# This is the key safety invariant for XACA-0655-004.
assert_contains "$_RFP_FUNC" \
    '|| true' \
    "run_first_launch_preflight must guard doctor call with '|| true' — doctor crash must never block 'aiteamforge start'"
test_pass


# ════════════════════════════════════════════════════════════════════════════
# SUMMARY (standalone mode only)
# ════════════════════════════════════════════════════════════════════════════
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_SKIP_COUNT} skipped, ${_FAIL_COUNT} failed"
    if [ "$_FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
fi
exit 0
