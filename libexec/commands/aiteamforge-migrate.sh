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
source "${LIBEXEC_DIR}/lib/constants.sh"

# Source org identity resolver (XACA-0139) — graceful no-op if lib not yet installed
# shellcheck source=../lib/aiteamforge-org-paths.sh
source "${LIBEXEC_DIR}/lib/aiteamforge-org-paths.sh" 2>/dev/null || true

# Version — read from VERSION file (single source of truth)
_find_version() { for p in "${LIBEXEC_DIR}/../VERSION" "${LIBEXEC_DIR}/../../VERSION"; do [ -f "$p" ] && cat "$p" | tr -d '[:space:]' && return; done; echo "unknown"; }
VERSION="$(_find_version)"

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

# NOTE: FLEET_MONITOR_PORT default mirrors install-fleet-monitor.sh:15. If
# you change one, change the other. Sibling-drift consolidation is a pending
# follow-up (mirrors the pattern XACA-0516 fixed for KANBAN_BACKUP_INTERVAL).
readonly XACA_0512_FLEET_MONITOR_PORT_DEFAULT=3000

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
  # Core team slugs — the baseline set installed by the framework.
  # xaca-0139:allowed — "mainevent" is a legacy detection slug for backward-compat migration; not user-facing org branding
  # "mainevent" is kept here as a LEGACY DETECTION slug for existing Main Event
  # installs pre-XACA-0139.  New installs that enable the main-event plugin will
  # have the same slug; the loop below handles both cases without duplication.
  TEAMS=("academy" "android" "command" "dns-framework" "firebase" "freelance" "ios" "legal" "mainevent" "medical") # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
  # Dynamically append any org-specific team directories reported by the
  # org resolver.  This gives non-Main-Event orgs first-class migration support
  # without hardcoding their team slugs here.
  if command -v _aiteamforge_org_slug >/dev/null 2>&1; then
    _org_slug="$(_aiteamforge_org_slug 2>/dev/null || echo "")"
    if [ -n "$_org_slug" ] && [ "$_org_slug" != "example-org" ]; then
      # Add org-slug as a potential team dir if it's not already in the list
      _already_listed=false
      for _t in "${TEAMS[@]}"; do
        [ "$_t" = "$_org_slug" ] && _already_listed=true && break
      done
      [ "$_already_listed" = "false" ] && TEAMS+=("$_org_slug")
      unset _already_listed
    fi
    unset _org_slug
  fi
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

# Cleanup helper invoked by update_launchagents' RETURN trap.
# Removes any *.new tempfiles that survived an interrupt or early return.
# _migrate_tmpfiles is populated by update_launchagents before each render.
_migrate_tmpfiles=()
# shellcheck disable=SC2329  # called indirectly via trap; not a dead function
_cleanup_migrate_tmpfiles() {
  local f
  for f in "${_migrate_tmpfiles[@]}"; do
    rm -f "$f"
  done
}

# Render a kanban-family LaunchAgent template to a tempfile.
# Substitution map matches install-kanban.sh:771-775 + the XACA-0510
# extension (PYTHON3_PATH) so every kanban template gets every substitution.
# Usage: _render_kanban_template <template_path> <dest_path>
# Returns: 0 on success, 1 if template not found.
_render_kanban_template() {
  local template="$1"
  local dest="$2"

  if [ ! -f "$template" ]; then
    warning "LaunchAgent template not found: $template"
    return 1
  fi

  local kanban_backup_interval="${KANBAN_BACKUP_INTERVAL:-$KANBAN_BACKUP_INTERVAL_DEFAULT}"
  local python3_path
  # NOTE: PYTHON3_PATH is re-resolved on every migrate — PATH changes between
  # original install and migrate will re-pin the plist interpreter. See XACA-0510.
  python3_path="$(command -v python3 2>/dev/null || echo "/usr/bin/python3")"

  sed -e "s|{{USER_HOME}}|$HOME|g" \
      -e "s|{{AITEAMFORGE_DIR}}|${NEW_DATA_DIR}|g" \
      -e "s|{{BACKUP_INTERVAL}}|${kanban_backup_interval}|g" \
      -e "s|{{PYTHON3_PATH}}|${python3_path}|g" \
      "$template" > "$dest"
}

# Render the fleet-monitor LaunchAgent template to a tempfile.
# Substitution map mirrors install-fleet-monitor.sh:569-577.
# Usage: _render_fleet_template <template_path> <dest_path>
# Returns: 0 on success, 1 if template not found or node missing.
_render_fleet_template() {
  local template="$1"
  local dest="$2"

  if [ ! -f "$template" ]; then
    warning "LaunchAgent template not found: $template"
    return 1
  fi

  local node_path
  if command -v node >/dev/null 2>&1; then
    node_path="$(command -v node)"
  elif [ -x "/opt/homebrew/bin/node" ]; then
    node_path="/opt/homebrew/bin/node"
  else
    warning "Node.js not found — skipping fleet-monitor LaunchAgent render"
    return 1
  fi

  local fleet_port="${FLEET_MONITOR_PORT:-$XACA_0512_FLEET_MONITOR_PORT_DEFAULT}"
  local homebrew_prefix
  homebrew_prefix="$(brew --prefix 2>/dev/null || echo '/opt/homebrew')"

  sed -e "s|{{NODE_PATH}}|${node_path}|g" \
      -e "s|{{FLEET_SERVER_PATH}}|${NEW_DATA_DIR}/fleet-monitor/server|g" \
      -e "s|{{LOG_DIR}}|${NEW_DATA_DIR}/logs|g" \
      -e "s|{{HOMEBREW_PREFIX}}|${homebrew_prefix}|g" \
      -e "s|{{HOME_DIR}}|$HOME|g" \
      -e "s|{{FLEET_PORT}}|${fleet_port}|g" \
      -e "s|{{AITEAMFORGE_DIR}}|${NEW_DATA_DIR}|g" \
      "$template" > "$dest"
}

update_launchagents() {
  section "Updating LaunchAgents"

  # Resolve framework dir (where templates ship) lazily — get_framework_dir
  # is provided by lib/config.sh, sourced at script load.
  local framework_dir="${FRAMEWORK_DIR:-$(get_framework_dir)}"

  # Allow tests to inject a sandbox path instead of the real LaunchAgents dir.
  local launchagents_dir="${LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"

  # Pairs of "plist-filename|render-fn|template-relpath". The render function
  # selects which substitution map to apply — kanban vs fleet-monitor have
  # different placeholder sets and cannot share a single sed expression.
  local agents=(
    "com.aiteamforge.kanban-backup.plist|_render_kanban_template|share/templates/kanban/backup-plist.template"
    "com.aiteamforge.lcars-health.plist|_render_kanban_template|share/templates/kanban/lcars-health-plist.template"
    "com.aiteamforge.fleet-monitor.plist|_render_fleet_template|share/templates/fleet-monitor/fleet-launchagent.template.plist"
  )

  local agents_updated=0
  # Reset module-level tempfile tracker; RETURN trap cleans up any survivors.
  _migrate_tmpfiles=()
  trap '_cleanup_migrate_tmpfiles' RETURN

  for entry in "${agents[@]}"; do
    local agent="${entry%%|*}"
    local rest="${entry#*|}"
    local render_fn="${rest%%|*}"
    local tmpl_relpath="${rest#*|}"
    local template="${framework_dir}/${tmpl_relpath}"
    local target="${launchagents_dir}/${agent}"
    local tmpfile="${target}.new"
    _migrate_tmpfiles+=("$tmpfile")

    # Opt-in guard: only re-render agents the user already has installed.
    # Migrate must not silently materialise agents that weren't there.
    if [[ ! -f "${target}" ]]; then
      continue
    fi

    log "Rendering ${agent} from template..."

    # Dispatch to the per-agent render function. Failures (missing template,
    # missing node, etc.) are reported by the render fn and we move on.
    if ! "$render_fn" "$template" "$tmpfile"; then
      continue
    fi

    # Diff rendered output against live target. If unchanged, no-op.
    if ! diff -q "$tmpfile" "$target" >/dev/null 2>&1 || [[ "${FORCE}" == "true" ]]; then
      if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[DRY RUN] Would update: ${agent}"
        rm -f "$tmpfile"
        agents_updated=$((agents_updated + 1))
        continue
      fi

      # Unload current agent (ignore failure — may not be loaded)
      launchctl unload "${target}" 2>/dev/null || true

      # Atomically replace with rendered version
      mv "$tmpfile" "${target}"

      # Reload agent (ignore failure — may need user session context)
      launchctl load "${target}" 2>/dev/null || true

      success "Updated ${agent}"
      agents_updated=$((agents_updated + 1))
    else
      # No change — clean up tempfile, count as no-op
      rm -f "$tmpfile"
    fi
  done

  if [[ "${agents_updated}" -eq 0 ]]; then
    success "All LaunchAgents up to date"
  elif [[ "${DRY_RUN}" == "true" ]]; then
    success "Would update ${agents_updated} LaunchAgent(s)"
  else
    success "LaunchAgents updated: ${agents_updated}"
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
