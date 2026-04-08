#!/bin/bash
# LCARS Kanban System Installer
# Sets up kanban boards, LCARS web UI, backup system, and port management

set -euo pipefail

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

#──────────────────────────────────────────────────────────────────────────────
# Constants
#──────────────────────────────────────────────────────────────────────────────

KANBAN_BACKUP_LABEL="com.aiteamforge.kanban-backup"
KANBAN_BACKUP_INTERVAL=900  # 15 minutes (in seconds)
DEFAULT_LCARS_PORT=8080

#──────────────────────────────────────────────────────────────────────────────
# Helper Functions
#──────────────────────────────────────────────────────────────────────────────

# Parse team working dirs from serialized env var (team:path team:path ...)
# Stored in a plain indexed array to avoid eval with user-controlled values.
_TEAM_WORKING_DIRS=()
if [ -n "${TEAM_WORKING_DIRS_STR:-}" ]; then
    for entry in $TEAM_WORKING_DIRS_STR; do
        _TEAM_WORKING_DIRS+=("$entry")
    done
fi

# Lookup function — linear scan replaces the eval'd _TDIR_<team> variables.
_get_team_working_dir() {
    local team="$1"
    for entry in "${_TEAM_WORKING_DIRS[@]}"; do
        local _key="${entry%%:*}"
        local _val="${entry#*:}"
        if [ "$_key" = "$team" ]; then
            echo "$_val"
            return 0
        fi
    done
    return 1
}

# Get kanban directory for a specific team
get_team_kanban_dir() {
    local team="$1"

    # Use working dir from wizard if available
    local wizard_dir=""
    wizard_dir="$(_get_team_working_dir "$team" || true)"
    if [ -n "$wizard_dir" ]; then
        echo "${wizard_dir}/kanban"
        return
    fi

    # Fallback: read from team conf file
    local conf_file="$INSTALL_ROOT/share/teams/${team}.conf"
    if [ -f "$conf_file" ]; then
        local working_dir
        working_dir="$(grep '^TEAM_WORKING_DIR=' "$conf_file" | head -1 | cut -d'"' -f2)"
        working_dir="${working_dir/\$HOME/$HOME}"
        if [ -n "$working_dir" ]; then
            echo "${working_dir}/kanban"
            return
        fi
    fi

    # Last resort: under aiteamforge dir
    echo "$AITEAMFORGE_DIR/${team}/kanban"
}

# Derive series prefix from team ID (e.g., "academy" → "XACA", "ios" → "XIOS")
derive_series_prefix() {
    local team="$1"
    # Use first 3 letters of team ID, uppercased, prefixed with X
    local abbrev
    abbrev="$(echo "$team" | tr '[:lower:]' '[:upper:]' | cut -c1-3)"
    echo "X${abbrev}"
}

# Derive org color from team category or color
derive_org_color() {
    local category="${1:-}"
    case "$category" in
        infrastructure) echo "lavender" ;;
        platform)       echo "blue" ;;
        project)        echo "green" ;;
        strategic)      echo "gold" ;;
        *)              echo "white" ;;
    esac
}

# Map uniform color name from persona to LCARS color token
# Persona files use human-readable names; board uses lowercase tokens.
_map_uniform_color() {
    local raw_color
    raw_color="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    case "$raw_color" in
        command*)   echo "command" ;;
        operations*) echo "operations" ;;
        science*|sciences*) echo "science" ;;
        medical*)   echo "medical" ;;
        engineering*) echo "operations" ;;
        *)          echo "operations" ;;   # safe default
    esac
}

# Extract a field from a persona markdown file.
# Fields follow the pattern "**Field:** Value" in the Core Identity section.
# Returns empty string if not found or file doesn't exist.
_parse_persona_field() {
    local persona_file="$1"
    local field_name="$2"     # e.g. "Name", "Role", "Uniform Color"
    if [ ! -f "$persona_file" ]; then
        echo ""
        return
    fi
    # Match "**Field Name:** rest of line" — strip leading/trailing whitespace
    grep -m1 "^\*\*${field_name}:\*\*" "$persona_file" \
        | sed "s/^\*\*${field_name}:\*\*[[:space:]]*//" \
        | sed 's/[[:space:]]*$//'
}

# Find the persona markdown file for a given team+agent.
# Persona filenames follow the pattern: <team>_<character>_<role>_persona.md
# where <role> is the agent identifier (e.g., "chancellor", "engineer", "documentation").
# The agent name may appear in any segment, so we search broadly.
_find_persona_file() {
    local personas_dir="$1"   # INSTALL_ROOT/share/personas/<team>/agents/
    local agent="$2"
    if [ ! -d "$personas_dir" ]; then
        echo ""
        return
    fi
    # First try: agent name as an exact segment between underscores
    local found
    found="$(ls "${personas_dir}"/*_"${agent}"_persona.md 2>/dev/null | head -1 || true)"
    [ -n "$found" ] && { echo "$found"; return; }
    found="$(ls "${personas_dir}"/*_"${agent}"_*_persona.md 2>/dev/null | head -1 || true)"
    [ -n "$found" ] && { echo "$found"; return; }
    # Fallback: substring match (e.g. "chancellor" inside "nahla_chancellor_persona")
    found="$(ls "${personas_dir}"/*persona.md 2>/dev/null | grep "_${agent}_\|_${agent}\.md$" | head -1 || true)"
    echo "$found"
}

# Populate the terminals object in a kanban board JSON from team conf + persona files.
# Usage: populate_board_terminals <team> <board_file>
# Non-fatal: logs warnings on missing data and continues.
populate_board_terminals() {
    local team="$1"
    local board_file="$2"

    if [ ! -f "$board_file" ]; then
        warning "Board file not found for terminal registration: $board_file"
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        warning "jq not available — skipping terminal registration for $team"
        return 0
    fi

    local conf_file="$INSTALL_ROOT/share/teams/${team}.conf"
    if [ ! -f "$conf_file" ]; then
        warning "No conf file for team '$team' — cannot register terminals"
        return 0
    fi

    # Read TEAM_AGENTS array from conf (source in subshell, print one agent per line)
    local agents_raw
    agents_raw="$(
        (
            unset TEAM_REPOS TEAM_BREW_DEPS TEAM_BREW_CASK_DEPS TEAM_AGENTS
            # shellcheck source=/dev/null
            source "$conf_file" 2>/dev/null || true
            for agent in "${TEAM_AGENTS[@]}"; do
                printf '%s\n' "$agent"
            done
        )
    )"

    if [ -z "$agents_raw" ]; then
        warning "No agents found in $conf_file — terminals object will remain empty"
        return 0
    fi

    local personas_dir="$INSTALL_ROOT/share/personas/${team}/agents"

    # Build terminals JSON object incrementally.
    # We start with null and use jq to add each terminal entry.
    local terminals_json="{}"
    while IFS= read -r agent; do
        [ -z "$agent" ] && continue

        # Locate persona file for this agent
        local persona_file
        persona_file="$(_find_persona_file "$personas_dir" "$agent")"

        # Parse character metadata from persona file (empty string if absent)
        local dev_name role raw_color lcars_color
        dev_name="$(_parse_persona_field "$persona_file" "Name")"
        role="$(_parse_persona_field "$persona_file" "Role")"
        raw_color="$(_parse_persona_field "$persona_file" "Uniform Color")"
        lcars_color="$(_map_uniform_color "$raw_color")"

        # Fall back to sensible defaults derived from the agent name
        if [ -z "$dev_name" ]; then
            # Title-case the agent name (Python-based for macOS/Linux portability)
            dev_name="$(python3 -c "import sys; s=sys.argv[1]; print(s[:1].upper()+s[1:])" "$agent" 2>/dev/null || echo "$agent")"
        fi
        if [ -z "$role" ]; then
            role="Team Agent"
        fi

        # Merge this terminal entry into the accumulating JSON object
        # Note: jq --arg handles all JSON string escaping internally (apostrophes, quotes, etc.)
        terminals_json="$(
            printf '%s' "$terminals_json" | \
            jq --arg key "$agent" \
               --arg developer "$dev_name" \
               --arg avatar "$agent" \
               --arg role "$role" \
               --arg color "$lcars_color" \
               '.[$key] = {developer: $developer, avatar: $avatar, role: $role, color: $color}'
        )"
    done <<< "$agents_raw"

    # Patch the board file: merge new terminals into existing terminals object.
    # Existing entries are preserved; new entries are added; conflicting keys
    # are overwritten only if the existing developer field is "Unknown" or empty
    # (i.e. we don't overwrite manual customizations).
    local tmp_file
    tmp_file="$(mktemp /tmp/_kb_terminals_$$.json)"
    local patch_success=false

    jq --argjson new_terminals "$terminals_json" '
        .terminals as $existing |
        ($new_terminals | to_entries) as $new_entries |
        reduce $new_entries[] as $entry (
            $existing;
            if (.[$entry.key] == null)
              or (.[$entry.key].developer == "Unknown")
              or (.[$entry.key].developer == "")
            then
              .[$entry.key] = $entry.value
            else
              .
            end
        ) as $merged_terminals |
        .terminals = $merged_terminals |
        .lastUpdated = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    ' "$board_file" > "$tmp_file" && patch_success=true

    if [ "$patch_success" = true ] && [ -s "$tmp_file" ]; then
        mv "$tmp_file" "$board_file"
        local agent_count
        agent_count="$(echo "$agents_raw" | grep -c '[^[:space:]]' || true)"
        success "Registered ${agent_count} terminal(s) in kanban board for team: $team"
    else
        warning "Failed to patch terminals in board file: $board_file"
        rm -f "$tmp_file"
    fi
}

# Initialize empty kanban board for a team
init_kanban_board() {
    local team="$1"
    local kanban_dir
    kanban_dir="$(get_team_kanban_dir "$team")"

    # For project-based teams, include project name in board filename
    # e.g., ~/legal/coparenting/kanban/ → legal-coparenting-board.json
    local working_dir=""
    working_dir="$(_get_team_working_dir "$team" || true)"
    local parent_dir
    parent_dir="$(dirname "$kanban_dir")"
    local project_name
    project_name="$(basename "$parent_dir")"
    local board_name="${team}"

    # Check if this is a project-based team (working dir ends with a project folder)
    local conf_file="$INSTALL_ROOT/share/teams/${team}.conf"
    if [ -f "$conf_file" ] && grep -q 'TEAM_HAS_PROJECTS="true"' "$conf_file"; then
        board_name="${team}-${project_name}"
    fi

    local board_file="$kanban_dir/${board_name}-board.json"

    # Create kanban directory if it doesn't exist
    mkdir -p "$kanban_dir"
    mkdir -p "$kanban_dir/config"
    mkdir -p "$kanban_dir/releases"

    # Only create board file if it doesn't already exist
    if [ ! -f "$board_file" ]; then
        info "Creating empty kanban board for team: $team"

        # Use template to create initial board structure
        local template="$INSTALL_ROOT/share/templates/kanban/board-template.json"
        if [ -f "$template" ]; then
            # Load team conf variables for template substitution
            local team_id="$team"
            local team_name="$team"
            local team_subtitle=""
            local team_ship=""
            local team_series
            team_series="$(derive_series_prefix "$team")"
            local team_org="DEVTEAM"
            local team_org_color="white"
            local team_category=""

            if [ -f "$conf_file" ]; then
                # Create a secure temp file for conf variable extraction
                local _conf_tmp
                _conf_tmp="$(mktemp)" || { warn "Failed to create temp file for conf extraction"; _conf_tmp=""; }
                # Clean up temp file on exit (handles early returns and signals)
                trap 'rm -f "$_conf_tmp"' EXIT

                # Source conf to get team variables (unset arrays first to avoid parse errors)
                (
                    # Temporarily unset array vars that might cause issues in subshell
                    unset TEAM_REPOS TEAM_BREW_DEPS TEAM_BREW_CASK_DEPS TEAM_AGENTS
                    # shellcheck source=/dev/null
                    source "$conf_file" 2>/dev/null || true
                    echo "TEAM_ID=${TEAM_ID:-$team}"
                    echo "TEAM_NAME=${TEAM_NAME:-$team}"
                    echo "TEAM_THEME=${TEAM_THEME:-}"
                    echo "TEAM_SHIP=${TEAM_SHIP:-}"
                    echo "TEAM_CATEGORY=${TEAM_CATEGORY:-}"
                    echo "TEAM_ORGANIZATION=${TEAM_ORGANIZATION:-}"
                ) > "$_conf_tmp"

                # Read back the exported values
                while IFS='=' read -r key val; do
                    case "$key" in
                        TEAM_ID)           team_id="$val" ;;
                        TEAM_NAME)         team_name="$val" ;;
                        TEAM_THEME)        team_subtitle="$val" ;;
                        TEAM_SHIP)         team_ship="$val" ;;
                        TEAM_CATEGORY)     team_category="$val" ;;
                        TEAM_ORGANIZATION) [ -n "$val" ] && team_org="$val" ;;
                    esac
                done < "$_conf_tmp"
                rm -f "$_conf_tmp"
                trap - EXIT

                # Derive series from team ID and org color from category
                team_series="$(derive_series_prefix "$team_id")"
                team_org_color="$(derive_org_color "$team_category")"
            fi

            # Convert team name to uppercase for display
            local team_name_upper
            team_name_upper="$(echo "$team_name" | tr '[:lower:]' '[:upper:]')"
            local team_subtitle_upper=""
            [ -n "$team_subtitle" ] && team_subtitle_upper="$(echo "$team_subtitle" | tr '[:lower:]' '[:upper:]')"

            # Generate ISO timestamp for board creation date
            local created_date
            created_date="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

            # Resolve kanban dir (expand HOME)
            local kanban_dir_resolved="${kanban_dir/\$HOME/$HOME}"

            # Substitute all template variables
            sed \
                -e "s|{{TEAM_ID}}|${team_id}|g" \
                -e "s|{{TEAM_NAME}}|${team_name_upper}|g" \
                -e "s|{{TEAM_SUBTITLE}}|${team_subtitle_upper}|g" \
                -e "s|{{TEAM_SHIP}}|${team_ship}|g" \
                -e "s|{{TEAM_SERIES}}|${team_series}|g" \
                -e "s|{{TEAM_ORG}}|${team_org}|g" \
                -e "s|{{TEAM_ORG_COLOR}}|${team_org_color}|g" \
                -e "s|{{KANBAN_DIR}}|${kanban_dir_resolved}|g" \
                -e "s|{{CREATED_DATE}}|${created_date}|g" \
                "$template" > "$board_file"
        else
            # Fallback to minimal structure
            local created_date
            created_date="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            cat > "$board_file" << EOF
{
  "team": "$board_name",
  "teamName": "$(echo "$board_name" | tr '[:lower:]' '[:upper:]')",
  "subtitle": "",
  "ship": "",
  "series": "$(derive_series_prefix "$team")",
  "organization": "DEVTEAM",
  "orgColor": "white",
  "kanbanDir": "$kanban_dir",
  "lastUpdated": "$created_date",
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
        fi

        success "Created kanban board: $board_file"

        # Populate terminals from team conf + persona files.
        # Non-fatal: board is still usable if this step fails.
        populate_board_terminals "$team" "$board_file"
    else
        info "Kanban board already exists: $board_file (skipping)"
    fi
}

# Install kanban-helpers.sh
install_kanban_helpers() {
    # Prefer the standalone kanban-aliases.sh (works without tmux/dev-team context)
    # Fall back to the full kanban-helpers.template.sh if aliases not found
    local template=""
    if [ -f "$INSTALL_ROOT/share/templates/aliases/kanban-aliases.sh" ]; then
        template="$INSTALL_ROOT/share/templates/aliases/kanban-aliases.sh"
    elif [ -f "$INSTALL_ROOT/share/templates/kanban/kanban-helpers.template.sh" ]; then
        template="$INSTALL_ROOT/share/templates/kanban/kanban-helpers.template.sh"
    fi
    local target="$AITEAMFORGE_DIR/kanban-helpers.sh"

    if [ -z "$template" ] || [ ! -f "$template" ]; then
        warning "Kanban helpers template not found (skipping)"
        return 0
    fi

    info "Installing kanban helper functions"

    # Substitute AITEAMFORGE_DIR in template
    sed -e "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g" \
        "$template" > "$target"

    chmod +x "$target"
    success "Installed: $target"
}

# Install board check and restore helper scripts to AITEAMFORGE_DIR
install_board_check_scripts() {
    local scripts_src="$INSTALL_ROOT/share/scripts"
    local board_check_src="${scripts_src}/kanban-board-check.sh"
    local restore_helper_src="${scripts_src}/kanban-restore-helper.sh"

    # Destination: alongside kanban-helpers.sh for easy sourcing
    local board_check_dest="$AITEAMFORGE_DIR/kanban-board-check.sh"
    local restore_helper_dest="$AITEAMFORGE_DIR/kanban-restore-helper.sh"

    if [ ! -f "$board_check_src" ]; then
        warning "Board check script not found at: ${board_check_src} (skipping)"
        return 0
    fi

    info "Installing kanban board check script"
    cp "$board_check_src" "$board_check_dest"
    chmod +x "$board_check_dest"
    success "Installed: $board_check_dest"

    if [ ! -f "$restore_helper_src" ]; then
        warning "Restore helper script not found at: ${restore_helper_src} (skipping)"
        return 0
    fi

    info "Installing kanban restore helper script"
    cp "$restore_helper_src" "$restore_helper_dest"
    chmod +x "$restore_helper_dest"
    success "Installed: $restore_helper_dest"
}

# Install kanban hooks
install_kanban_hooks() {
    local hooks_src="$INSTALL_ROOT/share/kanban-hooks"
    local hooks_dest="$AITEAMFORGE_DIR/kanban-hooks"

    if [ ! -d "$hooks_src" ]; then
        warning "Kanban hooks not found at: $hooks_src (skipping)"
        return 0
    fi

    info "Installing kanban hooks"

    # Create hooks directory
    mkdir -p "$hooks_dest"

    # Copy all Python hook files
    cp -r "$hooks_src"/* "$hooks_dest/"

    # Make hook scripts executable
    chmod +x "$hooks_dest"/*.py 2>/dev/null || true

    success "Installed kanban hooks to: $hooks_dest"
}

# Install LCARS web UI
install_lcars_ui() {
    local lcars_src="$INSTALL_ROOT/share/lcars-ui"
    local lcars_dest="$AITEAMFORGE_DIR/lcars-ui"

    if [ ! -d "$lcars_src" ]; then
        warning "LCARS UI not found at: $lcars_src (skipping)"
        return 0
    fi

    info "Installing LCARS web UI"

    # Create LCARS directory
    mkdir -p "$lcars_dest"

    # Copy all LCARS files recursively
    cp -r "$lcars_src"/* "$lcars_dest/"

    # Make server script executable
    chmod +x "$lcars_dest/server.py" 2>/dev/null || true
    chmod +x "$lcars_dest"/*.sh 2>/dev/null || true

    success "Installed LCARS UI to: $lcars_dest"
}

# Install LCARS profile creation script for iTerm2 browser tab
install_lcars_profile_script() {
    local scripts_dest="$AITEAMFORGE_DIR/scripts"
    mkdir -p "$scripts_dest"

    # Install LCARS profile creator
    local create_src="$INSTALL_ROOT/share/scripts/create-lcars-profile.py"
    if [ -f "$create_src" ]; then
        cp "$create_src" "$scripts_dest/create-lcars-profile.py"
        chmod +x "$scripts_dest/create-lcars-profile.py"
        info "Installed: create-lcars-profile.py"
    else
        warning "create-lcars-profile.py not found (skipping)"
    fi

    # Install LCARS profile URL setter (for inline browser tabs)
    local setter_src="$INSTALL_ROOT/share/scripts/set-lcars-profile-browser.py"
    if [ -f "$setter_src" ]; then
        cp "$setter_src" "$scripts_dest/set-lcars-profile-browser.py"
        chmod +x "$scripts_dest/set-lcars-profile-browser.py"
        info "Installed: set-lcars-profile-browser.py"
    else
        warning "set-lcars-profile-browser.py not found (skipping)"
    fi

    # Install Dynamic Profile JSON to iTerm2's hot-load directory.
    # iTerm2 reads this directory automatically — no restart required.
    # The profile uses 'Initial URL' (correct key for browser-mode tabs).
    # set-lcars-profile-browser.py updates this file at team startup time
    # to point to the correct per-team LCARS port.
    local dynamic_profiles_dir="$HOME/Library/Application Support/iTerm2/DynamicProfiles"
    local dynamic_profile_src="$INSTALL_ROOT/share/scripts/aiteamforge-lcars.json"
    local dynamic_profile_dest="$dynamic_profiles_dir/aiteamforge-lcars.json"

    if [ -f "$dynamic_profile_src" ]; then
        mkdir -p "$dynamic_profiles_dir"
        # Only install if the file does not already exist (avoid overwriting
        # a customized profile with a different URL or color settings)
        if [ ! -f "$dynamic_profile_dest" ]; then
            cp "$dynamic_profile_src" "$dynamic_profile_dest"
            info "Installed iTerm2 Dynamic Profile: aiteamforge-lcars.json"
        else
            info "iTerm2 Dynamic Profile already present (skipping overwrite)"
        fi
    else
        warning "aiteamforge-lcars.json not found (skipping Dynamic Profile install)"
    fi
}

# Install iTerm2 window manager script
# Deploys iterm2_window_manager.py to both:
#   $AITEAMFORGE_DIR/scripts/iterm2_window_manager.py  (canonical scripts location)
#   $AITEAMFORGE_DIR/iterm2_window_manager.py           (root location checked by startup templates)
# Templates use a two-path fallback and will find it in either location.
install_iterm2_window_manager() {
    local src="$INSTALL_ROOT/share/scripts/iterm2_window_manager.py"

    if [ ! -f "$src" ]; then
        warning "iterm2_window_manager.py not found at: $src (skipping)"
        return 0
    fi

    local scripts_dest="$AITEAMFORGE_DIR/scripts"
    mkdir -p "$scripts_dest"

    # Install to scripts/ subdirectory (canonical location)
    cp "$src" "$scripts_dest/iterm2_window_manager.py"
    chmod +x "$scripts_dest/iterm2_window_manager.py"
    info "Installed: $scripts_dest/iterm2_window_manager.py"

    # Also promote to AITEAMFORGE_DIR root — startup templates check this path first
    # (team-startup.sh.template, team-project-startup.sh.template, agent-panel-display.sh)
    cp "$src" "$AITEAMFORGE_DIR/iterm2_window_manager.py"
    chmod +x "$AITEAMFORGE_DIR/iterm2_window_manager.py"
    info "Installed: $AITEAMFORGE_DIR/iterm2_window_manager.py"

    success "Installed iterm2_window_manager.py"
}

# Configure LCARS port
configure_lcars_port() {
    local port="${1:-$DEFAULT_LCARS_PORT}"
    local port_config="$AITEAMFORGE_DIR/lcars-ui/lcars-target.js"

    info "Configuring LCARS port: $port"

    # Create simple port configuration file
    cat > "$port_config" << EOF
// LCARS Server Port Configuration
// Generated by aiteamforge installer
const LCARS_PORT = $port;
EOF

    # Also create a shell-readable version
    echo "$port" > "$AITEAMFORGE_DIR/lcars-ui/.lcars-port"

    success "LCARS port configured: $port"
}

# Install port management files
install_port_management() {
    local ports_src="$INSTALL_ROOT/share/lcars-ports"
    local ports_dest="$AITEAMFORGE_DIR/lcars-ports"

    info "Installing port management configuration"

    mkdir -p "$ports_dest"

    # Copy port configuration template
    local port_template="$INSTALL_ROOT/share/templates/kanban/port-config.json"
    if [ -f "$port_template" ]; then
        cp "$port_template" "$ports_dest/port-config.json"
    fi

    # If source ports exist, copy them as examples
    if [ -d "$ports_src" ]; then
        cp -r "$ports_src"/* "$ports_dest/" 2>/dev/null || true
    fi

    success "Installed port management to: $ports_dest"
}

# Install kanban backup system
install_kanban_backup() {
    local backup_script_src="$INSTALL_ROOT/share/scripts/kanban-backup.py"
    local backup_script_dest="$AITEAMFORGE_DIR/kanban-backup.py"

    if [ ! -f "$backup_script_src" ]; then
        warning "Backup script not found (skipping automated backups)"
        return 0
    fi

    info "Installing kanban backup system"

    # Copy backup script
    cp "$backup_script_src" "$backup_script_dest"
    chmod +x "$backup_script_dest"

    # Create backup directory
    mkdir -p "$HOME/aiteamforge-backups/kanban"

    success "Installed backup script: $backup_script_dest"
}

# Install and load LaunchAgent for backup automation
install_backup_launchagent() {
    local plist_template="$INSTALL_ROOT/share/templates/kanban/backup-plist.template"
    local plist_dest="$HOME/Library/LaunchAgents/${KANBAN_BACKUP_LABEL}.plist"

    if [ ! -f "$plist_template" ]; then
        warning "LaunchAgent template not found: $plist_template (skipping)"
        return 0
    fi

    info "Installing backup LaunchAgent"

    # Create LaunchAgents directory if needed
    mkdir -p "$HOME/Library/LaunchAgents"

    # Find python3 path
    local python3_path
    python3_path="$(command -v python3 2>/dev/null || echo "/usr/bin/python3")"

    # Substitute variables in template
    sed -e "s|{{USER_HOME}}|$HOME|g" \
        -e "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g" \
        -e "s|{{BACKUP_INTERVAL}}|$KANBAN_BACKUP_INTERVAL|g" \
        -e "s|{{PYTHON3_PATH}}|$python3_path|g" \
        "$plist_template" > "$plist_dest"

    # Unload if already loaded (ignore errors)
    launchctl unload "$plist_dest" 2>/dev/null || true

    # Load the LaunchAgent
    if launchctl load "$plist_dest"; then
        success "Installed and loaded backup LaunchAgent"
        info "Backups will run every 15 minutes"
    else
        warning "Failed to load LaunchAgent (may need manual activation)"
    fi
}

# Uninstall backup LaunchAgent
uninstall_backup_launchagent() {
    local plist_file="$HOME/Library/LaunchAgents/${KANBAN_BACKUP_LABEL}.plist"

    if [ -f "$plist_file" ]; then
        info "Unloading backup LaunchAgent"
        launchctl unload "$plist_file" 2>/dev/null || true
        rm -f "$plist_file"
        success "Removed backup LaunchAgent"
    fi
}

# Install LCARS health check LaunchAgent
install_lcars_health_launchagent() {
    local plist_template="$INSTALL_ROOT/share/templates/kanban/lcars-health-plist.template"
    local plist_dest="$HOME/Library/LaunchAgents/com.aiteamforge.lcars-health.plist"

    if [ ! -f "$plist_template" ]; then
        warning "LCARS health LaunchAgent template not found (skipping)"
        return 0
    fi

    info "Installing LCARS health LaunchAgent"
    mkdir -p "$HOME/Library/LaunchAgents"

    sed -e "s|{{USER_HOME}}|$HOME|g" \
        -e "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g" \
        "$plist_template" > "$plist_dest"

    launchctl unload "$plist_dest" 2>/dev/null || true

    if launchctl load "$plist_dest"; then
        success "Installed and loaded LCARS health LaunchAgent"
        info "Health checks will run every 5 minutes"
    else
        warning "Failed to load LCARS health LaunchAgent (may need manual activation)"
    fi
}

# Uninstall LCARS health LaunchAgent
uninstall_lcars_health_launchagent() {
    local plist_file="$HOME/Library/LaunchAgents/com.aiteamforge.lcars-health.plist"

    if [ -f "$plist_file" ]; then
        info "Unloading LCARS health LaunchAgent"
        launchctl unload "$plist_file" 2>/dev/null || true
        rm -f "$plist_file"
        success "Removed LCARS health LaunchAgent"
    fi
}

# Test LCARS server startup
test_lcars_server() {
    local port="${1:-$DEFAULT_LCARS_PORT}"
    local server_script="$AITEAMFORGE_DIR/lcars-ui/server.py"

    if [ ! -f "$server_script" ]; then
        warning "LCARS server not found, skipping test"
        return 0
    fi

    info "Testing LCARS server startup..."

    # Start server in background
    python3 "$server_script" "$port" &>/dev/null &
    local server_pid=$!

    # Wait a moment for startup
    sleep 2

    # Check if server is running
    if kill -0 "$server_pid" 2>/dev/null; then
        success "LCARS server started successfully on port $port"
        info "Access at: http://localhost:$port"

        # Stop the test server
        kill "$server_pid" 2>/dev/null || true
        return 0
    else
        warning "LCARS server failed to start (check port availability)"
        return 1
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# Main Installation Function
#──────────────────────────────────────────────────────────────────────────────

install_kanban_system() {
    header "Installing LCARS Kanban System"

    # Get selected teams from wizard env var, config file, or default
    local teams=()
    if [ -n "${SELECTED_TEAMS:-}" ]; then
        # Teams passed from setup wizard
        read -ra teams <<< "$SELECTED_TEAMS"
    elif [ -f "$AITEAMFORGE_DIR/.aiteamforge-config" ]; then
        # Read teams from JSON config file
        if command -v jq &>/dev/null; then
            while IFS= read -r team; do
                teams+=("$team")
            done < <(jq -r '.teams[]' "$AITEAMFORGE_DIR/.aiteamforge-config" 2>/dev/null)
        fi
    fi

    # Default to empty if no teams found (don't assume academy)
    if [ ${#teams[@]} -eq 0 ]; then
        warning "No teams specified for kanban boards"
        return 0
    fi

    info "Setting up kanban boards for teams: ${teams[*]}"

    # Install core kanban components (non-fatal if templates missing)
    install_kanban_helpers
    install_board_check_scripts
    install_kanban_hooks

    # Initialize kanban boards for each team
    for team in "${teams[@]}"; do
        init_kanban_board "$team"
    done

    # Install LCARS UI (non-fatal if source missing)
    install_lcars_ui

    # Install LCARS profile script for iTerm2 browser tab (non-fatal)
    install_lcars_profile_script

    # Install iTerm2 window manager (referenced by startup templates, non-fatal)
    install_iterm2_window_manager

    # Configure LCARS port with default (non-interactive in setup wizard context)
    local lcars_port=$DEFAULT_LCARS_PORT
    if [ -d "$AITEAMFORGE_DIR/lcars-ui" ]; then
        configure_lcars_port "$lcars_port"
    fi
    install_port_management

    # Install backup system (non-fatal if script missing)
    install_kanban_backup

    # Install LaunchAgents if templates exist
    install_backup_launchagent
    install_lcars_health_launchagent

    success "LCARS Kanban System installed successfully"

    info ""
    info "Kanban System Ready:"
    info "  • Boards initialized for: ${teams[*]}"
    [ -d "$AITEAMFORGE_DIR/lcars-ui" ] && info "  • LCARS UI: http://localhost:$lcars_port"
    [ -f "$AITEAMFORGE_DIR/kanban-backup.py" ] && info "  • Backup system: Automated (every 15 min)"
    [ -f "$AITEAMFORGE_DIR/kanban-helpers.sh" ] && info "  • Helper functions: source $AITEAMFORGE_DIR/kanban-helpers.sh"
    info ""
    if [ -d "$AITEAMFORGE_DIR/lcars-ui" ]; then
        info "To start LCARS server manually:"
        info "  python3 $AITEAMFORGE_DIR/lcars-ui/server.py $lcars_port"
        info ""
    fi

    return 0
}

#──────────────────────────────────────────────────────────────────────────────
# Uninstall Function
#──────────────────────────────────────────────────────────────────────────────

uninstall_kanban_system() {
    header "Uninstalling LCARS Kanban System"

    # Unload LaunchAgent
    uninstall_backup_launchagent

    # Remove installed files
    info "Removing kanban system files"
    rm -f "$AITEAMFORGE_DIR/kanban-helpers.sh"
    rm -rf "$AITEAMFORGE_DIR/kanban-hooks"
    rm -rf "$AITEAMFORGE_DIR/lcars-ui"
    rm -rf "$AITEAMFORGE_DIR/lcars-ports"
    rm -f "$AITEAMFORGE_DIR/kanban-backup.py"

    # Ask about board data
    if prompt_yes_no "Remove kanban board data?" "n"; then
        warning "This will delete all kanban boards and history!"
        if prompt_yes_no "Are you SURE?" "n"; then
            rm -rf "$AITEAMFORGE_DIR/kanban"
            rm -rf "$HOME/aiteamforge-backups/kanban"
            success "Removed all kanban data"
        fi
    else
        info "Keeping kanban board data (can be manually removed later)"
    fi

    success "LCARS Kanban System uninstalled"

    return 0
}

#──────────────────────────────────────────────────────────────────────────────
# Export functions for setup wizard
#──────────────────────────────────────────────────────────────────────────────

export -f install_kanban_system
export -f uninstall_kanban_system
export -f populate_board_terminals
