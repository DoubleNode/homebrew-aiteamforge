#!/usr/bin/env bash
set +x
# Medical Team Neurology Terminal Startup
# Location: Princeton-Plainsboro Teaching Hospital - Neurology Department
# Primary Developer: Dr. Eric Foreman (Lead Refactoring Developer)
# Color Theme: Operations Gold (representing systematic improvement)

SESSION_THEME="OPERATIONS"
SESSION_TYPE="medical"
SESSION_NAME="neurology"
SESSION_DESCRIPTION="NEUROLOGY - LEAD REFACTORING DEVELOPER"
SESSION_LOCATION="Medical: Neurology Department"
SESSION_DEVELOPER="Dr. Eric Foreman"
SESSION_ROLE="Lead Refactoring Developer & Code Quality Specialist"

# Require environment variables from master startup script
if [ -z "$MEDICAL_PROJECTID" ] || [ -z "$MEDICAL_PROJECT_DIR" ]; then
    echo "ERROR: This script must be launched via medical-startup.sh"
    echo "Usage: cd ~/dev-team/medical/scripts && ./medical-startup.sh <PROJECTID>"
    exit 1
fi

PROJECTID="$MEDICAL_PROJECTID"
SESSION_DIRECTORY="$MEDICAL_PROJECT_DIR"
PROJECT_LOWER=$(echo "$PROJECTID" | tr '[:upper:]' '[:lower:]')
SESSION_CODE="medical-${PROJECT_LOWER}-${SESSION_NAME}"

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
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". ~/.zshrc_${SESSION_TYPE}_${SESSION_NAME}" C-m
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". $KANBAN_HELPERS" C-m
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". ~/dev-team/$SESSION_TYPE/scripts/$SESSION_TYPE-banner.sh \"$SESSION_THEME\" \"$SESSION_TYPE\" \"$SESSION_NAME\" \"$TERMINAL_NUMBER\" \"$TERMINAL_NAME\" \"$SESSION_DESCRIPTION\" \"$SESSION_LOCATION\" \"$SESSION_DEVELOPER\" \"$SESSION_ROLE\" \"$TERMINAL_DESCRIPTION\" \"$SESSION_CODE\"" C-m
}


$TMUX_CMD has-session -t $SESSION_CODE

if [ $? != 0 ]; then
    clear
    echo "  Initializing Medical Neurology Terminal..."

    for i in {0..3}; do
        TERMINAL_NUMBER=$i
        case $i in
            0) TERMINAL_NAME="neurology-cmd"; TERMINAL_DESCRIPTION="Neurology Command Center" ;;
            1) TERMINAL_NAME="code-scan"; TERMINAL_DESCRIPTION="Code Analysis & Scanning" ;;
            2) TERMINAL_NAME="refactor"; TERMINAL_DESCRIPTION="Refactoring & Code Improvement" ;;
            3) TERMINAL_NAME="optimization"; TERMINAL_DESCRIPTION="Performance Optimization" ;;
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

    # Configure tmux status line - Operations Gold theme (systematic improvement)
    $TMUX_CMD set -t $SESSION_CODE status-left-length 15
    $TMUX_CMD set -t $SESSION_CODE status-left "  $SESSION_NAME "
    $TMUX_CMD set -t $SESSION_CODE @developer "$SESSION_DEVELOPER"
    $TMUX_CMD set -t $SESSION_CODE @claude_agent "foreman"
    $TMUX_CMD set -t $SESSION_CODE status-right " #{@claude_agent} | 🖥  #h  "
    $TMUX_CMD set -t $SESSION_CODE status-style "bg=colour25,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE status-left-style "bg=colour178,fg=colour232,bold"
    $TMUX_CMD set -t $SESSION_CODE status-right-style "bg=colour25,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-style "bg=colour25,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-current-style "bg=colour178,fg=colour232,bold"
    $TMUX_CMD set -t $SESSION_CODE pane-border-style "fg=colour25"
    $TMUX_CMD set -t $SESSION_CODE pane-active-border-style "fg=colour178"

    sleep 0.5
    $TMUX_CMD select-window -t $SESSION_CODE:0

    echo "  Medical Neurology Terminal initialized"
    echo ""
    echo "--> 4 neurology stations active"
    echo "--> Dr. Foreman reporting for duty"
    echo ""
    sleep 1
fi

# Only attach if not being launched by master startup script
if [ -z "$SKIP_ATTACH" ]; then
    $TMUX_CMD attach-session -t $SESSION_CODE
fi
