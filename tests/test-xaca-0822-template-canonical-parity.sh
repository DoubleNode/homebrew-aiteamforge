#!/bin/bash
# test-xaca-0822-template-canonical-parity.sh
# Regression tests for XACA-0822 (retire canonical-vs-tap kb-* function drift):
# ports canonical fixes into kanban-helpers.template.sh that had drifted
# out of sync. Covers XACA-0822-002, -005, -006, -008 with functional
# assertions (sourced and executed), and XACA-0822-004 with a static content
# assertion (it fixes a literal string embedded in echo/prompt text, not
# control flow).
#
# NOTE ON SHELL: kanban-helpers.template.sh is #!/bin/zsh and uses zsh-only
# constructs (e.g. brace-group command lists without a trailing `;`) starting
# well before any of the functions under test here. `bash -n` on the whole
# file reports a syntax error at a zsh-only construct that predates every
# function this suite exercises, and sourcing the file under bash stops
# parsing at that point — none of kb-backlog, _kb_team_lcars_port, or
# kb-release-create ever get defined under bash. This suite therefore sources
# the substituted template under zsh (its actual target shell), not bash.
#
# Designed to run standalone OR via test-runner.sh.
# Exit 0 = all cases pass. Exit 1 = at least one case failed.
#
# Requires: zsh, jq

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="$TAP_ROOT/share/templates/kanban/kanban-helpers.template.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Minimal self-contained test framework (mirrors test-xaca-0649's fallback
# pattern: only define these if test-runner.sh hasn't already exported them).
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
_PASS=0
_FAIL=0
_CURRENT_TEST=""

if ! declare -F test_start &>/dev/null; then
    _STANDALONE=true
    test_start() { _CURRENT_TEST="$1"; }
fi
if ! declare -F test_pass &>/dev/null; then
    test_pass() {
        _PASS=$((_PASS + 1))
        printf "  PASS: %s\n" "$_CURRENT_TEST"
    }
fi
if ! declare -F test_fail &>/dev/null; then
    test_fail() {
        _FAIL=$((_FAIL + 1))
        printf "  FAIL: %s — %s\n" "$_CURRENT_TEST" "${1:-}" >&2
    }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Expected-assertion-count guard ([Review] finding — vacuous-green prevention):
# without this, a case block silently skipped (an early `return`/`exit` inside
# a stubbed helper, a block accidentally commented/deleted) reports a SMALLER
# total and this script still exits 0. $_PASS/$_FAIL above are NOT a reliable
# per-file case count to gate on: under test-runner.sh, test_start/test_pass/
# test_fail are the RUNNER's own exported functions (this file's `if !
# declare -F ...` fallbacks above never fire), so $_PASS/$_FAIL stay 0 for
# this file's whole run — the runner keeps its own counters instead, shared
# across every suite it invokes that session. $_CASES_RUN below is local to
# THIS file: it wraps whichever test_start is active (the fallback just
# defined above, or the runner's) so every case counts, in either mode.
# ─────────────────────────────────────────────────────────────────────────────
_EXPECTED_CASES=10
_CASES_RUN=0
eval "$(declare -f test_start | sed '1s/^test_start[[:space:]]*(/_kb_xaca0822_test_start_inner (/')"
test_start() {
    _CASES_RUN=$((_CASES_RUN + 1))
    _kb_xaca0822_test_start_inner "$@"
}

if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "FATAL: kanban-helpers.template.sh not found at: $TEMPLATE_PATH" >&2
    exit 1
fi
if ! command -v zsh >/dev/null 2>&1; then
    echo "FATAL: zsh not found — required to source the template (see NOTE ON SHELL above)" >&2
    exit 1
fi

_TEST_TMP=""
_PROCESSED_TEMPLATE=""
_STDOUT_FILE="/tmp/xaca0822-parity-stdout.$$"
_STDERR_FILE="/tmp/xaca0822-parity-stderr.$$"
_BOARD_FILE=""

_setup_sandbox() {
    _TEST_TMP=$(mktemp -d -t xaca0822-parity.XXXXXX)
    _PROCESSED_TEMPLATE="$_TEST_TMP/kanban-helpers-template-substituted.sh"
    sed "s|{{AITEAMFORGE_DIR}}|${_TEST_TMP}/aiteamforge|g; \
         s|{{SHARED_DEV_ROOT}}|${_TEST_TMP}/shared|g; \
         s|{{ORG_NAME}}|TestOrg|g" \
        "$TEMPLATE_PATH" > "$_PROCESSED_TEMPLATE"

    _BOARD_FILE="$_TEST_TMP/board.json"
    cat > "$_BOARD_FILE" <<'EOF'
{"backlog": [], "lastUpdated": "", "nextId": 1, "teamCode": "TST"}
EOF
}

_teardown_sandbox() {
    [ -n "$_TEST_TMP" ] && [ -d "$_TEST_TMP" ] && rm -rf "$_TEST_TMP"
    _TEST_TMP=""
    _PROCESSED_TEMPLATE=""
    _BOARD_FILE=""
}

_cleanup() {
    rm -f "$_STDOUT_FILE" "$_STDERR_FILE"
    _teardown_sandbox
}
trap '_cleanup' EXIT INT TERM

# Run a zsh snippet with the substituted template sourced and test doubles
# for the environment functions (_kb_detect_context, board resolution, etc.)
# stubbed out so we exercise only the logic under test, not live tmux/LCARS
# state. $1 = zsh code to run after sourcing.
_run_zsh() {
    zsh --no-rcs -c "
        source '$_PROCESSED_TEMPLATE' 2>/dev/null
        # Isolation: on a machine that has the REAL aiteamforge-paths.sh loader
        # installed (e.g. this dev box's own ~/dev-team checkout), the template's
        # top-of-file loader block picks it up and defines a live
        # aiteamforge_team_lcars_port() — which _kb_team_lcars_port prefers over
        # its own built-in fallback table (by design, XACA-0168). That would
        # mask a bug in the fallback table itself behind this host's real,
        # correct answer. Neutralize it so tests exercise the fallback table.
        unset -f aiteamforge_team_lcars_port aiteamforge_team_kanban_dir 2>/dev/null
        $1
    " >"$_STDOUT_FILE" 2>"$_STDERR_FILE"
    return $?
}

_stdout() { cat "$_STDOUT_FILE" 2>/dev/null; }
_stderr() { cat "$_STDERR_FILE" 2>/dev/null; }

_setup_sandbox

# ─────────────────────────────────────────────────────────────────────────────
# XACA-0822-005a: _kb_team_lcars_port('mainevent') must be 8400, not 8234
# (8234 collides with 'command' — stale pre-XACA-0727/XACA-0463 value).
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0822-005: _kb_team_lcars_port mainevent resolves to 8400 (not command's 8234)"
_run_zsh 'echo "$(_kb_team_lcars_port mainevent)"'
got="$(_stdout | tail -1)"
if [ "$got" = "8400" ]; then
    test_pass
else
    test_fail "expected 8400, got '$got' (stderr: $(_stderr))"
fi

# ─────────────────────────────────────────────────────────────────────────────
# XACA-0822-005b: kb-release-create resolves the port via _kb_team_lcars_port
# for an overlay-only team, not the single global lcars-ui/.lcars-port file.
# Stubs _kb_detect_context + _kb_overlay_lookup + curl so no network/tmux is
# touched; asserts the curl call target embeds the overlay port (8514), not
# the global default (8080).
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0822-005: kb-release-create uses team-resolved port, not global .lcars-port default"
_CURL_URL_FILE="$_TEST_TMP/curl-url-seen.txt"
rm -f "$_CURL_URL_FILE"
# NOTE: the template's own curl invocation ends with `2>/dev/null`, which
# would swallow anything this stub writes to its stderr — so the stub
# records the URL to a side file instead of echoing to &2.
_run_zsh "
_kb_detect_context() { echo 'freelance-testclient:agent'; }
_kb_overlay_lookup() { [[ \"\$1\" == 'freelance-testclient' && \"\$2\" == 'lcars_port' ]] && { echo '8514'; return 0; }; return 1; }
_kb_lcars_auth_args() { :; }
curl() {
    for a in \"\$@\"; do
        case \"\$a\" in http://*) echo \"\$a\" >> '$_CURL_URL_FILE' ;; esac
    done
    echo -e '\n000'
}
kb-release-create 'Test Release' --type feature >/dev/null 2>/dev/null
"
seen="$(cat "$_CURL_URL_FILE" 2>/dev/null)"
if [ "$seen" = "http://localhost:8514/api/releases" ]; then
    test_pass
elif [ "$seen" = "http://localhost:8080/api/releases" ]; then
    test_fail "BUG REGRESSED: resolved global default port 8080 instead of team-overlay port 8514"
else
    test_fail "unexpected/missing curl URL: '$seen' (stderr: $(_stderr))"
fi

# ─────────────────────────────────────────────────────────────────────────────
# XACA-0822-006a: kb-backlog add --points stores a numeric points field.
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0822-006: kb-backlog add --points stores points as a JSON number"
_run_zsh "
_kb_detect_context() { echo 'testteam:agent'; }
_kb_get_board_file() { echo '$_BOARD_FILE'; }
_kb_ensure_jq() { command -v jq >/dev/null; }
_kb_generate_id() { echo 'TST-0001'; }
_kb_increment_id() { :; }
_kb_log_activity() { :; }
kb-backlog add 'Task with points' medium '' '' '' --points 4.5
"
got="$(jq -r '.backlog[0].points' "$_BOARD_FILE" 2>/dev/null)"
got_type="$(jq -r '.backlog[0].points | type' "$_BOARD_FILE" 2>/dev/null)"
if [ "$got" = "4.5" ] && [ "$got_type" = "number" ]; then
    test_pass
else
    test_fail "expected points=4.5 (number), got '$got' (type $got_type). stderr: $(_stderr)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# XACA-0822-006b: kb-backlog add --points rejects non-numeric input.
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0822-006: kb-backlog add --points rejects non-numeric input"
: > "$_BOARD_FILE"
cat > "$_BOARD_FILE" <<'EOF'
{"backlog": [], "lastUpdated": "", "nextId": 1, "teamCode": "TST"}
EOF
_run_zsh "
_kb_detect_context() { echo 'testteam:agent'; }
_kb_get_board_file() { echo '$_BOARD_FILE'; }
_kb_ensure_jq() { command -v jq >/dev/null; }
_kb_generate_id() { echo 'TST-0002'; }
_kb_increment_id() { :; }
_kb_log_activity() { :; }
kb-backlog add 'Bad points task' medium '' '' '' --points notanumber
"
rc=$?
count="$(jq '.backlog | length' "$_BOARD_FILE" 2>/dev/null)"
if [ "$rc" -ne 0 ] && [ "$count" = "0" ]; then
    test_pass
else
    test_fail "expected rejection (exit!=0, no item added); got rc=$rc count=$count"
fi

# ─────────────────────────────────────────────────────────────────────────────
# XACA-0822-006c: kb-backlog points <id> <hours> sets, then kb-backlog points
# <id> - clears, the points field on an existing item.
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0822-006: kb-backlog points set/clear round-trip"
: > "$_BOARD_FILE"
cat > "$_BOARD_FILE" <<'EOF'
{"backlog": [{"id": "TST-0003", "title": "Existing item", "priority": "medium"}], "lastUpdated": "", "nextId": 4, "teamCode": "TST"}
EOF
_run_zsh "
_kb_detect_context() { echo 'testteam:agent'; }
_kb_get_board_file() { echo '$_BOARD_FILE'; }
_kb_ensure_jq() { command -v jq >/dev/null; }
_kb_resolve_selector() { echo 0; }
_kb_log_activity() { :; }
kb-backlog points TST-0003 8
"
set_val="$(jq -r '.backlog[0].points' "$_BOARD_FILE" 2>/dev/null)"
_run_zsh "
_kb_detect_context() { echo 'testteam:agent'; }
_kb_get_board_file() { echo '$_BOARD_FILE'; }
_kb_ensure_jq() { command -v jq >/dev/null; }
_kb_resolve_selector() { echo 0; }
_kb_log_activity() { :; }
kb-backlog points TST-0003 -
"
cleared_val="$(jq -r 'if .backlog[0] | has("points") then "present" else "absent" end' "$_BOARD_FILE" 2>/dev/null)"
if [ "$set_val" = "8" ] && [ "$cleared_val" = "absent" ]; then
    test_pass
else
    test_fail "expected set=8 then cleared=absent; got set='$set_val' cleared='$cleared_val'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# XACA-0822-008a: kb-backlog unestimated lists only OPEN items without a
# numeric points field — completed/cancelled items excluded even when they
# also lack points. Ported from canonical (XACA-0624).
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0822-008: kb-backlog unestimated reports open+unpointed items only"
: > "$_BOARD_FILE"
cat > "$_BOARD_FILE" <<'EOF'
{"backlog": [
  {"id": "TST-0001", "title": "No points", "priority": "medium", "status": "todo"},
  {"id": "TST-0002", "title": "Has points", "priority": "medium", "status": "todo", "points": 3},
  {"id": "TST-0003", "title": "Completed no points", "priority": "medium", "status": "completed"},
  {"id": "TST-0004", "title": "Cancelled no points", "priority": "medium", "status": "cancelled"}
], "lastUpdated": "", "nextId": 5, "teamCode": "TST"}
EOF
_run_zsh "
_kb_detect_context() { echo 'testteam:agent'; }
_kb_get_board_file() { echo '$_BOARD_FILE'; }
kb-backlog unestimated
"
out="$(_stdout)"
if printf '%s\n' "$out" | grep -q '(1 open without points)' \
    && printf '%s\n' "$out" | grep -q 'TST-0001' \
    && ! printf '%s\n' "$out" | grep -q 'TST-0002' \
    && ! printf '%s\n' "$out" | grep -q 'TST-0003' \
    && ! printf '%s\n' "$out" | grep -q 'TST-0004'; then
    test_pass
else
    test_fail "expected only TST-0001 listed under '(1 open without points)'; got: $out"
fi

# ─────────────────────────────────────────────────────────────────────────────
# XACA-0822-008b: kb-pick refuses to start an UNESTIMATED item (status stays
# "todo", exit != 0) and succeeds once points are set. Ported from canonical
# (XACA-0624) via _kb_require_points.
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0822-008: kb-pick gate blocks unestimated item, allows estimated item"
: > "$_BOARD_FILE"
cat > "$_BOARD_FILE" <<'EOF'
{"backlog": [{"id": "TST-0011", "title": "Unestimated item", "priority": "medium", "status": "todo"}], "lastUpdated": "", "nextId": 12, "teamCode": "TST"}
EOF
_run_zsh "
_kb_detect_context() { echo 'testteam:agent'; }
_kb_get_board_file() { echo '$_BOARD_FILE'; }
_kb_resolve_selector() { echo 0; }
kb-pick TST-0011
"
rc_blocked=$?
status_blocked="$(jq -r '.backlog[0].status' "$_BOARD_FILE" 2>/dev/null)"

: > "$_BOARD_FILE"
cat > "$_BOARD_FILE" <<'EOF'
{"backlog": [{"id": "TST-0012", "title": "Estimated item", "priority": "medium", "status": "todo", "points": 4}], "lastUpdated": "", "nextId": 13, "teamCode": "TST"}
EOF
_run_zsh "
_kb_detect_context() { echo 'testteam:agent'; }
_kb_get_board_file() { echo '$_BOARD_FILE'; }
_kb_resolve_selector() { echo 0; }
_kb_release_sync() { :; }
_kb_update_window() { :; }
_kb_set_working_on() { :; }
kb-pick TST-0012
"
rc_allowed=$?
status_allowed="$(jq -r '.backlog[0].status' "$_BOARD_FILE" 2>/dev/null)"

if [ "$rc_blocked" -ne 0 ] && [ "$status_blocked" = "todo" ] \
    && [ "$rc_allowed" -eq 0 ] && [ "$status_allowed" = "in_progress" ]; then
    test_pass
else
    test_fail "expected blocked(rc!=0,status=todo) and allowed(rc=0,status=in_progress); got blocked(rc=$rc_blocked,status=$status_blocked) allowed(rc=$rc_allowed,status=$status_allowed)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# XACA-0822-008c: kb-run refuses to start an UNESTIMATED item — the gate must
# fire AFTER the user confirms [Y] but BEFORE any worktree/status mutation.
# Feeds "y" on stdin for the confirmation prompt; asserts exit != 0 and the
# board status is untouched (kb-run's gate is a precondition check only —
# kb-pick is the write site, per canonical XACA-0624).
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0822-008: kb-run gate blocks unestimated item after confirmation, before any write"
: > "$_BOARD_FILE"
cat > "$_BOARD_FILE" <<'EOF'
{"backlog": [{"id": "TST-0010", "title": "Unestimated item", "priority": "medium", "status": "todo"}], "lastUpdated": "", "nextId": 11, "teamCode": "TST"}
EOF
_run_zsh "
_kb_detect_context() { echo 'testteam:agent'; }
_kb_get_board_file() { echo '$_BOARD_FILE'; }
_kb_resolve_selector() { echo 0; }
echo y | kb-run TST-0010
"
rc="$?"
status_after="$(jq -r '.backlog[0].status' "$_BOARD_FILE" 2>/dev/null)"
out="$(_stdout)"
if [ "$rc" -ne 0 ] && [ "$status_after" = "todo" ] && printf '%s\n' "$out" | grep -q 'Cannot start \[TST-0010\]: no effort estimate'; then
    test_pass
else
    test_fail "expected blocked (rc!=0, status=todo, error message present); got rc=$rc status=$status_after. stdout: $out"
fi

# ─────────────────────────────────────────────────────────────────────────────
# XACA-0822-004: no literal unexpanded tilde remains in the retro-template
# path (was: ${AITEAMFORGE_DIR}/~/knowledge/templates/retrospective_template.md,
# a path that can never exist). Static content assertion — this fix corrects
# text embedded in echo/prompt strings, not control flow, so grepping the
# shipped file is the direct and correct check (not a weaker substitute for
# a functional test).
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0822-004: no literal '/~/knowledge' path remains in the template"
if grep -q '/~/knowledge' "$TEMPLATE_PATH"; then
    test_fail "found literal unexpanded '/~/knowledge' path in $TEMPLATE_PATH"
else
    test_pass
fi

# ─────────────────────────────────────────────────────────────────────────────
# XACA-0822-002 ([Review] strengthened): actually EXERCISE the reserved-slot
# release guard end-to-end instead of grepping for the fixed error string it
# prints. The grep-only version below (kept as history in this comment) would
# still pass if the guard's condition were inverted (e.g. `[[ -s "$target_
# file" ]]`) or its `rm -f`/`return 1` were deleted outright — it never
# invokes kb-knowledge-promote and never forces a real target-write failure:
#   grep -q 'released reserved slot \${target_entry_id}' <promote_body>
#
# This version forces a REAL write failure and asserts on filesystem state:
#   1. Let the REAL _kb_alloc_slot allocator reserve a genuine slot (so the
#      scan/lock/tombstone-backstop machinery all runs for real) via a thin
#      wrapper — a zsh `functions -c` copy, not a hand-reimplementation —
#      that chmod 444's the placeholder FILE it returns (never the
#      directory) so the content write immediately following it in
#      kb-knowledge-promote gets EACCES and leaves the placeholder at 0
#      bytes: the exact condition the guard exists to detect. `rm -f` only
#      needs directory write permission, which this never touches, so the
#      release step itself is not what's engineered here — only the trigger.
#   2. Assert the call fails (rc != 0), the placeholder is actually GONE from
#      disk afterward, the stderr names the release, and the source entry
#      was left byte-for-byte unchanged (not turned into a promotion stub).
#   3. Re-invoke kb-knowledge-promote in a FRESH zsh process (real, unwrapped
#      _kb_alloc_slot) against the same still-unpromoted source. If the
#      first call's slot were merely orphaned rather than genuinely
#      released, the real allocator's next scan would see it and skip past
#      it. Landing the real promotion on the SAME NNN (s001) the failed
#      attempt used is the proof the slot came back, not just that a file
#      vanished.
#
# Sandboxed: KB_KNOWLEDGE_GLOBAL_ROOT points at a dir under $_TEST_TMP for
# both invocations below — this never reads or writes a real ~/knowledge
# tree or a live kanban board.
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0822-002: kb-knowledge-promote genuinely releases the reserved slot on a forced target-write failure (source left intact)"

_KP_ROOT="$_TEST_TMP/knowledge-promote-002"
mkdir -p "$_KP_ROOT/agents/emh"
_KP_SOURCE="$_KP_ROOT/agents/emh/k042-test-entry.md"
cat > "$_KP_SOURCE" <<'SRCEOF'
---
id: k042-test-entry
tier: agent
agent: emh
date: 2026-09-01
tags: test
---

Original source body — must survive an aborted promotion untouched.
SRCEOF
_KP_SOURCE_BEFORE="$(cat "$_KP_SOURCE")"
_KP_TARGET_DIR="$_KP_ROOT/subjects/test-topic"
_KP_RESERVED="$_KP_TARGET_DIR/s001-test-entry.md"

_run_zsh "
export KB_KNOWLEDGE_GLOBAL_ROOT='$_KP_ROOT'
functions -c _kb_alloc_slot _kb_alloc_slot_real
_kb_alloc_slot() {
    local f
    f=\$(_kb_alloc_slot_real \"\$@\") || return 1
    chmod 444 \"\$f\"
    printf '%s' \"\$f\"
}
kb-knowledge-promote 'agents:emh:k042' 'subjects:test-topic' --confirm
"
rc1=$?
err1="$(_stderr)"

if [ "$rc1" -eq 0 ]; then
    test_fail "expected kb-knowledge-promote to FAIL on a forced write error; it returned 0. stdout: $(_stdout) stderr: $err1"
elif [ -e "$_KP_RESERVED" ]; then
    test_fail "reserved placeholder $_KP_RESERVED still exists after the guard should have released it"
elif ! echo "$err1" | grep -q "released reserved slot s001-test-entry"; then
    test_fail "expected release message naming s001-test-entry in stderr; got: $err1"
elif [ "$(cat "$_KP_SOURCE" 2>/dev/null)" != "$_KP_SOURCE_BEFORE" ]; then
    test_fail "source entry was modified despite the promotion failing — expected it left intact"
else
    # Slot genuinely free: a real (unstubbed) promotion in a FRESH zsh
    # process must land on the SAME NNN (s001), not skip past a leftover.
    _run_zsh "
    export KB_KNOWLEDGE_GLOBAL_ROOT='$_KP_ROOT'
    kb-knowledge-promote 'agents:emh:k042' 'subjects:test-topic' --confirm
    "
    rc2=$?
    if [ "$rc2" -ne 0 ]; then
        test_fail "real re-promotion after release failed (rc=$rc2): $(_stderr)"
    elif [ -f "$_KP_RESERVED" ]; then
        test_pass
    else
        test_fail "expected the real promotion to land at $_KP_RESERVED (slot s001 reused); it did not — ls: $(ls "$_KP_TARGET_DIR" 2>&1)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Expected-assertion-count guard: run as its own case, LAST, so a silent
# skip anywhere above (rather than a genuine test_fail) is what this catches.
# Snapshot $_CASES_RUN BEFORE this case's own test_start increments it, so
# the comparison reflects only the 7 cases above, not this guard itself.
# ─────────────────────────────────────────────────────────────────────────────
_OBSERVED_CASES="$_CASES_RUN"
test_start "XACA-0822: expected-assertion-count guard (${_EXPECTED_CASES} cases expected)"
if [ "$_OBSERVED_CASES" -eq "$_EXPECTED_CASES" ]; then
    test_pass
else
    test_fail "expected ${_EXPECTED_CASES} test cases to have run in $(basename "$0") before this guard; observed ${_OBSERVED_CASES} — a case was silently skipped"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Results
# ─────────────────────────────────────────────────────────────────────────────
if $_STANDALONE; then
    echo ""
    echo "Results: $_PASS passed, $_FAIL failed"
    [ "$_FAIL" -eq 0 ]
    exit $?
fi
