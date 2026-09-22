#!/bin/bash
# test-xaca-1300-014-session-account-map-shipping.sh
#
# XACA-1300-014: tap consumers must actually RECORD sessions in
# ~/.claude/.session-account-map.jsonl. Measured before this ticket: the file
# did not exist on any tap machine, because the recorder chain
# (session-account-map-headless.sh -> session-account-map-record.sh ->
# session-account-map.py) never shipped and share/templates/aliases/cc-aliases.sh
# never called it.
#
#   ST1  install-shell.sh's helper loop copies all three (executable)
#   ST2  _xaca0673_mandatory_materialize_basenames lists all three
#   B1   update_runtime_helpers() materialises all three on an ALREADY-INSTALLED
#        box that never had them, and the RENDERED copies still work end to end
#   E*   the installed cc-aliases.sh records: _cc_launch (persona) and the
#        argument-less plain-claude fallback (the headless `printf | cc` gate
#        path). RECORD ONLY — a declared-but-unapplied team ai.credential in
#        team-paths.json must NEVER appear in the row (follow-up XACA-1312
#        applies routes); the row carries default OAuth or, for an inherited
#        credential, account_resolved:false.
#   E5   recorder failure: the launch still happens and the failure is visible
#   Z    the real ~/.claude/.session-account-map.jsonl is never written
#
# Sandboxing: HOME, AITEAMFORGE_DIR and SESSION_ACCOUNT_MAP_PATH all point under
# TEST_TMP_DIR. `claude` is a stub on PATH; no real session is ever launched.
# Credential values are fake sentinels and are never printed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SHELL_SH="$TAP_ROOT/libexec/installers/install-shell.sh"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
CC_ALIASES_TPL="$TAP_ROOT/share/templates/aliases/cc-aliases.sh"
CHAIN="session-account-map-headless.sh session-account-map-record.sh session-account-map.py"
REAL_MAP="${HOME}/.claude/.session-account-map.jsonl"

for _need in "$INSTALL_SHELL_SH" "$UPGRADE_SH" "$CC_ALIASES_TPL"; do
    [ -f "$_need" ] || { echo "FATAL: required file not found: $_need" >&2; exit 1; }
done
for _f in $CHAIN; do
    [ -f "$TAP_ROOT/share/scripts/$_f" ] || { echo "FATAL: share/scripts/$_f not shipped" >&2; exit 1; }
done

# ── standalone framework ────────────────────────────────────────────────────
if ! type -t test_start >/dev/null 2>&1; then
    _PASS_COUNT=0; _FAIL_COUNT=0; _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi
type -t test_skip >/dev/null 2>&1 || test_skip() { echo "     SKIP: $_CURRENT_TEST — $1"; }
for _p in print_section print_info print_success print_warning print_error \
          header info success warning error; do
    declare -f "$_p" >/dev/null 2>&1 || eval "${_p}() { :; }"
done

# ── temp dir ────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1300014.XXXXXX)"; _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
case "$TEST_TMP_DIR" in
    "$HOME"|"$HOME"/.claude*|"$HOME"/aiteamforge*) echo "FATAL: sandbox resolved onto a real path" >&2; exit 1 ;;
esac
WORK="$TEST_TMP_DIR/xaca1300014"
mkdir -p "$WORK"
cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -d "${TEST_TMP_DIR:-}" ]; then
        find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

_extract_fn() {
    awk -v fn="$2" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$1"
}

# ═══ ST1 — install loop ═════════════════════════════════════════════════════
test_start "ST1: install_helper_scripts copies the recorder chain, executable"
ST1_ROOT="$WORK/st1"
(
    export AITEAMFORGE_DIR="$ST1_ROOT/aiteamforge"
    export INSTALL_ROOT="$TAP_ROOT"
    mkdir -p "$AITEAMFORGE_DIR"
    eval "$(_extract_fn "$INSTALL_SHELL_SH" install_helper_scripts)"
    install_helper_scripts
) >"$WORK/st1.out" 2>&1
_st1_ok=true
for _f in $CHAIN; do
    [ -x "$ST1_ROOT/aiteamforge/scripts/$_f" ] || { _st1_ok=false; _st1_miss="$_st1_miss $_f"; }
done
if $_st1_ok; then test_pass; else test_fail "not installed/executable:$_st1_miss; out=$(tail -5 "$WORK/st1.out")"; fi

# ═══ ST2 — upgrade mandatory-materialize list ════════════════════════════════
test_start "ST2: mandatory-materialize list names all three (exact lines)"
_mm="$(eval "$(_extract_fn "$UPGRADE_SH" _xaca0673_mandatory_materialize_basenames)"; _xaca0673_mandatory_materialize_basenames)"
_st2_ok=true
for _f in $CHAIN; do
    printf '%s\n' "$_mm" | grep -qxF "$_f" || { _st2_ok=false; _st2_miss="$_st2_miss $_f"; }
done
if $_st2_ok; then test_pass; else test_fail "missing:$_st2_miss"; fi

# ═══ B1 — upgrade materialises the chain on an existing box ═════════════════
URH_SRC="$WORK/urh.sh"
: >"$URH_SRC"
_deps_ok=true
for _fn in _xaca0608_render_team_script _xaca0608_aux_script_map \
           _xaca0608_aux_scriptdir_basenames _xaca0673_mandatory_materialize_basenames \
           update_runtime_helpers; do
    _src="$(_extract_fn "$UPGRADE_SH" "$_fn")"
    [ -n "$_src" ] || { _deps_ok=false; break; }
    printf '%s\n' "$_src" >>"$URH_SRC"
done

FAKE_FW="$WORK/framework"
mkdir -p "$FAKE_FW/share/scripts"
for _f in $CHAIN; do cp "$TAP_ROOT/share/scripts/$_f" "$FAKE_FW/share/scripts/$_f"; done

ATF="$WORK/home/aiteamforge"          # the "already-installed" box
SBHOME="$WORK/home"
mkdir -p "$ATF/scripts" "$SBHOME/.claude"

test_start "B1: update_runtime_helpers materialises the ABSENT chain on upgrade"
if [ "$_deps_ok" != true ]; then
    test_fail "could not extract update_runtime_helpers + deps from aiteamforge-upgrade.sh"
else
    (
        source "$URH_SRC"
        FRAMEWORK_DIR="$FAKE_FW"; WORKING_DIR="$ATF"; DRY_RUN=false
        update_runtime_helpers
    ) >"$WORK/b1.out" 2>&1
    _b1_ok=true
    for _f in $CHAIN; do [ -x "$ATF/scripts/$_f" ] || { _b1_ok=false; _b1_miss="$_b1_miss $_f"; }; done
    if $_b1_ok; then test_pass; else test_fail "not materialised:$_b1_miss; out=$(tail -5 "$WORK/b1.out")"; fi
fi

# ── stub claude + scrubbed env for E* ────────────────────────────────────────
mkdir -p "$WORK/bin"
cat >"$WORK/bin/claude" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "--help" ]; then
    echo "  --session-id <uuid>  Use a specific session ID"
    exit 0
fi
printf '%s\n' "$*" >> "$STUB_ARGV"
cat >> "$STUB_STDIN"
exit 0
STUB
chmod +x "$WORK/bin/claude"
STUB_ARGV="$WORK/argv.log"; STUB_STDIN="$WORK/stdin.log"
MAP="$SBHOME/.claude/.session-account-map.jsonl"
ALL_SIDS="$WORK/sids.txt"; : >"$ALL_SIDS"

# Installed (rendered) cc-aliases.sh, exactly as install_aliases() writes it.
mkdir -p "$ATF/share/aliases"
sed -e "s|{{AITEAMFORGE_DIR}}|$ATF|g" "$CC_ALIASES_TPL" >"$ATF/share/aliases/cc-aliases.sh"
CC_INSTALLED="$ATF/share/aliases/cc-aliases.sh"

# A DECLARED team route that the tap launcher does not apply. It must never
# leak into a row (the launcher runs on whatever it inherits).
mkdir -p "$SBHOME/.aiteamforge"
cat >"$SBHOME/.aiteamforge/team-paths.json" <<'JSON'
{"teams":{"academy":{"ai":{"credential":{"account_id":"declared-team-acct","nickname":"Declared","env_var_name":"CLAUDE_ACCT_TEST_TOKEN","engine_slug":"claude","account_slug":"x"}}}}}
JSON

# Persona prompt so _cc_launch has something to launch.
mkdir -p "$ATF/academy/scripts/prompts"
echo "You are a test persona." >"$ATF/academy/scripts/prompts/academy-training-prompt.txt"

sandboxed() {
    env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
        -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX \
        -u CLAUDE_BILLED_ACCOUNT_ID -u CLAUDE_BILLED_ACCOUNT_NICKNAME \
        -u CLAUDE_ACTIVE_ACCOUNT_ID -u CLAUDE_ACTIVE_ACCOUNT_NICKNAME \
        -u SESSION_TYPE -u SESSION_NAME -u SESSION_DIR -u SESSION_CODE \
        -u TMUX -u TMUX_PANE -u LCARS_TEAM -u CLAUDE_SESSION_ID \
        HOME="$SBHOME" AITEAMFORGE_DIR="$ATF" SESSION_ACCOUNT_MAP_PATH="$MAP" \
        PATH="$WORK/bin:$PATH" KB_TEAM=academy KB_TERMINAL=agent \
        CLAUDE_ACCT_TEST_TOKEN="fake-sentinel-declared-not-applied" \
        STUB_ARGV="$STUB_ARGV" STUB_STDIN="$STUB_STDIN" \
        "$@"
}
reset_logs() { : >"$MAP"; : >"$STUB_ARGV"; : >"$STUB_STDIN"; }
rows() { if [ -f "$MAP" ]; then grep -c . "$MAP"; else echo 0; fi; }
field() {
    printf '%s' "$1" | python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print("__ABSENT__" if v is None else (str(v).lower() if isinstance(v,bool) else v))' "$2"
}
launch_sid() { sed -n 's/.*--session-id \([0-9a-f-]*\).*/\1/p' "$STUB_ARGV" | head -1; }

# check_row <label> <want_account_id> <want_resolved>
check_row() {
    local line sid
    line="$(cat "$MAP" 2>/dev/null)"
    sid="$(launch_sid)"
    echo "$sid" >>"$ALL_SIDS"
    if [ "$(rows)" != 1 ]; then test_fail "$1: rows=$(rows), want 1"; return; fi
    if [ -z "$sid" ] || [ "$(field "$line" session_id)" != "$sid" ]; then
        test_fail "$1: row session_id=$(field "$line" session_id) != launch --session-id '$sid'"; return
    fi
    if [ "$(field "$line" account_id)" != "$2" ] || [ "$(field "$line" account_resolved)" != "$3" ]; then
        test_fail "$1: account_id=$(field "$line" account_id) resolved=$(field "$line" account_resolved), want '$2'/$3"; return
    fi
    if grep -q "declared-team-acct\|fake-sentinel" "$MAP"; then
        test_fail "$1: declared route or credential value leaked into the row"; return
    fi
    test_pass
}

if ! command -v zsh >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    test_start "E*: installed cc-aliases.sh records launches"
    test_skip "zsh and/or python3 not on PATH (cc-aliases.sh is zsh) — ST1/ST2/B1 still ran"
else
    test_start "E1: headless gate (printf | cc, no persona) → one row, default OAuth, not the declared route"
    reset_logs
    sandboxed zsh -fc 'source "$1" >/dev/null 2>&1; printf "%s\n" "GATE PROMPT e1" | cc' _ "$CC_INSTALLED" >/dev/null 2>"$WORK/e1.err"
    if grep -q "GATE PROMPT e1" "$STUB_STDIN"; then check_row E1 "" true
    else test_fail "gate prompt never reached claude; err=$(cat "$WORK/e1.err")"; fi

    test_start "E2: inherited credential (agent shell) → account_resolved:false, never machine default"
    reset_logs
    sandboxed env ANTHROPIC_AUTH_TOKEN="fake-sentinel-inherited" \
        zsh -fc 'source "$1" >/dev/null 2>&1; printf "%s\n" "GATE PROMPT e2" | cc' _ "$CC_INSTALLED" >/dev/null 2>"$WORK/e2.err"
    check_row E2 "" false

    test_start "E3: persona _cc_launch → one row keyed on the launch id"
    reset_logs
    sandboxed env SESSION_TYPE=academy SESSION_NAME=training \
        zsh -fc 'source "$1" >/dev/null 2>&1; cc </dev/null' _ "$CC_INSTALLED" >/dev/null 2>"$WORK/e3.err"
    if [ "$(grep -c . "$STUB_ARGV")" = 1 ] && grep -q -- "--append-system-prompt" "$STUB_ARGV"; then
        check_row E3 "" true
    else
        test_fail "persona launch did not run exactly once; argv=$(cat "$STUB_ARGV") err=$(tail -3 "$WORK/e3.err")"
    fi

    test_start "E4: cc WITH arguments (--resume) is untouched — no --session-id, no row"
    reset_logs
    sandboxed zsh -fc 'source "$1" >/dev/null 2>&1; cc --resume 11111111-2222-3333-4444-555555555555 </dev/null' _ "$CC_INSTALLED" >/dev/null 2>&1
    if grep -q -- "--session-id" "$STUB_ARGV" || [ "$(rows)" != 0 ]; then
        test_fail "argv=$(cat "$STUB_ARGV") rows=$(rows)"
    else test_pass; fi

    test_start "E5: recorder failure → launch still runs, failure visible on stderr"
    reset_logs
    mkdir -p "$WORK/map-is-a-dir.jsonl"
    sandboxed env SESSION_ACCOUNT_MAP_PATH="$WORK/map-is-a-dir.jsonl" \
        zsh -fc 'source "$1" >/dev/null 2>&1; printf "%s\n" "GATE PROMPT e5" | cc' _ "$CC_INSTALLED" >/dev/null 2>"$WORK/e5.err"
    launch_sid >>"$ALL_SIDS"
    if grep -q "GATE PROMPT e5" "$STUB_STDIN" && grep -q "recorder rc=" "$WORK/e5.err"; then test_pass
    else test_fail "stdin=$(cat "$STUB_STDIN") err=$(cat "$WORK/e5.err")"; fi
fi

# ═══ Z — real map untouched ═════════════════════════════════════════════════
test_start "Z: real ~/.claude/.session-account-map.jsonl never received a test session id"
_leak=false
if [ -f "$REAL_MAP" ]; then
    while IFS= read -r _s; do
        [ -n "$_s" ] && grep -q "$_s" "$REAL_MAP" && _leak=true
    done <"$ALL_SIDS"
fi
if $_leak; then test_fail "a test session id reached the REAL map"; else test_pass; fi

if [ -n "${_PASS_COUNT+x}" ]; then
    echo ""
    echo "XACA-1300-014 session-account-map shipping tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
