#!/bin/bash
# test-xaca-1322-vault-drift.sh
#
# Table-driven regression suite for the vault-fetch.js/vault-keygen.js drift
# checker (XACA-1322-013/014/015, and its PR #965 round-6 redesign).
#
# BACKGROUND: the checker verifies an installed vault-keygen.js/
# vault-fetch.js pair is not stale relative to what this tap release
# shipped. Before XACA-1322 it existed as TWO near-identical copies
# (_val_check_vault_drift in libexec/lib/validate-install.sh,
# check_vault_keygen_drift in libexec/commands/aiteamforge-doctor.sh), both
# hardcoding a single member name (resolveFleetUrl) and both falling back,
# when node was unavailable, to an awk scan for the end of
# `module.exports` that only recognized a closing brace flush-left at
# column 0.
#
# XACA-1322-013/014/015 unified the two copies into ONE shared
# implementation and replaced that awk scan with a byte-compare (cmp)
# no-node fallback. XACA-1322-017 through 021 then tried to make a real
# node-probe path sound too: derive the required kg.* member set from the
# installed vault-fetch.js via a static awk lexer (regex-vs-division
# disambiguation, string/template/comment stripping, a token-accounting
# ratchet), and verify a node require() probe against it. PR #965 rounds 2
# through 5 iterated that lexer and the reviewer found a new desync every
# round: regex vs division after `if (...)`, `i++ / 2`, a template literal
# immediately before `/`, `await`/`yield` as regex-permitting keywords
# missing from the lexer's keyword table. Each desync manifests as a MISSED
# kg.* reference -- a false PASS on a real drift, which is the one failure
# mode this checker exists to prevent.
#
# THE FIX under test here (round 6, user-decided): static JS parsing is
# removed from the runtime check ENTIRELY. libexec/lib/vault-drift.sh is
# now ALWAYS a byte comparison of the installed vault-fetch.js and
# vault-keygen.js against the copies shipped with this tap release:
#   - installed vault-fetch.js absent -> SKIP.
#   - installed vault-keygen.js absent -> FAIL.
#   - shipped copies unavailable/unreadable -> WARN, never a silent PASS.
#   - installed vault-keygen.js unreadable -> WARN.
#   - cmp both files -- identical -> PASS; either differs -> FAIL, naming
#     which file(s) differ.
# No node, no lexer, no heuristic -- nothing for adversarial installed JS
# to desynchronize. The case byte-compare cannot catch (a shipped release
# whose vault-fetch.js and vault-keygen.js are already mutually
# inconsistent with each other) is covered separately by
# tests/test-xaca-1322-shipped-kg-contract.sh, which runs once against the
# real shipped files -- fixed, trusted input, not adversarial installed JS.
#
# See libexec/lib/vault-drift.sh's own header for the full history.
#
# All filesystem activity is sandboxed to TEST_TMP_DIR. NEVER touches real
# $HOME / ~/.aiteamforge.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VAULT_DRIFT_LIB="$TAP_ROOT/libexec/lib/vault-drift.sh"
COMMON_LIB="$TAP_ROOT/libexec/lib/common.sh"
CONFIG_LIB="$TAP_ROOT/libexec/lib/config.sh"
VALIDATE_LIB="$TAP_ROOT/libexec/lib/validate-install.sh"
DOCTOR_CMD="$TAP_ROOT/libexec/commands/aiteamforge-doctor.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (works sourced by test-runner.sh's `export -f`'d
# helpers OR invoked directly, same convention as
# test-xaca-1300-token-report-materialize.sh).
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST -- $1" >&2; }
fi
if ! type -t assert_equal >/dev/null 2>&1; then
    assert_equal() { [ "$1" = "$2" ] || { test_fail "${3:-Expected '$2', got '$1'}"; return 1; }; }
fi
if ! type -t assert_contains >/dev/null 2>&1; then
    assert_contains() { [[ "$1" == *"$2"* ]] || { test_fail "${3:-Expected to find '$2' in: $1}"; return 1; }; }
fi
if ! type -t assert_not_contains >/dev/null 2>&1; then
    assert_not_contains() { [[ "$1" != *"$2"* ]] || { test_fail "${3:-Did not expect to find '$2' in: $1}"; return 1; }; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Sandbox (XACA sandboxing convention: never touch a real install).
# ─────────────────────────────────────────────────────────────────────────────
export AITEAMFORGE_DIR="${TEST_TMP_DIR:-}/aiteamforge"

if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1322-vault-drift.XXXXXX)"
    _OWN_TMP=true
    export AITEAMFORGE_DIR="${TEST_TMP_DIR}/aiteamforge"
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

SANDBOX="$TEST_TMP_DIR/xaca1322-vd"
mkdir -p "$SANDBOX"

# ═══════════════════════════════════════════════════════════════════════════
# Fixture builders
# ═══════════════════════════════════════════════════════════════════════════

# _mk_pair <dir> <fetch_content> <keygen_content>  — writes both files under
# <dir>/scripts/, creating the dir. Omit either content (pass "") to skip
# writing that file.
_mk_pair() {
    local dir="$1" fetch_content="$2" keygen_content="$3"
    mkdir -p "$dir/scripts"
    [ -n "$fetch_content" ] && printf '%s\n' "$fetch_content" > "$dir/scripts/vault-fetch.js"
    [ -n "$keygen_content" ] && printf '%s\n' "$keygen_content" > "$dir/scripts/vault-keygen.js"
}

# _mk_shipped <dir> <fetch_content> <keygen_content> — writes both files
# under <dir>/shipped/. Omit either content (pass "") to skip writing that
# file, so a test can exercise a missing/partial shipped copy.
_mk_shipped() {
    local dir="$1" fetch_content="$2" keygen_content="$3"
    mkdir -p "$dir/shipped"
    [ -n "$fetch_content" ] && printf '%s\n' "$fetch_content" > "$dir/shipped/vault-fetch.js"
    [ -n "$keygen_content" ] && printf '%s\n' "$keygen_content" > "$dir/shipped/vault-keygen.js"
}

_reload_vault_drift_lib() {
    unset _VAULT_DRIFT_SH_LOADED
    # shellcheck source=../libexec/lib/vault-drift.sh
    source "$VAULT_DRIFT_LIB"
}

_FETCH_OK="const kg = require('./vault-keygen');
kg.resolveFleetUrl();"
_KEYGEN_OK="function resolveFleetUrl() { return null; }
module.exports = { resolveFleetUrl };"
_KEYGEN_STALE="function generateKeypair() { return {}; }
module.exports = { generateKeypair };"
_FETCH_ALT="const kg = require('./vault-keygen');
kg.resolveFleetUrl();
kg.acceptFleetUrl();"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 1 — core contract table (SKIP/FAIL/WARN/PASS)
# ═══════════════════════════════════════════════════════════════════════════

test_start "SKIP when vault-fetch.js is not installed"
_reload_vault_drift_lib
d="$SANDBOX/t-skip"; mkdir -p "$d/scripts"
_aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
assert_equal "SKIP" "$_AITF_VD_STATUS" && test_pass

test_start "FAIL when vault-keygen.js is missing entirely, message names the upgrade remedy"
_reload_vault_drift_lib
d="$SANDBOX/t-keygen-missing"; _mk_pair "$d" "$_FETCH_OK" ""
_aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
assert_equal "FAIL" "$_AITF_VD_STATUS"
assert_contains "$_AITF_VD_MSG" "aiteamforge upgrade" && test_pass

test_start "PASS when both installed files are byte-identical to the shipped copies"
_reload_vault_drift_lib
d="$SANDBOX/t-identical"; _mk_pair "$d" "$_FETCH_OK" "$_KEYGEN_OK"
_mk_shipped "$d" "$_FETCH_OK" "$_KEYGEN_OK"
_aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
assert_equal "PASS" "$_AITF_VD_STATUS"
assert_contains "$_AITF_VD_MSG" "shipped copy" && test_pass

test_start "FAIL when installed vault-keygen.js differs from the shipped copy, message names vault-keygen.js"
_reload_vault_drift_lib
d="$SANDBOX/t-keygen-differs"; _mk_pair "$d" "$_FETCH_OK" "$_KEYGEN_STALE"
_mk_shipped "$d" "$_FETCH_OK" "$_KEYGEN_OK"
_aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
assert_equal "FAIL" "$_AITF_VD_STATUS"
assert_contains "$_AITF_VD_MSG" "vault-keygen.js"
assert_contains "$_AITF_VD_MSG" "aiteamforge upgrade" && test_pass

test_start "FAIL when installed vault-fetch.js differs from the shipped copy, message names vault-fetch.js"
_reload_vault_drift_lib
d="$SANDBOX/t-fetch-differs"; _mk_pair "$d" "$_FETCH_ALT" "$_KEYGEN_OK"
_mk_shipped "$d" "$_FETCH_OK" "$_KEYGEN_OK"
_aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
assert_equal "FAIL" "$_AITF_VD_STATUS"
assert_contains "$_AITF_VD_MSG" "vault-fetch.js"
assert_contains "$_AITF_VD_MSG" "aiteamforge upgrade" && test_pass

test_start "FAIL when BOTH installed files differ from the shipped copy, message names both"
_reload_vault_drift_lib
d="$SANDBOX/t-both-differ"; _mk_pair "$d" "$_FETCH_ALT" "$_KEYGEN_STALE"
_mk_shipped "$d" "$_FETCH_OK" "$_KEYGEN_OK"
_aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
assert_equal "FAIL" "$_AITF_VD_STATUS"
assert_contains "$_AITF_VD_MSG" "vault-keygen.js"
assert_contains "$_AITF_VD_MSG" "vault-fetch.js" && test_pass

test_start "WARN (never PASS) when the shipped scripts dir cannot be resolved"
_reload_vault_drift_lib
d="$SANDBOX/t-no-shipped-dir"; _mk_pair "$d" "$_FETCH_OK" "$_KEYGEN_OK"
_aitf_vault_drift_check "$d/scripts" "$d/nonexistent-shipped" >/dev/null 2>&1
assert_equal "WARN" "$_AITF_VD_STATUS"
assert_contains "$_AITF_VD_MSG" "shipped copies unavailable" && test_pass

test_start "WARN (never PASS) when the shipped scripts dir arg is empty"
_reload_vault_drift_lib
d="$SANDBOX/t-empty-shipped-arg"; _mk_pair "$d" "$_FETCH_OK" "$_KEYGEN_OK"
_aitf_vault_drift_check "$d/scripts" "" >/dev/null 2>&1
assert_equal "WARN" "$_AITF_VD_STATUS"
assert_contains "$_AITF_VD_MSG" "shipped copies unavailable" && test_pass

test_start "WARN (never PASS) when the shipped vault-keygen.js is missing"
_reload_vault_drift_lib
d="$SANDBOX/t-shipped-keygen-missing"; _mk_pair "$d" "$_FETCH_OK" "$_KEYGEN_OK"
_mk_shipped "$d" "$_FETCH_OK" ""
_aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
assert_equal "WARN" "$_AITF_VD_STATUS"
assert_contains "$_AITF_VD_MSG" "shipped copies unavailable" && test_pass

test_start "WARN (never PASS) when the shipped vault-fetch.js is missing"
_reload_vault_drift_lib
d="$SANDBOX/t-shipped-fetch-missing"; _mk_pair "$d" "$_FETCH_OK" "$_KEYGEN_OK"
_mk_shipped "$d" "" "$_KEYGEN_OK"
_aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
assert_equal "WARN" "$_AITF_VD_STATUS"
assert_contains "$_AITF_VD_MSG" "shipped copies unavailable" && test_pass

test_start "WARN (never a silent PASS) when the installed vault-keygen.js is unreadable"
_reload_vault_drift_lib
d="$SANDBOX/t-installed-unreadable"; _mk_pair "$d" "$_FETCH_OK" "$_KEYGEN_OK"
_mk_shipped "$d" "$_FETCH_OK" "$_KEYGEN_OK"
chmod 000 "$d/scripts/vault-keygen.js"
_aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
chmod 644 "$d/scripts/vault-keygen.js"  # restore so cleanup can remove it
assert_equal "WARN" "$_AITF_VD_STATUS" && test_pass

test_start "PASS message names the shipped-copy comparison, never a JS-parsing heuristic"
_reload_vault_drift_lib
d="$SANDBOX/t-pass-msg"; _mk_pair "$d" "$_FETCH_OK" "$_KEYGEN_OK"
_mk_shipped "$d" "$_FETCH_OK" "$_KEYGEN_OK"
_aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
assert_not_contains "$_AITF_VD_MSG" "kg.*"
assert_not_contains "$_AITF_VD_MSG" "node require" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 2 — both callers exercised (XACA-1322-013: single implementation)
# ═══════════════════════════════════════════════════════════════════════════

# ── 2a: validate-install.sh's _val_check_vault_drift wrapper ───────────────
test_start "validate-install.sh's _val_check_vault_drift renders a PASS from the shared lib"
(
    unset _VALIDATE_INSTALL_SH_LOADED
    # shellcheck source=../libexec/lib/validate-install.sh
    source "$VALIDATE_LIB"
    d="$SANDBOX/wrap-val-pass"
    _mk_pair "$d" "$_FETCH_OK" "$_KEYGEN_OK"
    fw="$SANDBOX/wrap-val-pass-fw"
    mkdir -p "$fw/share/scripts"
    cp "$d/scripts/vault-fetch.js" "$fw/share/scripts/vault-fetch.js"
    cp "$d/scripts/vault-keygen.js" "$fw/share/scripts/vault-keygen.js"
    export AITEAMFORGE_HOME="$fw"
    _val_reset
    _val_check_vault_drift "$d" >/dev/null 2>&1
    echo "STATUS_PASS=$_VAL_PASS STATUS_WARN=$_VAL_WARN STATUS_FAIL=$_VAL_FAIL"
) > "$SANDBOX/wrap-val-pass.out" 2>&1
_wrap_out="$(cat "$SANDBOX/wrap-val-pass.out")"
assert_contains "$_wrap_out" "STATUS_PASS=1 STATUS_WARN=0 STATUS_FAIL=0" && test_pass

test_start "validate-install.sh's _val_check_vault_drift renders a FAIL from the shared lib"
(
    unset _VALIDATE_INSTALL_SH_LOADED
    source "$VALIDATE_LIB"
    d="$SANDBOX/wrap-val-fail"
    _mk_pair "$d" "$_FETCH_OK" "$_KEYGEN_STALE"
    fw="$SANDBOX/wrap-val-fail-fw"
    mkdir -p "$fw/share/scripts"
    cp "$d/scripts/vault-fetch.js" "$fw/share/scripts/vault-fetch.js"
    printf '%s\n' "$_KEYGEN_OK" > "$fw/share/scripts/vault-keygen.js"
    export AITEAMFORGE_HOME="$fw"
    _val_reset
    _val_check_vault_drift "$d" >/dev/null 2>&1
    echo "STATUS_PASS=$_VAL_PASS STATUS_WARN=$_VAL_WARN STATUS_FAIL=$_VAL_FAIL"
) > "$SANDBOX/wrap-val-fail.out" 2>&1
_wrap_out="$(cat "$SANDBOX/wrap-val-fail.out")"
assert_contains "$_wrap_out" "STATUS_PASS=0 STATUS_WARN=0 STATUS_FAIL=1" && test_pass

# ── 2b: aiteamforge-doctor.sh's check_vault_keygen_drift, via its REAL
# extracted function bodies (same seam test-xaca-1097-doctor-phantom-deps.sh
# uses: the command file has main-body side effects, so it cannot be
# `source`d directly -- extract just the functions under test).
_extract_doctor_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$DOCTOR_CMD"
}
DOCTOR_CHECK_RESULT_SRC="$(_extract_doctor_fn check_result)"
DOCTOR_VAULT_CHECK_SRC="$(_extract_doctor_fn check_vault_keygen_drift)"
if [ -z "$DOCTOR_CHECK_RESULT_SRC" ] || [ -z "$DOCTOR_VAULT_CHECK_SRC" ]; then
    echo "FATAL: could not extract check_result/check_vault_keygen_drift from $DOCTOR_CMD" >&2
    _FAIL_COUNT=$((_FAIL_COUNT + 1))
fi

_run_doctor_check() {
    local working_dir_fixture="$1" framework_fixture="$2"
    AITEAMFORGE_DIR="$working_dir_fixture" AITEAMFORGE_HOME="$framework_fixture" LIBEXEC_DIR="$TAP_ROOT/libexec" \
        /bin/bash -c "
        set -eo pipefail
        source '$COMMON_LIB'
        source '$CONFIG_LIB'
        source '$VAULT_DRIFT_LIB'
        TOTAL_CHECKS=0 PASSED_CHECKS=0 FAILED_CHECKS=0 WARNING_CHECKS=0 VERBOSE=false
        $DOCTOR_CHECK_RESULT_SRC
        $DOCTOR_VAULT_CHECK_SRC
        check_vault_keygen_drift
        echo \"DOCTOR_COUNTS pass=\$PASSED_CHECKS warn=\$WARNING_CHECKS fail=\$FAILED_CHECKS\"
    " 2>&1
}

test_start "aiteamforge-doctor.sh's REAL check_vault_keygen_drift reports PASS via the shared lib"
d="$SANDBOX/wrap-doc-pass"
_mk_pair "$d" "$_FETCH_OK" "$_KEYGEN_OK"
fw="$SANDBOX/wrap-doc-pass-fw"; mkdir -p "$fw/share/scripts"
cp "$d/scripts/vault-fetch.js" "$fw/share/scripts/vault-fetch.js"
cp "$d/scripts/vault-keygen.js" "$fw/share/scripts/vault-keygen.js"
_doctor_out="$(_run_doctor_check "$d" "$fw")"
assert_contains "$_doctor_out" "DOCTOR_COUNTS pass=1 warn=0 fail=0" && test_pass

test_start "aiteamforge-doctor.sh's REAL check_vault_keygen_drift reports FAIL via the shared lib, naming the stale file"
d="$SANDBOX/wrap-doc-fail"
_mk_pair "$d" "$_FETCH_OK" "$_KEYGEN_STALE"
fw="$SANDBOX/wrap-doc-fail-fw"; mkdir -p "$fw/share/scripts"
cp "$d/scripts/vault-fetch.js" "$fw/share/scripts/vault-fetch.js"
printf '%s\n' "$_KEYGEN_OK" > "$fw/share/scripts/vault-keygen.js"
_doctor_out="$(_run_doctor_check "$d" "$fw")"
assert_contains "$_doctor_out" "DOCTOR_COUNTS pass=0 warn=0 fail=1"
assert_contains "$_doctor_out" "vault-keygen.js" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 3 — set -e/pipefail caller matrix (XACA-1322-016)
#
# Both real callers of this shared lib run under a caller's
# `set -eo pipefail`. Before XACA-1322-016 a bare, unguarded assignment
# whose command substitution failed could abort the WHOLE calling script
# right here -- silently, with no PASS/WARN/FAIL rendered. The byte-compare
# redesign has far fewer such sites than the old node-probe/lexer version
# (no node resolution, no awk scan to guard), but every remaining `cmp`
# call is still the condition of an `if`, never a bare assignment -- this
# section proves that holds for both real callers, under BOTH shells.
# ═══════════════════════════════════════════════════════════════════════════

_mk_pair "$SANDBOX/sep-identical" "$_FETCH_OK" "$_KEYGEN_OK"
_mk_shipped "$SANDBOX/sep-identical" "$_FETCH_OK" "$_KEYGEN_OK"

_mk_pair "$SANDBOX/sep-differs" "$_FETCH_OK" "$_KEYGEN_STALE"
_mk_shipped "$SANDBOX/sep-differs" "$_FETCH_OK" "$_KEYGEN_OK"

_mk_pair "$SANDBOX/sep-shipmissing" "$_FETCH_OK" "$_KEYGEN_OK"
mkdir -p "$SANDBOX/sep-shipmissing/shipped-empty"

mkdir -p "$SANDBOX/sep-absent/scripts"
mkdir -p "$SANDBOX/sep-absent/shipped"

# _run_doctor_sete <working_dir> <shipped_dir> <shell_bin>
_run_doctor_sete() {
    local working_dir_fixture="$1" shipped_fixture="$2" shell_bin="$3"
    local fw="${working_dir_fixture}-fw-sete"
    mkdir -p "$fw/share/scripts"
    if [ -f "$shipped_fixture/vault-fetch.js" ]; then cp "$shipped_fixture/vault-fetch.js" "$fw/share/scripts/vault-fetch.js"; fi
    if [ -f "$shipped_fixture/vault-keygen.js" ]; then cp "$shipped_fixture/vault-keygen.js" "$fw/share/scripts/vault-keygen.js"; fi
    AITEAMFORGE_DIR="$working_dir_fixture" AITEAMFORGE_HOME="$fw" LIBEXEC_DIR="$TAP_ROOT/libexec" \
        "$shell_bin" -c "
        set -eo pipefail
        source '$COMMON_LIB'
        source '$CONFIG_LIB'
        source '$VAULT_DRIFT_LIB'
        TOTAL_CHECKS=0 PASSED_CHECKS=0 FAILED_CHECKS=0 WARNING_CHECKS=0 VERBOSE=false
        $DOCTOR_CHECK_RESULT_SRC
        $DOCTOR_VAULT_CHECK_SRC
        check_vault_keygen_drift
        echo \"REACHED pass=\$PASSED_CHECKS warn=\$WARNING_CHECKS fail=\$FAILED_CHECKS\"
    " 2>&1
}

# _run_val_sete <install_dir> <shipped_dir> <shell_bin>
_run_val_sete() {
    local install_dir_fixture="$1" shipped_fixture="$2" shell_bin="$3"
    local fw="${install_dir_fixture}-fw-sete"
    mkdir -p "$fw/share/scripts"
    if [ -f "$shipped_fixture/vault-fetch.js" ]; then cp "$shipped_fixture/vault-fetch.js" "$fw/share/scripts/vault-fetch.js"; fi
    if [ -f "$shipped_fixture/vault-keygen.js" ]; then cp "$shipped_fixture/vault-keygen.js" "$fw/share/scripts/vault-keygen.js"; fi
    AITEAMFORGE_HOME="$fw" "$shell_bin" -c "
        set -eo pipefail
        source '$VALIDATE_LIB'
        export AITEAMFORGE_HOME='$fw'
        _val_reset
        _val_check_vault_drift '$install_dir_fixture'
        echo \"REACHED pass=\$_VAL_PASS warn=\$_VAL_WARN fail=\$_VAL_FAIL\"
    " 2>&1
}

# _run_sep_row <slug> <doctor|val> <shell_bin> <install_or_working_dir> <shipped_dir> <expected substring>
_run_sep_row() {
    local slug="$1" caller="$2" shell_bin="$3" wd="$4" shipped="$5" expect="$6"
    local out
    case "$caller" in
        doctor) out="$(_run_doctor_sete "$wd" "$shipped" "$shell_bin")" ;;
        val)    out="$(_run_val_sete "$wd" "$shipped" "$shell_bin")" ;;
    esac
    test_start "set -eo pipefail [$slug/$caller/$shell_bin]: reaches REACHED and reports $expect"
    assert_contains "$out" "REACHED" \
        "aborted before the REACHED sentinel under set -eo pipefail -- this is the exact XACA-1322-016 regression. Output: $out"
    assert_contains "$out" "$expect" \
        "reached but reported the wrong status -- expected to contain '$expect'. Output: $out" \
        && test_pass
}

for _sep_shell in /bin/bash bash; do
    for _sep_caller in doctor val; do
        _run_sep_row "identical"   "$_sep_caller" "$_sep_shell" "$SANDBOX/sep-identical"   "$SANDBOX/sep-identical/shipped"   "pass=1"
        _run_sep_row "differs"     "$_sep_caller" "$_sep_shell" "$SANDBOX/sep-differs"     "$SANDBOX/sep-differs/shipped"     "fail=1"
        _run_sep_row "shipmissing" "$_sep_caller" "$_sep_shell" "$SANDBOX/sep-shipmissing" "$SANDBOX/sep-shipmissing/shipped-empty" "warn=1"
        _run_sep_row "fetchabsent" "$_sep_caller" "$_sep_shell" "$SANDBOX/sep-absent"      "$SANDBOX/sep-absent/shipped"      "pass=0 warn=0 fail=0"
    done
done

# aiteamforge-setup.sh's REAL call convention is
# `validate_installation "${INSTALL_DIR}" || true` (bin/aiteamforge-setup.sh)
# -- tested directly (not just via _val_check_vault_drift) since a
# tester-bot finding named this call path explicitly.
for _sep_shell in /bin/bash bash; do
    test_start "set -eo pipefail via aiteamforge-setup.sh's real 'validate_installation ... || true' convention [$_sep_shell]: reaches the next statement"
    _setup_fw="$SANDBOX/sep-differs-fw-setup"
    mkdir -p "$_setup_fw/share/scripts"
    cp "$SANDBOX/sep-differs/shipped/vault-fetch.js" "$_setup_fw/share/scripts/vault-fetch.js"
    cp "$SANDBOX/sep-differs/shipped/vault-keygen.js" "$_setup_fw/share/scripts/vault-keygen.js"
    _setup_out="$(
        AITEAMFORGE_HOME="$_setup_fw" "$_sep_shell" -c "
            set -eo pipefail
            source '$VALIDATE_LIB'
            export AITEAMFORGE_HOME='$_setup_fw'
            validate_installation '$SANDBOX/sep-differs' || true
            echo REACHED_VIA_SETUP_SH_CONVENTION
        " 2>&1
    )"
    assert_contains "$_setup_out" "REACHED_VIA_SETUP_SH_CONVENTION" \
        "aiteamforge-setup.sh's real call convention (validate_installation ... || true) did not reach its own next statement -- output: $_setup_out" \
        && test_pass
done

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 4 — mutation sentinel
#
# Proves SECTION 1's differs-from-shipped rows are not vacuous: a checker
# whose cmp comparison always lies "identical" (the exact class of defect
# byte-compare exists to prevent -- a fallback that "verifies" nothing) is
# CAUGHT, because overriding cmp to always report success flips a
# differs-from-shipped row's result from FAIL to PASS.
# ═══════════════════════════════════════════════════════════════════════════

test_start "MUTATION SENTINEL: an always-true cmp flips a differs-from-shipped row's result from FAIL to PASS"
_MUTANT_STATUS="$(
    cmp() { return 0; }
    _reload_vault_drift_lib
    d="$SANDBOX/mutant"
    _mk_pair "$d" "$_FETCH_OK" "$_KEYGEN_STALE"
    _mk_shipped "$d" "$_FETCH_OK" "$_KEYGEN_OK"
    _aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
    echo "$_AITF_VD_STATUS"
)"
# The real (unmutated) equivalent of this exact fixture is asserted FAIL by
# "FAIL when installed vault-keygen.js differs from the shipped copy" above.
# Under the mutant it must read PASS instead -- proving that row is
# sensitive to a real regression, not tautological.
assert_equal "PASS" "$_MUTANT_STATUS" \
    "mutant cmp override should have flipped the differs-from-shipped row from FAIL to PASS -- if this doesn't hold, the differs rows above cannot be trusted to catch an always-PASS regression" \
    && test_pass

# ═══════════════════════════════════════════════════════════════════════════
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
fi
exit 0
