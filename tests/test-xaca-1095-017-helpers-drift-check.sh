#!/bin/bash
# test-xaca-1095-017-helpers-drift-check.sh
#
# Dedicated coverage for check_kanban_helpers_inventory(), added to BOTH
# doctor entry points in this same ticket (XACA-1095) with zero test-suite
# coverage of its own — the tester gate flagged this as XACA-1095-017.
#
# The check compares the installed kanban-helpers.sh's top-level kb-*
# function inventory against the shipped template
# (share/templates/kanban/kanban-helpers.template.sh) and names the missing
# commands. It exists in TWO independent copies that must both behave
# correctly and — this is the part a naive test would miss — the two copies
# map their severities to DIFFERENT exit codes:
#
#   bin/aiteamforge-doctor.sh:              warn -> exit 0, fail -> exit 1
#   libexec/commands/aiteamforge-doctor.sh: warn -> exit 1, fail -> exit 2
#
# (Confirmed by reading each script's own end-of-run Summary/exit block, not
# assumed from symmetry with the other file — the two scripts' overall exit
# semantics genuinely differ across their WHOLE check suites, not just this
# check, so pinning this per-script here is the only way a future edit that
# reintroduces a mismatch gets caught.)
#
# Both scripts resolve the template/installed paths via env vars
# (AITEAMFORGE_HOME / AITEAMFORGE_DIR, read directly in bin/aiteamforge-
# doctor.sh and via get_framework_dir()/get_working_dir() in libexec/commands/
# aiteamforge-doctor.sh — see lib/config.sh), so this suite sandboxes the
# check by pointing those two env vars at a fixture template/installed pair
# under TEST_TMP_DIR and invoking each doctor script for real with
# `--check helpers-drift`, rather than re-implementing the check's logic.
# `--check helpers-drift` also means TOTAL_CHECKS=1 in every case, so the
# doctor script's own final exit code is driven entirely by this one check —
# no other check's ambient pass/warn/fail can contaminate the exit-code
# assertions below.
#
# Exit codes are captured via `OUT=$(...); RC=$?` — never through a pipe,
# since `$?` after `cmd | tail` reads tail's exit status, not the command's
# (feedback_pipefail_hides_exit_code.md).
#
# All filesystem activity is sandboxed under TEST_TMP_DIR / a private mktemp
# dir. Never touches real $HOME/aiteamforge or ~/.aiteamforge.
#
# Designed to run standalone OR via test-runner.sh.
# Exit 0 = all cases pass (standalone). Exit 1 = at least one case failed
# (standalone only — see the _STANDALONE note below for why non-standalone
# always exits 0 and relies on the runner's own FAIL: aggregation instead).

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DOCTOR="$TAP_ROOT/bin/aiteamforge-doctor.sh"
LIBEXEC_DOCTOR="$TAP_ROOT/libexec/commands/aiteamforge-doctor.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: fallbacks ONLY when test-runner.sh hasn't already
# exported test_start/test_pass/test_fail (it exports all three together —
# see test-runner.sh's `export -f test_start test_pass test_fail test_skip`).
# The printed summary is gated on _STANDALONE, not on whether the local
# counters are nonzero — a bare `_PASS=0`/`_FAIL=0` initializer with an
# unconditional trailing echo is the exact vacuous-green shape XACA-1095-018
# (this same ticket) fixed elsewhere in this suite; see knowledge k070.
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
_PASS=0
_FAIL=0
_FAIL_AT_START=0
_CURRENT_TEST=""

if ! declare -F test_start &>/dev/null; then
    _STANDALONE=true
    # XACA-1095: test_pass must NOT be unconditional. assert_* records only on
    # FAILURE, so an unconditional trailing test_pass makes a case that failed an
    # assertion report BOTH a FAIL and a PASS — and makes _PASS equal the case
    # count regardless of outcome, i.e. evidence of nothing. Demonstrated by
    # negative control while building this suite: mutating the subject produced
    # "PASS=16 FAIL=1" with the PASS total unchanged. The exit code stayed correct,
    # but a pass total that cannot move is the same displayed-vs-actual divergence
    # this whole ticket exists to close. Gate the pass on "no failure was recorded
    # since this case started".
    test_start() { _CURRENT_TEST="$1"; _FAIL_AT_START=$_FAIL; printf "TEST: %s\n" "$1"; }
    test_pass()  {
        if [ "${_FAIL:-0}" -ne "${_FAIL_AT_START:-0}" ]; then return 0; fi
        _PASS=$((_PASS + 1)); printf "  PASS: %s\n" "$_CURRENT_TEST"
    }
    test_fail()  { _FAIL=$((_FAIL + 1)); printf "  FAIL: %s — %s\n" "$_CURRENT_TEST" "${1:-}" >&2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# XACA-1095 [Review] (PR #820): case-level pass gating that works under BOTH
# invocation paths.
#
# The first attempt at this redefined test_pass inside the
# `if ! declare -F test_start` standalone shim. That is INERT under
# test-runner.sh: the runner exports its own test_start/test_pass before
# sourcing each file, so the shim never installs and a failing case still
# reported a PASS in CI — the exact divergence the fix claimed to close, just
# relocated to the path that actually matters.
#
# These wrappers are defined unconditionally and used at every call site, so
# the gating holds whether test_pass comes from the local shim or from the
# runner. _LOCAL_FAILS is our own tally; it is incremented by the assert_*
# helpers below (which are also always locally defined) and by _t_fail.
# ─────────────────────────────────────────────────────────────────────────────
_LOCAL_FAILS=0
_LOCAL_FAILS_AT_START=0
_t_start() { _LOCAL_FAILS_AT_START="$_LOCAL_FAILS"; test_start "$@"; }
_t_fail()  { _LOCAL_FAILS=$((_LOCAL_FAILS + 1)); test_fail "$@"; }
_t_pass()  {
    # NOTE: the call below MUST stay `test_pass` (the underlying harness
    # function), never `_t_pass`. An earlier mechanical rewrite of call sites
    # matched this very line and made this function call itself — infinite
    # recursion, SIGSEGV (exit 139) on every run. Kept explicit as a warning.
    if [ "$_LOCAL_FAILS" -ne "$_LOCAL_FAILS_AT_START" ]; then return 0; fi
    test_pass
}

assert_eq() {
    local got="$1" expected="$2" msg="${3:-Expected '$2', got '$1'}"
    [ "$got" = "$expected" ] || _t_fail "$msg"
}
assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-Expected to find '$2' in output}"
    [[ "$haystack" == *"$needle"* ]] || _t_fail "$msg"
}
assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-Expected NOT to find '$2' in output}"
    [[ "$haystack" != *"$needle"* ]] || _t_fail "$msg"
}

# Pull out ONLY the dynamic "Missing (first N of M): a,b,c" line from a
# doctor run's output. NOT a whole-output substring check: both doctor
# scripts' FAIL message carries a STATIC boilerplate suffix — "— kb-sweep and
# other lifecycle commands may be unusable" — that literally contains the
# string "kb-sweep" regardless of which functions are actually missing. An
# assert_contains against the WHOLE output would pass even if the dynamic
# missing-list logic were completely broken (the exact "matches for the
# wrong reason" trap this ticket's standards call out — see XACA-0564's
# TEMPLATE_MARKER precedent). Isolating this one line is what makes the
# kb-sweep assertion below actually verify the DYNAMIC list, not the
# hardcoded sentence.
_extract_missing_line() {
    printf '%s\n' "$1" | grep 'Missing (first'
}

if [ ! -f "$BIN_DOCTOR" ]; then
    echo "FATAL: bin/aiteamforge-doctor.sh not found at: $BIN_DOCTOR" >&2
    exit 1
fi
if [ ! -f "$LIBEXEC_DOCTOR" ]; then
    echo "FATAL: libexec/commands/aiteamforge-doctor.sh not found at: $LIBEXEC_DOCTOR" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Fixture sandbox
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1095017-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi

_cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap _cleanup EXIT INT TERM

SANDBOX="$TEST_TMP_DIR/xaca1095017"
FRAMEWORK_HOME="$SANDBOX/home"
WORKING_DIR="$SANDBOX/atf"
TEMPLATE_DIR="$FRAMEWORK_HOME/share/templates/kanban"
TEMPLATE_FILE="$TEMPLATE_DIR/kanban-helpers.template.sh"
INSTALLED_FILE="$WORKING_DIR/kanban-helpers.sh"

mkdir -p "$TEMPLATE_DIR" "$WORKING_DIR"

# Matching template: six kb-* functions, deliberately including kb-sweep (the
# protected-subitem PR merge gate named explicitly in the check's own FAIL
# message) so a truncation that drops it is unambiguous.
cat > "$TEMPLATE_FILE" <<'EOF'
#!/bin/zsh
kb-sweep() { :; }
kb-epic() { :; }
kb-release() { :; }
kb-run() { :; }
kb-pick() { :; }
kb-help() { :; }
EOF

_install_matching() {
    cp "$TEMPLATE_FILE" "$INSTALLED_FILE"
}
_install_truncated() {
    # Drops kb-sweep, kb-epic, kb-release — keeps kb-run/kb-pick/kb-help.
    cat > "$INSTALLED_FILE" <<'EOF'
#!/bin/zsh
kb-run() { :; }
kb-pick() { :; }
kb-help() { :; }
EOF
}

_install_partial_keeping_sweep() {
    # XACA-1095-019: drops kb-epic, kb-release, kb-run but KEEPS kb-sweep.
    # Same missing COUNT as _install_truncated (3 of 6) so the only variable
    # between the two fixtures is whether kb-sweep itself is in the missing set.
    cat > "$INSTALLED_FILE" <<'EOF'
#!/bin/zsh
kb-sweep() { :; }
kb-pick() { :; }
kb-help() { :; }
EOF
}

# Run a doctor script with the fixture env, sandboxed, capturing stdout+stderr
# and exit code SEPARATELY (never through a pipe — feedback_pipefail_hides_exit_code.md).
# Usage: _run_doctor <script> <framework_home> <working_dir> [extra args...]
_DOCTOR_OUT=""
_DOCTOR_RC=""
_run_doctor() {
    local script="$1" fw_home="$2" wd="$3"
    shift 3
    _DOCTOR_OUT="$(AITEAMFORGE_HOME="$fw_home" AITEAMFORGE_DIR="$wd" bash "$script" --check helpers-drift "$@" 2>&1)"
    _DOCTOR_RC=$?
    # Strip ANSI color codes for reliable substring assertions.
    _DOCTOR_OUT="$(printf '%s' "$_DOCTOR_OUT" | sed 's/\x1b\[[0-9;]*m//g')"
}

# ═════════════════════════════════════════════════════════════════════════════
# Behaviour 4: reachability — `--check helpers-drift` invokes the check, and
# it runs under `all`, in BOTH scripts. Static source assertions: fastest and
# most precise, and avoids depending on `all`'s many other ambient-system
# checks (services/network/disk/git) to succeed in a sandbox.
# ═════════════════════════════════════════════════════════════════════════════

_t_start "Reachability: bin/aiteamforge-doctor.sh dispatches helpers-drift to check_kanban_helpers_inventory"
_BIN_CASE="$(awk '/^  helpers-drift\)/,/;;/' "$BIN_DOCTOR")"
assert_contains "$_BIN_CASE" "check_kanban_helpers_inventory" \
    "bin/aiteamforge-doctor.sh's 'helpers-drift)' case must call check_kanban_helpers_inventory"
_t_pass
_t_start "Reachability: bin/aiteamforge-doctor.sh runs check_kanban_helpers_inventory under 'all'"
_BIN_ALL_CASE="$(awk '/^  all\)/,/;;/' "$BIN_DOCTOR")"
assert_contains "$_BIN_ALL_CASE" "check_kanban_helpers_inventory" \
    "bin/aiteamforge-doctor.sh's 'all)' case must call check_kanban_helpers_inventory"
_t_pass
_t_start "Reachability: libexec/commands/aiteamforge-doctor.sh dispatches helpers-drift to check_kanban_helpers_inventory"
_LIB_CASE="$(awk '/^  helpers-drift\)/,/;;/' "$LIBEXEC_DOCTOR")"
assert_contains "$_LIB_CASE" "check_kanban_helpers_inventory" \
    "libexec/commands/aiteamforge-doctor.sh's 'helpers-drift)' case must call check_kanban_helpers_inventory"
_t_pass
_t_start "Reachability: libexec/commands/aiteamforge-doctor.sh runs check_kanban_helpers_inventory under 'all'"
_LIB_ALL_CASE="$(awk '/^  all\)/,/;;/' "$LIBEXEC_DOCTOR")"
assert_contains "$_LIB_ALL_CASE" "check_kanban_helpers_inventory" \
    "libexec/commands/aiteamforge-doctor.sh's 'all)' case must call check_kanban_helpers_inventory"
_t_pass
# ═════════════════════════════════════════════════════════════════════════════
# bin/aiteamforge-doctor.sh — warn exits 0, fail exits 1
# ═════════════════════════════════════════════════════════════════════════════

_t_start "bin/: Behaviour 2 — passes cleanly when installed and shipped match (exit 0)"
_install_matching
_run_doctor "$BIN_DOCTOR" "$FRAMEWORK_HOME" "$WORKING_DIR"
assert_contains "$_DOCTOR_OUT" "kanban-helpers.sh has all 6 shipped kb-* commands" \
    "Expected a clean pass message naming the matched count"
assert_eq "$_DOCTOR_RC" "0" "bin/: a passing helpers-drift check must exit 0, got $_DOCTOR_RC"
_t_pass
_t_start "bin/: Behaviour 1 — fires on a truncated installed helper, names kb-sweep, exit 1"
_install_truncated
_run_doctor "$BIN_DOCTOR" "$FRAMEWORK_HOME" "$WORKING_DIR" --verbose
assert_contains "$_DOCTOR_OUT" "MISSING 3 of 6 shipped kb-* commands" \
    "Expected the FAIL message to report the correct missing/total counts"
_BIN_MISSING_LINE="$(_extract_missing_line "$_DOCTOR_OUT")"
[ -n "$_BIN_MISSING_LINE" ] || test_fail "Expected a 'Missing (first ...)' line to be present at all"
assert_contains "$_BIN_MISSING_LINE" "kb-sweep" \
    "Expected the DYNAMIC missing-commands line (not the static boilerplate sentence) to name kb-sweep"
assert_eq "$_DOCTOR_RC" "1" "bin/: a failing helpers-drift check must exit 1, got $_DOCTOR_RC"
_t_pass
_t_start "bin/: Behaviour 3 — degrades honestly (warn, not pass) when the shipped template is missing/unreadable, exit 0"
_install_matching
_run_doctor "$BIN_DOCTOR" "$SANDBOX/nonexistent-home" "$WORKING_DIR"
assert_contains "$_DOCTOR_OUT" "shipped template not found/readable" \
    "Expected an explicit warn naming the missing template"
assert_not_contains "$_DOCTOR_OUT" "has all 6 shipped kb-* commands" \
    "A missing template must never read as a pass"
assert_eq "$_DOCTOR_RC" "0" "bin/: a warn-only helpers-drift check must exit 0, got $_DOCTOR_RC"
_t_pass
_t_start "bin/: Behaviour 4 — degrades honestly (fail, distinct from partial drift) when the installed file is missing, exit 1"
_run_doctor "$BIN_DOCTOR" "$FRAMEWORK_HOME" "$SANDBOX/no-such-atf-dir"
assert_contains "$_DOCTOR_OUT" "kanban-helpers.sh not found/readable at" \
    "Expected an explicit fail naming the missing installed file"
assert_contains "$_DOCTOR_OUT" "no kb-* commands available" \
    "A missing installed file must be distinguishable from a partial-drift FAIL"
assert_not_contains "$_DOCTOR_OUT" "MISSING 3 of 6" \
    "A wholly-missing installed file must not be reported via the partial-drift MISSING-N-of-M message"
assert_eq "$_DOCTOR_RC" "1" "bin/: a failing (missing-installed) helpers-drift check must exit 1, got $_DOCTOR_RC"
_t_pass
# ═════════════════════════════════════════════════════════════════════════════
# libexec/commands/aiteamforge-doctor.sh — warn exits 1, fail exits 2
# (Deliberately different from bin/'s mapping above — this is the load-bearing
# part of this coverage; see header comment.)
# ═════════════════════════════════════════════════════════════════════════════

_t_start "libexec/: Behaviour 2 — passes cleanly when installed and shipped match (exit 0)"
_install_matching
_run_doctor "$LIBEXEC_DOCTOR" "$FRAMEWORK_HOME" "$WORKING_DIR"
assert_contains "$_DOCTOR_OUT" "kanban-helpers.sh has all 6 shipped kb-* commands" \
    "Expected a clean pass message naming the matched count"
assert_eq "$_DOCTOR_RC" "0" "libexec/: a passing helpers-drift check must exit 0, got $_DOCTOR_RC"
_t_pass
_t_start "libexec/: Behaviour 1 — fires on a truncated installed helper, names kb-sweep, exit 2"
_install_truncated
_run_doctor "$LIBEXEC_DOCTOR" "$FRAMEWORK_HOME" "$WORKING_DIR" --verbose
assert_contains "$_DOCTOR_OUT" "MISSING 3 of 6 shipped kb-* commands" \
    "Expected the FAIL message to report the correct missing/total counts"
_LIB_MISSING_LINE="$(_extract_missing_line "$_DOCTOR_OUT")"
[ -n "$_LIB_MISSING_LINE" ] || test_fail "Expected a 'Missing (first ...)' line to be present at all"
assert_contains "$_LIB_MISSING_LINE" "kb-sweep" \
    "Expected the DYNAMIC missing-commands line (not the static boilerplate sentence) to name kb-sweep"
assert_eq "$_DOCTOR_RC" "2" "libexec/: a failing helpers-drift check must exit 2, got $_DOCTOR_RC"
_t_pass
_t_start "libexec/: Behaviour 3 — degrades honestly (warn, not pass) when the shipped template is missing/unreadable, exit 1"
_install_matching
_run_doctor "$LIBEXEC_DOCTOR" "$SANDBOX/nonexistent-home" "$WORKING_DIR"
assert_contains "$_DOCTOR_OUT" "shipped template not found/readable" \
    "Expected an explicit warn naming the missing template"
assert_not_contains "$_DOCTOR_OUT" "has all 6 shipped kb-* commands" \
    "A missing template must never read as a pass"
assert_eq "$_DOCTOR_RC" "1" "libexec/: a warn-only helpers-drift check must exit 1, got $_DOCTOR_RC"
_t_pass
_t_start "libexec/: Behaviour 4 — degrades honestly (fail, distinct from partial drift) when the installed file is missing, exit 2"
_run_doctor "$LIBEXEC_DOCTOR" "$FRAMEWORK_HOME" "$SANDBOX/no-such-atf-dir"
assert_contains "$_DOCTOR_OUT" "kanban-helpers.sh not found/readable at" \
    "Expected an explicit fail naming the missing installed file"
assert_contains "$_DOCTOR_OUT" "no kb-* commands available" \
    "A missing installed file must be distinguishable from a partial-drift FAIL"
assert_not_contains "$_DOCTOR_OUT" "MISSING 3 of 6" \
    "A wholly-missing installed file must not be reported via the partial-drift MISSING-N-of-M message"
assert_eq "$_DOCTOR_RC" "2" "libexec/: a failing (missing-installed) helpers-drift check must exit 2, got $_DOCTOR_RC"
_t_pass
# ═════════════════════════════════════════════════════════════════════════════
# XACA-1095-019 — the kb-sweep "honesty" clause must be CONDITIONAL.
#
# The FAIL message used to hardcode "kb-sweep and other lifecycle commands may
# be unusable" as static boilerplate, printed whether or not kb-sweep was in
# the missing set. That misinforms an operator whose kb-sweep is present, and
# it let an assert_contains pass by coincidence. The fix emits the clause only
# when kb-sweep is genuinely missing.
#
# Testing only the positive direction would NOT catch a regression to the
# hardcoded form -- the clause would still be there. Both directions are the
# test; either alone is decoration.
# ═════════════════════════════════════════════════════════════════════════════

_t_start "bin/: gate note IS emitted when kb-sweep is genuinely missing"
_install_truncated
_run_doctor "$BIN_DOCTOR" "$FRAMEWORK_HOME" "$WORKING_DIR"
assert_contains "$_DOCTOR_OUT" "kb-sweep is among them" \
    "kb-sweep is missing, so the FAIL message must say so"
_t_pass
_t_start "bin/: gate note is NOT emitted when kb-sweep is present (regression guard for the hardcoded boilerplate)"
_install_partial_keeping_sweep
_run_doctor "$BIN_DOCTOR" "$FRAMEWORK_HOME" "$WORKING_DIR"
assert_contains "$_DOCTOR_OUT" "MISSING 3 of 6 shipped kb-* commands" \
    "Fixture must still trip the drift FAIL, otherwise the negative assertion below is vacuous"
assert_not_contains "$_DOCTOR_OUT" "kb-sweep is among them" \
    "kb-sweep is PRESENT -- naming it as missing misinforms the operator (the hardcoded-boilerplate regression)"
_t_pass
_t_start "libexec/: gate note IS emitted when kb-sweep is genuinely missing"
_install_truncated
_run_doctor "$LIBEXEC_DOCTOR" "$FRAMEWORK_HOME" "$WORKING_DIR"
assert_contains "$_DOCTOR_OUT" "kb-sweep is among them" \
    "kb-sweep is missing, so the FAIL message must say so"
_t_pass
_t_start "libexec/: gate note is NOT emitted when kb-sweep is present (regression guard for the hardcoded boilerplate)"
_install_partial_keeping_sweep
_run_doctor "$LIBEXEC_DOCTOR" "$FRAMEWORK_HOME" "$WORKING_DIR"
assert_contains "$_DOCTOR_OUT" "MISSING 3 of 6 shipped kb-* commands" \
    "Fixture must still trip the drift FAIL, otherwise the negative assertion below is vacuous"
assert_not_contains "$_DOCTOR_OUT" "kb-sweep is among them" \
    "kb-sweep is PRESENT -- naming it as missing misinforms the operator (the hardcoded-boilerplate regression)"
_t_pass
# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone mode only — test-runner.sh tallies pass/fail from its
# OWN exported functions' output).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "──────────────────────────────────────────────"
    echo "  helpers-drift check test:  PASS=$_PASS  FAIL=$_FAIL"
    echo "──────────────────────────────────────────────"
    [ "$_FAIL" -eq 0 ] || exit 1
fi
exit 0
