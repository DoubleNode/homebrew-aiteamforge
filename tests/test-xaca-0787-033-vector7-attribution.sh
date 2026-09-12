#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# XACA-0787-033 — Vector 7 (real team-paths.json registry leak guard):
# prove it actually fires, and does so IN CI.
# ═══════════════════════════════════════════════════════════════════════════
# DEFECT this guards against: vector 7 (XACA-0787 recurrence #4, round 5)
# shipped with no automated test proving it ever trips. Worse, it is
# STRUCTURALLY UNREACHABLE on a CI runner: CI has no real
# ~/.aiteamforge/team-paths.json, so both the "before" and "after"
# fingerprint snapshots read __absent__ and the content-change check can
# never fire there — "vector 7 fires" was, until this suite, a local manual
# claim only. That is precisely the defect class round 4 of this same
# ticket already found once (the bats guard was blind on Linux, the only
# platform actually running it in CI) — repeating it here would be
# especially poor.
#
# PR #859 round-6 review also found two adjacent defects in vector 7 itself,
# both covered below:
#   XACA-0787-031  a real registry write during the bracketed window is not
#                  proof THIS suite caused it on a shared machine — round 5
#                  shipped vector 7 with a hard fail and no attributability
#                  split, the exact false-positive shape vector 6 already
#                  had to be split for (rounds 3-4). Fixed by
#                  _leak_guard_suite_touches_team_paths(): attributable ->
#                  hard fail; not attributable -> reported loudly, never
#                  silently, but does not fail the run.
#   XACA-0787-032  a backup-count SHRINK was silently swallowed (`-gt` only,
#                  no `-lt` arm) — a test that DELETES real backup history
#                  produced no message and no trip. Fixed: shrink always
#                  reports AND always trips, regardless of attribution (no
#                  production code path prunes this backup family, so there
#                  is no legitimate concurrent-session explanation for one).
#
# HOW THIS RUNS IN CI WITHOUT A REAL REGISTRY: vector 7's watched directory
# is read through the indirection variable _LEAK_GUARD_AITEAMFORGE_DIR
# (defaults to the real $HOME/.aiteamforge — production behavior UNCHANGED;
# see that variable's own header comment in test-runner.sh). This suite
# points it at a throwaway fixture directory per case and drives the REAL
# runner (`bash test-runner.sh <stub>`) end to end — leak_guard_snapshot,
# the stub's own mutation, and leak_guard_assert all run for real, just
# against a fixture instead of $HOME. The assertion is real on a bare CI
# runner precisely because it never depends on a real registry existing.
#
# Cases (each spawns the REAL runner against a throwaway one-line stub):
#   A  ATTRIBUTABLE-CONTENT-CHANGE-TRIPS       — content change, stub names
#                                                 an entry point -> hard fail
#   B  UNATTRIBUTED-CONTENT-CHANGE-REPORTS     — content change, stub names
#                                                 nothing -> reported, NOT
#                                                 failed (the "concurrent
#                                                 unrelated session" case
#                                                 vector 7 previously
#                                                 false-positived on)
#   C  ATTRIBUTABLE-BACKUP-GROWTH-TRIPS        — backup family grows,
#                                                 attributable -> hard fail
#   D  UNATTRIBUTED-BACKUP-GROWTH-REPORTS      — backup family grows, NOT
#                                                 attributable -> reported,
#                                                 NOT failed
#   E  BACKUP-SHRINK-ALWAYS-TRIPS              — backup family SHRINKS, NOT
#                                                 attributable -> hard fail
#                                                 anyway (XACA-0787-032's own
#                                                 regression test — the most
#                                                 important case here)
#   F  CLEAN-RUN-NO-VECTOR7-NOISE              — fixture untouched -> no
#                                                 vector-7 LEAK line at all
#   G  EMPTY-EVIDENCE-FAILS-CLOSED             — CURRENT_TEST_FILE unset/no
#                                                 suite file -> attribution
#                                                 helper returns "not
#                                                 attributable", never
#                                                 guesses yes from nothing
#                                                 (the empty-value glob bug
#                                                 class this ticket is
#                                                 about, guarded directly)
#
# All fixtures/stubs live under an mktemp sandbox, trap-cleaned. This suite
# NEVER touches the real $HOME/.aiteamforge — every case redirects vector 7
# via _LEAK_GUARD_AITEAMFORGE_DIR before invoking the runner. Enrolled in
# tests/ci-manifest as plain-shell (see that file).
# ═══════════════════════════════════════════════════════════════════════════

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/test-runner.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  ${RED}✗${NC} FAIL: $1" >&2; }
section() { echo ""; echo -e "${BLUE}${BOLD}── $1 ──${NC}"; }

SANDBOX=""
cleanup() {
  if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}
trap cleanup EXIT INT TERM

SANDBOX=$(mktemp -d -t xaca0787033-vector7.XXXXXX)

section "Preconditions"

if [ -f "$RUNNER" ]; then
  pass "runner under test found: $(basename "$RUNNER")"
else
  fail "runner under test not found: $RUNNER"
  echo "" && echo -e "${RED}Cannot continue without the runner.${NC}"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────
# Helper: run one case. Args:
#   $1  case label (for messages)
#   $2  fixture dir (becomes _LEAK_GUARD_AITEAMFORGE_DIR for this invocation)
#   $3  stub script BODY (appended after the shebang; runs with
#       _LEAK_GUARD_AITEAMFORGE_DIR/TEST_DIR already in its environment)
#   $4  1 if the stub should be "attributable" (its own source names an
#       entry point vector 7's attribution grep recognizes), 0 otherwise
# Writes the stub into $SANDBOX (so TEST_DIR=$SANDBOX makes the attribution
# grep target — $TEST_DIR/$CURRENT_TEST_FILE — resolve to this exact file),
# invokes the REAL runner against it, and captures combined output + exit
# code into globals CASE_OUT / CASE_RC for the caller to assert against.
# ─────────────────────────────────────────────────────────────────────────
CASE_OUT=""
CASE_RC=0
_run_case() {
  local label="$1" fixture_dir="$2" stub_body="$3" attributable="$4"
  local stub_name stub_path
  if [ "$attributable" = "1" ]; then
    stub_name="stub-${label}-attr.sh"
  else
    stub_name="stub-${label}-unattr.sh"
  fi
  stub_path="$SANDBOX/$stub_name"

  {
    echo '#!/bin/bash'
    if [ "$attributable" = "1" ]; then
      # Names an entry point vector 7's attribution grep recognizes, without
      # actually invoking anything real — the grep only inspects source text.
      echo '# This suite would drive install-team.sh against team-paths.json.'
    else
      echo '# This suite has nothing to do with any registry.'
    fi
    echo "$stub_body"
    echo 'exit 0'
  } > "$stub_path"
  chmod +x "$stub_path"

  CASE_RC=0
  CASE_OUT="$(TEST_DIR="$SANDBOX" _LEAK_GUARD_AITEAMFORGE_DIR="$fixture_dir" bash "$RUNNER" "$stub_path" 2>&1)" || CASE_RC=$?
}

# ═══════════════════════════════════════════════════════════════════════════
section "Case A — attributable content change trips the guard"
# ═══════════════════════════════════════════════════════════════════════════
FIX_A="$SANDBOX/fixture-a"
mkdir -p "$FIX_A"
echo '{"v":1}' > "$FIX_A/team-paths.json"

_run_case "case-a" "$FIX_A" \
  'echo "{\"v\":2}" > "$_LEAK_GUARD_AITEAMFORGE_DIR/team-paths.json"' \
  1

if printf '%s' "$CASE_OUT" | grep -aqF 'LEAK [team-paths] '; then
  pass "A1: attributed content-change LEAK line printed"
else
  fail "A1: expected 'LEAK [team-paths] ' in output, got: $CASE_OUT"
fi
if [ "$CASE_RC" -ne 0 ]; then
  pass "A2: runner exited non-zero (rc=$CASE_RC) for an attributable content change"
else
  fail "A2: runner exited 0 — vector 7 did NOT trip for an attributable content change"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "Case B — unattributed content change reports but does NOT trip"
# ═══════════════════════════════════════════════════════════════════════════
FIX_B="$SANDBOX/fixture-b"
mkdir -p "$FIX_B"
echo '{"v":1}' > "$FIX_B/team-paths.json"

_run_case "case-b" "$FIX_B" \
  '_t1=team-paths; _t2=json; echo "{\"v\":2}" > "$_LEAK_GUARD_AITEAMFORGE_DIR/${_t1}.${_t2}"' \
  0

if printf '%s' "$CASE_OUT" | grep -aqF 'LEAK [team-paths:unattributed]'; then
  pass "B1: unattributed content-change LEAK line printed (reported loudly)"
else
  fail "B1: expected 'LEAK [team-paths:unattributed]' in output, got: $CASE_OUT"
fi
if printf '%s' "$CASE_OUT" | grep -aqF 'LEAK [team-paths] '; then
  fail "B2: the ATTRIBUTED variant fired for a suite with no attributing evidence — attribution gate is not working"
else
  pass "B2: the attributed 'LEAK [team-paths] ' line did NOT fire for an unattributed suite"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "Case C — attributable backup-family growth trips the guard"
# ═══════════════════════════════════════════════════════════════════════════
FIX_C="$SANDBOX/fixture-c"
mkdir -p "$FIX_C"

_run_case "case-c" "$FIX_C" \
  'touch "$_LEAK_GUARD_AITEAMFORGE_DIR/team-paths.json.bak-xaca0463-installer-20260911T000000Z"' \
  1

if printf '%s' "$CASE_OUT" | grep -aqF 'LEAK [team-paths-backup-growth]'; then
  pass "C1: attributed backup-growth LEAK line printed"
else
  fail "C1: expected 'LEAK [team-paths-backup-growth]' in output, got: $CASE_OUT"
fi
if [ "$CASE_RC" -ne 0 ]; then
  pass "C2: runner exited non-zero (rc=$CASE_RC) for attributable backup growth"
else
  fail "C2: runner exited 0 — vector 7 did NOT trip for attributable backup growth"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "Case D — unattributed backup-family growth reports but does NOT trip"
# ═══════════════════════════════════════════════════════════════════════════
FIX_D="$SANDBOX/fixture-d"
mkdir -p "$FIX_D"

_run_case "case-d" "$FIX_D" \
  '_t1=team-paths; _t2=json; touch "$_LEAK_GUARD_AITEAMFORGE_DIR/${_t1}.${_t2}.bak-xaca0463-installer-20260911T000000Z"' \
  0

if printf '%s' "$CASE_OUT" | grep -aqF 'LEAK [team-paths-backup-growth:unattributed]'; then
  pass "D1: unattributed backup-growth LEAK line printed (reported loudly)"
else
  fail "D1: expected 'LEAK [team-paths-backup-growth:unattributed]' in output, got: $CASE_OUT"
fi
if printf '%s' "$CASE_OUT" | grep -aqF 'LEAK [team-paths-backup-growth]'; then
  fail "D2: the ATTRIBUTED growth variant fired for a suite with no attributing evidence"
else
  pass "D2: the attributed growth line did NOT fire for an unattributed suite"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "Case E — backup-family SHRINK ALWAYS trips, even unattributed (XACA-0787-032)"
# ═══════════════════════════════════════════════════════════════════════════
FIX_E="$SANDBOX/fixture-e"
mkdir -p "$FIX_E"
touch "$FIX_E/team-paths.json.bak-xaca0463-installer-20260910T000000Z"

_run_case "case-e" "$FIX_E" \
  '_t1=team-paths; _t2=json; rm -f "$_LEAK_GUARD_AITEAMFORGE_DIR"/"${_t1}.${_t2}".bak-xaca0463-installer-*' \
  0

if printf '%s' "$CASE_OUT" | grep -aqF 'LEAK [team-paths-backup-shrink]'; then
  pass "E1: backup-shrink LEAK line printed for an UNATTRIBUTED suite (this is the round-5 defect: previously silently swallowed)"
else
  fail "E1: expected 'LEAK [team-paths-backup-shrink]' in output even though this suite is not attributable, got: $CASE_OUT"
fi
if [ "$CASE_RC" -ne 0 ]; then
  pass "E2: runner exited non-zero (rc=$CASE_RC) for a backup shrink — trips regardless of attribution"
else
  fail "E2: runner exited 0 — backup-family shrink did NOT trip the guard (XACA-0787-032 regression)"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "Case F — clean run produces no vector-7 noise at all"
# ═══════════════════════════════════════════════════════════════════════════
FIX_F="$SANDBOX/fixture-f"
mkdir -p "$FIX_F"
echo '{"v":1}' > "$FIX_F/team-paths.json"
touch "$FIX_F/team-paths.json.bak-xaca0463-installer-20260910T000000Z"

_run_case "case-f" "$FIX_F" ':' 1

if printf '%s' "$CASE_OUT" | grep -aq 'team-paths'; then
  fail "F1: a clean run (fixture untouched) still printed a team-paths LEAK/report line: $CASE_OUT"
else
  pass "F1: a clean run produced no team-paths output at all"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "Case G — no evidence fails CLOSED, never invents attribution"
# ═══════════════════════════════════════════════════════════════════════════
# Direct unit check of _leak_guard_suite_touches_team_paths() in isolation —
# sourcing test-runner.sh propagates its `set -eo pipefail`, so this is
# isolated in its own subshell/bash -c the way the rest of this codebase
# does it (see feedback_verify_under_bin_bash_not_path_bash.md's sibling
# guidance on sourcing this file).
g_result="$(
  bash -c '
    source "'"$RUNNER"'"
    unset CURRENT_TEST_FILE
    unset TEST_DIR
    if _leak_guard_suite_touches_team_paths; then
      echo "ATTRIBUTABLE"
    else
      echo "NOT_ATTRIBUTABLE"
    fi
  ' 2>&1
)"
if [ "$g_result" = "NOT_ATTRIBUTABLE" ]; then
  pass "G1: unset CURRENT_TEST_FILE/TEST_DIR -> not attributable (fails closed, invents nothing)"
else
  fail "G1: expected NOT_ATTRIBUTABLE with no evidence, got: $g_result"
fi

# ─────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}${BOLD}  XACA-0787-033 vector 7 attribution — Summary${NC}"
echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}Passed: $PASS${NC}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "  ${RED}Failed: $FAIL${NC}"
else
  echo -e "  Failed: $FAIL"
fi
echo ""

# XACA-0787-033 (PR #859 round-6 review): VACUITY FLOOR. Without this, a run in
# which no check executed at all leaves PASS=0 and FAIL=0 and falls into the
# success branch below — green on zero verification, which is precisely the
# defect class this entire ticket exists to eliminate. A suite that verifies
# nothing must never report success. EXPECTED_CHECKS is asserted rather than
# merely floored so that silently DROPPING a case is caught too, not just
# dropping all of them.
EXPECTED_CHECKS=13
if [ "$(( PASS + FAIL ))" -ne "$EXPECTED_CHECKS" ]; then
  echo -e "${RED}${BOLD}✗ VACUITY: ran $(( PASS + FAIL )) check(s), expected ${EXPECTED_CHECKS}. Either a case was dropped or the suite aborted early — refusing to report a result on an incomplete run.${NC}"
  echo ""
  exit 1
fi

if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}✓ All ${EXPECTED_CHECKS} XACA-0787-033 vector-7 attribution checks passed.${NC}"
  echo ""
  exit 0
else
  echo -e "${RED}${BOLD}✗ $FAIL check(s) failed — vector 7 attribution regressed.${NC}"
  echo ""
  exit 1
fi
