#!/usr/bin/env bash
set +x
# Freelance Engineering Terminal Startup
# ENT Location: Main Engineering
# Primary Developer: Commander Charles "Trip" Tucker III (Release Engineering)
# Color Theme: Operations Gold

SESSION_THEME="OPERATIONS"
SESSION_TYPE="freelance"
SESSION_NAME="engineering"
SESSION_DESCRIPTION="FREELANCE ENGINEERING - RELEASE MANAGEMENT"
SESSION_LOCATION="ENT: Main Engineering"
SESSION_DEVELOPER="Commander Charles 'Trip' Tucker III"
SESSION_ROLE="Release Engineer & CI/CD"

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
    SESSION_DIRECTORY="/Users/Shared/Development/DoubleNode"
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
    echo "🔧 Initializing Freelance Engineering..."

    # Window 0: Engineering Command
    TERMINAL_NUMBER=0
    TERMINAL_NAME="engineering-cmd"
    TERMINAL_DESCRIPTION="Engineering Command Center"
    echo -n "- Connecting to $TERMINAL_DESCRIPTION..."
    $TMUX_CMD new-session -d -s $SESSION_CODE -n $TERMINAL_NAME -c "$SESSION_DIRECTORY"
    setup_window
    sleep 0.2
    echo "CONNECTED"

    # Window 1: Build Systems
    TERMINAL_NUMBER=1
    TERMINAL_NAME="build"
    TERMINAL_DESCRIPTION="Build Systems & Compilation"
    echo -n "- Connecting to $TERMINAL_DESCRIPTION..."
    $TMUX_CMD new-window -t $SESSION_CODE:$TERMINAL_NUMBER -n $TERMINAL_NAME
    setup_window
    sleep 0.2
    echo "CONNECTED"

    # Window 2: CI/CD Pipeline
    TERMINAL_NUMBER=2
    TERMINAL_NAME="cicd"
    TERMINAL_DESCRIPTION="CI/CD Pipeline Management"
    echo -n "- Connecting to $TERMINAL_DESCRIPTION..."
    $TMUX_CMD new-window -t $SESSION_CODE:$TERMINAL_NUMBER -n $TERMINAL_NAME
    setup_window
    sleep 0.2
    echo "CONNECTED"

    # ── Switch to Reed for testing window (3) ──
    SESSION_DEVELOPER="Lieutenant Malcolm Reed"
    SESSION_ROLE="Security & Testing Lead"

    # Window 3: Testing
    TERMINAL_NUMBER=3
    TERMINAL_NAME="testing"
    TERMINAL_DESCRIPTION="Automated Testing & QA"
    echo -n "- Connecting to $TERMINAL_DESCRIPTION..."
    $TMUX_CMD new-window -t $SESSION_CODE:$TERMINAL_NUMBER -n $TERMINAL_NAME
    setup_window
    $TMUX_CMD set-option -w -t $SESSION_CODE:$TERMINAL_NUMBER @claude_agent "reed"
    $TMUX_CMD set-option -w -t $SESSION_CODE:$TERMINAL_NUMBER @developer "Lieutenant Malcolm Reed"
    sleep 0.2
    echo "CONNECTED"

    # ── Switch back to Tucker for remaining windows ──
    SESSION_DEVELOPER="Commander Charles 'Trip' Tucker III"
    SESSION_ROLE="Release Engineer & CI/CD"

    # Configure tmux status line - Operations Gold theme
    $TMUX_CMD set -t $SESSION_CODE status-left-length 15
    $TMUX_CMD set -t $SESSION_CODE status-left "  $SESSION_NAME "
    $TMUX_CMD set -t $SESSION_CODE @developer "$SESSION_DEVELOPER"
    $TMUX_CMD set -t $SESSION_CODE @claude_agent "tucker"
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

    echo "✅ Freelance Engineering initialized"
    echo ""
    echo "--> 4 engineering stations active"
    echo "--> Commander Tucker reporting for duty"
    echo ""
    sleep 1
fi

# Only attach if not being launched by master startup script
if [ -z "$SKIP_ATTACH" ]; then
    $TMUX_CMD attach-session -t $SESSION_CODE
fi
