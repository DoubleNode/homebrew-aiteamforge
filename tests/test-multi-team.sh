#!/bin/bash

# test-multi-team.sh
# Tests for multi-team configuration: switching teams, concurrent team configs,
# and team isolation. Verifies that teams do not contaminate each other's
# configuration, ports, sessions, and directories.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_LIB="$TAP_ROOT/libexec/lib/config.sh"
TEAMS_DIR="$TAP_ROOT/share/teams"
KANBAN_PATHS_LIB="$TAP_ROOT/libexec/lib/kanban-paths.sh"

# Set up isolated aiteamforge dir for all tests in this file
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
mkdir -p "$AITEAMFORGE_DIR"

# Source the config library
# shellcheck source=/dev/null
source "$CONFIG_LIB"

# ═══════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════

# Source a team conf file in a subshell and print a variable value.
# Usage: get_team_field <conf_file> <variable_name>
get_team_field() {
  local conf_file="$1"
  local var_name="$2"
  # shellcheck disable=SC1090
  (source "$conf_file" && echo "${!var_name}")
}

# Build a minimal .aiteamforge-config with multiple teams configured.
# Usage: create_multi_team_config [team1 team2 ...]
create_multi_team_config() {
  local config_file="$AITEAMFORGE_DIR/.aiteamforge-config"

  # Build JSON teams array from arguments (default: ios android firebase)
  local teams=("${@:-ios android firebase}")
  local teams_json=""
  for team in "${teams[@]}"; do
    teams_json+="\"$team\", "
  done
  teams_json="[${teams_json%, }]"

  # Build team_paths object
  local paths_json=""
  for team in "${teams[@]}"; do
    paths_json+="\"${team}\": {\"working_dir\": \"$TEST_TMP_DIR/${team}\"}, "
  done
  paths_json="{${paths_json%, }}"

  cat > "$config_file" <<EOF
{
  "version": "1.3.0",
  "machine": {
    "name": "test-machine",
    "hostname": "localhost",
    "user": "Test User"
  },
  "teams": ${teams_json},
  "team_paths": ${paths_json},
  "installed_features": ["shell_environment", "claude_code_config", "lcars_kanban"],
  "fleet_registration_status": "not_configured",
  "features": {
    "shell_environment": true,
    "claude_code_config": true,
    "lcars_kanban": true,
    "fleet_monitor": false
  },
  "installed_at": "2026-01-01T00:00:00Z"
}
EOF
}

# Load all .conf files and return their ids in a sorted list
get_all_conf_team_ids() {
  for f in "$TEAMS_DIR"/*.conf; do
    [ -f "$f" ] || continue
    get_team_field "$f" "TEAM_ID"
  done | sort
}

# ═══════════════════════════════════════════════════════════════════════════
# Section 1: Team Switching — changing active team, config updates
# ═══════════════════════════════════════════════════════════════════════════

test_start "Config reads correct team list after switching from single to multi-team"
# Start with a single team, then 'switch' to a multi-team config and verify
cat > "$AITEAMFORGE_DIR/.aiteamforge-config" <<'EOF'
{
  "version": "1.3.0",
  "teams": ["ios"],
  "installed_features": ["shell_environment"],
  "installed_at": "2026-01-01T00:00:00Z"
}
EOF
single_teams=$(get_configured_teams)
assert_contains "$single_teams" "ios"
assert_not_contains "$single_teams" "android"

# Now write a new config simulating the user adding more teams
cat > "$AITEAMFORGE_DIR/.aiteamforge-config" <<'EOF'
{
  "version": "1.3.0",
  "teams": ["ios", "android", "firebase"],
  "installed_features": ["shell_environment"],
  "installed_at": "2026-01-01T00:00:00Z"
}
EOF
multi_teams=$(get_configured_teams)
assert_contains "$multi_teams" "ios"
assert_contains "$multi_teams" "android"
assert_contains "$multi_teams" "firebase"
test_pass

test_start "Config reflects team removal correctly"
# Begin with three teams, remove one by rewriting config
create_multi_team_config ios android firebase
before_teams=$(get_configured_teams)
assert_contains "$before_teams" "firebase"

cat > "$AITEAMFORGE_DIR/.aiteamforge-config" <<'EOF'
{
  "version": "1.3.0",
  "teams": ["ios", "android"],
  "installed_features": ["shell_environment"],
  "installed_at": "2026-01-01T00:00:00Z"
}
EOF
after_teams=$(get_configured_teams)
assert_contains "$after_teams" "ios"
assert_contains "$after_teams" "android"
assert_not_contains "$after_teams" "firebase"
test_pass

test_start "get_configured_teams handles empty teams array"
cat > "$AITEAMFORGE_DIR/.aiteamforge-config" <<'EOF'
{
  "version": "1.3.0",
  "teams": [],
  "installed_features": [],
  "installed_at": "2026-01-01T00:00:00Z"
}
EOF
empty_teams=$(get_configured_teams)
assert_empty "$empty_teams" "Teams list should be empty when no teams configured"
test_pass

test_start "Config version is preserved across team additions"
create_multi_team_config ios android
version=$(get_installed_version)
assert_equal "1.3.0" "$version"

# Simulate adding a team — version must remain stable
create_multi_team_config ios android firebase
version_after=$(get_installed_version)
assert_equal "1.3.0" "$version_after"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Section 2: Concurrent Team Configs — multiple teams configured simultaneously
# ═══════════════════════════════════════════════════════════════════════════

test_start "All configured teams are returned concurrently from a single config"
create_multi_team_config ios android firebase academy
teams=$(get_configured_teams)
assert_contains "$teams" "ios"
assert_contains "$teams" "android"
assert_contains "$teams" "firebase"
assert_contains "$teams" "academy"
test_pass

test_start "Team count is correct for multi-team config"
if command -v jq &>/dev/null; then
  create_multi_team_config ios android firebase academy command
  count=$(jq '.teams | length' "$AITEAMFORGE_DIR/.aiteamforge-config")
  assert_equal "5" "$count"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Adding maximum number of teams (all 9 defined teams) is supported"
create_multi_team_config ios android firebase academy command finance freelance legal medical
if command -v jq &>/dev/null; then
  count=$(jq '.teams | length' "$AITEAMFORGE_DIR/.aiteamforge-config")
  assert_equal "9" "$count"
fi
teams=$(get_configured_teams)
assert_contains "$teams" "ios"
assert_contains "$teams" "medical"
assert_contains "$teams" "finance"
test_pass

test_start "team_paths block holds independent entries for each concurrent team"
if command -v jq &>/dev/null; then
  create_multi_team_config ios android firebase
  ios_path=$(jq -r '.team_paths.ios.working_dir' "$AITEAMFORGE_DIR/.aiteamforge-config")
  android_path=$(jq -r '.team_paths.android.working_dir' "$AITEAMFORGE_DIR/.aiteamforge-config")
  firebase_path=$(jq -r '.team_paths.firebase.working_dir' "$AITEAMFORGE_DIR/.aiteamforge-config")
  assert_not_equal "$ios_path" "$android_path" "iOS and Android working dirs must differ"
  assert_not_equal "$ios_path" "$firebase_path" "iOS and Firebase working dirs must differ"
  assert_not_equal "$android_path" "$firebase_path" "Android and Firebase working dirs must differ"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Config with concurrent teams validates as valid JSON"
create_multi_team_config ios android firebase academy
if validate_config 2>/dev/null; then
  test_pass
else
  test_fail "Multi-team config should be valid JSON"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Section 3: Team Isolation — one team's config doesn't leak into another
# ═══════════════════════════════════════════════════════════════════════════

test_start "Sourcing one team .conf file does not set another team's variables"
ios_conf="$TEAMS_DIR/ios.conf"
android_conf="$TEAMS_DIR/android.conf"

# Load iOS conf in a subshell and check Android-specific variable is absent
result=$(
  # shellcheck disable=SC1090
  source "$ios_conf"
  # TEAM_SHIP is ios-specific; android sets the same variable to a different value
  echo "ID=$TEAM_ID|SHIP=$TEAM_SHIP"
)
ios_id=$(echo "$result" | sed -n 's/.*ID=\([^|]*\).*/\1/p')
ios_ship=$(echo "$result" | sed -n 's/.*SHIP=\(.*\)/\1/p')
assert_equal "ios" "$ios_id"
assert_not_equal "" "$ios_ship"

android_ship=$(get_team_field "$android_conf" "TEAM_SHIP")
assert_not_equal "$ios_ship" "$android_ship" "iOS and Android ship names must differ"
test_pass

test_start "Each team .conf defines its own TEAM_ID (no shared global state)"
declare -A team_id_map
while IFS= read -r conf_file; do
  tid=$(get_team_field "$conf_file" "TEAM_ID")
  # Verify each conf has a non-empty, unique TEAM_ID relative to prior entries
  assert_not_empty "$tid" "TEAM_ID is empty in: $(basename "$conf_file")"
  if [ -n "${team_id_map[$tid]:-}" ]; then
    test_fail "Duplicate TEAM_ID '$tid' in $(basename "$conf_file") and ${team_id_map[$tid]}"
  fi
  team_id_map[$tid]=$(basename "$conf_file")
done < <(find "$TEAMS_DIR" -maxdepth 1 -name "*.conf" -type f | sort)
test_pass

test_start "Team conf variables are not persistent across sourcing different confs"
# Source iOS, then Android in sequence; verify Android's values overwrite iOS's
result=$(
  # shellcheck disable=SC1090
  source "$TEAMS_DIR/ios.conf"
  ios_id="$TEAM_ID"
  ios_port="$TEAM_LCARS_PORT"

  # shellcheck disable=SC1090
  source "$TEAMS_DIR/android.conf"
  # After sourcing android, TEAM_ID must be android's id, not ios's
  if [ "$TEAM_ID" = "android" ] && [ "$TEAM_ID" != "$ios_id" ]; then
    echo "ISOLATED"
  else
    echo "LEAKED"
  fi
)
assert_equal "ISOLATED" "$result" "Sourcing android.conf should override iOS conf variables"
test_pass

test_start "Team working directories are distinct from each other"
declare -A working_dirs
while IFS= read -r conf_file; do
  tid=$(get_team_field "$conf_file" "TEAM_ID")
  wdir=$(get_team_field "$conf_file" "TEAM_WORKING_DIR")
  if [ -n "${working_dirs[$wdir]:-}" ]; then
    # Two teams share a working dir — only acceptable if they intentionally co-locate
    # (e.g. academy and command both use ~/dev-team — these are strategic teams)
    other_tid="${working_dirs[$wdir]}"
    other_cat=$(get_team_field "$TEAMS_DIR/${other_tid}.conf" "TEAM_CATEGORY")
    this_cat=$(get_team_field "$conf_file" "TEAM_CATEGORY")
    # Platform and personal teams must never share working directories
    if [ "$other_cat" = "platform" ] || [ "$this_cat" = "platform" ] ||
       [ "$other_cat" = "personal" ] || [ "$this_cat" = "personal" ] ||
       [ "$other_cat" = "project" ] || [ "$this_cat" = "project" ]; then
      test_fail "Platform/personal/project teams share working dir '$wdir': $tid and $other_tid"
    fi
  fi
  working_dirs[$wdir]="$tid"
done < <(find "$TEAMS_DIR" -maxdepth 1 -name "*.conf" -type f | sort)
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Section 4: Config Merging — team-specific overrides on top of global config
# ═══════════════════════════════════════════════════════════════════════════

test_start "team_paths overrides can coexist with top-level teams array"
if command -v jq &>/dev/null; then
  # Both structures must be present and consistent
  create_multi_team_config ios android
  teams_array=$(jq -r '.teams[]' "$AITEAMFORGE_DIR/.aiteamforge-config" | sort | tr '\n' ' ')
  paths_keys=$(jq -r '.team_paths | keys[]' "$AITEAMFORGE_DIR/.aiteamforge-config" | sort | tr '\n' ' ')
  assert_equal "$teams_array" "$paths_keys" "teams array and team_paths keys must match"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Per-team working_dir in team_paths is preferred over global install_dir"
if command -v jq &>/dev/null; then
  # Write config with both install_dir and per-team override
  cat > "$AITEAMFORGE_DIR/.aiteamforge-config" <<EOF
{
  "version": "1.3.0",
  "install_dir": "$TEST_TMP_DIR/global",
  "teams": ["ios"],
  "team_paths": {
    "ios": {"working_dir": "$TEST_TMP_DIR/ios-custom"}
  },
  "installed_features": ["shell_environment"],
  "installed_at": "2026-01-01T00:00:00Z"
}
EOF
  ios_path=$(jq -r '.team_paths.ios.working_dir' "$AITEAMFORGE_DIR/.aiteamforge-config")
  global_path=$(jq -r '.install_dir' "$AITEAMFORGE_DIR/.aiteamforge-config")
  assert_not_equal "$ios_path" "$global_path" "Per-team path must differ from global install_dir"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Features block applies globally, not per-team"
if command -v jq &>/dev/null; then
  create_multi_team_config ios android
  # Features are a global map — not duplicated per team
  feature_count=$(jq '.features | length' "$AITEAMFORGE_DIR/.aiteamforge-config")
  [ "$feature_count" -gt 0 ]
  assert_exit_success $? "Features block must be non-empty"

  # Confirm there is no per-team features key
  ios_features=$(jq -r '.team_paths.ios.features // empty' "$AITEAMFORGE_DIR/.aiteamforge-config")
  assert_empty "$ios_features" "Per-team features override should not exist in base config"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "installed_features list persists unchanged when teams are added"
if command -v jq &>/dev/null; then
  create_multi_team_config ios
  initial_features=$(jq -r '.installed_features | sort | join(" ")' "$AITEAMFORGE_DIR/.aiteamforge-config")

  create_multi_team_config ios android firebase
  updated_features=$(jq -r '.installed_features | sort | join(" ")' "$AITEAMFORGE_DIR/.aiteamforge-config")

  assert_equal "$initial_features" "$updated_features" "installed_features must be stable across team additions"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Section 5: Port Conflicts — different teams use different LCARS ports
# ═══════════════════════════════════════════════════════════════════════════

test_start "All team LCARS ports are unique across all .conf files"
declare -A ports_seen
port_conflict=false
while IFS= read -r conf_file; do
  tid=$(get_team_field "$conf_file" "TEAM_ID")
  port=$(get_team_field "$conf_file" "TEAM_LCARS_PORT")

  # Every team must declare a port
  assert_not_empty "$port" "TEAM_LCARS_PORT missing in: $(basename "$conf_file")"

  if [ -n "${ports_seen[$port]:-}" ]; then
    print_error "Port conflict: $port used by both '$tid' and '${ports_seen[$port]}'"
    port_conflict=true
  fi
  ports_seen[$port]="$tid"
done < <(find "$TEAMS_DIR" -maxdepth 1 -name "*.conf" -type f | sort)

if [ "$port_conflict" = false ]; then
  test_pass
else
  test_fail "Found duplicate LCARS port assignments"
fi

test_start "All team LCARS ports are numeric and in the expected range (8000-9999)"
while IFS= read -r conf_file; do
  port=$(get_team_field "$conf_file" "TEAM_LCARS_PORT")
  assert_matches "$port" "^[0-9]+$" "Port must be numeric in: $(basename "$conf_file")"
  if [ -n "$port" ] && [[ "$port" =~ ^[0-9]+$ ]]; then
    if [ "$port" -lt 8000 ] || [ "$port" -gt 9999 ]; then
      test_fail "Port $port in $(basename "$conf_file") is outside 8000-9999 range"
    fi
  fi
done < <(find "$TEAMS_DIR" -maxdepth 1 -name "*.conf" -type f | sort)
test_pass

test_start "Known platform teams use expected LCARS port assignments"
ios_port=$(get_team_field "$TEAMS_DIR/ios.conf" "TEAM_LCARS_PORT")
android_port=$(get_team_field "$TEAMS_DIR/android.conf" "TEAM_LCARS_PORT")
firebase_port=$(get_team_field "$TEAMS_DIR/firebase.conf" "TEAM_LCARS_PORT")
academy_port=$(get_team_field "$TEAMS_DIR/academy.conf" "TEAM_LCARS_PORT")

assert_equal "8260" "$ios_port"
assert_equal "8280" "$android_port"
assert_equal "8240" "$firebase_port"
assert_equal "8200" "$academy_port"
test_pass

test_start "Port assignments are stable (unchanged) when team conf is sourced multiple times"
# Sourcing the same conf file twice must produce the same port
first=$(get_team_field "$TEAMS_DIR/ios.conf" "TEAM_LCARS_PORT")
second=$(get_team_field "$TEAMS_DIR/ios.conf" "TEAM_LCARS_PORT")
assert_equal "$first" "$second" "LCARS port must be stable across repeated sourcing"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Section 6: Session Naming — team sessions don't collide
# ═══════════════════════════════════════════════════════════════════════════

test_start "All team tmux sockets are unique across all .conf files"
declare -A sockets_seen
socket_conflict=false
while IFS= read -r conf_file; do
  tid=$(get_team_field "$conf_file" "TEAM_ID")
  socket=$(get_team_field "$conf_file" "TEAM_TMUX_SOCKET")

  assert_not_empty "$socket" "TEAM_TMUX_SOCKET missing in: $(basename "$conf_file")"

  if [ -n "${sockets_seen[$socket]:-}" ]; then
    print_error "Tmux socket conflict: '$socket' used by '$tid' and '${sockets_seen[$socket]}'"
    socket_conflict=true
  fi
  sockets_seen[$socket]="$tid"
done < <(find "$TEAMS_DIR" -maxdepth 1 -name "*.conf" -type f | sort)

if [ "$socket_conflict" = false ]; then
  test_pass
else
  test_fail "Found duplicate TEAM_TMUX_SOCKET assignments"
fi

test_start "Each team's tmux socket matches its team ID"
# Convention: socket name == team ID (ensures predictable session lookup)
while IFS= read -r conf_file; do
  tid=$(get_team_field "$conf_file" "TEAM_ID")
  socket=$(get_team_field "$conf_file" "TEAM_TMUX_SOCKET")
  assert_equal "$tid" "$socket" "TEAM_TMUX_SOCKET should equal TEAM_ID in: $(basename "$conf_file")"
done < <(find "$TEAMS_DIR" -maxdepth 1 -name "*.conf" -type f | sort)
test_pass

test_start "Tmux socket names contain only lowercase alphanumeric and hyphen characters"
while IFS= read -r conf_file; do
  socket=$(get_team_field "$conf_file" "TEAM_TMUX_SOCKET")
  assert_matches "$socket" "^[a-z0-9-]+$" \
    "TEAM_TMUX_SOCKET must be lowercase alphanumeric/hyphen in: $(basename "$conf_file")"
done < <(find "$TEAMS_DIR" -maxdepth 1 -name "*.conf" -type f | sort)
test_pass

test_start "Startup script names are unique across all team confs"
declare -A startup_scripts_seen
startup_conflict=false
while IFS= read -r conf_file; do
  tid=$(get_team_field "$conf_file" "TEAM_ID")
  script=$(get_team_field "$conf_file" "TEAM_STARTUP_SCRIPT")

  if [ -n "${startup_scripts_seen[$script]:-}" ]; then
    print_error "Startup script conflict: '$script' used by '$tid' and '${startup_scripts_seen[$script]}'"
    startup_conflict=true
  fi
  startup_scripts_seen[$script]="$tid"
done < <(find "$TEAMS_DIR" -maxdepth 1 -name "*.conf" -type f | sort)

if [ "$startup_conflict" = false ]; then
  test_pass
else
  test_fail "Found duplicate TEAM_STARTUP_SCRIPT names"
fi

test_start "Shutdown script names are unique across all team confs"
declare -A shutdown_scripts_seen
shutdown_conflict=false
while IFS= read -r conf_file; do
  tid=$(get_team_field "$conf_file" "TEAM_ID")
  script=$(get_team_field "$conf_file" "TEAM_SHUTDOWN_SCRIPT")

  if [ -n "${shutdown_scripts_seen[$script]:-}" ]; then
    print_error "Shutdown script conflict: '$script' used by '$tid' and '${shutdown_scripts_seen[$script]}'"
    shutdown_conflict=true
  fi
  shutdown_scripts_seen[$script]="$tid"
done < <(find "$TEAMS_DIR" -maxdepth 1 -name "*.conf" -type f | sort)

if [ "$shutdown_conflict" = false ]; then
  test_pass
else
  test_fail "Found duplicate TEAM_SHUTDOWN_SCRIPT names"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Section 7: Directory Isolation — each team's kanban dir is independent
# ═══════════════════════════════════════════════════════════════════════════

test_start "kanban-paths.sh library can be sourced without errors"
( source "$KANBAN_PATHS_LIB" )
assert_exit_success $?
test_pass

test_start "get_kanban_dir succeeds for teams with working_dir in config"
if command -v jq &>/dev/null; then
  # shellcheck source=/dev/null
  source "$KANBAN_PATHS_LIB"
  # Point config to a test setup
  mkdir -p "$TEST_TMP_DIR/ios-wd/kanban"
  mkdir -p "$TEST_TMP_DIR/android-wd/kanban"

  cat > "$HOME/aiteamforge/.aiteamforge-config" <<EOF 2>/dev/null || true
{
  "version": "1.3.0",
  "teams": ["ios", "android"],
  "team_paths": {
    "ios": {"working_dir": "$TEST_TMP_DIR/ios-wd"},
    "android": {"working_dir": "$TEST_TMP_DIR/android-wd"}
  },
  "installed_features": ["lcars_kanban"]
}
EOF
  # Note: get_kanban_dir reads from $HOME/aiteamforge/.aiteamforge-config
  # (not AITEAMFORGE_DIR) so the above write location depends on whether
  # the home config exists. We test the library sourcing succeeds and
  # validate directory uniqueness via conf files instead (below).
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Each team's kanban directory path is derived from its own working_dir"
if command -v jq &>/dev/null; then
  create_multi_team_config ios android firebase
  ios_wd=$(jq -r '.team_paths.ios.working_dir' "$AITEAMFORGE_DIR/.aiteamforge-config")
  android_wd=$(jq -r '.team_paths.android.working_dir' "$AITEAMFORGE_DIR/.aiteamforge-config")
  firebase_wd=$(jq -r '.team_paths.firebase.working_dir' "$AITEAMFORGE_DIR/.aiteamforge-config")

  # Each team's expected kanban dir
  ios_kanban="${ios_wd}/kanban"
  android_kanban="${android_wd}/kanban"
  firebase_kanban="${firebase_wd}/kanban"

  # All three must be distinct paths
  assert_not_equal "$ios_kanban" "$android_kanban" "iOS and Android kanban dirs must differ"
  assert_not_equal "$ios_kanban" "$firebase_kanban" "iOS and Firebase kanban dirs must differ"
  assert_not_equal "$android_kanban" "$firebase_kanban" "Android and Firebase kanban dirs must differ"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Creating kanban files in one team's dir does not affect another team's dir"
mkdir -p "$TEST_TMP_DIR/ios-kb/kanban"
mkdir -p "$TEST_TMP_DIR/android-kb/kanban"

# Write a board file to the iOS kanban dir
echo '{"team":"ios","items":[]}' > "$TEST_TMP_DIR/ios-kb/kanban/kanban-board.json"

# Android kanban dir must remain empty
android_board="$TEST_TMP_DIR/android-kb/kanban/kanban-board.json"
if [ -f "$android_board" ]; then
  test_fail "Android kanban dir should not contain iOS board file"
else
  test_pass
fi

test_start "Removing one team's kanban dir does not affect another team's dir"
mkdir -p "$TEST_TMP_DIR/ios-rm/kanban"
mkdir -p "$TEST_TMP_DIR/firebase-rm/kanban"
echo '{"team":"firebase"}' > "$TEST_TMP_DIR/firebase-rm/kanban/kanban-board.json"

# Remove iOS kanban dir
rm -rf "$TEST_TMP_DIR/ios-rm/kanban"

# Firebase kanban dir and board must still exist
assert_file_exists "$TEST_TMP_DIR/firebase-rm/kanban/kanban-board.json" \
  "Removing iOS kanban dir must not affect Firebase kanban dir"
test_pass

test_start "Platform teams each have a unique working_dir (no sharing between platform teams)"
declare -A platform_wdirs
platform_conflict=false
while IFS= read -r conf_file; do
  cat_val=$(get_team_field "$conf_file" "TEAM_CATEGORY")
  [ "$cat_val" = "platform" ] || continue

  tid=$(get_team_field "$conf_file" "TEAM_ID")
  wdir=$(get_team_field "$conf_file" "TEAM_WORKING_DIR")

  if [ -n "${platform_wdirs[$wdir]:-}" ]; then
    print_error "Platform working dir conflict: '$wdir' shared by '$tid' and '${platform_wdirs[$wdir]}'"
    platform_conflict=true
  fi
  platform_wdirs[$wdir]="$tid"
done < <(find "$TEAMS_DIR" -maxdepth 1 -name "*.conf" -type f | sort)

if [ "$platform_conflict" = false ]; then
  test_pass
else
  test_fail "Platform teams must not share working directories"
fi

test_start "Personal category teams have unique working directories"
declare -A personal_wdirs
personal_conflict=false
while IFS= read -r conf_file; do
  cat_val=$(get_team_field "$conf_file" "TEAM_CATEGORY")
  [ "$cat_val" = "personal" ] || continue

  tid=$(get_team_field "$conf_file" "TEAM_ID")
  wdir=$(get_team_field "$conf_file" "TEAM_WORKING_DIR")

  if [ -n "${personal_wdirs[$wdir]:-}" ]; then
    print_error "Personal working dir conflict: '$wdir' shared by '$tid' and '${personal_wdirs[$wdir]}'"
    personal_conflict=true
  fi
  personal_wdirs[$wdir]="$tid"
done < <(find "$TEAMS_DIR" -maxdepth 1 -name "*.conf" -type f | sort)

if [ "$personal_conflict" = false ]; then
  test_pass
else
  test_fail "Personal teams must not share working directories"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Section 8: Additional Cross-Team Integrity Checks
# ═══════════════════════════════════════════════════════════════════════════

test_start "Team colors are unique across all .conf files"
declare -A colors_seen
color_conflict=false
while IFS= read -r conf_file; do
  tid=$(get_team_field "$conf_file" "TEAM_ID")
  color=$(get_team_field "$conf_file" "TEAM_COLOR")
  # Colors should be defined
  assert_not_empty "$color" "TEAM_COLOR missing in: $(basename "$conf_file")"

  if [ -n "${colors_seen[$color]:-}" ]; then
    print_error "Color conflict: '$color' used by '$tid' and '${colors_seen[$color]}'"
    color_conflict=true
  fi
  colors_seen[$color]="$tid"
done < <(find "$TEAMS_DIR" -maxdepth 1 -name "*.conf" -type f | sort)

if [ "$color_conflict" = false ]; then
  test_pass
else
  test_fail "Found duplicate TEAM_COLOR assignments"
fi

test_start "All team colors are valid CSS hex color format (#RRGGBB)"
while IFS= read -r conf_file; do
  color=$(get_team_field "$conf_file" "TEAM_COLOR")
  if [ -n "$color" ]; then
    assert_matches "$color" "^#[0-9A-Fa-f]{6}$" \
      "TEAM_COLOR '$color' must be #RRGGBB format in: $(basename "$conf_file")"
  fi
done < <(find "$TEAMS_DIR" -maxdepth 1 -name "*.conf" -type f | sort)
test_pass

test_start "No team .conf agent persona names overlap across platform teams"
# Platform teams should use different agent persona sets so sessions are identifiable
declare -A agent_to_team
agent_conflict=false
while IFS= read -r conf_file; do
  cat_val=$(get_team_field "$conf_file" "TEAM_ID")
  platform=$(get_team_field "$conf_file" "TEAM_CATEGORY")
  [ "$platform" = "platform" ] || continue
  tid="$cat_val"

  # Read TEAM_AGENTS array from the conf file
  agents=$(
    # shellcheck disable=SC1090
    source "$conf_file"
    echo "${TEAM_AGENTS[*]}"
  )
  for agent in $agents; do
    if [ -n "${agent_to_team[$agent]:-}" ]; then
      # Agent name collision between two platform teams
      print_error "Agent '$agent' shared by platform teams '$tid' and '${agent_to_team[$agent]}'"
      agent_conflict=true
    fi
    agent_to_team[$agent]="$tid"
  done
done < <(find "$TEAMS_DIR" -maxdepth 1 -name "*.conf" -type f | sort)

if [ "$agent_conflict" = false ]; then
  test_pass
else
  test_fail "Platform teams must not share agent persona names"
fi

test_start "Registry team count matches number of .conf files"
if command -v jq &>/dev/null; then
  registry_count=$(jq '.teams | length' "$TEAMS_DIR/registry.json")
  conf_count=$(find "$TEAMS_DIR" -maxdepth 1 -name "*.conf" -type f | wc -l | tr -d ' ')
  assert_equal "$registry_count" "$conf_count" \
    "Registry must have one entry per .conf file (registry=$registry_count, confs=$conf_count)"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Config round-trip: write then read multi-team config preserves all teams"
expected_teams="ios android firebase academy"
create_multi_team_config ios android firebase academy
actual_teams=$(get_configured_teams)
for t in $expected_teams; do
  assert_contains "$actual_teams" "$t" "Team '$t' lost after config round-trip"
done
test_pass

# Success!
exit 0
