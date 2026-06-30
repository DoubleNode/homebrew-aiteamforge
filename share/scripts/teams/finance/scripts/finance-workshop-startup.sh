#!/usr/bin/env bash
set +x
# Finance Team Workshop Terminal Startup
# Location: Tower of Commerce - Engineering Workshop
# Primary Developer: Rom (Finance Automation Engineer)
# Color Theme: Sciences Green (representing data and automation)

SESSION_THEME="SCIENCES"
SESSION_TYPE="finance"
SESSION_NAME="workshop"
SESSION_DESCRIPTION="ENGINEERING WORKSHOP - FINANCE AUTOMATION ENGINEER"
SESSION_LOCATION="Finance: Tower of Commerce - Engineering Workshop"
SESSION_DEVELOPER="Rom"
SESSION_ROLE="Finance Automation Engineer & Tool Builder"

# Require environment variables from master startup script
if [ -z "$FINANCE_PROJECTID" ] || [ -z "$FINANCE_PROJECT_DIR" ]; then
    echo "ERROR: This script must be launched via finance-startup.sh"
    echo "Usage: cd ~/dev-team/finance/scripts && ./finance-startup.sh <PROJECTID>"
    exit 1
fi

PROJECTID="$FINANCE_PROJECTID"
SESSION_DIRECTORY="$FINANCE_PROJECT_DIR"
PROJECT_LOWER=$(echo "$PROJECTID" | tr '[:upper:]' '[:lower:]')
SESSION_CODE="finance-${PROJECT_LOWER}-${SESSION_NAME}"

# Use team-specific tmux socket if set, otherwise use default server
TMUX_CMD="tmux${TMUX_SOCKET:+ -L $TMUX_SOCKET}"

# ============================================================================
# Function: setup_window
# Executes the common setup commands for each tmux window
# ============================================================================
KANBAN_HELPERS="$HOME/dev-team/kanban-helpers.sh"

setup_window() {
    sleep 0.1
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER "cd \"$SESSION_DIRECTORY\"" C-m
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". ~/.zshrc_${SESSION_TYPE}_${SESSION_NAME} 2>/dev/null || true" C-m
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". $KANBAN_HELPERS" C-m
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". ~/dev-team/$SESSION_TYPE/scripts/$SESSION_TYPE-banner.sh \"$SESSION_THEME\" \"$SESSION_TYPE\" \"$SESSION_NAME\" \"$TERMINAL_NUMBER\" \"$TERMINAL_NAME\" \"$SESSION_DESCRIPTION\" \"$SESSION_LOCATION\" \"$SESSION_DEVELOPER\" \"$SESSION_ROLE\" \"$TERMINAL_DESCRIPTION\" \"$SESSION_CODE\"" C-m
}


$TMUX_CMD has-session -t $SESSION_CODE

if [ $? != 0 ]; then
    clear
    echo "  Initializing Finance Workshop Terminal..."

    for i in {0..3}; do
        TERMINAL_NUMBER=$i
        case $i in
            0) TERMINAL_NAME="workshop-cmd"; TERMINAL_DESCRIPTION="Workshop Command Center" ;;
            1) TERMINAL_NAME="scripting"; TERMINAL_DESCRIPTION="Script Development & Automation Building" ;;
            2) TERMINAL_NAME="tools"; TERMINAL_DESCRIPTION="Tool Building & Integration Testing" ;;
            3) TERMINAL_NAME="data"; TERMINAL_DESCRIPTION="Data Processing & Pipeline Management" ;;
        esac

        echo -n "- Connecting to $TERMINAL_DESCRIPTION..."
        if [ $i -eq 0 ]; then
            $TMUX_CMD new-session -d -s $SESSION_CODE -n $TERMINAL_NAME -c "$SESSION_DIRECTORY"
        else
            $TMUX_CMD new-window -t $SESSION_CODE:$TERMINAL_NUMBER -n $TERMINAL_NAME
        fi
        setup_window
        sleep 0.2
        echo "CONNECTED"
    done

    # Configure tmux status line - Sciences Green theme (data and automation)
    $TMUX_CMD set -t $SESSION_CODE status-left-length 15
    $TMUX_CMD set -t $SESSION_CODE status-left "  $SESSION_NAME "
    $TMUX_CMD set -t $SESSION_CODE @developer "$SESSION_DEVELOPER"
    $TMUX_CMD set -t $SESSION_CODE @claude_agent "rom"
    $TMUX_CMD set -t $SESSION_CODE status-right " #{@claude_agent} | 🖥  #h  "
    $TMUX_CMD set -t $SESSION_CODE status-style "bg=colour22,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE status-left-style "bg=colour34,fg=colour255,bold"
    $TMUX_CMD set -t $SESSION_CODE status-right-style "bg=colour22,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-style "bg=colour22,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-current-style "bg=colour34,fg=colour255,bold"
    $TMUX_CMD set -t $SESSION_CODE pane-border-style "fg=colour22"
    $TMUX_CMD set -t $SESSION_CODE pane-active-border-style "fg=colour34"

    sleep 0.5
    $TMUX_CMD select-window -t $SESSION_CODE:0

    echo "  Finance Workshop Terminal initialized"
    echo ""
    echo "--> 4 automation stations active"
    echo "--> Rom reporting for engineering"
    echo ""
    sleep 1
fi

# Only attach if not being launched by master startup script
if [ -z "$SKIP_ATTACH" ]; then
    $TMUX_CMD attach-session -t $SESSION_CODE
fi
