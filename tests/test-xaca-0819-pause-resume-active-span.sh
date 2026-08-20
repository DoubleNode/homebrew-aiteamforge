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
# pause/resume cycle -- see the ticket's evidence). The fix:
#   - kb-pause now flushes the active span via the newly-ported
#     _kb_flush_work_time() into timeWorkedMs, then clears workStartedAt --
#     for BOTH the parent-item branch and the subitem branch of its jq filter.
#   - kb-resume now opens a FRESH span (`workStartedAt = $timestamp`) and
#     seeds `startedAt` only if absent (`startedAt //= $timestamp`) so the
#     item's original start time is never clobbered by a later resume --
#     again for both branches.
#   - `_kb_flush_work_time` is a pure, read-only-of-intent helper: it computes
#     existing_time_ms + elapsed(workStartedAt..now), but does NOT write
#     anything itself; kb-pause applies its result via the jq --arg timeMs.
#   - `kb-backlog demote` (XACA-0884/XACA-0552) is DELIBERATELY NOT wired to
#     this helper -- a demoted item's open workStartedAt must be DISCARDED,
#     never credited, or a stale span (observed: ~4 months) would be booked
#     as phantom work. This suite's static assertions are the enforcement
#     mechanism the template's own comments point back to.
#
# THE PLATFORM TRAP (XACA-0819 ticket note, confirmed by reading the code):
# _kb_flush_work_time parses timestamps via `date -j -f`, which is BSD/macOS-
# only, with zero GNU `date -d` fallback anywhere in this template. Tap CI
# runs ubuntu-latest, where that parse fails, the `|| echo "0"` guard fires,
# and elapsed computes as exactly ZERO (existing_time_ms passes through
# unchanged). This suite therefore NEVER asserts "elapsed time grew" -- every
# assertion below is chosen to hold on BOTH macOS (seed + real elapsed) and
# Linux (elapsed == 0, i.e. exactly the seed) while still being sensitive to
# the actual regression:
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
# Both the pause and resume jq filters carry TWO branches (parent-item id
# match, and subitem id match within `.subitems[]`) -- both were changed by
# this port and both are exercised here (Coverage 1 + 2 below).
#
# Coverage:
#   A. Render + hygiene -- no {{placeholder}} survives the rendered template.
#   1. Parent-item path: full pick-state -> pause -> resume cycle, asserting
#      (a)-(e) on the top-level backlog item.
#   2. Subitem path: same cycle, asserting (a)-(e) on a subitem nested under
#      a parent item (`workingOnId` set to the SUBITEM id).
#   3. Static structural assertions on the (unmodified, real) template:
#        - exactly 1 _kb_flush_work_time function definition
#        - exactly 2 real call sites (`_kb_flush_work_time "`), and BOTH fall
#          inside kb-pause's own line range (extracted by isolating the
#          function body between its `kb-pause() {` header and its own
#          top-level closing `}`)
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
# Coverage 1: PARENT-ITEM pick -> pause -> resume cycle.
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
ok "1a: parent item — workStartedAt is ABSENT after pause" \
   "$([ "$_P1_WSA_AFTER_PAUSE" = "false" ] && echo 1 || echo 0)" \
   "expected workStartedAt absent, has()=$_P1_WSA_AFTER_PAUSE; board=$(cat "$BOARD")"

_P1_TWM_AFTER_PAUSE=$(jq -r '.backlog[0].timeWorkedMs' "$BOARD")
ok "1b: parent item — timeWorkedMs >= seeded value ($SEED_TIME_MS) after pause" \
   "$([ "${_P1_TWM_AFTER_PAUSE:-0}" -ge "$SEED_TIME_MS" ] 2>/dev/null && echo 1 || echo 0)" \
   "expected >= $SEED_TIME_MS, got $_P1_TWM_AFTER_PAUSE"

zsh -c "source '$RENDERED' >/dev/null 2>&1; kb-resume" >"$WORK_DIR/p1-resume.out" 2>&1
_P1_WSA_AFTER_RESUME=$(jq -r '.backlog[0] | has("workStartedAt")' "$BOARD")
ok "1c: parent item — workStartedAt is PRESENT after resume" \
   "$([ "$_P1_WSA_AFTER_RESUME" = "true" ] && echo 1 || echo 0)" \
   "expected workStartedAt present, has()=$_P1_WSA_AFTER_RESUME"

_P1_TWM_AFTER_RESUME=$(jq -r '.backlog[0].timeWorkedMs' "$BOARD")
ok "1d [REGRESSION GUARD]: parent item — timeWorkedMs UNCHANGED across resume ($_P1_TWM_AFTER_PAUSE -> $_P1_TWM_AFTER_RESUME)" \
   "$([ "$_P1_TWM_AFTER_RESUME" = "$_P1_TWM_AFTER_PAUSE" ] && echo 1 || echo 0)" \
   "post-pause timeWorkedMs=$_P1_TWM_AFTER_PAUSE, post-resume timeWorkedMs=$_P1_TWM_AFTER_RESUME — a mismatch means the active span was lost or re-banked across resume"

_P1_STARTED_AT_AFTER_RESUME=$(jq -r '.backlog[0].startedAt' "$BOARD")
ok "1e: parent item — startedAt preserved across resume (proves //= not =)" \
   "$([ "$_P1_STARTED_AT_AFTER_RESUME" = "$SEED_STARTED_AT" ] && echo 1 || echo 0)" \
   "expected startedAt still '$SEED_STARTED_AT', got '$_P1_STARTED_AT_AFTER_RESUME'"

# ─────────────────────────────────────────────────────────────────────────────
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

# 3b: exactly TWO real call sites file-wide (call-shaped substring, not mere mentions).
_CALL_COUNT_TOTAL=$(grep -c '_kb_flush_work_time "' "$RENDERED" 2>/dev/null)
[ -n "$_CALL_COUNT_TOTAL" ] || _CALL_COUNT_TOTAL=0
ok "3b: exactly 2 real _kb_flush_work_time call sites file-wide" \
   "$([ "$_CALL_COUNT_TOTAL" -eq 2 ] && echo 1 || echo 0)" \
   "expected 2 call sites (call-shaped substring '_kb_flush_work_time \"'), found $_CALL_COUNT_TOTAL"

# 3c: isolate kb-pause's own function body (from its header to its own
# top-level closing brace) and confirm BOTH call sites fall inside it.
KB_PAUSE_BODY="$WORK_DIR/kb-pause-body.txt"
awk '
  /^kb-pause\(\) \{/ { flag=1; print; next }
  flag && /^\}$/ { print; flag=0; next }
  flag { print }
' "$RENDERED" > "$KB_PAUSE_BODY"
_KB_PAUSE_LINES=$(wc -l < "$KB_PAUSE_BODY" | tr -d '[:space:]')
_CALL_COUNT_IN_PAUSE=$(grep -c '_kb_flush_work_time "' "$KB_PAUSE_BODY" 2>/dev/null)
[ -n "$_CALL_COUNT_IN_PAUSE" ] || _CALL_COUNT_IN_PAUSE=0
ok "3c: both _kb_flush_work_time call sites are inside kb-pause (body=${_KB_PAUSE_LINES} lines, calls found=${_CALL_COUNT_IN_PAUSE})" \
   "$([ -n "$_KB_PAUSE_LINES" ] && [ "$_KB_PAUSE_LINES" -gt 20 ] && [ "$_CALL_COUNT_IN_PAUSE" -eq 2 ] && echo 1 || echo 0)" \
   "expected kb-pause body >20 lines with exactly 2 call sites; got ${_KB_PAUSE_LINES} lines / ${_CALL_COUNT_IN_PAUSE} calls"

# 3d: isolate `kb-backlog demote`'s case arm (from its case label to the next
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
ok "3d [INVERSION GUARD]: zero real _kb_flush_work_time call sites inside kb-backlog demote arm (arm=${_DEMOTE_ARM_LINES} lines, comment mentions=${_MENTION_COUNT_IN_DEMOTE}, real calls=${_CALL_COUNT_IN_DEMOTE})" \
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
# least 13 assertions (5 x2 cycles + 4 static + 3 demote = 17 planned) so a
# future accidental short-circuit that skips whole sections is still caught.
if [ "$_P0819_FAIL" -gt 0 ] || [ "$_TOTAL" -lt 13 ]; then
    exit 1
fi
exit 0
