#!/bin/bash
# kanban-restore-helper.sh
# Interactive kanban board backup discovery and restoration helper.
#
# PURPOSE & SCOPE
# ───────────────
# This script is designed for STANDALONE CLI use and interactive restoration
# sessions. It is NOT sourced by the automated startup validation flow.
#
# The startup flow (kanban-board-check.sh) uses its own simpler, non-interactive
# restore functions (_kbc_restore_from_backup, _kbc_find_latest_backup) that are
# appropriate for automated startup. Those functions deliberately avoid the richer
# menu-driven UX provided here.
#
# This script provides the fuller interactive experience:
#   - find_board_backups  : lists all backups with size and date information
#   - show_backup_menu    : presents a numbered menu for backup selection
#   - restore_board_from_backup : performs the actual restore with full validation
#
# Future CLI commands (e.g., `aiteamforge restore-board`) should source this script
# to get the interactive restoration experience rather than duplicating the logic.
#
# Usage (source this file, then call functions):
#   source /path/to/kanban-restore-helper.sh
#   find_board_backups "academy"
#   show_backup_menu "academy"
#   restore_board_from_backup "academy" "/path/to/backup.zip"
#
# Backup directory structure:
#   ~/aiteamforge-backups/kanban/
#     {team}/
#       backup_YYYYMMDD_HHMMSS.zip    (preferred format)
#       backup_YYYYMMDD_HHMMSS.json   (legacy format)
#
# Author: Reno's Engineering Lab (Academy Team)

# Guard against double-sourcing
if [ -n "${_KANBAN_RESTORE_HELPER_LOADED:-}" ]; then
    return 0
fi
_KANBAN_RESTORE_HELPER_LOADED=1

# Source common print functions if not already loaded.
# We look for common.sh relative to this script's location first, then fall
# back to the installed path. If neither exists, define minimal stubs so the
# functions still work without the full aiteamforge install.
_COMMON_SH_PATHS=(
    "$(dirname "${BASH_SOURCE[0]:-$0}")/../../libexec/lib/common.sh"
    "/usr/local/opt/aiteamforge/libexec/lib/common.sh"
    "/opt/homebrew/opt/aiteamforge/libexec/lib/common.sh"
)
_COMMON_LOADED=0
for _path in "${_COMMON_SH_PATHS[@]}"; do
    if [ -f "$_path" ]; then
        # shellcheck source=/dev/null
        source "$_path"
        _COMMON_LOADED=1
        break
    fi
done
if [ "$_COMMON_LOADED" -eq 0 ]; then
    # Minimal stubs — no colors, just plain output
    info()    { echo "  $*"; }
    success() { echo "  OK: $*"; }
    warning() { echo "  WARN: $*" >&2; }
    error()   { echo "  ERROR: $*" >&2; }
fi
unset _COMMON_SH_PATHS _path _COMMON_LOADED

# Source the canonical kanban path library (ARCH-1).
# Try paths in order: relative to this script (works in the source tree and
# when installed alongside the libexec tree), then Homebrew prefix locations.
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
    warning "kanban-restore-helper: kanban-paths.sh not found; path resolution may fail"
fi
unset _KANBAN_PATHS_SCRIPT

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Root directory where all kanban backups are stored.
KANBAN_BACKUP_ROOT="${HOME}/aiteamforge-backups/kanban"

# Maximum number of backups to display in the interactive menu.
KANBAN_RESTORE_MENU_LIMIT=10

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _krh_backup_dir <team>
# Prints the backup directory path for a team (does NOT verify it exists).
_krh_backup_dir() {
    echo "${KANBAN_BACKUP_ROOT}/$1"
}

# _krh_kanban_dir <team>
# Prints the live kanban directory path for a team.
# Thin wrapper around get_kanban_dir() from kanban-paths.sh (ARCH-1).
# Returns empty string for unknown teams so callers can detect the error,
# matching the previous behaviour of this function.
_krh_kanban_dir() {
    local team="$1"
    local dir
    if dir=$(get_kanban_dir "$team" 2>/dev/null); then
        echo "$dir"
    else
        # Unknown team — return empty so callers can detect the error
        echo ""
        return 1
    fi
}

# _krh_board_file <team>
# Prints the expected board JSON file path for a team.
_krh_board_file() {
    local kanban_dir
    kanban_dir="$(_krh_kanban_dir "$1")"
    if [ -z "$kanban_dir" ]; then
        echo ""
        return 1
    fi
    echo "${kanban_dir}/$1-board.json"
}

# _krh_is_valid_json <filepath>
# Returns 0 if the file exists, is non-empty, and contains valid JSON.
# Returns 1 otherwise.
_krh_is_valid_json() {
    local filepath="$1"
    if [ ! -f "$filepath" ] || [ ! -s "$filepath" ]; then
        return 1
    fi
    if command -v python3 &>/dev/null; then
        python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$filepath" 2>/dev/null
        return $?
    elif command -v python &>/dev/null; then
        python -c "import json,sys; json.load(open(sys.argv[1]))" "$filepath" 2>/dev/null
        return $?
    else
        # No Python available — try a rough structural check with grep
        # This is a last resort; it won't catch all invalid JSON
        grep -q '^[[:space:]]*[{\[]' "$filepath" 2>/dev/null
        return $?
    fi
}

# _krh_is_valid_zip <filepath>
# Returns 0 if the file exists, is non-empty, and is a readable zip archive.
_krh_is_valid_zip() {
    local filepath="$1"
    if [ ! -f "$filepath" ] || [ ! -s "$filepath" ]; then
        return 1
    fi
    if command -v python3 &>/dev/null; then
        python3 -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'r'); z.namelist(); z.close()" \
            "$filepath" 2>/dev/null
        return $?
    elif command -v unzip &>/dev/null; then
        unzip -t "$filepath" &>/dev/null
        return $?
    else
        # Can't verify — assume it's okay if it has content
        [ -s "$filepath" ]
        return $?
    fi
}

# _krh_format_bytes <bytes>
# Formats a byte count as a human-readable string (e.g. "1.4 MB").
_krh_format_bytes() {
    local bytes="$1"
    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes} B"
    elif [ "$bytes" -lt 1048576 ]; then
        # KB
        awk "BEGIN { printf \"%.1f KB\", $bytes / 1024 }"
    elif [ "$bytes" -lt 1073741824 ]; then
        # MB
        awk "BEGIN { printf \"%.1f MB\", $bytes / 1048576 }"
    else
        # GB
        awk "BEGIN { printf \"%.1f GB\", $bytes / 1073741824 }"
    fi
}

# _krh_parse_backup_date <filename>
# Extracts and reformats the date portion of a backup filename into a
# human-readable string like "2026-02-18 12:00:00".
# Input examples: backup_20260218_120000.zip  backup_20260217_180000.json
_krh_parse_backup_date() {
    local filename
    filename="$(basename "$1")"
    # Strip prefix and extensions: backup_YYYYMMDD_HHMMSS -> YYYYMMDD_HHMMSS
    local ts="${filename#backup_}"
    ts="${ts%.zip}"
    ts="${ts%.json}"

    # Must be exactly 15 chars: YYYYMMDD_HHMMSS
    if [ "${#ts}" -ne 15 ]; then
        echo "(unknown date)"
        return
    fi

    local year="${ts:0:4}"
    local month="${ts:4:2}"
    local day="${ts:6:2}"
    local hour="${ts:9:2}"
    local min="${ts:11:2}"
    local sec="${ts:13:2}"
    echo "${year}-${month}-${day} ${hour}:${min}:${sec}"
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# find_board_backups <team>
#
# Scans the backup directory for a team and prints information about each
# available backup, sorted newest-first. Handles both .zip and .json formats.
# Skips files that are empty or corrupted.
#
# Output format (one line per backup):
#   <date>  <size>  <filename>
#
# Returns 0 if at least one backup is found, 1 if none are available.
find_board_backups() {
    local team="$1"

    if [ -z "$team" ]; then
        error "find_board_backups: team name is required"
        return 1
    fi

    local backup_dir
    backup_dir="$(_krh_backup_dir "$team")"

    if [ ! -d "$backup_dir" ]; then
        warning "No backup directory found for team '${team}' at: ${backup_dir}"
        return 1
    fi

    # Collect all backup files (both formats).
    # We build a sorted list by constructing sort keys from the filename
    # timestamps, then print newest-first.
    local found=0
    local backup_file date_str size_bytes size_human

    # Use process substitution to read sorted output.
    # Sort in reverse so newest backups appear first.
    while IFS= read -r backup_file; do
        [ -z "$backup_file" ] && continue

        # Skip zero-byte files
        if [ ! -s "$backup_file" ]; then
            continue
        fi

        # Skip corrupted zips
        if [[ "$backup_file" == *.zip ]]; then
            if ! _krh_is_valid_zip "$backup_file"; then
                continue
            fi
        fi

        date_str="$(_krh_parse_backup_date "$(basename "$backup_file")")"
        size_bytes="$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo 0)"
        size_human="$(_krh_format_bytes "$size_bytes")"

        printf "  %s  %8s  %s\n" "$date_str" "$size_human" "$(basename "$backup_file")"
        found=$((found + 1))

    done < <(find "$backup_dir" -maxdepth 1 \( -name 'backup_*.zip' -o -name 'backup_*.json' \) \
        -not -empty 2>/dev/null | sort -r)

    if [ "$found" -eq 0 ]; then
        warning "No valid backups found for team '${team}'"
        return 1
    fi

    return 0
}

# restore_board_from_backup <team> <backup_file>
#
# Restores a team's kanban board from the specified backup file.
#
# - .zip backups are extracted into the team's kanban directory, restoring
#   the full directory structure (board JSON + any subdirectories).
# - .json backups are copied directly as the board file.
#
# After restoration, the board file is validated as JSON. If validation fails,
# the function reports the error and returns 1 — it does NOT attempt to re-restore.
#
# Returns 0 on success, 1 on failure.
restore_board_from_backup() {
    local team="$1"
    local backup_file="$2"

    if [ -z "$team" ]; then
        error "restore_board_from_backup: team name is required"
        return 1
    fi
    if [ -z "$backup_file" ]; then
        error "restore_board_from_backup: backup_file path is required"
        return 1
    fi
    if [ ! -f "$backup_file" ]; then
        error "Backup file not found: ${backup_file}"
        return 1
    fi
    if [ ! -s "$backup_file" ]; then
        error "Backup file is empty: ${backup_file}"
        return 1
    fi

    local kanban_dir
    kanban_dir="$(_krh_kanban_dir "$team")"
    if [ -z "$kanban_dir" ]; then
        error "Unknown team '${team}'. Cannot determine kanban directory."
        return 1
    fi

    local board_file
    board_file="$(_krh_board_file "$team")"

    # Ensure the kanban directory exists
    if ! mkdir -p "$kanban_dir" 2>/dev/null; then
        error "Cannot create kanban directory: ${kanban_dir}"
        return 1
    fi

    local extension="${backup_file##*.}"

    if [ "$extension" = "zip" ]; then
        # Validate the zip before attempting extraction
        if ! _krh_is_valid_zip "$backup_file"; then
            error "Backup file appears to be a corrupted zip: $(basename "$backup_file")"
            return 1
        fi

        info "Extracting zip backup to ${kanban_dir} ..."

        if command -v python3 &>/dev/null; then
            python3 -c "
import zipfile, sys
with zipfile.ZipFile(sys.argv[1], 'r') as z:
    z.extractall(sys.argv[2])
" "$backup_file" "$kanban_dir" 2>/dev/null
            local rc=$?
        elif command -v unzip &>/dev/null; then
            unzip -q -o "$backup_file" -d "$kanban_dir" 2>/dev/null
            local rc=$?
        else
            error "Cannot extract zip: neither python3 nor unzip is available"
            return 1
        fi

        if [ $rc -ne 0 ]; then
            error "Failed to extract zip backup: $(basename "$backup_file")"
            return 1
        fi

    elif [ "$extension" = "json" ]; then
        info "Copying JSON backup to ${board_file} ..."
        if ! cp -f "$backup_file" "$board_file" 2>/dev/null; then
            error "Failed to copy JSON backup to: ${board_file}"
            return 1
        fi
    else
        error "Unsupported backup format '.${extension}'. Expected .zip or .json"
        return 1
    fi

    # Validate the restored board file
    if [ ! -f "$board_file" ]; then
        error "Restoration appeared to succeed but board file is missing: ${board_file}"
        return 1
    fi

    if ! _krh_is_valid_json "$board_file"; then
        error "Restored board file failed JSON validation: ${board_file}"
        error "The backup may be corrupted. Try an older backup."
        return 1
    fi

    success "Board restored successfully from: $(basename "$backup_file")"
    return 0
}

# show_backup_menu <team>
#
# Displays an interactive numbered menu of available backups (newest-first,
# limited to KANBAN_RESTORE_MENU_LIMIT entries). The user picks a number to
# select a backup, or presses Enter / types 'q' to cancel.
#
# On selection: prints the full path of the chosen backup file to stdout,
#               then returns 0.
# On cancel:    prints nothing to stdout, returns 1.
#
# NOTE: All menu output goes to stderr so that only the selected path
#       (or empty string on cancel) is captured when calling:
#         selected=$(show_backup_menu "academy")
show_backup_menu() {
    local team="$1"

    if [ -z "$team" ]; then
        error "show_backup_menu: team name is required" >&2
        return 1
    fi

    local backup_dir
    backup_dir="$(_krh_backup_dir "$team")"

    if [ ! -d "$backup_dir" ]; then
        warning "No backup directory found for team '${team}' at: ${backup_dir}" >&2
        return 1
    fi

    # Collect valid backup files, sorted newest-first, up to the menu limit.
    local -a backup_files=()
    local backup_file

    while IFS= read -r backup_file; do
        [ -z "$backup_file" ] && continue
        [ ! -s "$backup_file" ] && continue

        # Validate zips before including them
        if [[ "$backup_file" == *.zip ]]; then
            if ! _krh_is_valid_zip "$backup_file"; then
                continue
            fi
        fi

        backup_files+=("$backup_file")

        # Stop once we've hit the display limit
        if [ "${#backup_files[@]}" -ge "$KANBAN_RESTORE_MENU_LIMIT" ]; then
            break
        fi

    done < <(find "$backup_dir" -maxdepth 1 \( -name 'backup_*.zip' -o -name 'backup_*.json' \) \
        -not -empty 2>/dev/null | sort -r)

    if [ "${#backup_files[@]}" -eq 0 ]; then
        warning "No valid backups found for team '${team}'" >&2
        return 1
    fi

    # Display the menu on stderr (keeps stdout clean for the return value)
    echo "" >&2
    echo "  Available backups for team '${team}':" >&2
    echo "  ─────────────────────────────────────────────────────────" >&2

    local i=0
    local date_str size_bytes size_human ext_label
    for backup_file in "${backup_files[@]}"; do
        i=$((i + 1))
        date_str="$(_krh_parse_backup_date "$(basename "$backup_file")")"
        size_bytes="$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo 0)"
        size_human="$(_krh_format_bytes "$size_bytes")"
        ext_label="$(basename "$backup_file")"

        printf "  %2d)  %s  %8s  %s\n" "$i" "$date_str" "$size_human" "$ext_label" >&2
    done

    echo "" >&2
    echo "  Enter number to restore, or press Enter to cancel:" >&2
    printf "  > " >&2

    local choice
    read -r choice

    # Treat empty input or 'q'/'Q' as cancellation
    if [ -z "$choice" ] || [ "$choice" = "q" ] || [ "$choice" = "Q" ]; then
        info "Restore cancelled." >&2
        return 1
    fi

    # Validate that the choice is a number in range
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        error "Invalid selection: '${choice}'" >&2
        return 1
    fi

    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backup_files[@]}" ]; then
        error "Selection out of range. Choose 1-${#backup_files[@]}" >&2
        return 1
    fi

    # Arrays are 0-indexed; menu is 1-indexed
    local selected_file="${backup_files[$((choice - 1))]}"

    # Print the selected path to stdout — this is the function's return value
    echo "$selected_file"
    return 0
}
