#!/bin/zsh
# Kanban Helper Functions
# Terminal shortcuts for kanban board management via Python backend

# Installation directory (substituted during install)
AITEAMFORGE_DIR="{{AITEAMFORGE_DIR}}"

#──────────────────────────────────────────────────────────────────────────────
# Configuration
#──────────────────────────────────────────────────────────────────────────────

# Kanban Python backend script location
KANBAN_MANAGER="$AITEAMFORGE_DIR/kanban-hooks/kanban-manager.py"

# Default team (override by setting KANBAN_TEAM env var)
: ${KANBAN_TEAM:="academy"}

#──────────────────────────────────────────────────────────────────────────────
# Helper Functions
#──────────────────────────────────────────────────────────────────────────────

# Check if kanban backend is installed
_kb_check_backend() {
    if [ ! -f "$KANBAN_MANAGER" ]; then
        echo "⚠️  Kanban backend not installed"
        echo "Run: aiteamforge-setup to install kanban system"
        return 1
    fi
    return 0
}

# Run kanban command with error handling
_kb_run() {
    _kb_check_backend || return 1

    local team="${KANBAN_TEAM}"
    if [ -n "$KB_TEAM_OVERRIDE" ]; then
        team="$KB_TEAM_OVERRIDE"
    fi

    python3 "$KANBAN_MANAGER" --team "$team" "$@"
}

#──────────────────────────────────────────────────────────────────────────────
# Main Kanban Commands
#──────────────────────────────────────────────────────────────────────────────

# List items
kb-list() {
    _kb_run list "$@"
}

# List backlog items
kb-backlog() {
    _kb_run backlog "$@"
}

# Add new item
kb-add() {
    _kb_run add "$@"
}

# Update item
kb-update() {
    _kb_run update "$@"
}

# Move item to status
kb-move() {
    _kb_run move "$@"
}

# Start working on item
kb-start() {
    _kb_run start "$@"
}

# Mark item as done
kb-done() {
    _kb_run done "$@"
}

# View item details
kb-view() {
    _kb_run view "$@"
}

# Search items
kb-search() {
    _kb_run search "$@"
}

# Show kanban statistics
kb-stats() {
    _kb_run stats "$@"
}

#──────────────────────────────────────────────────────────────────────────────
# Worktree Integration
#──────────────────────────────────────────────────────────────────────────────

# Set current working item based on worktree
kb-set-worktree() {
    if [ -z "$CURRENT_WORKTREE" ]; then
        echo "Not in a worktree"
        return 1
    fi

    # Extract item ID from worktree branch name
    # Assumes format: feature/XACA-0001 or bugfix/XIOS-0042
    local branch=$(git branch --show-current 2>/dev/null)
    if [ -z "$branch" ]; then
        echo "Could not determine git branch"
        return 1
    fi

    local item_id=$(echo "$branch" | grep -oE '[A-Z]+-[0-9]+' | head -1)
    if [ -z "$item_id" ]; then
        echo "Could not extract item ID from branch: $branch"
        return 1
    fi

    # Set as current item
    export KB_CURRENT_ITEM="$item_id"
    echo "✓ Set current item: $item_id"
}

# Clear current item
kb-clear() {
    unset KB_CURRENT_ITEM
    echo "✓ Cleared current item"
}

# Show current item
kb-current() {
    if [ -n "$KB_CURRENT_ITEM" ]; then
        echo "Current item: $KB_CURRENT_ITEM"
        kb-view "$KB_CURRENT_ITEM"
    else
        echo "No current item set"
        echo "Use: kb-set-worktree (in a worktree)"
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# Pull Request Integration
#──────────────────────────────────────────────────────────────────────────────

# Mark item as in review (PR created)
kb-pr() {
    if [ -n "$KB_CURRENT_ITEM" ]; then
        kb-move "$KB_CURRENT_ITEM" "in-review"
    else
        echo "Usage: kb-pr <item-id>"
        echo "Or set KB_CURRENT_ITEM first"
        return 1
    fi
}

# Mark item as merged
kb-merged() {
    if [ -n "$KB_CURRENT_ITEM" ]; then
        kb-done "$KB_CURRENT_ITEM"
    else
        echo "Usage: kb-merged <item-id>"
        echo "Or set KB_CURRENT_ITEM first"
        return 1
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# Utility Functions
#──────────────────────────────────────────────────────────────────────────────

# Switch team context
kb-team() {
    local team="$1"

    if [ -z "$team" ]; then
        echo "Current team: $KANBAN_TEAM"
        echo ""
        echo "Available teams:"
        echo "  academy, ios, android, firebase, command, dns"
        echo "  freelance-doublenode-starwords"
        echo "  freelance-doublenode-appplanning"
        echo "  freelance-doublenode-workstats"
        echo "  legal-coparenting"
        echo "  medical-general"
        echo ""
        echo "Usage: kb-team <team-name>"
        return 0
    fi

    export KANBAN_TEAM="$team"
    echo "✓ Switched to team: $team"
}

# Show kanban status for status line
kb-status() {
    if [ -n "$KB_CURRENT_ITEM" ]; then
        echo "📋 $KB_CURRENT_ITEM"
    fi
}

# Help
kb-help() {
    echo ""
    echo "📋 Kanban Helper Commands"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Basic Commands:"
    echo "  kb-list             List all items"
    echo "  kb-backlog          List backlog items"
    echo "  kb-add              Add new item"
    echo "  kb-update <id>      Update item"
    echo "  kb-move <id> <status>  Move item to status"
    echo "  kb-start <id>       Start working on item"
    echo "  kb-done <id>        Mark item as done"
    echo "  kb-view <id>        View item details"
    echo "  kb-search <term>    Search items"
    echo "  kb-stats            Show statistics"
    echo ""
    echo "Worktree Integration:"
    echo "  kb-set-worktree     Set current item from worktree branch"
    echo "  kb-clear            Clear current item"
    echo "  kb-current          Show current item"
    echo ""
    echo "Pull Request Workflow:"
    echo "  kb-pr [id]          Mark item as in review (PR created)"
    echo "  kb-merged [id]      Mark item as merged/done"
    echo ""
    echo "Utility:"
    echo "  kb-team [name]      Switch team context"
    echo "  kb-status           Show current item for status line"
    echo "  kb-help             Show this help"
    echo ""
    echo "Current team: $KANBAN_TEAM"
    if [ -n "$KB_CURRENT_ITEM" ]; then
        echo "Current item: $KB_CURRENT_ITEM"
    fi
    echo ""
}

echo "✓ Kanban helpers loaded (use 'kb-help' for commands)"
