#!/bin/zsh
# Shared terminal registration helper
# Populates the terminals object in a kanban board JSON from persona files.
#
# Usage: source register-terminals.sh, then call:
#   _atf_register_terminals <board_file> <personas_base> <agents_array_name> [<display_label>]
#
# Arguments:
#   board_file      - absolute path to the kanban board JSON file
#   personas_base   - directory containing *_persona.md files
#   agents          - array of agent names (passed as "$agents[@]")
#   display_label   - optional label for status messages (default: "terminals")
#
# All helper functions are prefixed _atf_ to avoid namespace collisions.
# After calling _atf_register_terminals, callers should unset the helpers:
#   unset -f _atf_register_terminals _atf_parse_field _atf_color_token 2>/dev/null || true

# Extract a field from a persona markdown file.
# Fields follow the pattern "**Field:** Value" in the Core Identity section.
_atf_parse_field() {
    local file="$1" field="$2"
    [[ -f "$file" ]] || { echo ""; return; }
    grep -m1 "^\*\*${field}:\*\*" "$file" \
        | sed "s/^\*\*${field}:\*\*[[:space:]]*//" \
        | sed 's/[[:space:]]*$//'
}

# Map uniform color name from persona to LCARS color token.
_atf_color_token() {
    local c
    c="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    case "$c" in
        command*)     echo "command" ;;
        operations*)  echo "operations" ;;
        science*|sciences*) echo "science" ;;
        medical*)     echo "medical" ;;
        engineering*) echo "operations" ;;
        *)            echo "operations" ;;
    esac
}

# Register agents as terminals in a kanban board JSON file.
# Arguments:
#   $1 - board_file: path to kanban board JSON
#   $2 - personas_base: directory containing persona markdown files
#   $3 - display_label: label for status messages (optional, default "terminal(s)")
#   $@ - agent names (remaining positional arguments)
#
# Designed to be called as:
#   _atf_register_terminals "$board_file" "$personas_base" "" "${AGENTS[@]}"
_atf_register_terminals() {
    local board_file="$1"
    local personas_base="$2"
    local display_label="${3:-terminal(s)}"
    shift 3
    local agents=("$@")

    if [[ ! -f "$board_file" ]]; then
        echo "  ⚠️  Kanban board not found: $board_file (skipping terminal registration)"
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        echo "  ⚠️  jq not available — skipping terminal registration"
        return 0
    fi

    local terminals_json="{}"
    local agent
    for agent in "${agents[@]}"; do
        [[ -z "$agent" ]] && continue

        # Locate persona file — agent name may appear in any segment of the filename
        local persona_file=""
        if [[ -d "$personas_base" ]]; then
            persona_file="$(ls "${personas_base}"/*_"${agent}"_persona.md 2>/dev/null | head -1 || true)"
            [[ -z "$persona_file" ]] && persona_file="$(ls "${personas_base}"/*_"${agent}"_*_persona.md 2>/dev/null | head -1 || true)"
            [[ -z "$persona_file" ]] && persona_file="$(ls "${personas_base}"/*persona.md 2>/dev/null | grep -E "_${agent}_|_${agent}\.md$" | head -1 || true)"
        fi

        local dev_name role raw_color lcars_color
        dev_name="$(_atf_parse_field "$persona_file" "Name")"
        role="$(_atf_parse_field "$persona_file" "Role")"
        raw_color="$(_atf_parse_field "$persona_file" "Uniform Color")"
        lcars_color="$(_atf_color_token "$raw_color")"

        # Fall back to title-cased agent name using pure zsh (no python3 needed)
        if [[ -z "$dev_name" ]]; then
            dev_name="${(C)agent}"
        fi
        [[ -z "$role" ]] && role="Team Agent"

        terminals_json="$(
            printf '%s' "$terminals_json" | \
            jq --arg key "$agent" \
               --arg developer "$dev_name" \
               --arg avatar "$agent" \
               --arg role "$role" \
               --arg color "$lcars_color" \
               '.[$key] = {developer: $developer, avatar: $avatar, role: $role, color: $color}'
        )"
    done

    # Merge into board: add new agents, skip agents already registered with real names
    local tmp_file
    tmp_file="$(mktemp /tmp/_atf_reg_$$.json)"
    local ok=false
    jq --argjson new_terms "$terminals_json" '
        .terminals as $existing |
        ($new_terms | to_entries) as $entries |
        reduce $entries[] as $e (
            $existing;
            if (.[$e.key] == null)
              or (.[$e.key].developer == "Unknown")
              or (.[$e.key].developer == "")
            then .[$e.key] = $e.value
            else .
            end
        ) as $merged |
        .terminals = $merged |
        .lastUpdated = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    ' "$board_file" > "$tmp_file" && ok=true

    if [[ "$ok" == true && -s "$tmp_file" ]]; then
        mv "$tmp_file" "$board_file"
        echo "  ✅ Registered ${#agents[@]} ${display_label} in kanban board"
    else
        echo "  ⚠️  Terminal registration failed (board still functional)"
        rm -f "$tmp_file"
    fi
}
