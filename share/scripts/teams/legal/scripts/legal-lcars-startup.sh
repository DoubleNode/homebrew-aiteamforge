#!/bin/bash
set +x
# Legal Team LCARS Terminal Startup
# Location: Court Administration Office
# Primary Function: Kanban Workflow Monitor
# Color Theme: Legal Blue/Gold

SESSION_TYPE="legal"
SESSION_NAME="lcars"
SESSION_DIRECTORY="/Users/darrenehlers/dev-team"

# Require environment variables from master startup script
if [ -z "$LEGAL_PROJECTID" ] || [ -z "$LEGAL_LCARS_PORT" ]; then
    echo "ERROR: This script must be launched via legal-startup.sh"
    echo "Usage: cd ~/dev-team/legal/scripts && ./legal-startup.sh <PROJECTID>"
    exit 1
fi

PROJECTID="$LEGAL_PROJECTID"
PROJECT_LOWER=$(echo "$PROJECTID" | tr '[:upper:]' '[:lower:]')
SESSION_CODE="legal-${PROJECT_LOWER}-${SESSION_NAME}"
LCARS_TEAM="legal-${PROJECT_LOWER}"
LCARS_PORT="$LEGAL_LCARS_PORT"

# Port file directory for fleet-monitor integration
LCARS_PORTS_DIR="$HOME/dev-team/lcars-ports"

# Use team-specific tmux socket if set, otherwise use default server
TMUX_CMD="tmux${TMUX_SOCKET:+ -L $TMUX_SOCKET}"

$TMUX_CMD has-session -t $SESSION_CODE 2>/dev/null

if [ $? != 0 ]; then
    clear
    echo "  Initializing Legal LCARS Display..."

    # Create session with single window
    $TMUX_CMD new-session -d -s $SESSION_CODE -n "lcars-monitor" -c "$SESSION_DIRECTORY"

    sleep 0.1

    # Configure tmux status line - Legal theme (blue/gold - representing justice)
    $TMUX_CMD set -t $SESSION_CODE status-left-length 15
    $TMUX_CMD set -t $SESSION_CODE status-left "  LCARS "
    $TMUX_CMD set -t $SESSION_CODE @developer "Legal Team"
    $TMUX_CMD set -t $SESSION_CODE status-right "Kanban Monitor | Port $LCARS_PORT | 🖥  #h  "
    $TMUX_CMD set -t $SESSION_CODE status-style "bg=colour25,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE status-left-style "bg=colour178,fg=colour232,bold"
    $TMUX_CMD set -t $SESSION_CODE status-right-style "bg=colour25,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-style "bg=colour25,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-current-style "bg=colour178,fg=colour232,bold"
    $TMUX_CMD set -t $SESSION_CODE pane-border-style "fg=colour25"
    $TMUX_CMD set -t $SESSION_CODE pane-active-border-style "fg=colour178"

    # Start server ONLY if not launched by main startup script
    # (Main script handles server startup more reliably with wait-for-ready loop)
    if [ -z "$SKIP_SERVER_START" ]; then
        $TMUX_CMD send-keys -t $SESSION_CODE:0 "cd $SESSION_DIRECTORY/lcars-ui && LCARS_TEAM=$LCARS_TEAM LCARS_SESSION_NAME=$SESSION_CODE python3 server.py $LCARS_PORT" C-m
    else
        $TMUX_CMD send-keys -t $SESSION_CODE:0 "echo 'LCARS server will be started by main startup script...'" C-m
    fi

    # Write port file for fleet-monitor integration
    mkdir -p "$LCARS_PORTS_DIR"
    echo "$LCARS_PORT" > "$LCARS_PORTS_DIR/${SESSION_CODE}.port"
    echo "  Port file written: ${SESSION_CODE}.port -> $LCARS_PORT"

    sleep 1

    echo "  Legal LCARS Display initialized"
    echo ""
    echo "--> LCARS server running on port $LCARS_PORT"
    echo "--> Open http://localhost:$LCARS_PORT in browser"
    echo "--> To attach to server: $TMUX_CMD attach -t $SESSION_CODE"
    echo ""
    sleep 1
fi

# Only attach if not being launched by master startup script
if [ -z "$SKIP_ATTACH" ]; then
    $TMUX_CMD attach-session -t $SESSION_CODE
fi
