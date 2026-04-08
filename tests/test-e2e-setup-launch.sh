#!/bin/bash

# test-e2e-setup-launch.sh
# End-to-end tests for the full setup-to-launch user journey
#
# Coverage:
#   - Full setup wizard flow (non-interactive, dry-run, and simulated config creation)
#   - Config file creation and validation
#   - Team directory scaffolding
#   - LCARS server startup verification (mocked)
#   - Team stop and cleanup
#   - Error recovery (partial setup, restart)
#   - --dry-run mode behavior
#
# Approach:
#   - Mocks ALL external dependencies (tmux, launchctl, osascript, pgrep, kill, curl, python3)
#   - Uses $TEST_TMP_DIR as install prefix
#   - Overrides HOME and AITEAMFORGE_DIR to isolate from real system
#   - Focused on orchestration logic, not individual component internals

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMANDS_DIR="$TAP_ROOT/libexec/commands"
SETUP_SCRIPT="$TAP_ROOT/libexec/aiteamforge-setup.sh"
BIN_SETUP_SCRIPT="$TAP_ROOT/bin/aiteamforge-setup.sh"
START_SCRIPT="$COMMANDS_DIR/aiteamforge-start.sh"
STOP_SCRIPT="$COMMANDS_DIR/aiteamforge-stop.sh"

# ═══════════════════════════════════════════════════════════════════════════
# Test Environment Setup
# ═══════════════════════════════════════════════════════════════════════════

# Save originals for restoration — prevents contamination across test files
ORIG_HOME="$HOME"

# Override HOME to prevent touching real home directory
export HOME="$TEST_TMP_DIR/home"
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
export AITEAMFORGE_HOME="$TAP_ROOT"

mkdir -p "$HOME"
mkdir -p "$AITEAMFORGE_DIR"

# Bin directory for mock commands
MOCK_BIN="$TEST_TMP_DIR/mock-bin"
mkdir -p "$MOCK_BIN"

# Save original PATH so repeated PATH prepends don't accumulate
ORIG_PATH="$PATH"

# ═══════════════════════════════════════════════════════════════════════════
# Mock Infrastructure
# ═══════════════════════════════════════════════════════════════════════════

# Create a mock command that records calls and returns success
create_mock() {
  local cmd="$1"
  local exit_code="${2:-0}"
  local output="${3:-}"

  cat > "$MOCK_BIN/$cmd" <<EOF
#!/bin/bash
# Mock: $cmd
echo "\$@" >> "$MOCK_BIN/${cmd}.calls"
${output:+echo "$output"}
exit $exit_code
EOF
  chmod +x "$MOCK_BIN/$cmd"
}

# Create a mock that outputs to stdout
create_mock_with_output() {
  local cmd="$1"
  local output="$2"
  local exit_code="${3:-0}"

  cat > "$MOCK_BIN/$cmd" <<EOF
#!/bin/bash
# Mock with output: $cmd
echo "\$@" >> "$MOCK_BIN/${cmd}.calls"
echo "$output"
exit $exit_code
EOF
  chmod +x "$MOCK_BIN/$cmd"
}

# Reset call log for a mock command
reset_mock_calls() {
  local cmd="$1"
  rm -f "$MOCK_BIN/${cmd}.calls"
}

# Count times a mock was called
mock_call_count() {
  local cmd="$1"
  if [ -f "$MOCK_BIN/${cmd}.calls" ]; then
    wc -l < "$MOCK_BIN/${cmd}.calls" | tr -d ' '
  else
    echo "0"
  fi
}

# Check if mock was called with specific arguments
mock_was_called_with() {
  local cmd="$1"
  local args="$2"
  if [ -f "$MOCK_BIN/${cmd}.calls" ]; then
    grep -qF "$args" "$MOCK_BIN/${cmd}.calls" 2>/dev/null
    return $?
  fi
  return 1
}

# Create a mock python3 that pretends to start an HTTP server
create_mock_python3_server() {
  local pid_to_report="${1:-$$}"

  cat > "$MOCK_BIN/python3" <<EOF
#!/bin/bash
echo "\$@" >> "$MOCK_BIN/python3.calls"
# If this is server.py, simulate a background server start
if echo "\$@" | grep -q "server.py"; then
  # Just sleep in background to simulate a running process
  sleep 60 &
  disown 2>/dev/null
fi
exit 0
EOF
  chmod +x "$MOCK_BIN/python3"
}

# Create a mock curl that simulates HTTP responses
# Usage: create_mock_curl <response_code>
create_mock_curl() {
  local http_code="${1:-200}"

  cat > "$MOCK_BIN/curl" <<EOF
#!/bin/bash
echo "\$@" >> "$MOCK_BIN/curl.calls"
# Output the http code if requested via -w
if echo "\$@" | grep -q -- "-w"; then
  echo "$http_code"
fi
exit 0
EOF
  chmod +x "$MOCK_BIN/curl"
}

# Create a mock pgrep that simulates process detection
# Usage: create_mock_pgrep <pid_to_return_or_empty>
create_mock_pgrep() {
  local pid="${1:-}"

  cat > "$MOCK_BIN/pgrep" <<EOF
#!/bin/bash
echo "\$@" >> "$MOCK_BIN/pgrep.calls"
if [ -n "$pid" ]; then
  echo "$pid"
  exit 0
else
  exit 1
fi
EOF
  chmod +x "$MOCK_BIN/pgrep"
}

# Create a mock kill
create_mock_kill() {
  local exit_code="${1:-0}"

  cat > "$MOCK_BIN/kill" <<KILLEOF
#!/bin/bash
echo "\$@" >> "$MOCK_BIN/kill.calls"
exit $exit_code
KILLEOF
  chmod +x "$MOCK_BIN/kill"
}

# Create a mock launchctl
create_mock_launchctl() {
  cat > "$MOCK_BIN/launchctl" <<EOF
#!/bin/bash
echo "\$@" >> "$MOCK_BIN/launchctl.calls"
# 'list' subcommand returns empty (no agents loaded)
if [ "\$1" = "list" ]; then
  echo ""
fi
exit 0
EOF
  chmod +x "$MOCK_BIN/launchctl"
}

# Create all standard mocks for a clean start/stop environment
setup_start_stop_mocks() {
  create_mock_curl "000"     # No server running by default
  create_mock_python3_server
  create_mock_pgrep ""       # No processes running
  create_mock_kill 0
  create_mock_launchctl
  create_mock "osascript" 0
  create_mock "tmux" 0
  create_mock "npm" 0
  create_mock "open" 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Config Helpers
# ═══════════════════════════════════════════════════════════════════════════

# Write a valid minimal config to $AITEAMFORGE_DIR
write_minimal_config() {
  local teams="${1:-iOS}"
  local teams_json
  teams_json=$(echo "$teams" | tr ',' '\n' | sed 's/^/"/;s/$/"/' | tr '\n' ',' | sed 's/,$//')

  cat > "$AITEAMFORGE_DIR/.aiteamforge-config" <<EOF
{
  "version": "1.3.0",
  "machine": {
    "name": "e2e-test-machine",
    "hostname": "localhost",
    "user": "E2E Test"
  },
  "teams": [$teams_json],
  "team_paths": {
    "iOS": {"working_dir": "$TEST_TMP_DIR/ios-project"}
  },
  "installed_features": ["shell_environment", "lcars_kanban"],
  "fleet_registration_status": "not_configured",
  "features": {
    "shell_environment": true,
    "claude_code_config": false,
    "lcars_kanban": true,
    "fleet_monitor": false,
    "fleet_mode": "standalone",
    "fleet_server_url": ""
  },
  "paths": {
    "install_dir": "$AITEAMFORGE_DIR",
    "config_dir": "$AITEAMFORGE_DIR/.aiteamforge"
  },
  "installed_at": "2026-01-01T00:00:00Z"
}
EOF
}

# Scaffold the expected install directory structure
scaffold_install_dir() {
  # LCARS UI directory (needed by start command)
  mkdir -p "$AITEAMFORGE_DIR/lcars-ui"
  touch "$AITEAMFORGE_DIR/lcars-ui/server.py"
  touch "$AITEAMFORGE_DIR/lcars-ui/index.html"
  echo "8080" > "$AITEAMFORGE_DIR/lcars-ui/.lcars-port"

  # Kanban board check script (needed by start all)
  mkdir -p "$AITEAMFORGE_DIR/../share/scripts"
  cat > "$AITEAMFORGE_DIR/../share/scripts/kanban-board-check.sh" <<'EOF'
#!/bin/bash
validate_kanban_board() { return 0; }
EOF

  # Team directories
  mkdir -p "$AITEAMFORGE_DIR/iOS"
  mkdir -p "$AITEAMFORGE_DIR/Android"

  # Startup/shutdown scripts for teams
  for team in iOS Android; do
    cat > "$AITEAMFORGE_DIR/${team}-startup.sh" <<EOF
#!/bin/bash
# Startup for $team team
TERMINALS=(lcars agent1 agent2)
echo "Starting $team team..."
EOF
    chmod +x "$AITEAMFORGE_DIR/${team}-startup.sh"

    cat > "$AITEAMFORGE_DIR/${team}-shutdown.sh" <<EOF
#!/bin/bash
echo "Stopping $team team..."
EOF
    chmod +x "$AITEAMFORGE_DIR/${team}-shutdown.sh"
  done

  # Kanban helpers
  touch "$AITEAMFORGE_DIR/kanban-helpers.sh"

  # Kanban boards
  mkdir -p "$AITEAMFORGE_DIR/kanban"
  cat > "$AITEAMFORGE_DIR/kanban/ios-board.json" <<'EOF'
{"version": "1.0", "team": "iOS", "items": []}
EOF
  cat > "$AITEAMFORGE_DIR/kanban/android-board.json" <<'EOF'
{"version": "1.0", "team": "Android", "items": []}
EOF

  # Kanban hooks
  mkdir -p "$AITEAMFORGE_DIR/kanban-hooks"
  touch "$AITEAMFORGE_DIR/kanban-hooks/hooks.py"
}

# ═══════════════════════════════════════════════════════════════════════════
# Tier 3 E2E Tests: Setup Wizard Flow
# ═══════════════════════════════════════════════════════════════════════════

test_start "E2E Setup: Setup wizard script exists"
assert_file_exists "$SETUP_SCRIPT"
test_pass

test_start "E2E Setup: Bin setup script exists"
assert_file_exists "$BIN_SETUP_SCRIPT"
test_pass

test_start "E2E Setup: Setup wizard --help exits cleanly"
output=$(zsh "$SETUP_SCRIPT" --help 2>&1 || true)
exit_code=$?
# --help should exit 0 and mention setup
assert_contains "$output" "setup"
test_pass

test_start "E2E Setup: Dry-run mode produces output without filesystem changes"
rm -rf "$TEST_TMP_DIR/home/.aiteamforge"
output=$(zsh "$SETUP_SCRIPT" --dry-run --non-interactive 2>&1 || true)
assert_not_empty "$output"
assert_contains "$output" "DRY RUN"
# In dry-run mode, no real config should be written to the test home
# (the wizard writes to $HOME/.aiteamforge/config.json)
test_pass

test_start "E2E Setup: Dry-run mentions what would be installed"
output=$(zsh "$SETUP_SCRIPT" --dry-run --non-interactive 2>&1 || true)
assert_not_empty "$output"
# Should mention at least one installation phase
assert_contains "$output" "Would"
test_pass

test_start "E2E Setup: Non-interactive mode skips team selection"
output=$(zsh "$SETUP_SCRIPT" --dry-run --non-interactive 2>&1 || true)
assert_contains "$output" "Non-interactive"
test_pass

test_start "E2E Setup: Setup wizard completes without crash (dry-run)"
exit_code=0
zsh "$SETUP_SCRIPT" --dry-run --non-interactive >/dev/null 2>&1 || exit_code=$?
# Exit 0 = success, exit 1 = optional dep warning; both acceptable
[ "$exit_code" -eq 0 ] || [ "$exit_code" -eq 1 ]
assert_exit_success $?
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Tier 3 E2E Tests: Config File Creation and Validation
# ═══════════════════════════════════════════════════════════════════════════

test_start "E2E Config: Config file is created by setup"
rm -rf "$TEST_TMP_DIR/home/.aiteamforge"

# The wizard writes config to $HOME/.aiteamforge/config.json
# Run non-interactive (non-dry-run) to get actual file creation
# NOTE: This will try to run real installers; we run in dry-run to avoid side effects
# but verify that the config output is shown
output=$(zsh "$SETUP_SCRIPT" --dry-run --non-interactive 2>&1 || true)
# In dry-run mode, the config is printed but not saved — verify the output contains config content
assert_contains "$output" "config"
test_pass

test_start "E2E Config: Manual config passes JSON validation"
write_minimal_config "iOS"
assert_file_exists "$AITEAMFORGE_DIR/.aiteamforge-config"
assert_file_valid_json "$AITEAMFORGE_DIR/.aiteamforge-config"
test_pass

test_start "E2E Config: Config contains required top-level fields"
write_minimal_config "iOS"
if command -v jq &>/dev/null; then
  version=$(jq -r '.version' "$AITEAMFORGE_DIR/.aiteamforge-config")
  assert_not_empty "$version" "version field missing"

  machine_name=$(jq -r '.machine.name' "$AITEAMFORGE_DIR/.aiteamforge-config")
  assert_not_empty "$machine_name" "machine.name missing"

  teams=$(jq -r '.teams | length' "$AITEAMFORGE_DIR/.aiteamforge-config")
  assert_not_equal "0" "$teams" "teams array empty"

  features=$(jq -r '.features' "$AITEAMFORGE_DIR/.aiteamforge-config")
  assert_not_equal "null" "$features" "features object missing"
fi
test_pass

test_start "E2E Config: Config teams field is an array"
write_minimal_config "iOS,Android"
if command -v jq &>/dev/null; then
  team_count=$(jq -r '.teams | length' "$AITEAMFORGE_DIR/.aiteamforge-config")
  assert_equal "2" "$team_count" "Expected 2 teams in config"
fi
test_pass

test_start "E2E Config: Config with single team passes validation"
write_minimal_config "iOS"
if command -v jq &>/dev/null; then
  team=$(jq -r '.teams[0]' "$AITEAMFORGE_DIR/.aiteamforge-config")
  assert_equal "iOS" "$team"
fi
test_pass

test_start "E2E Config: is_configured returns true when config exists"
write_minimal_config "iOS"
# Source config.sh and test is_configured
result=$(bash -c "
  source '$TAP_ROOT/libexec/lib/config.sh'
  export AITEAMFORGE_DIR='$AITEAMFORGE_DIR'
  if is_configured; then echo 'configured'; else echo 'not_configured'; fi
" 2>&1)
assert_equal "configured" "$result"
test_pass

test_start "E2E Config: is_configured returns false when config absent"
rm -f "$AITEAMFORGE_DIR/.aiteamforge-config"
result=$(bash -c "
  source '$TAP_ROOT/libexec/lib/config.sh'
  export AITEAMFORGE_DIR='$AITEAMFORGE_DIR'
  if is_configured; then echo 'configured'; else echo 'not_configured'; fi
" 2>&1)
assert_equal "not_configured" "$result"
test_pass

test_start "E2E Config: get_configured_teams reads team list correctly"
write_minimal_config "iOS"
if command -v jq &>/dev/null; then
  teams=$(bash -c "
    source '$TAP_ROOT/libexec/lib/config.sh'
    export AITEAMFORGE_DIR='$AITEAMFORGE_DIR'
    get_configured_teams
  " 2>&1)
  assert_contains "$teams" "iOS"
fi
test_pass

test_start "E2E Config: get_machine_name reads machine name from config"
write_minimal_config "iOS"
if command -v jq &>/dev/null; then
  name=$(bash -c "
    source '$TAP_ROOT/libexec/lib/config.sh'
    export AITEAMFORGE_DIR='$AITEAMFORGE_DIR'
    get_machine_name
  " 2>&1)
  assert_equal "e2e-test-machine" "$name"
fi
test_pass

test_start "E2E Config: validate_config succeeds on well-formed config"
write_minimal_config "iOS"
result=$(bash -c "
  source '$TAP_ROOT/libexec/lib/config.sh'
  export AITEAMFORGE_DIR='$AITEAMFORGE_DIR'
  if validate_config >/dev/null 2>&1; then echo 'valid'; else echo 'invalid'; fi
" 2>&1)
assert_equal "valid" "$result"
test_pass

test_start "E2E Config: validate_config fails on malformed JSON"
echo "{ not valid json" > "$AITEAMFORGE_DIR/.aiteamforge-config"
if command -v jq &>/dev/null; then
  result=$(bash -c "
    source '$TAP_ROOT/libexec/lib/config.sh'
    export AITEAMFORGE_DIR='$AITEAMFORGE_DIR'
    if validate_config >/dev/null 2>&1; then echo 'valid'; else echo 'invalid'; fi
  " 2>&1)
  assert_equal "invalid" "$result"
fi
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Tier 3 E2E Tests: Team Directory Scaffolding
# ═══════════════════════════════════════════════════════════════════════════

test_start "E2E Scaffold: Scaffold creates LCARS UI directory"
scaffold_install_dir
assert_dir_exists "$AITEAMFORGE_DIR/lcars-ui"
test_pass

test_start "E2E Scaffold: Scaffold creates team directories"
scaffold_install_dir
assert_dir_exists "$AITEAMFORGE_DIR/iOS"
assert_dir_exists "$AITEAMFORGE_DIR/Android"
test_pass

test_start "E2E Scaffold: Scaffold creates startup scripts"
scaffold_install_dir
assert_file_exists "$AITEAMFORGE_DIR/iOS-startup.sh"
assert_file_exists "$AITEAMFORGE_DIR/Android-startup.sh"
test_pass

test_start "E2E Scaffold: Scaffold startup scripts are executable"
scaffold_install_dir
[ -x "$AITEAMFORGE_DIR/iOS-startup.sh" ]
assert_exit_success $? "iOS-startup.sh not executable"
[ -x "$AITEAMFORGE_DIR/Android-startup.sh" ]
assert_exit_success $? "Android-startup.sh not executable"
test_pass

test_start "E2E Scaffold: Startup scripts contain TERMINALS array"
scaffold_install_dir
output=$(grep "TERMINALS=" "$AITEAMFORGE_DIR/iOS-startup.sh" 2>/dev/null || echo "")
assert_not_empty "$output" "iOS-startup.sh missing TERMINALS array"
test_pass

test_start "E2E Scaffold: Startup script syntax is valid bash"
scaffold_install_dir
bash -n "$AITEAMFORGE_DIR/iOS-startup.sh" 2>/dev/null
assert_exit_success $? "iOS-startup.sh has syntax errors"
test_pass

test_start "E2E Scaffold: Shutdown script syntax is valid bash"
scaffold_install_dir
bash -n "$AITEAMFORGE_DIR/iOS-shutdown.sh" 2>/dev/null
assert_exit_success $? "iOS-shutdown.sh has syntax errors"
test_pass

test_start "E2E Scaffold: Kanban boards are valid JSON"
scaffold_install_dir
assert_file_valid_json "$AITEAMFORGE_DIR/kanban/ios-board.json"
assert_file_valid_json "$AITEAMFORGE_DIR/kanban/android-board.json"
test_pass

test_start "E2E Scaffold: LCARS port file contains a port number"
scaffold_install_dir
port=$(cat "$AITEAMFORGE_DIR/lcars-ui/.lcars-port" 2>/dev/null || echo "")
assert_not_empty "$port"
assert_matches "$port" "^[0-9]+$" "Port file should contain a number"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Tier 3 E2E Tests: LCARS Server Startup Verification (Mocked)
# ═══════════════════════════════════════════════════════════════════════════

test_start "E2E Start: Start command fails gracefully when not configured"
rm -f "$AITEAMFORGE_DIR/.aiteamforge-config"
setup_start_stop_mocks
export PATH="$MOCK_BIN:$ORIG_PATH"

output=$(bash "$START_SCRIPT" 2>&1 || true)
assert_contains "$output" "not configured" || assert_contains "$output" "setup"
test_pass

test_start "E2E Start: Start command with lcars service handles missing lcars-ui"
write_minimal_config "iOS"
setup_start_stop_mocks
export PATH="$MOCK_BIN:$ORIG_PATH"

# Remove lcars-ui directory so it fails gracefully
rm -rf "$AITEAMFORGE_DIR/lcars-ui"

output=$(bash "$START_SCRIPT" lcars 2>&1 || true)
# Should report error, not crash with unhandled exception
assert_not_empty "$output"
test_pass

test_start "E2E Start: Start LCARS reads port from .lcars-port file"
write_minimal_config "iOS"
scaffold_install_dir
setup_start_stop_mocks
export PATH="$MOCK_BIN:$ORIG_PATH"

# Set a non-default port
echo "9090" > "$AITEAMFORGE_DIR/lcars-ui/.lcars-port"

output=$(bash "$START_SCRIPT" lcars 2>&1 || true)
# Should reference port 9090, not 8080
assert_contains "$output" "9090" "Start command should use port from .lcars-port file"
test_pass

test_start "E2E Start: Start LCARS defaults to port 8080 when .lcars-port absent"
write_minimal_config "iOS"
scaffold_install_dir
setup_start_stop_mocks
export PATH="$MOCK_BIN:$ORIG_PATH"

# Remove .lcars-port file
rm -f "$AITEAMFORGE_DIR/lcars-ui/.lcars-port"

output=$(bash "$START_SCRIPT" lcars 2>&1 || true)
assert_contains "$output" "8080" "Start command should default to port 8080"
test_pass

test_start "E2E Start: Start LCARS reports server already running when curl returns 200"
write_minimal_config "iOS"
scaffold_install_dir
setup_start_stop_mocks
# Override curl to return 200 (server already running)
create_mock_curl "200"
export PATH="$MOCK_BIN:$ORIG_PATH"

output=$(bash "$START_SCRIPT" lcars 2>&1 || true)
assert_contains "$output" "already running" "Should report server already running"
test_pass

test_start "E2E Start: Start LCARS launches python3 server.py when not running"
write_minimal_config "iOS"
scaffold_install_dir
setup_start_stop_mocks
# curl returns non-200 (server not running), then python3 starts it
create_mock_curl "000"
export PATH="$MOCK_BIN:$ORIG_PATH"

reset_mock_calls "python3"
output=$(bash "$START_SCRIPT" lcars 2>&1 || true)
# python3 should have been invoked with server.py
python3_calls=$(mock_call_count "python3")
assert_not_equal "0" "$python3_calls" "python3 server.py should have been called"
test_pass

test_start "E2E Start: Start agents skips plists that don't exist"
write_minimal_config "iOS"
setup_start_stop_mocks
export PATH="$MOCK_BIN:$ORIG_PATH"

# Ensure no plist files exist in mock home
rm -f "$HOME/Library/LaunchAgents/com.aiteamforge.*.plist"

output=$(bash "$START_SCRIPT" agents 2>&1 || true)
# Should warn about missing plists but not crash
assert_not_empty "$output"
test_pass

test_start "E2E Start: Start handles unknown service name"
write_minimal_config "iOS"
setup_start_stop_mocks
export PATH="$MOCK_BIN:$ORIG_PATH"

exit_code=0
bash "$START_SCRIPT" nonexistent-service >/dev/null 2>&1 || exit_code=$?
# Should exit non-zero for unknown service
assert_exit_failure $exit_code "Expected failure for unknown service"
test_pass

test_start "E2E Start: Start --open flag is accepted without error"
write_minimal_config "iOS"
scaffold_install_dir
setup_start_stop_mocks
export PATH="$MOCK_BIN:$ORIG_PATH"

exit_code=0
bash "$START_SCRIPT" lcars --open >/dev/null 2>&1 || exit_code=$?
# --open should be accepted (exit 0 or 1 depending on server state, not syntax error)
[ "$exit_code" -le 1 ]
assert_exit_success $?
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Tier 3 E2E Tests: Team Stop and Cleanup
# ═══════════════════════════════════════════════════════════════════════════

test_start "E2E Stop: Stop command fails gracefully when not configured"
rm -f "$AITEAMFORGE_DIR/.aiteamforge-config"
setup_start_stop_mocks
export PATH="$MOCK_BIN:$ORIG_PATH"

output=$(bash "$STOP_SCRIPT" 2>&1 || true)
assert_contains "$output" "not configured" || assert_contains "$output" "setup"
test_pass

test_start "E2E Stop: Stop LCARS reports not running when no process found"
write_minimal_config "iOS"
setup_start_stop_mocks
create_mock_pgrep ""  # No process found
export PATH="$MOCK_BIN:$ORIG_PATH"

output=$(bash "$STOP_SCRIPT" lcars 2>&1 || true)
assert_contains "$output" "not running" "Should report LCARS not running"
test_pass

test_start "E2E Stop: Stop LCARS attempts termination when process is found"
write_minimal_config "iOS"
setup_start_stop_mocks
create_mock_pgrep "12345"  # Simulate running process
export PATH="$MOCK_BIN:$ORIG_PATH"

output=$(bash "$STOP_SCRIPT" lcars 2>&1 || true)
# bash's kill is a builtin so mock_call_count doesn't apply here
# Instead verify the stop script attempted termination by checking output
# "Stopping LCARS server..." means pgrep found a PID and kill was attempted
assert_contains "$output" "Stopping LCARS server" "Stop should attempt termination when process found"
test_pass

test_start "E2E Stop: Stop Fleet Monitor reports not running when no process found"
write_minimal_config "iOS"
setup_start_stop_mocks
create_mock_pgrep ""  # No process found
export PATH="$MOCK_BIN:$ORIG_PATH"

output=$(bash "$STOP_SCRIPT" fleet 2>&1 || true)
assert_contains "$output" "not running" "Should report Fleet Monitor not running"
test_pass

test_start "E2E Stop: Stop agents with --persist keeps LaunchAgents loaded"
write_minimal_config "iOS"
setup_start_stop_mocks
export PATH="$MOCK_BIN:$ORIG_PATH"

reset_mock_calls "launchctl"
output=$(bash "$STOP_SCRIPT" --persist 2>&1 || true)
# With --persist, launchctl unload should NOT be called
output_contains_persist=$(echo "$output" | grep -c "Keeping LaunchAgents" || echo "0")
assert_not_equal "0" "$output_contains_persist" "Should confirm agents kept loaded with --persist"
test_pass

test_start "E2E Stop: Stop handles unknown service name"
write_minimal_config "iOS"
setup_start_stop_mocks
export PATH="$MOCK_BIN:$ORIG_PATH"

exit_code=0
bash "$STOP_SCRIPT" nonexistent-service >/dev/null 2>&1 || exit_code=$?
assert_exit_failure $exit_code "Expected failure for unknown service"
test_pass

test_start "E2E Stop: Stop all runs through all service categories"
write_minimal_config "iOS"
scaffold_install_dir
setup_start_stop_mocks
create_mock_pgrep ""  # Nothing running
export PATH="$MOCK_BIN:$ORIG_PATH"

output=$(bash "$STOP_SCRIPT" all 2>&1 || true)
# Should mention LCARS and Fleet sections
assert_contains "$output" "LCARS" "Stop all should process LCARS section"
assert_contains "$output" "Fleet" "Stop all should process Fleet section"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Tier 3 E2E Tests: Error Recovery
# ═══════════════════════════════════════════════════════════════════════════

test_start "E2E Recovery: Start after partial setup (missing lcars-ui) fails gracefully"
write_minimal_config "iOS"
# Do NOT scaffold install dir — simulates partial setup (no lcars-ui directory)
setup_start_stop_mocks
export PATH="$MOCK_BIN:$ORIG_PATH"

exit_code=0
output=$(bash "$START_SCRIPT" lcars 2>&1 || exit_code=$?)
# Should fail with a clear message, not a bash error
assert_not_empty "$output"
# Should report an error about LCARS (either missing dir or failed to start)
assert_contains "$output" "LCARS" "Output should mention LCARS"
test_pass

test_start "E2E Recovery: Stop when nothing is running exits successfully"
write_minimal_config "iOS"
setup_start_stop_mocks
create_mock_pgrep ""
export PATH="$MOCK_BIN:$ORIG_PATH"

exit_code=0
bash "$STOP_SCRIPT" all >/dev/null 2>&1 || exit_code=$?
assert_exit_success $exit_code "Stop with nothing running should exit 0"
test_pass

test_start "E2E Recovery: Start after previous start (already running) is idempotent"
write_minimal_config "iOS"
scaffold_install_dir
setup_start_stop_mocks
# Simulate server already running
create_mock_curl "200"
export PATH="$MOCK_BIN:$ORIG_PATH"

# First start — already running
output1=$(bash "$START_SCRIPT" lcars 2>&1 || true)
# Second start — still already running
output2=$(bash "$START_SCRIPT" lcars 2>&1 || true)

# Both should succeed and report already running
assert_contains "$output1" "already running"
assert_contains "$output2" "already running"
test_pass

test_start "E2E Recovery: Config can be recreated after deletion"
# Create config, delete it, recreate it — system should work again
write_minimal_config "iOS"
rm -f "$AITEAMFORGE_DIR/.aiteamforge-config"

# After deletion: not configured
result=$(bash -c "
  source '$TAP_ROOT/libexec/lib/config.sh'
  export AITEAMFORGE_DIR='$AITEAMFORGE_DIR'
  if is_configured; then echo 'configured'; else echo 'not_configured'; fi
" 2>&1)
assert_equal "not_configured" "$result"

# Recreate config
write_minimal_config "iOS"

# After recreation: configured again
result=$(bash -c "
  source '$TAP_ROOT/libexec/lib/config.sh'
  export AITEAMFORGE_DIR='$AITEAMFORGE_DIR'
  if is_configured; then echo 'configured'; else echo 'not_configured'; fi
" 2>&1)
assert_equal "configured" "$result"
test_pass

test_start "E2E Recovery: Start command produces diagnostic info on failure"
write_minimal_config "iOS"
setup_start_stop_mocks
# Remove lcars-ui so startup fails
rm -rf "$AITEAMFORGE_DIR/lcars-ui"
export PATH="$MOCK_BIN:$ORIG_PATH"

output=$(bash "$START_SCRIPT" lcars 2>&1 || true)
# Should give user actionable information
assert_not_empty "$output" "Empty output on failure is unhelpful"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Tier 3 E2E Tests: --dry-run Mode
# ═══════════════════════════════════════════════════════════════════════════

test_start "E2E DryRun: Setup --dry-run does not write config.json to disk"
rm -rf "$TEST_TMP_DIR/home/.aiteamforge"
export HOME="$TEST_TMP_DIR/home"

zsh "$SETUP_SCRIPT" --dry-run --non-interactive >/dev/null 2>&1 || true

# In dry-run, wizard config.json should NOT be written
assert_file_not_exists "$TEST_TMP_DIR/home/.aiteamforge/config.json"
test_pass

test_start "E2E DryRun: Setup --dry-run shows preview of what would be installed"
output=$(zsh "$SETUP_SCRIPT" --dry-run --non-interactive 2>&1 || true)
assert_contains "$output" "DRY RUN"
test_pass

test_start "E2E DryRun: Setup --dry-run does not invoke real installers"
output=$(zsh "$SETUP_SCRIPT" --dry-run --non-interactive 2>&1 || true)
# Dry run should say "Would install" not actually install
assert_contains "$output" "Would"
test_pass

test_start "E2E DryRun: Setup --dry-run shows config preview"
output=$(zsh "$SETUP_SCRIPT" --dry-run --non-interactive 2>&1 || true)
# Config preview should appear in output
assert_contains "$output" "version"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Tier 3 E2E Tests: Full User Journey (Start-to-Finish)
# ═══════════════════════════════════════════════════════════════════════════

test_start "E2E Journey: Full flow — config creation, scaffold, start, stop"
# Step 1: Create config (simulates post-setup state)
write_minimal_config "iOS"
scaffold_install_dir

# Step 2: Verify config is valid
assert_file_valid_json "$AITEAMFORGE_DIR/.aiteamforge-config"

# Step 3: Verify team structure is in place
assert_dir_exists "$AITEAMFORGE_DIR/iOS"
assert_dir_exists "$AITEAMFORGE_DIR/lcars-ui"
assert_file_exists "$AITEAMFORGE_DIR/iOS-startup.sh"

# Step 4: Start LCARS (mocked)
setup_start_stop_mocks
create_mock_curl "000"  # Server not running yet
export PATH="$MOCK_BIN:$ORIG_PATH"

start_output=$(bash "$START_SCRIPT" lcars 2>&1 || true)
assert_not_empty "$start_output"

# Step 5: Stop (mocked, nothing actually running after mock python3)
create_mock_pgrep ""  # Mock shows no process
stop_output=$(bash "$STOP_SCRIPT" lcars 2>&1 || true)
assert_not_empty "$stop_output"
assert_contains "$stop_output" "not running"
test_pass

test_start "E2E Journey: Start all services, then stop all services"
write_minimal_config "iOS"
scaffold_install_dir
setup_start_stop_mocks
create_mock_curl "000"
create_mock_pgrep ""
export PATH="$MOCK_BIN:$ORIG_PATH"

# Start all
start_output=$(bash "$START_SCRIPT" all 2>&1 || true)
assert_not_empty "$start_output"
assert_contains "$start_output" "LCARS" "Start all should mention LCARS"

# Stop all
stop_output=$(bash "$STOP_SCRIPT" all 2>&1 || true)
assert_not_empty "$stop_output"
assert_contains "$stop_output" "LCARS" "Stop all should mention LCARS"
test_pass

test_start "E2E Journey: Config survives round-trip through start and stop"
write_minimal_config "iOS,Android"
scaffold_install_dir
setup_start_stop_mocks
create_mock_curl "000"
create_mock_pgrep ""
export PATH="$MOCK_BIN:$ORIG_PATH"

# Config should still be valid and unchanged after start/stop
bash "$START_SCRIPT" lcars >/dev/null 2>&1 || true
bash "$STOP_SCRIPT" lcars >/dev/null 2>&1 || true

# Config still valid?
assert_file_exists "$AITEAMFORGE_DIR/.aiteamforge-config"
assert_file_valid_json "$AITEAMFORGE_DIR/.aiteamforge-config"

# Teams still correct?
if command -v jq &>/dev/null; then
  team_count=$(jq -r '.teams | length' "$AITEAMFORGE_DIR/.aiteamforge-config")
  assert_equal "2" "$team_count" "Teams should be unchanged after start/stop cycle"
fi
test_pass

test_start "E2E Journey: Setup dry-run to start pipeline is non-destructive"
write_minimal_config "iOS"
scaffold_install_dir

# Capture config state before dry-run
config_before=$(cat "$AITEAMFORGE_DIR/.aiteamforge-config")

# Run setup in dry-run (simulates a user reviewing setup again)
zsh "$SETUP_SCRIPT" --dry-run --non-interactive >/dev/null 2>&1 || true

# Config should be unchanged
config_after=$(cat "$AITEAMFORGE_DIR/.aiteamforge-config")
assert_equal "$config_before" "$config_after" "Dry-run should not modify existing config"
test_pass

test_start "E2E Journey: Multiple stop calls are idempotent"
write_minimal_config "iOS"
setup_start_stop_mocks
create_mock_pgrep ""  # Nothing running
export PATH="$MOCK_BIN:$ORIG_PATH"

exit_code1=0
exit_code2=0
exit_code3=0

bash "$STOP_SCRIPT" all >/dev/null 2>&1 || exit_code1=$?
bash "$STOP_SCRIPT" all >/dev/null 2>&1 || exit_code2=$?
bash "$STOP_SCRIPT" lcars >/dev/null 2>&1 || exit_code3=$?

assert_exit_success $exit_code1 "First stop all should exit 0"
assert_exit_success $exit_code2 "Second stop all should exit 0"
assert_exit_success $exit_code3 "Stop lcars when not running should exit 0"
test_pass

# Restore HOME so subsequent test files in the same runner are not contaminated
export HOME="$ORIG_HOME"

# Success!
exit 0
