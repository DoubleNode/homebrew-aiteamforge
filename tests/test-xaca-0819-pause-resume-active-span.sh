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
# SCOPE CORRECTION (XACA-0819-014, PR #756 review): the fix below is now
# SUBITEM-ONLY, not "both branches" as an earlier draft of this ticket shipped
# and this suite originally asserted. Why: this template's ITEM level has no
# counterpart flush anywhere -- kb-done / kb-cancel / kb-stop-working /
# kb-backlog unpick all DELETE an item's workStartedAt WITHOUT banking it.
# Writing item-level timeWorkedMs on pause alone would therefore produce a
# total that is ALWAYS missing its final span. Worse: `kb-variance` (share/
# templates/aliases/kanban-aliases.sh) selects completed items on
# `timeWorkedMs > 0`, so those items would silently graduate from the honest
# `no_time` bucket into the estimate-accuracy math carrying a systematically
# LOW actual -- a plausible-looking wrong number is worse than an absent one.
# Subitems DO have the counterpart flushes canonical assumes (4 pre-existing
# sites in this file), so the span is fully accounted there and applying the
# full XACA-0551 sync to subitems only is safe. The fix, as shipped:
#   - kb-pause flushes the active span via the newly-ported
#     _kb_flush_work_time() into timeWorkedMs, then clears workStartedAt --
#     for the SUBITEM branch of its jq filter ONLY. The parent-item branch is
#     UNCHANGED from pre-XACA-0819 behavior (no flush, no clear).
#   - kb-resume opens a FRESH span (`workStartedAt = $timestamp`) and seeds
#     `startedAt` only if absent (`startedAt //= $timestamp`) -- again for the
#     SUBITEM branch ONLY. The parent-item branch only clears paused-state
#     fields; it deliberately does NOT touch workStartedAt/startedAt, because
#     kb-pause never ended that span at item level in the first place.
#   - `_kb_flush_work_time` is a pure, read-only-of-intent helper: it computes
#     existing_time_ms + elapsed(workStartedAt..now), but does NOT write
#     anything itself; kb-pause applies its result via the jq --arg timeMs.
#   - `kb-backlog demote` (XACA-0884/XACA-0552) is DELIBERATELY NOT wired to
#     this helper -- a demoted item's open workStartedAt must be DISCARDED,
#     never credited, or a stale span (observed: ~4 months) would be booked
#     as phantom work. This suite's static assertions are the enforcement
#     mechanism the template's own comments point back to.
#
# THE PLATFORM TRAP (verified against the template's source):
# _kb_flush_work_time parses timestamps via `date -j -f`, which is BSD/macOS-
# only, with zero GNU `date -d` fallback anywhere in this template. On any
# GNU-coreutils host that parse fails, the `|| echo "0"` guard fires, and
# elapsed computes as exactly ZERO (existing_time_ms passes through unchanged).
#
# CORRECTION (PR #756 review): an earlier version of this header asserted "Tap
# CI runs ubuntu-latest". That was WRONG and was inferred, not checked. The
# manifest-driven plain-shell suites -- including this one -- run in the
# `test-shell-homebrew-tap` job on **macos-latest**, in this tap repo's own
# .github/workflows/tests.yml. The ubuntu-latest job that claim was taken from
# lives in dev-team's tap-installer-tests.yml and runs installer tests, not
# these suites.
#
# The portable assertions below are KEPT anyway, deliberately. They cost
# nothing on macOS, they keep the suite correct if it is ever run on a Linux
# runner or by a Linux consumer, and the property that actually catches the
# regression -- (d) -- is platform-independent either way. This suite therefore
# NEVER asserts "elapsed time grew" for the subitem cycle -- every assertion
# below is chosen to hold on BOTH macOS (seed + real elapsed) and Linux
# (elapsed == 0, i.e. exactly the seed) while still being sensitive to the
# actual regression, on the SUBITEM which now carries the full behavior:
#   (a) after pause:  workStartedAt is ABSENT                       [portable]
#   (b) after pause:  timeWorkedMs >= seeded value                  [portable]
#   (c) after resume: workStartedAt is PRESENT                      [portable]
#   (d) after resume: timeWorkedMs is UNCHANGED from its post-pause
#       value                                                       [portable]
#       <- the core data-loss regression guard: a broken kb-resume that
#          re-banks or drops time on resume fails HERE.
#   (e) startedAt is preserved across resume, never overwritten     [portable]
#       <- proves the `//=` (not `=`) operator choice on kb-resume.
#
# The PARENT-ITEM branch is asserted SEPARATELY (Coverage 1) as UNCHANGED --
# workStartedAt/timeWorkedMs/startedAt must all be identical before and after
# a pause/resume cycle at item level, framed explicitly as a regression guard
# against someone re-adding the item-level write without also adding the four
# counterpart flushes XACA-0819-014 identified as missing.
#
# Coverage:
#   A. Render + hygiene -- no {{placeholder}} survives the rendered template.
#   1. [REGRESSION GUARD XACA-0819-014] Parent-item path: full pick-state ->
#      pause -> resume cycle, asserting workStartedAt/timeWorkedMs/startedAt
#      are ALL UNCHANGED throughout -- item-level pause/resume behavior must
#      stay exactly as it was before XACA-0819 (no flush, no span restart).
#   2. Subitem path: full XACA-0551 cycle, asserting (a)-(e) on a subitem
#      nested under a parent item (`workingOnId` set to the SUBITEM id).
#   3. Static structural assertions on the (unmodified, real) template:
#        - exactly 1 _kb_flush_work_time function definition
#        - exactly 1 real call site (`_kb_flush_work_time "`), inside
#          kb-pause's own line range (extracted by isolating the function
#          body between its `kb-pause() {` header and its own top-level
#          closing `}`)
#        - kb-pause's PARENT-ITEM jq branch (isolated between its
#          `if .id == $workingOnId then` and the following
#          `elif (.subitems ...` marker) contains ZERO `timeWorkedMs` writes
#          and ZERO `del(.workStartedAt)` calls -- the XACA-0819-014 guard
#          that this suite's Coverage 1 exists to back up structurally.
#        - ZERO real call sites inside the `kb-backlog demote` case arm
#          (extracted the same way, between the `demote|todo)` case label and
#          the next case label) -- comment mentions of the function's name do
#          not count, because the assertion greps for the call-shaped
#          substring `_kb_flush_work_time "`, which none of the arm's prose
#          comments contain. This is the XACA-0884/XACA-0552 inversion guard.
#   4. Demote freeze behavior: a STALE workStartedAt (~142 days old) must be
#      DISCARDED by `kb-backlog demote`, and timeWorkedMs must be left
#      EXACTLY at its seeded value -- not inflated by a naive flush-on-demote
#      (which would book ~12.27 BILLION ms for a 142-day-old span).
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
# Coverage 1 [REGRESSION GUARD XACA-0819-014]: PARENT-ITEM pick -> pause ->
# resume cycle. Item-level behavior must be COMPLETELY UNCHANGED by this
# cycle -- no flush, no clear, no span restart -- because this template has
# no counterpart flush at item level (kb-done/kb-cancel/kb-stop-working/
# kb-backlog unpick all discard workStartedAt without banking it). A pass
# here means item-level pause/resume is still a pure paused-state toggle.
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
_P1_WSA_AFTER_PAUSE=$(jq -r '.backlog[0].workStartedAt // "ABSENT"' "$BOARD")
ok "1a [REGRESSION GUARD XACA-0819-014]: parent item — workStartedAt SURVIVES pause unchanged (no item-level flush exists)" \
   "$([ "$_P1_WSA_AFTER_PAUSE" = "$SEED_STARTED_AT" ] && echo 1 || echo 0)" \
   "expected workStartedAt still '$SEED_STARTED_AT' after pause (item level has no flush), got '$_P1_WSA_AFTER_PAUSE'; board=$(cat "$BOARD")"

_P1_TWM_AFTER_PAUSE=$(jq -r '.backlog[0].timeWorkedMs' "$BOARD")
ok "1b [REGRESSION GUARD XACA-0819-014]: parent item — timeWorkedMs does NOT grow after pause (stays exactly seeded value)" \
   "$([ "$_P1_TWM_AFTER_PAUSE" = "$SEED_TIME_MS" ] && echo 1 || echo 0)" \
   "expected timeWorkedMs to remain exactly $SEED_TIME_MS after pause (a change means an item-level write crept back in without its counterpart flush machinery), got $_P1_TWM_AFTER_PAUSE"

zsh -c "source '$RENDERED' >/dev/null 2>&1; kb-resume" >"$WORK_DIR/p1-resume.out" 2>&1
_P1_WSA_AFTER_RESUME=$(jq -r '.backlog[0].workStartedAt // "ABSENT"' "$BOARD")
ok "1c [REGRESSION GUARD XACA-0819-014]: parent item — workStartedAt after resume is STILL the ORIGINAL value (kb-resume does not restart the item-level span)" \
   "$([ "$_P1_WSA_AFTER_RESUME" = "$SEED_STARTED_AT" ] && echo 1 || echo 0)" \
   "expected workStartedAt still '$SEED_STARTED_AT' after resume (item-level span was never ended, so there is nothing to restart), got '$_P1_WSA_AFTER_RESUME'"

_P1_TWM_AFTER_RESUME=$(jq -r '.backlog[0].timeWorkedMs' "$BOARD")
ok "1d [REGRESSION GUARD XACA-0819-014]: parent item — timeWorkedMs UNCHANGED across the full pause+resume cycle ($_P1_TWM_AFTER_PAUSE -> $_P1_TWM_AFTER_RESUME)" \
   "$([ "$_P1_TWM_AFTER_RESUME" = "$SEED_TIME_MS" ] && echo 1 || echo 0)" \
   "expected timeWorkedMs to remain exactly $SEED_TIME_MS after resume, got $_P1_TWM_AFTER_RESUME"

_P1_STARTED_AT_AFTER_RESUME=$(jq -r '.backlog[0].startedAt' "$BOARD")
ok "1e [REGRESSION GUARD XACA-0819-014]: parent item — startedAt untouched throughout (item level was never part of this sync)" \
   "$([ "$_P1_STARTED_AT_AFTER_RESUME" = "$SEED_STARTED_AT" ] && echo 1 || echo 0)" \
   "expected startedAt still '$SEED_STARTED_AT', got '$_P1_STARTED_AT_AFTER_RESUME'"

# ─────────────────────────────────────────────────────────────────────────────

# Re-assert the sandbox gate before this section's mutating calls (XACA-0819-018):
# the header claims EVERY board-mutating call is gated, so every section must gate.
_assert_board_in_sandbox
# Coverage 2: SUBITEM pick -> pause -> resume cycle (workingOnId = subitem id).
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

# 3b: exactly ONE real call site file-wide (XACA-0819-014: subitem-only now,
# so the parent-item call site that used to exist is gone).
_CALL_COUNT_TOTAL=$(grep -c '_kb_flush_work_time "' "$RENDERED" 2>/dev/null)
[ -n "$_CALL_COUNT_TOTAL" ] || _CALL_COUNT_TOTAL=0
ok "3b [XACA-0819-014]: exactly 1 real _kb_flush_work_time call site file-wide (subitem-only scope)" \
   "$([ "$_CALL_COUNT_TOTAL" -eq 1 ] && echo 1 || echo 0)" \
   "expected 1 call site (call-shaped substring '_kb_flush_work_time \"'), found $_CALL_COUNT_TOTAL"

# 3c: isolate kb-pause's own function body (from its header to its own
# top-level closing brace) and confirm the call site falls inside it.
KB_PAUSE_BODY="$WORK_DIR/kb-pause-body.txt"
awk '
  /^kb-pause\(\) \{/ { flag=1; print; next }
  flag && /^\}$/ { print; flag=0; next }
  flag { print }
' "$RENDERED" > "$KB_PAUSE_BODY"
_KB_PAUSE_LINES=$(wc -l < "$KB_PAUSE_BODY" | tr -d '[:space:]')
_CALL_COUNT_IN_PAUSE=$(grep -c '_kb_flush_work_time "' "$KB_PAUSE_BODY" 2>/dev/null)
[ -n "$_CALL_COUNT_IN_PAUSE" ] || _CALL_COUNT_IN_PAUSE=0
ok "3c: the _kb_flush_work_time call site is inside kb-pause (body=${_KB_PAUSE_LINES} lines, calls found=${_CALL_COUNT_IN_PAUSE})" \
   "$([ -n "$_KB_PAUSE_LINES" ] && [ "$_KB_PAUSE_LINES" -gt 20 ] && [ "$_CALL_COUNT_IN_PAUSE" -eq 1 ] && echo 1 || echo 0)" \
   "expected kb-pause body >20 lines with exactly 1 call site; got ${_KB_PAUSE_LINES} lines / ${_CALL_COUNT_IN_PAUSE} calls"

# 3d [XACA-0819-014 GUARD]: isolate kb-pause's PARENT-ITEM jq branch (between
# its `if .id == $workingOnId then` header and the following
# `elif (.subitems ...` marker) and confirm it contains ZERO timeWorkedMs
# writes and ZERO del(.workStartedAt) calls. Uses plain substring matching
# (awk index(), not a /regex/ literal) deliberately -- an earlier draft of
# this extraction used a /.../ regex containing an escaped `//` that is
# fragile inside a regex delimiter and silently ran past its intended stop
# marker to end-of-function during manual verification; index() sidesteps
# that class of bug entirely by never treating the pattern as a regex.
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
ok "3d [XACA-0819-014 GUARD]: kb-pause's parent-item branch has ZERO timeWorkedMs writes and ZERO del(.workStartedAt) (branch=${_ITEM_BRANCH_LINES} lines)" \
   "$([ -n "$_ITEM_BRANCH_LINES" ] && [ "$_ITEM_BRANCH_LINES" -ge 3 ] && [ "$_ITEM_BRANCH_TWM" -eq 0 ] && [ "$_ITEM_BRANCH_DEL" -eq 0 ] && echo 1 || echo 0)" \
   "expected item branch >=3 lines, 0 timeWorkedMs writes, 0 del(.workStartedAt); got ${_ITEM_BRANCH_LINES} lines / ${_ITEM_BRANCH_TWM} timeWorkedMs mentions / ${_ITEM_BRANCH_DEL} del(.workStartedAt) — a non-zero count means the item-level write was re-added without its counterpart flush machinery (see Coverage 1)"

# 3e: isolate `kb-backlog demote`'s case arm (from its case label to the next
# case label at the same indentation) and confirm ZERO real call sites — the
# XACA-0884/XACA-0552 inversion guard. The arm's prose comments MENTION the
# function name but do not contain the call-shaped substring, so this grep
# correctly ignores them.
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

# ─────────────────────────────────────────────────────────────────────────────
# Coverage 4: demote freeze behavior — a stale workStartedAt must be
# DISCARDED, and timeWorkedMs must be left EXACTLY at its seeded value (not
# inflated by a naive flush-on-demote). Fixture: workStartedAt ~142 days
# stale — a naive flush would book ~12.27 BILLION ms of phantom work.
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
# least 17 assertions (5 item + 6 subitem[a-f] + 5 static + 3 demote = 19
# planned) so a future accidental short-circuit that skips whole sections is
# still caught.
if [ "$_P0819_FAIL" -gt 0 ] || [ "$_TOTAL" -lt 17 ]; then
    exit 1
fi
exit 0
