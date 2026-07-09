#!/usr/bin/env bash
# test-xaca-0762-start-port-reconcile-yes.sh
# Regression test for XACA-0762 — aiteamforge-start.sh's auto-reconcile gate
# must pass --yes to kb-port-fix.py --apply.
#
# Bug: check_port_health() in libexec/commands/aiteamforge-start.sh runs
# `"${port_fix_cmd[@]}" --apply` (no --yes) when `--check` first fails.
# kb-port-fix.py's cmd_apply() requires --yes whenever stdin is not a tty
# (see libexec/commands/kb-port-fix.py, ~line 470). aiteamforge start runs
# under lcars-watch, whose stdin is non-interactive by construction — so the
# auto-apply was GUARANTEED to fail every time it was needed, and
# check_port_health() aborted startup instead of self-healing. Net effect
# observed on M4Mini 2026-07-09: ONE team with a null lcars_port in
# ~/.aiteamforge/team-paths.json blocked EVERY team's LCARS server from
# starting, because the self-heal that exists specifically to rescue that
# state was the thing that blocked.
#
# Covers:
#   Case 1 — Behavioral (the actual regression): kb-port-fix.py --apply --yes
#            against a null-port fixture, closed stdin, succeeds and
#            reassigns a concrete in-band port; a subsequent --check passes.
#   Case 2 — Negative control: the same fixture driven with --apply (no
#            --yes) and closed stdin fails and names the --yes remediation.
#            This pins the upstream kb-port-fix.py contract and documents
#            WHY the fix is needed — it is not itself the regression guard.
#   Case 3 — Structural (the regression guard): asserts the --apply call
#            site inside check_port_health() literally carries --yes. This
#            is the assertion that would have caught the original bug —
#            cases 1/2 alone would keep passing even if aiteamforge-start.sh
#            never adopted --yes, because they invoke kb-port-fix.py
#            directly rather than through the start-gate's own resolution
#            logic.
#   Case 4 — End-to-end: check_port_health() itself (extracted from the real
#            aiteamforge-start.sh, not reimplemented) is sourced into a
#            throwaway bash subprocess and invoked directly against a
#            null-port fixture with closed stdin — exercising the exact
#            code path aiteamforge start/restart runs, without launching
#            any real LCARS/Fleet servers.
#
# Sandboxing: all writes go to $TEST_TMP_DIR (a mktemp dir, auto-cleaned).
#             AITEAMFORGE_DIR is exported into $TEST_TMP_DIR before anything
#             that might write. Every kb-port-fix.py invocation is pointed
#             at a fixture via AITEAMFORGE_CONFIG (the real seam it reads:
#             `os.environ.get("AITEAMFORGE_CONFIG", str(DEFAULT_CONFIG_PATH))`).
#             The real ~/.aiteamforge/team-paths.json is never touched; a
#             final guard case asserts it is byte-identical before and after.
# See homebrew-tap/tests/README.md for the test framework convention.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
START_SCRIPT="$TAP_ROOT/libexec/commands/aiteamforge-start.sh"
PORT_FIX_PY="$TAP_ROOT/libexec/commands/kb-port-fix.py"
COMMON_SH="$TAP_ROOT/libexec/lib/common.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: provide minimal stubs when the test-runner has not
# exported the real functions, and manage our own pass/fail counters.
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""

    test_start() { _CURRENT_TEST="$1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); printf "PASS: %s\n" "$_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); printf "FAIL: %s — %s\n" "$_CURRENT_TEST" "$1" >&2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory: use runner-supplied TEST_TMP_DIR or create our own.
# Canonicalise via `pwd -P` (macOS mktemp returns a /var/folders symlink).
# ─────────────────────────────────────────────────────────────────────────────
if [[ -z "${TEST_TMP_DIR:-}" ]] || [[ ! -d "${TEST_TMP_DIR:-}" ]]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0762-start-portfix-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"

_cleanup() {
    if [[ "${_OWN_TMP:-false}" = true ]] && [[ -n "${TEST_TMP_DIR:-}" ]]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap _cleanup EXIT INT TERM

# Hard sandbox: this machine is the dev source of truth (M3Pro rule) — never
# let a wayward code path resolve to the real $HOME/.aiteamforge.
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
mkdir -p "$AITEAMFORGE_DIR"

REAL_CONFIG="$HOME/.aiteamforge/team-paths.json"
_real_config_before=""
if [[ -f "$REAL_CONFIG" ]]; then
    _real_config_before="$(cat "$REAL_CONFIG" 2>/dev/null || true)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Fixture helper — a single team ("academy") with a null lcars_port.
# academy's band is base=8200, range=10 → valid allocations are [8200,8210).
# ─────────────────────────────────────────────────────────────────────────────
new_fixture() {
    local label="$1"
    local path="$TEST_TMP_DIR/team-paths-${label}.json"
    printf '{"schema_version":1,"teams":{"academy":{"team_code":"ACA","lcars_port":null}}}\n' > "$path"
    printf '%s' "$path"
}

# ─────────────────────────────────────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0762 preflight: aiteamforge-start.sh exists"
if [[ -f "$START_SCRIPT" ]]; then
    test_pass
else
    test_fail "not found: $START_SCRIPT"
fi

test_start "XACA-0762 preflight: kb-port-fix.py exists"
if [[ -f "$PORT_FIX_PY" ]]; then
    test_pass
else
    test_fail "not found: $PORT_FIX_PY"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Case 1 — Behavioral: --apply --yes against a null-port fixture, closed
# stdin, succeeds and reassigns a concrete in-band port.
# ─────────────────────────────────────────────────────────────────────────────
_c1_fixture="$(new_fixture "c1")"

test_start "XACA-0762 case-1a: kb-port-fix.py --apply --yes exits 0 on a null-port fixture with closed stdin"
_c1_rc=0
AITEAMFORGE_CONFIG="$_c1_fixture" python3 "$PORT_FIX_PY" --apply --yes \
    >"$TEST_TMP_DIR/c1-apply.out" 2>"$TEST_TMP_DIR/c1-apply.err" < /dev/null || _c1_rc=$?
if [[ "$_c1_rc" -eq 0 ]]; then
    test_pass
else
    test_fail "expected exit 0, got $_c1_rc (see $TEST_TMP_DIR/c1-apply.err)"
fi

test_start "XACA-0762 case-1b: academy's null lcars_port was reassigned to a concrete port in [8200,8210)"
_c1_port="$(jq -r '.teams.academy.lcars_port // empty' "$_c1_fixture" 2>/dev/null)"
if [[ -n "$_c1_port" ]] && [[ "$_c1_port" =~ ^[0-9]+$ ]] && [[ "$_c1_port" -ge 8200 ]] && [[ "$_c1_port" -lt 8210 ]]; then
    test_pass
else
    test_fail "expected academy.lcars_port in [8200,8210), got '${_c1_port:-<empty>}'"
fi

test_start "XACA-0762 case-1c: a subsequent --check now passes"
_c1_check_rc=0
AITEAMFORGE_CONFIG="$_c1_fixture" python3 "$PORT_FIX_PY" --check >/dev/null 2>&1 < /dev/null || _c1_check_rc=$?
if [[ "$_c1_check_rc" -eq 0 ]]; then
    test_pass
else
    test_fail "expected --check exit 0 after reconcile, got $_c1_check_rc"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Case 2 — Negative control: --apply WITHOUT --yes on closed stdin fails and
# names the remediation. Pins the upstream contract that makes --yes
# necessary; documents WHY the fix in aiteamforge-start.sh is required.
# ─────────────────────────────────────────────────────────────────────────────
_c2_fixture="$(new_fixture "c2")"

test_start "XACA-0762 case-2a: kb-port-fix.py --apply (no --yes) exits non-zero on closed stdin"
_c2_rc=0
AITEAMFORGE_CONFIG="$_c2_fixture" python3 "$PORT_FIX_PY" --apply \
    >"$TEST_TMP_DIR/c2-apply.out" 2>"$TEST_TMP_DIR/c2-apply.err" < /dev/null || _c2_rc=$?
if [[ "$_c2_rc" -ne 0 ]]; then
    test_pass
else
    test_fail "expected non-zero exit without --yes under non-interactive stdin, got 0"
fi

test_start "XACA-0762 case-2b: stderr names the --yes remediation"
if grep -qi "Pass --yes" "$TEST_TMP_DIR/c2-apply.err" 2>/dev/null; then
    test_pass
else
    test_fail "stderr did not mention 'Pass --yes'; got: $(head -c 200 "$TEST_TMP_DIR/c2-apply.err" 2>/dev/null)"
fi

test_start "XACA-0762 case-2c: the refused apply left the fixture unmodified (no partial write)"
_c2_port_after="$(jq -r '.teams.academy.lcars_port // "null"' "$_c2_fixture" 2>/dev/null)"
if [[ "$_c2_port_after" = "null" ]]; then
    test_pass
else
    test_fail "expected fixture lcars_port to remain null after a refused apply, got '$_c2_port_after'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Case 3 — Structural (the regression guard): the --apply call site inside
# check_port_health() must literally carry --yes. Extract the function body
# first so this can't false-pass on a --yes mention elsewhere in the file
# (e.g. the print_warning/print_error prose lines, which also say
# "--apply --yes" as human-readable text but are not the invocation).
# ─────────────────────────────────────────────────────────────────────────────
_fn_extract="$TEST_TMP_DIR/check_port_health.extracted.sh"
awk '/^check_port_health\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$START_SCRIPT" > "$_fn_extract"

test_start "XACA-0762 case-3a: check_port_health() function body extracted from aiteamforge-start.sh"
if [[ -s "$_fn_extract" ]] && grep -q '^check_port_health() {' "$_fn_extract" && grep -q '^}$' "$_fn_extract"; then
    test_pass
else
    test_fail "failed to extract a well-formed check_port_health() body from $START_SCRIPT"
fi

test_start "XACA-0762 case-3b (regression anchor): the port_fix_cmd --apply invocation inside check_port_health() carries --yes"
# Robust to inter-token whitespace, anchored to the actual array invocation
# ("${port_fix_cmd[@]}" --apply --yes) rather than a bare substring match.
if grep -Eq '"\$\{port_fix_cmd\[@\]\}"[[:space:]]+--apply[[:space:]]+--yes([[:space:]]|;|$)' "$_fn_extract"; then
    test_pass
else
    test_fail "the port_fix_cmd --apply invocation inside check_port_health() does not carry --yes — this is the exact XACA-0762 regression (a non-interactive lcars-watch stdin makes --apply without --yes fail every time, blocking startup for every team over one team's null port)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Case 4 — End-to-end: source the REAL check_port_health() (extracted above,
# not reimplemented) into a throwaway bash subprocess and invoke it directly
# against a null-port fixture with closed stdin. This exercises the exact
# code path aiteamforge start/restart runs — including the --check /
# --apply --yes / re-check sequence and print_warning/print_error/
# print_success wiring — without launching any real LCARS/Fleet servers or
# touching the real $HOME.
#
# Precondition: this relies on check_port_health()'s own libexec-fallback
# branch (aiteamforge-port-fix not found on PATH -> use SCRIPT_DIR/kb-port-fix.py).
# If a real tap install has put aiteamforge-port-fix on PATH, that assumption
# is invalid (and would itself violate the M3Pro dev-only rule) — skip case 4
# rather than silently exercising the wrong binary.
# ─────────────────────────────────────────────────────────────────────────────
_c4_skip=false
test_start "XACA-0762 case-4 preflight: aiteamforge-port-fix is not shadowed on PATH"
if command -v aiteamforge-port-fix >/dev/null 2>&1; then
    test_fail "aiteamforge-port-fix found on PATH ($(command -v aiteamforge-port-fix)) — this machine appears to have the tap installed, which violates the M3Pro dev-only rule and invalidates case-4's libexec-fallback assumption; skipping case 4"
    _c4_skip=true
else
    test_pass
fi

if [[ "$_c4_skip" != true ]]; then
    _c4_fixture="$(new_fixture "c4")"
    _c4_harness="$TEST_TMP_DIR/check_port_health-harness.sh"
    cat > "$_c4_harness" <<EOF_HARNESS
#!/usr/bin/env bash
set -eo pipefail
SCRIPT_DIR="$TAP_ROOT/libexec/commands"
source "$COMMON_SH"
source "$_fn_extract"
check_port_health
EOF_HARNESS
    chmod +x "$_c4_harness"

    test_start "XACA-0762 case-4a: check_port_health() end-to-end exits 0 against a real null-port fixture, closed stdin"
    _c4_rc=0
    AITEAMFORGE_CONFIG="$_c4_fixture" bash "$_c4_harness" \
        >"$TEST_TMP_DIR/c4.out" 2>"$TEST_TMP_DIR/c4.err" < /dev/null || _c4_rc=$?
    if [[ "$_c4_rc" -eq 0 ]]; then
        test_pass
    else
        test_fail "check_port_health() exited $_c4_rc against a null-port fixture under closed stdin (see $TEST_TMP_DIR/c4.err) — this is the exact XACA-0762 regression: the LCARS start gate blocking on a self-heal that can never succeed under lcars-watch's non-interactive stdin"
    fi

    test_start "XACA-0762 case-4b: check_port_health() end-to-end reassigned the null port"
    _c4_port="$(jq -r '.teams.academy.lcars_port // empty' "$_c4_fixture" 2>/dev/null)"
    if [[ -n "$_c4_port" ]] && [[ "$_c4_port" =~ ^[0-9]+$ ]]; then
        test_pass
    else
        test_fail "expected academy.lcars_port to be reassigned by check_port_health(), got '${_c4_port:-<empty>}'"
    fi
else
    test_start "XACA-0762 case-4a: check_port_health() end-to-end (skipped)"
    test_fail "skipped — case-4 preflight failed (aiteamforge-port-fix shadowed on PATH)"
    test_start "XACA-0762 case-4b: check_port_health() end-to-end port reassignment (skipped)"
    test_fail "skipped — case-4 preflight failed (aiteamforge-port-fix shadowed on PATH)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Sandbox guard: the real ~/.aiteamforge/team-paths.json must never be touched
# by this suite, regardless of which case ran.
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0762 sandbox guard: real ~/.aiteamforge/team-paths.json untouched by this suite"
_real_config_after=""
if [[ -f "$REAL_CONFIG" ]]; then
    _real_config_after="$(cat "$REAL_CONFIG" 2>/dev/null || true)"
fi
if [[ "$_real_config_before" = "$_real_config_after" ]]; then
    test_pass
else
    test_fail "real $REAL_CONFIG changed during this test run — sandboxing leak"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone mode only)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$_STANDALONE" = true ]]; then
    echo ""
    printf "Results: %d passed, %d failed\n" "$_PASS_COUNT" "$_FAIL_COUNT"
    if [[ "$_FAIL_COUNT" -gt 0 ]]; then
        exit 1
    fi
fi
