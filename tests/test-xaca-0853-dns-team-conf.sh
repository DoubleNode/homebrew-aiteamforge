#!/bin/bash

# test-xaca-0853-dns-team-conf.sh
#
# Regression + structural tests for XACA-0853: dns shipped NO share/teams/*.conf,
# which made it invisible to every code path that discovers teams by globbing
# that directory. The team could not be provisioned, and sweeps believed to be
# fleet-wide silently skipped it.
#
# WHY THIS BECAME LOAD-BEARING ON 2026-09-02. The previous arrangement — dns
# lifecycle scripts hand-authored and committed to the dev-team repo root —
# worked only because dns ran on the dev-source machine, where those files were
# simply present. On 2026-09-02 dns migrated to a TAP CONSUMER with no dev-team
# checkout. Measured there 2026-09-09: the 19GB umbrella tree, 7 personas and a
# live LCARS on :8180 were all present, and ALL FOUR lifecycle scripts
# (startup/shutdown/connect/disconnect) were absent. The team was running with
# no sanctioned way to be started, stopped, or attached to.
#
# NON-VACUITY. Structural greps are the failure mode this harness is prone to:
# a pattern that matches nothing reads identical to a pattern whose contract
# holds. Every structural assertion below therefore asserts on a RESOLVED LINE
# NUMBER or a COUNT, never on "grep found something". T0 is a negative control
# that fails loudly if the file under test cannot be located at all, so a moved
# or renamed installer can never present as a green suite.
#
# CONTRACT UNDER TEST:
#   1. share/teams/dns.conf exists, is shell-parseable, and sets TEAM_ID=dns.
#   2. It declares all 7 dns agents, each with a 4-window list — the data whose
#      absence XACA-0862 warned would ship broken tmux session names.
#   3. dns appears in share/teams/registry.json (the installable catalog).
#   4. The tap ships all four dns lifecycle scripts plus the 8 station scripts.
#   5. _xaca0483_install_script is defined exactly ONCE, and BEFORE
#      _render_connect_disconnect — the ordering bug that would have made a
#      hand-authored connect script die with "command not found" on the
#      --connect-only path while working on the main install path.
#   6. The hand-authored branch is a FILE-PRESENCE contract, not a hardcoded
#      team id, and is evaluated BEFORE the parametric and flat template
#      branches so a team shipping its own scripts is never overwritten.

set -uo pipefail

# ---------------------------------------------------------------------------
# Harness (self-contained; matches the tap suite's test_pass/test_fail shape)
# ---------------------------------------------------------------------------
_PASS_COUNT=0
_FAIL_COUNT=0
_CURRENT_TEST=""

start_test() { _CURRENT_TEST="$1"; echo "  → $1"; }
test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }

# ---------------------------------------------------------------------------
# Self-locate the tap root from this script, so CWD never matters.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONF="$TAP_ROOT/share/teams/dns.conf"
REGISTRY="$TAP_ROOT/share/teams/registry.json"
INSTALLER="$TAP_ROOT/libexec/installers/install-team.sh"
TEAMS_SCRIPTS="$TAP_ROOT/share/scripts/teams"

echo "XACA-0853 — dns team conf + hand-authored connect provisioning"
echo "tap root: $TAP_ROOT"
echo

# ---------------------------------------------------------------------------
# T0 — NEGATIVE CONTROL. If the files under test cannot be found, every
# structural assertion below would trivially "not match" and could be misread
# as passing. Fail loudly and stop instead.
# ---------------------------------------------------------------------------
start_test "T0 negative control: files under test are present"
_t0_missing=""
for _f in "$CONF" "$REGISTRY" "$INSTALLER"; do
    [ -f "$_f" ] || _t0_missing="$_t0_missing $_f"
done
if [ -n "$_t0_missing" ]; then
    test_fail "cannot locate:$_t0_missing — every later assertion would be vacuous"
    echo
    echo "RESULT: $_PASS_COUNT passed, $_FAIL_COUNT failed (aborted at negative control)"
    exit 1
fi
test_pass

# ---------------------------------------------------------------------------
# T1 — conf exists, parses, and identifies dns
# ---------------------------------------------------------------------------
start_test "T1 dns.conf is shell-parseable and sets TEAM_ID=dns"
if ! bash -n "$CONF" 2>/dev/null; then
    test_fail "dns.conf is not shell-parseable"
else
    _tid="$(unset TEAM_ID; . "$CONF" >/dev/null 2>&1; echo "${TEAM_ID:-}")"
    if [ "$_tid" = "dns" ]; then test_pass; else test_fail "TEAM_ID resolved to '$_tid', expected 'dns'"; fi
fi

# ---------------------------------------------------------------------------
# T2 — all 7 agents present, each with exactly 4 windows.
# This is the data XACA-0862 named as the real missing input. Asserting the
# COUNT (not merely "some windows exist") is what makes this non-vacuous.
# ---------------------------------------------------------------------------
start_test "T2 all 7 dns agents declared, each with a 4-window list"
_t2_err=""
_t2_out="$(
    . "$CONF" >/dev/null 2>&1
    echo "COUNT=${#TEAM_AGENTS[@]}"
    for _a in "${TEAM_AGENTS[@]}"; do
        _v="AGENT_WINDOWS_$_a"
        _w="$(eval "printf '%s' \"\${$_v:-}\"")"
        echo "AGENT=$_a WINDOWS=$(printf '%s' "$_w" | wc -w | tr -d ' ')"
    done
)"
_t2_count="$(printf '%s\n' "$_t2_out" | sed -n 's/^COUNT=//p')"
[ "$_t2_count" = "7" ] || _t2_err="expected 7 agents, got '$_t2_count'"
while IFS= read -r _line; do
    case "$_line" in
        AGENT=*)
            _an="${_line#AGENT=}"; _an="${_an%% *}"
            _wc="${_line##*WINDOWS=}"
            [ "$_wc" = "4" ] || _t2_err="$_t2_err; agent '$_an' has $_wc windows, expected 4"
            ;;
    esac
done <<EOF
$_t2_out
EOF
if [ -z "$_t2_err" ]; then test_pass; else test_fail "$_t2_err"; fi

# ---------------------------------------------------------------------------
# T3 — dns is in the installable catalog
# ---------------------------------------------------------------------------
start_test "T3 dns present in registry.json and the file is valid JSON"
if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$REGISTRY" >/dev/null 2>&1; then
    test_fail "registry.json is not valid JSON"
else
    _n="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for t in d.get('teams',[]) if t.get('id')=='dns'))
" "$REGISTRY" 2>/dev/null)"
    if [ "$_n" = "1" ]; then test_pass; else test_fail "expected exactly 1 dns entry, found '$_n'"; fi
fi

# ---------------------------------------------------------------------------
# T4 — the tap actually ships the dns scripts. Provisioning cannot install a
# file the tap does not carry, so this is the delivery half of the fix.
# ---------------------------------------------------------------------------
start_test "T4 tap ships all 4 dns lifecycle scripts and 8 station scripts"
_t4_err=""
for _f in dns-startup.sh dns-shutdown.sh dns-connect.sh dns-disconnect.sh; do
    [ -f "$TEAMS_SCRIPTS/$_f" ] || _t4_err="$_t4_err missing:$_f"
done
_t4_stations=0
if [ -d "$TEAMS_SCRIPTS/dns/scripts" ]; then
    _t4_stations="$(find "$TEAMS_SCRIPTS/dns/scripts" -name 'dns-*-startup.sh' -type f | wc -l | tr -d ' ')"
fi
[ "$_t4_stations" = "8" ] || _t4_err="$_t4_err station-count=$_t4_stations expected 8"
if [ -z "$_t4_err" ]; then test_pass; else test_fail "$_t4_err"; fi

# ---------------------------------------------------------------------------
# T5 — ORDERING GUARD. _render_connect_disconnect is called from the
# --connect-only early exit. If _xaca0483_install_script is defined after that
# call site, the hand-authored path dies with "command not found" on that path
# only — a split failure that passes a main-flow smoke test.
# Asserted on resolved line numbers, so a renamed function fails rather than
# silently matching nothing.
# ---------------------------------------------------------------------------
start_test "T5 _xaca0483_install_script defined exactly once, before every _render_connect_disconnect call"
_def_count="$(grep -c '^_xaca0483_install_script() {' "$INSTALLER" || true)"
_def_line="$(grep -n '^_xaca0483_install_script() {' "$INSTALLER" | head -1 | cut -d: -f1)"
_t5_err=""
if [ "$_def_count" != "1" ]; then
    _t5_err="expected exactly 1 definition, found $_def_count"
elif [ -z "$_def_line" ]; then
    _t5_err="could not resolve definition line number"
else
    _call_lines="$(grep -n '^[[:space:]]*_render_connect_disconnect[[:space:]]*$' "$INSTALLER" | cut -d: -f1)"
    if [ -z "$_call_lines" ]; then
        _t5_err="no _render_connect_disconnect call sites found — assertion would be vacuous"
    else
        for _cl in $_call_lines; do
            [ "$_cl" -gt "$_def_line" ] || _t5_err="$_t5_err; call at line $_cl precedes definition at $_def_line"
        done
    fi
fi
if [ -z "$_t5_err" ]; then test_pass; else test_fail "$_t5_err"; fi

# ---------------------------------------------------------------------------
# T6 — the hand-authored opt-in is a FILE-PRESENCE contract, not a team list.
# A hardcoded `dns` would be the sibling-heuristic that must be found and
# edited again for the next such team.
# ---------------------------------------------------------------------------
start_test "T6 _has_preauthored_connect keys on file presence, not a hardcoded team id"
_t6_body="$(sed -n '/^_has_preauthored_connect() {/,/^}/p' "$INSTALLER")"
if [ -z "$_t6_body" ]; then
    test_fail "_has_preauthored_connect not found — assertion would be vacuous"
elif printf '%s' "$_t6_body" | grep -qE '(==|=~|\[\[ *"?\$?\{?TEAM_ID)[^=]*(dns|mainevent)'; then
    test_fail "function hardcodes a team id; it must key on file presence only"
elif printf '%s' "$_t6_body" | grep -q 'share/scripts/teams/\${TEAM_ID}-connect.sh'; then
    test_pass
else
    test_fail "function does not test for share/scripts/teams/\${TEAM_ID}-connect.sh"
fi

# ---------------------------------------------------------------------------
# T7 — BRANCH ORDER. The hand-authored branch must be evaluated before the
# parametric and flat template branches, or a team shipping its own scripts
# gets them silently overwritten by a template render.
# ---------------------------------------------------------------------------
start_test "T7 hand-authored branch precedes the parametric branch in _render_connect_disconnect"
_fn_start="$(grep -n '^_render_connect_disconnect() {' "$INSTALLER" | head -1 | cut -d: -f1)"
if [ -z "$_fn_start" ]; then
    test_fail "_render_connect_disconnect not found — assertion would be vacuous"
else
    _pre_off="$(sed -n "${_fn_start},\$p" "$INSTALLER" | grep -n '_has_preauthored_connect' | head -1 | cut -d: -f1)"
    _par_off="$(sed -n "${_fn_start},\$p" "$INSTALLER" | grep -n '_is_parametric_team' | head -1 | cut -d: -f1)"
    if [ -z "$_pre_off" ] || [ -z "$_par_off" ]; then
        test_fail "could not resolve both branch offsets (pre='$_pre_off' par='$_par_off')"
    elif [ "$_pre_off" -lt "$_par_off" ]; then
        test_pass
    else
        test_fail "hand-authored branch at offset $_pre_off does not precede parametric at $_par_off"
    fi
fi

# ---------------------------------------------------------------------------
echo
echo "RESULT: $_PASS_COUNT passed, $_FAIL_COUNT failed"
[ "$_FAIL_COUNT" -eq 0 ] || exit 1
exit 0
