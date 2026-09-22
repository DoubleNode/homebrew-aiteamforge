#!/bin/bash
# test-xaca-1312-014-missing-core-override.sh
#
# XACA-1312 fix round 1 (bot review, PR #957, subitem XACA-1312-014):
# share/templates/aliases/cc-aliases.sh's _cc_routing_core_missing used to
# return 1 UNCONDITIONALLY, so AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 — the exact
# escape hatch its own printed message (and design doc §6) promised — did
# nothing when the routing core itself was absent (partial install/upgrade,
# or a non-zsh caller). Verified pre-fix: core absent + override set + `ccc`
# still refused (rc=1, claude never invoked).
#
# This test proves, against the REAL rendered template (not a hand copy):
#   M1  no override → cc refuses (rc=1), claude never invoked
#   M2  no override → ccc refuses (rc=1), claude never invoked
#   M3  override set → cc launches on the machine login (rc=0, claude WAS
#       invoked, unrouted — no ANTHROPIC_*/CLAUDE_CODE_OAUTH_TOKEN injected)
#       and prints the unsuppressible ⚠ warning
#   M4  override set → ccc launches the same way
#
# Sandboxing: HOME/AITEAMFORGE_DIR point under TEST_TMP_DIR. `claude` is a
# stub on PATH; no real session is ever launched. The routing core is
# deliberately NEVER materialised in AITEAMFORGE_DIR/scripts/ — that
# absence is the scenario under test.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CC_ALIASES_TPL="$TAP_ROOT/share/templates/aliases/cc-aliases.sh"
[ -f "$CC_ALIASES_TPL" ] || { echo "FATAL: required file not found: $CC_ALIASES_TPL" >&2; exit 1; }

if ! type -t test_start >/dev/null 2>&1; then
    _PASS_COUNT=0; _FAIL_COUNT=0; _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi
type -t test_skip >/dev/null 2>&1 || test_skip() { echo "     SKIP: $_CURRENT_TEST — $1"; }

if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1312014.XXXXXX)"; _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
case "$TEST_TMP_DIR" in
    "$HOME"|"$HOME"/.claude*|"$HOME"/aiteamforge*) echo "FATAL: sandbox resolved onto a real path" >&2; exit 1 ;;
esac
WORK="$TEST_TMP_DIR/xaca1312014"
mkdir -p "$WORK"
cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -d "${TEST_TMP_DIR:-}" ]; then
        find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

if ! command -v zsh >/dev/null 2>&1; then
    test_start "M*: missing-core override handling (requires zsh)"
    test_skip "zsh not on PATH — cc-aliases.sh is zsh-only"
    if [ -n "${_PASS_COUNT+x}" ]; then
        echo ""
        echo "XACA-1312-014 missing-core override tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
        [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
    fi
    exit 0
fi

ATF="$WORK/home/aiteamforge"          # deliberately NO scripts/cc-account-routing.sh
SBHOME="$WORK/home"
mkdir -p "$ATF/scripts" "$SBHOME/.claude" "$ATF/academy/scripts/prompts"
echo "You are a test persona." >"$ATF/academy/scripts/prompts/academy-training-prompt.txt"

mkdir -p "$WORK/bin"
cat >"$WORK/bin/claude" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "--help" ]; then
    echo "  --session-id <uuid>  Use a specific session ID"
    exit 0
fi
printf '%s\n' "invoked" >> "$STUB_MARKER"
printf '%s\n' "$*" >> "$STUB_ARGV"
# Record whether any Anthropic credential var reached this "claude" —
# M3/M4 must show NONE of these, proving the override truly launches
# unrouted on the machine login and injects no team credential.
: >"$STUB_ENV"
[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]    && echo "ANTHROPIC_AUTH_TOKEN" >>"$STUB_ENV"
[ -n "${ANTHROPIC_API_KEY:-}" ]       && echo "ANTHROPIC_API_KEY" >>"$STUB_ENV"
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo "CLAUDE_CODE_OAUTH_TOKEN" >>"$STUB_ENV"
cat >/dev/null
exit 0
STUB
chmod +x "$WORK/bin/claude"

mkdir -p "$ATF/share/aliases"
sed -e "s|{{AITEAMFORGE_DIR}}|$ATF|g" "$CC_ALIASES_TPL" >"$ATF/share/aliases/cc-aliases.sh"
CC_INSTALLED="$ATF/share/aliases/cc-aliases.sh"

sandboxed() {
    env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
        -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX \
        -u CLAUDE_BILLED_ACCOUNT_ID -u CLAUDE_BILLED_ACCOUNT_NICKNAME \
        -u CLAUDE_ACTIVE_ACCOUNT_ID -u CLAUDE_ACTIVE_ACCOUNT_NICKNAME \
        -u SESSION_TYPE -u SESSION_NAME -u SESSION_DIR -u SESSION_CODE \
        -u TMUX -u TMUX_PANE -u LCARS_TEAM -u CLAUDE_SESSION_ID \
        -u AITEAMFORGE_ALLOW_DEFAULT_OAUTH \
        HOME="$SBHOME" AITEAMFORGE_DIR="$ATF" \
        PATH="$WORK/bin:$PATH" KB_TEAM=academy KB_TERMINAL=agent \
        STUB_MARKER="$STUB_MARKER" STUB_ARGV="$STUB_ARGV" STUB_ENV="$STUB_ENV" \
        "$@"
}
reset_logs() { : >"$STUB_MARKER"; : >"$STUB_ARGV"; : >"$STUB_ENV"; }
STUB_MARKER="$WORK/marker.log"; STUB_ARGV="$WORK/argv.log"; STUB_ENV="$WORK/env.log"

# ── M1: cc, no override, core missing → refuse ───────────────────────────
test_start "M1: cc refuses when routing core is missing and no override is set"
reset_logs
m1_out="$(sandboxed zsh -fc 'source "$1" >/dev/null 2>&1; printf "%s\n" "GATE PROMPT m1" | cc; print -r -- "RC=$?"' _ "$CC_INSTALLED" 2>&1)"
if [ ! -s "$STUB_MARKER" ] && printf '%s' "$m1_out" | grep -q "RC=1" && printf '%s' "$m1_out" | grep -q "routing core missing"; then
    test_pass
else
    test_fail "claude invoked or wrong rc/message; out=$m1_out marker=$(cat "$STUB_MARKER" 2>/dev/null)"
fi

# ── M2: ccc, no override, core missing → refuse ──────────────────────────
test_start "M2: ccc refuses when routing core is missing and no override is set"
reset_logs
m2_out="$(sandboxed zsh -fc 'source "$1" >/dev/null 2>&1; ccc; print -r -- "RC=$?"' _ "$CC_INSTALLED" 2>&1)"
if [ ! -s "$STUB_MARKER" ] && printf '%s' "$m2_out" | grep -q "RC=1" && printf '%s' "$m2_out" | grep -q "routing core missing"; then
    test_pass
else
    test_fail "claude invoked or wrong rc/message; out=$m2_out marker=$(cat "$STUB_MARKER" 2>/dev/null)"
fi

# ── M3: cc, override set, core missing → launches unrouted ───────────────
test_start "M3: AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 makes cc launch on the machine login despite a missing core"
reset_logs
m3_out="$(sandboxed env AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 zsh -fc 'source "$1" >/dev/null 2>&1; printf "%s\n" "GATE PROMPT m3" | cc; print -r -- "RC=$?"' _ "$CC_INSTALLED" 2>&1)"
if [ -s "$STUB_MARKER" ] && printf '%s' "$m3_out" | grep -q "RC=0" \
   && printf '%s' "$m3_out" | grep -q "AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1" \
   && printf '%s' "$m3_out" | grep -q "MACHINE LOGIN" \
   && [ ! -s "$STUB_ENV" ]; then
    test_pass
else
    test_fail "out=$m3_out marker=$(cat "$STUB_MARKER" 2>/dev/null) env-leak=$(cat "$STUB_ENV" 2>/dev/null)"
fi

# ── M4: ccc, override set, core missing → launches unrouted ──────────────
test_start "M4: AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 makes ccc launch on the machine login despite a missing core"
reset_logs
m4_out="$(sandboxed env AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 zsh -fc 'source "$1" >/dev/null 2>&1; ccc; print -r -- "RC=$?"' _ "$CC_INSTALLED" 2>&1)"
if [ -s "$STUB_MARKER" ] && printf '%s' "$m4_out" | grep -q "AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1" \
   && printf '%s' "$m4_out" | grep -q "MACHINE LOGIN" \
   && [ ! -s "$STUB_ENV" ]; then
    test_pass
else
    test_fail "out=$m4_out marker=$(cat "$STUB_MARKER" 2>/dev/null) env-leak=$(cat "$STUB_ENV" 2>/dev/null)"
fi

if [ -n "${_PASS_COUNT+x}" ]; then
    echo ""
    echo "XACA-1312-014 missing-core override tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
