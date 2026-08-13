#!/bin/bash
# test-xaca-0611-imgcat-provision.sh — XACA-0611 Testing & Debugging (subitem 004)
#
# Exercises ensure_imgcat helper and install/upgrade wiring.
# ALL tests use HOME=$(mktemp -d) sandboxing — never touches real ~/.iterm2.
#
# Designed to be run standalone OR discovered by test-runner.sh.
#
# Usage:
#   bash homebrew-tap/tests/test-xaca-0611-imgcat-provision.sh
#   bash homebrew-tap/tests/test-xaca-0611-imgcat-provision.sh --verbose
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKTREE_ROOT="$(cd "$TAP_ROOT/.." && pwd)"

# Cases 7/8 below assert against files that live in the OUTER dev-team
# monorepo (sync-tap.sh, scripts/vendor/iterm2/imgcat,
# scripts/tests/test-agent-panel-display.sh) — none of which are part of the
# homebrew-tap repo itself. On a developer's machine WORKTREE_ROOT is the
# dev-team checkout that has homebrew-tap nested inside it, so these exist.
# In tap-only CI (this repo checked out standalone — no outer dev-team repo
# present at all), WORKTREE_ROOT just resolves to the Actions workspace root
# and none of these paths exist; PRE-EXISTING, not caused by any tap commit —
# the gap is structural (repo layout), not code. Detect via two sentinels
# (sync-tap.sh + kanban-helpers.sh, mirroring the canonical-source pairing
# CONTRIBUTING.md documents) and SKIP with a visible reason rather than
# failing, matching the established idiom already used for the sibling-drift
# guard in test-xaca-0632-kb-variance.sh Case 7.
_IN_DEV_MONOREPO=false
if [[ -f "$WORKTREE_ROOT/sync-tap.sh" && -f "$WORKTREE_ROOT/kanban-helpers.sh" ]]; then
    _IN_DEV_MONOREPO=true
fi

VERBOSE=false
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=true

# ─── Lightweight test framework (matches test-runner.sh API) ─────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
CURRENT_TEST_NAME=""

# Master sandbox — cleaned at exit
MASTER_TMP=$(mktemp -d -t xaca0611-test.XXXXXX)
trap 'rm -rf "$MASTER_TMP"' EXIT INT TERM

test_start() {
    CURRENT_TEST_NAME="$1"
    TOTAL_TESTS=$(( TOTAL_TESTS + 1 ))
    $VERBOSE && echo -e "${BLUE}  running${NC} $1"
}

test_pass() {
    PASSED_TESTS=$(( PASSED_TESTS + 1 ))
    if $VERBOSE; then
        echo -e "${GREEN}  PASS${NC} $CURRENT_TEST_NAME"
    else
        printf "."
    fi
}

test_fail() {
    local msg="${1:-}"
    FAILED_TESTS=$(( FAILED_TESTS + 1 ))
    if $VERBOSE; then
        echo -e "${RED}  FAIL${NC} $CURRENT_TEST_NAME${msg:+: $msg}"
    else
        printf "F"
        echo ""
        echo -e "  ${RED}FAILED${NC}: $CURRENT_TEST_NAME${msg:+: $msg}"
    fi
}

assert_equal() {
    local expected="$1" actual="$2" msg="${3:-}"
    [[ "$expected" == "$actual" ]] && return 0
    test_fail "${msg:-Expected '$expected' but got '$actual'}"
    return 1
}

assert_file_exists()   { [[ -f "$1" ]] && return 0; test_fail "${2:-File missing: $1}"; return 1; }
assert_file_missing()  { [[ ! -f "$1" ]] && return 0; test_fail "${2:-File unexpectedly present: $1}"; return 1; }
assert_file_exec()     { [[ -x "$1" ]] && return 0; test_fail "${2:-File not executable: $1}"; return 1; }
assert_file_nonempty() { [[ -s "$1" ]] && return 0; test_fail "${2:-File is empty: $1}"; return 1; }
assert_exit_success()  { [[ "$1" -eq 0 ]] && return 0; test_fail "${2:-Expected exit 0, got $1}"; return 1; }
assert_exit_failure()  { [[ "$1" -ne 0 ]] && return 0; test_fail "${2:-Expected non-zero exit, got $1}"; return 1; }
assert_contains()      { [[ "$1" == *"$2"* ]] && return 0; test_fail "${3:-Expected '$2' in output}"; return 1; }
assert_not_contains()  { [[ "$1" != *"$2"* ]] && return 0; test_fail "${3:-Did NOT expect '$2' in output}"; return 1; }
assert_not_empty()     { [[ -n "$1" ]] && return 0; test_fail "${2:-Expected non-empty value}"; return 1; }

# ─── Helper: fresh sandbox HOME for each test ─────────────────────────────────
# Usage: SANDBOX=$(make_sandbox); HOME="$SANDBOX"
make_sandbox() {
    local d
    d=$(mktemp -d -t xaca0611-sandbox.XXXXXX)
    echo "$d"
}

# ─── Helper: load imgcat-provision.sh into current shell context ──────────────
# Provides stub info/warning/error/success that are required by the helper.
load_imgcat_provision() {
    # Stub common.sh output functions (imgcat-provision.sh requires them)
    info()    { :; }
    success() { :; }
    warning() { local msg="$*"; _LAST_WARNING="$msg"; }
    error()   { local msg="$*"; _LAST_ERROR="$msg"; }

    # Unset the guard so we can source fresh each time
    unset _IMGCAT_PROVISION_SH_LOADED
    source "$TAP_ROOT/libexec/lib/imgcat-provision.sh"
}

# ─── Paths ────────────────────────────────────────────────────────────────────
BUNDLED_SHARE="$TAP_ROOT/share"          # real tap share — has iterm2/imgcat
INSTALL_SHELL="$TAP_ROOT/libexec/installers/install-shell.sh"
UPGRADE_SCRIPT="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  XACA-0611 imgcat-provision Tests"
echo "================================================================"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
echo "--- Case 1: Happy path — bundled asset provisions correctly ---"
# ─────────────────────────────────────────────────────────────────────────────

SANDBOX=$(make_sandbox)

test_start "Happy path: ensure_imgcat returns 0"
(
    HOME="$SANDBOX"
    load_imgcat_provision
    ensure_imgcat "$BUNDLED_SHARE"
    rc=$?
    exit $rc
)
rc=$?
assert_exit_success "$rc" "ensure_imgcat should return 0 with bundled asset"
test_pass

test_start "Happy path: imgcat file is created"
assert_file_exists "$SANDBOX/.iterm2/imgcat" "~/.iterm2/imgcat must exist after provisioning"
test_pass

test_start "Happy path: imgcat file is executable"
assert_file_exec "$SANDBOX/.iterm2/imgcat" "~/.iterm2/imgcat must be executable"
test_pass

test_start "Happy path: imgcat file is non-empty (8560 bytes)"
SIZE=$(wc -c < "$SANDBOX/.iterm2/imgcat" | tr -d ' ')
assert_equal "8560" "$SIZE" "Bundled imgcat should be exactly 8560 bytes, got $SIZE"
test_pass

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Case 2: Idempotent — second call is a no-op ---"
# ─────────────────────────────────────────────────────────────────────────────

# Reuse SANDBOX from case 1 — imgcat already present
MTIME1=$(stat -f "%m" "$SANDBOX/.iterm2/imgcat" 2>/dev/null || stat -c "%Y" "$SANDBOX/.iterm2/imgcat")

test_start "Idempotent: second call returns 0"
(
    HOME="$SANDBOX"
    load_imgcat_provision
    ensure_imgcat "$BUNDLED_SHARE"
    rc=$?
    exit $rc
)
rc=$?
assert_exit_success "$rc" "Second call should return 0"
test_pass

test_start "Idempotent: file mtime unchanged (no unnecessary copy)"
MTIME2=$(stat -f "%m" "$SANDBOX/.iterm2/imgcat" 2>/dev/null || stat -c "%Y" "$SANDBOX/.iterm2/imgcat")
assert_equal "$MTIME1" "$MTIME2" "File should not be re-copied when already valid"
test_pass

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Case 3: Bundled missing + fallback unavailable ---"
# ─────────────────────────────────────────────────────────────────────────────

SANDBOX3=$(make_sandbox)
# Empty share dir — no bundled imgcat
EMPTY_SHARE="$MASTER_TMP/empty-share"
mkdir -p "$EMPTY_SHARE/iterm2"
# Do NOT place imgcat there

test_start "Missing bundled + failed curl: ensure_imgcat returns 1"
(
    HOME="$SANDBOX3"
    # Stub curl to fail
    curl() { return 1; }
    load_imgcat_provision
    ensure_imgcat "$EMPTY_SHARE" 2>/dev/null
    rc=$?
    exit $rc
)
rc=$?
assert_exit_failure "$rc" "Should return 1 when both bundled and curl fail"
test_pass

test_start "Missing bundled + failed curl: no bogus empty file left behind"
# If curl fails after writing a partial file, the helper must not leave a
# zero-byte file that would fool a subsequent idempotency check.
# Check: if file exists, it must be non-empty AND executable.
if [[ -f "$SANDBOX3/.iterm2/imgcat" ]]; then
    SIZE3=$(wc -c < "$SANDBOX3/.iterm2/imgcat" | tr -d ' ')
    IS_EXEC=0
    [[ -x "$SANDBOX3/.iterm2/imgcat" ]] && IS_EXEC=1
    if [[ "$SIZE3" -eq 0 || "$IS_EXEC" -eq 0 ]]; then
        test_fail "BUG: left a zero-byte or non-executable imgcat after failure (size=$SIZE3 exec=$IS_EXEC)"
    else
        # File exists and is non-empty+executable — the curl stub must have
        # somehow succeeded, which is unexpected but not a bug in the helper.
        test_pass
    fi
else
    # No file — correct: nothing to fool a later idempotency check
    test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Case 4: Pre-seeded bad artifact is repaired ---"
# ─────────────────────────────────────────────────────────────────────────────

# Case 4a: empty file pre-seeded
SANDBOX4A=$(make_sandbox)
mkdir -p "$SANDBOX4A/.iterm2"
touch "$SANDBOX4A/.iterm2/imgcat"          # zero-byte
chmod +x "$SANDBOX4A/.iterm2/imgcat"

test_start "Pre-seeded empty file: ensure_imgcat repairs it (returns 0)"
(
    HOME="$SANDBOX4A"
    load_imgcat_provision
    ensure_imgcat "$BUNDLED_SHARE"
    rc=$?
    exit $rc
)
rc=$?
assert_exit_success "$rc" "Should repair empty pre-existing file"
test_pass

test_start "Pre-seeded empty file: repaired file is non-empty"
assert_file_nonempty "$SANDBOX4A/.iterm2/imgcat" "File should be non-empty after repair"
test_pass

test_start "Pre-seeded empty file: repaired file is executable"
assert_file_exec "$SANDBOX4A/.iterm2/imgcat" "File should be executable after repair"
test_pass

# Case 4b: non-executable file pre-seeded
SANDBOX4B=$(make_sandbox)
mkdir -p "$SANDBOX4B/.iterm2"
cp "$BUNDLED_SHARE/iterm2/imgcat" "$SANDBOX4B/.iterm2/imgcat"
chmod -x "$SANDBOX4B/.iterm2/imgcat"       # strip exec bit

test_start "Pre-seeded non-executable file: ensure_imgcat repairs it (returns 0)"
(
    HOME="$SANDBOX4B"
    load_imgcat_provision
    ensure_imgcat "$BUNDLED_SHARE"
    rc=$?
    exit $rc
)
rc=$?
assert_exit_success "$rc" "Should repair non-executable pre-existing file"
test_pass

test_start "Pre-seeded non-executable file: repaired file is executable"
assert_file_exec "$SANDBOX4B/.iterm2/imgcat" "File should be executable after repair"
test_pass

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Case 5: M1Pro regression — integration.zsh pre-exists, imgcat still runs ---"
# ─────────────────────────────────────────────────────────────────────────────

# Structural check: ensure_imgcat call is OUTSIDE the shell-integration if-block
test_start "Structural: ensure_imgcat is at same indent level as shell-integration block (not nested inside it)"
# Strategy: get the line numbers of the if-block close (fi) for iterm2_shell_integration.zsh
# and the ensure_imgcat call. The ensure_imgcat call must come AFTER the fi.

INTEGRATION_IF_LINE=$(grep -n "if \[ ! -f.*iterm2_shell_integration" "$INSTALL_SHELL" | head -1 | cut -d: -f1)
INTEGRATION_FI_LINE=$(awk -v start="$INTEGRATION_IF_LINE" 'NR >= start && /^[[:space:]]*fi[[:space:]]*$/ { print NR; exit }' "$INSTALL_SHELL")
ENSURE_IMGCAT_LINE=$(grep -n "ensure_imgcat" "$INSTALL_SHELL" | grep -v "^[[:space:]]*#" | grep -v "source" | head -1 | cut -d: -f1)

assert_not_empty "$INTEGRATION_IF_LINE" "Could not find shell-integration if block"
assert_not_empty "$INTEGRATION_FI_LINE" "Could not find closing fi for shell-integration block"
assert_not_empty "$ENSURE_IMGCAT_LINE"  "Could not find ensure_imgcat call in install-shell.sh"

if [[ "$ENSURE_IMGCAT_LINE" -gt "$INTEGRATION_FI_LINE" ]]; then
    test_pass
else
    test_fail "ensure_imgcat (line $ENSURE_IMGCAT_LINE) is inside the shell-integration if-block (ends line $INTEGRATION_FI_LINE) — M1Pro regression NOT fixed"
fi

test_start "Structural: old inline curl imgcat block is GONE from install-shell.sh"
# Use grep -q (not -c) to avoid the "0\n0" double-output when no match (grep -c exits 1
# on no-match; || echo 0 then appends a second "0", making the string "0\n0" != "0").
if grep -q "curl.*iterm2.com/utilities/imgcat" "$INSTALL_SHELL" 2>/dev/null; then
    test_fail "Old inline curl imgcat block must be removed from install-shell.sh"
else
    test_pass
fi

test_start "Functional: integration.zsh pre-exists, ensure_imgcat still provisions"
SANDBOX5=$(make_sandbox)
mkdir -p "$SANDBOX5/.iterm2"
# Pre-seed the integration file so the if-block in install-shell.sh would have skipped old code
touch "$SANDBOX5/.iterm2_shell_integration.zsh"

(
    HOME="$SANDBOX5"
    load_imgcat_provision
    ensure_imgcat "$BUNDLED_SHARE"
    rc=$?
    exit $rc
)
rc=$?
assert_exit_success "$rc" "ensure_imgcat must run even when integration.zsh pre-exists"
test_pass

test_start "Functional: imgcat present after run with pre-existing integration.zsh"
assert_file_exists "$SANDBOX5/.iterm2/imgcat" "imgcat must be provisioned regardless of shell-integration state"
assert_file_exec   "$SANDBOX5/.iterm2/imgcat" "imgcat must be executable"
assert_file_nonempty "$SANDBOX5/.iterm2/imgcat" "imgcat must be non-empty"
test_pass

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Case 6: Upgrade wiring — update_imgcat defined AND called ---"
# ─────────────────────────────────────────────────────────────────────────────

test_start "Upgrade: update_imgcat function is defined in aiteamforge-upgrade.sh"
DEF_COUNT=$(grep -c "^update_imgcat()" "$UPGRADE_SCRIPT" 2>/dev/null || echo 0)
assert_equal "1" "$DEF_COUNT" "update_imgcat() must be defined exactly once"
test_pass

test_start "Upgrade: update_imgcat is called (not just defined)"
# Must appear as a bare call (not inside a comment or string) after its definition
CALL_LINE=$(awk '
    /^update_imgcat\(\)/ { in_def=1 }
    in_def && /^\}/ { in_def=0; next }
    !in_def && /^update_imgcat[[:space:]]*$/ { print NR; exit }
' "$UPGRADE_SCRIPT")
assert_not_empty "$CALL_LINE" "update_imgcat must be called at top level in aiteamforge-upgrade.sh"
test_pass

test_start "Upgrade: update_imgcat call is between update_runtime_helpers and update_shell_helpers"
RUNTIME_LINE=$(grep -n "^update_runtime_helpers" "$UPGRADE_SCRIPT" | tail -1 | cut -d: -f1)
SHELL_LINE=$(grep -n "^update_shell_helpers" "$UPGRADE_SCRIPT" | tail -1 | cut -d: -f1)
IMGCAT_CALL_LINE=$(awk '
    /^update_imgcat\(\)/ { in_def=1 }
    in_def && /^\}/ { in_def=0; next }
    !in_def && /^update_imgcat[[:space:]]*$/ { print NR; exit }
' "$UPGRADE_SCRIPT")

if [[ -n "$RUNTIME_LINE" && -n "$SHELL_LINE" && -n "$IMGCAT_CALL_LINE" ]]; then
    if [[ "$IMGCAT_CALL_LINE" -gt "$RUNTIME_LINE" && "$IMGCAT_CALL_LINE" -lt "$SHELL_LINE" ]]; then
        test_pass
    else
        test_fail "update_imgcat call (line $IMGCAT_CALL_LINE) should be between update_runtime_helpers ($RUNTIME_LINE) and update_shell_helpers ($SHELL_LINE)"
    fi
else
    test_fail "Could not locate all three call sites (runtime=$RUNTIME_LINE imgcat=$IMGCAT_CALL_LINE shell=$SHELL_LINE)"
fi

test_start "Upgrade: failing ensure_imgcat does NOT abort upgrade (non-fatal)"
# The update_imgcat function must not use bare 'return 1' or 'exit' when ensure_imgcat fails
# — it must use a conditional + warning pattern. Verify no unguarded 'return 1' after
# the ensure_imgcat call inside update_imgcat.
# Use grep -q (not -c) to avoid the "0\n0" false-positive (grep -c exits 1 on no-match;
# || echo 0 appends a second "0", making string "0\n0" != "0").
FUNC_BODY=$(awk '/^update_imgcat\(\)/,/^\}/' "$UPGRADE_SCRIPT")
if echo "$FUNC_BODY" | grep -qE "ensure_imgcat.*\|\|.*(return|exit)"; then
    test_fail "ensure_imgcat in update_imgcat must not use bare || return/exit (use if/else)"
else
    test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Case 7: sync-tap drift check ---"
# ─────────────────────────────────────────────────────────────────────────────

if ! $_IN_DEV_MONOREPO; then
    test_start "Sync-tap: script exists at worktree root"
    echo "  SKIP: outer dev-team monorepo not reachable (consumer/standalone tap checkout — sync-tap.sh lives outside this repo)"
    test_pass
    test_start "Sync-tap: vendored imgcat is byte-identical in scripts/vendor and tap/share"
    echo "  SKIP: outer dev-team monorepo not reachable (consumer/standalone tap checkout)"
    test_pass
    test_start "Sync-tap: iterm2/imgcat section shows no drift (XACA-0611 targets clean)"
    echo "  SKIP: outer dev-team monorepo not reachable (consumer/standalone tap checkout)"
    test_pass
else
SYNC_TAP="$WORKTREE_ROOT/sync-tap.sh"

test_start "Sync-tap: script exists at worktree root"
assert_file_exists "$SYNC_TAP" "sync-tap.sh must exist at worktree root"
test_pass

test_start "Sync-tap: vendored imgcat is byte-identical in scripts/vendor and tap/share"
VENDOR_COPY="$WORKTREE_ROOT/scripts/vendor/iterm2/imgcat"
TAP_COPY="$TAP_ROOT/share/iterm2/imgcat"
assert_file_exists "$VENDOR_COPY" "scripts/vendor/iterm2/imgcat must exist"
assert_file_exists "$TAP_COPY"    "homebrew-tap/share/iterm2/imgcat must exist"
if diff -q "$VENDOR_COPY" "$TAP_COPY" > /dev/null 2>&1; then
    test_pass
else
    test_fail "scripts/vendor/iterm2/imgcat and homebrew-tap/share/iterm2/imgcat differ — sync-tap.sh not run or drift present"
fi

test_start "Sync-tap: iterm2/imgcat section shows no drift (XACA-0611 targets clean)"
# sync-tap.sh is a ZSH script — must be invoked with zsh, not bash.
# We only assert the XACA-0611 section (iterm2/) is clean, not the entire tap,
# because pre-existing drift (e.g. docs/TROUBLESHOOTING.md) is unrelated to this ticket.
SYNC_TAP_OUTPUT=$(zsh "$SYNC_TAP" --check \
    --source-dir "$WORKTREE_ROOT" \
    --reference-dir "$WORKTREE_ROOT" 2>&1)
# Extract the iterm2 section (lines between "── iterm2/" and the next "──" section)
ITERM2_SECTION=$(echo "$SYNC_TAP_OUTPUT" | awk '/── iterm2\//,/── [a-z]/' | grep -v "── [a-z]" || true)
if echo "$ITERM2_SECTION" | grep -qiE "^DRIFT|^MISSING"; then
    test_fail "XACA-0611: iterm2/imgcat section shows drift: $ITERM2_SECTION"
else
    test_pass
fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Case 8: Existing panel tests pass (no regression) ---"
# ─────────────────────────────────────────────────────────────────────────────

if ! $_IN_DEV_MONOREPO; then
    test_start "Panel tests: test-agent-panel-display.sh exists"
    echo "  SKIP: outer dev-team monorepo not reachable (consumer/standalone tap checkout — scripts/tests/ lives outside this repo)"
    test_pass
    test_start "Panel tests: no NEW failures introduced by XACA-0611 (pre-existing baseline: 1 known fail)"
    echo "  SKIP: outer dev-team monorepo not reachable (consumer/standalone tap checkout)"
    test_pass
else
PANEL_TEST="$WORKTREE_ROOT/scripts/tests/test-agent-panel-display.sh"

test_start "Panel tests: test-agent-panel-display.sh exists"
assert_file_exists "$PANEL_TEST"
test_pass

test_start "Panel tests: no NEW failures introduced by XACA-0611 (pre-existing baseline: 1 known fail)"
# Known pre-existing failure on develop before XACA-0611:
#   "get_crew_avatars: returns empty for stale subagent file (>10 min)" — macOS touch -t timing bug
# XACA-0611 changes (imgcat-provision.sh, install-shell.sh, aiteamforge-upgrade.sh) do NOT
# touch agent-panel-display.sh or get_crew_avatars — any NEW failure would be a regression.
PANEL_OUTPUT=$(bash "$PANEL_TEST" 2>&1)
FAIL_LINES=$(echo "$PANEL_OUTPUT" | grep "FAILED:" || true)
# grep -q avoids the "0\n0" double-output from grep -c on no-match + || echo 0
NEW_FAILS=$(echo "$FAIL_LINES" | grep -v "returns empty for stale subagent file" || true)
EXTRA_FAIL_COUNT=$(echo "$FAIL_LINES" | grep -c "returns empty for stale subagent file" 2>/dev/null; true)
EXTRA_FAIL_COUNT="${EXTRA_FAIL_COUNT%%$'\n'*}"  # take only first line (strip grep -c double-output)
if [[ -n "$NEW_FAILS" ]]; then
    test_fail "NEW regression introduced: $NEW_FAILS"
elif [[ "${#FAIL_LINES}" -gt 0 && "$EXTRA_FAIL_COUNT" -ne 1 ]]; then
    test_fail "Unexpected failure count (expected only 1 pre-existing): $FAIL_LINES"
else
    test_pass
fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Test Summary"
echo "================================================================"
echo ""
echo "  Total:   $TOTAL_TESTS"
echo -e "  ${GREEN}Passed:  $PASSED_TESTS${NC}"
if [[ $FAILED_TESTS -gt 0 ]]; then
    echo -e "  ${RED}Failed:  $FAILED_TESTS${NC}"
else
    echo    "  Failed:  $FAILED_TESTS"
fi
echo ""
if [[ $FAILED_TESTS -eq 0 ]]; then
    echo -e "${GREEN}All tests passed.${NC}"
    echo ""
    exit 0
else
    echo -e "${RED}${FAILED_TESTS} test(s) failed.${NC}"
    echo ""
    exit 1
fi
