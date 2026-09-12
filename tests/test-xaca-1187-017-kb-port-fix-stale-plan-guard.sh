#!/usr/bin/env bash
# test-xaca-1187-017-kb-port-fix-stale-plan-guard.sh
#
# Regression coverage for XACA-1187-017 (PR #875 review, subitem 16):
# libexec/commands/kb-port-fix.py's `--apply` mode computes its plan and
# shows it to the operator via the interactive "Apply these changes? [y/N]"
# prompt BEFORE acquiring the shared team-paths.json.lock. The pre-existing
# XACA-1187-005 id-set guard (re-read under the lock, refuse if any team id
# would be lost) does NOT catch a concurrent writer changing a FIELD on an
# id this plan is about to overwrite during the operator's think-time at
# that prompt -- the id set is unchanged, so that guard is silent, and the
# tool's write is unconditional on `data` (the STALE pre-prompt snapshot),
# silently clobbering whatever changed.
#
# The fix: cmd_apply freezes a deep copy of the config as read (before the
# prompt) and the exact set of instance ids the plan is about to touch;
# _atomic_write compares that frozen snapshot against a FRESH re-read taken
# under the lock, for exactly those ids, and refuses (raises ValueError,
# caught and reported as a clean ERROR line) if anything differs -- fail
# closed, never by holding the lock across the human prompt.
#
# ── HOW THIS IS EXERCISED ────────────────────────────────────────────────
# kb-port-fix.py's cmd_apply() is called DIRECTLY (imported via
# importlib, not re-implemented) with only two things replaced at the
# CALLER level -- `sys.stdin.isatty` (forced True so the interactive path
# runs without a real TTY) and `builtins.input` (a fake that, in the
# "conflict" case, performs a concurrent field-level edit to the sandboxed
# registry file at the exact moment the real prompt would be waiting on a
# human, then returns "y"). Not one line of kb-port-fix.py's own logic is
# modified or bypassed by this harness.
#
# Cross-checked to discriminate: run identically against the PRE-fix
# version of this file (git show HEAD:libexec/commands/kb-port-fix.py from
# before this ticket's subitem-16 commit), the same conflict scenario is
# silently clobbered (exit 0, concurrent edit discarded) instead of
# refused -- see CASE 3.
#
# Sandboxing: every registry lives under mktemp -d; AITEAMFORGE_CONFIG
# points there. The real ~/.aiteamforge/team-paths.json is never read or
# written.
#
# Exit codes: 0 all assertions passed, 1 one or more failed, 2 SKIP.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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

if [ ! -f "$KB_PORT_FIX_PY" ]; then
    echo "FATAL: kb-port-fix.py not found at $KB_PORT_FIX_PY" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: prerequisite 'python3' not on PATH" >&2
    exit 2
fi

if [[ -z "${TEST_TMP_DIR:-}" ]] || [[ ! -d "${TEST_TMP_DIR:-}" ]]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1187017-portfix-test.XXXXXX)"
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

SEED_REGISTRY='{"teams":{"academy":{"team_code":"ACA","lcars_port":8600,"working_dir":"/w0"},"ios":{"team_code":"IOS","lcars_port":8700,"working_dir":"/w1"},"android":{"team_code":"AND","lcars_port":8700,"working_dir":"/w2"}}}'

# The harness that drives cmd_apply() directly. Written once into
# TEST_TMP_DIR (not a heredoc embedded per-case) since all three cases
# reuse it unmodified with different arguments.
DRIVER="$TEST_TMP_DIR/driver.py"
cat > "$DRIVER" <<'PYEOF'
import argparse
import builtins
import importlib.util
import json
import os
import sys

REG = sys.argv[1]
KB_PORT_FIX_PY = sys.argv[2]
SCENARIO = sys.argv[3]  # "conflict" or "clean"

os.environ["AITEAMFORGE_CONFIG"] = REG

spec = importlib.util.spec_from_file_location("kbportfix_under_test", KB_PORT_FIX_PY)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

sys.stdin.isatty = lambda: True  # pretend interactive; nothing else about stdin is touched


def _fake_input(prompt=""):
    if SCENARIO == "conflict":
        # Simulate a concurrent writer changing a FIELD (not the id set) on
        # an id this plan is about to touch, during the operator's
        # think-time at the (real, unmocked-otherwise) confirmation prompt.
        with open(REG, encoding="utf-8") as fh:
            d = json.load(fh)
        d["teams"]["ios"]["working_dir"] = "/CONCURRENTLY-CHANGED"
        text = json.dumps(d, indent=2)
        with open(REG, "w", encoding="utf-8") as fh:
            fh.write(text)
    return "y"


builtins.input = _fake_input

args = argparse.Namespace(yes=False)
rc = mod.cmd_apply(args)
sys.exit(rc)
PYEOF

run_scenario() {
    # run_scenario <label> <kb-port-fix.py path> <scenario>
    local label="$1" pyfile="$2" scenario="$3"
    local dir="$TEST_TMP_DIR/$label"
    mkdir -p "$dir"
    local reg="$dir/team-paths.json"
    printf '%s' "$SEED_REGISTRY" > "$reg"
    python3 "$DRIVER" "$reg" "$pyfile" "$scenario" > "$dir/out.txt" 2>&1
    echo $? > "$dir/rc.txt"
    RUN_REG="$reg"
    RUN_OUT="$dir/out.txt"
    RUN_RC="$(cat "$dir/rc.txt")"
}

# ============================================================================
# CASE 1: clean apply (no concurrent edit) -- must succeed normally.
# ============================================================================
test_start "CASE1: clean apply with no concurrent change succeeds"
run_scenario "case1-clean" "$KB_PORT_FIX_PY" "clean"
if [ "$RUN_RC" = "0" ]; then
    test_pass
else
    test_fail "expected exit 0, got $RUN_RC -- output: $(cat "$RUN_OUT")"
fi

test_start "CASE1b: clean apply actually renumbers the colliding instance"
NEW_PORT="$(python3 -c "
import json
d = json.load(open('$RUN_REG'))
print(d['teams']['ios']['lcars_port'])
")"
if [ "$NEW_PORT" != "8700" ] && [ -n "$NEW_PORT" ]; then
    test_pass
else
    test_fail "expected 'ios' to be renumbered off 8700, got lcars_port=$NEW_PORT"
fi

# ============================================================================
# CASE 2: a concurrent writer changes a FIELD (working_dir) on 'ios' -- one
# of the ids this plan is about to overwrite -- during the confirmation
# prompt's think-time. Must ABORT (non-zero exit) and must NOT clobber the
# concurrent change.
# ============================================================================
test_start "CASE2: concurrent field-level edit during think-time aborts the write"
run_scenario "case2-conflict" "$KB_PORT_FIX_PY" "conflict"
if [ "$RUN_RC" != "0" ]; then
    test_pass
else
    test_fail "expected a non-zero exit when a concurrent edit is detected, got 0 -- output: $(cat "$RUN_OUT")"
fi

test_start "CASE2b: the abort message names XACA-1187-017 and the affected id"
if grep -q "XACA-1187-017" "$RUN_OUT" && grep -q "ios" "$RUN_OUT"; then
    test_pass
else
    test_fail "expected the error to cite XACA-1187-017 and name 'ios' -- output: $(cat "$RUN_OUT")"
fi

test_start "CASE2c: the concurrent writer's change survives untouched (not clobbered)"
SURVIVED="$(python3 -c "
import json
d = json.load(open('$RUN_REG'))
print(d['teams']['ios']['working_dir'])
")"
if [ "$SURVIVED" = "/CONCURRENTLY-CHANGED" ]; then
    test_pass
else
    test_fail "expected 'ios'.working_dir to still be '/CONCURRENTLY-CHANGED', got '$SURVIVED' -- the stale plan clobbered it"
fi

test_start "CASE2d: 'ios' was NOT renumbered (the write was refused, not partially applied)"
STILL_PORT="$(python3 -c "
import json
d = json.load(open('$RUN_REG'))
print(d['teams']['ios']['lcars_port'])
")"
if [ "$STILL_PORT" = "8700" ]; then
    test_pass
else
    test_fail "expected 'ios'.lcars_port to still be 8700 (refused write, not a partial one), got $STILL_PORT"
fi

# NOTE: an earlier draft of this suite had a CASE 3 that pulled the
# pre-subitem-16 body via `git show HEAD:...` for a discriminating
# contrast check. Deliberately removed (XACA-1187-007 durability lesson,
# same PR): this repo squash-merges, so any commit reference resolved at
# test-write time can stop existing the moment the enclosing PR merges,
# and a test that depends on git history to pass is not durable. CASE 1
# and CASE 2 above already exercise the CURRENT, real, unmodified
# kb-port-fix.py directly and prove the fix's behavior on their own,
# without needing a before/after contrast. If a discriminating contrast
# is ever wanted again, vendor a frozen fixture file (see
# tests/fixtures/xaca1187/ in the outer dev-team repo for the pattern),
# never a git-history lookup.

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
