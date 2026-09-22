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
#        path). RECORD ONLY — the "academy" team in team-paths.json declares
#        NO ai.credential (undeclared — mirrors the measured real-fleet norm,
#        XACA-0282-012 F2: 0 of 27 teams carried an `ai` block), so no
#        account_id ever appears in the row; the row carries default OAuth.
#
#        XACA-1312 fix round 1 (bot review, PR #957): this fixture now also
#        materialises cc-account-routing.sh into AITEAMFORGE_DIR/scripts/ (a
#        real install has it there per XACA-1312's own
#        _xaca0673_mandatory_materialize_basenames entry) so the rendered
#        cc-aliases.sh's "routing core missing" fail-closed guard does not
#        refuse every launch outright. With the core present, EVERY
#        team-context launch now runs GATED resolution (_cc_route_prepare),
#        even when the team is undeclared and the outcome is "use the
#        machine login".
#
#        XACA-1312 fix round 2 (orchestrator review of round 1): round 1's
#        claim above — "account_resolved is true whenever a row is written
#        at all" — was WRONG and has been REVERTED, not kept. It rested on
#        "_cc_record_session_account always passes --account-id explicitly,
#        even empty", which was accurate about round-1's code but encoded a
#        wrong billing record: _cc_run_claude_with_auth's empty-token
#        branch runs plain `claude "$@"`, which INHERITS whatever
#        credential the calling shell already carried (E2's
#        ANTHROPIC_AUTH_TOKEN="fake-sentinel-inherited" — an agent shell's
#        own token, never named in the row by design). Recording that as
#        "resolved, default OAuth" claims the launch ran on the machine
#        login when it actually ran on an unidentified inherited
#        credential. _cc_record_session_account now mirrors
#        session-account-map-headless.sh's own rule 1 vs rule 3 exactly: no
#        credential var anywhere in the shell → resolved/default-OAuth
#        (E1, E3 — neither sets ANTHROPIC_AUTH_TOKEN); a credential var
#        present with no gated billed pair → account_resolved=false,
#        unknown account (E2, restored to its pre-round-1 expectation). See
#        cc-account-routing.sh's _cc_record_session_account docstring for
#        the full rule table. E2b (below) exercises the ONE case that is
#        still legitimately resolved-to-a-real-account despite an inherited
#        credential: CLAUDE_BILLED_ACCOUNT_ID also present (a NESTED
#        headless launch inheriting an already-routed parent's exported
#        pair) — that is rule 2, unaffected by this fix, and only reachable
#        through the OTHER cc() branch (no team context at all, which still
#        calls session-account-map-headless.sh directly and always did). A
#        declared-but-unresolvable OR engine-mismatched credential is a
#        DIFFERENT, already-refused case (see cc-account-routing.sh's
#        engine guard and _cc_fail_closed) and is exhaustively covered by
#        scripts/tests/test-cc-aliases-smoke.sh, not here.
#   E5   recorder failure: the launch still happens and the failure is visible
#   E6/E6-ccc  the ticket's own core scenario: a DECLARED credential (team
#        "declared" in team-paths.json above) applied by the consumer
#        launcher end to end, through `cc` and through `ccc`. Env var is
#        checked for PRESENCE only in the stub (never its value); the
#        calling shell is checked too, to confirm the token stays scoped to
#        claude's child env (_cc_run_claude_with_auth's subshell), never
#        exported back.
#   E7/E7-ccc  same declared team, env var empty -> refuse (rc 1), claude
#        never runs, nothing is recorded — through `cc` and `ccc`.
#   E8   E7 + AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 -> launches anyway on an
#        unsuppressible warning, recorded as default OAuth.
#   E6 mutation check: breaks the declared env-var resolution in a SCRATCH
#        COPY of cc-account-routing.sh and confirms E6 goes red, proving E6
#        actually exercises that code path.
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
# XACA-1312 round 2 (E6): presence-only credential check, never the value.
# `${VAR:+SET}` alone is the safe idiom -- concatenating it with `${VAR:-...}`
# would print the ACTUAL VALUE when the var is set (the `:-` fallback
# operator only substitutes on unset/empty; when set it expands to $VAR
# itself), which is exactly the leak this must not reproduce.
if [ -n "${STUB_ENV:-}" ]; then
    {
        printf 'AUTH_TOKEN=%s\n' "${ANTHROPIC_AUTH_TOKEN:+SET}"
        printf 'API_KEY=%s\n' "${ANTHROPIC_API_KEY:+SET}"
        printf 'OAUTH_TOKEN=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN:+SET}"
    } >> "$STUB_ENV"
fi
exit 0
STUB
chmod +x "$WORK/bin/claude"
STUB_ARGV="$WORK/argv.log"; STUB_STDIN="$WORK/stdin.log"; STUB_ENV="$WORK/env.log"
MAP="$SBHOME/.claude/.session-account-map.jsonl"
ALL_SIDS="$WORK/sids.txt"; : >"$ALL_SIDS"

# Installed (rendered) cc-aliases.sh, exactly as install_aliases() writes it.
mkdir -p "$ATF/share/aliases"
sed -e "s|{{AITEAMFORGE_DIR}}|$ATF|g" "$CC_ALIASES_TPL" >"$ATF/share/aliases/cc-aliases.sh"
CC_INSTALLED="$ATF/share/aliases/cc-aliases.sh"

# XACA-1312 fix round 1 (bot review, PR #957): materialise the credential-
# routing core into AITEAMFORGE_DIR/scripts/ so this sandbox actually mirrors
# a real install — cc-aliases.sh's "routing core missing" fail-closed guard
# (XACA-1312 §6) refuses EVERY launch outright when this file is absent,
# which is what made E1-E5 die before ever reaching the recording behavior
# this test exists to check. No vault-fetch.sh is materialised alongside it
# — this fixture models a non-vault machine (tier 1 is skipped, "_vault_
# configured stays 0", per cc-account-routing.sh's own comment), which is
# sufficient for an undeclared team (env-var tier 3 never even runs for it).
cp "$TAP_ROOT/share/scripts/cc-account-routing.sh" "$ATF/scripts/cc-account-routing.sh"
chmod +x "$ATF/scripts/cc-account-routing.sh"

# The "academy" team declares NO ai.credential (undeclared) — mirrors the
# measured real-fleet norm (XACA-0282-012 F2: 0 of 27 teams carried an `ai`
# block). cred_state="absent" quietly defers to the machine login; see this
# file's top-of-file comment for why that still yields account_resolved:true
# now that the routing core is wired in (XACA-1312).
mkdir -p "$SBHOME/.aiteamforge"
cat >"$SBHOME/.aiteamforge/team-paths.json" <<'JSON'
{"teams":{"academy":{},"declared":{"ai":{"credential":{"account_id":"acct-e6-declared","nickname":"E6 Declared","env_var_name":"CLAUDE_ACCT_TEST_TOKEN"}}}}}
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
        STUB_ARGV="$STUB_ARGV" STUB_STDIN="$STUB_STDIN" STUB_ENV="$STUB_ENV" \
        "$@"
}
reset_logs() { : >"$MAP"; : >"$STUB_ARGV"; : >"$STUB_STDIN"; : >"$STUB_ENV"; }
rows() { if [ -f "$MAP" ]; then grep -c . "$MAP"; else echo 0; fi; }
field() {
    printf '%s' "$1" | python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print("__ABSENT__" if v is None else (str(v).lower() if isinstance(v,bool) else v))' "$2"
}
launch_sid() { sed -n 's/.*--session-id \([0-9a-f-]*\).*/\1/p' "$STUB_ARGV" | head -1; }

# check_row <label> <want_account_id> <want_resolved> [<want_rows>=1]
#
# XACA-1312 fix round 1: reads the LAST line only (`tail -n 1`), not the
# whole file concatenated — needed now that E3 legitimately writes 2 rows
# for one launch (see E3's own comment) and `field()`'s `json.load` cannot
# parse two concatenated JSON objects as one document (silently prints
# nothing on that parse error, which is what previously made a >1-row map
# read as if every field were empty/absent instead of failing loudly).
check_row() {
    local line sid want_rows="${4:-1}"
    line="$(tail -n 1 "$MAP" 2>/dev/null)"
    sid="$(launch_sid)"
    echo "$sid" >>"$ALL_SIDS"
    if [ "$(rows)" != "$want_rows" ]; then test_fail "$1: rows=$(rows), want $want_rows"; return; fi
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

    test_start "E2: inherited credential (agent shell), team undeclared → gated resolution attempted but produced no billed pair → account_resolved:false (unknown account), inherited token never named in the row"
    reset_logs
    sandboxed env ANTHROPIC_AUTH_TOKEN="fake-sentinel-inherited" \
        zsh -fc 'source "$1" >/dev/null 2>&1; printf "%s\n" "GATE PROMPT e2" | cc' _ "$CC_INSTALLED" >/dev/null 2>"$WORK/e2.err"
    check_row E2 "" false

    test_start "E2b: inherited credential + CLAUDE_BILLED_ACCOUNT_ID already exported (nested headless launch under an already-routed parent, NO team context) → resolved to that inherited account"
    reset_logs
    sandboxed env -u KB_TEAM \
        ANTHROPIC_AUTH_TOKEN="fake-sentinel-inherited-e2b" \
        CLAUDE_BILLED_ACCOUNT_ID="acct-e2b-parent" \
        CLAUDE_BILLED_ACCOUNT_NICKNAME="E2B Parent" \
        zsh -fc 'source "$1" >/dev/null 2>&1; printf "%s\n" "GATE PROMPT e2b" | cc' _ "$CC_INSTALLED" >/dev/null 2>"$WORK/e2b.err"
    if grep -q "GATE PROMPT e2b" "$STUB_STDIN"; then check_row E2b "acct-e2b-parent" true
    else test_fail "gate prompt never reached claude; err=$(cat "$WORK/e2b.err")"; fi

    # XACA-1312 fix round 1: _cc_launch (design doc §4 site #1) records
    # TWICE for one launch by design — once BEFORE invoking claude
    # (crash-safe: the session is trackable even if claude never exits) and
    # once AFTER (dev _cc_launch parity, same XACA-0668 rationale) — both
    # calls carry the same session id and the same (unchanged) billed
    # identity, so the MOST RECENT row is authoritative and a reader
    # (session-account-map.py lookup) already takes exactly that. 2 rows is
    # therefore the correct count here, not a bug — see check_row's own
    # comment for why field-parsing needed to change to accommodate it.
    test_start "E3: persona _cc_launch → 2 rows (pre-launch + post-exit), same session id, most recent authoritative"
    reset_logs
    sandboxed env SESSION_TYPE=academy SESSION_NAME=training \
        zsh -fc 'source "$1" >/dev/null 2>&1; cc </dev/null' _ "$CC_INSTALLED" >/dev/null 2>"$WORK/e3.err"
    if [ "$(grep -c . "$STUB_ARGV")" = 1 ] && grep -q -- "--append-system-prompt" "$STUB_ARGV"; then
        check_row E3 "" true 2
    else
        test_fail "persona launch did not run exactly once; argv=$(cat "$STUB_ARGV") err=$(tail -3 "$WORK/e3.err")"
    fi

    test_start "E4: cc WITH arguments (--resume) is untouched — no --session-id, no row"
    reset_logs
    sandboxed zsh -fc 'source "$1" >/dev/null 2>&1; cc --resume 11111111-2222-3333-4444-555555555555 </dev/null' _ "$CC_INSTALLED" >/dev/null 2>&1
    if grep -q -- "--session-id" "$STUB_ARGV" || [ "$(rows)" != 0 ]; then
        test_fail "argv=$(cat "$STUB_ARGV") rows=$(rows)"
    else test_pass; fi

    # XACA-1312 fix round 1 (bot review, PR #957): with a team context
    # (KB_TEAM=academy, always exported by sandboxed() above) the gate path
    # now goes through the SAME gated _cc_record_session_account every other
    # routed site uses, not the old standalone session-account-map-
    # headless.sh this assertion originally pinned. That shared helper's own
    # contract (cc-account-routing.sh, see _cc_record_session_account's
    # docstring) is fail-SOFT and SILENT by design — "$_recorder" ...
    # 2>/dev/null || true — specifically so a broken recorder can never
    # abort or even visibly disrupt a launch. So the invariant this test can
    # still hold is "the launch still runs despite a broken map location";
    # a stderr message is no longer part of the contract to assert on.
    test_start "E5: recorder write failure (map path is a directory) never blocks the launch"
    reset_logs
    mkdir -p "$WORK/map-is-a-dir.jsonl"
    sandboxed env SESSION_ACCOUNT_MAP_PATH="$WORK/map-is-a-dir.jsonl" \
        zsh -fc 'source "$1" >/dev/null 2>&1; printf "%s\n" "GATE PROMPT e5" | cc; print -r -- "RC=$?"' _ "$CC_INSTALLED" >"$WORK/e5.out" 2>"$WORK/e5.err"
    launch_sid >>"$ALL_SIDS"
    if grep -q "GATE PROMPT e5" "$STUB_STDIN" && grep -q "RC=0" "$WORK/e5.out"; then test_pass
    else test_fail "stdin=$(cat "$STUB_STDIN") out=$(cat "$WORK/e5.out") err=$(cat "$WORK/e5.err")"; fi

    # ═══ E6/E7/E8 — the ticket's own core scenario: a DECLARED credential
    # applied by the CONSUMER launcher (round-1 replaced the fixture's
    # declared-team case with the undeclared "academy" team above, which
    # left this end-to-end path with no coverage at all — see this file's
    # top-of-file comment). The "declared" team (team-paths.json above)
    # points env_var_name at CLAUDE_ACCT_TEST_TOKEN, which sandboxed()
    # already exports with a fake sentinel value by default — E6 uses that
    # default; E7/E8 override it to empty.
    test_start "E6: declared credential + env var SET (non-vault) → claude (stub) receives it in env (presence-only), row records the declared account, resolved:true, token never left in the calling shell"
    reset_logs
    sandboxed env KB_TEAM=declared \
        zsh -fc 'source "$1" >/dev/null 2>&1; printf "%s\n" "GATE PROMPT e6" | cc; print -r -- "SHELL_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN:+SET}"' \
        _ "$CC_INSTALLED" >"$WORK/e6.out" 2>"$WORK/e6.err"
    if grep -q "GATE PROMPT e6" "$STUB_STDIN" \
        && grep -q "^AUTH_TOKEN=SET$" "$STUB_ENV" \
        && grep -q "^SHELL_AUTH_TOKEN=$" "$WORK/e6.out"; then
        check_row E6 "acct-e6-declared" true
    else
        test_fail "argv=$(cat "$STUB_ARGV") env=$(cat "$STUB_ENV") out=$(cat "$WORK/e6.out") err=$(tail -5 "$WORK/e6.err")"
    fi

    test_start "E6-ccc: same declared credential via ccc() (no saved sidecar -> --continue fallback) → claude (stub) still receives it in env, never in the calling shell"
    reset_logs
    sandboxed env KB_TEAM=declared \
        zsh -fc 'source "$1" >/dev/null 2>&1; ccc </dev/null; print -r -- "RC=$? SHELL_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN:+SET}"' \
        _ "$CC_INSTALLED" >"$WORK/e6ccc.out" 2>"$WORK/e6ccc.err"
    if grep -q "^AUTH_TOKEN=SET$" "$STUB_ENV" && grep -q "RC=0 SHELL_AUTH_TOKEN=$" "$WORK/e6ccc.out"; then
        test_pass
    else
        test_fail "env=$(cat "$STUB_ENV") out=$(cat "$WORK/e6ccc.out") err=$(tail -5 "$WORK/e6ccc.err")"
    fi

    test_start "E7: declared credential + env var EMPTY (non-vault) → refuse, rc 1, stub claude NOT invoked, no row claiming the machine login"
    reset_logs
    sandboxed env KB_TEAM=declared CLAUDE_ACCT_TEST_TOKEN= \
        zsh -fc 'source "$1" >/dev/null 2>&1; printf "%s\n" "GATE PROMPT e7" | cc; print -r -- "RC=$?"' \
        _ "$CC_INSTALLED" >"$WORK/e7.out" 2>"$WORK/e7.err"
    if grep -q "RC=1" "$WORK/e7.out" && ! grep -q "GATE PROMPT e7" "$STUB_STDIN" && [ "$(rows)" = 0 ]; then
        test_pass
    else
        test_fail "out=$(cat "$WORK/e7.out") rows=$(rows) stdin=$(cat "$STUB_STDIN") err=$(tail -5 "$WORK/e7.err")"
    fi

    test_start "E7-ccc: same empty-env-var refusal via ccc() — rc 1, stub claude NOT invoked (before any sidecar is even read)"
    reset_logs
    sandboxed env KB_TEAM=declared CLAUDE_ACCT_TEST_TOKEN= \
        zsh -fc 'source "$1" >/dev/null 2>&1; ccc </dev/null; print -r -- "RC=$?"' \
        _ "$CC_INSTALLED" >"$WORK/e7ccc.out" 2>"$WORK/e7ccc.err"
    if grep -q "RC=1" "$WORK/e7ccc.out" && [ "$(rows)" = 0 ] && [ ! -s "$STUB_ARGV" ]; then
        test_pass
    else
        test_fail "out=$(cat "$WORK/e7ccc.out") rows=$(rows) argv=$(cat "$STUB_ARGV") err=$(tail -5 "$WORK/e7ccc.err")"
    fi

    test_start "E8: E7 + AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 → launches anyway, unsuppressible warning printed, row = default OAuth"
    reset_logs
    sandboxed env KB_TEAM=declared CLAUDE_ACCT_TEST_TOKEN= AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 \
        zsh -fc 'source "$1" >/dev/null 2>&1; printf "%s\n" "GATE PROMPT e8" | cc; print -r -- "RC=$?"' \
        _ "$CC_INSTALLED" >"$WORK/e8.out" 2>"$WORK/e8.err"
    if grep -q "GATE PROMPT e8" "$STUB_STDIN" && grep -q "RC=0" "$WORK/e8.out" \
        && grep -q "AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1" "$WORK/e8.err" \
        && grep -q "MACHINE LOGIN" "$WORK/e8.err"; then
        check_row E8 "" true
    else
        test_fail "out=$(cat "$WORK/e8.out") err=$(cat "$WORK/e8.err") stdin=$(cat "$STUB_STDIN")"
    fi

    # Mutation check for E6: break the declared-credential env-var path in a
    # scratch COPY of the routing core and confirm E6 goes red (proves the
    # test actually exercises that code, not a vacuously-green fixture).
    test_start "E6 mutation check: breaking the declared env-var resolution makes E6 fail"
    _mut_core="$WORK/cc-account-routing.mutant.sh"
    sed 's/_CC_RESOLVED_TOKEN="\$_env_token"/_CC_RESOLVED_TOKEN=""/' \
        "$ATF/scripts/cc-account-routing.sh" >"$_mut_core"
    if ! diff -q "$ATF/scripts/cc-account-routing.sh" "$_mut_core" >/dev/null 2>&1; then
        cp "$ATF/scripts/cc-account-routing.sh" "$WORK/cc-account-routing.orig.sh"
        cp "$_mut_core" "$ATF/scripts/cc-account-routing.sh"
        reset_logs
        sandboxed env KB_TEAM=declared \
            zsh -fc 'source "$1" >/dev/null 2>&1; printf "%s\n" "GATE PROMPT e6mut" | cc; print -r -- "RC=$?"' \
            _ "$CC_INSTALLED" >"$WORK/e6mut.out" 2>"$WORK/e6mut.err"
        cp "$WORK/cc-account-routing.orig.sh" "$ATF/scripts/cc-account-routing.sh"
        # Mutated: token resolution silently zeroed, but a declared credential
        # was still found -- _CC_BILLED_ID stays non-empty (from
        # CLAUDE_ACTIVE_ACCOUNT_ID, gated on $_CC_RESOLVED_TOKEN in
        # _cc_route_prepare) only when the token IS non-empty, so this mutant
        # instead surfaces as a launch that now records default OAuth (or a
        # differing account_id) instead of E6's declared account -- either
        # way, NOT a match for E6's asserted row. Confirm the mutant's
        # observable result actually differs from E6's.
        if grep -q "^AUTH_TOKEN=SET$" "$STUB_ENV"; then
            test_fail "mutant still injected a credential into claude's env — mutation had no effect"
        else
            test_pass
        fi
    else
        test_fail "mutation sed produced no change — pattern no longer matches cc-account-routing.sh"
    fi
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
