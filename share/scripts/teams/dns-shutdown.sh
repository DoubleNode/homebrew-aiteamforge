#!/usr/bin/env bash
set +x
# DNS Framework Terminal Cleanup Script
# Kills all DNS Framework tmux sessions

# Use the same tmux socket as the startup script
TMUX_SOCKET="dns"

echo "🧹 Cleaning up DNS Framework terminal sessions..."
echo "   tmux socket: $TMUX_SOCKET"
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
    "dns-command"
    "dns-bugbay"
    "dns-testing"
    "dns-build"
    "dns-refactor"
    "dns-apidesign"
    "dns-docs"
)

count=0
for session in "${sessions[@]}"; do
    if tmux -L $TMUX_SOCKET has-session -t $session 2>/dev/null; then
        echo "  ✓ Killing session: $session"
        tmux -L $TMUX_SOCKET kill-session -t $session
        ((count++))
    fi
done

echo ""
if [ $count -eq 0 ]; then
    echo "ℹ️  No DNS Framework sessions were running"
else
    echo "✅ Cleanup complete! Terminated $count session(s)"
    cleanup_agent_panels "dns"
    # Reset kanban
    echo ""
    echo "📋 Resetting Kanban board..."
    python3 ~/dev-team/kanban-hooks/kanban-reset.py dns
fi
echo ""
echo "Remaining tmux sessions (socket: $TMUX_SOCKET):"
tmux -L $TMUX_SOCKET list-sessions 2>/dev/null || echo "  (none)"
