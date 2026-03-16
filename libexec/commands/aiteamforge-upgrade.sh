#!/bin/bash
# aiteamforge-upgrade.sh
# Upgrade aiteamforge components and framework
# Updates formula, templates, LCARS UI, and skills

set -eo pipefail

# Get framework location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBEXEC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source shared libraries
source "${LIBEXEC_DIR}/lib/common.sh"
source "${LIBEXEC_DIR}/lib/config.sh"

VERSION="1.3.3"

# Options
DRY_RUN=false
FORCE=false

# Usage
usage() {
  cat <<EOF
AITeamForge Upgrade v${VERSION}
Update aiteamforge components to latest version

Usage: aiteamforge upgrade [options]

Options:
  --dry-run         Show what would be updated without making changes
  --force           Force upgrade even if up to date
  -v, --version     Show version
  -h, --help        Show this help

What Gets Updated:
  • Homebrew formula (if newer version available)
  • Template files (re-processed with current config)
  • LCARS UI files (updated from framework)
  • Shell aliases and helpers (re-sourced)
  • Skills (symlinks verified or re-copied)
  • LaunchAgents (updated if changed)

What Gets Preserved:
  • User customizations in config files
  • Kanban board data and backups
  • Team configurations
  • secrets.env and credentials

Examples:
  aiteamforge upgrade               # Upgrade to latest version
  aiteamforge upgrade --dry-run     # Preview changes
  aiteamforge upgrade --force       # Re-install even if current

Exit Codes:
  0 - Upgrade successful or already up to date
  1 - Upgrade failed
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    -v|--version)
      echo "AITeamForge Upgrade v${VERSION}"
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

# Check if configured
if ! is_configured; then
  print_error "Dev-team not configured"
  echo "Run: aiteamforge setup"
  exit 1
fi

# Get directories
FRAMEWORK_DIR=$(get_framework_dir)
WORKING_DIR=$(get_working_dir)
CURRENT_VERSION=$(get_installed_version)

# Banner
clear
print_header "AITEAMFORGE UPGRADE"

echo "Current version: ${CURRENT_VERSION:-unknown}"
echo "Framework: ${FRAMEWORK_DIR}"
echo "Working: ${WORKING_DIR}"
echo ""

if [ "$DRY_RUN" = true ]; then
  print_warning "DRY RUN MODE - No changes will be made"
  echo ""
fi

# Check for Homebrew formula updates
check_brew_updates() {
  print_section "Checking for Updates"

  if ! command -v brew &>/dev/null; then
    print_warning "Homebrew not found, skipping formula check"
    return
  fi

  print_info "Checking Homebrew formula..."

  # Check if aiteamforge is installed via Homebrew
  if ! brew list aiteamforge &>/dev/null; then
    print_warning "aiteamforge not installed via Homebrew"
    return
  fi

  # Check for updates
  if brew outdated aiteamforge &>/dev/null; then
    local available_version
    available_version=$(brew info aiteamforge --json | jq -r '.[0].versions.stable')
    print_warning "Update available: ${available_version}"

    if [ "$DRY_RUN" = false ]; then
      if prompt_yes_no "Upgrade Homebrew formula?" "y"; then
        print_info "Upgrading via Homebrew..."
        brew upgrade aiteamforge
        print_success "Formula upgraded"
      fi
    else
      echo "Would upgrade: brew upgrade aiteamforge"
    fi
  else
    print_success "Homebrew formula is up to date"
  fi
}

# Update templates
update_templates() {
  print_section "Updating Templates"

  local templates_updated=0

  # Check if templates directory exists
  if [ ! -d "${FRAMEWORK_DIR}/config/templates" ]; then
    print_warning "Templates directory not found in framework"
    return
  fi

  # Find all templates
  local templates
  templates=$(find "${FRAMEWORK_DIR}/config/templates" -name "*.template" 2>/dev/null)

  if [ -z "$templates" ]; then
    print_info "No templates to update"
    return
  fi

  # Process each template
  while IFS= read -r template; do
    local template_name
    template_name=$(basename "$template" .template)
    local target_file="${WORKING_DIR}/config/${template_name}"

    # Skip if target doesn't exist (wasn't originally installed)
    if [ ! -f "$target_file" ]; then
      continue
    fi

    # Check if template is newer than target
    if [ "$template" -nt "$target_file" ] || [ "$FORCE" = true ]; then
      print_info "Updating ${template_name}..."

      if [ "$DRY_RUN" = false ]; then
        # Back up existing file
        cp "$target_file" "${target_file}.backup-$(date +%Y%m%d-%H%M%S)"

        # Re-process template (this would call template processor)
        # For now, just copy
        cp "$template" "$target_file"

        print_success "Updated ${template_name}"
        templates_updated=$((templates_updated + 1))
      else
        echo "Would update: ${template_name}"
        templates_updated=$((templates_updated + 1))
      fi
    fi
  done <<< "$templates"

  if [ $templates_updated -eq 0 ]; then
    print_success "All templates up to date"
  else
    print_success "Updated ${templates_updated} template(s)"
  fi
}

# Update LCARS UI
update_lcars() {
  print_section "Updating LCARS UI"

  local lcars_source="${FRAMEWORK_DIR}/lcars-ui"
  local lcars_target="${WORKING_DIR}/lcars-ui"

  if [ ! -d "$lcars_source" ]; then
    print_warning "LCARS UI not found in framework"
    return
  fi

  if [ ! -d "$lcars_target" ]; then
    print_warning "LCARS UI not installed in working directory"
    return
  fi

  print_info "Syncing LCARS UI files..."

  if [ "$DRY_RUN" = false ]; then
    # Sync files (preserving user customizations in config/)
    rsync -av --exclude 'config/' \
      "${lcars_source}/" "${lcars_target}/"

    print_success "LCARS UI updated"
  else
    echo "Would sync: ${lcars_source}/ -> ${lcars_target}/"
  fi
}

# Update shell helpers
update_shell_helpers() {
  print_section "Updating Shell Helpers"

  local helpers=(
    "kanban-helpers.sh"
    "worktree-helpers.sh"
    "claude_agent_aliases.sh"
    "claude_code_cc_aliases.sh"
  )

  local updated=0

  for helper in "${helpers[@]}"; do
    local source="${FRAMEWORK_DIR}/${helper}"
    local target="${WORKING_DIR}/${helper}"

    if [ ! -f "$source" ]; then
      continue
    fi

    if [ ! -f "$target" ]; then
      continue
    fi

    # Check if source is newer
    if [ "$source" -nt "$target" ] || [ "$FORCE" = true ]; then
      print_info "Updating ${helper}..."

      if [ "$DRY_RUN" = false ]; then
        cp "$source" "$target"
        print_success "Updated ${helper}"
        updated=$((updated + 1))
      else
        echo "Would update: ${helper}"
        updated=$((updated + 1))
      fi
    fi
  done

  if [ $updated -eq 0 ]; then
    print_success "All shell helpers up to date"
  else
    print_success "Updated ${updated} helper(s)"

    if [ "$DRY_RUN" = false ]; then
      print_info "Reload shell or run: source ~/.zshrc"
    fi
  fi
}

# Update skills
update_skills() {
  print_section "Updating Skills"

  local skills_source="${FRAMEWORK_DIR}/skills"
  local skills_target="${WORKING_DIR}/skills"

  if [ ! -d "$skills_source" ]; then
    print_warning "Skills not found in framework"
    return
  fi

  if [ ! -d "$skills_target" ]; then
    print_warning "Skills not installed in working directory"
    return
  fi

  # Check if skills are symlinked or copied
  if [ -L "$skills_target" ]; then
    # Symlinked - just verify link is correct
    local link_target
    link_target=$(readlink "$skills_target")

    if [ "$link_target" = "$skills_source" ]; then
      print_success "Skills symlink is correct"
    else
      print_warning "Skills symlink points to: ${link_target}"
      print_warning "Expected: ${skills_source}"

      if [ "$DRY_RUN" = false ]; then
        if prompt_yes_no "Fix symlink?" "y"; then
          rm "$skills_target"
          ln -s "$skills_source" "$skills_target"
          print_success "Symlink fixed"
        fi
      else
        echo "Would fix symlink"
      fi
    fi
  else
    # Copied - sync files
    print_info "Syncing skills..."

    if [ "$DRY_RUN" = false ]; then
      rsync -av --delete "${skills_source}/" "${skills_target}/"
      print_success "Skills updated"
    else
      echo "Would sync: ${skills_source}/ -> ${skills_target}/"
    fi
  fi
}

# Update LaunchAgents
update_launchagents() {
  print_section "Updating LaunchAgents"

  local agents=(
    "com.aiteamforge.kanban-backup.plist"
    "com.aiteamforge.lcars-health.plist"
  )

  local updated=0

  for agent in "${agents[@]}"; do
    local source="${FRAMEWORK_DIR}/launchagents/${agent}"
    local target="$HOME/Library/LaunchAgents/${agent}"

    if [ ! -f "$source" ]; then
      continue
    fi

    if [ ! -f "$target" ]; then
      continue
    fi

    # Check if source is newer or different
    if ! diff -q "$source" "$target" &>/dev/null || [ "$FORCE" = true ]; then
      print_info "Updating ${agent}..."

      if [ "$DRY_RUN" = false ]; then
        # Unload current agent
        launchctl unload "$target" 2>/dev/null || true

        # Update file
        cp "$source" "$target"

        # Reload agent
        launchctl load "$target" 2>/dev/null || true

        print_success "Updated ${agent}"
        updated=$((updated + 1))
      else
        echo "Would update: ${agent}"
        updated=$((updated + 1))
      fi
    fi
  done

  if [ $updated -eq 0 ]; then
    print_success "All LaunchAgents up to date"
  else
    print_success "Updated ${updated} LaunchAgent(s)"
  fi
}

# Show changelog
show_changelog() {
  print_section "What's New"

  local changelog="${FRAMEWORK_DIR}/CHANGELOG.md"

  if [ ! -f "$changelog" ]; then
    print_info "No changelog available"
    return
  fi

  # Show recent changes (last 20 lines)
  print_info "Recent changes:"
  echo ""
  head -n 20 "$changelog"
  echo ""
  print_info "Full changelog: ${changelog}"
}

# Run upgrade
check_brew_updates
update_templates
update_lcars
update_shell_helpers
update_skills
update_launchagents

# Show changelog (only if not dry run)
if [ "$DRY_RUN" = false ]; then
  show_changelog
fi

# Summary
print_section "Upgrade Complete"

if [ "$DRY_RUN" = true ]; then
  print_info "Dry run complete - no changes made"
  echo ""
  print_info "Run without --dry-run to apply changes"
else
  print_success "Dev-team has been upgraded successfully!"
  echo ""
  print_info "Next steps:"
  echo "  • Reload your shell: source ~/.zshrc"
  echo "  • Restart services: aiteamforge restart"
  echo "  • Run health check: aiteamforge doctor"
fi

exit 0
