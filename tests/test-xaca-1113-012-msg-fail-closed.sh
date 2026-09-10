#!/usr/bin/env bash
# test-xaca-1113-012-msg-fail-closed.sh
#
# XACA-1113-012: prove the PORTED kb-msg (share/templates/kanban/
# kanban-helpers.template.sh, tap commit edfbef8) fails CLOSED — non-zero
# return + a cause-naming stderr message, never a silent drop, never a queue,
# never a retry — when Tier-2 (cross-machine) routing credentials are absent.
#
# INHERITANCE: this ship condition was carried over from XACA-1149 (a
# duplicate ticket that stood down). A peer reported, from reading the
# CANONICAL dev-team/kanban-helpers.sh, that _kb_msg_send already fails
# closed when it cannot resolve a target machine. That report is a CLAIM, not
# a finding — canonical and the ported template are two different files that
# have drifted before (that is the entire premise of XACA-1113). Every
# assertion below runs against the file consumers actually receive: the tap
# TEMPLATE. Nothing here reads or trusts the canonical copy.
#
# FIVE FAILURE MODES from the ticket, each proven fail-closed:
#   1. No team-machines.json entry for the target team, $MSG_TARGET_MACHINE unset.
#   2. team-machines.json present but the target team absent from it.
#   3. Relay URL unresolvable (no FLEET_MONITOR_URL, no fleet-config.json).
#   4. msg-client.sh missing (or present-but-not-executable).
#   5. Vault key absent for the target machine (machine not registered with
#      the vault registry the relay serves at /api/vault/machines).
#
# NEGATIVE CONTROLS (mandatory — a check that never fails proves nothing):
# every positive (fail-closed) assertion below has a companion run where the
# SAME code path is given what it needs to succeed instead, and we assert the
# fail-closed message is ABSENT there. That proves the grep is sensitive to
# the actual condition, not a string that would match regardless of input.
# Cases C/D additionally prove the gate can be walked all the way through to
# a real downstream invocation (a dummy client script actually runs), so a
# "pass" on the positive case cannot be explained by "this codepath is
# unreachable no matter what".
#
# WHY MODE 5 IS TESTED AT THE JS LAYER, NOT THROUGH THE SHELL WRAPPER:
# msg-client.sh (the shell wrapper _kb_msg_send execs into) unconditionally
# gates on `node_modules/libsodium-wrappers` existing BEFORE it ever execs
# node — even on a call that would never actually need libsodium (mode 5's
# failure happens on the network fetch, before crypto is ever touched). That
# guard has no offline bypass that still runs real code (MSG_CLIENT_NO_AUTO_
# INSTALL=1 just prints "not installed" and exits — a different message than
# the one under test), and this suite must not depend on npm/network access.
# So mode 5 calls the shipped msg-client.js's own exported fetchMachinePubKey
# directly (absolute require path — Node resolves msg-client.js's own
# `require('./vault-keygen.js')` relative to ITS directory, not the caller's,
# so this is the real shipped code, unmodified) against a local stub HTTP
# server standing in for the fleet-monitor relay's /api/vault/machines route.
# fetchMachinePubKey is called BEFORE seal() in cmdSend, so this exercises
# the exact failure without ever needing libsodium-wrappers installed — same
# principle test-msg-client-install.sh's T3/T5 already rely on (module
# resolution / narrow-slice execution without a full crypto round-trip).
#
# A companion STATIC check closes the loop back to the shell layer: it proves
# `bash "$client" send ...` is the textual LAST statement in _kb_msg_send's
# Tier-2 branch (no `return 0` or swallow-and-continue after it), so whatever
# exit code msg-client.sh/msg-client.js produces for mode 5 propagates
# unchanged as _kb_msg_send's own return code.
#
# SANDBOXING (non-negotiable, XACA-0212 / M3Pro dev-machine rule):
# _kb_msg_resolve_machine, _kb_msg_relay_url and the vault/machine-registry
# paths in the ported template are ALL hardcoded to literal "$HOME/.aiteamforge/..."
# — there is no AITEAMFORGE_DIR-style override for them. The ONLY way to keep
# this suite from ever touching the real ~/.aiteamforge (which exists and is
# live on this machine) is to override HOME itself for every invocation below.
# Every case does this. AITEAMFORGE_DIR is ALSO always explicitly overridden
# per case, because this shell's ambient AITEAMFORGE_DIR points at the real
# dev-team checkout — left unset inside a case script it would resolve
# _kb_msg_client to the REAL fleet-monitor/client/msg-client.sh.
#
# Invoke standalone: bash tests/test-xaca-1113-012-msg-fail-closed.sh
# Exit 0 = all assertions passed; exit 1 = at least one failed (or too few ran).
# Requires: zsh, jq, python3. node is optional (mode 5 + its negative control
# SKIP without it, everything else does not need it).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="$TAP_ROOT/share/templates/kanban/kanban-helpers.template.sh"
MSG_CLIENT_JS="$TAP_ROOT/share/scripts/msg-client.js"

if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "FATAL: kanban-helpers.template.sh not found at: $TEMPLATE_PATH" >&2
    exit 1
fi
if [ ! -f "$MSG_CLIENT_JS" ]; then
    echo "FATAL: msg-client.js not found at: $MSG_CLIENT_JS" >&2
    exit 1
fi

for _tool in zsh jq python3; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        echo "FATAL: required tool '$_tool' not on PATH — cannot run kb-msg fail-closed tests." >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (mirrors test-xaca-0819's pattern).
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
else
    # XACA-1113: `type -t test_start` only proves the FUNCTION was inherited
    # from test-runner.sh (it exports the functions at test-runner.sh:456);
    # it says nothing about whether the STATE those functions mutate came
    # with them. test-runner.sh:27-38 (TOTAL_TESTS, PASSED_TESTS,
    # FAILED_TESTS, SKIPPED_TESTS, TEST_FAILED, CURRENT_TEST_NAME) are plain
    # assignments in the parent shell, never `export`-ed, so a child process
    # that inherits the *functions* still starts with those variables unset.
    # Under this suite's `set -u` (above), the inherited test_start's first
    # line — `TOTAL_TESTS=$((TOTAL_TESTS + 1))` — reads that unset variable
    # and aborts the whole script before assertion #1 ever runs, printing
    # only "TOTAL_TESTS: unbound variable" (reproduced standalone vs. under
    # test-runner.sh — it only happens under the runner, because only there
    # is test_start inherited rather than locally defined above).
    #
    # The fix is NOT to drop `-u` — it is load-bearing for the sandbox-path
    # construction later in this file, and silencing it here would trade a
    # loud failure for a quiet one, which is the exact defect class this
    # whole ticket exists to eliminate. Instead, seed the variables the
    # inherited functions actually dereference, satisfying `set -u` without
    # touching test-runner.sh (88 other suites depend on it). This does NOT
    # change what the runner itself tallies for this suite: run_test_file()
    # aggregates by grepping TEST_RESULTS_FILE for START/PASS/FAIL: lines
    # (test-runner.sh:471-476), which the inherited test_start/test_pass/
    # test_fail already write regardless of these local seed values — the
    # seeds exist purely to keep the inherited functions from crashing on
    # first read.
    : "${TOTAL_TESTS:=0}"
    : "${PASSED_TESTS:=0}"
    : "${FAILED_TESTS:=0}"
    : "${SKIPPED_TESTS:=0}"
    : "${TEST_FAILED:=false}"
    : "${CURRENT_TEST_NAME:=}"
fi

_M012_PASS=0
_M012_FAIL=0

# ok <label> <cond(1|0)> [failure_detail]
ok() {
    local label="$1" cond="$2" detail="${3:-}"
    test_start "$label"
    if [ "$cond" = "1" ]; then
        _M012_PASS=$((_M012_PASS + 1)); test_pass
    else
        _M012_FAIL=$((_M012_FAIL + 1)); test_fail "$detail"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Sandbox root. Refuse outright if it resolves anywhere near a real $HOME.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1113-012-msg-failclosed.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
case "$TEST_TMP_DIR" in
    "$HOME"|"$HOME"/*) echo "FATAL: sandbox resolved inside \$HOME — refusing." >&2; exit 1 ;;
esac
WORK_DIR="$TEST_TMP_DIR/xaca1113-012"
mkdir -p "$WORK_DIR"

STUB_PID=""
cleanup() {
    [ -n "$STUB_PID" ] && kill "$STUB_PID" >/dev/null 2>&1
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

echo "=== XACA-1113-012: kb-msg Tier-2 fails CLOSED with no routing credentials ==="

# ─────────────────────────────────────────────────────────────────────────────
# Render the template (placeholder hygiene — same substitution set every
# other suite in this dir uses; only {{AITEAMFORGE_DIR}} appears near code we
# exercise, the rest are inert comment/echo text for other teams).
# ─────────────────────────────────────────────────────────────────────────────
RENDERED="$WORK_DIR/kanban-helpers-rendered.sh"
sed "s|{{AITEAMFORGE_DIR}}|__UNUSED__|g; \
     s|{{SHARED_DEV_ROOT}}|$WORK_DIR/shared|g; \
     s|{{ORG_NAME}}|TestOrg|g; \
     s|{{ORG_SLUG}}|testorg|g" \
    "$TEMPLATE_PATH" > "$RENDERED"

_LEFT=$(grep -c '{{' "$RENDERED" 2>/dev/null); [ -n "$_LEFT" ] || _LEFT=0
ok "render: no {{placeholder}} survives in the rendered template" \
   "$([ "$_LEFT" -eq 0 ] && echo 1 || echo 0)" \
   "found $_LEFT residual placeholder(s)"

# ─────────────────────────────────────────────────────────────────────────────
# write_case <script_path> <fake_home> <af_dir> <to_addr> <body> <mtm> <fmu>
#   mtm = MSG_TARGET_MACHINE value, or "" to leave it unset
#   fmu = FLEET_MONITOR_URL value, or "" to leave it unset
# Writes a zsh script that sources the RENDERED template with HOME and
# AITEAMFORGE_DIR both pinned into the sandbox, then calls _kb_msg_send.
# KB_TEAM/KB_TERMINAL are explicit env — per _kb_resolve_explicit_env_context
# (kanban-helpers.template.sh:514-530) explicit env OUTRANKS the ambient tmux
# session, so this is deterministic regardless of what real tmux/session
# context this test happens to run inside.
# ─────────────────────────────────────────────────────────────────────────────
write_case() {
    local script="$1" fake_home="$2" af_dir="$3" to_addr="$4" body="$5" mtm="$6" fmu="$7"
    {
        echo "unset MSG_TARGET_MACHINE"
        echo "unset FLEET_MONITOR_URL"
        echo "export HOME='$fake_home'"
        echo "export AITEAMFORGE_DIR='$af_dir'"
        echo "export KB_TEAM=fromteam"
        echo "export KB_TERMINAL=agent"
        [ -n "$mtm" ] && echo "export MSG_TARGET_MACHINE='$mtm'"
        [ -n "$fmu" ] && echo "export FLEET_MONITOR_URL='$fmu'"
        echo "source '$RENDERED' >/dev/null 2>&1"
        echo "_kb_msg_send '$to_addr' '$body'"
    } > "$script"
}

# run_case <case_dir> <fake_home> <af_dir> <to_addr> <body> <mtm> <fmu>
# Populates <case_dir>/{stdout.txt,stderr.txt,exit.txt}.
run_case() {
    local case_dir="$1" fake_home="$2" af_dir="$3" to_addr="$4" body="$5" mtm="$6" fmu="$7"
    mkdir -p "$case_dir" "$fake_home" "$af_dir"
    write_case "$case_dir/run.zsh" "$fake_home" "$af_dir" "$to_addr" "$body" "$mtm" "$fmu"
    zsh "$case_dir/run.zsh" >"$case_dir/stdout.txt" 2>"$case_dir/stderr.txt"
    echo $? > "$case_dir/exit.txt"
}

# nothing_queued <fake_home> <af_dir> <before_snapshot_file>
# Asserts the file trees under fake_home/af_dir are BYTE-IDENTICAL in listing
# to a snapshot taken before the run — i.e. the failed send left no queued
# envelope, no retry marker, nothing at all behind.
snapshot() { find "$1" "$2" -type f 2>/dev/null | sort; }

# ═════════════════════════════════════════════════════════════════════════
# MODE 1 — no team-machines.json, no $MSG_TARGET_MACHINE
# ═════════════════════════════════════════════════════════════════════════
M1_DIR="$WORK_DIR/mode1"
M1_HOME="$M1_DIR/home"; M1_AF="$M1_DIR/af"
mkdir -p "$M1_HOME" "$M1_AF"
BEFORE=$(snapshot "$M1_HOME" "$M1_AF")
run_case "$M1_DIR/pos" "$M1_HOME" "$M1_AF" "ghost-team" "mode1 test message" "" ""
AFTER=$(snapshot "$M1_HOME" "$M1_AF")
EC=$(cat "$M1_DIR/pos/exit.txt")
ERR=$(cat "$M1_DIR/pos/stderr.txt")

ok "mode1 positive: exit code is non-zero" \
   "$([ "$EC" != "0" ] && echo 1 || echo 0)" "exit was $EC"
ok "mode1 positive: stderr names the real cause (cannot resolve which machine)" \
   "$(printf '%s' "$ERR" | grep -qF "kb-msg: cannot resolve which machine team 'ghost-team' runs on (fail-closed, no silent drop)." && echo 1 || echo 0)" \
   "stderr was: $ERR"
ok "mode1 positive: remediation names both fix paths (env var + team-machines.json)" \
   "$(printf '%s' "$ERR" | grep -qF 'export MSG_TARGET_MACHINE=' && printf '%s' "$ERR" | grep -qF 'team-machines.json' && echo 1 || echo 0)" \
   "stderr was: $ERR"
ok "mode1 positive: nothing queued or written under HOME/AITEAMFORGE_DIR" \
   "$([ "$BEFORE" = "$AFTER" ] && echo 1 || echo 0)" \
   "tree changed:$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"

# NEGATIVE CONTROL: same sandbox, but MSG_TARGET_MACHINE now resolves the
# machine. The mode-1 message must be ABSENT (it will fail later, for an
# unrelated reason — client missing — proving THIS gate specifically passed).
run_case "$M1_DIR/neg" "$M1_HOME" "$M1_AF" "ghost-team" "mode1 neg" "some-machine-slug" ""
NEG_ERR=$(cat "$M1_DIR/neg/stderr.txt")
NEG_EC=$(cat "$M1_DIR/neg/exit.txt")
ok "mode1 NEGATIVE CONTROL: resolving the machine makes the mode-1 message disappear" \
   "$(printf '%s' "$NEG_ERR" | grep -qF "cannot resolve which machine" && echo 0 || echo 1)" \
   "message still present with machine resolved — grep is not discriminating: $NEG_ERR"
ok "mode1 NEGATIVE CONTROL: still fails (client missing) — control isn't a green light for everything" \
   "$([ "$NEG_EC" != "0" ] && echo 1 || echo 0)" "unexpectedly exited 0"

# ═════════════════════════════════════════════════════════════════════════
# MODE 2 — team-machines.json present, target team absent from it
# ═════════════════════════════════════════════════════════════════════════
M2_DIR="$WORK_DIR/mode2"
M2_HOME="$M2_DIR/home"; M2_AF="$M2_DIR/af"
mkdir -p "$M2_HOME/.aiteamforge" "$M2_AF"
echo '{"other-team":"other-slug"}' > "$M2_HOME/.aiteamforge/team-machines.json"
BEFORE=$(snapshot "$M2_HOME" "$M2_AF")
run_case "$M2_DIR/pos" "$M2_HOME" "$M2_AF" "ghost-team" "mode2 test message" "" ""
AFTER=$(snapshot "$M2_HOME" "$M2_AF")
EC=$(cat "$M2_DIR/pos/exit.txt")
ERR=$(cat "$M2_DIR/pos/stderr.txt")

ok "mode2 positive: exit code is non-zero" \
   "$([ "$EC" != "0" ] && echo 1 || echo 0)" "exit was $EC"
ok "mode2 positive: stderr names the real cause (team absent from the map)" \
   "$(printf '%s' "$ERR" | grep -qF "kb-msg: cannot resolve which machine team 'ghost-team' runs on (fail-closed, no silent drop)." && echo 1 || echo 0)" \
   "stderr was: $ERR"
ok "mode2 positive: nothing queued or written beyond the pre-existing map" \
   "$([ "$BEFORE" = "$AFTER" ] && echo 1 || echo 0)" \
   "tree changed:$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"

# NEGATIVE CONTROL: team-machines.json now DOES carry the target team.
M2_HOME_OK="$M2_DIR/home-ok"; mkdir -p "$M2_HOME_OK/.aiteamforge"
echo '{"other-team":"other-slug","ghost-team":"ghost-slug"}' > "$M2_HOME_OK/.aiteamforge/team-machines.json"
run_case "$M2_DIR/neg" "$M2_HOME_OK" "$M2_AF" "ghost-team" "mode2 neg" "" ""
NEG_ERR=$(cat "$M2_DIR/neg/stderr.txt")
NEG_EC=$(cat "$M2_DIR/neg/exit.txt")
ok "mode2 NEGATIVE CONTROL: a matching map entry makes the mode-1/2 message disappear" \
   "$(printf '%s' "$NEG_ERR" | grep -qF "cannot resolve which machine" && echo 0 || echo 1)" \
   "message still present with a matching map entry — grep is not discriminating: $NEG_ERR"
ok "mode2 NEGATIVE CONTROL: still fails (client missing) downstream" \
   "$([ "$NEG_EC" != "0" ] && echo 1 || echo 0)" "unexpectedly exited 0"

# ═════════════════════════════════════════════════════════════════════════
# MODE 3 — relay URL unresolvable (machine resolves, client exists+executable,
# but no FLEET_MONITOR_URL and no fleet-config.json).
# ═════════════════════════════════════════════════════════════════════════
M3_DIR="$WORK_DIR/mode3"
M3_HOME="$M3_DIR/home"; M3_AF="$M3_DIR/af"
mkdir -p "$M3_HOME" "$M3_AF/fleet-monitor/client"
DUMMY_CLIENT="$M3_AF/fleet-monitor/client/msg-client.sh"
cat > "$DUMMY_CLIENT" <<'EOF'
#!/bin/sh
echo "dummy-client-invoked: $*"
exit 0
EOF
chmod +x "$DUMMY_CLIENT"
BEFORE=$(snapshot "$M3_HOME" "$M3_AF")
run_case "$M3_DIR/pos" "$M3_HOME" "$M3_AF" "ghost-team" "mode3 test message" "some-machine-slug" ""
AFTER=$(snapshot "$M3_HOME" "$M3_AF")
EC=$(cat "$M3_DIR/pos/exit.txt")
ERR=$(cat "$M3_DIR/pos/stderr.txt")
OUT=$(cat "$M3_DIR/pos/stdout.txt")

ok "mode3 positive: exit code is non-zero" \
   "$([ "$EC" != "0" ] && echo 1 || echo 0)" "exit was $EC"
ok "mode3 positive: stderr names the real cause (no Tier-2 relay URL configured)" \
   "$(printf '%s' "$ERR" | grep -qF "kb-msg: no Tier-2 relay URL configured, so a cross-machine send cannot be addressed." && echo 1 || echo 0)" \
   "stderr was: $ERR"
ok "mode3 positive: the (executable, reachable) dummy client was NEVER invoked" \
   "$(printf '%s' "$OUT" | grep -qF 'dummy-client-invoked' && echo 0 || echo 1)" \
   "stdout unexpectedly shows the client ran: $OUT"
ok "mode3 positive: nothing queued or written under HOME/AITEAMFORGE_DIR" \
   "$([ "$BEFORE" = "$AFTER" ] && echo 1 || echo 0)" \
   "tree changed:$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"

# NEGATIVE CONTROL: relay URL now resolves — the mode-3 message must vanish,
# AND (unlike modes 1/2's negative controls) the whole chain now completes:
# the dummy client actually runs and the send reports success. This is the
# proof that the gate genuinely opens when properly configured, not merely
# that some other failure took its place.
run_case "$M3_DIR/neg" "$M3_HOME" "$M3_AF" "ghost-team" "mode3 neg" "some-machine-slug" "http://127.0.0.1:1"
NEG_ERR=$(cat "$M3_DIR/neg/stderr.txt")
NEG_OUT=$(cat "$M3_DIR/neg/stdout.txt")
NEG_EC=$(cat "$M3_DIR/neg/exit.txt")
ok "mode3 NEGATIVE CONTROL: resolving FLEET_MONITOR_URL makes the mode-3 message disappear" \
   "$(printf '%s' "$NEG_ERR" | grep -qF "no Tier-2 relay URL configured" && echo 0 || echo 1)" \
   "message still present with FLEET_MONITOR_URL set — grep is not discriminating: $NEG_ERR"
ok "mode3 NEGATIVE CONTROL: the dummy client WAS reached and invoked" \
   "$(printf '%s' "$NEG_OUT" | grep -qF 'dummy-client-invoked' && echo 1 || echo 0)" \
   "stdout was: $NEG_OUT"
ok "mode3 NEGATIVE CONTROL: send now succeeds end-to-end (exit 0)" \
   "$([ "$NEG_EC" = "0" ] && echo 1 || echo 0)" "exit was $NEG_EC"

# ═════════════════════════════════════════════════════════════════════════
# MODE 4 — msg-client.sh missing (and, separately, present-but-not-executable)
# ═════════════════════════════════════════════════════════════════════════
M4_DIR="$WORK_DIR/mode4"
M4_HOME="$M4_DIR/home"; M4_AF="$M4_DIR/af"
mkdir -p "$M4_HOME" "$M4_AF"
# Deliberately do NOT create fleet-monitor/client/msg-client.sh at all.
BEFORE=$(snapshot "$M4_HOME" "$M4_AF")
run_case "$M4_DIR/pos" "$M4_HOME" "$M4_AF" "ghost-team" "mode4 test message" "some-machine-slug" "http://127.0.0.1:1"
AFTER=$(snapshot "$M4_HOME" "$M4_AF")
EC=$(cat "$M4_DIR/pos/exit.txt")
ERR=$(cat "$M4_DIR/pos/stderr.txt")
EXPECT_PATH="$M4_AF/fleet-monitor/client/msg-client.sh"

ok "mode4 positive (missing file): exit code is non-zero" \
   "$([ "$EC" != "0" ] && echo 1 || echo 0)" "exit was $EC"
ok "mode4 positive (missing file): stderr names the real cause + the exact path" \
   "$(printf '%s' "$ERR" | grep -qF "kb-msg: Tier-2 client not found/executable at $EXPECT_PATH" && echo 1 || echo 0)" \
   "stderr was: $ERR"
ok "mode4 positive (missing file): nothing queued or written" \
   "$([ "$BEFORE" = "$AFTER" ] && echo 1 || echo 0)" \
   "tree changed:$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"

# Sub-case: file present but NOT executable — same gate (`[[ ! -x "$client" ]]`)
# must catch this too, not just outright absence.
M4B_DIR="$WORK_DIR/mode4b"
M4B_HOME="$M4B_DIR/home"; M4B_AF="$M4B_DIR/af"
mkdir -p "$M4B_HOME" "$M4B_AF/fleet-monitor/client"
NOEXEC_CLIENT="$M4B_AF/fleet-monitor/client/msg-client.sh"
echo '#!/bin/sh' > "$NOEXEC_CLIENT"
chmod -x "$NOEXEC_CLIENT"
run_case "$M4B_DIR/pos" "$M4B_HOME" "$M4B_AF" "ghost-team" "mode4b test message" "some-machine-slug" "http://127.0.0.1:1"
EC=$(cat "$M4B_DIR/pos/exit.txt")
ERR=$(cat "$M4B_DIR/pos/stderr.txt")
ok "mode4b (present, not executable): exit code is non-zero" \
   "$([ "$EC" != "0" ] && echo 1 || echo 0)" "exit was $EC"
ok "mode4b (present, not executable): stderr names the same cause" \
   "$(printf '%s' "$ERR" | grep -qF "kb-msg: Tier-2 client not found/executable at $NOEXEC_CLIENT" && echo 1 || echo 0)" \
   "stderr was: $ERR"

# NEGATIVE CONTROL: an executable dummy client at the exact expected path —
# the mode-4 message must vanish and the client must actually run.
run_case "$M4_DIR/neg" "$M4_HOME" "$M3_AF" "ghost-team" "mode4 neg" "some-machine-slug" "http://127.0.0.1:1"
NEG_ERR=$(cat "$M4_DIR/neg/stderr.txt")
NEG_OUT=$(cat "$M4_DIR/neg/stdout.txt")
NEG_EC=$(cat "$M4_DIR/neg/exit.txt")
ok "mode4 NEGATIVE CONTROL: an executable client at the path makes the message disappear" \
   "$(printf '%s' "$NEG_ERR" | grep -qF "Tier-2 client not found/executable" && echo 0 || echo 1)" \
   "message still present with client executable — grep is not discriminating: $NEG_ERR"
ok "mode4 NEGATIVE CONTROL: send now succeeds end-to-end (exit 0)" \
   "$([ "$NEG_EC" = "0" ] && echo 1 || echo 0)" "exit was $NEG_EC, stdout: $NEG_OUT"

# ═════════════════════════════════════════════════════════════════════════
# MODE 5 — vault key absent for the target machine.
#
# Real shipped msg-client.js's fetchMachinePubKey(), called directly (see
# header note for why this is the correct boundary), against a local stub
# standing in for the fleet-monitor relay's /api/vault/machines route.
# ═════════════════════════════════════════════════════════════════════════
if ! command -v node >/dev/null 2>&1; then
    echo "  SKIP  mode5 (node not on PATH)"
else
    M5_DIR="$WORK_DIR/mode5"
    mkdir -p "$M5_DIR"
    STUB_PY="$M5_DIR/stub_vault_server.py"
    cat > "$STUB_PY" <<'PYEOF'
import http.server, socketserver, sys

RESPONSE_FILE = sys.argv[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_GET(self):
        if self.path.startswith('/api/vault/machines'):
            with open(RESPONSE_FILE, 'rb') as f:
                data = f.read()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_response(404)
            self.end_headers()

httpd = socketserver.TCPServer(("127.0.0.1", 0), Handler)
print(httpd.server_address[1], flush=True)
sys.stdout.flush()
httpd.serve_forever()
PYEOF

    RESP_FILE="$M5_DIR/vault_machines_response.json"
    echo '{"machines":[]}' > "$RESP_FILE"

    python3 "$STUB_PY" "$RESP_FILE" >"$M5_DIR/stub_port.txt" 2>"$M5_DIR/stub_err.txt" &
    STUB_PID=$!

    STUB_PORT=""
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        if [ -s "$M5_DIR/stub_port.txt" ]; then
            STUB_PORT=$(tr -d '[:space:]' < "$M5_DIR/stub_port.txt")
            break
        fi
        sleep 0.2
    done

    if [ -z "$STUB_PORT" ]; then
        ok "mode5: stub vault-registry server started" 0 \
           "stub never printed a port; stderr: $(cat "$M5_DIR/stub_err.txt" 2>/dev/null)"
    else
        ok "mode5: stub vault-registry server started on 127.0.0.1:$STUB_PORT" 1

        CHECK_JS="$M5_DIR/check-pubkey.js"
        cat > "$CHECK_JS" <<'JSEOF'
const [msgClientPath, base, slug] = process.argv.slice(2);
const mc = require(msgClientPath);
mc.fetchMachinePubKey(base, slug).then((pk) => {
    process.stdout.write('OK:' + pk + '\n');
    process.exit(0);
}).catch((err) => {
    process.stderr.write('ERR:' + err.message + '\n');
    process.exit(1);
});
JSEOF

        node "$CHECK_JS" "$MSG_CLIENT_JS" "http://127.0.0.1:$STUB_PORT" "no-such-slug" \
            >"$M5_DIR/pos-stdout.txt" 2>"$M5_DIR/pos-stderr.txt"
        POS_EC=$?
        POS_ERR=$(cat "$M5_DIR/pos-stderr.txt")

        ok "mode5 positive: exit code is non-zero" \
           "$([ "$POS_EC" != "0" ] && echo 1 || echo 0)" "exit was $POS_EC"
        ok "mode5 positive: stderr names the real cause (machine not registered in the vault)" \
           "$(printf '%s' "$POS_ERR" | grep -qF "ERR:machine 'no-such-slug' is not registered in the vault (run vault-keygen on it)" && echo 1 || echo 0)" \
           "stderr was: $POS_ERR"

        # NEGATIVE CONTROL: same stub, now WITH the machine registered — the
        # mode-5 message must be absent and the call must succeed with the
        # public key from the registry.
        echo '{"machines":[{"id":"no-such-slug","public_key":"dGVzdHB1YmtleWJhc2U2NA=="}]}' > "$RESP_FILE"
        node "$CHECK_JS" "$MSG_CLIENT_JS" "http://127.0.0.1:$STUB_PORT" "no-such-slug" \
            >"$M5_DIR/neg-stdout.txt" 2>"$M5_DIR/neg-stderr.txt"
        NEG_EC=$?
        NEG_OUT=$(cat "$M5_DIR/neg-stdout.txt")
        NEG_ERR=$(cat "$M5_DIR/neg-stderr.txt")

        ok "mode5 NEGATIVE CONTROL: a registered machine makes the mode-5 message disappear" \
           "$(printf '%s' "$NEG_ERR" | grep -qF "is not registered in the vault" && echo 0 || echo 1)" \
           "message still present with machine registered — grep is not discriminating: $NEG_ERR"
        ok "mode5 NEGATIVE CONTROL: the call now succeeds and returns the registered public key" \
           "$([ "$NEG_EC" = "0" ] && printf '%s' "$NEG_OUT" | grep -qF 'OK:dGVzdHB1YmtleWJhc2U2NA==' && echo 1 || echo 0)" \
           "exit was $NEG_EC, stdout: $NEG_OUT"
    fi

    kill "$STUB_PID" >/dev/null 2>&1
    wait "$STUB_PID" 2>/dev/null
    STUB_PID=""
fi

# STATIC guard closing the shell<->JS loop for mode 5: `bash "$client" send
# ...` must be the textual LAST statement in _kb_msg_send's Tier-2 branch, so
# whatever exit code msg-client.sh/msg-client.js produce (mode 5's failure
# included) propagates unchanged as _kb_msg_send's own return code — no
# `return 0` after it, no swallow-and-continue.
SEND_FUNC_BODY="$WORK_DIR/send-func-body.txt"
sed -n '/^_kb_msg_send() {/,/^}/p' "$TEMPLATE_PATH" > "$SEND_FUNC_BODY"
CLIENT_CALL_LINE=$(grep -n 'bash "\$client" send' "$SEND_FUNC_BODY" | tail -1 | cut -d: -f1)
if [ -z "$CLIENT_CALL_LINE" ]; then
    ok "static: _kb_msg_send invokes the Tier-2 client via bash \"\$client\" send" 0 \
       "call site not found — function shape changed, update this test"
else
    ok "static: _kb_msg_send invokes the Tier-2 client via bash \"\$client\" send" 1
    TOTAL_LINES=$(wc -l < "$SEND_FUNC_BODY")
    AFTER_RETURNS=$(tail -n +"$((CLIENT_CALL_LINE + 1))" "$SEND_FUNC_BODY" | grep -c '\breturn\b')
    ok "static: no return/swallow AFTER the client call — its exit code IS _kb_msg_send's" \
       "$([ "$AFTER_RETURNS" -eq 0 ] && echo 1 || echo 0)" \
       "found $AFTER_RETURNS return statement(s) after the client invocation"
fi

# Redundant STATIC guard for mode 5's exact error text, so this suite still
# asserts something about mode 5 even when node is unavailable and the
# runtime checks above SKIP.
ok "static: msg-client.js's not-registered message text is present verbatim" \
   "$(grep -qF "is not registered in the vault (run vault-keygen on it)" "$MSG_CLIENT_JS" && echo 1 || echo 0)" \
   "expected literal string not found in $MSG_CLIENT_JS — wording changed, update this test"
ok "static: msg-client.js's main() prints caught errors to stderr and returns non-zero" \
   "$(grep -qF "process.stderr.write('Error: ' + err.message + '\\n')" "$MSG_CLIENT_JS" && echo 1 || echo 0)" \
   "expected error-surfacing line not found in $MSG_CLIENT_JS"

echo
echo "Passed: $_M012_PASS   Failed: $_M012_FAIL"

# Gate on FAILED *and* on PASSED (feedback_tap_test_harness_vacuous_green): a
# run that skips everything (node absent, an early return, a refactor that
# stops reaching assertions) must never report a bare 0/0 as green.
MIN_EXPECTED=28
if [ "$_M012_FAIL" -ne 0 ]; then
    exit 1
fi
if [ "$_M012_PASS" -lt "$MIN_EXPECTED" ]; then
    echo "ERROR: only $_M012_PASS assertions ran (expected >= $MIN_EXPECTED) — treating as FAILURE," >&2
    echo "       not success. A run that asserts nothing must never report green." >&2
    exit 1
fi
exit 0
