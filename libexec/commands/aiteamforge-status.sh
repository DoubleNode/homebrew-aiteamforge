#!/bin/bash
# aiteamforge-status.sh
# Display current state and status of aiteamforge environment
# LCARS-styled output with machine, services, and kanban info

set -eo pipefail

# Get framework location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBEXEC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source shared libraries
source "${LIBEXEC_DIR}/lib/common.sh"
source "${LIBEXEC_DIR}/lib/config.sh"
source "${LIBEXEC_DIR}/lib/constants.sh"
# Registry access for per-team LCARS status (XACA-0792-001). aiteamforge-paths.sh
# provides aiteamforge_resolve_team_key/aiteamforge_team_lcars_port; kanban-paths.sh
# provides the canonical get_board_id map the resolver consults first (guarded
# source, mirroring aiteamforge-doctor.sh).
source "${LIBEXEC_DIR}/lib/aiteamforge-paths.sh"
# shellcheck source=../lib/kanban-paths.sh
[ -f "${LIBEXEC_DIR}/lib/kanban-paths.sh" ] && source "${LIBEXEC_DIR}/lib/kanban-paths.sh" 2>/dev/null || true

# Version — read from VERSION file (single source of truth)
if [ -f "${LIBEXEC_DIR}/../VERSION" ]; then
  VERSION="$(cat "${LIBEXEC_DIR}/../VERSION" | tr -d '[:space:]')"
elif [ -f "${LIBEXEC_DIR}/../../VERSION" ]; then
  VERSION="$(cat "${LIBEXEC_DIR}/../../VERSION" | tr -d '[:space:]')"
else
  VERSION="unknown"
fi

# Options
JSON_OUTPUT=false
BRIEF=false

# Usage
usage() {
  cat <<EOF
AITeamForge Status v${VERSION}
Display current environment status

Usage: aiteamforge status [options]

Options:
  --json            Output in JSON format (machine-readable)
  --brief           One-line summary
  -v, --version     Show version
  -h, --help        Show this help

Output Includes:
  • Machine identity (name, ID, user)
  • Installed version and install date
  • Active teams and configurations
  • Running services (LCARS, Fleet Monitor) with ports
  • Active Claude agents and worktrees
  • Kanban board summary (items per team, in-progress)
  • Fleet Monitor status (if multi-machine)
  • Last backup timestamp
  • Disk usage

Examples:
  aiteamforge status               # Full status display
  aiteamforge status --brief       # One-line summary
  aiteamforge status --json        # JSON output for scripts

Exit Codes:
  0 - Status retrieved successfully
  1 - Error retrieving status
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --brief)
      BRIEF=true
      shift
      ;;
    -v|--version)
      echo "AITeamForge Status v${VERSION}"
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

# Check if configured
if ! is_configured; then
  if [ "$JSON_OUTPUT" = true ]; then
    echo '{"configured": false, "error": "Not configured"}'
  else
    print_error "Dev-team not configured"
    echo "Run: aiteamforge setup"
  fi
  exit 1
fi

# Get directories
WORKING_DIR=$(get_working_dir)

# Gather status data
gather_status_data() {
  # Machine info
  MACHINE_NAME=$(get_machine_name)
  MACHINE_ID=$(get_machine_id)
  USER_NAME=$(whoami)

  # Version info
  INSTALLED_VERSION=$(get_installed_version)
  INSTALL_DATE=$(get_install_date)

  # Teams
  CONFIGURED_TEAMS=$(get_configured_teams)

  # Services status — resolve EACH configured team's LCARS port from the canonical
  # registry and probe it (XACA-0792-001).
  #
  # The old model probed a single legacy `lcars-ui/.lcars-port` (defaulting to
  # 8080) and predates multi-team LCARS entirely. On any real install it reported
  # the wrong thing: with XACA-0792's start fix in place, finance-personal comes up
  # on 8361 and this still said DOWN, because 8361 is not 8080 and nothing here ever
  # consulted the registry. Teams are resolved through aiteamforge_resolve_team_key
  # so profile-scoped ids (finance -> finance-personal, legal -> legal-coparenting)
  # land on the right port.
  #
  # LCARS_RUNNING / LCARS_PORT are retained as scalars for the existing JSON shape
  # and brief output: RUNNING means "at least one configured team's server answers",
  # and PORT is the first such port (falling back to the first configured team's
  # port, then the legacy file, then 8080) so the field is never empty.
  LCARS_RUNNING=false
  LCARS_PORT=""
  LCARS_TEAM_STATUS=""   # newline-delimited "<key>|<port>|<up>"
  LCARS_UP_COUNT=0
  LCARS_TOTAL_COUNT=0

  for _lcars_team in $CONFIGURED_TEAMS; do
    [ -z "$_lcars_team" ] && continue

    _lcars_key=""
    _lcars_key=$(aiteamforge_resolve_team_key "$_lcars_team" 2>/dev/null) || _lcars_key=""
    [ -z "$_lcars_key" ] && continue

    _lcars_port=""
    _lcars_port=$(aiteamforge_team_lcars_port "$_lcars_key" 2>/dev/null) || _lcars_port=""
    [ -z "$_lcars_port" ] && continue

    LCARS_TOTAL_COUNT=$((LCARS_TOTAL_COUNT + 1))

    _lcars_up=false
    if curl -s -o /dev/null -w '%{http_code}' "http://localhost:${_lcars_port}/" 2>/dev/null | grep -q '200'; then
      _lcars_up=true
      LCARS_UP_COUNT=$((LCARS_UP_COUNT + 1))
      LCARS_RUNNING=true
      [ -z "$LCARS_PORT" ] && LCARS_PORT="$_lcars_port"
    fi

    LCARS_TEAM_STATUS="${LCARS_TEAM_STATUS}${_lcars_key}|${_lcars_port}|${_lcars_up}
"
  done

  # Scalar fallbacks so the JSON `port` field is never empty.
  if [ -z "$LCARS_PORT" ] && [ -n "$LCARS_TEAM_STATUS" ]; then
    LCARS_PORT=$(printf '%s' "$LCARS_TEAM_STATUS" | head -1 | cut -d'|' -f2)
  fi
  if [ -z "$LCARS_PORT" ] && [ -f "${WORKING_DIR}/lcars-ui/.lcars-port" ]; then
    LCARS_PORT="$(cat "${WORKING_DIR}/lcars-ui/.lcars-port" 2>/dev/null || echo 8080)"
  fi
  [ -z "$LCARS_PORT" ] && LCARS_PORT=8080

  # Fleet Monitor — check server AND client (reporter)
  FLEET_RUNNING=false
  FLEET_PORT=""
  FLEET_HAS_SERVER=false
  FLEET_REPORTER_INSTALLED=false
  FLEET_REPORTER_AGENT_LOADED=false

  if [ -d "${WORKING_DIR}/fleet-monitor/server" ]; then
    FLEET_HAS_SERVER=true
    # shellcheck disable=SC2086
    for port in $FLEET_MONITOR_PORT_SCAN_RANGE; do
      if curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}/" 2>/dev/null | grep -q '200'; then
        FLEET_RUNNING=true
        FLEET_PORT=$port
        break
      fi
    done
  fi

  # Fleet reporter client
  if [ -f "${WORKING_DIR}/fleet-monitor/client/fleet-reporter.sh" ]; then
    FLEET_REPORTER_INSTALLED=true
  fi

  # Fleet reporter LaunchAgent
  if launchctl list 2>/dev/null | grep -q "com.aiteamforge.fleet-reporter"; then
    FLEET_REPORTER_AGENT_LOADED=true
  fi

  # LaunchAgents status
  KANBAN_BACKUP_AGENT_LOADED=false
  if launchctl list 2>/dev/null | grep -q "com.aiteamforge.kanban-backup"; then
    KANBAN_BACKUP_AGENT_LOADED=true
  fi

  LCARS_HEALTH_AGENT_LOADED=false
  if launchctl list 2>/dev/null | grep -q "com.aiteamforge.lcars-health"; then
    LCARS_HEALTH_AGENT_LOADED=true
  fi

  # Active worktrees
  WORKTREE_COUNT=0
  if [ -d "${WORKING_DIR}/worktrees" ]; then
    WORKTREE_COUNT=$(find "${WORKING_DIR}/worktrees" -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    WORKTREE_COUNT=$((WORKTREE_COUNT - 1)) # Subtract parent dir
  fi

  # Kanban summary — scan boards in central dir AND team-specific paths
  TOTAL_ITEMS=0
  IN_PROGRESS_ITEMS=0
  BOARD_COUNT=0

  _count_board() {
    local board="$1"
    [ -f "$board" ] || return
    BOARD_COUNT=$((BOARD_COUNT + 1))
    if command -v jq &>/dev/null; then
      # Support both schema formats: .backlog[] (flat) and .columns[].items[] (columnar)
      local items
      items=$(jq '(try ([.columns[].items[]] | length) catch 0) + (try (.backlog | length) catch 0)' "$board" 2>/dev/null || echo "0")
      TOTAL_ITEMS=$((TOTAL_ITEMS + items))

      local in_progress
      in_progress=$(jq '(try ([.columns[] | select(.id == "in-progress") | .items[]] | length) catch 0) + (try ([.backlog[] | select(.status == "in-progress")] | length) catch 0)' "$board" 2>/dev/null || echo "0")
      IN_PROGRESS_ITEMS=$((IN_PROGRESS_ITEMS + in_progress))
    fi
  }

  # Scan central kanban dir
  if [ -d "${WORKING_DIR}/kanban" ]; then
    for board in ${WORKING_DIR}/kanban/*-board.json; do
      _count_board "$board"
    done
  fi

  # Scan team-specific kanban dirs from config
  local config_file
  config_file=$(get_config_file)
  if [ -f "$config_file" ] && command -v jq &>/dev/null; then
    local team_paths
    team_paths=$(jq -r '.team_paths // {} | to_entries[] | .value.working_dir // empty' "$config_file" 2>/dev/null)
    while IFS= read -r team_dir; do
      [ -z "$team_dir" ] && continue
      if [ -d "${team_dir}/kanban" ]; then
        for board in ${team_dir}/kanban/*-board.json; do
          _count_board "$board"
        done
      fi
    done <<< "$team_paths"
  fi

  # Last backup
  LAST_BACKUP="None"
  if [ -d "${WORKING_DIR}/kanban-backups" ]; then
    local latest_backup
    latest_backup=$(find "${WORKING_DIR}/kanban-backups" -name "*.json" -type f 2>/dev/null | sort -r | head -n1)
    if [ -n "$latest_backup" ]; then
      LAST_BACKUP=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$latest_backup" 2>/dev/null || echo "Unknown")
    fi
  fi

  # Disk usage
  DISK_USAGE=$(du -sh "${WORKING_DIR}" 2>/dev/null | awk '{print $1}' || echo "Unknown")
  DISK_AVAILABLE=$(df -h "${WORKING_DIR}" 2>/dev/null | awk 'NR==2 {print $4}' || echo "Unknown")
}

# Output JSON format
output_json() {
  cat <<EOF
{
  "configured": true,
  "machine": {
    "name": "${MACHINE_NAME}",
    "id": "${MACHINE_ID}",
    "user": "${USER_NAME}"
  },
  "version": {
    "installed": "${INSTALLED_VERSION}",
    "install_date": "${INSTALL_DATE}"
  },
  "teams": [$(echo "$CONFIGURED_TEAMS" | sed 's/ /", "/g' | sed 's/^/"/;s/$/"/')],
  "services": {
    "lcars": {
      "running": ${LCARS_RUNNING},
      "port": ${LCARS_PORT},
      "teams_up": ${LCARS_UP_COUNT},
      "teams_total": ${LCARS_TOTAL_COUNT},
      "teams": [$(
        _json_first=true
        while IFS='|' read -r _js_key _js_port _js_up; do
          [ -z "$_js_key" ] && continue
          [ "$_json_first" = true ] || printf ', '
          _json_first=false
          printf '{"team": "%s", "port": %s, "running": %s}' "$_js_key" "$_js_port" "$_js_up"
        done <<< "$LCARS_TEAM_STATUS"
      )]
    },
    "fleet_monitor": {
      "server_running": ${FLEET_RUNNING},
      "server_port": "${FLEET_PORT}",
      "reporter_installed": ${FLEET_REPORTER_INSTALLED},
      "reporter_agent_loaded": ${FLEET_REPORTER_AGENT_LOADED}
    }
  },
  "launchagents": {
    "kanban_backup": ${KANBAN_BACKUP_AGENT_LOADED},
    "lcars_health": ${LCARS_HEALTH_AGENT_LOADED},
    "fleet_reporter": ${FLEET_REPORTER_AGENT_LOADED}
  },
  "worktrees": {
    "count": ${WORKTREE_COUNT}
  },
  "kanban": {
    "boards": ${BOARD_COUNT},
    "total_items": ${TOTAL_ITEMS},
    "in_progress": ${IN_PROGRESS_ITEMS},
    "last_backup": "${LAST_BACKUP}"
  },
  "disk": {
    "usage": "${DISK_USAGE}",
    "available": "${DISK_AVAILABLE}"
  }
}
EOF
}

# Output brief format
output_brief() {
  local status="OK"
  if [ "$LCARS_RUNNING" = false ]; then
    status="WARN"
  fi

  echo "AITeamForge ${INSTALLED_VERSION} | ${MACHINE_NAME} | ${IN_PROGRESS_ITEMS}/${TOTAL_ITEMS} tasks | Status: ${status}"
}

# Output full LCARS-styled format
output_full() {
  [[ -t 1 ]] && clear
  print_header "AITEAMFORGE STATUS"

  # Machine Identity
  print_section "Machine Identity"
  print_color "${COLOR_BLUE}" "Machine:     ${MACHINE_NAME}"
  print_color "${COLOR_BLUE}" "Machine ID:  ${MACHINE_ID}"
  print_color "${COLOR_BLUE}" "User:        ${USER_NAME}"
  echo ""

  # Installation
  print_section "Installation"
  print_color "${COLOR_AMBER}" "Version:     ${INSTALLED_VERSION}"
  print_color "${COLOR_AMBER}" "Installed:   ${INSTALL_DATE}"
  print_color "${COLOR_AMBER}" "Location:    ${WORKING_DIR}"
  echo ""

  # Teams
  print_section "Configured Teams"
  if [ -n "$CONFIGURED_TEAMS" ]; then
    for team in $CONFIGURED_TEAMS; do
      print_color "${COLOR_LILAC}" "  • ${team}"
    done
  else
    print_info "No teams configured"
  fi
  echo ""

  # Services
  print_section "Services"

  # Per-team LCARS status (XACA-0792-001). One line per configured team with the
  # port actually resolved from the registry, so a team that is up on a non-default
  # port is no longer reported as down.
  if [ -n "$LCARS_TEAM_STATUS" ]; then
    if [ "$LCARS_UP_COUNT" -eq "$LCARS_TOTAL_COUNT" ]; then
      print_success "LCARS Kanban Server (${LCARS_UP_COUNT}/${LCARS_TOTAL_COUNT} teams running)"
    elif [ "$LCARS_UP_COUNT" -gt 0 ]; then
      print_warning "LCARS Kanban Server (${LCARS_UP_COUNT}/${LCARS_TOTAL_COUNT} teams running)"
    else
      print_error "LCARS Kanban Server (not running)"
    fi

    while IFS='|' read -r _st_key _st_port _st_up; do
      [ -z "$_st_key" ] && continue
      if [ "$_st_up" = "true" ]; then
        print_color "${COLOR_LILAC}" "    ✓ ${_st_key} — port ${_st_port}"
      else
        print_color "${COLOR_LILAC}" "    ✗ ${_st_key} — port ${_st_port} (not running)"
      fi
    done <<< "$LCARS_TEAM_STATUS"
  elif [ "$LCARS_RUNNING" = true ]; then
    print_success "LCARS Kanban Server (port ${LCARS_PORT})"
  else
    print_error "LCARS Kanban Server (not running)"
  fi

  # Fleet Monitor server (only if server directory exists)
  if [ "$FLEET_HAS_SERVER" = true ]; then
    if [ "$FLEET_RUNNING" = true ]; then
      print_success "Fleet Monitor Server (port ${FLEET_PORT})"
    else
      print_error "Fleet Monitor Server (not running)"
    fi
  fi

  # Fleet reporter client
  if [ "$FLEET_REPORTER_INSTALLED" = true ]; then
    if [ "$FLEET_REPORTER_AGENT_LOADED" = true ]; then
      print_success "Fleet Reporter (active)"
    else
      print_warning "Fleet Reporter (installed, agent not loaded)"
    fi
  fi

  echo ""

  # LaunchAgents
  print_section "Background Services"

  if [ "$KANBAN_BACKUP_AGENT_LOADED" = true ]; then
    print_success "Kanban Backup (hourly)"
  else
    print_warning "Kanban Backup (not loaded)"
  fi

  if [ "$LCARS_HEALTH_AGENT_LOADED" = true ]; then
    print_success "LCARS Health Monitor"
  else
    print_warning "LCARS Health Monitor (not loaded)"
  fi

  if [ "$FLEET_REPORTER_AGENT_LOADED" = true ]; then
    print_success "Fleet Reporter Agent (60s interval)"
  fi

  echo ""

  # Active Work
  print_section "Active Work"
  print_color "${COLOR_BLUE}" "Worktrees:   ${WORKTREE_COUNT}"
  echo ""

  # Kanban Summary
  print_section "Kanban Boards"
  print_color "${COLOR_AMBER}" "Teams:       ${BOARD_COUNT}"
  print_color "${COLOR_AMBER}" "Total Items: ${TOTAL_ITEMS}"
  print_color "${COLOR_AMBER}" "In Progress: ${IN_PROGRESS_ITEMS}"
  print_color "${COLOR_AMBER}" "Last Backup: ${LAST_BACKUP}"
  echo ""

  # Disk Usage
  print_section "Storage"
  print_color "${COLOR_BLUE}" "Usage:       ${DISK_USAGE}"
  print_color "${COLOR_BLUE}" "Available:   ${DISK_AVAILABLE}"
  echo ""

  # Overall Status
  print_section "Overall Status"

  local issues=0

  if [ "$LCARS_RUNNING" = false ]; then
    print_warning "LCARS server not running (start: aiteamforge start)"
    issues=$((issues + 1))
  fi

  if [ "$KANBAN_BACKUP_AGENT_LOADED" = false ]; then
    print_warning "Kanban backup not active"
    issues=$((issues + 1))
  fi

  if [ $issues -eq 0 ]; then
    print_success "All systems operational"
  else
    print_warning "${issues} issue(s) detected (run: aiteamforge doctor)"
  fi

  echo ""
}

# Gather data
gather_status_data

# Output based on format
if [ "$JSON_OUTPUT" = true ]; then
  output_json
elif [ "$BRIEF" = true ]; then
  output_brief
else
  output_full
fi

exit 0
