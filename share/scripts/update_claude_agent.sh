#!/bin/bash

# Update Claude Code Agent Display in tmux Status Bar
# Usage: ./update_claude_agent.sh "agent-name"

AGENT_NAME="${1:-general-purpose}"

# Set tmux session-specific user option (visible in status-right)
if [ -n "$TMUX" ]; then
    # Update the @claude_agent user option for current session
    tmux set-option @claude_agent "$AGENT_NAME"

    # Update status-right to show both agent and worktree
    worktree=$(tmux show-options -v @current_worktree 2>/dev/null)
    if [ -n "$worktree" ]; then
        tmux set-option status-right "🌿 $worktree | 🤖 $AGENT_NAME  "
    else
        tmux set-option status-right "🤖 $AGENT_NAME  "
    fi

    # Also write to file for persistence
    mkdir -p ~/.claude
    echo "$AGENT_NAME" > ~/.claude/current-agent

    echo "✓ Updated Claude Code agent: 🤖 $AGENT_NAME"
else
    echo "⚠️  Not running in tmux. Skipping tmux status update."
fi

# Also update iTerm2 badge if helper is available
_BADGE_HELPER="${AITEAMFORGE_DIR:-${HOME}/aiteamforge}/share/scripts/iterm2_badge_helper.sh"
if type -t set_claude_badge > /dev/null; then
    set_claude_badge "$AGENT_NAME"
    echo "✓ Updated iTerm2 badge"
elif [ -f "$_BADGE_HELPER" ]; then
    source "$_BADGE_HELPER"
    set_claude_badge "$AGENT_NAME"
    echo "✓ Updated iTerm2 badge"
fi
