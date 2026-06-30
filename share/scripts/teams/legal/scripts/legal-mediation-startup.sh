#!/usr/bin/env bash
set +x
# Legal Team Mediation Terminal Startup
# Location: Mediation Conference Room
# Primary Developer: Alan Shore (Negotiation & Settlement)
# Color Theme: Sciences Blue (diplomatic resolution)

SESSION_THEME="SCIENCES"
SESSION_TYPE="legal"
SESSION_NAME="mediation"
SESSION_DESCRIPTION="MEDIATION - NEGOTIATION & SETTLEMENT"
SESSION_LOCATION="Legal: Mediation Conference Room"
SESSION_DEVELOPER="Alan Shore"
SESSION_ROLE="Mediation Specialist & Settlement Negotiator"

# Require environment variables from master startup script
if [ -z "$LEGAL_PROJECTID" ] || [ -z "$LEGAL_PROJECT_DIR" ]; then
    echo "ERROR: This script must be launched via legal-startup.sh"
    echo "Usage: cd ~/dev-team/legal/scripts && ./legal-startup.sh <PROJECTID>"
    exit 1
fi

PROJECTID="$LEGAL_PROJECTID"
SESSION_DIRECTORY="$LEGAL_PROJECT_DIR"
PROJECT_LOWER=$(echo "$PROJECTID" | tr '[:upper:]' '[:lower:]')
SESSION_CODE="legal-${PROJECT_LOWER}-${SESSION_NAME}"

# Use team-specific tmux socket if set, otherwise use default server
TMUX_CMD="tmux${TMUX_SOCKET:+ -L $TMUX_SOCKET}"

# ============================================================================
# Function: set_window_metadata
# Sets TERMINAL_NUMBER / TERMINAL_NAME / TERMINAL_DESCRIPTION for a window index.
# Factored out so it can be reused by the panel-regen loop AND the tmux
# session-creation loop below.
# ============================================================================
set_window_metadata() {
    case "$1" in
        0) TERMINAL_NUMBER=0; TERMINAL_NAME="mediation-cmd"; TERMINAL_DESCRIPTION="Mediation Command Center" ;;
        1) TERMINAL_NUMBER=1; TERMINAL_NAME="negotiation"; TERMINAL_DESCRIPTION="Negotiation Workspace" ;;
        2) TERMINAL_NUMBER=2; TERMINAL_NAME="settlement"; TERMINAL_DESCRIPTION="Settlement Drafting" ;;
        3) TERMINAL_NUMBER=3; TERMINAL_NAME="communication"; TERMINAL_DESCRIPTION="Party Communications" ;;
    esac
}

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

# ============================================================================
# Refresh agent panel JSON for every window — UNCONDITIONAL.
# The has-session block below only fires on first creation; the banner that
# writes panel JSON via display_agent_avatar only runs then. Panel JSON lives
# outside tmux, so we regenerate it on every invocation. Protects against
# iTerm restarts, tmux socket reboots, and infrastructure upgrades leaving
# panels stuck on "Awaiting agent...".
# ============================================================================
_AVATAR_HELPER="$HOME/dev-team/scripts/display-agent-avatar.sh"
if [ -f "$_AVATAR_HELPER" ]; then
    source "$_AVATAR_HELPER"
    for _i in 0 1 2 3; do
        set_window_metadata "$_i"
        export SESSION_THEME SESSION_DESCRIPTION SESSION_LOCATION SESSION_ROLE
        export SESSION_CODE TERMINAL_NUMBER TERMINAL_NAME TERMINAL_DESCRIPTION
        display_agent_avatar "$SESSION_TYPE" "$SESSION_DEVELOPER" >/dev/null 2>&1
    done
fi

$TMUX_CMD has-session -t $SESSION_CODE

if [ $? != 0 ]; then
    clear
    echo "  Initializing Legal Mediation Terminal..."

    for i in {0..3}; do
        set_window_metadata "$i"

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

    # Configure tmux status line - Sciences Blue theme (diplomacy)
    $TMUX_CMD set -t $SESSION_CODE status-left-length 15
    $TMUX_CMD set -t $SESSION_CODE status-left "  $SESSION_NAME "
    $TMUX_CMD set -t $SESSION_CODE @developer "$SESSION_DEVELOPER"
    $TMUX_CMD set -t $SESSION_CODE @claude_agent "mediator"
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

    echo "  Legal Mediation Terminal initialized"
    echo ""
    echo "--> 4 mediation stations active"
    echo "--> Alan Shore reporting for duty"
    echo ""
    sleep 1
fi

# Only attach if not being launched by master startup script
if [ -z "$SKIP_ATTACH" ]; then
    $TMUX_CMD attach-session -t $SESSION_CODE
fi
