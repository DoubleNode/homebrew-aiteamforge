#!/bin/bash
# AITeamForge CLI - Main command dispatcher
# This script routes subcommands to appropriate handlers

set -eo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get AITEAMFORGE_HOME from environment or default to Homebrew location
if [ -z "$AITEAMFORGE_HOME" ]; then
  # Try to detect Homebrew installation
  if command -v brew &>/dev/null; then
    AITEAMFORGE_HOME="$(brew --prefix)/opt/aiteamforge/libexec"
  else
    echo -e "${RED}ERROR: AITEAMFORGE_HOME not set and Homebrew not found${NC}" >&2
    exit 1
  fi
fi

# Get user's aiteamforge working directory (where actual configs/data live)
AITEAMFORGE_DIR="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"

VERSION="1.1.0"

# Usage information
usage() {
  cat <<EOF
AITeamForge CLI v${VERSION}
AITeamForge

Usage: aiteamforge <command> [options]

Commands:
  setup       Run interactive setup wizard
  doctor      Health check and diagnostics
  status      Show current environment status
  upgrade     Upgrade aiteamforge components
  uninstall   Remove aiteamforge environment
  start       Start aiteamforge services
  stop        Stop aiteamforge services
  restart     Restart aiteamforge services
  version     Show version information
  help        Show this help message

Installation Locations:
  Framework:  ${AITEAMFORGE_HOME}
  Working:    ${AITEAMFORGE_DIR}

Examples:
  aiteamforge setup              # Run setup wizard
  aiteamforge doctor             # Check system health
  aiteamforge status             # Show current status
  aiteamforge start ios          # Start iOS team environment

For detailed help on a command:
  aiteamforge <command> --help
EOF
}

# Version information
version_info() {
  echo "AITeamForge v${VERSION}"
  echo "Framework: ${AITEAMFORGE_HOME}"
  echo "Working Directory: ${AITEAMFORGE_DIR}"
  echo ""

  # Show installation status
  if [ -f "${AITEAMFORGE_DIR}/.aiteamforge-config" ]; then
    echo -e "${GREEN}✓${NC} Configured"
  else
    echo -e "${YELLOW}⚠${NC}  Not configured (run: aiteamforge setup)"
  fi
}

# Check if working directory is configured
check_configured() {
  if [ ! -f "${AITEAMFORGE_DIR}/.aiteamforge-config" ]; then
    echo -e "${YELLOW}⚠ AITeamForge not configured${NC}" >&2
    echo "Run: aiteamforge setup" >&2
    exit 1
  fi
}

# Main command dispatcher
case "${1:-}" in
  setup)
    shift
    exec "${AITEAMFORGE_HOME}/bin/aiteamforge-setup.sh" "$@"
    ;;

  doctor)
    shift
    exec "${AITEAMFORGE_HOME}/libexec/commands/aiteamforge-doctor.sh" "$@"
    ;;

  status)
    check_configured
    shift
    exec "${AITEAMFORGE_HOME}/libexec/commands/aiteamforge-status.sh" "$@"
    ;;

  upgrade)
    check_configured
    shift
    exec "${AITEAMFORGE_HOME}/libexec/commands/aiteamforge-upgrade.sh" "$@"
    ;;

  uninstall)
    shift
    exec "${AITEAMFORGE_HOME}/libexec/commands/aiteamforge-uninstall.sh" "$@"
    ;;

  start)
    check_configured
    shift
    exec "${AITEAMFORGE_HOME}/libexec/commands/aiteamforge-start.sh" "$@"
    ;;

  stop)
    check_configured
    shift
    exec "${AITEAMFORGE_HOME}/libexec/commands/aiteamforge-stop.sh" "$@"
    ;;

  restart)
    check_configured
    shift
    "${AITEAMFORGE_HOME}/libexec/commands/aiteamforge-stop.sh" "$@"
    exec "${AITEAMFORGE_HOME}/libexec/commands/aiteamforge-start.sh" "$@"
    ;;

  version|-v|--version)
    version_info
    ;;

  help|-h|--help|"")
    usage
    ;;

  *)
    echo -e "${RED}ERROR: Unknown command: $1${NC}" >&2
    echo "" >&2
    usage >&2
    exit 1
    ;;
esac
