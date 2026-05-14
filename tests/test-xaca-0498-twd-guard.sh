#!/usr/bin/env bash
# test-xaca-0498-twd-guard.sh
# Sandbox harness for XACA-0498 TEAM_WORKING_DIR guard
#
# Covers:
# - Branch A: DENY  — sentinel + depth-1 TEAM_WORKING_DIR (non-project team)
# - Branch B: ALLOW — Command monorepo, AITF inside TEAM_WORKING_DIR
# - Branch C: ALLOW — no sentinel (end-user machine, short-circuit path)
# - Branch D: ALLOW — depth-2 project team on dev machine
#
# All sandbox writes go under TEST_TMP_DIR; real $HOME is never touched.
# Runnable standalone or via test-runner.sh (framework functions are stubs
# when not exported by the runner).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_TEAM="$TAP_ROOT/libexec/installers/install-team.sh"
ORG_EXAMPLE="$TAP_ROOT/share/config/organization.yaml.example"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: provide no-op stubs when test-runner hasn't exported
# the real functions, and manage our own pass/fail counters.
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
# Temp directory: use runner-supplied TEST_TMP_DIR or create our own.
#
# IMPORTANT: On macOS, mktemp returns paths under /var/folders which is a
# symlink to /private/var/folders.  The guard in install-team.sh uses
# `pwd -P` to resolve the canonical path when computing _TWD_PARENT.
# If $HOME points to the symlinked form and _TWD_PARENT is the resolved form
# they won't compare equal, so the guard never fires.
#
# Fix: canonicalize TEST_TMP_DIR via `cd … && pwd -P` before building fake
# HOME paths from it.  This ensures $HOME == _TWD_PARENT in the guard.
# ─────────────────────────────────────────────────────────────────────────────
if [[ -z "${TEST_TMP_DIR:-}" ]] || [[ ! -d "${TEST_TMP_DIR:-}" ]]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0498-guard-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi

# Resolve to canonical (symlink-free) path so guard comparisons work on macOS.
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"

cleanup() {
    if [[ "${_OWN_TMP:-false}" = true ]] && [[ -n "${TEST_TMP_DIR:-}" ]]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

# ─────────────────────────────────────────────────────────────────────────────
# Helper: create a minimal organization.yaml in $1/.aiteamforge/ so the org
# check in install-team.sh passes without needing an interactive terminal.
# ─────────────────────────────────────────────────────────────────────────────
_write_org_config() {
    local fake_home="$1"
    mkdir -p "$fake_home/.aiteamforge"
    cp "$ORG_EXAMPLE" "$fake_home/.aiteamforge/organization.yaml"
}

# ─────────────────────────────────────────────────────────────────────────────
# Preflight: confirm install-team.sh exists and is executable
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0498: install-team.sh exists and is executable"
if [[ -x "$INSTALL_TEAM" ]]; then
    test_pass
else
    test_fail "install-team.sh not found or not executable: $INSTALL_TEAM"
fi

# ─────────────────────────────────────────────────────────────────────────────
# BRANCH A: DENY — sentinel present, depth-1 TEAM_WORKING_DIR
# ─────────────────────────────────────────────────────────────────────────────
# Academy: TEAM_WORKING_DIR=$HOME/academy (depth-1, parent==$HOME).
# Sentinel: $HOME/dev-team/.aiteamforge-source-tree present.
# AITEAMFORGE_DIR is outside dev-team and not a prefix/suffix of TWD.
# Expected: guard fires, exit non-zero, $HOME/academy NOT created.
#
# Canonical paths are required (see TEST_TMP_DIR note above).
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0498-A: DENY — sentinel present, academy depth-1 TEAM_WORKING_DIR"

_A_HOME="$TEST_TMP_DIR/branch-a-home"
_A_AITF="$TEST_TMP_DIR/branch-a-aitf"
mkdir -p "$_A_HOME/dev-team" "$_A_AITF"
touch "$_A_HOME/dev-team/.aiteamforge-source-tree"
_write_org_config "$_A_HOME"

_A_STDERR="$TEST_TMP_DIR/branch-a-stderr.txt"
_A_STDOUT="$TEST_TMP_DIR/branch-a-stdout.txt"

_A_EXIT=0
HOME="$_A_HOME" AITEAMFORGE_DIR="$_A_AITF" \
    bash "$INSTALL_TEAM" academy \
    >"$_A_STDOUT" 2>"$_A_STDERR" || _A_EXIT=$?

_A_PASS=true

if [[ "$_A_EXIT" -eq 0 ]]; then
    test_fail "Branch A: guard did not fire — expected non-zero exit, got 0"
    _A_PASS=false
fi

if [[ "$_A_PASS" = true ]] && ! grep -q "TEAM_WORKING_DIR resolves to a direct" "$_A_STDERR" 2>/dev/null; then
    test_fail "Branch A: XACA-0498 error message absent from stderr (got: $(cat "$_A_STDERR"))"
    _A_PASS=false
fi

if [[ "$_A_PASS" = true ]] && [[ -d "$_A_HOME/academy" ]]; then
    test_fail "Branch A: \$HOME/academy was created despite guard firing"
    _A_PASS=false
fi

[[ "$_A_PASS" = true ]] && test_pass

# ─────────────────────────────────────────────────────────────────────────────
# BRANCH B: ALLOW — Command monorepo (AITF inside TEAM_WORKING_DIR)
# ─────────────────────────────────────────────────────────────────────────────
# Command: TEAM_WORKING_DIR=$HOME/dev-team (depth-1). Sentinel present.
# AITEAMFORGE_DIR=$HOME/dev-team/aiteamforge — a sub-path of TEAM_WORKING_DIR.
# Guard clause 3 (AITF starts with TWD prefix) is FALSE → guard does NOT fire.
# XACA-0497 doesn't fire: $HOME/dev-team/aiteamforge has no sentinel.
# Expected: guard does NOT fire; install progresses to "Team Name:" output.
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0498-B: ALLOW — Command monorepo, AITF inside TEAM_WORKING_DIR"

_B_HOME="$TEST_TMP_DIR/branch-b-home"
_B_AITF="$_B_HOME/dev-team/aiteamforge"
mkdir -p "$_B_HOME/dev-team" "$_B_AITF"
touch "$_B_HOME/dev-team/.aiteamforge-source-tree"
_write_org_config "$_B_HOME"

_B_STDERR="$TEST_TMP_DIR/branch-b-stderr.txt"
_B_STDOUT="$TEST_TMP_DIR/branch-b-stdout.txt"

HOME="$_B_HOME" AITEAMFORGE_DIR="$_B_AITF" \
    bash "$INSTALL_TEAM" command \
    >"$_B_STDOUT" 2>"$_B_STDERR" || true

_B_PASS=true

if grep -q "TEAM_WORKING_DIR resolves to a direct" "$_B_STDERR" 2>/dev/null; then
    test_fail "Branch B: XACA-0498 guard fired unexpectedly (stderr: $(cat "$_B_STDERR"))"
    _B_PASS=false
fi

if [[ "$_B_PASS" = true ]] && ! grep -q "Team Name:" "$_B_STDOUT" 2>/dev/null; then
    test_fail "Branch B: did not reach 'Team Name:' output past guard (stdout: $(cat "$_B_STDOUT"))"
    _B_PASS=false
fi

[[ "$_B_PASS" = true ]] && test_pass

# ─────────────────────────────────────────────────────────────────────────────
# BRANCH C: ALLOW — no sentinel (end-user machine)
# ─────────────────────────────────────────────────────────────────────────────
# Fake $HOME has no dev-team/.aiteamforge-source-tree. Guard short-circuits.
# AITEAMFORGE_DIR is outside any source tree. Academy team (depth-1).
# Expected: no XACA-0498 error; install progresses to "Team Name:" output.
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0498-C: ALLOW — no sentinel, end-user machine"

_C_HOME="$TEST_TMP_DIR/branch-c-home"
_C_AITF="$TEST_TMP_DIR/branch-c-aitf"
# Deliberately NOT creating $_C_HOME/dev-team or any sentinel.
mkdir -p "$_C_HOME" "$_C_AITF"
_write_org_config "$_C_HOME"

_C_STDERR="$TEST_TMP_DIR/branch-c-stderr.txt"
_C_STDOUT="$TEST_TMP_DIR/branch-c-stdout.txt"

HOME="$_C_HOME" AITEAMFORGE_DIR="$_C_AITF" \
    bash "$INSTALL_TEAM" academy \
    >"$_C_STDOUT" 2>"$_C_STDERR" || true

_C_PASS=true

if grep -q "TEAM_WORKING_DIR resolves to a direct" "$_C_STDERR" 2>/dev/null; then
    test_fail "Branch C: XACA-0498 guard fired on a no-sentinel machine (stderr: $(cat "$_C_STDERR"))"
    _C_PASS=false
fi

if [[ "$_C_PASS" = true ]] && ! grep -q "Team Name:" "$_C_STDOUT" 2>/dev/null; then
    test_fail "Branch C: did not reach 'Team Name:' output past guard (stdout: $(cat "$_C_STDOUT"))"
    _C_PASS=false
fi

[[ "$_C_PASS" = true ]] && test_pass

# ─────────────────────────────────────────────────────────────────────────────
# BRANCH D: ALLOW — depth-2 project team on dev machine
# ─────────────────────────────────────────────────────────────────────────────
# Medical: TEAM_HAS_PROJECTS=true. Conf base: $HOME/medical.
# After XACA-0485 augmentation: TEAM_WORKING_DIR=$HOME/medical/general.
# TWD parent = $HOME/medical (NOT $HOME itself) → guard clause 1 is FALSE.
# Sentinel present. Expected: guard does NOT fire.
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0498-D: ALLOW — depth-2 project team on dev machine (medical/general)"

_D_HOME="$TEST_TMP_DIR/branch-d-home"
_D_AITF="$TEST_TMP_DIR/branch-d-aitf"
mkdir -p "$_D_HOME/dev-team" "$_D_AITF"
touch "$_D_HOME/dev-team/.aiteamforge-source-tree"
_write_org_config "$_D_HOME"

_D_STDERR="$TEST_TMP_DIR/branch-d-stderr.txt"
_D_STDOUT="$TEST_TMP_DIR/branch-d-stdout.txt"

HOME="$_D_HOME" AITEAMFORGE_DIR="$_D_AITF" \
    bash "$INSTALL_TEAM" medical --project general \
    >"$_D_STDOUT" 2>"$_D_STDERR" || true

_D_PASS=true

if grep -q "TEAM_WORKING_DIR resolves to a direct" "$_D_STDERR" 2>/dev/null; then
    test_fail "Branch D: XACA-0498 guard fired for depth-2 project team (stderr: $(cat "$_D_STDERR"))"
    _D_PASS=false
fi

if [[ "$_D_PASS" = true ]] && ! grep -q "Team Name:" "$_D_STDOUT" 2>/dev/null; then
    test_fail "Branch D: did not reach 'Team Name:' output past guard (stdout: $(cat "$_D_STDOUT"))"
    _D_PASS=false
fi

[[ "$_D_PASS" = true ]] && test_pass

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone mode only)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$_STANDALONE" = true ]]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    if [[ "$_FAIL_COUNT" -gt 0 ]]; then
        exit 1
    fi
fi
