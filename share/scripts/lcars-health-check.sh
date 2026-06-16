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

# XACA-0626 Defect B fix: derive LCARS_UI_DIR from AITEAMFORGE_DIR instead of
# hardcoding ~/dev-team. On tap machines the install dir is ~/aiteamforge; on the
# dev source machine it is ~/dev-team. When AITEAMFORGE_DIR is not exported, probe
# both well-known dirs (tap first, then dev) — same idiom finance-connect.sh uses —
# so a manual/cron run on the dev machine resolves ~/dev-team rather than a
# non-existent ~/aiteamforge. An explicitly-set AITEAMFORGE_DIR always wins.
# DEV_TEAM_DIR is kept as an alias so any remaining references still compile.
if [[ -z "${AITEAMFORGE_DIR:-}" ]]; then
    for _atf_d in "$HOME/aiteamforge" "$HOME/dev-team"; do
        [[ -d "$_atf_d" ]] && AITEAMFORGE_DIR="$_atf_d" && break
    done
    AITEAMFORGE_DIR="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
    unset _atf_d
fi
DEV_TEAM_DIR="$AITEAMFORGE_DIR"
LCARS_UI_DIR="$AITEAMFORGE_DIR/lcars-ui"
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
# Start LCARS server for a team (health-check restart path)
# ============================================================================
# XACA-0614: This function now uses resolve_lcars_python() from
# lcars-launch-helpers.sh (the single canonical python resolver) and adopts
# the same nohup+disown durable-detach form as start_lcars_server so a
# health-restarted server is HUP-immune too (XACA-0652 invariant).
#
# SIBLING: keep in sync with lcars-launch-helpers.sh::start_lcars_server —
# the launch form (nohup env ... sh -c 'exec ... python3 server.py ...') must
# remain identical to preserve HUP-immunity and PID-trackability.
#
# LaunchAgent compatibility: sources lcars-launch-helpers.sh once via the
# same _SCRIPT_DIR already used above to locate lcars_ports.py. Sourcing only
# defines functions (no side-effects); safe under launchd's minimal env.
_hc_start_lcars_server() {
    local local_port=$1
    local team=$2
    local session_name=$3

    log "  Starting LCARS server: team=$team port=$local_port session=$session_name"

    # Source the shared helpers to get resolve_lcars_python (XACA-0614).
    # _SCRIPT_DIR is already set at the top of this file.
    local _helpers="${_SCRIPT_DIR}/scripts/lcars-launch-helpers.sh"
    if [[ -f "$_helpers" ]]; then
        # shellcheck disable=SC1090
        source "$_helpers" 2>/dev/null || true
    fi

    # Resolve the python that has the LCARS runtime deps (venv on tap hosts,
    # bare python3 as last-resort on the dev source machine). Falls back to
    # plain python3 if resolve_lcars_python is not yet defined (e.g., helpers
    # failed to source in an extremely constrained env).
    local lcars_python
    if typeset -f resolve_lcars_python >/dev/null 2>&1; then
        lcars_python="$(resolve_lcars_python)"
    else
        lcars_python="python3"
    fi

    # XACA-0713: server.py requires Python >= 3.10 at RUNTIME (PEP-604 unions are
    # deferred by `from __future__ import annotations`, but other runtime paths
    # may still assume 3.10+). If the resolver had to fall back to the macOS
    # system python3 (3.9.6) — e.g. no venv installed, brew unreachable under
    # launchd — the server will crash on boot. Emit a LOUD, unmistakable warning
    # to the log so the failure is diagnosable. This is a WARNING, not a hard
    # abort: the dev source machine intentionally runs a globally-installed 3.x.
    local _lcars_pyver
    _lcars_pyver="$("$lcars_python" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
    if [[ -n "$_lcars_pyver" ]]; then
        local _lcars_pymaj="${_lcars_pyver%%.*}"
        local _lcars_pymin="${_lcars_pyver#*.}"
        if [[ "$_lcars_pymaj" -lt 3 ]] \
           || { [[ "$_lcars_pymaj" -eq 3 ]] && [[ "$_lcars_pymin" -lt 10 ]]; }; then
            log "  ############################################################"
            log "  ## XACA-0713 WARNING: resolved python is ${_lcars_pyver} (< 3.10)"
            log "  ## interpreter: ${lcars_python}"
            log "  ## server.py REQUIRES >= 3.10 and will likely CRASH on boot."
            log "  ## Cause: LCARS venv not found / brew unreachable under this"
            log "  ## environment (launchd PATH?) — falling back to system python3."
            log "  ## Fix: ensure the aiteamforge venv exists, or set \$LCARS_PYTHON."
            log "  ############################################################"
        fi
    fi

    # Kill any zombie process on this port
    pkill -f "server.py.*$local_port" 2>/dev/null
    sleep 1

    # XACA-0614 / XACA-0652: Durable server launch — mirrors start_lcars_server.
    # nohup + disown ensures the restarted server survives SSH logout and the
    # health-check LaunchAgent's own process-group cleanup.
    local _hc_log="/tmp/lcars-${team}-${local_port}.log"
    nohup env \
        _ATF_LCARS_DIR="${LCARS_UI_DIR}" \
        _ATF_TEAM="${team}" \
        _ATF_SESSION="${session_name}" \
        _ATF_PYTHON="${lcars_python}" \
        _ATF_PORT="${local_port}" \
        sh -c 'cd "$_ATF_LCARS_DIR" && exec env \
            LCARS_TEAM="$_ATF_TEAM" LCARS_SESSION_NAME="$_ATF_SESSION" \
            "$_ATF_PYTHON" server.py "$_ATF_PORT"' \
        >/dev/null 2>>"${_hc_log}" &
    local _hc_pid=$!
    disown "${_hc_pid}" 2>/dev/null || true

    # Wait for it to come up (10s, same budget as before)
    local attempts=0
    while [[ $attempts -lt 10 ]]; do
        if check_server_health "$local_port"; then
            log "  Server started successfully on port $local_port (pid ${_hc_pid})"
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
# Detect the actual bound port of every running LCARS server, keyed by team.
# ============================================================================
# XACA-0706 (root cause of XACA-0613): the health loop below only asked
# "is something answering on the team's CANONICAL port?". It was blind to a
# live <instance>-lcars server.py bound to a NON-canonical port — the exact
# state M1Pro's finance-personal got stuck in after the v0.15.0 resolver
# refresh moved its canonical port (8360) while a long-lived session kept
# serving on the pre-refresh cksum port (8427). The launcher's has-session
# idempotency guard then BLOCKED recreation, so script+config fixes never
# rebound the running session; the phantom later died unnoticed for 13 days.
#
# This function does one cheap `ps eww` sweep and maps team -> bound port(s)
# so the loop can compare bound-vs-canonical and self-heal surgically.
#
# HOW WE READ THE BOUND PORT (verified against real `ps eww` on macOS):
#   Every LCARS server is launched (start_lcars_server / _hc_start_lcars_server)
#   as:  env LCARS_TEAM=<team> ... <python> server.py <PORT>
#   `ps eww -o args=` prints the argv ("<python> server.py <PORT>") immediately
#   followed by the inherited environment ("... LCARS_TEAM=<team> ..."), with NO
#   delimiter between them. We therefore parse two anchored tokens out of that
#   single string:
#     - PORT: the first integer that follows the literal "server.py " (argv tail)
#     - TEAM: the value after a whitespace-prefixed "LCARS_TEAM=" up to the next
#             space (team ids never contain whitespace)
#   Both anchors are immune to the noisy env blob (paths with spaces, the giant
#   CLAUDE_SYSTEM_PROMPT, CC_SESSION_NAME text that merely mentions "port", and
#   the sibling _ATF_TEAM= / LCARS_SESSION_NAME= vars) because neither the bare
#   word "port" nor those vars carry the exact `server.py <N>` / ` LCARS_TEAM=`
#   prefixes we anchor on.
#
# Populates the global associative array LCARS_BOUND_PORTS (team -> "p1 p2 ...").
# A team may legitimately appear with multiple ports if a stale + fresh server
# coexist; the caller handles that.
typeset -gA LCARS_BOUND_PORTS
detect_lcars_bound_ports() {
    LCARS_BOUND_PORTS=()
    local _pid _args _team _port
    for _pid in ${(f)"$(pgrep -f 'server\.py' 2>/dev/null)"}; do
        [[ -z "$_pid" ]] && continue
        _args="$(ps eww -o args= -p "$_pid" 2>/dev/null)"
        [[ -z "$_args" ]] && continue
        # Only LCARS servers carry an LCARS_TEAM env var; skip anything else
        # (e.g. an unrelated server.py) that lacks it.
        _team="${_args##*[[:space:]]LCARS_TEAM=}"
        # No match → ${...##...} returns the string unchanged; guard on that.
        [[ "$_team" == "$_args" ]] && continue
        _team="${_team%%[[:space:]]*}"
        [[ -z "$_team" ]] && continue
        # Port = first integer immediately after "server.py ".
        _port="${_args#*server.py[[:space:]]}"
        _port="${_port%%[^0-9]*}"
        [[ -z "$_port" ]] && continue
        if [[ -n "${LCARS_BOUND_PORTS[$_team]:-}" ]]; then
            LCARS_BOUND_PORTS[$_team]="${LCARS_BOUND_PORTS[$_team]} $_port"
        else
            LCARS_BOUND_PORTS[$_team]="$_port"
        fi
    done
}

# ============================================================================
# Surgically heal a team whose live LCARS server is bound to a non-canonical
# port: kill ONLY that team's <instance>-lcars tmux session and the stale
# server.py on the wrong port(s), then recreate on the canonical port.
# ============================================================================
# XACA-0706: This NEVER re-runs <team>-startup.sh — live agent tmux panes and
# sessions in that team must be untouched. We only kill the one <instance>-lcars
# session and the wrong-port server.py, then call _hc_start_lcars_server (which
# already mirrors start_lcars_server's HUP-immune nohup+disown launch form).
_hc_heal_noncanonical_port() {
    local canonical_port=$1
    local team=$2
    local session_name=$3
    local tmux_socket=$4
    local wrong_ports=$5  # space-separated list of bound ports != canonical

    log "  Healing $team: live server bound to non-canonical port(s) [$wrong_ports], canonical=$canonical_port"

    # 1. Kill the team's <instance>-lcars tmux session ONLY (not other panes).
    #    The session name is the team's session_pattern with the leading ".*"
    #    glob stripped, matching how run_health_check derives it for restart.
    local kill_session="${session_name}"
    local socket_path="$TMUX_SOCKET_DIR/$tmux_socket"
    if [[ -S "$socket_path" ]]; then
        if tmux -S "$socket_path" has-session -t "$kill_session" 2>/dev/null; then
            log "    Killing stale tmux session: $kill_session (socket $tmux_socket)"
            tmux -S "$socket_path" kill-session -t "$kill_session" 2>/dev/null || true
        fi
    else
        # Fallback to -L syntax.
        if tmux -L "$tmux_socket" has-session -t "$kill_session" 2>/dev/null; then
            log "    Killing stale tmux session: $kill_session (socket $tmux_socket)"
            tmux -L "$tmux_socket" kill-session -t "$kill_session" 2>/dev/null || true
        fi
    fi

    # 2. Kill the stale server.py process(es) on each wrong port. Anchor the
    #    port at a word boundary so "8427" cannot match "84270" (XACA-0661 idiom).
    local _wp
    for _wp in ${=wrong_ports}; do
        [[ "$_wp" == "$canonical_port" ]] && continue
        log "    Killing stale server.py on wrong port $_wp"
        pkill -f "server\.py[[:space:]].*[[:space:]]${_wp}([[:space:]]|\$)" 2>/dev/null || \
            pkill -f "server\.py[[:space:]]${_wp}([[:space:]]|\$)" 2>/dev/null || true
    done
    sleep 1

    # 3. Recreate on the CANONICAL port via the shared restart path.
    _hc_start_lcars_server "$canonical_port" "$team" "$session_name"
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
    local drifted=0
    # XACA-0706: hoist loop-scoped scratch var. A bare `local _bp` INSIDE the
    # outer loop re-declares an already-set local on the 2nd+ iteration, which
    # zsh prints as `_bp=<value>` to stdout — corrupting the health-check log
    # (k501-zsh-local-in-loop-gotcha). Declare once here, assign without `local`
    # inside the loop.
    local _bp

    log "═══════════════════════════════════════════════════════"
    log "LCARS Health Check"
    log "═══════════════════════════════════════════════════════"

    # XACA-0706: one ps sweep up front — map every live LCARS server's actual
    # bound port by team, so the loop can catch a server bound to a
    # non-canonical port (the XACA-0613 refresh-gap) before the canonical-port
    # health check masks it.
    detect_lcars_bound_ports

    for server_config in "${LCARS_SERVERS[@]}"; do
        # Parse config
        IFS=':' read -r funnel_port local_port team tmux_socket session_pattern <<< "$server_config"

        # The canonical <instance>-lcars session name = pattern minus the ".*"
        # glob (freelance uses ".*-lcars"). Used for both surgical heal and the
        # normal restart path below.
        local canonical_session="${session_pattern/\.\*/}"

        # XACA-0706: NON-CANONICAL-PORT DRIFT DETECTION.
        # Compare the team's actual bound port(s) against its canonical port.
        # A live server.py for this team bound to a port != $local_port is the
        # XACA-0613 stuck-on-stale-port case. We detect it BEFORE the canonical
        # health check because the canonical port is usually dead in that state
        # (the server is serving the wrong port) — and even if both are up, a
        # server on the wrong port is still wrong and must be reconciled.
        local _bound="${LCARS_BOUND_PORTS[$team]:-}"
        local _noncanonical=""
        if [[ -n "$_bound" ]]; then
            for _bp in ${=_bound}; do
                [[ "$_bp" != "$local_port" ]] && _noncanonical="${_noncanonical:+$_noncanonical }$_bp"
            done
        fi
        if [[ -n "$_noncanonical" ]]; then
            log "  [diag] $team: bound=[$_bound] canonical=$local_port — NON-CANONICAL DRIFT on [$_noncanonical]"
            ((drifted++))
            if [[ "$STATUS_ONLY" == "false" ]]; then
                log "🔧 $team - self-healing non-canonical-port drift"
                if _hc_heal_noncanonical_port "$local_port" "$team" "$canonical_session" "$tmux_socket" "$_noncanonical"; then
                    ((restarted++))
                fi
                continue
            else
                log "⚠️  $team:$local_port - bound to non-canonical port(s) [$_noncanonical] (status-only: not healed)"
                # Fall through to normal status reporting below.
            fi
        else
            log "  [diag] $team: bound=[${_bound:-none}] canonical=$local_port — port OK"
        fi

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

        # XACA-0626 Defect C fix: gate on configured-team membership, not on a live
        # tmux session or zombie process. After a machine reboot no tmux sessions
        # exist and no processes are running, so the old "team_active" check would
        # skip ALL teams — preventing the health check from ever restarting LCARS.
        # Any team that made it into LCARS_SERVERS (i.e., has a valid resolved port
        # from aiteamforge_paths.py / team-paths.json) is a configured team that
        # SHOULD have LCARS running. We still log session/process state as a hint.
        local has_session=false has_process=false
        if check_tmux_session "$tmux_socket" "$session_pattern"; then
            has_session=true
        fi
        if check_server_process_exists "$local_port"; then
            has_process=true
        fi
        log "  [diag] $team: tmux_session=$has_session process=$has_process"
        # All teams in LCARS_SERVERS are configured; if the server is not responding,
        # attempt restart regardless of session/process state.

        # Server not responding for a configured team — restart it
        log "❌ $team:$local_port - NOT RESPONDING (configured team)"
        ((unhealthy++))

        if [[ "$STATUS_ONLY" == "false" ]]; then
            _hc_start_lcars_server "$local_port" "$team" "$canonical_session"
            if [[ $? -eq 0 ]]; then
                ((restarted++))
            fi
        fi
    done

    log "───────────────────────────────────────────────────────"
    log "Summary: $healthy healthy, $unhealthy unhealthy (configured teams that were restarted/retried), $drifted non-canonical-port drift, $skipped skipped (port-unresolved)"

    if [[ "$STATUS_ONLY" == "false" && $restarted -gt 0 ]]; then
        log "Restarted: $restarted servers"
    fi

    log "═══════════════════════════════════════════════════════"

    # Return non-zero in status-only mode if any server is unhealthy or bound to
    # a non-canonical port (XACA-0706 — surfaces the drift to callers/monitors).
    if [[ "$STATUS_ONLY" == "true" && ( $unhealthy -gt 0 || $drifted -gt 0 ) ]]; then
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
