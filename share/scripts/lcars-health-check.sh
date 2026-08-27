#!/usr/bin/env zsh
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
# XACA-0890-013: restrict run_health_check's sweep to one team when set
# (--team <name>). Empty (default) = existing full-sweep behaviour, so the
# cron/LaunchAgent/--daemon path is completely unaffected. See run_health_check
# below for the filter and --team's arg-parse case just below for how it's set.
TEAM_FILTER=""

# XACA-0889 mitigation: require 2 CONSECUTIVE failed probes, spaced this many
# seconds apart, before a team is declared unhealthy / restarted. See the
# in-run-vs-persisted-state design note above _hc_check_health_with_retry()
# for why this is an in-run retry rather than a cross-invocation counter.
# Overridable via env for tests (e.g. HEALTH_CHECK_RETRY_DELAY=0).
HEALTH_CHECK_RETRY_DELAY="${HEALTH_CHECK_RETRY_DELAY:-3}"

# XACA-0889-007: validate the override. Without this, a negative or non-numeric
# value silently DISCARDS the backoff instead of failing: BSD sleep treats a
# leading '-' as an option flag ("sleep -5" -> "illegal option -- 5") and rejects
# non-numerics ("invalid time interval"), so the retry fires ~instantly while
# emitting stderr noise. That is the worst outcome — the mitigation appears
# configured but is not actually spacing the probes. Fail loudly to the default.
# NOTE the QUOTED regex. Under zsh, an UNQUOTED =~ right-hand side undergoes
# quote removal before regcomp sees it, so `\.` degrades to `.` — matching ANY
# character, which let 1x3 / 1-3 / 1@3 pass validation and then break sleep:
# exactly the silently-discarded-backoff failure this guard exists to prevent.
# (This is the OPPOSITE of bash, where quoting the =~ RHS forces a literal match.)
if ! [[ "$HEALTH_CHECK_RETRY_DELAY" =~ '^[0-9]+(\.[0-9]+)?$' ]]; then
    echo "WARNING: HEALTH_CHECK_RETRY_DELAY='$HEALTH_CHECK_RETRY_DELAY' is not a non-negative number; falling back to 3s." >&2
    HEALTH_CHECK_RETRY_DELAY=3
fi

# Parse arguments.
# XACA-0890-013: switched from `for arg in "$@"` to a shift-based `while`
# loop so --team can consume its following value — the for-loop form has no
# way to do that. Matches the existing --team convention used elsewhere in
# this repo (kb-reconcile-inprogress/kb-recover in kanban-helpers.sh,
# kb-port-reconcile).
while [[ $# -gt 0 ]]; do
    case "${1-}" in
        --status) STATUS_ONLY=true; shift ;;
        --daemon) DAEMON_MODE=true; shift ;;
        --team)
            TEAM_FILTER="${2-}"
            if [[ -z "$TEAM_FILTER" ]]; then
                echo "ERROR: --team requires a value" >&2
                exit 1
            fi
            shift 2
            ;;
        --help)
            echo "LCARS Health Check & Auto-Restart"
            echo ""
            echo "Usage:"
            echo "  $0                    # Check and restart unhealthy servers (all teams)"
            echo "  $0 --status           # Just show status, don't restart"
            echo "  $0 --daemon           # Run as daemon with periodic checks"
            echo "  $0 --team <name>      # Restrict the sweep to one team (e.g. --team finance-personal)"
            echo ""
            echo "--team narrows run_health_check's LCARS_SERVERS sweep to the single named"
            echo "team (matched against the team field of the infra table) instead of every"
            echo "configured team on this host. Composable with --status/--daemon. Omit for"
            echo "the existing full-sweep behaviour (used by cron/LaunchAgent/--daemon)."
            exit 0
            ;;
        *)
            echo "WARNING: unrecognized argument '${1-}' ignored" >&2
            shift
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

# Derive lcars_port for each team from the team-paths registry at runtime via the
# shared kanban-hooks/lcars_ports.py helper (XACA-0561-008 — single source of the
# derivation logic, shared with lcars-smoke-test.sh).
# In this script, "canonical port" or "resolved port" means the team's registry port
# from ~/.aiteamforge/team-paths.json, NOT the DEFAULT_TEAMS template baseline.
# See docs/team-registry-guide.md § "LCARS Port Authority Model" (XACA-0803).
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
# The port returned is from the registry (team-paths.json), not DEFAULT_TEAMS fallback.
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
        echo "WARNING: no registry lcars_port for team '$_team' — skipping health-check entry" >&2
        continue
    fi
    LCARS_SERVERS+=("${_fp}:${_lp}:${_team}:${_sock}:${_pat}")
done

# XACA-0890-025 fix: single source of truth for --team matching, called by
# BOTH the eager validation below and the sweep filter in run_health_check
# (search _hc_team_filter_matches there) so the two can never drift out of
# sync with each other.
#
# THE BUG THIS FIXES: XACA-0890-013 originally required an EXACT string
# match between --team's value and an _LCARS_INFRA entry's team field. The
# parametric connect template passed --team ${INSTANCE} — a COMPOSITE id
# (${TEAM_ID}-${PROJECT}, or ${TEAM_ID}-${GROUP}-${PROJECT} for freelance)
# — but _LCARS_INFRA's team field is NOT consistently team-shaped: for
# flat teams and freelance it IS the bare team id (freelance's session
# PATTERN is a wildcard, ".*-lcars", precisely because it covers every
# freelance instance), but for finance/legal it is already a specific
# PROVISIONED INSTANCE id ("finance-personal", "legal-coparenting") that
# does not necessarily match whatever project the connecting template's
# own TEAM_DEFAULT_PROJECT happens to compute (verified: legal.conf's
# TEAM_DEFAULT_PROJECT="default" produces INSTANCE "legal-default", which
# never equals the registered "legal-coparenting" under exact matching --
# only finance's "personal" happened to match by coincidence). Combined
# with the XACA-0890-013 eager validation (correctly conservative), every
# non-matching parametric team degraded from "restart on failure" to "warn
# and never restart" -- strictly worse than before XACA-0890-013.
#
# THE FIX: the template now passes --team ${TEAM_ID} (the bare team id,
# ALWAYS known statically from the top of the template -- no derivation,
# no guessing at what project is actually provisioned). Matching here
# accepts that bare id against BOTH shapes of _LCARS_INFRA entry:
#   - EXACT match: $team == $filter (flat teams, freelance's bare entry).
#   - PREFIX match: $team starts with "$filter-" (composite entries like
#     finance-personal/legal-coparenting -- the bare team id is a prefix
#     of the one instance actually registered for it).
# Deliberately ONE DIRECTION only (filter is a prefix of team, never the
# reverse) -- an instance-shaped filter like "legal-default" must NOT
# match "legal-coparenting" by design; only a bare team id may.
_hc_team_filter_matches() {
    local team="$1" filter="$2"
    [[ "$team" == "$filter" ]] && return 0
    [[ "$team" == "${filter}-"* ]] && return 0
    return 1
}

# XACA-0890-013: validate --team eagerly. Without this, a typo'd or stale
# team name (e.g. a renamed team, or a caller passing the wrong INSTANCE
# value) silently sweeps ZERO servers and exits 0 — indistinguishable from
# "everything's healthy" in both --status and restart mode. Fail loudly
# instead: this is invoked automatically over SSH by the parametric
# *-connect.sh scripts, where a silent no-op would look like a successful
# health check that actually checked nothing.
#
# XACA-0890-025: also fails loudly on AMBIGUITY (--team matching MORE THAN
# ONE _LCARS_INFRA entry), never silently restarting an arbitrarily-picked
# one. Not reachable with today's static table (verified: no two entries
# share a team-id prefix), but the prefix-match rule above makes it
# reachable in principle if a second project were ever registered for the
# same personal team (e.g. a hypothetical "legal-custody" alongside
# "legal-coparenting") -- a silent pick in that case would risk restarting
# the WRONG team's server, which is worse than refusing to guess.
if [[ -n "$TEAM_FILTER" ]]; then
    _team_filter_matches=()
    for _e in "${LCARS_SERVERS[@]}"; do
        IFS=':' read -r _ _ _e_team _ _ <<< "$_e"
        if _hc_team_filter_matches "$_e_team" "$TEAM_FILTER"; then
            _team_filter_matches+=("$_e_team")
        fi
    done
    if [[ ${#_team_filter_matches[@]} -eq 0 ]]; then
        echo "ERROR: --team '$TEAM_FILTER' did not match any configured team in LCARS_SERVERS (checked ${#LCARS_SERVERS[@]} entries; a team missing its registry lcars_port is excluded — see the WARNING above, if any)." >&2
        exit 1
    elif [[ ${#_team_filter_matches[@]} -gt 1 ]]; then
        echo "ERROR: --team '$TEAM_FILTER' matched MULTIPLE configured teams (${_team_filter_matches[*]}) — ambiguous, refusing to guess which one to restart. Use a more specific --team value, or edit _LCARS_INFRA to disambiguate." >&2
        exit 1
    fi
    unset _team_filter_matches _e _e_team
fi

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
    # XACA-0889 mitigation: raised 3 -> 10. server.py's single-threaded
    # socketserver.TCPServer can block its one worker thread for up to 5s
    # servicing /api/usage/current?refresh=1 (subprocess.run(..., timeout=5)),
    # during which /api/status also cannot be answered on a perfectly healthy
    # server. A 3s --max-time was shorter than that worst-case block, so a
    # busy-not-dead server read as unhealthy and got killed (observed: iOS
    # 24x, Firebase 8x, Android 5x false restarts in one log cycle). 10s
    # comfortably exceeds the 5s worst case with margin for queuing. The real
    # fix (ThreadingHTTPServer) is a separate subitem; this mitigation must
    # stand on its own for consumers who haven't picked that up yet.
    local timeout=10

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
    # XACA-0889 mitigation: raised 3 -> 10, same rationale as
    # check_server_health() above (single-threaded server.py can legitimately
    # block up to 5s on /api/usage/current?refresh=1).
    local timeout=10

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
# XACA-0894-004: bounded wait for a port to actually release.
# ============================================================================
# SIGNATURE B (logs/lcars-server-android.log.old): "OSError: [Errno 48]
# Address already in use" — a new server was launched before the old one's
# socket was actually released. server.py sets allow_reuse_address=True
# (XACA-0889-018), which avoids the classic TIME_WAIT-stuck-socket EADDRINUSE,
# but does NOT help when the OLD process is simply still alive and still
# holding the listening socket (SIGTERM was sent but the process hasn't
# exited yet) — that is a real, measurable race, not a TIME_WAIT artifact.
#
# PROBE CHOICE — `nc -z`, NOT `lsof`, for the per-iteration check (measured,
# XACA-0894-004): this repo's other scripts (tests/test-lcars-server-*.sh,
# scripts/remote-*.sh) use `lsof -iTCP:<port> -sTCP:LISTEN` for one-shot
# checks, and that idiom was the obvious first choice here too. But measured
# directly on this dev machine, a single `lsof` call took 2.3s-6.8s wall
# clock (it scans every open file across every process; this machine runs
# many personas/tmux sessions/servers) — looping it `timeout` times would
# silently inflate a "10s bounded wait" to 30-80s+, which is precisely the
# unbounded-looking behavior this function exists to prevent. `nc -z`
# (zero-I/O connect probe, `-G1` caps its own connection attempt at 1s)
# answers the SAME yes/no "is anything accepting on this port" question in
# ~0.03-0.25s measured here. `lsof` is still used, once, for the "who holds
# it" diagnostic in the caller below — that is a single call, not a loop, so
# its cost is acceptable there and it is the only way to get a holder PID.
#
# BOUND — wall-clock elapsed time, not an iteration counter: counting loop
# iterations only bounds wall-clock time if every iteration has a known,
# fixed cost. It doesn't here (see above) — so the bound is enforced by
# comparing `date +%s` against the start time on every iteration instead.
# Never busy-loops forever; returns 1 (still held) once the elapsed budget is
# exhausted so the caller can fail loudly instead of hanging.
# ============================================================================
_hc_wait_for_port_release() {
    local port=$1
    local timeout=${2:-10}
    local _start _now
    _start=$(date +%s)
    while true; do
        if ! nc -z -G1 127.0.0.1 "${port}" 2>/dev/null; then
            return 0  # nothing accepting connections on the port -> released
        fi
        _now=$(date +%s)
        if (( _now - _start >= timeout )); then
            return 1  # bounded wall-clock budget exhausted, still held
        fi
        sleep 1
    done
}

# ============================================================================
# Start LCARS server for a team (health-check restart path)
# ============================================================================
# XACA-0763 (004): this is now a THIN WRAPPER delegating to
# scripts/lcars-launch-helpers.sh::start_lcars_server instead of a hand-copied
# duplicate of its launch form. The two had drifted (this function's own
# header used to say "keep in sync with lcars-launch-helpers.sh::start_lcars_server",
# which is itself a k501 sibling-drift smell — see memory
# k501-sibling-heuristic-drift-pattern.md), and the drift was load-bearing:
#
#   - start_lcars_server runs its pkill UNDER a per-port `mkdir` advisory lock
#     (XACA-0661) with an ANCHORED port-boundary pattern, and short-circuits
#     when a healthy server is already answering on the port.
#   - This function's old pkill was a bare, UNLOCKED, UNANCHORED
#     `pkill -f "server.py.*$local_port"` with no short-circuit.
#
#   So the health-check loop could SIGTERM a server that a concurrent
#   `aiteamforge restart lcars` had launched moments earlier, and vice versa
#   (the "supervisor race" half of XACA-0763). Delegating inherits the lock,
#   the anchored pkill, the short-circuit, the XACA-0763-003 setsid(2) detach,
#   the XACA-0626 port-drift guard, and the XACA-0713 python-version warning —
#   all defined in exactly one place.
#
# Signature note: argument ORDER differs from start_lcars_server's
# (team, port, session_name) — this function keeps its historical
# (local_port, team, session_name) order for its own callers
# (_hc_heal_noncanonical_port, run_health_check), so the delegating call below
# transposes the first two arguments deliberately.
#
# lcars-target.js write suppression (trap avoided): start_lcars_server writes
# lcars-target.js (the router-redirect file) unconditionally when called
# directly, because its direct callers are the user opening/refreshing exactly
# that team's LCARS tab. This function's caller (run_health_check) instead
# restarts EVERY configured team in one sweep — naive delegation would rewrite
# lcars-target.js up to 9 times per cycle, last-team-wins, silently
# retargeting the user's LCARS cockpit to whichever team happened to be
# restarted last. We suppress that write here via LCARS_SKIP_TARGET_WRITE=1,
# a `local` (dynamically-scoped, so start_lcars_server sees it during this
# call only) — see the flag's definition in lcars-launch-helpers.sh for the
# full rationale.
#
# Log location (trap avoided, decided deliberately): start_lcars_server logs
# to the canonical ${AITEAMFORGE_DIR:-~/dev-team}/logs/lcars-server-<team>.log
# (log-rotation included) instead of this function's old ad hoc
# /tmp/lcars-<team>-<port>.log. Converging on ONE log location is desirable —
# it's the same file whichever launch site (dev startup script or health
# check) started the server, so there is exactly one place to look. BUT:
# /tmp/lcars-<team>-<port>.log is not merely a log — it is a load-bearing
# DETECTION SENTINEL. scripts/lcars-restart-helpers.sh::detect_active_lcars_team
# (used by the post-merge auto-restart hook) globs /tmp/lcars-*-*.log as its
# tier-2 "which team is currently running" signal (existence + mtime + a live
# process on that port — content is never read). Silently dropping that write
# would have broken that hook's detection for any server that was last
# (re)started via the health-check path. We therefore still touch a pointer
# stub at the legacy /tmp path after delegating, preserving the sentinel
# without duplicating real log content.
#
# Poll window (trap avoided, decided deliberately): start_lcars_server polls
# for up to 15s (30 x 0.5s); this function's own poll used to be 10s (10 x
# 1s). Converging on 15s (by simply propagating start_lcars_server's return
# code instead of re-polling here) is a strict improvement — a healthy but
# slightly slow boot now has 5 more seconds to answer before the health check
# gives up and logs a false failure.
#
# LaunchAgent compatibility: sources lcars-launch-helpers.sh once via the
# same _SCRIPT_DIR already used above to locate lcars_ports.py. Sourcing only
# defines functions (no side-effects); safe under launchd's minimal env. If
# sourcing fails or start_lcars_server is unavailable for any reason, this
# degrades to a loud failure rather than silently doing nothing (graceful
# degradation, not silent breakage).
#
# Called by: run_health_check (normal unhealthy-team restart) AND
# _hc_heal_noncanonical_port (XACA-0706 non-canonical-port self-heal).
#
# XACA-0983: gained a 4th (optional) arg, tmux_socket. Both existing callers
# already had a tmux_socket value in lexical scope (heal path: its own $4;
# restart path: the outer run_health_check loop variable) and were updated to
# pass it, so this is not a break for either — but it IS a real arity/behavior
# change: before starting the server, this function now also ensures the
# `<team>-lcars` tmux session exists (see ensure_lcars_tmux_session in
# lcars-launch-helpers.sh). The heal path kills that session as part of its
# repair with nothing to recreate it, leaving a healthy server with no tmux
# session — no Fleet Monitor LCARS tab, and the operator's attached LCARS
# terminal tab dies with the session. If tmux_socket is omitted, session
# recreation is skipped (loud log, not a silent no-op) and the rest of this
# function's original contract (args, return 0/1, log() messages) is
# unchanged.
_hc_start_lcars_server() {
    local local_port=$1
    local team=$2
    local session_name=$3
    local tmux_socket=$4

    log "  Starting LCARS server: team=$team port=$local_port session=$session_name"

    # Source the shared helpers to get start_lcars_server (XACA-0763-004;
    # previously only resolve_lcars_python was needed here — XACA-0614).
    # _SCRIPT_DIR is already set at the top of this file.
    local _helpers="${_SCRIPT_DIR}/scripts/lcars-launch-helpers.sh"
    if [[ -f "$_helpers" ]]; then
        # shellcheck disable=SC1090
        source "$_helpers" 2>/dev/null || true
    fi

    if ! typeset -f start_lcars_server >/dev/null 2>&1; then
        log "  ❌ start_lcars_server is not available (failed to source ${_helpers}) — cannot start server on port $local_port"
        return 1
    fi

    # XACA-0763 (004): suppress the lcars-target.js router-redirect write for
    # this health-check-triggered restart — see header comment above for why.
    local LCARS_SKIP_TARGET_WRITE=1

    # XACA-0983: recreate the `<team>-lcars` tmux session BEFORE starting the
    # server — mirrors canonical startup ordering (session first, server
    # second: academy-lcars-startup.sh:29 then academy-startup.sh:203) so the
    # session is present the instant the server answers. start_lcars_server
    # itself never touches tmux (bare nohup spawn); this is what closes the
    # kill-with-no-recreate gap in _hc_heal_noncanonical_port (see that
    # function's header comment). Soft-fail: a missing tmux_socket or a
    # failed create only logs — it never blocks the server start below,
    # matching this function's existing soft-fail contract.
    if [[ -n "$tmux_socket" ]]; then
        if typeset -f ensure_lcars_tmux_session >/dev/null 2>&1; then
            if ! ensure_lcars_tmux_session "$session_name" "$tmux_socket"; then
                log "  ⚠️  ensure_lcars_tmux_session failed for $session_name (socket $tmux_socket) — continuing without a tmux session"
            fi
        else
            log "  ⚠️  ensure_lcars_tmux_session is not available (failed to source ${_helpers}) — tmux session will not be recreated"
        fi
    else
        log "  ⚠️  no tmux_socket passed to _hc_start_lcars_server — skipping tmux session recreation for $session_name"
    fi

    # NOTE argument order: start_lcars_server takes (team, port, session_name),
    # this function's own params are (local_port, team, session_name) — do not
    # transpose.
    start_lcars_server "$team" "$local_port" "$session_name"
    local _rc=$?

    # XACA-0894-004: bounded EADDRINUSE recovery (Signature B).
    #
    # start_lcars_server's own pkill (XACA-0661-007, under its per-port mkdir
    # lock) sends SIGTERM to any stale holder on this port, but does NOT wait
    # to confirm the socket was actually released before binding the new
    # server — if the old process is slow to die (or was itself hung), the
    # new bind can lose that race. logs/lcars-server-android.log.old is a
    # confirmed instance: "OSError: [Errno 48] Address already in use".
    #
    # We detect this from a MEASURED fact — the literal EADDRINUSE signature
    # in the server's own stderr log — never a guess, and never duplicate
    # start_lcars_server's own pkill/lock here (a second, unlocked pkill in
    # this wrapper is exactly the drifted-duplicate antipattern XACA-0763-004
    # already removed once; see this file's header comment above
    # _hc_start_lcars_server). If the signature is present, we wait (bounded,
    # via _hc_wait_for_port_release) for the port to actually clear, then
    # retry the SAME locked/anchored start_lcars_server call exactly once.
    #
    # This addresses Signature B only. It does NOT address Signature A's
    # "before becoming ready" SIGTERM/status-143 death by itself — that death
    # happens before the server ever answers, and its cause (concurrent
    # userspace re-entrancy vs. a launchd process-group reap of the whole job
    # — the latter is what subitem 001/002's AbandonProcessGroup fix targets)
    # is not something a userspace retry can distinguish or repair. All this
    # retry can do for a Signature-A-shaped failure is attempt again; it will
    # only actually help if the underlying cause was transient.
    if [[ $_rc -ne 0 ]]; then
        local _server_log_path="${AITEAMFORGE_DIR:-$HOME/dev-team}/logs/lcars-server-${team}.log"
        if [[ -f "$_server_log_path" ]] && grep -q "Address already in use\|\[Errno 48\]" "$_server_log_path" 2>/dev/null; then
            # `lsof` gives us the holder PID for the log (nc can't — it only
            # answers yes/no), but measured on this machine a single lsof
            # call can itself take 2-7s under load (it scans every open file
            # across every process). Query it ONCE here and reuse the value
            # in both log lines below rather than re-querying after the wait
            # — a second lsof call on the give-up path would silently add
            # several more seconds on top of the already-bounded wait, which
            # is exactly the kind of hidden-latency drift this whole
            # subitem exists to eliminate. The holder is not expected to
            # change identity mid-wait (nothing else in this path signals
            # it to), so the pre-wait reading remains accurate context for
            # the give-up message too.
            local _holder
            _holder="$(lsof -ti tcp:"${local_port}" -sTCP:LISTEN 2>/dev/null | tr '\n' ' ')"
            log "  [measured] EADDRINUSE signature found in ${_server_log_path} — port ${local_port} currently held by pid(s)=[${_holder:-none}]"
            if _hc_wait_for_port_release "$local_port" 10; then
                log "  [measured] port ${local_port} released — retrying start once"
                start_lcars_server "$team" "$local_port" "$session_name"
                _rc=$?
            else
                log "  [measured] port ${local_port} still held after 10s bounded wait (holder pid(s) at detection time=[${_holder:-none}]) — not retrying further"
            fi
        fi
    fi

    # XACA-0763 (004): preserve the /tmp/lcars-<team>-<port>.log DETECTION
    # SENTINEL that scripts/lcars-restart-helpers.sh::detect_active_lcars_team
    # depends on (tier 2: existence + mtime + a live process on that port —
    # content is never read by that detector). start_lcars_server itself logs
    # to the canonical ${AITEAMFORGE_DIR}/logs/lcars-server-<team>.log now, so
    # write a one-line pointer stub here instead of duplicating real content.
    # Written unconditionally (best-effort) to match the old behavior, where
    # the /tmp file was created immediately on launch regardless of whether
    # the server subsequently passed its health poll.
    local _hc_sentinel="/tmp/lcars-${team}-${local_port}.log"
    echo "# XACA-0763: full log at ${AITEAMFORGE_DIR:-$HOME/dev-team}/logs/lcars-server-${team}.log" \
        > "${_hc_sentinel}" 2>/dev/null || true

    if [[ $_rc -eq 0 ]]; then
        log "  Server started successfully on port $local_port"
    else
        log "  FAILED to start server on port $local_port"
    fi
    return $_rc
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
# Surgically heal a team whose live LCARS server is bound to the wrong port:
# kill ONLY that team's <instance>-lcars tmux session and the stale server.py
# on the wrong port(s), then recreate on the registry (resolved) port.
# ============================================================================
# XACA-0706: This NEVER re-runs <team>-startup.sh — live agent tmux panes and
# sessions in that team must be untouched. We only kill the one <instance>-lcars
# session and the wrong-port server.py, then call _hc_start_lcars_server (which
# already mirrors start_lcars_server's HUP-immune nohup+disown launch form).
#
# "canonical port" in this function means the team's RESOLVED port from the
# registry (~/.aiteamforge/team-paths.json), NOT the template baseline.
_hc_heal_noncanonical_port() {
    local canonical_port=$1  # resolved port from registry
    local team=$2
    local session_name=$3
    local tmux_socket=$4
    local wrong_ports=$5  # space-separated list of bound ports != resolved port

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

    # 3. Recreate on the CANONICAL port via the shared restart path. Pass
    #    tmux_socket (our own $4) so _hc_start_lcars_server can recreate the
    #    session we just killed above, on the same tmux server (XACA-0983).
    _hc_start_lcars_server "$canonical_port" "$team" "$session_name" "$tmux_socket"
    return $?
}

# ============================================================================
# Require 2 consecutive failed health probes before a team is treated as
# unhealthy (XACA-0889 mitigation, second half — first half is the 3->10
# timeout raise on check_server_health/check_remote_server_health above).
# ============================================================================
# DESIGN DECISION (in-run retry, not cross-invocation persisted state):
#
# Two ways to require "2 consecutive failures" were considered:
#   1. In-run retry: on a failed probe, back off briefly and re-probe once
#      more within THIS SAME invocation before declaring unhealthy.
#   2. Cross-run persisted state: a per-team failure counter on disk that
#      survives between separate invocations (cron ticks / daemon loop
#      iterations / LaunchAgent runs), incremented on failure and reset on
#      success, restarting only once the counter reaches 2.
#
# Chose (1), in-run retry. Reasoning:
#   - The root cause is a request that blocks server.py's single worker
#     thread for AT MOST ~5s (subprocess.run(..., timeout=5)). A second
#     probe a few seconds later, still inside the same invocation, is on the
#     same timescale as the stall itself and reliably distinguishes
#     "busy" from "actually dead." Persisted state would instead wait for a
#     second separate invocation to confirm — with this script installable
#     either as a 5-minute cron job or a 60s daemon loop (both supported,
#     see file header / DAEMON_INTERVAL), that means anywhere from 60s to a
#     full 5 minutes of extra confirmation latency for a GENUINELY dead
#     server, which is a real regression in outage-detection time that a
#     few seconds of in-run backoff does not cause.
#   - No stale-state failure mode. This codebase has an existing problem
#     class of leftover per-team state/lock files needing their own sweeper
#     (see _sweep_stale_locks in lcars-ui/server.py) — a persisted
#     failure-counter file would be exactly that class again (needs reset-
#     on-success, needs to tolerate a missing/corrupt file, needs to not
#     accumulate forever across team churn). In-run retry needs none of
#     that: nothing written to disk, nothing to go stale, nothing to sweep.
#   - This script is invoked in three different modes (manual, cron,
#     --daemon) and manual/status-only runs would pollute or reset a
#     persisted counter in ways that don't reflect the daemon's own view of
#     "consecutive," making a shared on-disk counter an awkward fit anyway.
#
# HEALTH_CHECK_RETRY_DELAY (default 3s, env-overridable) is the backoff
# between the two probes. --status mode still never restarts anything —
# this wrapper only changes what counts as "unhealthy," the STATUS_ONLY gate
# around the actual restart call in run_health_check is untouched.
# ============================================================================
_hc_check_health_with_retry() {
    local local_port=$1
    local team=$2
    local remote_host=$3

    if [[ -n "$remote_host" ]]; then
        if check_remote_server_health "$remote_host" "$local_port"; then
            return 0
        fi
        log "  ⚠️  $team:$local_port - first health probe failed (remote: $remote_host); waiting ${HEALTH_CHECK_RETRY_DELAY}s to confirm before declaring unhealthy"
        sleep "$HEALTH_CHECK_RETRY_DELAY"
        check_remote_server_health "$remote_host" "$local_port"
        return $?
    else
        if check_server_health "$local_port"; then
            return 0
        fi
        log "  ⚠️  $team:$local_port - first health probe failed; waiting ${HEALTH_CHECK_RETRY_DELAY}s to confirm before declaring unhealthy"
        sleep "$HEALTH_CHECK_RETRY_DELAY"
        check_server_health "$local_port"
        return $?
    fi
}

# ============================================================================
# XACA-0894-004: whole-invocation single-instance lock.
# ============================================================================
# WHAT THIS DOES AND DOES NOT ADDRESS: the actual per-team restart (pkill +
# relaunch) is already serialized per-PORT inside start_lcars_server via its
# own mkdir lock (XACA-0661-007), and that lock is shared by every caller
# (this script's delegation AND team-startup.sh's direct calls), so a manual
# startup racing a health-check restart of the SAME team was already fixed by
# that prior work (XACA-0763-004 delegation). This lock is a DIFFERENT,
# coarser layer on top: it prevents two *invocations of this whole script*
# (e.g. a launchd StartInterval firing again before the previous run
# finished, or a manual/cron run overlapping a --daemon loop) from both
# executing run_health_check's team-by-team sweep at the same time. Two such
# sweeps racing each other would duplicate every per-team health probe and
# restart decision, adding load and log noise even though the per-port lock
# would still keep any individual restart itself safe.
#
# WHAT THIS DELIBERATELY DOES NOT CLAIM TO FIX: analysis of the available
# /tmp/lcars-health.log / .log.1 / .log.2 history found exactly two
# Signature-A ("exited ... before becoming ready", status 143) events in the
# retained history — android on 2026-08-04 08:33:43 and ios on 2026-08-05
# 09:27:56 — a full day apart, each the only unhealthy team in its own
# health-check run. No coincident same-run, different-team burst is visible
# in that data. A whole-run lock like this one cannot make two DIFFERENT
# teams' restarts (which already run sequentially within one invocation's
# `for` loop, never concurrently with each other) fail together — if the
# 143 death is caused by something process-group-wide (the AbandonProcessGroup
# hypothesis subitem 001/002 are testing), this lock does not touch that
# mechanism at all. It only closes the whole-script re-entrancy window.
#
# STALE-LOCK POLICY mirrors the proven pattern already in
# scripts/lcars-launch-helpers.sh::start_lcars_server (liveness check via
# `kill -0`, then an age fallback) rather than inventing a new one — see that
# function's header for the fuller rationale of why mkdir + these two tests.
# On failure to acquire (another live, recent run holds it), we SKIP this
# entire invocation rather than block: launchd re-fires every
# ${DAEMON_INTERVAL:-120}s regardless, so a skipped cycle costs at most one
# more interval of detection latency, which is far cheaper than two sweeps
# racing each other or a busy-wait piling up.
# ============================================================================
_HC_RUN_LOCK_DIR="/tmp/lcars-healthcheck-run-lock"

# XACA-0894-004 (Review #1): OWNERSHIP-AWARE release. The old body was a bare
# `rm -rf "${_HC_RUN_LOCK_DIR}"` — safe everywhere it used to be called (only
# on run_health_check's own fall-through path, always AFTER a successful
# _hc_acquire_run_lock, so ownership was implied by control flow). run_daemon's
# INT/TERM trap now also calls this (see below) to close a wedge-free-but-slow
# gap: the trap can fire asynchronously WHILE run_health_check is mid-sweep,
# i.e. between a successful acquire and its own release call, in which case
# skipping cleanup would leave the lock held until the 600s age fallback. But
# a bare rm -rf in the trap would be unsafe in general — the trap fires in
# EVERY invocation's process, including ones that never held the lock (skipped
# because another run was live) or already released it, and blindly removing
# the dir in those cases could delete a DIFFERENT invocation's live lock out
# from under it. So this checks the pid file against our own $$ before
# touching anything: only the process whose pid is actually recorded as
# holder may remove the dir.
#
# Death-at-each-step: if THIS process dies between the `cat` read and the
# `rm -rf`, at most a lock dir with our own (now-dead) pid in its pid file is
# left behind — indistinguishable from any other stale-holder case, self-heals
# via the existing kill -0 / 600s-age reclaim path in _hc_acquire_run_lock. No
# new wedge is possible: this function only ever deletes a dir it has just
# confirmed, by pid match, that it itself is the current holder of.
_hc_run_lock_release() {
    local _held_pid
    _held_pid="$(cat "${_HC_RUN_LOCK_DIR}/pid" 2>/dev/null || true)"
    if [[ -n "${_held_pid}" && "${_held_pid}" == "$$" ]]; then
        rm -rf "${_HC_RUN_LOCK_DIR}" 2>/dev/null || true
    fi
    # else: not our lock (never acquired it, already released it, or a
    # different invocation now legitimately holds it) — leave it alone.
}

# XACA-0894-004 (Review #2): opportunistic, age-bounded sweep of orphaned
# "<lock>.stale.<pid>" directories left behind by _hc_acquire_run_lock's
# atomic-mv reclaim (see that function's header for why the reclaim uses a
# uniquely-named intermediate). The reclaim winner normally removes its own
# "${_HC_RUN_LOCK_DIR}.stale.$$" immediately after the mv; a crash in that
# narrow window (after the mv, before the rm -rf) leaks the directory
# permanently — nothing ever revisits it otherwise, so these accumulate in
# /tmp without bound over the life of the machine.
#
# VERIFIED (not assumed) what a pid-reuse collision actually does on this
# platform's `mv` (BSD /bin/mv, no GNU -T/--no-target-directory): when the
# destination name "${_HC_RUN_LOCK_DIR}.stale.$$" already exists as a
# directory (an old orphan under a reused $$), plain `mv src dst` does NOT
# fail with ENOTEMPTY — it moves src INSIDE dst as dst/$(basename src), which
# succeeds, and the reclaim's own following `rm -rf "${_claim}"` then deletes
# that whole nested tree (old orphan contents included). This is safe, not a
# defect: a pid can only be reused after the OS has confirmed the previous
# holder of that pid is dead (pids are never shared between two live
# processes), so an orphan sitting at exactly our own "$$" name can never
# belong to a still-running concurrent reclaim — absorbing and discarding it
# is exactly correct. (A hand-rolled `mv -T`/`rename()` equivalent — which
# WOULD ENOTEMPTY-fail here — is deliberately not used; the existing "move
# into" form is what makes same-pid collisions self-heal for free instead of
# needlessly skipping a cycle, so the earlier draft plan to add ENOTEMPTY
# handling in the reclaim path is unnecessary here and was dropped.)
#
# So this sweep's job is pure hygiene, not correctness-for-the-reclaim: bound
# how long a truly-abandoned "<lock>.stale.<dead-pid>" directory can persist
# in /tmp, independent of whether a pid-reuse event ever happens to trigger
# the self-heal above. Without it, a crash-during-reclaim leaves a permanent,
# unbounded leak.
#
# SAFETY — must never remove a dir a CONCURRENT reclaim is actively using:
# that window is a single `mv` immediately followed by a single `rm -rf` —
# sub-millisecond in practice, no sleeps, no I/O other than one recursive
# delete of a directory containing at most a "pid" file. AGE_SECONDS below
# (60s) is >100x that real window, so anything old enough to sweep cannot be
# a live in-flight reclaim.
#
# BOUND — must not wedge or slow the common (uncontended) path: this is a
# single in-process glob (readdir, not a forked `find`) plus, for each match,
# one stat + conditional rm -rf. The common case (zero stale.* dirs) costs one
# empty glob. To keep the WORST case (many accumulated orphans, e.g. after a
# long outage this script wasn't invoked to sweep) bounded too, at most
# MAX_SWEEP dirs are removed per call — any remainder ages further and is
# swept on a later invocation, so this never has to do unbounded work in one
# pass.
#
# Death-at-each-step: dies mid-loop -> some already-processed orphans are
# gone, the rest untouched; every removal target is a uniquely pid-named
# orphan this call itself decided (by age) is abandoned, never the live
# ${_HC_RUN_LOCK_DIR} itself (that name never matches the .stale.* glob) and
# never a dir younger than AGE_SECONDS. No new wedge possible.
_hc_sweep_stale_lock_orphans() {
    local -a _stale_dirs
    local _d _mtime _now _age
    local _AGE_SECONDS=60
    local _MAX_SWEEP=25

    _stale_dirs=( "${_HC_RUN_LOCK_DIR}".stale.*(N) )
    (( ${#_stale_dirs[@]} == 0 )) && return 0

    _now="$(date +%s)"
    local _n=0
    for _d in "${_stale_dirs[@]}"; do
        (( _n >= _MAX_SWEEP )) && break
        [[ -d "$_d" ]] || continue
        _mtime="$(stat -c %Y "$_d" 2>/dev/null || stat -f %m "$_d" 2>/dev/null || echo "$_now")"
        _age=$(( _now - _mtime ))
        if (( _age > _AGE_SECONDS )); then
            rm -rf "$_d" 2>/dev/null || true
            ((_n++))
        fi
    done
    return 0
}

# Returns 0 if the lock is held by us (caller should proceed and MUST call
# _hc_run_lock_release before every return path), 1 if another live run holds
# it and this invocation should skip its sweep entirely.
#
# XACA-0894-004: STALE-RECLAIM ATOMICITY. The original implementation decided
# staleness, then did `rm -rf` followed by a SEPARATE `mkdir`. Two invocations
# racing against the same dead/aged-out lock could BOTH pass the staleness
# check, BOTH rm -rf, and BOTH mkdir successfully — each believing it alone
# holds the lock (reproduced 10/10 with a scripted two-process race). The fix
# below makes the reclaim decision hinge on a single atomic `mv` (rename(2),
# atomic on one filesystem — /tmp here) instead of the delete-then-create
# pair: a racer that judges the lock stale attempts to rename the stale dir
# to a name unique to its own pid. Exactly one racer's `mv` can succeed —
# rename(2) requires the source to exist, so the loser's `mv` fails with
# ENOENT because the winner already moved the source out from under it. No
# mutex is held across a window (nothing is held OVER the mv at all — it's a
# single atomic syscall), so there is no step whose failure produces a
# permanent wedge; see the death-at-each-step analysis in the XACA-0894-004
# plan doc / retro. Deliberately NOT using a second mkdir-based reclaim mutex
# guarding the rm+mkdir pair: if the mutex-holder died before releasing it,
# that mutex would itself be permanently orphaned and unreclaimable — trading
# an intermittent under-protection bug for a total, permanent outage of the
# health checker. Rejected for that reason.
_hc_acquire_run_lock() {
    # XACA-0894-004 (Review #2): sweep age-bounded orphaned .stale.<pid> dirs
    # opportunistically on every acquire attempt, BEFORE the fast-path mkdir.
    # Cheap on the common (no-orphans) path (see function header). This is
    # pure hygiene (bounds /tmp accumulation) — it is not required for
    # correctness of the reclaim below, which already self-heals a same-pid
    # collision safely on its own (see the sweep function's header for the
    # verified `mv` behavior and why that's safe).
    _hc_sweep_stale_lock_orphans

    if mkdir "${_HC_RUN_LOCK_DIR}" 2>/dev/null; then
        echo "$$" > "${_HC_RUN_LOCK_DIR}/pid" 2>/dev/null || true
        return 0
    fi

    local _holder_pid _mtime _now _age _stale=false _reason=""
    _holder_pid="$(cat "${_HC_RUN_LOCK_DIR}/pid" 2>/dev/null || true)"

    # Test 1: holder liveness — kill -0 fails → process is dead → stale lock.
    if [[ -n "${_holder_pid}" ]] && ! kill -0 "${_holder_pid}" 2>/dev/null; then
        _stale=true
        _reason="stale (holder pid ${_holder_pid} is dead)"
    else
        # Test 2: age guard. A single sweep restarting several unhealthy teams
        # can legitimately take a few minutes (per-team: up to ~20s lock-wait
        # + ~15s poll + ~10s EADDRINUSE bounded wait + ~15s retry poll); 600s
        # is generous headroom above that worst case for a holder that is
        # still genuinely working, while still reclaiming from a truly stuck
        # process rather than wedging forever.
        # Portable mtime: GNU `stat -c %Y` first, BSD `stat -f %m` fallback —
        # BSD `-f` does not error on Linux (means "filesystem" there), so
        # GNU-first is required for the `|| echo 0` fallback to ever fire.
        _mtime="$(stat -c %Y "${_HC_RUN_LOCK_DIR}" 2>/dev/null || stat -f %m "${_HC_RUN_LOCK_DIR}" 2>/dev/null || echo 0)"
        _now="$(date +%s)"
        _age=$(( _now - _mtime ))
        if (( _age > 600 )); then
            _stale=true
            _reason="${_age}s old (holder pid ${_holder_pid:-?} may be stuck)"
        fi
    fi

    if [[ "${_stale}" != "true" ]]; then
        log "  ⏭  another health-check run (pid ${_holder_pid:-?}) is in progress — skipping this cycle to avoid an overlapping sweep"
        return 1
    fi

    log "  ⚠️  run-lock: ${_reason} — attempting atomic reclaim"

    # Atomic winner-take-all: rename the stale dir to a name unique to our
    # own pid. At most one racing invocation's rename can succeed (see header
    # comment). A failure here means (a) another racer's mv beat ours, or (b)
    # the original holder finished and released the lock normally (rm -rf,
    # not rename) in the window between our staleness check and this mv —
    # indistinguishable from here, and both equally safe to treat the same
    # way: back off. Skipping one cycle is cheap; launchd re-fires on its own
    # interval regardless.
    #
    # NOTE on same-pid orphans: if ${_claim} already exists as a leftover
    # directory (an earlier invocation reused this exact pid and crashed
    # between its own mv and its own rm -rf), this `mv` does NOT fail on this
    # platform's `mv` (verified — see _hc_sweep_stale_lock_orphans's header) —
    # it succeeds by moving ${_HC_RUN_LOCK_DIR} INSIDE the existing ${_claim}
    # directory, and the `rm -rf "${_claim}"` a few lines below then discards
    # the whole nested tree, old orphan included. That is safe by
    # construction (a reused pid can only belong to a process the OS has
    # already confirmed is dead), so this `if` branch is never reached by a
    # same-pid collision — only by a genuinely different racer or a
    # concurrently-releasing original holder.
    local _claim="${_HC_RUN_LOCK_DIR}.stale.$$"
    if ! mv "${_HC_RUN_LOCK_DIR}" "${_claim}" 2>/dev/null; then
        log "  ⏭  run-lock: lost the reclaim race (or holder released concurrently) — skipping this cycle"
        return 1
    fi
    # Only the mv winner reaches here, and only the winner ever refers to
    # ${_claim} (the name is unique to our own $$) — safe to remove without
    # racing anyone else.
    rm -rf "${_claim}" 2>/dev/null || true

    if mkdir "${_HC_RUN_LOCK_DIR}" 2>/dev/null; then
        echo "$$" > "${_HC_RUN_LOCK_DIR}/pid" 2>/dev/null || true
        return 0
    fi
    # A brand-new invocation's ordinary top-level mkdir landed in the gap we
    # opened by moving the stale dir away, and it now holds a legitimate
    # fresh lock. Yield to it — proceeding unlocked here would recreate
    # exactly the double-proceed defect this fix exists to close, now that we
    # have a positive signal (failed mkdir) that a live holder exists.
    log "  ⏭  run-lock: another invocation acquired a fresh lock during our reclaim — skipping this cycle"
    return 1
}

# ============================================================================
# Main health check routine
# ============================================================================
run_health_check() {
    # Rotate log if it's getting too large
    rotate_log_if_needed

    if ! _hc_acquire_run_lock; then
        return 0  # another live invocation is already sweeping; not an error
    fi

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
    # bound port by team, so the loop can catch a server bound to the wrong port
    # (the XACA-0613 refresh-gap) before the registry-port health check masks it.
    detect_lcars_bound_ports

    for server_config in "${LCARS_SERVERS[@]}"; do
        # Parse config
        IFS=':' read -r funnel_port local_port team tmux_socket session_pattern <<< "$server_config"

        # XACA-0890-013: --team scopes the sweep to a single team. This is an
        # opt-in filter (TEAM_FILTER empty by default) so the daemon/cron/
        # LaunchAgent path — which is SUPPOSED to check everything — is
        # completely unaffected; only an explicit `--team <name>` invocation
        # (used by the parametric *-connect.sh scripts' remote health check)
        # narrows the loop. Fixes the real defect behind the ~191s worst-case
        # connect-script latency: a connect attempt for team X was triggering
        # a full-fleet sweep of every OTHER team on the host, not just X.
        # XACA-0890-025: uses the SAME _hc_team_filter_matches the eager
        # validation above already used to decide TEAM_FILTER was valid —
        # see that function's comment for why this is a prefix match, not
        # an exact one.
        if [[ -n "$TEAM_FILTER" ]] && ! _hc_team_filter_matches "$team" "$TEAM_FILTER"; then
            continue
        fi

        # The <instance>-lcars session name = pattern minus the ".*" glob
        # (freelance uses ".*-lcars"). Used for both surgical heal and the
        # normal restart path below.
        local canonical_session="${session_pattern/\.\*/}"

        # XACA-0706: PORT DRIFT DETECTION.
        # Compare the team's actual bound port(s) against its resolved port
        # (from the registry). A live server.py for this team bound to a port
        # != $local_port is the XACA-0613 stuck-on-stale-port case. We detect
        # it BEFORE the registry-port health check because the correct port is
        # usually dead in that state (the server is serving the wrong port) —
        # and even if both are up, a server on the wrong port is still wrong
        # and must be reconciled.
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

        # First, check if the server is responding. XACA-0889: this now
        # requires 2 CONSECUTIVE failed probes (see
        # _hc_check_health_with_retry's design-decision comment above) before
        # falling through to the unhealthy/restart path below — a lone failed
        # probe against a server.py that's merely busy for up to ~5s no
        # longer triggers a restart.
        if _hc_check_health_with_retry "$local_port" "$team" "$remote_host"; then
            if [[ -n "$remote_host" ]]; then
                log "✅ $team:$local_port - healthy (remote: $remote_host)"
            else
                log "✅ $team:$local_port - healthy"
            fi
            ((healthy++))
            continue
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
            # Pass tmux_socket (the loop variable above) so a team whose
            # session is already gone — reboot, crash, or a prior run of
            # this very bug — gets it recreated here too (XACA-0983).
            _hc_start_lcars_server "$local_port" "$team" "$canonical_session" "$tmux_socket"
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
    # the wrong port (XACA-0706 — surfaces the drift to callers/monitors).
    if [[ "$STATUS_ONLY" == "true" && ( $unhealthy -gt 0 || $drifted -gt 0 ) ]]; then
        _hc_run_lock_release
        return 1
    fi
    _hc_run_lock_release
    return 0
}

# ============================================================================
# Daemon mode - run periodic checks
# ============================================================================
run_daemon() {
    log "Starting LCARS health daemon (checking every ${DAEMON_INTERVAL}s)"
    log "Press Ctrl+C to stop"

    # XACA-0894-004 (Review #1): release the run lock deterministically on
    # daemon shutdown instead of relying solely on the 600s staleness
    # backstop. _hc_run_lock_release is ownership-aware (checks the pid file
    # against $$ before removing anything — see its header comment), so this
    # is safe to call unconditionally even when this trap fires in an
    # invocation that never acquired the lock, already released it, or whose
    # acquire attempt is not the one currently holding it: in every such case
    # it is a safe no-op. It IS a real fix in the one case that matters: the
    # signal arriving while run_health_check is mid-sweep (between a
    # successful _hc_acquire_run_lock and its own release call at the end),
    # which the exit here would otherwise bypass.
    trap 'log "Daemon stopped"; _hc_run_lock_release; exit 0' INT TERM

    while true; do
        run_health_check
        sleep $DAEMON_INTERVAL
    done
}

# ============================================================================
# Main
# ============================================================================
# XACA-0889-017: sourced-vs-executed guard. Without this, `source
# lcars-health-check.sh` (the only way a test harness — or any future caller
# — can reuse _hc_check_health_with_retry/check_server_health/etc. as
# functions) unconditionally fired a real run_health_check sweep as a side
# effect of sourcing, including restarts when STATUS_ONLY is false. Verified:
# sourcing this file before this guard wrote a live entry to
# /tmp/lcars-health.log and printed the full health-check banner.
#
# $zsh_eval_context is zsh's stack of the contexts the currently-running code
# is nested under; its LAST element is "toplevel" only when THIS file is the
# outermost script being run (`./lcars-health-check.sh` or
# `zsh lcars-health-check.sh`), and "file" when it was reached via
# `source`/`.` from another script or an interactive shell. Functions/vars
# defined above this guard are still fully usable after sourcing — only the
# auto-run at the bottom is suppressed.
if [[ "${zsh_eval_context[-1]}" == "toplevel" ]]; then
    if [[ "$DAEMON_MODE" == "true" ]]; then
        run_daemon
    else
        run_health_check
    fi
fi
