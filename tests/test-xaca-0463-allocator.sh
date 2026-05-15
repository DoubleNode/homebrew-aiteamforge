#!/bin/bash
# test-xaca-0463-allocator.sh
# Unit tests for aiteamforge_compute_instance_port (XACA-0463 subitem 003).
#
# Can be run standalone OR via test-runner.sh.
#
# Standalone:
#   bash homebrew-tap/tests/test-xaca-0463-allocator.sh
#
# Via runner:
#   bash homebrew-tap/tests/test-runner.sh

# ─────────────────────────────────────────────────────────────────────────────
# Bootstrap: set up TEST_TMP_DIR and helpers if running standalone.
# When sourced by test-runner.sh these are already provided.
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if [ -z "${TEST_TMP_DIR:-}" ]; then
    _STANDALONE=true
    TEST_TMP_DIR=$(mktemp -d -t aiteamforge-allocator-test.XXXXXX)
    trap 'rm -rf "$TEST_TMP_DIR"' EXIT INT TERM

    # Minimal test helpers mirroring test-runner.sh API.
    _PASS_COUNT=0
    _FAIL_COUNT=0

    test_start() { _CURRENT_TEST="$1"; }

    test_pass() {
        _PASS_COUNT=$(( _PASS_COUNT + 1 ))
        printf "PASS: %s\n" "$_CURRENT_TEST"
    }

    test_fail() {
        _FAIL_COUNT=$(( _FAIL_COUNT + 1 ))
        printf "FAIL: %s — %s\n" "$_CURRENT_TEST" "$1" >&2
    }

    assert_equal() {
        local got="$1" expected="$2"
        if [ "$got" = "$expected" ]; then
            test_pass
        else
            test_fail "expected '${expected}', got '${got}'"
        fi
    }

    assert_exit_success() {
        if [ "$1" -eq 0 ]; then
            test_pass
        else
            test_fail "expected exit 0, got $1"
        fi
    }

    assert_exit_failure() {
        if [ "$1" -ne 0 ]; then
            test_pass
        else
            test_fail "expected non-zero exit, got 0"
        fi
    }

    assert_contains() {
        local haystack="$1" needle="$2"
        if printf '%s' "$haystack" | grep -qi "$needle"; then
            test_pass
        else
            test_fail "expected output to contain '${needle}'; got: ${haystack}"
        fi
    }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Resolve paths
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATHS_LIB="$TAP_ROOT/libexec/lib/aiteamforge-paths.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Source the library under a sandboxed config path so it never touches $HOME.
# ─────────────────────────────────────────────────────────────────────────────
export AITEAMFORGE_CONFIG="$TEST_TMP_DIR/team-paths.json"

# shellcheck source=/dev/null
source "$PATHS_LIB"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

# write_team_paths <json>  — write JSON to the sandboxed team-paths file.
write_team_paths() {
    printf '%s\n' "$1" > "$AITEAMFORGE_CONFIG"
}

# empty_team_paths — team-paths with no entries.
empty_team_paths() {
    write_team_paths '{"schema_version":1,"teams":{}}'
}

# Finance band: base=8360, range=10
FINANCE_BASE=8360
FINANCE_RANGE=10

# Freelance band: base=8500, range=100
FREELANCE_BASE=8500

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

# ── 1. Empty state ───────────────────────────────────────────────────────────
test_start "compute_instance_port: empty state for finance returns base (8360)"
empty_team_paths
result=$(aiteamforge_compute_instance_port "finance" "$AITEAMFORGE_CONFIG")
assert_equal "$result" "$FINANCE_BASE"

# ── 2. Partial fill ──────────────────────────────────────────────────────────
test_start "compute_instance_port: partial fill returns next free port"
write_team_paths '{
  "schema_version": 1,
  "teams": {
    "finance-personal": {"lcars_port": 8360},
    "finance-business": {"lcars_port": 8361}
  }
}'
result=$(aiteamforge_compute_instance_port "finance" "$AITEAMFORGE_CONFIG")
assert_equal "$result" "8362"

# ── 3. Mid-band skip ─────────────────────────────────────────────────────────
test_start "compute_instance_port: mid-band taken port; lowest free is still base"
write_team_paths '{
  "schema_version": 1,
  "teams": {
    "some-team": {"lcars_port": 8361}
  }
}'
result=$(aiteamforge_compute_instance_port "finance" "$AITEAMFORGE_CONFIG")
assert_equal "$result" "$FINANCE_BASE"

# ── 4. Band exhausted ────────────────────────────────────────────────────────
test_start "compute_instance_port: band exhausted returns non-zero"
# Fill all 10 finance ports (8360–8369).
ports_json='"schema_version":1,"teams":{'
for i in $(seq 0 $(( FINANCE_RANGE - 1 ))); do
    port=$(( FINANCE_BASE + i ))
    ports_json="${ports_json}\"finance-instance${i}\":{\"lcars_port\":${port}},"
done
# trim trailing comma, close braces
ports_json="${ports_json%,}}"
write_team_paths "{$ports_json}"
result_exit=0
aiteamforge_compute_instance_port "finance" "$AITEAMFORGE_CONFIG" >/dev/null 2>&1 || result_exit=$?
assert_exit_failure "$result_exit"

# ── 4b. Band exhausted stderr contains 'exhausted' ───────────────────────────
test_start "compute_instance_port: band exhausted error message contains 'exhausted'"
# Reuse the same team-paths.json written above.
err_msg=$(aiteamforge_compute_instance_port "finance" "$AITEAMFORGE_CONFIG" 2>&1 || true)
assert_contains "$err_msg" "exhausted"

# ── 5. Unknown template ───────────────────────────────────────────────────────
test_start "compute_instance_port: unknown template returns non-zero"
empty_team_paths
bogus_exit=0
aiteamforge_compute_instance_port "bogus" "$AITEAMFORGE_CONFIG" >/dev/null 2>&1 || bogus_exit=$?
assert_exit_failure "$bogus_exit"

# ── 6. Tolerant input (instance id) ──────────────────────────────────────────
test_start "compute_instance_port: tolerant input — instance id 'finance-personal' resolves to finance band"
empty_team_paths
result_template=$(aiteamforge_compute_instance_port "finance" "$AITEAMFORGE_CONFIG")
result_instance=$(aiteamforge_compute_instance_port "finance-personal" "$AITEAMFORGE_CONFIG")
assert_equal "$result_template" "$result_instance"

# ── 7. Cross-template collision honored ───────────────────────────────────────
test_start "compute_instance_port: cross-template collision: port 8360 taken by unrelated team"
write_team_paths '{
  "schema_version": 1,
  "teams": {
    "unrelated-team": {"lcars_port": 8360}
  }
}'
result=$(aiteamforge_compute_instance_port "finance" "$AITEAMFORGE_CONFIG")
assert_equal "$result" "8361"

# ── 8. Null port entries ignored ──────────────────────────────────────────────
test_start "compute_instance_port: null lcars_port entries are ignored"
write_team_paths '{
  "schema_version": 1,
  "teams": {
    "a": {"lcars_port": null},
    "b": {"lcars_port": 8360}
  }
}'
result=$(aiteamforge_compute_instance_port "finance" "$AITEAMFORGE_CONFIG")
assert_equal "$result" "8361"

# ── 9. Freelance band size ─────────────────────────────────────────────────────
test_start "compute_instance_port: empty state for freelance returns 8500"
empty_team_paths
result=$(aiteamforge_compute_instance_port "freelance" "$AITEAMFORGE_CONFIG")
assert_equal "$result" "$FREELANCE_BASE"

# ── 10. Freelance band allows >10 instances ────────────────────────────────────
test_start "compute_instance_port: freelance band size 100 — fills 8500-8509, next is 8510"
ports_json='"schema_version":1,"teams":{'
for i in $(seq 0 9); do
    port=$(( FREELANCE_BASE + i ))
    ports_json="${ports_json}\"freelance-client-p${i}\":{\"lcars_port\":${port}},"
done
ports_json="${ports_json%,}}"
write_team_paths "{$ports_json}"
result=$(aiteamforge_compute_instance_port "freelance" "$AITEAMFORGE_CONFIG")
assert_equal "$result" "8510"

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone mode only)
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    printf "Results: %d passed, %d failed\n" "$_PASS_COUNT" "$_FAIL_COUNT"
    if [ "$_FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
    exit 0
fi
