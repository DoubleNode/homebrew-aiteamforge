#!/bin/bash
# test-xaca-0788-crash-recovery-in-tap.sh
#
# XACA-0788: ports the crash-recovery reconciliation engine (XACA-0778) from
# canonical dev-team/kanban-helpers.sh into the tap-shipped template
# share/templates/kanban/kanban-helpers.template.sh. Six functions were ported —
#   _kb_tmux_live_window_ids
#   _kb_reconcile_plan_doc_path
#   _kb_reconcile_inprogress   (the pure read-only BOUND/ORPHANED classifier)
#   kb-reconcile-inprogress
#   kb-recover
#   _kb_resume_rebind
# plus an arg-dispatch graft on the existing kb-resume (kb-resume <ID> now
# routes to _kb_resume_rebind).
#
# The classifier _kb_reconcile_inprogress <team> [board_file] reads
# backlog[].status==in_progress items, resolves each item's persistent
# worktreeWindowId ("terminal:window_name") against the LIVE tmux windows for
# the team's "<team>-<terminal>" sessions, and emits a JSON array classifying
# each as BOUND (window alive) or ORPHANED (window gone). It is READ-ONLY: it
# never mutates the board or tmux, and emits "[]" (not an error) for a
# missing/unreadable board.
#
# XACA-0830 (ported subsequently): "window alive" now REQUIRES a live Claude
# process among the pane's descendants -- a window that merely still exists
# (Claude killed by jetsam, pane idling at a shell prompt) no longer counts
# as BOUND. The C0/C0b fixture below runs a fake `claude` process in the
# pane (not a bare shell) to exercise this contract; see the fixture comment
# near FAKE_BIN_DIR for the technique, mirrored from the canonical
# tests/test-xaca-0830-tmux-liveness.sh.
#
# This suite proves the engine SHIPS and BEHAVES correctly out of the tap
# template, using the P088 reference technique: a KB_BOARD_FILE-style scratch
# board (passed directly as the classifier's 2nd positional arg) crossed with a
# disposable "<team>-<terminal>" tmux session whose team slug can never collide
# with any real fleet session. Verified read-only via a byte-identical
# before/after board comparison, and teardown kills only the throwaway session.
#
#   A. Render + hygiene — no {{placeholder}} survives; the ported region carries
#      no ~/dev-team / $HOME/dev-team coupling.
#   B. Definition parity — all 6 ported functions + kb-resume are defined.
#   C. Behavioral (the core value) — a live-window item classifies BOUND, a
#      dead-window item classifies ORPHANED (with a NEGATIVE CONTROL asserting
#      the orphan is NOT BOUND, so a broken classifier fails loudly).
#   D. Read-only guarantee — the scratch board is byte-identical after classify.
#   E. Missing-board contract — a nonexistent board yields "[]" and rc 0.
#   F. Graceful no-tmux — with tmux unreachable, classify still exits 0, emits
#      valid JSON, and does not crash or leak a "command not found"/traceback.
#
# The template is a zsh script (#!/bin/zsh) using zsh-isms; every classifier
# invocation runs under `zsh -c "source <rendered>; ..."`. Sandboxed: HOME +
# AITEAMFORGE_DIR redirected under TEST_TMP_DIR, no real $HOME mutation, no
# network. Requires: bash, zsh, tmux, jq.
#
# Runs standalone (`bash tests/test-xaca-0788-crash-recovery-in-tap.sh`) OR via
# tests/test-runner.sh. Exit 0 = all assertions pass, exit 1 = any fail.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="$TAP_ROOT/share/templates/kanban/kanban-helpers.template.sh"

if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "FATAL: kanban-helpers.template.sh not found at: $TEMPLATE_PATH" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Hard prerequisites. tmux liveness IS the system under test — if it is
# unavailable we CANNOT stub the behavioral case into a vacuous pass, so we
# fail loudly instead (matches the escalation contract in the ticket).
# ─────────────────────────────────────────────────────────────────────────────
for _tool in zsh tmux jq; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        echo "FATAL: required tool '$_tool' not on PATH — cannot run behavioral crash-recovery tests." >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (mirrors test-xaca-0770's pattern): provide test_start/
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
# passed" vacuously. We increment _P0788_PASS on EVERY successful assertion,
# print an explicit "Passed: N / Total: M", and exit non-zero if any assertion
# failed — true both standalone and under test-runner.sh.
# ─────────────────────────────────────────────────────────────────────────────
_P0788_PASS=0
_P0788_FAIL=0

# ok <label> <cond(1|0)> [failure_detail]
ok() {
    local label="$1" cond="$2" detail="${3:-}"
    test_start "$label"
    if [ "$cond" = "1" ]; then
        _P0788_PASS=$((_P0788_PASS + 1)); test_pass
    else
        _P0788_FAIL=$((_P0788_FAIL + 1)); test_fail "$detail"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0788-crash-recovery-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
WORK_DIR="$TEST_TMP_DIR/xaca0788"
mkdir -p "$WORK_DIR"

# XACA-0830: process-liveness fixture. Since the port, a tmux window that
# merely EXISTS no longer counts as BOUND -- the classifier now walks the
# pane's process descendants for a live Claude process (Defect B). A
# throwaway script literally named `claude` stands in for a live Claude
# session's foreground process, mirroring the canonical dev-team fixture in
# tests/test-xaca-0830-tmux-liveness.sh Case A: comm alone is not trusted
# (a shebang-exec'd script can report its interpreter as `comm`), so the
# match rule also scans argv tokens for a basename of "claude" -- this
# script's own invocation path ends in "/claude", satisfying that half of
# the rule regardless of how `comm` resolves on this OS.
FAKE_BIN_DIR="$WORK_DIR/bin"
mkdir -p "$FAKE_BIN_DIR"
cat > "$FAKE_BIN_DIR/claude" <<'EOF'
#!/bin/sh
sleep 600
EOF
chmod +x "$FAKE_BIN_DIR/claude"

# A throwaway team slug (contains NO dash, so the "<team>-<terminal>" split is
# unambiguous) unique to this PID — can never collide with a real fleet session
# such as academy-agent. The terminal component is "agent".
TEAM="xaca0788t$$"
SESSION="${TEAM}-agent"

cleanup() {
    # Kill ONLY our throwaway session — real fleet sessions are untouched.
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# A. Render the template into the sandbox. AITEAMFORGE_DIR is exported BEFORE
# rendering and substituted along with the other install-time placeholders.
# ─────────────────────────────────────────────────────────────────────────────
export AITEAMFORGE_DIR="$WORK_DIR/aiteamforge"
RENDERED="$WORK_DIR/kanban-helpers-rendered.sh"
sed "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g; \
     s|{{SHARED_DEV_ROOT}}|$WORK_DIR/shared|g; \
     s|{{ORG_NAME}}|TestOrg|g; \
     s|{{ORG_SLUG}}|testorg|g" \
    "$TEMPLATE_PATH" > "$RENDERED"

# A1: NO {{...}} placeholder survives anywhere in the rendered file.
# NOTE: `grep -c` prints "0" AND exits 1 on no-match, so do NOT append `|| echo 0`
# (that would emit a second "0" line and break the integer test).
_A1_LEFT=$(grep -c '{{' "$RENDERED" 2>/dev/null)
[ -n "$_A1_LEFT" ] || _A1_LEFT=0
ok "A1: no {{placeholder}} survives in the rendered template" \
   "$([ "$_A1_LEFT" -eq 0 ] && echo 1 || echo 0)" \
   "found $_A1_LEFT residual '{{' placeholder(s): $(grep -oE '\{\{[A-Z_]+\}\}' "$RENDERED" | sort -u | tr '\n' ' ')"

# A2: the ported crash-recovery region carries no ~/dev-team / $HOME/dev-team
# coupling. Extract from the section header through the line before kb-sweep()
# (the next top-level function after the kb-resume graft) and grep it.
_PORTED_REGION="$WORK_DIR/ported-region.sh"
awk '/# Crash-Recovery Reconciliation Engine \(XACA-0778-001\)/{flag=1} /^kb-sweep\(\) \{/{flag=0} flag{print}' \
    "$RENDERED" > "$_PORTED_REGION"
_A2_LINES=$(wc -l < "$_PORTED_REGION" | tr -d '[:space:]')
_A2_BAD=$(grep -nE '~/dev-team|\$HOME/dev-team|\$\{HOME\}/dev-team' "$_PORTED_REGION" || true)
ok "A2: ported crash-recovery region has no ~/dev-team / \$HOME/dev-team coupling (region=${_A2_LINES} lines)" \
   "$([ -n "$_A2_LINES" ] && [ "$_A2_LINES" -gt 100 ] && [ -z "$_A2_BAD" ] && echo 1 || echo 0)" \
   "region extracted ${_A2_LINES} lines; offending dev-team refs: ${_A2_BAD:-<none but region too small?>}"

# ─────────────────────────────────────────────────────────────────────────────
# B. Definition parity — all 6 ported functions + kb-resume are defined after
# sourcing the rendered template under zsh.
# ─────────────────────────────────────────────────────────────────────────────
PORTED_FNS=(
    _kb_tmux_live_window_ids
    _kb_reconcile_plan_doc_path
    _kb_reconcile_inprogress
    kb-reconcile-inprogress
    kb-recover
    _kb_resume_rebind
    kb-resume
)
_B_MISSING=()
for fn in "${PORTED_FNS[@]}"; do
    _defn=$(zsh -c "source '$RENDERED' >/dev/null 2>&1; typeset -f '$fn' >/dev/null 2>&1 && echo DEFINED || echo MISSING")
    [ "$_defn" = "DEFINED" ] || _B_MISSING+=("$fn")
done
ok "B: all ${#PORTED_FNS[@]} crash-recovery functions (6 ported + kb-resume graft) are defined" \
   "$([ ${#_B_MISSING[@]} -eq 0 ] && echo 1 || echo 0)" \
   "missing: ${_B_MISSING[*]}"

# ── B2: kb-resume dispatches to _kb_resume_rebind when given an ID arg ─────────
# Structural proof the arg-dispatch graft is present (not just that both fns
# exist independently): kb-resume's body must reference _kb_resume_rebind.
_B2_BODY=$(zsh -c "source '$RENDERED' >/dev/null 2>&1; typeset -f kb-resume 2>/dev/null")
ok "B2: kb-resume body routes an ID arg to _kb_resume_rebind (dispatch graft present)" \
   "$(echo "$_B2_BODY" | grep -q '_kb_resume_rebind' && echo 1 || echo 0)" \
   "kb-resume body does not reference _kb_resume_rebind"

# ─────────────────────────────────────────────────────────────────────────────
# Build the scratch board (P088): TWO status==in_progress items plus one
# non-in_progress item that must be ignored.
#   XTST-0001 -> worktreeWindowId "agent:main"     -> will be BOUND (window live)
#   XTST-0002 -> worktreeWindowId "agent:ghostwin" -> will be ORPHANED (no window)
#   XTST-0003 -> status "todo"                      -> must NOT appear at all
# ─────────────────────────────────────────────────────────────────────────────
BOARD="$WORK_DIR/${TEAM}-board.json"
cat > "$BOARD" <<'JSON'
{
  "nextId": 4,
  "activeWindows": [],
  "backlog": [
    {
      "id": "XTST-0001",
      "title": "Live-window item",
      "status": "in_progress",
      "worktreeWindowId": "agent:main",
      "worktree": "/tmp/wt-xtst-0001",
      "worktreeBranch": "feature/xtst-0001"
    },
    {
      "id": "XTST-0002",
      "title": "Dead-window item",
      "status": "in_progress",
      "worktreeWindowId": "agent:ghostwin",
      "worktree": "/tmp/wt-xtst-0002",
      "worktreeBranch": "feature/xtst-0002"
    },
    {
      "id": "XTST-0003",
      "title": "Not started",
      "status": "todo"
    }
  ]
}
JSON

# Disposable tmux session for the team with a window named "main", running
# the fake `claude` process (XACA-0830: a plain shell pane no longer counts
# as live -- see the fixture comment above). Its stable window-id key
# resolves to "agent:main" (session "<team>-agent" -> terminal "agent";
# window name "main"), matching XTST-0001's worktreeWindowId only.
tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -n main -x 80 -y 24 "$FAKE_BIN_DIR/claude"
_SESSION_UP=$(tmux has-session -t "$SESSION" 2>/dev/null && echo 1 || echo 0)
ok "C0: disposable tmux session '$SESSION' (window 'main', live 'claude' process) created for the behavioral test" \
   "$_SESSION_UP" \
   "could not create ephemeral tmux session '$SESSION'"

# Sanity: the live-window resolver sees exactly our team window "agent:main".
_LIVE=$(zsh -c "source '$RENDERED' >/dev/null 2>&1; _kb_tmux_live_window_ids '$TEAM'")
ok "C0b: _kb_tmux_live_window_ids '$TEAM' reports the live 'agent:main' window key" \
   "$([ "$_LIVE" = "agent:main" ] && echo 1 || echo 0)" \
   "expected exactly 'agent:main', got: [$_LIVE]"

# ─────────────────────────────────────────────────────────────────────────────
# D (setup): capture a pristine copy + cksum of the board BEFORE any classify
# call, to prove read-only afterward.
# ─────────────────────────────────────────────────────────────────────────────
BOARD_PRISTINE="$WORK_DIR/board.pristine.json"
cp "$BOARD" "$BOARD_PRISTINE"
_CKSUM_BEFORE=$(cksum "$BOARD" | awk '{print $1, $2}')

# ─────────────────────────────────────────────────────────────────────────────
# C. Behavioral core: classify the two in_progress items.
# ─────────────────────────────────────────────────────────────────────────────
CLASSIFY_OUT="$WORK_DIR/classify.json"
zsh -c "source '$RENDERED' >/dev/null 2>&1; _kb_reconcile_inprogress '$TEAM' '$BOARD'" > "$CLASSIFY_OUT" 2>"$WORK_DIR/classify.err"
_CLASSIFY_RC=$?

# The output must be a valid JSON array of exactly 2 objects (the todo item is
# excluded), with the exact contract field names present.
_CNT=$(jq -r 'length' "$CLASSIFY_OUT" 2>/dev/null || echo -1)
ok "C1: classifier returns rc 0 and a 2-element JSON array (todo item excluded)" \
   "$([ "$_CLASSIFY_RC" -eq 0 ] && [ "$_CNT" = "2" ] && echo 1 || echo 0)" \
   "rc=$_CLASSIFY_RC length=$_CNT out=$(cat "$CLASSIFY_OUT") err=$(cat "$WORK_DIR/classify.err")"

# Contract-field presence on the first element (id/title/team/parentId/worktree/
# branch/planDocPath/lastKnownWindow/classification).
_FIELDS_OK=$(jq -e '
  .[0] | has("id") and has("title") and has("team") and has("parentId")
       and has("worktree") and has("branch") and has("planDocPath")
       and has("lastKnownWindow") and has("classification")' "$CLASSIFY_OUT" >/dev/null 2>&1 && echo 1 || echo 0)
ok "C2: classified objects carry the full XACA-0778 output-contract field set" \
   "$_FIELDS_OK" \
   "missing one or more contract fields; got: $(jq -c '.[0]' "$CLASSIFY_OUT" 2>/dev/null)"

# The live-window item (XTST-0001) classifies BOUND.
_CLASS_1=$(jq -r '.[] | select(.id=="XTST-0001") | .classification' "$CLASSIFY_OUT" 2>/dev/null)
ok "C3: live-window item XTST-0001 classifies BOUND" \
   "$([ "$_CLASS_1" = "BOUND" ] && echo 1 || echo 0)" \
   "expected BOUND, got: [$_CLASS_1]"

# The dead-window item (XTST-0002) classifies ORPHANED.
_CLASS_2=$(jq -r '.[] | select(.id=="XTST-0002") | .classification' "$CLASSIFY_OUT" 2>/dev/null)
ok "C4: dead-window item XTST-0002 classifies ORPHANED" \
   "$([ "$_CLASS_2" = "ORPHANED" ] && echo 1 || echo 0)" \
   "expected ORPHANED, got: [$_CLASS_2]"

# ── NEGATIVE CONTROL ──────────────────────────────────────────────────────────
# The deliberately-orphaned item must NOT be classified BOUND. A classifier that
# blindly returns BOUND (e.g. a broken live-window match that always succeeds)
# would fail HERE rather than sneak through — this is the guard against a
# vacuous green suite that never distinguishes real behavior.
ok "C5 [NEGATIVE CONTROL]: deliberately-orphaned XTST-0002 is NOT classified BOUND" \
   "$([ "$_CLASS_2" != "BOUND" ] && echo 1 || echo 0)" \
   "orphan was mis-classified BOUND — classifier is not distinguishing live vs dead windows"

# Second negative control: the todo item never leaks into the manifest.
_HAS_TODO=$(jq -r 'any(.[]; .id=="XTST-0003")' "$CLASSIFY_OUT" 2>/dev/null)
ok "C6 [NEGATIVE CONTROL]: non-in_progress item XTST-0003 is absent from the manifest" \
   "$([ "$_HAS_TODO" = "false" ] && echo 1 || echo 0)" \
   "todo item XTST-0003 leaked into the reconciliation manifest"

# ─────────────────────────────────────────────────────────────────────────────
# D. Read-only guarantee: the board is byte-identical after classify.
# ─────────────────────────────────────────────────────────────────────────────
_CKSUM_AFTER=$(cksum "$BOARD" | awk '{print $1, $2}')
_BYTES_IDENTICAL=$(cmp -s "$BOARD" "$BOARD_PRISTINE" && echo 1 || echo 0)
ok "D: classify is READ-ONLY — scratch board is byte-identical afterward" \
   "$([ "$_BYTES_IDENTICAL" = "1" ] && [ "$_CKSUM_BEFORE" = "$_CKSUM_AFTER" ] && echo 1 || echo 0)" \
   "board mutated: cmp_identical=$_BYTES_IDENTICAL cksum_before='$_CKSUM_BEFORE' cksum_after='$_CKSUM_AFTER'"

# ─────────────────────────────────────────────────────────────────────────────
# E. Missing-board contract: a nonexistent board yields "[]" and rc 0.
# ─────────────────────────────────────────────────────────────────────────────
_MISS_OUT=$(zsh -c "source '$RENDERED' >/dev/null 2>&1; _kb_reconcile_inprogress '$TEAM' '$WORK_DIR/does-not-exist.json'; echo RC=\$?" 2>/dev/null)
_MISS_RC=$(echo "$_MISS_OUT" | grep -oE 'RC=[0-9]+' | tail -1 | cut -d= -f2)
_MISS_JSON=$(echo "$_MISS_OUT" | grep -v '^RC=' | tr -d '[:space:]')
ok "E: missing board file -> emits '[]' and exits 0 (not an error)" \
   "$([ "$_MISS_JSON" = "[]" ] && [ "$_MISS_RC" = "0" ] && echo 1 || echo 0)" \
   "expected '[]' + rc 0; got json='$_MISS_JSON' rc='$_MISS_RC' raw='$_MISS_OUT'"

# ─────────────────────────────────────────────────────────────────────────────
# F. Graceful no-tmux: with tmux unreachable, classify still exits 0, emits
# valid JSON (every candidate ORPHANED), and does not crash or leak a
# "command not found"/traceback. Simulated by shadowing `tmux` with a function
# returning 127 — this drives the classifier's `tmux list-sessions || return 0`
# degradation guard, the realistic post-crash "server is gone" state.
# ─────────────────────────────────────────────────────────────────────────────
_NOTMUX_OUT="$WORK_DIR/notmux.json"
_NOTMUX_ERR="$WORK_DIR/notmux.err"
zsh -c "
    source '$RENDERED' >/dev/null 2>&1
    tmux() { return 127; }
    _kb_reconcile_inprogress '$TEAM' '$BOARD'
" > "$_NOTMUX_OUT" 2>"$_NOTMUX_ERR"
_NOTMUX_RC=$?
_NOTMUX_LEN=$(jq -r 'length' "$_NOTMUX_OUT" 2>/dev/null || echo -1)
_NOTMUX_ALL_ORPHANED=$(jq -e 'length==2 and all(.[]; .classification=="ORPHANED")' "$_NOTMUX_OUT" >/dev/null 2>&1 && echo 1 || echo 0)
_NOTMUX_LEAK=$( { cat "$_NOTMUX_OUT" "$_NOTMUX_ERR"; } | grep -qiE 'command not found|traceback' && echo 1 || echo 0)
ok "F: tmux unavailable -> classify exits 0, emits valid JSON, all items ORPHANED, no crash/leak" \
   "$([ "$_NOTMUX_RC" -eq 0 ] && [ "$_NOTMUX_ALL_ORPHANED" = "1" ] && [ "$_NOTMUX_LEAK" = "0" ] && echo 1 || echo 0)" \
   "rc=$_NOTMUX_RC len=$_NOTMUX_LEN all_orphaned=$_NOTMUX_ALL_ORPHANED leak=$_NOTMUX_LEAK out=$(cat "$_NOTMUX_OUT") err=$(cat "$_NOTMUX_ERR")"

# F2: the real "no live session for this team" case (session killed) also
# degrades cleanly — this is the universal post-crash orphan state.
tmux kill-session -t "$SESSION" 2>/dev/null || true
_NOSESS_OUT="$WORK_DIR/nosession.json"
zsh -c "source '$RENDERED' >/dev/null 2>&1; _kb_reconcile_inprogress '$TEAM' '$BOARD'" > "$_NOSESS_OUT" 2>/dev/null
_NOSESS_RC=$?
_NOSESS_ALL_ORPHANED=$(jq -e 'length==2 and all(.[]; .classification=="ORPHANED")' "$_NOSESS_OUT" >/dev/null 2>&1 && echo 1 || echo 0)
ok "F2: no live session for the team -> classify exits 0, all items ORPHANED (post-crash universal-orphan)" \
   "$([ "$_NOSESS_RC" -eq 0 ] && [ "$_NOSESS_ALL_ORPHANED" = "1" ] && echo 1 || echo 0)" \
   "rc=$_NOSESS_RC all_orphaned=$_NOSESS_ALL_ORPHANED out=$(cat "$_NOSESS_OUT")"

# ─────────────────────────────────────────────────────────────────────────────
# Summary — explicit real assertion count (defeats vacuous-green).
# ─────────────────────────────────────────────────────────────────────────────
_TOTAL=$((_P0788_PASS + _P0788_FAIL))
echo ""
echo "──────────────────────────────────────────────────────────────"
echo "XACA-0788 crash-recovery-in-tap: Passed: ${_P0788_PASS} / Total: ${_TOTAL}  (Failed: ${_P0788_FAIL})"
echo "──────────────────────────────────────────────────────────────"

if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_P0788_PASS} passed, ${_P0788_FAIL} failed"
fi

# Exit non-zero if ANY assertion failed OR if zero real assertions ran (a
# zero-assertion run is itself a harness failure, never a pass).
if [ "$_P0788_FAIL" -gt 0 ] || [ "$_TOTAL" -eq 0 ]; then
    exit 1
fi
exit 0
