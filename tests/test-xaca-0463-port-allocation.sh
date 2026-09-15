#!/usr/bin/env bash
# test-xaca-0463-port-allocation.sh
# Tap-side integration test for XACA-0463 per-instance LCARS port allocation.
#
# Verifies that install-team.sh calls aiteamforge_compute_instance_port for
# new instances, persists the result to team-paths.json, and that the two
# instances of the same template receive distinct in-band ports.
#
# Covers:
#   Case 1 — Two finance instances get distinct, adjacent in-band ports
#   Case 2 — Freelance band size honoured (8500, 8501)
#   Case 3 — team-paths.json correctly records the per-instance port
#             (parametric teams use template-keyed startup scripts; the
#             per-instance port is stored in team-paths.json, NOT substituted
#             into a script file.  This case validates that JSON record.)
#   Case 4 — Unknown template fails loud (non-zero exit, meaningful error)
#   Case 5 — Band exhaustion fails loud (non-zero exit, "exhausted" in stderr)
#
# Sandboxing: all writes go to $TEST_TMP_DIR (a mktemp dir, auto-cleaned).
#             The real $HOME and ~/.aiteamforge are never touched.
# See homebrew-tap/tests/README.md for the test framework convention.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_TEAM="$TAP_ROOT/libexec/installers/install-team.sh"
ORG_EXAMPLE="$TAP_ROOT/share/config/organization.yaml.example"

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
#
# On macOS, mktemp returns paths under /var/folders (a symlink to
# /private/var/folders).  Canonicalise via `pwd -P` so that $HOME-relative
# comparisons inside install-team.sh agree with the $HOME we pass in.
# ─────────────────────────────────────────────────────────────────────────────
if [[ -z "${TEST_TMP_DIR:-}" ]] || [[ ! -d "${TEST_TMP_DIR:-}" ]]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0463-alloc-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi

# Resolve symlinks so guard comparisons inside install-team.sh are consistent.
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"

_cleanup() {
    if [[ "${_OWN_TMP:-false}" = true ]] && [[ -n "${TEST_TMP_DIR:-}" ]]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap _cleanup EXIT INT TERM

# ─────────────────────────────────────────────────────────────────────────────
# XACA-1222: stub `brew` so run_install() can never reach the network or
# mutate the host.
#
# install-team.sh's dependency step (libexec/installers/install-team.sh
# ~1910-1938) runs `brew list [--cask] $dep` then, on a miss, `brew install
# [--cask] $dep` for every entry in TEAM_BREW_DEPS / TEAM_BREW_CASK_DEPS.
# freelance.conf (exercised by Case 2 below) lists real deps including the
# `android-studio` cask — a real `brew install --cask android-studio` is a
# multi-hundred-MB network fetch that would hang this runner and install
# real software on the host. finance/legal (Cases 1/3/5) ship empty
# TEAM_BREW_DEPS/CASK_DEPS arrays, so only Case 2 actually exercises the
# install path today — but the stub is wired into every run_install() call
# (not just Case 2's) so a future conf change can't silently reintroduce a
# real brew invocation here.
#
# Pattern lifted from tests/test-xaca-1216-flat-persona-deploy.sh's brew
# stub (`brew list` reports "installed", everything else refuses loudly),
# extended with: full-argv logging (so the "nothing mutating happened"
# claim is verified, not assumed — see the assertion after Case 2 and the
# suite-wide one near the end), and an explicit mutating-subcommand refusal
# list rather than a single install|else split.
# ─────────────────────────────────────────────────────────────────────────────
STUB_BIN="$TEST_TMP_DIR/stub-bin"
mkdir -p "$STUB_BIN"
BREW_STUB_LOG="$TEST_TMP_DIR/brew-stub.log"
: > "$BREW_STUB_LOG"

cat > "$STUB_BIN/brew" <<'BREWSTUBEOF'
#!/bin/sh
# XACA-1222 test stub for test-xaca-0463-port-allocation.sh.
# Logs every invocation (full argv) to $_BREW_STUB_LOG, then:
#   - `brew list ...`    → exit 0 ("already installed"), so install-team.sh
#                           takes its already-installed branch and never
#                           calls `brew install` for a dep that happens to
#                           already be on the runner (real or otherwise).
#   - `brew --prefix`    → not currently called by install-team.sh (grepped
#                           for XACA-1222), but handled defensively: prints a
#                           nonexistent path, never a real host prefix.
#   - anything mutating/network (install/upgrade/tap/untap/reinstall/
#     uninstall/update/services) → refuse loudly, non-zero exit.
#   - anything else       → refuse loudly too (fail closed on the unknown).
{
    printf '%s' "brew"
    for _a in "$@"; do printf ' %s' "$_a"; done
    printf '\n'
} >> "${_BREW_STUB_LOG:-/dev/null}"

case "$1" in
    list)
        exit 0
        ;;
    --prefix)
        printf '%s\n' "/nonexistent-xaca-1222-brew-prefix"
        exit 0
        ;;
    install|upgrade|tap|untap|reinstall|uninstall|update|services)
        echo "brew stub: refusing mutating/network subcommand '$*' inside XACA-0463 port-allocation sandbox (XACA-1222)" >&2
        exit 1
        ;;
    *)
        echo "brew stub: refusing unrecognised subcommand '$*' inside XACA-0463 port-allocation sandbox (XACA-1222)" >&2
        exit 1
        ;;
esac
BREWSTUBEOF
chmod +x "$STUB_BIN/brew"

# find_brew_violations <logfile> — mutating/network brew subcommands present
# in a stub log. Anchored on line-start "brew <subcommand>" so it cannot
# false-match a dep NAMED "install" etc. appearing as an argument.
find_brew_violations() {
    grep -E '^brew (install|upgrade|tap|untap|reinstall|uninstall|update|services)\b' "$1" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Sandbox helpers
# ─────────────────────────────────────────────────────────────────────────────

# new_sandbox <case-label>
# Creates an isolated directory with a blank team-paths.json and a pre-populated
# organization.yaml so the installer does not prompt interactively.
# Sets global vars: _SB (sandbox root), _SB_HOME, _SB_AITF, _SB_CONFIG.
# All install-team.sh invocations in a case must use these vars.
new_sandbox() {
    local label="$1"
    _SB="$TEST_TMP_DIR/case-${label}"
    _SB_HOME="$_SB/home"
    _SB_AITF="$_SB/aiteamforge"
    _SB_CONFIG="$_SB/team-paths.json"

    mkdir -p "$_SB_HOME/.aiteamforge" "$_SB_AITF"

    # Provide a pre-populated organization.yaml so _ensure_org_config skips
    # its interactive prompt.  Copy the shipped example (it has slug: example-org
    # which is treated as "not configured" by the resolver — safe for tests).
    cp "$ORG_EXAMPLE" "$_SB_HOME/.aiteamforge/organization.yaml"

    # Empty team-paths.json (schema v1).
    printf '{"schema_version":1,"teams":{}}\n' > "$_SB_CONFIG"
}

# run_install <case-label> <team> [extra-args...]
# Runs install-team.sh under the current sandbox, logging stdout/stderr to
# _SB/install-<label>.{out,err}.  Returns the exit code.
# Must be called AFTER new_sandbox.
run_install() {
    local label="$1"; shift
    local team="$1";  shift
    local out_file="$_SB/install-${label}.out"
    local err_file="$_SB/install-${label}.err"
    local rc=0

    # XACA-1222: PATH-prepend the brew stub so install-team.sh's dependency
    # step (real for freelance, see Case 2) can never reach the network or
    # mutate the host. _BREW_STUB_LOG is the suite-wide log; every case's
    # brew invocations accumulate into it for the assertions below.
    HOME="$_SB_HOME" \
    AITEAMFORGE_DIR="$_SB_AITF" \
    AITEAMFORGE_CONFIG="$_SB_CONFIG" \
    PATH="$STUB_BIN:$PATH" \
    _BREW_STUB_LOG="$BREW_STUB_LOG" \
        bash "$INSTALL_TEAM" "$team" "$@" \
        >"$out_file" 2>"$err_file" || rc=$?

    # Surface stderr on failure so test output is self-contained.
    if [[ $rc -ne 0 && "${_VERBOSE_SANDBOX:-false}" = true ]]; then
        printf "  [stderr] %s\n" "$(cat "$err_file")" >&2
    fi

    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Preflight: confirm install-team.sh exists and is executable
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0463-port: install-team.sh exists and is executable"
if [[ -x "$INSTALL_TEAM" ]]; then
    test_pass
else
    test_fail "install-team.sh not found or not executable: $INSTALL_TEAM"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Case 1: Two finance instances get distinct in-band ports
#
# finance band: base=8360, range=10.
# First install  → expects port 8360 (band base, no existing entries).
# Second install → expects port 8361 (next free in band).
# Both must be distinct and in [8360, 8370).
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0463-port case-1a: finance-personal gets port 8360 (band base, empty state)"
new_sandbox "1"
_c1_pass=true

if ! run_install "fp" finance --project personal; then
    test_fail "install-team.sh exited non-zero for finance --project personal (see $_SB/install-fp.err)"
    _c1_pass=false
fi

if [[ "$_c1_pass" = true ]]; then
    _c1_port1="$(jq -r '.teams["finance-personal"].lcars_port // empty' "$_SB_CONFIG" 2>/dev/null)"
    if [[ "$_c1_port1" = "8360" ]]; then
        test_pass
    else
        test_fail "expected finance-personal.lcars_port=8360, got '${_c1_port1:-<empty>}'"
        _c1_pass=false
    fi
fi

test_start "XACA-0463-port case-1b: finance-business gets port 8361 (next free in band)"
if [[ "$_c1_pass" = true ]]; then
    if ! run_install "fb" finance --project business; then
        test_fail "install-team.sh exited non-zero for finance --project business (see $_SB/install-fb.err)"
        _c1_pass=false
    fi
fi

if [[ "$_c1_pass" = true ]]; then
    _c1_port2="$(jq -r '.teams["finance-business"].lcars_port // empty' "$_SB_CONFIG" 2>/dev/null)"
    if [[ "$_c1_port2" = "8361" ]]; then
        test_pass
    else
        test_fail "expected finance-business.lcars_port=8361, got '${_c1_port2:-<empty>}'"
        _c1_pass=false
    fi
fi

test_start "XACA-0463-port case-1c: both finance ports are distinct and within band [8360,8370)"
if [[ "$_c1_pass" = true ]]; then
    _c1_port1_n="${_c1_port1:-0}"
    _c1_port2_n="${_c1_port2:-0}"
    if [[ "$_c1_port1_n" -ne "$_c1_port2_n" ]] \
        && [[ "$_c1_port1_n" -ge 8360 && "$_c1_port1_n" -lt 8370 ]] \
        && [[ "$_c1_port2_n" -ge 8360 && "$_c1_port2_n" -lt 8370 ]]; then
        test_pass
    else
        test_fail "ports not distinct or out of band: p1=$_c1_port1_n p2=$_c1_port2_n (expected distinct values in [8360,8370))"
    fi
else
    test_fail "skipped — earlier case-1 sub-test failed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Case 2: Freelance band size honoured
#
# freelance band: base=8500, range=100.
# First install  → expects 8500.
# Second install → expects 8501.
# This confirms the installer routes through the allocator for freelance too,
# and that the band's 100-slot size allows more than 10 instances.
#
# Note: freelance is template-client-project, so --client AND --project are
# required (no default project is defined in freelance.conf).
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0463-port case-2a: freelance-doublenode-starwords gets port 8500 (freelance band base)"
new_sandbox "2"
_c2_pass=true

if ! run_install "fw1" freelance --client doublenode --project starwords; then
    test_fail "install-team.sh exited non-zero for freelance --client doublenode --project starwords (see $_SB/install-fw1.err)"
    _c2_pass=false
fi

if [[ "$_c2_pass" = true ]]; then
    _c2_port1="$(jq -r '.teams["freelance-doublenode-starwords"].lcars_port // empty' "$_SB_CONFIG" 2>/dev/null)"
    if [[ "$_c2_port1" = "8500" ]]; then
        test_pass
    else
        test_fail "expected freelance-doublenode-starwords.lcars_port=8500, got '${_c2_port1:-<empty>}'"
        _c2_pass=false
    fi
fi

test_start "XACA-0463-port case-2b: freelance-doublenode-workstats gets port 8501 (next free)"
if [[ "$_c2_pass" = true ]]; then
    if ! run_install "fw2" freelance --client doublenode --project workstats; then
        test_fail "install-team.sh exited non-zero for freelance --client doublenode --project workstats (see $_SB/install-fw2.err)"
        _c2_pass=false
    fi
fi

if [[ "$_c2_pass" = true ]]; then
    _c2_port2="$(jq -r '.teams["freelance-doublenode-workstats"].lcars_port // empty' "$_SB_CONFIG" 2>/dev/null)"
    if [[ "$_c2_port2" = "8501" ]]; then
        test_pass
    else
        test_fail "expected freelance-doublenode-workstats.lcars_port=8501, got '${_c2_port2:-<empty>}'"
    fi
fi

# XACA-1222: freelance.conf is the one team.conf in this suite with real
# TEAM_BREW_DEPS/TEAM_BREW_CASK_DEPS (including the android-studio cask) —
# this is the case that would have hung the runner on real brew network I/O
# pre-stub. Assert POSITIVE evidence the stub was actually reached for it
# (absence of a violation later proves nothing if the stub was never
# invoked at all — e.g. if `brew` resolved to the real host binary because
# PATH wiring broke). "brew list android-studio" appearing in the log means
# install-team.sh's cask-dep loop ran and called our stub, not the real
# brew.
test_start "XACA-1222 case-2c: freelance install actually reached the brew stub (not real brew)"
if grep -qF 'brew list --cask android-studio' "$BREW_STUB_LOG" 2>/dev/null; then
    test_pass
else
    test_fail "expected 'brew list --cask android-studio' in $BREW_STUB_LOG after the freelance install — stub was not reached (or freelance.conf's cask deps changed); log: $(cat "$BREW_STUB_LOG" 2>/dev/null | tr '\n' ';')"
fi

test_start "XACA-1222 case-2d: no mutating brew subcommand reached the stub for the freelance install"
_c2_brew_viol="$(find_brew_violations "$BREW_STUB_LOG")"
if [[ -z "$_c2_brew_viol" ]]; then
    test_pass
else
    test_fail "mutating brew subcommand(s) reached the stub: ${_c2_brew_viol//$'\n'/; }"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Case 3: team-paths.json records distinct per-instance ports
#
# finance and freelance are both parametric (TEAM_HAS_PROJECTS=true) and ship
# startup scripts under share/scripts/teams/.  In parametric mode the installer
# copies ONE template-keyed script (e.g. finance-startup.sh) rather than
# generating a per-instance substituted file.  The per-instance port is NOT
# embedded in the script file; it is persisted to team-paths.json and resolved
# at runtime by lcars-launch-helpers.sh.
#
# This case verifies the JSON record is correct (which is the INSTALLER
# WIRING under test), not the script contents.
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0463-port case-3a: finance-personal lcars_port stored in team-paths.json"
new_sandbox "3"
_c3_pass=true

if ! run_install "c3a" finance --project personal; then
    test_fail "install-team.sh exited non-zero for finance --project personal (see $_SB/install-c3a.err)"
    _c3_pass=false
fi

if [[ "$_c3_pass" = true ]]; then
    _c3_port1="$(jq -r '.teams["finance-personal"].lcars_port // empty' "$_SB_CONFIG" 2>/dev/null)"
    if [[ -n "$_c3_port1" ]] && [[ "$_c3_port1" -ge 8360 ]] && [[ "$_c3_port1" -lt 8370 ]]; then
        test_pass
    else
        test_fail "finance-personal.lcars_port not in [8360,8370): got '${_c3_port1:-<empty>}'"
        _c3_pass=false
    fi
fi

test_start "XACA-0463-port case-3b: finance-business lcars_port is distinct from finance-personal"
if [[ "$_c3_pass" = true ]]; then
    if ! run_install "c3b" finance --project business; then
        test_fail "install-team.sh exited non-zero for finance --project business (see $_SB/install-c3b.err)"
        _c3_pass=false
    fi
fi

if [[ "$_c3_pass" = true ]]; then
    _c3_port2="$(jq -r '.teams["finance-business"].lcars_port // empty' "$_SB_CONFIG" 2>/dev/null)"
    if [[ -n "$_c3_port2" ]] \
        && [[ "$_c3_port2" -ge 8360 && "$_c3_port2" -lt 8370 ]] \
        && [[ "$_c3_port1" != "$_c3_port2" ]]; then
        test_pass
    else
        test_fail "finance-business.lcars_port must be in band and != finance-personal: personal=$_c3_port1 business=${_c3_port2:-<empty>}"
        _c3_pass=false
    fi
fi

# Confirm parametric mode: template-keyed startup script exists, NOT instance-keyed.
# This is a documentation assertion — it shows WHY we check JSON and not the script.
test_start "XACA-0463-port case-3c: parametric mode — finance-startup.sh is template-keyed, not instance-keyed"
if [[ "$_c3_pass" = true ]]; then
    _finance_startup="$_SB_AITF/finance-startup.sh"
    _finance_personal_startup="$_SB_AITF/finance-personal-startup.sh"
    if [[ -f "$_finance_startup" ]] && [[ ! -f "$_finance_personal_startup" ]]; then
        # Correct parametric behaviour: one template-keyed script, no instance-keyed file.
        test_pass
    elif [[ ! -f "$_finance_startup" ]] && [[ -f "$_finance_personal_startup" ]]; then
        # Legacy path: instance-keyed; check it embeds the correct port.
        # (Reaches here if XACA-0483 parametric mode is ever reverted.)
        _port_in_script="$(grep -o '[0-9]\{4,\}' "$_finance_personal_startup" | grep -F "$_c3_port1" | head -1 || true)"
        if [[ -n "$_port_in_script" ]]; then
            test_pass
        else
            test_fail "legacy mode: instance-keyed script does not contain expected port $_c3_port1 (check $FINANCE_PERSONAL_STARTUP)"
        fi
    else
        test_fail "unexpected script layout: template-keyed exists=$(test -f "$_finance_startup" && echo y || echo n), instance-keyed exists=$(test -f "$_finance_personal_startup" && echo y || echo n)"
    fi
else
    test_fail "skipped — earlier case-3 sub-test failed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Case 4: Installer fails loud on a non-existent template
#
# The allocator is called after the conf file check, so "unknown template"
# reaches the conf-not-found guard first, producing an early non-zero exit.
# Either guard produces a meaningful error; the test accepts any non-zero exit.
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0463-port case-4: bogus-template exits non-zero (no conf file)"
new_sandbox "4"
_c4_exit=0
run_install "c4" bogus-template --project whatever || _c4_exit=$?
if [[ "$_c4_exit" -ne 0 ]]; then
    test_pass
else
    test_fail "expected non-zero exit for unknown template 'bogus-template', got 0"
fi

test_start "XACA-0463-port case-4b: bogus-template output contains a meaningful error phrase"
# The conf-not-found guard writes "Error: Team configuration not found: ..." to stdout
# (plain echo, not >&2).  The allocator's own errors use >&2.  Check both streams.
_c4_out="$(cat "$_SB/install-c4.out" 2>/dev/null)"
_c4_err="$(cat "$_SB/install-c4.err" 2>/dev/null)"
_c4_combined="${_c4_out}${_c4_err}"
# Accept any of: "not found", "Unknown", "no lcars_port_base", "Invalid", "Error"
if printf '%s' "$_c4_combined" | grep -qiE 'not found|unknown|no lcars_port|invalid|error'; then
    test_pass
else
    test_fail "output did not contain a recognisable error phrase; stdout='${_c4_out:0:200}' stderr='${_c4_err:0:200}'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Case 5: Band-exhaustion sad path
#
# legal band: base=8320, range=10 (10 ports total).
# Hand-craft a team-paths.json that has all 10 ports occupied.
# Then attempt to install legal --project anotherone.
# Expected: non-zero exit; stderr contains "exhausted" (from the allocator).
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-0463-port case-5: band-exhausted legal install exits non-zero"
new_sandbox "5"

# Build a team-paths.json with all 10 legal ports occupied (8320-8329).
_c5_json='{"schema_version":1,"teams":{'
for _i in $(seq 0 9); do
    _port=$((8320 + _i))
    _c5_json="${_c5_json}\"legal-fake-$(printf '%03d' "$_i")\":{\"lcars_port\":${_port}},"
done
# Trim trailing comma, close object.
_c5_json="${_c5_json%,}}}"
printf '%s\n' "$_c5_json" > "$_SB_CONFIG"

_c5_exit=0
run_install "c5" legal --project anotherone || _c5_exit=$?
if [[ "$_c5_exit" -ne 0 ]]; then
    test_pass
else
    test_fail "expected non-zero exit when legal band is exhausted, got 0"
fi

test_start "XACA-0463-port case-5b: band-exhausted stderr contains 'exhausted'"
_c5_err="$(cat "$_SB/install-c5.err" 2>/dev/null || true)"
if printf '%s' "$_c5_err" | grep -qi 'exhausted'; then
    test_pass
else
    test_fail "stderr does not contain 'exhausted'; got: ${_c5_err:0:200}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# XACA-1222: suite-wide brew-sandboxing backstop.
#
# Case-2c/2d above already checked the one case with real deps. This is a
# second, independent read over the FULL suite log (every run_install() call
# across every case) so a future case added anywhere in this file that adds
# team-conf brew deps can't silently regress the sandboxing without tripping
# a test. Positive-evidence first (the log has SOME content — an empty log
# would make the "no violations" check below vacuously true), then the
# no-mutating-subcommand check.
# ─────────────────────────────────────────────────────────────────────────────
test_start "XACA-1222: brew stub log is non-empty (stub was reached at least once this suite)"
if [[ -s "$BREW_STUB_LOG" ]]; then
    test_pass
else
    test_fail "brew stub log at $BREW_STUB_LOG is empty or missing — either no case in this suite still exercises TEAM_BREW_DEPS, or the PATH stub wiring is broken; either way this check can't verify anything below it"
fi

test_start "XACA-1222: no mutating brew subcommand was attempted anywhere in this suite"
_suite_brew_viol="$(find_brew_violations "$BREW_STUB_LOG")"
if [[ -z "$_suite_brew_viol" ]]; then
    test_pass
else
    test_fail "mutating brew subcommand(s) reached the stub: ${_suite_brew_viol//$'\n'/; } (full log: $(cat "$BREW_STUB_LOG" 2>/dev/null | tr '\n' ';'))"
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
