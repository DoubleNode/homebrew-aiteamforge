#!/bin/bash

# test-xaca-0564-kanban-helpers-overwrite-guard.sh
# Regression tests for the XACA-0559 / XACA-0564 dev-repo overwrite guard in
# install_kanban_helpers() (libexec/installers/install-kanban.sh).
#
# Guard contract:
#   - AITEAMFORGE_DIR is a git work-tree root OR kanban-helpers.sh is
#     git-tracked under AITEAMFORGE_DIR
#     + AITEAMFORGE_ALLOW_DEV_OVERWRITE != "1"  =>  exit 1 (hard abort)
#     + AITEAMFORGE_ALLOW_DEV_OVERWRITE=1        =>  warning + proceeds to write
#   - AITEAMFORGE_DIR is a plain non-git dir     =>  normal write (no guard)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLERS_DIR="$TAP_ROOT/libexec/installers"

INSTALLER="$INSTALLERS_DIR/install-kanban.sh"
TEMPLATE="$TAP_ROOT/share/templates/aliases/kanban-aliases.sh"

# Sentinel content written into fixture kanban-helpers.sh files.
SENTINEL="# SENTINEL-SOURCE-OF-TRUTH — must not be overwritten"

# Known string that MUST appear in the rendered kanban-aliases.sh template.
TEMPLATE_MARKER="kb-list"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: provide no-op stubs when test-runner.sh has not exported
# the real harness functions, and manage our own pass/fail counters.  Lets a
# developer run `bash tests/test-xaca-0564-...sh` directly OR via test-runner.sh.
# (Pattern mirrors test-xaca-0498-twd-guard.sh — PR #476 review follow-up.)
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

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory: use the runner-supplied TEST_TMP_DIR or create our own.
# Canonicalize via `cd && pwd -P` so the guard's own `cd && pwd` comparisons
# match on macOS, where /var and /tmp are symlinks into /private/...
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0564-guard-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Helper: run install_kanban_helpers in an isolated subshell.
#
# Usage: run_guard <aiteamforge_dir> [AITEAMFORGE_ALLOW_DEV_OVERWRITE=1]
#
# The subshell sources install-kanban.sh (which pulls in common.sh / constants.sh
# via BASH_SOURCE-relative paths) and then calls install_kanban_helpers().
# set -euo pipefail is inherited inside the subshell only — it cannot escape.
# exit 1 inside the guard only kills the subshell, so the test runner survives.
# ─────────────────────────────────────────────────────────────────────────────
run_guard() {
  local dir="$1"
  local allow_overwrite="${2:-}"

  (
    # Required by install_kanban_helpers to find the template.
    export INSTALL_ROOT="$TAP_ROOT"
    export AITEAMFORGE_HOME="$TAP_ROOT"
    export AITEAMFORGE_DIR="$dir"
    if [ "$allow_overwrite" = "1" ]; then
      export AITEAMFORGE_ALLOW_DEV_OVERWRITE=1
    else
      unset AITEAMFORGE_ALLOW_DEV_OVERWRITE
    fi

    # Suppress unrelated installer variables that set -u would complain about.
    export TEAM_WORKING_DIRS_STR=""
    export KANBAN_BACKUP_INTERVAL=900

    # Source the installer.  BASH_SOURCE[0] inside install-kanban.sh will
    # point to the file path, so the lib/ relative sources resolve correctly.
    # Redirect stdout so installer progress messages don't pollute test output.
    source "$INSTALLER" >/dev/null 2>&1

    # Call the guard function under test.
    install_kanban_helpers >/dev/null 2>&1
  )
  # Capture subshell exit code.
  echo $?
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1 — Abort case (reproduces the XACA-0559 bug).
#
# Fixture: a git-repo-root AITEAMFORGE_DIR with a committed kanban-helpers.sh
# containing the sentinel string.  With no opt-in, the guard must:
#   (a) abort with exit code 1
#   (b) leave the file content unchanged (sentinel still present)
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0564: guard aborts when AITEAMFORGE_DIR is a git repo root (no opt-in)"

CASE1_DIR="$TEST_TMP_DIR/case1-dev-repo"
mkdir -p "$CASE1_DIR"
git -c init.defaultBranch=main init "$CASE1_DIR" >/dev/null 2>&1
echo "$SENTINEL" > "$CASE1_DIR/kanban-helpers.sh"
git -C "$CASE1_DIR" -c user.email=test@test -c user.name=test add kanban-helpers.sh >/dev/null 2>&1
git -C "$CASE1_DIR" -c user.email=test@test -c user.name=test commit -m "add helpers" >/dev/null 2>&1

CASE1_EXIT=$(run_guard "$CASE1_DIR")
CASE1_CONTENT=$(cat "$CASE1_DIR/kanban-helpers.sh")

if [ "$CASE1_EXIT" != "0" ] && echo "$CASE1_CONTENT" | grep -q "SENTINEL-SOURCE-OF-TRUTH"; then
  test_pass
else
  test_fail "exit=$CASE1_EXIT (want non-0); sentinel_intact=$(echo "$CASE1_CONTENT" | grep -q "SENTINEL-SOURCE-OF-TRUTH" && echo "yes" || echo "no")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 2 — Opt-in bypass.
#
# Same git-repo fixture; AITEAMFORGE_ALLOW_DEV_OVERWRITE=1.  The guard must:
#   (a) exit 0
#   (b) overwrite the file with template content (sentinel is gone; template
#       marker is present)
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0564: AITEAMFORGE_ALLOW_DEV_OVERWRITE=1 allows overwrite and exits 0"

CASE2_DIR="$TEST_TMP_DIR/case2-allow-overwrite"
mkdir -p "$CASE2_DIR"
git -c init.defaultBranch=main init "$CASE2_DIR" >/dev/null 2>&1
echo "$SENTINEL" > "$CASE2_DIR/kanban-helpers.sh"
git -C "$CASE2_DIR" -c user.email=test@test -c user.name=test add kanban-helpers.sh >/dev/null 2>&1
git -C "$CASE2_DIR" -c user.email=test@test -c user.name=test commit -m "add helpers" >/dev/null 2>&1

CASE2_EXIT=$(run_guard "$CASE2_DIR" "1")
CASE2_CONTENT=$(cat "$CASE2_DIR/kanban-helpers.sh" 2>/dev/null || echo "")

CASE2_SENTINEL_GONE=false
CASE2_TEMPLATE_PRESENT=false
if ! echo "$CASE2_CONTENT" | grep -q "SENTINEL-SOURCE-OF-TRUTH"; then
  CASE2_SENTINEL_GONE=true
fi
if echo "$CASE2_CONTENT" | grep -q "$TEMPLATE_MARKER"; then
  CASE2_TEMPLATE_PRESENT=true
fi

if [ "$CASE2_EXIT" = "0" ] && [ "$CASE2_SENTINEL_GONE" = "true" ] && [ "$CASE2_TEMPLATE_PRESENT" = "true" ]; then
  test_pass
else
  test_fail "exit=$CASE2_EXIT (want 0); sentinel_gone=$CASE2_SENTINEL_GONE; template_present=$CASE2_TEMPLATE_PRESENT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 3 — Clean sandbox (fresh-install / sandboxed paths unaffected).
#
# Fixture: a plain non-git temp directory.  With no opt-in, the guard must:
#   (a) exit 0
#   (b) write the template content into kanban-helpers.sh
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0564: plain non-git AITEAMFORGE_DIR proceeds normally (exit 0, file written)"

CASE3_DIR="$TEST_TMP_DIR/case3-plain-sandbox"
mkdir -p "$CASE3_DIR"
# No git init — this is a plain directory, simulating ~/.aiteamforge

CASE3_EXIT=$(run_guard "$CASE3_DIR")
CASE3_CONTENT=$(cat "$CASE3_DIR/kanban-helpers.sh" 2>/dev/null || echo "")
CASE3_TEMPLATE_PRESENT=false
if echo "$CASE3_CONTENT" | grep -q "$TEMPLATE_MARKER"; then
  CASE3_TEMPLATE_PRESENT=true
fi

if [ "$CASE3_EXIT" = "0" ] && [ "$CASE3_TEMPLATE_PRESENT" = "true" ]; then
  test_pass
else
  test_fail "exit=$CASE3_EXIT (want 0); template_present=$CASE3_TEMPLATE_PRESENT; content_head=$(echo "$CASE3_CONTENT" | head -2)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 4 (bonus) — Subdir-tracked detection.
#
# Fixture: AITEAMFORGE_DIR is a SUBDIRECTORY of a git repo, and
# kanban-helpers.sh is tracked at that subdir path (git ls-files sees it).
# This exercises Check 2 in the guard (not just the work-tree-root check).
# The guard must abort with exit 1 even though the subdir is NOT the repo root.
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0564: guard aborts when kanban-helpers.sh is git-tracked in a subdir (Check 2)"

CASE4_REPO="$TEST_TMP_DIR/case4-parent-repo"
CASE4_DIR="$CASE4_REPO/subdir"
mkdir -p "$CASE4_DIR"
git -c init.defaultBranch=main init "$CASE4_REPO" >/dev/null 2>&1
echo "$SENTINEL" > "$CASE4_DIR/kanban-helpers.sh"
git -C "$CASE4_REPO" -c user.email=test@test -c user.name=test add subdir/kanban-helpers.sh >/dev/null 2>&1
git -C "$CASE4_REPO" -c user.email=test@test -c user.name=test commit -m "track subdir" >/dev/null 2>&1

CASE4_EXIT=$(run_guard "$CASE4_DIR")
CASE4_CONTENT=$(cat "$CASE4_DIR/kanban-helpers.sh")

if [ "$CASE4_EXIT" != "0" ] && echo "$CASE4_CONTENT" | grep -q "SENTINEL-SOURCE-OF-TRUTH"; then
  test_pass
else
  test_fail "exit=$CASE4_EXIT (want non-0); sentinel_intact=$(echo "$CASE4_CONTENT" | grep -q "SENTINEL-SOURCE-OF-TRUTH" && echo "yes" || echo "no")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone mode only — test-runner.sh tallies pass/fail from output).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    if [ "$_FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
fi
exit 0
