#!/bin/bash
# aiteamforge-uninstall.sh
# Clean removal of aiteamforge environment
# Removes configurations, services, and optionally data

set -eo pipefail

# Get framework location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBEXEC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source shared libraries
source "${LIBEXEC_DIR}/lib/common.sh"
source "${LIBEXEC_DIR}/lib/config.sh"

VERSION="1.3.3"

# Options
KEEP_DATA=false
PURGE=false
YES=false

# Usage
usage() {
  cat <<EOF
AITeamForge Uninstall v${VERSION}
Clean removal of aiteamforge environment

Usage: aiteamforge uninstall [options]

Options:
  --keep-data       Preserve kanban boards and config data
  --purge           Remove absolutely everything (including data)
  --yes             Skip confirmation prompts
  -v, --version     Show version
  -h, --help        Show this help

What Gets Removed:
  • zshrc integration (between marker comments)
  • LaunchAgents (unloaded and deleted)
  • Running services (LCARS, Fleet Monitor)
  • Installed files in ~/.aiteamforge/ (or custom location)
  • Claude Code config additions (backups restored)
  • Shell aliases and helpers

What Can Be Preserved (with --keep-data):
  • Kanban board data
  • secrets.env
  • User configurations

WARNING: This does NOT uninstall the Homebrew formula.
         After running this, execute: brew uninstall aiteamforge

Examples:
  aiteamforge uninstall                # Interactive uninstall
  aiteamforge uninstall --keep-data    # Preserve data
  aiteamforge uninstall --purge --yes  # Complete removal

Exit Codes:
  0 - Uninstall successful
  1 - Uninstall failed or cancelled
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --keep-data)
      KEEP_DATA=true
      shift
      ;;
    --purge)
      PURGE=true
      shift
      ;;
    --yes)
      YES=true
      shift
      ;;
    -v|--version)
      echo "AITeamForge Uninstall v${VERSION}"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Conflicting options check
if [ "$KEEP_DATA" = true ] && [ "$PURGE" = true ]; then
  print_error "Cannot use --keep-data and --purge together"
  exit 1
fi

# Get directories
WORKING_DIR=$(get_working_dir)

# Banner
clear
print_header "AITEAMFORGE UNINSTALL"

if [ "$PURGE" = true ]; then
  print_warning "PURGE MODE - Everything will be removed!"
elif [ "$KEEP_DATA" = true ]; then
  print_info "Data preservation mode - kanban data will be kept"
fi

echo ""
echo "Working directory: ${WORKING_DIR}"
echo ""

# Confirmation
if [ "$YES" = false ]; then
  print_warning "This will remove aiteamforge from your system."
  echo ""

  if [ "$KEEP_DATA" = false ] && [ "$PURGE" = false ]; then
    echo "You will be asked about preserving data during uninstall."
    echo ""
  fi

  if ! prompt_yes_no "Continue with uninstall?" "n"; then
    print_info "Uninstall cancelled"
    exit 1
  fi
fi

# Stop services
stop_services() {
  print_section "Stopping Services"

  # Stop LCARS server
  if pgrep -f "lcars-ui/server.py" &>/dev/null; then
    print_info "Stopping LCARS server..."
    pkill -f "lcars-ui/server.py" || true
    print_success "LCARS server stopped"
  fi

  # Stop Fleet Monitor
  if pgrep -f "fleet-monitor/server/server.js" &>/dev/null; then
    print_info "Stopping Fleet Monitor..."
    pkill -f "fleet-monitor/server/server.js" || true
    print_success "Fleet Monitor stopped"
  fi

  # Stop any Claude agents
  if pgrep -f "claude" &>/dev/null; then
    print_warning "Claude Code agents are still running"
    print_info "You may want to stop them manually"
  fi
}

# Remove LaunchAgents
remove_launchagents() {
  print_section "Removing LaunchAgents"

  local agents=(
    "com.aiteamforge.kanban-backup.plist"
    "com.aiteamforge.lcars-health.plist"
  )

  for agent in "${agents[@]}"; do
    local plist="$HOME/Library/LaunchAgents/${agent}"

    if [ -f "$plist" ]; then
      print_info "Removing ${agent}..."

      # Unload agent
      launchctl unload "$plist" 2>/dev/null || true

      # Remove file
      rm "$plist"

      print_success "Removed ${agent}"
    fi
  done
}

# Remove zshrc integration
remove_zshrc_integration() {
  print_section "Removing Shell Integration"

  local zshrc="$HOME/.zshrc"

  if [ ! -f "$zshrc" ]; then
    print_info "No .zshrc file found"
    return
  fi

  # Check for aiteamforge markers
  if grep -q "# >>> aiteamforge initialize >>>" "$zshrc" 2>/dev/null; then
    print_info "Removing aiteamforge integration from .zshrc..."

    # Back up first
    cp "$zshrc" "${zshrc}.backup-$(date +%Y%m%d-%H%M%S)"

    # Remove lines between markers
    sed -i.tmp '/# >>> aiteamforge initialize >>>/,/# <<< aiteamforge initialize <<</d' "$zshrc"
    rm "${zshrc}.tmp"

    print_success "Shell integration removed"
    print_info "Backup saved: ${zshrc}.backup-*"
  else
    print_info "No aiteamforge integration found in .zshrc"
  fi
}

# Remove files
remove_files() {
  print_section "Removing Files"

  if [ ! -d "$WORKING_DIR" ]; then
    print_info "Working directory not found: ${WORKING_DIR}"
    return
  fi

  # Ask about data preservation (if not already specified)
  local preserve_data=$KEEP_DATA

  if [ "$PURGE" = true ]; then
    preserve_data=false
  elif [ "$YES" = false ] && [ "$KEEP_DATA" = false ]; then
    echo ""
    if prompt_yes_no "Preserve kanban board data?" "y"; then
      preserve_data=true
    fi

    if prompt_yes_no "Preserve secrets.env?" "y"; then
      PRESERVE_SECRETS=true
    else
      PRESERVE_SECRETS=false
    fi
  fi

  # List what will be preserved
  if [ "$preserve_data" = true ]; then
    echo ""
    print_info "The following will be preserved:"
    echo "  • kanban/"
    echo "  • kanban-backups/"
    if [ "${PRESERVE_SECRETS:-false}" = true ]; then
      echo "  • secrets.env"
    fi
    echo ""
  fi

  # Remove directories selectively
  print_info "Removing aiteamforge files..."

  local removed=0

  # Remove non-data directories
  local dirs_to_remove=(
    "lcars-ui"
    "fleet-monitor"
    "scripts"
    "config"
    "docs"
    "skills"
    "claude"
    "templates"
  )

  for dir in "${dirs_to_remove[@]}"; do
    if [ -d "${WORKING_DIR}/${dir}" ]; then
      rm -rf "${WORKING_DIR}/${dir}"
      print_success "Removed ${dir}/"
      removed=$((removed + 1))
    fi
  done

  # Remove helper scripts
  local scripts=(
    "kanban-helpers.sh"
    "worktree-helpers.sh"
    "claude_agent_aliases.sh"
    "claude_code_cc_aliases.sh"
    "*-startup.sh"
    "*-shutdown.sh"
    "startup.sh"
    "cleanup.sh"
  )

  for script_pattern in "${scripts[@]}"; do
    for script in ${WORKING_DIR}/${script_pattern}; do
      if [ -f "$script" ]; then
        rm "$script"
        removed=$((removed + 1))
      fi
    done
  done

  # Handle data directories based on options
  if [ "$preserve_data" = false ]; then
    if [ -d "${WORKING_DIR}/kanban" ]; then
      rm -rf "${WORKING_DIR}/kanban"
      print_success "Removed kanban/"
      removed=$((removed + 1))
    fi

    if [ -d "${WORKING_DIR}/kanban-backups" ]; then
      rm -rf "${WORKING_DIR}/kanban-backups"
      print_success "Removed kanban-backups/"
      removed=$((removed + 1))
    fi
  else
    print_info "Preserved kanban/"
    print_info "Preserved kanban-backups/"
  fi

  # Handle secrets.env
  if [ -f "${WORKING_DIR}/secrets.env" ]; then
    if [ "${PRESERVE_SECRETS:-false}" = false ]; then
      rm "${WORKING_DIR}/secrets.env"
      print_success "Removed secrets.env"
      removed=$((removed + 1))
    else
      print_info "Preserved secrets.env"
    fi
  fi

  # Remove config marker
  if [ -f "${WORKING_DIR}/.aiteamforge-config" ]; then
    rm "${WORKING_DIR}/.aiteamforge-config"
  fi

  # Remove working directory if empty (or if purge)
  if [ "$PURGE" = true ] || [ -z "$(ls -A "$WORKING_DIR" 2>/dev/null)" ]; then
    rmdir "$WORKING_DIR" 2>/dev/null || true
    print_success "Removed working directory"
  else
    print_info "Working directory preserved (contains data): ${WORKING_DIR}"
  fi

  echo ""
  print_success "Removed ${removed} file(s)/directory(ies)"
}

# Restore Claude Code config
restore_claude_config() {
  print_section "Restoring Claude Code Config"

  local claude_config="$HOME/.config/claude/settings.json"
  local backup="${claude_config}.pre-devteam"

  if [ -f "$backup" ]; then
    print_info "Restoring Claude Code settings from backup..."
    mv "$backup" "$claude_config"
    print_success "Claude Code config restored"
  else
    print_info "No Claude Code backup found (config may have aiteamforge entries)"
    print_info "You may want to manually edit: ${claude_config}"
  fi
}

# Run uninstall steps
stop_services
remove_launchagents
remove_zshrc_integration
restore_claude_config
remove_files

# Summary
print_section "Uninstall Complete"

print_success "Dev-team has been uninstalled from your system"
echo ""

if [ "$KEEP_DATA" = true ] || [ "$PURGE" = false ]; then
  print_info "Preserved data location: ${WORKING_DIR}"
  echo ""
fi

print_warning "To complete uninstall, run:"
echo "  brew uninstall aiteamforge"
echo ""

print_info "To reinstall aiteamforge:"
echo "  brew install aiteamforge"
echo "  aiteamforge setup"
echo ""

exit 0
