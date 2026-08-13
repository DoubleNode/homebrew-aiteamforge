#!/bin/bash

# test-xaca-0925-persona-parity-check.sh
#
# Tests for share/scripts/aiteamforge-persona-parity-check.sh — the XACA-0925
# durability guard that DETECTS working-dir-vs-Cellar persona content drift
# (as opposed to update_team_personas() in aiteamforge-upgrade.sh, which
# FIXES it). See that script's header comment for the full design rationale;
# in short, it exists so this drift class is caught on a going-forward basis
# (doctor check / fleet cron — see that file's "SUGGESTED INTEGRATION"
# section) rather than discovered by accident 2 months later, the way the
# parent XACA-0925 defect was.
#
# Both this script and its tests are new in this PR — there is no historical
# "pre-fix" baseline to run a negative control against the way
# test-xaca-0925-persona-refresh.sh does for update_team_personas(). Rigor
# here instead comes from: (a) every test asserting a non-vacuous PRECONDITION
# before invoking the script (proving the scenario is actually set up as
# claimed), and (b) covering both the "clean" and "dirty" outcome for every
# assertion axis (a passing-parity test AND a failing-parity test for the
# same mechanism), so no single assertion could pass by the script being
# permanently a no-op.
#
# Assertions:
#   T1  CLEAN-EXIT-0: identical content across all configured teams -> exit 0, no DRIFT lines.
#   T2  STALE-DETECTED: a content mismatch -> exit 1, DRIFT line naming team + file.
#   T3  MISSING-TEAM-DIR-DETECTED: a configured team with no working-dir persona dir at all -> exit 1, DRIFT line naming the team.
#   T4  ENUMERATION-FROM-CONFIG-NOT-GLOB: a team shipped in the Cellar but NOT in .teams[] is never mentioned in output.
#   T5  MTIME-IMMUNE: content differs but target has a NEWER mtime than the Cellar source -> still detected (content-only comparison).
#   T6  ORPHAN-NOT-FLAGGED: an extra working-dir file with no Cellar counterpart does not, by itself, cause drift.
#   T7  QUIET-SUPPRESSES-OUTPUT: --quiet produces no stdout even when drift exists, but the exit code still reflects it.
#   T8  MULTI-TEAM-ANY-DRIFT-EXITS-1: one clean team + one dirty team among several configured -> exit 1 overall.
#
# ROUND-3 ADDITIONS (T9-T11, XACA-0925-021 — the highest-priority of the 4
# round-3 findings): get_configured_teams() (lib/config.sh) swallows jq's
# own exit status via `2>/dev/null` and reports the PIPELINE's exit status
# (always `tr`'s, never jq's), so an unreadable OR malformed
# .aiteamforge-config comes back indistinguishable from a legitimately empty
# one — "no teams to check", exit 0, silent even under --quiet. That is a
# fail-OPEN masquerade inside the durability guard this ticket built to
# catch exactly this defect class.
#   T9  CONFIG-UNREADABLE-FAILS-CLOSED-EVEN-UNDER-QUIET: chmod 000 on an
#       otherwise-valid .aiteamforge-config -> non-zero exit AND a non-empty
#       diagnostic even with --quiet passed.
#   T10 CONFIG-MALFORMED-JSON-FAILS-CLOSED: syntactically invalid JSON ->
#       non-zero exit and a diagnostic (jq's own failure checked explicitly,
#       never inferred from tr's exit status).
#   T11 CONFIG-VALID-ZERO-TEAMS-STILL-EXITS-0-QUIETLY: a well-formed config
#       with "teams": [] is the LEGITIMATE empty case and must not regress
#       into a false alarm -> exit 0, no output under --quiet.
#
# All filesystem activity is sandboxed under TEST_TMP_DIR, including a
# synthetic FRAMEWORK_DIR/WORKING_DIR pair per test and .aiteamforge-config.
# NEVER touches the real $HOME/aiteamforge or the real share/personas/ tree —
# installer-test safety rule.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARITY_SH="$TAP_ROOT/share/scripts/aiteamforge-persona-parity-check.sh"

if [ ! -f "$PARITY_SH" ]; then
    echo "FATAL: required file not found: $PARITY_SH" >&2
    exit 1
fi
if [ ! -x "$PARITY_SH" ]; then
    echo "FATAL: $PARITY_SH is not executable (exec bit missing)" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (works sourced by test-runner.sh OR invoked directly).
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory (runner-supplied or our own).
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0925-parity-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

WORK_DIR="$TEST_TMP_DIR/xaca0925-parity"
mkdir -p "$WORK_DIR"

_next_sandbox() { mktemp -d "$WORK_DIR/sbx-XXXXXX"; }

_seed_framework_team() {
    local fw="$1" team="$2"; shift 2
    mkdir -p "${fw}/share/personas/${team}/agents"
    while [ $# -ge 2 ]; do
        printf '%s\n' "$2" > "${fw}/share/personas/${team}/agents/$1"
        shift 2
    done
}

_seed_config() {
    local wd="$1"; shift
    local teams_json=""
    local t
    for t in "$@"; do
        [ -n "$teams_json" ] && teams_json="${teams_json}, "
        teams_json="${teams_json}\"${t}\""
    done
    printf '{\n  "schema_version": 1,\n  "teams": [%s]\n}\n' "$teams_json" > "${wd}/.aiteamforge-config"
}

_run_parity() {
    local fw="$1" wd="$2"; shift 2
    "$PARITY_SH" --working-dir "$wd" --framework-dir "$fw" "$@"
}

# ═══════════════════════════════════════════════════════════════════════════
# T1 — CLEAN-EXIT-0
# ═══════════════════════════════════════════════════════════════════════════
test_start "T1: identical working-dir/Cellar content across all configured teams -> exit 0, no DRIFT lines"
T1_FW="$(_next_sandbox)"; T1_WD="$(_next_sandbox)"
_seed_framework_team "$T1_FW" academy a.md "CONTENT-A"
_seed_config "$T1_WD" academy
mkdir -p "$T1_WD/academy/personas/agents"
printf 'CONTENT-A\n' > "$T1_WD/academy/personas/agents/a.md"

if ! cmp -s "$T1_WD/academy/personas/agents/a.md" "$T1_FW/share/personas/academy/agents/a.md"; then
    test_fail "PRECONDITION FAILED: fixture content does not actually match — test would be vacuous"
else
    _out="$(_run_parity "$T1_FW" "$T1_WD" 2>&1)"; _rc=$?
    if [ "$_rc" = "0" ] && ! echo "$_out" | grep -q "DRIFT"; then
        test_pass
    else
        test_fail "expected exit 0 and no DRIFT lines; rc=$_rc; output: $_out"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T2 — STALE-DETECTED
# ═══════════════════════════════════════════════════════════════════════════
test_start "T2: a content mismatch is detected -> exit 1, DRIFT line names team + file"
T2_FW="$(_next_sandbox)"; T2_WD="$(_next_sandbox)"
_seed_framework_team "$T2_FW" academy a.md "CELLAR-CONTENT-A-v2"
_seed_config "$T2_WD" academy
mkdir -p "$T2_WD/academy/personas/agents"
printf 'OLD-STALE-CONTENT-A\n' > "$T2_WD/academy/personas/agents/a.md"

if cmp -s "$T2_WD/academy/personas/agents/a.md" "$T2_FW/share/personas/academy/agents/a.md"; then
    test_fail "PRECONDITION FAILED: fixture content already matches — test would be vacuous"
else
    _out="$(_run_parity "$T2_FW" "$T2_WD" 2>&1)"; _rc=$?
    if [ "$_rc" = "1" ] && echo "$_out" | grep -q "DRIFT \[academy\]" && echo "$_out" | grep -q "a.md"; then
        test_pass
    else
        test_fail "expected exit 1 and a DRIFT line naming academy + a.md; rc=$_rc; output: $_out"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T3 — MISSING-TEAM-DIR-DETECTED
# ═══════════════════════════════════════════════════════════════════════════
test_start "T3: a configured team with no working-dir persona dir at all -> exit 1, DRIFT line names the team"
T3_FW="$(_next_sandbox)"; T3_WD="$(_next_sandbox)"
_seed_framework_team "$T3_FW" dns d.md "CELLAR-CONTENT-D"
_seed_config "$T3_WD" dns
# T3_WD/dns deliberately does not exist (dns/mainevent real-world shape).

if [ -e "$T3_WD/dns" ]; then
    test_fail "PRECONDITION FAILED: dns dir unexpectedly exists — test would be vacuous"
else
    _out="$(_run_parity "$T3_FW" "$T3_WD" 2>&1)"; _rc=$?
    if [ "$_rc" = "1" ] && echo "$_out" | grep -q "DRIFT \[dns\]"; then
        test_pass
    else
        test_fail "expected exit 1 and a DRIFT line naming dns's missing directory; rc=$_rc; output: $_out"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T4 — ENUMERATION-FROM-CONFIG-NOT-GLOB
# ═══════════════════════════════════════════════════════════════════════════
test_start "T4: a team shipped in the Cellar but ABSENT from .teams[] is never mentioned in output"
T4_FW="$(_next_sandbox)"; T4_WD="$(_next_sandbox)"
_seed_framework_team "$T4_FW" academy a.md "CONTENT-A"
_seed_framework_team "$T4_FW" ghostteam g.md "CONTENT-G"
_seed_config "$T4_WD" academy   # ghostteam deliberately NOT listed
mkdir -p "$T4_WD/academy/personas/agents"
printf 'CONTENT-A\n' > "$T4_WD/academy/personas/agents/a.md"
# ghostteam has no working-dir dir either — if enumeration were a glob of
# share/personas/*/ instead of .teams[], this would surface as a DRIFT line.

_out="$(_run_parity "$T4_FW" "$T4_WD" 2>&1)"; _rc=$?
if [ "$_rc" = "0" ] && ! echo "$_out" | grep -qi "ghostteam"; then
    test_pass
else
    test_fail "ghostteam was flagged even though it is not in .teams[] — enumeration appears to glob share/personas/*/; rc=$_rc; output: $_out"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T5 — MTIME-IMMUNE
# ═══════════════════════════════════════════════════════════════════════════
test_start "T5: content differs but target has a NEWER mtime than the Cellar source -> still detected (content-only comparison)"
T5_FW="$(_next_sandbox)"; T5_WD="$(_next_sandbox)"
_seed_framework_team "$T5_FW" academy a.md "CELLAR-CONTENT-A-v3"
touch -t 202001010000 "$T5_FW/share/personas/academy/agents/a.md"
_seed_config "$T5_WD" academy
mkdir -p "$T5_WD/academy/personas/agents"
printf 'OLD-STALE-CONTENT-A\n' > "$T5_WD/academy/personas/agents/a.md"
touch "$T5_WD/academy/personas/agents/a.md"   # "now" — deliberately newer than the Cellar file

if [ ! "$T5_WD/academy/personas/agents/a.md" -nt "$T5_FW/share/personas/academy/agents/a.md" ]; then
    test_fail "PRECONDITION FAILED: target is not actually newer than source by mtime — scenario not set up"
elif cmp -s "$T5_WD/academy/personas/agents/a.md" "$T5_FW/share/personas/academy/agents/a.md"; then
    test_fail "PRECONDITION FAILED: content already matches — test would be vacuous"
else
    _out="$(_run_parity "$T5_FW" "$T5_WD" 2>&1)"; _rc=$?
    if [ "$_rc" = "1" ] && echo "$_out" | grep -q "DRIFT \[academy\]"; then
        test_pass
    else
        test_fail "a NEWER-mtime-but-stale-content file was not flagged — comparison appears mtime-gated, not content-gated; rc=$_rc; output: $_out"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T6 — ORPHAN-NOT-FLAGGED
# ═══════════════════════════════════════════════════════════════════════════
test_start "T6: an extra working-dir file with no Cellar counterpart does not, by itself, cause drift"
T6_FW="$(_next_sandbox)"; T6_WD="$(_next_sandbox)"
_seed_framework_team "$T6_FW" academy a.md "CONTENT-A"
_seed_config "$T6_WD" academy
mkdir -p "$T6_WD/academy/personas/agents"
printf 'CONTENT-A\n' > "$T6_WD/academy/personas/agents/a.md"
printf 'LOCAL-ONLY-NOTES\n' > "$T6_WD/academy/personas/agents/orphan.md"

if [ ! -f "$T6_WD/academy/personas/agents/orphan.md" ]; then
    test_fail "PRECONDITION FAILED: orphan fixture not seeded"
else
    _out="$(_run_parity "$T6_FW" "$T6_WD" 2>&1)"; _rc=$?
    if [ "$_rc" = "0" ] && ! echo "$_out" | grep -q "DRIFT"; then
        test_pass
    else
        test_fail "an orphan-only working dir (all Cellar-tracked files matching) should exit 0 with no DRIFT; rc=$_rc; output: $_out"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T7 — QUIET-SUPPRESSES-OUTPUT
# ═══════════════════════════════════════════════════════════════════════════
test_start "T7: --quiet produces no stdout even when drift exists, but the exit code still reflects it"
T7_FW="$(_next_sandbox)"; T7_WD="$(_next_sandbox)"
_seed_framework_team "$T7_FW" academy a.md "CELLAR-CONTENT-A-v2"
_seed_config "$T7_WD" academy
mkdir -p "$T7_WD/academy/personas/agents"
printf 'OLD-STALE-CONTENT-A\n' > "$T7_WD/academy/personas/agents/a.md"

if cmp -s "$T7_WD/academy/personas/agents/a.md" "$T7_FW/share/personas/academy/agents/a.md"; then
    test_fail "PRECONDITION FAILED: fixture content already matches — test would be vacuous"
else
    _out="$(_run_parity "$T7_FW" "$T7_WD" --quiet 2>&1)"; _rc=$?
    if [ "$_rc" = "1" ] && [ -z "$_out" ]; then
        test_pass
    else
        test_fail "expected exit 1 and empty stdout/stderr under --quiet; rc=$_rc; output: '$_out'"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T8 — MULTI-TEAM-ANY-DRIFT-EXITS-1
# ═══════════════════════════════════════════════════════════════════════════
test_start "T8: one clean team + one dirty team among several configured -> overall exit 1, only the dirty team flagged"
T8_FW="$(_next_sandbox)"; T8_WD="$(_next_sandbox)"
_seed_framework_team "$T8_FW" academy a.md "CONTENT-A-CLEAN"
_seed_framework_team "$T8_FW" ios i.md "CONTENT-I-STALE-TARGET"
_seed_config "$T8_WD" academy ios
mkdir -p "$T8_WD/academy/personas/agents" "$T8_WD/ios/personas/agents"
printf 'CONTENT-A-CLEAN\n' > "$T8_WD/academy/personas/agents/a.md"
printf 'OLD-STALE-CONTENT-I\n' > "$T8_WD/ios/personas/agents/i.md"

if cmp -s "$T8_WD/ios/personas/agents/i.md" "$T8_FW/share/personas/ios/agents/i.md"; then
    test_fail "PRECONDITION FAILED: ios fixture content already matches — test would be vacuous"
else
    _out="$(_run_parity "$T8_FW" "$T8_WD" 2>&1)"; _rc=$?
    if [ "$_rc" = "1" ] && echo "$_out" | grep -q "DRIFT \[ios\]" && ! echo "$_out" | grep -q "DRIFT \[academy\]"; then
        test_pass
    else
        test_fail "expected exit 1 with ios flagged and academy NOT flagged; rc=$_rc; output: $_out"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T9 — CONFIG-UNREADABLE-FAILS-CLOSED-EVEN-UNDER-QUIET (XACA-0925-021)
# ═══════════════════════════════════════════════════════════════════════════
test_start "T9: an unreadable .aiteamforge-config exits non-zero and prints a diagnostic EVEN under --quiet"
T9_FW="$(_next_sandbox)"; T9_WD="$(_next_sandbox)"
_seed_framework_team "$T9_FW" academy a.md "CONTENT-A"
_seed_config "$T9_WD" academy
chmod 000 "$T9_WD/.aiteamforge-config"

if [ -r "$T9_WD/.aiteamforge-config" ]; then
    chmod 644 "$T9_WD/.aiteamforge-config" 2>/dev/null || true
    test_fail "PRECONDITION FAILED: could not make .aiteamforge-config unreadable — test would be vacuous (running as root?)"
else
    _out="$(_run_parity "$T9_FW" "$T9_WD" --quiet 2>&1)"; _rc=$?
    chmod 644 "$T9_WD/.aiteamforge-config" 2>/dev/null || true
    if [ "$_rc" != "0" ] && [ -n "$_out" ]; then
        test_pass
    else
        test_fail "expected non-zero exit AND a non-empty diagnostic even under --quiet (an unreadable config must never read as 'nothing to check'); rc=$_rc; output: '$_out'"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T10 — CONFIG-MALFORMED-JSON-FAILS-CLOSED (XACA-0925-021)
# ═══════════════════════════════════════════════════════════════════════════
test_start "T10: a syntactically invalid .aiteamforge-config exits non-zero with a diagnostic, never silently 'nothing to check'"
T10_FW="$(_next_sandbox)"; T10_WD="$(_next_sandbox)"
_seed_framework_team "$T10_FW" academy a.md "CONTENT-A"
mkdir -p "$T10_WD"
printf '{ this is not valid json,,, ' > "$T10_WD/.aiteamforge-config"

if command -v jq >/dev/null 2>&1 && jq empty "$T10_WD/.aiteamforge-config" >/dev/null 2>&1; then
    test_fail "PRECONDITION FAILED: fixture .aiteamforge-config unexpectedly parses as valid JSON — test would be vacuous"
else
    _out="$(_run_parity "$T10_FW" "$T10_WD" 2>&1)"; _rc=$?
    if [ "$_rc" != "0" ] && [ -n "$_out" ]; then
        test_pass
    else
        test_fail "expected non-zero exit and a diagnostic for malformed .aiteamforge-config (jq's parse failure must be checked explicitly, not inferred from tr's exit status); rc=$_rc; output: '$_out'"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T11 — CONFIG-VALID-ZERO-TEAMS-STILL-EXITS-0-QUIETLY (XACA-0925-021 regression guard)
# ═══════════════════════════════════════════════════════════════════════════
test_start "T11: a well-formed config with zero configured teams is the LEGITIMATE empty case -> exit 0, no output under --quiet"
T11_FW="$(_next_sandbox)"; T11_WD="$(_next_sandbox)"
_seed_framework_team "$T11_FW" academy a.md "CONTENT-A"
_seed_config "$T11_WD"   # no team args -> "teams": []

if [ ! -f "$T11_WD/.aiteamforge-config" ] || ! grep -q '"teams": \[\]' "$T11_WD/.aiteamforge-config"; then
    test_fail "PRECONDITION FAILED: expected a valid config fixture with an empty teams array; got: $(cat "$T11_WD/.aiteamforge-config" 2>/dev/null || echo '<missing>')"
else
    _out="$(_run_parity "$T11_FW" "$T11_WD" --quiet 2>&1)"; _rc=$?
    if [ "$_rc" = "0" ] && [ -z "$_out" ]; then
        test_pass
    else
        test_fail "expected exit 0 and empty output for a valid config with zero configured teams (must not regress into a false alarm); rc=$_rc; output: '$_out'"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone only).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
fi
exit 0
