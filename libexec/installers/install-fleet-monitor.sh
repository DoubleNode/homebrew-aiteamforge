#!/bin/bash
# Fleet Monitor Installer
# Sets up cross-machine monitoring, agent status display, and Tailscale networking

set -euo pipefail

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

#──────────────────────────────────────────────────────────────────────────────
# Constants
#──────────────────────────────────────────────────────────────────────────────

FLEET_MONITOR_PORT="${FLEET_MONITOR_PORT:-3000}"
FLEET_MODE="${FLEET_MODE:-standalone}"  # standalone | client | server
TAILSCALE_FUNNEL_PORT="${TAILSCALE_FUNNEL_PORT:-443}"

#──────────────────────────────────────────────────────────────────────────────
# Detection Functions
#──────────────────────────────────────────────────────────────────────────────

# Check if Tailscale is installed
has_tailscale() {
    command -v tailscale &>/dev/null || [ -x "/opt/homebrew/bin/tailscale" ]
}

# Check if iTerm2 is available
has_iterm2() {
    [ -d "/Applications/iTerm.app" ]
}

# Check if Fleet Monitor is already running
is_fleet_monitor_running() {
    pgrep -f "fleet-monitor/server/server.js" &>/dev/null
}

# Generate a unique machine ID (UUID)
generate_machine_id() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        # Fallback: use hostname + timestamp hash
        echo "$(hostname)-$(date +%s)" | md5sum | cut -d' ' -f1
    fi
}

# Get Tailscale IP address
get_tailscale_ip() {
    if has_tailscale; then
        local ts_path
        if [ -x "/opt/homebrew/bin/tailscale" ]; then
            ts_path="/opt/homebrew/bin/tailscale"
        else
            ts_path="tailscale"
        fi

        $ts_path ip -4 2>/dev/null | head -n1 || echo ""
    else
        echo ""
    fi
}

# Get Tailscale hostname
get_tailscale_hostname() {
    if has_tailscale; then
        local ts_path
        if [ -x "/opt/homebrew/bin/tailscale" ]; then
            ts_path="/opt/homebrew/bin/tailscale"
        else
            ts_path="tailscale"
        fi

        $ts_path status --json 2>/dev/null | grep -o '"HostName":"[^"]*"' | cut -d'"' -f4 || echo ""
    else
        echo ""
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# Configuration Functions
#──────────────────────────────────────────────────────────────────────────────

# Create Fleet Monitor configuration
create_fleet_config() {
    local config_file="$AITEAMFORGE_DIR/config/fleet-config.json"
    local machine_id="${1:-}"
    local nickname="${2:-}"

    if [ -z "$machine_id" ]; then
        machine_id=$(generate_machine_id)
    fi

    local hostname=$(hostname -s)
    local tailscale_enabled="false"
    local tailscale_ip=""
    local tailscale_hostname=""

    if has_tailscale; then
        tailscale_enabled="true"
        tailscale_ip=$(get_tailscale_ip)
        tailscale_hostname=$(get_tailscale_hostname)
    fi

    local iterm_integration="false"
    local show_agent_panels="false"
    if has_iterm2; then
        iterm_integration="true"
        show_agent_panels="true"
    fi

    local server_url="http://localhost:${FLEET_MONITOR_PORT}"
    if [ "$FLEET_MODE" = "client" ]; then
        # Use pre-configured URL from wizard, or prompt if running standalone
        if [ -n "${FLEET_SERVER_URL:-}" ]; then
            server_url="$FLEET_SERVER_URL"
        elif [ "${NON_INTERACTIVE:-}" != "true" ]; then
            read -p "Enter Fleet Monitor server URL (default: $server_url): " custom_url
            server_url="${custom_url:-$server_url}"
        fi
    fi

    # Create config from template or generate directly
    local config_template="$SCRIPT_DIR/../../share/templates/fleet-monitor/fleet-config.template.json"
    if [ -f "$config_template" ]; then
        sed \
            -e "s|{{FLEET_MODE}}|$FLEET_MODE|g" \
            -e "s|{{FLEET_SERVER_URL}}|$server_url|g" \
            -e "s|{{MACHINE_ID}}|$machine_id|g" \
            -e "s|{{HOSTNAME}}|$hostname|g" \
            -e "s|{{NICKNAME}}|${nickname:-}|g" \
            -e "s|{{TAILSCALE_ENABLED}}|$tailscale_enabled|g" \
            -e "s|{{LOCAL_PORT}}|$FLEET_MONITOR_PORT|g" \
            -e "s|{{PUBLIC_PORT}}|$TAILSCALE_FUNNEL_PORT|g" \
            -e "s|{{SHOW_AGENT_PANELS}}|$show_agent_panels|g" \
            -e "s|{{ITERM_INTEGRATION}}|$iterm_integration|g" \
            "$config_template" > "$config_file"
    else
        # Fallback: generate config directly
        cat > "$config_file" <<CFGEOF
{
  "mode": "$FLEET_MODE",
  "serverUrl": "$server_url",
  "machineId": "$machine_id",
  "hostname": "$hostname",
  "nickname": "${nickname:-}",
  "tailscale": { "enabled": $tailscale_enabled },
  "ports": { "local": $FLEET_MONITOR_PORT, "public": $TAILSCALE_FUNNEL_PORT },
  "display": { "showAgentPanels": $show_agent_panels, "itermIntegration": $iterm_integration }
}
CFGEOF
    fi

    success "Created Fleet Monitor configuration at $config_file"
    echo "$machine_id"
}

# Create machine identity file
create_machine_identity() {
    local machine_id="$1"
    local nickname="${2:-}"
    local identity_file="$AITEAMFORGE_DIR/config/machine-identity.json"

    local hostname=$(hostname -s)
    local local_ip=$(ipconfig getifaddr en0 2>/dev/null || echo "unknown")
    local tailscale_ip=$(get_tailscale_ip)
    local tailscale_hostname=$(get_tailscale_hostname)
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local can_host_server="true"
    if [ "$FLEET_MODE" = "client" ]; then
        can_host_server="false"
    fi

    local tailscale_enabled="false"
    if has_tailscale; then
        tailscale_enabled="true"
    fi

    local iterm_available="false"
    if has_iterm2; then
        iterm_available="true"
    fi

    # Create identity from template or generate directly
    local identity_template="$SCRIPT_DIR/../../share/templates/fleet-monitor/machine-identity.template.json"
    if [ -f "$identity_template" ]; then
        sed \
            -e "s|{{MACHINE_ID}}|$machine_id|g" \
            -e "s|{{HOSTNAME}}|$hostname|g" \
            -e "s|{{NICKNAME}}|${nickname:-}|g" \
            -e "s|{{TIMESTAMP}}|$timestamp|g" \
            -e "s|{{MACHINE_ROLE}}|${FLEET_MODE}|g" \
            -e "s|{{ORGANIZATION}}|starfleet|g" \
            -e "s|{{CAN_HOST_SERVER}}|$can_host_server|g" \
            -e "s|{{TAILSCALE_ENABLED}}|$tailscale_enabled|g" \
            -e "s|{{ITERM_AVAILABLE}}|$iterm_available|g" \
            -e "s|{{LOCAL_IP}}|$local_ip|g" \
            -e "s|{{TAILSCALE_IP}}|${tailscale_ip:-unknown}|g" \
            -e "s|{{TAILSCALE_HOSTNAME}}|${tailscale_hostname:-unknown}|g" \
            "$identity_template" > "$identity_file"
    else
        # Fallback: generate identity directly
        cat > "$identity_file" <<IDEOF
{
  "machineId": "$machine_id",
  "hostname": "$hostname",
  "nickname": "${nickname:-}",
  "registered": "$timestamp",
  "role": "$FLEET_MODE",
  "organization": "starfleet",
  "capabilities": { "canHostServer": $can_host_server, "tailscale": $tailscale_enabled, "iterm": $iterm_available },
  "network": { "localIp": "$local_ip", "tailscaleIp": "${tailscale_ip:-unknown}", "tailscaleHostname": "${tailscale_hostname:-unknown}" }
}
IDEOF
    fi

    success "Created machine identity at $identity_file"
}

#──────────────────────────────────────────────────────────────────────────────
# Installation Functions
#──────────────────────────────────────────────────────────────────────────────

# Install Fleet Monitor server
install_fleet_server() {
    local fleet_dir="$AITEAMFORGE_DIR/fleet-monitor"

    info "Installing Fleet Monitor server..."

    # Check if Fleet Monitor source exists in the package
    if [ ! -d "$SCRIPT_DIR/../../fleet-monitor" ]; then
        warning "Fleet Monitor source not found in package (skipping server install)"
        return 0
    fi

    # Copy Fleet Monitor files
    info "Copying Fleet Monitor files to $fleet_dir"
    cp -R "$SCRIPT_DIR/../../fleet-monitor" "$fleet_dir"

    # Install Node dependencies
    info "Installing Node.js dependencies (this may take a minute)..."
    (
        cd "$fleet_dir/server"
        npm install --production --silent
    ) || {
        error "Failed to install Fleet Monitor dependencies"
        return 1
    }

    success "Fleet Monitor server installed at $fleet_dir"
}

# Install Tailscale Funnel restore script and LaunchAgent
install_tailscale_funnel() {
    if ! has_tailscale; then
        info "Tailscale not installed, skipping Funnel setup"
        return 0
    fi

    info "Setting up Tailscale Funnel restore script..."

    local funnel_script="$AITEAMFORGE_DIR/tailscale-funnel-restore.sh"
    local ts_path="/opt/homebrew/bin/tailscale"

    # Get team ports for LCARS dashboards
    local team_routes=""
    # Use compgen to check if glob pattern matches any files
    if compgen -G "$AITEAMFORGE_DIR"/lcars-ports/*.port >/dev/null 2>&1; then
        for team_port_file in "$AITEAMFORGE_DIR"/lcars-ports/*.port; do
            if [ -f "$team_port_file" ]; then
                local team_name=$(basename "$team_port_file" .port)
                local port=$(cat "$team_port_file")
                local path="/${team_name}"
                team_routes+="$ts_path funnel --bg --yes --set-path $path http://localhost:$port\n"
                team_routes+="echo \"✓ Port ${TAILSCALE_FUNNEL_PORT}${path} configured\"\n\n"
            fi
        done
    fi

    # Create funnel restore script from template
    sed \
        -e "s|{{TAILSCALE_PATH}}|$ts_path|g" \
        -e "s|{{FUNNEL_PORT}}|$TAILSCALE_FUNNEL_PORT|g" \
        -e "s|{{TEAM_ROUTES}}|$team_routes|g" \
        "$SCRIPT_DIR/../../share/templates/fleet-monitor/tailscale-funnel.template.sh" \
        > "$funnel_script"

    chmod +x "$funnel_script"

    success "Tailscale Funnel restore script created at $funnel_script"

    # Install Funnel LaunchAgent to restore routes on system restart
    local launchagent_file="$HOME/Library/LaunchAgents/com.aiteamforge.tailscale-funnel.plist"

    info "Installing Tailscale Funnel LaunchAgent..."

    # Create LaunchAgent from template
    sed \
        -e "s|{{FUNNEL_SCRIPT_PATH}}|$funnel_script|g" \
        -e "s|{{LOG_DIR}}|$AITEAMFORGE_DIR/logs|g" \
        "$SCRIPT_DIR/../../share/templates/fleet-monitor/funnel-launchagent.template.plist" \
        > "$launchagent_file"

    # Load LaunchAgent
    if launchctl list | grep -q "com.aiteamforge.tailscale-funnel"; then
        info "Unloading existing Tailscale Funnel LaunchAgent..."
        launchctl unload "$launchagent_file" 2>/dev/null || true
    fi

    info "Loading Tailscale Funnel LaunchAgent..."
    launchctl load "$launchagent_file"

    success "Tailscale Funnel LaunchAgent installed (will restore routes on restart)"
}

# Install Fleet Monitor LaunchAgent
install_fleet_launchagent() {
    local launchagent_file="$HOME/Library/LaunchAgents/com.aiteamforge.fleet-monitor.plist"
    local fleet_server_path="$AITEAMFORGE_DIR/fleet-monitor/server"
    local node_path

    # Find Node.js path
    if command -v node &>/dev/null; then
        node_path=$(command -v node)
    elif [ -x "/opt/homebrew/bin/node" ]; then
        node_path="/opt/homebrew/bin/node"
    else
        error "Node.js not found. Please install Node.js first."
        return 1
    fi

    info "Installing Fleet Monitor LaunchAgent..."

    # Create LaunchAgent from template
    sed \
        -e "s|{{NODE_PATH}}|$node_path|g" \
        -e "s|{{FLEET_SERVER_PATH}}|$fleet_server_path|g" \
        -e "s|{{LOG_DIR}}|$AITEAMFORGE_DIR/logs|g" \
        -e "s|{{HOMEBREW_PREFIX}}|/opt/homebrew|g" \
        -e "s|{{HOME_DIR}}|$HOME|g" \
        -e "s|{{FLEET_PORT}}|$FLEET_MONITOR_PORT|g" \
        "$SCRIPT_DIR/../../share/templates/fleet-monitor/fleet-launchagent.template.plist" \
        > "$launchagent_file"

    # Create logs directory
    mkdir -p "$AITEAMFORGE_DIR/logs"

    # Load LaunchAgent
    if launchctl list | grep -q "com.aiteamforge.fleet-monitor"; then
        info "Unloading existing Fleet Monitor LaunchAgent..."
        launchctl unload "$launchagent_file" 2>/dev/null || true
    fi

    info "Loading Fleet Monitor LaunchAgent..."
    launchctl load "$launchagent_file"

    # Wait a moment for service to start
    sleep 2

    if is_fleet_monitor_running; then
        success "Fleet Monitor LaunchAgent installed and running"
    else
        warning "Fleet Monitor LaunchAgent installed but service may not have started"
        info "Check logs at $AITEAMFORGE_DIR/logs/fleet-monitor.log"
    fi
}

# Install iTerm2 integration for agent panels
install_iterm_integration() {
    if ! has_iterm2; then
        info "iTerm2 not installed, skipping agent panel setup"
        return 0
    fi

    info "Setting up iTerm2 agent panel integration..."

    # Copy iTerm2 helper scripts
    local iterm_badge_helper="$AITEAMFORGE_DIR/iterm2_badge_helper.sh"
    local iterm_window_manager="$AITEAMFORGE_DIR/iterm2_window_manager.py"

    if [ -f "$SCRIPT_DIR/../../share/scripts/iterm2_badge_helper.sh" ]; then
        cp "$SCRIPT_DIR/../../share/scripts/iterm2_badge_helper.sh" "$iterm_badge_helper"
        chmod +x "$iterm_badge_helper"
    fi

    if [ -f "$SCRIPT_DIR/../../share/scripts/iterm2_window_manager.py" ]; then
        cp "$SCRIPT_DIR/../../share/scripts/iterm2_window_manager.py" "$iterm_window_manager"
        chmod +x "$iterm_window_manager"
    fi

    success "iTerm2 agent panel integration configured"
}

# Install fleet reporter client (status reporting script)
install_fleet_reporter() {
    local reporter_src="$SCRIPT_DIR/../../share/scripts/fleet-reporter.sh"
    local reporter_dest="$AITEAMFORGE_DIR/fleet-monitor/client/fleet-reporter.sh"

    if [ ! -f "$reporter_src" ]; then
        warning "Fleet reporter script not found (skipping status reporting)"
        return 0
    fi

    info "Installing fleet reporter client..."

    # Create target directory
    mkdir -p "$AITEAMFORGE_DIR/fleet-monitor/client"

    # Copy fleet reporter script
    cp "$reporter_src" "$reporter_dest"
    chmod +x "$reporter_dest"

    success "Fleet reporter installed at $reporter_dest"
}

# Create fleet reporter config at the path the reporter expects ($HOME/.aiteamforge/)
create_fleet_reporter_config() {
    local server_url="${1:-http://localhost:${FLEET_MONITOR_PORT}}"

    info "Creating fleet reporter configuration..."

    # The reporter reads from $HOME/.aiteamforge/fleet-config.json
    mkdir -p "$HOME/.aiteamforge"

    local reporter_config_template="$SCRIPT_DIR/../../share/templates/fleet-monitor/fleet-reporter-config.template.json"

    # Determine central vs local settings based on mode
    local central_enabled="false"
    local central_api=""
    local local_enabled="false"
    local local_port="$FLEET_MONITOR_PORT"

    case "$FLEET_MODE" in
        client)
            central_enabled="true"
            central_api="${server_url}/api/status"
            local_enabled="false"
            ;;
        standalone)
            central_enabled="false"
            central_api=""
            local_enabled="true"
            ;;
        server)
            central_enabled="false"
            central_api=""
            local_enabled="true"
            ;;
    esac

    if [ -f "$reporter_config_template" ]; then
        sed \
            -e "s|{{FLEET_MODE}}|$FLEET_MODE|g" \
            -e "s|{{CENTRAL_ENABLED}}|$central_enabled|g" \
            -e "s|{{CENTRAL_API_ENDPOINT}}|$central_api|g" \
            -e "s|{{LOCAL_ENABLED}}|$local_enabled|g" \
            -e "s|{{LOCAL_PORT}}|$local_port|g" \
            -e "s|{{DASHBOARD_GROUP}}||g" \
            "$reporter_config_template" > "$HOME/.aiteamforge/fleet-config.json"
    else
        # Fallback: generate config directly
        cat > "$HOME/.aiteamforge/fleet-config.json" <<RCEOF
{
  "mode": "$FLEET_MODE",
  "centralServer": {
    "enabled": $central_enabled,
    "apiEndpoint": "$central_api",
    "authToken": ""
  },
  "localServer": {
    "enabled": $local_enabled,
    "port": $local_port
  },
  "reporting": {
    "interval": 60
  },
  "dashboardGroup": ""
}
RCEOF
    fi

    success "Fleet reporter config created at $HOME/.aiteamforge/fleet-config.json"
}

# Install LaunchAgent for fleet reporter (periodic status reporting)
install_fleet_reporter_launchagent() {
    local reporter_script="$AITEAMFORGE_DIR/fleet-monitor/client/fleet-reporter.sh"
    local plist_template="$SCRIPT_DIR/../../share/templates/fleet-monitor/fleet-reporter-launchagent.template.plist"
    local plist_dest="$HOME/Library/LaunchAgents/com.aiteamforge.fleet-reporter.plist"

    if [ ! -f "$reporter_script" ]; then
        warning "Fleet reporter not installed, skipping LaunchAgent"
        return 0
    fi

    if [ ! -f "$plist_template" ]; then
        warning "Fleet reporter LaunchAgent template not found (skipping)"
        return 0
    fi

    info "Installing fleet reporter LaunchAgent..."

    # Create LaunchAgents directory if needed
    mkdir -p "$HOME/Library/LaunchAgents"

    # Create logs directory
    mkdir -p "$AITEAMFORGE_DIR/logs"

    # Substitute variables in template
    sed \
        -e "s|{{REPORTER_SCRIPT_PATH}}|$reporter_script|g" \
        -e "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g" \
        -e "s|{{USER_HOME}}|$HOME|g" \
        "$plist_template" > "$plist_dest"

    # Unload if already loaded (ignore errors)
    launchctl unload "$plist_dest" 2>/dev/null || true

    # Load the LaunchAgent
    if launchctl load "$plist_dest"; then
        success "Fleet reporter LaunchAgent installed and loaded"
        info "Status reports will be sent every 60 seconds"
    else
        warning "Failed to load fleet reporter LaunchAgent (may need manual activation)"
    fi
}

# Uninstall fleet reporter LaunchAgent
uninstall_fleet_reporter_launchagent() {
    local plist_file="$HOME/Library/LaunchAgents/com.aiteamforge.fleet-reporter.plist"

    if [ -f "$plist_file" ]; then
        info "Unloading fleet reporter LaunchAgent"
        launchctl unload "$plist_file" 2>/dev/null || true
        rm -f "$plist_file"
        success "Removed fleet reporter LaunchAgent"
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# Main Installation Function
#──────────────────────────────────────────────────────────────────────────────

install_fleet_monitor() {
    header "Fleet Monitor Setup"

    # Check if Fleet Monitor is desired
    if [ "${SKIP_FLEET_MONITOR:-}" = "true" ]; then
        info "Fleet Monitor installation skipped (SKIP_FLEET_MONITOR=true)"
        return 0
    fi

    # For non-interactive mode, skip if not explicitly enabled
    if [ "${NON_INTERACTIVE:-}" = "true" ] && [ "${INSTALL_FLEET_MONITOR:-}" != "true" ]; then
        info "Fleet Monitor installation skipped (non-interactive mode)"
        return 0
    fi

    # Interactive prompt
    if [ "${NON_INTERACTIVE:-}" != "true" ]; then
        echo ""
        echo "Fleet Monitor enables cross-machine monitoring of agent sessions,"
        echo "displays agent status panels, and provides network service discovery."
        echo ""
        echo "Features:"
        echo "  • Web-based LCARS dashboard for monitoring all machines"
        echo "  • Agent status display in iTerm2 terminals (if available)"
        echo "  • Tailscale networking for secure multi-machine access (if available)"
        echo "  • Real-time session tracking and uptime monitoring"
        echo ""

        read -p "Install Fleet Monitor? (y/n, default: n): " install_fleet
        if [[ ! "$install_fleet" =~ ^[Yy] ]]; then
            info "Skipping Fleet Monitor installation"
            return 0
        fi

        # Ask for Fleet mode
        echo ""
        echo "Fleet Monitor modes:"
        echo "  1) standalone - Run Fleet Monitor server on this machine (recommended for single machine)"
        echo "  2) server     - Run Fleet Monitor server, allow other machines to connect"
        echo "  3) client     - Connect to an existing Fleet Monitor server"
        echo ""
        read -p "Select mode (1-3, default: 1): " mode_choice

        case "$mode_choice" in
            2) FLEET_MODE="server" ;;
            3) FLEET_MODE="client" ;;
            *) FLEET_MODE="standalone" ;;
        esac

        # Ask for machine nickname
        read -p "Enter a nickname for this machine (optional, default: hostname): " machine_nickname
    fi

    # Create necessary directories
    mkdir -p "$AITEAMFORGE_DIR/config"
    mkdir -p "$AITEAMFORGE_DIR/logs"

    # Generate machine ID
    local machine_id=$(generate_machine_id)
    info "Machine ID: $machine_id"

    # Create configuration files (don't capture stdout — it contains colored status messages)
    create_fleet_config "$machine_id" "${machine_nickname:-}"
    create_machine_identity "$machine_id" "${machine_nickname:-}"

    # Install Fleet Monitor server (for standalone and server modes)
    if [ "$FLEET_MODE" != "client" ]; then
        install_fleet_server
        # Only install LaunchAgent if server was actually installed
        if [ -d "$AITEAMFORGE_DIR/fleet-monitor/server" ]; then
            install_fleet_launchagent
        fi
    fi

    # Install Tailscale integration (if available)
    if has_tailscale; then
        install_tailscale_funnel
    fi

    # Install iTerm2 integration (if available)
    install_iterm_integration

    # Install fleet reporter client (for ALL modes — sends status to server)
    install_fleet_reporter

    # Determine the server URL for the reporter config
    local server_url="http://localhost:${FLEET_MONITOR_PORT}"
    if [ "$FLEET_MODE" = "client" ]; then
        if [ -n "${FLEET_SERVER_URL:-}" ]; then
            server_url="$FLEET_SERVER_URL"
        fi
    fi

    # Create reporter config at the path fleet-reporter.sh expects
    create_fleet_reporter_config "$server_url"

    # Install reporter LaunchAgent (runs every 60 seconds)
    install_fleet_reporter_launchagent

    # Final success message
    echo ""
    success "Fleet Monitor installation complete!"
    echo ""

    if [ "$FLEET_MODE" != "client" ]; then
        local access_url="http://localhost:${FLEET_MONITOR_PORT}"

        if has_tailscale; then
            local ts_hostname=$(get_tailscale_hostname)
            if [ -n "$ts_hostname" ]; then
                access_url="https://${ts_hostname}"
            fi
        fi

        info "Fleet Monitor dashboard: $access_url"
        info "LCARS interface: $access_url/lcars"

        if has_tailscale; then
            echo ""
            info "Tailscale Funnel configured - dashboard is accessible from anywhere"
            info "Run 'tailscale funnel status' to see URLs"
        fi
    else
        info "Fleet Monitor client configured"
        info "This machine will report to the configured Fleet Monitor server"
    fi

    info "Fleet reporter: Sending status every 60 seconds"
    echo ""
}

# Uninstall function
uninstall_fleet_monitor() {
    header "Fleet Monitor Uninstall"

    # Stop and remove Fleet Monitor LaunchAgent
    local launchagent_file="$HOME/Library/LaunchAgents/com.aiteamforge.fleet-monitor.plist"
    if [ -f "$launchagent_file" ]; then
        info "Unloading Fleet Monitor LaunchAgent..."
        launchctl unload "$launchagent_file" 2>/dev/null || true
        rm "$launchagent_file"
    fi

    # Stop and remove Tailscale Funnel LaunchAgent
    local funnel_launchagent="$HOME/Library/LaunchAgents/com.aiteamforge.tailscale-funnel.plist"
    if [ -f "$funnel_launchagent" ]; then
        info "Unloading Tailscale Funnel LaunchAgent..."
        launchctl unload "$funnel_launchagent" 2>/dev/null || true
        rm "$funnel_launchagent"
    fi

    # Remove Fleet Monitor directory
    if [ -d "$AITEAMFORGE_DIR/fleet-monitor" ]; then
        info "Removing Fleet Monitor files..."
        rm -rf "$AITEAMFORGE_DIR/fleet-monitor"
    fi

    # Stop and remove Fleet Reporter LaunchAgent
    uninstall_fleet_reporter_launchagent

    # Remove configuration files
    rm -f "$AITEAMFORGE_DIR/config/fleet-config.json"
    rm -f "$AITEAMFORGE_DIR/config/machine-identity.json"
    rm -f "$AITEAMFORGE_DIR/tailscale-funnel-restore.sh"

    # Remove reporter config
    rm -f "$HOME/.aiteamforge/fleet-config.json"

    # Remove logs
    rm -f "$AITEAMFORGE_DIR/logs/fleet-monitor.log"
    rm -f "$AITEAMFORGE_DIR/logs/fleet-monitor.error.log"
    rm -f "$AITEAMFORGE_DIR/logs/fleet-reporter.log"
    rm -f "$AITEAMFORGE_DIR/logs/fleet-reporter.error.log"
    rm -f "$AITEAMFORGE_DIR/logs/tailscale-funnel.log"
    rm -f "$AITEAMFORGE_DIR/logs/tailscale-funnel.error.log"

    success "Fleet Monitor uninstalled"
}

# If script is run directly (not sourced), execute install
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    install_fleet_monitor
fi
