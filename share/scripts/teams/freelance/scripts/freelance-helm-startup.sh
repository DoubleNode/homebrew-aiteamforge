#!/bin/bash
set +x
# Freelance Helm Terminal Startup
# ENT Location: Helm Station
# Primary Developer: Ensign Travis Mayweather (UX & Interface Design)
# Color Theme: Operations Gold

SESSION_THEME="OPERATIONS"
SESSION_TYPE="freelance"
SESSION_NAME="helm"
SESSION_DESCRIPTION="FREELANCE HELM - UX DESIGN"
SESSION_LOCATION="ENT: Helm Station"
SESSION_DEVELOPER="Ensign Travis Mayweather"
SESSION_ROLE="UX/UI Developer"
# Use passed project directory or fallback to default
if [ -n "$FREELANCE_PROJECT_DIR" ]; then
    SESSION_DIRECTORY="$FREELANCE_PROJECT_DIR"
    GROUPID="$FREELANCE_GROUPID"
    PROJECTID="$FREELANCE_PROJECTID"
    # Include project info in session name for uniqueness
    GROUP_LOWER=$(echo "$GROUPID" | tr '[:upper:]' '[:lower:]')
    PROJECT_LOWER=$(echo "$PROJECTID" | tr '[:upper:]' '[:lower:]')
    SESSION_CODE="${SESSION_TYPE}-${GROUP_LOWER}-${PROJECT_LOWER}-${SESSION_NAME}"
else
    SESSION_DIRECTORY="/Users/Shared/Development/AcmeCorp"
    GROUPID=""
    PROJECTID=""
    SESSION_CODE="${SESSION_TYPE}-${SESSION_NAME}"
fi

# Use team-specific tmux socket if set, otherwise use default server
TMUX_CMD="tmux${TMUX_SOCKET:+ -L $TMUX_SOCKET}"

# ============================================================================
# Function: setup_window
# Executes the common setup commands for each tmux window
# ============================================================================
setup_window() {
    sleep 0.1
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER "cd \"$SESSION_DIRECTORY\"" C-m
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". ~/.zshrc_${SESSION_TYPE}_${SESSION_NAME}" C-m
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". ~/dev-team/$SESSION_TYPE/scripts/$SESSION_TYPE-banner.sh \"$SESSION_THEME\" \"$SESSION_TYPE\" \"$SESSION_NAME\" \"$TERMINAL_NUMBER\" \"$TERMINAL_NAME\" \"$SESSION_DESCRIPTION\" \"$SESSION_LOCATION\" \"$SESSION_DEVELOPER\" \"$SESSION_ROLE\" \"$TERMINAL_DESCRIPTION\" \"$SESSION_CODE\"" C-m

    # If project parameters were provided, set up worktree
    if [ -n "$GROUPID" ] && [ -n "$PROJECTID" ]; then
        sleep 0.3
        $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER "wt-project freelance" C-m
        sleep 0.2
        $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER "wt-dev" C-m
        sleep 0.2
        $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER "onscreen" C-m
    fi
}


$TMUX_CMD has-session -t $SESSION_CODE

if [ $? != 0 ]; then
    clear
    echo "🎮 Initializing Freelance Helm..."

    for i in {0..3}; do
        TERMINAL_NUMBER=$i
        case $i in
            0) TERMINAL_NAME="helm-cmd"; TERMINAL_DESCRIPTION="Helm Command Center" ;;
            1) TERMINAL_NAME="ui-design"; TERMINAL_DESCRIPTION="UI Design & Development" ;;
            2) TERMINAL_NAME="ux-research"; TERMINAL_DESCRIPTION="UX Research & Testing" ;;
            3) TERMINAL_NAME="prototyping"; TERMINAL_DESCRIPTION="Rapid Prototyping" ;;
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

    # Configure tmux status line - Operations Gold theme
    $TMUX_CMD set -t $SESSION_CODE status-left-length 15
    $TMUX_CMD set -t $SESSION_CODE status-left "  $SESSION_NAME "
    $TMUX_CMD set -t $SESSION_CODE @developer "$SESSION_DEVELOPER"
    $TMUX_CMD set -t $SESSION_CODE @claude_agent "mayweather"
    $TMUX_CMD set -t $SESSION_CODE status-right "🤖 #{@claude_agent} | 🖥  #h  "
    $TMUX_CMD set -t $SESSION_CODE status-style "bg=colour136,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE status-left-style "bg=colour178,fg=colour255,bold"
    $TMUX_CMD set -t $SESSION_CODE status-right-style "bg=colour136,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-style "bg=colour136,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-current-style "bg=colour178,fg=colour255,bold"
    $TMUX_CMD set -t $SESSION_CODE pane-border-style "fg=colour136"
    $TMUX_CMD set -t $SESSION_CODE pane-active-border-style "fg=colour178"

    sleep 0.5
    $TMUX_CMD select-window -t $SESSION_CODE:0

    echo "✅ Freelance Helm initialized"
    echo ""
    echo "--> 4 helm stations active"
    echo "--> Ensign Mayweather reporting for duty"
    echo ""
    sleep 1
fi

# Only attach if not being launched by master startup script
if [ -z "$SKIP_ATTACH" ]; then
    $TMUX_CMD attach-session -t $SESSION_CODE
fi
