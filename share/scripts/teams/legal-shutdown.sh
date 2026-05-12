#!/bin/zsh
# Legal Team Cleanup Sessions Script
# Kills all Legal Team tmux sessions
# Usage: ./legal-shutdown.sh [PROJECTID]
# Example: ./legal-shutdown.sh coparenting

# Use the same tmux socket as the startup script
TMUX_SOCKET="legal"

# Check if a project ID was provided
if [ $# -ge 1 ]; then
    PROJECTID="$1"
    PROJECT_LOWER=$(echo "$PROJECTID" | tr '[:upper:]' '[:lower:]')
    SESSION_PREFIX="legal-${PROJECT_LOWER}"
    KANBAN_BOARD="legal-${PROJECT_LOWER}"

    echo "  LEGAL TEAM SESSION CLEANUP - Project: $PROJECTID"
else
    # Default to coparenting for backward compatibility
    SESSION_PREFIX="legal"
    KANBAN_BOARD="legal-coparenting"

    echo "  LEGAL TEAM SESSION CLEANUP - Default (coparenting)"
fi

echo "   Terminating sessions matching: ${SESSION_PREFIX}-*"
echo "   tmux socket: $TMUX_SOCKET"
echo ""

# List of all legal terminal types
terminal_types=(
    "lcars"
    "chambers"
    "discovery"
    "research"
    "filings"
    "mediation"
    "timeline"
)

echo "Checking for active Legal sessions..."
echo ""

# ── Agent Panel Cleanup ──────────────────────────────
# Kill orphan agent-panel-display.sh processes for this team
cleanup_agent_panels() {
    local team_prefix="$1"
    echo "🧹 Cleaning up agent panel processes (${team_prefix})..."

    # Kill agent-panel-display.sh processes matching this team
    local panel_pids=$(pgrep -f "agent-panel-display.sh ${team_prefix}-" 2>/dev/null)
    if [[ -n "$panel_pids" ]]; then
        echo "$panel_pids" | xargs kill 2>/dev/null
        echo "  ✓ Killed agent panel processes"
    fi

    # Clean up temp files for this team's sessions — /tmp/ (legacy location)
    rm -f /tmp/lcars-agent-${team_prefix}-*.json 2>/dev/null
    rm -f /tmp/lcars-avatar-${team_prefix}-*-rounded.png 2>/dev/null
    rm -f /tmp/lcars-termlogo-${team_prefix}-*-rounded.png 2>/dev/null
    rm -f /tmp/lcars-crew-${team_prefix}-*.png 2>/dev/null
    rm -f /tmp/lcars-active-window-${team_prefix}-* 2>/dev/null
    rm -f /tmp/lcars-subagents-${team_prefix}-*.json 2>/dev/null

    # Clean up temp files from kanban/tmp/ (new location)
    local lcars_tmp_helper="${HOME}/dev-team/scripts/lcars-tmp-dir.sh"
    if [[ -f "$lcars_tmp_helper" ]]; then
        source "$lcars_tmp_helper"
        local kanban_tmp
        kanban_tmp=$(_get_lcars_tmp_dir "${team_prefix}-x")
        if [[ -d "$kanban_tmp" ]]; then
            rm -f "${kanban_tmp}lcars-agent-${team_prefix}-*.json" 2>/dev/null
            rm -f "${kanban_tmp}lcars-avatar-${team_prefix}-*-rounded.png" 2>/dev/null
            rm -f "${kanban_tmp}lcars-termlogo-${team_prefix}-*-rounded.png" 2>/dev/null
            rm -f "${kanban_tmp}lcars-crew-${team_prefix}-*.png" 2>/dev/null
            rm -f "${kanban_tmp}lcars-active-window-${team_prefix}-*" 2>/dev/null
            rm -f "${kanban_tmp}lcars-subagents-${team_prefix}-*.json" 2>/dev/null
        fi
    fi
    echo "  ✓ Cleaned up temp files"
}

killed_count=0
not_found_count=0

for terminal in "${terminal_types[@]}"; do
    session="${SESSION_PREFIX}-${terminal}"
    if tmux -L $TMUX_SOCKET has-session -t "$session" 2>/dev/null; then
        echo "     Killing session: $session"
        tmux -L $TMUX_SOCKET kill-session -t "$session"
        killed_count=$((killed_count + 1))
    else
        echo "     Session not found: $session"
        not_found_count=$((not_found_count + 1))
    fi
done

echo ""
echo "  Cleanup complete!"
echo "   Sessions terminated: $killed_count"
echo "   Sessions not found: $not_found_count"
echo ""

if [ $killed_count -gt 0 ]; then
    echo "All Legal team members have been dismissed."
    echo "Legal Team standing down."
    cleanup_agent_panels "legal"
    # Reset kanban for the appropriate board
    echo ""
    echo "   Resetting Kanban board: $KANBAN_BOARD"
    python3 ~/dev-team/kanban-hooks/kanban-reset.py "$KANBAN_BOARD"
else
    echo "No active Legal sessions were found."
fi
echo ""
