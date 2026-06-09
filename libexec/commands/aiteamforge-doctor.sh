#!/bin/bash
# aiteamforge-doctor.sh
# Comprehensive health check and diagnostics for aiteamforge installation
# Verifies dependencies, configuration, services, and system health

set -eo pipefail

# Get framework location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBEXEC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source shared libraries
source "${LIBEXEC_DIR}/lib/common.sh"
source "${LIBEXEC_DIR}/lib/config.sh"
source "${LIBEXEC_DIR}/lib/constants.sh"
# XACA-0650: resolve tap-owned venv Python (sets AITEAMFORGE_PYTHON)
# shellcheck source=../lib/python-env.sh
[ -f "${LIBEXEC_DIR}/lib/python-env.sh" ] && source "${LIBEXEC_DIR}/lib/python-env.sh" 2>/dev/null || true

# Version — read from VERSION file (single source of truth)
_find_version() { for p in "${LIBEXEC_DIR}/../VERSION" "${LIBEXEC_DIR}/../../VERSION"; do [ -f "$p" ] && cat "$p" | tr -d '[:space:]' && return; done; echo "unknown"; }
VERSION="$(_find_version)"

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

# Options
VERBOSE=false
FIX=false
CHECK_COMPONENT="all"

# Usage
usage() {
  cat <<EOF
AITeamForge Doctor v${VERSION}
Comprehensive health check and diagnostics

Usage: aiteamforge doctor [options]

Options:
  --verbose              Show detailed diagnostic information
  --fix                  Attempt to fix common issues
  --check <component>    Check specific component only
  -v, --version          Show version
  -h, --help             Show this help

Components:
  dependencies    External dependencies (brew, node, python, etc.)
  python-venv     Tap-owned Python venv and required packages (XACA-0650)
  framework       Framework installation integrity
  version-drift   Cellar vs working-dir version drift (XACA-0578)
  config          Configuration files and validity
  services        Running services (LCARS, Fleet Monitor)
  launchagents    LaunchAgent status
  git             Git repository health
  network         Network connectivity (Tailscale if configured)
  disk            Disk space for kanban backups
  all             Run all checks (default)

Examples:
  aiteamforge doctor                    # Run all health checks
  aiteamforge doctor --verbose          # Detailed diagnostics
  aiteamforge doctor --check services   # Check services only
  aiteamforge doctor --fix              # Auto-fix common issues

Exit Codes:
  0 - All checks passed
  1 - Warnings detected (system should work)
  2 - Failures detected (system may not work correctly)
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --verbose)
      VERBOSE=true
      shift
      ;;
    --fix)
      FIX=true
      shift
      ;;
    --check)
      CHECK_COMPONENT="$2"
      shift 2
      ;;
    -v|--version)
      echo "AITeamForge Doctor v${VERSION}"
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

# Check result tracker
check_result() {
  local status=$1
  local message=$2
  local detail="${3:-}"

  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

  case $status in
    pass)
      print_success "$message"
      PASSED_CHECKS=$((PASSED_CHECKS + 1))
      ;;
    fail)
      print_error "$message"
      FAILED_CHECKS=$((FAILED_CHECKS + 1))
      ;;
    warn)
      print_warning "$message"
      WARNING_CHECKS=$((WARNING_CHECKS + 1))
      ;;
  esac

  if [ "$VERBOSE" = true ] && [ -n "$detail" ]; then
    echo "    $detail"
  fi
}

# Banner
[[ -t 1 ]] && clear
print_header "AITEAMFORGE DOCTOR - HEALTH CHECK"

# Check: External Dependencies
check_dependencies() {
  print_section "Checking External Dependencies"

  # Python
  if command -v python3 &>/dev/null; then
    py_version=$(python3 --version 2>&1 | awk '{print $2}')
    check_result pass "Python 3 (${py_version})"
  else
    check_result fail "Python 3 not found" "Install: brew install python@3.13"
  fi

  # Node.js
  if command -v node &>/dev/null; then
    node_version=$(node --version)
    check_result pass "Node.js (${node_version})"
  else
    check_result fail "Node.js not found" "Install: brew install node"
  fi

  # jq
  if command -v jq &>/dev/null; then
    jq_version=$(jq --version)
    check_result pass "jq (${jq_version})"
  else
    check_result fail "jq not found" "Install: brew install jq"
  fi

  # GitHub CLI
  if command -v gh &>/dev/null; then
    gh_version=$(gh --version | head -n1)
    check_result pass "GitHub CLI (${gh_version})"

    # Check authentication
    if gh auth status &>/dev/null; then
      check_result pass "GitHub CLI authenticated"
    else
      check_result warn "GitHub CLI not authenticated" "Run: gh auth login"
    fi
  else
    check_result fail "GitHub CLI not found" "Install: brew install gh"
  fi

  # Git
  if command -v git &>/dev/null; then
    git_version=$(git --version | awk '{print $3}')
    check_result pass "Git (${git_version})"
  else
    check_result fail "Git not found" "Install: xcode-select --install"
  fi

  # iTerm2
  if [ -d "/Applications/iTerm.app" ]; then
    check_result pass "iTerm2"
  else
    check_result fail "iTerm2 not found" "Install: brew install --cask iterm2"
  fi

  # Claude Code
  if command -v claude &>/dev/null; then
    claude_version=$(claude --version 2>&1 || echo "unknown")
    check_result pass "Claude Code (${claude_version})"

    # Check authentication
    if [ -f "$HOME/.config/claude/config.json" ]; then
      check_result pass "Claude Code configured"
    else
      check_result warn "Claude Code not configured" "Run: claude auth login"
    fi
  else
    check_result fail "Claude Code not found" "Install: npm install -g @anthropic-ai/claude-code"
  fi

  # Optional: Tailscale (check CLI in PATH, Homebrew, and macOS app)
  if command -v tailscale &>/dev/null; then
    check_result pass "Tailscale (CLI in PATH)"
  elif [ -x "/opt/homebrew/bin/tailscale" ]; then
    check_result pass "Tailscale (Homebrew)"
  elif [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
    check_result pass "Tailscale (macOS app)"
  else
    check_result warn "Tailscale not installed (optional)" "Install: brew install --cask tailscale"
  fi

  # Optional: ImageMagick
  if command -v convert &>/dev/null; then
    check_result pass "ImageMagick (optional)"
  else
    check_result warn "ImageMagick not installed (optional)" "Install: brew install imagemagick"
  fi
}

# Check: Tap-owned Python venv and required deps (XACA-0650)
# The tap venv is provisioned by the Formula post_install at:
#   $HOMEBREW_PREFIX/var/aiteamforge/venv
# If iterm2 or another required dep is missing, the fix is always:
#   brew postinstall aiteamforge  (re-provisions the venv from requirements.txt)
check_python_venv() {
  print_section "Checking Tap-Owned Python Venv"

  # AITEAMFORGE_PYTHON resolved by python-env.sh at the top of this file.
  local atf_python="${AITEAMFORGE_PYTHON:-}"

  if [ -z "$atf_python" ] || [ "$atf_python" = "python3" ]; then
    check_result fail "Tap-owned Python venv not found" \
      "Run: brew postinstall aiteamforge  (provisions the venv with all Python deps)"
    if [ "$FIX" = true ]; then
      print_info "  --fix: run 'brew postinstall aiteamforge' to reprovision the venv"
    fi
    return
  fi

  if [ ! -x "$atf_python" ]; then
    check_result fail "Tap-owned venv Python not executable: ${atf_python}" \
      "Run: brew postinstall aiteamforge"
    return
  fi

  local atf_py_version
  atf_py_version=$("$atf_python" --version 2>&1 | awk '{print $2}')
  check_result pass "Tap-owned venv Python (${atf_py_version:-unknown}) — ${atf_python}"

  # Check required deps from requirements.txt using pip show
  local venv_bin
  venv_bin="$(dirname "$atf_python")"
  local venv_pip="${venv_bin}/pip"

  if [ ! -x "$venv_pip" ]; then
    check_result fail "pip not found in tap venv — venv may be incomplete" \
      "Run: brew postinstall aiteamforge"
    return
  fi

  # Parse required Python packages from share/requirements.txt.
  # Strip comments, blank lines, PEP 508 version specifiers, extras, and
  # environment markers.  Fall back to the known set if the file is unreadable.
  local requirements_file="${LIBEXEC_DIR}/../share/requirements.txt"
  local required_packages=()
  if [ -r "$requirements_file" ]; then
    while IFS= read -r line; do
      # Skip blank lines and comment lines
      [[ -z "$line" || "$line" == \#* ]] && continue
      # Strip from first PEP 508 operator/marker/extras char onward:
      #   <>=~!  version comparisons  (==, >=, <=, ~=, !=, >, <)
      #   ;      environment markers  (pkg ; python_version < '3')
      #   [      extras spec          (pkg[extra]==1.0)
      local pkg_name
      pkg_name="${line%%[<>=~!;[]*}"
      # Trim leading whitespace
      pkg_name="${pkg_name#"${pkg_name%%[![:space:]]*}"}"
      # Trim trailing whitespace
      pkg_name="${pkg_name%"${pkg_name##*[![:space:]]}"}"
      [[ -n "$pkg_name" ]] && required_packages+=("$pkg_name")
    done < "$requirements_file"
  fi
  if [ "${#required_packages[@]}" -eq 0 ]; then
    # Fallback: requirements.txt unreadable or empty — use known set
    required_packages=("iterm2" "pyzipper")
  fi

  for pkg in "${required_packages[@]}"; do
    if "$venv_pip" show "$pkg" &>/dev/null; then
      local pkg_ver
      pkg_ver="$("$venv_pip" show "$pkg" 2>/dev/null | grep '^Version:' | awk '{print $2}')"
      check_result pass "${pkg} package installed (${pkg_ver:-unknown version})"
    else
      check_result fail "${pkg} package missing from tap venv" \
        "Run: brew postinstall aiteamforge  (re-provisions the venv from requirements.txt)"
      if [ "$FIX" = true ]; then
        print_info "  --fix: run 'brew postinstall aiteamforge' to reinstall ${pkg}"
      fi
    fi
  done
}

# Check: Framework Installation
check_framework() {
  print_section "Checking Framework Installation"

  local framework_dir
  framework_dir=$(get_framework_dir)

  # Framework directory exists
  if [ -d "$framework_dir" ]; then
    check_result pass "Framework directory: ${framework_dir}"
  else
    check_result fail "Framework directory not found: ${framework_dir}"
    return
  fi

  # Core templates exist in framework
  local core_templates=(
    "share/templates/kanban/kanban-helpers.template.sh"
    "share/templates/aliases/agent-aliases.sh"
    "share/templates/aliases/worktree-aliases.sh"
  )

  for tmpl in "${core_templates[@]}"; do
    local tmpl_name
    tmpl_name="$(basename "$tmpl")"
    if [ -f "${framework_dir}/${tmpl}" ]; then
      check_result pass "${tmpl_name} (template)"
    else
      check_result warn "${tmpl_name} template missing"
    fi
  done

  # Core directories exist
  local core_dirs=(
    "share/templates"
    "share/teams"
    "docs"
    "libexec/commands"
    "libexec/lib"
  )

  for dir in "${core_dirs[@]}"; do
    if [ -d "${framework_dir}/${dir}" ]; then
      check_result pass "${dir}/"
    else
      check_result warn "${dir}/ missing"
    fi
  done

  # Check if wizard UI library exists
  if [ -f "${framework_dir}/libexec/lib/wizard-ui.sh" ]; then
    check_result pass "Wizard UI library"
  else
    check_result fail "Wizard UI library missing"
  fi
}

# Check: Cellar-vs-working-dir version drift (XACA-0578)
# Detects when `brew upgrade aiteamforge` ran but `aiteamforge upgrade --non-interactive`
# did NOT follow (e.g. cellar-watch LaunchAgent is disabled/missing/broken).
# The .installed-version stamp is written by `aiteamforge upgrade` (Edit A); if it
# is absent the check falls back to the "version" field in .aiteamforge-config
# (install-time only — less reliable for drift detection).
check_version_drift() {
  print_section "Checking Cellar vs Working-Dir Version"

  local framework_dir working_dir
  framework_dir=$(get_framework_dir)
  working_dir=$(get_working_dir)

  # --- Cellar VERSION (what brew upgraded to) ---
  local cellar_version=""
  local cellar_version_file=""
  for _candidate in "${framework_dir}/../VERSION" "${framework_dir}/VERSION"; do
    if [ -f "$_candidate" ]; then
      cellar_version_file="$_candidate"
      cellar_version="$(cat "$_candidate" | tr -d '[:space:]' | sed 's/^v//')"
      break
    fi
  done
  unset _candidate

  if [ -z "$cellar_version" ]; then
    check_result fail "Cellar VERSION file not found (checked ${framework_dir}/../VERSION)" \
      "Verify FRAMEWORK_DIR resolves correctly: ${framework_dir}"
    return
  fi

  # --- Working-dir installed version ---
  local installed_version=""
  local drift_mode=""
  local stamp_file="${working_dir}/.installed-version"

  if [ -f "$stamp_file" ]; then
    installed_version="$(cat "$stamp_file" | tr -d '[:space:]' | sed 's/^v//')"
    drift_mode="stamp"
  else
    # Fallback: config "version" field (install-time only — less reliable)
    installed_version="$(get_installed_version | tr -d '[:space:]' | sed 's/^v//')"
    drift_mode="config-fallback"
  fi

  # --- Diagnostics for missing stamp ---
  if [ -z "$installed_version" ]; then
    check_result warn "Cannot determine working-dir version (no .installed-version stamp and no version in config)" \
      "Run: aiteamforge upgrade --non-interactive  to refresh and stamp"
    return
  fi

  # Fallback mode advisory
  if [ "$drift_mode" = "config-fallback" ]; then
    print_info "  Note: .installed-version stamp absent — using config version (less reliable; run 'aiteamforge upgrade --non-interactive' to stamp)"
  fi

  # --- Compare ---
  if [ "$cellar_version" = "$installed_version" ]; then
    check_result pass "Cellar v${cellar_version} matches working-dir v${installed_version}" \
      "Version stamp mode: ${drift_mode}"
  else
    check_result warn "Cellar v${cellar_version} BUT working-dir v${installed_version} — run: aiteamforge upgrade --non-interactive" \
      "Stamp file: ${stamp_file} | Drift mode: ${drift_mode}"
    if [ "$VERBOSE" = true ]; then
      echo "    Cellar VERSION file: ${cellar_version_file}"
      echo "    Working-dir stamp:   ${stamp_file}"
      echo "    Stamp mode:          ${drift_mode}"
    fi
  fi
}

# Check: Configuration
check_config() {
  print_section "Checking Configuration"

  local working_dir
  working_dir=$(get_working_dir)

  # Working directory exists
  if [ -d "$working_dir" ]; then
    check_result pass "Working directory: ${working_dir}"
  else
    check_result fail "Working directory not found: ${working_dir}" "Run: aiteamforge setup"
    return
  fi

  # Configuration marker exists
  if is_configured; then
    check_result pass "Configuration marker"

    # Validate config structure
    if validate_config; then
      check_result pass "Config file valid JSON"

      # Show config details in verbose mode
      if [ "$VERBOSE" = true ]; then
        echo "    Machine: $(get_machine_name)"
        echo "    Machine ID: $(get_machine_id)"
        echo "    Version: $(get_installed_version)"
        echo "    Teams: $(get_configured_teams)"
      fi
    else
      check_result fail "Config file invalid"
    fi
  else
    check_result fail "Not configured" "Run: aiteamforge setup"
  fi

  # Check kanban directory
  if [ -d "${working_dir}/kanban" ]; then
    check_result pass "Kanban directory"

    # Count board files
    local board_count
    board_count=$(find "${working_dir}/kanban" -name "*-board.json" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$VERBOSE" = true ]; then
      echo "    Kanban boards: ${board_count}"
    fi
  else
    check_result warn "Kanban directory missing"
  fi

  # Check LCARS UI directory
  if [ -d "${working_dir}/lcars-ui" ]; then
    check_result pass "LCARS UI directory"
  else
    check_result warn "LCARS UI directory missing"
  fi
}

# Check: Services
check_services() {
  print_section "Checking Services"

  # LCARS Kanban server — read port from config, check root URL (no /health endpoint)
  local lcars_port=8080
  local lcars_working_dir
  lcars_working_dir=$(get_working_dir)
  if [ -f "${lcars_working_dir}/lcars-ui/.lcars-port" ]; then
    lcars_port="$(cat "${lcars_working_dir}/lcars-ui/.lcars-port" 2>/dev/null || echo 8080)"
  fi
  if curl -s -o /dev/null -w '%{http_code}' "http://localhost:${lcars_port}/" 2>/dev/null | grep -q '200'; then
    check_result pass "LCARS Kanban server (port ${lcars_port})"
  else
    check_result warn "LCARS Kanban server not running"
    if [ "$VERBOSE" = true ]; then
      echo "    Start: aiteamforge start kanban"
    fi
  fi

  # Fleet Monitor — check server AND client (reporter)
  local working_dir
  working_dir=$(get_working_dir)

  if [ -d "${working_dir}/fleet-monitor/server" ]; then
    # Server mode: check if server is running
    local fleet_running=false
    # shellcheck disable=SC2086
    for port in $FLEET_MONITOR_PORT_SCAN_RANGE; do
      if curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}/" 2>/dev/null | grep -q '200'; then
        check_result pass "Fleet Monitor server (port ${port})"
        fleet_running=true
        break
      fi
    done

    if [ "$fleet_running" = false ]; then
      check_result warn "Fleet Monitor server not running"
      if [ "$VERBOSE" = true ]; then
        echo "    Start: aiteamforge start fleet"
      fi
    fi
  fi

  # Fleet reporter client
  if [ -f "${working_dir}/fleet-monitor/client/fleet-reporter.sh" ]; then
    check_result pass "Fleet reporter client installed"
  elif [ -f "$HOME/.aiteamforge/fleet-config.json" ]; then
    check_result warn "Fleet reporter config exists but script missing"
  fi
}

# Check: LaunchAgents
check_launchagents() {
  print_section "Checking LaunchAgents"

  # Kanban backup agent
  if launchctl list 2>/dev/null | grep -q "com.aiteamforge.kanban-backup"; then
    check_result pass "Kanban backup LaunchAgent loaded"
  else
    check_result warn "Kanban backup LaunchAgent not loaded"
    if [ "$VERBOSE" = true ]; then
      echo "    Load: launchctl load ~/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist"
    fi
  fi

  # LCARS health agent
  if launchctl list 2>/dev/null | grep -q "com.aiteamforge.lcars-health"; then
    check_result pass "LCARS health LaunchAgent loaded"
  else
    check_result warn "LCARS health LaunchAgent not loaded"
    if [ "$VERBOSE" = true ]; then
      echo "    Load: launchctl load ~/Library/LaunchAgents/com.aiteamforge.lcars-health.plist"
    fi
  fi
  # XACA-0585: script the LaunchAgent invokes must exist; missing = exit 127 on every tick
  if [ -f "${AITEAMFORGE_DIR}/lcars-health-check.sh" ]; then
    check_result pass "LCARS health check script present"
  else
    check_result fail "LCARS health check script missing: ${AITEAMFORGE_DIR}/lcars-health-check.sh"
    if [ "$VERBOSE" = true ]; then
      echo "    Fix: aiteamforge setup  (re-runs the installer lay-down)"
      echo "    Note: 'aiteamforge upgrade' will NOT create a missing script — update_aux_scripts skips absent targets."
    fi
  fi

  # Fleet reporter agent
  if launchctl list 2>/dev/null | grep -q "com.aiteamforge.fleet-reporter"; then
    check_result pass "Fleet reporter LaunchAgent loaded"
  elif [ -f "$HOME/Library/LaunchAgents/com.aiteamforge.fleet-reporter.plist" ]; then
    check_result warn "Fleet reporter LaunchAgent not loaded"
    if [ "$VERBOSE" = true ]; then
      echo "    Load: launchctl load ~/Library/LaunchAgents/com.aiteamforge.fleet-reporter.plist"
    fi
  fi

  # CR Confluence Poller agent (XACA-0328-003)
  if launchctl list 2>/dev/null | grep -q "com.aiteamforge.cr-confluence-poller"; then
    check_result pass "CR Confluence Poller LaunchAgent loaded"
  elif [ -f "$HOME/Library/LaunchAgents/com.aiteamforge.cr-confluence-poller.plist" ]; then
    check_result warn "CR Confluence Poller LaunchAgent not loaded"
    if [ "$VERBOSE" = true ]; then
      echo "    Load: launchctl load ~/Library/LaunchAgents/com.aiteamforge.cr-confluence-poller.plist"
    fi
  fi
}

# Check: Git Repositories
check_git() {
  print_section "Checking Git Repositories"

  local working_dir
  working_dir=$(get_working_dir)

  # Main aiteamforge repo
  if [ -d "${working_dir}/.git" ]; then
    check_result pass "Dev-team git repository"

    # Check repo status
    cd "${working_dir}"
    if git status --porcelain 2>/dev/null | grep -q .; then
      check_result warn "Dev-team repo has uncommitted changes"
    else
      check_result pass "Dev-team repo clean"
    fi
  else
    check_result warn "Dev-team not a git repository"
  fi

  # Check for worktrees
  if [ -d "${working_dir}/worktrees" ]; then
    local worktree_count
    worktree_count=$(find "${working_dir}/worktrees" -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    worktree_count=$((worktree_count - 1)) # Subtract parent dir
    if [ "$VERBOSE" = true ] && [ "$worktree_count" -gt 0 ]; then
      echo "    Active worktrees: ${worktree_count}"
    fi
  fi
}

# Check: Network Connectivity
check_network() {
  print_section "Checking Network Connectivity"

  # Internet connectivity
  if ping -c 1 -t 5 8.8.8.8 &>/dev/null; then
    check_result pass "Internet connectivity"
  else
    check_result warn "No internet connectivity"
  fi

  # Tailscale (check CLI in PATH, Homebrew, and macOS app)
  local ts_cmd=""
  if command -v tailscale &>/dev/null; then
    ts_cmd="tailscale"
  elif [ -x "/opt/homebrew/bin/tailscale" ]; then
    ts_cmd="/opt/homebrew/bin/tailscale"
  elif [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
    ts_cmd="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  fi

  if [ -n "$ts_cmd" ]; then
    if "$ts_cmd" status &>/dev/null 2>&1; then
      check_result pass "Tailscale connected"
      if [ "$VERBOSE" = true ]; then
        "$ts_cmd" status --peers=false 2>/dev/null | head -n3 || true
      fi
    else
      check_result warn "Tailscale not connected"
    fi
  fi
}

# Check: Disk Space
check_disk() {
  print_section "Checking Disk Space"

  local working_dir
  working_dir=$(get_working_dir)

  # Get disk space for aiteamforge directory
  local disk_usage
  disk_usage=$(du -sh "${working_dir}" 2>/dev/null | awk '{print $1}')
  check_result pass "Dev-team disk usage: ${disk_usage}"

  # Check available space
  local available_space
  available_space=$(df -h "${working_dir}" | awk 'NR==2 {print $4}')
  check_result pass "Available disk space: ${available_space}"

  # Warn if less than 1GB available
  local available_gb
  available_gb=$(df -g "${working_dir}" | awk 'NR==2 {print $4}')
  if [ "$available_gb" -lt 1 ]; then
    check_result warn "Low disk space (less than 1GB available)"
  fi

  # Check kanban backups
  if [ -d "${working_dir}/kanban-backups" ]; then
    local backup_count
    backup_count=$(find "${working_dir}/kanban-backups" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$VERBOSE" = true ]; then
      echo "    Kanban backups: ${backup_count}"
    fi
  fi
}

# Run checks based on component
case "$CHECK_COMPONENT" in
  dependencies)
    check_dependencies
    ;;
  python-venv)
    check_python_venv
    ;;
  framework)
    check_framework
    ;;
  version-drift)
    check_version_drift
    ;;
  config)
    check_config
    ;;
  services)
    check_services
    ;;
  launchagents)
    check_launchagents
    ;;
  git)
    check_git
    ;;
  network)
    check_network
    ;;
  disk)
    check_disk
    ;;
  all)
    check_dependencies
    check_python_venv
    check_framework
    check_version_drift
    check_config
    check_services
    check_launchagents
    check_git
    check_network
    check_disk
    ;;
  *)
    print_error "Unknown component: ${CHECK_COMPONENT}"
    usage
    exit 1
    ;;
esac

# Summary
echo ""
print_section "Summary"
echo "Total checks:    ${TOTAL_CHECKS}"
print_color "${COLOR_SUCCESS}" "Passed:          ${PASSED_CHECKS}"
print_color "${COLOR_WARNING}" "Warnings:        ${WARNING_CHECKS}"
print_color "${COLOR_ERROR}" "Failed:          ${FAILED_CHECKS}"
echo ""

# Overall status
if [ $FAILED_CHECKS -eq 0 ]; then
  if [ $WARNING_CHECKS -eq 0 ]; then
    print_success "All checks passed - aiteamforge is healthy!"
    exit 0
  else
    print_warning "Some warnings detected - aiteamforge should work but has minor issues"
    exit 1
  fi
else
  print_error "Some checks failed - aiteamforge may not function correctly"
  echo ""
  if [ "$FIX" = true ]; then
    print_info "Attempting to fix issues..."
    echo "(Auto-fix not yet implemented - run: aiteamforge setup --upgrade)"
  else
    print_info "Run with --fix to attempt automatic fixes"
    print_info "Or run: aiteamforge setup --upgrade"
  fi
  exit 2
fi
