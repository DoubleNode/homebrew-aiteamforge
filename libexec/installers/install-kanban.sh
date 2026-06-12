#!/bin/bash
# LCARS Kanban System Installer
# Sets up kanban boards, LCARS web UI, backup system, and port management

set -euo pipefail

# Source common utilities and shared constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/constants.sh"

#──────────────────────────────────────────────────────────────────────────────
# Constants
#──────────────────────────────────────────────────────────────────────────────

KANBAN_BACKUP_LABEL="com.aiteamforge.kanban-backup"
KANBAN_BACKUP_INTERVAL="${KANBAN_BACKUP_INTERVAL:-$KANBAN_BACKUP_INTERVAL_DEFAULT}"  # default 900s / 15min — see lib/constants.sh
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
    # Guard for bash 3.2: iterating an empty array under `set -u` throws
    # "unbound variable" on macOS /bin/bash. Reachable if a caller invokes this
    # without TEAM_WORKING_DIRS_STR set (XACA-0559 — same bug class as the
    # empty-teams board loop below).
    [ ${#_TEAM_WORKING_DIRS[@]} -eq 0 ] && return 1
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
            # Fallback to minimal structure, but read branding from registry.json
            # if available (XACA-0460-011). Hard-fail if registry.json exists but
            # lacks an entry for this template — we should never write generic defaults.
            local created_date
            created_date="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            local _reg_json="$INSTALL_ROOT/share/teams/registry.json"
            local _reg_name="" _reg_desc="" _reg_color="" _reg_icon=""
            if [ -f "$_reg_json" ] && command -v jq >/dev/null 2>&1; then
                local _reg_entry
                _reg_entry="$(jq -e --arg tid "$team" '.teams[] | select(.id == $tid)' "$_reg_json" 2>/dev/null)" || {
                    error "Template '${team}' has no entry in registry.json — refusing to write generic board defaults."
                    return 1
                }
                _reg_name="$(echo "$_reg_entry"  | jq -r '.name')"
                _reg_desc="$(echo "$_reg_entry"  | jq -r '.description')"
                _reg_color="$(echo "$_reg_entry" | jq -r '.color')"
                _reg_icon="$(echo "$_reg_entry"  | jq -r '.icon')"
            fi
            # Use registry branding when available; generic fallback only when
            # registry.json itself is missing (should not happen post-install).
            local _org_name="${_reg_name:-DEVTEAM}"
            local _subtitle="${_reg_desc:-}"
            local _org_color="${_reg_color:-white}"
            local _icon="${_reg_icon:-}"
            jq -n \
                --arg team        "$board_name" \
                --arg teamName    "$_org_name" \
                --arg subtitle    "$_subtitle" \
                --arg series      "$(derive_series_prefix "$team")" \
                --arg organization "$_org_name" \
                --arg orgColor    "$_org_color" \
                --arg icon        "$_icon" \
                --arg template    "$team" \
                --arg instance    "$board_name" \
                --arg kanbanDir   "$kanban_dir" \
                --arg created     "$created_date" \
                '{
                  "team":         $team,
                  "teamName":     $teamName,
                  "subtitle":     $subtitle,
                  "ship":         "",
                  "series":       $series,
                  "organization": $organization,
                  "orgColor":     $orgColor,
                  "icon":         $icon,
                  "template":     $template,
                  "instance":     $instance,
                  "kanbanDir":    $kanbanDir,
                  "lastUpdated":  $created,
                  "nextId":       1,
                  "nextEpicId":   1,
                  "nextReleaseId":1,
                  "fleetMonitorUrl": "",
                  "terminals":    {},
                  "activeWindows":[],
                  "backlog":      [],
                  "epics":        [],
                  "releases":     []
                }' > "$board_file"
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

    # XACA-0559 / XACA-0564: refuse to overwrite a git-tracked kanban-helpers.sh.
    # On a real install $AITEAMFORGE_DIR is ~/.aiteamforge (never a git repo) so
    # this guard is a no-op.  On a dev checkout the sed-redirect would silently
    # replace the full source-of-truth helpers with the tiny aliases template,
    # dropping kb-sweep/kb-merge and breaking PR merge gates.
    # Set AITEAMFORGE_ALLOW_DEV_OVERWRITE=1 to override (sandboxed tests only).
    if command -v git >/dev/null 2>&1; then
        local _is_dev_repo=0
        # Check 1: $AITEAMFORGE_DIR is the root of a git work-tree.
        local _git_toplevel
        _git_toplevel="$(git -C "$AITEAMFORGE_DIR" rev-parse --show-toplevel 2>/dev/null)" || true
        if [ -n "$_git_toplevel" ]; then
            local _norm_dir _norm_top
            _norm_dir="$(cd "$AITEAMFORGE_DIR" 2>/dev/null && pwd)" || _norm_dir="$AITEAMFORGE_DIR"
            _norm_top="$(cd "$_git_toplevel" 2>/dev/null && pwd)" || _norm_top="$_git_toplevel"
            if [ "$_norm_dir" = "$_norm_top" ]; then
                _is_dev_repo=1
            fi
        fi
        # Check 2: kanban-helpers.sh is git-tracked there (catches subdir case).
        if [ "$_is_dev_repo" = "0" ]; then
            if git -C "$AITEAMFORGE_DIR" ls-files --error-unmatch kanban-helpers.sh >/dev/null 2>&1; then
                _is_dev_repo=1
            fi
        fi
        if [ "$_is_dev_repo" = "1" ]; then
            if [ "${AITEAMFORGE_ALLOW_DEV_OVERWRITE:-}" = "1" ]; then
                warning "AITEAMFORGE_ALLOW_DEV_OVERWRITE=1 set — overwriting kanban-helpers.sh inside a git work-tree / tracked repo ($AITEAMFORGE_DIR). Proceed with caution."
            else
                error "$AITEAMFORGE_DIR looks like a git work-tree or kanban-helpers.sh is git-tracked there."
                error "Refusing to overwrite the source-of-truth helpers with the installer template (XACA-0559 / XACA-0564)."
                error "Set AITEAMFORGE_ALLOW_DEV_OVERWRITE=1 to override (sandboxed tests only)."
                exit 1
            fi
        fi
    fi

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

# XACA-0585: Install LCARS health check script to AITEAMFORGE_DIR
# Must run before install_lcars_health_launchagent so the script the LaunchAgent
# invokes actually exists at ${AITEAMFORGE_DIR}/lcars-health-check.sh.
install_lcars_health_check_script() {
    local scripts_src="$INSTALL_ROOT/share/scripts"
    local health_check_src="${scripts_src}/lcars-health-check.sh"
    local health_check_dest="$AITEAMFORGE_DIR/lcars-health-check.sh"

    if [ ! -f "$health_check_src" ]; then
        warning "LCARS health check script not found at: ${health_check_src} (skipping)"
        return 0
    fi

    info "Installing LCARS health check script"
    cp "$health_check_src" "$health_check_dest"
    chmod +x "$health_check_dest"
    success "Installed: $health_check_dest"
}

# XACA-0584: Install worktree persona deployment helper to AITEAMFORGE_DIR/scripts/.
# The wt-new hook (-x guard) calls this script to copy master personas into each
# new worktree's .claude/agents/ dir on tap machines where gitignored personas are
# absent after checkout. Without this seed the entire wt-new -x feature is a no-op.
install_worktree_personas_script() {
    local scripts_src="$INSTALL_ROOT/share/scripts"
    local src="${scripts_src}/deploy-worktree-personas.sh"
    local dest="$AITEAMFORGE_DIR/scripts/deploy-worktree-personas.sh"

    if [ ! -f "$src" ]; then
        warning "deploy-worktree-personas.sh not found at: ${src} (skipping)"
        return 0
    fi

    mkdir -p "$AITEAMFORGE_DIR/scripts"
    info "Installing worktree persona deployment helper"
    cp "$src" "$dest"
    chmod +x "$dest"
    success "Installed: $dest"
}

# XACA-0626: Install kb-port-reconcile to AITEAMFORGE_DIR/scripts/ so tap machines
# can self-heal LCARS port drift without requiring a full reinstall or dev-machine access.
# Without this, --apply cannot run on M1Pro/M4Mini (the tool was dev-only before XACA-0626).
# SIBLING-DRIFT NOTE: this install function is paired with:
#   (a) _xaca0608_aux_script_map entry in aiteamforge-upgrade.sh (refresh on upgrade)
#   (b) remove entry in aiteamforge-uninstall.sh::uninstall_kanban_system (teardown)
# All three sites must stay in sync when kb-port-reconcile is renamed or moved.
install_kb_port_reconcile_script() {
    local scripts_src="$INSTALL_ROOT/share/scripts"
    local src="${scripts_src}/kb-port-reconcile"
    local dest="$AITEAMFORGE_DIR/scripts/kb-port-reconcile"

    if [ ! -f "$src" ]; then
        warning "kb-port-reconcile not found at: ${src} (skipping)"
        return 0
    fi

    mkdir -p "$AITEAMFORGE_DIR/scripts"
    info "Installing kb-port-reconcile (LCARS port drift reconciler)"
    cp "$src" "$dest"
    chmod +x "$dest"
    success "Installed: $dest"
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

    # Install shared hostname resolver (Tailscale → hostname fallback).
    # Used by per-agent tmux scripts to set status-right consistent with
    # the LCARS header's server hostname display.
    local hostname_src="$INSTALL_ROOT/share/scripts/aiteamforge-resolve-hostname.sh"
    if [ -f "$hostname_src" ]; then
        cp "$hostname_src" "$scripts_dest/aiteamforge-resolve-hostname.sh"
        chmod +x "$scripts_dest/aiteamforge-resolve-hostname.sh"
        info "Installed: aiteamforge-resolve-hostname.sh"
    else
        warning "aiteamforge-resolve-hostname.sh not found (skipping)"
    fi

    # Install kb-cr (CR-Lifecycle) helper. Sourced by kanban-helpers.sh.
    # All subcommands no-op when teamConfig.crSupport.enabled=false (default).
    local kbcr_src="$INSTALL_ROOT/share/scripts/kb-cr.sh"
    if [ -f "$kbcr_src" ]; then
        cp "$kbcr_src" "$scripts_dest/kb-cr.sh"
        chmod +x "$scripts_dest/kb-cr.sh"
        info "Installed: kb-cr.sh"
    else
        warning "kb-cr.sh not found (skipping)"
    fi

    # Install kb-tap-release — one-shot homebrew-tap release-cut script (XACA-0570).
    # Reads VERSION, computes next semver, promotes CHANGELOG [Unreleased] -> dated
    # [X.Y.Z], maintains compare-URL footer, bumps VERSION + Formula tag/version,
    # commits + tags + pushes the tap inner, then bumps the outer-repo submodule
    # pointer + commits + pushes. 12 preflight checks with --dry-run / --no-push.
    local kbtaprelease_src="$INSTALL_ROOT/share/scripts/kb-tap-release"
    if [ -f "$kbtaprelease_src" ]; then
        cp "$kbtaprelease_src" "$scripts_dest/kb-tap-release"
        chmod +x "$scripts_dest/kb-tap-release"
        info "Installed: kb-tap-release"
    else
        warning "kb-tap-release not found (skipping)"
    fi

    # Install migrate-cr-schema.py — one-shot migration tool that upgrades
    # kanban board JSON from pre-v2.0.0 cr fields to the crs[] container schema.
    # Operators run this manually after upgrading if they have existing CR data.
    local migrate_cr_src="$INSTALL_ROOT/share/scripts/migrate-cr-schema.py"
    if [ -f "$migrate_cr_src" ]; then
        cp "$migrate_cr_src" "$scripts_dest/migrate-cr-schema.py"
        chmod +x "$scripts_dest/migrate-cr-schema.py"
        info "Installed: migrate-cr-schema.py"
    else
        warning "migrate-cr-schema.py not found (skipping)"
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
        if [ ! -f "$dynamic_profile_dest" ]; then
            # Fresh install: live file absent — copy source unconditionally
            cp "$dynamic_profile_src" "$dynamic_profile_dest"
            info "Installed fresh dynamic profile at $dynamic_profile_dest"
        elif [ "${AITEAMFORGE_REFRESH_PROFILES:-}" = "1" ]; then
            # Refresh requested: merge AITeamForge-managed keys, preserve user customizations
            local merge_script="$SCRIPT_DIR/merge-dynamic-profile.py"
            if [ ! -f "$merge_script" ]; then
                warning "merge-dynamic-profile.py not found at $merge_script — cannot refresh profile"
                return 1
            fi
            python3 "$merge_script" "$dynamic_profile_src" "$dynamic_profile_dest"
            local merge_exit=$?
            if [ $merge_exit -ne 0 ]; then
                warning "Dynamic profile merge failed (exit code $merge_exit)"
                return 1
            fi
            info "Refreshed dynamic profile (user customizations preserved)"
        else
            # Live file exists and refresh not requested — leave it alone
            info "Dynamic profile already exists — skipping. Use --refresh-profiles to update AITeamForge-managed keys."
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

    # XACA-0651: the backup agent runs with RunAtLoad=true and redirects stdout/stderr
    # into ~/aiteamforge-backups/kanban/. That directory is normally created by
    # install_kanban_backup, but that helper early-returns when the backup script
    # source is missing — leaving the log dir absent, so launchd cannot open the
    # job's StandardOutPath and the agent never registers. (The lcars-health agent
    # logs to /tmp and so always loads — that asymmetry is exactly the consumer
    # symptom this fixes.) Create the log dir here so the load is self-sufficient.
    mkdir -p "$HOME/aiteamforge-backups/kanban"

    # Find python3 path
    local python3_path
    python3_path="$(command -v python3 2>/dev/null || echo "/usr/bin/python3")"

    # XACA-0651: guard the StartInterval substitution. An empty KANBAN_BACKUP_INTERVAL
    # renders <integer></integer> — an invalid plist that launchctl rejects. Fall back
    # to the documented 900s default rather than emit a malformed plist.
    local backup_interval="${KANBAN_BACKUP_INTERVAL:-900}"
    case "$backup_interval" in
        ''|*[!0-9]*) backup_interval=900 ;;
    esac

    # Substitute variables in template
    sed -e "s|{{USER_HOME}}|$HOME|g" \
        -e "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g" \
        -e "s|{{BACKUP_INTERVAL}}|$backup_interval|g" \
        -e "s|{{PYTHON3_PATH}}|$python3_path|g" \
        "$plist_template" > "$plist_dest"

    # Unload if already loaded (ignore errors)
    _aitf_launchctl unload "$plist_dest" 2>/dev/null || true

    # Load the LaunchAgent. XACA-0651: legacy `launchctl load` returns 0 even when the
    # job is rejected, so verify registration with `launchctl list` rather than trust
    # the exit code — the old code reported a false "loaded" success.
    _aitf_launchctl load "$plist_dest" 2>/dev/null || true
    if launchctl list 2>/dev/null | grep -q "${KANBAN_BACKUP_LABEL}"; then
        success "Installed and loaded backup LaunchAgent"
        info "Backups will run every ${backup_interval}s"
    else
        warning "Backup LaunchAgent installed but not loaded — activate with: launchctl load ${plist_dest}"
    fi
}

# Uninstall backup LaunchAgent
uninstall_backup_launchagent() {
    local plist_file="$HOME/Library/LaunchAgents/${KANBAN_BACKUP_LABEL}.plist"

    if [ -f "$plist_file" ]; then
        info "Unloading backup LaunchAgent"
        _aitf_launchctl unload "$plist_file" 2>/dev/null || true
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

    _aitf_launchctl unload "$plist_dest" 2>/dev/null || true

    # XACA-0651: verify registration via `launchctl list` rather than trust the legacy
    # `launchctl load` exit code (which returns 0 even when the job is rejected). Kept
    # consistent with install_backup_launchagent so neither inherits the false-success
    # bug if either ever gains a non-/tmp log path or RunAtLoad behavior (XACA-0651-009).
    _aitf_launchctl load "$plist_dest" 2>/dev/null || true
    if launchctl list 2>/dev/null | grep -q "com.aiteamforge.lcars-health"; then
        success "Installed and loaded LCARS health LaunchAgent"
        info "Health checks will run every 5 minutes"
    else
        warning "LCARS health LaunchAgent installed but not loaded — activate with: launchctl load ${plist_dest}"
    fi
}

# Uninstall LCARS health LaunchAgent
uninstall_lcars_health_launchagent() {
    local plist_file="$HOME/Library/LaunchAgents/com.aiteamforge.lcars-health.plist"

    if [ -f "$plist_file" ]; then
        info "Unloading LCARS health LaunchAgent"
        _aitf_launchctl unload "$plist_file" 2>/dev/null || true
        rm -f "$plist_file"
        success "Removed LCARS health LaunchAgent"
    fi
}

# Install LCARS WatchPaths LaunchAgent — triggers restart on lcars-ui changes (XACA-0571)
#
# Creates a passive launchd watcher on $AITEAMFORGE_DIR/lcars-ui. When the
# upgrade process refreshes that directory, launchd fires "aiteamforge restart
# lcars" exactly once (ThrottleInterval=30s debounces the burst of file events).
#
# This is intentionally NOT a persistent daemon (no KeepAlive, no RunAtLoad) —
# it only acts when files actually change.
#
# XACA-0571-014 SIBLING-DRIFT NOTE: this installer uses inline sed for first-time
# render. A SECOND renderer lives at libexec/commands/aiteamforge-upgrade.sh
# (_render_launchagent_template) which re-renders the SAME template on every
# `aiteamforge upgrade`. Both must understand the SAME placeholder vocabulary
# ({{AITEAMFORGE_BIN}}, {{LCARS_UI_DIR}}, {{LOG_DIR}}, {{AITEAMFORGE_DIR}},
# {{HOME_DIR}}) — adding a placeholder here requires updating the upgrade-side
# renderer too, otherwise upgraded plists ship with unresolved {{...}} tokens.
install_lcars_watch_launchagent() {
    local plist_template="$INSTALL_ROOT/share/templates/auto-upgrade/lcars-watch-launchagent.template.plist"
    local plist_dest="$HOME/Library/LaunchAgents/com.aiteamforge.lcars-watch.plist"
    local lcars_ui_dir="$AITEAMFORGE_DIR/lcars-ui"

    if [ ! -f "$plist_template" ]; then
        warning "LCARS watch LaunchAgent template not found (skipping)"
        return 0
    fi

    if [ ! -d "$lcars_ui_dir" ]; then
        info "LCARS UI not yet installed, skipping watch LaunchAgent (will install on next kanban install)"
        return 0
    fi

    # Resolve the aiteamforge binary path from Homebrew prefix
    local brew_prefix
    if command -v brew &>/dev/null; then
        brew_prefix="$(brew --prefix)"
    else
        brew_prefix="/opt/homebrew"
    fi
    local aiteamforge_bin="${brew_prefix}/bin/aiteamforge"

    info "Installing LCARS watch LaunchAgent..."

    mkdir -p "$HOME/Library/LaunchAgents"
    mkdir -p "$AITEAMFORGE_DIR/logs"

    sed \
        -e "s|{{AITEAMFORGE_BIN}}|${aiteamforge_bin}|g" \
        -e "s|{{LCARS_UI_DIR}}|${lcars_ui_dir}|g" \
        -e "s|{{LOG_DIR}}|${AITEAMFORGE_DIR}/logs|g" \
        -e "s|{{HOME_DIR}}|${HOME}|g" \
        -e "s|{{AITEAMFORGE_DIR}}|${AITEAMFORGE_DIR}|g" \
        "$plist_template" > "$plist_dest"

    _aitf_launchctl unload "$plist_dest" 2>/dev/null || true

    # XACA-0651: verify registration via `launchctl list` rather than trust the legacy
    # `launchctl load` exit code (returns 0 even on reject). Consistent with
    # install_backup_launchagent / install_lcars_health_launchagent (XACA-0651-009).
    _aitf_launchctl load "$plist_dest" 2>/dev/null || true
    if launchctl list 2>/dev/null | grep -q "com.aiteamforge.lcars-watch"; then
        success "LCARS watch LaunchAgent installed — will auto-restart LCARS on upgrade"
    else
        warning "LCARS watch LaunchAgent installed but not loaded — activate with: launchctl load ${plist_dest}"
    fi
}

# Uninstall LCARS WatchPaths LaunchAgent
uninstall_lcars_watch_launchagent() {
    local plist_file="$HOME/Library/LaunchAgents/com.aiteamforge.lcars-watch.plist"

    if [ -f "$plist_file" ]; then
        info "Unloading LCARS watch LaunchAgent"
        _aitf_launchctl unload "$plist_file" 2>/dev/null || true
        rm -f "$plist_file"
        success "Removed LCARS watch LaunchAgent"
    fi
}

# Install RunAtLoad LCARS LaunchAgent — starts all configured LCARS servers at login/reboot (XACA-0626)
#
# Creates a one-shot launchd agent that fires `aiteamforge start lcars` at every
# login/reboot. This ensures LCARS servers come up automatically without the user
# having to manually run a startup script. Already-running servers are left untouched
# by the idempotent guard in aiteamforge-start.sh.
#
# Why: lcars-watch only fires on file changes; lcars-health skips teams with no tmux
# session after reboot (Defect C, partially fixed in XACA-0626). This agent provides
# defence-in-depth: fires immediately at login to cover the reboot case.
#
# XACA-0578 SIBLING-DRIFT NOTE: this installer is one of five coupled sites for
# com.aiteamforge.lcars-runatload. All five must move together:
#   (a) this function  — install side
#   (b) uninstall_lcars_runatload_launchagent below  — uninstall side
#   (c) share/templates/auto-upgrade/lcars-runatload.template.plist  — template
#   (d) aiteamforge-upgrade.sh::update_launchagents agents array  — upgrade re-render
#   (e) aiteamforge-migrate.sh::update_launchagents agents array  — migrate re-render
# Adding a new {{PLACEHOLDER}} to the template also requires updating
# _render_launchagent_template in aiteamforge-upgrade.sh (XACA-0571-014 note).
install_lcars_runatload_launchagent() {
    local plist_template="$INSTALL_ROOT/share/templates/auto-upgrade/lcars-runatload.template.plist"
    local plist_dest="$HOME/Library/LaunchAgents/com.aiteamforge.lcars-runatload.plist"

    if [ ! -f "$plist_template" ]; then
        warning "LCARS runatload LaunchAgent template not found (skipping)"
        return 0
    fi

    # Resolve the aiteamforge binary path from Homebrew prefix
    local brew_prefix
    if command -v brew &>/dev/null; then
        brew_prefix="$(brew --prefix)"
    else
        brew_prefix="/opt/homebrew"
    fi
    local aiteamforge_bin="${brew_prefix}/bin/aiteamforge"

    info "Installing LCARS runatload LaunchAgent (starts LCARS on login/reboot)..."

    mkdir -p "$HOME/Library/LaunchAgents"
    mkdir -p "$AITEAMFORGE_DIR/logs"

    sed \
        -e "s|{{AITEAMFORGE_BIN}}|${aiteamforge_bin}|g" \
        -e "s|{{LOG_DIR}}|${AITEAMFORGE_DIR}/logs|g" \
        -e "s|{{HOME_DIR}}|${HOME}|g" \
        -e "s|{{AITEAMFORGE_DIR}}|${AITEAMFORGE_DIR}|g" \
        "$plist_template" > "$plist_dest"

    _aitf_launchctl unload "$plist_dest" 2>/dev/null || true

    # XACA-0651-009 load-verify pattern (aligned with the sibling LaunchAgent
    # installers): verify registration via `launchctl list` rather than trust the
    # legacy `launchctl load` exit code, which returns 0 even when the job is
    # rejected. A one-shot RunAtLoad agent stays REGISTERED in the domain after
    # its run completes (KeepAlive=false governs restart, not registration), so
    # `launchctl list` still reports it here.
    _aitf_launchctl load "$plist_dest" 2>/dev/null || true
    if launchctl list 2>/dev/null | grep -q "com.aiteamforge.lcars-runatload"; then
        success "LCARS runatload LaunchAgent installed — LCARS will start automatically on login/reboot"
    else
        warning "LCARS runatload LaunchAgent installed but not loaded — activate with: launchctl load ${plist_dest}"
    fi
}

# Uninstall RunAtLoad LCARS LaunchAgent
uninstall_lcars_runatload_launchagent() {
    local plist_file="$HOME/Library/LaunchAgents/com.aiteamforge.lcars-runatload.plist"

    if [ -f "$plist_file" ]; then
        info "Unloading LCARS runatload LaunchAgent"
        _aitf_launchctl unload "$plist_file" 2>/dev/null || true
        rm -f "$plist_file"
        success "Removed LCARS runatload LaunchAgent"
    fi
}

# Install Cellar WatchPaths LaunchAgent — triggers upgrade on Homebrew Cellar changes (XACA-0578)
#
# Creates a passive launchd watcher on $(brew --prefix)/Cellar/aiteamforge. When
# Homebrew upgrades the formula (creating a new versioned subdir in the Cellar
# parent directory), launchd fires cellar-watch-trigger.sh which chains
# `aiteamforge upgrade --non-interactive` (ThrottleInterval=60s debounces the
# uninstall+reinstall double-fire scenario).
#
# WHY THE CELLAR DIR, NOT THE OPT SYMLINK: watching the opt symlink is unreliable
# because launchd holds a kernel event descriptor on the original inode — when
# brew retargets the symlink, the watched inode no longer backs the name. The
# Cellar parent directory is mutated in-place (new versioned subdir created/removed),
# so WatchPaths fires reliably.
#
# This is intentionally NOT a persistent daemon (no KeepAlive, no RunAtLoad).
#
# XACA-0578 SIBLING-DRIFT NOTE: this installer uses inline sed for first-time
# render. A SECOND renderer lives at libexec/commands/aiteamforge-upgrade.sh
# (_render_launchagent_template) which re-renders the SAME template on every
# `aiteamforge upgrade`. Both must understand the SAME placeholder vocabulary
# ({{CELLAR_WATCH_TRIGGER}}, {{BREW_CELLAR_DIR}}, {{LOG_DIR}}, {{HOME_DIR}},
# {{AITEAMFORGE_DIR}}) — adding a placeholder here requires updating the
# upgrade-side renderer too, otherwise upgraded plists ship with unresolved
# {{...}} tokens.
install_cellar_watch_launchagent() {
    local plist_template="$INSTALL_ROOT/share/templates/auto-upgrade/cellar-watch-launchagent.template.plist"
    local plist_dest="$HOME/Library/LaunchAgents/com.aiteamforge.cellar-watch.plist"
    local script_src="$INSTALL_ROOT/share/scripts/cellar-watch-trigger.sh"
    local script_dest="$AITEAMFORGE_DIR/scripts/cellar-watch-trigger.sh"

    # Copy the trigger script into place
    if [ ! -f "$script_src" ]; then
        warning "cellar-watch-trigger.sh not found at $script_src (skipping cellar-watch LaunchAgent)"
        return 0
    fi

    if [ ! -f "$plist_template" ]; then
        warning "Cellar watch LaunchAgent template not found (skipping)"
        return 0
    fi

    # Resolve the Homebrew prefix for the Cellar path
    local brew_prefix
    if command -v brew &>/dev/null; then
        brew_prefix="$(brew --prefix)"
    else
        brew_prefix="/opt/homebrew"
    fi

    info "Installing com.aiteamforge.cellar-watch LaunchAgent..."

    mkdir -p "$AITEAMFORGE_DIR/scripts"
    mkdir -p "$AITEAMFORGE_DIR/logs"
    mkdir -p "$HOME/Library/LaunchAgents"

    cp "$script_src" "$script_dest"
    chmod +x "$script_dest"

    sed \
        -e "s|{{CELLAR_WATCH_TRIGGER}}|${script_dest}|g" \
        -e "s|{{BREW_CELLAR_DIR}}|${brew_prefix}/Cellar/aiteamforge|g" \
        -e "s|{{LOG_DIR}}|${AITEAMFORGE_DIR}/logs|g" \
        -e "s|{{HOME_DIR}}|${HOME}|g" \
        -e "s|{{AITEAMFORGE_DIR}}|${AITEAMFORGE_DIR}|g" \
        "$plist_template" > "$plist_dest"

    _aitf_launchctl unload "$plist_dest" 2>/dev/null || true

    # XACA-0651-009 load-verify pattern (aligned with the sibling LaunchAgent
    # installers): verify registration via `launchctl list` rather than trust the
    # legacy `launchctl load` exit code, which returns 0 even when the job is
    # rejected.
    _aitf_launchctl load "$plist_dest" 2>/dev/null || true
    if launchctl list 2>/dev/null | grep -q "com.aiteamforge.cellar-watch"; then
        success "Cellar watch LaunchAgent installed — will auto-upgrade on brew upgrade (XACA-0578)"
        info "Trigger: $script_dest"
        info "Watches: ${brew_prefix}/Cellar/aiteamforge"
    else
        warning "Cellar watch LaunchAgent installed but not loaded — activate with: launchctl load ${plist_dest}"
    fi
}

# Uninstall Cellar WatchPaths LaunchAgent
uninstall_cellar_watch_launchagent() {
    local plist_file="$HOME/Library/LaunchAgents/com.aiteamforge.cellar-watch.plist"

    if [ -f "$plist_file" ]; then
        info "Unloading cellar watch LaunchAgent"
        _aitf_launchctl unload "$plist_file" 2>/dev/null || true
        rm -f "$plist_file"
        success "Removed cellar watch LaunchAgent"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Change Request (CR) config + credentials helpers (XACA-0470)
#
# Two files in ~/.config/aiteamforge/ drive the per-team CR workflow:
#
#   cr-config.json              (mode 644, NON-secret) — persisted per-team opt-in
#       record. Lives in ~/.config so `aiteamforge upgrade` never touches it; the
#       "prompted" flag suppresses re-nagging once the user has answered.
#         { "version":1, "prompted":true, "teams": {"academy":false,"mainevent":true} }
#
#   confluence-credentials.json (mode 600, SECRET) — shared Atlassian creds with
#       one entry per CR-enabled team. The poller daemon reads this; a team's
#       presence here is what actually arms its LaunchAgent.
#         { "teams": {"mainevent": {"site":..,"email":..,"api_token":..,"space_key":..}},
#           "default": "mainevent" }
#
# cr-config.json is the authority for which teams are ENABLED (drives plist
# reconcile + migration); confluence-credentials.json supplies the secrets a
# plist needs before it can be armed.
# ─────────────────────────────────────────────────────────────────────────────

cr_config_file()      { echo "$HOME/.config/aiteamforge/cr-config.json"; }
cr_credentials_file() { echo "$HOME/.config/aiteamforge/confluence-credentials.json"; }

# Is this a context where we may prompt? FALSE under --non-interactive / CI /
# auto-upgrade so migration never blocks an unattended `aiteamforge upgrade`.
_cr_interactive() {
    [ -t 0 ] || return 1
    [ "${AITEAMFORGE_NONINTERACTIVE:-}" = "1" ] && return 1
    [ "${CI:-}" = "true" ] && return 1
    [ "${KB_CI:-}" = "1" ] && return 1
    return 0
}

# Has the CR opt-in prompt already been shown on this install?
cr_already_prompted() {
    local cfg; cfg="$(cr_config_file)"
    [ -f "$cfg" ] || return 1
    command -v jq &>/dev/null || return 1
    [ "$(jq -r '.prompted // false' "$cfg" 2>/dev/null)" = "true" ]
}

# Write/refresh cr-config.json. Args: <enabled_csv> <all_selected_csv>
# Records every selected team true/false (merging with any prior record so a
# subset install never wipes other teams' flags) and marks prompted=true.
write_cr_config() {
    local enabled_csv="$1" all_csv="$2"
    local cfg; cfg="$(cr_config_file)"
    if ! command -v jq &>/dev/null; then
        warning "jq required to persist CR config (skipping)"; return 0
    fi
    mkdir -p "$(dirname "$cfg")"

    local teams_obj="{}"
    [ -f "$cfg" ] && teams_obj="$(jq -c '.teams // {}' "$cfg" 2>/dev/null || echo '{}')"

    local t val
    for t in $all_csv; do
        [ -z "$t" ] && continue
        val="false"
        case " $enabled_csv " in *" $t "*) val="true";; esac
        teams_obj="$(jq -c --arg k "$t" --argjson v "$val" '. + {($k): $v}' <<<"$teams_obj")"
    done

    # Non-secret, but write under a fixed umask for mode-symmetry with the
    # credentials writer (XACA-0470 review follow-up #2).
    ( umask 022; jq -n --argjson teams "$teams_obj" '{version:1, prompted:true, teams:$teams}' > "$cfg" )
    chmod 644 "$cfg"
    info "Recorded per-team CR opt-in → $cfg"
}

# Write/refresh confluence-credentials.json (mode 600, merge-safe).
# Args: <enabled_csv> <email> <token> <site> <space>
# Only the opted-in teams are written; existing entries for other teams are
# preserved so a partial re-run never drops working credentials.
write_confluence_credentials() {
    local enabled_csv="$1" email="$2" token="$3" site="$4" space="$5"
    local creds; creds="$(cr_credentials_file)"
    if ! command -v jq &>/dev/null; then
        warning "jq required to write Confluence credentials (skipping)"; return 1
    fi
    [ -n "$enabled_csv" ] || return 0
    mkdir -p "$(dirname "$creds")"

    local teams_obj="{}" default_team=""
    if [ -f "$creds" ]; then
        teams_obj="$(jq -c '.teams // {}' "$creds" 2>/dev/null || echo '{}')"
        default_team="$(jq -r '.default // empty' "$creds" 2>/dev/null || true)"
    fi

    local t
    for t in $enabled_csv; do
        [ -z "$t" ] && continue
        teams_obj="$(jq -c --arg k "$t" --arg site "$site" --arg email "$email" \
            --arg token "$token" --arg space "$space" \
            '. + {($k): {site:$site, email:$email, api_token:$token, space_key:$space}}' <<<"$teams_obj")"
        [ -z "$default_team" ] && default_team="$t"
    done

    # Lock the destination to 600 BEFORE the secret lands. `umask 077` only
    # protects a NEWLY-created file; a redirect into a pre-existing looser-mode
    # file would otherwise leave the secret group/other-readable until the
    # trailing chmod. So: create-if-absent under umask 077, tighten any existing
    # file to 600, THEN write (the `>` redirect preserves the file's 600 mode).
    # XACA-0470 review follow-up (#1).
    ( umask 077; : >> "$creds" ) 2>/dev/null || true
    chmod 600 "$creds" 2>/dev/null || true
    jq -n --argjson teams "$teams_obj" --arg def "$default_team" \
        '{teams:$teams, default:$def}' > "$creds"
    chmod 600 "$creds"
    success "Wrote Confluence credentials (mode 600) for: $enabled_csv"
}

# Interactively capture shared Atlassian credentials and write them for the
# given CR-enabled teams. Args: <enabled_csv>
_cr_prompt_credentials_and_write() {
    local enabled="$1"
    local email token site space
    echo ""
    info "Atlassian API credentials (shared across CR-enabled teams)"
    info "Create an API token: https://id.atlassian.com/manage-profile/security/api-tokens"
    printf "  Atlassian account email: "; read -r email
    printf "  Atlassian API token (hidden): "; read -rs token; echo ""
    printf "  Confluence site [mainevent.atlassian.net]: "; read -r site
    site="${site:-mainevent.atlassian.net}"
    printf "  Confluence space key [DPD2]: "; read -r space
    space="${space:-DPD2}"
    if [ -z "$email" ] || [ -z "$token" ]; then
        warning "Email and API token are both required — skipping credential write."
        warning "Re-run 'aiteamforge upgrade' interactively to finish CR setup."
        return 1
    fi
    write_confluence_credentials "$enabled" "$email" "$token" "$site" "$space"
}

# Migration (XACA-0470, decision (c) prompt-at-upgrade): installs that predate
# cr-config.json get one populated without surprising the user:
#   • creds file already has teams → infer those as enabled (the user opted in by
#     authoring credentials); write cr-config silently. Preserves prior behavior.
#   • no creds, interactive TTY    → prompt per configured team; capture shared
#     credentials if any team opts in.
#   • no creds, non-interactive    → do nothing (preserve the historical skip);
#     leave cr-config absent so a later interactive run can prompt. Never blocks
#     an unattended auto-upgrade.
maybe_migrate_cr_config() {
    cr_already_prompted && return 0
    command -v jq &>/dev/null || return 0

    local creds; creds="$(cr_credentials_file)"

    # Case 1: infer from existing credentials.
    if [ -f "$creds" ]; then
        local existing_teams
        existing_teams="$(jq -r '.teams | keys[]' "$creds" 2>/dev/null | tr '\n' ' ' || true)"
        existing_teams="$(echo "$existing_teams" | xargs 2>/dev/null || true)"
        if [ -n "$existing_teams" ]; then
            info "Migrating CR config from existing credentials (teams: $existing_teams)"
            write_cr_config "$existing_teams" "$existing_teams"
            return 0
        fi
    fi

    # Determine configured teams from the installer config.
    local configured_teams=""
    if [ -f "$AITEAMFORGE_DIR/.aiteamforge-config" ]; then
        configured_teams="$(jq -r '.teams[]' "$AITEAMFORGE_DIR/.aiteamforge-config" 2>/dev/null | tr '\n' ' ' || true)"
        configured_teams="$(echo "$configured_teams" | xargs 2>/dev/null || true)"
    fi
    [ -n "$configured_teams" ] || return 0

    # Case 3: non-interactive — never prompt, never block.
    if ! _cr_interactive; then
        info "Change Request workflow not configured (non-interactive). Run 'aiteamforge upgrade' interactively to enable per-team CR tracking."
        return 0
    fi

    # Case 2: interactive prompt-at-upgrade.
    header "Change Request Workflow Setup"
    info "New: enable Confluence + IT Connect CR tracking per team. Default is disabled."
    local enabled="" t
    for t in $configured_teams; do
        [ -z "$t" ] && continue
        if prompt_yes_no "Enable Change Request workflow for team '$t'?" "n"; then
            enabled="$enabled $t"
        fi
    done
    enabled="$(echo "$enabled" | xargs 2>/dev/null || true)"
    write_cr_config "$enabled" "$configured_teams"
    if [ -n "$enabled" ]; then
        _cr_prompt_credentials_and_write "$enabled"
    fi
}

# Reconcile: unload+remove CR poller plists for teams that are NOT CR-enabled in
# cr-config.json (disabled, or never opted in). Stops idle daemons from polluting
# launchd — the core complaint behind XACA-0470.
_cr_reconcile_disabled_plists() {
    local launch_agents_dir="$HOME/Library/LaunchAgents"
    local cfg_file; cfg_file="$(cr_config_file)"
    shopt -s nullglob
    local f base team enabled
    for f in "$launch_agents_dir"/com.aiteamforge.cr-confluence-poller.*.plist; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        team="${base#com.aiteamforge.cr-confluence-poller.}"
        team="${team%.plist}"
        [ -z "$team" ] && continue
        enabled="false"
        if [ -f "$cfg_file" ]; then
            enabled="$(jq -r --arg t "$team" '.teams[$t] // false' "$cfg_file" 2>/dev/null || echo false)"
        fi
        if [ "$enabled" != "true" ]; then
            info "Removing CR poller LaunchAgent for non-enabled team '$team'"
            _aitf_launchctl unload "$f" 2>/dev/null || true
            rm -f "$f"
        fi
    done
    shopt -u nullglob
}

# Install CR Confluence Poller LaunchAgents — one per team (XACA-0350)
#
# Scans cr-drafted CRs every 10 min per team; detects appended CR-Proper links
# on Confluence request pages; writes cr_proper_url and transitions
# cr-drafted → cr-submitted.  Isolating one LaunchAgent per team means a bad
# team config only wedges that team's poller; others keep running.
#
# Per-team plists:  ~/Library/LaunchAgents/com.aiteamforge.cr-confluence-poller.<team>.plist
# Per-team logs:    ~/Library/Logs/aiteamforge/cr-poller/<team>.{out,err}.log
#
# Credentials are NOT auto-created — user must populate:
#   ~/.config/aiteamforge/confluence-credentials.json
# If absent or empty, installer logs an info message and skips plist installation.
# The daemon itself exits cleanly with a warning if the file is absent at runtime.
install_cr_confluence_poller_launchagent() {
    local plist_template="$INSTALL_ROOT/share/templates/kanban/cr-confluence-poller-plist.template"
    local poller_src="$INSTALL_ROOT/share/scripts/cr-confluence-poller.py"
    local poller_dest="$AITEAMFORGE_DIR/scripts/cr-confluence-poller.py"
    local creds_file="$HOME/.config/aiteamforge/confluence-credentials.json"
    local launch_agents_dir="$HOME/Library/LaunchAgents"
    local log_dir="$HOME/Library/Logs/aiteamforge/cr-poller"

    # Install the poller script first (non-fatal if missing)
    if [ -f "$poller_src" ]; then
        mkdir -p "$AITEAMFORGE_DIR/scripts"
        cp "$poller_src" "$poller_dest"
        chmod +x "$poller_dest"
        info "Installed: cr-confluence-poller.py"
    else
        warning "cr-confluence-poller.py not found at $poller_src (skipping LaunchAgent)"
        return 0
    fi

    if [ ! -f "$plist_template" ]; then
        warning "CR Confluence Poller LaunchAgent template not found (skipping)"
        return 0
    fi

    mkdir -p "$launch_agents_dir"
    mkdir -p "$log_dir"

    # ── Migration: remove legacy global plist (XACA-0350-004) ─────────────────
    local legacy_plist="$launch_agents_dir/com.aiteamforge.cr-confluence-poller.plist"
    if [ -f "$legacy_plist" ]; then
        info "Migrating: unloading legacy global CR Confluence Poller LaunchAgent"
        _aitf_launchctl unload "$legacy_plist" 2>/dev/null || true
        rm -f "$legacy_plist"
        info "Removed legacy plist: com.aiteamforge.cr-confluence-poller.plist"
    fi

    # jq is required to parse cr-config / credentials; surface a clear error
    # rather than silently degrading (XACA-0350-016).
    if ! command -v jq &>/dev/null; then
        warning "jq is required for per-team CR Confluence Poller install — install jq and re-run."
        return 0
    fi

    # ── XACA-0470: per-team opt-in is the authority ───────────────────────────
    # Ensure a cr-config.json exists (migrates pre-flag installs; prompt-at-upgrade
    # when interactive). cr-config records which teams are CR-ENABLED; the
    # credentials file supplies the secrets a plist needs before it is armed.
    maybe_migrate_cr_config

    # Tear down any plists for teams that are NOT CR-enabled — the central fix
    # for "idle daemons polluting launchd" (XACA-0470).
    _cr_reconcile_disabled_plists

    local cfg_file; cfg_file="$(cr_config_file)"
    local enabled_teams=""
    if [ -f "$cfg_file" ]; then
        enabled_teams="$(jq -r '.teams | to_entries[] | select(.value==true) | .key' "$cfg_file" 2>/dev/null | tr '\n' ' ' || true)"
        enabled_teams="$(echo "$enabled_teams" | xargs 2>/dev/null || true)"
    fi
    if [ -z "$enabled_teams" ]; then
        info "No teams have Change Request workflow enabled — skipping CR poller LaunchAgents."
        return 0
    fi

    if [ ! -f "$creds_file" ]; then
        info "CR workflow enabled but no credentials at $creds_file — skipping LaunchAgent."
        info "Run 'aiteamforge upgrade' interactively to supply Atlassian credentials."
        return 0
    fi

    # Find python3 path once (shared across all team plists)
    local python3_path
    python3_path="$(command -v python3 2>/dev/null || echo "/usr/bin/python3")"

    info "Installing per-team CR Confluence Poller LaunchAgents"

    # ── Render and load one plist per ENABLED team that has credentials ───────
    local team plist_dest
    for team in $enabled_teams; do
        [ -z "$team" ] && continue
        # Allow only [a-zA-Z0-9_-] in team names — the value flows into a sed
        # replacement and a launchctl Label, so a JSON key with pipes/slashes
        # could break the plist render or produce an invalid LaunchAgent label
        # (XACA-0350-014).
        if [[ ! "$team" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            warning "Skipping team '$team': name must match [a-zA-Z0-9_-]+ for LaunchAgent label."
            continue
        fi
        # An enabled team without a credentials entry cannot run — skip rather
        # than arm a daemon that will only warn-and-exit (XACA-0470).
        if ! jq -e --arg t "$team" '.teams[$t]' "$creds_file" >/dev/null 2>&1; then
            warning "Team '$team' is CR-enabled but has no credentials entry — skipping its LaunchAgent."
            continue
        fi
        plist_dest="$launch_agents_dir/com.aiteamforge.cr-confluence-poller.${team}.plist"

        sed -e "s|{{USER_HOME}}|$HOME|g" \
            -e "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g" \
            -e "s|{{PYTHON3_PATH}}|$python3_path|g" \
            -e "s|{{TEAM_NAME}}|$team|g" \
            "$plist_template" > "$plist_dest"

        _aitf_launchctl unload "$plist_dest" 2>/dev/null || true

        # XACA-0651-009 load-verify pattern (aligned with the sibling LaunchAgent
        # installers): verify registration via `launchctl list` rather than trust the
        # legacy `launchctl load` exit code, which returns 0 even when the job is
        # rejected.
        _aitf_launchctl load "$plist_dest" 2>/dev/null || true
        if launchctl list 2>/dev/null | grep -q "com.aiteamforge.cr-confluence-poller.${team}"; then
            success "Loaded CR Confluence Poller LaunchAgent: $team"
        else
            warning "CR Confluence Poller LaunchAgent installed but not loaded for team '$team' — activate with: launchctl load ${plist_dest}"
        fi
    done

    info "Per-team pollers scan cr-drafted CRs every 10 minutes"
    info "Logs: $log_dir/<team>.{out,err}.log"
}

# Uninstall CR Confluence Poller LaunchAgents — glob-removes all per-team plists
# and the legacy global plist if it still exists (XACA-0350-005).
#
# Note: per-team logs at ~/Library/Logs/aiteamforge/cr-poller/<team>.{out,err}.log
# are intentionally preserved on uninstall (matches lcars-health convention).
# Operators can inspect prior poller output after uninstall; remove the log
# directory manually if desired (XACA-0350-015).
uninstall_cr_confluence_poller_launchagent() {
    local launch_agents_dir="$HOME/Library/LaunchAgents"
    local found_any=0

    # Use nullglob-safe loop: test -e guards against no-match expansion in bash
    shopt -s nullglob
    local plist_files=("$launch_agents_dir"/com.aiteamforge.cr-confluence-poller*.plist)
    shopt -u nullglob

    for plist_file in "${plist_files[@]}"; do
        [ -e "$plist_file" ] || continue
        info "Unloading: $(basename "$plist_file")"
        _aitf_launchctl unload "$plist_file" 2>/dev/null || true
        rm -f "$plist_file"
        found_any=1
    done

    if [ "$found_any" -eq 1 ]; then
        success "Removed CR Confluence Poller LaunchAgent(s)"
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

# Install auto-upgrade LaunchAgent (XACA-0571)
#
# Installs a daily LaunchAgent that runs `brew upgrade aiteamforge` at 03:15
# local time, with version-pin support and macOS operator notifications.
#
# Script installed to: $AITEAMFORGE_DIR/scripts/auto-upgrade.sh
# Plist:               ~/Library/LaunchAgents/com.aiteamforge.auto-upgrade.plist
# Log:                 $AITEAMFORGE_DIR/logs/auto-upgrade.log
#
# Version-pin:  echo "v0.12.3" > ~/.aiteamforge/version-pin
# Quiet mode:   echo "AITEAMFORGE_AUTO_UPGRADE_QUIET=1" > ~/.aiteamforge/auto-upgrade.env
#
# XACA-0571-014 SIBLING-DRIFT NOTE: this installer uses inline sed for first-time
# render. A SECOND renderer lives at libexec/commands/aiteamforge-upgrade.sh
# (_render_launchagent_template) which re-renders the SAME template on every
# `aiteamforge upgrade`. Both must understand the SAME placeholder vocabulary
# ({{AUTO_UPGRADE_SCRIPT}}, {{LOG_DIR}}, {{AITEAMFORGE_DIR}}, {{HOME_DIR}}) —
# adding a placeholder here requires updating the upgrade-side renderer too,
# otherwise upgraded plists ship with unresolved {{...}} tokens.
install_auto_upgrade_launchagent() {
    local plist_template="$INSTALL_ROOT/share/templates/auto-upgrade/auto-upgrade-launchagent.template.plist"
    local plist_dest="$HOME/Library/LaunchAgents/com.aiteamforge.auto-upgrade.plist"
    local script_src="$INSTALL_ROOT/share/scripts/auto-upgrade.sh"
    local script_dest="$AITEAMFORGE_DIR/scripts/auto-upgrade.sh"

    # Copy the upgrade script into place
    if [ ! -f "$script_src" ]; then
        warning "auto-upgrade.sh not found at $script_src (skipping auto-upgrade LaunchAgent)"
        return 0
    fi

    if [ ! -f "$plist_template" ]; then
        warning "auto-upgrade LaunchAgent template not found (skipping)"
        return 0
    fi

    info "Installing auto-upgrade LaunchAgent..."

    mkdir -p "$AITEAMFORGE_DIR/scripts"
    mkdir -p "$AITEAMFORGE_DIR/logs"
    mkdir -p "$HOME/Library/LaunchAgents"

    cp "$script_src" "$script_dest"
    chmod +x "$script_dest"

    sed \
        -e "s|{{AUTO_UPGRADE_SCRIPT}}|$script_dest|g" \
        -e "s|{{LOG_DIR}}|$AITEAMFORGE_DIR/logs|g" \
        -e "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g" \
        -e "s|{{HOME_DIR}}|$HOME|g" \
        "$plist_template" > "$plist_dest"

    _aitf_launchctl unload "$plist_dest" 2>/dev/null || true

    # XACA-0651-009 load-verify pattern (aligned with the sibling LaunchAgent
    # installers): verify registration via `launchctl list` rather than trust the
    # legacy `launchctl load` exit code, which returns 0 even when the job is
    # rejected.
    _aitf_launchctl load "$plist_dest" 2>/dev/null || true
    if launchctl list 2>/dev/null | grep -q "com.aiteamforge.auto-upgrade"; then
        success "Auto-upgrade LaunchAgent installed (daily at 03:15)"
        info "Script:  $script_dest"
        info "Log:     $AITEAMFORGE_DIR/logs/auto-upgrade.log"
        info "Pin:     echo \"v0.12.3\" > $AITEAMFORGE_DIR/version-pin"
    else
        warning "Auto-upgrade LaunchAgent installed but not loaded — activate with: launchctl load ${plist_dest}"
    fi
}

# Uninstall auto-upgrade LaunchAgent
uninstall_auto_upgrade_launchagent() {
    local plist_file="$HOME/Library/LaunchAgents/com.aiteamforge.auto-upgrade.plist"

    if [ -f "$plist_file" ]; then
        info "Unloading auto-upgrade LaunchAgent..."
        _aitf_launchctl unload "$plist_file" 2>/dev/null || true
        rm -f "$plist_file"
        success "Removed auto-upgrade LaunchAgent"
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# Main Installation Function
#──────────────────────────────────────────────────────────────────────────────

install_kanban_system() {
    header "Installing LCARS Kanban System"

    # Get selected teams from wizard env var, config file, or default
    local teams=()
    if [ -n "${SELECTED_TEAMS_STR:-}" ]; then
        # Teams passed from setup wizard (space-separated string)
        read -ra teams <<< "$SELECTED_TEAMS_STR"
    elif [ -f "$AITEAMFORGE_DIR/.aiteamforge-config" ]; then
        # Read teams from JSON config file
        if command -v jq &>/dev/null; then
            while IFS= read -r team; do
                teams+=("$team")
            done < <(jq -r '.teams[]' "$AITEAMFORGE_DIR/.aiteamforge-config" 2>/dev/null)
        fi
    fi

    # XACA-0559: Shared components (helpers, hooks, LCARS UI, port mgmt, backup,
    # LaunchAgents) are DECOUPLED from team presence. They must refresh whenever
    # install_kanban_system is invoked — including on an upgrade where teams may
    # resolve empty — otherwise an upgrade leaves stale hooks/UI/helpers behind
    # (the "gate stayed 0" bug). Per-team board init is the ONLY step gated on
    # teams being non-empty; init_kanban_board already skips existing boards, so
    # board preservation is unaffected.
    if [ ${#teams[@]} -eq 0 ]; then
        info "No teams specified — refreshing shared kanban components only"
    else
        info "Setting up kanban boards for teams: ${teams[*]}"
    fi

    # Install core kanban components (non-fatal if templates missing)
    install_kanban_helpers
    install_board_check_scripts
    install_lcars_health_check_script
    install_worktree_personas_script
    install_kb_port_reconcile_script
    install_kanban_hooks

    # Initialize kanban boards for each team (skipped when no teams resolved —
    # shared components above still refresh). Guarded for bash 3.2: iterating an
    # empty array under `set -u` throws "unbound variable" on macOS /bin/bash,
    # and the empty-teams upgrade path now reaches this loop (XACA-0559).
    if [ ${#teams[@]} -gt 0 ]; then
        for team in "${teams[@]}"; do
            init_kanban_board "$team"
        done
    fi

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

    # XACA-0470: persist the per-team CR opt-in + write Confluence credentials from
    # the setup wizard's selections (if it passed them). Must run BEFORE the poller
    # LaunchAgent install so it sees fresh config. The env vars are exported by
    # bin/aiteamforge-setup.sh; they are absent on a plain `aiteamforge upgrade`,
    # where install_cr_confluence_poller_launchagent's migration path takes over.
    # Gate on CR_WIZARD_RAN (set only when the wizard actually showed the CR
    # prompt) — NOT on CR_ENABLED_TEAMS_STR being set. A hydrated upgrade exports
    # an empty CR_ENABLED_TEAMS_STR without prompting; acting on that would wipe a
    # team's existing CR opt-in. An empty list WITH CR_WIZARD_RAN=1 correctly means
    # "wizard asked, user declined all" → record it (prompted=true) so migration
    # won't nag again.
    if [ "${CR_WIZARD_RAN:-}" = "1" ]; then
        # All CR_* are `:-`-defaulted so a manual `CR_WIZARD_RAN=1` (without the
        # sibling exports) can't abort the installer under `set -u` (review #012).
        write_cr_config "${CR_ENABLED_TEAMS_STR:-}" "${CR_ALL_SELECTED_TEAMS_STR:-${SELECTED_TEAMS_STR:-}}"
        if [ -n "${CR_ENABLED_TEAMS_STR:-}" ] && [ -n "${CR_ATLASSIAN_TOKEN:-}" ]; then
            write_confluence_credentials "${CR_ENABLED_TEAMS_STR:-}" \
                "${CR_ATLASSIAN_EMAIL:-}" "${CR_ATLASSIAN_TOKEN:-}" \
                "${CR_CONFLUENCE_SITE:-mainevent.atlassian.net}" "${CR_SPACE_KEY:-DPD2}"
        fi
    fi

    # Install LaunchAgents if templates exist
    install_backup_launchagent
    install_lcars_health_launchagent
    install_cr_confluence_poller_launchagent
    install_auto_upgrade_launchagent
    install_lcars_watch_launchagent
    install_cellar_watch_launchagent
    install_lcars_runatload_launchagent

    success "LCARS Kanban System installed successfully"

    info ""
    info "Kanban System Ready:"
    if [ ${#teams[@]} -gt 0 ]; then
        info "  • Boards initialized for: ${teams[*]}"
    else
        info "  • Shared components refreshed (no team boards changed)"
    fi
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

    # Unload LaunchAgents
    uninstall_backup_launchagent
    uninstall_cr_confluence_poller_launchagent
    uninstall_cellar_watch_launchagent
    uninstall_auto_upgrade_launchagent
    uninstall_lcars_watch_launchagent
    uninstall_lcars_runatload_launchagent

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
