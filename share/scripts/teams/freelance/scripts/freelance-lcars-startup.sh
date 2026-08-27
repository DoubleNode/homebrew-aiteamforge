#!/usr/bin/env bash
set +x
# Freelance LCARS Terminal Startup
# ENT Location: Enterprise NX-01 Computer Core
# Primary Function: Kanban Workflow Monitor
# Color Theme: ENT Orange/Beige

SESSION_TYPE="freelance"
SESSION_NAME="lcars"

# Use passed project parameters or fallback to defaults
if [ -n "$FREELANCE_PROJECT_DIR" ]; then
    SESSION_DIRECTORY="$FREELANCE_PROJECT_DIR"
    GROUPID="$FREELANCE_GROUPID"
    PROJECTID="$FREELANCE_PROJECTID"
    # Include project info in session name for uniqueness
    GROUP_LOWER=$(echo "$GROUPID" | tr '[:upper:]' '[:lower:]')
    PROJECT_LOWER=$(echo "$PROJECTID" | tr '[:upper:]' '[:lower:]')
    SESSION_PROJECT="${GROUP_LOWER}-${PROJECT_LOWER}"
    SESSION_CODE="${SESSION_TYPE}-${SESSION_PROJECT}-${SESSION_NAME}"
else
    SESSION_DIRECTORY="${AITEAMFORGE_DIR:-$HOME/dev-team}"
    SESSION_PROJECT="doublenode-workstats"
    SESSION_CODE="${SESSION_TYPE}-${SESSION_PROJECT}-${SESSION_NAME}"
fi

# Port for Freelance LCARS - use passed port or default
# Master script calculates unique port per project
LCARS_PORT="${FREELANCE_LCARS_PORT:-8505}"

# Port file directory for fleet-monitor integration
LCARS_PORTS_DIR="${AITEAMFORGE_DIR:-$HOME/dev-team}/lcars-ports"

# Use team-specific tmux socket if set, otherwise use default server
TMUX_CMD="tmux${TMUX_SOCKET:+ -L $TMUX_SOCKET}"

# Compute LCARS team name for data isolation (e.g., freelance-doublenode-starwords)
LCARS_TEAM_NAME="${SESSION_TYPE}-${SESSION_PROJECT}"

$TMUX_CMD has-session -t $SESSION_CODE 2>/dev/null
SESSION_EXISTS=$?

if [ $SESSION_EXISTS != 0 ]; then
    clear
    echo "  Initializing Freelance LCARS Display..."

    # Create session with single window
    $TMUX_CMD new-session -d -s $SESSION_CODE -n "lcars-monitor" -c "$SESSION_DIRECTORY"

    sleep 0.1

    # Configure tmux status line - ENT Orange/Beige theme
    $TMUX_CMD set -t $SESSION_CODE status-left-length 15
    $TMUX_CMD set -t $SESSION_CODE status-left "  LCARS "
    $TMUX_CMD set -t $SESSION_CODE @developer "Enterprise NX-01"
    $TMUX_CMD set -t $SESSION_CODE status-right "Kanban Monitor | Port $LCARS_PORT | 🖥  #h  "
    $TMUX_CMD set -t $SESSION_CODE status-style "bg=colour208,fg=colour232"
    $TMUX_CMD set -t $SESSION_CODE status-left-style "bg=colour166,fg=colour255,bold"
    $TMUX_CMD set -t $SESSION_CODE status-right-style "bg=colour208,fg=colour232"
    $TMUX_CMD set -t $SESSION_CODE window-status-style "bg=colour208,fg=colour232"
    $TMUX_CMD set -t $SESSION_CODE window-status-current-style "bg=colour166,fg=colour255,bold"
    $TMUX_CMD set -t $SESSION_CODE pane-border-style "fg=colour208"
    $TMUX_CMD set -t $SESSION_CODE pane-active-border-style "fg=colour166"

    # Start server ONLY if not launched by main startup script
    # (Main script handles server startup more reliably with wait-for-ready loop)
    # XACA-0988-001: append-only spawn-ledger instrumentation (site #3 of 3
    # known server.py spawn sites -- this tmux send-keys dispatch bypasses
    # start_lcars_server entirely: no per-port lock, no pkill, no log
    # rotation -- see scripts/lcars-spawn-ledger.sh's header). Fires on BOTH
    # branches below so "we decided NOT to spawn here" is just as
    # recoverable during an incident review as "we did". PASSIVE: never
    # blocks the real dispatch below it.
    # shellcheck disable=SC1090
    [ -f "$SESSION_DIRECTORY/scripts/lcars-spawn-ledger.sh" ] && source "$SESSION_DIRECTORY/scripts/lcars-spawn-ledger.sh"
    _XACA0988_LID=""
    if typeset -f _lcars_new_launch_id >/dev/null 2>&1; then
        _XACA0988_LID="$(_lcars_new_launch_id)"
    fi
    if typeset -f _lcars_ledger_write >/dev/null 2>&1; then
        if [ -z "$SKIP_SERVER_START" ]; then
            _lcars_ledger_write "team_startup_sendkeys" "spawn_attempt" "$_XACA0988_LID" \
                "$LCARS_TEAM_NAME" "$LCARS_PORT" "$SESSION_CODE" "" "$$" \
                "python3 server.py $LCARS_PORT" "$SKIP_SERVER_START" "$SKIP_ATTACH"
        else
            _lcars_ledger_write "team_startup_sendkeys" "spawn_skipped" "$_XACA0988_LID" \
                "$LCARS_TEAM_NAME" "$LCARS_PORT" "$SESSION_CODE" "" "$$" \
                "python3 server.py $LCARS_PORT" "$SKIP_SERVER_START" "$SKIP_ATTACH"
        fi
    fi

    if [ -z "$SKIP_SERVER_START" ]; then
        # Start the LCARS server with correct team settings
        $TMUX_CMD send-keys -t $SESSION_CODE:0 "cd ~/dev-team/lcars-ui && LCARS_TEAM=$LCARS_TEAM_NAME LCARS_SESSION_NAME=$SESSION_CODE python3 server.py $LCARS_PORT" C-m
    else
        # Show waiting message - main script will start server
        $TMUX_CMD send-keys -t $SESSION_CODE:0 "echo 'LCARS server will be started by main startup script...'" C-m
    fi

    # Write port file for fleet-monitor integration
    mkdir -p "$LCARS_PORTS_DIR"
    echo "$LCARS_PORT" > "$LCARS_PORTS_DIR/${SESSION_CODE}.port"
    echo "📡 Port file written: ${SESSION_CODE}.port -> $LCARS_PORT"

    sleep 1

    echo "  Freelance LCARS Display initialized"
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
