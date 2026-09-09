#!/usr/bin/env bash

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
        tmux set-option status-right "🌿 $worktree | 🤖 $AGENT_NAME | 🖥  #h  "
    else
        tmux set-option status-right "🤖 $AGENT_NAME | 🖥  #h  "
    fi

    # Also write to file for persistence
    mkdir -p ~/.claude
    echo "$AGENT_NAME" > ~/.claude/current-agent

    echo "✓ Updated Claude Code agent: 🤖 $AGENT_NAME"
else
    echo "⚠️  Not running in tmux. Skipping tmux status update."
fi

# Also update iTerm2 badge if helper is available
#
# XACA-1144-004: mirror the same candidate order the other three call sites
# use (claude_code_cc_aliases.sh's clear_claude_active cleanup, and the
# kanban-session-start.py / kanban-stop.py resolve_helper_path() chains):
#   1. $DEV_TEAM_ROOT/iterm2_badge_helper.sh   (explicit override)
#   2. ~/dev-team/iterm2_badge_helper.sh       (dev checkout)
#   3. ~/aiteamforge/iterm2_badge_helper.sh    (tap-installed consumer)
# This file previously probed ONLY #2, so the shipped tap copy (which is a
# mirror of this file) could never find the helper on a consumer machine —
# ~/dev-team never exists there. $DEV_TEAM_ROOT is included even though only
# 2 of the other 3 sites honor it: the omission in claude_code_cc_aliases.sh
# looks like drift rather than an intentional exclusion, this file ships to
# consumers who may set a custom root, and the override is free to support.
if type -t set_claude_badge > /dev/null; then
    set_claude_badge "$AGENT_NAME"
    echo "✓ Updated iTerm2 badge"
else
    badge_helper=""
    if [ -n "$DEV_TEAM_ROOT" ] && [ -f "$DEV_TEAM_ROOT/iterm2_badge_helper.sh" ]; then
        badge_helper="$DEV_TEAM_ROOT/iterm2_badge_helper.sh"
    elif [ -f ~/dev-team/iterm2_badge_helper.sh ]; then
        badge_helper=~/dev-team/iterm2_badge_helper.sh
    elif [ -f ~/aiteamforge/iterm2_badge_helper.sh ]; then
        badge_helper=~/aiteamforge/iterm2_badge_helper.sh
    fi

    if [ -n "$badge_helper" ]; then
        source "$badge_helper"
        set_claude_badge "$AGENT_NAME"
        echo "✓ Updated iTerm2 badge"
    fi
fi
