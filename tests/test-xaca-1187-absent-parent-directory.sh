#!/usr/bin/env bash
# test-xaca-1187-absent-parent-directory.sh
#
# Regression coverage for the PR #875 round-2 fix (tap-native sites):
# libexec/installers/install-team.sh's team-paths write, and
# libexec/commands/kb-port-fix.py:_atomic_write, must be able to write a
# config into a directory that does not exist yet. Every hardened site in
# this ticket opened its shared team-paths.json.lock file BEFORE creating
# the parent directory; on a genuinely first-time machine
# (~/.aiteamforge/ never created) the lock open() failed with ENOENT and
# the tool always exited non-zero -- caught live by CI's shell-suite check
# on PR #875 head dfd75831 (in the dev-team outer repo's kb-init-team /
# kb-freelance; the reviewer found the identical ordering here by
# inspection).
#
# See tests/test-xaca1187-007-concurrent-team-registration.sh (outer
# dev-team repo, CASE 11-14) for the fully discriminating
# (fails-before/passes-after, via a vendored frozen pre-fix fixture) proof
# against kb-init-team and kb-freelance. This suite covers the two
# tap-native sites directly (called, not re-implemented), with
# discrimination for install-team.sh verified by hand while writing the
# fix (see that commit's message for the exact before/after run) rather
# than vendoring a second copy of the whole ~3700-line installer as a
# frozen fixture for one function's before/after.
#
# kb-port-fix.py:_atomic_write's CASE B below is explicitly a
# consistency/future-proofing check, not a reachable-today regression
# test: its one caller (cmd_apply) already exits 3 earlier via
# _load_team_paths() if the config file doesn't exist, which guarantees
# the parent directory is already present by the time _atomic_write runs.
# The mkdir added there cannot currently be exercised through the CLI --
# this suite calls _atomic_write() directly to prove it, so a future
# caller that skips that earlier existence check doesn't silently
# reintroduce the regression unnoticed.
#
# Sandboxing: every path lives under mktemp -d / TEST_TMP_DIR. The real
# ~/.aiteamforge/team-paths.json is never read or written, and this suite
# never deletes or recreates any real directory.
#
# Exit codes: 0 all assertions passed, 1 one or more failed, 2 SKIP.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_TEAM="$TAP_ROOT/libexec/installers/install-team.sh"
KB_PORT_FIX_PY="$TAP_ROOT/libexec/commands/kb-port-fix.py"

_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""

    test_start() { _CURRENT_TEST="$1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); printf "PASS: %s\n" "$_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); printf "FAIL: %s -- %s\n" "$_CURRENT_TEST" "$1" >&2; }
fi

if [ ! -f "$INSTALL_TEAM" ]; then
    echo "FATAL: install-team.sh not found at $INSTALL_TEAM" >&2
    exit 1
fi
if [ ! -f "$KB_PORT_FIX_PY" ]; then
    echo "FATAL: kb-port-fix.py not found at $KB_PORT_FIX_PY" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: prerequisite 'python3' not on PATH" >&2
    exit 2
fi

if [[ -z "${TEST_TMP_DIR:-}" ]] || [[ ! -d "${TEST_TMP_DIR:-}" ]]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1187-absentparent-tap.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"

_cleanup() {
    if [[ "${_OWN_TMP:-false}" = true ]] && [[ -n "${TEST_TMP_DIR:-}" ]]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap _cleanup EXIT INT TERM

# ============================================================================
# CASE A: install-team.sh's team-paths write, extracted heredoc, called
# directly against a genuinely absent parent directory.
# ============================================================================
test_start "CASE A: install-team.sh team-paths write succeeds against a genuinely absent parent"

HEREDOC_PY="$TEST_TMP_DIR/install-team-heredoc.py"
awk '/<<.TEAM_PATHS_PYEOF./{f=1;next} f && /^TEAM_PATHS_PYEOF$/{exit} f{print}' "$INSTALL_TEAM" > "$HEREDOC_PY"
if [ ! -s "$HEREDOC_PY" ]; then
    test_fail "could not extract the TEAM_PATHS_PYEOF heredoc body from install-team.sh -- the anchor may have moved"
else
    ABSENT_DIR="$TEST_TMP_DIR/case-a/does-not-exist-yet/nested"
    ABSENT_REG="$ABSENT_DIR/team-paths.json"
    if [ -e "$(dirname "$ABSENT_DIR")" ]; then
        test_fail "harness bug -- absent-parent directory already exists before the write under test ran"
    else
        python3 "$HEREDOC_PY" fresh-instance-a academy /kanban/a /work/a 8700 "$ABSENT_REG" \
            > "$TEST_TMP_DIR/case-a.out" 2>&1
        RC=$?
        if [ "$RC" -eq 0 ] && [ -f "$ABSENT_REG" ]; then
            test_pass
        else
            test_fail "expected exit 0 and a written registry -- got rc=$RC, output: $(cat "$TEST_TMP_DIR/case-a.out")"
        fi
    fi
fi

# ============================================================================
# CASE B: kb-port-fix.py:_atomic_write, called directly (importlib) against
# a genuinely absent parent directory. See the header comment above for why
# this specific path is not reachable via the CLI today.
# ============================================================================
test_start "CASE B: kb-port-fix.py _atomic_write succeeds against a genuinely absent parent (consistency/future-proofing, not reachable via the CLI today)"

DRIVER="$TEST_TMP_DIR/portfix-driver.py"
cat > "$DRIVER" <<'PYEOF'
import importlib.util
import sys
from pathlib import Path

kb_port_fix_py, target = sys.argv[1], sys.argv[2]

spec = importlib.util.spec_from_file_location("kbportfix_under_test", kb_port_fix_py)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

try:
    mod._atomic_write({"teams": {"academy": {"team_code": "ACA", "lcars_port": 8600}}}, Path(target))
    sys.exit(0)
except Exception as exc:
    sys.stderr.write(f"{type(exc).__name__}: {exc}\n")
    sys.exit(1)
PYEOF

ABSENT_DIR_B="$TEST_TMP_DIR/case-b/does-not-exist-yet/nested"
ABSENT_REG_B="$ABSENT_DIR_B/team-paths.json"
python3 "$DRIVER" "$KB_PORT_FIX_PY" "$ABSENT_REG_B" > "$TEST_TMP_DIR/case-b.out" 2>&1
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$ABSENT_REG_B" ]; then
    test_pass
else
    test_fail "expected exit 0 and a written registry -- got rc=$RC, output: $(cat "$TEST_TMP_DIR/case-b.out")"
fi

# ============================================================================
# Summary
# ============================================================================
if [ "$_STANDALONE" = true ]; then
    TOTAL=$((_PASS_COUNT + _FAIL_COUNT))
    if [ "$TOTAL" -eq 0 ]; then
        echo "FAIL: 0 assertions executed -- vacuous run" >&2
        exit 1
    fi
    echo ""
    echo "${_PASS_COUNT} passed, ${_FAIL_COUNT} failed (of ${TOTAL} assertions)"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
    exit 0
fi
