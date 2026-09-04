#!/bin/bash
# test-xaca-0632-kb-variance.sh
# Drift-detection test for the kb-variance estimate-vs-actual handicap reporter
# in the SHIPPED tap helper files.
#
# Context (XACA-0632): kb-variance was ported into the tap aliases template so
# installed-tap users have the CLI alongside the LCARS variance panel. The
# canonical implementation still lives in dev-team's kanban-helpers.sh.
#
# XACA-1095-007 fix (this revision) — two defects found while investigating a
# vacuous-green report ("kb-variance drift test: PASS=0 FAIL=0" under
# test-runner.sh, despite 7 real assertions running):
#
#   1. VACUOUS OWN-SUMMARY LINE. This file keeps a local _PASS/_FAIL tally and
#      only defines its OWN test_start/test_pass/test_fail fallbacks when the
#      runner hasn't already exported those names (`if ! declare -F
#      test_start`). Under test-runner.sh the runner's real functions ARE
#      already exported, so the local fallbacks — and therefore _PASS/_FAIL —
#      were never touched, even though every case ran and passed via the
#      runner's own functions (confirmed: `test-runner.sh -v` on this file
#      alone reports "Total Tests: 7 / Passed: 7", i.e. the runner's own
#      aggregate was NEVER vacuous). Only this script's OWN trailing summary
#      line was wrong — it unconditionally printed the local counters
#      regardless of which harness actually ran. Fixed by adopting the
#      _STANDALONE convention already used elsewhere in this suite (see
#      test-xaca-0564-kanban-helpers-overwrite-guard.sh): the local tally and
#      its printed summary exist ONLY for a bare `bash tests/test-xaca-0632-
#      ...sh` run; under test-runner.sh the runner's own exported functions
#      and its own summary are authoritative, and this file no longer prints
#      a second, ownership-confused, always-zero one.
#
#   2. WRONG SHIPPED FILE. This test's ALIASES_PATH pointed only at
#      share/templates/aliases/kanban-aliases.sh. XACA-1095 flipped both
#      install_kanban_helpers() and update_shell_helpers() to PREFER
#      share/templates/kanban/kanban-helpers.template.sh — a real consumer
#      install/upgrade now receives the template, not kanban-aliases.sh,
#      whenever the template is present (which is unconditional in a real
#      tap payload). A drift test that only watched the fallback file was no
#      longer covering what actually ships. Fixed by adding PART A below,
#      which runs the full case set against the template FIRST (as the
#      primary, ship-accurate target) — the pre-existing aliases coverage is
#      kept as PART B, retained because: (a) kanban-aliases.sh is still a
#      real shipped fallback (selected when the template is absent) and (b)
#      several sibling tests (test-xaca-0649-kanban-dir-resolver.sh,
#      test-kb-quarantine-stub.sh, test-xaca-0746/0770/0831/0819) already
#      depend on kanban-aliases.sh directly for unrelated contracts, so this
#      file dropping its own aliases coverage would silently narrow the only
#      place kb-variance-in-the-fallback-file is exercised.
#
# What this test pins for BOTH files:
#   - the function is present and runnable in the shipped file
#   - --json emits the spec §7 payload with deterministic, spec-anchored values
#   - human / empty-state / --help paths render
#   - kb-help advertises kb-variance
#   - (when reachable) the shipped copy's --json is byte-identical to the dev
#     canonical, catching sibling-drift before it ships
#
# Runtime shell note: BOTH share/templates/kanban/kanban-helpers.template.sh
# and share/templates/aliases/kanban-aliases.sh are zsh-only (`#!/bin/zsh`,
# zsh glob-qualifier syntax that bash's parser rejects outright). Sourcing the
# template under bash aborts at a syntax error BEFORE reaching kb-variance()'s
# definition at all (verified: bash -c source on the template dies at an
# earlier `fi` with no kb-variance defined). Sourcing kanban-aliases.sh under
# bash happens to leave kb-variance defined only because its own break point
# falls after kb-variance's definition but before kb-help's — the exact
# "pre-existing test bug" this file's original Case 6 comment already flagged
# for kb-help. Rather than keep relying on that coincidence for cases 1-5,
# every invocation below (both files) now runs under zsh — the real runtime
# shell both files are actually written for and sourced by.
#
# Designed to run standalone OR via test-runner.sh.
# Exit 0 = all cases pass.  Exit 1 = at least one case failed (standalone only
# — see the _STANDALONE note above for why non-standalone always exits 0 and
# relies on the runner's own FAIL: aggregation instead).

set -o pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Locate the SHIPPED files under test.
# Source-of-truth is kanban-helpers.sh in dev-team; both files below are tap
# copies of it (or, for kanban-aliases.sh, a curated subset).
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="$TAP_ROOT/share/templates/kanban/kanban-helpers.template.sh"
ALIASES_PATH="$TAP_ROOT/share/templates/aliases/kanban-aliases.sh"

if ! command -v zsh >/dev/null 2>&1; then
    echo "FATAL: zsh not available — both shipped files under test are zsh-only." >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: provide fallbacks ONLY when test-runner.sh has not
# already exported the real harness functions, and keep our OWN pass/fail
# counters ONLY in that standalone case. (Pattern mirrors
# test-xaca-0564-kanban-helpers-overwrite-guard.sh — this file previously
# diverged from that convention, which is what produced the vacuous
# "PASS=0 FAIL=0" own-summary line under the runner; see header comment.)
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
_PASS=0
_FAIL=0
_CURRENT_TEST=""
if ! declare -F test_start &>/dev/null; then
    _STANDALONE=true

    test_start() { _CURRENT_TEST="$1"; printf "TEST: %s\n" "$1"; }
    test_pass()  { _PASS=$((_PASS + 1)); printf "  PASS: %s\n" "$_CURRENT_TEST"; }
    test_fail()  { _FAIL=$((_FAIL + 1)); printf "  FAIL: %s — %s\n" "$_CURRENT_TEST" "${1:-}" >&2; }
fi

# Current failure count, regardless of which harness is active: this file's
# own _FAIL tally in standalone mode (see above — under the runner it is
# declared but never incremented, since the RUNNER's own test_fail is what
# actually runs), or a live count of "FAIL:" lines the runner has recorded
# to $TEST_RESULTS_FILE so far when running under test-runner.sh. Used below
# to guard a multi-assertion case's trailing test_pass on "no new failures
# since this case started" in BOTH contexts — without this, the pre-existing
# pattern of an unconditional test_pass after several assert_contains calls
# would silently count a genuine failure as a pass too (assert_contains only
# calls test_fail on mismatch; it never skips the test_pass that follows it).
_fail_count_now() {
    if [ "$_STANDALONE" = true ]; then
        printf '%s' "$_FAIL"
    elif [ -n "${TEST_RESULTS_FILE:-}" ] && [ -f "${TEST_RESULTS_FILE:-/nonexistent}" ]; then
        # NOTE: `grep -c` exits 1 (while still printing "0") when there are
        # no matches — piping it into `cmd || printf '0'` would run BOTH
        # branches on a zero count and emit "0\n0", corrupting the later
        # `-eq` comparison ("0\n0: integer expected"). Capture the count
        # first; only fall back if it came back empty (e.g. grep itself
        # failed to run), never based on grep's exit status.
        local _c
        _c="$(grep -c '^FAIL:' "$TEST_RESULTS_FILE" 2>/dev/null)"
        printf '%s' "${_c:-0}"
    else
        printf '0'
    fi
}
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

# Hard-stop on missing files — nothing else can be tested.
if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "FATAL: Shipped template not found at: $TEMPLATE_PATH" >&2
    echo "  This test must run from inside the homebrew-tap checkout." >&2
    exit 1
fi
if [ ! -f "$ALIASES_PATH" ]; then
    echo "FATAL: Shipped aliases file not found at: $ALIASES_PATH" >&2
    echo "  This test must run from inside the homebrew-tap checkout." >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Deterministic fixture (spec-anchored values) — shared by both PART A and B.
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

# Source a shipped file under zsh (the real runtime shell for both — see
# header note) and run kb-variance. --board-file bypasses team resolution so
# no sandbox HOME is needed.
_run_variance() {
    local shipped_file="$1"; shift
    zsh -c "source '$shipped_file' >/dev/null 2>&1; kb-variance $*" 2>/dev/null
}

# ═════════════════════════════════════════════════════════════════════════════
# PART A — kanban-helpers.template.sh (PRIMARY)
# This is what a real install/upgrade actually renders into a consumer's
# kanban-helpers.sh as of XACA-1095 (install_kanban_helpers /
# update_shell_helpers both prefer this file over kanban-aliases.sh whenever
# it is present, which is unconditional in a real tap payload).
# ═════════════════════════════════════════════════════════════════════════════

test_start "[template] kb-variance is defined in kanban-helpers.template.sh"
if grep -q '^kb-variance()' "$TEMPLATE_PATH"; then test_pass; else test_fail "no kb-variance() definition"; fi

test_start "[template] kb-variance --json emits spec §7 payload with expected values"
_TA_JSON=$(_run_variance "$TEMPLATE_PATH" --json --board-file "$_FIXTURE")
if ! printf '%s' "$_TA_JSON" | jq -e . >/dev/null 2>&1; then
    test_fail "output is not valid JSON: $_TA_JSON"
else
    _caseA2_fail_before=$(_fail_count_now)
    assert_eq "$(printf '%s' "$_TA_JSON" | jq -r '.eligible')"            "4"
    assert_eq "$(printf '%s' "$_TA_JSON" | jq -r '.excluded.no_estimate')" "1"
    assert_eq "$(printf '%s' "$_TA_JSON" | jq -r '.excluded.no_time')"     "1"
    assert_eq "$(printf '%s' "$_TA_JSON" | jq -r '.excluded.both_missing')" "1"
    assert_eq "$(printf '%s' "$_TA_JSON" | jq -r '.excluded.total')"        "3"
    assert_eq "$(printf '%s' "$_TA_JSON" | jq -r '.global.handicap')"       "1.21"
    assert_eq "$(printf '%s' "$_TA_JSON" | jq -r '.global.median')"         "1.32"
    assert_eq "$(printf '%s' "$_TA_JSON" | jq -r '.global.sumEstimatedHours')" "19"
    assert_eq "$(printf '%s' "$_TA_JSON" | jq -r '.global.sumActualHours')"    "23"
    assert_eq "$(printf '%s' "$_TA_JSON" | jq -r '.buckets | length')"      "4"
    assert_eq "$(printf '%s' "$_TA_JSON" | jq -r '.buckets[2].handicap')"   "0.83"
    [ "$(_fail_count_now)" -eq "$_caseA2_fail_before" ] && test_pass
fi

test_start "[template] kb-variance human table renders global + bucket rows"
_TA_HUMAN=$(_run_variance "$TEMPLATE_PATH" --board-file "$_FIXTURE")
_caseA3_fail_before=$(_fail_count_now)
assert_contains "$_TA_HUMAN" "Estimate-vs-Actual Handicap"
assert_contains "$_TA_HUMAN" "Eligible items: 4"
assert_contains "$_TA_HUMAN" "Global weighted handicap : 1.21"
assert_contains "$_TA_HUMAN" "<=1h"
assert_contains "$_TA_HUMAN" ">8h"
[ "$(_fail_count_now)" -eq "$_caseA3_fail_before" ] && test_pass

test_start "[template] kb-variance prints empty-state when no eligible items"
_TA_EMPTYOUT=$(_run_variance "$TEMPLATE_PATH" --board-file "$_EMPTY")
_caseA4_fail_before=$(_fail_count_now)
assert_contains "$_TA_EMPTYOUT" "Not enough tracked data yet"
[ "$(_fail_count_now)" -eq "$_caseA4_fail_before" ] && test_pass

test_start "[template] kb-variance --help prints usage"
_TA_HELP=$(_run_variance "$TEMPLATE_PATH" --help)
_caseA5_fail_before=$(_fail_count_now)
assert_contains "$_TA_HELP" "Estimate-vs-actual handicap analytics"
assert_contains "$_TA_HELP" "Usage: kb-variance"
[ "$(_fail_count_now)" -eq "$_caseA5_fail_before" ] && test_pass

test_start "[template] kb-help lists kb-variance under Reporting / Analytics"
_TA_KBHELP=$(zsh -c "source '$TEMPLATE_PATH' >/dev/null 2>&1; kb-help" 2>/dev/null)
_caseA6_fail_before=$(_fail_count_now)
assert_contains "$_TA_KBHELP" "kb-variance"
[ "$(_fail_count_now)" -eq "$_caseA6_fail_before" ] && test_pass

# Sibling-drift guard vs the dev canonical. This is now the PRIMARY drift
# guard (the template is what ships) — only runs on a dev-team checkout where
# kanban-helpers.sh is reachable; on a consumer tap checkout this is skipped
# (the file won't exist there).
_DEV_HELPERS=""
for cand in \
    "$HOME/dev-team/kanban-helpers.sh" \
    "$TAP_ROOT/../kanban-helpers.sh"; do
    [ -f "$cand" ] && { _DEV_HELPERS="$cand"; break; }
done

test_start "[template] tap kb-variance --json == dev kb-variance --json (sibling-drift guard)"
if [ -z "$_DEV_HELPERS" ]; then
    printf "  SKIP: dev kanban-helpers.sh not reachable (consumer tap checkout)\n"
else
    _TA_TAP_JSON=$(zsh -c "source '$TEMPLATE_PATH' >/dev/null 2>&1; kb-variance --json --board-file '$_FIXTURE'" 2>/dev/null | grep -v generatedAt)
    _TA_DEV_JSON=$(zsh -c "source '$_DEV_HELPERS' >/dev/null 2>&1; kb-variance --json --board-file '$_FIXTURE'" 2>/dev/null | grep -v generatedAt)
    if [ -n "$_TA_TAP_JSON" ] && [ "$_TA_TAP_JSON" = "$_TA_DEV_JSON" ]; then
        test_pass
    else
        test_fail "template and dev kb-variance --json diverged — re-sync the port"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# PART B — kanban-aliases.sh (fallback surface)
# Still shipped and still selected by install_kanban_helpers /
# update_shell_helpers whenever the template is ABSENT, and still targeted
# directly by several sibling tests for unrelated contracts (kb-quarantine-
# stub, kanban-dir-resolver, knowledge-in-tap, alloc-slot-atomicity,
# pause-resume-active-span) — kept here so kb-variance-in-the-fallback-file
# has at least one place watching it for drift too.
# ═════════════════════════════════════════════════════════════════════════════

test_start "[aliases] kb-variance is defined in the shipped aliases file"
if grep -q '^kb-variance()' "$ALIASES_PATH"; then test_pass; else test_fail "no kb-variance() definition"; fi

test_start "[aliases] kb-variance --json emits spec §7 payload with expected values"
_TB_JSON=$(_run_variance "$ALIASES_PATH" --json --board-file "$_FIXTURE")
if ! printf '%s' "$_TB_JSON" | jq -e . >/dev/null 2>&1; then
    test_fail "output is not valid JSON: $_TB_JSON"
else
    _caseB2_fail_before=$(_fail_count_now)
    assert_eq "$(printf '%s' "$_TB_JSON" | jq -r '.eligible')"            "4"
    assert_eq "$(printf '%s' "$_TB_JSON" | jq -r '.excluded.no_estimate')" "1"
    assert_eq "$(printf '%s' "$_TB_JSON" | jq -r '.excluded.no_time')"     "1"
    assert_eq "$(printf '%s' "$_TB_JSON" | jq -r '.excluded.both_missing')" "1"
    assert_eq "$(printf '%s' "$_TB_JSON" | jq -r '.excluded.total')"        "3"
    assert_eq "$(printf '%s' "$_TB_JSON" | jq -r '.global.handicap')"       "1.21"
    assert_eq "$(printf '%s' "$_TB_JSON" | jq -r '.global.median')"         "1.32"
    assert_eq "$(printf '%s' "$_TB_JSON" | jq -r '.global.sumEstimatedHours')" "19"
    assert_eq "$(printf '%s' "$_TB_JSON" | jq -r '.global.sumActualHours')"    "23"
    assert_eq "$(printf '%s' "$_TB_JSON" | jq -r '.buckets | length')"      "4"
    assert_eq "$(printf '%s' "$_TB_JSON" | jq -r '.buckets[2].handicap')"   "0.83"
    [ "$(_fail_count_now)" -eq "$_caseB2_fail_before" ] && test_pass
fi

test_start "[aliases] kb-variance human table renders global + bucket rows"
_TB_HUMAN=$(_run_variance "$ALIASES_PATH" --board-file "$_FIXTURE")
_caseB3_fail_before=$(_fail_count_now)
assert_contains "$_TB_HUMAN" "Estimate-vs-Actual Handicap"
assert_contains "$_TB_HUMAN" "Eligible items: 4"
assert_contains "$_TB_HUMAN" "Global weighted handicap : 1.21"
assert_contains "$_TB_HUMAN" "<=1h"
assert_contains "$_TB_HUMAN" ">8h"
[ "$(_fail_count_now)" -eq "$_caseB3_fail_before" ] && test_pass

test_start "[aliases] kb-variance prints empty-state when no eligible items"
_TB_EMPTYOUT=$(_run_variance "$ALIASES_PATH" --board-file "$_EMPTY")
_caseB4_fail_before=$(_fail_count_now)
assert_contains "$_TB_EMPTYOUT" "Not enough tracked data yet"
[ "$(_fail_count_now)" -eq "$_caseB4_fail_before" ] && test_pass

test_start "[aliases] kb-variance --help prints usage"
_TB_HELP=$(_run_variance "$ALIASES_PATH" --help)
_caseB5_fail_before=$(_fail_count_now)
assert_contains "$_TB_HELP" "Estimate-vs-actual handicap analytics"
assert_contains "$_TB_HELP" "Usage: kb-variance"
[ "$(_fail_count_now)" -eq "$_caseB5_fail_before" ] && test_pass

test_start "[aliases] kb-help lists kb-variance under Reporting / Analytics"
_TB_KBHELP=$(zsh -c "source '$ALIASES_PATH' >/dev/null 2>&1; kb-help" 2>/dev/null)
_caseB6_fail_before=$(_fail_count_now)
assert_contains "$_TB_KBHELP" "kb-variance"
[ "$(_fail_count_now)" -eq "$_caseB6_fail_before" ] && test_pass

test_start "[aliases] tap kb-variance --json == dev kb-variance --json (sibling-drift guard)"
if [ -z "$_DEV_HELPERS" ]; then
    printf "  SKIP: dev kanban-helpers.sh not reachable (consumer tap checkout)\n"
else
    _TB_TAP_JSON=$(zsh -c "source '$ALIASES_PATH' >/dev/null 2>&1; kb-variance --json --board-file '$_FIXTURE'" 2>/dev/null | grep -v generatedAt)
    _TB_DEV_JSON=$(zsh -c "source '$_DEV_HELPERS' >/dev/null 2>&1; kb-variance --json --board-file '$_FIXTURE'" 2>/dev/null | grep -v generatedAt)
    if [ -n "$_TB_TAP_JSON" ] && [ "$_TB_TAP_JSON" = "$_TB_DEV_JSON" ]; then
        test_pass
    else
        test_fail "aliases and dev kb-variance --json diverged — re-sync the port"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone mode only — test-runner.sh tallies pass/fail from its
# OWN exported functions' output; printing a second, locally-tallied summary
# in that mode is exactly what produced the vacuous "PASS=0 FAIL=0" line this
# revision fixes — see header comment).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "──────────────────────────────────────────────"
    echo "  kb-variance drift test:  PASS=$_PASS  FAIL=$_FAIL"
    echo "──────────────────────────────────────────────"
    [ "$_FAIL" -eq 0 ] || exit 1
fi
exit 0
