#!/usr/bin/env bash
set +x
# Medical Team Emergency Terminal Startup
# Location: Princeton-Plainsboro Teaching Hospital - Emergency Department
# Primary Developer: Dr. Lisa Cuddy (Release Engineer)
# Color Theme: Command Blue (representing administrative authority)

SESSION_THEME="COMMAND"
SESSION_TYPE="medical"
SESSION_NAME="emergency"
SESSION_DESCRIPTION="EMERGENCY - RELEASE ENGINEER"
SESSION_LOCATION="Medical: Emergency Department & Administration"
SESSION_DEVELOPER="Dr. Lisa Cuddy"
SESSION_ROLE="Release Engineer & Hospital Administrator"

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
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". ~/dev-team/$SESSION_TYPE/scripts/$SESSION_TYPE-banner.sh \"$SESSION_THEME\" \"$SESSION_TYPE\" \"$SESSION_NAME\" \"$TERMINAL_NUMBER\" \"$TERMINAL_NAME\" \"$SESSION_DESCRIPTION\" \"$SESSION_LOCATION\" \"$SESSION_DEVELOPER\" \"$SESSION_ROLE\" \"$TERMINAL_DESCRIPTION\" \"$SESSION_CODE\"" C-m
}


$TMUX_CMD has-session -t $SESSION_CODE

if [ $? != 0 ]; then
    clear
    echo "  Initializing Medical Emergency Terminal..."

    for i in {0..3}; do
        TERMINAL_NUMBER=$i
        case $i in
            0) TERMINAL_NAME="emergency-cmd"; TERMINAL_DESCRIPTION="Emergency Command Center" ;;
            1) TERMINAL_NAME="release-prep"; TERMINAL_DESCRIPTION="Release Preparation & Staging" ;;
            2) TERMINAL_NAME="deployment"; TERMINAL_DESCRIPTION="Deployment & Distribution" ;;
            3) TERMINAL_NAME="monitoring"; TERMINAL_DESCRIPTION="Release Monitoring & Support" ;;
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

    # Configure tmux status line - Command Blue theme (administrative authority)
    $TMUX_CMD set -t $SESSION_CODE status-left-length 15
    $TMUX_CMD set -t $SESSION_CODE status-left "  $SESSION_NAME "
    $TMUX_CMD set -t $SESSION_CODE @developer "$SESSION_DEVELOPER"
    $TMUX_CMD set -t $SESSION_CODE @claude_agent "cuddy"
    $TMUX_CMD set -t $SESSION_CODE status-right " #{@claude_agent} | 🖥  #h  "
    $TMUX_CMD set -t $SESSION_CODE status-style "bg=colour25,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE status-left-style "bg=colour33,fg=colour255,bold"
    $TMUX_CMD set -t $SESSION_CODE status-right-style "bg=colour25,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-style "bg=colour25,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-current-style "bg=colour33,fg=colour255,bold"
    $TMUX_CMD set -t $SESSION_CODE pane-border-style "fg=colour25"
    $TMUX_CMD set -t $SESSION_CODE pane-active-border-style "fg=colour33"

    sleep 0.5
    $TMUX_CMD select-window -t $SESSION_CODE:0

    echo "  Medical Emergency Terminal initialized"
    echo ""
    echo "--> 4 emergency stations active"
    echo "--> Dr. Cuddy reporting for duty"
    echo ""
    sleep 1
fi

# Only attach if not being launched by master startup script
if [ -z "$SKIP_ATTACH" ]; then
    $TMUX_CMD attach-session -t $SESSION_CODE
fi
