#!/bin/bash
# LCARS Kanban System Installer
# Sets up kanban boards, LCARS web UI, backup system, and port management

set -euo pipefail

# Source common utilities and shared constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/constants.sh"
# XACA-0734: opt-out sentinel helpers. Each install_<x>_launchagent() below
# CHECKS the sentinel and refuses to install when the user has opted out;
# uninstall_<x>_launchagent() RECORDS an opt-out — but ONLY for a targeted,
# single-agent removal. During the BATCH teardown (uninstall_kanban_system) the
# recording is suppressed via _xaca0734_record_optout_unless_batch, because
# "remove the kanban system" is not a statement about which agents you want on a
# future reinstall. This lets `aiteamforge upgrade` tell "deliberately removed"
# from "never existed on this box" instead of inferring it from disk state.
# Full contract + lifecycle: see lib/launchagents.sh.
source "$SCRIPT_DIR/../lib/launchagents.sh"

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

# XACA-0774: Install remote-tmux-attach.sh to AITEAMFORGE_DIR/scripts/ so freshly
# rendered *-connect.sh scripts (which reference it as
# ${AITEAMFORGE_DIR}/scripts/remote-tmux-attach.sh, a LOCAL client-side path) find
# it on disk. Without this seed a fresh install's connect scripts point at a
# missing file.
# SIBLING-DRIFT NOTE: this install function is paired with:
#   (a) _xaca0673_mandatory_materialize_basenames entry in aiteamforge-upgrade.sh
#       (materialize-when-absent on upgrade — this is a BRAND-NEW file, so the
#       self-maintaining *.sh sweep's default "only refresh if already present"
#       rule would otherwise never lay it down on existing installs). NOT added
#       to _xaca0608_aux_script_map — that map is for files the *.sh/*.py glob
#       does NOT already cover (extensionless, like kb-port-reconcile); this file
#       already has the .sh extension so the self-maintaining sweep in
#       update_runtime_helpers picks it up for refresh once present.
#   (b) no per-file removal entry in aiteamforge-uninstall.sh — that script
#       removes the entire scripts/ directory wholesale (remove_files()'s
#       dirs_to_remove), so kb-port-reconcile and this file are both covered
#       without an individual entry.
# All sites must stay in sync when remote-tmux-attach.sh is renamed or moved.
install_remote_tmux_attach_script() {
    local scripts_src="$INSTALL_ROOT/share/scripts"
    local src="${scripts_src}/remote-tmux-attach.sh"
    local dest="$AITEAMFORGE_DIR/scripts/remote-tmux-attach.sh"

    if [ ! -f "$src" ]; then
        warning "remote-tmux-attach.sh not found at: ${src} (skipping)"
        return 0
    fi

    mkdir -p "$AITEAMFORGE_DIR/scripts"
    info "Installing remote-tmux-attach.sh (remote tmux session attach helper)"
    cp "$src" "$dest"
    chmod +x "$dest"
    success "Installed: $dest"
}

# XACA-0698: Install kb-init-team and kb-init-team-guard.sh to AITEAMFORGE_DIR/scripts/
# so a fresh install with NO team selected still has the provisioner available.
# Without this, install-team.sh (which is team-gated) is the only installer that
# copies these files — leaving a no-team fresh install unable to run kb-init-team
# and breaking the XACA-0653 E2E gate step 3 with "not found in the installed tree".
# SIBLING-DRIFT NOTE: this install function is paired with:
#   (a) _xaca0673_mandatory_materialize_basenames entries in aiteamforge-upgrade.sh
#       (materialize-when-absent on upgrade — these files are newly mandatory, so the
#        upgrade path adds them if missing rather than only refreshing existing copies)
# Both sites must stay in sync when kb-init-team is renamed or moved.
install_kb_init_team_scripts() {
    local scripts_src="$INSTALL_ROOT/share/scripts"
    local guard_src="${scripts_src}/kb-init-team-guard.sh"
    local init_src="${scripts_src}/kb-init-team"
    local guard_dest="$AITEAMFORGE_DIR/scripts/kb-init-team-guard.sh"
    local init_dest="$AITEAMFORGE_DIR/scripts/kb-init-team"

    mkdir -p "$AITEAMFORGE_DIR/scripts"

    if [ -f "$guard_src" ]; then
        info "Installing kb-init-team-guard.sh"
        cp "$guard_src" "$guard_dest"
        chmod +x "$guard_dest"
        success "Installed: $guard_dest"
    else
        warning "kb-init-team-guard.sh not found at: ${guard_src} (skipping)"
    fi

    if [ -f "$init_src" ]; then
        info "Installing kb-init-team (team provisioner)"
        cp "$init_src" "$init_dest"
        chmod +x "$init_dest"
        success "Installed: $init_dest"
    else
        warning "kb-init-team not found at: ${init_src} (skipping)"
    fi
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

    # XACA-0734: this function is called unconditionally by install_kanban_system
    # on EVERY `aiteamforge setup` (including reconfigure), not just a fresh
    # install. Checking the opt-out sentinel here — rather than auto-clearing it —
    # is what makes a hand-recorded opt-out actually stick across unrelated setup
    # re-runs. See the LIFECYCLE note in lib/launchagents.sh for the full story.
    if _xaca0734_is_opted_out "${KANBAN_BACKUP_LABEL}.plist"; then
        info "Skipping backup LaunchAgent — opted out. To reinstall, remove this line from $(_xaca0734_optout_file): ${KANBAN_BACKUP_LABEL}.plist"
        return 0
    fi

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
#
# XACA-0734: records the opt-out so a later `aiteamforge upgrade` does NOT
# re-materialize this mandatory agent. The record happens even when the plist is
# already gone — the intent ("I do not want this agent") is what we persist, not
# the disk state.
#
# ...EXCEPT during a batch teardown, where _xaca0734_record_optout_unless_batch
# suppresses it: uninstall_kanban_system means "remove the kanban system", which
# expresses no preference at all about individual agents on a future reinstall.
# Recording there — and then trying to undo it — is what let a Ctrl-C'd uninstall
# permanently seal a box against auto-upgrade. See uninstall_kanban_system's
# header and lib/launchagents.sh.
uninstall_backup_launchagent() {
    local plist_file="$HOME/Library/LaunchAgents/${KANBAN_BACKUP_LABEL}.plist"

    _xaca0734_record_optout_unless_batch "${KANBAN_BACKUP_LABEL}.plist"

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

    # XACA-0734: see the identical guard in install_backup_launchagent.
    if _xaca0734_is_opted_out "com.aiteamforge.lcars-health.plist"; then
        info "Skipping LCARS health LaunchAgent — opted out. To reinstall, remove this line from $(_xaca0734_optout_file): com.aiteamforge.lcars-health.plist"
        return 0
    fi

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
# XACA-0734: records the opt-out — see uninstall_backup_launchagent.
uninstall_lcars_health_launchagent() {
    local plist_file="$HOME/Library/LaunchAgents/com.aiteamforge.lcars-health.plist"

    _xaca0734_record_optout_unless_batch "com.aiteamforge.lcars-health.plist"

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

    # XACA-0734: see the identical guard in install_backup_launchagent. lcars-watch
    # is in the shared agent map but not mandatory, so this guard is not load-bearing
    # for upgrade's behavior today — kept for correctness-by-construction.
    if _xaca0734_is_opted_out "com.aiteamforge.lcars-watch.plist"; then
        info "Skipping LCARS watch LaunchAgent — opted out. To reinstall, remove this line from $(_xaca0734_optout_file): com.aiteamforge.lcars-watch.plist"
        return 0
    fi

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
# XACA-0734: records the opt-out — see uninstall_backup_launchagent.
uninstall_lcars_watch_launchagent() {
    local plist_file="$HOME/Library/LaunchAgents/com.aiteamforge.lcars-watch.plist"

    _xaca0734_record_optout_unless_batch "com.aiteamforge.lcars-watch.plist"

    if [ -f "$plist_file" ]; then
        info "Unloading LCARS watch LaunchAgent"
        _aitf_launchctl unload "$plist_file" 2>/dev/null || true
        rm -f "$plist_file"
        success "Removed LCARS watch LaunchAgent"
    fi
}

# Uninstall RunAtLoad LCARS LaunchAgent (XACA-0763-005: RETIRED, uninstall-only)
#
# com.aiteamforge.lcars-runatload was retired by XACA-0763-005: XACA-0626
# Defect C already relaxed lcars-health's tmux gate, so com.aiteamforge.lcars-health
# (RunAtLoad=true, 300s interval) now covers the post-reboot cold-start case this
# agent existed for, making it a redundant fourth writer to LCARS lifecycle state.
#
# The install-side function, its template (share/templates/auto-upgrade/
# lcars-runatload.template.plist), and its entries in aiteamforge-upgrade.sh /
# aiteamforge-migrate.sh's update_launchagents agents arrays were all removed —
# NEW installs never get this agent. This uninstall function is intentionally
# KEPT: any machine that installed it before XACA-0763-005 still has the plist
# LOADED in the GUI domain and needs a teardown path. `aiteamforge uninstall`
# still calls this. Machines that only ever run `aiteamforge upgrade` /
# `aiteamforge migrate` (never a full uninstall) are covered separately by
# remove_legacy_lcars_runatload_agent() in libexec/lib/common.sh, wired into
# both of those commands' run sequences — see that function's header comment.
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

    # XACA-0734: see the identical guard in install_backup_launchagent. Like
    # lcars-watch, cellar-watch is in the shared agent map but not mandatory.
    if _xaca0734_is_opted_out "com.aiteamforge.cellar-watch.plist"; then
        info "Skipping cellar watch LaunchAgent — opted out. To reinstall, remove this line from $(_xaca0734_optout_file): com.aiteamforge.cellar-watch.plist"
        return 0
    fi

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
# XACA-0734: records the opt-out — see uninstall_backup_launchagent.
uninstall_cellar_watch_launchagent() {
    local plist_file="$HOME/Library/LaunchAgents/com.aiteamforge.cellar-watch.plist"

    _xaca0734_record_optout_unless_batch "com.aiteamforge.cellar-watch.plist"

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

    # XACA-0734: see the identical guard in install_backup_launchagent. This is
    # the HIGHEST-PRIORITY agent in the mandatory set — it is the one that
    # performs upgrades — so respecting a recorded opt-out here matters most.
    if _xaca0734_is_opted_out "com.aiteamforge.auto-upgrade.plist"; then
        info "Skipping auto-upgrade LaunchAgent — opted out. To reinstall, remove this line from $(_xaca0734_optout_file): com.aiteamforge.auto-upgrade.plist"
        return 0
    fi

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
# XACA-0734: records the opt-out — see uninstall_backup_launchagent. Removing THIS
# agent is the one with teeth: it is the agent that performs upgrades, so a box
# without it can never self-heal. The sentinel is what makes that a deliberate,
# recorded choice rather than an accident that upgrade would silently perpetuate.
uninstall_auto_upgrade_launchagent() {
    local plist_file="$HOME/Library/LaunchAgents/com.aiteamforge.auto-upgrade.plist"

    _xaca0734_record_optout_unless_batch "com.aiteamforge.auto-upgrade.plist"

    if [ -f "$plist_file" ]; then
        info "Unloading auto-upgrade LaunchAgent..."
        _aitf_launchctl unload "$plist_file" 2>/dev/null || true
        rm -f "$plist_file"
        success "Removed auto-upgrade LaunchAgent"
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# Four-tier ~/knowledge/ provisioning + migration (XACA-0743 / schema XACA-0222)
#──────────────────────────────────────────────────────────────────────────────
# Provisions the canonical four-tier knowledge tree (agents/subjects/teams/
# projects + templates) under $KB_KNOWLEDGE_GLOBAL_ROOT, then non-destructively
# migrates any pre-XACA-0222 per-repo `<repo>/kanban/knowledge/` content into the
# project tier. Fully idempotent, copy-not-move, no-overwrite, dry-run-aware,
# and sandbox-safe (honors HOME / KB_KNOWLEDGE_GLOBAL_ROOT overrides).

# Resolve the global knowledge root. Mirrors the template helper
# _kb_knowledge_global_root: ${KB_KNOWLEDGE_GLOBAL_ROOT:-${HOME}/knowledge}.
_knowledge_global_root() {
    echo "${KB_KNOWLEDGE_GLOBAL_ROOT:-${HOME}/knowledge}"
}

# True when running in preview mode. Mirrors aiteamforge-migrate.sh's DRY_RUN
# convention so a `DRY_RUN=true` outer run skips all writes here too.
_knowledge_dry_run() {
    [ "${DRY_RUN:-false}" = "true" ]
}

# Write $2 (content) to file $1 ONLY if absent. Never overwrites existing files.
# Honors dry-run. Returns 0 and prints when a file is (or would be) created;
# returns 1 (no-op) when the file already exists.
_knowledge_seed_file() {
    local target="$1"
    local content="$2"
    if [ -f "$target" ]; then
        return 1
    fi
    if _knowledge_dry_run; then
        info "[dry-run] would seed $target"
        return 0
    fi
    mkdir -p "$(dirname "$target")"
    printf '%s\n' "$content" > "$target"
    success "Seeded: $target"
    return 0
}

# Provision the four-tier knowledge tree + starter INDEX/templates, then migrate
# legacy per-repo knowledge into the project tier. Idempotent.
install_knowledge_tree() {
    local root
    root="$(_knowledge_global_root)"

    info "Provisioning four-tier knowledge tree at $root"

    local created=0
    local tier
    # Tier roots. `agents`, `subjects`, `teams`, `projects` mirror SPEC.md §1.
    for tier in agents subjects teams projects templates; do
        local dir="$root/$tier"
        if [ ! -d "$dir" ]; then
            if _knowledge_dry_run; then
                info "[dry-run] would create $dir/"
            else
                mkdir -p "$dir"
            fi
            created=1
        fi
        # Keep empty tier roots tracked (matches the live ~/knowledge layout,
        # which marks each tier root with a .gitkeep).
        if [ "$tier" != "templates" ]; then
            _knowledge_seed_file "$dir/.gitkeep" "" >/dev/null && created=1
        fi
    done

    # Starter INDEX.md per content tier (never overwrites an existing index).
    # The agent/team/subject tiers share a generic catalog header; the project
    # tier gets a project-flavored header. Seeds at the tier root so a fresh
    # install has a discoverable entry point; per-entity INDEX.md files are
    # created later by kb-knowledge-add as real entries land.
    local _today
    _today="$(date +%Y-%m-%d 2>/dev/null || echo 'YYYY-MM-DD')"

    _knowledge_seed_file "$root/agents/INDEX.md" \
"# Agent Knowledge — Tier Index

**Tier:** agent (\`agents/<persona>/\`)
**Last Updated:** ${_today}

Per-persona learnings live in \`agents/<persona>/\` with entry prefix \`k###\`.
Each persona directory carries its own \`INDEX.md\`. Add entries with:
\`kb-knowledge-add agent <persona> \"<title>\"\`. See SPEC.md §4.1." && created=1

    _knowledge_seed_file "$root/subjects/INDEX.md" \
"# Subject Knowledge — Tier Index

**Tier:** subject (\`subjects/<path>/\`)
**Last Updated:** ${_today}

Cross-cutting domain/technology knowledge lives under \`subjects/<path>/\`
(kebab-case, platform-qualified) with entry prefix \`s###\`. Add entries with:
\`kb-knowledge-add subject <path> \"<title>\"\`. See SPEC.md §4.3." && created=1

    _knowledge_seed_file "$root/teams/INDEX.md" \
"# Team Knowledge — Tier Index

**Tier:** team (\`teams/<team>/\`)
**Last Updated:** ${_today}

Themed agent-bundle shared patterns live under \`teams/<team>/\` with entry
prefix \`t###\`. Add entries with: \`kb-knowledge-add team <team> \"<title>\"\`.
See SPEC.md §4.2." && created=1

    _knowledge_seed_file "$root/projects/INDEX.md" \
"# Project Knowledge — Tier Index

**Tier:** project (\`projects/<repo-slug>/\`)
**Last Updated:** ${_today}

Per-codebase conventions live under \`projects/<repo-slug>/\` with entry prefix
\`p###\`. Each project directory carries its own \`INDEX.md\`. Add entries with:
\`kb-knowledge-add project <repo-slug> \"<title>\"\`. See SPEC.md §4.4." && created=1

    # Minimal starter templates (only if the schema's templates/ is empty).
    _knowledge_seed_file "$root/templates/knowledge_entry_template.md" \
"---
id: <prefix>NNN-kebab-case-title
tier: agent|team|subject|project
date: ${_today}
tags: [tag-one, tag-two, tag-three]
---

# <TITLE>

## Problem

## Solution

## Why this matters" && created=1

    _knowledge_seed_file "$root/templates/index_template.md" \
"# [Agent/Team/Subject] Knowledge Index

**Last Updated:** ${_today}

## Tag Index

| Tag | Entries |
|-----|---------|

## Entries
" && created=1

    _knowledge_seed_file "$root/templates/project_index_template.md" \
"# Project Knowledge — <repo-slug>

**Project:** <repo-slug>
**Last Updated:** ${_today}

## Tag Index

| Tag | Entries |
|-----|---------|

## Entries
" && created=1

    if [ "$created" -eq 0 ]; then
        info "Knowledge tree already provisioned (no changes)"
    fi

    # Non-destructive migration of legacy per-repo knowledge into project tier.
    migrate_legacy_repo_knowledge "$root"

    return 0
}

# Discover pre-XACA-0222 `<repo>/kanban/knowledge/` directories and COPY their
# contents into the project tier ($root/projects/<repo-slug>/). Never moves or
# deletes source content; skips files that already exist at the destination.
# Idempotent and dry-run-aware. Disable entirely with KB_KNOWLEDGE_MIGRATE=0.
migrate_legacy_repo_knowledge() {
    local root="$1"

    if [ "${KB_KNOWLEDGE_MIGRATE:-1}" = "0" ]; then
        info "Legacy knowledge migration disabled (KB_KNOWLEDGE_MIGRATE=0)"
        return 0
    fi

    # Bounded search roots — avoid scanning all of $HOME. Override/extend via
    # KB_KNOWLEDGE_MIGRATE_SEARCH_ROOTS (space-separated absolute paths).
    local search_roots=()
    if [ -n "${KB_KNOWLEDGE_MIGRATE_SEARCH_ROOTS:-}" ]; then
        local _r
        for _r in $KB_KNOWLEDGE_MIGRATE_SEARCH_ROOTS; do
            search_roots+=("$_r")
        done
    else
        search_roots=(
            "$HOME/dev-team"
            "$HOME/Development"
            "$HOME/Projects"
            "/Users/Shared/Development"
        )
    fi

    # XACA-0743 (review #5): guard the bash 3.2 empty-array-under-`set -u` hazard.
    # If KB_KNOWLEDGE_MIGRATE_SEARCH_ROOTS was set but whitespace-only, the split
    # loop above adds nothing and `"${search_roots[@]}"` throws unbound on macOS
    # bash 3.2. Nothing to scan → return cleanly.
    if [ ${#search_roots[@]} -eq 0 ]; then
        info "No knowledge migration search roots resolved — skipping migration"
        return 0
    fi

    # Normalize the global root for the self-containment guard below.
    local _root_real
    _root_real="$(cd "$root" 2>/dev/null && pwd || echo "$root")"

    local found=0
    local migrated_any=0
    local sroot
    # XACA-0743 (review #6): newline list of "slug<TAB>repo_dir" for collision detection.
    local _seen_slugs=""
    for sroot in "${search_roots[@]}"; do
        [ -d "$sroot" ] || continue
        # Pre-0222 layout: <repo>/kanban/knowledge/. Cap depth + prune .git to
        # keep the scan cheap and zero-blast-radius.
        local kdir
        while IFS= read -r kdir; do
            [ -d "$kdir" ] || continue
            found=1

            # Skip anything already inside the global root (prevents recursion
            # when a search root overlaps $KB_KNOWLEDGE_GLOBAL_ROOT).
            local _kdir_real
            _kdir_real="$(cd "$kdir" 2>/dev/null && pwd || echo "$kdir")"
            case "$_kdir_real/" in
                "$_root_real"/*) continue ;;
            esac

            # repo = dirname(dirname(knowledge)); slug = basename(repo).
            local repo_dir slug dest
            repo_dir="$(dirname "$(dirname "$kdir")")"
            slug="$(basename "$repo_dir")"
            dest="$root/projects/$slug"

            # XACA-0743 (review #6): warn on slug collision — two repos sharing a
            # basename map to the same projects/<slug>/, and skip-if-exists would
            # silently omit the second repo's same-named files. Copy-not-move means
            # the source is never lost, but the operator should know the merge
            # happened. Exact field match via awk (no substring false-positives).
            local _prev_repo
            _prev_repo="$(printf '%s' "$_seen_slugs" | awk -F'\t' -v s="$slug" '$1==s {print $2; exit}')"
            if [ -n "$_prev_repo" ] && [ "$_prev_repo" != "$repo_dir" ]; then
                warning "Knowledge migration slug collision: '$slug' already migrated from '$_prev_repo'; projects/$slug/ will merge and same-named files from '$repo_dir' are skipped (sources preserved)"
            fi
            _seen_slugs="${_seen_slugs}${slug}"$'\t'"${repo_dir}"$'\n'

            info "Found legacy knowledge: $kdir → projects/$slug/"

            # Copy every file, preserving relative structure, skip-if-exists.
            local src rel target copied=0 skipped=0
            while IFS= read -r -d '' src; do
                rel="${src#"$kdir"/}"
                target="$dest/$rel"
                if [ -f "$target" ]; then
                    skipped=$((skipped + 1))
                    continue
                fi
                if _knowledge_dry_run; then
                    info "[dry-run] would copy $rel → projects/$slug/$rel"
                    copied=$((copied + 1))
                    continue
                fi
                mkdir -p "$(dirname "$target")"
                cp -p "$src" "$target"
                copied=$((copied + 1))
            done < <(find "$kdir" -type f -print0 2>/dev/null)

            if [ "$copied" -gt 0 ]; then
                migrated_any=1
                success "Migrated $copied file(s) into projects/$slug/ (skipped $skipped existing)"
            else
                info "projects/$slug/ already up to date (skipped $skipped existing)"
            fi
        done < <(find "$sroot" -maxdepth 6 -type d -name knowledge -path '*/kanban/knowledge' -not -path '*/.git/*' 2>/dev/null)
    done

    if [ "$found" -eq 0 ]; then
        info "No legacy per-repo knowledge found to migrate"
    elif [ "$migrated_any" -eq 0 ]; then
        info "Legacy knowledge migration up to date (nothing new to copy)"
    fi

    return 0
}

#──────────────────────────────────────────────────────────────────────────────
# ~/knowledge git-repo provisioning (XACA-0747 / EPIC-0047)
#──────────────────────────────────────────────────────────────────────────────
# install_knowledge_tree() (above) scaffolds an EMPTY four-tier tree. This step
# turns that into a REAL clone of the canonical private knowledge repo, so a
# fresh machine gets actual entries + the frontmatter pre-commit gate — not a
# hollow directory. Runs BEFORE install_knowledge_tree() (see install_kanban_
# system) so the scaffold seeds only the gaps a clone leaves, and the "directory
# exists but has no .git" husk case is the M1Pro pre-XACA-0222 husk, never a
# scaffold we just created.
#
# Four states, decided in this order:
#   1. Already a real clone ($root/.git present) → fetch + ff-only update, keep
#      local work; never re-clone. (Conflict resolution is the sync daemon's job,
#      XACA-0749 — a diverged/dirty tree is left as-is with a warning.)
#   2. Auth not yet granted (remote unreachable) → soft-skip: log and return 0,
#      leaving whatever is on disk untouched. This is what lets XACA-0747 ship
#      and deploy BEFORE the fleet-auth gate (XACA-0750) is unblocked; a later
#      upgrade (post-auth) completes the clone.
#   3. M1Pro husk ($root exists, no .git) → move aside to $root.husk-bak-<ts>
#      (never deleted), then clone onto the clean path.
#   4. Fresh machine ($root absent) → clone.
# Fully idempotent, dry-run-aware, sandbox-safe (honors HOME / KB_KNOWLEDGE_*).

# Canonical private knowledge repo candidates, in resolution priority order.
#
# XACA-0751-014 fix: XACA-0750 provisions a per-machine, REPO-SCOPED ed25519
# deploy key for DoubleNode/knowledge that is reachable ONLY through a dedicated
# SSH host alias — `Host github-knowledge` (HostName github.com, IdentitiesOnly
# yes, its own IdentityFile). Plain `git@github.com` carries no key on a fleet
# box, so the original hard default (github.com) made even a FULLY-authorized
# machine soft-skip (and blame XACA-0750, which had already succeeded).
# Resolution now PROBES the deploy-key alias first, then plain github.com.
#
# An explicit KB_KNOWLEDGE_REPO_URL is the top-priority escape hatch and is used
# verbatim — the two defaults are never probed when it is set (operator retarget
# / sandbox fixtures). Each default is also individually overridable
# (KB_KNOWLEDGE_REPO_URL_ALIAS / _DIRECT) so sandbox tests can point a candidate
# at a local file:// fixture without real SSH.
_knowledge_repo_url_alias() {
    echo "${KB_KNOWLEDGE_REPO_URL_ALIAS:-git@github-knowledge:DoubleNode/knowledge.git}"
}
_knowledge_repo_url_direct() {
    echo "${KB_KNOWLEDGE_REPO_URL_DIRECT:-git@github.com:DoubleNode/knowledge.git}"
}

# Ordered candidate URL list, one per line. An explicit KB_KNOWLEDGE_REPO_URL is
# the SOLE candidate (never overridden, never probed away). Otherwise: the
# github-knowledge deploy-key alias first, then plain github.com.
_knowledge_repo_candidates() {
    if [ -n "${KB_KNOWLEDGE_REPO_URL:-}" ]; then
        echo "$KB_KNOWLEDGE_REPO_URL"
    else
        _knowledge_repo_url_alias
        _knowledge_repo_url_direct
    fi
}

# Back-compat shim: the FIRST candidate URL, UNPROBED. Retained because the
# symbol is exported for the setup wizard; resolution logic uses
# _knowledge_resolve_repo_url instead. Never used to rewrite an existing clone.
_knowledge_repo_url() {
    _knowledge_repo_candidates | head -n 1
}

# Echo the first candidate URL that authenticates non-interactively (return 0),
# or return 1 echoing nothing when none does. Probing reuses the single
# _knowledge_repo_reachable probe below, so each candidate is bounded by that
# probe's ConnectTimeout; at most two short probes (alias + direct) on an
# unauthorized fleet box — safe for the nightly auto-upgrade LaunchAgent. Stops
# at the first success, so a machine holding the deploy key pays exactly ONE
# probe. Returns non-zero (never echoes a URL) when nothing authenticates, which
# is what drives install_knowledge_repo's fail-soft skip.
_knowledge_resolve_repo_url() {
    local cand
    for cand in $(_knowledge_repo_candidates); do
        if _knowledge_repo_reachable "$cand"; then
            echo "$cand"
            return 0
        fi
    done
    return 1
}

# True when $1 is reachable for clone WITHOUT prompting for credentials. Batch/
# non-interactive so an unauthorized machine fails fast instead of hanging on an
# SSH password or HTTPS credential prompt (the XACA-0750 fleet-auth gate).
#
# Host-key policy (XACA-0747 review fold-in): StrictHostKeyChecking=accept-new is
# a deliberate choice, not the weaker `no`/`accept-all`. `accept-new` trusts a
# host on FIRST contact but still REFUSES a subsequently CHANGED key (MITM
# protection after TOFU), and BatchMode makes an unknown/changed host fail
# closed (the reachability check returns non-zero → clone is skipped, never an
# interactive prompt). We intentionally do NOT pin github.com host keys inline:
# GitHub rotates them (e.g. the 2023 RSA-key rotation), and a hardcoded pin would
# silently break every fleet clone the day a key rotates — a worse failure than
# the narrow first-contact TOFU window this closes. Operators wanting zero TOFU
# can pre-seed ~/.ssh/known_hosts out of band; accept-new then no-ops.
# XACA-0751 review hardening: `-c protocol.ext.allow=never` refuses git's `ext::`
# transport, which treats the URL as a shell command to spawn. KB_KNOWLEDGE_REPO_URL
# is owner-controlled today, but this code runs unattended, nightly, as the user via
# the auto-upgrade LaunchAgent — a URL is not a safe place to trust. Scoped to `ext`
# rather than an allow-list so `file://` test fixtures and `ssh`/`https` keep working.
_knowledge_repo_reachable() {
    local url="$1"
    GIT_TERMINAL_PROMPT=0 \
    GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new" \
        git -c protocol.ext.allow=never ls-remote --exit-code "$url" HEAD >/dev/null 2>&1
}

# Wire the repo's frontmatter pre-commit gate after a clone. Delegates to the
# repo's own tracked setup script (canonical authority on how its hooks wire)
# rather than reimplementing dispatcher logic here. Two layers:
#   * setup-global-hooks.sh installs the init.templateDir dispatcher → every
#     FUTURE clone/init on this machine is zero-touch.
#   * `git init` inside the fresh clone retrofits THIS clone now (re-copies the
#     template hooks; harmless to history). If the setup script is absent (older
#     repo revision), fall back to per-clone `core.hooksPath .githooks`.
# Non-fatal throughout — a knowledge clone is still useful without the gate.
# Skip entirely with KB_KNOWLEDGE_SKIP_HOOK_SETUP=1.
_knowledge_wire_hooks() {
    local root="$1"
    if [ "${KB_KNOWLEDGE_SKIP_HOOK_SETUP:-0}" = "1" ]; then
        info "Knowledge hook wiring skipped (KB_KNOWLEDGE_SKIP_HOOK_SETUP=1)"
        return 0
    fi

    local setup="$root/.githooks/setup-global-hooks.sh"
    if _knowledge_dry_run; then
        if [ -x "$setup" ]; then
            info "[dry-run] would run $setup + 'git init $root' to wire zero-touch frontmatter hook"
        else
            info "[dry-run] would set core.hooksPath=.githooks in $root (no setup script)"
        fi
        return 0
    fi

    if [ -x "$setup" ]; then
        # Installs the init.templateDir dispatcher for all future clones.
        if "$setup" >/dev/null 2>&1; then
            success "Installed zero-touch git-hook dispatcher (init.templateDir)"
        else
            warn "setup-global-hooks.sh failed; the frontmatter gate may need manual wiring"
        fi
        # Retrofit the current clone so the gate is live immediately.
        git -C "$root" init >/dev/null 2>&1 || true
    else
        git -C "$root" config core.hooksPath .githooks >/dev/null 2>&1 || true
    fi

    # Verify + log: gate is live if .git/hooks/pre-commit resolved (templateDir
    # path) OR core.hooksPath points at the tracked .githooks/pre-commit.
    local hooks_dir
    hooks_dir="$(git -C "$root" rev-parse --git-path hooks 2>/dev/null)"
    if { [ -n "$hooks_dir" ] && [ -x "$root/$hooks_dir/pre-commit" ]; } \
        || [ -x "$root/.git/hooks/pre-commit" ] \
        || { [ "$(git -C "$root" config --get core.hooksPath 2>/dev/null)" = ".githooks" ] \
             && [ -x "$root/.githooks/pre-commit" ]; }; then
        success "Frontmatter pre-commit gate active in $root"
    else
        warn "Frontmatter pre-commit gate not detected after clone (non-fatal)"
    fi
    return 0
}

install_knowledge_repo() {
    local root url
    root="$(_knowledge_global_root)"

    # State 1 — already a real clone: update in place, never re-clone.
    #
    # Deliberately resolves NO candidate URL and runs NO reachability probe: an
    # existing clone keeps whatever remote it was cloned with (e.g. M3Pro's
    # canonical HTTPS origin) and we NEVER rewrite it. The update rides the
    # clone's own upstream (`@{u}`), so this path is both URL-agnostic and
    # probe-free (fast — no SSH round trips before the fetch).
    if [ -d "$root/.git" ]; then
        info "Knowledge repo already present at $root — updating"
        if _knowledge_dry_run; then
            info "[dry-run] would fetch + fast-forward $root"
            return 0
        fi
        if git -C "$root" fetch --quiet --all 2>/dev/null \
            && git -C "$root" merge --ff-only --quiet '@{u}' 2>/dev/null; then
            success "Knowledge repo updated (fast-forward)"
        else
            # Diverged, dirty, or no upstream — leave for the sync daemon
            # (XACA-0749) rather than risk clobbering local work.
            info "Knowledge repo left as-is (local changes or non-ff; sync daemon owns reconciliation)"
        fi
        _knowledge_wire_hooks "$root"
        return 0
    fi

    # State 2 — auth gate: resolve the first candidate that authenticates without
    # prompting (github-knowledge deploy-key alias first, then plain github.com;
    # an explicit KB_KNOWLEDGE_REPO_URL short-circuits to itself). No candidate
    # reachable → soft-skip: name the URL(s) we tried (never assert a ticket
    # state the installer can't know) and return 0, leaving disk untouched.
    if ! url="$(_knowledge_resolve_repo_url)"; then
        if [ -n "${KB_KNOWLEDGE_REPO_URL:-}" ]; then
            info "Knowledge repo unreachable — KB_KNOWLEDGE_REPO_URL ($KB_KNOWLEDGE_REPO_URL) did not authenticate non-interactively (default candidates not tried) — skipping clone; scaffold retained"
        else
            info "Knowledge repo unreachable — tried the github-knowledge deploy-key alias ($(_knowledge_repo_url_alias)) then $(_knowledge_repo_url_direct); neither authenticated non-interactively — skipping clone; scaffold retained"
        fi
        info "  (authorize this machine's deploy key on the knowledge repo and configure the"
        info "   github-knowledge SSH alias, or set KB_KNOWLEDGE_REPO_URL to a reachable remote;"
        info "   then re-run the installer/upgrade to complete the clone)"
        return 0
    fi

    # State 3 — M1Pro husk: a non-git directory is in the way. Move it aside
    # (never delete) so the clone lands on a clean path.
    if [ -e "$root" ]; then
        # Collision-proof backup path: POSIX `mv <dir> <existing-dir>` NESTS the
        # source inside the target instead of failing, so the destination MUST
        # not already exist. A second-granularity timestamp alone can collide
        # (two husk moves within the same UTC second — reproducible with fast
        # local fixtures) and the `date` fallback is a fixed literal; disambiguate
        # both with a monotonic -N suffix until we find a free name (XACA-0747
        # review/test fold-in). Read-only stat, safe under dry-run.
        local backup ts n
        ts="$(date -u +%Y%m%d%H%M%S 2>/dev/null || echo backup)"
        backup="${root}.husk-bak-${ts}"
        n=1
        while [ -e "$backup" ]; do
            backup="${root}.husk-bak-${ts}-${n}"
            n=$((n + 1))
        done
        if _knowledge_dry_run; then
            info "[dry-run] would move husk $root → $backup, then clone $url"
        else
            if mv "$root" "$backup"; then
                success "Moved pre-existing non-git ~/knowledge husk aside → $backup"
            else
                warn "Could not move husk $root aside — skipping clone to avoid data loss"
                return 0
            fi
        fi
    fi

    # State 3/4 — clone.
    if _knowledge_dry_run; then
        info "[dry-run] would clone $url → $root"
        return 0
    fi
    info "Cloning knowledge repo $url → $root"
    if GIT_TERMINAL_PROMPT=0 \
        GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new" \
        git -c protocol.ext.allow=never clone --quiet "$url" "$root" 2>/dev/null; then
        success "Cloned knowledge repo → $root"
        _knowledge_wire_hooks "$root"
    else
        warn "Knowledge repo clone failed after reachability check — leaving scaffold in place"
    fi
    return 0
}

# Install knowledge-sync LaunchAgent (XACA-0761)
#
# Installs a 30-minute LaunchAgent that keeps a machine's ~/knowledge git
# clone in sync with the fleet (git pull --rebase, then git push if there are
# local commits ahead) via kb-knowledge-sync.sh. Modeled 1:1 on
# install_auto_upgrade_launchagent above.
#
# Script installed to: $AITEAMFORGE_DIR/scripts/kb-knowledge-sync.sh
# Plist:               ~/Library/LaunchAgents/com.aiteamforge.knowledge-sync.plist
# Log:                 $AITEAMFORGE_DIR/logs/knowledge-sync.log
#
# FAIL-SOFT GATE: kb-knowledge-sync.sh itself never exits non-zero (see its
# own "Exit-code policy" doc comment), but this installer ADDITIONALLY gates
# on ~/knowledge actually being a real git clone before installing/loading the
# daemon at all — reusing the EXACT detection idiom install_knowledge_repo
# uses for its "already a real clone" branch: [ -d "$root/.git" ]. A
# scaffold-only or absent ~/knowledge means the fleet-auth gate (XACA-0750)
# has not been granted on this box yet; installing a periodic daemon with
# nothing to sync would just be a pointless 30-minute no-op poll loop. This
# gate is belt-and-suspenders on top of the script's own self-fail-soft
# behavior, not a replacement for it.
#
# XACA-0761 SIBLING-DRIFT NOTE (mirrors XACA-0571-014, but simpler): unlike
# auto-upgrade's install/upgrade split (two independent sed renderers that
# must agree on a placeholder vocabulary), update_knowledge_sync in
# libexec/commands/aiteamforge-upgrade.sh REUSES this exact function (sourced
# in a subshell) instead of re-rendering the template a second way — so there
# is only ONE place that understands {{KNOWLEDGE_SYNC_SCRIPT}} / {{LOG_DIR}} /
# {{AITEAMFORGE_DIR}} / {{HOME_DIR}}.
install_knowledge_sync_launchagent() {
    local root
    root="$(_knowledge_global_root)"

    if [ ! -d "$root/.git" ]; then
        info "Skipping knowledge-sync LaunchAgent — ~/knowledge is not a git clone ($root)"
        return 0
    fi

    local plist_template="$INSTALL_ROOT/share/templates/auto-upgrade/knowledge-sync-launchagent.template.plist"
    local plist_dest="$HOME/Library/LaunchAgents/com.aiteamforge.knowledge-sync.plist"
    local script_src="$INSTALL_ROOT/share/scripts/kb-knowledge-sync.sh"
    local script_dest="$AITEAMFORGE_DIR/scripts/kb-knowledge-sync.sh"

    if [ ! -f "$script_src" ]; then
        warning "kb-knowledge-sync.sh not found at $script_src (skipping knowledge-sync LaunchAgent)"
        return 0
    fi

    if [ ! -f "$plist_template" ]; then
        warning "knowledge-sync LaunchAgent template not found (skipping)"
        return 0
    fi

    info "Installing knowledge-sync LaunchAgent..."

    mkdir -p "$AITEAMFORGE_DIR/scripts"
    mkdir -p "$AITEAMFORGE_DIR/logs"
    mkdir -p "$HOME/Library/LaunchAgents"

    cp "$script_src" "$script_dest"
    chmod +x "$script_dest"

    sed \
        -e "s|{{KNOWLEDGE_SYNC_SCRIPT}}|$script_dest|g" \
        -e "s|{{LOG_DIR}}|$AITEAMFORGE_DIR/logs|g" \
        -e "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g" \
        -e "s|{{HOME_DIR}}|$HOME|g" \
        "$plist_template" > "$plist_dest"

    _aitf_launchctl unload "$plist_dest" 2>/dev/null || true

    # XACA-0651-009 load-verify pattern (aligned with the sibling LaunchAgent
    # installers): verify registration via `launchctl list` rather than trust
    # the legacy `launchctl load` exit code, which returns 0 even when the
    # job is rejected.
    _aitf_launchctl load "$plist_dest" 2>/dev/null || true
    if launchctl list 2>/dev/null | grep -q "com.aiteamforge.knowledge-sync"; then
        success "Knowledge-sync LaunchAgent installed (every 30 minutes)"
        info "Script:  $script_dest"
        info "Log:     $AITEAMFORGE_DIR/logs/knowledge-sync.log"
    else
        warning "Knowledge-sync LaunchAgent installed but not loaded — activate with: launchctl load ${plist_dest}"
    fi
    return 0
}

# Uninstall knowledge-sync LaunchAgent
uninstall_knowledge_sync_launchagent() {
    local plist_file="$HOME/Library/LaunchAgents/com.aiteamforge.knowledge-sync.plist"

    if [ -f "$plist_file" ]; then
        info "Unloading knowledge-sync LaunchAgent..."
        _aitf_launchctl unload "$plist_file" 2>/dev/null || true
        rm -f "$plist_file"
        success "Removed knowledge-sync LaunchAgent"
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
    install_remote_tmux_attach_script
    install_kb_init_team_scripts
    install_kanban_hooks

    # Provision ~/knowledge. Repo clone FIRST (XACA-0747): turn an empty/absent/
    # husk ~/knowledge into a real clone of the canonical repo (auth-gated soft
    # skip when the fleet-auth gate XACA-0750 is not yet granted). Then the tree
    # step seeds only the gaps a clone leaves (or the full fallback scaffold when
    # the clone was skipped). Decoupled from team presence (XACA-0743); both
    # refresh on every run, fully idempotent.
    install_knowledge_repo
    install_knowledge_tree

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
    # XACA-0161-002: the ttyd terminal-bridge agents are per-(team, terminal),
    # dynamic, and config-gated OFF by default, so they are reconciled by their
    # own script rather than rendered from the static launchagent map. Install
    # and upgrade deliberately share ONE entry point -- `reconcile` is
    # level-triggered (renders missing, refreshes drifted, prunes undesired) --
    # so there is no second code path to forget when the shape changes.
    # `|| true` because a machine that never opts in must not fail its install.
    "$AITEAMFORGE_DIR/scripts/kb-ttyd-bridge.sh" reconcile || true
    install_auto_upgrade_launchagent
    install_lcars_watch_launchagent
    install_cellar_watch_launchagent
    install_knowledge_sync_launchagent
    # com.aiteamforge.lcars-runatload retired (XACA-0763-005) — no install-side
    # call. uninstall_lcars_runatload_launchagent below is kept so existing
    # installs can still be torn down.

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

    # ═══ XACA-0734: THIS IS A BATCH TEARDOWN, NOT A STRING OF OPT-OUTS ═══
    #
    # Read this before "simplifying" it away.
    #
    # Every uninstall_<x>_launchagent() below CAN record an opt-out, because a
    # TARGETED removal means "I do not want this agent" and `aiteamforge upgrade`
    # must respect that rather than re-materializing it. But this function is a
    # BATCH teardown of the whole kanban system. "Remove the kanban system" says
    # nothing about which agents the user wants if they ever reinstall it — so
    # recording an opt-out for each one, here, would be inventing intent nobody
    # expressed. That is the sin this entire ticket exists to punish.
    #
    # The first cut of XACA-0734 recorded anyway and wiped the sentinel at the end
    # to undo it. This script runs under `set -euo pipefail`, so any non-zero exit
    # — or a Ctrl-C, which is an utterly normal response to an uninstall you began
    # by mistake — landing between the first record and the final wipe left the
    # sentinel listing EVERY MANDATORY AGENT. Nothing downstream ever clears it
    # (installers refuse an opted-out agent; upgrade skips it), so:
    #
    #     uninstall → ^C partway → reinstall
    #       ⇒ auto-upgrade can never be installed by ANY code path, ever again
    #
    # ...which is the original self-sealing failure, resurrected on the
    # uninstall→reinstall path. So we do not record at all: the flag below makes
    # every helper skip its record for the duration of the batch. There is
    # nothing to undo, so there is nothing an abort can leave behind. Note this
    # replaced a trailing _xaca0734_clear_all_optouts() — DO NOT reintroduce it:
    # with no batch recording, its only remaining effect would be to silently
    # destroy the user's HAND-EDITED opt-outs, which are the sentinel's primary
    # population path. (The FULL uninstall still wipes the sentinel, correctly —
    # see aiteamforge-uninstall.sh, where the whole install is going away.)
    #
    # Scoped to this function: set before the calls, unset after, so a later
    # targeted uninstall in the same shell records normally.
    #
    # EXPORTED, and that is load-bearing (XACA-0734-011). uninstall_kanban_system
    # is `export -f`'d (see the bottom of this file), so it is REACHABLE from a
    # separate bash process — `bash -c uninstall_kanban_system`, a `xargs`/`find
    # -exec` wrapper, a future installer that shells out. A plain shell variable
    # does not cross that boundary: the child would run the whole teardown with the
    # guard UNSET, every helper would fall through to _xaca0734_record_optout, and
    # the sentinel would come out listing every mandatory agent — the poisoned,
    # self-sealing box that BLOCKING 2 exists to prevent, reintroduced by nothing
    # more than the caller's choice of invocation. Exporting the flag makes the
    # guard travel with the function it guards.
    export _XACA0734_BATCH_UNINSTALL=1

    # Unload LaunchAgents
    uninstall_backup_launchagent
    uninstall_cr_confluence_poller_launchagent
    uninstall_cellar_watch_launchagent
    uninstall_auto_upgrade_launchagent
    uninstall_lcars_watch_launchagent
    uninstall_lcars_runatload_launchagent
    uninstall_knowledge_sync_launchagent

    unset _XACA0734_BATCH_UNINSTALL

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
export -f install_knowledge_tree
export -f migrate_legacy_repo_knowledge
export -f install_knowledge_repo
export -f _knowledge_repo_url
export -f _knowledge_repo_url_alias
export -f _knowledge_repo_url_direct
export -f _knowledge_repo_candidates
export -f _knowledge_resolve_repo_url
export -f _knowledge_repo_reachable
export -f _knowledge_wire_hooks
