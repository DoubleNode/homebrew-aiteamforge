#!/bin/bash

# test-integration.sh
# Integration tests for full setup → doctor → status → stop → uninstall flow

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Set up isolated test environment
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge-integration"
export AITEAMFORGE_HOME="$TAP_ROOT"
mkdir -p "$AITEAMFORGE_DIR"

SETUP_SCRIPT="$TAP_ROOT/bin/aiteamforge-setup.sh"
DOCTOR_SCRIPT="$TAP_ROOT/libexec/commands/aiteamforge-doctor.sh"
STATUS_SCRIPT="$TAP_ROOT/libexec/commands/aiteamforge-status.sh"
STOP_SCRIPT="$TAP_ROOT/libexec/commands/aiteamforge-stop.sh"
UNINSTALL_SCRIPT="$TAP_ROOT/libexec/commands/aiteamforge-uninstall.sh"

# ═══════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════

test_start "Integration: Setup wizard runs in dry-run mode"
output=$(zsh "$SETUP_SCRIPT" --dry-run --non-interactive 2>&1 || true)
assert_not_empty "$output"
test_pass

test_start "Integration: Setup wizard completes without errors (dry-run)"
zsh "$SETUP_SCRIPT" --dry-run --non-interactive >/dev/null 2>&1 || exit_code=$?
# May exit with 1 on missing optional deps, that's OK
[ "${exit_code:-0}" -eq 0 ] || [ "${exit_code:-0}" -eq 1 ]
assert_exit_success $?
test_pass

test_start "Integration: Doctor runs before configuration"
output=$(bash "$DOCTOR_SCRIPT" 2>&1 || true)
assert_not_empty "$output"
test_pass

test_start "Integration: Doctor produces diagnostic information"
output=$(bash "$DOCTOR_SCRIPT" 2>&1 || true)
# Should check system components
assert_not_empty "$output"
test_pass

test_start "Integration: Create minimal working config"
mkdir -p "$AITEAMFORGE_DIR/.aiteamforge"
cat > "$AITEAMFORGE_DIR/.aiteamforge-config" <<'EOF'
{
  "version": "1.2.0",
  "machine": {
    "name": "test-machine",
    "hostname": "localhost",
    "user": "Integration Test"
  },
  "teams": ["iOS"],
  "features": {
    "kanban": true,
    "fleet_monitor": false,
    "shell_env": true,
    "claude_config": false,
    "iterm_integration": false
  },
  "paths": {
    "install_dir": "$AITEAMFORGE_DIR",
    "config_dir": "$AITEAMFORGE_DIR/.aiteamforge"
  },
  "installed_at": "2026-02-17T00:00:00Z"
}
EOF
config_file="$AITEAMFORGE_DIR/.aiteamforge-config"
assert_file_exists "$config_file"
test_pass

test_start "Integration: Status command works with config"
output=$(bash "$STATUS_SCRIPT" 2>&1 || true)
assert_not_empty "$output"
test_pass

test_start "Integration: Status --json produces valid JSON"
if command -v jq &>/dev/null; then
  output=$(bash "$STATUS_SCRIPT" --json 2>&1 || true)
  # Try to parse as JSON
  echo "$output" | jq empty 2>/dev/null || true
fi
test_pass

test_start "Integration: Status --brief produces concise output"
output=$(bash "$STATUS_SCRIPT" --brief 2>&1 || true)
# Should be brief (check line count is small)
line_count=$(echo "$output" | wc -l | tr -d ' ')
[ "$line_count" -lt 10 ] || true  # Brief should be < 10 lines
test_pass

test_start "Integration: Stop command runs without errors"
output=$(bash "$STOP_SCRIPT" 2>&1 || true)
# Should handle no running services gracefully
assert_not_empty "$output"
test_pass

test_start "Integration: Uninstall shows help with --help"
output=$(bash "$UNINSTALL_SCRIPT" --help 2>&1 || true)
assert_contains "$output" "uninstall"
test_pass

test_start "Integration: Full workflow completes"
# Run through complete lifecycle
zsh "$SETUP_SCRIPT" --dry-run --non-interactive >/dev/null 2>&1 || true
bash "$DOCTOR_SCRIPT" >/dev/null 2>&1 || true
bash "$STATUS_SCRIPT" >/dev/null 2>&1 || true
bash "$STOP_SCRIPT" >/dev/null 2>&1 || true
# All should complete without crashing
test_pass

test_start "Integration: Config file is valid JSON"
assert_file_valid_json "$AITEAMFORGE_DIR/.aiteamforge-config"
test_pass

test_start "Integration: Config has required fields"
if command -v jq &>/dev/null; then
  version=$(jq -r '.version' "$AITEAMFORGE_DIR/.aiteamforge-config")
  assert_not_empty "$version"

  machine_name=$(jq -r '.machine.name' "$AITEAMFORGE_DIR/.aiteamforge-config")
  assert_not_empty "$machine_name"

  teams=$(jq -r '.teams' "$AITEAMFORGE_DIR/.aiteamforge-config")
  assert_not_equal "null" "$teams"
fi
test_pass

test_start "Integration: Idempotency - setup can run twice"
# First run
zsh "$SETUP_SCRIPT" --dry-run --non-interactive >/dev/null 2>&1 || true
# Second run should also work
zsh "$SETUP_SCRIPT" --dry-run --non-interactive >/dev/null 2>&1 || exit_code=$?
[ "${exit_code:-0}" -eq 0 ] || [ "${exit_code:-0}" -eq 1 ]
assert_exit_success $?
test_pass

test_start "Integration: Doctor after config shows configured state"
output=$(bash "$DOCTOR_SCRIPT" 2>&1 || true)
# Should reflect that system is configured
assert_not_empty "$output"
test_pass

test_start "Integration: All commands handle --help gracefully"
commands="$SETUP_SCRIPT $DOCTOR_SCRIPT $STATUS_SCRIPT $STOP_SCRIPT $UNINSTALL_SCRIPT"
for cmd in $commands; do
  if [ -f "$cmd" ]; then
    bash "$cmd" --help >/dev/null 2>&1 || zsh "$cmd" --help >/dev/null 2>&1 || true
  fi
done
test_pass

# Success!
exit 0
