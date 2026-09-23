#!/bin/bash
# test-xaca-1312-022-kbcr-core-completeness.sh
#
# XACA-1312 fix round 3 (bot review, PR #957, subitem XACA-1312-022):
# kb-cr.sh had the SAME partial-core hole as cc-aliases.sh (see
# test-xaca-1312-014-missing-core-override.sh's P1-P4 for the full
# repro/fix narrative). kb-cr.sh's publish flow used to gate on
# `command -v _cc_route_prepare` (routing decision) and, separately,
# `command -v _cc_run_claude_with_auth` (which launcher to call) — two
# independent per-function checks. A truncated core (defines
# _cc_route_prepare, not _cc_run_claude_with_auth) passed the FIRST check,
# resolved a real token, then failed the SECOND check and fell straight to
# a plain `claude -p` call with NO AITEAMFORGE_ALLOW_DEFAULT_OAUTH gate at
# all — dropping the resolved token unconditionally, not just under
# explicit consent.
#
# This test does not drive the full `kb-cr publish` flow (heavy CR/board
# fixture setup, out of scope for this regression). It instead verifies,
# against the REAL shipped kb-cr.sh, the ONE piece of new logic the round-3
# fix depends on: sourcing kb-cr.sh must always leave a working
# _cc_routing_core_complete in scope, and that function must correctly
# distinguish a full core from a partial one. Both call sites the publish
# flow uses (`_kbcr_core_complete=1` guarding both the routing decision AND
# the launcher choice — see kb-cr.sh's own comment on the routing block)
# collapse to this single boolean, so this is the load-bearing check.
#
# K1  full core sourced → _cc_routing_core_complete returns 0 (true), and
#     the four required functions are all defined
# K2  PARTIAL core sourced (same truncation shape as P1-P4) →
#     _cc_routing_core_complete returns 1 (false), even though
#     _cc_route_prepare IS defined
# K3  no core file at all → kb-cr.sh's own local fallback stub defines
#     _cc_routing_core_complete, and it returns 1 (false)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KB_CR_SH="$TAP_ROOT/share/scripts/kb-cr.sh"
REAL_CORE="$TAP_ROOT/share/scripts/cc-account-routing.sh"
[ -f "$KB_CR_SH" ] || { echo "FATAL: required file not found: $KB_CR_SH" >&2; exit 1; }
[ -f "$REAL_CORE" ] || { echo "FATAL: required file not found: $REAL_CORE" >&2; exit 1; }

if ! type -t test_start >/dev/null 2>&1; then
    _PASS_COUNT=0; _FAIL_COUNT=0; _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi
type -t test_skip >/dev/null 2>&1 || test_skip() { echo "     SKIP: $_CURRENT_TEST — $1"; }

if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1312022.XXXXXX)"; _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
case "$TEST_TMP_DIR" in
    "$HOME"|"$HOME"/.claude*|"$HOME"/aiteamforge*) echo "FATAL: sandbox resolved onto a real path" >&2; exit 1 ;;
esac
WORK="$TEST_TMP_DIR/xaca1312022"
mkdir -p "$WORK"
cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -d "${TEST_TMP_DIR:-}" ]; then
        find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

if ! command -v zsh >/dev/null 2>&1; then
    test_start "K*: kb-cr.sh core-completeness gate (requires zsh)"
    test_skip "zsh not on PATH — kb-cr.sh is zsh-only"
    if [ -n "${_PASS_COUNT+x}" ]; then
        echo ""
        echo "XACA-1312-022 kb-cr.sh core-completeness tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
        [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
    fi
    exit 0
fi

sandboxed() {
    env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
        -u AITEAMFORGE_ALLOW_DEFAULT_OAUTH -u KB_TEAM -u KB_TERMINAL \
        HOME="$WORK/home" "$@"
}
mkdir -p "$WORK/home"

# ── K1: full core sourced alongside kb-cr.sh → complete ──────────────────
test_start "K1: kb-cr.sh + full core → _cc_routing_core_complete is true, all 4 functions defined"
FULLDIR="$WORK/full"
mkdir -p "$FULLDIR"
cp "$KB_CR_SH" "$FULLDIR/kb-cr.sh"
cp "$REAL_CORE" "$FULLDIR/cc-account-routing.sh"
k1_out="$(sandboxed zsh -fc '
    source "$1"/kb-cr.sh >/dev/null 2>&1
    ok=1
    command -v _cc_routing_core_complete >/dev/null 2>&1 || ok=0
    _cc_routing_core_complete || ok=0
    for fn in _cc_route_prepare _cc_run_claude_with_auth _cc_record_session_account _cc_resume_account_guard; do
        command -v "$fn" >/dev/null 2>&1 || ok=0
    done
    print -r -- "OK=$ok"
' _ "$FULLDIR" 2>&1)"
if printf '%s' "$k1_out" | grep -q "OK=1"; then
    test_pass
else
    test_fail "expected OK=1; got: $k1_out"
fi

# ── K2: PARTIAL core (same truncation shape as P1-P4) → incomplete ───────
route_prepare_line="$(grep -n '^_cc_route_prepare()' "$REAL_CORE" | head -1 | cut -d: -f1)"
run_claude_line="$(grep -n '^_cc_run_claude_with_auth()' "$REAL_CORE" | head -1 | cut -d: -f1)"
if [ -z "$route_prepare_line" ] || [ -z "$run_claude_line" ] || [ "$run_claude_line" -le "$route_prepare_line" ]; then
    echo "FATAL: could not compute a valid truncation point in $REAL_CORE" >&2
    exit 1
fi
TRUNCATE_AT=$((run_claude_line - 1))

test_start "K2: kb-cr.sh + PARTIAL core (route_prepare defined, run_claude_with_auth not) → _cc_routing_core_complete is false"
PARTIALDIR="$WORK/partial"
mkdir -p "$PARTIALDIR"
cp "$KB_CR_SH" "$PARTIALDIR/kb-cr.sh"
head -n "$TRUNCATE_AT" "$REAL_CORE" >"$PARTIALDIR/cc-account-routing.sh"
k2_out="$(sandboxed zsh -fc '
    source "$1"/kb-cr.sh >/dev/null 2>&1
    has_rp=0; command -v _cc_route_prepare >/dev/null 2>&1 && has_rp=1
    complete=1; _cc_routing_core_complete && complete=0
    # complete is inverted on purpose: 1 means "reported incomplete" (want this)
    print -r -- "HAS_ROUTE_PREPARE=$has_rp REPORTED_INCOMPLETE=$complete"
' _ "$PARTIALDIR" 2>&1)"
if printf '%s' "$k2_out" | grep -q "HAS_ROUTE_PREPARE=1" && printf '%s' "$k2_out" | grep -q "REPORTED_INCOMPLETE=1"; then
    test_pass
else
    test_fail "core must define _cc_route_prepare but still report incomplete; got: $k2_out"
fi

# ── K3: no core file at all → kb-cr.sh's own fallback reports incomplete ──
test_start "K3: kb-cr.sh with NO core file present → local fallback reports incomplete"
NOCOREDIR="$WORK/nocore"
mkdir -p "$NOCOREDIR"
cp "$KB_CR_SH" "$NOCOREDIR/kb-cr.sh"
k3_out="$(sandboxed zsh -fc '
    source "$1"/kb-cr.sh >/dev/null 2>&1
    defined=0; command -v _cc_routing_core_complete >/dev/null 2>&1 && defined=1
    complete=1; _cc_routing_core_complete && complete=0
    print -r -- "DEFINED=$defined REPORTED_INCOMPLETE=$complete"
' _ "$NOCOREDIR" 2>&1)"
if printf '%s' "$k3_out" | grep -q "DEFINED=1" && printf '%s' "$k3_out" | grep -q "REPORTED_INCOMPLETE=1"; then
    test_pass
else
    test_fail "expected the local fallback to define _cc_routing_core_complete and report incomplete; got: $k3_out"
fi

# ─────────────────────────────────────────────────────────────────────────
# XACA-1312 fix round 4 (bot review, PR #957, subitem XACA-1312-024): K1-K3
# above only prove the completeness GATE itself distinguishes a full core
# from a partial one (this file's header explicitly scopes out driving
# _kb_cr_publish). That leaves the publish flow's OWN routing branches --
# refuse-without-override / launch-unrouted-with-override, the same
# AITEAMFORGE_ALLOW_DEFAULT_OAUTH shape as
# test-xaca-1312-014-missing-core-override.sh's M/P series -- unverified
# for kb-cr.sh's call site specifically. It has its own independent gate
# wiring (kb-cr.sh's publish flow, ~L4362-4394), not a call into
# cc-aliases.sh's shared launch sites.
#
# L1/L2 isolate _kb_cr_publish the same way K1-K3 isolate the completeness
# gate: source the REAL kb-cr.sh next to a PARTIAL core (same truncation
# shape as K2), then override every board/network-touching dependency
# (_kb_cr_preamble, _kb_jq_read, _kb_cr_find_container,
# _kb_cr_set_confluence_url, _kb_cr_set_publish_stamps) with sandboxed
# stand-ins, relying on the SAME dynamic-scoping convention the real
# _kb_cr_preamble uses (assigns _cr_team/_cr_board/etc. without `local`,
# into the caller's locals) -- so the call never touches a real kanban
# board or Confluence; only the routing-gate branch under test executes.
# `claude` is a stub on PATH; no real session or Confluence call is ever
# made.
#
# L1  no override → _kb_cr_publish refuses (rc=1), claude stub NEVER invoked
# L2  override set → _kb_cr_publish invokes the claude stub, with NO
#     ANTHROPIC_*/CLAUDE_CODE_OAUTH_TOKEN var reaching it (presence-only
#     check via ${VAR:+SET}), and prints the unsuppressible MACHINE LOGIN
#     warning
LDIR="$WORK/publish-partial"
mkdir -p "$LDIR/bin" "$LDIR/board/cr-docs" "$LDIR/home"
cp "$KB_CR_SH" "$LDIR/kb-cr.sh"
head -n "$TRUNCATE_AT" "$REAL_CORE" >"$LDIR/cc-account-routing.sh"
ITEM_ID="XACA-TEST-0001"
echo "# fake CR doc" >"$LDIR/board/cr-docs/${ITEM_ID}-CR.md"

L_STUB_MARKER="$LDIR/marker.log"
L_STUB_ENV="$LDIR/env.log"
cat >"$LDIR/bin/claude" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "--help" ]; then
    echo "  --session-id <uuid>  Use a specific session ID"
    exit 0
fi
printf '%s\n' "invoked" >>"$L_STUB_MARKER"
: >"$L_STUB_ENV"
[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]    && echo "ANTHROPIC_AUTH_TOKEN" >>"$L_STUB_ENV"
[ -n "${ANTHROPIC_API_KEY:-}" ]       && echo "ANTHROPIC_API_KEY" >>"$L_STUB_ENV"
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo "CLAUDE_CODE_OAUTH_TOKEN" >>"$L_STUB_ENV"
cat >/dev/null
echo "Confluence URL: https://example.invalid/wiki/spaces/DPD2/pages/1"
echo "Confluence Version: 1"
echo "Confluence Title: Test CR"
exit 0
STUB
chmod +x "$LDIR/bin/claude"

sandboxed_pub() {
    env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
        -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX \
        -u CLAUDE_BILLED_ACCOUNT_ID -u CLAUDE_BILLED_ACCOUNT_NICKNAME \
        -u CLAUDE_ACTIVE_ACCOUNT_ID -u CLAUDE_ACTIVE_ACCOUNT_NICKNAME \
        -u SESSION_TYPE -u SESSION_NAME -u SESSION_DIR -u SESSION_CODE \
        -u TMUX -u TMUX_PANE -u LCARS_TEAM -u CLAUDE_SESSION_ID \
        -u AITEAMFORGE_ALLOW_DEFAULT_OAUTH \
        HOME="$LDIR/home" PATH="$LDIR/bin:$PATH" KB_TEAM=academy KB_TERMINAL=agent \
        L_STUB_MARKER="$L_STUB_MARKER" L_STUB_ENV="$L_STUB_ENV" \
        "$@"
}
reset_l_logs() { : >"$L_STUB_MARKER"; : >"$L_STUB_ENV"; }

test_start "L1: kb-cr publish with a PARTIAL core and NO override refuses (rc=1), claude stub never invoked"
reset_l_logs
l1_out="$(sandboxed_pub zsh -fc '
    LDIR_L="$1"; ITEM_L="$2"
    source "$LDIR_L/kb-cr.sh" >/dev/null 2>&1
    _kb_cr_preamble() {
        _cr_team="academy"; _cr_board="$LDIR_L/board/board.json"
        _cr_enabled="true"; _cr_item_id="$ITEM_L"; _cr_idx=0
        return 0
    }
    _kb_jq_read() { echo "CR-TEST-0001"; }
    _kb_cr_find_container() { echo "0"; }
    _kb_cr_set_confluence_url() { return 0; }
    _kb_cr_set_publish_stamps() { return 0; }
    _kb_cr_publish "$ITEM_L"
    print -r -- "RC=$?"
' _ "$LDIR" "$ITEM_ID" 2>&1)"
if [ ! -s "$L_STUB_MARKER" ] && printf '%s' "$l1_out" | grep -q "RC=1" \
   && printf '%s' "$l1_out" | grep -q "routing core did not load/incomplete"; then
    test_pass
else
    test_fail "claude invoked or wrong rc/message; out=$l1_out marker=$(cat "$L_STUB_MARKER" 2>/dev/null)"
fi

test_start "L2: kb-cr publish with a PARTIAL core and AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 invokes the claude stub with no team credential, prints the warning"
reset_l_logs
l2_out="$(sandboxed_pub env AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 zsh -fc '
    LDIR_L="$1"; ITEM_L="$2"
    source "$LDIR_L/kb-cr.sh" >/dev/null 2>&1
    _kb_cr_preamble() {
        _cr_team="academy"; _cr_board="$LDIR_L/board/board.json"
        _cr_enabled="true"; _cr_item_id="$ITEM_L"; _cr_idx=0
        return 0
    }
    _kb_jq_read() { echo "CR-TEST-0001"; }
    _kb_cr_find_container() { echo "0"; }
    _kb_cr_set_confluence_url() { return 0; }
    _kb_cr_set_publish_stamps() { return 0; }
    _kb_cr_publish "$ITEM_L"
    print -r -- "RC=$?"
' _ "$LDIR" "$ITEM_ID" 2>&1)"
if [ -s "$L_STUB_MARKER" ] && printf '%s' "$l2_out" | grep -q "AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1" \
   && printf '%s' "$l2_out" | grep -q "MACHINE LOGIN" \
   && [ ! -s "$L_STUB_ENV" ]; then
    test_pass
else
    test_fail "out=$l2_out marker=$(cat "$L_STUB_MARKER" 2>/dev/null) env-leak=$(cat "$L_STUB_ENV" 2>/dev/null)"
fi

if [ -n "${_PASS_COUNT+x}" ]; then
    echo ""
    echo "XACA-1312-022 kb-cr.sh core-completeness tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
