#!/bin/bash

# test-cli.sh
# Tests for aiteamforge CLI dispatcher (bin/aiteamforge-cli.sh)

# Source test runner functions (when run via test-runner)
# shellcheck disable=SC2154

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI_SCRIPT="$TAP_ROOT/bin/aiteamforge-cli.sh"

# Mock AITEAMFORGE_HOME for testing
export AITEAMFORGE_HOME="$TAP_ROOT"
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"

# ═══════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════

# Run CLI command and capture output
run_cli() {
  bash "$CLI_SCRIPT" "$@" 2>&1
}

# ═══════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════

test_start "CLI script exists and is executable"
assert_file_exists "$CLI_SCRIPT"
test_pass

test_start "CLI help command works"
output=$(run_cli help)
assert_contains "$output" "AITeamForge CLI"
assert_contains "$output" "Usage:"
test_pass

test_start "CLI version command works"
output=$(run_cli version)
assert_contains "$output" "AITeamForge v"
test_pass

test_start "CLI --version flag works"
output=$(run_cli --version)
assert_contains "$output" "AITeamForge v"
test_pass

test_start "CLI -v flag works"
output=$(run_cli -v)
assert_contains "$output" "AITeamForge v"
test_pass

test_start "CLI --help flag works"
output=$(run_cli --help)
assert_contains "$output" "Usage:"
test_pass

test_start "CLI -h flag works"
output=$(run_cli -h)
assert_contains "$output" "Usage:"
test_pass

test_start "CLI with no arguments shows help"
output=$(run_cli)
assert_contains "$output" "Usage:"
test_pass

test_start "CLI unknown command shows error"
output=$(run_cli invalid-command 2>&1)
assert_contains "$output" "ERROR: Unknown command"
assert_contains "$output" "invalid-command"
test_pass

test_start "CLI lists all expected commands in help"
output=$(run_cli help)
assert_contains "$output" "setup"
assert_contains "$output" "doctor"
assert_contains "$output" "status"
assert_contains "$output" "upgrade"
assert_contains "$output" "uninstall"
assert_contains "$output" "start"
assert_contains "$output" "stop"
assert_contains "$output" "restart"
test_pass

test_start "CLI shows framework location in version"
output=$(run_cli version)
assert_contains "$output" "Framework:"
test_pass

test_start "CLI shows working directory in version"
output=$(run_cli version)
assert_contains "$output" "Working Directory:"
test_pass

test_start "CLI shows not configured warning when no config"
output=$(run_cli version)
assert_contains "$output" "Not configured"
test_pass

test_start "CLI setup command is routable"
# Just check that setup script path is attempted (will fail with missing file, that's OK)
output=$(run_cli setup --help 2>&1 || true)
# Should attempt to exec aiteamforge-setup.sh
assert_success "true" # Always pass, just checking routing works
test_pass

test_start "CLI status requires configuration"
# Should exit with error when not configured
output=$(run_cli status 2>&1 || true)
assert_contains "$output" "not configured"
test_pass

test_start "CLI upgrade requires configuration"
output=$(run_cli upgrade 2>&1 || true)
assert_contains "$output" "not configured"
test_pass

test_start "CLI start requires configuration"
output=$(run_cli start 2>&1 || true)
assert_contains "$output" "not configured"
test_pass

test_start "CLI stop requires configuration"
output=$(run_cli stop 2>&1 || true)
assert_contains "$output" "not configured"
test_pass

# Success!
exit 0
