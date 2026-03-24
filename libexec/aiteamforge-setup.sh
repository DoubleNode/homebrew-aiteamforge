#!/usr/bin/env zsh

# aiteamforge-setup.sh
# Interactive setup wizard for AITeamForge
# Guides new users through machine setup and configuration

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════════════

# Determine script location (works in Homebrew installation or development)
SCRIPT_DIR="${0:A:h}"
LIB_DIR="${SCRIPT_DIR}/lib"

# Default installation paths
DEFAULT_INSTALL_DIR="${HOME}/aiteamforge"
CONFIG_DIR="${HOME}/.aiteamforge"
CONFIG_FILE="${CONFIG_DIR}/config.json"

# Version
VERSION="0.5.0"

# ═══════════════════════════════════════════════════════════════════════════
# Source UI Library
# ═══════════════════════════════════════════════════════════════════════════

if [ ! -f "${LIB_DIR}/wizard-ui.sh" ]; then
  echo "ERROR: Cannot find wizard-ui.sh library"
  echo "Expected location: ${LIB_DIR}/wizard-ui.sh"
  exit 1
fi

source "${LIB_DIR}/wizard-ui.sh"

# ═══════════════════════════════════════════════════════════════════════════
# Global Variables
# ═══════════════════════════════════════════════════════════════════════════

# Flags
DRY_RUN=false
NON_INTERACTIVE=false
VERBOSE=false

# Installation selections (will be populated by wizard)
MACHINE_NAME=""
USER_NAME=""
SELECTED_TEAMS=()
INSTALL_KANBAN=true
INSTALL_FLEET_MONITOR=false
INSTALL_SHELL_ENV=true
INSTALL_CLAUDE_CONFIG=true
INSTALL_ITERM_INTEGRATION=false

# Dependency status
MISSING_DEPS=()
MISSING_OPTIONAL_DEPS=()

# ═══════════════════════════════════════════════════════════════════════════
# Available Teams
# ═══════════════════════════════════════════════════════════════════════════

# Team definitions: name|description
AVAILABLE_TEAMS=(
  "iOS|iOS app development team"
  "Android|Android app development team"
  "Firebase|Backend and Firebase functions team"
  "Academy|Infrastructure and tooling team"
  "DNS|DNS Framework development team"
  "Freelance|Freelance project team (full-stack)"
  "Command|Strategic leadership team"
  "Legal|Legal and compliance team"
  "Medical|Healthcare and compliance team"
  "MainEvent|Main Event cross-platform coordination"
)

# ═══════════════════════════════════════════════════════════════════════════
# Utility Functions
# ═══════════════════════════════════════════════════════════════════════════

# Check if command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Get version of installed tool
get_version() {
  local cmd="$1"
  case "$cmd" in
    python3)
      python3 --version 2>&1 | awk '{print $2}'
      ;;
    node)
      node --version 2>&1 | sed 's/^v//'
      ;;
    git)
      git --version 2>&1 | awk '{print $3}'
      ;;
    gh)
      gh --version 2>&1 | head -1 | awk '{print $3}'
      ;;
    jq)
      jq --version 2>&1 | sed 's/^jq-//'
      ;;
    claude)
      claude --version 2>&1 || echo "unknown"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

# ═══════════════════════════════════════════════════════════════════════════
# Stage 1: Welcome & Prerequisites Check
# ═══════════════════════════════════════════════════════════════════════════

stage_welcome() {
  clear_screen
  print_welcome_banner

  if [ "$NON_INTERACTIVE" = false ]; then
    press_any_key
  fi
}

stage_check_prerequisites() {
  print_section "Checking Prerequisites"

  # Required dependencies
  local required_deps=(
    "git:Git version control"
    "python3:Python 3 runtime"
    "node:Node.js runtime"
    "jq:JSON processor"
    "gh:GitHub CLI"
  )

  # Optional dependencies
  local optional_deps=(
    "claude:Claude Code CLI"
    "brew:Homebrew package manager"
  )

  # Check required dependencies
  print_info "Checking required dependencies..."
  echo ""

  for dep_info in "${required_deps[@]}"; do
    local dep="${dep_info%%:*}"
    local desc="${dep_info#*:}"

    if command_exists "$dep"; then
      local version=$(get_version "$dep")
      print_status "$desc" "ok ($version)"
    else
      print_status "$desc" "missing"
      MISSING_DEPS+=("$dep")
    fi
  done

  echo ""

  # Check optional dependencies
  print_info "Checking optional dependencies..."
  echo ""

  for dep_info in "${optional_deps[@]}"; do
    local dep="${dep_info%%:*}"
    local desc="${dep_info#*:}"

    if command_exists "$dep"; then
      local version=$(get_version "$dep")
      print_status "$desc" "ok ($version)"
    else
      print_status "$desc" "missing"
      MISSING_OPTIONAL_DEPS+=("$dep")
    fi
  done

  echo ""

  # Report missing dependencies
  if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    print_error "Missing required dependencies: ${MISSING_DEPS[*]}"
    echo ""
    print_info "Installation instructions:"
    echo ""

    for dep in "${MISSING_DEPS[@]}"; do
      case "$dep" in
        git)
          echo "  • Git: Install Xcode Command Line Tools"
          echo "    xcode-select --install"
          ;;
        python3)
          echo "  • Python 3: brew install python3"
          ;;
        node)
          echo "  • Node.js: brew install node"
          ;;
        jq)
          echo "  • jq: brew install jq"
          ;;
        gh)
          echo "  • GitHub CLI: brew install gh"
          ;;
      esac
    done

    echo ""
    die "Please install missing dependencies and run setup again"
  fi

  if [ ${#MISSING_OPTIONAL_DEPS[@]} -gt 0 ]; then
    print_warning "Missing optional dependencies: ${MISSING_OPTIONAL_DEPS[*]}"
    echo ""

    for dep in "${MISSING_OPTIONAL_DEPS[@]}"; do
      case "$dep" in
        claude)
          echo "  • Claude Code: npm install -g @anthropic-ai/claude-code"
          ;;
        brew)
          echo "  • Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
          ;;
      esac
    done

    echo ""

    if [ "$NON_INTERACTIVE" = false ]; then
      if prompt_yes_no "Continue without optional dependencies?" "y"; then
        print_info "Continuing with warnings..."
      else
        die "Setup cancelled by user"
      fi
    fi
  else
    print_success "All dependencies satisfied"
  fi

  if [ "$NON_INTERACTIVE" = false ]; then
    echo ""
    press_any_key
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Stage 2: Machine Identity
# ═══════════════════════════════════════════════════════════════════════════

stage_machine_identity() {
  print_section "Machine Identity Configuration"

  print_info "This information is used to identify this machine in Fleet Monitor"
  print_info "and helps coordinate multi-machine development setups."
  echo ""

  # Get machine name
  local default_machine_name=$(hostname -s)
  if [ "$NON_INTERACTIVE" = true ]; then
    MACHINE_NAME="$default_machine_name"
  else
    MACHINE_NAME=$(prompt_text "Machine name (e.g., 'macbook-pro-office', 'mac-studio-home'):" "$default_machine_name")
  fi

  # Get user name
  local default_user_name=$(id -F 2>/dev/null || echo "$USER")
  if [ "$NON_INTERACTIVE" = true ]; then
    USER_NAME="$default_user_name"
  else
    USER_NAME=$(prompt_text "Your name/display name:" "$default_user_name")
  fi

  echo ""
  print_success "Machine identity configured"
  print_info "Machine: $MACHINE_NAME"
  print_info "User: $USER_NAME"

  if [ "$NON_INTERACTIVE" = false ]; then
    echo ""
    press_any_key
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Stage 3: Team Selection
# ═══════════════════════════════════════════════════════════════════════════

stage_team_selection() {
  print_section "Team Selection"

  print_info "Select the teams you want to configure on this machine."
  print_info "You can select multiple teams."
  echo ""

  if [ "$NON_INTERACTIVE" = true ]; then
    # In non-interactive mode, read from config file
    print_warning "Non-interactive mode: team selection skipped (configure via config file)"
    return
  fi

  # Build display list of teams
  local team_display=()
  local team_ids=()

  for team_info in "${AVAILABLE_TEAMS[@]}"; do
    local team_id="${team_info%%|*}"
    local team_desc="${team_info#*|}"
    team_display+=("$team_id - $team_desc")
    team_ids+=("$team_id")
  done

  # Get user selection
  local selected_indices=($(prompt_multi_select "Select teams:" "${team_display[@]}"))

  # Build selected teams array
  SELECTED_TEAMS=()
  for idx in "${selected_indices[@]}"; do
    SELECTED_TEAMS+=("${team_ids[$((idx + 1))]}")
  done

  echo ""
  print_success "Selected teams: ${SELECTED_TEAMS[*]}"

  echo ""
  press_any_key
}

# ═══════════════════════════════════════════════════════════════════════════
# Stage 4: Feature Selection
# ═══════════════════════════════════════════════════════════════════════════

stage_feature_selection() {
  print_section "Feature Selection"

  print_info "Select optional features to install."
  echo ""

  if [ "$NON_INTERACTIVE" = true ]; then
    # In non-interactive mode, use defaults
    print_info "Non-interactive mode: using default feature selections"
    return
  fi

  # LCARS Kanban System
  if prompt_yes_no "Install LCARS Kanban system?" "y"; then
    INSTALL_KANBAN=true
  else
    INSTALL_KANBAN=false
  fi

  # Fleet Monitor
  if prompt_yes_no "Install Fleet Monitor (for multi-machine setups)?" "n"; then
    INSTALL_FLEET_MONITOR=true
  else
    INSTALL_FLEET_MONITOR=false
  fi

  # Shell Environment
  if prompt_yes_no "Install shell environment (prompts, aliases)?" "y"; then
    INSTALL_SHELL_ENV=true
  else
    INSTALL_SHELL_ENV=false
  fi

  # Claude Code Configuration
  if prompt_yes_no "Install Claude Code configuration?" "y"; then
    INSTALL_CLAUDE_CONFIG=true
  else
    INSTALL_CLAUDE_CONFIG=false
  fi

  # iTerm2 Integration
  if prompt_yes_no "Install iTerm2 integration (requires iTerm2)?" "n"; then
    INSTALL_ITERM_INTEGRATION=true
  else
    INSTALL_ITERM_INTEGRATION=false
  fi

  echo ""
  print_success "Feature selection complete"

  echo ""
  press_any_key
}

# ═══════════════════════════════════════════════════════════════════════════
# Stage 5: Configuration Generation
# ═══════════════════════════════════════════════════════════════════════════

stage_generate_config() {
  print_section "Generating Configuration"

  # Create config directory
  if [ "$DRY_RUN" = false ]; then
    mkdir -p "$CONFIG_DIR"
  fi

  # Generate config.json
  local teams_json=""
  if [ ${#SELECTED_TEAMS[@]} -gt 0 ]; then
    teams_json=$(printf '"%s",' "${SELECTED_TEAMS[@]}" | sed 's/,$//')
  fi

  local config_json=$(cat <<EOF
{
  "version": "$VERSION",
  "machine": {
    "name": "$MACHINE_NAME",
    "hostname": "$(hostname)",
    "user": "$USER_NAME"
  },
  "teams": [$teams_json],
  "features": {
    "kanban": $INSTALL_KANBAN,
    "fleet_monitor": $INSTALL_FLEET_MONITOR,
    "shell_env": $INSTALL_SHELL_ENV,
    "claude_config": $INSTALL_CLAUDE_CONFIG,
    "iterm_integration": $INSTALL_ITERM_INTEGRATION
  },
  "paths": {
    "install_dir": "$DEFAULT_INSTALL_DIR",
    "config_dir": "$CONFIG_DIR"
  },
  "installed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
  )

  if [ "$DRY_RUN" = false ]; then
    echo "$config_json" > "$CONFIG_FILE"
    print_success "Configuration saved to: $CONFIG_FILE"
  else
    print_info "[DRY RUN] Would save configuration to: $CONFIG_FILE"
    echo ""
    print_info "Configuration preview:"
    echo "$config_json"
  fi

  if [ "$NON_INTERACTIVE" = false ]; then
    echo ""
    press_any_key
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Stage 6: Installation Orchestration
# ═══════════════════════════════════════════════════════════════════════════

stage_installation() {
  print_section "Installing Components"

  local total_steps=0
  local current_step=0

  # Count enabled features
  [ "$INSTALL_SHELL_ENV" = true ] && total_steps=$((total_steps + 1))
  [ "$INSTALL_CLAUDE_CONFIG" = true ] && total_steps=$((total_steps + 1))
  [ "$INSTALL_KANBAN" = true ] && total_steps=$((total_steps + 1))
  [ "$INSTALL_FLEET_MONITOR" = true ] && total_steps=$((total_steps + 1))
  [ ${#SELECTED_TEAMS[@]} -gt 0 ] && total_steps=$((total_steps + 1))

  echo ""

  # Phase 1: Shell Environment (if enabled)
  if [ "$INSTALL_SHELL_ENV" = true ]; then
    current_step=$((current_step + 1))
    print_progress "$current_step" "$total_steps" "Installing shell environment"
    install_shell_environment
  fi

  # Phase 2: Claude Code Configuration (if enabled)
  if [ "$INSTALL_CLAUDE_CONFIG" = true ]; then
    current_step=$((current_step + 1))
    print_progress "$current_step" "$total_steps" "Installing Claude Code configuration"
    install_claude_config
  fi

  # Phase 3: LCARS Kanban (if enabled)
  if [ "$INSTALL_KANBAN" = true ]; then
    current_step=$((current_step + 1))
    print_progress "$current_step" "$total_steps" "Installing LCARS Kanban system"
    install_lcars_kanban
  fi

  # Phase 4: Fleet Monitor (if enabled)
  if [ "$INSTALL_FLEET_MONITOR" = true ]; then
    current_step=$((current_step + 1))
    print_progress "$current_step" "$total_steps" "Installing Fleet Monitor"
    install_fleet_monitor
  fi

  # Phase 5: Team-Specific Setup (if teams selected)
  if [ ${#SELECTED_TEAMS[@]} -gt 0 ]; then
    current_step=$((current_step + 1))
    print_progress "$current_step" "$total_steps" "Configuring team environments"
    install_team_configs
  fi

  echo ""
  print_success "All components installed successfully"

  if [ "$NON_INTERACTIVE" = false ]; then
    echo ""
    press_any_key
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Installer Modules - Wire to actual installer scripts
# ═══════════════════════════════════════════════════════════════════════════

install_shell_environment() {
  if [ "$DRY_RUN" = true ]; then
    print_info "[DRY RUN] Would install shell environment"
    return 0
  fi

  # Set environment variables for installer
  export INSTALL_ROOT="${SCRIPT_DIR}"
  export AITEAMFORGE_DIR="${DEFAULT_INSTALL_DIR}"

  # Source and run the actual installer
  local installer="${SCRIPT_DIR}/installers/install-shell.sh"
  if [ ! -f "$installer" ]; then
    print_error "Shell installer not found: $installer"
    return 1
  fi

  source "$installer"
  install_shell_environment
}

install_claude_config() {
  if [ "$DRY_RUN" = true ]; then
    print_info "[DRY RUN] Would install Claude Code configuration"
    return 0
  fi

  # Set environment variables for installer
  export INSTALL_ROOT="${SCRIPT_DIR}"
  export AITEAMFORGE_DIR="${DEFAULT_INSTALL_DIR}"

  # Source and run the actual installer
  local installer="${SCRIPT_DIR}/installers/install-claude-config.sh"
  if [ ! -f "$installer" ]; then
    print_error "Claude config installer not found: $installer"
    return 1
  fi

  source "$installer"
  install_claude_config
}

install_lcars_kanban() {
  if [ "$DRY_RUN" = true ]; then
    print_info "[DRY RUN] Would install LCARS Kanban system"
    return 0
  fi

  # Set environment variables for installer
  export INSTALL_ROOT="${SCRIPT_DIR}"
  export AITEAMFORGE_DIR="${DEFAULT_INSTALL_DIR}"

  # Source and run the actual installer
  local installer="${SCRIPT_DIR}/installers/install-kanban.sh"
  if [ ! -f "$installer" ]; then
    print_error "Kanban installer not found: $installer"
    return 1
  fi

  source "$installer"
  install_kanban_system
}

install_fleet_monitor() {
  if [ "$DRY_RUN" = true ]; then
    print_info "[DRY RUN] Would install Fleet Monitor"
    return 0
  fi

  # Set environment variables for installer
  export INSTALL_ROOT="${SCRIPT_DIR}"
  export AITEAMFORGE_DIR="${DEFAULT_INSTALL_DIR}"

  # Source and run the actual installer
  local installer="${SCRIPT_DIR}/installers/install-fleet-monitor.sh"
  if [ ! -f "$installer" ]; then
    print_error "Fleet Monitor installer not found: $installer"
    return 1
  fi

  source "$installer"
  install_fleet_monitor
}

install_team_configs() {
  if [ "$DRY_RUN" = true ]; then
    print_info "[DRY RUN] Would configure teams: ${SELECTED_TEAMS[*]}"
    return 0
  fi

  # Set environment variables for installer
  export INSTALL_ROOT="${SCRIPT_DIR}"
  export AITEAMFORGE_DIR="${DEFAULT_INSTALL_DIR}"

  # Run installer as subprocess for each selected team
  local installer="${SCRIPT_DIR}/installers/install-team.sh"
  if [ ! -f "$installer" ]; then
    print_error "Team installer not found: $installer"
    return 1
  fi

  for team in "${SELECTED_TEAMS[@]}"; do
    bash "$installer" "$team" --install-dir "$AITEAMFORGE_DIR"
  done
}

# ═══════════════════════════════════════════════════════════════════════════
# Stage 7: Summary & Next Steps
# ═══════════════════════════════════════════════════════════════════════════

stage_summary() {
  print_completion_banner

  print_info "Installation Summary:"
  echo ""

  # Machine info
  print_color "${COLOR_BLUE}" "Machine Configuration:"
  echo "  Name: $MACHINE_NAME"
  echo "  User: $USER_NAME"
  echo ""

  # Teams
  if [ ${#SELECTED_TEAMS[@]} -gt 0 ]; then
    print_color "${COLOR_BLUE}" "Configured Teams:"
    for team in "${SELECTED_TEAMS[@]}"; do
      echo "  • $team"
    done
    echo ""
  fi

  # Features
  print_color "${COLOR_BLUE}" "Installed Features:"
  [ "$INSTALL_KANBAN" = true ] && echo "  ✓ LCARS Kanban System"
  [ "$INSTALL_FLEET_MONITOR" = true ] && echo "  ✓ Fleet Monitor"
  [ "$INSTALL_SHELL_ENV" = true ] && echo "  ✓ Shell Environment"
  [ "$INSTALL_CLAUDE_CONFIG" = true ] && echo "  ✓ Claude Code Configuration"
  [ "$INSTALL_ITERM_INTEGRATION" = true ] && echo "  ✓ iTerm2 Integration"
  echo ""

  # Next steps
  print_color "${COLOR_AMBER}${COLOR_BOLD}" "Next Steps:"
  echo ""
  echo "  1. Restart your terminal to load shell environment"
  echo "  2. View configuration: cat $CONFIG_FILE"

  if [ "$INSTALL_KANBAN" = true ]; then
    echo "  3. Access LCARS Kanban: open http://localhost:8082"
  fi

  if [ "$INSTALL_CLAUDE_CONFIG" = true ]; then
    echo "  4. Start Claude Code: claude"
  fi

  echo ""

  # Warnings (if any)
  if [ ${#MISSING_OPTIONAL_DEPS[@]} -gt 0 ]; then
    print_warning "Optional dependencies missing: ${MISSING_OPTIONAL_DEPS[*]}"
    print_info "Some features may not work until these are installed"
    echo ""
  fi

  # Support info
  print_color "${COLOR_LILAC}" "For help and documentation:"
  echo "  • Quick Reference: $DEFAULT_INSTALL_DIR/docs/QUICK_REFERENCE.md"
  echo "  • Onboarding Guide: $DEFAULT_INSTALL_DIR/docs/ONBOARDING_GUIDE.md"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# Main Workflow
# ═══════════════════════════════════════════════════════════════════════════

main() {
  # Parse command-line arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        print_info "DRY RUN MODE: No changes will be made"
        shift
        ;;
      --non-interactive)
        NON_INTERACTIVE=true
        shift
        ;;
      --verbose)
        VERBOSE=true
        shift
        ;;
      --help)
        cat <<EOF
aiteamforge-setup - AITeamForge Setup Wizard

USAGE:
  aiteamforge-setup [OPTIONS]

OPTIONS:
  --dry-run          Preview changes without applying them
  --non-interactive  Run without prompts (uses config file or defaults)
  --verbose          Enable verbose output
  --help             Show this help message

EXAMPLES:
  # Interactive setup (recommended)
  aiteamforge-setup

  # Preview without changes
  aiteamforge-setup --dry-run

  # Automated setup from config file
  aiteamforge-setup --non-interactive

EOF
        exit 0
        ;;
      *)
        die "Unknown option: $1. Use --help for usage information"
        ;;
    esac
  done

  # Execute setup stages
  stage_welcome
  stage_check_prerequisites
  stage_machine_identity
  stage_team_selection
  stage_feature_selection
  stage_generate_config
  stage_installation
  stage_summary

  # Exit cleanly
  exit 0
}

# Run main function
main "$@"
