#!/bin/bash

# test-xaca-1300-token-report-materialize.sh
# Regression tests for XACA-1300 (Part B2): update_runtime_helpers must
# MATERIALISE share/scripts/kb-token-report on upgrade even when the
# working-dir target is ABSENT.
#
# REGRESSION INTENT: fleet-reporter.sh's send_token_reports() runs
# $AITEAMFORGE_DIR/scripts/kb-token-report on tap machines. kb-token-report is
# a BRAND-NEW file for every already-installed box, and it is EXTENSIONLESS, so
# two independent gaps would each keep it off upgraded machines forever:
#   (a) the *.sh / *.py glob sweep cannot match it — it must be listed
#       explicitly in the loop (same gap class as kb-init-team / kb-pr-monitor,
#       XACA-0395 / XACA-1275);
#   (b) the sweep only refreshes what already exists, so a brand-new file must
#       also be in _xaca0673_mandatory_materialize_basenames (XACA-0673).
# Without both, the reporter ships to upgraded machines and silently finds no
# tool to run, so the fleet collects no token aggregates from any of them.
#
# Assertions:
#   1. kb-token-report is MATERIALISED when absent from WORKING_DIR/scripts/.
#   2. The materialised copy is executable and matches the shipped source.
#   3. --dry-run does not materialise it.
#   4. It is registered in the mandatory-materialise set.
#   5. It is listed explicitly in update_runtime_helpers' sweep loop (the glob
#      cannot reach an extensionless name).
#
# All filesystem activity is sandboxed to TEST_TMP_DIR.
# NEVER touches real $HOME / ~/.aiteamforge — installer-test safety rule.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"

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
if ! type -t assert_file_exists >/dev/null 2>&1; then
    assert_file_exists() { [ -f "$1" ] || { test_fail "${2:-Expected file to exist: $1}"; return 1; }; }
fi
if ! type -t assert_file_not_exists >/dev/null 2>&1; then
    assert_file_not_exists() { [ ! -f "$1" ] || { test_fail "${2:-Expected file to not exist: $1}"; return 1; }; }
fi
if ! type -t assert_contains >/dev/null 2>&1; then
    assert_contains() { [[ "$1" == *"$2"* ]] || { test_fail "${3:-Expected to find '$2'}"; return 1; }; }
fi

for _p in print_section print_info print_success print_warning print_error; do
    if ! declare -f "$_p" >/dev/null 2>&1; then eval "${_p}() { :; }"; fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory (runner-supplied or our own).
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1300-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

# Extract the functions under test (the script's main body has side effects).
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$UPGRADE_SH"
}
for _fn in _xaca0608_render_team_script _xaca0608_aux_script_map \
           _xaca0608_aux_scriptdir_basenames _xaca0673_mandatory_materialize_basenames \
           update_runtime_helpers; do
    _src="$(_extract_fn "$_fn")"
    if [ -z "$_src" ]; then echo "FATAL: could not extract $_fn from upgrade.sh"; exit 1; fi
    eval "$_src"
    declare -f "$_fn" >/dev/null || { echo "FATAL: $_fn not defined after extraction"; exit 1; }
done

SANDBOX="$TEST_TMP_DIR/xaca1300"
RH_WORKING="$SANDBOX/rh-working"
RH_SCRIPTS="$RH_WORKING/scripts"
mkdir -p "$RH_SCRIPTS"

NAME="kb-token-report"
SRC="$TAP_ROOT/share/scripts/$NAME"

# Seed an unrelated installed helper so scripts/ looks like a real install.
printf '#!/bin/bash\n# pre-existing sibling\n' > "$RH_SCRIPTS/kanban-helpers.sh"
chmod +x "$RH_SCRIPTS/kanban-helpers.sh"

# ═══════════════════════════════════════════════════════════════════════════
# TEST 1: materialised when absent
# ═══════════════════════════════════════════════════════════════════════════
test_start "update_runtime_helpers materialises an ABSENT kb-token-report"
if [ -f "$SRC" ]; then
    rm -f "$RH_SCRIPTS/$NAME"
    FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$RH_WORKING" FORCE=false DRY_RUN=false \
        update_runtime_helpers >/dev/null 2>&1
    assert_file_exists "$RH_SCRIPTS/$NAME" \
        "kb-token-report must be materialised on upgrade even though its target was absent" \
        && test_pass
else
    test_fail "share/scripts/$NAME missing — cannot exercise materialisation"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 2: executable and matches the shipped source
# ═══════════════════════════════════════════════════════════════════════════
test_start "Materialised kb-token-report is executable and matches the shipped source"
if [ -f "$RH_SCRIPTS/$NAME" ]; then
    if [ -x "$RH_SCRIPTS/$NAME" ] && cmp -s "$SRC" "$RH_SCRIPTS/$NAME"; then
        test_pass
    else
        test_fail "Materialised copy must keep its exec bit and be byte-identical to share/scripts/$NAME"
    fi
else
    test_fail "Materialised copy absent — cannot validate"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 3: --dry-run writes nothing
# ═══════════════════════════════════════════════════════════════════════════
test_start "--dry-run does not materialise kb-token-report"
DRY_WORKING="$SANDBOX/dry-working"
mkdir -p "$DRY_WORKING/scripts"
FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$DRY_WORKING" DRY_RUN=true FORCE=false \
    update_runtime_helpers >/dev/null 2>&1
assert_file_not_exists "$DRY_WORKING/scripts/$NAME" \
    "--dry-run must not write kb-token-report to disk" \
    && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 4: registered in the mandatory set
# ═══════════════════════════════════════════════════════════════════════════
test_start "Mandatory set registers kb-token-report"
assert_contains $'\n'"$(_xaca0673_mandatory_materialize_basenames)"$'\n' $'\n'"$NAME"$'\n' \
    "kb-token-report must be in _xaca0673_mandatory_materialize_basenames" \
    && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 5: listed explicitly in the sweep loop (extensionless)
# ═══════════════════════════════════════════════════════════════════════════
test_start "update_runtime_helpers' sweep loop lists kb-token-report explicitly"
_loop_line="$(_extract_fn update_runtime_helpers | grep -E '^[[:space:]]*for src in ' | head -1)"
assert_contains "$_loop_line" '"$scripts_source"/kb-token-report' \
    "The *.sh/*.py globs cannot match an extensionless name; list it in the for-src loop" \
    && test_pass

if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
fi
exit 0
