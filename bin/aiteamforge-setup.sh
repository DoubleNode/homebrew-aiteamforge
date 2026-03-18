#!/bin/bash
# AITeamForge Setup Wizard
# Interactive configuration and installation

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

VERSION="1.4.0"

# Banner
show_banner() {
  cat <<'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║                                                                      ║
║     █████╗ ██╗████████╗███████╗ █████╗ ███╗   ███╗                   ║
║    ██╔══██╗██║╚══██╔══╝██╔════╝██╔══██╗████╗ ████║                   ║
║    ███████║██║   ██║   █████╗  ███████║██╔████╔██║                   ║
║    ██╔══██║██║   ██║   ██╔══╝  ██╔══██║██║╚██╔╝██║                   ║
║    ██║  ██║██║   ██║   ███████╗██║  ██║██║ ╚═╝ ██║                   ║
║    ╚═╝  ╚═╝╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝                   ║
║                                                                      ║
║    ███████╗ ██████╗ ██████╗  ██████╗ ███████╗                        ║
║    ██╔════╝██╔═══██╗██╔══██╗██╔════╝ ██╔════╝                        ║
║    █████╗  ██║   ██║██████╔╝██║  ███╗█████╗                          ║
║    ██╔══╝  ██║   ██║██╔══██╗██║   ██║██╔══╝                          ║
║    ██║     ╚██████╔╝██║  ██║╚██████╔╝███████╗                        ║
║    ╚═╝      ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝                        ║
║                                                                      ║
║          AI-Powered Team Development Infrastructure                  ║
║                        Version 1.3.0                                 ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
  echo ""
}

# Usage
usage() {
  cat <<EOF
AITeamForge Setup Wizard v${VERSION}

Usage: aiteamforge setup [options]

Options:
  --install-dir DIR      Installation directory (default: ~/aiteamforge)
  --upgrade              Upgrade existing installation
  --uninstall            Remove aiteamforge configuration
  --non-interactive      Run in non-interactive mode
  -h, --help             Show this help

Interactive Mode:
  When run without options, launches interactive setup wizard
  to configure your aiteamforge environment.

Examples:
  aiteamforge setup                          # Interactive setup
  aiteamforge setup --install-dir ~/my-team  # Custom location
  aiteamforge setup --upgrade                # Upgrade existing
  aiteamforge setup --uninstall              # Clean removal
EOF
}

# Save original args for re-exec after dependency install
ORIGINAL_ARGS=("$@")

# Parse arguments
INSTALL_DIR="$HOME/aiteamforge"
MODE="interactive"
IS_UPGRADE="false"

while [[ $# -gt 0 ]]; do
  case $1 in
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --upgrade)
      IS_UPGRADE="true"
      shift
      ;;
    --uninstall)
      MODE="uninstall"
      shift
      ;;
    --non-interactive)
      MODE="non-interactive"
      shift
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

# Check if already configured
is_configured() {
  [ -f "${INSTALL_DIR}/.aiteamforge-config" ]
}

# Uninstall mode
if [ "$MODE" = "uninstall" ]; then
  echo -e "${BOLD}AITeamForge Uninstall${NC}"
  echo ""

  if ! is_configured; then
    echo -e "${YELLOW}⚠ No aiteamforge installation found at: ${INSTALL_DIR}${NC}"
    exit 0
  fi

  echo "This will remove:"
  echo "  • Dev-team configuration from: ${INSTALL_DIR}"
  echo "  • LaunchAgents (kanban-backup, lcars-health)"
  echo "  • Shell integration from ~/.zshrc"
  echo ""
  echo -e "${RED}Warning: This will NOT remove the Homebrew formula${NC}"
  echo "To fully remove aiteamforge, also run: brew uninstall aiteamforge"
  echo ""
  read -p "Continue with uninstall? (yes/no): " confirm

  if [ "$confirm" != "yes" ]; then
    echo "Uninstall cancelled"
    exit 0
  fi

  # Remove LaunchAgents
  if [ -f "$HOME/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist" ]; then
    launchctl unload "$HOME/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist" 2>/dev/null || true
    rm "$HOME/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist"
    echo -e "${GREEN}✓${NC} Removed kanban-backup LaunchAgent"
  fi

  if [ -f "$HOME/Library/LaunchAgents/com.aiteamforge.lcars-health.plist" ]; then
    launchctl unload "$HOME/Library/LaunchAgents/com.aiteamforge.lcars-health.plist" 2>/dev/null || true
    rm "$HOME/Library/LaunchAgents/com.aiteamforge.lcars-health.plist"
    echo -e "${GREEN}✓${NC} Removed lcars-health LaunchAgent"
  fi

  # Remove shell integration (backup first)
  if [ -f "$HOME/.zshrc" ]; then
    cp "$HOME/.zshrc" "$HOME/.zshrc.backup.$(date +%s)"
    # Remove aiteamforge sourcing lines
    grep -v "aiteamforge" "$HOME/.zshrc" > "$HOME/.zshrc.tmp" || true
    mv "$HOME/.zshrc.tmp" "$HOME/.zshrc"
    echo -e "${GREEN}✓${NC} Removed shell integration (backed up .zshrc)"
  fi

  # Ask about removing working directory
  echo ""
  read -p "Remove working directory ${INSTALL_DIR}? (yes/no): " remove_dir

  if [ "$remove_dir" = "yes" ]; then
    rm -rf "${INSTALL_DIR}"
    echo -e "${GREEN}✓${NC} Removed ${INSTALL_DIR}"
  else
    # Just remove config marker
    rm -f "${INSTALL_DIR}/.aiteamforge-config"
    echo -e "${GREEN}✓${NC} Unmarked installation (files preserved)"
  fi

  echo ""
  echo -e "${GREEN}AITeamForge uninstalled successfully${NC}"
  echo "To reinstall: aiteamforge setup"
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# Helper: prompt with non-interactive support
# Usage: wizard_prompt "prompt text" default_value variable_name
# In non-interactive mode, always uses default_value
# ═══════════════════════════════════════════════════════════════════════════
wizard_prompt() {
  local prompt_text="$1"
  local default_val="$2"

  if [ "$MODE" = "non-interactive" ]; then
    echo "$default_val"
    return
  fi

  local answer
  read -p "$prompt_text" answer
  echo "${answer:-$default_val}"
}

# Interactive setup
show_banner

echo -e "${CYAN}This wizard will configure your AITeamForge.${NC}"
if [ "$MODE" = "non-interactive" ]; then
  echo -e "${CYAN}Running in non-interactive mode — using defaults.${NC}"
fi
echo ""

# Check dependencies
echo -e "${BOLD}Checking dependencies...${NC}"
echo ""

MISSING_DEPS=()

check_dep() {
  local cmd=$1
  local name=$2
  local install=$3

  if command -v "$cmd" &>/dev/null; then
    echo -e "${GREEN}✓${NC} $name"
  else
    echo -e "${RED}✗${NC} $name ${YELLOW}(missing)${NC}"
    MISSING_DEPS+=("$name:$install")
  fi
}

check_dep "python3" "Python 3" "brew install python@3.13"
check_dep "node" "Node.js" "brew install node"
check_dep "jq" "jq" "brew install jq"
check_dep "gh" "GitHub CLI" "brew install gh"
check_dep "git" "Git" "xcode-select --install"
check_dep "tmux" "tmux" "brew install tmux"

# Check for iTerm2 (application, not command)
if [ -d "/Applications/iTerm.app" ]; then
  echo -e "${GREEN}✓${NC} iTerm2"
else
  echo -e "${RED}✗${NC} iTerm2 ${YELLOW}(missing)${NC}"
  MISSING_DEPS+=("iTerm2:brew install --cask iterm2")
fi

# Check for Claude Code
if command -v claude &>/dev/null; then
  echo -e "${GREEN}✓${NC} Claude Code"
else
  echo -e "${RED}✗${NC} Claude Code ${YELLOW}(missing)${NC}"
  MISSING_DEPS+=("Claude Code:npm install -g @anthropic-ai/claude-code")
fi

# Check iTerm2 Python API (required for tab management)
if [ -d "/Applications/iTerm.app" ]; then
  api_enabled=$(defaults read com.googlecode.iterm2 EnableAPIServer 2>/dev/null || true)
  if [ "$api_enabled" = "1" ]; then
    echo -e "${GREEN}✓${NC} iTerm2 Python API"
  else
    echo -e "${YELLOW}⚠${NC} iTerm2 Python API ${YELLOW}(disabled)${NC}"
    if [ "$MODE" = "non-interactive" ]; then
      echo -e "  Enabling iTerm2 Python API..."
      defaults write com.googlecode.iterm2 EnableAPIServer -bool true
      echo -e "${GREEN}✓${NC} iTerm2 Python API (enabled)"
    else
      echo ""
      echo -e "  The iTerm2 Python API is required for automatic tab creation."
      echo -e "  Enable it now, or manually via: iTerm2 → Settings → General → Magic → Enable Python API"
      read -p "  Enable iTerm2 Python API? (yes/no) [yes]: " enable_api
      enable_api="${enable_api:-yes}"
      if [ "$enable_api" = "yes" ]; then
        defaults write com.googlecode.iterm2 EnableAPIServer -bool true
        echo -e "${GREEN}✓${NC} iTerm2 Python API (enabled)"
        echo -e "  ${YELLOW}Note: Restart iTerm2 for this to take effect.${NC}"
      else
        echo -e "${YELLOW}⚠${NC} Tab management will not work without Python API"
      fi
    fi
  fi
fi

echo ""

# Handle missing dependencies
if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
  echo -e "${YELLOW}⚠ Missing required dependencies${NC}"
  echo ""
  echo "Install missing dependencies:"
  echo ""
  for dep in "${MISSING_DEPS[@]}"; do
    name="${dep%%:*}"
    install="${dep#*:}"
    echo "  $install"
  done
  echo ""

  if [ "$MODE" = "non-interactive" ]; then
    echo -e "${YELLOW}⚠ Skipping missing dependencies in non-interactive mode${NC}"
  else
    read -p "Install missing dependencies now? (yes/no): " install_deps

    if [ "$install_deps" = "yes" ]; then
      echo ""
      echo -e "${BLUE}Installing dependencies...${NC}"
      for dep in "${MISSING_DEPS[@]}"; do
        install="${dep#*:}"
        echo "Running: $install"
        # Execute directly without eval - install commands are hardcoded in script
        bash -c "$install" || echo -e "${RED}Failed: $install${NC}"
      done
      echo ""
      echo -e "${GREEN}Dependencies installed${NC}"
      echo ""
      echo "Restarting setup wizard..."
      echo ""
      sleep 1
      exec bash "$0" "${ORIGINAL_ARGS[@]}"
    else
      echo ""
      echo -e "${RED}Cannot continue without required dependencies${NC}"
      exit 1
    fi
  fi
fi

# Installation directory
echo -e "${BOLD}Installation Location${NC}"
echo ""
echo "Default installation directory: ${INSTALL_DIR}"

if [ "$MODE" != "non-interactive" ]; then
  echo ""
  read -p "Use default location? (yes/no): " use_default

  if [ "$use_default" != "yes" ]; then
    read -p "Enter installation directory: " custom_dir
    INSTALL_DIR="${custom_dir/#\~/$HOME}" # Expand ~
  fi
fi

echo ""
echo "Installing to: ${INSTALL_DIR}"

# Check if already exists
if is_configured; then
  echo ""
  echo -e "${YELLOW}⚠ Existing installation found${NC}"

  if [ "$MODE" = "non-interactive" ]; then
    echo "Upgrading existing installation (non-interactive mode)"
    IS_UPGRADE="true"
  else
    echo ""
    read -p "Upgrade existing installation? (yes/no): " upgrade_existing

    if [ "$upgrade_existing" != "yes" ]; then
      echo "Setup cancelled"
      exit 0
    fi
    IS_UPGRADE="true"
  fi
fi

# Create installation directory
mkdir -p "${INSTALL_DIR}"

# ═══════════════════════════════════════════════════════════════════════════
# EXPORT VARIABLES FOR INSTALLER MODULES
# ═══════════════════════════════════════════════════════════════════════════

export AITEAMFORGE_DIR="${INSTALL_DIR}"
export INSTALL_ROOT="${AITEAMFORGE_HOME}"
INSTALLERS_DIR="${AITEAMFORGE_HOME}/libexec/installers"
TEAMS_DIR="${AITEAMFORGE_HOME}/share/teams"

# Source common utilities (used by installer modules)
source "${AITEAMFORGE_HOME}/libexec/lib/common.sh"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1: MACHINE IDENTITY
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}Step 1: Machine Identity${NC}"
echo ""
echo "Give this machine a name (used for Fleet Monitor and multi-machine setups)."
echo ""

DEFAULT_MACHINE_NAME="$(hostname -s 2>/dev/null || echo "my-mac")"

if [ "$MODE" = "non-interactive" ]; then
  MACHINE_NAME="$DEFAULT_MACHINE_NAME"
else
  read -p "Machine name [${DEFAULT_MACHINE_NAME}]: " MACHINE_NAME
  MACHINE_NAME="${MACHINE_NAME:-$DEFAULT_MACHINE_NAME}"
fi

echo ""
echo -e "${GREEN}✓${NC} Machine name: ${MACHINE_NAME}"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2: TEAM SELECTION
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}Step 2: Select Teams${NC}"
echo ""
echo "Choose which development teams to install."
echo "Each team includes agent personas, kanban board, and startup scripts."
echo ""

# Build list of available teams from .conf files
AVAILABLE_TEAMS=()
TEAM_LABELS=()

for conf_file in "${TEAMS_DIR}"/*.conf; do
  [ -f "$conf_file" ] || continue
  tid="$(basename "$conf_file" .conf)"

  # Read team name and description from conf
  tname="$(grep '^TEAM_NAME=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
  tdesc="$(grep '^TEAM_DESCRIPTION=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
  tcat="$(grep '^TEAM_CATEGORY=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"

  AVAILABLE_TEAMS+=("$tid")
  TEAM_LABELS+=("${tid} - ${tname} (${tdesc})")
done

# Display teams with numbers
for i in "${!TEAM_LABELS[@]}"; do
  echo "  $((i + 1))) ${TEAM_LABELS[$i]}"
done
echo ""
echo "Enter team numbers separated by spaces (e.g., '1 3 5'), or 'all' for everything."
echo ""

if [ "$MODE" = "non-interactive" ]; then
  team_choices="${AITEAMFORGE_TEAMS:-all}"
  echo "Teams to install: $team_choices (non-interactive)"
else
  read -p "Teams to install: " team_choices
fi

SELECTED_TEAMS=()
if [ "$team_choices" = "all" ]; then
  SELECTED_TEAMS=("${AVAILABLE_TEAMS[@]}")
else
  for choice in $team_choices; do
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#AVAILABLE_TEAMS[@]} ]; then
      SELECTED_TEAMS+=("${AVAILABLE_TEAMS[$((choice - 1))]}")
    else
      echo -e "${YELLOW}⚠ Skipping invalid choice: $choice${NC}"
    fi
  done
fi

if [ ${#SELECTED_TEAMS[@]} -eq 0 ]; then
  echo -e "${RED}No teams selected. At least one team is required.${NC}"
  exit 1
fi

echo ""
echo -e "${GREEN}✓${NC} Selected teams: ${SELECTED_TEAMS[*]}"

# -----------------------------------------------------------------------
# For project-based teams, ask for ClientID and/or ProjectID
# Uses eval instead of declare -A (bash 3.2 compatible)
# Variables: _PROJECT_<team_id>, _WORKDIR_<team_id>, _CLIENT_<team_id>
# -----------------------------------------------------------------------

for team_id in "${SELECTED_TEAMS[@]}"; do
  conf_file="${TEAMS_DIR}/${team_id}.conf"
  [ -f "$conf_file" ] || continue

  has_projects="$(grep '^TEAM_HAS_PROJECTS=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
  requires_client="$(grep '^TEAM_REQUIRES_CLIENT_ID=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
  working_dir="$(grep '^TEAM_WORKING_DIR=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
  working_dir="${working_dir/\$HOME/$HOME}" # Expand $HOME

  # If the conf's working_dir is the default ($HOME/aiteamforge), remap to the
  # user-chosen INSTALL_DIR so non-default installs stay self-contained.
  if [ "$working_dir" = "$HOME/aiteamforge" ] && [ "$INSTALL_DIR" != "$HOME/aiteamforge" ]; then
    working_dir="$INSTALL_DIR"
  fi

  if [ "$requires_client" = "true" ]; then
    # Team requires ClientID + ProjectID (e.g., freelance)
    default_project="$(grep '^TEAM_DEFAULT_PROJECT=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
    team_name="$(grep '^TEAM_NAME=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
    echo ""
    echo -e "${CYAN}${team_name}${NC} requires client and project identifiers"
    echo -e "  (e.g., client=acme, project=mobile-app → ${working_dir}/acme/mobile-app/)"

    if [ "$MODE" = "non-interactive" ]; then
      client_id="default-client"
    else
      read -p "  Client ID: " client_id
    fi
    if [ -z "$client_id" ]; then
      echo -e "  ${RED}Client ID is required. Skipping ${team_id}.${NC}"
      # Remove from selected teams
      SELECTED_TEAMS=("${SELECTED_TEAMS[@]/$team_id}")
      continue
    fi
    if [ "$MODE" = "non-interactive" ]; then
      project_id="${default_project}"
    else
      read -p "  Project ID [${default_project}]: " project_id
      project_id="${project_id:-$default_project}"
    fi
    eval "_PROJECT_${team_id}=\"${project_id}\""
    eval "_CLIENT_${team_id}=\"${client_id}\""
    eval "_WORKDIR_${team_id}=\"${working_dir}/${client_id}/${project_id}\""
    echo -e "  ${GREEN}✓${NC} ${team_id}: ${working_dir}/${client_id}/${project_id}"

  elif [ "$has_projects" = "true" ]; then
    # Team requires ProjectID only (e.g., legal, medical)
    default_project="$(grep '^TEAM_DEFAULT_PROJECT=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
    team_name="$(grep '^TEAM_NAME=' "$conf_file" 2>/dev/null | head -1 | cut -d'"' -f2 || true)"
    echo ""
    echo -e "${CYAN}${team_name}${NC} uses project-based organization"
    if [ "$MODE" = "non-interactive" ]; then
      project_id="${default_project}"
    else
      read -p "  Project ID [${default_project}]: " project_id
      project_id="${project_id:-$default_project}"
    fi
    eval "_PROJECT_${team_id}=\"${project_id}\""
    eval "_WORKDIR_${team_id}=\"${working_dir}/${project_id}\""
    echo -e "  ${GREEN}✓${NC} ${team_id}: ${working_dir}/${project_id}"

  else
    eval "_WORKDIR_${team_id}=\"${working_dir}\""
  fi
done

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3: FEATURE SELECTION
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}Step 3: Choose Features${NC}"
echo ""

if [ "$MODE" = "non-interactive" ]; then
  INSTALL_SHELL="yes"
  INSTALL_CLAUDE="yes"
  INSTALL_KANBAN="yes"
  INSTALL_FLEET="no"
  FLEET_MODE="standalone"
  FLEET_SERVER_URL=""
  echo -e "${GREEN}✓${NC} Features: shell=yes, claude=yes, kanban=yes, fleet=skip (defaults)"
else
  INSTALL_SHELL="no"
  INSTALL_CLAUDE="no"
  INSTALL_KANBAN="no"
  INSTALL_FLEET="no"

  # Shell Environment
  echo -e "${CYAN}Shell Environment${NC} — Terminal aliases, prompts, and helpers"
  read -p "  Install shell environment? (yes/no) [yes]: " ans
  INSTALL_SHELL="${ans:-yes}"
  echo ""

  # Claude Code Configuration
  echo -e "${CYAN}Claude Code Config${NC} — AI agent settings, hooks, and personas"
  read -p "  Install Claude Code config? (yes/no) [yes]: " ans
  INSTALL_CLAUDE="${ans:-yes}"
  echo ""

  # LCARS Kanban System
  echo -e "${CYAN}LCARS Kanban System${NC} — Visual task management with web UI"
  read -p "  Install LCARS Kanban? (yes/no) [yes]: " ans
  INSTALL_KANBAN="${ans:-yes}"
  echo ""

  # Fleet Monitor
  echo -e "${CYAN}Fleet Monitor${NC} — Cross-machine monitoring and agent status tracking"
  echo -e "  Fleet Monitor provides a web dashboard to see agent sessions across"
  echo -e "  all your development machines. Requires Tailscale for remote access."
  echo ""
  echo "  Options:"
  echo "    1) Skip       — Don't install Fleet Monitor"
  echo "    2) New Server — Set up a NEW Fleet Monitor server on this machine"
  echo "    3) Connect    — Connect this machine to an EXISTING Fleet Monitor"
  echo ""
  read -p "  Choose (1/2/3) [1]: " fleet_choice
  fleet_choice="${fleet_choice:-1}"

  FLEET_MODE="standalone"
  FLEET_SERVER_URL=""

  case "$fleet_choice" in
    2)
      INSTALL_FLEET="yes"
      FLEET_MODE="server"
      echo -e "  ${GREEN}✓${NC} Will set up a new Fleet Monitor server"
      ;;
    3)
      INSTALL_FLEET="yes"
      FLEET_MODE="client"
      echo ""
      echo "  Enter the URL of the existing Fleet Monitor server."
      echo "  (e.g., http://192.168.1.100:3000 or https://my-mac.tail12345.ts.net)"
      read -p "  Server URL: " FLEET_SERVER_URL
      if [ -z "$FLEET_SERVER_URL" ]; then
        echo -e "  ${RED}✗ No URL provided — skipping Fleet Monitor${NC}"
        INSTALL_FLEET="no"
      else
        echo -e "  ${GREEN}✓${NC} Will connect to: ${FLEET_SERVER_URL}"
      fi
      ;;
    *)
      echo -e "  Skipping Fleet Monitor"
      ;;
  esac
  echo ""
fi

echo -e "${GREEN}✓${NC} Features selected"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 4: CONFIRM & INSTALL
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}Installation Summary${NC}"
echo ""
echo "  Machine:    ${MACHINE_NAME}"
echo "  Directory:  ${INSTALL_DIR}"
echo "  Teams:      ${SELECTED_TEAMS[*]}"
echo "  Features:"
echo "    Shell Environment:   ${INSTALL_SHELL}"
echo "    Claude Code Config:  ${INSTALL_CLAUDE}"
echo "    LCARS Kanban:        ${INSTALL_KANBAN}"
if [ "$INSTALL_FLEET" = "yes" ]; then
  if [ "$FLEET_MODE" = "client" ]; then
    echo "    Fleet Monitor:       Connect to ${FLEET_SERVER_URL}"
  else
    echo "    Fleet Monitor:       New server (${FLEET_MODE} mode)"
  fi
else
  echo "    Fleet Monitor:       skip"
fi
echo ""

if [ "$MODE" = "non-interactive" ]; then
  echo "Proceeding with installation (non-interactive mode)..."
else
  read -p "Proceed with installation? (yes/no): " confirm

  if [ "$confirm" != "yes" ]; then
    echo "Setup cancelled."
    exit 0
  fi
fi

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Beginning Installation...${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
echo ""

INSTALL_ERRORS=0

# -----------------------------------------------------------------------
# Copy base framework files
# -----------------------------------------------------------------------
echo -e "${BOLD}Copying framework files...${NC}"
mkdir -p "${INSTALL_DIR}/share"
mkdir -p "${INSTALL_DIR}/docs"
mkdir -p "${INSTALL_DIR}/teams"

[ -d "${AITEAMFORGE_HOME}/share/templates" ] && cp -r "${AITEAMFORGE_HOME}/share/templates" "${INSTALL_DIR}/templates" 2>/dev/null && echo -e "${GREEN}✓${NC} Templates"
[ -d "${AITEAMFORGE_HOME}/docs" ] && cp -r "${AITEAMFORGE_HOME}/docs"/* "${INSTALL_DIR}/docs/" 2>/dev/null && echo -e "${GREEN}✓${NC} Documentation"
[ -d "${AITEAMFORGE_HOME}/share/teams" ] && cp -r "${AITEAMFORGE_HOME}/share/teams"/* "${INSTALL_DIR}/teams/" 2>/dev/null && echo -e "${GREEN}✓${NC} Team configurations"

# Copy scripts (window manager, agent panel display, helpers)
if [ -d "${AITEAMFORGE_HOME}/share/scripts" ]; then
  mkdir -p "${INSTALL_DIR}/scripts"
  cp "${AITEAMFORGE_HOME}/share/scripts/"* "${INSTALL_DIR}/scripts/" 2>/dev/null
  chmod +x "${INSTALL_DIR}/scripts/"*.sh "${INSTALL_DIR}/scripts/"*.py 2>/dev/null
  # Also copy window manager to root for backward compat with startup templates
  cp "${INSTALL_DIR}/scripts/iterm2_window_manager.py" "${INSTALL_DIR}/iterm2_window_manager.py" 2>/dev/null
  echo -e "${GREEN}✓${NC} Scripts (window manager, agent panel, helpers)"
fi

# Create Python venv with iterm2 package (required for tab management)
if [ ! -d "${INSTALL_DIR}/.venv" ]; then
  echo -e "${BOLD}Creating Python virtual environment...${NC}"
  if python3 -m venv "${INSTALL_DIR}/.venv" 2>/dev/null; then
    "${INSTALL_DIR}/.venv/bin/pip" install --quiet iterm2 2>/dev/null && \
      echo -e "${GREEN}✓${NC} Python venv with iterm2 package" || \
      echo -e "${YELLOW}⚠${NC} Python venv created but iterm2 install failed"
  else
    echo -e "${YELLOW}⚠${NC} Could not create Python venv (iTerm2 tab management may not work)"
  fi
else
  echo -e "${GREEN}✓${NC} Python venv (already exists)"
fi

# Copy skills (Claude Code slash commands)
if [ -d "${AITEAMFORGE_HOME}/share/skills" ]; then
  mkdir -p "${INSTALL_DIR}/skills"
  cp -r "${AITEAMFORGE_HOME}/share/skills"/* "${INSTALL_DIR}/skills/" 2>/dev/null && echo -e "${GREEN}✓${NC} Skills (Kanban Manager, git-worktree, Project Planner)"
fi

# Copy agent personas, avatars, and terminal logos for selected teams
_personas_copied=0
_logos_copied=0
for team_id in "${SELECTED_TEAMS[@]}"; do
  [ -z "$team_id" ] && continue
  # Agent personas and avatar thumbnails
  if [ -d "${AITEAMFORGE_HOME}/share/personas/${team_id}" ]; then
    mkdir -p "${INSTALL_DIR}/${team_id}/personas/agents"
    mkdir -p "${INSTALL_DIR}/${team_id}/personas/avatars"
    cp "${AITEAMFORGE_HOME}/share/personas/${team_id}/agents/"*.md "${INSTALL_DIR}/${team_id}/personas/agents/" 2>/dev/null
    cp "${AITEAMFORGE_HOME}/share/personas/${team_id}/avatars/"*.png "${INSTALL_DIR}/${team_id}/personas/avatars/" 2>/dev/null
    _personas_copied=$((_personas_copied + 1))
  fi
  # Terminal logos (for iTerm2 profiles)
  if [ -d "${AITEAMFORGE_HOME}/share/terminals/${team_id}/logos" ]; then
    mkdir -p "${INSTALL_DIR}/${team_id}/terminals/logos"
    cp "${AITEAMFORGE_HOME}/share/terminals/${team_id}/logos/"*.png "${INSTALL_DIR}/${team_id}/terminals/logos/" 2>/dev/null
    _logos_copied=$((_logos_copied + 1))
  fi
done
[ $_personas_copied -gt 0 ] && echo -e "${GREEN}✓${NC} Agent personas and avatars (${_personas_copied} teams)"
[ $_logos_copied -gt 0 ] && echo -e "${GREEN}✓${NC} Terminal logos (${_logos_copied} teams)"
echo ""

# -----------------------------------------------------------------------
# Install selected teams
# -----------------------------------------------------------------------
echo -e "${BOLD}Installing teams...${NC}"
echo ""

for team_id in "${SELECTED_TEAMS[@]}"; do
  [ -z "$team_id" ] && continue  # skip empty entries from removed teams
  eval "team_work_dir=\"\${_WORKDIR_${team_id}:-${INSTALL_DIR}/${team_id}}\""
  eval "team_project=\"\${_PROJECT_${team_id}:-}\""
  echo -e "${BLUE}  Installing team: ${team_id} → ${team_work_dir}${NC}"
  if [ -x "${INSTALLERS_DIR}/install-team.sh" ]; then
    AITEAMFORGE_DIR="${INSTALL_DIR}" TEAM_WORKING_DIR="${team_work_dir}" bash "${INSTALLERS_DIR}/install-team.sh" "$team_id" --install-dir "${INSTALL_DIR}" 2>&1 | sed 's/^/    /' || {
      echo -e "    ${RED}✗ Team ${team_id} had errors (continuing)${NC}"
      INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    }
  else
    # Fallback: create basic team directory structure
    mkdir -p "${team_work_dir}"
    echo -e "    ${GREEN}✓${NC} Created ${team_work_dir}/ directory"
  fi
  echo ""
done

# -----------------------------------------------------------------------
# Install Shell Environment
# -----------------------------------------------------------------------
if [ "$INSTALL_SHELL" = "yes" ]; then
  echo -e "${BOLD}Installing Shell Environment...${NC}"
  if [ -x "${INSTALLERS_DIR}/install-shell.sh" ]; then
    # Source installer so its functions are available, then call main function
    (
      export AITEAMFORGE_DIR="${INSTALL_DIR}"
      export INSTALL_ROOT="${AITEAMFORGE_HOME}"
      # When installing to a non-default location, sandbox the zshrc modification
      if [ "${INSTALL_DIR}" != "${HOME}/aiteamforge" ]; then
        export ZSHRC_TARGET="${INSTALL_DIR}/.zshrc-integration"
      fi
      source "${AITEAMFORGE_HOME}/libexec/lib/common.sh"
      source "${INSTALLERS_DIR}/install-shell.sh"
      install_shell_environment
    ) 2>&1 | sed 's/^/  /' || {
      echo -e "  ${RED}✗ Shell environment had errors${NC}"
      INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    }
  else
    echo -e "  ${YELLOW}⚠ Shell installer not found (skipping)${NC}"
  fi
  echo ""
fi

# -----------------------------------------------------------------------
# Install Claude Code Configuration
# -----------------------------------------------------------------------
if [ "$INSTALL_CLAUDE" = "yes" ]; then
  echo -e "${BOLD}Installing Claude Code Configuration...${NC}"
  if [ -x "${INSTALLERS_DIR}/install-claude-config.sh" ]; then
    (
      export AITEAMFORGE_DIR="${INSTALL_DIR}"
      export INSTALL_ROOT="${AITEAMFORGE_HOME}"
      export TEMPLATE_DIR="${AITEAMFORGE_HOME}/share/templates"
      # Sandbox mode: stage configs under INSTALL_DIR instead of modifying real ~/.claude
      # Users can apply staged configs later with: aiteamforge apply-claude-config
      if [ "${INSTALL_DIR}" != "${HOME}/aiteamforge" ]; then
        export CLAUDE_SANDBOX=1
      fi
      bash "${INSTALLERS_DIR}/install-claude-config.sh"
    ) 2>&1 | sed 's/^/  /' || {
      echo -e "  ${RED}✗ Claude config had errors${NC}"
      INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    }
  else
    echo -e "  ${YELLOW}⚠ Claude config installer not found (skipping)${NC}"
  fi
  echo ""
fi

# -----------------------------------------------------------------------
# Install LCARS Kanban System
# -----------------------------------------------------------------------
if [ "$INSTALL_KANBAN" = "yes" ]; then
  echo -e "${BOLD}Installing LCARS Kanban System...${NC}"
  if [ -f "${INSTALLERS_DIR}/install-kanban.sh" ]; then
    # Serialize team working dirs as "team:path team:path ..."
    _team_dirs=""
    for _tid in "${SELECTED_TEAMS[@]}"; do
      [ -z "$_tid" ] && continue
      eval "_tw=\"\${_WORKDIR_${_tid}:-${INSTALL_DIR}/${_tid}}\""
      _team_dirs="${_team_dirs}${_tid}:${_tw} "
    done
    (
      export AITEAMFORGE_DIR="${INSTALL_DIR}"
      export INSTALL_ROOT="${AITEAMFORGE_HOME}"
      export SELECTED_TEAMS="${SELECTED_TEAMS[*]}"
      export TEAM_WORKING_DIRS_STR="${_team_dirs}"
      source "${AITEAMFORGE_HOME}/libexec/lib/common.sh"
      source "${INSTALLERS_DIR}/install-kanban.sh"
      install_kanban_system
    ) 2>&1 | sed 's/^/  /' || {
      echo -e "  ${RED}✗ Kanban system had errors${NC}"
      INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    }
  else
    echo -e "  ${YELLOW}⚠ Kanban installer not found (skipping)${NC}"
  fi
  echo ""
fi

# -----------------------------------------------------------------------
# Install Fleet Monitor
# -----------------------------------------------------------------------
if [ "$INSTALL_FLEET" = "yes" ]; then
  echo -e "${BOLD}Installing Fleet Monitor...${NC}"
  if [ -f "${INSTALLERS_DIR}/install-fleet-monitor.sh" ]; then
    (
      export AITEAMFORGE_DIR="${INSTALL_DIR}"
      export INSTALL_ROOT="${AITEAMFORGE_HOME}"
      export MACHINE_NAME="${MACHINE_NAME}"
      export FLEET_MODE="${FLEET_MODE}"
      export FLEET_SERVER_URL="${FLEET_SERVER_URL}"
      export NON_INTERACTIVE="true"
      export INSTALL_FLEET_MONITOR="true"
      source "${AITEAMFORGE_HOME}/libexec/lib/common.sh"
      source "${INSTALLERS_DIR}/install-fleet-monitor.sh"
      install_fleet_monitor
    ) 2>&1 | sed 's/^/  /' || {
      echo -e "  ${RED}✗ Fleet Monitor had errors${NC}"
      INSTALL_ERRORS=$((INSTALL_ERRORS + 1))
    }
  else
    echo -e "  ${YELLOW}⚠ Fleet Monitor installer not found (skipping)${NC}"
  fi
  echo ""
fi

# -----------------------------------------------------------------------
# Load LaunchAgents (must run at TOP LEVEL, not in subshells)
# launchctl fails silently when run inside pipes or subshells
# -----------------------------------------------------------------------
echo -e "${BOLD}Loading LaunchAgents...${NC}"
_loaded_agents=0
for _plist in \
    "$HOME/Library/LaunchAgents/com.aiteamforge.fleet-reporter.plist" \
    "$HOME/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist" \
    "$HOME/Library/LaunchAgents/com.aiteamforge.lcars-health.plist" \
    "$HOME/Library/LaunchAgents/com.aiteamforge.tailscale-funnel.plist" \
    "$HOME/Library/LaunchAgents/com.aiteamforge.fleet-monitor.plist"; do
    if [ -f "$_plist" ]; then
        _name=$(basename "$_plist" .plist)
        launchctl unload "$_plist" 2>/dev/null || true
        if launchctl load "$_plist" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} ${_name}"
            _loaded_agents=$((_loaded_agents + 1))
        else
            echo -e "  ${YELLOW}⚠${NC} ${_name} (failed to load)"
        fi
    fi
done
if [ "$_loaded_agents" -eq 0 ]; then
    echo -e "  ${YELLOW}⚠${NC} No LaunchAgents found to load"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# WRITE CONFIGURATION FILE
# ═══════════════════════════════════════════════════════════════════════════

# Convert yes/no to JSON true/false
to_json_bool() { [ "$1" = "yes" ] && echo "true" || echo "false"; }

cat > "${INSTALL_DIR}/.aiteamforge-config" <<EOF
{
  "version": "${VERSION}",
  "install_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "install_dir": "${INSTALL_DIR}",
  "framework_home": "${AITEAMFORGE_HOME}",
  "machine_name": "${MACHINE_NAME}",
  "teams": [$(printf '"%s",' "${SELECTED_TEAMS[@]}" | sed 's/,""//' | sed 's/,$//')],
  "team_paths": {$(
    for _tid in "${SELECTED_TEAMS[@]}"; do
      [ -z "$_tid" ] && continue
      eval "_proj=\"\${_PROJECT_${_tid}:-}\""
      eval "_wdir=\"\${_WORKDIR_${_tid}:-}\""
      eval "_client=\"\${_CLIENT_${_tid}:-}\""
      if [ -n "$_client" ] && [ -n "$_proj" ]; then
        printf '"%s": {"working_dir": "%s", "client_id": "%s", "project_id": "%s"},' "$_tid" "$_wdir" "$_client" "$_proj"
      elif [ -n "$_proj" ]; then
        printf '"%s": {"working_dir": "%s", "project_id": "%s"},' "$_tid" "$_wdir" "$_proj"
      else
        printf '"%s": {"working_dir": "%s"},' "$_tid" "$_wdir"
      fi
    done | sed 's/,$//'
  )},
  "features": {
    "shell_environment": $(to_json_bool "$INSTALL_SHELL"),
    "claude_code_config": $(to_json_bool "$INSTALL_CLAUDE"),
    "lcars_kanban": $(to_json_bool "$INSTALL_KANBAN"),
    "fleet_monitor": $(to_json_bool "$INSTALL_FLEET"),
    "fleet_mode": "${FLEET_MODE}",
    "fleet_server_url": "${FLEET_SERVER_URL}"
  }
}
EOF

# ═══════════════════════════════════════════════════════════════════════════
# COMPLETION
# ═══════════════════════════════════════════════════════════════════════════

echo ""
if [ "$INSTALL_ERRORS" -gt 0 ]; then
  echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║           Setup Complete (with ${INSTALL_ERRORS} warnings)                      ║${NC}"
  echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${YELLOW}Some installers reported errors. Run 'aiteamforge doctor' for details.${NC}"
else
  echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║                    Setup Complete!                                ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
fi
echo ""
echo "  Machine:    ${MACHINE_NAME}"
echo "  Directory:  ${INSTALL_DIR}"
echo "  Teams:      ${SELECTED_TEAMS[*]}"
echo ""

# -----------------------------------------------------------------------
# Post-install checklist: detect what still needs attention
# -----------------------------------------------------------------------
echo -e "${BOLD}Post-Install Checklist${NC}"
echo ""

CHECKLIST_ITEMS=0

# GitHub CLI authentication
if command -v gh &>/dev/null; then
  if gh auth status &>/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} GitHub CLI authenticated"
  else
    echo -e "  ${YELLOW}○${NC} GitHub CLI not authenticated"
    echo -e "    Run: ${CYAN}gh auth login${NC}"
    CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
  fi
fi

# Tailscale setup (for Fleet Monitor remote access)
# Resolve tailscale CLI path (cask puts it inside the app bundle)
TAILSCALE_CLI=""
if command -v tailscale &>/dev/null; then
  TAILSCALE_CLI="tailscale"
elif [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
  TAILSCALE_CLI="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  # Create symlink so 'tailscale' works everywhere
  if [ ! -e "/usr/local/bin/tailscale" ]; then
    echo -e "  ${CYAN}Creating tailscale CLI symlink...${NC}"
    sudo mkdir -p /usr/local/bin 2>/dev/null || true
    sudo ln -sf "$TAILSCALE_CLI" /usr/local/bin/tailscale 2>/dev/null && TAILSCALE_CLI="tailscale" || true
  fi
fi

if [ -n "$TAILSCALE_CLI" ]; then
  # Tailscale installed — check if running and authenticated
  ts_status=$($TAILSCALE_CLI status 2>&1 || true)
  if echo "$ts_status" | grep -q "failed to connect\|stopped"; then
    echo -e "  ${YELLOW}○${NC} Tailscale installed but not running"
    if [ "$MODE" != "non-interactive" ]; then
      echo ""
      echo -e "    Tailscale enables remote access to your Fleet Monitor and LCARS dashboards."
      read -p "    Start Tailscale now? (yes/no) [yes]: " start_ts
      start_ts="${start_ts:-yes}"
      if [ "$start_ts" = "yes" ]; then
        echo -e "    Starting Tailscale..."
        if [ -d "/Applications/Tailscale.app" ]; then
          open /Applications/Tailscale.app
          echo -e "    Opened Tailscale app. Sign in via the menu bar icon."
          sleep 5
        else
          echo -e "    ${YELLOW}Tailscale GUI app not found.${NC}"
          echo -e "    The CLI-only package cannot run the daemon on macOS."
          echo -e "    Installing the full app..."
          brew uninstall tailscale 2>/dev/null || true
          brew install --cask tailscale 2>&1 | tail -3
          open /Applications/Tailscale.app 2>/dev/null
          echo -e "    Opened Tailscale app. Sign in via the menu bar icon."
          sleep 5
        fi
        # Check if connected after app launch
        ts_status2=$($TAILSCALE_CLI status 2>&1 || true)
        if echo "$ts_status2" | grep -q "NeedsLogin\|not logged in\|failed to connect"; then
          echo ""
          echo -e "    ${CYAN}Sign in to Tailscale via the menu bar icon, then press Enter.${NC}"
          read -p "    Press Enter when signed in... "
        fi
        # Verify
        ts_ip=$($TAILSCALE_CLI ip -4 2>/dev/null | head -n1 || true)
        if [ -n "$ts_ip" ]; then
          ts_hostname=$($TAILSCALE_CLI status 2>/dev/null | head -1 | awk '{print $2}' || true)
          echo -e "  ${GREEN}✓${NC} Tailscale connected: ${ts_hostname:-$ts_ip}"
        else
          echo -e "  ${YELLOW}⚠${NC} Tailscale started but not yet connected"
          CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
        fi
      else
        echo -e "    Run later: ${CYAN}open /Applications/Tailscale.app${NC}"
        CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
      fi
    else
      echo -e "    Start with: ${CYAN}open /Applications/Tailscale.app${NC}"
      CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
    fi
  elif echo "$ts_status" | grep -q "NeedsLogin\|not logged in"; then
    echo -e "  ${YELLOW}○${NC} Tailscale running but not authenticated"
    if [ "$MODE" != "non-interactive" ]; then
      echo ""
      echo -e "    Running ${CYAN}tailscale up${NC} — this will open a browser for login."
      echo ""
      $TAILSCALE_CLI up 2>&1 || true
      sleep 2
      ts_ip=$($TAILSCALE_CLI ip -4 2>/dev/null | head -n1 || true)
      if [ -n "$ts_ip" ]; then
        echo -e "  ${GREEN}✓${NC} Tailscale authenticated"
      else
        echo -e "  ${YELLOW}⚠${NC} Tailscale authentication incomplete"
        CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
      fi
    else
      echo -e "    Authenticate: ${CYAN}tailscale up${NC}"
      CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
    fi
  else
    ts_ip=$($TAILSCALE_CLI ip -4 2>/dev/null | head -n1 || true)
    ts_hostname=$($TAILSCALE_CLI status 2>/dev/null | head -1 | awk '{print $2}' || true)
    echo -e "  ${GREEN}✓${NC} Tailscale connected: ${ts_hostname:-$ts_ip}"
  fi
else
  echo -e "  ${YELLOW}○${NC} Tailscale not installed (optional — needed for remote access)"
  if [ "$MODE" != "non-interactive" ]; then
    read -p "    Install Tailscale now? (yes/no) [no]: " install_ts
    install_ts="${install_ts:-no}"
    if [ "$install_ts" = "yes" ]; then
      echo -e "    Installing Tailscale (GUI app)..."
      brew install --cask tailscale 2>&1 | tail -3
      echo -e "    Opening Tailscale app..."
      open /Applications/Tailscale.app 2>/dev/null
      sleep 5
      echo -e "    ${CYAN}Sign in to Tailscale via the menu bar icon, then press Enter.${NC}"
      read -p "    Press Enter when signed in... "
      ts_ip=$($TAILSCALE_CLI ip -4 2>/dev/null | head -n1 || true)
      if [ -n "$ts_ip" ]; then
        echo -e "  ${GREEN}✓${NC} Tailscale installed and connected"
      else
        echo -e "  ${YELLOW}⚠${NC} Tailscale installed — sign in via the menu bar icon"
        CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
      fi
    else
      echo -e "    Install later: ${CYAN}brew install --cask tailscale${NC}"
      CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
    fi
  else
    echo -e "    Install: ${CYAN}brew install --cask tailscale${NC}"
    CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
  fi
fi

# iTerm2 Python API
if [ -d "/Applications/iTerm.app" ]; then
  api_enabled=$(defaults read com.googlecode.iterm2 EnableAPIServer 2>/dev/null || true)
  if [ "$api_enabled" = "1" ]; then
    echo -e "  ${GREEN}✓${NC} iTerm2 Python API enabled"
  else
    echo -e "  ${YELLOW}○${NC} iTerm2 Python API not enabled (needed for automatic tab creation)"
    echo -e "    Fix: ${CYAN}defaults write com.googlecode.iterm2 EnableAPIServer -bool true${NC}"
    echo -e "    Then restart iTerm2"
    CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
  fi
fi

# Shell integration
if [ -f "$HOME/.zshrc" ] && grep -q "aiteamforge" "$HOME/.zshrc" 2>/dev/null; then
  echo -e "  ${GREEN}✓${NC} Shell integration in .zshrc"
else
  echo -e "  ${YELLOW}○${NC} Shell not yet reloaded"
  echo -e "    Run: ${CYAN}source ~/.zshrc${NC}"
  CHECKLIST_ITEMS=$((CHECKLIST_ITEMS + 1))
fi

echo ""

if [ "$CHECKLIST_ITEMS" -eq 0 ]; then
  echo -e "  ${GREEN}All set! No additional steps needed.${NC}"
else
  echo -e "  ${YELLOW}${CHECKLIST_ITEMS} item(s) above will enhance your setup (all optional).${NC}"
fi

echo ""
echo -e "${BOLD}Getting Started${NC}"
echo ""
echo "  Launch a team:"
for team_id in "${SELECTED_TEAMS[@]}"; do
  [ -z "$team_id" ] && continue
  echo -e "    ${CYAN}${INSTALL_DIR}/${team_id}-startup.sh${NC}"
  break  # Just show the first one as example
done
if [ ${#SELECTED_TEAMS[@]} -gt 1 ]; then
  echo "    (${#SELECTED_TEAMS[@]} teams available)"
fi
echo ""
echo "  Other commands:"
echo -e "    ${CYAN}aiteamforge doctor${NC}    Health check & diagnostics"
echo -e "    ${CYAN}aiteamforge status${NC}    Show environment status"
echo -e "    ${CYAN}aiteamforge help${NC}      All available commands"
echo ""
