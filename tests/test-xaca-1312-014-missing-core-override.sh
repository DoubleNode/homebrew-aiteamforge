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

# ─────────────────────────────────────────────────────────────────────────
# XACA-1312 fix round 3 (bot review, PR #957, subitem XACA-1312-022):
# PARTIAL core, not just a fully-absent one. A truncated/mid-parse-error
# cc-account-routing.sh (interrupted upgrade copy) can define an EARLY
# function like _cc_route_prepare (~L1223) without ever reaching a LATER
# one like _cc_run_claude_with_auth (~L1693). Round 1/2's shims were
# installed PER missing function, so this half-loaded state resolved a
# REAL token via the real _cc_route_prepare and then silently dropped it
# into the (still-installed, since only _cc_run_claude_with_auth was
# missing) runner shim's `shift 2` — launching bare `claude` on the machine
# login with NO override set, while the banner/recorder still claimed the
# team account. Pre-fix-round-3 this was "invoked, no override, no
# warning" (the exact silent bypass this whole ticket exists to close);
# BEFORE round 1/2 existed at all it was rc=127 "command not found" (no
# launch at all — the safe-by-accident shape the round-2 review used as
# its control).
#
# P1/P2 prove the no-override refusal now also covers this partial shape.
# P3/P4 prove the override still launches (unrouted, no credential leaked)
# rather than crashing with "command not found".
#
# The cut point (N) is computed from the REAL core file at test time, not
# hardcoded — it must land strictly after _cc_route_prepare's definition
# and strictly before _cc_run_claude_with_auth's, so the failure this test
# exists to catch is reproduced regardless of future edits shifting line
# numbers in cc-account-routing.sh.
REAL_CORE="$TAP_ROOT/share/scripts/cc-account-routing.sh"
[ -f "$REAL_CORE" ] || { echo "FATAL: required file not found: $REAL_CORE" >&2; exit 1; }

route_prepare_line="$(grep -n '^_cc_route_prepare()' "$REAL_CORE" | head -1 | cut -d: -f1)"
run_claude_line="$(grep -n '^_cc_run_claude_with_auth()' "$REAL_CORE" | head -1 | cut -d: -f1)"
if [ -z "$route_prepare_line" ] || [ -z "$run_claude_line" ]; then
    echo "FATAL: could not locate _cc_route_prepare/_cc_run_claude_with_auth in $REAL_CORE — cannot compute a valid truncation point" >&2
    exit 1
fi
if [ "$run_claude_line" -le "$route_prepare_line" ]; then
    echo "FATAL: _cc_run_claude_with_auth ($run_claude_line) is not after _cc_route_prepare ($route_prepare_line) in $REAL_CORE — assumption this test relies on no longer holds" >&2
    exit 1
fi
TRUNCATE_AT=$((run_claude_line - 1))
if [ "$TRUNCATE_AT" -le "$route_prepare_line" ]; then
    echo "FATAL: computed truncation point ($TRUNCATE_AT) does not land strictly between _cc_route_prepare ($route_prepare_line) and _cc_run_claude_with_auth ($run_claude_line)" >&2
    exit 1
fi

TRUNC_CORE="$ATF/scripts/cc-account-routing.sh"
head -n "$TRUNCATE_AT" "$REAL_CORE" >"$TRUNC_CORE"
# Sanity: the truncated copy must actually fail to define
# _cc_run_claude_with_auth (proves the cut really landed mid-function /
# before it, not e.g. past a stray earlier match), and must still define
# _cc_route_prepare (proves the cut didn't accidentally land too early).
if zsh -fc "source '$TRUNC_CORE' >/dev/null 2>&1; command -v _cc_run_claude_with_auth" >/dev/null 2>&1; then
    echo "FATAL: truncated core at $TRUNCATE_AT still defines _cc_run_claude_with_auth — truncation point is wrong" >&2
    exit 1
fi
if ! zsh -fc "source '$TRUNC_CORE' >/dev/null 2>&1; command -v _cc_route_prepare" >/dev/null 2>&1; then
    echo "FATAL: truncated core at $TRUNCATE_AT no longer defines _cc_route_prepare — truncation point is wrong" >&2
    exit 1
fi

# ── P1: cc, no override, PARTIAL core → refuse (not "command not found") ─
test_start "P1: cc refuses when the routing core is PARTIALLY loaded (route_prepare defined, run_claude_with_auth not) and no override is set"
reset_logs
p1_out="$(sandboxed zsh -fc 'source "$1" >/dev/null 2>&1; printf "%s\n" "GATE PROMPT p1" | cc; print -r -- "RC=$?"' _ "$CC_INSTALLED" 2>&1)"
if [ ! -s "$STUB_MARKER" ] && printf '%s' "$p1_out" | grep -q "RC=1" && printf '%s' "$p1_out" | grep -q "routing core missing"; then
    test_pass
else
    test_fail "claude invoked, wrong rc, or 'command not found' leaked through; out=$p1_out marker=$(cat "$STUB_MARKER" 2>/dev/null)"
fi

# ── P2: ccc, no override, PARTIAL core → refuse ───────────────────────────
test_start "P2: ccc refuses when the routing core is PARTIALLY loaded and no override is set"
reset_logs
p2_out="$(sandboxed zsh -fc 'source "$1" >/dev/null 2>&1; ccc; print -r -- "RC=$?"' _ "$CC_INSTALLED" 2>&1)"
if [ ! -s "$STUB_MARKER" ] && printf '%s' "$p2_out" | grep -q "RC=1" && printf '%s' "$p2_out" | grep -q "routing core missing"; then
    test_pass
else
    test_fail "claude invoked, wrong rc, or 'command not found' leaked through; out=$p2_out marker=$(cat "$STUB_MARKER" 2>/dev/null)"
fi

# ── P3: cc, override set, PARTIAL core → launches unrouted, NO credential ─
test_start "P3: AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 makes cc launch on the machine login with a PARTIAL core, with no team credential leaked"
reset_logs
p3_out="$(sandboxed env AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 zsh -fc 'source "$1" >/dev/null 2>&1; printf "%s\n" "GATE PROMPT p3" | cc; print -r -- "RC=$?"' _ "$CC_INSTALLED" 2>&1)"
if [ -s "$STUB_MARKER" ] && printf '%s' "$p3_out" | grep -q "RC=0" \
   && printf '%s' "$p3_out" | grep -q "AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1" \
   && printf '%s' "$p3_out" | grep -q "MACHINE LOGIN" \
   && [ ! -s "$STUB_ENV" ]; then
    test_pass
else
    test_fail "out=$p3_out marker=$(cat "$STUB_MARKER" 2>/dev/null) env-leak=$(cat "$STUB_ENV" 2>/dev/null)"
fi

# ── P4: ccc, override set, PARTIAL core → launches unrouted, NO credential
test_start "P4: AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 makes ccc launch on the machine login with a PARTIAL core, with no team credential leaked"
reset_logs
p4_out="$(sandboxed env AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 zsh -fc 'source "$1" >/dev/null 2>&1; ccc; print -r -- "RC=$?"' _ "$CC_INSTALLED" 2>&1)"
if [ -s "$STUB_MARKER" ] && printf '%s' "$p4_out" | grep -q "AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1" \
   && printf '%s' "$p4_out" | grep -q "MACHINE LOGIN" \
   && [ ! -s "$STUB_ENV" ]; then
    test_pass
else
    test_fail "out=$p4_out marker=$(cat "$STUB_MARKER" 2>/dev/null) env-leak=$(cat "$STUB_ENV" 2>/dev/null)"
fi

# Remove the truncated core before the next block (M-series reused ATF —
# not an issue since they ran first, but leave the sandbox clean).
rm -f "$TRUNC_CORE"

# ─────────────────────────────────────────────────────────────────────────
# XACA-1312 fix round 4 (bot review, PR #957, subitem XACA-1312-025): the
# sentinel must be cleared when this file is SOURCED, not only checked at
# read time. Round 3's completeness gate (_cc_routing_core_complete) is a
# real function that stays defined once a COMPLETE core has been sourced
# into a shell. Re-sourcing a TRUNCATED/interrupted copy of the SAME file
# into that shell later (e.g. `aiteamforge upgrade` re-running mid-copy, or
# any code path that re-sources the core defensively) only ADDS/overwrites
# definitions -- it never UNSETS what the prior complete load already set.
# Before this fix, _CC_ROUTING_CORE_COMPLETE stayed 1 across the truncated
# re-source, so _cc_routing_core_complete kept reporting "complete" against
# a shell that now mixed stale (pre-truncation) and missing function
# bodies -- the same silent-drop shape XACA-1312-022 closed for a
# NEVER-complete core, reopened here for a PREVIOUSLY-complete one.
#
# S1 proves the gate itself flips false. S2 proves the integration
# behavior: cc refuses (no override) rather than launching on the stale
# "complete" state.
FULL_CORE_ATF="$ATF/scripts/cc-account-routing.sh"
cp "$REAL_CORE" "$FULL_CORE_ATF"
RESOURCE_TRUNC="$WORK/trunc-core-for-resource.sh"
head -n "$TRUNCATE_AT" "$REAL_CORE" >"$RESOURCE_TRUNC"

test_start "S1: re-sourcing a TRUNCATED core after a COMPLETE core in the same shell flips _cc_routing_core_complete to false"
reset_logs
s1_out="$(sandboxed zsh -fc '
    source "$1" >/dev/null 2>&1
    source "$2" >/dev/null 2>&1
    if command -v _cc_routing_core_complete >/dev/null 2>&1 && _cc_routing_core_complete; then
        print -r -- "COMPLETE=1"
    else
        print -r -- "COMPLETE=0"
    fi
' _ "$CC_INSTALLED" "$RESOURCE_TRUNC" 2>&1)"
if printf '%s' "$s1_out" | grep -q "COMPLETE=0"; then
    test_pass
else
    test_fail "expected COMPLETE=0 after a truncated re-source followed a complete one; out=$s1_out"
fi

test_start "S2: cc refuses (no override) after a COMPLETE core is followed by a TRUNCATED re-source in the same shell"
reset_logs
s2_out="$(sandboxed zsh -fc 'source "$1" >/dev/null 2>&1; source "$2" >/dev/null 2>&1; printf "%s\n" "GATE PROMPT s2" | cc; print -r -- "RC=$?"' _ "$CC_INSTALLED" "$RESOURCE_TRUNC" 2>&1)"
if [ ! -s "$STUB_MARKER" ] && printf '%s' "$s2_out" | grep -q "RC=1" && printf '%s' "$s2_out" | grep -q "routing core missing"; then
    test_pass
else
    test_fail "claude invoked or wrong rc/message; out=$s2_out marker=$(cat "$STUB_MARKER" 2>/dev/null)"
fi

rm -f "$FULL_CORE_ATF"

if [ -n "${_PASS_COUNT+x}" ]; then
    echo ""
    echo "XACA-1312-014 missing-core override tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
