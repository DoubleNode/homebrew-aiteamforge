#!/bin/zsh
# ============================================================================
# LCARS Health Check & Auto-Restart
# ============================================================================
# Monitors LCARS servers and restarts any that have died
#
# Usage:
#   ./lcars-health-check.sh           # Check and restart unhealthy servers
#   ./lcars-health-check.sh --status  # Just show status, don't restart
#   ./lcars-health-check.sh --daemon  # Run as daemon with periodic checks
#
# Can be added to crontab for periodic health checks:
#   */5 * * * * /Users/darrenehlers/dev-team/lcars-health-check.sh >> /tmp/lcars-health.log 2>&1
# ============================================================================

DEV_TEAM_DIR="$HOME/dev-team"
LCARS_UI_DIR="$DEV_TEAM_DIR/lcars-ui"
LOG_FILE="/tmp/lcars-health.log"
STATUS_ONLY=false
DAEMON_MODE=false
DAEMON_INTERVAL=60  # Check every 60 seconds in daemon mode

# Parse arguments
for arg in "$@"; do
    case $arg in
        --status) STATUS_ONLY=true ;;
        --daemon) DAEMON_MODE=true ;;
        --help)
            echo "LCARS Health Check & Auto-Restart"
            echo ""
            echo "Usage:"
            echo "  $0           # Check and restart unhealthy servers"
            echo "  $0 --status  # Just show status, don't restart"
            echo "  $0 --daemon  # Run as daemon with periodic checks"
            exit 0
            ;;
    esac
done

# ============================================================================
# LCARS Server Configuration
# ============================================================================
# Infrastructure-only metadata: funnel_port, tmux_socket, session_pattern.
# Format: "funnel_port:team:tmux_socket:session_pattern"
# session_pattern uses grep-compatible regex
#
# NOTE (XACA-0561): local_port is DERIVED at runtime from
# aiteamforge_paths.DEFAULT_TEAMS[team]["lcars_port"] — it does NOT live here.
# Funnel ports (8443+), tmux sockets, and session patterns are
# infrastructure-specific and live only here.
# When adding teams, add them to both this table AND aiteamforge_paths.py.
# Use 0 for funnel_port if the team is not Tailscale-funneled.
declare -a _LCARS_INFRA=(
    "8443:ios:ios:ios-lcars"
    "8444:android:android:android-lcars"
    "8445:firebase:firebase:firebase-lcars"
    "8446:academy:academy:academy-lcars"
    "8447:dns:dns:dns-lcars"
    "8448:freelance:freelance:.*-lcars"
    "8449:command:command:command-lcars"
    "0:finance-personal:finance-personal:finance-personal-lcars"
    "0:legal-coparenting:legal-coparenting:legal-coparenting-lcars"
)

# Derive lcars_port for each team from the canonical source at runtime via the
# shared kanban-hooks/lcars_ports.py helper (XACA-0561-008 — single source of the
# derivation logic, shared with lcars-smoke-test.sh).
# Both dev-tree (kanban-hooks/ sibling of this script) and shipped tap layout
# (share/kanban-hooks/) resolve via script dir.
_SCRIPT_DIR="${0:A:h}"
_KANBAN_HOOKS_DIR="${_SCRIPT_DIR}/kanban-hooks"

# Extract the team names from the infra table for the port lookup.
_INFRA_TEAMS=()
for _e in "${_LCARS_INFRA[@]}"; do
    IFS=':' read -r _fp _team _sock _pat <<< "$_e"
    _INFRA_TEAMS+=("$_team")
done

# Emits "team:port" per line to stdout; missing/None ports → stderr warning,
# omitted from output so we never build a LCARS_SERVERS entry with "".
_PORT_LOOKUP=$(python3 "${_KANBAN_HOOKS_DIR}/lcars_ports.py" "${_INFRA_TEAMS[@]}")

# Build a team->port associative array from the lookup output.
typeset -A _TEAM_PORT
while IFS=':' read -r _t _p; do
    [[ -n "$_t" && -n "$_p" ]] && _TEAM_PORT[$_t]=$_p
done <<< "$_PORT_LOOKUP"

# Build LCARS_SERVERS by combining infra metadata with derived ports.
# Format: "funnel_port:local_port:team:tmux_socket:session_pattern"
declare -a LCARS_SERVERS=()
for _e in "${_LCARS_INFRA[@]}"; do
    IFS=':' read -r _fp _team _sock _pat <<< "$_e"
    _lp="${_TEAM_PORT[$_team]}"
    if [[ -z "$_lp" ]]; then
        echo "WARNING: no canonical lcars_port for team '$_team' — skipping health-check entry" >&2
        continue
    fi
    LCARS_SERVERS+=("${_fp}:${_lp}:${_team}:${_sock}:${_pat}")
done

# ============================================================================
# Logging & Log Rotation
# ============================================================================
LOG_MAX_SIZE=5242880  # 5MB in bytes
LOG_KEEP_COUNT=2      # Keep 2 rotated logs

log() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1"
}

# Rotate log if it exceeds max size
rotate_log_if_needed() {
    [[ ! -f "$LOG_FILE" ]] && return

    local size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ $size -ge $LOG_MAX_SIZE ]]; then
        # Rotate existing backups
        for ((i=$LOG_KEEP_COUNT-1; i>=1; i--)); do
            if [[ -f "${LOG_FILE}.${i}" ]]; then
                mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))"
            fi
        done
        # Rotate current log
        mv "$LOG_FILE" "${LOG_FILE}.1"
        log "Log rotated (was ${size} bytes)"
    fi
}

# ============================================================================
# Check if a tmux session exists (meaning the team is "active")
# Supports simple patterns with grep matching
# ============================================================================
# Explicitly compute socket dir at runtime for launchd compatibility
TMUX_UID=$(id -u)
TMUX_SOCKET_DIR="/tmp/tmux-${TMUX_UID}"

# Debug: Show socket dir if it doesn't exist or is empty
if [[ ! -d "$TMUX_SOCKET_DIR" ]]; then
    log "WARNING: tmux socket dir not found: $TMUX_SOCKET_DIR (UID: $TMUX_UID)"
fi

check_tmux_session() {
    local socket=$1
    local session_pattern=$2

    # Use explicit socket path for launchd compatibility
    local socket_path="$TMUX_SOCKET_DIR/$socket"

    if [[ ! -S "$socket_path" ]]; then
        # Also try the -L syntax as fallback
        local sessions=$(tmux -L "$socket" list-sessions -F "#{session_name}" 2>/dev/null)
        if [[ -n "$sessions" ]]; then
            if echo "$sessions" | grep -q "$session_pattern"; then
                return 0
            fi
        fi
        return 1  # Socket doesn't exist and -L didn't work
    fi

    # Get all sessions for this socket using -S (explicit path)
    local sessions=$(tmux -S "$socket_path" list-sessions -F "#{session_name}" 2>/dev/null)

    if [[ -z "$sessions" ]]; then
        return 1  # No sessions at all
    fi

    # Check if any session matches the pattern (supports regex)
    if echo "$sessions" | grep -q "$session_pattern"; then
        return 0
    fi

    return 1
}

# ============================================================================
# Check if LCARS server is responding (local)
# ============================================================================
check_server_health() {
    local port=$1
    local timeout=3  # 3 second timeout

    # Try to hit the status endpoint
    if curl -s --max-time $timeout "http://localhost:$port/api/status" > /dev/null 2>&1; then
        return 0  # Healthy
    else
        return 1  # Unhealthy
    fi
}

# ============================================================================
# Check if remote LCARS server is responding via SSH tunnel
# ============================================================================
check_remote_server_health() {
    local host=$1
    local port=$2
    local timeout=3  # 3 second timeout

    # First check if SSH tunnel is alive (via ControlMaster check)
    if ! ssh -O check "$host" 2>/dev/null; then
        log "  SSH tunnel to $host is down"
        return 1
    fi

    # Check if LCARS responds through the tunnel
    if curl -s --max-time $timeout "http://localhost:$port/api/status" > /dev/null 2>&1; then
        return 0  # Healthy (tunnel alive and server responding)
    else
        # Determine if it's tunnel-down or server-down
        # If we got here, ControlMaster is alive, so it's server-down
        log "  LCARS server on $host not responding (tunnel alive)"
        return 1  # Server-down
    fi
}

# ============================================================================
# Get remote host from PID file (if tunnel exists for this port)
# Returns: hostname or empty string if no tunnel
# ============================================================================
get_remote_host_for_port() {
    local port=$1
    local pid_dir="/tmp/lcars-port-forwards"

    if [[ ! -d "$pid_dir" ]]; then
        echo ""
        return 0
    fi

    # Look for PID files matching this port
    for pid_file in "$pid_dir"/*-${port}.pid(N); do
        if [[ -f "$pid_file" ]]; then
            local filename=$(basename "$pid_file" .pid)
            # Extract hostname from "hostname-port.pid" format
            echo "${filename%-${port}}"
            return 0
        fi
    done

    echo ""
    return 0
}

# ============================================================================
# Start LCARS server for a team
# ============================================================================
# Health-check-local variant with a distinct (port, team, session) signature,
# separate from scripts/lcars-launch-helpers.sh::start_lcars_server.
_hc_start_lcars_server() {
    local local_port=$1
    local team=$2
    local session_name=$3

    log "  Starting LCARS server: team=$team port=$local_port session=$session_name"

    # Kill any zombie process on this port
    pkill -f "server.py.*$local_port" 2>/dev/null
    sleep 1

    # Start the server
    cd "$LCARS_UI_DIR" && \
        LCARS_TEAM="$team" \
        LCARS_SESSION_NAME="$session_name" \
        nohup python3 server.py "$local_port" > /tmp/lcars-$team-$local_port.log 2>&1 &

    # Wait for it to come up
    local attempts=0
    while [[ $attempts -lt 10 ]]; do
        if check_server_health "$local_port"; then
            log "  Server started successfully on port $local_port"
            return 0
        fi
        sleep 1
        ((attempts++))
    done

    log "  FAILED to start server on port $local_port"
    return 1
}

# ============================================================================
# Check if server process exists (was started but may have crashed)
# ============================================================================
check_server_process_exists() {
    local port=$1
    pgrep -f "server.py.*$port" > /dev/null 2>&1
    return $?
}

# ============================================================================
# Main health check routine
# ============================================================================
run_health_check() {
    # Rotate log if it's getting too large
    rotate_log_if_needed

    local healthy=0
    local unhealthy=0
    local skipped=0
    local restarted=0

    log "═══════════════════════════════════════════════════════"
    log "LCARS Health Check"
    log "═══════════════════════════════════════════════════════"

    for server_config in "${LCARS_SERVERS[@]}"; do
        # Parse config
        IFS=':' read -r funnel_port local_port team tmux_socket session_pattern <<< "$server_config"

        # Check if this port has a remote tunnel
        local remote_host=$(get_remote_host_for_port "$local_port")

        # First, check if the server is responding
        if [[ -n "$remote_host" ]]; then
            # Remote health check (via SSH tunnel)
            if check_remote_server_health "$remote_host" "$local_port"; then
                log "✅ $team:$local_port - healthy (remote: $remote_host)"
                ((healthy++))
                continue
            fi
        else
            # Local health check (existing behavior)
            if check_server_health "$local_port"; then
                log "✅ $team:$local_port - healthy"
                ((healthy++))
                continue
            fi
        fi

        # Server not responding - check if it's expected to be running
        # Method 1: Check if tmux session exists
        local team_active=false
        if check_tmux_session "$tmux_socket" "$session_pattern"; then
            team_active=true
        fi

        # Method 2: Check if server process exists (crashed but was running)
        if check_server_process_exists "$local_port"; then
            team_active=true
        fi

        if [[ "$team_active" == "false" ]]; then
            log "⏭️  $team:$local_port - team inactive (no session or process)"
            ((skipped++))
            continue
        fi

        # Team is active but server not responding - restart it
        log "❌ $team:$local_port - NOT RESPONDING (team active)"
        ((unhealthy++))

        if [[ "$STATUS_ONLY" == "false" ]]; then
            _hc_start_lcars_server "$local_port" "$team" "${session_pattern/\.\*/}"
            if [[ $? -eq 0 ]]; then
                ((restarted++))
            fi
        fi
    done

    log "───────────────────────────────────────────────────────"
    log "Summary: $healthy healthy, $unhealthy unhealthy, $skipped skipped (inactive teams)"

    if [[ "$STATUS_ONLY" == "false" && $restarted -gt 0 ]]; then
        log "Restarted: $restarted servers"
    fi

    log "═══════════════════════════════════════════════════════"

    # Return non-zero if any servers are unhealthy and weren't restarted
    if [[ $unhealthy -gt 0 && "$STATUS_ONLY" == "true" ]]; then
        return 1
    fi
    return 0
}

# ============================================================================
# Daemon mode - run periodic checks
# ============================================================================
run_daemon() {
    log "Starting LCARS health daemon (checking every ${DAEMON_INTERVAL}s)"
    log "Press Ctrl+C to stop"

    trap 'log "Daemon stopped"; exit 0' INT TERM

    while true; do
        run_health_check
        sleep $DAEMON_INTERVAL
    done
}

# ============================================================================
# Main
# ============================================================================
if [[ "$DAEMON_MODE" == "true" ]]; then
    run_daemon
else
    run_health_check
fi
