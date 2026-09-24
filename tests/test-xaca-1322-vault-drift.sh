#!/bin/bash
# test-xaca-1322-vault-drift.sh
#
# Table-driven regression suite for the vault-fetch.js/vault-keygen.js drift
# checker after PR #965 review (XACA-1322-013/014/015).
#
# BACKGROUND: the checker verifies an installed vault-keygen.js still
# exports every kg.* member the installed vault-fetch.js requires. Before
# this ticket it existed as TWO near-identical copies
# (_val_check_vault_drift in libexec/lib/validate-install.sh,
# check_vault_keygen_drift in libexec/commands/aiteamforge-doctor.sh), both
# hardcoding a single member name (resolveFleetUrl) and both falling back,
# when node is unavailable, to an awk scan for the end of `module.exports`
# that only recognizes a closing brace flush-left at column 0 — which the
# PR #965 tester demonstrated gives a FALSE PASS (indented/one-line exports
# block plus unrelated later text mentioning the name) or a FALSE FAIL (an
# earlier nested flush-left brace truncates the scan before the real
# export).
#
# THE FIX under test here, in libexec/lib/vault-drift.sh:
#   013 — ONE shared implementation (_aitf_vault_drift_check), sourced by
#         both callers, which only render its PASS/WARN/FAIL/SKIP result.
#   014 — the required member set is DERIVED from the installed
#         vault-fetch.js (grep for kg.*), not hardcoded to resolveFleetUrl,
#         so a newly-added kg.* usage is covered without a matching edit
#         to the checker.
#   015 — the no-node fallback does NO JavaScript text parsing at all. It
#         byte-compares (cmp) the installed vault-keygen.js AND
#         vault-fetch.js against the shipped copies. Identical -> PASS.
#         Either differs -> FAIL. Shipped copy missing/unreadable -> WARN,
#         never a silent PASS.
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

_HAVE_NODE=false
command -v node &>/dev/null && _HAVE_NODE=true

# ═══════════════════════════════════════════════════════════════════════════
# Fixture builders
# ═══════════════════════════════════════════════════════════════════════════

# _gen_fetch_js <member> [<member> ...] -> stdout: a vault-fetch.js body that
# references kg.<member>(...) for every member given.
_gen_fetch_js() {
    echo "const kg = require('./vault-keygen');"
    local m
    for m in "$@"; do
        echo "kg.${m}();"
    done
}

# _gen_fetch_js_ref <member> [<member> ...] -> stdout: a vault-fetch.js body
# that references kg.<member> WITHOUT calling it (XACA-1322-019: a
# not-called member only needs to be DEFINED, not a function).
_gen_fetch_js_ref() {
    echo "const kg = require('./vault-keygen');"
    local m
    for m in "$@"; do
        echo "console.log(kg.${m});"
    done
}

# _gen_keygen_js <member> [<member> ...] -> stdout: a vault-keygen.js body
# that exports every member given as a function.
_gen_keygen_js() {
    echo "'use strict';"
    local m
    for m in "$@"; do
        echo "function ${m}() { return null; }"
    done
    echo "module.exports = {"
    for m in "$@"; do
        echo "  ${m},"
    done
    echo "};"
}

# _mk_pair <dir> <fetch_content> <keygen_content>  — writes both files under
# <dir>/scripts/, creating the dir. Omit either content (pass "") to skip
# writing that file.
_mk_pair() {
    local dir="$1" fetch_content="$2" keygen_content="$3"
    mkdir -p "$dir/scripts"
    [ -n "$fetch_content" ] && printf '%s\n' "$fetch_content" > "$dir/scripts/vault-fetch.js"
    [ -n "$keygen_content" ] && printf '%s\n' "$keygen_content" > "$dir/scripts/vault-keygen.js"
}

# The 7 real kg.* members vault-fetch.js uses (XACA-1322-014 finding).
ALL_7_MEMBERS="acceptFleetUrl assertNoRedirect defaultMachineSlug fleetFetchInit readPrivateKey resolveFleetUrl unresolvedFleetUrlMessage"

# shellcheck disable=SC2086
_full_fetch_js="$(_gen_fetch_js $ALL_7_MEMBERS)"
# shellcheck disable=SC2086
_full_keygen_js="$(_gen_keygen_js $ALL_7_MEMBERS)"

_reload_vault_drift_lib() {
    unset _VAULT_DRIFT_SH_LOADED
    # shellcheck source=../libexec/lib/vault-drift.sh
    source "$VAULT_DRIFT_LIB"
}

# _scan <fetch_js_path> -> stdout: raw _aitf_vd_scan_kg_usage output
# (M:CALLED:/M:NOTCALLED:/U: lines), against a freshly reloaded lib.
_scan() {
    _reload_vault_drift_lib
    _aitf_vd_scan_kg_usage "$1"
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 1 — _aitf_vault_drift_check core contract (SKIP/FAIL-missing/WARN)
# ═══════════════════════════════════════════════════════════════════════════

test_start "SKIP when vault-fetch.js is not installed"
_reload_vault_drift_lib
d="$SANDBOX/t1"; mkdir -p "$d/scripts"
_aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
assert_equal "SKIP" "$_AITF_VD_STATUS" && test_pass

test_start "FAIL when vault-keygen.js is missing entirely, message names the upgrade remedy"
_reload_vault_drift_lib
d="$SANDBOX/t2"; _mk_pair "$d" "$_full_fetch_js" ""
_aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
assert_equal "FAIL" "$_AITF_VD_STATUS"
assert_contains "$_AITF_VD_MSG" "aiteamforge upgrade" && test_pass

test_start "WARN (never PASS) when nothing can be derived from vault-fetch.js"
_reload_vault_drift_lib
d="$SANDBOX/t3"; _mk_pair "$d" "// no kg.* references at all" "$_full_keygen_js"
_aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
assert_equal "WARN" "$_AITF_VD_STATUS" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 2 — node-probe primary check (derived required set, XACA-1322-014)
# ═══════════════════════════════════════════════════════════════════════════

if [ "$_HAVE_NODE" = true ]; then
    test_start "node probe: all 7 real kg.* members present -> PASS"
    _reload_vault_drift_lib
    d="$SANDBOX/t4"; _mk_pair "$d" "$_full_fetch_js" "$_full_keygen_js"
    _aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
    assert_equal "PASS" "$_AITF_VD_STATUS" && test_pass

    test_start "node probe: one of the 7 missing -> FAIL naming it"
    _reload_vault_drift_lib
    d="$SANDBOX/t5"
    # shellcheck disable=SC2086
    _stub_missing_one="$(_gen_keygen_js acceptFleetUrl assertNoRedirect defaultMachineSlug fleetFetchInit readPrivateKey resolveFleetUrl)"
    _mk_pair "$d" "$_full_fetch_js" "$_stub_missing_one"
    _aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
    assert_equal "FAIL" "$_AITF_VD_STATUS"
    assert_contains "$_AITF_VD_MSG" "unresolvedFleetUrlMessage" && test_pass

    test_start "node probe: pre-XACA-0972 stub (generateKeypair only, no resolveFleetUrl) -> FAIL"
    _reload_vault_drift_lib
    d="$SANDBOX/t6"
    _mk_pair "$d" "$(_gen_fetch_js resolveFleetUrl)" "$(_gen_keygen_js generateKeypair)"
    _aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
    assert_equal "FAIL" "$_AITF_VD_STATUS"
    assert_contains "$_AITF_VD_MSG" "resolveFleetUrl is not a function"
    assert_contains "$_AITF_VD_MSG" "aiteamforge upgrade" && test_pass

    test_start "node probe: vault-fetch.js references a NEW kg.fooBar the keygen lacks -> FAIL (proves 014 -- derived, not hardcoded)"
    _reload_vault_drift_lib
    d="$SANDBOX/t7"
    _mk_pair "$d" "$(_gen_fetch_js resolveFleetUrl brandNewFutureMember)" "$(_gen_keygen_js resolveFleetUrl)"
    _aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
    assert_equal "FAIL" "$_AITF_VD_STATUS"
    assert_contains "$_AITF_VD_MSG" "brandNewFutureMember" && test_pass

    test_start "node probe: require() throws (unrelated dep) + shipped copy ABSENT -> WARN, never PASS or FAIL off the throw"
    _reload_vault_drift_lib
    d="$SANDBOX/t8"
    _throwing_keygen="require('totally-does-not-exist-xaca-1322-fixture');
$(_gen_keygen_js resolveFleetUrl)"
    _mk_pair "$d" "$(_gen_fetch_js resolveFleetUrl)" "$_throwing_keygen"
    _aitf_vault_drift_check "$d/scripts" "$d/nonexistent-shipped" >/dev/null 2>&1
    assert_equal "WARN" "$_AITF_VD_STATUS" && test_pass

    test_start "node probe: require() throws (unrelated dep) + shipped copy MATCHES installed -> falls through to fallback -> PASS"
    _reload_vault_drift_lib
    d="$SANDBOX/t9"
    _mk_pair "$d" "$(_gen_fetch_js resolveFleetUrl)" "$_throwing_keygen"
    cp "$d/scripts/vault-fetch.js" "$d/scripts/vault-fetch.js.bak"
    mkdir -p "$d/shipped"
    cp "$d/scripts/vault-fetch.js" "$d/shipped/vault-fetch.js"
    cp "$d/scripts/vault-keygen.js" "$d/shipped/vault-keygen.js"
    _aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
    assert_equal "PASS" "$_AITF_VD_STATUS" && test_pass
else
    echo "    SKIP: node not resolvable on this machine/runner -- node-probe-specific assertions skipped (fallback assertions below still run against a stripped PATH)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 3 — no-node fallback: byte-compare against shipped copy
# (XACA-1322-015 -- replaces the awk/grep static scan entirely)
# ═══════════════════════════════════════════════════════════════════════════

_NO_NODE_PATH="/usr/bin:/bin"

# Every variant below reproduces one of the ds9-tester-bot's PR #965
# adversarial shapes. Under the OLD awk-based fallback these gave a FALSE
# PASS or FALSE FAIL depending on brace placement. Under the NEW
# byte-compare fallback, the JS shape is irrelevant -- only whether the
# bytes match the shipped copy decides the result.
_variant_indented_brace_no_match="function generateKeypair() { return {}; }
module.exports = {
    generateKeypair
    };
"
_variant_indented_brace_false_match="function generateKeypair() { return {}; }
module.exports = {
    generateKeypair
    };
// TODO: add resolveFleetUrl here eventually
"
_variant_one_line_exports_false_match="function generateKeypair() { return {}; }
module.exports = { generateKeypair };
// resolveFleetUrl not implemented yet
"
_variant_nested_brace_real_export="function generateKeypair() {
  return {};
}
function resolveFleetUrl() { return null; }
module.exports = {
  generateKeypair: function() {
    return {};
  },
  resolveFleetUrl,
};
"

_run_fallback_row() {
    # $1 = description slug, $2 = installed keygen content,
    # $3 = shipped keygen content, $4 = expected status (PASS|FAIL)
    local slug="$1" installed="$2" shipped="$3" expect="$4"
    test_start "no-node fallback [$slug]: cmp-determined result is $expect"
    _reload_vault_drift_lib
    local d="$SANDBOX/fb-$slug"
    _mk_pair "$d" "$(_gen_fetch_js resolveFleetUrl)" "$installed"
    mkdir -p "$d/shipped"
    cp "$d/scripts/vault-fetch.js" "$d/shipped/vault-fetch.js"
    printf '%s\n' "$shipped" > "$d/shipped/vault-keygen.js"
    local _saved_path="$PATH"
    PATH="$_NO_NODE_PATH"
    _aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
    PATH="$_saved_path"
    assert_equal "$expect" "$_AITF_VD_STATUS" && test_pass
}

# Identical to shipped -> PASS, regardless of how confusing the JS shape is.
_run_fallback_row "indented-brace-no-match-identical" \
    "$_variant_indented_brace_no_match" "$_variant_indented_brace_no_match" "PASS"
_run_fallback_row "indented-brace-false-match-identical" \
    "$_variant_indented_brace_false_match" "$_variant_indented_brace_false_match" "PASS"
_run_fallback_row "one-line-exports-false-match-identical" \
    "$_variant_one_line_exports_false_match" "$_variant_one_line_exports_false_match" "PASS"
_run_fallback_row "nested-brace-real-export-identical" \
    "$_variant_nested_brace_real_export" "$_variant_nested_brace_real_export" "PASS"

# Differs from shipped -> FAIL, even the variant where a naive text scan
# would have found "resolveFleetUrl" and said PASS (variant 2/3), and even
# the variant a naive scan would have wrongly FAILed on its own file
# (variant 4, real export truncated by the nested brace) -- because the
# comparison basis is now bytes-vs-shipped, not JS structure.
_run_fallback_row "indented-brace-false-match-differs" \
    "$_variant_indented_brace_false_match" "$_variant_nested_brace_real_export" "FAIL"
_run_fallback_row "one-line-exports-false-match-differs" \
    "$_variant_one_line_exports_false_match" "$_variant_indented_brace_no_match" "FAIL"
_run_fallback_row "nested-brace-real-export-differs" \
    "$_variant_nested_brace_real_export" "$_variant_indented_brace_no_match" "FAIL"
_run_fallback_row "indented-brace-no-match-differs" \
    "$_variant_indented_brace_no_match" "$_variant_one_line_exports_false_match" "FAIL"

test_start "no-node fallback: shipped scripts dir absent -> WARN, never a silent PASS"
_reload_vault_drift_lib
d="$SANDBOX/fb-shipped-absent"
_mk_pair "$d" "$(_gen_fetch_js resolveFleetUrl)" "$_variant_indented_brace_no_match"
_saved_path="$PATH"; PATH="$_NO_NODE_PATH"
_aitf_vault_drift_check "$d/scripts" "$d/nonexistent-shipped" >/dev/null 2>&1
PATH="$_saved_path"
assert_equal "WARN" "$_AITF_VD_STATUS" && test_pass

test_start "no-node fallback: vault-keygen.js unreadable -> WARN, never a silent PASS"
_reload_vault_drift_lib
d="$SANDBOX/fb-unreadable"
_mk_pair "$d" "$(_gen_fetch_js resolveFleetUrl)" "$_variant_indented_brace_no_match"
mkdir -p "$d/shipped"
cp "$d/scripts/vault-fetch.js" "$d/shipped/vault-fetch.js"
cp "$d/scripts/vault-keygen.js" "$d/shipped/vault-keygen.js"
chmod 000 "$d/scripts/vault-keygen.js"
_saved_path="$PATH"; PATH="$_NO_NODE_PATH"
_aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
PATH="$_saved_path"
chmod 644 "$d/scripts/vault-keygen.js"
assert_equal "WARN" "$_AITF_VD_STATUS" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 4 — both callers exercised (XACA-1322-013: single implementation)
# ═══════════════════════════════════════════════════════════════════════════

# ── 4a: validate-install.sh's _val_check_vault_drift wrapper ───────────────
# Both tests seed a shipped-copy fixture too (matching for the PASS case,
# the full valid set for the FAIL case) so the assertion holds regardless
# of whether node is resolvable on the machine/runner executing this suite
# -- i.e. it is correct whichever of the two internal paths (node probe or
# no-node fallback) the shared lib actually takes here.
test_start "validate-install.sh's _val_check_vault_drift renders a PASS from the shared lib"
(
    unset _VALIDATE_INSTALL_SH_LOADED
    # shellcheck source=../libexec/lib/validate-install.sh
    source "$VALIDATE_LIB"
    d="$SANDBOX/wrap-val-pass"
    _mk_pair "$d" "$_full_fetch_js" "$_full_keygen_js"
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
    _mk_pair "$d" "$(_gen_fetch_js resolveFleetUrl)" "$(_gen_keygen_js generateKeypair)"
    fw="$SANDBOX/wrap-val-fail-fw"
    mkdir -p "$fw/share/scripts"
    cp "$d/scripts/vault-fetch.js" "$fw/share/scripts/vault-fetch.js"
    printf '%s\n' "$(_gen_keygen_js resolveFleetUrl)" > "$fw/share/scripts/vault-keygen.js"
    export AITEAMFORGE_HOME="$fw"
    _val_reset
    _val_check_vault_drift "$d" >/dev/null 2>&1
    echo "STATUS_PASS=$_VAL_PASS STATUS_WARN=$_VAL_WARN STATUS_FAIL=$_VAL_FAIL"
) > "$SANDBOX/wrap-val-fail.out" 2>&1
_wrap_out="$(cat "$SANDBOX/wrap-val-fail.out")"
assert_contains "$_wrap_out" "STATUS_PASS=0 STATUS_WARN=0 STATUS_FAIL=1" && test_pass

# ── 4b: aiteamforge-doctor.sh's check_vault_keygen_drift, via its REAL
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
_mk_pair "$d" "$_full_fetch_js" "$_full_keygen_js"
fw="$SANDBOX/wrap-doc-pass-fw"; mkdir -p "$fw/share/scripts"
cp "$d/scripts/vault-fetch.js" "$fw/share/scripts/vault-fetch.js"
cp "$d/scripts/vault-keygen.js" "$fw/share/scripts/vault-keygen.js"
_doctor_out="$(_run_doctor_check "$d" "$fw")"
assert_contains "$_doctor_out" "DOCTOR_COUNTS pass=1 warn=0 fail=0" && test_pass

test_start "aiteamforge-doctor.sh's REAL check_vault_keygen_drift reports FAIL via the shared lib, naming the missing member"
d="$SANDBOX/wrap-doc-fail"
_mk_pair "$d" "$(_gen_fetch_js resolveFleetUrl)" "$(_gen_keygen_js generateKeypair)"
fw="$SANDBOX/wrap-doc-fail-fw"; mkdir -p "$fw/share/scripts"
cp "$d/scripts/vault-fetch.js" "$fw/share/scripts/vault-fetch.js"
printf '%s\n' "$(_gen_keygen_js resolveFleetUrl)" > "$fw/share/scripts/vault-keygen.js"
_doctor_out="$(_run_doctor_check "$d" "$fw")"
assert_contains "$_doctor_out" "DOCTOR_COUNTS pass=0 warn=0 fail=1"
assert_contains "$_doctor_out" "resolveFleetUrl" && test_pass

# ── 4c: doctor's richer PATH-aware node resolver (_x1097_resolve) is
# preferred over the plain `command -v node` fallback when the sourcing
# shell defines it (design requirement: "use doctor's existing PATH-aware
# node resolution _x1097_resolve where available, otherwise command -v
# node"). None of the tests above exercise this branch -- doctor's real
# _x1097_resolve was never extracted into their sandboxes, so
# _aitf_vd_resolve_node always took the "otherwise" arm. This test stubs
# _x1097_resolve directly to prove the "where available" arm is reachable
# and actually used.
test_start "_aitf_vd_resolve_node prefers _x1097_resolve over plain 'command -v node' when the caller defines it"
_STUBBED_NODE_PATH="$(command -v node 2>/dev/null || echo /nonexistent-node)"
_RESOLVE_NODE_RESULT="$(
    _x1097_resolve() { [ "$1" = "node" ] && echo "$_STUBBED_NODE_PATH-STUBBED"; }
    _reload_vault_drift_lib
    _aitf_vd_resolve_node
)"
assert_contains "$_RESOLVE_NODE_RESULT" "-STUBBED" \
    "_aitf_vd_resolve_node must call _x1097_resolve when the sourcing shell defines it, not fall through to plain 'command -v node'" \
    && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 5 — mutation sentinel
#
# Proves the table rows above are not vacuous: a fallback that always lies
# PASS (the exact defect class XACA-1322-015 fixed -- a wrong-result
# fallback that "verifies" nothing) is CAUGHT by the differs-from-shipped
# rows, because overriding cmp to always report "identical" flips their
# result from FAIL to PASS.
# ═══════════════════════════════════════════════════════════════════════════

test_start "MUTATION SENTINEL: an always-true cmp (fallback that always lies PASS) flips a differs-from-shipped row's result"
_MUTANT_STATUS="$(
    cmp() { return 0; }
    _reload_vault_drift_lib
    d="$SANDBOX/mutant"
    _mk_pair "$d" "$(_gen_fetch_js resolveFleetUrl)" "$_variant_indented_brace_false_match"
    mkdir -p "$d/shipped"
    cp "$d/scripts/vault-fetch.js" "$d/shipped/vault-fetch.js"
    printf '%s\n' "$_variant_nested_brace_real_export" > "$d/shipped/vault-keygen.js"
    _saved_path="$PATH"; PATH="$_NO_NODE_PATH"
    _aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
    PATH="$_saved_path"
    echo "$_AITF_VD_STATUS"
)"
# The real (unmutated) equivalent of this exact fixture is asserted FAIL by
# "no-node fallback [indented-brace-false-match-differs]: cmp-determined
# result is FAIL" above. Under the mutant it must read PASS instead --
# proving that row is sensitive to a real regression, not tautological.
assert_equal "PASS" "$_MUTANT_STATUS" \
    "mutant cmp override should have flipped the differs-from-shipped row from FAIL to PASS -- if this doesn't hold, the table rows above cannot be trusted to catch an always-PASS fallback regression" \
    && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 6 — derivation edge cases (PR #965 round 2: XACA-1322-017/018/019)
#
# 017 — left-boundary: pkg.version / _kg.x / obj.kg.x must NOT count, but
#       the real `...kg.fleetFetchInit()` spread shape must.
# 018 — comments (//, single-line /* */, multi-line /* */) are stripped
#       before scanning, so a mere mention is never counted; and
#       bracket/computed access, destructuring, and aliasing are flagged
#       as an unrecognized pattern (WARN), never silently ignored.
# 019 — a member vault-fetch.js CALLS must be a function; a member it only
#       references (never calls) just needs to be defined.
# ═══════════════════════════════════════════════════════════════════════════

test_start "derivation: pkg.version / _kg.x / obj.kg.x are NOT counted (XACA-1322-017 left-boundary)"
d="$SANDBOX/deriv-boundary.js"
cat > "$d" <<'EOF_JS'
const kg = require('./vault-keygen');
const v = pkg.version;
const w = obj.kg.x;
const z = _kg.x;
kg.resolveFleetUrl();
EOF_JS
_scan_out="$(_scan "$d")"
assert_equal "M:CALLED:resolveFleetUrl" "$_scan_out" \
    "boundary-excluded occurrences (pkg./_kg./obj.kg.) leaked into the derived set: $_scan_out" && test_pass

test_start "derivation: '...kg.fleetFetchInit()' spread is counted as CALLED (XACA-1322-017 spread exception)"
d="$SANDBOX/deriv-spread.js"
cat > "$d" <<'EOF_JS'
const kg = require('./vault-keygen');
foo({ ...kg.fleetFetchInit(), signal: 1 });
EOF_JS
_scan_out="$(_scan "$d")"
assert_equal "M:CALLED:fleetFetchInit" "$_scan_out" \
    "the real spread shape used in vault-fetch.js was not counted: $_scan_out" && test_pass

test_start "derivation: a // line-comment mention of kg.futureMember is NOT counted (XACA-1322-018)"
d="$SANDBOX/deriv-comment-line.js"
cat > "$d" <<'EOF_JS'
const kg = require('./vault-keygen');
kg.resolveFleetUrl();
// TODO: use kg.futureMember() here later
EOF_JS
_scan_out="$(_scan "$d")"
assert_equal "M:CALLED:resolveFleetUrl" "$_scan_out" \
    "a // line-comment mention leaked into the derived set: $_scan_out" && test_pass

test_start "derivation: a single-line /* */ block-comment mention of kg.anotherFuture is NOT counted (XACA-1322-018)"
d="$SANDBOX/deriv-comment-block1.js"
cat > "$d" <<'EOF_JS'
const kg = require('./vault-keygen');
kg.resolveFleetUrl();
/* also mentions kg.anotherFuture() */
EOF_JS
_scan_out="$(_scan "$d")"
assert_equal "M:CALLED:resolveFleetUrl" "$_scan_out" \
    "a single-line block-comment mention leaked into the derived set: $_scan_out" && test_pass

test_start "derivation: a multi-line /* */ block-comment mention of kg.thirdFuture is NOT counted (XACA-1322-018)"
d="$SANDBOX/deriv-comment-block2.js"
cat > "$d" <<'EOF_JS'
const kg = require('./vault-keygen');
kg.resolveFleetUrl();
/* multi
   line kg.thirdFuture()
   comment */
EOF_JS
_scan_out="$(_scan "$d")"
assert_equal "M:CALLED:resolveFleetUrl" "$_scan_out" \
    "a multi-line block-comment mention leaked into the derived set: $_scan_out" && test_pass

test_start "derivation: kg['acceptFleetUrl'](...) bracket/computed access is flagged unrecognized (XACA-1322-018)"
d="$SANDBOX/deriv-bracket.js"
cat > "$d" <<'EOF_JS'
const kg = require('./vault-keygen');
kg.resolveFleetUrl();
const a = kg['acceptFleetUrl'](1);
EOF_JS
_scan_out="$(_scan "$d")"
assert_contains "$_scan_out" "M:CALLED:resolveFleetUrl" "real call missing from scan: $_scan_out"
assert_contains "$_scan_out" "U:bracket" "kg['x'] bracket access was not flagged unrecognized: $_scan_out" && test_pass

test_start "derivation: 'const {a} = kg' destructuring is flagged unrecognized (XACA-1322-018)"
d="$SANDBOX/deriv-destructure.js"
cat > "$d" <<'EOF_JS'
const kg = require('./vault-keygen');
kg.resolveFleetUrl();
const {a} = kg;
EOF_JS
_scan_out="$(_scan "$d")"
assert_contains "$_scan_out" "M:CALLED:resolveFleetUrl" "real call missing from scan: $_scan_out"
assert_contains "$_scan_out" "U:destructur" "destructuring from kg was not flagged unrecognized: $_scan_out" && test_pass

test_start "derivation: 'const k = kg;' aliasing is flagged unrecognized (XACA-1322-018)"
d="$SANDBOX/deriv-alias.js"
cat > "$d" <<'EOF_JS'
const kg = require('./vault-keygen');
kg.resolveFleetUrl();
const k = kg;
EOF_JS
_scan_out="$(_scan "$d")"
assert_contains "$_scan_out" "M:CALLED:resolveFleetUrl" "real call missing from scan: $_scan_out"
assert_contains "$_scan_out" "U:kg aliased" "kg aliasing was not flagged unrecognized: $_scan_out" && test_pass

test_start "derivation against the REAL shipped share/scripts/vault-fetch.js: exact 7-member CALLED set, zero unrecognized patterns (XACA-1322-014/017/018)"
_scan_out="$(_scan "$TAP_ROOT/share/scripts/vault-fetch.js")"
# shellcheck disable=SC2086
_expected_sorted="$(printf '%s\n' $ALL_7_MEMBERS | sed 's/^/M:CALLED:/' | sort)"
_actual_sorted="$(printf '%s\n' "$_scan_out" | sort)"
assert_equal "$_expected_sorted" "$_actual_sorted" \
    "derivation against the real vault-fetch.js did not produce exactly the known 7 CALLED members with no unrecognized patterns -- got: $_scan_out" && test_pass

if [ "$_HAVE_NODE" = true ]; then
    for _bad_kind in null string object; do
        test_start "node probe: a CALLED member exported as $_bad_kind (not a function) -> FAIL (XACA-1322-019)"
        _reload_vault_drift_lib
        d="$SANDBOX/deriv-notfunc-$_bad_kind"
        _mk_pair "$d" "$(_gen_fetch_js resolveFleetUrl)" ""
        case "$_bad_kind" in
            null)   printf '%s\n' "module.exports = { resolveFleetUrl: null };" > "$d/scripts/vault-keygen.js" ;;
            string) printf '%s\n' "module.exports = { resolveFleetUrl: 'not-a-fn' };" > "$d/scripts/vault-keygen.js" ;;
            object) printf '%s\n' "module.exports = { resolveFleetUrl: {} };" > "$d/scripts/vault-keygen.js" ;;
        esac
        _aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
        assert_equal "FAIL" "$_AITF_VD_STATUS" \
            "a CALLED member exported as $_bad_kind (not a function) must FAIL -- this is the exact crash class XACA-1322 exists to catch, got: $_AITF_VD_STATUS / $_AITF_VD_MSG"
        assert_contains "$_AITF_VD_MSG" "resolveFleetUrl" && test_pass
    done

    test_start "node probe: a NOT-called member exported as a plain string -> PASS (presence-only requirement, XACA-1322-019)"
    _reload_vault_drift_lib
    d="$SANDBOX/deriv-notcalled-string"
    mkdir -p "$d/scripts"
    printf '%s\n' "$(_gen_fetch_js_ref readPrivateKey)" > "$d/scripts/vault-fetch.js"
    printf '%s\n' "module.exports = { readPrivateKey: 'not-a-function-but-never-called' };" > "$d/scripts/vault-keygen.js"
    _aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
    assert_equal "PASS" "$_AITF_VD_STATUS" \
        "a NOT-called member exported as a non-function must still PASS -- vault-fetch.js never invokes it, got: $_AITF_VD_STATUS / $_AITF_VD_MSG" && test_pass

    test_start "full check: an unrecognized bracket access downgrades an otherwise-PASS node-probe result to WARN, never silently PASS (XACA-1322-018)"
    _reload_vault_drift_lib
    d="$SANDBOX/deriv-full-warn"
    mkdir -p "$d/scripts"
    cat > "$d/scripts/vault-fetch.js" <<'EOF_JS'
const kg = require('./vault-keygen');
kg.resolveFleetUrl();
const a = kg['acceptFleetUrl'](1);
EOF_JS
    printf '%s\n' "$(_gen_keygen_js resolveFleetUrl acceptFleetUrl)" > "$d/scripts/vault-keygen.js"
    _aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
    assert_equal "WARN" "$_AITF_VD_STATUS" \
        "an unrecognized access pattern alongside an otherwise-PASS node probe must downgrade to WARN, not stay PASS -- got: $_AITF_VD_STATUS / $_AITF_VD_MSG"
    assert_contains "$_AITF_VD_MSG" "could not fully verify" && test_pass
else
    echo "    SKIP: node not resolvable on this machine/runner -- 019/018-downgrade node-probe assertions skipped"
fi

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 7 — set -e/pipefail caller matrix (XACA-1322-016)
#
# Both real callers of this shared lib (doctor's check_vault_keygen_drift,
# validate-install's _val_check_vault_drift) run under a caller's
# `set -eo pipefail`. Before this fix, a bare `node_bin=$(...)` (no node
# resolvable) or a bare `required_members=$(...)` (no kg.* references, so
# the derivation pipe's grep exits 1 under pipefail) aborted the WHOLE
# calling script right here -- silently, with no PASS/WARN/FAIL rendered,
# and (in doctor's case) no further checks or summary.
#
# Every row below runs the REAL extracted function bodies (same seam
# test-xaca-1097-doctor-phantom-deps.sh uses -- the command file has
# main-body side effects, so it cannot be `source`d directly) under
# `set -eo pipefail` with PATH stripped to exclude node, and asserts BOTH
# that a REACHED sentinel prints (the calling script did not abort) AND
# that the expected status was reported. Every row runs under BOTH
# /bin/bash and PATH bash.
# ═══════════════════════════════════════════════════════════════════════════

_sep_fetch="$(_gen_fetch_js resolveFleetUrl)"
_sep_keygen_ok="$(_gen_keygen_js resolveFleetUrl)"
_sep_keygen_stale="$(_gen_keygen_js generateKeypair)"

# identical -> PASS (no-node fallback byte-compare)
_mk_pair "$SANDBOX/sep-identical" "$_sep_fetch" "$_sep_keygen_ok"
mkdir -p "$SANDBOX/sep-identical-fw/share/scripts"
printf '%s\n' "$_sep_fetch" > "$SANDBOX/sep-identical-fw/share/scripts/vault-fetch.js"
printf '%s\n' "$_sep_keygen_ok" > "$SANDBOX/sep-identical-fw/share/scripts/vault-keygen.js"

# differs -> FAIL (no-node fallback byte-compare)
_mk_pair "$SANDBOX/sep-differs" "$_sep_fetch" "$_sep_keygen_stale"
mkdir -p "$SANDBOX/sep-differs-fw/share/scripts"
printf '%s\n' "$_sep_fetch" > "$SANDBOX/sep-differs-fw/share/scripts/vault-fetch.js"
printf '%s\n' "$_sep_keygen_ok" > "$SANDBOX/sep-differs-fw/share/scripts/vault-keygen.js"

# shipped copy missing -> WARN
_mk_pair "$SANDBOX/sep-shipmissing" "$_sep_fetch" "$_sep_keygen_ok"
mkdir -p "$SANDBOX/sep-shipmissing-fw"

# no kg.* references at all -> WARN (variant B: the derivation pipe itself
# has nothing to emit -- this is the "grep exits 1 under pipefail" trigger)
mkdir -p "$SANDBOX/sep-nokg/scripts"
printf '%s\n%s\n' "// no kg.* references at all" "console.log(1);" > "$SANDBOX/sep-nokg/scripts/vault-fetch.js"
printf '%s\n' "$_sep_keygen_ok" > "$SANDBOX/sep-nokg/scripts/vault-keygen.js"
mkdir -p "$SANDBOX/sep-nokg-fw/share/scripts"
printf '%s\n' "$_sep_fetch" > "$SANDBOX/sep-nokg-fw/share/scripts/vault-fetch.js"
printf '%s\n' "$_sep_keygen_ok" > "$SANDBOX/sep-nokg-fw/share/scripts/vault-keygen.js"

# vault-fetch.js not installed at all -> SKIP (both callers return early,
# before even resolving node -- included to confirm it stays harmless too)
mkdir -p "$SANDBOX/sep-absent/scripts"
mkdir -p "$SANDBOX/sep-absent-fw/share/scripts"

# _run_doctor_nonode <working_dir> <framework_dir> <shell_bin> [<vault_drift_lib>]
_run_doctor_nonode() {
    local working_dir_fixture="$1" framework_fixture="$2" shell_bin="$3" vd_lib="${4:-$VAULT_DRIFT_LIB}"
    AITEAMFORGE_DIR="$working_dir_fixture" AITEAMFORGE_HOME="$framework_fixture" LIBEXEC_DIR="$TAP_ROOT/libexec" \
        PATH="/usr/bin:/bin" "$shell_bin" -c "
        set -eo pipefail
        source '$COMMON_LIB'
        source '$CONFIG_LIB'
        source '$vd_lib'
        TOTAL_CHECKS=0 PASSED_CHECKS=0 FAILED_CHECKS=0 WARNING_CHECKS=0 VERBOSE=false
        $DOCTOR_CHECK_RESULT_SRC
        $DOCTOR_VAULT_CHECK_SRC
        check_vault_keygen_drift
        echo \"REACHED pass=\$PASSED_CHECKS warn=\$WARNING_CHECKS fail=\$FAILED_CHECKS\"
    " 2>&1
}

# _run_val_nonode <install_dir> <framework_dir> <shell_bin>
# validate-install.sh self-sources ITS OWN libexec/lib/vault-drift.sh (see
# its header) -- unlike the doctor helper above there is no separate lib
# path to inject, so this always exercises the real on-disk file, same as
# SECTION 4a above.
_run_val_nonode() {
    local install_dir_fixture="$1" framework_fixture="$2" shell_bin="$3"
    AITEAMFORGE_HOME="$framework_fixture" PATH="/usr/bin:/bin" "$shell_bin" -c "
        set -eo pipefail
        source '$VALIDATE_LIB'
        export AITEAMFORGE_HOME='$framework_fixture'
        _val_reset
        _val_check_vault_drift '$install_dir_fixture'
        echo \"REACHED pass=\$_VAL_PASS warn=\$_VAL_WARN fail=\$_VAL_FAIL\"
    " 2>&1
}

# _run_sep_row <slug> <doctor|val> <shell_bin> <wd> <fw> <expected substring>
_run_sep_row() {
    local slug="$1" caller="$2" shell_bin="$3" wd="$4" fw="$5" expect="$6"
    local out
    case "$caller" in
        doctor) out="$(_run_doctor_nonode "$wd" "$fw" "$shell_bin")" ;;
        val)    out="$(_run_val_nonode "$wd" "$fw" "$shell_bin")" ;;
    esac
    test_start "set -eo pipefail [$slug/$caller/$shell_bin, no node]: reaches REACHED and reports $expect"
    assert_contains "$out" "REACHED" \
        "aborted before the REACHED sentinel under set -eo pipefail with no node on PATH -- this is the exact XACA-1322-016 regression. Output: $out"
    assert_contains "$out" "$expect" \
        "reached but reported the wrong status -- expected to contain '$expect'. Output: $out" \
        && test_pass
}

for _sep_shell in /bin/bash bash; do
    for _sep_caller in doctor val; do
        _run_sep_row "identical"   "$_sep_caller" "$_sep_shell" "$SANDBOX/sep-identical"   "$SANDBOX/sep-identical-fw"   "pass=1"
        _run_sep_row "differs"     "$_sep_caller" "$_sep_shell" "$SANDBOX/sep-differs"     "$SANDBOX/sep-differs-fw"     "fail=1"
        _run_sep_row "shipmissing" "$_sep_caller" "$_sep_shell" "$SANDBOX/sep-shipmissing" "$SANDBOX/sep-shipmissing-fw" "warn=1"
        _run_sep_row "nokg"        "$_sep_caller" "$_sep_shell" "$SANDBOX/sep-nokg"        "$SANDBOX/sep-nokg-fw"        "warn=1"
        _run_sep_row "fetchabsent" "$_sep_caller" "$_sep_shell" "$SANDBOX/sep-absent"      "$SANDBOX/sep-absent-fw"      "pass=0 warn=0 fail=0"
    done
done

# aiteamforge-setup.sh's REAL call convention is
# `validate_installation "${INSTALL_DIR}" || true` (bin/aiteamforge-setup.sh)
# -- tested directly (not just via _val_check_vault_drift) since a
# tester-bot finding named this call path explicitly.
for _sep_shell in /bin/bash bash; do
    test_start "set -eo pipefail via aiteamforge-setup.sh's real 'validate_installation ... || true' convention [$_sep_shell, no node]: reaches the next statement"
    _setup_out="$(
        AITEAMFORGE_HOME="$SANDBOX/sep-differs-fw" PATH="/usr/bin:/bin" "$_sep_shell" -c "
            set -eo pipefail
            source '$VALIDATE_LIB'
            export AITEAMFORGE_HOME='$SANDBOX/sep-differs-fw'
            validate_installation '$SANDBOX/sep-differs' || true
            echo REACHED_VIA_SETUP_SH_CONVENTION
        " 2>&1
    )"
    assert_contains "$_setup_out" "REACHED_VIA_SETUP_SH_CONVENTION" \
        "aiteamforge-setup.sh's real call convention (validate_installation ... || true) did not reach its own next statement -- output: $_setup_out" \
        && test_pass
done

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 8 — mutation sentinel (set -e class, XACA-1322-016)
#
# Proves SECTION 7's rows are not vacuous: patching out the
# `|| node_bin=""` guard reintroduces the exact bare-assignment-under-
# set-e hazard the fix closes, and a no-node REACHED row must then fail to
# reach its sentinel.
# ═══════════════════════════════════════════════════════════════════════════

_MUTANT_VD_LIB="$SANDBOX/vault-drift-mutant.sh"
sed 's/node_bin="\$(_aitf_vd_resolve_node)" || node_bin=""/node_bin="$(_aitf_vd_resolve_node)"/' "$VAULT_DRIFT_LIB" > "$_MUTANT_VD_LIB"

test_start "MUTATION SENTINEL (set -e class): the patched temp copy actually differs from the real lib"
if diff -q "$VAULT_DRIFT_LIB" "$_MUTANT_VD_LIB" >/dev/null 2>&1; then
    test_fail "mutant lib is IDENTICAL to the real lib -- the sed substitution did not match the guard; every row below would be vacuous"
else
    test_pass
fi

for _sep_shell in /bin/bash bash; do
    test_start "MUTATION SENTINEL [$_sep_shell]: removing '|| node_bin=\"\"' makes a no-node REACHED row fail (proves SECTION 7 is not vacuous)"
    _mutant_out="$(_run_doctor_nonode "$SANDBOX/sep-differs" "$SANDBOX/sep-differs-fw" "$_sep_shell" "$_MUTANT_VD_LIB")"
    assert_not_contains "$_mutant_out" "REACHED" \
        "mutant (guard removed) should have aborted before REACHED under set -eo pipefail with no node on PATH -- if REACHED still printed, SECTION 7's rows cannot be trusted to catch a regression of the XACA-1322-016 fix. Output: $_mutant_out" \
        && test_pass
done

# ═══════════════════════════════════════════════════════════════════════════
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
fi
exit 0
