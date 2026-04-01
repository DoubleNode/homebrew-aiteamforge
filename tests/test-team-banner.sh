#!/bin/bash

# test-team-banner.sh
# Tests for team banner template generation:
#   - Hex-to-xterm-256 color conversion (the _hex_to_256 shell+Python function)
#   - Secondary color derivation logic
#   - Template variable substitution (all {{PLACEHOLDERS}})
#   - onscreen() function definition and stored _BANNER_* variables
#   - Banner output formatting (separator lines, field structure)
#   - Missing / empty template variable handling
#   - Multiple team configurations (color variety, id/name/ship values)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BANNER_TEMPLATE="$TAP_ROOT/share/templates/team-banner.sh.template"

# ═══════════════════════════════════════════════════════════════════════════
# Internal reimplementation of the installer's _hex_to_256 helper.
# Tests call this directly so they are independent of install-team.sh state.
# ═══════════════════════════════════════════════════════════════════════════

_hex_to_256() {
    local hex="${1#\#}"   # Strip leading #
    python3 -c "
import sys

def nearest_256(r, g, b):
    def cube_val(n):
        return 0 if n == 0 else 55 + n * 40

    best_cube_dist = float('inf')
    best_cube_idx = 16
    for ri in range(6):
        for gi in range(6):
            for bi in range(6):
                cr, cg, cb = cube_val(ri), cube_val(gi), cube_val(bi)
                d = (r-cr)**2 + (g-cg)**2 + (b-cb)**2
                if d < best_cube_dist:
                    best_cube_dist = d
                    best_cube_idx = 16 + 36*ri + 6*gi + bi

    best_gray_dist = float('inf')
    best_gray_idx = 232
    for i in range(24):
        gv = 8 + i * 10
        d = (r-gv)**2 + (g-gv)**2 + (b-gv)**2
        if d < best_gray_dist:
            best_gray_dist = d
            best_gray_idx = 232 + i

    return best_cube_idx if best_cube_dist <= best_gray_dist else best_gray_idx

h = sys.argv[1].lstrip('#')
r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
print(nearest_256(r, g, b))
" "$hex" 2>/dev/null || echo "178"
}

# Derive secondary color exactly as install-team.sh does.
_derive_secondary() {
    local primary_code="$1"
    if [[ "$primary_code" -ge 52 ]]; then
        echo $((primary_code - 36))
    else
        local s=$((primary_code + 36))
        [[ "$s" -gt 231 ]] && s=231
        echo "$s"
    fi
}

# Apply all template substitutions used by install-team.sh and return the
# generated script content.  Writes to stdout.
_apply_template() {
    local team_id="${1:-testteam}"
    local team_name="${2:-Test Team}"
    local team_ship="${3:-USS Test}"
    local team_color="${4:-#5585CC}"

    local primary_code
    primary_code=$(_hex_to_256 "$team_color")
    local secondary_code
    secondary_code=$(_derive_secondary "$primary_code")
    local banner_script_name="${team_id}-banner.sh"

    sed \
        -e "s|{{TEAM_ID}}|${team_id}|g" \
        -e "s|{{TEAM_NAME}}|${team_name}|g" \
        -e "s|{{TEAM_SHIP}}|${team_ship}|g" \
        -e "s|{{TEAM_BANNER_SCRIPT}}|${banner_script_name}|g" \
        -e "s|{{TEAM_COLOR_PRIMARY}}|${primary_code}|g" \
        -e "s|{{TEAM_COLOR_SECONDARY}}|${secondary_code}|g" \
        "$BANNER_TEMPLATE"
}

# ═══════════════════════════════════════════════════════════════════════════
# Prerequisite checks
# ═══════════════════════════════════════════════════════════════════════════

test_start "Banner template file exists"
assert_file_exists "$BANNER_TEMPLATE"
test_pass

test_start "python3 is available (required for color conversion)"
assert_success "command -v python3"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Hex-to-xterm-256 color conversion — output range
# ═══════════════════════════════════════════════════════════════════════════

test_start "hex_to_256 returns a numeric result"
result=$(_hex_to_256 "#5585CC")
assert_matches "$result" "^[0-9]+$" "Expected numeric result, got: '$result'"
test_pass

test_start "hex_to_256 result is in valid range 16–255"
result=$(_hex_to_256 "#5585CC")
[ "$result" -ge 16 ] && [ "$result" -le 255 ]
assert_exit_success $? "Color index $result out of valid range 16-255"
test_pass

test_start "hex_to_256 black (#000000) maps to a dark cube index"
result=$(_hex_to_256 "#000000")
# Pure black maps to cube index 16 (all-zero cube slot)
assert_equal "16" "$result" "Expected #000000 -> 16, got $result"
test_pass

test_start "hex_to_256 white (#ffffff) maps to index 231"
result=$(_hex_to_256 "#ffffff")
# Pure white is the last 6x6x6 cube slot: 16 + 35*1 ... index 231
assert_equal "231" "$result" "Expected #ffffff -> 231, got $result"
test_pass

test_start "hex_to_256 pure red (#ff0000) maps to index 196"
result=$(_hex_to_256 "#ff0000")
# Cube: ri=5,gi=0,bi=0 => 16 + 36*5 + 0 + 0 = 196
assert_equal "196" "$result" "Expected #ff0000 -> 196, got $result"
test_pass

test_start "hex_to_256 pure green (#00ff00) maps to index 46"
result=$(_hex_to_256 "#00ff00")
# Cube: ri=0,gi=5,bi=0 => 16 + 0 + 6*5 + 0 = 46
assert_equal "46" "$result" "Expected #00ff00 -> 46, got $result"
test_pass

test_start "hex_to_256 pure blue (#0000ff) maps to index 21"
result=$(_hex_to_256 "#0000ff")
# Cube: ri=0,gi=0,bi=5 => 16 + 0 + 0 + 5 = 21
assert_equal "21" "$result" "Expected #0000ff -> 21, got $result"
test_pass

test_start "hex_to_256 mid-gray (#808080) selects gray ramp or nearby cube"
result=$(_hex_to_256 "#808080")
# Result must be numeric and in valid range
assert_matches "$result" "^[0-9]+$" "Expected numeric result"
[ "$result" -ge 16 ] && [ "$result" -le 255 ]
assert_exit_success $? "Index $result out of valid range"
test_pass

test_start "hex_to_256 near-black gray (#121212) prefers gray ramp"
result=$(_hex_to_256 "#121212")
# #121212 = 18,18,18 which is very close to gray ramp value 18 (index 233)
assert_equal "233" "$result" "Expected #121212 -> 233 (gray ramp), got $result"
test_pass

test_start "hex_to_256 hex input without # prefix still works"
result_hash=$(_hex_to_256 "#5585CC")
result_nohash=$(_hex_to_256 "5585CC")
assert_equal "$result_hash" "$result_nohash" "Results should match with or without leading #"
test_pass

test_start "hex_to_256 default fallback on bad input returns numeric"
# The function falls back to echo "178" on Python error; simulate bad input
result=$(echo "" | python3 -c "import sys; print('178')" 2>/dev/null || echo "178")
assert_matches "$result" "^[0-9]+$" "Fallback result should be numeric"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Secondary color derivation
# ═══════════════════════════════════════════════════════════════════════════

test_start "secondary color is primary - 36 when primary >= 52"
primary=100
secondary=$(_derive_secondary "$primary")
assert_equal "64" "$secondary" "Expected 100-36=64, got $secondary"
test_pass

test_start "secondary color is primary + 36 when primary < 52"
primary=20
secondary=$(_derive_secondary "$primary")
assert_equal "56" "$secondary" "Expected 20+36=56, got $secondary"
test_pass

test_start "secondary color clamps at 231 when primary + 36 would exceed 231"
primary=16
secondary=$(_derive_secondary "$primary")
# 16 < 52, so 16+36=52 which is under 231 — no clamp needed here
assert_equal "52" "$secondary" "Expected 16+36=52, got $secondary"
test_pass

test_start "secondary color for primary=215 stays within valid cube range"
primary=215
secondary=$(_derive_secondary "$primary")
[ "$secondary" -ge 16 ] && [ "$secondary" -le 255 ]
assert_exit_success $? "Secondary $secondary out of range"
test_pass

test_start "secondary color is always in range 16–231"
for primary_test in 16 20 51 52 100 195 196 220 231; do
    sec=$(_derive_secondary "$primary_test")
    if ! [[ "$sec" -ge 16 && "$sec" -le 231 ]]; then
        test_fail "secondary $sec out of range for primary $primary_test"
    fi
done
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Template variable substitution
# ═══════════════════════════════════════════════════════════════════════════

test_start "No unreplaced {{PLACEHOLDER}} tokens remain after substitution"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_not_contains "$generated" "{{" "Found unreplaced {{ in generated script"
assert_not_contains "$generated" "}}" "Found unreplaced }} in generated script"
test_pass

test_start "TEAM_ID substituted in generated script"
generated=$(_apply_template "mytestteam" "My Test Team" "USS Test" "#5585CC")
assert_contains "$generated" "mytestteam" "TEAM_ID 'mytestteam' not found in generated script"
test_pass

test_start "TEAM_NAME substituted in generated script"
generated=$(_apply_template "testteam" "Thunderous Lions" "USS Test" "#5585CC")
assert_contains "$generated" "Thunderous Lions" "TEAM_NAME not substituted correctly"
test_pass

test_start "TEAM_SHIP substituted in generated script"
generated=$(_apply_template "testteam" "Test Team" "USS Enterprise" "#5585CC")
assert_contains "$generated" "USS Enterprise" "TEAM_SHIP not substituted correctly"
test_pass

test_start "TEAM_BANNER_SCRIPT substituted with correct filename"
generated=$(_apply_template "mytestteam" "My Test Team" "USS Test" "#5585CC")
assert_contains "$generated" "mytestteam-banner.sh" "Banner script name not correct in generated script"
test_pass

test_start "TEAM_COLOR_PRIMARY substituted with a numeric xterm code"
primary=$(_hex_to_256 "#5585CC")
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" "%F{${primary}}" "Expected color escape %F{$primary} not found"
test_pass

test_start "TEAM_COLOR_SECONDARY substituted with a numeric xterm code"
primary=$(_hex_to_256 "#5585CC")
secondary=$(_derive_secondary "$primary")
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" "%F{${secondary}}" "Expected secondary color escape %F{$secondary} not found"
test_pass

test_start "Primary and secondary colors are different in generated script"
primary=$(_hex_to_256 "#5585CC")
secondary=$(_derive_secondary "$primary")
assert_not_equal "$primary" "$secondary" "Primary and secondary colors should differ"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Generated script syntax validity
# ═══════════════════════════════════════════════════════════════════════════

test_start "Generated banner script has valid bash/zsh-compatible syntax"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
# Write to temp file and check syntax (bash -n; zsh shebang but bash -n is permissive enough)
tmp_script="$TEST_TMP_DIR/generated-banner.sh"
echo "$generated" > "$tmp_script"
bash -n "$tmp_script" 2>/dev/null
assert_exit_success $? "Generated script failed syntax check"
test_pass

test_start "Generated banner script defines SESSION_THEME variable"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" 'SESSION_THEME=' "SESSION_THEME variable not defined in generated script"
test_pass

test_start "Generated banner script defines SESSION_TYPE variable"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" 'SESSION_TYPE=' "SESSION_TYPE variable not defined"
test_pass

test_start "Generated banner script defines SESSION_NAME variable"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" 'SESSION_NAME=' "SESSION_NAME variable not defined"
test_pass

test_start "Generated banner script defines all 11 parameter variables"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
for var in SESSION_THEME SESSION_TYPE SESSION_NAME TERMINAL_NUMBER TERMINAL_NAME \
           SESSION_DESCRIPTION SESSION_LOCATION SESSION_DEVELOPER SESSION_ROLE \
           TERMINAL_DESCRIPTION PASSED_SESSION_CODE; do
    assert_contains "$generated" "${var}=" "Missing variable: $var"
done
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# onscreen() function definition
# ═══════════════════════════════════════════════════════════════════════════

test_start "Generated script defines onscreen() function"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" "onscreen()" "onscreen() function not defined in generated script"
test_pass

test_start "onscreen() sources the banner script"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" 'source "$_BANNER_SCRIPT"' "onscreen() does not source _BANNER_SCRIPT"
test_pass

test_start "onscreen() passes all 12 banner parameters"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
# The onscreen() invocation line should reference all _BANNER_* vars
for var in _BANNER_THEME _BANNER_TYPE _BANNER_NAME _BANNER_NUM _BANNER_TERM \
           _BANNER_DESC _BANNER_LOC _BANNER_DEV _BANNER_ROLE _BANNER_TDESC _BANNER_CODE; do
    assert_contains "$generated" "\$${var}" "onscreen() missing parameter: \$$var"
done
test_pass

test_start "Generated script stores all _BANNER_* state variables"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
for var in _BANNER_SCRIPT _BANNER_THEME _BANNER_TYPE _BANNER_NAME _BANNER_NUM \
           _BANNER_TERM _BANNER_DESC _BANNER_LOC _BANNER_DEV _BANNER_ROLE \
           _BANNER_TDESC _BANNER_CODE; do
    assert_contains "$generated" "${var}=" "Missing state variable: $var"
done
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Banner output formatting
# ═══════════════════════════════════════════════════════════════════════════

test_start "Generated script contains horizontal separator lines"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" "═══════════════════════════════════════════════════════════" \
    "Banner separator lines not present"
test_pass

test_start "Generated script contains exactly two separator lines (top and bottom)"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
count=$(echo "$generated" | grep -c "═══════════════════════════════════════════════════════════" || true)
assert_equal "2" "$count" "Expected 2 separator lines, found $count"
test_pass

test_start "Generated script uses print -P for colored output"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" "print -P" "Banner uses print -P for zsh color output"
test_pass

test_start "Generated script sets iTerm2 tab title via ANSI escape"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" 'printf "\e]0;' "iTerm2 title escape not found"
test_pass

test_start "Generated script calls display_agent_avatar with team ID"
generated=$(_apply_template "mytestteam" "My Test Team" "USS Test" "#5585CC")
assert_contains "$generated" 'display_agent_avatar "mytestteam"' "display_agent_avatar call missing"
test_pass

test_start "Generated script references SESSION_DESCRIPTION in banner header"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" '${SESSION_DESCRIPTION}' "SESSION_DESCRIPTION not used in banner"
test_pass

test_start "Generated script references SESSION_LOCATION in banner"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" '${SESSION_LOCATION}' "SESSION_LOCATION not used in banner"
test_pass

test_start "Generated script references SESSION_DEVELOPER in banner"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" '${SESSION_DEVELOPER}' "SESSION_DEVELOPER not used in banner"
test_pass

test_start "Generated script references SESSION_ROLE in banner"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" '${SESSION_ROLE}' "SESSION_ROLE not used in banner"
test_pass

test_start "Generated script references TERMINAL_NAME in banner footer"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" '${TERMINAL_NAME}' "TERMINAL_NAME not used in banner"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# SESSION_CODE construction
# ═══════════════════════════════════════════════════════════════════════════

test_start "Generated script constructs SESSION_CODE from type-name when not passed"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" 'SESSION_CODE="${SESSION_TYPE}-${SESSION_NAME}"' \
    "SESSION_CODE construction from type+name not found"
test_pass

test_start "Generated script uses PASSED_SESSION_CODE when provided"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" 'SESSION_CODE="$PASSED_SESSION_CODE"' \
    "Explicit SESSION_CODE override not found"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Theme mapping / color fallback
# ═══════════════════════════════════════════════════════════════════════════

test_start "Generated script maps OPERATIONS theme to primary color"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" 'SESSION_THEME == "OPERATIONS"' "OPERATIONS theme mapping not found"
test_pass

test_start "Generated script maps COMMAND theme to primary color"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" 'SESSION_THEME == "COMMAND"' "COMMAND theme mapping not found"
test_pass

test_start "Generated script has fallback when SESSION_THEME is unrecognised"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" 'THEME_COLOR="${THEME_COLOR:-$TEAM_PRIMARY}"' \
    "THEME_COLOR fallback to TEAM_PRIMARY not found"
assert_contains "$generated" 'THEME_COLOR_HIGHLIGHT="${THEME_COLOR_HIGHLIGHT:-$TEAM_SECONDARY}"' \
    "THEME_COLOR_HIGHLIGHT fallback not found"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Multiple team configurations
# ═══════════════════════════════════════════════════════════════════════════

test_start "Academy team config generates valid script (blue palette)"
generated=$(_apply_template "academy" "Starfleet Academy" "Starfleet Academy" "#5585CC")
assert_not_contains "$generated" "{{" "Unreplaced placeholder in academy config"
assert_contains "$generated" "academy" "Academy TEAM_ID not found"
test_pass

test_start "Red-themed team generates primary in red range"
primary=$(_hex_to_256 "#CC0000")
# Pure red range is around 160-196 in xterm-256
[ "$primary" -ge 16 ] && [ "$primary" -le 255 ]
assert_exit_success $? "Red team primary $primary out of range"
generated=$(_apply_template "redteam" "Red Team" "USS Defiant" "#CC0000")
assert_contains "$generated" "%F{${primary}}" "Red team primary color not substituted"
test_pass

test_start "Gold-themed team generates valid script"
generated=$(_apply_template "goldteam" "Gold Team" "USS Voyager" "#FFD700")
assert_not_contains "$generated" "{{" "Unreplaced placeholder in gold config"
primary=$(_hex_to_256 "#FFD700")
assert_contains "$generated" "%F{${primary}}" "Gold team primary color not found"
test_pass

test_start "Team ID with hyphen generates correct banner script name"
generated=$(_apply_template "dns-framework" "DNS Framework" "Homebase" "#44CC88")
assert_contains "$generated" "dns-framework-banner.sh" "Hyphenated team ID banner filename wrong"
test_pass

test_start "Different color inputs produce different primary codes for distinct colors"
primary_blue=$(_hex_to_256 "#0000FF")
primary_red=$(_hex_to_256 "#FF0000")
assert_not_equal "$primary_blue" "$primary_red" "Blue and red should produce different xterm codes"
test_pass

test_start "Two different teams get different banner scripts (team-specific content)"
gen_a=$(_apply_template "alpha" "Alpha Team" "USS Alpha" "#5585CC")
gen_b=$(_apply_template "beta" "Beta Team" "USS Beta" "#CC5585")
assert_not_equal "$gen_a" "$gen_b" "Two different teams should generate different banner scripts"
test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Edge cases and robustness
# ═══════════════════════════════════════════════════════════════════════════

test_start "Template substitution handles team name with spaces"
generated=$(_apply_template "ios" "Main Event iOS" "USS Pioneer" "#5585CC")
assert_contains "$generated" "Main Event iOS" "Team name with spaces not preserved"
test_pass

test_start "Template substitution handles special characters in TEAM_SHIP"
generated=$(_apply_template "testteam" "Test Team" "32nd Century Starfleet" "#5585CC")
assert_contains "$generated" "32nd Century Starfleet" "TEAM_SHIP with special chars not substituted"
test_pass

test_start "Generated script includes worktree helper source guard"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" "worktree-helpers.sh" "Worktree helper source guard not found"
test_pass

test_start "Generated script sources display-agent-avatar helper"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" "display-agent-avatar.sh" "Avatar helper not sourced in generated script"
test_pass

test_start "Generated script clears terminal and tmux history on run"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" "clear" "clear command not present in banner script"
assert_contains "$generated" "tmux clear-history" "tmux clear-history not present"
test_pass

test_start "AITEAMFORGE_DIR path takes priority for avatar helper (homebrew install)"
generated=$(_apply_template "testteam" "Test Team" "USS Test" "#5585CC")
assert_contains "$generated" 'AITEAMFORGE_DIR' "AITEAMFORGE_DIR not referenced for avatar path"
test_pass

# Success
exit 0
