#!/bin/bash
# test-xaca-0819-pause-resume-active-span.sh
#
# XACA-0819: ports the pause/resume active-span sync (XACA-0551) from
# canonical dev-team/kanban-helpers.sh into the tap-shipped template
# share/templates/kanban/kanban-helpers.template.sh.
#
# Problem this closes: a pause ends the current active work span, but before
# this change, kb-pause left `workStartedAt` untouched and never banked the
# elapsed time into `timeWorkedMs`. kb-resume then unconditionally overwrote
# `workStartedAt` with a fresh timestamp on the NEXT resume, silently
# DESTROYING the entire pre-pause span (measured: a ~9h span vanished on one
# pause/resume cycle -- see the ticket's evidence).
#
# XACA-0819-014 RETIRED (XACA-1151 PR-C, this revision). PR #756's review
# narrowed the original fix to SUBITEMS ONLY, because at the time this
# template's ITEM level had no counterpart flush anywhere -- kb-done /
# kb-cancel / kb-stop-working / kb-backlog unpick all DELETED an item's
# workStartedAt WITHOUT banking it. Writing item-level timeWorkedMs on pause
# alone would have produced a total always missing its final span.
#
# THAT PREMISE NO LONGER HOLDS. XACA-1151 PR-C wired _kb_flush_work_time
# into kb-done, kb-cancel and kb-stop-working at the item level (kb-backlog
# unpick, and its sibling `demote`, are the one deliberate exception -- see
# below). With three of the four counterpart verbs now banking the span,
# leaving kb-pause's item arm as a bare paused-state toggle became actively
# HARMFUL rather than merely incomplete: a paused item's workStartedAt kept
# ticking straight through the pause (nothing cleared it), so kb-done went on
# to compute an elapsed time that included the paused wall-clock gap as if it
# were active work. That is the exact `kb-variance` estimate-accuracy
# corruption XACA-0819-014 was written to prevent -- now happening in the
# INFLATING direction instead of the deflating one the original fix guarded
# against. Item-level pause/resume is therefore ported in full, matching
# canonical: kb-pause flushes + clears workStartedAt for a parent-item
# workingOnId exactly as it already did for a subitem one; kb-resume restarts
# workStartedAt and seeds startedAt (`//=`, never overwriting an existing
# value) for a parent-item workingOnId exactly as it already did for a
# subitem one. Item and subitem paths are now IDENTICAL in shape.
#
# `kb-backlog unpick` and `kb-backlog demote` remain the ONE deliberate
# exception, UNCHANGED by this ticket: neither calls _kb_flush_work_time.
# Canonical's `unpick` flush is on record inflating timeWorkedMs to ~12.2
# BILLION ms from a single stale workStartedAt (XACA-0884, outer
# CHANGELOG) -- unpick/demote spans can be arbitrarily stale (months,
# observed), where a paused span is bounded by how long a human leaves work
# paused. Leaving unpick/demote non-flushing means an item stopped that way
# simply loses its final open span (timeWorkedMs reads slightly LOW), the
# conservative failure direction, and that trade is unchanged by this ticket.
#
# THE PLATFORM TRAP (verified against the template's source):
# _kb_flush_work_time parses timestamps via `date -j -f`, which is BSD/macOS-
# only, with zero GNU `date -d` fallback anywhere in this template. On any
# GNU-coreutils host that parse fails, the `|| echo "0"` guard fires, and
# elapsed computes as exactly ZERO (existing_time_ms passes through unchanged).
#
# PLATFORM NOTE: the manifest-driven plain-shell suites -- including this one
# -- run in the `test-shell-homebrew-tap` job on **macos-latest**, in this tap
# repo's own .github/workflows/tests.yml.
#
# The portable assertions below are KEPT deliberately. They cost nothing on
# macOS, they keep the suite correct if it is ever run on a Linux runner or by
# a Linux consumer, and the property that actually catches the regression --
# (d) below -- is platform-independent either way. This suite therefore NEVER
# asserts "elapsed time grew"; every assertion is chosen to hold on BOTH macOS
# (seed + real elapsed) and Linux (elapsed == 0, i.e. exactly the seed) while
# still being sensitive to the actual regression:
#   (a) after pause:  workStartedAt is ABSENT                       [portable]
#   (b) after pause:  timeWorkedMs >= seeded value                  [portable]
#   (c) after resume: workStartedAt is PRESENT                      [portable]
#   (d) after resume: timeWorkedMs is UNCHANGED from its post-pause
#       value                                                       [portable]
#       <- the core data-loss regression guard: a broken kb-resume that
#          re-banks or drops time on resume fails HERE.
#   (e) startedAt is preserved across resume, never overwritten     [portable]
#       <- proves the `//=` (not `=`) operator choice on kb-resume.
# Item and subitem coverage below now assert the IDENTICAL (a)-(e) shape --
# there is no longer a behavioral difference between them to distinguish.
#
# Coverage:
#   A. Render + hygiene -- no {{placeholder}} survives the rendered template.
#   1. Parent-item path: full pick-state -> pause -> resume cycle, asserting
#      (a)-(e) above -- item-level pause/resume now matches canonical and
#      the subitem path (Coverage 2) exactly.
#   2. Subitem path: full XACA-0551 cycle, asserting (a)-(e) on a subitem
#      nested under a parent item (`workingOnId` set to the SUBITEM id).
#      Unchanged by this ticket.
#   3. Static structural assertions on the (unmodified, real) template:
#        - exactly 1 _kb_flush_work_time function definition
#        - the file-wide real call-site count (`_kb_flush_work_time "`)
#          matches the CURRENT set of callers: kb-done (item+subitem),
#          kb-cancel (item+subitem), kb-stop-working (item+subitem),
#          kb-pause (item+subitem), _kb_add_subitem_blocker (subitem only)
#          = 9. This count is expected to grow again if a future ticket
#          ports another verb; a MISMATCH (not just a shrink) fails, so an
#          accidental removal is caught the same as an unreviewed addition.
#        - kb-pause's own function body contains exactly 2 call sites (item
#          + subitem, isolated the same way as before).
#        - kb-pause's PARENT-ITEM jq branch (isolated between its
#          `if .id == $workingOnId then` and the following
#          `elif (.subitems ...` marker) now contains >= 1 `timeWorkedMs`
#          write and >= 1 `del(.workStartedAt)` call -- the INVERSE of the
#          old XACA-0819-014 guard, now asserting the item branch DOES
#          flush, backing up Coverage 1 structurally.
#        - ZERO real call sites inside the `kb-backlog demote` case arm
#          (extracted the same way, between the `demote|todo)` case label and
#          the next case label) -- comment mentions of the function's name do
#          not count, because the assertion greps for the call-shaped
#          substring `_kb_flush_work_time "`, which none of the arm's prose
#          comments contain. This is the XACA-0884/XACA-0552 inversion guard.
#        - ZERO real call sites inside the `kb-backlog unpick` case arm
#          (same extraction method, between the `unpick)` case label and the
#          next case label) -- unpick is the OTHER deliberate non-flushing
#          verb and was not previously asserted here.
#   4. Demote freeze behavior: a STALE workStartedAt (~142 days old) must be
#      DISCARDED by `kb-backlog demote`, and timeWorkedMs must be left
#      EXACTLY at its seeded value -- not inflated by a naive flush-on-demote
#      (which would book ~12.27 BILLION ms for a 142-day-old span). Unchanged
#      by this ticket.
#
# The template is a zsh script (#!/bin/zsh) using zsh-isms; every invocation
# runs under `zsh -c "source <rendered>; ..."`. Sandboxed: AITEAMFORGE_DIR
# AND AITEAMFORGE_CONFIG (the team-paths.json registry) are BOTH redirected
# under TEST_TMP_DIR -- the AITEAMFORGE_CONFIG override is required, not
# optional: without it, `_kb_get_kanban_dir`'s Strategy-1 registry lookup
# would consult the REAL ~/.aiteamforge/team-paths.json on a dev machine,
# which can carry a real, existing kanban_dir for a real team and would let
# this suite mutate a live board. Context is resolved via KB_TEAM/KB_TERMINAL
# env (XACA-0725) -- no tmux needed, unlike the 0788 crash-recovery suite.
# Every board-mutating call is preceded by a safety-gate assertion that the
# resolved board path lives under this test's own TEST_TMP_DIR.
#
# Runs standalone (`bash tests/test-xaca-0819-pause-resume-active-span.sh`) OR
# via tests/test-runner.sh. Exit 0 = all assertions pass, exit 1 = any fail.
# Requires: bash, zsh, jq. Does NOT require tmux.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="$TAP_ROOT/share/templates/kanban/kanban-helpers.template.sh"

if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "FATAL: kanban-helpers.template.sh not found at: $TEMPLATE_PATH" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Hard prerequisites.
# ─────────────────────────────────────────────────────────────────────────────
for _tool in zsh jq; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        echo "FATAL: required tool '$_tool' not on PATH — cannot run pause/resume active-span tests." >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (mirrors test-xaca-0788's pattern): provide test_start/
# test_pass/test_fail when test-runner.sh has NOT exported them.
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# EXPLICIT pass/fail counters — independent of the outer harness. The known
# trap (feedback_tap_test_harness_vacuous_green): tap assert_* helpers record
# only on FAILURE, so a suite that runs 0 real assertions prints "All tests
# passed" vacuously. We increment _P0819_PASS on EVERY successful assertion,
# print an explicit "Passed: N / Total: M", and exit non-zero if any assertion
# failed — true both standalone and under test-runner.sh.
# ─────────────────────────────────────────────────────────────────────────────
_P0819_PASS=0
_P0819_FAIL=0

# ok <label> <cond(1|0)> [failure_detail]
ok() {
    local label="$1" cond="$2" detail="${3:-}"
    test_start "$label"
    if [ "$cond" = "1" ]; then
        _P0819_PASS=$((_P0819_PASS + 1)); test_pass
    else
        _P0819_FAIL=$((_P0819_FAIL + 1)); test_fail "$detail"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0819-pause-resume-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
WORK_DIR="$TEST_TMP_DIR/xaca0819"
mkdir -p "$WORK_DIR/aiteamforge" "$WORK_DIR/kanban"

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

# A throwaway team slug unique to this PID — can never collide with a real
# fleet team (e.g. academy). Its 3-letter uppercase form ("TST") also
# satisfies _kb_resolve_selector's `^X[A-Z]{3}-[0-9]+$` ID-format regex, so
# item IDs below (XTST-####[-###]) resolve correctly through kb-backlog too.
TEAM="xtst$$"
BOARD="$WORK_DIR/kanban/${TEAM}-board.json"

# ─────────────────────────────────────────────────────────────────────────────
# A. Render the template into the sandbox.
# ─────────────────────────────────────────────────────────────────────────────
export AITEAMFORGE_DIR="$WORK_DIR/aiteamforge"
RENDERED="$WORK_DIR/kanban-helpers-rendered.sh"
sed "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g; \
     s|{{SHARED_DEV_ROOT}}|$WORK_DIR/shared|g; \
     s|{{ORG_NAME}}|TestOrg|g; \
     s|{{ORG_SLUG}}|testorg|g" \
    "$TEMPLATE_PATH" > "$RENDERED"

_A_LEFT=$(grep -c '{{' "$RENDERED" 2>/dev/null)
[ -n "$_A_LEFT" ] || _A_LEFT=0
ok "A: no {{placeholder}} survives in the rendered template" \
   "$([ "$_A_LEFT" -eq 0 ] && echo 1 || echo 0)" \
   "found $_A_LEFT residual '{{' placeholder(s): $(grep -oE '\{\{[A-Z_]+\}\}' "$RENDERED" | sort -u | tr '\n' ' ')"

# ─────────────────────────────────────────────────────────────────────────────
# Sandboxed team-paths.json registry (Strategy 1 of _kb_get_kanban_dir). This
# MUST be set — without it, an unmapped team slug still falls through to
# Strategy 2/3 in the template's built-in case arms, but pointing the
# registry explicitly at our sandbox is the belt to that suspenders'
# braces, and is what the AITEAMFORGE_CONFIG override is FOR (XACA-0649).
# ─────────────────────────────────────────────────────────────────────────────
export AITEAMFORGE_CONFIG="$WORK_DIR/team-paths.json"
cat > "$AITEAMFORGE_CONFIG" <<JSON
{"teams": {"${TEAM}": {"kanban_dir": "$WORK_DIR/kanban"}}}
JSON

export KB_TEAM="$TEAM" KB_TERMINAL="agent"

# ─────────────────────────────────────────────────────────────────────────────
# Safety gate (MANDATORY): before ANY command that mutates the board, resolve
# the board path via the rendered template's own resolver and assert it is a
# prefix match inside TEST_TMP_DIR. Abort loudly (exit 1, not a failed
# assertion) if a resolution bug would let this suite touch a real board.
# ─────────────────────────────────────────────────────────────────────────────
_assert_board_in_sandbox() {
    local resolved
    resolved=$(zsh -c "source '$RENDERED' >/dev/null 2>&1; _kb_get_board_file '$TEAM'" 2>/dev/null)
    case "$resolved" in
        "$TEST_TMP_DIR"/*) ;;
        *)
            echo "FATAL SAFETY-GATE ABORT: resolved board path '$resolved' is NOT under sandbox '$TEST_TMP_DIR' — refusing to run any board-mutating command." >&2
            exit 1
            ;;
    esac
}
_assert_board_in_sandbox

# ─────────────────────────────────────────────────────────────────────────────
# Coverage 1: PARENT-ITEM pick -> pause -> resume cycle. Item-level behavior
# now matches canonical AND the subitem path (Coverage 2) exactly: pause
# flushes the elapsed span into timeWorkedMs and clears workStartedAt; resume
# restarts workStartedAt and seeds startedAt only if it was absent.
# ─────────────────────────────────────────────────────────────────────────────
SEED_STARTED_AT="2026-08-20T09:00:00Z"
SEED_TIME_MS="5000000"

cat > "$BOARD" <<JSON
{
  "nextId": 2,
  "activeWindows": [
    {"id": "agent:main", "status": "coding", "workingOnId": "XTST-0001"}
  ],
  "backlog": [
    {
      "id": "XTST-0001",
      "title": "Parent test item",
      "status": "in_progress",
      "startedAt": "$SEED_STARTED_AT",
      "workStartedAt": "$SEED_STARTED_AT",
      "timeWorkedMs": $SEED_TIME_MS
    }
  ]
}
JSON

zsh -c "source '$RENDERED' >/dev/null 2>&1; kb-pause 'suite pause reason'" >"$WORK_DIR/p1-pause.out" 2>&1
_P1_WSA_AFTER_PAUSE=$(jq -r '.backlog[0] | has("workStartedAt")' "$BOARD")
ok "1a: parent item — workStartedAt is ABSENT after pause (span ended, matching canonical)" \
   "$([ "$_P1_WSA_AFTER_PAUSE" = "false" ] && echo 1 || echo 0)" \
   "expected workStartedAt absent after pause, has()=$_P1_WSA_AFTER_PAUSE; board=$(cat "$BOARD")"

_P1_TWM_AFTER_PAUSE=$(jq -r '.backlog[0].timeWorkedMs' "$BOARD")
ok "1b: parent item — timeWorkedMs >= seeded value ($SEED_TIME_MS) after pause" \
   "$([ "${_P1_TWM_AFTER_PAUSE:-0}" -ge "$SEED_TIME_MS" ] 2>/dev/null && echo 1 || echo 0)" \
   "expected >= $SEED_TIME_MS, got $_P1_TWM_AFTER_PAUSE"

zsh -c "source '$RENDERED' >/dev/null 2>&1; kb-resume" >"$WORK_DIR/p1-resume.out" 2>&1
_P1_WSA_AFTER_RESUME=$(jq -r '.backlog[0] | has("workStartedAt")' "$BOARD")
ok "1c: parent item — workStartedAt is PRESENT after resume (span restarted)" \
   "$([ "$_P1_WSA_AFTER_RESUME" = "true" ] && echo 1 || echo 0)" \
   "expected workStartedAt present after resume, has()=$_P1_WSA_AFTER_RESUME"

_P1_TWM_AFTER_RESUME=$(jq -r '.backlog[0].timeWorkedMs' "$BOARD")
ok "1d [REGRESSION GUARD]: parent item — timeWorkedMs UNCHANGED across resume ($_P1_TWM_AFTER_PAUSE -> $_P1_TWM_AFTER_RESUME)" \
   "$([ "$_P1_TWM_AFTER_RESUME" = "$_P1_TWM_AFTER_PAUSE" ] && echo 1 || echo 0)" \
   "post-pause timeWorkedMs=$_P1_TWM_AFTER_PAUSE, post-resume timeWorkedMs=$_P1_TWM_AFTER_RESUME — a mismatch means the active span was lost or re-banked across resume"

_P1_STARTED_AT_AFTER_RESUME=$(jq -r '.backlog[0].startedAt' "$BOARD")
ok "1e: parent item — startedAt preserved across resume (proves //= not =)" \
   "$([ "$_P1_STARTED_AT_AFTER_RESUME" = "$SEED_STARTED_AT" ] && echo 1 || echo 0)" \
   "expected startedAt still '$SEED_STARTED_AT', got '$_P1_STARTED_AT_AFTER_RESUME'"

# ─────────────────────────────────────────────────────────────────────────────

# Re-assert the sandbox gate before this section's mutating calls (XACA-0819-018):
# the header claims EVERY board-mutating call is gated, so every section must gate.
_assert_board_in_sandbox
# Coverage 2: SUBITEM pick -> pause -> resume cycle (workingOnId = subitem id).
# Unchanged by this ticket — subitem behavior already matched canonical.
# ─────────────────────────────────────────────────────────────────────────────
cat > "$BOARD" <<JSON
{
  "nextId": 2,
  "activeWindows": [
    {"id": "agent:main", "status": "coding", "workingOnId": "XTST-0001-001"}
  ],
  "backlog": [
    {
      "id": "XTST-0001",
      "title": "Parent of subitem test",
      "status": "in_progress",
      "subitems": [
        {
          "id": "XTST-0001-001",
          "title": "Sub test item",
          "status": "in_progress",
          "startedAt": "$SEED_STARTED_AT",
          "workStartedAt": "$SEED_STARTED_AT",
          "timeWorkedMs": $SEED_TIME_MS
        }
      ]
    }
  ]
}
JSON

zsh -c "source '$RENDERED' >/dev/null 2>&1; kb-pause 'suite sub-pause reason'" >"$WORK_DIR/p2-pause.out" 2>&1
_P2_WSA_AFTER_PAUSE=$(jq -r '.backlog[0].subitems[0] | has("workStartedAt")' "$BOARD")
ok "2a: subitem — workStartedAt is ABSENT after pause" \
   "$([ "$_P2_WSA_AFTER_PAUSE" = "false" ] && echo 1 || echo 0)" \
   "expected workStartedAt absent on subitem, has()=$_P2_WSA_AFTER_PAUSE; board=$(cat "$BOARD")"

_P2_TWM_AFTER_PAUSE=$(jq -r '.backlog[0].subitems[0].timeWorkedMs' "$BOARD")
ok "2b: subitem — timeWorkedMs >= seeded value ($SEED_TIME_MS) after pause" \
   "$([ "${_P2_TWM_AFTER_PAUSE:-0}" -ge "$SEED_TIME_MS" ] 2>/dev/null && echo 1 || echo 0)" \
   "expected >= $SEED_TIME_MS, got $_P2_TWM_AFTER_PAUSE"

zsh -c "source '$RENDERED' >/dev/null 2>&1; kb-resume" >"$WORK_DIR/p2-resume.out" 2>&1
_P2_WSA_AFTER_RESUME=$(jq -r '.backlog[0].subitems[0] | has("workStartedAt")' "$BOARD")
ok "2c: subitem — workStartedAt is PRESENT after resume" \
   "$([ "$_P2_WSA_AFTER_RESUME" = "true" ] && echo 1 || echo 0)" \
   "expected workStartedAt present on subitem, has()=$_P2_WSA_AFTER_RESUME"

_P2_TWM_AFTER_RESUME=$(jq -r '.backlog[0].subitems[0].timeWorkedMs' "$BOARD")
ok "2d [REGRESSION GUARD]: subitem — timeWorkedMs UNCHANGED across resume ($_P2_TWM_AFTER_PAUSE -> $_P2_TWM_AFTER_RESUME)" \
   "$([ "$_P2_TWM_AFTER_RESUME" = "$_P2_TWM_AFTER_PAUSE" ] && echo 1 || echo 0)" \
   "post-pause timeWorkedMs=$_P2_TWM_AFTER_PAUSE, post-resume timeWorkedMs=$_P2_TWM_AFTER_RESUME — a mismatch means the active span was lost or re-banked across resume"

_P2_STARTED_AT_AFTER_RESUME=$(jq -r '.backlog[0].subitems[0].startedAt' "$BOARD")
ok "2e: subitem — startedAt preserved across resume (proves //= not =)" \
   "$([ "$_P2_STARTED_AT_AFTER_RESUME" = "$SEED_STARTED_AT" ] && echo 1 || echo 0)" \
   "expected startedAt still '$SEED_STARTED_AT', got '$_P2_STARTED_AT_AFTER_RESUME'"

# 2f: a FRESH subitem (never previously started — startedAt/workStartedAt
# absent from the seed entirely) exercises the OTHER half of `//=`: when
# startedAt is absent, resume must SET it. 2e alone cannot distinguish `//=`
# from a stripped-entirely write, because when startedAt is already present
# (2e's fixture), both "leave it alone" and "no-op due to missing line" look
# identical. This scenario is the one that actually pins the operator down.
cat > "$BOARD" <<JSON
{
  "nextId": 2,
  "activeWindows": [
    {"id": "agent:main", "status": "coding", "workingOnId": "XTST-0001-002"}
  ],
  "backlog": [
    {
      "id": "XTST-0001",
      "title": "Parent of fresh subitem test",
      "status": "in_progress",
      "subitems": [
        {
          "id": "XTST-0001-002",
          "title": "Fresh sub test item (never started)",
          "status": "in_progress"
        }
      ]
    }
  ]
}
JSON

zsh -c "source '$RENDERED' >/dev/null 2>&1; kb-pause 'fresh sub pause'" >"$WORK_DIR/p2f-pause.out" 2>&1
zsh -c "source '$RENDERED' >/dev/null 2>&1; kb-resume" >"$WORK_DIR/p2f-resume.out" 2>&1
_P2F_STARTED_AT_PRESENT=$(jq -r '.backlog[0].subitems[0] | has("startedAt")' "$BOARD")
ok "2f [//= SETS-WHEN-ABSENT GUARD]: fresh subitem — startedAt becomes PRESENT on first resume (was never set before)" \
   "$([ "$_P2F_STARTED_AT_PRESENT" = "true" ] && echo 1 || echo 0)" \
   "expected startedAt present after resume on a subitem that never had one (proves the //= operator SETS on first use, not just 'preserves'), has()=$_P2F_STARTED_AT_PRESENT; board=$(cat "$BOARD")"

# ─────────────────────────────────────────────────────────────────────────────
# Coverage 3: static structural assertions on the rendered template.
# ─────────────────────────────────────────────────────────────────────────────

# 3a: exactly ONE _kb_flush_work_time function definition.
# NOTE: `grep -c` prints "0" AND exits 1 on no-match, so do NOT append
# `|| echo 0` (that would emit a second "0" line and break the integer test).
_DEF_COUNT=$(grep -c '^_kb_flush_work_time() {' "$RENDERED" 2>/dev/null)
[ -n "$_DEF_COUNT" ] || _DEF_COUNT=0
ok "3a: exactly 1 _kb_flush_work_time() definition in the rendered template" \
   "$([ "$_DEF_COUNT" -eq 1 ] && echo 1 || echo 0)" \
   "expected 1 definition, found $_DEF_COUNT"

# 3b: the file-wide real call-site count. XACA-1151 PR-C ported item-level
# flushing into kb-done, kb-cancel, kb-stop-working and kb-pause (2 sites
# each: item + subitem), plus _kb_add_subitem_blocker's 1 (subitem only) = 9,
# review round 3 (XACA-1151-041) added `kb-backlog sub cancel`'s 1 (subitem
# only) = 10, and the same round (XACA-1151-044) added item-level
# `_kb_add_blocker`'s 1 (block side only -- `_kb_remove_blocker` restarts
# the span via a plain jq assignment, not a call to this function) = 11.
# This is an EXACT match, not a floor: a mismatch in EITHER direction means
# either an un-reviewed removal or an un-reviewed addition, and both need
# eyes on the diff.
_CALL_COUNT_TOTAL=$(grep -c '_kb_flush_work_time "' "$RENDERED" 2>/dev/null)
[ -n "$_CALL_COUNT_TOTAL" ] || _CALL_COUNT_TOTAL=0
ok "3b: exactly 11 real _kb_flush_work_time call sites file-wide (kb-done/kb-cancel/kb-stop-working/kb-pause x2 each + _kb_add_subitem_blocker x1 + sub-cancel x1 + _kb_add_blocker x1)" \
   "$([ "$_CALL_COUNT_TOTAL" -eq 11 ] && echo 1 || echo 0)" \
   "expected 11 call sites (call-shaped substring '_kb_flush_work_time \"'), found $_CALL_COUNT_TOTAL"

# 3c: isolate kb-pause's own function body (from its header to its own
# top-level closing brace) and confirm it now contains 2 call sites (item +
# subitem — XACA-1151 PR-C ported the item arm to match canonical).
KB_PAUSE_BODY="$WORK_DIR/kb-pause-body.txt"
awk '
  /^kb-pause\(\) \{/ { flag=1; print; next }
  flag && /^\}$/ { print; flag=0; next }
  flag { print }
' "$RENDERED" > "$KB_PAUSE_BODY"
_KB_PAUSE_LINES=$(wc -l < "$KB_PAUSE_BODY" | tr -d '[:space:]')
_CALL_COUNT_IN_PAUSE=$(grep -c '_kb_flush_work_time "' "$KB_PAUSE_BODY" 2>/dev/null)
[ -n "$_CALL_COUNT_IN_PAUSE" ] || _CALL_COUNT_IN_PAUSE=0
ok "3c: kb-pause contains exactly 2 _kb_flush_work_time call sites (item + subitem) (body=${_KB_PAUSE_LINES} lines, calls found=${_CALL_COUNT_IN_PAUSE})" \
   "$([ -n "$_KB_PAUSE_LINES" ] && [ "$_KB_PAUSE_LINES" -gt 20 ] && [ "$_CALL_COUNT_IN_PAUSE" -eq 2 ] && echo 1 || echo 0)" \
   "expected kb-pause body >20 lines with exactly 2 call sites; got ${_KB_PAUSE_LINES} lines / ${_CALL_COUNT_IN_PAUSE} calls"

# 3d [ITEM-LEVEL PARITY GUARD]: isolate kb-pause's PARENT-ITEM jq branch
# (between its `if .id == $workingOnId then` header and the following
# `elif (.subitems ...` marker) and confirm it now contains >= 1
# timeWorkedMs write and >= 1 del(.workStartedAt) call — the INVERSE of the
# retired XACA-0819-014 guard, which asserted ZERO of each. Uses plain
# substring matching (awk index(), not a /regex/ literal) deliberately -- an
# earlier draft of this extraction used a /.../ regex containing an escaped
# `//` that is fragile inside a regex delimiter and silently ran past its
# intended stop marker to end-of-function during manual verification;
# index() sidesteps that class of bug entirely by never treating the
# pattern as a regex.
ITEM_BRANCH="$WORK_DIR/item-branch.txt"
awk '
  index($0, "if .id == $workingOnId then") > 0 && started == 0 { flag=1; started=1; next }
  index($0, "elif (.subitems") > 0 { flag=0 }
  flag { print }
' "$KB_PAUSE_BODY" > "$ITEM_BRANCH"
_ITEM_BRANCH_LINES=$(wc -l < "$ITEM_BRANCH" | tr -d '[:space:]')
_ITEM_BRANCH_TWM=$(grep -c 'timeWorkedMs' "$ITEM_BRANCH" 2>/dev/null)
[ -n "$_ITEM_BRANCH_TWM" ] || _ITEM_BRANCH_TWM=0
_ITEM_BRANCH_DEL=$(grep -c 'del(\.workStartedAt)' "$ITEM_BRANCH" 2>/dev/null)
[ -n "$_ITEM_BRANCH_DEL" ] || _ITEM_BRANCH_DEL=0
ok "3d [ITEM-LEVEL PARITY GUARD]: kb-pause's parent-item branch now flushes (>=1 timeWorkedMs write, >=1 del(.workStartedAt)) (branch=${_ITEM_BRANCH_LINES} lines)" \
   "$([ -n "$_ITEM_BRANCH_LINES" ] && [ "$_ITEM_BRANCH_LINES" -ge 3 ] && [ "$_ITEM_BRANCH_TWM" -ge 1 ] && [ "$_ITEM_BRANCH_DEL" -ge 1 ] && echo 1 || echo 0)" \
   "expected item branch >=3 lines, >=1 timeWorkedMs write, >=1 del(.workStartedAt); got ${_ITEM_BRANCH_LINES} lines / ${_ITEM_BRANCH_TWM} timeWorkedMs mentions / ${_ITEM_BRANCH_DEL} del(.workStartedAt) — a zero count means the item-level flush this ticket ported was silently removed (see Coverage 1)"

# 3e: isolate `kb-backlog demote`'s case arm (from its case label to the next
# case label at the same indentation) and confirm ZERO real call sites — the
# XACA-0884/XACA-0552 inversion guard. The arm's prose comments MENTION the
# function name but do not contain the call-shaped substring, so this grep
# correctly ignores them. Unchanged by this ticket.
DEMOTE_ARM="$WORK_DIR/demote-arm.txt"
awk '
  /^        demote\|todo\)/ { flag=1; print; next }
  flag && /^        [A-Za-z_|]+\)/ { flag=0 }
  flag { print }
' "$RENDERED" > "$DEMOTE_ARM"
_DEMOTE_ARM_LINES=$(wc -l < "$DEMOTE_ARM" | tr -d '[:space:]')
_CALL_COUNT_IN_DEMOTE=$(grep -c '_kb_flush_work_time "' "$DEMOTE_ARM" 2>/dev/null)
[ -n "$_CALL_COUNT_IN_DEMOTE" ] || _CALL_COUNT_IN_DEMOTE=0
_MENTION_COUNT_IN_DEMOTE=$(grep -c '_kb_flush_work_time' "$DEMOTE_ARM" 2>/dev/null)
[ -n "$_MENTION_COUNT_IN_DEMOTE" ] || _MENTION_COUNT_IN_DEMOTE=0
ok "3e [INVERSION GUARD]: zero real _kb_flush_work_time call sites inside kb-backlog demote arm (arm=${_DEMOTE_ARM_LINES} lines, comment mentions=${_MENTION_COUNT_IN_DEMOTE}, real calls=${_CALL_COUNT_IN_DEMOTE})" \
   "$([ -n "$_DEMOTE_ARM_LINES" ] && [ "$_DEMOTE_ARM_LINES" -gt 20 ] && [ "$_CALL_COUNT_IN_DEMOTE" -eq 0 ] && [ "$_MENTION_COUNT_IN_DEMOTE" -ge 1 ] && echo 1 || echo 0)" \
   "expected demote arm >20 lines, >=1 comment mention, 0 real call sites; got ${_DEMOTE_ARM_LINES} lines / ${_MENTION_COUNT_IN_DEMOTE} mentions / ${_CALL_COUNT_IN_DEMOTE} calls"

# 3f [INVERSION GUARD, unpick]: isolate `kb-backlog unpick`'s case arm (from
# its case label to the next case label) and confirm ZERO real call sites --
# unpick is the OTHER deliberate non-flushing verb (XACA-0884), not
# previously asserted by this suite. New in this revision.
UNPICK_ARM="$WORK_DIR/unpick-arm.txt"
awk '
  /^        unpick\)/ { flag=1; print; next }
  flag && /^        [A-Za-z_|]+\)/ { flag=0 }
  flag { print }
' "$RENDERED" > "$UNPICK_ARM"
_UNPICK_ARM_LINES=$(wc -l < "$UNPICK_ARM" | tr -d '[:space:]')
_CALL_COUNT_IN_UNPICK=$(grep -c '_kb_flush_work_time "' "$UNPICK_ARM" 2>/dev/null)
[ -n "$_CALL_COUNT_IN_UNPICK" ] || _CALL_COUNT_IN_UNPICK=0
ok "3f [INVERSION GUARD, unpick]: zero real _kb_flush_work_time call sites inside kb-backlog unpick arm (arm=${_UNPICK_ARM_LINES} lines, real calls=${_CALL_COUNT_IN_UNPICK})" \
   "$([ -n "$_UNPICK_ARM_LINES" ] && [ "$_UNPICK_ARM_LINES" -gt 10 ] && [ "$_CALL_COUNT_IN_UNPICK" -eq 0 ] && echo 1 || echo 0)" \
   "expected unpick arm >10 lines, 0 real call sites; got ${_UNPICK_ARM_LINES} lines / ${_CALL_COUNT_IN_UNPICK} calls"

# ─────────────────────────────────────────────────────────────────────────────
# Coverage 4: demote freeze behavior — a stale workStartedAt must be
# DISCARDED, and timeWorkedMs must be left EXACTLY at its seeded value (not
# inflated by a naive flush-on-demote). Fixture: workStartedAt ~142 days
# stale — a naive flush would book ~12.27 BILLION ms of phantom work.
# Unchanged by this ticket.
# ─────────────────────────────────────────────────────────────────────────────
STALE_STARTED_AT="2026-03-31T09:00:00Z"
cat > "$BOARD" <<JSON
{
  "nextId": 2,
  "activeWindows": [],
  "backlog": [
    {
      "id": "XTST-0002",
      "title": "Demote freeze test item",
      "status": "in_progress",
      "startedAt": "$STALE_STARTED_AT",
      "workStartedAt": "$STALE_STARTED_AT",
      "timeWorkedMs": $SEED_TIME_MS
    }
  ]
}
JSON

_assert_board_in_sandbox
zsh -c "source '$RENDERED' >/dev/null 2>&1; kb-backlog demote XTST-0002" >"$WORK_DIR/demote.out" 2>&1
_DEMOTE_STATUS=$(jq -r '.backlog[0].status' "$BOARD")
_DEMOTE_WSA_PRESENT=$(jq -r '.backlog[0] | has("workStartedAt")' "$BOARD")
_DEMOTE_TWM=$(jq -r '.backlog[0].timeWorkedMs' "$BOARD")

ok "4a: kb-backlog demote — status becomes todo" \
   "$([ "$_DEMOTE_STATUS" = "todo" ] && echo 1 || echo 0)" \
   "expected status=todo, got '$_DEMOTE_STATUS'; output=$(cat "$WORK_DIR/demote.out")"

ok "4b: kb-backlog demote — stale workStartedAt is DISCARDED (absent), not flushed" \
   "$([ "$_DEMOTE_WSA_PRESENT" = "false" ] && echo 1 || echo 0)" \
   "expected workStartedAt absent after demote, has()=$_DEMOTE_WSA_PRESENT"

ok "4c [PHANTOM-WORK GUARD]: kb-backlog demote — timeWorkedMs left EXACTLY at seeded value (no naive flush-on-demote)" \
   "$([ "$_DEMOTE_TWM" = "$SEED_TIME_MS" ] && echo 1 || echo 0)" \
   "expected timeWorkedMs to remain exactly $SEED_TIME_MS (a naive flush of a ~142-day-stale span would book ~12,268,800,000ms); got $_DEMOTE_TWM"

# ─────────────────────────────────────────────────────────────────────────────
# Summary — explicit real assertion count (defeats vacuous-green).
# ─────────────────────────────────────────────────────────────────────────────
_TOTAL=$((_P0819_PASS + _P0819_FAIL))
echo ""
echo "──────────────────────────────────────────────────────────────"
echo "XACA-0819 pause-resume-active-span: Passed: ${_P0819_PASS} / Total: ${_TOTAL}  (Failed: ${_P0819_FAIL})"
echo "──────────────────────────────────────────────────────────────"

if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_P0819_PASS} passed, ${_P0819_FAIL} failed"
fi

# Exit non-zero if ANY assertion failed OR if zero real assertions ran (a
# zero-assertion run is itself a harness failure, never a pass). Require at
# least 18 assertions (5 item + 6 subitem[a-f] + 6 static[a-f] + 3 demote =
# 20 planned) so a future accidental short-circuit that skips whole sections
# is still caught.
if [ "$_P0819_FAIL" -gt 0 ] || [ "$_TOTAL" -lt 18 ]; then
    exit 1
fi
exit 0
