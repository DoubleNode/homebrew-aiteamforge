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

test_start "derivation: pkg.version / _kg.x are NOT counted at all (not tokens); obj.kg.x IS a token but NOT a recognized access -> unaccounted (XACA-1322-017/021 left-boundary)"
d="$SANDBOX/deriv-boundary.js"
cat > "$d" <<'EOF_JS'
const kg = require('./vault-keygen');
const v = pkg.version;
const w = obj.kg.x;
const z = _kg.x;
kg.resolveFleetUrl();
EOF_JS
_scan_out="$(_scan "$d")"
# pkg./_kg. are never even "kg" tokens (preceded by an identifier char) --
# no output of any kind. obj.kg.x's "kg" IS a standalone token (preceded
# by a plain "."), so as of XACA-1322-021 it is no longer silently
# dropped -- it is a token that is not a recognized member access
# (`kg` itself is someone else's member here, not the free variable), so
# it must surface as exactly one U: line rather than vanishing.
assert_contains "$_scan_out" "M:CALLED:resolveFleetUrl" \
    "the real call went missing from the scan: $_scan_out"
assert_contains "$_scan_out" "U:unaccounted kg token" \
    "obj.kg.x's kg token must now be flagged unaccounted, not silently dropped (XACA-1322-021): $_scan_out"
# Exactly TWO lines total: the one real M:CALLED call and the one
# obj.kg.x U: line -- pkg.version and _kg.x must not have contributed a
# line of their own (they are never even tokens).
_scan_line_count="$(printf '%s\n' "$_scan_out" | grep -c .)"
assert_equal "2" "$_scan_line_count" \
    "expected exactly 2 output lines (1 M: + 1 U:) -- pkg.version/_kg.x must not surface as their own occurrence: $_scan_out" && test_pass

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
assert_contains "$_scan_out" "U:unaccounted kg token" "kg['x'] bracket access was not flagged unrecognized: $_scan_out" && test_pass

test_start "derivation: 'const {a} = kg' destructuring is flagged unrecognized (XACA-1322-018)"
d="$SANDBOX/deriv-destructure.js"
cat > "$d" <<'EOF_JS'
const kg = require('./vault-keygen');
kg.resolveFleetUrl();
const {a} = kg;
EOF_JS
_scan_out="$(_scan "$d")"
assert_contains "$_scan_out" "M:CALLED:resolveFleetUrl" "real call missing from scan: $_scan_out"
assert_contains "$_scan_out" "U:unaccounted kg token" "destructuring from kg was not flagged unrecognized: $_scan_out" && test_pass

test_start "derivation: 'const k = kg;' aliasing is flagged unrecognized (XACA-1322-018)"
d="$SANDBOX/deriv-alias.js"
cat > "$d" <<'EOF_JS'
const kg = require('./vault-keygen');
kg.resolveFleetUrl();
const k = kg;
EOF_JS
_scan_out="$(_scan "$d")"
assert_contains "$_scan_out" "M:CALLED:resolveFleetUrl" "real call missing from scan: $_scan_out"
assert_contains "$_scan_out" "U:unaccounted kg token" "kg aliasing was not flagged unrecognized: $_scan_out" && test_pass

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
# SECTION 6B — token-accounting ratchet (PR #965 round 3: XACA-1322-021/022)
#
# 021 (Blocking): kg?.x, kg .x, kg<TAB>.x, kg\n  .x, (kg).x, helper(kg),
# [kg], a bare "let k = kg" (no ; or ,), "return kg", and "obj.kg.x" were
# all invisible to both the required-member derivation AND the old
# bracket/destructure/alias-only U: downgrade -- a file mixing one of
# these with a normal kg.<member>() call read as a clean PASS. The fix is
# the token-accounting ratchet: every standalone "kg" token must be
# accounted for as a recognized kg.<member> access or the one allowed
# require() binding, or it emits exactly one U: line.
#
# 022 (Advisory): "} = kg" was reported as BOTH destructure and alias.
# The ratchet visits each token occurrence exactly once, so this class of
# double-report is structurally impossible now, not just patched for this
# one shape.
# ═══════════════════════════════════════════════════════════════════════════

# _run_021_variant_row <slug> <variant_code_lines> -- mixes the variant
# with a normal, satisfied kg.a() call (keygen exports ONLY "a") so a PASS
# can only happen if the variant's own "kg" token is never accounted for.
# The variant itself references kg.bMissing, a member the keygen does NOT
# export -- proving the WARN is not incidentally caused by something else.
_run_021_variant_row() {
    local slug="$1" variant_code="$2"
    test_start "021 variant [$slug]: mixed with a normal kg.a() call -> WARN, never a silent PASS (XACA-1322-021)"
    _reload_vault_drift_lib
    local d="$SANDBOX/v021-$slug"
    mkdir -p "$d/scripts"
    {
        printf '%s\n' "const kg = require('./vault-keygen');"
        printf '%s\n' "kg.a();"
        printf '%s\n' "$variant_code"
    } > "$d/scripts/vault-fetch.js"
    printf '%s\n' "$(_gen_keygen_js a)" > "$d/scripts/vault-keygen.js"
    _aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
    assert_equal "WARN" "$_AITF_VD_STATUS" \
        "the '$slug' kg-access variant mixed with a normal call must downgrade an otherwise-PASS result to WARN, never stay silently PASS (XACA-1322-021) -- got: $_AITF_VD_STATUS / $_AITF_VD_MSG"
    assert_contains "$_AITF_VD_MSG" "could not fully verify" \
        "expected the WARN message to name 'could not fully verify' -- got: $_AITF_VD_MSG" && test_pass
}

if [ "$_HAVE_NODE" = true ]; then
    _run_021_variant_row "optional-chaining"      "kg?.bMissing();"
    _run_021_variant_row "space-before-dot"       "kg .bMissing();"
    _run_021_variant_row "tab-before-dot"         "$(printf 'kg\t.bMissing();')"
    _run_021_variant_row "parenthesized"          "(kg).bMissing();"
    _run_021_variant_row "chained-across-newline" "$(printf 'kg\n  .bMissing();')"
    _run_021_variant_row "bare-argument"          "helper(kg);"
    _run_021_variant_row "array-literal"          "[kg];"
    _run_021_variant_row "alias-no-semicolon"     "let k = kg"
    _run_021_variant_row "return-kg"              "return kg;"
    _run_021_variant_row "kg-as-someone-elses-member" "obj.kg.x();"

    test_start "021: a SECOND 'const kg = require(...)' binding is itself unaccounted -> WARN (only the first binding is allowed)"
    _reload_vault_drift_lib
    d="$SANDBOX/v021-second-require"
    mkdir -p "$d/scripts"
    cat > "$d/scripts/vault-fetch.js" <<'EOF_JS'
const kg = require('./vault-keygen');
kg.a();
const kg = require('./vault-keygen');
EOF_JS
    printf '%s\n' "$(_gen_keygen_js a)" > "$d/scripts/vault-keygen.js"
    _aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
    assert_equal "WARN" "$_AITF_VD_STATUS" \
        "a second require() binding must be treated as an unaccounted extra token, downgrading to WARN -- got: $_AITF_VD_STATUS / $_AITF_VD_MSG" && test_pass
else
    echo "    SKIP: node not resolvable on this machine/runner -- 021 node-probe-downgrade assertions skipped"
fi

test_start "021: pkg.x / kgx.y / \$kg.z are not even TOKENS -- no U: lines"
d="$SANDBOX/deriv-nontoken.js"
cat > "$d" <<'EOF_JS'
const kg = require('./vault-keygen');
kg.resolveFleetUrl();
pkg.x;
kgx.y;
$kg.z;
EOF_JS
_scan_out="$(_scan "$d")"
assert_equal "M:CALLED:resolveFleetUrl" "$_scan_out" \
    "pkg./kgx./\$kg. must never be treated as a 'kg' token -- got: $_scan_out" && test_pass

test_start "021: a bare 'kg' mention (no dot) inside a comment is ignored, same as a kg.member mention"
d="$SANDBOX/deriv-comment-bare-kg.js"
cat > "$d" <<'EOF_JS'
const kg = require('./vault-keygen');
kg.resolveFleetUrl();
// just kg, not a real reference
EOF_JS
_scan_out="$(_scan "$d")"
assert_equal "M:CALLED:resolveFleetUrl" "$_scan_out" \
    "a bare 'kg' mention inside a // comment leaked into the derived/unaccounted set: $_scan_out" && test_pass

test_start "021 FIXED: '// kg' inside a string literal no longer eats the real call on the same line (XACA-1322-023/024)"
# FORMERLY a documented known limitation (XACA-1322-018 review): the old
# comment stripper was a plain per-character state machine with no idea
# about string/template literals, so the literal text "// kg" INSIDE a
# string was misread as the start of a real comment and ate the rest of
# the line -- including a genuine kg.resolveFleetUrl() call that followed
# on the same line, AND the bare "kg" word inside the string itself. With
# nothing left to derive, the old check WARNed "could not determine which
# vault-keygen.js exports ... (no kg.* references found)". PR #965 round 4
# review (XACA-1322-023) demonstrated a sibling shape (a comment-lookalike
# inside a string with NO bare "kg" mention, e.g. 'http://host') could
# actually reach a false PASS this way whenever the eaten call was the
# only reference to a member the keygen was missing. Round 4 tester repro
# XACA-1322-024 confirmed it (see the "lexer fix" rows below). FIXED by
# replacing the stripper with a real single-pass lexer (see the header
# comment above _aitf_vd_scan_kg_usage) that tracks string/template/regex
# boundaries, so a "//"/"/*" lookalike inside one is never mistaken for a
# comment start -- string CONTENTS are kept verbatim, never blanked.
#
# The UPDATED, ACCURATE claim for THIS specific fixture: the real
# kg.resolveFleetUrl() call is no longer eaten (no longer "no kg.*
# references found"). But this fixture's string ALSO contains a bare "kg"
# word (not followed by ".") -- kept verbatim per rule 2, that word is now
# correctly a real, standalone "kg" token with no recognized access
# pattern, so it downgrades the result to WARN ("could not fully
# verify"), same as any other unrecognized kg token (XACA-1322-021/022).
# This is rule 2's guarantee working exactly as designed: "a kg mention
# inside a string can only cause a WARN or FAIL, never a false PASS." A
# fixture with a comment-lookalike but no bare "kg" word (the "lexer fix"
# rows below) is what now reaches a clean, correctly-derived PASS/FAIL.
_reload_vault_drift_lib
d="$SANDBOX/v021-string-literal-comment"
mkdir -p "$d/scripts"
printf '%s\n' \
    "const kg = require('./vault-keygen');" \
    "const s = \"// kg\"; kg.resolveFleetUrl();" \
    > "$d/scripts/vault-fetch.js"
printf '%s\n' "$(_gen_keygen_js resolveFleetUrl)" > "$d/scripts/vault-keygen.js"
_scan_out="$(_scan "$d/scripts/vault-fetch.js")"
assert_contains "$_scan_out" "M:CALLED:resolveFleetUrl" \
    "the '// kg' string-literal lookalike must no longer eat the real kg.resolveFleetUrl() call that follows it on the same line -- got: $_scan_out"
assert_contains "$_scan_out" "U:unaccounted kg token" \
    "the bare 'kg' word kept verbatim inside the string (not followed by '.') must still be flagged as an unaccounted token -- got: $_scan_out"
if [ "$_HAVE_NODE" = true ]; then
    _aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
    assert_equal "WARN" "$_AITF_VD_STATUS" \
        "the real call is now correctly derived, but the bare 'kg' word inside the string is still unaccounted -- this must WARN (could not fully verify), never silently PASS -- got: $_AITF_VD_STATUS / $_AITF_VD_MSG"
    assert_contains "$_AITF_VD_MSG" "could not fully verify" && test_pass
else
    echo "    SKIP: node not resolvable on this machine/runner -- WARN assertion needs the node-probe path"
fi

# ═══════════════════════════════════════════════════════════════════════════
# SECTION 6C -- lexer-based comment/string stripper (PR #965 round 4:
# XACA-1322-023 review / XACA-1322-024 tester repro)
#
# 023/024 (Blocking): the OLD per-character stripper did not know about
# string/template/regex literals, so a "//" or "/*" lookalike INSIDE one
# was misread as a real comment start and ate a genuine kg.<member>() call
# that followed on the same (or, for a stray unterminated block-comment
# opener, a later) line -- a FALSE PASS whenever the eaten call was the
# only reference to a member the installed keygen was missing. The fix
# replaces the stripper with a small single-pass lexer that tracks single-
# and double-quoted strings, template literals (with `${...}`
# substitutions lexed as real code, to any nesting depth), and regex-vs-
# division. String/template/regex CONTENTS are kept verbatim in the
# scanned text (never blanked) -- a `kg` mention inside one can therefore
# still produce a WARN or FAIL via the token-accounting ratchet, but never
# a false PASS. An unterminated string/template/regex/block-comment, or an
# unclosed `${` substitution, fails closed with one `U:unterminated
# <kind>` line at EOF rather than trusting a partial scan.
#
# NOTE ON QUOTING: every fixture below is written DIRECTLY to a file via
# `cat > "$f" <<'EOF_JS'` (a plain redirection), never captured through a
# `$(cat <<'EOF_JS' ... )` command substitution. /bin/bash 3.2 (macOS'
# shipped bash) has a real parsing bug where a heredoc with a literal
# apostrophe in its body, when that heredoc lives inside a `$( ... )`
# command substitution, corrupts the shell's quote-tracking for the REST
# OF THE FILE ("unexpected EOF while looking for matching `''" at every
# later checkpoint) even though the heredoc delimiter is quoted (fully
# literal body, no expansion) -- confirmed by bisection while writing
# this suite. Writing straight to a file sidesteps it entirely and is the
# same pattern already used throughout this file.
# ═══════════════════════════════════════════════════════════════════════════

# _assert_trigger_row <slug> <fetch_js_path> <missing_member>
#   <fetch_js_path> must already be a complete vault-fetch.js: the
#   require() binding, a real kg.a() call, then a trigger line/lines that
#   themselves reference kg.<missing_member> (same line or a following
#   line). keygen exports ONLY "a". Runs the FULL check on both the
#   node-probe path (must FAIL, naming missing_member -- the comment/
#   string lookalike in the trigger must not swallow the real call) and
#   the no-node fallback path (must never read PASS).
_assert_trigger_row() {
    local slug="$1" fetch_js_path="$2" missing_member="$3"
    local d="$SANDBOX/vfix-$slug"
    mkdir -p "$d/scripts"
    cp "$fetch_js_path" "$d/scripts/vault-fetch.js"
    printf '%s\n' "$(_gen_keygen_js a)" > "$d/scripts/vault-keygen.js"

    if [ "$_HAVE_NODE" = true ]; then
        test_start "lexer fix [$slug]: kg.$missing_member() is derived, not eaten -> FAIL (node path, XACA-1322-023/024)"
        _reload_vault_drift_lib
        _aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
        assert_equal "FAIL" "$_AITF_VD_STATUS" \
            "the '$slug' trigger must not swallow the real kg.$missing_member() call as if it were commented out -- got: $_AITF_VD_STATUS / $_AITF_VD_MSG"
        assert_contains "$_AITF_VD_MSG" "$missing_member" \
            "expected the FAIL message to name $missing_member -- got: $_AITF_VD_MSG" && test_pass
    else
        echo "    SKIP: node not resolvable on this machine/runner -- [$slug] node-path assertion skipped"
    fi

    test_start "lexer fix [$slug]: no-node fallback path -> never PASS (XACA-1322-023/024)"
    _reload_vault_drift_lib
    local _saved_path="$PATH"
    PATH="$_NO_NODE_PATH"
    _aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
    PATH="$_saved_path"
    assert_not_contains "$_AITF_VD_STATUS" "PASS" \
        "the '$slug' trigger must never read as a silent PASS on the no-node fallback path either -- got: $_AITF_VD_STATUS / $_AITF_VD_MSG" && test_pass
}

# ── Same-line lookalikes: a comment-opener substring sits INSIDE a
# string/template on the SAME line as the real call (XACA-1322-023 repro
# shapes from the round-4 review body).
_src_http_single="$SANDBOX/src-http-url-single-quote-same-line.js"
cat > "$_src_http_single" <<'EOF_JS'
const kg = require('./vault-keygen.js');
kg.a();
const u = 'http://host'; kg.bMissing();
EOF_JS

_src_aslashslashb_double="$SANDBOX/src-double-quote-slash-slash-same-line.js"
cat > "$_src_aslashslashb_double" <<'EOF_JS'
const kg = require('./vault-keygen.js');
kg.a();
const s = "a//b"; kg.bMissing();
EOF_JS

_src_xslashslashy_template="$SANDBOX/src-template-slash-slash-same-line.js"
cat > "$_src_xslashslashy_template" <<'EOF_JS'
const kg = require('./vault-keygen.js');
kg.a();
const t = `x//y`; kg.bMissing();
EOF_JS

_src_blockcomment_open_singleline="$SANDBOX/src-block-comment-open-string-same-line.js"
cat > "$_src_blockcomment_open_singleline" <<'EOF_JS'
const kg = require('./vault-keygen.js');
kg.a();
const c = '/*'; kg.bMissing();
EOF_JS

_assert_trigger_row "http-url-single-quote-same-line"     "$_src_http_single"                  "bMissing"
_assert_trigger_row "double-quote-slash-slash-same-line"  "$_src_aslashslashb_double"           "bMissing"
_assert_trigger_row "template-slash-slash-same-line"      "$_src_xslashslashy_template"         "bMissing"
_assert_trigger_row "block-comment-open-string-same-line" "$_src_blockcomment_open_singleline"  "bMissing"

# An escaped quote inside a single-quoted string must not end the string
# early -- the "// not a comment" text after it stays inside the string,
# and the real call after the string closes is still derived.
_src_escaped_quote="$SANDBOX/src-escaped-quote-in-string.js"
cat > "$_src_escaped_quote" <<'EOF_JS'
const kg = require('./vault-keygen.js');
kg.a();
const s = 'it\'s // not a comment'; kg.bMissing();
EOF_JS
_assert_trigger_row "escaped-quote-in-string" "$_src_escaped_quote" "bMissing"

# ── Regex literals: a "/" that is regex, not division, and a character
# class inside the regex where "/" does not end it.
_src_regex_escaped_slashes="$SANDBOX/src-regex-escaped-slashes.js"
cat > "$_src_regex_escaped_slashes" <<'EOF_JS'
const kg = require('./vault-keygen.js');
kg.a();
/\/\//.test(s); kg.bMissing();
EOF_JS

_src_regex_char_class="$SANDBOX/src-regex-character-class.js"
cat > "$_src_regex_char_class" <<'EOF_JS'
const kg = require('./vault-keygen.js');
kg.a();
/[/]/.test(s); kg.bMissing();
EOF_JS

_assert_trigger_row "regex-escaped-slashes" "$_src_regex_escaped_slashes" "bMissing"
_assert_trigger_row "regex-character-class" "$_src_regex_char_class" "bMissing"

# ── XACA-1322-024 tester repros: the exact 4 round-4 trigger shapes, with
# the real call on the LINE AFTER the trigger (not combined on one line),
# derived against resolveFleetUrl (the member the real shipped file
# actually needs) rather than a synthetic bMissing.
_src_double_quoted_url_nextline="$SANDBOX/src-024-double-quoted-url-next-line.js"
cat > "$_src_double_quoted_url_nextline" <<'EOF_JS'
const kg = require('./vault-keygen.js');
kg.a();
const base = "http://fleet.example.com";
kg.resolveFleetUrl();
EOF_JS

_src_single_quoted_url_nextline="$SANDBOX/src-024-single-quoted-url-next-line.js"
cat > "$_src_single_quoted_url_nextline" <<'EOF_JS'
const kg = require('./vault-keygen.js');
kg.a();
const base = 'http://fleet.example.com';
kg.resolveFleetUrl();
EOF_JS

_src_template_url_nextline="$SANDBOX/src-024-template-url-next-line.js"
cat > "$_src_template_url_nextline" <<'EOF_JS'
const kg = require('./vault-keygen.js');
kg.a();
const base = `http://fleet.example.com`;
kg.resolveFleetUrl();
EOF_JS

_src_blockcomment_open_nextline="$SANDBOX/src-024-block-comment-open-next-line.js"
cat > "$_src_blockcomment_open_nextline" <<'EOF_JS'
const kg = require('./vault-keygen.js');
kg.a();
const note = "/* see docs";
kg.resolveFleetUrl();
EOF_JS

_assert_trigger_row "024-double-quoted-url-next-line"  "$_src_double_quoted_url_nextline"  "resolveFleetUrl"
_assert_trigger_row "024-single-quoted-url-next-line"  "$_src_single_quoted_url_nextline"  "resolveFleetUrl"
_assert_trigger_row "024-template-url-next-line"       "$_src_template_url_nextline"       "resolveFleetUrl"
_assert_trigger_row "024-block-comment-open-next-line" "$_src_blockcomment_open_nextline"  "resolveFleetUrl"

# ── Template substitution: kg.bMissing() called INSIDE ${...} must be
# lexed as real code, including when nested with its own string + real
# comment.
test_start "lexer fix: kg.bMissing() inside a template \${...} substitution is derived as CALLED"
d="$SANDBOX/tpl-subst-called.js"
cat > "$d" <<'EOF_JS'
const kg = require('./vault-keygen');
const t = `${kg.bMissing()}`;
EOF_JS
_scan_out="$(_scan "$d")"
assert_equal "M:CALLED:bMissing" "$_scan_out" \
    "kg.bMissing() inside a template \${...} substitution must be recognized as a real, accounted CALLED reference -- got: $_scan_out" && test_pass

test_start "lexer fix: a nested string + a real comment inside \${...} are both handled correctly"
d="$SANDBOX/tpl-subst-nested.js"
cat > "$d" <<'EOF_JS'
const kg = require('./vault-keygen');
const t = `${"nested // string" /* real comment */ + kg.bMissing()}`;
EOF_JS
_scan_out="$(_scan "$d")"
assert_equal "M:CALLED:bMissing" "$_scan_out" \
    "a nested string and a real /* comment */ inside a template substitution must not confuse the lexer's return to the enclosing template -- got: $_scan_out" && test_pass

# ── Division vs. regex: a real "/" division followed by a genuine "//"
# comment must NOT be misread as a regex literal, and the comment must
# still be stripped (kg.fake() inside it is never required).
test_start "lexer fix: division (not regex) followed by a real // comment -- comment IS stripped"
d="$SANDBOX/div-not-regex.js"
cat > "$d" <<'EOF_JS'
const kg = require('./vault-keygen');
kg.a();
var a = 1, b = 2;
a / b; // kg.fake()
EOF_JS
_scan_out="$(_scan "$d")"
assert_equal "M:CALLED:a" "$_scan_out" \
    "'a / b' must be read as division (not a regex literal), and the trailing // comment must still be stripped so kg.fake() is never required -- got: $_scan_out" && test_pass

# ── Multi-line constructs: a multi-line template and a multi-line block
# comment must both close correctly and not corrupt subsequent scanning.
test_start "lexer fix: a multi-line template literal closes correctly"
d="$SANDBOX/multiline-template.js"
cat > "$d" <<'EOF_JS'
const kg = require('./vault-keygen');
const t = `line one
line two still inside
`;
kg.a();
EOF_JS
_scan_out="$(_scan "$d")"
assert_equal "M:CALLED:a" "$_scan_out" \
    "a multi-line template literal must close at its final backtick and not swallow/corrupt the real call after it -- got: $_scan_out" && test_pass

test_start "lexer fix: a multi-line block comment closes correctly and strips a kg.bMissing() mention inside it"
d="$SANDBOX/multiline-blockcomment.js"
cat > "$d" <<'EOF_JS'
const kg = require('./vault-keygen');
/* this is
   a multi-line
   comment mentioning kg.bMissing() which must be stripped */
kg.a();
EOF_JS
_scan_out="$(_scan "$d")"
assert_equal "M:CALLED:a" "$_scan_out" \
    "a multi-line block comment must be fully stripped (including a kg.bMissing() mention inside it) and still let the real call after it through -- got: $_scan_out" && test_pass

# ── FAIL-CLOSED AT EOF (rule 6): an unterminated string/template/regex/
# block comment, or an unclosed \${ substitution, must emit exactly one
# U:unterminated <kind> line and the full check must WARN, never PASS.
_run_unterminated_row() {
    # <keygen_content> defaults to a keygen exporting all 7 real members
    # ($_full_keygen_js) -- override it when the fixture itself derives a
    # DIFFERENT real, accounted member before running out of file (e.g.
    # the "${ substitution" case, which fully lexes kg.bMissing() before
    # EOF), so the node probe's OTHER required member doesn't itself FAIL
    # and mask the WARN-from-unterminated-construct this row exists to
    # prove.
    local slug="$1" kind="$2" fetch_js_path="$3" keygen_content="${4:-$_full_keygen_js}"

    test_start "EOF fail-closed [$slug]: unterminated $kind emits a U:unterminated line"
    _scan_out="$(_scan "$fetch_js_path")"
    assert_contains "$_scan_out" "U:unterminated $kind" \
        "expected a fail-closed U:unterminated $kind line at EOF -- got: $_scan_out" && test_pass

    test_start "EOF fail-closed [$slug]: full check reports WARN, never PASS"
    _reload_vault_drift_lib
    local dd="$SANDBOX/unterm-full-$slug"
    mkdir -p "$dd/scripts"
    cp "$fetch_js_path" "$dd/scripts/vault-fetch.js"
    printf '%s\n' "$keygen_content" > "$dd/scripts/vault-keygen.js"
    _aitf_vault_drift_check "$dd/scripts" "$dd/shipped" >/dev/null 2>&1
    assert_equal "WARN" "$_AITF_VD_STATUS" \
        "an unterminated $kind at EOF must WARN, never PASS -- got: $_AITF_VD_STATUS / $_AITF_VD_MSG" && test_pass
}

_src_unterm_sq="$SANDBOX/src-unterm-single-quoted-string.js"
cat > "$_src_unterm_sq" <<'EOF_JS'
const kg = require('./vault-keygen');
const s = 'never closed
EOF_JS

_src_unterm_dq="$SANDBOX/src-unterm-double-quoted-string.js"
cat > "$_src_unterm_dq" <<'EOF_JS'
const kg = require('./vault-keygen');
const s = "never closed
EOF_JS

_src_unterm_tpl="$SANDBOX/src-unterm-template-literal.js"
cat > "$_src_unterm_tpl" <<'EOF_JS'
const kg = require('./vault-keygen');
const t = `never closed
EOF_JS

_src_unterm_regex="$SANDBOX/src-unterm-regex-literal.js"
cat > "$_src_unterm_regex" <<'EOF_JS'
const kg = require('./vault-keygen');
var re = /never closed
EOF_JS

_src_unterm_bcomment="$SANDBOX/src-unterm-block-comment.js"
cat > "$_src_unterm_bcomment" <<'EOF_JS'
const kg = require('./vault-keygen');
/* never closed
EOF_JS

_src_unterm_subst="$SANDBOX/src-unterm-subst.js"
cat > "$_src_unterm_subst" <<'EOF_JS'
const kg = require('./vault-keygen');
const t = `head ${kg.bMissing()
EOF_JS

_run_unterminated_row "single-quoted-string" "single-quoted string" "$_src_unterm_sq"
_run_unterminated_row "double-quoted-string" "double-quoted string" "$_src_unterm_dq"
_run_unterminated_row "template-literal"     "template literal"     "$_src_unterm_tpl"
_run_unterminated_row "regex-literal"        "regex literal"        "$_src_unterm_regex"
_run_unterminated_row "block-comment"        "block comment"        "$_src_unterm_bcomment"
_run_unterminated_row "subst"                '${ substitution'      "$_src_unterm_subst" "$(_gen_keygen_js bMissing)"

# ── Mutation sentinel (string-literal/lexer class, XACA-1322-023/024) ───
# Proves the rows above are not vacuous: patching the lexer so it treats
# quote characters as ordinary code (never entering the SQ/DQ string
# states) reintroduces the exact false-PASS defect this round fixes -- a
# "//" inside what would have been a string is read as a real comment
# again, eating the real call. The 'http://host' same-line row must then
# flip from FAIL to PASS.
_MUTANT_023_LIB="$SANDBOX/vault-drift-mutant-023.sh"
sed -e 's/c1 == SQC) {/0) {/' -e 's/c1 == DQC) {/0) {/' "$VAULT_DRIFT_LIB" > "$_MUTANT_023_LIB"

test_start "MUTATION SENTINEL (string-literal class): the patched temp copy actually differs from the real lib"
if diff -q "$VAULT_DRIFT_LIB" "$_MUTANT_023_LIB" >/dev/null 2>&1; then
    test_fail "mutant lib is IDENTICAL to the real lib -- the sed substitution did not match the quote-handling branches; the row below would be vacuous"
else
    test_pass
fi

if [ "$_HAVE_NODE" = true ]; then
    test_start "MUTATION SENTINEL [string-literal class]: treating quotes as ordinary code flips the 'http://host' row from FAIL to PASS"
    _MUTANT_STATUS_023="$(
        unset _VAULT_DRIFT_SH_LOADED
        # shellcheck source=../libexec/lib/vault-drift.sh
        source "$_MUTANT_023_LIB"
        d="$SANDBOX/mutant-023"
        mkdir -p "$d/scripts"
        cp "$_src_http_single" "$d/scripts/vault-fetch.js"
        printf '%s\n' "$(_gen_keygen_js a)" > "$d/scripts/vault-keygen.js"
        _aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
        echo "$_AITF_VD_STATUS"
    )"
    assert_equal "PASS" "$_MUTANT_STATUS_023" \
        "mutant (quotes treated as ordinary code) should have flipped the 'http://host' row from FAIL to PASS -- if this doesn't hold, the string-literal rows above cannot be trusted to catch a regression of the XACA-1322-023/024 lexer fix. Got: $_MUTANT_STATUS_023" \
        && test_pass
else
    echo "    SKIP: node not resolvable on this machine/runner -- string-literal mutation sentinel needs the node-probe PASS path"
fi

# ── Mutation sentinel (021 class) ───────────────────────────────────────
# Proves the rows above are not vacuous: disabling the ratchet's
# unaccounted-token branch reintroduces the exact false-PASS defect
# XACA-1322-021 fixes, and a 021 variant row must then flip from WARN to
# PASS.
_MUTANT_021_LIB="$SANDBOX/vault-drift-mutant-021.sh"
sed 's/if (!recognized) {/if (0) {/' "$VAULT_DRIFT_LIB" > "$_MUTANT_021_LIB"

test_start "MUTATION SENTINEL (021 class): the patched temp copy actually differs from the real lib"
if diff -q "$VAULT_DRIFT_LIB" "$_MUTANT_021_LIB" >/dev/null 2>&1; then
    test_fail "mutant lib is IDENTICAL to the real lib -- the sed substitution did not match the ratchet's unaccounted branch; the row below would be vacuous"
else
    test_pass
fi

if [ "$_HAVE_NODE" = true ]; then
    test_start "MUTATION SENTINEL [021 class]: disabling the unaccounted-token branch flips a 021 variant row (kg?.x()) from WARN to PASS"
    _MUTANT_STATUS_021="$(
        unset _VAULT_DRIFT_SH_LOADED
        # shellcheck source=../libexec/lib/vault-drift.sh
        source "$_MUTANT_021_LIB"
        d="$SANDBOX/mutant-021"
        mkdir -p "$d/scripts"
        printf '%s\n' "const kg = require('./vault-keygen');" "kg.a();" "kg?.bMissing();" > "$d/scripts/vault-fetch.js"
        printf '%s\n' "$(_gen_keygen_js a)" > "$d/scripts/vault-keygen.js"
        _aitf_vault_drift_check "$d/scripts" "$d/shipped" >/dev/null 2>&1
        echo "$_AITF_VD_STATUS"
    )"
    assert_equal "PASS" "$_MUTANT_STATUS_021" \
        "mutant (unaccounted-token branch disabled) should have flipped the kg?.x() row from WARN to PASS -- if this doesn't hold, the 021 rows above cannot be trusted to catch a regression of the ratchet. Got: $_MUTANT_STATUS_021" \
        && test_pass
else
    echo "    SKIP: node not resolvable on this machine/runner -- 021 mutation sentinel needs the node-probe PASS path"
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
