#!/bin/bash
# aiteamforge-start.sh
# Start aiteamforge services (LCARS, Fleet Monitor)
# Can start all services or specific ones

set -eo pipefail

# Get framework location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBEXEC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source shared libraries
source "${LIBEXEC_DIR}/lib/common.sh"
source "${LIBEXEC_DIR}/lib/config.sh"

VERSION="1.2.0"

# Options
OPEN_BROWSER=false
SERVICE="${1:-all}"

# Usage
usage() {
  cat <<EOF
AITeamForge Start v${VERSION}
Start aiteamforge services

Usage: aiteamforge start [service] [options]

Services:
  all         Start all services (default)
  lcars       Start LCARS Kanban server only
  kanban      Alias for 'lcars'
  fleet       Start Fleet Monitor only
  agents      Load LaunchAgents

Options:
  --open      Open LCARS dashboard in browser after start
  -v, --version     Show version
  -h, --help        Show this help

Examples:
  aiteamforge start                # Start all services
  aiteamforge start lcars          # Start LCARS only
  aiteamforge start fleet          # Start Fleet Monitor only
  aiteamforge start --open         # Start and open browser

Exit Codes:
  0 - Services started successfully
  1 - Error starting services
EOF
}

# Parse arguments
ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --open)
      OPEN_BROWSER=true
      shift
      ;;
    -v|--version)
      echo "AITeamForge Start v${VERSION}"
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

# Get directories
WORKING_DIR=$(get_working_dir)

# Banner
clear
print_header "AITEAMFORGE START"

# Validate kanban boards for all configured teams
# Runs first so any board issues can be resolved before agents start.
validate_boards() {
  local board_check_script="${LIBEXEC_DIR}/../share/scripts/kanban-board-check.sh"

  if [ ! -f "$board_check_script" ]; then
    print_warning "Board check script not found: ${board_check_script}"
    return 0
  fi

  # shellcheck source=/dev/null
  source "$board_check_script"

  print_section "Validating Kanban Boards"

  local teams_str
  teams_str=$(get_configured_teams)

  if [ -z "$teams_str" ]; then
    print_warning "No configured teams found — skipping board validation"
    return 0
  fi

  local valid=0
  local skipped=0

  local -a teams=()
  read -ra teams <<< "$teams_str"
  for team in "${teams[@]}"; do
    [ -z "$team" ] && continue
    print_info "Checking board: ${team}"
    if validate_kanban_board "$team"; then
      print_success "Board OK: ${team}"
      valid=$((valid + 1))
    else
      print_warning "Board unavailable: ${team} (continuing startup)"
      skipped=$((skipped + 1))
    fi
  done

  if [ $skipped -gt 0 ]; then
    print_warning "${valid} board(s) valid, ${skipped} board(s) skipped"
  else
    print_success "All ${valid} board(s) valid"
  fi
}

# Start LCARS server
start_lcars() {
  print_section "Starting LCARS Kanban Server"

  local lcars_dir="${WORKING_DIR}/lcars-ui"

  # Read port from config file (set by install-kanban.sh), default to 8080
  local port=8080
  if [ -f "${lcars_dir}/.lcars-port" ]; then
    port="$(cat "${lcars_dir}/.lcars-port" 2>/dev/null || echo 8080)"
  fi

  if [ ! -d "$lcars_dir" ]; then
    print_error "LCARS UI not found: ${lcars_dir}"
    return 1
  fi

  # Check if already running (try root URL — server has no /health endpoint)
  if curl -s -o /dev/null -w '%{http_code}' http://localhost:${port}/ 2>/dev/null | grep -q '200'; then
    print_warning "LCARS server already running on port ${port}"
    return 0
  fi

  # Start server in background
  print_info "Starting LCARS server on port ${port}..."

  pushd "$lcars_dir" > /dev/null
  nohup python3 server.py "$port" > /tmp/lcars-server.log 2>&1 &
  local pid=$!
  popd > /dev/null

  # Wait for startup
  sleep 3

  # Check if process is still alive (confirms no crash on startup)
  if kill -0 "$pid" 2>/dev/null; then
    print_success "LCARS server started (PID: ${pid})"
    print_info "Access at: http://localhost:${port}"

    # Open browser if requested
    if [ "$OPEN_BROWSER" = true ]; then
      print_info "Opening browser..."
      open "http://localhost:${port}" 2>/dev/null || true
    fi

    return 0
  else
    print_error "Failed to start LCARS server"
    print_info "Check logs: /tmp/lcars-server.log"
    return 1
  fi
}

# Start Fleet Monitor (server and/or reporter client)
start_fleet() {
  print_section "Starting Fleet Monitor"

  local fleet_server_dir="${WORKING_DIR}/fleet-monitor/server"
  local fleet_reporter="${WORKING_DIR}/fleet-monitor/client/fleet-reporter.sh"
  local has_server=false
  local has_reporter=false

  [ -d "$fleet_server_dir" ] && has_server=true
  [ -f "$fleet_reporter" ] && has_reporter=true

  # Nothing installed at all
  if [ "$has_server" = false ] && [ "$has_reporter" = false ]; then
    print_warning "Fleet Monitor not installed"
    return 0
  fi

  # Start server if installed
  if [ "$has_server" = true ]; then
    # Check if already running
    local server_running=false
    for port in 3000 3001 3002; do
      if curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}/" 2>/dev/null | grep -q '200'; then
        print_warning "Fleet Monitor server already running on port ${port}"
        server_running=true
        break
      fi
    done

    if [ "$server_running" = false ]; then
      print_info "Starting Fleet Monitor server..."
      pushd "$fleet_server_dir" > /dev/null

      # Make sure dependencies are installed
      if [ ! -d "node_modules" ]; then
        print_info "Installing dependencies..."
        npm install --silent
      fi

      # Start server in background
      nohup npm start > /tmp/fleet-monitor.log 2>&1 &
      local pid=$!
      popd > /dev/null

      # Wait for startup
      sleep 3

      # Check if it started successfully
      local started=false
      for port in 3000 3001 3002; do
        if curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}/" 2>/dev/null | grep -q '200'; then
          print_success "Fleet Monitor server started (PID: ${pid}, port: ${port})"
          print_info "Access at: http://localhost:${port}"
          started=true
          break
        fi
      done

      if [ "$started" = false ]; then
        print_error "Failed to start Fleet Monitor server"
        print_info "Check logs: /tmp/fleet-monitor.log"
      fi
    fi
  fi

  # Ensure fleet reporter LaunchAgent is loaded (client mode)
  if [ "$has_reporter" = true ]; then
    local reporter_plist="$HOME/Library/LaunchAgents/com.aiteamforge.fleet-reporter.plist"
    if launchctl list 2>/dev/null | grep -q "com.aiteamforge.fleet-reporter"; then
      print_info "Fleet reporter already active"
    elif [ -f "$reporter_plist" ]; then
      print_info "Loading Fleet reporter LaunchAgent..."
      if launchctl load "$reporter_plist" 2>/dev/null; then
        print_success "Fleet reporter started"
      else
        print_error "Failed to load Fleet reporter LaunchAgent"
      fi
    else
      print_warning "Fleet reporter installed but LaunchAgent plist not found"
    fi
  fi

  return 0
}

# Load LaunchAgents
start_agents() {
  print_section "Loading LaunchAgents"

  local agents=(
    "com.aiteamforge.kanban-backup.plist"
    "com.aiteamforge.lcars-health.plist"
    "com.aiteamforge.fleet-reporter.plist"
  )

  local loaded=0

  for agent in "${agents[@]}"; do
    local plist="$HOME/Library/LaunchAgents/${agent}"

    if [ ! -f "$plist" ]; then
      print_warning "${agent} not found"
      continue
    fi

    # Check if already loaded
    if launchctl list 2>/dev/null | grep -q "${agent%.plist}"; then
      print_info "${agent} already loaded"
      continue
    fi

    # Load agent
    print_info "Loading ${agent}..."
    if launchctl load "$plist" 2>/dev/null; then
      print_success "Loaded ${agent}"
      loaded=$((loaded + 1))
    else
      print_error "Failed to load ${agent}"
    fi
  done

  if [ $loaded -gt 0 ]; then
    print_success "Loaded ${loaded} LaunchAgent(s)"
  fi

  return 0
}

# Start services based on selection
case "$SERVICE" in
  all)
    # Board validation runs only for full startup — individual services
    # (lcars, fleet, agents) don't require kanban boards to function.
    validate_boards
    start_lcars
    start_fleet
    start_agents
    ;;
  lcars|kanban)
    start_lcars
    ;;
  fleet)
    start_fleet
    ;;
  agents)
    start_agents
    ;;
  *)
    print_error "Unknown service: ${SERVICE}"
    usage
    exit 1
    ;;
esac

# Summary
echo ""
print_section "Services Started"
print_success "Dev-team services are now running"
echo ""
print_info "Check status: aiteamforge status"
print_info "View logs: /tmp/lcars-server.log, /tmp/fleet-monitor.log"

exit 0
