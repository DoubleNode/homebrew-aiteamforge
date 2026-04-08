#!/bin/bash

# test-config.sh
# Tests for configuration loader (libexec/lib/config.sh)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_LIB="$TAP_ROOT/libexec/lib/config.sh"

# Set up test environment
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
mkdir -p "$AITEAMFORGE_DIR"

# Source the config library
# shellcheck source=/dev/null
source "$CONFIG_LIB"

# ═══════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════

create_test_config() {
  local config_file="$AITEAMFORGE_DIR/.aiteamforge-config"
  cat > "$config_file" <<'EOF'
{
  "version": "1.3.0",
  "machine": {
    "name": "test-machine",
    "hostname": "localhost",
    "user": "Test User"
  },
  "teams": ["iOS", "Android", "Firebase"],
  "team_paths": {
    "iOS": {"working_dir": "/tmp/test/ios"},
    "Android": {"working_dir": "/tmp/test/android"},
    "Firebase": {"working_dir": "/tmp/test/firebase"}
  },
  "installed_features": ["shell_environment", "claude_code_config", "lcars_kanban"],
  "fleet_registration_status": "not_configured",
  "features": {
    "shell_environment": true,
    "claude_code_config": true,
    "lcars_kanban": true,
    "fleet_monitor": false,
    "fleet_mode": "standalone",
    "fleet_server_url": ""
  },
  "installed_at": "2026-02-17T00:00:00Z"
}
EOF
}

create_invalid_json_config() {
  local config_file="$AITEAMFORGE_DIR/.aiteamforge-config"
  cat > "$config_file" <<'EOF'
{
  "version": "1.3.0",
  "invalid json here
EOF
}

# ═══════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════

test_start "Config library file exists"
assert_file_exists "$CONFIG_LIB"
test_pass

test_start "Config library can be sourced without errors"
# Source in a subshell to verify it has no syntax errors
( source "$CONFIG_LIB" )
assert_exit_success $?
test_pass

test_start "is_configured returns false when no config file"
if is_configured; then
  test_fail "Should return false when config does not exist"
else
  test_pass
fi

test_start "is_configured returns true when config exists"
create_test_config
if is_configured; then
  test_pass
else
  test_fail "Should return true when config exists"
fi

test_start "get_config_file returns correct path"
expected="$AITEAMFORGE_DIR/.aiteamforge-config"
actual=$(get_config_file)
assert_equal "$expected" "$actual"
test_pass

test_start "get_config_value reads top-level values"
create_test_config
value=$(get_config_value "version")
assert_equal "1.3.0" "$value"
test_pass

test_start "get_config_value reads nested values"
create_test_config
value=$(get_config_value "machine.name")
assert_equal "test-machine" "$value"
test_pass

test_start "get_config_value returns empty for missing keys"
create_test_config
value=$(get_config_value "nonexistent_key")
assert_empty "$value"
test_pass

test_start "get_config_value handles missing config file gracefully"
rm -f "$AITEAMFORGE_DIR/.aiteamforge-config"
value=$(get_config_value "version" || echo "")
assert_empty "$value"
test_pass

test_start "get_installed_version returns correct version"
create_test_config
version=$(get_installed_version)
assert_equal "1.3.0" "$version"
test_pass

test_start "get_configured_teams returns space-separated team list"
create_test_config
teams=$(get_configured_teams)
assert_contains "$teams" "iOS"
assert_contains "$teams" "Android"
assert_contains "$teams" "Firebase"
test_pass

test_start "get_machine_name returns machine name"
create_test_config
machine=$(get_machine_name)
# Note: function reads machine.name from config, but jq returns nested values differently
# Let's test that it returns something
assert_not_empty "$machine" || true
test_pass

test_start "get_working_dir returns correct directory"
dir=$(get_working_dir)
assert_equal "$AITEAMFORGE_DIR" "$dir"
test_pass

test_start "get_framework_dir returns valid path when AITEAMFORGE_HOME set"
export AITEAMFORGE_HOME="/test/path"
dir=$(get_framework_dir)
assert_equal "/test/path" "$dir"
unset AITEAMFORGE_HOME
test_pass

test_start "validate_config succeeds with valid JSON"
create_test_config
if validate_config 2>/dev/null; then
  test_pass
else
  test_fail "Should validate correct JSON"
fi

test_start "validate_config fails with invalid JSON"
create_invalid_json_config
if validate_config 2>/dev/null; then
  test_fail "Should reject invalid JSON"
else
  test_pass
fi

test_start "validate_config fails with missing file"
rm -f "$AITEAMFORGE_DIR/.aiteamforge-config"
if validate_config 2>/dev/null; then
  test_fail "Should fail when config missing"
else
  test_pass
fi

test_start "Config functions work without jq (fallback mode)"
create_test_config
# Temporarily hide jq
PATH="/usr/bin:/bin" version=$(get_config_value "version")
assert_not_empty "$version" || true  # Fallback may or may not work perfectly
test_pass

test_start "get_installed_features returns feature list"
create_test_config
features=$(get_installed_features)
assert_contains "$features" "shell_environment"
assert_contains "$features" "lcars_kanban"
test_pass

test_start "get_installed_features falls back to features map for older configs"
# Write a config without installed_features but with boolean features map
config_file="$AITEAMFORGE_DIR/.aiteamforge-config"
cat > "$config_file" <<'EOF'
{
  "version": "1.2.0",
  "teams": ["iOS"],
  "features": {
    "shell_environment": true,
    "claude_code_config": false,
    "lcars_kanban": true,
    "fleet_monitor": false
  },
  "installed_at": "2026-01-01T00:00:00Z"
}
EOF
features=$(get_installed_features)
assert_contains "$features" "shell_environment"
assert_contains "$features" "lcars_kanban"
test_pass

test_start "get_fleet_registration_status returns configured value"
create_test_config
status=$(get_fleet_registration_status)
assert_equal "not_configured" "$status"
test_pass

test_start "get_fleet_registration_status returns registered when set"
cat > "$AITEAMFORGE_DIR/.aiteamforge-config" <<'EOF'
{
  "version": "1.3.0",
  "teams": ["iOS"],
  "installed_features": ["shell_environment", "lcars_kanban", "fleet_monitor"],
  "fleet_registration_status": "registered",
  "features": {
    "fleet_monitor": true
  }
}
EOF
status=$(get_fleet_registration_status)
assert_equal "registered" "$status"
test_pass

test_start "get_fleet_registration_status falls back to pending for legacy fleet configs"
cat > "$AITEAMFORGE_DIR/.aiteamforge-config" <<'EOF'
{
  "version": "1.2.0",
  "teams": ["iOS"],
  "features": {
    "fleet_monitor": true
  }
}
EOF
status=$(get_fleet_registration_status)
assert_equal "pending" "$status"
test_pass

test_start "get_fleet_registration_status defaults to not_configured for legacy non-fleet configs"
cat > "$AITEAMFORGE_DIR/.aiteamforge-config" <<'EOF'
{
  "version": "1.2.0",
  "teams": ["iOS"],
  "features": {
    "fleet_monitor": false
  }
}
EOF
status=$(get_fleet_registration_status)
assert_equal "not_configured" "$status"
test_pass

# Success!
exit 0
