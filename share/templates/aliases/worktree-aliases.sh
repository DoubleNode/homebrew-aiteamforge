#!/bin/zsh
# Git Worktree Helper Functions
# Simplified worktree management for multi-project development

# Installation directory (substituted during install)
AITEAMFORGE_DIR="{{AITEAMFORGE_DIR}}"

#──────────────────────────────────────────────────────────────────────────────
# Configuration
#──────────────────────────────────────────────────────────────────────────────

# Current project context (set by wt-project command)
export WT_CURRENT_PROJECT=""
export WT_CURRENT_BASE=""
export WT_CURRENT_DIR=""

#──────────────────────────────────────────────────────────────────────────────
# Project Detection
#──────────────────────────────────────────────────────────────────────────────

# Detect current git repository
_wt_detect_repo() {
    git rev-parse --show-toplevel 2>/dev/null
}

# Check if currently in a worktree
_wt_in_worktree() {
    local git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
    local git_dir=$(git rev-parse --git-dir 2>/dev/null)

    if [ -z "$git_common_dir" ] || [ -z "$git_dir" ]; then
        return 1
    fi

    # If they differ and common_dir isn't just ".git", we're in a worktree
    if [[ "$git_common_dir" != "$git_dir" ]] && [[ "$git_common_dir" != ".git" ]]; then
        return 0
    fi

    return 1
}

# Get worktree name from current directory
_wt_current_name() {
    if ! _wt_in_worktree; then
        return 1
    fi

    # Current branch name is the worktree identifier
    git branch --show-current 2>/dev/null
}

#──────────────────────────────────────────────────────────────────────────────
# Worktree Management Commands
#──────────────────────────────────────────────────────────────────────────────

# List worktrees
wt-list() {
    local repo=$(_wt_detect_repo)

    if [ -z "$repo" ]; then
        echo "Not in a git repository"
        return 1
    fi

    echo "Worktrees for: $repo"
    echo ""

    cd "$repo" && git worktree list
}

# Create new worktree
wt-create() {
    local branch="$1"
    local base_branch="${2:-develop}"

    if [ -z "$branch" ]; then
        echo "Usage: wt-create <branch-name> [base-branch]"
        echo ""
        echo "Example: wt-create feature/xaca-0001 develop"
        return 1
    fi

    local repo=$(_wt_detect_repo)
    if [ -z "$repo" ]; then
        echo "Not in a git repository"
        return 1
    fi

    # Determine worktree directory
    local worktree_dir
    if [ -n "$WT_CURRENT_DIR" ]; then
        worktree_dir="$WT_CURRENT_DIR/$branch"
    else
        # Default to ../worktrees relative to repo
        worktree_dir="$(dirname "$repo")/worktrees/$branch"
    fi

    echo "Creating worktree: $worktree_dir"
    echo "Base branch: $base_branch"
    echo ""

    cd "$repo" && git worktree add -b "$branch" "$worktree_dir" "$base_branch"

    if [ $? -eq 0 ]; then
        echo ""
        echo "✓ Created worktree successfully"
        echo "To switch: cd $worktree_dir"
    fi
}

# Remove worktree
wt-remove() {
    local branch="$1"

    if [ -z "$branch" ]; then
        echo "Usage: wt-remove <branch-name>"
        echo ""
        echo "Active worktrees:"
        wt-list
        return 1
    fi

    local repo=$(_wt_detect_repo)
    if [ -z "$repo" ]; then
        echo "Not in a git repository"
        return 1
    fi

    echo "Removing worktree: $branch"
    cd "$repo" && git worktree remove "$branch"

    if [ $? -eq 0 ]; then
        echo "✓ Removed worktree successfully"
    fi
}

# Prune deleted worktrees
wt-prune() {
    local repo=$(_wt_detect_repo)
    if [ -z "$repo" ]; then
        echo "Not in a git repository"
        return 1
    fi

    echo "Pruning deleted worktrees..."
    cd "$repo" && git worktree prune

    echo "✓ Pruned worktrees"
}

#──────────────────────────────────────────────────────────────────────────────
# Navigation Commands
#──────────────────────────────────────────────────────────────────────────────

# Jump to main repo
wt-main() {
    local repo=$(_wt_detect_repo)
    if [ -z "$repo" ]; then
        echo "Not in a git repository"
        return 1
    fi

    cd "$repo"
}

# Jump to specific worktree
wt-go() {
    local branch="$1"

    if [ -z "$branch" ]; then
        echo "Usage: wt-go <branch-name>"
        echo ""
        echo "Active worktrees:"
        wt-list
        return 1
    fi

    local repo=$(_wt_detect_repo)
    if [ -z "$repo" ]; then
        echo "Not in a git repository"
        return 1
    fi

    # Find worktree path
    local worktree_path=$(cd "$repo" && git worktree list | grep "$branch" | awk '{print $1}')

    if [ -z "$worktree_path" ]; then
        echo "Worktree not found: $branch"
        return 1
    fi

    cd "$worktree_path"
}

#──────────────────────────────────────────────────────────────────────────────
# Project Context Management
#──────────────────────────────────────────────────────────────────────────────

# Set project context
wt-project() {
    local project="$1"

    if [ -z "$project" ]; then
        echo "Current project: ${WT_CURRENT_PROJECT:-none}"
        echo ""
        echo "Usage: wt-project <project-name>"
        echo ""
        echo "This sets the default worktree directory for wt-create commands"
        return 0
    fi

    local repo=$(_wt_detect_repo)
    if [ -z "$repo" ]; then
        echo "Not in a git repository"
        return 1
    fi

    export WT_CURRENT_PROJECT="$project"
    export WT_CURRENT_BASE="$repo"
    export WT_CURRENT_DIR="$(dirname "$repo")/worktrees"

    echo "✓ Project context set: $project"
    echo "  Base: $repo"
    echo "  Worktrees: $WT_CURRENT_DIR"

    # Also set CURRENT_WORKTREE if we're in one
    if _wt_in_worktree; then
        export CURRENT_WORKTREE=$(_wt_current_name)
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# Status and Info
#──────────────────────────────────────────────────────────────────────────────

# Show worktree status
wt-status() {
    echo ""
    echo "🌿 Worktree Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local repo=$(_wt_detect_repo)
    if [ -z "$repo" ]; then
        echo "Not in a git repository"
        return 0
    fi

    echo "Repository: $repo"

    if _wt_in_worktree; then
        echo "In worktree: $(_wt_current_name)"
        echo "Branch: $(git branch --show-current)"
    else
        echo "In main repository"
    fi

    if [ -n "$WT_CURRENT_PROJECT" ]; then
        echo "Project context: $WT_CURRENT_PROJECT"
    fi

    echo ""
}

# Help
wt-help() {
    echo ""
    echo "🌿 Worktree Helper Commands"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Management:"
    echo "  wt-list                 List all worktrees"
    echo "  wt-create <branch> [base]  Create new worktree"
    echo "  wt-remove <branch>      Remove worktree"
    echo "  wt-prune                Clean up deleted worktrees"
    echo ""
    echo "Navigation:"
    echo "  wt-main                 Jump to main repository"
    echo "  wt-go <branch>          Jump to specific worktree"
    echo ""
    echo "Context:"
    echo "  wt-project [name]       Set/show project context"
    echo "  wt-status               Show current status"
    echo "  wt-help                 Show this help"
    echo ""
    echo "Examples:"
    echo "  wt-create feature/xaca-0001"
    echo "  wt-go feature/xaca-0001"
    echo "  wt-remove feature/xaca-0001"
    echo ""
}

echo "✓ Worktree helpers loaded (use 'wt-help' for commands)"
