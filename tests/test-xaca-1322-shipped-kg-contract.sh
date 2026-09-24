#!/bin/bash
# test-xaca-1322-shipped-kg-contract.sh
#
# CI-time contract test for the ONE case byte comparison (vault-drift.sh,
# XACA-1322-013/014/015) cannot catch: a tap release that ships a
# vault-fetch.js and vault-keygen.js that are already mutually inconsistent
# with EACH OTHER, both installed exactly as shipped. Byte-comparing an
# installed copy against the shipped copy proves the installed copy matches
# what shipped -- it says nothing about whether what shipped is internally
# sound.
#
# This runs against the REAL shipped files ONLY --
#   homebrew-tap/share/scripts/vault-fetch.js
#   homebrew-tap/share/scripts/vault-keygen.js
# -- never arbitrary/installed input. That is what makes a simple grep-
# derived member list plus a real `node -e require()` sound here where it
# was NOT sound as a runtime check: the runtime check had to survive
# adversarial installed JS (PR #965 rounds 2-5 demonstrated it couldn't);
# this test's input is fixed and trusted (this repo's own shipped file, at
# the commit CI is testing), so there is nothing adversarial to defend
# against.
#
# See libexec/lib/vault-drift.sh's header comment for the full history of
# why static JS parsing was removed from the runtime check.
#
# All filesystem activity is sandboxed to TEST_TMP_DIR. NEVER touches real
# $HOME / ~/.aiteamforge. Reads share/scripts/*.js read-only except for a
# throwaway mutant copy written under the sandbox.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHIPPED_FETCH="$TAP_ROOT/share/scripts/vault-fetch.js"
SHIPPED_KEYGEN="$TAP_ROOT/share/scripts/vault-keygen.js"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (mirrors test-xaca-1322-vault-drift.sh / test-xaca-0655
# pattern: works sourced by test-runner.sh's `export -f`'d helpers OR invoked
# directly).
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _SKIP_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST -- $1" >&2; }
    test_skip()  { _SKIP_COUNT=$((_SKIP_COUNT + 1)); echo "     SKIP: $_CURRENT_TEST -- $1"; }
fi
if ! type -t assert_equal >/dev/null 2>&1; then
    assert_equal() { [ "$1" = "$2" ] || { test_fail "${3:-Expected '$2', got '$1'}"; return 1; }; }
fi
if ! type -t assert_contains >/dev/null 2>&1; then
    assert_contains() { [[ "$1" == *"$2"* ]] || { test_fail "${3:-Expected to find '$2' in: $1}"; return 1; }; }
fi

if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1322-kg-contract.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

SANDBOX="$TEST_TMP_DIR/xaca1322-kg-contract"
mkdir -p "$SANDBOX"

test_start "sandboxed under TEST_TMP_DIR, real \$HOME untouched"
assert_contains "$SANDBOX" "$TEST_TMP_DIR" && test_pass

if [ ! -r "$SHIPPED_FETCH" ] || [ ! -r "$SHIPPED_KEYGEN" ]; then
    test_start "shipped vault-fetch.js/vault-keygen.js are present and readable"
    test_fail "expected both at $SHIPPED_FETCH and $SHIPPED_KEYGEN -- cannot run the rest of this contract test"
    if [ "$_STANDALONE" = true ]; then
        echo ""
        echo "Results: ${_PASS_COUNT} passed, ${_SKIP_COUNT} skipped, ${_FAIL_COUNT} failed"
        exit 1
    fi
    exit 0
fi
test_start "shipped vault-fetch.js/vault-keygen.js are present and readable"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Member derivation — a simple grep, sound ONLY because the input (the
# shipped file at HEAD) is fixed/trusted, not adversarial installed JS.
# ═══════════════════════════════════════════════════════════════════════════

# _derive_kg_members <fetch_js> -> stdout: one member name per line, deduped.
# Two shapes: `kg.<member>` (any non-identifier/non-dot char, or start of
# line, immediately before "kg") and the `...kg.<member>` spread form (the
# char immediately before "kg" there is ".", which the first pattern's
# negated class deliberately excludes -- see vault-drift.sh's own former
# left-boundary-rule comment for why "obj.kg.x" must NOT count: a "." right
# before "kg" means "kg" is somebody else's member, not the free variable
# -- except the literal three-dot spread, which this second pattern exists
# to catch on its own).
_derive_kg_members() {
    local fetch_js="$1"
    {
        grep -oE '(^|[^A-Za-z0-9_$.])kg\.[A-Za-z_$][A-Za-z0-9_$]*' "$fetch_js"
        grep -oE '\.\.\.kg\.[A-Za-z_$][A-Za-z0-9_$]*' "$fetch_js"
    } | sed -E 's/^.*kg\.//' | sort -u
}

MEMBERS_RAW="$(_derive_kg_members "$SHIPPED_FETCH")"
MEMBERS=()
while IFS= read -r _m; do
    [ -n "$_m" ] && MEMBERS+=("$_m")
done <<EOF_MEMBERS
$MEMBERS_RAW
EOF_MEMBERS

test_start "derived member set is non-empty"
if [ "${#MEMBERS[@]}" -gt 0 ]; then
    test_pass
else
    test_fail "grep derived ZERO kg.* members from $SHIPPED_FETCH -- either the file no longer uses vault-keygen.js at all (update this test) or the derivation regex broke"
fi

test_start "derived member set contains resolveFleetUrl"
_found_resolve=false
for _m in "${MEMBERS[@]}"; do
    [ "$_m" = "resolveFleetUrl" ] && _found_resolve=true
done
if [ "$_found_resolve" = true ]; then
    test_pass
else
    test_fail "resolveFleetUrl not found in derived set: ${MEMBERS[*]}"
fi

echo "     (derived ${#MEMBERS[@]} member(s): ${MEMBERS[*]})"

# ═══════════════════════════════════════════════════════════════════════════
# Accounting ratchet (PR #965 round-6 advisory): the derivation above only
# sees `kg.<member>`. If vault-fetch.js ever reaches kg another way
# (destructuring, kg[...], an alias, passing kg as an argument), those
# members would silently drop out of the contract. So every standalone `kg`
# token must be immediately followed by "." -- except the single
# `const|let|var kg = require(` binding line.
# ═══════════════════════════════════════════════════════════════════════════

# _unaccounted_kg_uses <fetch_js> -> stdout: "<line>:<match>" for each kg
# token not followed by "." outside the one require binding; empty = clean.
_unaccounted_kg_uses() {
    local fetch_js="$1" _binding_seen=false _ln _line _hits
    _ln=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        _ln=$((_ln + 1))
        _hits="$(printf '%s\n' "$_line" | grep -oE '(^|[^A-Za-z0-9_$])kg([^A-Za-z0-9_$.]|$)' || true)"
        [ -z "$_hits" ] && continue
        if [ "$_binding_seen" = false ] \
            && printf '%s\n' "$_line" | grep -qE '^[[:space:]]*(const|let|var)[[:space:]]+kg[[:space:]]*=[[:space:]]*require\(' \
            && [ "$(printf '%s\n' "$_hits" | wc -l | tr -d ' ')" = "1" ]; then
            _binding_seen=true
            continue
        fi
        printf '%s\n' "$_hits" | sed "s/^/${_ln}:/"
    done < "$fetch_js"
}

test_start "every kg use in shipped vault-fetch.js is kg.<member> (or the one require binding)"
_unacc="$(_unaccounted_kg_uses "$SHIPPED_FETCH")"
if [ -z "$_unacc" ]; then
    test_pass
else
    test_fail "unaccounted kg use(s) -- the member contract below cannot see these; extend _derive_kg_members before relaxing this: $(printf '%s' "$_unacc" | tr '\n' ' ')"
fi

test_start "MUTATION SENTINEL: an unaccounted kg use (helper(kg), destructuring, kg[...]) is caught"
_ratchet_ok=true
for _variant in 'helper(kg);' 'const { resolveFleetUrl } = kg;' "kg['resolveFleetUrl']();" 'const k = kg;'; do
    _mut="$SANDBOX/vault-fetch-ratchet-mutant.js"
    { cat "$SHIPPED_FETCH"; printf '%s\n' "$_variant"; } > "$_mut"
    if cmp -s "$SHIPPED_FETCH" "$_mut" || [ -z "$(_unaccounted_kg_uses "$_mut")" ]; then
        _ratchet_ok=false
        test_fail "ratchet did not flag appended variant: $_variant"
    fi
done
[ "$_ratchet_ok" = true ] && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# require() wiring — vault-fetch.js must actually require vault-keygen.js
# from the same directory.
# ═══════════════════════════════════════════════════════════════════════════

test_start "shipped vault-fetch.js require()s ./vault-keygen.js (or the extension-less form)"
if grep -qE "require\((['\"])\./vault-keygen(\.js)?\1\)" "$SHIPPED_FETCH"; then
    test_pass
else
    test_fail "no require('./vault-keygen.js') (or './vault-keygen') found in $SHIPPED_FETCH"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Node contract check — every derived member must be exported as a function.
# Loud SKIP (not a pass) when node isn't available: this test asserts
# nothing about export shape in that case.
# ═══════════════════════════════════════════════════════════════════════════

_HAVE_NODE=false
command -v node &>/dev/null && _HAVE_NODE=true

# _run_kg_contract_probe <keygen_js_path> -> stdout: "OK" or
# "MISSING:<comma-separated-non-function-members>"; exit 0 on OK, 1 on
# MISSING, 2 if require() itself threw (inconclusive about export shape).
_run_kg_contract_probe() {
    local keygen_js="$1"
    shift
    node -e '
        let kg;
        try {
            kg = require(process.argv[1]);
        } catch (e) {
            console.log("REQUIRE_FAILED:" + (e && e.message ? e.message : String(e)));
            process.exit(2);
        }
        var members = process.argv.slice(2);
        var missing = [];
        for (var i = 0; i < members.length; i++) {
            if (typeof kg[members[i]] !== "function") missing.push(members[i]);
        }
        if (missing.length > 0) {
            console.log("MISSING:" + missing.join(","));
            process.exit(1);
        }
        console.log("OK");
        process.exit(0);
    ' "$keygen_js" "$@"
}

if [ "$_HAVE_NODE" = true ]; then
    test_start "shipped vault-keygen.js exports every derived member as a function (node require)"
    if _probe_out="$(_run_kg_contract_probe "$SHIPPED_KEYGEN" "${MEMBERS[@]}" 2>&1)"; then
        assert_equal "OK" "$_probe_out" && test_pass
    else
        test_fail "shipped vault-keygen.js does not satisfy the shipped vault-fetch.js's kg.* contract: $_probe_out"
    fi
else
    test_start "shipped vault-keygen.js exports every derived member as a function (node require)"
    if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
        # PR #965 round-6 advisory: in CI a missing node must not read green.
        test_fail "node not resolvable in CI (CI/GITHUB_ACTIONS set) -- the contract this test exists to enforce went unchecked; install node on the runner"
    else
        test_skip "node not resolvable in this environment -- the export-shape contract cannot be verified here; this is a real gap in coverage for THIS run, not a pass"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# Mutation sentinel — proves the node-probe assertion above is not vacuous:
# a shipped vault-keygen.js missing an export the shipped vault-fetch.js
# actually needs must FAIL this contract check.
# ═══════════════════════════════════════════════════════════════════════════

if [ "$_HAVE_NODE" = true ]; then
    MUTANT_KEYGEN="$SANDBOX/vault-keygen-mutant.js"
    # Remove the `resolveFleetUrl,` export line from the module.exports
    # block only -- the function definition stays, so this mutates ONLY
    # the export surface, exactly the class of drift this contract test
    # exists to catch.
    sed -E '/^[[:space:]]*resolveFleetUrl,[[:space:]]*$/d' "$SHIPPED_KEYGEN" > "$MUTANT_KEYGEN"

    test_start "MUTATION SENTINEL: the mutant copy actually differs from the shipped file"
    if cmp -s "$SHIPPED_KEYGEN" "$MUTANT_KEYGEN"; then
        test_fail "mutant is IDENTICAL to the shipped file -- the sed deletion did not match the export line; the sentinel below would be vacuous"
    else
        test_pass
    fi

    test_start "MUTATION SENTINEL: the mutant (resolveFleetUrl un-exported) FAILS the contract check"
    if _mutant_probe_out="$(_run_kg_contract_probe "$MUTANT_KEYGEN" "${MEMBERS[@]}" 2>&1)"; then
        test_fail "expected the mutant (resolveFleetUrl removed from exports) to FAIL the contract probe, but it reported: $_mutant_probe_out -- if this holds, the PASS assertion above cannot be trusted to catch a real missing-export regression"
    else
        assert_contains "$_mutant_probe_out" "resolveFleetUrl" \
            "mutant probe failed as expected but did not name resolveFleetUrl -- got: $_mutant_probe_out" \
            && test_pass
    fi
else
    test_start "MUTATION SENTINEL: mutant copy differs from shipped file"
    test_skip "node not resolvable -- mutation sentinel requires the node probe above, which is also skipped in this run"
    test_start "MUTATION SENTINEL: mutant (resolveFleetUrl un-exported) FAILS the contract check"
    test_skip "node not resolvable -- mutation sentinel requires the node probe above, which is also skipped in this run"
fi

# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "──────────────────────────────────────────────"
    echo "  shipped kg contract test:  PASS=${_PASS_COUNT}  SKIP=${_SKIP_COUNT}  FAIL=${_FAIL_COUNT}"
    echo "──────────────────────────────────────────────"
    [ "$_FAIL_COUNT" -eq 0 ] || exit 1
fi
exit 0
