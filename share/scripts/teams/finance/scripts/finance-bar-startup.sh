#!/usr/bin/env bash
set +x
# Finance Team Bar Terminal Startup
# Location: Tower of Commerce - Quark's Emporium
# Primary Developer: Quark (Budget & Expense Manager)
# Color Theme: Operations Orange (representing commerce and transactions)

SESSION_THEME="OPERATIONS"
SESSION_TYPE="finance"
SESSION_NAME="bar"
SESSION_DESCRIPTION="QUARK'S EMPORIUM - BUDGET & EXPENSE MANAGER"
SESSION_LOCATION="Finance: Tower of Commerce - Quark's Emporium"
SESSION_DEVELOPER="Quark"
SESSION_ROLE="Budget & Expense Manager & Head of Acquisitions"

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
setup_window() {
    sleep 0.1
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER "cd \"$SESSION_DIRECTORY\"" C-m
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". ~/.zshrc_${SESSION_TYPE}_${SESSION_NAME} 2>/dev/null || true" C-m
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". ~/dev-team/$SESSION_TYPE/scripts/$SESSION_TYPE-banner.sh \"$SESSION_THEME\" \"$SESSION_TYPE\" \"$SESSION_NAME\" \"$TERMINAL_NUMBER\" \"$TERMINAL_NAME\" \"$SESSION_DESCRIPTION\" \"$SESSION_LOCATION\" \"$SESSION_DEVELOPER\" \"$SESSION_ROLE\" \"$TERMINAL_DESCRIPTION\" \"$SESSION_CODE\"" C-m
}


$TMUX_CMD has-session -t $SESSION_CODE

if [ $? != 0 ]; then
    clear
    echo "  Initializing Finance Bar Terminal..."

    for i in {0..3}; do
        TERMINAL_NUMBER=$i
        case $i in
            0) TERMINAL_NAME="bar-cmd"; TERMINAL_DESCRIPTION="Emporium Command Center" ;;
            1) TERMINAL_NAME="expenses"; TERMINAL_DESCRIPTION="Expense Tracking & Cost Management" ;;
            2) TERMINAL_NAME="budget"; TERMINAL_DESCRIPTION="Budget Analysis & Allocation Review" ;;
            3) TERMINAL_NAME="deals"; TERMINAL_DESCRIPTION="Deal Hunting & Opportunity Scouting" ;;
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

    # Configure tmux status line - Operations Orange theme (commerce and transactions)
    $TMUX_CMD set -t $SESSION_CODE status-left-length 15
    $TMUX_CMD set -t $SESSION_CODE status-left "  $SESSION_NAME "
    $TMUX_CMD set -t $SESSION_CODE @developer "$SESSION_DEVELOPER"
    $TMUX_CMD set -t $SESSION_CODE @claude_agent "quark-fin"
    $TMUX_CMD set -t $SESSION_CODE status-right " #{@claude_agent} | 🖥  #h  "
    $TMUX_CMD set -t $SESSION_CODE status-style "bg=colour130,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE status-left-style "bg=colour208,fg=colour0,bold"
    $TMUX_CMD set -t $SESSION_CODE status-right-style "bg=colour130,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-style "bg=colour130,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-current-style "bg=colour208,fg=colour0,bold"
    $TMUX_CMD set -t $SESSION_CODE pane-border-style "fg=colour130"
    $TMUX_CMD set -t $SESSION_CODE pane-active-border-style "fg=colour208"

    sleep 0.5
    $TMUX_CMD select-window -t $SESSION_CODE:0

    echo "  Finance Bar Terminal initialized"
    echo ""
    echo "--> 4 commerce stations active"
    echo "--> Quark reporting for business"
    echo ""
    sleep 1
fi

# Only attach if not being launched by master startup script
if [ -z "$SKIP_ATTACH" ]; then
    $TMUX_CMD attach-session -t $SESSION_CODE
fi
