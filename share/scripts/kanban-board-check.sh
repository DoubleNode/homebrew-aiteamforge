#!/bin/bash
# kanban-board-check.sh
# Shared utility: validate a team's kanban board exists and is well-formed.
#
# USAGE (source this file, then call the function):
#   source "${LIBEXEC_DIR}/share/scripts/kanban-board-check.sh"
#   validate_kanban_board "academy" || echo "Warning: Kanban board not available"
#
# RETURN CODES:
#   0 = board is valid (or was successfully restored/created)
#   1 = board is missing/invalid and user chose to skip (or non-interactive)
#
# DEPENDENCIES:
#   - common.sh must be sourced before this file (provides print_info, print_warning,
#     print_error, print_success, prompt_yes_no)
#   - jq must be available for JSON validation

# Guard against double-sourcing
if [ -n "${_KANBAN_BOARD_CHECK_LOADED:-}" ]; then
    return 0
fi
_KANBAN_BOARD_CHECK_LOADED=1

# Ensure common.sh print functions are available. If they haven't been sourced,
# define minimal stubs so the script works standalone (same pattern as
# kanban-restore-helper.sh).
if ! type print_info &>/dev/null; then
    print_info()    { echo "  ℹ $*"; }
    print_success() { echo "  ✓ $*"; }
    print_warning() { echo "  ⚠ $*" >&2; }
    print_error()   { echo "  ✗ $*" >&2; }
fi

# ──────────────────────────────────────────────────────────────────────────────
# Source the canonical kanban path library (ARCH-1).
# Try paths in order: relative to this script (works in the source tree and
# when installed alongside the libexec tree), then Homebrew prefix locations.
# ──────────────────────────────────────────────────────────────────────────────
_KANBAN_PATHS_SCRIPT="$(dirname "${BASH_SOURCE[0]:-$0}")/../../libexec/lib/kanban-paths.sh"
if [ ! -f "$_KANBAN_PATHS_SCRIPT" ]; then
    _KANBAN_PATHS_SCRIPT="/opt/homebrew/opt/aiteamforge/libexec/lib/kanban-paths.sh"
fi
if [ ! -f "$_KANBAN_PATHS_SCRIPT" ]; then
    _KANBAN_PATHS_SCRIPT="/usr/local/opt/aiteamforge/libexec/lib/kanban-paths.sh"
fi
if [ -f "$_KANBAN_PATHS_SCRIPT" ]; then
    # shellcheck source=/dev/null
    source "$_KANBAN_PATHS_SCRIPT"
else
    print_warning "kanban-board-check: kanban-paths.sh not found; path resolution may fail"
fi
unset _KANBAN_PATHS_SCRIPT

# ──────────────────────────────────────────────────────────────────────────────
# Internal: resolve the kanban directory for a given team ID.
# Thin wrapper around get_kanban_dir() from kanban-paths.sh.
# Falls back to the academy directory with a warning for unknown teams so that
# callers continue to get a usable path (matching previous behaviour).
# ──────────────────────────────────────────────────────────────────────────────
_kbc_get_kanban_dir() {
    local team="$1"
    local dir
    if dir=$(get_kanban_dir "$team" 2>/dev/null); then
        echo "$dir"
    else
        print_warning "kanban-board-check: unknown team '${team}', defaulting to academy directory"
        echo "${HOME}/aiteamforge/kanban"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Internal: find the most recent backup for a team.
# Backups live at ~/aiteamforge-backups/kanban/{team}/
# Files are named backup_YYYYMMDD_HHMMSS.zip (or .json for older backups).
# Prints the full path of the most recent backup, or nothing if none found.
# ──────────────────────────────────────────────────────────────────────────────
_kbc_find_latest_backup() {
    local team="$1"
    local backup_dir="${HOME}/aiteamforge-backups/kanban/${team}"

    if [ ! -d "$backup_dir" ]; then
        return 1
    fi

    # List all backup files sorted by name (YYYYMMDD_HHMMSS sorts lexically),
    # pick the last one. Supports both .zip and legacy .json backups.
    local latest
    latest=$(ls -1 "${backup_dir}"/backup_*.{zip,json} 2>/dev/null | sort | tail -n 1)

    if [ -n "$latest" ] && [ -f "$latest" ]; then
        echo "$latest"
        return 0
    fi

    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Internal: restore a board from a backup file.
# Handles both .zip and .json backup formats.
# Returns 0 on success, 1 on failure.
# ──────────────────────────────────────────────────────────────────────────────
_kbc_restore_from_backup() {
    local team="$1"
    local backup_file="$2"
    local kanban_dir="$3"
    local board_file="${kanban_dir}/${team}-board.json"

    # Make sure the kanban directory exists
    mkdir -p "$kanban_dir"

    if [[ "$backup_file" == *.zip ]]; then
        # Zip backup: extract board JSON from inside the archive.
        # The zip may contain just the board file, or a directory structure.
        # Try common board file names inside the zip.
        local tmpdir
        tmpdir=$(mktemp -d)

        if ! unzip -q "$backup_file" -d "$tmpdir" 2>/dev/null; then
            print_error "Failed to unzip backup: ${backup_file}"
            rm -rf "$tmpdir"
            return 1
        fi

        # Look for the board JSON file inside the extracted contents
        local extracted_board
        extracted_board=$(find "$tmpdir" -name "${team}-board.json" 2>/dev/null | head -n 1)

        if [ -z "$extracted_board" ]; then
            # Fallback: any .json file in the archive
            extracted_board=$(find "$tmpdir" -name "*.json" -not -name "*.lock" 2>/dev/null | head -n 1)
        fi

        if [ -z "$extracted_board" ]; then
            print_error "No board JSON found inside backup archive"
            rm -rf "$tmpdir"
            return 1
        fi

        cp "$extracted_board" "$board_file"
        rm -rf "$tmpdir"

    elif [[ "$backup_file" == *.json ]]; then
        # Legacy plain JSON backup — copy directly
        cp "$backup_file" "$board_file"

    else
        print_error "Unknown backup format: ${backup_file}"
        return 1
    fi

    # Verify the restored file is valid JSON before declaring success
    if ! _kbc_validate_json "$board_file"; then
        print_error "Restored file is not valid JSON — backup may be corrupt"
        rm -f "$board_file"
        return 1
    fi

    print_success "Restored board from backup: $(basename "$backup_file")"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Internal: validate that a file is non-empty, parseable JSON.
# Returns 0 if valid, 1 if invalid.
# ──────────────────────────────────────────────────────────────────────────────
_kbc_validate_json() {
    local file="$1"

    # Must exist and be non-empty
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        return 1
    fi

    # Use jq if available; fall back to python3
    if command -v jq &>/dev/null; then
        jq empty "$file" 2>/dev/null
        return $?
    elif command -v python3 &>/dev/null; then
        python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$file" 2>/dev/null
        return $?
    else
        # No JSON validator available — check for basic structure only
        grep -q '^\s*{' "$file" 2>/dev/null
        return $?
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Internal: check that the board JSON has the minimum required top-level fields.
#
# Real boards (production format) use:
#   "team"    — team identifier
#   "backlog" — primary item list
#
# Template-created boards use:
#   "name"    — team identifier
#   "items"   — primary item list
#
# Both formats are valid. We accept either combination.
# Returns 0 if valid, 1 if missing required fields.
# ──────────────────────────────────────────────────────────────────────────────
_kbc_validate_board_fields() {
    local board_file="$1"

    if command -v jq &>/dev/null; then
        # Must have at least one identifier field: "team" or "name"
        local has_identifier
        has_identifier=$(jq 'has("team") or has("name")' "$board_file" 2>/dev/null)

        if [ "$has_identifier" != "true" ]; then
            return 1
        fi

        # Must have at least one item collection field: "backlog" or "items"
        local has_items
        has_items=$(jq 'has("backlog") or has("items")' "$board_file" 2>/dev/null)

        if [ "$has_items" != "true" ]; then
            return 1
        fi

        return 0
    else
        # jq unavailable — check for any of the known field names as strings
        if grep -qE '"(team|name)"' "$board_file" 2>/dev/null && \
           grep -qE '"(backlog|items)"' "$board_file" 2>/dev/null; then
            return 0
        fi
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Internal: apply all template variable substitutions and write the result.
# Arguments:
#   $1 = source template file
#   $2 = destination board file (output)
#   $3 = team ID
#   $4 = kanban directory path (used for {{KANBAN_DIR}} substitution)
# Returns 0 on success, non-zero on sed/write failure.
# ──────────────────────────────────────────────────────────────────────────────
_kbc_apply_template_subs() {
    local src="$1"
    local dest="$2"
    local team="$3"
    local kanban_dir="$4"

    local team_name_upper
    team_name_upper="$(echo "$team" | tr '[:lower:]' '[:upper:]')"
    local team_abbrev
    team_abbrev="$(echo "$team" | tr '[:lower:]' '[:upper:]' | cut -c1-3)"
    local team_series="X${team_abbrev}"
    local created_date
    created_date="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    sed \
        -e "s|{{TEAM_ID}}|${team}|g" \
        -e "s|{{TEAM_NAME}}|${team_name_upper}|g" \
        -e "s|{{TEAM_SUBTITLE}}||g" \
        -e "s|{{TEAM_SHIP}}||g" \
        -e "s|{{TEAM_SERIES}}|${team_series}|g" \
        -e "s|{{TEAM_ORG}}|DEVTEAM|g" \
        -e "s|{{TEAM_ORG_COLOR}}|white|g" \
        -e "s|{{KANBAN_DIR}}|${kanban_dir}|g" \
        -e "s|{{CREATED_DATE}}|${created_date}|g" \
        -e "s|{{TEAM}}|${team}|g" \
        "$src" > "$dest"
}

# ──────────────────────────────────────────────────────────────────────────────
# Internal: create a new minimal board from template (or inline fallback).
# Arguments:
#   $1 = team ID
#   $2 = board file path to create
#   $3 = (optional) explicit template file path
# Returns 0 on success, 1 on failure.
# ──────────────────────────────────────────────────────────────────────────────
_kbc_create_board_from_template() {
    local team="$1"
    local board_file="$2"
    local template_path="${3:-}"

    local kanban_dir
    kanban_dir=$(dirname "$board_file")
    mkdir -p "$kanban_dir"

    # Try the provided template path first
    if [ -n "$template_path" ] && [ -f "$template_path" ]; then
        _kbc_apply_template_subs "$template_path" "$board_file" "$team" "$kanban_dir"
        print_success "Created board from template: ${template_path}"
        return 0
    fi

    # Try to find the template relative to INSTALL_ROOT (set by the installer)
    if [ -n "${INSTALL_ROOT:-}" ]; then
        local default_template="${INSTALL_ROOT}/share/templates/kanban/board-template.json"
        if [ -f "$default_template" ]; then
            _kbc_apply_template_subs "$default_template" "$board_file" "$team" "$kanban_dir"
            print_success "Created board from default template"
            return 0
        fi
    fi

    # Fallback: try to find it relative to a known Homebrew prefix
    local brew_template
    brew_template="$(brew --prefix 2>/dev/null)/opt/aiteamforge/libexec/share/templates/kanban/board-template.json"
    if [ -f "$brew_template" ]; then
        _kbc_apply_template_subs "$brew_template" "$board_file" "$team" "$kanban_dir"
        print_success "Created board from Homebrew template"
        return 0
    fi

    # Last resort: write a minimal inline board
    print_warning "No template found — creating minimal board inline"
    local _now
    _now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    cat > "$board_file" <<EOF
{
  "team": "${team}",
  "teamName": "${team}",
  "subtitle": "",
  "ship": "",
  "series": "",
  "organization": "",
  "orgColor": "",
  "kanbanDir": "$(dirname "$board_file")",
  "lastUpdated": "${_now}",
  "nextId": 1,
  "nextEpicId": 1,
  "nextReleaseId": 1,
  "fleetMonitorUrl": "",
  "terminals": {},
  "activeWindows": [],
  "backlog": [],
  "epics": [],
  "releases": []
}
EOF

    print_success "Created minimal board for team '${team}'"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# PUBLIC: validate_kanban_board
#
# Checks whether a team's kanban board exists and is well-formed.
# If the board is missing or invalid, presents interactive recovery options.
#
# Arguments:
#   $1 = team ID (required)  e.g. "academy", "ios", "android"
#   $2 = template path (optional) — override template used when creating new board
#
# Return codes:
#   0 = board is valid (or was successfully restored/created)
#   1 = board is missing/invalid and user chose to skip (or non-interactive mode)
# ──────────────────────────────────────────────────────────────────────────────
validate_kanban_board() {
    local team="${1:-}"
    local template_path="${2:-}"

    # ── Argument check ────────────────────────────────────────────────────────
    if [ -z "$team" ]; then
        print_error "validate_kanban_board: team ID is required"
        return 1
    fi

    # ── Resolve paths ─────────────────────────────────────────────────────────
    local kanban_dir
    kanban_dir=$(_kbc_get_kanban_dir "$team")

    local board_file="${kanban_dir}/${team}-board.json"

    # ── Check 1: kanban directory exists ──────────────────────────────────────
    if [ ! -d "$kanban_dir" ]; then
        print_warning "Kanban directory not found for team '${team}': ${kanban_dir}"
        _kbc_handle_missing_board "$team" "$kanban_dir" "$board_file" "$template_path"
        return $?
    fi

    # ── Check 2: board file exists ────────────────────────────────────────────
    if [ ! -f "$board_file" ]; then
        print_warning "Board file not found: ${board_file}"
        _kbc_handle_missing_board "$team" "$kanban_dir" "$board_file" "$template_path"
        return $?
    fi

    # ── Check 3: board file is non-empty and valid JSON ───────────────────────
    if ! _kbc_validate_json "$board_file"; then
        print_error "Board file is empty or invalid JSON: ${board_file}"
        _kbc_handle_corrupt_board "$team" "$kanban_dir" "$board_file" "$template_path"
        return $?
    fi

    # ── Check 4: board has minimum required fields (name/team + items) ────────
    if ! _kbc_validate_board_fields "$board_file"; then
        print_error "Board file is missing required fields (need 'name'/'team' and 'items'): ${board_file}"
        _kbc_handle_corrupt_board "$team" "$kanban_dir" "$board_file" "$template_path"
        return $?
    fi

    # All checks passed
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Internal: handle the case where the board file is missing entirely.
# Presents recovery options to the user.
# ──────────────────────────────────────────────────────────────────────────────
_kbc_handle_missing_board() {
    local team="$1"
    local kanban_dir="$2"
    local board_file="$3"
    local template_path="$4"

    _kbc_present_recovery_options "$team" "$kanban_dir" "$board_file" "$template_path" "missing"
    return $?
}

# ──────────────────────────────────────────────────────────────────────────────
# Internal: handle the case where the board file exists but is corrupt/invalid.
# Backs up the bad file before attempting recovery.
# ──────────────────────────────────────────────────────────────────────────────
_kbc_handle_corrupt_board() {
    local team="$1"
    local kanban_dir="$2"
    local board_file="$3"
    local template_path="$4"

    # Move the corrupt file aside so it doesn't block recovery
    if [ -f "$board_file" ]; then
        local corrupt_backup="${board_file}.corrupt.$(date +%Y%m%d_%H%M%S)"
        mv "$board_file" "$corrupt_backup"
        print_info "Corrupt board moved to: ${corrupt_backup}"
    fi

    _kbc_present_recovery_options "$team" "$kanban_dir" "$board_file" "$template_path" "corrupt"
    return $?
}

# ──────────────────────────────────────────────────────────────────────────────
# Internal: present the three recovery options and act on user choice.
# Returns 0 if board was recovered, 1 if user chose to skip.
# ──────────────────────────────────────────────────────────────────────────────
_kbc_present_recovery_options() {
    local team="$1"
    local kanban_dir="$2"
    local board_file="$3"
    local template_path="$4"
    local reason="$5"  # "missing" or "corrupt"

    # Detect whether we're running in a non-interactive environment.
    # If stdin is not a terminal, skip interactive prompts and return 1.
    if [ ! -t 0 ]; then
        print_warning "Non-interactive mode: skipping kanban board recovery for team '${team}'"
        print_warning "Kanban operations will not be available."
        return 1
    fi

    # ── Find available backups ────────────────────────────────────────────────
    local latest_backup
    latest_backup=$(_kbc_find_latest_backup "$team") || true

    # ── Display recovery menu ─────────────────────────────────────────────────
    echo ""
    print_warning "Kanban board problem detected for team: ${team}"
    echo ""

    if [ "$reason" = "corrupt" ]; then
        print_info "The board file exists but could not be parsed."
    else
        print_info "The board file does not exist at: ${board_file}"
    fi

    echo ""
    echo "Recovery options:"
    echo ""

    if [ -n "$latest_backup" ]; then
        echo "  1) Restore from backup ($(basename "$latest_backup"))"
    else
        echo "  1) Restore from backup  [no backups available]"
    fi
    echo "  2) Create a new empty board from template"
    echo "  3) Skip — continue without kanban (board operations will fail)"
    echo ""

    # ── Prompt for choice ─────────────────────────────────────────────────────
    local choice
    local attempts=0
    local max_attempts=5
    while [ $attempts -lt $max_attempts ]; do
        attempts=$((attempts + 1))
        printf "Choose an option [1-3]: "
        read -r choice

        case "$choice" in
            1)
                # Option 1: restore from backup
                if [ -z "$latest_backup" ]; then
                    print_error "No backups available for team '${team}'"
                    print_info "Please choose another option."
                    continue
                fi

                print_info "Restoring from: ${latest_backup}"
                if _kbc_restore_from_backup "$team" "$latest_backup" "$kanban_dir"; then
                    return 0
                else
                    print_error "Restore failed. Try a different option."
                    continue
                fi
                ;;

            2)
                # Option 2: create a new board from template
                print_info "Creating new board for team '${team}'..."
                if _kbc_create_board_from_template "$team" "$board_file" "$template_path"; then
                    return 0
                else
                    print_error "Board creation failed."
                    continue
                fi
                ;;

            3)
                # Option 3: skip — caller gets return code 1
                print_warning "Skipping kanban board setup for team '${team}'"
                print_warning "Kanban operations will not be available until the board is restored."
                return 1
                ;;

            *)
                print_error "Invalid choice. Please enter 1, 2, or 3."
                ;;
        esac
    done

    print_warning "Maximum recovery attempts (${max_attempts}) reached. Skipping board setup."
    print_warning "Kanban operations will not be available until the board is restored."
    return 1
}
