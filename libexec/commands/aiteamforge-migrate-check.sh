#!/bin/bash
# aiteamforge-migrate-check.sh
# Pre-migration analysis and safety check for existing aiteamforge installations
# Scans current installation, identifies components, and assesses migration readiness

set -eo pipefail

# Get framework location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBEXEC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source shared libraries
source "${LIBEXEC_DIR}/lib/common.sh"
source "${LIBEXEC_DIR}/lib/config.sh"

VERSION="1.3.0"

# Default values
INSTALL_DIR="${HOME}/aiteamforge"
VERBOSE=false

# Counters
TOTAL_ITEMS=0
CRITICAL_ITEMS=0
WARNING_ITEMS=0
INFO_ITEMS=0

# Usage
usage() {
  cat <<EOF
AITeamForge Migration Check v${VERSION}
Pre-migration analysis for existing installations

Usage: aiteamforge migrate --check [options]

Options:
  --dir <path>        Path to existing aiteamforge installation (default: ~/aiteamforge)
  --verbose           Show detailed analysis
  -v, --version       Show version
  -h, --help          Show this help

Exit Codes:
  0    Safe to migrate
  1    Issues found (review required)
  2    Not recommended (critical issues)
  3    Invalid installation or not found
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=true
      shift
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

# Expand path (safe tilde expansion)
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"

# Check if installation exists
if [[ ! -d "${INSTALL_DIR}" ]]; then
  error "No aiteamforge installation found at: ${INSTALL_DIR}"
  echo ""
  echo "If your installation is in a different location, use: --dir <path>"
  exit 3
fi

section "AITeamForge Migration Check"
echo "Analyzing installation at: ${INSTALL_DIR}"
echo ""

# Analysis results storage
declare -A COMPONENTS
declare -A ISSUES
declare -A RECOMMENDATIONS

#-----------------------------------------------------------------------------
# Analysis Functions
#-----------------------------------------------------------------------------

analyze_git_repo() {
  section "Git Repository Analysis"

  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    success "Git repository detected"

    # Check for uncommitted changes
    cd "${INSTALL_DIR}"
    if ! git diff-index --quiet HEAD 2>/dev/null; then
      WARNING_ITEMS=$((WARNING_ITEMS + 1))
      warning "Uncommitted changes detected"
      ISSUES["git_uncommitted"]="true"

      if [[ "${VERBOSE}" == "true" ]]; then
        echo "  Modified files:"
        git status --short | sed 's/^/    /'
      fi
    else
      info "No uncommitted changes"
    fi

    # Check current branch
    CURRENT_BRANCH=$(git branch --show-current)
    info "Current branch: ${CURRENT_BRANCH}"

    # Check for worktrees
    WORKTREE_COUNT=$(git worktree list 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${WORKTREE_COUNT}" -gt 1 ]]; then
      INFO_ITEMS=$((INFO_ITEMS + 1))
      info "Git worktrees detected: ${WORKTREE_COUNT}"
      COMPONENTS["worktrees"]="${WORKTREE_COUNT}"

      if [[ "${VERBOSE}" == "true" ]]; then
        echo "  Worktrees:"
        git worktree list | sed 's/^/    /'
      fi
    fi

    COMPONENTS["git_repo"]="true"
  else
    WARNING_ITEMS=$((WARNING_ITEMS + 1))
    warning "Not a git repository (this is unusual)"
    COMPONENTS["git_repo"]="false"
  fi

  echo ""
}

analyze_kanban_data() {
  section "Kanban Data Analysis"

  KANBAN_DIR="${INSTALL_DIR}/kanban"

  if [[ ! -d "${KANBAN_DIR}" ]]; then
    warning "No kanban directory found"
    COMPONENTS["kanban"]="false"
    echo ""
    return
  fi

  # Count board files
  BOARD_COUNT=$(find "${KANBAN_DIR}" -maxdepth 1 -name "*-board.json" 2>/dev/null | wc -l | tr -d ' ')
  PLAN_COUNT=$(find "${KANBAN_DIR}" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')

  if [[ "${BOARD_COUNT}" -eq 0 ]]; then
    warning "No kanban boards found"
    COMPONENTS["kanban"]="false"
  else
    success "Kanban boards found: ${BOARD_COUNT}"
    success "Plan documents found: ${PLAN_COUNT}"
    COMPONENTS["kanban_boards"]="${BOARD_COUNT}"
    COMPONENTS["kanban_plans"]="${PLAN_COUNT}"
    CRITICAL_ITEMS=$((CRITICAL_ITEMS + BOARD_COUNT + PLAN_COUNT))

    if [[ "${VERBOSE}" == "true" ]]; then
      echo "  Boards:"
      find "${KANBAN_DIR}" -maxdepth 1 -name "*-board.json" -exec basename {} \; | sed 's/^/    /'
    fi
  fi

  # Check for kanban backups
  BACKUP_DIR="${INSTALL_DIR}/kanban-backups"
  if [[ -d "${BACKUP_DIR}" ]]; then
    BACKUP_COUNT=$(find "${BACKUP_DIR}" -type f -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${BACKUP_COUNT}" -gt 0 ]]; then
      info "Kanban backups found: ${BACKUP_COUNT}"
      COMPONENTS["kanban_backups"]="${BACKUP_COUNT}"
    fi
  fi

  # Estimate data size
  KANBAN_SIZE=$(du -sh "${KANBAN_DIR}" 2>/dev/null | cut -f1)
  info "Kanban data size: ${KANBAN_SIZE}"

  echo ""
}

analyze_configuration() {
  section "Configuration Analysis"

  # Check for secrets.env
  if [[ -f "${INSTALL_DIR}/config/secrets.env" ]]; then
    CRITICAL_ITEMS=$((CRITICAL_ITEMS + 1))
    success "secrets.env found (will be preserved)"
    COMPONENTS["secrets"]="true"
  else
    info "No secrets.env (this is okay)"
    COMPONENTS["secrets"]="false"
  fi

  # Check for machine.json
  if [[ -f "${INSTALL_DIR}/config/machine.json" ]]; then
    CRITICAL_ITEMS=$((CRITICAL_ITEMS + 1))
    success "machine.json found (will be preserved)"
    COMPONENTS["machine_config"]="true"
  else
    warning "No machine.json (will need to configure after migration)"
    COMPONENTS["machine_config"]="false"
  fi

  # Check for teams.json
  if [[ -f "${INSTALL_DIR}/config/teams.json" ]]; then
    CRITICAL_ITEMS=$((CRITICAL_ITEMS + 1))
    success "teams.json found (will be preserved)"
    COMPONENTS["teams_config"]="true"
  else
    warning "No teams.json (will need to configure after migration)"
    COMPONENTS["teams_config"]="false"
  fi

  # Check for remote-hosts.json
  if [[ -f "${INSTALL_DIR}/config/remote-hosts.json" ]]; then
    INFO_ITEMS=$((INFO_ITEMS + 1))
    info "remote-hosts.json found (will be preserved)"
    COMPONENTS["remote_hosts"]="true"
  fi

  echo ""
}

analyze_claude_agents() {
  section "Claude Code Agent Analysis"

  CLAUDE_DIR="${INSTALL_DIR}/claude"

  if [[ ! -d "${CLAUDE_DIR}" ]]; then
    warning "No claude directory found"
    COMPONENTS["claude_agents"]="false"
    echo ""
    return
  fi

  # Check for settings.json
  if [[ -f "${CLAUDE_DIR}/settings.json" ]]; then
    CRITICAL_ITEMS=$((CRITICAL_ITEMS + 1))
    success "Claude settings.json found (will be preserved)"
    COMPONENTS["claude_settings"]="true"
  else
    warning "No Claude settings.json"
    COMPONENTS["claude_settings"]="false"
  fi

  # Count agent directories
  AGENT_COUNT=0
  if [[ -d "${CLAUDE_DIR}/agents" ]]; then
    AGENT_COUNT=$(find "${CLAUDE_DIR}/agents" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${AGENT_COUNT}" -gt 0 ]]; then
      success "Agent configurations found: ${AGENT_COUNT}"
      COMPONENTS["agent_count"]="${AGENT_COUNT}"
      CRITICAL_ITEMS=$((CRITICAL_ITEMS + AGENT_COUNT))

      if [[ "${VERBOSE}" == "true" ]]; then
        echo "  Agents:"
        find "${CLAUDE_DIR}/agents" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sed 's/^/    /'
      fi
    fi
  fi

  echo ""
}

analyze_teams() {
  section "Team Directories Analysis"

  # Known team directories
  TEAMS=("academy" "android" "command" "dns-framework" "firebase" "freelance" "ios" "legal" "mainevent" "medical")
  FOUND_TEAMS=0

  for team in "${TEAMS[@]}"; do
    if [[ -d "${INSTALL_DIR}/${team}" ]]; then
      FOUND_TEAMS=$((FOUND_TEAMS + 1))

      # Check for personas
      PERSONA_COUNT=0
      if [[ -d "${INSTALL_DIR}/${team}/personas" ]]; then
        PERSONA_COUNT=$(find "${INSTALL_DIR}/${team}/personas" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
      fi

      if [[ "${PERSONA_COUNT}" -gt 0 ]]; then
        info "${team}: ${PERSONA_COUNT} personas"
      else
        info "${team}: directory exists"
      fi
    fi
  done

  if [[ "${FOUND_TEAMS}" -gt 0 ]]; then
    success "Team directories found: ${FOUND_TEAMS}"
    COMPONENTS["team_count"]="${FOUND_TEAMS}"
  else
    warning "No team directories found"
  fi

  echo ""
}

analyze_services() {
  section "Service Analysis"

  # Check for LCARS
  if [[ -d "${INSTALL_DIR}/lcars-ui" ]]; then
    success "LCARS UI found"
    COMPONENTS["lcars"]="true"

    # Check if LCARS is running
    if curl -s http://localhost:8082 >/dev/null 2>&1; then
      info "LCARS is currently running"
      COMPONENTS["lcars_running"]="true"
    fi
  fi

  # Check for Fleet Monitor
  if [[ -d "${INSTALL_DIR}/fleet-monitor" ]]; then
    success "Fleet Monitor found"
    COMPONENTS["fleet_monitor"]="true"

    # Check for Fleet Monitor data
    if [[ -d "${INSTALL_DIR}/fleet-monitor/data" ]]; then
      FLEET_SIZE=$(du -sh "${INSTALL_DIR}/fleet-monitor/data" 2>/dev/null | cut -f1)
      info "Fleet Monitor data: ${FLEET_SIZE}"
    fi
  fi

  echo ""
}

analyze_launchagents() {
  section "LaunchAgent Analysis"

  LAUNCHAGENT_DIR="${HOME}/Library/LaunchAgents"
  FOUND_AGENTS=0

  EXPECTED_AGENTS=(
    "com.aiteamforge.kanban-backup.plist"
    "com.aiteamforge.lcars-health.plist"
    "com.aiteamforge.fleet-monitor.plist"
  )

  for agent in "${EXPECTED_AGENTS[@]}"; do
    if [[ -f "${LAUNCHAGENT_DIR}/${agent}" ]]; then
      FOUND_AGENTS=$((FOUND_AGENTS + 1))

      # Check if it's running
      if launchctl list | grep -q "${agent%.plist}"; then
        info "${agent}: installed and running"
      else
        warning "${agent}: installed but not running"
      fi
    fi
  done

  if [[ "${FOUND_AGENTS}" -gt 0 ]]; then
    success "LaunchAgents found: ${FOUND_AGENTS}"
    COMPONENTS["launchagents"]="${FOUND_AGENTS}"
  else
    info "No LaunchAgents found (this is okay)"
  fi

  echo ""
}

analyze_shell_integration() {
  section "Shell Integration Analysis"

  # Check for zshrc modifications
  if [[ -f "${HOME}/.zshrc" ]]; then
    if grep -q "aiteamforge" "${HOME}/.zshrc" 2>/dev/null; then
      success "Shell integration detected in ~/.zshrc"
      COMPONENTS["shell_integration"]="true"

      if [[ "${VERBOSE}" == "true" ]]; then
        echo "  Lines referencing aiteamforge:"
        grep -n "aiteamforge" "${HOME}/.zshrc" | sed 's/^/    /'
      fi
    else
      warning "No aiteamforge references in ~/.zshrc"
    fi
  fi

  # Check for team-specific zshrc files
  ZSHRC_COUNT=$(find "${INSTALL_DIR}/home-scripts" -name ".zshrc_*" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${ZSHRC_COUNT}" -gt 0 ]]; then
    info "Team-specific zshrc files: ${ZSHRC_COUNT}"
    COMPONENTS["zshrc_files"]="${ZSHRC_COUNT}"
  fi

  echo ""
}

analyze_disk_space() {
  section "Disk Space Analysis"

  # Calculate total size
  TOTAL_SIZE=$(du -sh "${INSTALL_DIR}" 2>/dev/null | cut -f1)
  success "Current installation size: ${TOTAL_SIZE}"

  # Calculate available space
  AVAILABLE_SPACE=$(df -h "${HOME}" | tail -1 | awk '{print $4}')
  info "Available disk space: ${AVAILABLE_SPACE}"

  # Estimate migration backup size (same as installation)
  echo ""
  info "Migration backup will require: ${TOTAL_SIZE}"
  info "Total space needed (installation + backup): ~$(echo "${TOTAL_SIZE}" | awk '{print $1*2}') (estimate)"

  echo ""
}

calculate_risk_score() {
  section "Migration Risk Assessment"

  RISK_SCORE=0
  RISK_FACTORS=()

  # Critical data presence (GOOD - lower risk)
  if [[ "${COMPONENTS[kanban_boards]:-0}" -gt 0 ]]; then
    RISK_FACTORS+=("✓ Kanban data detected (will be backed up)")
  else
    RISK_SCORE=$((RISK_SCORE + 5))
    RISK_FACTORS+=("⚠ No kanban data (less to lose, but unusual)")
  fi

  # Git repository (GOOD - can recover)
  if [[ "${COMPONENTS[git_repo]}" == "true" ]]; then
    RISK_FACTORS+=("✓ Git repository (can recover from git history)")
  else
    RISK_SCORE=$((RISK_SCORE + 10))
    RISK_FACTORS+=("⚠ Not a git repository (harder to recover)")
  fi

  # Uncommitted changes (BAD - could be lost)
  if [[ "${ISSUES[git_uncommitted]}" == "true" ]]; then
    RISK_SCORE=$((RISK_SCORE + 15))
    RISK_FACTORS+=("⚠ Uncommitted changes (should commit first)")
  else
    RISK_FACTORS+=("✓ No uncommitted changes")
  fi

  # Running services (NEUTRAL - just need to stop)
  if [[ "${COMPONENTS[lcars_running]}" == "true" ]]; then
    RISK_SCORE=$((RISK_SCORE + 2))
    RISK_FACTORS+=("⚠ LCARS is running (will need to stop)")
  fi

  # Worktrees (NEUTRAL - just need to handle)
  if [[ "${COMPONENTS[worktrees]:-0}" -gt 1 ]]; then
    RISK_SCORE=$((RISK_SCORE + 5))
    RISK_FACTORS+=("⚠ Git worktrees detected (need special handling)")
  fi

  # Configuration files missing (BAD - need manual setup after)
  if [[ "${COMPONENTS[machine_config]}" != "true" ]]; then
    RISK_SCORE=$((RISK_SCORE + 5))
    RISK_FACTORS+=("⚠ No machine.json (will need manual configuration)")
  fi

  # Print risk factors
  for factor in "${RISK_FACTORS[@]}"; do
    echo "  ${factor}"
  done

  echo ""

  # Risk level determination
  if [[ "${RISK_SCORE}" -le 10 ]]; then
    success "Risk Level: LOW (${RISK_SCORE} points)"
    echo "  Migration should be safe. Proceed with confidence."
    RECOMMENDATION="SAFE"
  elif [[ "${RISK_SCORE}" -le 25 ]]; then
    warning "Risk Level: MEDIUM (${RISK_SCORE} points)"
    echo "  Review the warnings above before proceeding."
    RECOMMENDATION="REVIEW"
  else
    error "Risk Level: HIGH (${RISK_SCORE} points)"
    echo "  Address critical issues before migrating."
    RECOMMENDATION="FIX_ISSUES"
  fi

  echo ""
}

estimate_migration_time() {
  section "Migration Time Estimate"

  # Base time
  MINUTES=5

  # Add time for kanban data
  if [[ "${COMPONENTS[kanban_boards]:-0}" -gt 0 ]]; then
    MINUTES=$((MINUTES + 2))
  fi

  # Add time for agent configurations
  if [[ "${COMPONENTS[agent_count]:-0}" -gt 0 ]]; then
    MINUTES=$((MINUTES + COMPONENTS[agent_count]))
  fi

  # Add time for worktrees
  if [[ "${COMPONENTS[worktrees]:-0}" -gt 1 ]]; then
    MINUTES=$((MINUTES + COMPONENTS[worktrees]))
  fi

  info "Estimated migration time: ${MINUTES} minutes"
  info "Includes: backup, migration, validation"

  echo ""
}

#-----------------------------------------------------------------------------
# Run Analysis
#-----------------------------------------------------------------------------

analyze_git_repo
analyze_kanban_data
analyze_configuration
analyze_claude_agents
analyze_teams
analyze_services
analyze_launchagents
analyze_shell_integration
analyze_disk_space
calculate_risk_score
estimate_migration_time

#-----------------------------------------------------------------------------
# Final Recommendation
#-----------------------------------------------------------------------------

section "Migration Recommendation"

echo "Summary:"
echo "  Critical items to preserve: ${CRITICAL_ITEMS}"
echo "  Warnings: ${WARNING_ITEMS}"
echo "  Informational: ${INFO_ITEMS}"
echo ""

case "${RECOMMENDATION}" in
  SAFE)
    success "✓ SAFE TO MIGRATE"
    echo ""
    echo "Your installation is ready for migration."
    echo ""
    echo "Next steps:"
    echo "  1. Review the analysis above"
    echo "  2. Run: aiteamforge migrate"
    echo "  3. Follow the interactive migration process"
    echo ""
    exit 0
    ;;
  REVIEW)
    warning "⚠ REVIEW RECOMMENDED"
    echo ""
    echo "Your installation can be migrated, but review the warnings above first."
    echo ""
    echo "Recommended actions:"
    if [[ "${ISSUES[git_uncommitted]}" == "true" ]]; then
      echo "  • Commit or stash uncommitted git changes"
    fi
    if [[ "${COMPONENTS[machine_config]}" != "true" ]]; then
      echo "  • Note that you'll need to reconfigure machine.json after migration"
    fi
    echo ""
    echo "When ready, run: aiteamforge migrate"
    echo ""
    exit 1
    ;;
  FIX_ISSUES)
    error "⚠ NOT RECOMMENDED"
    echo ""
    echo "Critical issues detected. Fix these before migrating:"
    echo ""
    if [[ "${ISSUES[git_uncommitted]}" == "true" ]]; then
      echo "  • Commit uncommitted changes: cd ${INSTALL_DIR} && git add -A && git commit"
    fi
    if [[ "${COMPONENTS[git_repo]}" != "true" ]]; then
      echo "  • Initialize git: cd ${INSTALL_DIR} && git init && git add -A && git commit -m 'Initial commit before migration'"
    fi
    echo ""
    echo "After fixing, run this check again: aiteamforge migrate --check"
    echo ""
    exit 2
    ;;
esac
