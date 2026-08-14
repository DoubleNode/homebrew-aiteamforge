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

# Get LCARS port for a session (if available)
# Looks for port file at ~/dev-team/lcars-ports/{session_name}.port
get_lcars_port() {
    local session_name="$1"
    local port_file="$LCARS_PORTS_DIR/${session_name}.port"

    if [ -f "$port_file" ]; then
        cat "$port_file"
    else
        echo ""
    fi
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

# Build status payload
build_payload() {
    local sessions=$(get_tmux_sessions)
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
  "backup_status": $backup_json
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
_msg_has_vault_key() {
    local slug="$1"
    [ -n "$slug" ] || return 1
    if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
        security find-generic-password -s com.aiteamforge.vault -a "$slug" >/dev/null 2>&1 && return 0
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

    # Guard 1: msg-client.js/.sh not shipped to this box yet (older tap install,
    # or dev checkout predating XACA-0777) — silent no-op.
    [ -x "$client" ] || return 0
    [ -f "$store" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    command -v node >/dev/null 2>&1 || return 0

    # Guard 2: no vault key configured on this machine — silent no-op, and
    # crucially BEFORE we pay for a node/libsodium startup + network round-trip
    # on every reporter cycle on a box that was never set up for kb-msg.
    local machine_slug
    machine_slug=$(_msg_default_machine_slug)
    _msg_has_vault_key "$machine_slug" || return 0

    # Derive the relay base URL from the configured central API endpoint by
    # stripping the trailing /api/... path. Skip when there is no central server.
    local base=""
    if [ -n "${CENTRAL_API:-}" ]; then
        base="${CENTRAL_API%/api/*}"
    fi
    [ -n "$base" ] || return 0

    # msg-client.js reads FLEET_AUTH_TOKEN from env or fleet-config for the
    # Bearer header; pass the central token through explicitly. Both stderr and
    # exit code are swallowed — a transient relay/decrypt failure must never
    # break the reporter loop for the status report that already succeeded.
    local decrypted
    decrypted=$(FLEET_MONITOR_URL="$base" FLEET_AUTH_TOKEN="${CENTRAL_AUTH_TOKEN:-}" \
        bash "$client" pull --server "$base" 2>/dev/null || true)
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
