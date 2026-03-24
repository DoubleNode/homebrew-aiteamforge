#!/bin/bash

# test-teams.sh
# Tests for team configuration files (share/teams/)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEAMS_DIR="$TAP_ROOT/share/teams"
REGISTRY_FILE="$TEAMS_DIR/registry.json"

# ═══════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════

get_conf_files() {
  find "$TEAMS_DIR" -maxdepth 1 -name "*.conf" -type f
}

get_team_ids_from_registry() {
  if command -v jq &>/dev/null; then
    jq -r '.teams[].id' "$REGISTRY_FILE" 2>/dev/null
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════

test_start "Teams directory exists"
assert_dir_exists "$TEAMS_DIR"
test_pass

test_start "Registry file exists"
assert_file_exists "$REGISTRY_FILE"
test_pass

test_start "Registry file contains valid JSON"
assert_file_valid_json "$REGISTRY_FILE"
test_pass

test_start "Registry file has 'teams' array"
if command -v jq &>/dev/null; then
  teams_array=$(jq -r '.teams' "$REGISTRY_FILE")
  assert_not_equal "null" "$teams_array"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Registry file has 'version' field"
if command -v jq &>/dev/null; then
  version=$(jq -r '.version' "$REGISTRY_FILE")
  assert_not_empty "$version"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "At least one team is defined in registry"
if command -v jq &>/dev/null; then
  count=$(jq '.teams | length' "$REGISTRY_FILE")
  [ "$count" -gt 0 ]
  assert_exit_success $?
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "At least one .conf file exists"
conf_count=$(get_conf_files | wc -l | tr -d ' ')
[ "$conf_count" -gt 0 ]
assert_exit_success $?
test_pass

test_start "All .conf files are parseable (valid shell syntax)"
while IFS= read -r conf_file; do
  # Try to parse the file without executing
  bash -n "$conf_file" 2>/dev/null
  assert_exit_success $? "Failed to parse: $(basename "$conf_file")"
done < <(get_conf_files)
test_pass

test_start "All .conf files have TEAM_ID field"
while IFS= read -r conf_file; do
  # shellcheck disable=SC1090
  source "$conf_file"
  assert_not_empty "$TEAM_ID" "Missing TEAM_ID in: $(basename "$conf_file")"
done < <(get_conf_files)
test_pass

test_start "All .conf files have TEAM_NAME field"
while IFS= read -r conf_file; do
  unset TEAM_NAME
  # shellcheck disable=SC1090
  source "$conf_file"
  assert_not_empty "$TEAM_NAME" "Missing TEAM_NAME in: $(basename "$conf_file")"
done < <(get_conf_files)
test_pass

test_start "All .conf files have TEAM_DESCRIPTION field"
while IFS= read -r conf_file; do
  unset TEAM_DESCRIPTION
  # shellcheck disable=SC1090
  source "$conf_file"
  assert_not_empty "$TEAM_DESCRIPTION" "Missing TEAM_DESCRIPTION in: $(basename "$conf_file")"
done < <(get_conf_files)
test_pass

test_start "All .conf files have TEAM_AGENTS array"
while IFS= read -r conf_file; do
  unset TEAM_AGENTS
  # shellcheck disable=SC1090
  source "$conf_file"
  # Check if TEAM_AGENTS is defined and is an array with at least one element
  if [ "${#TEAM_AGENTS[@]}" -eq 0 ]; then
    assert_not_empty "" "Missing or empty TEAM_AGENTS in: $(basename "$conf_file")"
  fi
done < <(get_conf_files)
test_pass

test_start "All teams in registry have corresponding .conf files"
if command -v jq &>/dev/null; then
  while IFS= read -r team_id; do
    conf_file="$TEAMS_DIR/${team_id}.conf"
    assert_file_exists "$conf_file" "Missing .conf for team: $team_id"
  done < <(get_team_ids_from_registry)
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "All .conf files have entry in registry"
if command -v jq &>/dev/null; then
  registry_ids=$(get_team_ids_from_registry | tr '\n' ' ')
  while IFS= read -r conf_file; do
    # Extract team ID from filename
    team_id=$(basename "$conf_file" .conf)
    assert_contains "$registry_ids" "$team_id" "No registry entry for: $team_id"
  done < <(get_conf_files)
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "No duplicate team IDs in .conf files"
declare -A seen_ids
duplicate_found=false
while IFS= read -r conf_file; do
  unset TEAM_ID
  # shellcheck disable=SC1090
  source "$conf_file"
  if [ -n "${seen_ids[$TEAM_ID]}" ]; then
    print_error "Duplicate TEAM_ID: $TEAM_ID in $(basename "$conf_file") and ${seen_ids[$TEAM_ID]}"
    duplicate_found=true
  fi
  seen_ids[$TEAM_ID]=$(basename "$conf_file")
done < <(get_conf_files)

if [ "$duplicate_found" = false ]; then
  test_pass
else
  test_fail "Found duplicate team IDs"
fi

test_start "Registry team IDs match .conf filenames"
if command -v jq &>/dev/null; then
  mismatch_found=false
  while IFS= read -r team_id; do
    # Check if .conf file exists with exact name
    conf_file="$TEAMS_DIR/${team_id}.conf"
    if [ ! -f "$conf_file" ]; then
      print_error "Registry has team '$team_id' but no ${team_id}.conf file"
      mismatch_found=true
    fi
  done < <(get_team_ids_from_registry)

  if [ "$mismatch_found" = false ]; then
    test_pass
  else
    test_fail "Team ID / filename mismatches found"
  fi
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Known teams are present"
# Check for expected core teams (lowercase IDs)
expected_teams="ios android firebase academy"
if command -v jq &>/dev/null; then
  registry_ids=$(get_team_ids_from_registry | tr '\n' ' ')
  for team in $expected_teams; do
    assert_contains "$registry_ids" "$team" "Expected team not found: $team"
  done
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

# Success!
exit 0
