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
# XACA-0799: the port registry (for the port→team reverse map) and the restart
# manifest that hands the running server set to the start phase.
source "${LIBEXEC_DIR}/lib/aiteamforge-paths.sh"
source "${LIBEXEC_DIR}/lib/lcars-restart-manifest.sh"

# Version — read from VERSION file (single source of truth)
_find_version() { for p in "${LIBEXEC_DIR}/../VERSION" "${LIBEXEC_DIR}/../../VERSION"; do [ -f "$p" ] && cat "$p" | tr -d '[:space:]' && return; done; echo "unknown"; }
VERSION="$(_find_version)"

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
[[ -t 1 ]] && clear
print_header "AITEAMFORGE STOP"

# Stop LCARS server
stop_lcars() {
  print_section "Stopping LCARS Kanban Server"

  # Find LCARS server process. Match `server.py <port>` rather than a path
  # prefix: start.sh and the per-team startup scripts launch LCARS via
  # `cd lcars-ui && python3 server.py <port>`, so the running cmdline carries
  # NO "lcars-ui/" substring (XACA-0560). The old `lcars-ui/server.py` pattern
  # never matched, making stop/restart silent no-ops. The trailing [0-9]
  # anchors on the port arg so we don't match e.g. an editor open on server.py.
  #
  # DELIBERATELY PORT-LESS (kill-all): `aiteamforge stop` tears down ALL LCARS
  # servers, so this matcher omits the port on purpose. Do NOT "align" it with
  # the per-port helper matcher in scripts/lcars-restart-helpers.sh
  # (`server\.py.*<port>`, kill-one) during a future sibling-drift audit —
  # narrowing this to one port would silently break stop-all. (XACA-0560-001)
  local pids
  pids=$(pgrep -f "server\.py [0-9]" 2>/dev/null || true)

  # ── XACA-0799: capture BEFORE teardown ────────────────────────────────────
  # `aiteamforge restart` is stop.sh followed by start.sh — two processes with no
  # shared memory. This kill-all reaps every LCARS server on the box, but start
  # only relaunches `.teams[]`, so any team started by its own *-startup.sh was
  # left DOWN until the 300s lcars-health LaunchAgent noticed (M4Mini: 7 of 8
  # teams, ~5 minutes of fleet-wide outage per restart).
  #
  # Snapshotting the live set to disk here — BEFORE the first kill, so a crash
  # mid-teardown still leaves a complete record — lets start restore exactly what
  # was torn down. Written unconditionally, including the empty case: "nothing was
  # running" is a real answer, and writing it also clears any earlier manifest
  # that would otherwise be replayed.
  #
  # Never allowed to abort the stop: a failed snapshot degrades restart to the old
  # `.teams[]`-only behavior, which is exactly today's baseline. Losing LCARS to a
  # bookkeeping error would be a strictly worse trade, and this script runs under
  # `set -eo pipefail`.
  if lcars_restart_manifest_capture 2>/dev/null; then
    local _captured=0
    _captured=$(lcars_restart_manifest_teams 2>/dev/null | grep -c . || true)
    [ -z "$_captured" ] && _captured=0
    if [ "$_captured" -gt 0 ]; then
      print_info "Recorded ${_captured} running LCARS instance(s) for restart"
    fi
  else
    print_warning "Could not record running LCARS set — start will fall back to configured teams only"
  fi

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

  if ! pgrep -f "server\.py [0-9]" &>/dev/null; then
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
    if _aitf_launchctl unload "$plist" 2>/dev/null; then
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
