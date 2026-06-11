#!/bin/bash
# test-xaca-0632-kb-variance.sh
# Drift-detection test for the kb-variance estimate-vs-actual handicap reporter
# in the SHIPPED tap aliases file.
#
# Context (XACA-0632): kb-variance was ported into the tap aliases template so
# installed-tap users have the CLI alongside the LCARS variance panel. The
# canonical implementation still lives in dev-team's kanban-helpers.sh; THIS is
# the tap copy. Two copies now exist, so this test pins the contract:
#   - the function is present and runnable in the shipped file
#   - --json emits the spec §7 payload with deterministic, spec-anchored values
#   - human / empty-state / --help paths render
#   - (when reachable) the tap copy's --json is byte-identical to the dev copy,
#     catching sibling-drift before it ships
#
# Designed to run standalone OR via test-runner.sh.
# Exit 0 = all cases pass.  Exit 1 = at least one case failed.

set -o pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Locate the SHIPPED aliases file — the whole point of this test.
# Source-of-truth is kanban-helpers.sh in dev-team; THIS file is the tap copy.
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ALIASES_PATH="$TAP_ROOT/share/templates/aliases/kanban-aliases.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Minimal self-contained test framework
# (Falls through to runner-exported functions if available — no conflict.)
# ─────────────────────────────────────────────────────────────────────────────
_PASS=0
_FAIL=0
_CURRENT_TEST=""

if ! declare -F test_start &>/dev/null; then
    test_start() { _CURRENT_TEST="$1"; printf "TEST: %s\n" "$1"; }
fi
if ! declare -F test_pass &>/dev/null; then
    test_pass() { _PASS=$((_PASS + 1)); printf "  PASS: %s\n" "$_CURRENT_TEST"; }
fi
if ! declare -F test_fail &>/dev/null; then
    test_fail() { _FAIL=$((_FAIL + 1)); printf "  FAIL: %s — %s\n" "$_CURRENT_TEST" "${1:-}" >&2; }
fi
if ! declare -F assert_contains &>/dev/null; then
    assert_contains() {
        local haystack="$1" needle="$2"
        if [[ "$haystack" != *"$needle"* ]]; then test_fail "Expected to find '$needle'"; fi
    }
fi
if ! declare -F assert_eq &>/dev/null; then
    assert_eq() {
        if [[ "$1" != "$2" ]]; then test_fail "Expected '$2', got '$1'"; fi
    }
fi

# Hard-stop on missing aliases file — nothing else can be tested.
if [ ! -f "$ALIASES_PATH" ]; then
    echo "FATAL: Shipped aliases file not found at: $ALIASES_PATH" >&2
    echo "  This test must run from inside the homebrew-tap checkout." >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Deterministic fixture (spec-anchored values)
#   A-1: 1pt   / 1.5h  → ratio 1.50   bucket <=1h
#   A-2: 2pt   / 2.5h  → ratio 1.25   bucket 1-4h
#   A-3: 6pt   / 5.0h  → ratio 0.833… bucket 4-8h
#   A-4: 10pt  / 14.0h → ratio 1.40   bucket >8h
#   A-5: completed, points only        → excluded no_time
#   A-6: completed, time only          → excluded no_estimate
#   A-7: completed, neither            → excluded both_missing
#   A-8: not completed (ignored)
# Global: sumEst=19, sumAct=23 → handicap 1.21; median of [1.5,1.25,0.833,1.4]
#         sorted=[0.833,1.25,1.4,1.5] → (1.25+1.4)/2 = 1.325 → round2 1.32
# ─────────────────────────────────────────────────────────────────────────────
_FIXTURE_DIR=$(mktemp -d -t kbvar-test.XXXXXX)
_FIXTURE="$_FIXTURE_DIR/academy-board.json"
cat > "$_FIXTURE" <<'JSON'
{
  "backlog": [
    {"id":"A-1","status":"completed","points":1,"timeWorkedMs":5400000},
    {"id":"A-2","status":"completed","points":2,"timeWorkedMs":9000000},
    {"id":"A-3","status":"completed","points":6,"timeWorkedMs":18000000},
    {"id":"A-4","status":"completed","points":10,"timeWorkedMs":50400000},
    {"id":"A-5","status":"completed","points":3,"timeWorkedMs":null},
    {"id":"A-6","status":"completed","points":null,"timeWorkedMs":3600000},
    {"id":"A-7","status":"completed"},
    {"id":"A-8","status":"coding","points":4,"timeWorkedMs":7200000}
  ]
}
JSON
_EMPTY="$_FIXTURE_DIR/empty-board.json"
printf '{"backlog":[{"id":"E-1","status":"coding","points":2,"timeWorkedMs":3600000}]}\n' > "$_EMPTY"

_cleanup() { rm -rf "$_FIXTURE_DIR"; }
trap _cleanup EXIT

# Source the shipped aliases and run kb-variance. --board-file bypasses team
# resolution so no sandbox HOME is needed; functions are bash-compatible.
_run_variance() {
    bash -c "source '$ALIASES_PATH' >/dev/null 2>&1; kb-variance $*" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Case 1: function is present in the shipped file
# ─────────────────────────────────────────────────────────────────────────────
test_start "kb-variance is defined in the shipped aliases file"
if grep -q '^kb-variance()' "$ALIASES_PATH"; then test_pass; else test_fail "no kb-variance() definition"; fi

# ─────────────────────────────────────────────────────────────────────────────
# Case 2: --json emits spec-anchored deterministic values
# ─────────────────────────────────────────────────────────────────────────────
test_start "kb-variance --json emits spec §7 payload with expected values"
_JSON=$(_run_variance --json --board-file "$_FIXTURE")
if ! printf '%s' "$_JSON" | jq -e . >/dev/null 2>&1; then
    test_fail "output is not valid JSON: $_JSON"
else
    # Snapshot the failure counter so the pass-guard reflects THIS case only —
    # a failure in an earlier case must not suppress Case 2's pass label.
    _case2_fail_before=$_FAIL
    assert_eq "$(printf '%s' "$_JSON" | jq -r '.eligible')"            "4"
    assert_eq "$(printf '%s' "$_JSON" | jq -r '.excluded.no_estimate')" "1"
    assert_eq "$(printf '%s' "$_JSON" | jq -r '.excluded.no_time')"     "1"
    assert_eq "$(printf '%s' "$_JSON" | jq -r '.excluded.both_missing')" "1"
    assert_eq "$(printf '%s' "$_JSON" | jq -r '.excluded.total')"        "3"
    assert_eq "$(printf '%s' "$_JSON" | jq -r '.global.handicap')"       "1.21"
    assert_eq "$(printf '%s' "$_JSON" | jq -r '.global.median')"         "1.32"
    assert_eq "$(printf '%s' "$_JSON" | jq -r '.global.sumEstimatedHours')" "19"
    assert_eq "$(printf '%s' "$_JSON" | jq -r '.global.sumActualHours')"    "23"
    assert_eq "$(printf '%s' "$_JSON" | jq -r '.buckets | length')"      "4"
    assert_eq "$(printf '%s' "$_JSON" | jq -r '.buckets[2].handicap')"   "0.83"
    [ "$_FAIL" -eq "$_case2_fail_before" ] && test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# Case 3: human table renders key rows
# ─────────────────────────────────────────────────────────────────────────────
test_start "kb-variance human table renders global + bucket rows"
_HUMAN=$(_run_variance --board-file "$_FIXTURE")
assert_contains "$_HUMAN" "Estimate-vs-Actual Handicap"
assert_contains "$_HUMAN" "Eligible items: 4"
assert_contains "$_HUMAN" "Global weighted handicap : 1.21"
assert_contains "$_HUMAN" "<=1h"
assert_contains "$_HUMAN" ">8h"
test_pass

# ─────────────────────────────────────────────────────────────────────────────
# Case 4: empty-state path
# ─────────────────────────────────────────────────────────────────────────────
test_start "kb-variance prints empty-state when no eligible items"
_EMPTYOUT=$(_run_variance --board-file "$_EMPTY")
assert_contains "$_EMPTYOUT" "Not enough tracked data yet"
test_pass

# ─────────────────────────────────────────────────────────────────────────────
# Case 5: --help path
# ─────────────────────────────────────────────────────────────────────────────
test_start "kb-variance --help prints usage"
_HELP=$(_run_variance --help)
assert_contains "$_HELP" "Estimate-vs-actual handicap analytics"
assert_contains "$_HELP" "Usage: kb-variance"
test_pass

# ─────────────────────────────────────────────────────────────────────────────
# Case 6: kb-help advertises kb-variance
# ─────────────────────────────────────────────────────────────────────────────
test_start "kb-help lists kb-variance under Reporting / Analytics"
_KBHELP=$(bash -c "source '$ALIASES_PATH' >/dev/null 2>&1; kb-help" 2>/dev/null)
assert_contains "$_KBHELP" "kb-variance"
test_pass

# ─────────────────────────────────────────────────────────────────────────────
# Case 7 (conditional): sibling-drift guard vs the dev canonical.
# Only runs on a dev-team checkout where kanban-helpers.sh is reachable; on a
# consumer tap checkout this is skipped (the file won't exist there).
# ─────────────────────────────────────────────────────────────────────────────
_DEV_HELPERS=""
for cand in \
    "$HOME/dev-team/kanban-helpers.sh" \
    "$TAP_ROOT/../kanban-helpers.sh"; do
    [ -f "$cand" ] && { _DEV_HELPERS="$cand"; break; }
done

# Both implementations' real runtime is zsh (the template is `#!/bin/zsh`,
# sourced into the user's interactive zsh; dev kanban-helpers.sh is zsh-only and
# does not define its functions under bash). Compare zsh-vs-zsh.
test_start "tap kb-variance --json == dev kb-variance --json (sibling-drift guard)"
if [ -z "$_DEV_HELPERS" ]; then
    printf "  SKIP: dev kanban-helpers.sh not reachable (consumer tap checkout)\n"
elif ! command -v zsh >/dev/null 2>&1; then
    printf "  SKIP: zsh not available — parity comparison requires the real runtime shell\n"
else
    _TAP_JSON=$(zsh -c "source '$ALIASES_PATH' >/dev/null 2>&1; kb-variance --json --board-file '$_FIXTURE'" 2>/dev/null | grep -v generatedAt)
    _DEV_JSON=$(zsh -c "source '$_DEV_HELPERS' >/dev/null 2>&1; kb-variance --json --board-file '$_FIXTURE'" 2>/dev/null | grep -v generatedAt)
    if [ -n "$_TAP_JSON" ] && [ "$_TAP_JSON" = "$_DEV_JSON" ]; then
        test_pass
    else
        test_fail "tap and dev kb-variance --json diverged — re-sync the port"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────"
echo "  kb-variance drift test:  PASS=$_PASS  FAIL=$_FAIL"
echo "──────────────────────────────────────────────"
[ "$_FAIL" -eq 0 ] || exit 1
exit 0
