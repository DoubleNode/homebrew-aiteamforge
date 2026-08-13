#!/bin/bash
# test-xaca-0862-028-resolve-parametric-crash-guard.sh
#
# XACA-0862-028 (PROTECTED [Test] gate).
#
# Regression test for the crash fixed in commit f5409979:
# _resolve_parametric_defaults() TIER 2's candidate-filter loop in
# install-team.sh used `[[ cond ]] && printf` as the LAST statement of its
# `while read` loop body. install-team.sh runs under `set -euo pipefail` at
# file scope. When the (sole) candidate on the loop's final iteration is
# REJECTED — i.e. exactly the stale/never-completed registry entry the
# XACA-0862-023 filesystem-proof gate exists to filter out gracefully — that
# `&&` expression returns 1. Bash propagates that as the `while` loop's own
# exit status, then as the exit status of the `matches="$( ... )"` command
# substitution/assignment, which aborts the whole script under `set -e` —
# precisely on the input this gate was built to handle gracefully instead.
# Fixed by replacing the bare `&&` with an explicit if/fi (only `&&`/`||`
# short-circuit propagate a nonzero status as a "command failed" signal to
# set -e in this way; `if` does not).
#
# EXTRACTION TECHNIQUE: same recipe as test-xaca-0862-022-runtime-resolver.sh
# — awk-extract _resolve_parametric_defaults() verbatim (byte for byte) from
# the real, on-disk install-team.sh, not a hand copy, then drive it inside a
# subshell with `set -euo pipefail` EXPLICITLY re-applied. Extraction alone
# loses the file-scope `set -euo pipefail` install-team.sh normally runs
# under, and the bug this test guards only reproduces in that strict-mode
# context — omitting it would make this suite pass vacuously.
#
# This suite is written to FAIL (crash / non-zero exit, no PROJECT=/
# MATCH_COUNT= output) against the pre-f5409979 (bare `&&`) version of the
# function, and PASS only with the if/fi fix in place. Verified by manual
# mutation during development (reverted to bare `&&` in a scratch copy: R1
# and R2 failed with a hard abort; restored: both pass) — see PR #744 /
# kanban XACA-0862-028.
#
# Runs standalone (`bash tests/test-xaca-0862-028-resolve-parametric-crash-guard.sh`)
# OR via test-runner.sh. Exit 0 = all pass, exit 1 = any fail.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_TEAM_SH="$TAP_ROOT/libexec/installers/install-team.sh"

if [ ! -f "$INSTALL_TEAM_SH" ]; then
    echo "FATAL: required file not found: $INSTALL_TEAM_SH" >&2
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
# Temp directory (runner-supplied or our own). Never touches real $HOME.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0862028-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true; fi; }
trap cleanup EXIT

WORK_DIR="$TEST_TMP_DIR/xaca0862028"
mkdir -p "$WORK_DIR"
_next_sandbox() { mktemp -d "$WORK_DIR/sbx-XXXXXX"; }

# ─────────────────────────────────────────────────────────────────────────────
# Extraction: pull _resolve_parametric_defaults() verbatim out of the real
# install-team.sh (same awk recipe as check-resolve-cochange-guard.sh's
# _extract_body / test-xaca-0862-022's _extract_fn).
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn() {
    # $1 = source file, $2 = function name
    awk -v fn="$2" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$1"
}

FN_SRC="$WORK_DIR/resolve_parametric_defaults.extracted.sh"
_extract_fn "$INSTALL_TEAM_SH" "_resolve_parametric_defaults" > "$FN_SRC"
if [ ! -s "$FN_SRC" ]; then
    echo "FATAL: could not extract _resolve_parametric_defaults from $INSTALL_TEAM_SH" >&2
    exit 1
fi
# Fixture sanity: extracted body must be non-trivial (currently ~75 lines),
# or every case below would be exercising an empty function.
FN_LINES=$(wc -l < "$FN_SRC" | tr -d ' ')
if [ "$FN_LINES" -lt 30 ]; then
    echo "FATAL: extracted function body suspiciously small ($FN_LINES lines) — extraction broken, refusing to run a vacuous suite." >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Registry-writing helper (same shape as test-xaca-0862-022's _write_registry).
#   "<instance_id>::<working_dir>::<kanban_dir>" -> full entry
#   "<instance_id>"                              -> {} entry (no dirs)
# ─────────────────────────────────────────────────────────────────────────────
_write_registry() {
    local out="$1"; shift
    mkdir -p "$(dirname "$out")"
    if [ "$#" -eq 0 ]; then
        printf '{"teams": {}}\n' > "$out"
        return 0
    fi
    python3 - "$out" "$@" <<'PYEOF'
import json, sys
out = sys.argv[1]
specs = sys.argv[2:]
teams = {}
for spec in specs:
    if "::" in spec:
        parts = spec.split("::")
        instance_id = parts[0]
        working_dir = parts[1] if len(parts) > 1 else ""
        kanban_dir = parts[2] if len(parts) > 2 else ""
        entry = {}
        if working_dir:
            entry["working_dir"] = working_dir
        if kanban_dir:
            entry["kanban_dir"] = kanban_dir
        teams[instance_id] = entry
    else:
        teams[spec] = {}
data = {"teams": teams}
with open(out, "w") as f:
    json.dump(data, f)
PYEOF
}

# Drive the extracted resolver inside a subshell that REPRODUCES
# install-team.sh's own file-scope `set -euo pipefail` — the strict-mode
# context the real bug only reproduces under. On a crash the subshell aborts
# before any PROJECT=/GROUP=/MATCH_COUNT= line prints, so a non-empty,
# well-formed capture IS the "did not crash" assertion.
# $1=fn source file $2=registry $3=team_id $4=has_group
_run_resolver_strict() {
    local fn_src="$1" registry="$2" team_id="$3" has_group="$4"
    (
        set -euo pipefail
        # shellcheck disable=SC1090
        source "$fn_src"
        REFRESH_SWEEP="false"
        ARG_PROJECT=""
        ARG_CLIENT=""
        RESOLVED_PROJECT=""
        RESOLVED_CLIENT=""
        AITEAMFORGE_CONFIG="$registry" _resolve_parametric_defaults "$team_id" "$has_group"
        printf 'PROJECT=%s\n' "$_DERIVED_DEFAULT_PROJECT"
        printf 'GROUP=%s\n' "$_DERIVED_DEFAULT_GROUP"
        printf 'MATCH_COUNT=%s\n' "$_DERIVED_MATCH_COUNT"
    )
}

# ═══════════════════════════════════════════════════════════════════════════
# R1 [CRASH REGRESSION]: exactly one STALE registry entry (key matches the
# team's naming pattern, but neither working_dir nor kanban_dir exists on
# disk) must yield 0 matches and exit 0 — never abort the calling script.
# This is the exact XACA-0862 crash case: a lone rejected candidate is the
# loop's LAST (and only) iteration, so its failing `&&` status becomes the
# whole loop's exit status.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R1 [CRASH REGRESSION]: one stale entry (working_dir+kanban_dir both missing) -> 0 matches, rc=0, no crash"
R1_SBX="$(_next_sandbox)"
R1_REG="$R1_SBX/team-paths.json"
_write_registry "$R1_REG" "finance-ghost::$R1_SBX/does-not-exist/personal::$R1_SBX/does-not-exist/personal/kanban"
R1_OUT="$(_run_resolver_strict "$FN_SRC" "$R1_REG" "finance" "false")"; R1_RC=$?
if [ "$R1_RC" -eq 0 ] && printf '%s\n' "$R1_OUT" | grep -qx "PROJECT=" && printf '%s\n' "$R1_OUT" | grep -qx "MATCH_COUNT=0"; then
    test_pass
else
    test_fail "expected rc=0, PROJECT= empty, MATCH_COUNT=0 (no crash); got rc=$R1_RC output=[$R1_OUT]"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R2 [CRASH REGRESSION, other half of the gate]: working_dir exists but
# kanban_dir does not — same crash class, the other AND-branch rejecting.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R2 [CRASH REGRESSION]: one stale entry (working_dir exists, kanban_dir missing) -> 0 matches, rc=0, no crash"
R2_SBX="$(_next_sandbox)"
R2_REG="$R2_SBX/team-paths.json"
R2_WD="$R2_SBX/finance/ghost"; mkdir -p "$R2_WD"
_write_registry "$R2_REG" "finance-ghost::$R2_WD::$R2_WD/does-not-exist-kanban"
R2_OUT="$(_run_resolver_strict "$FN_SRC" "$R2_REG" "finance" "false")"; R2_RC=$?
if [ "$R2_RC" -eq 0 ] && printf '%s\n' "$R2_OUT" | grep -qx "MATCH_COUNT=0"; then
    test_pass
else
    test_fail "expected rc=0, MATCH_COUNT=0 (no crash); got rc=$R2_RC output=[$R2_OUT]"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R3 [POSITIVE CONTROL]: one LIVE entry (both dirs real) still resolves
# correctly — proves R1/R2 pass because the crash is fixed, not because the
# function stopped matching real entries altogether.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R3 [CONTROL]: one LIVE entry still resolves normally"
R3_SBX="$(_next_sandbox)"
R3_REG="$R3_SBX/team-paths.json"
R3_WD="$R3_SBX/finance/personal"; R3_KD="$R3_WD/kanban"; mkdir -p "$R3_KD"
_write_registry "$R3_REG" "finance-personal::$R3_WD::$R3_KD"
R3_OUT="$(_run_resolver_strict "$FN_SRC" "$R3_REG" "finance" "false")"; R3_RC=$?
if [ "$R3_RC" -eq 0 ] && printf '%s\n' "$R3_OUT" | grep -qx "PROJECT=personal" && printf '%s\n' "$R3_OUT" | grep -qx "MATCH_COUNT=1"; then
    test_pass
else
    test_fail "expected rc=0, PROJECT=personal, MATCH_COUNT=1; got rc=$R3_RC output=[$R3_OUT]"
fi

# ═══════════════════════════════════════════════════════════════════════════
# R4 [MIXED, NEGATIVE CONTROL]: one stale entry AND one live entry, stale
# key sorting AFTER the live one in jq's to_entries traversal (insertion
# order — the stale key is inserted second). Confirms the loop's final
# iteration being a REJECT does not, post-fix, hide or corrupt an
# already-accepted match earlier in the same run.
# ═══════════════════════════════════════════════════════════════════════════
test_start "R4 [MIXED]: live entry first, stale entry last (loop's final iteration rejects) -> still resolves the live one, rc=0"
R4_SBX="$(_next_sandbox)"
R4_REG="$R4_SBX/team-paths.json"
R4_WD="$R4_SBX/finance/personal"; R4_KD="$R4_WD/kanban"; mkdir -p "$R4_KD"
_write_registry "$R4_REG" "finance-personal::$R4_WD::$R4_KD" "finance-ghost::$R4_SBX/does-not-exist::$R4_SBX/does-not-exist/kanban"
R4_OUT="$(_run_resolver_strict "$FN_SRC" "$R4_REG" "finance" "false")"; R4_RC=$?
if [ "$R4_RC" -eq 0 ] && printf '%s\n' "$R4_OUT" | grep -qx "PROJECT=personal" && printf '%s\n' "$R4_OUT" | grep -qx "MATCH_COUNT=1"; then
    test_pass
else
    test_fail "expected rc=0, PROJECT=personal, MATCH_COUNT=1 (stale entry filtered, live entry preserved); got rc=$R4_RC output=[$R4_OUT]"
fi

echo ""
if [ "$_STANDALONE" = true ]; then
    echo "XACA-0862-028 resolve-parametric-defaults crash-guard tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    if [ "$_FAIL_COUNT" -eq 0 ]; then
        exit 0
    else
        exit 1
    fi
fi
