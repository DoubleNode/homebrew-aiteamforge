#!/bin/bash
# aiteamforge-migrate.sh
# Migrates an existing manual aiteamforge installation to Homebrew-managed structure
# CRITICAL: This script handles user data migration — data loss is unacceptable
#
# What it does:
# 1. Backs up the entire existing installation
# 2. Moves user data to ~/.aiteamforge/ (persistent)
# 3. Updates paths in configs and LaunchAgents
# 4. Validates the migration
# 5. Provides rollback if anything fails
#
# What it does NOT do:
# - Delete the original ~/aiteamforge/ directory (user decides when safe)
# - Modify git repository structure
# - Change kanban board data (only moves it)

set -eo pipefail

# Get framework location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBEXEC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source shared libraries
source "${LIBEXEC_DIR}/lib/common.sh"
source "${LIBEXEC_DIR}/lib/config.sh"

VERSION="1.4.0"

# Default values
OLD_INSTALL_DIR="${HOME}/aiteamforge"
NEW_DATA_DIR="${HOME}/.aiteamforge"
BACKUP_DIR="${HOME}/.aiteamforge/migration-backups/$(date +%Y-%m-%d_%H%M%S)"
DRY_RUN=false
SKIP_BACKUP=false
SKIP_VALIDATION=false
FORCE=false
ROLLBACK_MODE=false
ROLLBACK_FROM=""

# Migration state
MIGRATION_STATE_FILE="${HOME}/.aiteamforge/migration-state.json"
MIGRATION_LOG="${HOME}/.aiteamforge/migration.log"

# Usage
usage() {
  cat <<EOF
AITeamForge Migration v${VERSION}
Migrate existing manual installation to Homebrew-managed structure

Usage: aiteamforge migrate [options]

Options:
  --dry-run              Preview migration without making changes
  --skip-backup          Skip backup creation (DANGEROUS - not recommended)
  --skip-validation      Skip post-migration validation
  --force                Force migration even with warnings
  --rollback             Rollback to most recent migration backup
  --rollback-from <dir>  Rollback from specific backup directory
  --old-dir <path>       Path to existing installation (default: ~/aiteamforge)
  --new-dir <path>       Path for user data (default: ~/.aiteamforge)
  -v, --version          Show version
  -h, --help             Show this help

Examples:
  aiteamforge migrate                    # Interactive migration
  aiteamforge migrate --dry-run          # Preview without changes
  aiteamforge migrate --rollback         # Undo migration
  aiteamforge migrate --old-dir ~/old    # Migrate from custom path

Exit Codes:
  0    Migration successful
  1    Migration failed (see logs)
  2    Pre-migration check failed
  3    Rollback successful
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --skip-backup)
      SKIP_BACKUP=true
      shift
      ;;
    --skip-validation)
      SKIP_VALIDATION=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --rollback)
      ROLLBACK_MODE=true
      shift
      ;;
    --rollback-from)
      ROLLBACK_MODE=true
      ROLLBACK_FROM="$2"
      shift 2
      ;;
    --old-dir)
      OLD_INSTALL_DIR="$2"
      shift 2
      ;;
    --new-dir)
      NEW_DATA_DIR="$2"
      shift 2
      ;;
    -v|--version)
      echo "v${VERSION}"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Expand paths (safe tilde expansion)
OLD_INSTALL_DIR="${OLD_INSTALL_DIR/#\~/$HOME}"
NEW_DATA_DIR="${NEW_DATA_DIR/#\~/$HOME}"

# Initialize logging
mkdir -p "$(dirname "${MIGRATION_LOG}")"
exec > >(tee -a "${MIGRATION_LOG}") 2>&1

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

#-----------------------------------------------------------------------------
# Rollback Functions
#-----------------------------------------------------------------------------

rollback_migration() {
  section "Migration Rollback"

  # Find backup to restore
  if [[ -n "${ROLLBACK_FROM}" ]]; then
    BACKUP_TO_RESTORE="${ROLLBACK_FROM}"
  else
    # Find most recent backup
    BACKUP_TO_RESTORE=$(find "${HOME}/.aiteamforge/migration-backups" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort -r | head -1)
  fi

  if [[ -z "${BACKUP_TO_RESTORE}" ]]; then
    error "No migration backup found to restore"
    echo "Backup directory: ${HOME}/.aiteamforge/migration-backups"
    exit 1
  fi

  log "Restoring from backup: ${BACKUP_TO_RESTORE}"
  echo ""

  # Verify backup integrity
  if [[ ! -d "${BACKUP_TO_RESTORE}" ]]; then
    error "Backup directory not found: ${BACKUP_TO_RESTORE}"
    exit 1
  fi

  # Show what will be restored
  BACKUP_SIZE=$(du -sh "${BACKUP_TO_RESTORE}" | cut -f1)
  echo "Backup information:"
  echo "  Location: ${BACKUP_TO_RESTORE}"
  echo "  Size: ${BACKUP_SIZE}"
  echo "  Created: $(basename "${BACKUP_TO_RESTORE}")"
  echo ""

  # Confirm rollback
  if [[ "${FORCE}" != "true" ]]; then
    echo "⚠️  WARNING: This will restore the backup and overwrite current state"
    echo ""
    read -p "Continue with rollback? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Rollback cancelled"
      exit 0
    fi
  fi

  # Stop services
  log "Stopping services..."
  pkill -f "lcars-ui/server.py" 2>/dev/null || true
  pkill -f "fleet-monitor/server" 2>/dev/null || true

  # Restore backup
  log "Restoring backup..."

  # Restore to original location
  if [[ -d "${OLD_INSTALL_DIR}" ]]; then
    log "Backing up current state before rollback..."
    mv "${OLD_INSTALL_DIR}" "${OLD_INSTALL_DIR}.before-rollback-$(date +%s)"
  fi

  # Copy backup back
  cp -R "${BACKUP_TO_RESTORE}/aiteamforge" "${OLD_INSTALL_DIR}"

  # Restore LaunchAgents if backed up
  if [[ -d "${BACKUP_TO_RESTORE}/LaunchAgents" ]]; then
    log "Restoring LaunchAgents..."
    cp "${BACKUP_TO_RESTORE}/LaunchAgents"/* "${HOME}/Library/LaunchAgents/" 2>/dev/null || true
  fi

  # Restore shell configs if backed up
  if [[ -f "${BACKUP_TO_RESTORE}/.zshrc" ]]; then
    log "Restoring ~/.zshrc..."
    cp "${BACKUP_TO_RESTORE}/.zshrc" "${HOME}/.zshrc"
  fi

  success "Rollback completed successfully"
  echo ""
  echo "Your aiteamforge installation has been restored to:"
  echo "  ${OLD_INSTALL_DIR}"
  echo ""
  echo "The backup used for rollback is still available at:"
  echo "  ${BACKUP_TO_RESTORE}"
  echo ""

  exit 3
}

#-----------------------------------------------------------------------------
# Pre-Migration Checks
#-----------------------------------------------------------------------------

run_pre_migration_checks() {
  section "Pre-Migration Checks"

  # Check if old installation exists
  if [[ ! -d "${OLD_INSTALL_DIR}" ]]; then
    error "Source installation not found: ${OLD_INSTALL_DIR}"
    echo ""
    echo "If your installation is elsewhere, use: --old-dir <path>"
    exit 2
  fi

  log "Source installation: ${OLD_INSTALL_DIR}"

  # Run migration check script
  log "Running migration check..."
  echo ""

  if "${SCRIPT_DIR}/aiteamforge-migrate-check.sh" --dir "${OLD_INSTALL_DIR}"; then
    success "Migration check passed"
  else
    CHECK_EXIT=$?
    if [[ "${CHECK_EXIT}" -eq 2 ]]; then
      error "Migration check found critical issues"
      if [[ "${FORCE}" != "true" ]]; then
        echo ""
        echo "Fix the issues above or use --force to proceed anyway"
        exit 2
      else
        warning "Proceeding with --force (issues detected but ignored)"
      fi
    elif [[ "${CHECK_EXIT}" -eq 1 ]]; then
      warning "Migration check found warnings"
      if [[ "${FORCE}" != "true" ]]; then
        echo ""
        read -p "Continue despite warnings? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
          echo "Migration cancelled"
          exit 0
        fi
      fi
    fi
  fi

  echo ""

  # Check if already migrated
  if [[ -f "${NEW_DATA_DIR}/MIGRATED" ]]; then
    warning "Installation appears to already be migrated"
    echo ""
    echo "Found migration marker: ${NEW_DATA_DIR}/MIGRATED"
    echo ""
    if [[ "${FORCE}" != "true" ]]; then
      echo "Use --force to re-migrate"
      exit 2
    fi
  fi

  # Check disk space
  OLD_SIZE=$(du -sk "${OLD_INSTALL_DIR}" | cut -f1)
  AVAILABLE_SPACE=$(df -k "${HOME}" | tail -1 | awk '{print $4}')
  REQUIRED_SPACE=$((OLD_SIZE * 3))  # Original + backup + new location

  if [[ "${AVAILABLE_SPACE}" -lt "${REQUIRED_SPACE}" ]]; then
    error "Insufficient disk space"
    echo ""
    echo "Required: ~$((REQUIRED_SPACE / 1024))MB (includes backup)"
    echo "Available: $((AVAILABLE_SPACE / 1024))MB"
    echo ""
    if [[ "${SKIP_BACKUP}" != "true" ]]; then
      echo "Consider using --skip-backup (not recommended)"
    fi
    exit 2
  fi

  success "Pre-migration checks passed"
  echo ""
}

#-----------------------------------------------------------------------------
# Backup Phase
#-----------------------------------------------------------------------------

create_backup() {
  section "Backup Phase"

  if [[ "${SKIP_BACKUP}" == "true" ]]; then
    warning "Skipping backup (--skip-backup)"
    echo ""
    return
  fi

  log "Creating backup at: ${BACKUP_DIR}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY RUN] Would create backup at: ${BACKUP_DIR}"
    return
  fi

  # Create backup directory
  mkdir -p "${BACKUP_DIR}"

  # Backup entire aiteamforge directory
  log "Backing up aiteamforge directory..."
  cp -R "${OLD_INSTALL_DIR}" "${BACKUP_DIR}/aiteamforge"

  # Backup LaunchAgents
  log "Backing up LaunchAgents..."
  mkdir -p "${BACKUP_DIR}/LaunchAgents"
  for agent in com.aiteamforge.*.plist; do
    if [[ -f "${HOME}/Library/LaunchAgents/${agent}" ]]; then
      cp "${HOME}/Library/LaunchAgents/${agent}" "${BACKUP_DIR}/LaunchAgents/"
    fi
  done

  # Backup shell configs
  log "Backing up shell configs..."
  if [[ -f "${HOME}/.zshrc" ]]; then
    cp "${HOME}/.zshrc" "${BACKUP_DIR}/.zshrc"
  fi

  # Verify backup integrity
  log "Verifying backup..."
  ORIGINAL_COUNT=$(find "${OLD_INSTALL_DIR}" -type f | wc -l | tr -d ' ')
  BACKUP_COUNT=$(find "${BACKUP_DIR}/aiteamforge" -type f | wc -l | tr -d ' ')

  if [[ "${ORIGINAL_COUNT}" -ne "${BACKUP_COUNT}" ]]; then
    error "Backup verification failed"
    echo "Original files: ${ORIGINAL_COUNT}"
    echo "Backup files: ${BACKUP_COUNT}"
    exit 1
  fi

  BACKUP_SIZE=$(du -sh "${BACKUP_DIR}" | cut -f1)
  success "Backup created successfully (${BACKUP_SIZE})"
  echo "  Location: ${BACKUP_DIR}"
  echo ""
}

#-----------------------------------------------------------------------------
# Migration Phase
#-----------------------------------------------------------------------------

migrate_user_data() {
  section "Migrating User Data"

  # Create new data directory
  mkdir -p "${NEW_DATA_DIR}"

  # Kanban data (CRITICAL)
  if [[ -d "${OLD_INSTALL_DIR}/kanban" ]]; then
    log "Migrating kanban data..."
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "[DRY RUN] Would migrate: kanban/ -> ${NEW_DATA_DIR}/kanban/"
    else
      mkdir -p "${NEW_DATA_DIR}/kanban"
      cp -R "${OLD_INSTALL_DIR}/kanban"/* "${NEW_DATA_DIR}/kanban/" 2>/dev/null || true
      success "Kanban data migrated"
    fi
  fi

  # Kanban backups
  if [[ -d "${OLD_INSTALL_DIR}/kanban-backups" ]]; then
    log "Migrating kanban backups..."
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "[DRY RUN] Would migrate: kanban-backups/ -> ${NEW_DATA_DIR}/kanban-backups/"
    else
      cp -R "${OLD_INSTALL_DIR}/kanban-backups" "${NEW_DATA_DIR}/" 2>/dev/null || true
      success "Kanban backups migrated"
    fi
  fi

  # Configuration files
  if [[ -d "${OLD_INSTALL_DIR}/config" ]]; then
    log "Migrating configuration..."
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "[DRY RUN] Would migrate: config/ -> ${NEW_DATA_DIR}/config/"
    else
      mkdir -p "${NEW_DATA_DIR}/config"
      # Only copy user-created configs, not templates
      [[ -f "${OLD_INSTALL_DIR}/config/secrets.env" ]] && cp "${OLD_INSTALL_DIR}/config/secrets.env" "${NEW_DATA_DIR}/config/"
      [[ -f "${OLD_INSTALL_DIR}/config/machine.json" ]] && cp "${OLD_INSTALL_DIR}/config/machine.json" "${NEW_DATA_DIR}/config/"
      [[ -f "${OLD_INSTALL_DIR}/config/teams.json" ]] && cp "${OLD_INSTALL_DIR}/config/teams.json" "${NEW_DATA_DIR}/config/"
      [[ -f "${OLD_INSTALL_DIR}/config/remote-hosts.json" ]] && cp "${OLD_INSTALL_DIR}/config/remote-hosts.json" "${NEW_DATA_DIR}/config/"
      [[ -f "${OLD_INSTALL_DIR}/config/fleet-config.json" ]] && cp "${OLD_INSTALL_DIR}/config/fleet-config.json" "${NEW_DATA_DIR}/config/"
      success "Configuration migrated"
    fi
  fi

  # Claude agent configurations
  if [[ -d "${OLD_INSTALL_DIR}/claude" ]]; then
    log "Migrating Claude agent configs..."
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "[DRY RUN] Would migrate: claude/ -> ${NEW_DATA_DIR}/claude/"
    else
      mkdir -p "${NEW_DATA_DIR}/claude"
      cp -R "${OLD_INSTALL_DIR}/claude"/* "${NEW_DATA_DIR}/claude/" 2>/dev/null || true
      success "Claude configs migrated"
    fi
  fi

  # Team data directories
  log "Migrating team data..."
  TEAMS=("academy" "android" "command" "dns-framework" "firebase" "freelance" "ios" "legal" "mainevent" "medical")
  for team in "${TEAMS[@]}"; do
    if [[ -d "${OLD_INSTALL_DIR}/${team}" ]]; then
      if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[DRY RUN] Would migrate: ${team}/ -> ${NEW_DATA_DIR}/teams/${team}/"
      else
        mkdir -p "${NEW_DATA_DIR}/teams/${team}"
        cp -R "${OLD_INSTALL_DIR}/${team}"/* "${NEW_DATA_DIR}/teams/${team}/" 2>/dev/null || true
      fi
    fi
  done

  if [[ "${DRY_RUN}" != "true" ]]; then
    success "Team data migrated"
  fi

  # Fleet Monitor data
  if [[ -d "${OLD_INSTALL_DIR}/fleet-monitor/data" ]]; then
    log "Migrating Fleet Monitor data..."
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "[DRY RUN] Would migrate: fleet-monitor/data/ -> ${NEW_DATA_DIR}/fleet-monitor/"
    else
      mkdir -p "${NEW_DATA_DIR}/fleet-monitor"
      cp -R "${OLD_INSTALL_DIR}/fleet-monitor/data" "${NEW_DATA_DIR}/fleet-monitor/" 2>/dev/null || true
      success "Fleet Monitor data migrated"
    fi
  fi

  echo ""
}

update_launchagents() {
  section "Updating LaunchAgents"

  LAUNCHAGENT_DIR="${HOME}/Library/LaunchAgents"
  AGENTS_UPDATED=0

  EXPECTED_AGENTS=(
    "com.aiteamforge.kanban-backup.plist"
    "com.aiteamforge.lcars-health.plist"
    "com.aiteamforge.fleet-monitor.plist"
  )

  for agent in "${EXPECTED_AGENTS[@]}"; do
    AGENT_PATH="${LAUNCHAGENT_DIR}/${agent}"

    if [[ -f "${AGENT_PATH}" ]]; then
      log "Updating ${agent}..."

      if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[DRY RUN] Would update paths in: ${agent}"
        continue
      fi

      # Unload first
      launchctl unload "${AGENT_PATH}" 2>/dev/null || true

      # Update paths in plist
      sed -i.bak "s|${HOME}/aiteamforge|${NEW_DATA_DIR}|g" "${AGENT_PATH}"

      # Also update to use new framework location
      sed -i.bak2 "s|${HOME}/aiteamforge/|/opt/homebrew/opt/aiteamforge/libexec/|g" "${AGENT_PATH}"

      # Reload
      launchctl load "${AGENT_PATH}" 2>/dev/null || true

      AGENTS_UPDATED=$((AGENTS_UPDATED + 1))
    fi
  done

  if [[ "${DRY_RUN}" != "true" ]]; then
    if [[ "${AGENTS_UPDATED}" -gt 0 ]]; then
      success "LaunchAgents updated: ${AGENTS_UPDATED}"
    else
      info "No LaunchAgents to update"
    fi
  fi

  echo ""
}

update_shell_integration() {
  section "Updating Shell Integration"

  ZSHRC="${HOME}/.zshrc"

  if [[ ! -f "${ZSHRC}" ]]; then
    info "No ~/.zshrc found (nothing to update)"
    echo ""
    return
  fi

  # Check if aiteamforge is sourced
  if ! grep -q "aiteamforge" "${ZSHRC}"; then
    info "No aiteamforge references in ~/.zshrc"
    echo ""
    return
  fi

  log "Updating ~/.zshrc..."

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY RUN] Would update sourcing pattern in ~/.zshrc"
    echo ""
    return
  fi

  # Backup
  cp "${ZSHRC}" "${ZSHRC}.pre-migration"

  # Replace old sourcing pattern with new
  # Old: source ~/aiteamforge/kanban-helpers.sh
  # New: source ~/.aiteamforge/shell-init.sh (which sources everything)

  # Comment out old sources
  sed -i.bak "s|^source ~/aiteamforge/|# [MIGRATED] source ~/aiteamforge/|g" "${ZSHRC}"
  sed -i.bak2 "s|^source \${HOME}/aiteamforge/|# [MIGRATED] source \${HOME}/aiteamforge/|g" "${ZSHRC}"

  # Add new sourcing line (if not already present)
  if ! grep -q "source ~/.aiteamforge/shell-init.sh" "${ZSHRC}"; then
    echo "" >> "${ZSHRC}"
    echo "# AITeamForge Shell Integration (Homebrew)" >> "${ZSHRC}"
    echo "if [[ -f ~/.aiteamforge/shell-init.sh ]]; then" >> "${ZSHRC}"
    echo "  source ~/.aiteamforge/shell-init.sh" >> "${ZSHRC}"
    echo "fi" >> "${ZSHRC}"
  fi

  success "Shell integration updated"
  echo "  Backup: ${ZSHRC}.pre-migration"
  echo ""
}

create_migration_marker() {
  section "Finalizing Migration"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY RUN] Would create migration marker"
    return
  fi

  # Create migration marker file
  cat > "${NEW_DATA_DIR}/MIGRATED" <<EOF
This installation was migrated from a manual installation to Homebrew-managed.

Migration Date: $(date)
Source: ${OLD_INSTALL_DIR}
Destination: ${NEW_DATA_DIR}
Backup: ${BACKUP_DIR}
Migration Version: ${VERSION}

DO NOT DELETE THIS FILE - it indicates successful migration.
EOF

  # Save migration state
  cat > "${MIGRATION_STATE_FILE}" <<EOF
{
  "migrated": true,
  "migration_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source": "${OLD_INSTALL_DIR}",
  "destination": "${NEW_DATA_DIR}",
  "backup": "${BACKUP_DIR}",
  "version": "${VERSION}"
}
EOF

  success "Migration marker created"
  echo ""
}

#-----------------------------------------------------------------------------
# Validation Phase
#-----------------------------------------------------------------------------

validate_migration() {
  section "Validation Phase"

  if [[ "${SKIP_VALIDATION}" == "true" ]]; then
    warning "Skipping validation (--skip-validation)"
    echo ""
    return
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY RUN] Would run aiteamforge doctor for validation"
    return
  fi

  log "Running aiteamforge doctor..."
  echo ""

  if "${SCRIPT_DIR}/aiteamforge-doctor.sh"; then
    success "Validation passed"
  else
    warning "Validation found issues (see above)"
    echo ""
    echo "This doesn't necessarily mean migration failed."
    echo "Some issues may require manual configuration."
  fi

  echo ""
}

#-----------------------------------------------------------------------------
# Main Migration Flow
#-----------------------------------------------------------------------------

main() {
  # Handle rollback mode
  if [[ "${ROLLBACK_MODE}" == "true" ]]; then
    rollback_migration
    # Never returns
  fi

  # Show banner
  section "AITeamForge Migration to Homebrew"

  if [[ "${DRY_RUN}" == "true" ]]; then
    warning "DRY RUN MODE - No changes will be made"
    echo ""
  fi

  # Pre-migration checks
  run_pre_migration_checks

  # Show migration plan
  section "Migration Plan"
  echo "Source: ${OLD_INSTALL_DIR}"
  echo "Destination: ${NEW_DATA_DIR}"
  if [[ "${SKIP_BACKUP}" != "true" ]]; then
    echo "Backup: ${BACKUP_DIR}"
  fi
  echo ""

  # Confirm migration
  if [[ "${DRY_RUN}" != "true" ]] && [[ "${FORCE}" != "true" ]]; then
    echo "⚠️  This will migrate your aiteamforge installation"
    echo ""
    read -p "Continue with migration? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Migration cancelled"
      exit 0
    fi
    echo ""
  fi

  # Stop running services
  if [[ "${DRY_RUN}" != "true" ]]; then
    log "Stopping services..."
    pkill -f "lcars-ui/server.py" 2>/dev/null || true
    pkill -f "fleet-monitor/server" 2>/dev/null || true
    echo ""
  fi

  # Execute migration phases
  create_backup
  migrate_user_data
  update_launchagents
  update_shell_integration
  create_migration_marker
  validate_migration

  # Success
  section "Migration Complete!"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "Dry run completed. No changes were made."
    echo ""
    echo "To perform actual migration, run without --dry-run"
  else
    success "Your aiteamforge installation has been migrated successfully"
    echo ""
    echo "What was migrated:"
    echo "  ✓ Kanban boards and data → ${NEW_DATA_DIR}/kanban/"
    echo "  ✓ Configuration files → ${NEW_DATA_DIR}/config/"
    echo "  ✓ Claude agent configs → ${NEW_DATA_DIR}/claude/"
    echo "  ✓ Team data → ${NEW_DATA_DIR}/teams/"
    echo "  ✓ LaunchAgents updated"
    echo "  ✓ Shell integration updated"
    echo ""
    echo "What was backed up:"
    echo "  📦 Full backup at: ${BACKUP_DIR}"
    echo ""
    echo "What's next:"
    echo "  1. Restart your terminal (new shell integration)"
    echo "  2. Run: aiteamforge doctor (verify everything works)"
    echo "  3. Run: aiteamforge start (start services)"
    echo ""
    echo "Your original installation is still at:"
    echo "  ${OLD_INSTALL_DIR}"
    echo ""
    echo "⚠️  DO NOT delete it until you've verified everything works!"
    echo "After verification, you can safely remove it manually."
    echo ""
    echo "If anything goes wrong, you can rollback:"
    echo "  aiteamforge migrate --rollback"
    echo ""
  fi
}

# Execute
main
