#!/bin/bash
set +x
# Finance Team LCARS Terminal Startup
# Location: Tower of Commerce - Central Monitoring
# Primary Function: Kanban Workflow Monitor
# Color Theme: Finance Gold/Black

SESSION_TYPE="finance"
SESSION_NAME="lcars"
SESSION_DIRECTORY="${AITEAMFORGE_DIR:-$HOME/dev-team}"

# Require environment variables from master startup script
if [ -z "$FINANCE_PROJECTID" ] || [ -z "$FINANCE_LCARS_PORT" ]; then
    echo "ERROR: This script must be launched via finance-startup.sh"
    echo "Usage: cd ~/dev-team/finance/scripts && ./finance-startup.sh <PROJECTID>"
    exit 1
fi

PROJECTID="$FINANCE_PROJECTID"
PROJECT_LOWER=$(echo "$PROJECTID" | tr '[:upper:]' '[:lower:]')
SESSION_CODE="finance-${PROJECT_LOWER}-${SESSION_NAME}"
LCARS_TEAM="finance-${PROJECT_LOWER}"
LCARS_PORT="$FINANCE_LCARS_PORT"

# Port file directory for fleet-monitor integration
LCARS_PORTS_DIR="${AITEAMFORGE_DIR:-$HOME/dev-team}/lcars-ports"

# Use team-specific tmux socket if set, otherwise use default server
TMUX_CMD="tmux${TMUX_SOCKET:+ -L $TMUX_SOCKET}"

$TMUX_CMD has-session -t $SESSION_CODE 2>/dev/null

if [ $? != 0 ]; then
    clear
    echo "  Initializing Finance LCARS Display..."

    # Create session with single window
    $TMUX_CMD new-session -d -s $SESSION_CODE -n "lcars-monitor" -c "$SESSION_DIRECTORY"

    sleep 0.1

    # Configure tmux status line - Finance theme (gold/black - representing latinum)
    $TMUX_CMD set -t $SESSION_CODE status-left-length 15
    $TMUX_CMD set -t $SESSION_CODE status-left "  LCARS "
    $TMUX_CMD set -t $SESSION_CODE @developer "Finance Team"
    $TMUX_CMD set -t $SESSION_CODE status-right "Kanban Monitor | Port $LCARS_PORT | 🖥  #h  "
    $TMUX_CMD set -t $SESSION_CODE status-style "bg=colour94,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE status-left-style "bg=colour220,fg=colour0,bold"
    $TMUX_CMD set -t $SESSION_CODE status-right-style "bg=colour94,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-style "bg=colour94,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-current-style "bg=colour220,fg=colour0,bold"
    $TMUX_CMD set -t $SESSION_CODE pane-border-style "fg=colour94"
    $TMUX_CMD set -t $SESSION_CODE pane-active-border-style "fg=colour220"

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

    echo "  Finance LCARS Display initialized"
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
