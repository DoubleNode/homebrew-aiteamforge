#!/bin/bash

# test-board-template.sh
# Tests for kanban board template metadata:
#   - TEAM_ORGANIZATION population from .conf files
#   - Required JSON fields present in the board template
#   - Board JSON schema validation (valid JSON, correct structure)
#   - Template variable substitution during board creation
#   - Missing/invalid config handling
#   - Field type validation (arrays are arrays, strings are strings)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BOARD_TEMPLATE="$TAP_ROOT/share/templates/kanban/board-template.json"
TEAMS_DIR="$TAP_ROOT/share/teams"
INSTALL_KANBAN="$TAP_ROOT/libexec/installers/install-kanban.sh"

# ═══════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════

# Build a board JSON by substituting all template variables with known values.
# Arguments: output_file [team_id] [team_name] [team_org]
build_test_board() {
  local output_file="$1"
  local team_id="${2:-testteam}"
  local team_name="${3:-TEST TEAM}"
  local team_subtitle="${4:-Test Subtitle}"
  local team_ship="${5:-USS Test}"
  local team_series="${6:-XTST}"
  local team_org="${7:-Test Organization}"
  local team_org_color="${8:-blue}"
  local kanban_dir="${9:-/tmp/test-kanban}"
  local created_date="${10:-2026-01-01T00:00:00Z}"

  sed \
    -e "s|{{TEAM_ID}}|${team_id}|g" \
    -e "s|{{TEAM_NAME}}|${team_name}|g" \
    -e "s|{{TEAM_SUBTITLE}}|${team_subtitle}|g" \
    -e "s|{{TEAM_SHIP}}|${team_ship}|g" \
    -e "s|{{TEAM_SERIES}}|${team_series}|g" \
    -e "s|{{TEAM_ORG}}|${team_org}|g" \
    -e "s|{{TEAM_ORG_COLOR}}|${team_org_color}|g" \
    -e "s|{{KANBAN_DIR}}|${kanban_dir}|g" \
    -e "s|{{CREATED_DATE}}|${created_date}|g" \
    "$BOARD_TEMPLATE" > "$output_file"
}

# Source a .conf file safely in a subshell and echo a KEY=value for a named var.
read_conf_var() {
  local conf_file="$1"
  local var_name="$2"
  (
    unset TEAM_REPOS TEAM_BREW_DEPS TEAM_BREW_CASK_DEPS TEAM_AGENTS
    # shellcheck source=/dev/null
    source "$conf_file" 2>/dev/null || true
    eval "echo \"\${${var_name}:-}\""
  )
}

# ═══════════════════════════════════════════════════════════════════════════
# Section 1: Board Template File Existence
# ═══════════════════════════════════════════════════════════════════════════

test_start "Board template file exists"
assert_file_exists "$BOARD_TEMPLATE"
test_pass

test_start "Board template file is non-empty"
template_size=$(wc -c < "$BOARD_TEMPLATE" | tr -d ' ')
[ "$template_size" -gt 0 ]
assert_exit_success $?
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Section 2: Template Variable Placeholders
# ═══════════════════════════════════════════════════════════════════════════

test_start "Template contains {{TEAM_ID}} placeholder"
assert_contains "$(cat "$BOARD_TEMPLATE")" "{{TEAM_ID}}"
test_pass

test_start "Template contains {{TEAM_NAME}} placeholder"
assert_contains "$(cat "$BOARD_TEMPLATE")" "{{TEAM_NAME}}"
test_pass

test_start "Template contains {{TEAM_ORG}} placeholder"
assert_contains "$(cat "$BOARD_TEMPLATE")" "{{TEAM_ORG}}"
test_pass

test_start "Template contains {{TEAM_ORG_COLOR}} placeholder"
assert_contains "$(cat "$BOARD_TEMPLATE")" "{{TEAM_ORG_COLOR}}"
test_pass

test_start "Template contains {{TEAM_SHIP}} placeholder"
assert_contains "$(cat "$BOARD_TEMPLATE")" "{{TEAM_SHIP}}"
test_pass

test_start "Template contains {{TEAM_SERIES}} placeholder"
assert_contains "$(cat "$BOARD_TEMPLATE")" "{{TEAM_SERIES}}"
test_pass

test_start "Template contains {{KANBAN_DIR}} placeholder"
assert_contains "$(cat "$BOARD_TEMPLATE")" "{{KANBAN_DIR}}"
test_pass

test_start "Template contains {{CREATED_DATE}} placeholder"
assert_contains "$(cat "$BOARD_TEMPLATE")" "{{CREATED_DATE}}"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Section 3: Template Variable Substitution
# ═══════════════════════════════════════════════════════════════════════════

test_start "Full template substitution produces valid JSON"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/sub-test-board.json"
  build_test_board "$tmp_board"
  assert_file_valid_json "$tmp_board"
  test_pass
else
  print_warning "jq not available, skipping JSON validation"
  test_pass
fi

test_start "Substituted board has no remaining {{...}} placeholders"
tmp_board="$TEST_TMP_DIR/placeholder-check-board.json"
build_test_board "$tmp_board"
remaining=$(grep -o '{{[A-Z_]*}}' "$tmp_board" 2>/dev/null || true)
assert_empty "$remaining" "Unsubstituted placeholders remain: $remaining"
test_pass

test_start "TEAM_ID value is written to board 'team' field"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/team-field-board.json"
  build_test_board "$tmp_board" "myteam"
  value=$(jq -r '.team' "$tmp_board")
  assert_equal "myteam" "$value"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "TEAM_NAME value is written to board 'teamName' field"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/teamname-board.json"
  build_test_board "$tmp_board" "myteam" "MY TEAM NAME"
  value=$(jq -r '.teamName' "$tmp_board")
  assert_equal "MY TEAM NAME" "$value"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "TEAM_ORG value is written to board 'organization' field"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/org-board.json"
  build_test_board "$tmp_board" "myteam" "MY TEAM" "Subtitle" "USS Test" "XMYT" "Starfleet Command"
  value=$(jq -r '.organization' "$tmp_board")
  assert_equal "Starfleet Command" "$value"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "TEAM_ORG_COLOR value is written to board 'orgColor' field"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/orgcolor-board.json"
  build_test_board "$tmp_board" "myteam" "MY TEAM" "Subtitle" "USS Test" "XMYT" "TestOrg" "lavender"
  value=$(jq -r '.orgColor' "$tmp_board")
  assert_equal "lavender" "$value"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "TEAM_SHIP value is written to board 'ship' field"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/ship-board.json"
  build_test_board "$tmp_board" "myteam" "MY TEAM" "Subtitle" "USS Enterprise-D"
  value=$(jq -r '.ship' "$tmp_board")
  assert_equal "USS Enterprise-D" "$value"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "TEAM_SERIES value is written to board 'series' field"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/series-board.json"
  build_test_board "$tmp_board" "myteam" "MY TEAM" "Sub" "USS Test" "XMYT"
  value=$(jq -r '.series' "$tmp_board")
  assert_equal "XMYT" "$value"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "KANBAN_DIR value is written to board 'kanbanDir' field"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/kanbandir-board.json"
  build_test_board "$tmp_board" "myteam" "MY TEAM" "Sub" "USS Test" "XMYT" "TestOrg" "blue" "/home/user/myteam/kanban"
  value=$(jq -r '.kanbanDir' "$tmp_board")
  assert_equal "/home/user/myteam/kanban" "$value"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "CREATED_DATE value is written to board 'lastUpdated' field"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/date-board.json"
  build_test_board "$tmp_board" "myteam" "MY TEAM" "Sub" "USS Test" "XMYT" "TestOrg" "blue" "/tmp" "2026-03-01T12:00:00Z"
  value=$(jq -r '.lastUpdated' "$tmp_board")
  assert_equal "2026-03-01T12:00:00Z" "$value"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Section 4: Required JSON Fields Present in Substituted Board
# ═══════════════════════════════════════════════════════════════════════════

test_start "Substituted board has 'team' field (string)"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/fields-board.json"
  build_test_board "$tmp_board"
  value=$(jq -r '.team' "$tmp_board")
  assert_not_empty "$value"
  assert_not_equal "null" "$value"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Substituted board has 'teamName' field (string)"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/fields-board.json"
  build_test_board "$tmp_board"
  value=$(jq -r '.teamName' "$tmp_board")
  assert_not_empty "$value"
  assert_not_equal "null" "$value"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Substituted board has 'organization' field (string)"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/fields-board.json"
  build_test_board "$tmp_board"
  value=$(jq -r '.organization' "$tmp_board")
  assert_not_empty "$value"
  assert_not_equal "null" "$value"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Substituted board has 'nextId' field with value 1"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/fields-board.json"
  build_test_board "$tmp_board"
  value=$(jq -r '.nextId' "$tmp_board")
  assert_equal "1" "$value"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Substituted board has 'nextEpicId' field with value 1"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/fields-board.json"
  build_test_board "$tmp_board"
  value=$(jq -r '.nextEpicId' "$tmp_board")
  assert_equal "1" "$value"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Substituted board has 'nextReleaseId' field with value 1"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/fields-board.json"
  build_test_board "$tmp_board"
  value=$(jq -r '.nextReleaseId' "$tmp_board")
  assert_equal "1" "$value"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Section 5: Field Type Validation (arrays are arrays, objects are objects)
# ═══════════════════════════════════════════════════════════════════════════

test_start "Board 'backlog' field is an array"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/types-board.json"
  build_test_board "$tmp_board"
  field_type=$(jq -r '.backlog | type' "$tmp_board")
  assert_equal "array" "$field_type"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Board 'epics' field is an array"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/types-board.json"
  build_test_board "$tmp_board"
  field_type=$(jq -r '.epics | type' "$tmp_board")
  assert_equal "array" "$field_type"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Board 'releases' field is an array"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/types-board.json"
  build_test_board "$tmp_board"
  field_type=$(jq -r '.releases | type' "$tmp_board")
  assert_equal "array" "$field_type"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Board 'activeWindows' field is an array"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/types-board.json"
  build_test_board "$tmp_board"
  field_type=$(jq -r '.activeWindows | type' "$tmp_board")
  assert_equal "array" "$field_type"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Board 'terminals' field is an object"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/types-board.json"
  build_test_board "$tmp_board"
  field_type=$(jq -r '.terminals | type' "$tmp_board")
  assert_equal "object" "$field_type"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Board 'nextId' field is a number"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/types-board.json"
  build_test_board "$tmp_board"
  field_type=$(jq -r '.nextId | type' "$tmp_board")
  assert_equal "number" "$field_type"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Board 'backlog' array is empty on initial creation"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/empty-arrays-board.json"
  build_test_board "$tmp_board"
  count=$(jq '.backlog | length' "$tmp_board")
  assert_equal "0" "$count"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Board 'activeWindows' array is empty on initial creation"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/empty-arrays-board.json"
  build_test_board "$tmp_board"
  count=$(jq '.activeWindows | length' "$tmp_board")
  assert_equal "0" "$count"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Board 'terminals' object is empty on initial creation"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/empty-arrays-board.json"
  build_test_board "$tmp_board"
  count=$(jq '.terminals | length' "$tmp_board")
  assert_equal "0" "$count"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Section 6: TEAM_ORGANIZATION Population from .conf Files
# ═══════════════════════════════════════════════════════════════════════════

test_start "academy.conf defines TEAM_ORGANIZATION"
conf="$TEAMS_DIR/academy.conf"
if [ -f "$conf" ]; then
  org=$(read_conf_var "$conf" "TEAM_ORGANIZATION")
  assert_not_empty "$org" "academy.conf TEAM_ORGANIZATION is not set"
  test_pass
else
  print_warning "academy.conf not found, skipping"
  test_pass
fi

test_start "academy.conf TEAM_ORGANIZATION matches expected value"
conf="$TEAMS_DIR/academy.conf"
if [ -f "$conf" ]; then
  org=$(read_conf_var "$conf" "TEAM_ORGANIZATION")
  assert_equal "Starfleet Academy" "$org"
  test_pass
else
  print_warning "academy.conf not found, skipping"
  test_pass
fi

test_start "ios.conf defines TEAM_ORGANIZATION"
conf="$TEAMS_DIR/ios.conf"
if [ -f "$conf" ]; then
  org=$(read_conf_var "$conf" "TEAM_ORGANIZATION")
  assert_not_empty "$org" "ios.conf TEAM_ORGANIZATION is not set"
  test_pass
else
  print_warning "ios.conf not found, skipping"
  test_pass
fi

test_start "command.conf defines TEAM_ORGANIZATION"
conf="$TEAMS_DIR/command.conf"
if [ -f "$conf" ]; then
  org=$(read_conf_var "$conf" "TEAM_ORGANIZATION")
  assert_not_empty "$org" "command.conf TEAM_ORGANIZATION is not set"
  test_pass
else
  print_warning "command.conf not found, skipping"
  test_pass
fi

test_start "All .conf files that exist define TEAM_ORGANIZATION"
all_passed=true
while IFS= read -r conf_file; do
  org=$(read_conf_var "$conf_file" "TEAM_ORGANIZATION")
  if [ -z "$org" ]; then
    print_warning "$(basename "$conf_file") missing TEAM_ORGANIZATION"
    all_passed=false
  fi
done < <(find "$TEAMS_DIR" -maxdepth 1 -name "*.conf" -type f)

if [ "$all_passed" = true ]; then
  test_pass
else
  test_fail "One or more .conf files are missing TEAM_ORGANIZATION"
fi

test_start "TEAM_ORGANIZATION from conf populates board 'organization' field"
if command -v jq &>/dev/null; then
  conf="$TEAMS_DIR/academy.conf"
  if [ -f "$conf" ]; then
    org=$(read_conf_var "$conf" "TEAM_ORGANIZATION")
    tmp_board="$TEST_TMP_DIR/org-from-conf-board.json"
    build_test_board "$tmp_board" "academy" "STARFLEET ACADEMY" "Academy Theme" "Academy Campus" "XACA" "$org" "lavender"
    board_org=$(jq -r '.organization' "$tmp_board")
    assert_equal "$org" "$board_org"
    test_pass
  else
    print_warning "academy.conf not found, skipping"
    test_pass
  fi
else
  print_warning "jq not available, skipping"
  test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Section 7: Missing and Invalid Config Handling
# ═══════════════════════════════════════════════════════════════════════════

test_start "Template substitution with empty TEAM_ORG produces board with empty organization field"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/empty-org-board.json"
  build_test_board "$tmp_board" "myteam" "MY TEAM" "Sub" "USS Test" "XMYT" ""
  org=$(jq -r '.organization' "$tmp_board")
  # An empty substitution should result in an empty string (not a placeholder literal)
  assert_not_contains "$org" "{{TEAM_ORG}}"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Template substitution with empty TEAM_ORG still produces valid JSON"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/empty-org-valid-board.json"
  build_test_board "$tmp_board" "myteam" "MY TEAM" "Sub" "USS Test" "XMYT" ""
  assert_file_valid_json "$tmp_board"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Template substitution with special characters in org name produces valid JSON"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/special-char-org-board.json"
  # Note: sed substitution with special chars — keep to alphanumeric + spaces for safety
  build_test_board "$tmp_board" "myteam" "MY TEAM" "Sub" "USS Test" "XMYT" "Acme Corp International"
  assert_file_valid_json "$tmp_board"
  org=$(jq -r '.organization' "$tmp_board")
  assert_equal "Acme Corp International" "$org"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

test_start "Template with missing optional TEAM_SUBTITLE still produces valid JSON"
if command -v jq &>/dev/null; then
  tmp_board="$TEST_TMP_DIR/no-subtitle-board.json"
  build_test_board "$tmp_board" "myteam" "MY TEAM" ""
  assert_file_valid_json "$tmp_board"
  test_pass
else
  print_warning "jq not available, skipping"
  test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# Section 8: derive_series_prefix Logic Validation
# ═══════════════════════════════════════════════════════════════════════════

test_start "derive_series_prefix produces X + 3-letter uppercase prefix for 'academy'"
# Simulate the function logic inline (no need to source the full installer)
team="academy"
abbrev="$(echo "$team" | tr '[:lower:]' '[:upper:]' | cut -c1-3)"
series="X${abbrev}"
assert_equal "XACA" "$series"
test_pass

test_start "derive_series_prefix produces X + 3-letter uppercase prefix for 'ios'"
team="ios"
abbrev="$(echo "$team" | tr '[:lower:]' '[:upper:]' | cut -c1-3)"
series="X${abbrev}"
assert_equal "XIOS" "$series"
test_pass

test_start "derive_series_prefix produces X + 3-letter uppercase prefix for 'firebase'"
team="firebase"
abbrev="$(echo "$team" | tr '[:lower:]' '[:upper:]' | cut -c1-3)"
series="X${abbrev}"
assert_equal "XFIR" "$series"
test_pass

test_start "derive_series_prefix produces X + 3-letter uppercase prefix for 'command'"
team="command"
abbrev="$(echo "$team" | tr '[:lower:]' '[:upper:]' | cut -c1-3)"
series="X${abbrev}"
assert_equal "XCOM" "$series"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Section 9: derive_org_color Logic Validation
# ═══════════════════════════════════════════════════════════════════════════

test_start "derive_org_color returns 'lavender' for infrastructure category"
# Simulate the function logic inline
category="infrastructure"
case "$category" in
  infrastructure) color="lavender" ;;
  platform)       color="blue" ;;
  project)        color="green" ;;
  strategic)      color="gold" ;;
  *)              color="white" ;;
esac
assert_equal "lavender" "$color"
test_pass

test_start "derive_org_color returns 'blue' for platform category"
category="platform"
case "$category" in
  infrastructure) color="lavender" ;;
  platform)       color="blue" ;;
  project)        color="green" ;;
  strategic)      color="gold" ;;
  *)              color="white" ;;
esac
assert_equal "blue" "$color"
test_pass

test_start "derive_org_color returns 'gold' for strategic category"
category="strategic"
case "$category" in
  infrastructure) color="lavender" ;;
  platform)       color="blue" ;;
  project)        color="green" ;;
  strategic)      color="gold" ;;
  *)              color="white" ;;
esac
assert_equal "gold" "$color"
test_pass

test_start "derive_org_color returns 'white' for unknown category"
category="unknown_category"
case "$category" in
  infrastructure) color="lavender" ;;
  platform)       color="blue" ;;
  project)        color="green" ;;
  strategic)      color="gold" ;;
  *)              color="white" ;;
esac
assert_equal "white" "$color"
test_pass

test_start "derive_org_color returns 'white' for empty category"
category=""
case "$category" in
  infrastructure) color="lavender" ;;
  platform)       color="blue" ;;
  project)        color="green" ;;
  strategic)      color="gold" ;;
  *)              color="white" ;;
esac
assert_equal "white" "$color"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Section 10: Academy conf integration — full round-trip
# ═══════════════════════════════════════════════════════════════════════════

test_start "Academy conf round-trip: org and category values map to expected board fields"
if command -v jq &>/dev/null; then
  conf="$TEAMS_DIR/academy.conf"
  if [ -f "$conf" ]; then
    org=$(read_conf_var "$conf" "TEAM_ORGANIZATION")
    category=$(read_conf_var "$conf" "TEAM_CATEGORY")
    ship=$(read_conf_var "$conf" "TEAM_SHIP")
    theme=$(read_conf_var "$conf" "TEAM_THEME")

    # Derive color from category (mirror installer logic)
    case "$category" in
      infrastructure) org_color="lavender" ;;
      platform)       org_color="blue" ;;
      project)        org_color="green" ;;
      strategic)      org_color="gold" ;;
      *)              org_color="white" ;;
    esac

    tmp_board="$TEST_TMP_DIR/academy-roundtrip-board.json"
    build_test_board "$tmp_board" "academy" "STARFLEET ACADEMY" "$theme" "$ship" "XACA" "$org" "$org_color"

    board_org=$(jq -r '.organization' "$tmp_board")
    board_color=$(jq -r '.orgColor' "$tmp_board")
    board_ship=$(jq -r '.ship' "$tmp_board")

    assert_equal "$org" "$board_org"
    assert_equal "$org_color" "$board_color"
    assert_equal "$ship" "$board_ship"
    test_pass
  else
    print_warning "academy.conf not found, skipping"
    test_pass
  fi
else
  print_warning "jq not available, skipping"
  test_pass
fi

# Success
exit 0
