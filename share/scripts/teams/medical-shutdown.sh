#!/bin/bash
set +x
# Medical Team Cleanup Script
# Kills all Medical tmux sessions for a specific project

if [ $# -lt 1 ]; then
    echo "ERROR: Project ID required"
    echo "Usage: $0 <PROJECTID>"
    echo "Example: $0 clinic1"
    exit 1
fi

PROJECTID="$1"
PROJECT_LOWER=$(echo "$PROJECTID" | tr '[:upper:]' '[:lower:]')
SESSION_PREFIX="medical-${PROJECT_LOWER}"
KANBAN_BOARD="medical-${PROJECT_LOWER}"

# Use the same tmux socket as the startup script
TMUX_SOCKET="medical"

echo "🧹 Cleaning up Medical terminal sessions for project: $PROJECTID..."
echo "   tmux socket: $TMUX_SOCKET"
echo "   session prefix: $SESSION_PREFIX"
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

sessions=(
    "${SESSION_PREFIX}-lcars"
    "${SESSION_PREFIX}-diagnostics"
    "${SESSION_PREFIX}-oncology"
    "${SESSION_PREFIX}-immunology"
    "${SESSION_PREFIX}-surgery"
    "${SESSION_PREFIX}-neurology"
    "${SESSION_PREFIX}-emergency"
)

count=0
for session in "${sessions[@]}"; do
    if tmux -L $TMUX_SOCKET has-session -t $session 2>/dev/null; then
        echo "  ✓ Killing session: $session"
        tmux -L $TMUX_SOCKET kill-session -t $session
        ((count++))
    fi
done

# Clean up LCARS port file
LCARS_PORTS_DIR="${AITEAMFORGE_DIR:-$HOME/dev-team}/lcars-ports"
LCARS_PORT_FILE="$LCARS_PORTS_DIR/${SESSION_PREFIX}-lcars.port"
if [ -f "$LCARS_PORT_FILE" ]; then
    echo "  ✓ Removing LCARS port file: ${SESSION_PREFIX}-lcars.port"
    rm -f "$LCARS_PORT_FILE"
fi

echo ""
if [ $count -eq 0 ]; then
    echo "ℹ️  No Medical sessions were running for project: $PROJECTID"
else
    echo "✅ Cleanup complete! Terminated $count session(s) for project: $PROJECTID"
    cleanup_agent_panels "medical"
    # Reset kanban
    echo ""
    echo "📋 Resetting Kanban board: $KANBAN_BOARD..."
    python3 ~/dev-team/kanban-hooks/kanban-reset.py $KANBAN_BOARD
fi
echo ""
echo "Remaining Medical tmux sessions (socket: $TMUX_SOCKET):"
tmux -L $TMUX_SOCKET list-sessions 2>/dev/null || echo "  (none)"
