#!/bin/bash
# AITeamForge Doctor - Health check and diagnostics
# Verifies installation and identifies issues

set -eo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Get framework location
if [ -z "$AITEAMFORGE_HOME" ]; then
  if command -v brew &>/dev/null; then
    AITEAMFORGE_HOME="$(brew --prefix)/opt/aiteamforge/libexec"
  else
    echo -e "${RED}ERROR: AITEAMFORGE_HOME not set${NC}" >&2
    exit 1
  fi
fi

# Resolve tap-owned Python venv interpreter ($AITEAMFORGE_PYTHON).
# AITEAMFORGE_HOME is set above; python-env.sh lives in its libexec/lib/ subdir.
# shellcheck source=/dev/null
[ -f "$AITEAMFORGE_HOME/libexec/lib/python-env.sh" ] && . "$AITEAMFORGE_HOME/libexec/lib/python-env.sh"

# XACA-0734 (review #1): this script was the FIFTH place with its own LaunchAgent
# opinion, and the only one still asking nothing but "is it loaded?". A plist that
# does not EXIST is a different, worse problem than one that merely is not loaded
# — nothing will ever load it — and this doctor reported that state as a mere
# "not loaded" warning, which is how M1Pro's missing auto-upgrade agent hid in
# plain sight. Source the shared vocabulary (mandatory set + opt-out sentinel +
# applicability gate) so this doctor cannot drift from `aiteamforge doctor`,
# `aiteamforge upgrade`, and the installer.
#
# Sourced DEFENSIVELY: if the lib is absent (a partially-upgraded install), fall
# back to the legacy loaded-only checks rather than crashing the whole doctor.
# shellcheck source=/dev/null
_LAUNCHAGENTS_LIB_OK=false
if [ -f "$AITEAMFORGE_HOME/libexec/lib/launchagents.sh" ]; then
  . "$AITEAMFORGE_HOME/libexec/lib/launchagents.sh" && _LAUNCHAGENTS_LIB_OK=true
fi

# Working directory
AITEAMFORGE_DIR="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"

# Install profile — read from marker file; defaults to "full" if absent
INSTALL_PROFILE="full"
if [ -f "${AITEAMFORGE_DIR}/.install-profile" ]; then
  INSTALL_PROFILE="$(tr -d '[:space:]' < "${AITEAMFORGE_DIR}/.install-profile")"
fi

# Version — read from VERSION file (single source of truth)
_find_version() { for p in "$AITEAMFORGE_HOME/../VERSION" "$AITEAMFORGE_HOME/VERSION"; do [ -f "$p" ] && cat "$p" | tr -d '[:space:]' && return; done; echo "unknown"; }
VERSION="$(_find_version)"

# Usage
usage() {
  cat <<EOF
AITeamForge Doctor v${VERSION}
Health check and diagnostics for aiteamforge installation

Usage: aiteamforge doctor [options]

Options:
  --verbose              Show detailed diagnostic information
  --fix                  Attempt to fix common issues
  --check <component>    Check specific component only
  -v, --version          Show version
  -h, --help             Show this help

Components:
  dependencies    Check external dependencies
  framework       Check framework installation
  helpers-drift   Installed kanban-helpers.sh function inventory vs shipped template (XACA-1095)
  config          Check configuration files
  services        Check running services
  permissions     Check file permissions
  install         Validate post-install structure (teams, scripts, LCARS, venv)
  all             Run all checks (default)

Examples:
  aiteamforge doctor                    # Run all health checks
  aiteamforge doctor --verbose          # Detailed diagnostics
  aiteamforge doctor --check services   # Check services only
  aiteamforge doctor --fix              # Fix common issues
EOF
}

# Parse arguments
VERBOSE=false
FIX=false
CHECK_COMPONENT="all"

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
      echo -e "${RED}ERROR: Unknown option: $1${NC}" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

# Check result tracker
check_result() {
  local status=$1
  local message=$2

  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

  case $status in
    pass)
      echo -e "${GREEN}✓${NC} $message"
      PASSED_CHECKS=$((PASSED_CHECKS + 1))
      ;;
    fail)
      echo -e "${RED}✗${NC} $message"
      FAILED_CHECKS=$((FAILED_CHECKS + 1))
      ;;
    warn)
      echo -e "${YELLOW}⚠${NC} $message"
      WARNING_CHECKS=$((WARNING_CHECKS + 1))
      ;;
  esac

  if [ "$VERBOSE" = true ] && [ $# -gt 2 ]; then
    echo "    ${3}"
  fi
}

# Banner
echo ""
echo -e "${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           AITeamForge Doctor - Health Check                  ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Install Profile: ${CYAN}${INSTALL_PROFILE}${NC}"
if [ "$INSTALL_PROFILE" = "cockpit" ]; then
  echo -e "  ${YELLOW}Cockpit mode: checks for local-only components (teams, kanban,${NC}"
  echo -e "  ${YELLOW}LCARS server, personas, aliases) are suppressed.${NC}"
fi
echo ""

# Check dependencies
check_dependencies() {
  echo -e "${CYAN}Checking external dependencies...${NC}"
  echo ""

  # Python — presence check (bare python3 from PATH)
  if command -v python3 &>/dev/null; then
    py_version=$(python3 --version 2>&1 | awk '{print $2}')
    check_result pass "Python 3 (${py_version})"
  else
    check_result fail "Python 3 not found" "Install: brew install python@3.13"
  fi

  # Python — tap-owned venv status check
  if [ -n "${AITEAMFORGE_PYTHON:-}" ] && [ "$AITEAMFORGE_PYTHON" != "python3" ]; then
    if [ -x "$AITEAMFORGE_PYTHON" ]; then
      atf_py_version=$("$AITEAMFORGE_PYTHON" --version 2>&1 | awk '{print $2}')
      check_result pass "AITeamForge venv Python (${atf_py_version:-unknown}) — ${AITEAMFORGE_PYTHON}"
    else
      check_result fail "AITeamForge venv Python not executable: ${AITEAMFORGE_PYTHON}" \
        "Run: brew reinstall aiteamforge"
    fi
  else
    check_result fail "AITeamForge tap-owned venv not found — Python deps unavailable" \
      "Run: brew reinstall aiteamforge"
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

    # Check if authenticated
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

    # Check if authenticated
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

  echo ""
}

# Check framework installation
check_framework() {
  echo -e "${CYAN}Checking framework installation...${NC}"
  echo ""

  # Framework directory exists
  if [ -d "$AITEAMFORGE_HOME" ]; then
    check_result pass "Framework directory: ${AITEAMFORGE_HOME}"
  else
    check_result fail "Framework directory not found: ${AITEAMFORGE_HOME}"
    return
  fi

  # Core templates exist in framework
  local core_templates=(
    "share/templates/kanban/kanban-helpers.template.sh"
    "share/templates/aliases/agent-aliases.sh"
    "share/templates/aliases/cc-aliases.sh"
    "share/templates/aliases/worktree-aliases.sh"
  )

  for tmpl in "${core_templates[@]}"; do
    local tmpl_name
    tmpl_name="$(basename "$tmpl")"
    if [ -f "${AITEAMFORGE_HOME}/${tmpl}" ]; then
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
    if [ -d "${AITEAMFORGE_HOME}/${dir}" ]; then
      check_result pass "${dir}/"
    else
      check_result fail "${dir}/ missing"
    fi
  done

  echo ""
}

# Check installed kanban-helpers.sh function inventory vs the shipped template
# (XACA-1095). Mirrors libexec/commands/aiteamforge-doctor.sh's
# check_kanban_helpers_inventory — kept in sync per XACA-0734's precedent that
# these two doctor entry points must not contradict each other on the same
# machine. See that function's header comment for the full rationale.
#
# check_framework (above) only checks that the TEMPLATE exists in the
# framework dir; it never compares it against the INSTALLED copy in
# AITEAMFORGE_DIR. A stale/truncated installed copy still passes that check
# while missing whole kb-* commands (field-confirmed on two consumers: 20 of
# 61 shipped kb-* commands present, 48 missing, including kb-sweep — the
# protected-subitem PR merge gate). Severity is FAIL, not warn: this script's
# own summary lets warnings `exit 0` ("should work but has minor issues"),
# which is exactly the failure shape this check exists to not repeat when the
# merge gate is unusable. `--fix` here remains the unimplemented placeholder
# below (this check does not touch it) — the real remediation is
# `aiteamforge upgrade --non-interactive`, named explicitly in the output.
check_kanban_helpers_inventory() {
  echo -e "${CYAN}Checking kanban-helpers.sh function inventory...${NC}"
  echo ""

  local template="${AITEAMFORGE_HOME}/share/templates/kanban/kanban-helpers.template.sh"
  local installed="${AITEAMFORGE_DIR}/kanban-helpers.sh"

  # Degrade honestly: an unreadable template is a packaging problem on this
  # machine's tap install, not a signal about the installed copy.
  if [ ! -f "$template" ] || [ ! -r "$template" ]; then
    check_result warn "Cannot verify kanban-helpers.sh inventory — shipped template not found/readable: ${template}" \
      "Packaging problem, not a drift signal. Run: brew reinstall aiteamforge"
    echo ""
    return
  fi

  # A missing installed file is worse than a drifted one — no kb-* commands
  # at all are available in that shell.
  if [ ! -f "$installed" ] || [ ! -r "$installed" ]; then
    check_result fail "kanban-helpers.sh not found/readable at ${installed} — no kb-* commands available" \
      "Run: aiteamforge upgrade --non-interactive   (or: aiteamforge setup --upgrade)"
    echo ""
    return
  fi

  local tmpl_funcs installed_funcs tmpl_count installed_count
  tmpl_funcs=$(grep -oE '^[A-Za-z_][A-Za-z0-9_-]*\(\)' "$template" | sed 's/()//' | sort -u | grep '^kb-') || true
  installed_funcs=$(grep -oE '^[A-Za-z_][A-Za-z0-9_-]*\(\)' "$installed" | sed 's/()//' | sort -u | grep '^kb-') || true

  tmpl_count=$(printf '%s\n' "$tmpl_funcs" | grep -c . | head -1) || true
  tmpl_count="${tmpl_count:-0}"
  installed_count=$(printf '%s\n' "$installed_funcs" | grep -c . | head -1) || true
  installed_count="${installed_count:-0}"

  # Predicate self-check (feedback_malformed_check_returns_reassuring_result):
  # the template just passed a readability check and is the single shipped
  # source of every kb-* command. Zero matches here means the regex is
  # broken, not that the install is clean — never let that read as a pass.
  if [ "$tmpl_count" -eq 0 ]; then
    check_result warn "kb-* extraction found 0 functions in the shipped template — extraction pattern likely broken, not evidence of a clean install" \
      "Template checked: ${template}"
    echo ""
    return
  fi

  local missing_funcs missing_count
  missing_funcs=$(comm -23 <(printf '%s\n' "$tmpl_funcs") <(printf '%s\n' "$installed_funcs")) || true
  missing_count=$(printf '%s\n' "$missing_funcs" | grep -c . | head -1) || true
  missing_count="${missing_count:-0}"

  if [ "$missing_count" -eq 0 ]; then
    check_result pass "kanban-helpers.sh has all ${tmpl_count} shipped kb-* commands"
    echo ""
    return
  fi

  local shown_limit=10
  local shown more_note=""
  shown=$(printf '%s\n' "$missing_funcs" | head -"$shown_limit" | paste -sd, -)
  if [ "$missing_count" -gt "$shown_limit" ]; then
    more_note=" …and $((missing_count - shown_limit)) more"
  fi

  check_result fail "kanban-helpers.sh is MISSING ${missing_count} of ${tmpl_count} shipped kb-* commands (installed exposes only ${installed_count}) — kb-sweep and other lifecycle commands may be unusable"
  echo "    Missing (first ${shown_limit} of ${missing_count}): ${shown}${more_note}"
  if [ "$VERBOSE" = true ]; then
    echo "    Full list of missing kb-* commands:"
    printf '%s\n' "$missing_funcs" | sed 's/^/      - /'
  else
    echo "    (run with --verbose for the full list of ${missing_count})"
  fi
  echo "    Remediation: run 'aiteamforge upgrade --non-interactive' to refresh kanban-helpers.sh from the shipped template."
  echo "    (doctor --fix does not remediate this — the fix is the upgrade path above, not a doctor auto-fix.)"
  echo ""
}

# Check configuration
check_config() {
  echo -e "${CYAN}Checking configuration...${NC}"
  echo ""

  # Working directory exists
  if [ -d "$AITEAMFORGE_DIR" ]; then
    check_result pass "Working directory: ${AITEAMFORGE_DIR}"
  else
    check_result fail "Working directory not found: ${AITEAMFORGE_DIR}" "Run: aiteamforge setup"
    return
  fi

  # Configuration marker exists
  if [ -f "${AITEAMFORGE_DIR}/.aiteamforge-config" ]; then
    check_result pass "Configuration marker"

    # Read config
    if [ "$VERBOSE" = true ]; then
      echo "    $(cat "${AITEAMFORGE_DIR}/.aiteamforge-config")"
    fi

    # Check installed_features field is present
    if command -v jq &>/dev/null; then
      local features_count
      features_count=$(jq '.installed_features | length // 0' "${AITEAMFORGE_DIR}/.aiteamforge-config" 2>/dev/null || echo "0")
      if [ "$features_count" -gt 0 ] 2>/dev/null; then
        check_result pass "installed_features field present (${features_count} feature(s))"
      else
        check_result warn "installed_features field missing or empty (run: aiteamforge setup --upgrade)"
      fi

      # Check fleet registration status
      local fleet_reg_status
      fleet_reg_status=$(jq -r '.fleet_registration_status // "not_configured"' "${AITEAMFORGE_DIR}/.aiteamforge-config" 2>/dev/null || echo "not_configured")
      case "$fleet_reg_status" in
        registered)
          check_result pass "Fleet registration: registered"
          ;;
        pending)
          check_result warn "Fleet registration: pending (machine identity not yet confirmed)"
          ;;
        not_configured)
          # Not an error — fleet is optional
          if [ "$VERBOSE" = true ]; then
            check_result pass "Fleet registration: not configured (fleet monitor not installed)"
          fi
          ;;
        *)
          check_result warn "Fleet registration: unknown status '${fleet_reg_status}'"
          ;;
      esac
    fi
  else
    check_result fail "Not configured" "Run: aiteamforge setup"
  fi

  # Templates directory
  if [ -d "${AITEAMFORGE_DIR}/templates" ]; then
    check_result pass "Templates directory"
  else
    check_result warn "Templates directory missing"
  fi

  # Deployed alias files (installed by install-shell.sh)
  # Not installed in cockpit mode — skip these checks to avoid false failures.
  if [ "$INSTALL_PROFILE" != "cockpit" ]; then
    local deployed_aliases=(
      "share/aliases/agent-aliases.sh"
      "share/aliases/cc-aliases.sh"
      "share/aliases/worktree-aliases.sh"
    )

    for alias_file in "${deployed_aliases[@]}"; do
      local alias_name
      alias_name="$(basename "$alias_file")"
      if [ -f "${AITEAMFORGE_DIR}/${alias_file}" ]; then
        check_result pass "${alias_name} (deployed)"
      else
        check_result warn "${alias_name} missing" "Run: aiteamforge setup --shell"
      fi
    done
  else
    check_result pass "Alias files (not installed — cockpit profile)"
  fi

  # Cockpit-critical components: tap venv, iterm2_window_manager.py, connect scripts
  if [ "$INSTALL_PROFILE" = "cockpit" ]; then
    # Tap-owned venv (shared across all profiles, but cockpit hard-depends on it for iTerm2 scripts)
    if [ -n "${AITEAMFORGE_PYTHON:-}" ] && [ "$AITEAMFORGE_PYTHON" != "python3" ] && [ -x "$AITEAMFORGE_PYTHON" ]; then
      check_result pass "Tap-owned Python venv"
    else
      check_result fail "Tap-owned Python venv not provisioned" "Run: brew reinstall aiteamforge"
    fi
    # Window manager script
    if [ -f "${AITEAMFORGE_DIR}/iterm2_window_manager.py" ] || \
       [ -f "${AITEAMFORGE_DIR}/scripts/iterm2_window_manager.py" ]; then
      check_result pass "iterm2_window_manager.py"
    else
      check_result warn "iterm2_window_manager.py missing" "Re-run: aiteamforge setup --cockpit-only"
    fi
    # set-lcars-profile-browser.py
    if [ -f "${AITEAMFORGE_DIR}/scripts/set-lcars-profile-browser.py" ]; then
      check_result pass "set-lcars-profile-browser.py"
    else
      check_result warn "set-lcars-profile-browser.py missing"
    fi
    # Dynamic profile JSON
    local _dyn_profile="$HOME/Library/Application Support/iTerm2/DynamicProfiles/aiteamforge-lcars.json"
    if [ -f "$_dyn_profile" ]; then
      check_result pass "aiteamforge-lcars.json dynamic profile"
    else
      check_result warn "aiteamforge-lcars.json dynamic profile missing" "Re-run: aiteamforge setup --cockpit-only"
    fi
    # Connect scripts
    local _connect_count=0
    for _cs in "${AITEAMFORGE_DIR}"/*-connect.sh; do
      [ -f "$_cs" ] && _connect_count=$((_connect_count + 1))
    done
    if [ "$_connect_count" -gt 0 ]; then
      check_result pass "Connect scripts installed (${_connect_count} team(s))"
    else
      check_result fail "No connect scripts found" "Re-run: aiteamforge setup --cockpit-only"
    fi
  fi

  echo ""
}

# Check services
check_services() {
  echo -e "${CYAN}Checking services...${NC}"
  echo ""

  # In cockpit mode, no local services are expected — LCARS runs on the remote host.
  # Skip LCARS/fleet checks to avoid false "not running" warnings.
  if [ "$INSTALL_PROFILE" = "cockpit" ]; then
    check_result pass "LCARS Kanban server (not applicable — cockpit profile, runs on remote host)"
    check_result pass "Fleet Monitor (not applicable — cockpit profile)"
    check_result pass "LaunchAgents (not installed — cockpit profile)"
    echo ""
    return
  fi

  # LCARS Kanban server — read port from config, check root URL (no /health endpoint)
  local lcars_port=8080
  if [ -f "${AITEAMFORGE_DIR}/lcars-ui/.lcars-port" ]; then
    lcars_port="$(cat "${AITEAMFORGE_DIR}/lcars-ui/.lcars-port" 2>/dev/null || echo 8080)"
  fi
  if curl -s -o /dev/null -w '%{http_code}' "http://localhost:${lcars_port}/" 2>/dev/null | grep -q '200'; then
    check_result pass "LCARS Kanban server (port ${lcars_port})"
  else
    check_result warn "LCARS Kanban server not running" "Start: aiteamforge start lcars"
  fi

  # Fleet Monitor — check server AND client (reporter)
  if [ -d "${AITEAMFORGE_DIR}/fleet-monitor/server" ]; then
    # Server mode: check if server is running
    if curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/ 2>/dev/null | grep -q '200'; then
      check_result pass "Fleet Monitor server (port 3000)"
    else
      check_result warn "Fleet Monitor server not running"
    fi
  fi

  # Fleet reporter client
  if [ -f "${AITEAMFORGE_DIR}/fleet-monitor/client/fleet-reporter.sh" ]; then
    check_result pass "Fleet reporter client installed"
  elif [ -f "$HOME/.aiteamforge/fleet-config.json" ]; then
    check_result warn "Fleet reporter config exists but script missing"
  fi

  # Fleet reporter LaunchAgent
  if launchctl list 2>/dev/null | grep -q "com.aiteamforge.fleet-reporter"; then
    check_result pass "Fleet reporter LaunchAgent loaded"
  elif [ -f "${AITEAMFORGE_DIR}/fleet-monitor/client/fleet-reporter.sh" ]; then
    check_result warn "Fleet reporter LaunchAgent not loaded"
  fi

  # LaunchAgents — XACA-0734 (review #1): ported to the SHARED mandatory set.
  #
  # Note the cockpit early-return at the top of this function already handled the
  # cockpit case, but this gate ALSO covers the kanban-declined install, which the
  # profile marker alone does not. It is the same gate `aiteamforge doctor` and
  # `aiteamforge upgrade` use, which is the whole point: three tools, one answer.
  local _la_dir="${LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"

  if [ "$_LAUNCHAGENTS_LIB_OK" = true ] && ! _xaca0734_launchagents_applicable "$AITEAMFORGE_DIR"; then
    check_result pass "LaunchAgents (not applicable — $(_xaca0734_launchagents_skip_reason "$AITEAMFORGE_DIR"))"
  elif [ "$_LAUNCHAGENTS_LIB_OK" = true ]; then
    local _agent _label
    for _agent in $(_xaca0734_mandatory_launchagent_basenames); do
      _label="${_agent%.plist}"
      if _xaca0734_launchctl_is_loaded "$_label"; then
        check_result pass "${_label} LaunchAgent"
      elif [ -f "${_la_dir}/${_agent}" ]; then
        # Present but not loaded — a re-login or an explicit load fixes it.
        check_result warn "${_label} LaunchAgent not loaded" "Load: launchctl load ${_la_dir}/${_agent}"
      elif _xaca0734_is_opted_out "$_agent"; then
        # Recorded opt-out: absence is the CORRECT state here, not a defect.
        check_result pass "${_label} LaunchAgent absent (opted out — intentional)"
      else
        # MISSING ENTIRELY and nobody asked for that. This is the M1Pro failure:
        # not merely unloaded — nonexistent, with nothing on the box that would
        # ever create it. A FAIL with a real fix, not a shrug.
        check_result fail "${_label} LaunchAgent MISSING: ${_la_dir}/${_agent}" \
          "Fix: aiteamforge upgrade   (re-materializes mandatory LaunchAgents)"
      fi
    done
  else
    # Legacy fallback — lib unavailable (partially-upgraded install).
    if launchctl list 2>/dev/null | grep -qF "com.aiteamforge.kanban-backup"; then
      check_result pass "Kanban backup LaunchAgent"
    else
      check_result warn "Kanban backup LaunchAgent not loaded"
    fi

    if launchctl list 2>/dev/null | grep -qF "com.aiteamforge.lcars-health"; then
      check_result pass "LCARS health LaunchAgent"
    else
      check_result warn "LCARS health LaunchAgent not loaded"
    fi
  fi

  echo ""
}

# Check permissions
check_permissions() {
  echo -e "${CYAN}Checking permissions...${NC}"
  echo ""

  # Working directory writable
  if [ -w "$AITEAMFORGE_DIR" ]; then
    check_result pass "Working directory writable"
  else
    check_result fail "Working directory not writable: ${AITEAMFORGE_DIR}"
  fi

  # Scripts executable
  if [ -x "${AITEAMFORGE_HOME}/bin/aiteamforge-cli.sh" ]; then
    check_result pass "CLI scripts executable"
  else
    check_result fail "CLI scripts not executable"
  fi

  echo ""
}

# Check post-install structure via validate-install library
check_install() {
  echo -e "${CYAN}Checking post-install structure...${NC}"
  echo ""

  # Locate validate-install library alongside this script's framework home
  local val_lib=""
  for _cand in \
      "${AITEAMFORGE_HOME}/libexec/lib/validate-install.sh" \
      "$(dirname "$(realpath "$0" 2>/dev/null || echo "$0")")/../libexec/lib/validate-install.sh"; do
    if [ -f "$_cand" ]; then
      val_lib="$_cand"
      break
    fi
  done

  if [ -z "$val_lib" ]; then
    echo -e "${YELLOW}⚠ validate-install library not found — skipping${NC}"
    echo "  Expected: ${AITEAMFORGE_HOME}/libexec/lib/validate-install.sh"
    WARNING_CHECKS=$((WARNING_CHECKS + 1))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    return
  fi

  # Source and run — the library manages its own output and counters
  source "$val_lib"
  if validate_installation "${AITEAMFORGE_DIR}"; then
    PASSED_CHECKS=$((PASSED_CHECKS + _VAL_PASS))
    WARNING_CHECKS=$((WARNING_CHECKS + _VAL_WARN))
    TOTAL_CHECKS=$((TOTAL_CHECKS + _VAL_PASS + _VAL_WARN + _VAL_FAIL))
  else
    PASSED_CHECKS=$((PASSED_CHECKS + _VAL_PASS))
    WARNING_CHECKS=$((WARNING_CHECKS + _VAL_WARN))
    FAILED_CHECKS=$((FAILED_CHECKS + _VAL_FAIL))
    TOTAL_CHECKS=$((TOTAL_CHECKS + _VAL_PASS + _VAL_WARN + _VAL_FAIL))
  fi
}

# Run checks based on component
case "$CHECK_COMPONENT" in
  dependencies)
    check_dependencies
    ;;
  framework)
    check_framework
    ;;
  helpers-drift)
    check_kanban_helpers_inventory
    ;;
  config)
    check_config
    ;;
  services)
    check_services
    ;;
  permissions)
    check_permissions
    ;;
  install)
    check_install
    ;;
  all)
    check_dependencies
    check_framework
    check_kanban_helpers_inventory
    check_config
    check_services
    check_permissions
    check_install
    ;;
  *)
    echo -e "${RED}ERROR: Unknown component: ${CHECK_COMPONENT}${NC}" >&2
    usage >&2
    exit 1
    ;;
esac

# Summary
echo -e "${BOLD}Summary${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total checks:    ${TOTAL_CHECKS}"
echo -e "Passed:          ${GREEN}${PASSED_CHECKS}${NC}"
echo -e "Warnings:        ${YELLOW}${WARNING_CHECKS}${NC}"
echo -e "Failed:          ${RED}${FAILED_CHECKS}${NC}"
echo ""

# Overall status
if [ $FAILED_CHECKS -eq 0 ]; then
  if [ $WARNING_CHECKS -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed - aiteamforge is healthy!${NC}"
    exit 0
  else
    echo -e "${YELLOW}⚠ Some warnings detected - aiteamforge should work but has minor issues${NC}"
    exit 0
  fi
else
  echo -e "${RED}✗ Some checks failed - aiteamforge may not function correctly${NC}"
  echo ""
  if [ "$FIX" = true ]; then
    echo "Attempting to fix issues..."
    # Placeholder for auto-fix functionality
    echo "(Auto-fix not yet implemented)"
  else
    echo "Run with --fix to attempt automatic fixes"
    echo "Or run: aiteamforge setup --upgrade"
  fi
  exit 1
fi
