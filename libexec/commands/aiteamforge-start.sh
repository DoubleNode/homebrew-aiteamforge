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
source "${LIBEXEC_DIR}/lib/constants.sh"
# aiteamforge-paths.sh provides aiteamforge_team_lcars_port (used by start_lcars).
# It carries its own include-guard, so sourcing here is idempotent.
source "${LIBEXEC_DIR}/lib/aiteamforge-paths.sh"

# Version — read from VERSION file (single source of truth)
_find_version() { for p in "${LIBEXEC_DIR}/../VERSION" "${LIBEXEC_DIR}/../../VERSION"; do [ -f "$p" ] && cat "$p" | tr -d '[:space:]' && return; done; echo "unknown"; }
VERSION="$(_find_version)"

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

# ─────────────────────────────────────────────────────────────────────────────
# First-launch preflight self-heal (XACA-0655-004)
#
# Runs ONCE per install/upgrade, gated by a version-stamped sentinel so a fresh
# install or `brew upgrade` re-runs it exactly once. Delegates to
# `aiteamforge-doctor.sh --preflight`, which runs the fast/critical subset,
# auto-applies SAFE remediations silently, logs to ~/.aiteamforge/logs, prints
# at most one concise line, and NEVER blocks (always exits 0). We wrap it in
# `|| true` and background-safe guards so it cannot abort `aiteamforge start`.
#
# RE-ENTRY SAFETY (XACA-0655 review fix): a SAFE remediation run during preflight
# may itself shell out to `aiteamforge start` (the `server` self-heal historically
# ran `aiteamforge start kanban`). That nested start would re-enter this function;
# on a first launch with the server down the sentinel is not yet stamped, so every
# level re-runs preflight before ever starting the server → infinite recursion /
# fork-bomb. Two independent guards prevent this:
#   1. An EXPORTED process-tree guard (AITEAMFORGE_PREFLIGHT_ACTIVE) — any nested
#      `aiteamforge` invocation inherits it and skips preflight entirely.
#   2. The sentinel is stamped BEFORE invoking the doctor (not after), so even a
#      cross-process re-entry that does not inherit the env var no-ops. Stamping
#      first is safe: preflight is best-effort self-heal, already a one-shot that
#      never retries within a version regardless of outcome.
# (The doctor also refuses to auto-start the server while in --preflight mode.)
# ─────────────────────────────────────────────────────────────────────────────
run_first_launch_preflight() {
  # Guard 1: process-tree re-entry guard — exported so nested aiteamforge calls skip.
  [ -n "${AITEAMFORGE_PREFLIGHT_ACTIVE:-}" ] && return 0

  local sentinel_dir="${HOME}/.aiteamforge"
  local sentinel="${sentinel_dir}/.doctor-preflight-${VERSION}"

  # Already ran for this version → no-op.
  [ -f "$sentinel" ] && return 0

  local doctor="${LIBEXEC_DIR}/commands/aiteamforge-doctor.sh"
  if [ ! -x "$doctor" ] && [ ! -f "$doctor" ]; then
    return 0
  fi

  # Guard 2: stamp the sentinel BEFORE running the doctor, so any re-entry (this
  # process tree or a fresh one) sees it and no-ops. Best-effort, never blocks.
  mkdir -p "$sentinel_dir" 2>/dev/null || true
  : > "$sentinel" 2>/dev/null || true

  # Run the non-blocking self-heal under the exported re-entry guard. The doctor
  # exits 0 even on findings, but guard with `|| true` so a crash can't block launch.
  AITEAMFORGE_PREFLIGHT_ACTIVE=1 bash "$doctor" --preflight || true

  return 0
}

run_first_launch_preflight

# Banner
[[ -t 1 ]] && clear
print_header "AITEAMFORGE START"

# Gate: check for LCARS port collisions before launching servers.
# If collisions or null ports are found, print an actionable message and abort.
# Degrades gracefully if the tool is not installed (warn, continue).
check_port_health() {
  # Resolve the port-fix command: prefer the on-PATH bin stub, fall back to
  # libexec. Held as an array so a libexec path containing spaces survives
  # invocation without word-splitting. (XACA-0557 review, PR #472)
  local port_fix_cmd=()
  if command -v aiteamforge-port-fix &>/dev/null; then
    port_fix_cmd=(aiteamforge-port-fix)
  else
    local _libexec_pf="${SCRIPT_DIR}/kb-port-fix.py"
    if [ -x "$_libexec_pf" ]; then
      port_fix_cmd=(python3 "$_libexec_pf")
    fi
  fi

  if [ ${#port_fix_cmd[@]} -eq 0 ]; then
    print_warning "kb-port-fix not found — skipping port health check (degrade gracefully)"
    return 0
  fi

  # XACA-0762-005: capture the --check exit code directly rather than piping
  # it (`$?` after a pipe is the LAST command's status, not kb-port-fix's —
  # see MEMORY feedback_pipefail_hides_exit_code.md). This script runs under
  # `set -eo pipefail` (line 6), so the capture MUST happen inside an if/else
  # — a bare `cmd; rc=$?` statement is itself subject to set -e and aborts the
  # WHOLE start script the instant cmd returns non-zero, before rc=$? even
  # runs (verified empirically: the bare form never reaches the following
  # line under set -e). if/else conditions are exempt from set -e.
  local port_check_rc=0
  if "${port_fix_cmd[@]}" --check 2>/dev/null; then
    port_check_rc=0
  else
    port_check_rc=$?
  fi

  # Happy path: ports already healthy.
  if [ "$port_check_rc" -eq 0 ]; then
    print_success "LCARS port health check passed"
    return 0
  fi

  # XACA-0762-005: exit 3 means "config file not found" — a genuinely
  # unconfigured install, not a discovered problem. Degrade gracefully (warn
  # + continue) exactly like the "tool not found" branch above, instead of
  # falling into the auto-apply path below (which would itself fail the same
  # way against a missing file, and previously hard-aborted `aiteamforge
  # start` entirely — see kb-port-fix.py's --check exit-code contract at
  # ~line 341/579 for the 0/1/3 contract).
  if [ "$port_check_rc" -eq 3 ]; then
    print_warning "team-paths.json not found — skipping port health check (degrade gracefully)"
    return 0
  fi

  # XACA-0702: a failed --check used to ABORT start/restart and tell the user to
  # run the remediation by hand. That is busywork for a documented, self-applying
  # fix — so auto-apply it. Announce LOUDLY what we are doing (this MUTATES
  # team-paths.json port assignments), run `--apply`, then re-verify with `--check`.
  # Only if it STILL fails after the reconcile do we abort.
  print_warning "═══════════════════════════════════════════════════════════════"
  print_warning "LCARS port collision or null-port detected in team-paths.json."
  print_warning "Auto-applying a port reconcile (aiteamforge-port-fix --apply --yes):"
  print_warning "  this reassigns colliding/unset LCARS ports to free, unique values"
  print_warning "  so each team's LCARS server can bind correctly."
  print_warning "═══════════════════════════════════════════════════════════════"

  # XACA-0762: --yes is mandatory here, not cosmetic. This gate runs under
  # lcars-watch, whose stdin is non-interactive (not a tty). kb-port-fix.py's
  # cmd_apply() requires --yes when stdin is non-interactive — without it,
  # it detects the non-tty stdin and refuses with exit 1 EVERY time, so this
  # "auto-apply" self-heal was guaranteed to fail under the exact supervisor
  # that invokes it. Net effect: one team with a null lcars_port blocked
  # EVERY team's LCARS server from starting. Consent is already implied by
  # the loud warning above (and cmd_apply backs up team-paths.json before
  # mutating it), so skip the interactive confirmation explicitly.
  if ! "${port_fix_cmd[@]}" --apply --yes; then
    print_error "Port reconcile (--apply --yes) failed."
    print_error "Resolve manually with: aiteamforge-port-fix --apply --yes"
    print_error "Then re-run: aiteamforge start"
    return 1
  fi

  # Re-verify after the auto-apply. Same guarded-capture pattern as above —
  # rc==3 ("config not found") shouldn't be reachable here in practice (the
  # --apply --yes above already proved the config file exists, or we'd have
  # returned 1 at line ~235), but handle it the same way for robustness
  # rather than falling through to the generic "STILL failing" error.
  local port_recheck_rc=0
  if "${port_fix_cmd[@]}" --check 2>/dev/null; then
    port_recheck_rc=0
  else
    port_recheck_rc=$?
  fi

  if [ "$port_recheck_rc" -eq 0 ]; then
    print_success "Port reconcile applied — LCARS port health check now passes"
    return 0
  fi

  if [ "$port_recheck_rc" -eq 3 ]; then
    print_warning "team-paths.json not found on re-verify — skipping port health check (degrade gracefully)"
    return 0
  fi

  print_error "Port health STILL failing after auto-applied reconcile."
  print_error "This needs manual attention — inspect team-paths.json port assignments."
  print_error "Re-run after fixing: aiteamforge start"
  return 1
}

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

# Start LCARS server(s) — one per configured team instance.
#
# XACA-0555: server.py (0.12.0+) enforces the team-id contract and FATALs at
# boot when LCARS_TEAM is unset (validate_lcars_team_or_die, team-id-contract
# §6). Previously this launched a single bare `python3 server.py <port>` with
# no LCARS_TEAM, so the server died immediately. We loop the configured team
# instances, resolve each team's LCARS port from the aiteamforge_paths registry,
# and launch one server per team with LCARS_TEAM / LCARS_SESSION_NAME set.
#
# XACA-0562 (full canonicalization): the actual launch + readiness poll is now
# delegated to start_lcars_server() in the SHARED lcars-launch-helpers.sh — the
# same helper sourced by the 11 per-team *-startup.sh scripts. On a tap machine
# get_working_dir() returns $AITEAMFORGE_DIR and the helper is installed at
# $AITEAMFORGE_DIR/scripts/lcars-launch-helpers.sh, so ${WORKING_DIR}/scripts/...
# is exactly that installed helper. This kills the weaker inline launch (sleep 3
# + curl, one shared /tmp/lcars-server.log, no PID/crash detection) in favor of
# the hardened helper (per-team log, 15s first-boot, crash short-circuit). We
# keep the "already serving → leave it alone" check here so a healthy running
# server is never killed by the helper's pkill (least surprise).
start_lcars() {
  print_section "Starting LCARS Kanban Server"

  local lcars_dir="${WORKING_DIR}/lcars-ui"

  if [ ! -d "$lcars_dir" ]; then
    print_error "LCARS UI not found: ${lcars_dir}"
    return 1
  fi

  # XACA-0562: source the shared launch helper. ${WORKING_DIR}/scripts/... is the
  # SAME installed file the per-team startup scripts source, so the launch/poll
  # behavior is identical across `aiteamforge start` and team startup.
  local _helper="${WORKING_DIR}/scripts/lcars-launch-helpers.sh"
  if [ ! -r "$_helper" ]; then
    print_warning "Shared LCARS launch helper not found at ${_helper} — cannot start LCARS"
    return 1
  fi
  # shellcheck source=/dev/null
  source "$_helper"

  # Resolve configured team instance ids (e.g. "academy", "finance-personal").
  # `|| true` keeps `set -e` from aborting `aiteamforge start` when the config
  # file is missing entirely (get_configured_teams returns 1); the empty-string
  # check below then handles that case gracefully.
  local teams_str=""
  teams_str=$(get_configured_teams) || true
  if [ -z "$teams_str" ]; then
    print_warning "No configured teams found — skipping LCARS startup"
    return 0
  fi

  local -a teams=()
  read -ra teams <<< "$teams_str"

  local ok=0
  local team
  for team in "${teams[@]}"; do
    [ -z "$team" ] && continue

    # Resolve this team's LCARS port from the aiteamforge_paths registry.
    local port=""
    if ! port=$(aiteamforge_team_lcars_port "$team" 2>/dev/null) || [ -z "$port" ]; then
      print_warning "No LCARS port allocated for '${team}' — skipping"
      continue
    fi

    # Already serving on this port? Treat as success and LEAVE IT RUNNING.
    # (Do NOT fall through to start_lcars_server — its pkill would kill a healthy
    # server. Preserving this least-surprise behavior is intentional, XACA-0562.)
    if curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}/" 2>/dev/null | grep -q '200'; then
      print_warning "LCARS already running for '${team}' on port ${port}"
      continue
    fi

    print_info "Starting LCARS for '${team}' on port ${port}..."

    # Delegate launch + readiness poll to the shared helper. It prints its own
    # ✅/⚠️/❌ readiness lines, tracks the server PID, and short-circuits on crash.
    #
    # GUARD: this script runs under `set -eo pipefail` and start_lcars_server
    # returns 1 on soft-fail (slow/hung boot, or crash). The `if` consumes that
    # non-zero return so `set -e` does NOT abort the whole `aiteamforge start`.
    if start_lcars_server "$team" "$port" "${team}-lcars"; then
      ok=$((ok + 1))
      print_info "Access at: http://localhost:${port}"
      [ "$OPEN_BROWSER" = true ] && open "http://localhost:${port}" 2>/dev/null || true
    else
      print_error "LCARS server for '${team}' failed to become ready on port ${port}"
    fi
  done

  if [ "$ok" -eq 0 ]; then
    print_warning "No LCARS servers were launched"
    return 0
  fi

  if [ "$ok" -gt 0 ]; then
    return 0
  fi
  return 1
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
    # shellcheck disable=SC2086
    for port in $FLEET_MONITOR_PORT_SCAN_RANGE; do
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
      # shellcheck disable=SC2086
      for port in $FLEET_MONITOR_PORT_SCAN_RANGE; do
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
      if _aitf_launchctl load "$reporter_plist" 2>/dev/null; then
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
    if _aitf_launchctl load "$plist" 2>/dev/null; then
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
    # Port health gate: abort on collisions/null ports before launching servers.
    check_port_health || exit 1
    start_lcars
    start_fleet
    start_agents
    ;;
  lcars|kanban)
    # Port health gate: abort on collisions/null ports before launching servers.
    check_port_health || exit 1
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
# XACA-0562: LCARS now logs per-team via the shared helper to
# ${AITEAMFORGE_DIR}/logs/lcars-server-<team>.log (not the old shared
# /tmp/lcars-server.log). Fleet monitor still logs to /tmp.
print_info "View logs: ${WORKING_DIR}/logs/lcars-server-<team>.log, /tmp/fleet-monitor.log"

exit 0
