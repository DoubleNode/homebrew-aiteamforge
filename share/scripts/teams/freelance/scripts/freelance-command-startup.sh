#!/bin/bash
set +x
# Freelance Command Terminal Startup
# ENT Location: Captain's Ready Room / Bridge
# Primary Developer: Captain Jonathan Archer (Lead Feature Developer)
# Color Theme: Command Blue

SESSION_THEME="COMMAND"
SESSION_TYPE="freelance"
SESSION_NAME="command"
SESSION_DESCRIPTION="FREELANCE COMMAND - STRATEGIC DEVELOPMENT"
SESSION_LOCATION="ENT: Enterprise NX-01 Bridge"
SESSION_DEVELOPER="Captain Jonathan Archer"
SESSION_ROLE="Lead Feature Developer"

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
    echo "⭐ Initializing Freelance Command..."

    # Window 0: Command Center
    TERMINAL_NUMBER=0
    TERMINAL_NAME="command-center"
    TERMINAL_DESCRIPTION="Freelance Strategic Development & Architecture"
    echo -n "- Connecting to $TERMINAL_DESCRIPTION..."
    $TMUX_CMD new-session -d -s $SESSION_CODE -n $TERMINAL_NAME -c "$SESSION_DIRECTORY"
    setup_window
    sleep 0.2
    echo "CONNECTED"

    # Window 1: Project Development
    TERMINAL_NUMBER=1
    TERMINAL_NAME="project-dev"
    TERMINAL_DESCRIPTION="Project Development Area"
    echo -n "- Connecting to $TERMINAL_DESCRIPTION..."
    $TMUX_CMD new-window -t $SESSION_CODE:$TERMINAL_NUMBER -n $TERMINAL_NAME
    setup_window
    sleep 0.2
    echo "CONNECTED"

    # Window 2: Client Work
    TERMINAL_NUMBER=2
    TERMINAL_NAME="client-work"
    TERMINAL_DESCRIPTION="Client Projects & Features"
    echo -n "- Connecting to $TERMINAL_DESCRIPTION..."
    $TMUX_CMD new-window -t $SESSION_CODE:$TERMINAL_NUMBER -n $TERMINAL_NAME
    setup_window
    sleep 0.2
    echo "CONNECTED"

    # Window 3: Architecture
    TERMINAL_NUMBER=3
    TERMINAL_NAME="architecture"
    TERMINAL_DESCRIPTION="Architecture & Documentation"
    echo -n "- Connecting to $TERMINAL_DESCRIPTION..."
    $TMUX_CMD new-window -t $SESSION_CODE:$TERMINAL_NUMBER -n $TERMINAL_NAME
    setup_window
    sleep 0.2
    echo "CONNECTED"

    # Configure tmux status line - Command Blue theme
    $TMUX_CMD set -t $SESSION_CODE status-left-length 15
    $TMUX_CMD set -t $SESSION_CODE status-left "  $SESSION_NAME "
    # Set session-specific variables for dynamic status-right
    $TMUX_CMD set -t $SESSION_CODE @developer "$SESSION_DEVELOPER"
    $TMUX_CMD set -t $SESSION_CODE @claude_agent "archer"
    $TMUX_CMD set -t $SESSION_CODE status-right "🤖 #{@claude_agent} | 🖥  #h  "
    $TMUX_CMD set -t $SESSION_CODE status-style "bg=colour24,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE status-left-style "bg=colour33,fg=colour255,bold"
    $TMUX_CMD set -t $SESSION_CODE status-right-style "bg=colour24,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-style "bg=colour24,fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-current-style "bg=colour33,fg=colour255,bold"
    $TMUX_CMD set -t $SESSION_CODE pane-border-style "fg=colour24"
    $TMUX_CMD set -t $SESSION_CODE pane-active-border-style "fg=colour33"

    sleep 0.5
    $TMUX_CMD select-window -t $SESSION_CODE:0

    echo "✅ Freelance Command initialized"
    echo ""
    echo "--> 4 command stations active"
    echo "--> Captain Archer reporting for duty"
    echo ""
    sleep 1
fi

# Only attach if not being launched by master startup script
if [ -z "$SKIP_ATTACH" ]; then
    $TMUX_CMD attach-session -t $SESSION_CODE
fi
