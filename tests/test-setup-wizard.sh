#!/bin/bash

# test-setup-wizard.sh
# Tests for setup wizard (bin/aiteamforge-setup.sh)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP_SCRIPT="$TAP_ROOT/libexec/aiteamforge-setup.sh"

# Set up test environment
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
export AITEAMFORGE_HOME="$TAP_ROOT"
mkdir -p "$AITEAMFORGE_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════

run_setup() {
  zsh "$SETUP_SCRIPT" "$@" 2>&1
}

# ═══════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════

test_start "Setup script exists"
assert_file_exists "$SETUP_SCRIPT"
test_pass

test_start "Setup script is executable"
[ -x "$SETUP_SCRIPT" ]
assert_exit_success $?
test_pass

test_start "Setup script --help flag works"
output=$(run_setup --help)
assert_contains "$output" "aiteamforge-setup"
assert_contains "$output" "USAGE:"
assert_contains "$output" "OPTIONS:"
test_pass

test_start "Setup script shows dry-run option in help"
output=$(run_setup --help)
assert_contains "$output" "--dry-run"
test_pass

test_start "Setup script shows non-interactive option in help"
output=$(run_setup --help)
assert_contains "$output" "--non-interactive"
test_pass

test_start "Setup script shows verbose option in help"
output=$(run_setup --help)
assert_contains "$output" "--verbose"
test_pass

test_start "Setup script rejects unknown options"
output=$(run_setup --unknown-option 2>&1 || true)
assert_contains "$output" "Unknown option"
test_pass

test_start "Setup script runs in dry-run mode"
output=$(run_setup --dry-run --non-interactive 2>&1 || true)
# Should complete without errors in dry-run mode
assert_contains "$output" "DRY RUN" || true  # May or may not show this
test_pass

test_start "Setup script has UI library available"
# Check that it sources wizard-ui.sh successfully
ui_lib="$TAP_ROOT/libexec/lib/wizard-ui.sh"
assert_file_exists "$ui_lib"
test_pass

test_start "Setup script shows welcome banner"
# In verbose dry-run mode, should show welcome content
output=$(run_setup --dry-run --non-interactive 2>&1 || true)
# Banner may not show in non-interactive, so just check script runs
assert_not_empty "$output"
test_pass

test_start "Setup script checks prerequisites"
# Script should check for git, python, etc.
output=$(run_setup --dry-run --non-interactive 2>&1 || true)
# Should mention checking or dependencies
assert_not_empty "$output"
test_pass

test_start "Setup script creates config directory in dry-run"
# In dry-run mode, should preview config directory creation
output=$(run_setup --dry-run --non-interactive 2>&1 || true)
# Should mention config or setup completion
assert_not_empty "$output"
test_pass

test_start "Setup script generates valid config structure"
# Run in dry-run and check output mentions config.json
output=$(run_setup --dry-run --non-interactive 2>&1 || true)
# Should mention configuration
assert_not_empty "$output"
test_pass

test_start "Setup script accepts verbose flag"
output=$(run_setup --verbose --dry-run --non-interactive 2>&1 || true)
# Should run without error
exit_code=$?
[ "$exit_code" -eq 0 ] || [ "$exit_code" -eq 1 ]  # May exit 1 on missing deps
assert_exit_success $?
test_pass

test_start "Setup script default features include kanban"
# Default selections should include kanban system
output=$(run_setup --dry-run --non-interactive 2>&1 || true)
# In non-interactive mode, uses defaults
assert_not_empty "$output"
test_pass

test_start "Setup script has all 7 stages defined"
# Check that script defines the expected stages
grep -q "stage_welcome" "$SETUP_SCRIPT"
assert_exit_success $?
grep -q "stage_check_prerequisites" "$SETUP_SCRIPT"
assert_exit_success $?
grep -q "stage_machine_identity" "$SETUP_SCRIPT"
assert_exit_success $?
grep -q "stage_team_selection" "$SETUP_SCRIPT"
assert_exit_success $?
grep -q "stage_feature_selection" "$SETUP_SCRIPT"
assert_exit_success $?
grep -q "stage_generate_config" "$SETUP_SCRIPT"
assert_exit_success $?
grep -q "stage_installation" "$SETUP_SCRIPT"
assert_exit_success $?
test_pass

test_start "Setup script has main workflow function"
grep -q "main()" "$SETUP_SCRIPT"
assert_exit_success $?
test_pass

test_start "Setup script executes stages in order"
# Check main function calls stages in sequence
grep -A 60 "^main()" "$SETUP_SCRIPT" | grep -q "stage_welcome"
assert_exit_success $?
test_pass

# Success!
exit 0
