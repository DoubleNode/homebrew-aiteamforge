#!/usr/bin/env bash
# Claude Code Configuration Installer
# Part of aiteamforge Homebrew tap setup wizard
#
# Installs and configures Claude Code CLI settings, CLAUDE.md files,
# MCP servers, skills, hooks, and agent personas.

set -euo pipefail

# Source shared utilities (will be sourced by setup wizard)
# shellcheck disable=SC2034
INSTALLER_NAME="Claude Code Configuration"
INSTALLER_VERSION="1.4.0"

# Default paths (will be overridden by setup wizard config)
# CLAUDE_CONFIG_DIR: Where Claude Code config lives.
# When CLAUDE_SANDBOX=1 (set by setup wizard for non-production installs),
# configs are staged under AITEAMFORGE_DIR instead of modifying real ~/.claude.
AITEAMFORGE_DIR="${AITEAMFORGE_DIR:-${HOME}/aiteamforge}"
TEMPLATE_DIR="${TEMPLATE_DIR:-}"

if [[ "${CLAUDE_SANDBOX:-0}" == "1" ]]; then
    CLAUDE_CONFIG_DIR="${AITEAMFORGE_DIR}/.claude-staging"
else
    CLAUDE_CONFIG_DIR="${HOME}/.claude"
fi

BACKUP_DIR="${AITEAMFORGE_DIR}/.backups/claude-config-$(date +%Y%m%d-%H%M%S)"

# Colors (if not already defined)
if [[ -z "${COLOR_BLUE:-}" ]]; then
    COLOR_BLUE='\033[0;34m'
    COLOR_GREEN='\033[0;32m'
    COLOR_YELLOW='\033[1;33m'
    COLOR_RED='\033[0;31m'
    COLOR_RESET='\033[0m'
fi

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

log_info() {
    echo -e "${COLOR_BLUE}[Claude Config]${COLOR_RESET} $*"
}

log_success() {
    echo -e "${COLOR_GREEN}[Claude Config]${COLOR_RESET} $*"
}

log_warning() {
    echo -e "${COLOR_YELLOW}[Claude Config]${COLOR_RESET} $*"
}

log_error() {
    echo -e "${COLOR_RED}[Claude Config]${COLOR_RESET} $*"
}

# Backup existing file if it exists
backup_file() {
    local file_path="$1"

    if [[ -f "$file_path" ]]; then
        local backup_path="${BACKUP_DIR}/$(basename "$file_path")"
        mkdir -p "$(dirname "$backup_path")"
        cp "$file_path" "$backup_path"
        log_info "Backed up: $(basename "$file_path")"
    fi
}

# Merge JSON files (newer settings override older)
merge_json() {
    local base_file="$1"
    local overlay_file="$2"
    local output_file="$3"

    if ! command -v jq &>/dev/null; then
        log_error "jq is required for JSON merging"
        return 1
    fi

    # If base doesn't exist, just copy overlay
    if [[ ! -f "$base_file" ]]; then
        cp "$overlay_file" "$output_file"
        return 0
    fi

    # Merge: overlay values take precedence
    jq -s '.[0] * .[1]' "$base_file" "$overlay_file" > "$output_file"
}

# Template substitution for configuration files
apply_template() {
    local template_file="$1"
    local output_file="$2"

    if [[ ! -f "$template_file" ]]; then
        log_error "Template not found: $template_file"
        return 1
    fi

    # Replace placeholders with actual values
    sed -e "s|{{AITEAMFORGE_DIR}}|${AITEAMFORGE_DIR}|g" \
        -e "s|{{HOME}}|${HOME}|g" \
        -e "s|{{CLAUDE_CONFIG_DIR}}|${CLAUDE_CONFIG_DIR}|g" \
        -e "s|{{USER}}|${USER}|g" \
        "$template_file" > "$output_file"
}

#------------------------------------------------------------------------------
# Installation Functions
#------------------------------------------------------------------------------

# Check if Claude Code is installed
check_claude_installed() {
    log_info "Checking Claude Code installation..."

    if ! command -v claude &>/dev/null; then
        log_error "Claude Code CLI not found"
        log_error "Install with: npm install -g @anthropic-ai/claude-code"
        return 1
    fi

    local claude_version
    claude_version=$(claude --version 2>/dev/null || echo "unknown")
    log_success "Claude Code CLI found: $claude_version"
    return 0
}

# Install global CLAUDE.md
install_global_claude_md() {
    log_info "Installing global CLAUDE.md..."

    local template="${TEMPLATE_DIR}/claude/claude-md-global.template"
    local target="${CLAUDE_CONFIG_DIR}/CLAUDE.md"

    # Backup existing
    backup_file "$target"

    # Apply template
    if [[ -f "$template" ]]; then
        apply_template "$template" "$target"
        log_success "Global CLAUDE.md installed"
    else
        log_warning "Template not found, skipping: $template"
    fi
}

# Install team-specific CLAUDE.md files
install_team_claude_md() {
    local team_name="$1"

    log_info "Installing CLAUDE.md for $team_name..."

    local template="${TEMPLATE_DIR}/claude/claude-md-team.template"
    local agent_dir="${CLAUDE_CONFIG_DIR}/agents/${team_name}"
    local target="${agent_dir}/CLAUDE.md"

    # Create agent directory if needed
    mkdir -p "$agent_dir"

    # Apply template
    if [[ -f "$template" ]]; then
        # Team-specific template substitution (can be customized per team)
        sed -e "s|{{AITEAMFORGE_DIR}}|${AITEAMFORGE_DIR}|g" \
            -e "s|{{HOME}}|${HOME}|g" \
            -e "s|{{TEAM_NAME}}|${team_name}|g" \
            "$template" > "$target"
        log_success "CLAUDE.md installed for $team_name"
    else
        log_warning "Team CLAUDE.md template not found"
    fi
}

# Install MCP server configuration
install_mcp_config() {
    log_info "Configuring MCP servers..."

    local template="${TEMPLATE_DIR}/claude/mcp-settings.template"
    local temp_config="/tmp/mcp-settings-$$.json"

    if [[ ! -f "$template" ]]; then
        log_warning "MCP settings template not found, skipping"
        return 0
    fi

    # Apply template substitution
    apply_template "$template" "$temp_config"

    # We'll merge this into settings.json in the main settings function
    log_success "MCP server configuration prepared"
}

# Install Claude Code hooks
install_hooks() {
    log_info "Installing Claude Code hooks..."

    local hooks_dir="${CLAUDE_CONFIG_DIR}/hooks"
    mkdir -p "$hooks_dir"

    # Install damage control hooks (skip files that already exist and are read-only)
    if [[ -d "${TEMPLATE_DIR}/claude/hooks/damage-control" ]]; then
        log_info "Installing damage control hooks..."
        mkdir -p "$hooks_dir/damage-control"

        local hook_errors=0
        for hook_file in "${TEMPLATE_DIR}/claude/hooks/damage-control/"*; do
            [[ -f "$hook_file" ]] || continue
            local target="$hooks_dir/damage-control/$(basename "$hook_file")"
            if [[ -f "$target" && ! -w "$target" ]]; then
                log_warning "Skipping read-only hook: $(basename "$hook_file")"
                continue
            fi
            if cp "$hook_file" "$target" 2>/dev/null; then
                chmod +x "$target" 2>/dev/null || true
            else
                log_warning "Could not install: $(basename "$hook_file")"
                hook_errors=$((hook_errors + 1))
            fi
        done

        if [[ $hook_errors -eq 0 ]]; then
            log_success "Damage control hooks installed"
        else
            log_warning "Some hooks could not be installed (existing files may be protected)"
        fi
    fi

    # Apply template substitution to any hook scripts
    find "$hooks_dir" -type f -name "*.sh" -o -name "*.py" | while read -r hook_file; do
        # If file contains template markers, apply substitution
        if grep -q "{{" "$hook_file" 2>/dev/null; then
            local temp_file="/tmp/hook-$$.tmp"
            apply_template "$hook_file" "$temp_file"
            mv "$temp_file" "$hook_file"
            chmod +x "$hook_file"
        fi
    done
}

# Install Claude Code skills
install_skills() {
    log_info "Installing Claude Code skills..."

    local skills_src="${AITEAMFORGE_DIR}/skills"
    local skills_target="${CLAUDE_CONFIG_DIR}/skills"

    if [[ ! -d "$skills_src" ]]; then
        log_warning "Skills directory not found in aiteamforge, skipping"
        return 0
    fi

    mkdir -p "$skills_target"

    # Copy all skills (or create symlinks for easier updates)
    # Using symlinks so skills can be updated in aiteamforge without reinstalling
    find "$skills_src" -mindepth 1 -maxdepth 1 -type d | while read -r skill_dir; do
        local skill_name=$(basename "$skill_dir")
        local target_link="${skills_target}/${skill_name}"

        # Remove existing symlink/directory
        if [[ -L "$target_link" ]] || [[ -d "$target_link" ]]; then
            rm -rf "$target_link"
        fi

        # Create symlink to aiteamforge skills
        ln -s "$skill_dir" "$target_link"
        log_info "Linked skill: $skill_name"
    done

    log_success "Skills installed (symlinked to aiteamforge)"
}

# Install agent personas
install_agent_personas() {
    local team_name="$1"

    log_info "Installing agent personas for $team_name..."

    local team_slug=$(echo "$team_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    local personas_src="${AITEAMFORGE_DIR}/${team_slug}/personas/agents"
    local agent_dir="${CLAUDE_CONFIG_DIR}/agents/${team_name}"

    if [[ ! -d "$personas_src" ]]; then
        log_warning "Personas not found for $team_name at: $personas_src"
        return 0
    fi

    mkdir -p "$agent_dir"

    # Copy persona markdown files
    find "$personas_src" -name "*.md" -type f | while read -r persona_file; do
        cp "$persona_file" "$agent_dir/"
        log_info "Installed persona: $(basename "$persona_file")"
    done

    log_success "Agent personas installed for $team_name"
}

# Install statusline command
install_statusline() {
    log_info "Installing statusline command..."

    local template="${TEMPLATE_DIR}/claude/statusline-command.sh"
    local target="${CLAUDE_CONFIG_DIR}/statusline-command.sh"

    if [[ -f "$template" ]]; then
        apply_template "$template" "$target"
        chmod +x "$target"
        log_success "Statusline command installed"
    else
        # Try copying from aiteamforge if template doesn't exist
        if [[ -f "${AITEAMFORGE_DIR}/claude/statusline-command.sh" ]]; then
            cp "${AITEAMFORGE_DIR}/claude/statusline-command.sh" "$target"
            chmod +x "$target"
            log_success "Statusline command installed from aiteamforge"
        else
            log_warning "Statusline command not found"
        fi
    fi
}

# Install agent tracking script
install_agent_tracking() {
    log_info "Installing agent tracking script..."

    local template="${TEMPLATE_DIR}/claude/agent-tracking.sh"
    local target="${CLAUDE_CONFIG_DIR}/agent-tracking.sh"

    if [[ -f "$template" ]]; then
        apply_template "$template" "$target"
        chmod +x "$target"
        log_success "Agent tracking script installed"
    else
        # Try copying from aiteamforge
        if [[ -f "${AITEAMFORGE_DIR}/claude/agent-tracking.sh" ]]; then
            cp "${AITEAMFORGE_DIR}/claude/agent-tracking.sh" "$target"
            chmod +x "$target"
            log_success "Agent tracking script installed from aiteamforge"
        else
            log_warning "Agent tracking script not found"
        fi
    fi
}

# Generate and install settings.json
install_settings_json() {
    log_info "Installing Claude Code settings.json..."

    local template="${TEMPLATE_DIR}/claude/settings.json.template"
    local target="${CLAUDE_CONFIG_DIR}/settings.json"
    local temp_file="/tmp/claude-settings-$$.json"

    # Backup existing settings
    backup_file "$target"

    if [[ -f "$template" ]]; then
        # Apply template substitution
        apply_template "$template" "$temp_file"

        # If user has existing settings, merge them
        if [[ -f "$target" ]]; then
            log_info "Merging with existing settings..."
            local merged_file="/tmp/claude-settings-merged-$$.json"
            merge_json "$target" "$temp_file" "$merged_file"
            mv "$merged_file" "$target"
        else
            mv "$temp_file" "$target"
        fi

        log_success "settings.json installed"
    else
        log_warning "settings.json template not found"
    fi
}

#------------------------------------------------------------------------------
# Main Installation Function
#------------------------------------------------------------------------------

install_claude_config() {
    local selected_teams=("$@")

    echo ""
    log_info "═══════════════════════════════════════════════════════"
    log_info "  Claude Code Configuration Installer"
    log_info "═══════════════════════════════════════════════════════"
    echo ""

    # Check prerequisites
    if ! check_claude_installed; then
        return 1
    fi

    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    log_info "Backups will be saved to: $BACKUP_DIR"
    echo ""

    # Create .claude directory if it doesn't exist
    mkdir -p "$CLAUDE_CONFIG_DIR"

    # Install core components
    install_global_claude_md
    install_statusline
    install_agent_tracking
    install_hooks
    install_skills

    # Install team-specific components
    if [[ ${#selected_teams[@]} -gt 0 ]]; then
        echo ""
        log_info "Installing team-specific configurations..."

        for team in "${selected_teams[@]}"; do
            install_team_claude_md "$team"
            install_agent_personas "$team"
        done
    fi

    # Install settings.json (do this last so it can reference installed components)
    echo ""
    install_settings_json

    # Final summary
    echo ""
    log_success "═══════════════════════════════════════════════════════"
    log_success "  Claude Code Configuration Complete!"
    log_success "═══════════════════════════════════════════════════════"
    echo ""
    log_info "Configuration installed to: $CLAUDE_CONFIG_DIR"
    log_info "Backups saved to: $BACKUP_DIR"
    echo ""
    log_info "Next steps:"
    log_info "  1. Review settings: cat ~/.claude/settings.json"
    log_info "  2. Test Claude Code: claude"
    log_info "  3. Check agents: ls ~/.claude/agents/"
    echo ""

    return 0
}

# Restore function for --restore flag
restore_claude_config() {
    local backup_date="$1"

    if [[ -z "$backup_date" ]]; then
        log_error "No backup date specified"
        log_info "Usage: install-claude-config.sh --restore YYYYMMDD-HHMMSS"
        return 1
    fi

    local backup_path="${AITEAMFORGE_DIR}/.backups/claude-config-${backup_date}"

    if [[ ! -d "$backup_path" ]]; then
        log_error "Backup not found: $backup_path"
        return 1
    fi

    log_info "Restoring Claude Code configuration from: $backup_path"

    # Restore backed up files
    find "$backup_path" -type f | while read -r backup_file; do
        local rel_path="${backup_file#$backup_path/}"
        local target="${CLAUDE_CONFIG_DIR}/${rel_path}"

        mkdir -p "$(dirname "$target")"
        cp "$backup_file" "$target"
        log_info "Restored: $rel_path"
    done

    log_success "Configuration restored from backup"
    return 0
}

# If script is run directly (not sourced), execute main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Check for --restore flag
    if [[ "${1:-}" == "--restore" ]]; then
        restore_claude_config "${2:-}"
    else
        install_claude_config "$@"
    fi
fi
