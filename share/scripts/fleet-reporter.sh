#!/usr/bin/env bash

#
#  fleet-reporter.sh
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

# Fleet Status Reporter
# Collects tmux session data and reports to central monitoring server
# Run via cron every 60 seconds: * * * * * ~/dev-team/fleet-monitor/client/fleet-reporter.sh

# Ensure PATH includes common locations (cron has minimal PATH)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

# Configuration file locations
# Primary: written by install-fleet-monitor.sh to $HOME/.aiteamforge/
# Fallback: legacy path $HOME/.dev-team/ for pre-existing installs
if [ -f "$HOME/.aiteamforge/fleet-config.json" ]; then
    FLEET_CONFIG_FILE="$HOME/.aiteamforge/fleet-config.json"
elif [ -f "$HOME/.dev-team/fleet-config.json" ]; then
    FLEET_CONFIG_FILE="$HOME/.dev-team/fleet-config.json"
else
    FLEET_CONFIG_FILE="$HOME/.aiteamforge/fleet-config.json"
fi

if [ -f "$HOME/.aiteamforge/machine.json" ]; then
    MACHINE_CONFIG_FILE="$HOME/.aiteamforge/machine.json"
else
    MACHINE_CONFIG_FILE="$HOME/.dev-team/machine.json"
fi

# Machine GUID - persistent unique identifier for this machine
# Primary source: machine-identity.json written by installer
# Fallback: ~/.fleet-machine-id created on first run
MACHINE_IDENTITY_FILE="${AITEAMFORGE_DIR:-$HOME/aiteamforge}/config/machine-identity.json"
MACHINE_ID_FILE="$HOME/.fleet-machine-id"

# ============================================================================
# NEW CONFIG SYSTEM (XACA-0024)
# ============================================================================

# Read value from JSON config file using jq
read_config() {
    local file="$1"
    local path="$2"
    local default="$3"

    if [ -f "$file" ] && command -v jq &> /dev/null; then
        local value
        value=$(jq -r "$path // empty" "$file" 2>/dev/null)
        if [ -n "$value" ] && [ "$value" != "null" ]; then
            echo "$value"
            return
        fi
    fi
    echo "$default"
}

# Load configuration from new config system or fall back to environment
load_config() {
    # Fleet mode: client, standalone, or hybrid
    if [ -f "$FLEET_CONFIG_FILE" ]; then
        FLEET_MODE=$(read_config "$FLEET_CONFIG_FILE" ".mode" "client")
        CENTRAL_ENABLED=$(read_config "$FLEET_CONFIG_FILE" ".centralServer.enabled" "true")
        CENTRAL_API=$(read_config "$FLEET_CONFIG_FILE" ".centralServer.apiEndpoint" "")
        CENTRAL_AUTH_TOKEN=$(read_config "$FLEET_CONFIG_FILE" ".centralServer.authToken" "")
        LOCAL_ENABLED=$(read_config "$FLEET_CONFIG_FILE" ".localServer.enabled" "false")
        LOCAL_PORT=$(read_config "$FLEET_CONFIG_FILE" ".localServer.port" "3000")
        REPORT_INTERVAL=$(read_config "$FLEET_CONFIG_FILE" ".reporting.interval" "60")
        DASHBOARD_GROUP=$(read_config "$FLEET_CONFIG_FILE" ".dashboardGroup" "")
    else
        # Fall back to environment variables (legacy support)
        FLEET_MODE="${FLEET_MODE:-client}"
        CENTRAL_API="${FLEET_MONITOR_API:-http://localhost:3000/api/status}"
        CENTRAL_AUTH_TOKEN="${FLEET_AUTH_TOKEN:-}"
        LOCAL_PORT="${FLEET_LOCAL_PORT:-3000}"
        DASHBOARD_GROUP="${FLEET_DASHBOARD_GROUP:-}"
    fi

    # Load machine config if available
    if [ -f "$MACHINE_CONFIG_FILE" ]; then
        CONFIG_MACHINE_NAME=$(read_config "$MACHINE_CONFIG_FILE" ".machineName" "")
        CONFIG_DASHBOARD_GROUP=$(read_config "$MACHINE_CONFIG_FILE" ".dashboardGroup" "")
        # Use machine config dashboard group if not set in fleet config
        [ -z "$DASHBOARD_GROUP" ] && DASHBOARD_GROUP="$CONFIG_DASHBOARD_GROUP"
    fi

    # Build API endpoints based on mode
    case "$FLEET_MODE" in
        "client")
            API_ENDPOINTS=("${CENTRAL_API:-http://localhost:3000/api/status}")
            ;;
        "standalone")
            API_ENDPOINTS=("http://localhost:${LOCAL_PORT}/api/status")
            ;;
        "hybrid")
            API_ENDPOINTS=()
            # Add local endpoint first
            API_ENDPOINTS+=("http://localhost:${LOCAL_PORT}/api/status")
            # Add central endpoint if configured
            if [ -n "$CENTRAL_API" ]; then
                API_ENDPOINTS+=("$CENTRAL_API")
            fi
            ;;
        *)
            # Default to legacy behavior
            API_ENDPOINTS=("${FLEET_MONITOR_API:-http://localhost:3000/api/status}")
            ;;
    esac
}

# Load configuration
load_config

# Legacy compatibility: single endpoint for non-hybrid mode
API_ENDPOINT="${API_ENDPOINTS[0]:-http://localhost:3000/api/status}"

get_machine_id() {
    # Priority 1: machine-identity.json written by installer (authoritative ID)
    if [ -f "$MACHINE_IDENTITY_FILE" ] && command -v jq &>/dev/null; then
        local id_from_identity
        id_from_identity=$(jq -r '.machineId // empty' "$MACHINE_IDENTITY_FILE" 2>/dev/null)
        if [ -n "$id_from_identity" ] && [ "$id_from_identity" != "null" ]; then
            # Mirror into the simple ID file so legacy tools stay consistent
            echo "$id_from_identity" > "$MACHINE_ID_FILE"
            echo "$id_from_identity"
            return
        fi
    fi

    # Priority 2: simple ID file from a prior reporter run
    if [ -f "$MACHINE_ID_FILE" ]; then
        cat "$MACHINE_ID_FILE"
        return
    fi

    # Priority 3: generate new UUID and save it (first run, no installer)
    local new_id
    if command -v uuidgen &> /dev/null; then
        new_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    else
        # Fallback: generate pseudo-UUID from hostname + timestamp + random
        new_id=$(echo "$(hostname)-$(date +%s)-$RANDOM" | shasum | cut -c1-36)
    fi
    echo "$new_id" > "$MACHINE_ID_FILE"
    echo "$new_id"
}

MACHINE_ID=$(get_machine_id)

# Machine identification
# Priority: FLEET_MACHINE_NAME env var > Tailscale hostname > local hostname
get_hostname() {
    # First check for explicit override
    if [ -n "${FLEET_MACHINE_NAME:-}" ]; then
        echo "$FLEET_MACHINE_NAME"
        return
    fi

    # Try to get Tailscale MagicDNS hostname (for remote access)
    local tailscale_name=""
    local tailscale_json=""
    if [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
        tailscale_json=$(/Applications/Tailscale.app/Contents/MacOS/Tailscale status --self --json 2>/dev/null)
    elif command -v tailscale &> /dev/null; then
        tailscale_json=$(tailscale status --self --json 2>/dev/null)
    fi

    if [ -n "$tailscale_json" ]; then
        # Extract the first DNSName (which is Self) and remove trailing dot
        # XACA-0782: `|| true` guards the same set -e/pipefail abort class as the
        # session-count line — grep exits 1 if the JSON has no DNSName; empty name
        # is fine, the caller falls back to hostname below.
        tailscale_name=$(echo "$tailscale_json" | grep '"DNSName"' | head -1 | sed 's/.*"DNSName": *"\([^"]*\)".*/\1/' | sed 's/\.$//') || true
    fi

    if [ -n "$tailscale_name" ]; then
        echo "$tailscale_name"
    else
        # Fallback to local hostname
        hostname
    fi
}

HOSTNAME=$(get_hostname)
# XACA-0782: `|| true` prevents a whole-script abort here (top-level, under set
# -euo pipefail). On a loopback-only host, `grep -v '127.0.0.1'` filters every
# line and exits 1; pipefail + set -e would kill the reporter before it POSTs.
# Empty IP is acceptable in the payload; aborting is not.
IP_ADDRESS=$(/sbin/ifconfig | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | head -1) || true
OS_TYPE=$(uname -s)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

# LCARS port files directory
LCARS_PORTS_DIR="${AITEAMFORGE_DIR:-$HOME/dev-team}/lcars-ports"

# Backup status file location
BACKUP_STATUS_FILE="$HOME/aiteamforge-backups/kanban/backup-status.json"


# ============================================================================
# FUNCTIONS
# ============================================================================

# ---------------------------------------------------------------------------
# LCARS port resolution (XACA-0998)
#
# AUTHORITY MODEL -- decided in XACA-0998-002 (Q1, "Option A-prime"), signed
# off 2026-08-29. Resolution precedence, in this exact order:
#
#   1. LIVE PROCESS    -- the port the running LCARS server was launched on,
#                         joined on its exported LCARS_SESSION_NAME. Ground truth.
#   2. team-paths.json -- the canonical registry (.teams.<id>.lcars_port).
#   3. ""              -- empty string; the call site OMITS the field.
#
# <session>.port files are NEVER read on any reporting path. That is the entire
# point of the ticket. A .port file records "what some launcher wrote here
# once", not "what a dashboard link will actually reach" -- and 6 of 11 teams
# write it from a hardcoded literal that never touches the registry. The
# registry is canonical but demonstrably lossy (six damaged snapshots on this
# machine 2026-04 -> 2026-08; a restore from a stale backup on 2026-08-29
# reverted three freelance teams to pre-XACA-0838 ports while their servers
# were running on the corrected ones). Putting the live process ABOVE the
# registry means neither a stale file nor a stale registry can render a dead
# link: we report what is actually true instead of arbitrating between two
# artifacts, neither of which is ground truth.
#
# ACCEPTED TRADE-OFF (explicitly signed off): the field's semantics change from
# *configured port* to *currently-bound port*. Tier 2 covers the down/
# restarting case with the configured value, so the field disappears only when
# a team is unknown to BOTH the process table and the registry.
#
# FAIL CLOSED HERE MEANS WITHHOLD, NOT ALARM. This is a reporting path:
# unresolvable must yield "" so the caller omits lcars_port entirely. A missing
# link is safe; a wrong link is not. The *detection* path (XACA-0998-005) fails
# closed in the opposite shape -- by alarming, because silence is its failure
# mode. Different subsystem, different consumer: do not let the checker's rule
# leak into this emit path.
#
# DEPENDENCIES: tier 1 is parser-free (pgrep + ps, i.e. /usr/bin/pgrep and
# /bin/ps -- both unconditionally on the LaunchAgent plist's fixed PATH). Tier
# 2 uses jq, then python3, each behind its own `command -v` guard, mirroring
# the jq-or-degrade pattern in json_escape() below. Nothing here adds a new
# UNCONDITIONAL dependency to the reporter's core collection path, and every
# optional dependency degrades into tier 3 rather than into a wrong value.
# ---------------------------------------------------------------------------

# One-shot sweep of live LCARS servers, cached for the whole reporter run.
#
# PERFORMANCE: `ps eww` output is far larger than the single `cat` this
# replaced, and the reporter runs on a ~60s launchd cadence. Sweep ONCE and
# answer every lookup from the cached map -- never once per session.
#
# WHERE THE SWEEP MUST BE TRIGGERED FROM, AND WHY (XACA-0998-019/023).
# The cache is a plain global, so it is only shared by shells that DESCEND from
# the one that built it. get_lcars_port() is invoked as `$(get_lcars_port ...)`
# from inside get_tmux_sessions()'s per-session loop, and a command
# substitution is a SUBSHELL: a map built lazily down there dies with that
# subshell and _LCARS_LIVE_MAP_BUILT never flips in the caller, so the sweep
# re-ran once per LCARS session (measured on the review PR: 3 sweeps for 3
# sessions, ~0.118s each with 12 pids) -- exactly what the paragraph above
# promises does not happen. The fix is not in this function: every entry point
# that will resolve ports calls _lcars_build_live_map in ITS OWN scope, BEFORE
# any command substitution -- build_payload() (so one sweep covers the whole
# payload), get_tmux_sessions() and get_lcars_services() (so each stays correct
# when a test or a future caller drives it directly). The guard below makes the
# extra calls free. tests/test-xaca-0998-020-live-map-sweep-count.sh counts the
# sweeps and fails if any of those calls is removed.
#
# Map format: one record per line, "<session_name> <port> <team>". A
# newline-delimited string rather than an associative array because this script
# must run under bash 3.2 (macOS /bin/bash), which has no `declare -A`.
_LCARS_LIVE_MAP=""
_LCARS_LIVE_MAP_BUILT=false

_lcars_build_live_map() {
    if [ "$_LCARS_LIVE_MAP_BUILT" = true ]; then
        return 0
    fi
    _LCARS_LIVE_MAP_BUILT=true
    _LCARS_LIVE_MAP=""

    command -v pgrep >/dev/null 2>&1 || return 0
    command -v ps >/dev/null 2>&1 || return 0

    # pgrep exits 1 with empty output when nothing matches; `|| true` keeps
    # `set -e` from aborting the reporter when no LCARS server is running.
    local pids
    pids="$(pgrep -f 'server\.py' 2>/dev/null || true)"
    if [ -z "$pids" ]; then
        return 0
    fi

    # `while IFS= read -r` over a HERE-DOC, not `for pid in $pids` (XACA-0998-022).
    # This file is bash-only today, but the identical sweep in
    # scripts/lcars-launch-helpers.sh (_lcars_guard_live_bound_port) is sourced
    # under zsh as well, and zsh does NOT word-split an unquoted parameter
    # expansion -- the `for` form there would iterate exactly once over the
    # whole newline-joined blob and every extraction below would run on
    # garbage. The two readers are kept in the same shape deliberately so the
    # bash-only one cannot become the template someone copies into a zsh file.
    # A here-doc REDIRECT (not a pipe) keeps the loop in the current shell, so
    # accumulation into _LCARS_LIVE_MAP survives. All locals are declared
    # BEFORE the loop (zsh local-in-loop).
    local pid args session team port
    while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        args="$(ps eww -o args= -p "$pid" 2>/dev/null || true)"
        [ -z "$args" ] && continue

        # Only an LCARS server carries LCARS_SESSION_NAME in its environment,
        # so this doubles as the "is this actually an LCARS server" filter.
        #
        # LCARS_SESSION_NAME is the normative join key (XACA-0998-002 Q3):
        # verified across 8 live servers, every exported value is an EXACT
        # match for the reporter's own session_name -- including the multi-part
        # names (finance-personal-lcars, legal-coparenting-lcars) where a naive
        # "-lcars" strip is ambiguous. Equality join, no parsing, no inference.
        # parse_session_name() is disqualified for this: it takes the LAST
        # hyphen-part as `team`, so it returns team=lcars for every LCARS
        # session name and can never produce a registry team id.
        case "$args" in
            *" LCARS_SESSION_NAME="*) ;;
            *) continue ;;
        esac
        session="${args##* LCARS_SESSION_NAME=}"
        session="${session%%[[:space:]]*}"
        [ -z "$session" ] && continue

        team=""
        case "$args" in
            *" LCARS_TEAM="*)
                team="${args##* LCARS_TEAM=}"
                team="${team%%[[:space:]]*}"
                ;;
        esac

        # Bound port = the first integer token immediately after "server.py ".
        # Same extraction aiteamforge-doctor.sh::check_lcars_port_drift() uses
        # (the one live-process read already proven in this codebase). If
        # "server.py " is absent the expansion is a no-op and the digit trim
        # yields "", so the record is skipped rather than guessed at.
        port="${args#*server.py }"
        port="${port%%[![:digit:]]*}"
        case "$port" in
            ''|*[!0-9]*) continue ;;
            0*) continue ;;
        esac

        _LCARS_LIVE_MAP="${_LCARS_LIVE_MAP}${session} ${port} ${team}
"
    done <<_LBLM_EOF
$pids
_LBLM_EOF

    return 0
}

# Tier 1 lookup: exact-equality join of $1 against a live server's
# LCARS_SESSION_NAME. Prints every DISTINCT bound port for that session name,
# space-separated, or nothing at all. Always exits 0.
#
# WHY IT REPORTS ALL OF THEM RATHER THAN THE FIRST (XACA-0998-024).
# Normally there is exactly one. Two servers can claim one session name --
# a genuine split-brain -- and this used to resolve it with
# `awk '{print $2; exit}'`, i.e. by picking whichever pgrep listed first.
# That is a coin flip presented to the dashboard as a fact. Enumerating
# instead lets get_lcars_port() see the ambiguity and WITHHOLD, per the
# fail-closed shape this reporting path is signed off on: a missing link is
# safe, a wrong link is not.
#
# This deliberately mirrors _lcars_guard_live_bound_port() in
# scripts/lcars-launch-helpers.sh, which also returns all of them. The two
# readers now SEE the same thing and differ only in what they DO with it --
# the guard surfaces the split-brain to a human at startup, this one omits
# the field. That inversion is intentional and is the whole reason both
# functions enumerate rather than guess.
#
# Distinctness matters: two PIDs of one process group report the same port and
# must not read as a conflict, so the count is over distinct VALUES, not rows.
_lcars_live_ports_for_session() {
    local session_name="$1"
    [ -n "$session_name" ] || return 0
    _lcars_build_live_map
    [ -n "$_LCARS_LIVE_MAP" ] || return 0
    printf '%s' "$_LCARS_LIVE_MAP" | awk -v want="$session_name" '
        $1 == want && $2 != "" && !seen[$2]++ { out = (out == "" ? $2 : out " " $2) }
        END { if (out != "") print out }
    '
}

# Tier 2 lookup: the canonical registry, .teams.<team_id>.lcars_port.
#
# The session -> team-id bridge here is the naive "-lcars" suffix strip, and it
# is BEST-EFFORT by design -- documented rather than hidden. Two known-invalid
# classes: (a) the three legal orphan sessions (legal-lcars,
# legal-personal-lcars, legal-coparent-lcars) strip to ids that do not exist in
# the registry, which holds only legal-coparenting; (b) five of mainevent's six
# registry entries have no session of their own at all -- there is only ever
# one mainevent-lcars session for the whole team -- so the strip is
# structurally inapplicable to them. Both classes simply miss and fall through
# to tier 3, which is the correct outcome: no entry, no link.
#
# Tier 1 needs no mapping whatsoever; that is precisely why LCARS_SESSION_NAME
# is normative and this strip survives only down here on the fallback branch.
_lcars_registry_port_for_team() {
    local team_id="$1"
    [ -n "$team_id" ] || return 0

    # Same resolution aiteamforge_paths.py uses: $AITEAMFORGE_CONFIG wins,
    # otherwise the well-known dotdir path.
    local registry="${AITEAMFORGE_CONFIG:-$HOME/.aiteamforge/team-paths.json}"
    [ -f "$registry" ] || return 0

    local port=""
    if command -v jq >/dev/null 2>&1; then
        port="$(jq -r --arg t "$team_id" '.teams[$t].lcars_port // empty' "$registry" 2>/dev/null | head -1 || true)"
    elif command -v python3 >/dev/null 2>&1; then
        port="$(REGISTRY="$registry" TEAM_ID="$team_id" python3 -c '
import json, sys
from os import environ
try:
    with open(environ["REGISTRY"]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
teams = data.get("teams") if isinstance(data, dict) else None
if not isinstance(teams, dict):
    sys.exit(0)
entry = teams.get(environ["TEAM_ID"])
if not isinstance(entry, dict):
    sys.exit(0)
value = entry.get("lcars_port")
if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
    sys.exit(0)
print(value)
' 2>/dev/null || true)"
    fi

    # Reject null / non-integer / <= 0 / leading-zero values rather than emit a
    # malformed JSON number. A bad registry entry degrades to tier 3 (no field),
    # never to a wrong link. "0" and "007" are both caught by the 0* arm.
    case "$port" in
        ''|*[!0-9]*) return 0 ;;
        0*) return 0 ;;
    esac

    printf '%s' "$port"
}

# Get LCARS port for a session (if available).
#
# CONTRACT (unchanged, and load-bearing): prints a bare integer on success or
# an EMPTY string when unresolvable, and always exits 0. The call site in
# get_tmux_sessions() gates on `[ -n "$lcars_port" ]` before appending the
# `,"lcars_port":<n>` JSON fragment, so an empty return omits the field
# cleanly. Never print diagnostics to stdout here and never exit non-zero --
# the first lands inside the payload, the second aborts the reporter under
# `set -e`.
get_lcars_port() {
    local session_name="$1"
    local port=""

    # Tier 1 -- live process. Ground truth.
    #
    # An AMBIGUOUS tier-1 answer (two live servers exporting the same
    # LCARS_SESSION_NAME on different ports) is not a tier-1 miss and must not
    # fall through to tier 2: the registry records intent, and under a
    # split-brain "intent" is just a third opinion about which of two running
    # servers a dashboard link should open. Withhold outright (XACA-0998-024).
    # This is the ONE place the tier chain short-circuits to tier 3 without
    # consulting tier 2, and it does so in the safe direction -- no field
    # rather than a coin-flip field.
    port="$(_lcars_live_ports_for_session "$session_name")"
    case "$port" in
        '')
            ;;
        *' '*)
            echo ""
            return 0
            ;;
        *)
            printf '%s\n' "$port"
            return 0
            ;;
    esac

    # Tier 2 -- canonical registry, via the best-effort session -> team strip.
    port="$(_lcars_registry_port_for_team "${session_name%-lcars}")"
    if [ -n "$port" ]; then
        printf '%s\n' "$port"
        return 0
    fi

    # Tier 3 -- withhold. $LCARS_PORTS_DIR/<session>.port is deliberately NOT
    # consulted, on this or any other reporting path.
    echo ""
    return 0
}

# Get theme color for a session (if available)
# Looks for theme file at ~/dev-team/lcars-ports/{session_name}.theme
get_theme_color() {
    local session_name="$1"
    local theme_file="$LCARS_PORTS_DIR/${session_name}.theme"

    if [ -f "$theme_file" ]; then
        cat "$theme_file"
    else
        echo ""
    fi
}

# Get tab order for a session (if available)
# Looks for order file at ~/dev-team/lcars-ports/{session_name}.order
get_tab_order() {
    local session_name="$1"
    local order_file="$LCARS_PORTS_DIR/${session_name}.order"

    if [ -f "$order_file" ]; then
        cat "$order_file"
    else
        echo ""
    fi
}

# Check if session is an LCARS terminal
is_lcars_session() {
    local session_name="$1"
    # Case-insensitive check for "lcars" in session name
    echo "$session_name" | grep -qi "lcars" && return 0 || return 1
}

# Get backup status JSON (if available)
# Returns the backup_status object or empty string if not available
get_backup_status() {
    if [ -f "$BACKUP_STATUS_FILE" ]; then
        # Read and return the backup status JSON
        cat "$BACKUP_STATUS_FILE" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Escape a string for safe inclusion in a JSON string value.
# Handles: backslash, double-quote, newline, carriage return, tab,
# and other ASCII control characters (U+0000–U+001F).
# Prefers jq (handles full Unicode and all control chars correctly);
# falls back to a sed+awk pipeline when jq is unavailable.
json_escape() {
    local input="$1"
    if command -v jq &>/dev/null; then
        # jq @json produces a quoted JSON string; strip the outer quotes
        # to return just the escaped content for interpolation.
        jq -rn --arg v "$input" '$v | @json' | sed 's/^"\(.*\)"$/\1/'
    else
        # Fallback: sed pipeline — order is critical:
        # 1. Backslashes first (must precede all other substitutions)
        # 2. Double-quotes
        # 3. Tab, carriage return
        # 4. Newlines via awk (BSD sed lacks multi-line GNU extensions)
        printf '%s' "$input" \
            | sed 's/\\/\\\\/g' \
            | sed 's/"/\\"/g' \
            | sed $'s/\t/\\\\t/g' \
            | sed $'s/\r/\\\\r/g' \
            | awk '{if(NR>1) printf "\\n"; printf "%s", $0} END{printf "\n"}'
    fi
}

# Parse tmux session name into components
parse_session_name() {
    local session_name="$1"
    local division=""
    local project=""
    local team=""

    # Split by hyphens
    IFS='-' read -ra PARTS <<< "$session_name"

    # Determine structure based on number of parts
    if [ ${#PARTS[@]} -eq 2 ]; then
        # Simple format: division-team (e.g., ios-bridge)
        division="${PARTS[0]}"
        team="${PARTS[1]}"
    elif [ ${#PARTS[@]} -ge 3 ]; then
        # Check if this is a multi-project format
        # We need to determine where project ends and team begins
        # For now, assume: division-project-team or division-group-project-team
        division="${PARTS[0]}"

        # If 3 parts: division-project-team
        if [ ${#PARTS[@]} -eq 3 ]; then
            project="${PARTS[1]}"
            team="${PARTS[2]}"
        else
            # If 4+ parts: division-group-project-team (e.g., freelance-doublenode-workstats-command)
            # Join middle parts as project name
            project="${PARTS[1]}"
            last_index=$((${#PARTS[@]} - 1))
            for ((i=2; i<last_index; i++)); do
                project="${project}-${PARTS[i]}"
            done
            team="${PARTS[$last_index]}"
        fi
    else
        # Unknown format, treat whole thing as division
        division="$session_name"
        team="unknown"
    fi

    echo "$division|$project|$team"
}

# Auto-discover team names from available sources.
# Priority order:
#   1. .aiteamforge-config team_paths keys (authoritative for this install)
#   2. Directories under $AITEAMFORGE_DIR/ that contain a kanban board
#   3. Hardcoded fallback list (covers pre-config and legacy installs)
discover_team_names() {
    local teams=()
    local config_file="${AITEAMFORGE_DIR:-$HOME/aiteamforge}/.aiteamforge-config"

    # Strategy 1: read team_paths keys from .aiteamforge-config
    if [ -f "$config_file" ] && command -v jq &>/dev/null; then
        while IFS= read -r team; do
            [ -n "$team" ] && teams+=("$team")
        done < <(jq -r '.team_paths // {} | keys[]' "$config_file" 2>/dev/null)
    fi

    # Strategy 2: scan AITEAMFORGE_DIR subdirectories for kanban boards
    if [ ${#teams[@]} -eq 0 ]; then
        local forge_dir="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
        if [ -d "$forge_dir" ]; then
            for dir in "$forge_dir"/*/; do
                [ -d "$dir" ] || continue
                local team_name
                team_name=$(basename "$dir")
                # Skip known non-team directories
                case "$team_name" in
                    config|logs|backups|tmp|cache|crews|Formula|libexec|tests) continue ;;
                esac
                # Presence of a kanban board is a strong signal this is a team dir
                if [ -f "${dir}kanban/kanban-board.json" ] || [ -f "${dir}kanban-board.json" ]; then
                    teams+=("$team_name")
                fi
            done
        fi
    fi

    # Strategy 3: hardcoded fallback — used when config and dir scan both come up empty
    if [ ${#teams[@]} -eq 0 ]; then
        teams=(academy android command dns firebase freelance ios legal mainevent medical)
    fi

    printf '%s\n' "${teams[@]}"
}

# Find all tmux sockets (team-specific sockets in /tmp/)
find_tmux_sockets() {
    local sockets=()

    # Discover team names dynamically; fall back to hardcoded list if needed
    local team_names
    team_names=$(discover_team_names)

    # Check for team-specific sockets directly in /tmp/
    # These are socket files (type 's') owned by current user
    while IFS= read -r team; do
        [ -n "$team" ] || continue
        local socket="/tmp/${team}"
        if [ -S "$socket" ]; then
            sockets+=("$socket")
        fi
    done <<< "$team_names"

    # Also check standard tmux socket directory
    local uid
    uid=$(id -u)
    if [ -d "/tmp/tmux-${uid}" ]; then
        for socket in /tmp/tmux-${uid}/*; do
            if [ -S "$socket" ]; then
                sockets+=("$socket")
            fi
        done
    fi

    # Return sockets, one per line
    printf '%s\n' "${sockets[@]}"
}

# Get tmux session information from all sockets
get_tmux_sessions() {
    if ! command -v tmux &> /dev/null; then
        echo "[]"
        return
    fi

    local sessions="[]"
    local first=true
    local found_any=false

    # Find all tmux sockets
    local sockets
    sockets=$(find_tmux_sockets)

    if [ -z "$sockets" ]; then
        echo "[]"
        return
    fi

    # XACA-0998-019/023: build the live-process map HERE, in this function's
    # own shell, BEFORE the loop -- exactly as get_lcars_services() already
    # does. get_lcars_port() below is called as `$(get_lcars_port ...)`, and a
    # command substitution is a subshell: left to build the map lazily, it
    # rebuilt it once per LCARS session and threw it away each time. Priming it
    # in this scope means every one of those subshells inherits a map that is
    # already built, so the `ps eww` sweep happens once for this whole call.
    # See the "WHERE THE SWEEP MUST BE TRIGGERED FROM" note above
    # _LCARS_LIVE_MAP; the call is idempotent via _LCARS_LIVE_MAP_BUILT.
    _lcars_build_live_map

    # Iterate through each socket
    while IFS= read -r socket; do
        [ -z "$socket" ] && continue

        # Get sessions from this socket
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            found_any=true

            # Parse tmux list-sessions output
            # Format: session_name: X windows (created DATE) [attached]

            session_name=$(echo "$line" | awk -F: '{print $1}')
            # XACA-0782: `|| echo 0` keeps windows numeric AND guards the set -e/
            # pipefail abort class (grep -o exits 1 if the line has no "N windows").
            windows=$(echo "$line" | grep -o '[0-9]* windows' | awk '{print $1}' || echo 0)
            attached=$(echo "$line" | grep -q 'attached' && echo "true" || echo "false")

            # Extract creation date
            created_str=$(echo "$line" | sed -n 's/.*created \(.*\)) .*/\1/p')

            # Convert to ISO 8601 timestamp (approximation)
            if [ -n "$created_str" ]; then
                created_timestamp=$(date -j -f "%a %b %d %H:%M:%S %Y" "$created_str" "+%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || echo "$TIMESTAMP")
            else
                created_timestamp="$TIMESTAMP"
            fi

            # Calculate uptime in seconds
            created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S.000Z" "$created_timestamp" "+%s" 2>/dev/null || date "+%s")
            current_epoch=$(date "+%s")
            uptime_seconds=$((current_epoch - created_epoch))

            # Parse session name
            IFS='|' read -r division project team <<< "$(parse_session_name "$session_name")"

            # Escape user-controllable string values before JSON interpolation
            local session_name_esc division_esc team_esc
            session_name_esc=$(json_escape "$session_name")
            division_esc=$(json_escape "$division")
            team_esc=$(json_escape "$team")

            # Build JSON object for this session
            if [ "$first" = true ]; then
                first=false
                sessions="["
            else
                sessions="${sessions},"
            fi

            # Handle project field (null if empty, quoted string if present)
            if [ -z "$project" ]; then
                project_json="null"
            else
                project_json="\"$(json_escape "$project")\""
            fi

            # Check for LCARS port (for LCARS terminals)
            lcars_port_json=""
            if echo "$session_name" | grep -qi "lcars"; then
                lcars_port=$(get_lcars_port "$session_name")
                if [ -n "$lcars_port" ]; then
                    lcars_port_json=",\"lcars_port\":$lcars_port"
                fi
            fi

            # Check for theme color (any terminal can have one)
            theme_color_json=""
            theme_color=$(get_theme_color "$session_name")
            if [ -n "$theme_color" ]; then
                theme_color_json=",\"theme_color\":\"$(json_escape "$theme_color")\""
            fi

            # Check for tab order (for sorting in Fleet Monitor)
            tab_order_json=""
            tab_order=$(get_tab_order "$session_name")
            if [ -n "$tab_order" ]; then
                tab_order_json=",\"tab_order\":$tab_order"
            fi

            sessions="${sessions}{\"name\":\"$session_name_esc\",\"division\":\"$division_esc\",\"project\":$project_json,\"team\":\"$team_esc\",\"windows\":$windows,\"attached\":$attached,\"created\":\"$created_timestamp\",\"uptime_seconds\":$uptime_seconds${lcars_port_json}${theme_color_json}${tab_order_json}}"

        done < <(tmux -S "$socket" list-sessions 2>/dev/null || true)
    done <<< "$sockets"

    if [ "$first" = false ]; then
        sessions="${sessions}]"
    fi

    echo "$sessions"
}

# Get LCARS service records independent of tmux session enumeration (XACA-0983).
#
# WHY THIS EXISTS: get_lcars_port() is only ever CALLED from inside
# get_tmux_sessions()'s loop over live tmux sessions (see "Check for LCARS
# port" above). When a team's <team>-lcars tmux session dies (e.g. a
# health-check self-heal that kills-without-recreating -- see
# lcars-health-check.sh's _hc_heal_noncanonical_port, XACA-0983 fix (a)), that
# loop never iterates for the team and the reporter emits NOTHING for it, even
# though its server may still be answering.
#
# This is a MACHINE-LEVEL array, deliberately NOT nested under sessions[] --
# nesting it there would recreate the exact bug it fixes: a session-less team
# would still be structurally absent from the payload.
#
# ---- XACA-0998: THE ENUMERATION SOURCE CHANGED ---------------------------
# This function used to glob $LCARS_PORTS_DIR/*-lcars.port for its catalog. It
# no longer reads .port files at all -- the signed-off authority model (see the
# block above get_lcars_port()) removes them from EVERY reporting path, and
# this was the file's second, independent .port reader. Leaving it would have
# made the fix merely look done while the service catalog kept publishing stale
# ports and curl-probing the wrong ones.
#
# Enumeration is now the live-process sweep (_lcars_build_live_map), and each
# record's port goes through get_lcars_port() -- the SAME precedence chain
# sessions[] uses, so the two can never disagree about a team.
#
# WHY NOT ALSO ENUMERATE REGISTRY-KNOWN TEAMS as known-but-not-running entries:
# because team-paths.json carries no machine attribution. Every one of its
# entries (25 on this machine) looks identical whether the team is hosted here
# or on another machine in the fleet, so seeding this array from the registry
# would fabricate machine-level service records on EVERY host for teams that
# live elsewhere -- lighting up phantom LCARS cards fleet-wide. lcars_services[]
# is by definition a report about THIS machine; a fleet-wide registry cannot
# scope it. The live process table can, and does.
#
# Coverage after the change -- the XACA-0983 gap stays closed:
#   session alive + server alive  -> sessions[] AND lcars_services[]
#   session DEAD  + server alive  -> lcars_services[]   <- the XACA-0983 case
#   session alive + server DEAD   -> sessions[] (name-based LCARS gate still
#                                   fires; the port field is omitted, which is
#                                   the accepted semantic change)
#   session DEAD  + server DEAD   -> nothing. Previously a stale .port file
#                                   produced a phantom entry with
#                                   reachable=false; under the signed-off model
#                                   that record correctly disappears.
#
# Forward/backward compatibility: an old server ignores this unknown top-level
# key; this reporter still emits sessions[] unchanged, so an old server sees
# no behavior change. See server.js parseFleetData() for the other half of the
# contract -- it requires a non-empty division and team plus a finite numeric
# port on every record, and passes `source` straight through.
get_lcars_services() {
    local have_curl=false
    command -v curl &>/dev/null && have_curl=true

    # Pass 1: collect (session_name, division, project, team, port) tuples from
    # the live-process sweep. Cheap and synchronous -- no network I/O here, and
    # the `ps` sweep itself is cached across the whole reporter run.
    #
    # division/project/team are still derived with the SAME parse_session_name()
    # used for sessions[] above -- deliberately unchanged, so a server-side
    # consumer (parseFleetData in server.js) can key a service record into the
    # exact same divisionKey/projectKey/teamKey a live session for that same
    # LCARS terminal would produce, instead of inventing a second, incompatible
    # naming scheme it would have to reconcile. parse_session_name() is
    # disqualified for PORT resolution (it yields team=lcars for every LCARS
    # session name), not for the display hierarchy it was written for.
    _lcars_build_live_map

    local -a session_names=() divisions=() projects=() teams=() ports=()
    # live_port/live_team are deliberately read-and-discarded: they name fields
    # 2 and 3 of the live-map record so the read below stays self-documenting,
    # but the port is re-resolved through get_lcars_port() (see the comment in
    # the loop) rather than trusted from the map. Keeping the descriptive names
    # is worth one suppression; renaming them to _ would hide the record shape.
    local session_name live_port live_team division project team port

    # shellcheck disable=SC2034
    while read -r session_name live_port live_team; do
        [ -n "$session_name" ] || continue

        # Resolve through the shared precedence chain rather than trusting the
        # map's own port directly, so this catalog and sessions[] can never
        # report different ports for the same terminal.
        port="$(get_lcars_port "$session_name")"
        case "$port" in
            ''|*[!0-9]*) continue ;;
        esac

        IFS='|' read -r division project team <<< "$(parse_session_name "$session_name")"

        # server.js drops any record with an empty division or team; skip it
        # here rather than emit one that is silently discarded downstream.
        [ -n "$division" ] || continue
        [ -n "$team" ] || continue

        session_names+=("$session_name")
        divisions+=("$division")
        projects+=("$project")
        teams+=("$team")
        ports+=("$port")
    done <<< "$_LCARS_LIVE_MAP"

    if [ ${#session_names[@]} -eq 0 ]; then
        echo "[]"
        return
    fi

    # Pass 2: probe reachability IN PARALLEL, not serially. This reporter runs
    # on a ~30-60s cron/LaunchAgent cadence; probing N teams serially at up to
    # --max-time each would multiply wall time by N and risk the reporter
    # overrunning its own cadence (flagged explicitly in the XACA-0983 decision
    # doc section 4.1). Each probe writes its verdict to a scratch file; we wait
    # for all of them, then assemble JSON synchronously with no I/O left to do.
    #
    # The probe is NOT redundant now that enumeration is live-process-based: a
    # server can be bound and still not answering (wedged, mid-startup, or
    # bound to an interface this probe cannot reach), which is exactly what
    # reachable=false is for.
    local tmp_dir=""
    if [ "$have_curl" = true ]; then
        tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/fleet-lcars-probe.XXXXXX" 2>/dev/null || echo "")
    fi
    if [ -n "$tmp_dir" ]; then
        trap 'command rm -rf "$tmp_dir"' RETURN

        local i
        for i in "${!ports[@]}"; do
            (
                if curl -s --connect-timeout 1 --max-time 2 "http://localhost:${ports[$i]}/api/status" > /dev/null 2>&1; then
                    echo "true" > "$tmp_dir/$i"
                else
                    echo "false" > "$tmp_dir/$i"
                fi
            ) &
        done
        wait
    fi

    local -a entries=()
    local reachable_json session_esc division_esc project_json team_esc i
    for i in "${!ports[@]}"; do
        reachable_json="null"
        if [ -n "$tmp_dir" ] && [ -f "$tmp_dir/$i" ]; then
            reachable_json=$(cat "$tmp_dir/$i")
        fi
        session_esc=$(json_escape "${session_names[$i]}")
        division_esc=$(json_escape "${divisions[$i]}")
        team_esc=$(json_escape "${teams[$i]}")
        if [ -z "${projects[$i]}" ]; then
            project_json="null"
        else
            project_json="\"$(json_escape "${projects[$i]}")\""
        fi
        entries+=("{\"session_name\":\"$session_esc\",\"division\":\"$division_esc\",\"project\":$project_json,\"team\":\"$team_esc\",\"port\":${ports[$i]},\"reachable\":$reachable_json,\"source\":\"live-process\"}")
    done

    local joined
    joined=$(IFS=,; echo "${entries[*]}")
    echo "[$joined]"
}

# ----------------------------------------------------------------------------
# Machine-level "system" container (XACA-1031-001, EPIC-0061 Design Decision 8)
#
# Cached with a plain global + "_BUILT" guard flag, same shape as
# _lcars_build_live_map above -- bash 3.2 (macOS /bin/bash) has no
# associative arrays. NOTE: unlike _lcars_build_live_map, this guard buys
# nothing ACROSS reporter invocations -- this script is a one-shot process
# re-exec'd by cron/launchd every ~60s, so the global is reset to "" every
# run regardless. It is kept anyway because (a) it matches the established
# precedent so a future reader isn't left wondering why this one omits it,
# and (b) it protects any future caller that invokes the getter more than
# once WITHIN a single run, same as the live-map guard does for its sweep.
#
# Scope: this reports the WORKING-DIR installed AITeamForge version --
# homebrew-tap's aiteamforge-doctor.sh calls this exact concept "working-dir
# installed version" (its check_version_drift() function) and resolves it
# from three sources in priority order, none of which invoke `brew` as a
# subprocess (a `brew --prefix`/`brew list` fork means a Ruby VM startup
# every ~60s on every consumer machine, forever -- ruled out deliberately):
#
#   1. `.installed-version` stamp -- post-upgrade truth: what
#      aiteamforge-upgrade.sh actually wrote to the working dir the last
#      time `aiteamforge upgrade` ran. Most accurate when present.
#   2. Homebrew Cellar directory, read as a plain filesystem path (see
#      _get_aiteamforge_cellar_version below) -- what brew installed. This
#      is the ONLY source with a real answer on a machine that has
#      installed AITeamForge but never once run `aiteamforge upgrade`:
#      the stamp above is written EXCLUSIVELY by the upgrade flow, so a
#      never-upgraded machine has no stamp at all. Those never-upgraded
#      machines are exactly the most-drifted, least-monitored ones --
#      the case this ticket exists to catch -- so skipping this source
#      would make the feature blind on precisely the hosts it targets.
#   3. Legacy `.aiteamforge-config` "version" field -- stamped once at
#      install time and never updated by `brew upgrade` (XACA-0702); last
#      resort only, per aiteamforge-doctor.sh's own "less reliable" note.
#   4. None of the above resolve -- omit the "aiteamforge" key entirely.
#
# All reads are local files under $AITEAMFORGE_DIR (default ~/aiteamforge)
# or the Cellar path -- no network, no `brew` invocation of any kind.
#
# On this dev machine (M3Pro) the AITeamForge tap must NEVER be installed
# (see CLAUDE.md), so all three sources are expected to be absent here --
# that is the correct, common case, not a bug. Absence must still produce
# a valid "system" container -- "system" and "system.versions" are ALWAYS
# present -- but the "aiteamforge" LEAF is OMITTED (not null, not empty
# string) when it can't be read, per the single "uncollectable field is
# omitted" convention XACA-1091 froze for every key in this shared block.
# See build_payload() for where $_AITEAMFORGE_VERSION becomes `{}` vs
# `{"aiteamforge":"..."}`.
_AITEAMFORGE_VERSION=""
_AITEAMFORGE_VERSION_BUILT=false

# Compare two dot-separated version strings NUMERICALLY, component by
# component. Returns 0 (true, shell success) if $1 > $2, 1 otherwise.
#
# Why this exists at all: brew keeps old kegs around, so
# Cellar/aiteamforge/ can hold more than one version directory, and a
# lexicographic pick is WRONG -- "0.20.3" sorts BEFORE "0.9.0" as a string
# (the character '2' < '9'), which would silently report a downgrade at
# the current live version. Comparing each dot-separated field as an
# integer avoids that trap entirely.
#
# Bash 3.2 safe: indexed arrays (not associative), `read -ra`, and a
# C-style `for` loop are all supported since bash 2.x.
_version_gt() {
    local a="$1" b="$2"
    local -a a_parts b_parts
    IFS='.' read -ra a_parts <<< "$a"
    IFS='.' read -ra b_parts <<< "$b"

    local len=${#a_parts[@]}
    if [ ${#b_parts[@]} -gt "$len" ]; then
        len=${#b_parts[@]}
    fi

    local i ai bi
    for ((i = 0; i < len; i++)); do
        ai="${a_parts[i]:-0}"
        bi="${b_parts[i]:-0}"
        # Strip any trailing non-digit content (brew revision suffixes like
        # "3_1", pre-release tags) so the arithmetic comparison below never
        # sees a non-numeric operand; an empty result after stripping (a
        # component that was non-numeric start-to-finish) counts as 0.
        ai="${ai%%[!0-9]*}"; [ -z "$ai" ] && ai=0
        bi="${bi%%[!0-9]*}"; [ -z "$bi" ] && bi=0
        if [ "$ai" -gt "$bi" ]; then
            return 0
        elif [ "$ai" -lt "$bi" ]; then
            return 1
        fi
        # Equal in this component -- fall through to compare the next one.
    done
    return 1
}

# Normalize a Homebrew Cellar keg DIRECTORY NAME into the clean, dotted
# numeric string the frozen contract requires for `versions.aiteamforge`
# (kanban/plans/XACA-1091/CONTRACT-system-block.md: "semver, no leading v").
#
# Why this exists (XACA-1031-019, code review on PR #818): brew keg dirs are
# not always a clean semver token. A revision bump names the dir
# "0.20.3_1" (trailing "_1" is NOT part of the version), and a HEAD/
# pre-release build can carry its own non-numeric suffix. _version_gt()
# above ALREADY strips exactly this shape for ITS OWN numeric comparison
# (`ai="${ai%%[!0-9]*}"`) -- the SELECTION of which keg is "best" was never
# wrong. What was wrong is that the raw, unnormalized directory name was
# then sent VERBATIM over the wire: the server's isVersionOutdated() does a
# strict per-component digit parse and rejects a non-numeric component
# (`3_1`) as unparseable, returning null -- which surfaces as a permanent
# amber UNKNOWN badge for a machine whose version is perfectly well known.
#
# DECISION: normalize HERE, at the reporter, not server-side. The frozen
# contract's ownership table lists `versions.aiteamforge` as an XACA-1031
# (reporter-owned) field, with `latest`/`outdated` explicitly carved out as
# the only SERVER-INJECTED leaves in this block -- i.e. the contract already
# draws the line at "producer owns the raw field, server owns derived
# fields". Stripping it server-side instead would blur that boundary and
# require every current AND future producer of this field to duplicate the
# same tolerance logic. A machine running an already-deployed, un-upgraded
# reporter binary keeps sending the raw string until its reporter script is
# refreshed -- exactly the same propagation path every other reporter-side
# fix in this file takes (including the `local v` fix in this same PR); it
# is not a gap unique to this fix.
#
# Applies _version_gt's own per-component rule -- strip from the first
# non-digit character to the end of that dot-separated component, defaulting
# a component that is non-numeric start-to-finish to "0" -- so the reported
# string can never disagree with what the selection logic upstream already
# treated it as. A HEAD/pre-release build's non-numeric leading token (e.g.
# "abc1234") therefore collapses to "0"; this function does not invent a
# richer answer than _version_gt's own comparator already gives that case.
#
# Bash 3.2 safe (same primitives as _version_gt: indexed arrays, `read -ra`,
# a C-style `for` loop, `${var%%pattern}`).
_normalize_aiteamforge_version() {
    local raw="$1"
    [ -n "$raw" ] || { printf ''; return 0; }

    # Strip a leading "v" BEFORE component parsing. The contract specifies
    # "semver, no leading v", and aiteamforge-doctor.sh:663 does `sed 's/^v//'`
    # on this same stamp -- so a "v0.20.3" stamp is a real shape in this fleet,
    # not a hypothetical. Without this, the leading-component check below sees
    # "v0" -> strips to empty -> returns empty, turning a perfectly readable
    # version into an omitted field. That would be a NEW false-UNKNOWN of
    # exactly the class XACA-1031-019/023 exist to remove.
    raw="${raw#v}"

    local -a parts
    IFS='.' read -ra parts <<< "$raw"

    local out="" i part clean
    for ((i = 0; i < ${#parts[@]}; i++)); do
        part="${parts[i]}"
        clean="${part%%[!0-9]*}"

        # XACA-1031-024: a LEADING component that strips to nothing means the
        # token is not a version at all (a HEAD keg like "HEAD-abc1234").
        # Returning "0" for it would be a confident lie: isVersionOutdated("0",
        # "0.20.4") is TRUE, so the card renders "v0 OUTDATED" and tells the
        # operator to upgrade a machine that is AHEAD of the release. Return
        # empty instead -- empty flows into the existing omit path and the card
        # renders an honest UNKNOWN, per this file's omit-don't-invent rule.
        # Note "0" itself is a legitimate numeric component and is preserved:
        # only an EMPTY strip result is rejected, not a zero one.
        if [ -z "$clean" ]; then
            if [ "$i" -eq 0 ]; then
                printf ''
                return 0
            fi
            clean=0
        fi

        if [ -z "$out" ]; then
            out="$clean"
        else
            out="${out}.${clean}"
        fi
    done

    printf '%s' "$out"
}

# Resolve the installed AITeamForge version from the Homebrew Cellar
# directory as a plain filesystem read -- NEVER via `brew --prefix` or
# `brew list`, both of which fork a Ruby VM (see the container-level
# comment above for why that cost is unacceptable on a 60s cadence).
#
# Homebrew's install prefix is one of exactly two well-known locations
# depending on CPU architecture (Apple Silicon vs Intel); a machine only
# ever has ONE of these active, so probing both and stopping at the first
# one containing a Cellar/aiteamforge directory is sufficient -- there is
# no scenario where checking further would change the answer.
#
# AITEAMFORGE_CELLAR_PREFIXES (space-separated list) overrides the default
# probe list -- this is the "overridable variable" tests point the probe
# at a synthetic Cellar under a scratch directory with, instead of ever
# touching a real /opt/homebrew or /usr/local.
#
# Prints the resolved version token on stdout, NORMALIZED per
# _normalize_aiteamforge_version() above (XACA-1031-019) -- or nothing if no
# Cellar directory was found on any probed prefix, or it was found but empty.
# Only the final selected "best" is normalized; the internal tie-break loop
# still compares raw directory names through _version_gt(), which already
# tolerates the same suffixes on both operands and is left untouched.
_get_aiteamforge_cellar_version() {
    local prefixes prefix cellar_dir best d dname
    prefixes="${AITEAMFORGE_CELLAR_PREFIXES:-/opt/homebrew /usr/local}"
    best=""

    for prefix in $prefixes; do
        cellar_dir="${prefix}/Cellar/aiteamforge"
        [ -d "$cellar_dir" ] || continue

        # Unquoted glob is intentional and safe here: no nullglob in bash
        # 3.2, so a no-match leaves the literal pattern, and `[ -d ... ]`
        # below simply rejects it (mirrors the existing pgrep/ps `|| true`
        # empty-result handling elsewhere in this file).
        for d in "$cellar_dir"/*/; do
            [ -d "$d" ] || continue
            dname="$(basename "$d")"
            [ -z "$dname" ] && continue
            if [ -z "$best" ]; then
                best="$dname"
            elif _version_gt "$dname" "$best"; then
                best="$dname"
            fi
        done

        # Found a Cellar dir for aiteamforge on this prefix -- brew only
        # ever installs to one prefix per machine, so this IS the answer
        # (even an empty Cellar/aiteamforge/ means "found the prefix, no
        # version kegs in it" -- checking the other prefix cannot help).
        break
    done

    [ -z "$best" ] && return 0
    # Return the RAW keg name; normalization happens once for all three
    # sources at the end of _get_aiteamforge_version() (XACA-1031-023).
    printf '%s' "$best"
}

_get_aiteamforge_version() {
    if [ "$_AITEAMFORGE_VERSION_BUILT" = true ]; then
        return 0
    fi
    _AITEAMFORGE_VERSION_BUILT=true
    _AITEAMFORGE_VERSION=""

    # v MUST be initialized, not merely declared: `local v` leaves it UNSET, and
    # under this file's `set -u` the `[ -z "$v" ]` fallthrough below aborts
    # build_payload() mid-emit when no stamp file exists -- producing truncated,
    # invalid JSON. macOS /bin/bash 3.2 tolerates the bare declaration; bash 5.x
    # (CI, and any host invoking this under a newer bash) does not, so the dev
    # machine cannot reproduce it. Caught by CI on XACA-1031 (PR #818).
    local working_dir stamp_file
    local v=""
    working_dir="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
    stamp_file="${working_dir}/.installed-version"

    # Source 1: .installed-version stamp -- see container-level comment.
    if [ -f "$stamp_file" ]; then
        # `|| true` -- tr/read can fail on an unreadable file; `set -e` must
        # not abort the reporter over a version string it can't get.
        v="$(tr -d '[:space:]' < "$stamp_file" 2>/dev/null || true)"
    fi

    # Source 2: Homebrew Cellar directory -- the only source with a real
    # answer on a never-upgraded machine. See container-level comment.
    if [ -z "$v" ]; then
        v="$(_get_aiteamforge_cellar_version)"
    fi

    # Source 3: legacy config "version" field -- last resort, unreliable.
    if [ -z "$v" ]; then
        local config_file
        config_file="${working_dir}/.aiteamforge-config"
        if [ -f "$config_file" ]; then
            if command -v jq >/dev/null 2>&1; then
                v="$(jq -r '.version // empty' "$config_file" 2>/dev/null || true)"
            else
                # Fallback mirrors homebrew-tap/libexec/lib/config.sh's
                # get_config_value() non-jq branch.
                v="$(grep '"version"' "$config_file" 2>/dev/null | sed -E 's/.*"version": *"?([^",}]+)"?.*/\1/' | head -n1 || true)"
            fi
        fi
    fi

    # Source 4 (implicit): nothing resolved -- $v stays empty, and
    # build_payload() omits the "aiteamforge" key entirely on an empty
    # _AITEAMFORGE_VERSION, per the XACA-1091 "omit, don't null" convention.
    # XACA-1031-023: normalize HERE, on the single shared exit path, so it
    # covers ALL THREE sources. It previously sat on the last line of
    # _get_aiteamforge_cellar_version() -- source 2 of 3 -- leaving the
    # .installed-version stamp (source 1, the HIGHEST priority, present on
    # every machine that has ever run `aiteamforge upgrade`) emitting raw brew
    # keg names like "0.20.3_1". aiteamforge-upgrade.sh writes that stamp from
    # `brew list --versions` verbatim, so the suffixed form is the NORMAL
    # content of the dominant source, and isVersionOutdated("0.20.3_1", ...)
    # returns null -- a permanent amber UNKNOWN, i.e. exactly the defect
    # XACA-1031-019 was filed to remove, surviving on the path that matters most.
    _AITEAMFORGE_VERSION="$(_normalize_aiteamforge_version "$v")"
}

# Build status payload
build_payload() {
    # Prime the live-process sweep in THIS scope so the two command
    # substitutions below share one `ps eww` pass instead of taking one each.
    # Both callees also call it themselves (they must stay correct under a
    # direct call), and the _LCARS_LIVE_MAP_BUILT guard makes those free.
    # This is what makes "sweep once per reporter run" literally true.
    _lcars_build_live_map

    local sessions=$(get_tmux_sessions)
    local lcars_services=$(get_lcars_services)
    local backup_status=$(get_backup_status)

    # Build backup_status JSON field (null if not available)
    local backup_json="null"
    if [ -n "$backup_status" ]; then
        backup_json="$backup_status"
    fi

    # Escape machine-level string fields sourced from config files / environment
    local machine_id_esc hostname_esc ip_esc os_esc timestamp_esc
    machine_id_esc=$(json_escape "$MACHINE_ID")
    hostname_esc=$(json_escape "$HOSTNAME")
    ip_esc=$(json_escape "$IP_ADDRESS")
    os_esc=$(json_escape "$OS_TYPE")
    timestamp_esc=$(json_escape "$TIMESTAMP")

    # Include dashboard_group if set (XACA-0024)
    local dashboard_group_json=""
    if [ -n "$DASHBOARD_GROUP" ]; then
        dashboard_group_json=",\"dashboard_group\":\"$(json_escape "$DASHBOARD_GROUP")\""
    fi

    # Include fleet_mode in payload (XACA-0024)
    local fleet_mode_json=""
    if [ -n "$FLEET_MODE" ]; then
        fleet_mode_json=",\"fleet_mode\":\"$(json_escape "$FLEET_MODE")\""
    fi

    # Machine-level "system" container (XACA-1031-001, contract amended
    # mid-implementation by the orchestrator to match the frozen convention
    # sibling ticket XACA-1091 established for this same block: an
    # uncollectable LEAF FIELD is OMITTED, never emitted as JSON null. The
    # "system" and "versions" containers themselves are still ALWAYS present.
    # "schema_version" is a sibling of "versions" inside "system" (not inside
    # "versions") -- added now, while there is exactly one consumer, because
    # retrofitting it after XACA-1091 adds ~15 more sibling keys is far more
    # expensive than reserving the slot today.
    _get_aiteamforge_version
    local versions_json="{}"
    if [ -n "$_AITEAMFORGE_VERSION" ]; then
        versions_json="{\"aiteamforge\":\"$(json_escape "$_AITEAMFORGE_VERSION")\"}"
    fi

    cat <<EOF
{
  "machine": {
    "machine_id": "$machine_id_esc",
    "hostname": "$hostname_esc",
    "ip": "$ip_esc",
    "os": "$os_esc",
    "timestamp": "$timestamp_esc"$dashboard_group_json$fleet_mode_json
  },
  "sessions": $sessions,
  "lcars_services": $lcars_services,
  "backup_status": $backup_json,
  "system": {
    "schema_version": 1,
    "versions": $versions_json
  }
}
EOF
}

# Send status to a single endpoint with retry logic
send_to_endpoint() {
    local payload="$1"
    local endpoint="$2"
    local auth_token="$3"
    local max_retries=3
    local retry_delay=5
    local attempt=1

    # Build auth header if token provided (XACA-0024)
    local auth_header=""
    if [ -n "$auth_token" ]; then
        auth_header="-H \"Authorization: Bearer $auth_token\""
    fi

    while [ $attempt -le $max_retries ]; do
        # Use curl to POST data with timeouts
        # --connect-timeout: max time to establish connection (10s)
        # --max-time: max time for entire operation (30s)
        if [ -n "$auth_token" ]; then
            response=$(curl -s -w "\n%{http_code}" \
                --connect-timeout 10 \
                --max-time 30 \
                -X POST \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $auth_token" \
                -d "$payload" \
                "$endpoint" 2>&1)
        else
            response=$(curl -s -w "\n%{http_code}" \
                --connect-timeout 10 \
                --max-time 30 \
                -X POST \
                -H "Content-Type: application/json" \
                -d "$payload" \
                "$endpoint" 2>&1)
        fi

        http_code=$(echo "$response" | tail -1)
        body=$(echo "$response" | sed '$d')

        if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
            echo "  ✓ Reported to $endpoint"
            return 0
        else
            if [ $attempt -lt $max_retries ]; then
                sleep $retry_delay
            fi
        fi

        attempt=$((attempt + 1))
    done

    echo "  ✗ Failed to report to $endpoint (HTTP $http_code)"
    return 1
}


# Send status to all configured endpoints (XACA-0024 hybrid support)
send_status() {
    local payload="$1"
    local success_count=0
    local fail_count=0

    echo "Fleet Mode: $FLEET_MODE"
    echo "Endpoints: ${#API_ENDPOINTS[@]}"

    for endpoint in "${API_ENDPOINTS[@]}"; do
        # XACA-0395: send the token to every endpoint, not just non-localhost
        # ones. fleet-monitor's auth gate (FLEET_AUTH_TOKEN) is per-server-
        # process, not per-deployment-topology — a local fleet-monitor instance
        # started with FLEET_AUTH_TOKEN set gates its mutating routes exactly
        # like the fly.dev instance does, so skipping the header for "localhost"
        # endpoints would 401 against a locally-gated server. Matches the
        # sibling reporters (kanban-reporter.sh, knowledge-reporter.sh), which
        # never special-case the endpoint host. Graceful degradation is
        # unaffected: an empty CENTRAL_AUTH_TOKEN still sends no header.
        local auth=""
        if [ -n "$CENTRAL_AUTH_TOKEN" ]; then
            auth="$CENTRAL_AUTH_TOKEN"
        fi

        if send_to_endpoint "$payload" "$endpoint" "$auth"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done

    echo ""
    if [ $success_count -gt 0 ]; then
        echo "✓ Status reported to $success_count endpoint(s)"
        return 0
    else
        echo "✗ Failed to report to any endpoint"
        return 1
    fi
}

# ============================================================================
# kb-msg cross-machine pull (XACA-0777)
# ============================================================================
# Pull any SEALED envelopes addressed to THIS machine off the fleet-monitor
# /api/msg relay, open them locally with this machine's private key, and ingest
# the decrypted records into the local kb-msg inbox — the SAME inbox a Tier-1
# (same-machine) send writes to, so kb-msg inbox/read are identical regardless
# of origin. Best-effort: this NEVER fails the status report, and (XACA-0777-017
# review) must be a silent, zero-cost no-op on any box that hasn't been set up
# for kb-msg — no error, no output, no node/libsodium startup, no network call.

# Bash re-implementation of vault-keygen.js's defaultMachineSlug(): lowercase
# hostname, strip .local / domain, non-alnum -> dash, trim dashes, prefix "m-"
# if it doesn't start with a letter. Used ONLY for the cheap pre-check below —
# msg-client.js is the source of truth for the actual slug at send/pull time.
_msg_default_machine_slug() {
    local raw slug
    raw=$(hostname 2>/dev/null | tr '[:upper:]' '[:lower:]')
    slug=$(printf '%s' "$raw" \
        | sed -E 's/\.local$//' \
        | sed -E 's/\..*$//' \
        | sed -E 's/[^a-z0-9]+/-/g' \
        | sed -E 's/^-+//' \
        | sed -E 's/-+$//')
    if [ -z "$slug" ] || ! printf '%s' "$slug" | grep -qE '^[a-z]'; then
        slug=$(printf '%s' "m-${slug}" | sed -E 's/-+$//')
    fi
    printf '%s' "${slug:0:64}"
}

# Does this machine have a vault private key yet (Tier 2 prerequisite)?
# Mirrors vault-keygen.js's two storage backends: macOS Keychain
# (service com.aiteamforge.vault) or the ~/.aiteamforge/vault/<slug>.key
# file fallback. No key => this box never ran vault-keygen => skip Tier 2
# entirely, silently (most boxes, most of the time).
#
# XACA-1090: this predicate is PURELY LOCAL. It reads the Keychain and one file
# path and NEVER contacts the server, so a false answer here says nothing
# whatsoever about registration state on the relay. That distinction is the
# whole ticket — see the guard-2 comment in pull_messages().
#
# It also publishes WHERE it looked, in MSG_VAULT_KEY_LOOKED_IN. The caller has
# to describe the search in its skip record, and having the caller re-derive
# that list would put two places in charge of one fact — the sibling-heuristic
# drift that this tree has already been bitten by. The description is built by
# the code that actually performs the lookups, so the two cannot disagree.
#
# NOTE: tests/bats/kb-msg-pull-status.bats extracts this function with
# `awk '/^_msg_has_vault_key\(\)/,/^}/'`. Keep the opening line and the closing
# brace at column 0 or that extraction silently yields a partial function.
_msg_has_vault_key() {
    local slug="$1"
    MSG_VAULT_KEY_LOOKED_IN=""
    [ -n "$slug" ] || return 1
    if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
        MSG_VAULT_KEY_LOOKED_IN="macOS keychain service com.aiteamforge.vault, account '$slug'"
        security find-generic-password -s com.aiteamforge.vault -a "$slug" >/dev/null 2>&1 && return 0
    fi
    if [ -n "$MSG_VAULT_KEY_LOOKED_IN" ]; then
        MSG_VAULT_KEY_LOOKED_IN="$MSG_VAULT_KEY_LOOKED_IN; and $HOME/.aiteamforge/vault/${slug}.key"
    else
        MSG_VAULT_KEY_LOOKED_IN="$HOME/.aiteamforge/vault/${slug}.key"
    fi
    [ -f "$HOME/.aiteamforge/vault/${slug}.key" ] && return 0
    return 1
}

pull_messages() {
    local dir="${AITEAMFORGE_DIR:-$HOME/dev-team}"

    # msg-client.sh ships as a SIBLING of THIS script in both layouts:
    #   dev:      fleet-monitor/client/{fleet-reporter.sh,msg-client.sh}
    #   consumer: ~/aiteamforge/scripts/{fleet-reporter.sh,msg-client.sh}
    #             (tap-mirrored flattened into share/scripts/, same pattern
    #              fleet-reporter.sh itself already uses — see sync-tap.sh)
    # Resolving relative to this script's OWN location (not AITEAMFORGE_DIR)
    # keeps this correct in both layouts without a separate mapping.
    local reporter_dir
    reporter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local client="$reporter_dir/msg-client.sh"
    local store="$dir/kanban-hooks/msg-store.py"

    # ── Skip reasons are RECORDED, not swallowed (XACA-0885-003) ─────────────
    # Every guard below used to `return 0` without a word. That is the wrong
    # asymmetry: the SEND side errors loudly and fail-closed, while the RECEIVE
    # side went deaf in total silence. An un-provisioned box therefore never
    # learned it was unreachable, and — the part that actually cost us — an
    # empty inbox is indistinguishable from "nobody wrote to me". Mail sat
    # unread for 32 days on this machine while every side of the system
    # reported success.
    #
    # The guards still short-circuit exactly as before, and still BEFORE any
    # node/libsodium startup or network round-trip. What changes is that the
    # reason is written to a state file the doctor can read. Nothing is printed
    # on the normal path: this runs every reporter cycle, and a recurring
    # console warning would be tuned out within a day — which is how the
    # original silence was rationalised in the first place.
    _msg_record_skip() {
        local reason="$1"
        local dir="$HOME/.aiteamforge/run"
        mkdir -p "$dir" 2>/dev/null || return 0
        printf '%s\n' "$reason" > "$dir/kb-msg-pull-status" 2>/dev/null || true
    }

    # Guard 1: msg-client.js/.sh not shipped to this box yet (older tap install,
    # or dev checkout predating XACA-0777).
    [ -x "$client" ] || { _msg_record_skip "no-client: $client is missing or not executable"; return 0; }
    [ -f "$store" ]  || { _msg_record_skip "no-store: $store is missing"; return 0; }
    command -v python3 >/dev/null 2>&1 || { _msg_record_skip "no-python3"; return 0; }
    command -v node    >/dev/null 2>&1 || { _msg_record_skip "no-node"; return 0; }

    # Guard 2: no vault private key VISIBLE TO THIS PROCESS.
    #
    # ── XACA-1090: this record states an observation, not a diagnosis ────────
    # The reason recorded here used to read "nothing registered for machine
    # '<slug>' — run kb-msg-provision". Both halves of that were wrong.
    #
    # "nothing registered" overstated the evidence. _msg_has_vault_key is purely
    # local: it reads the Keychain and one file path and never contacts the
    # relay, so it cannot know what is or is not registered anywhere.
    #
    # "run kb-msg-provision" was an unrunnable instruction. MEASURED on
    # darren-m3pro 2026-09-04: kb-msg-provision exits 0, leaves the routing map
    # byte-identical, and the reason text is unchanged afterwards — because
    # nothing was missing for it to create. An operator following the
    # instruction loops forever and concludes they are doing it wrong.
    #
    # The actual cause, measured the same day: `security find-generic-password`
    # for this slug SUCCEEDS from an interactive shell and from `env -i`, but
    # under cron exits 44 — "SecKeychainSearchCopyNext: The specified item could
    # not be found in the keychain". Cron has no user security session, so
    # login.keychain-db is not in its keychain search list. The reporter is
    # scheduled from cron on that box. The key was never absent; it was
    # invisible to this process.
    #
    # Crucially, THIS CODE CANNOT TELL THOSE APART. The predicate returns the
    # same value for "absent" and for "present but invisible to me", so any
    # remedy named here would be a guess. It records what it checked and what it
    # did not find, and stops. `kb-msg doctor` re-runs the identical predicate
    # interactively and reports the DIFFERENCE between the two answers, which is
    # the only place that comparison can actually be made.
    #
    # The `no-vault-key:` prefix is machine-readable and load-bearing — the
    # doctor branches on it and the bats suite matches it. Reword the prose
    # freely; do not change the prefix.
    local machine_slug
    machine_slug=$(_msg_default_machine_slug)
    _msg_has_vault_key "$machine_slug" || {
        _msg_record_skip "no-vault-key: no vault private key for machine '$machine_slug' visible to this process (checked: ${MSG_VAULT_KEY_LOOKED_IN:-unknown locations})"
        return 0
    }

    # Derive the relay base URL from the configured central API endpoint by
    # stripping the trailing /api/... path. Skip when there is no central server.
    local base=""
    if [ -n "${CENTRAL_API:-}" ]; then
        base="${CENTRAL_API%/api/*}"
    fi
    [ -n "$base" ] || { _msg_record_skip "no-relay: CENTRAL_API is unset, so there is no server to pull from"; return 0; }

    # msg-client.js reads FLEET_AUTH_TOKEN from env or fleet-config for the
    # Bearer header; pass the central token through explicitly. Both stderr and
    # exit code are swallowed — a transient relay/decrypt failure must never
    # break the reporter loop for the status report that already succeeded.
    local decrypted
    decrypted=$(FLEET_MONITOR_URL="$base" FLEET_AUTH_TOKEN="${CENTRAL_AUTH_TOKEN:-}" \
        bash "$client" pull --server "$base" 2>/dev/null || true)

    # Record the reached-the-relay state on EVERY cycle that gets this far, not
    # just the ones that found mail. A status file that is only written on the
    # skip paths is worse than none: the last skip reason would outlive the
    # condition that caused it, and the doctor would keep reporting a problem
    # that was fixed weeks ago. "ok" here means the guards passed and the pull
    # was attempted — deliberately NOT "mail arrived", which is not a health
    # signal (an empty inbox is the normal case).
    _msg_record_skip "ok: relay reachable, pull attempted at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if [ -n "$decrypted" ]; then
        printf '%s\n' "$decrypted" | python3 "$store" ingest >/dev/null 2>&1 || true
        echo "  ✓ Pulled + ingested cross-machine kb-msg mail"
    fi
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    echo "=== Fleet Status Reporter ==="
    echo "Machine: $HOSTNAME ($IP_ADDRESS)"
    echo "Timestamp: $TIMESTAMP"
    echo ""

    # Build payload
    echo "Collecting tmux session data..."
    payload=$(build_payload)

    # Count sessions.
    # XACA-0782: the trailing `|| true` is REQUIRED, not redundant. Under
    # `set -euo pipefail` (top of file), an idle machine with ZERO tmux sessions
    # yields a payload with no `"name":` occurrences, so `grep -o` exits 1;
    # pipefail propagates that and `set -e` aborts the whole script HERE — before
    # send_status ever runs — so idle machines could never report. `|| true`
    # keeps the (correct, 0) count without letting grep's no-match abort the run.
    session_count=$(echo "$payload" | grep -o '"name":' | wc -l | tr -d ' ') || true
    echo "Found $session_count tmux sessions"
    echo ""

    # Optionally show payload for debugging
    if [ "${FLEET_DEBUG:-0}" = "1" ]; then
        echo "Payload:"
        echo "$payload" | jq '.' 2>/dev/null || echo "$payload"
        echo ""
    fi

    # Send to server
    echo "Reporting to $API_ENDPOINT..."
    if send_status "$payload"; then
        echo ""
        echo "Report complete."
    else
        echo ""
        echo "Report failed. Check API_ENDPOINT configuration."
        # Still attempt a mail pull below? No — if the server is unreachable the
        # pull will fail too. Exit as before.
        exit 1
    fi

    # Pull cross-machine kb-msg mail for this machine (best-effort; XACA-0777).
    echo ""
    echo "Checking kb-msg relay for cross-machine mail..."
    pull_messages || true
}

# Run main function
main "$@"
