#!/usr/bin/env zsh
# Freelance Cleanup Sessions Script
# Kills Freelance tmux sessions (optionally filtered by group/project)
#
# Usage:
#   ./freelance-cleanup-sessions.sh                    - Kill ALL freelance sessions
#   ./freelance-cleanup-sessions.sh AcmeCorp            - Kill all sessions for a group
#   ./freelance-cleanup-sessions.sh AcmeCorp WidgetTracker - Kill specific project only

# Use the same tmux socket as the startup script
TMUX_SOCKET="freelance"

GROUPID="$1"
PROJECTID="$2"

echo "🧹 FREELANCE SESSION CLEANUP"
echo "   Terminating Enterprise NX-01 sessions"
echo "   tmux socket: $TMUX_SOCKET"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

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

# Determine filter pattern based on parameters
if [ -n "$GROUPID" ] && [ -n "$PROJECTID" ]; then
    # Both group and project specified - kill specific project only
    GROUP_LOWER=$(echo "$GROUPID" | tr '[:upper:]' '[:lower:]')
    PROJECT_LOWER=$(echo "$PROJECTID" | tr '[:upper:]' '[:lower:]')
    FILTER_PATTERN="^freelance-${GROUP_LOWER}-${PROJECT_LOWER}-"
    echo "   Filter: Group '$GROUPID' / Project '$PROJECTID'"
elif [ -n "$GROUPID" ]; then
    # Only group specified - kill all projects in that group
    GROUP_LOWER=$(echo "$GROUPID" | tr '[:upper:]' '[:lower:]')
    FILTER_PATTERN="^freelance-${GROUP_LOWER}-"
    echo "   Filter: All projects in group '$GROUPID'"
else
    # No parameters - kill all freelance sessions
    FILTER_PATTERN="^freelance-"
    echo "   Filter: ALL freelance sessions"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Find sessions matching the filter pattern
echo "Scanning for Freelance sessions..."
freelance_sessions=$(tmux -L $TMUX_SOCKET list-sessions 2>/dev/null | grep "$FILTER_PATTERN" | cut -d: -f1)

if [ -z "$freelance_sessions" ]; then
    echo "  ⚪ No matching Freelance sessions found"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Cleanup complete!"
    if [ -n "$GROUPID" ] && [ -n "$PROJECTID" ]; then
        echo "   No sessions found for $GROUPID/$PROJECTID"
    elif [ -n "$GROUPID" ]; then
        echo "   No sessions found for group $GROUPID"
    else
        echo "   No active Freelance sessions were found"
    fi
    echo ""
    exit 0
fi

echo ""
echo "Found sessions:"
echo "$freelance_sessions" | sed 's/^/  • /'
echo ""
echo "Terminating sessions..."
echo ""

killed_count=0

while IFS= read -r session; do
    if [ -n "$session" ]; then
        echo "  🗑️  Killing session: $session"
        tmux -L $TMUX_SOCKET kill-session -t "$session" 2>/dev/null
        killed_count=$((killed_count + 1))
    fi
done <<< "$freelance_sessions"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Cleanup complete!"
echo "   Sessions terminated: $killed_count"
echo ""

if [ -n "$GROUPID" ] && [ -n "$PROJECTID" ]; then
    echo "Project $GROUPID/$PROJECTID sessions terminated."
    echo "Team dismissed. 🛸"
    cleanup_agent_panels "freelance"
    # Reset kanban for specific project
    echo ""
    echo "📋 Resetting Kanban board..."
    python3 ~/dev-team/kanban-hooks/kanban-reset.py freelance "${GROUP_LOWER}-${PROJECT_LOWER}"
elif [ -n "$GROUPID" ]; then
    echo "All $GROUPID project sessions terminated."
    echo "Teams dismissed. 🛸"
    cleanup_agent_panels "freelance"
    # Reset kanban for group
    echo ""
    echo "📋 Resetting Kanban board..."
    python3 ~/dev-team/kanban-hooks/kanban-reset.py freelance "${GROUP_LOWER}"
else
    echo "All Freelance team members have been dismissed."
    echo "Enterprise NX-01 standing down. 🛸"
    cleanup_agent_panels "freelance"
    # Reset all kanban entries
    echo ""
    echo "📋 Resetting Kanban board..."
    python3 ~/dev-team/kanban-hooks/kanban-reset.py freelance
fi
echo ""
