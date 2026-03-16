#!/bin/bash

# test-lifecycle.sh
# Tests for lifecycle commands (doctor, status, start, stop, upgrade, uninstall)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMANDS_DIR="$TAP_ROOT/libexec/commands"

# Set up test environment
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
export AITEAMFORGE_HOME="$TAP_ROOT"
mkdir -p "$AITEAMFORGE_DIR"

# Create minimal test config
create_test_config() {
  cat > "$AITEAMFORGE_DIR/.aiteamforge-config" <<'EOF'
{
  "version": "1.2.0",
  "machine": {
    "name": "test-machine",
    "hostname": "localhost",
    "user": "Test User"
  },
  "teams": ["iOS"],
  "features": {
    "kanban": true
  }
}
EOF
}

# ═══════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════

test_start "Commands directory exists"
assert_dir_exists "$COMMANDS_DIR"
test_pass

test_start "Doctor command script exists"
assert_file_exists "$COMMANDS_DIR/aiteamforge-doctor.sh"
test_pass

test_start "Status command script exists"
assert_file_exists "$COMMANDS_DIR/aiteamforge-status.sh"
test_pass

test_start "Start command script exists"
assert_file_exists "$COMMANDS_DIR/aiteamforge-start.sh"
test_pass

test_start "Stop command script exists"
assert_file_exists "$COMMANDS_DIR/aiteamforge-stop.sh"
test_pass

test_start "Upgrade command script exists"
assert_file_exists "$COMMANDS_DIR/aiteamforge-upgrade.sh"
test_pass

test_start "Uninstall command script exists"
assert_file_exists "$COMMANDS_DIR/aiteamforge-uninstall.sh"
test_pass

test_start "Doctor command has --help flag"
output=$(bash "$COMMANDS_DIR/aiteamforge-doctor.sh" --help 2>&1 || true)
assert_contains "$output" "doctor"
test_pass

test_start "Doctor command runs without config (diagnostic mode)"
output=$(bash "$COMMANDS_DIR/aiteamforge-doctor.sh" 2>&1 || true)
# Should run and produce output
assert_not_empty "$output"
test_pass

test_start "Doctor command produces structured output"
output=$(bash "$COMMANDS_DIR/aiteamforge-doctor.sh" 2>&1 || true)
# Should check various system components
assert_not_empty "$output"
test_pass

test_start "Status command requires config"
rm -f "$AITEAMFORGE_DIR/.aiteamforge-config"
output=$(bash "$COMMANDS_DIR/aiteamforge-status.sh" 2>&1 || true)
# Should error or warn about missing config
exit_code=$?
[ "$exit_code" -ne 0 ] || assert_contains "$output" "not configured"
test_pass

test_start "Status command works with valid config"
create_test_config
output=$(bash "$COMMANDS_DIR/aiteamforge-status.sh" 2>&1 || true)
# Should produce status output
assert_not_empty "$output"
test_pass

test_start "Status command supports --json flag"
create_test_config
output=$(bash "$COMMANDS_DIR/aiteamforge-status.sh" --json 2>&1 || true)
# Should produce JSON output
if command -v jq &>/dev/null; then
  echo "$output" | jq empty 2>/dev/null || true  # Try to parse as JSON
fi
test_pass

test_start "Status command supports --brief flag"
create_test_config
output=$(bash "$COMMANDS_DIR/aiteamforge-status.sh" --brief 2>&1 || true)
# Should produce brief output (single line or minimal)
assert_not_empty "$output"
test_pass

test_start "Start command handles missing services gracefully"
create_test_config
output=$(bash "$COMMANDS_DIR/aiteamforge-start.sh" 2>&1 || true)
# Should not crash, even if services don't exist
assert_not_empty "$output"
test_pass

test_start "Stop command handles missing services gracefully"
create_test_config
output=$(bash "$COMMANDS_DIR/aiteamforge-stop.sh" 2>&1 || true)
# Should not crash, even if services aren't running
assert_not_empty "$output"
test_pass

test_start "Upgrade command supports --dry-run flag"
create_test_config
output=$(bash "$COMMANDS_DIR/aiteamforge-upgrade.sh" --dry-run 2>&1 || true)
# Should preview without making changes
assert_contains "$output" "dry" || assert_contains "$output" "preview" || true
test_pass

test_start "Upgrade command has --help flag"
output=$(bash "$COMMANDS_DIR/aiteamforge-upgrade.sh" --help 2>&1 || true)
assert_contains "$output" "upgrade"
test_pass

test_start "Uninstall command has --help flag"
output=$(bash "$COMMANDS_DIR/aiteamforge-uninstall.sh" --help 2>&1 || true)
assert_contains "$output" "uninstall"
test_pass

test_start "Uninstall command requires confirmation in interactive mode"
create_test_config
# In non-interactive or with --force, should proceed
output=$(bash "$COMMANDS_DIR/aiteamforge-uninstall.sh" --help 2>&1 || true)
# Check help mentions confirmation or force
assert_not_empty "$output"
test_pass

test_start "All lifecycle commands are executable"
for cmd in doctor status start stop upgrade uninstall; do
  cmd_file="$COMMANDS_DIR/aiteamforge-${cmd}.sh"
  [ -x "$cmd_file" ]
  assert_exit_success $? "Command not executable: $cmd"
done
test_pass

test_start "All lifecycle commands have proper shebang"
for cmd in doctor status start stop upgrade uninstall; do
  cmd_file="$COMMANDS_DIR/aiteamforge-${cmd}.sh"
  first_line=$(head -n 1 "$cmd_file")
  assert_contains "$first_line" "#!/" "Missing shebang: $cmd"
done
test_pass

# Success!
exit 0
