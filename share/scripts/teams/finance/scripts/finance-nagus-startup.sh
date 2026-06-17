#!/usr/bin/env bash
set +x
# Finance Team Nagus Terminal Startup
# Location: Tower of Commerce - Grand Nagus Suite
# Primary Developer: Grand Nagus Zek (Lead Financial Strategist)
# Color Theme: Command Gold (representing supreme financial authority)

SESSION_THEME="COMMAND"
SESSION_TYPE="finance"
SESSION_NAME="nagus"
SESSION_DESCRIPTION="GRAND NAGUS SUITE - LEAD FINANCIAL STRATEGIST"
SESSION_LOCATION="Finance: Tower of Commerce - Grand Nagus Suite"
SESSION_DEVELOPER="Grand Nagus Zek"
SESSION_ROLE="Lead Financial Strategist & Chief Profit Officer"

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
    echo "  Initializing Finance Nagus Terminal..."

    for i in {0..3}; do
        TERMINAL_NUMBER=$i
        case $i in
            0) TERMINAL_NAME="nagus-cmd"; TERMINAL_DESCRIPTION="Grand Nagus Command Center" ;;
            1) TERMINAL_NAME="strategy"; TERMINAL_DESCRIPTION="Strategy Planning & Portfolio Direction" ;;
            2) TERMINAL_NAME="portfolio"; TERMINAL_DESCRIPTION="Portfolio Review & Performance Analysis" ;;
            3) TERMINAL_NAME="reports"; TERMINAL_DESCRIPTION="Financial Reports & Stakeholder Updates" ;;
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

    # Configure tmux status line - Command Gold theme (supreme financial authority)
    $TMUX_CMD set -t $SESSION_CODE status-left-length 15
    $TMUX_CMD set -t $SESSION_CODE status-left "  $SESSION_NAME "
    $TMUX_CMD set -t $SESSION_CODE @developer "$SESSION_DEVELOPER"
    $TMUX_CMD set -t $SESSION_CODE @claude_agent "zek"
    $TMUX_CMD set -t $SESSION_CODE status-right " #{@claude_agent} | 🖥  #h  "
    $TMUX_CMD set -t $SESSION_CODE status-style "bg=colour94,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE status-left-style "bg=colour220,fg=colour0,bold"
    $TMUX_CMD set -t $SESSION_CODE status-right-style "bg=colour94,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-style "bg=colour94,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-current-style "bg=colour220,fg=colour0,bold"
    $TMUX_CMD set -t $SESSION_CODE pane-border-style "fg=colour94"
    $TMUX_CMD set -t $SESSION_CODE pane-active-border-style "fg=colour220"

    sleep 0.5
    $TMUX_CMD select-window -t $SESSION_CODE:0

    echo "  Finance Nagus Terminal initialized"
    echo ""
    echo "--> 4 strategy stations active"
    echo "--> Grand Nagus Zek reporting for profit"
    echo ""
    sleep 1
fi

# Only attach if not being launched by master startup script
if [ -z "$SKIP_ATTACH" ]; then
    $TMUX_CMD attach-session -t $SESSION_CODE
fi
