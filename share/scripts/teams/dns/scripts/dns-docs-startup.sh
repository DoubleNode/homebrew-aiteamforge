#!/usr/bin/env bash
set +x

# DNS Framework Docs Center Terminal Startup
# Lower Decks Location: Cerritos Ready Room
# Primary Developer: Commander Ransom (Documentation Lead)
# Color Theme: Operations

SESSION_THEME="OPERATIONS"
SESSION_TYPE="dns"
SESSION_NAME="docs"
SESSION_DESCRIPTION="DNS FRAMEWORK DOCS CENTER - DOCUMENTATION"
SESSION_LOCATION="Lower Decks: Cerritos Ready Room"
SESSION_DEVELOPER="Commander Ransom"
SESSION_ROLE="Documentation Lead"
SESSION_DIRECTORY="/Users/Shared/Development/DNSFramework"

SESSION_CODE="${SESSION_TYPE}-${SESSION_NAME}"

# Use team-specific tmux socket if set, otherwise use default server
TMUX_CMD="tmux${TMUX_SOCKET:+ -L $TMUX_SOCKET}"

KANBAN_HELPERS="$HOME/dev-team/kanban-helpers.sh"

# ============================================================================
# Function: setup_window
# Executes the common setup commands for each tmux window
# ============================================================================
setup_window() {
    sleep 0.1
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER "cd $SESSION_DIRECTORY" C-m
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". ~/.zshrc_${SESSION_TYPE}_${SESSION_NAME}" C-m
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". $KANBAN_HELPERS" C-m
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". ~/dev-team/dns-framework/scripts/dns-banner.sh \"$SESSION_THEME\" \"$SESSION_TYPE\" \"$SESSION_NAME\" \"$TERMINAL_NUMBER\" \"$TERMINAL_NAME\" \"$SESSION_DESCRIPTION\" \"$SESSION_LOCATION\" \"$SESSION_DEVELOPER\" \"$SESSION_ROLE\" \"$TERMINAL_DESCRIPTION\" \"$SESSION_CODE\"" C-m
}

$TMUX_CMD has-session -t $SESSION_CODE

if [ $? != 0 ]; then
    clear
    echo "⭐ Initializing DNS Framework Docs Center..."

    # Window 0: Command Center
    TERMINAL_NUMBER=0
    TERMINAL_NAME="command-center"
    TERMINAL_DESCRIPTION="DNS Framework Documentation Oversight & Planning"
    echo -n "- Connecting to $TERMINAL_DESCRIPTION..."
    $TMUX_CMD new-session -d -s $SESSION_CODE -n $TERMINAL_NAME -c "$SESSION_DIRECTORY"
    setup_window
    sleep 0.2
    echo "CONNECTED"

    # Window 1: iOS Frameworks
    TERMINAL_NUMBER=1
    TERMINAL_NAME="ios-frameworks"
    TERMINAL_DESCRIPTION="iOS Framework Development (28 repos)"
    echo -n "- Connecting to $TERMINAL_DESCRIPTION..."
    $TMUX_CMD new-window -t $SESSION_CODE:$TERMINAL_NUMBER -n $TERMINAL_NAME
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER "cd $SESSION_DIRECTORY/DNSFramework-iOS" C-m
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". ~/.zshrc_${SESSION_TYPE}_${SESSION_NAME}" C-m
    sleep 0.2
    echo "CONNECTED"

    # Window 2: Android Frameworks
    TERMINAL_NUMBER=2
    TERMINAL_NAME="android-frameworks"
    TERMINAL_DESCRIPTION="Android Framework Development"
    echo -n "- Connecting to $TERMINAL_DESCRIPTION..."
    $TMUX_CMD new-window -t $SESSION_CODE:$TERMINAL_NUMBER -n $TERMINAL_NAME
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER "cd $SESSION_DIRECTORY/DNSFramework-Android" C-m
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". ~/.zshrc_${SESSION_TYPE}_${SESSION_NAME}" C-m
    sleep 0.2
    echo "CONNECTED"

    # Window 3: DocC Catalog
    TERMINAL_NUMBER=3
    TERMINAL_NAME="docc-catalog"
    TERMINAL_DESCRIPTION="DocC Catalog & API Reference Generation"
    echo -n "- Connecting to $TERMINAL_DESCRIPTION..."
    $TMUX_CMD new-window -t $SESSION_CODE:$TERMINAL_NUMBER -n $TERMINAL_NAME
    setup_window
    sleep 0.2
    echo "CONNECTED"

    # Configure tmux status line - Operations Gold theme (Lower Decks)
    $TMUX_CMD set -t $SESSION_CODE status-left-length 15
    $TMUX_CMD set -t $SESSION_CODE status-left "  $SESSION_NAME "
    $TMUX_CMD set -t $SESSION_CODE @developer "$SESSION_DEVELOPER"
    $TMUX_CMD set -t $SESSION_CODE @claude_agent "ransom"
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

    echo ""
    echo "✅ DNS Framework Docs Center ready!"
    echo "   Developer: Commander Ransom (Documentation Lead)"
    echo "   Theme: Lower Decks - Operations"
fi

# Only attach if not skipping
if [ -z "$SKIP_ATTACH" ]; then
    tmux attach -t $SESSION_CODE
fi
