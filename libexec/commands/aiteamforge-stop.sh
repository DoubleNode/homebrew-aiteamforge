#!/bin/bash
# aiteamforge-stop.sh
# Stop aiteamforge services (LCARS, Fleet Monitor)
# Can stop all services or specific ones

set -eo pipefail

# Get framework location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBEXEC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source shared libraries
source "${LIBEXEC_DIR}/lib/common.sh"
source "${LIBEXEC_DIR}/lib/config.sh"

VERSION="1.3.2"

# Options
PERSIST_AGENTS=false
SERVICE="${1:-all}"

# Usage
usage() {
  cat <<EOF
AITeamForge Stop v${VERSION}
Stop aiteamforge services

Usage: aiteamforge stop [service] [options]

Services:
  all         Stop all services (default)
  lcars       Stop LCARS Kanban server only
  kanban      Alias for 'lcars'
  fleet       Stop Fleet Monitor only
  agents      Unload LaunchAgents

Options:
  --persist   Keep LaunchAgents loaded (don't unload)
  -v, --version     Show version
  -h, --help        Show this help

Examples:
  aiteamforge stop                # Stop all services
  aiteamforge stop lcars          # Stop LCARS only
  aiteamforge stop --persist      # Stop services but keep agents loaded
  aiteamforge stop agents         # Unload LaunchAgents only

Exit Codes:
  0 - Services stopped successfully
  1 - Error stopping services
EOF
}

# Parse arguments
ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --persist)
      PERSIST_AGENTS=true
      shift
      ;;
    -v|--version)
      echo "AITeamForge Stop v${VERSION}"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

# Set service from remaining args
if [ ${#ARGS[@]} -gt 0 ]; then
  SERVICE="${ARGS[0]}"
fi

# Check if configured
if ! is_configured; then
  print_error "Dev-team not configured"
  echo "Run: aiteamforge setup"
  exit 1
fi

# Banner
clear
print_header "AITEAMFORGE STOP"

# Stop LCARS server
stop_lcars() {
  print_section "Stopping LCARS Kanban Server"

  # Find LCARS server process
  local pids
  pids=$(pgrep -f "lcars-ui/server.py" 2>/dev/null || true)

  if [ -z "$pids" ]; then
    print_info "LCARS server not running"
    return 0
  fi

  print_info "Stopping LCARS server..."

  # Kill processes
  for pid in $pids; do
    if kill "$pid" 2>/dev/null; then
      print_success "Stopped LCARS server (PID: ${pid})"
    else
      print_warning "Could not stop process ${pid}"
    fi
  done

  # Wait a moment and verify
  sleep 1

  if ! pgrep -f "lcars-ui/server.py" &>/dev/null; then
    print_success "LCARS server stopped"
    return 0
  else
    print_warning "LCARS server may still be running"
    return 1
  fi
}

# Stop Fleet Monitor
stop_fleet() {
  print_section "Stopping Fleet Monitor"

  # Find Fleet Monitor process
  local pids
  pids=$(pgrep -f "fleet-monitor/server/server.js" 2>/dev/null || true)

  if [ -z "$pids" ]; then
    print_info "Fleet Monitor not running"
    return 0
  fi

  print_info "Stopping Fleet Monitor..."

  # Kill processes
  for pid in $pids; do
    if kill "$pid" 2>/dev/null; then
      print_success "Stopped Fleet Monitor (PID: ${pid})"
    else
      print_warning "Could not stop process ${pid}"
    fi
  done

  # Wait a moment and verify
  sleep 1

  if ! pgrep -f "fleet-monitor/server/server.js" &>/dev/null; then
    print_success "Fleet Monitor stopped"
    return 0
  else
    print_warning "Fleet Monitor may still be running"
    return 1
  fi
}

# Unload LaunchAgents
stop_agents() {
  print_section "Unloading LaunchAgents"

  if [ "$PERSIST_AGENTS" = true ]; then
    print_info "Keeping LaunchAgents loaded (--persist flag)"
    return 0
  fi

  local agents=(
    "com.aiteamforge.kanban-backup.plist"
    "com.aiteamforge.lcars-health.plist"
    "com.aiteamforge.fleet-reporter.plist"
  )

  local unloaded=0

  for agent in "${agents[@]}"; do
    local plist="$HOME/Library/LaunchAgents/${agent}"

    if [ ! -f "$plist" ]; then
      continue
    fi

    # Check if loaded
    if ! launchctl list 2>/dev/null | grep -q "${agent%.plist}"; then
      print_info "${agent} not loaded"
      continue
    fi

    # Unload agent
    print_info "Unloading ${agent}..."
    if launchctl unload "$plist" 2>/dev/null; then
      print_success "Unloaded ${agent}"
      unloaded=$((unloaded + 1))
    else
      print_warning "Failed to unload ${agent}"
    fi
  done

  if [ $unloaded -gt 0 ]; then
    print_success "Unloaded ${unloaded} LaunchAgent(s)"
  fi

  return 0
}

# Stop services based on selection
case "$SERVICE" in
  all)
    stop_lcars
    stop_fleet
    stop_agents
    ;;
  lcars|kanban)
    stop_lcars
    ;;
  fleet)
    stop_fleet
    ;;
  agents)
    stop_agents
    ;;
  *)
    print_error "Unknown service: ${SERVICE}"
    usage
    exit 1
    ;;
esac

# Summary
echo ""
print_section "Services Stopped"
print_success "Dev-team services have been stopped"
echo ""
print_info "Check status: aiteamforge status"
print_info "Restart: aiteamforge start"

exit 0
