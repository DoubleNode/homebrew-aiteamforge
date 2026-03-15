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
                ) > /tmp/_kanban_conf_$$.env

                # Read back the exported values
                while IFS='=' read -r key val; do
                    case "$key" in
                        TEAM_ID)       team_id="$val" ;;
                        TEAM_NAME)     team_name="$val" ;;
                        TEAM_THEME)    team_subtitle="$val" ;;
                        TEAM_SHIP)     team_ship="$val" ;;
                        TEAM_CATEGORY) team_category="$val" ;;
                    esac
                done < /tmp/_kanban_conf_$$.env
                rm -f /tmp/_kanban_conf_$$.env

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
    else
        info "Kanban board already exists: $board_file (skipping)"
    fi
}

# Install kanban-helpers.sh
install_kanban_helpers() {
    local template="$INSTALL_ROOT/share/templates/kanban/kanban-helpers.template.sh"
    local target="$AITEAMFORGE_DIR/kanban-helpers.sh"

    if [ ! -f "$template" ]; then
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

    # Configure LCARS port with default (non-interactive in setup wizard context)
    local lcars_port=$DEFAULT_LCARS_PORT
    if [ -d "$AITEAMFORGE_DIR/lcars-ui" ]; then
        configure_lcars_port "$lcars_port"
    fi
    install_port_management

    # Install backup system (non-fatal if script missing)
    install_kanban_backup

    # Install backup LaunchAgent if template exists
    install_backup_launchagent

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
