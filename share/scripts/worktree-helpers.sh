#!/usr/bin/env zsh
# Git Worktree Helper Functions
# Provides easy worktree management for iOS, Firebase, and Android development

# ═══════════════════════════════════════════════════════════════
# Project Configurations
# ═══════════════════════════════════════════════════════════════

# iOS Project (TNG - Enterprise-D)
export WT_IOS_BASE="/Users/Shared/Development/Main Event/MainEventApp-iOS"
export WT_IOS_DIR="$WT_IOS_BASE/worktrees"
export WT_IOS_MAIN="$WT_IOS_BASE/DEV"

# Firebase Project (DS9 - Deep Space Nine)
export WT_FIREBASE_BASE="/Users/Shared/Development/Main Event/MainEventApp-Functions"
export WT_FIREBASE_DIR="$WT_FIREBASE_BASE/worktrees"
export WT_FIREBASE_MAIN="$WT_FIREBASE_BASE/develop"

# Android Project (TOS - USS Enterprise)
export WT_ANDROID_BASE="/Users/Shared/Development/Main Event/MainEventApp-Android"
export WT_ANDROID_DIR="$WT_ANDROID_BASE/worktrees"
export WT_ANDROID_MAIN="$WT_ANDROID_BASE/develop"

# Freelance Project (ENT - Enterprise NX-01)
# Note: Freelance uses dynamic detection based on current git repo
# These are placeholder defaults - actual values set by _detect_freelance_repo()
export WT_FREELANCE_BASE=""
export WT_FREELANCE_DIR=""
export WT_FREELANCE_MAIN=""

# MainEvent Project (VOY - USS Voyager)
# Note: MainEvent uses dynamic detection based on current git repo
# These are placeholder defaults - actual values set by _detect_mainevent_repo()
export WT_MAINEVENT_BASE=""
export WT_MAINEVENT_DIR=""
export WT_MAINEVENT_MAIN=""

# Academy Project (SFA - Starfleet Academy)
export WT_ACADEMY_BASE="/Users/darrenehlers/dev-team"
export WT_ACADEMY_DIR="$WT_ACADEMY_BASE/worktrees"
export WT_ACADEMY_MAIN="$WT_ACADEMY_BASE"

# Command Project (SFC - Starfleet Command)
export WT_COMMAND_BASE="/Users/Shared/Development/Main Event/dev-team"
export WT_COMMAND_DIR="$(dirname "$WT_COMMAND_BASE")/worktrees/dev-team"
export WT_COMMAND_MAIN="$WT_COMMAND_BASE"

# Finance Project (Ferengi Alliance)
# Note: Finance uses dynamic detection based on PROJECTID
# These are placeholder defaults - actual values set by _detect_finance_repo()
export WT_FINANCE_BASE=""
export WT_FINANCE_DIR=""
export WT_FINANCE_MAIN=""
export WT_FINANCE_MAIN_BRANCH=""

# Medical Project (Medical Division)
# Note: Medical uses dynamic detection based on PROJECTID
# These are placeholder defaults - actual values set by _detect_medical_repo()
export WT_MEDICAL_BASE=""
export WT_MEDICAL_DIR=""
export WT_MEDICAL_MAIN=""
export WT_MEDICAL_MAIN_BRANCH=""

# DNS Framework Project (Lower Decks - USS Cerritos)
# Note: DNS is a workspace of independent sub-repos (DNSCore, DNSError, etc.)
# The base dir is NOT itself a git repo — individual sub-frameworks are
export WT_DNS_BASE="/Users/Shared/Development/DNSFramework"
export WT_DNS_DIR="$WT_DNS_BASE/worktrees"
export WT_DNS_MAIN="$WT_DNS_BASE"
export WT_DNS_MAIN_BRANCH="master"

# Helper to detect freelance repo dynamically
# Optional $1: directory override (e.g., /Users/Shared/Development/DoubleNode/Starwords/develop)
# If not provided, uses current PWD
_detect_freelance_repo() {
    local current_dir="${1:-$PWD}"

    # Find git repo root - but handle worktrees properly
    local repo_root=$(git -C "$current_dir" rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$repo_root" ]; then
        return 1
    fi

    # Check if we're inside a worktree by comparing git-common-dir and git-dir
    # git-common-dir points to the main repo's .git, git-dir points to worktree's .git
    local git_common_dir=$(git -C "$current_dir" rev-parse --git-common-dir 2>/dev/null)
    local git_dir=$(git -C "$current_dir" rev-parse --git-dir 2>/dev/null)

    # If git-common-dir differs from git-dir and isn't just ".git", we're in a worktree
    # The main repo is the parent of git-common-dir
    if [[ "$git_common_dir" != "$git_dir" ]] && [[ "$git_common_dir" != ".git" ]]; then
        # git_common_dir is absolute path to main repo's .git directory
        # e.g., /Users/.../Starwords/develop/.git
        repo_root=$(dirname "$git_common_dir")
    fi

    # Check if this is one of the known Main Event projects
    if [[ "$repo_root" == "$WT_IOS_BASE" ]] || \
       [[ "$repo_root" == "$WT_FIREBASE_BASE" ]] || \
       [[ "$repo_root" == "$WT_ANDROID_BASE" ]]; then
        return 1  # Not a freelance repo
    fi

    # Run git detection in a subshell to avoid cd side-effects
    local result
    result=$(
        cd "$repo_root" || exit 1
        local main_branch=""
        if git show-ref --verify --quiet refs/heads/main; then
            main_branch="main"
        elif git show-ref --verify --quiet refs/heads/master; then
            main_branch="master"
        elif git show-ref --verify --quiet refs/heads/develop; then
            main_branch="develop"
        elif git show-ref --verify --quiet refs/heads/DEV; then
            main_branch="DEV"
        else
            main_branch=$(git branch --show-current 2>/dev/null)
        fi
        local repo_root_name=$(basename "$repo_root")
        local project_root
        if [[ "$repo_root_name" == "develop" ]] || [[ "$repo_root_name" == "main" ]] || [[ "$repo_root_name" == "master" ]] || [[ "$repo_root_name" == "DEV" ]]; then
            project_root=$(dirname "$repo_root")
        else
            project_root="$repo_root"
        fi
        echo "${repo_root}|${project_root}/worktrees|${repo_root}|${main_branch}"
    ) || return 1

    export WT_FREELANCE_BASE="${result%%|*}"; result="${result#*|}"
    export WT_FREELANCE_DIR="${result%%|*}"; result="${result#*|}"
    export WT_FREELANCE_MAIN="${result%%|*}"; result="${result#*|}"
    export WT_FREELANCE_MAIN_BRANCH="$result"

    return 0
}

# Helper to detect mainevent repo dynamically
_detect_mainevent_repo() {
    local current_dir="${1:-$PWD}"

    # Find git repo root - but handle worktrees properly
    local repo_root=$(git -C "$current_dir" rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$repo_root" ]; then
        return 1
    fi

    # Check if we're inside a worktree by comparing git-common-dir and git-dir
    # git-common-dir points to the main repo's .git, git-dir points to worktree's .git
    local git_common_dir=$(git -C "$current_dir" rev-parse --git-common-dir 2>/dev/null)
    local git_dir=$(git -C "$current_dir" rev-parse --git-dir 2>/dev/null)

    # If git-common-dir differs from git-dir and isn't just ".git", we're in a worktree
    # The main repo is the parent of git-common-dir
    if [[ "$git_common_dir" != "$git_dir" ]] && [[ "$git_common_dir" != ".git" ]]; then
        # git_common_dir is absolute path to main repo's .git directory
        repo_root=$(dirname "$git_common_dir")
    fi

    # Check if this is under /Users/Shared/Development/Main Event/
    if [[ "$repo_root" != "/Users/Shared/Development/Main Event/"* ]]; then
        return 1  # Not a MainEvent repo
    fi

    # Check if this is one of the known Main Event app projects (not freelance MainEvent)
    if [[ "$repo_root" == "$WT_IOS_BASE" ]] || \
       [[ "$repo_root" == "$WT_FIREBASE_BASE" ]] || \
       [[ "$repo_root" == "$WT_ANDROID_BASE" ]]; then
        return 1  # This is Main Event app, not freelance MainEvent project
    fi

    # Run git detection in a subshell to avoid cd side-effects
    local result
    result=$(
        cd "$repo_root" || exit 1
        local main_branch=""
        if git show-ref --verify --quiet refs/heads/main; then
            main_branch="main"
        elif git show-ref --verify --quiet refs/heads/master; then
            main_branch="master"
        elif git show-ref --verify --quiet refs/heads/develop; then
            main_branch="develop"
        elif git show-ref --verify --quiet refs/heads/DEV; then
            main_branch="DEV"
        else
            main_branch=$(git branch --show-current 2>/dev/null)
        fi
        local repo_root_name=$(basename "$repo_root")
        local project_root
        if [[ "$repo_root_name" == "develop" ]] || [[ "$repo_root_name" == "main" ]] || [[ "$repo_root_name" == "master" ]] || [[ "$repo_root_name" == "DEV" ]]; then
            project_root=$(dirname "$repo_root")
        else
            project_root="$repo_root"
        fi
        echo "${repo_root}|${project_root}/worktrees|${repo_root}|${main_branch}"
    ) || return 1

    export WT_MAINEVENT_BASE="${result%%|*}"; result="${result#*|}"
    export WT_MAINEVENT_DIR="${result%%|*}"; result="${result#*|}"
    export WT_MAINEVENT_MAIN="${result%%|*}"; result="${result#*|}"
    export WT_MAINEVENT_MAIN_BRANCH="$result"

    return 0
}

# Shared helper to detect a projectID-based repo dynamically
# Usage: _detect_projectid_repo <team> <base_dir> <default_project> [explicit_project]
# Sets WT_<TEAM>_BASE, WT_<TEAM>_DIR, WT_<TEAM>_MAIN, WT_<TEAM>_MAIN_BRANCH
# Runs git operations in a subshell to avoid cd side-effects on the caller
_detect_projectid_repo() {
    local team="$1"
    local base_dir="$2"
    local default_project="$3"
    local explicit_project="${4:-}"
    local project_id="$default_project"

    # If explicit project given, use it; otherwise try to detect from PWD
    if [ -n "$explicit_project" ]; then
        project_id="$explicit_project"
    elif [[ "$PWD" == "$base_dir"/* ]]; then
        local rel="${PWD#$base_dir/}"
        project_id="${rel%%/*}"
    fi

    local base_path="$base_dir/$project_id"

    # Check the directory exists
    if [ ! -d "$base_path" ]; then
        return 1
    fi

    # Run git detection in a subshell to avoid cd side-effects
    local result
    result=$(
        local repo_root=$(git -C "$base_path" rev-parse --show-toplevel 2>/dev/null)
        if [ -z "$repo_root" ]; then
            exit 1
        fi

        # Handle worktree: if git-common-dir differs from git-dir, use parent of git-common-dir
        local git_common_dir=$(git -C "$base_path" rev-parse --git-common-dir 2>/dev/null)
        local git_dir=$(git -C "$base_path" rev-parse --git-dir 2>/dev/null)
        if [[ "$git_common_dir" != "$git_dir" ]] && [[ "$git_common_dir" != ".git" ]]; then
            repo_root=$(dirname "$git_common_dir")
        fi

        # Detect main branch (check for main, master, develop, DEV in order)
        local main_branch=""
        cd "$repo_root" || exit 1
        if git show-ref --verify --quiet refs/heads/main; then
            main_branch="main"
        elif git show-ref --verify --quiet refs/heads/master; then
            main_branch="master"
        elif git show-ref --verify --quiet refs/heads/develop; then
            main_branch="develop"
        elif git show-ref --verify --quiet refs/heads/DEV; then
            main_branch="DEV"
        else
            main_branch=$(git branch --show-current 2>/dev/null)
        fi

        # Determine project root for worktrees
        local repo_root_name project_root
        repo_root_name=$(basename "$repo_root")
        if [[ "$repo_root_name" == "develop" ]] || [[ "$repo_root_name" == "main" ]] || [[ "$repo_root_name" == "master" ]] || [[ "$repo_root_name" == "DEV" ]]; then
            project_root=$(dirname "$repo_root")
        else
            project_root="$repo_root"
        fi

        # Output pipe-delimited results for the parent shell to parse
        echo "${repo_root}|${project_root}/worktrees|${repo_root}|${main_branch}"
    ) || return 1

    local team_upper=$(echo "$team" | tr '[:lower:]' '[:upper:]')
    local repo_root_val="${result%%|*}"; result="${result#*|}"
    local dir_val="${result%%|*}"; result="${result#*|}"
    local main_val="${result%%|*}"; result="${result#*|}"
    local branch_val="$result"

    export "WT_${team_upper}_BASE=$repo_root_val"
    export "WT_${team_upper}_DIR=$dir_val"
    export "WT_${team_upper}_MAIN=$main_val"
    export "WT_${team_upper}_MAIN_BRANCH=$branch_val"

    return 0
}

# Get the main branch name for the current project
# Dynamic projects store their branch in WT_<PROJECT>_MAIN_BRANCH
# Static projects derive it from basename of WT_MAIN
_wt_get_main_branch() {
    case "$WT_PROJECT" in
        freelance) echo "$WT_FREELANCE_MAIN_BRANCH" ;;
        mainevent) echo "$WT_MAINEVENT_MAIN_BRANCH" ;;
        finance)   echo "$WT_FINANCE_MAIN_BRANCH" ;;
        medical)   echo "$WT_MEDICAL_MAIN_BRANCH" ;;
        dns)       echo "$WT_DNS_MAIN_BRANCH" ;;
        *)         basename "$WT_MAIN" ;;
    esac
}

# Detect finance repo — thin wrapper around shared helper
_detect_finance_repo() {
    _detect_projectid_repo "finance" "$HOME/finance" "personal" "$1"
}

# Detect medical repo — thin wrapper around shared helper
_detect_medical_repo() {
    _detect_projectid_repo "medical" "$HOME/medical" "general" "$1"
}

# Helper to get the appropriate remote name dynamically
# Priority: 1) WT_REMOTE env var, 2) current branch tracking, 3) first available remote
_wt_get_remote() {
    # 1. Check for environment variable override
    if [[ -n "$WT_REMOTE" ]]; then
        echo "$WT_REMOTE"
        return
    fi

    # 2. Try to get remote from current branch's tracking configuration
    local current_branch=$(git branch --show-current 2>/dev/null)
    if [[ -n "$current_branch" ]]; then
        local tracking_remote=$(git config --get "branch.${current_branch}.remote" 2>/dev/null)
        if [[ -n "$tracking_remote" ]]; then
            echo "$tracking_remote"
            return
        fi
    fi

    # 3. Fall back to first available remote (usually the only one)
    local first_remote=$(git remote | head -1)
    if [[ -n "$first_remote" ]]; then
        echo "$first_remote"
        return
    fi

    # 4. Ultimate fallback to "origin" if no remotes detected
    echo "origin"
}

# Check if a branch has a merged PR on GitHub
# Uses gh CLI as the authoritative merge signal (handles squash merges)
# Returns 0 and outputs "NUMBER|TITLE" if merged, returns 1 otherwise
_wt_check_pr_merged() {
    local branch="$1"
    if [ -z "$branch" ]; then
        return 1
    fi

    # Gracefully handle gh not installed
    if ! command -v gh &>/dev/null; then
        return 1
    fi

    # Query GitHub for a merged PR associated with this branch
    local result
    result=$(gh pr view "$branch" --json state,number,title \
        --jq 'select(.state == "MERGED") | "\(.number)|\(.title)"' 2>/dev/null)

    if [ -n "$result" ]; then
        echo "$result"
        return 0
    fi

    return 1
}

# Classify a branch's safety for worktree removal.
# Extracted from wt-finish so that _kb_offer_worktree_cleanup (kanban-helpers.sh)
# and wt-finish AGREE on the same safety determination — avoiding sibling drift
# (a single authoritative classifier beats two independent copies, per k501 pattern).
#
# Usage: _wt_classify_branch <branch> [worktree_path]
# Echoes one token:
#   merged           → PR merged OR no unmerged commits ahead of main (safe to remove)
#   unmerged-commits → local commits not yet on main/remote (UNSAFE — would lose work)
#   remote-gone      → remote was deleted but local commits remain (caution)
# Returns 0 always; classification is via stdout.
_wt_classify_branch() {
    local branch="${1-}"
    local worktree_path="${2-}"
    # Optional 3rd arg: a pre-fetched _wt_check_pr_merged result. When the caller
    # already ran the PR check (e.g. wt-finish needs pr_number/pr_title for display),
    # it threads the result here so we don't pay a second GitHub round-trip
    # (XACA-0598-012). A non-empty value means "PR is merged".
    local pr_info pr_prefetched=0
    if [ $# -ge 3 ]; then
        pr_info="${3-}"
        pr_prefetched=1
    fi

    if [ -z "$branch" ]; then
        echo "unmerged-commits"
        return 0
    fi

    # PRIMARY: GitHub PR state (authoritative for squash merges)
    if [ "$pr_prefetched" -eq 0 ]; then
        pr_info=$(_wt_check_pr_merged "$branch")
    fi
    if [ -n "$pr_info" ]; then
        echo "merged"
        return 0
    fi

    # FALLBACK: git-based heuristic — run from worktree_path or cwd
    local git_dir="${worktree_path:-.}"
    local main_branch
    main_branch=$(_wt_get_main_branch)
    # Guard: if project context not set, derive main branch from the remote HEAD ref
    if [ -z "$main_branch" ]; then
        main_branch=$(git -C "$git_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
    fi
    if [ -z "$main_branch" ]; then
        main_branch="develop"
    fi

    # Count commits on the branch not yet on main. Capture git's own exit code
    # (not the pipe's) — if the range can't be resolved (e.g. invalid main_branch
    # ref), git fails and an empty stdout would otherwise count as 0 → a false
    # 'merged' classification. Conservative fallback: treat that as unsafe
    # (XACA-0598-015).
    local log_out log_rc
    log_out=$(git -C "$git_dir" log --oneline "${main_branch}..${branch}" 2>/dev/null)
    log_rc=$?
    if [ $log_rc -ne 0 ]; then
        echo "unmerged-commits"
        return 0
    fi
    local unmerged_commits
    if [ -z "$log_out" ]; then
        unmerged_commits=0
    else
        unmerged_commits=$(printf '%s\n' "$log_out" | wc -l | tr -d ' ')
    fi

    local remote_ref
    remote_ref=$(git -C "$git_dir" rev-parse --abbrev-ref "${branch}@{upstream}" 2>/dev/null)
    local remote_exists=$?

    if [ $remote_exists -ne 0 ]; then
        # Remote branch is gone
        if [ "${unmerged_commits}" -eq 0 ]; then
            echo "merged"
        else
            echo "remote-gone"
        fi
    else
        # Remote still exists
        if [ "${unmerged_commits}" -eq 0 ]; then
            echo "merged"
        else
            echo "unmerged-commits"
        fi
    fi
    return 0
}

# No default project - each terminal's .zshrc sets its own context
# (iOS/Android/Firebase .zshrc files call wt-project explicitly)
export WT_BASE=""
export WT_DIR=""
export WT_MAIN=""
export WT_PROJECT=""

# Ensure worktrees directories exist for Main Event projects
mkdir -p "$WT_IOS_DIR"
mkdir -p "$WT_FIREBASE_DIR"
mkdir -p "$WT_ANDROID_DIR"
mkdir -p "$WT_ACADEMY_DIR"
mkdir -p "$WT_COMMAND_DIR"
mkdir -p "$WT_DNS_DIR"
# Note: Freelance, Finance, and Medical worktrees directories created dynamically per-repo

# ═══════════════════════════════════════════════════════════════
# Project Selection Function
# ═══════════════════════════════════════════════════════════════

# Set current project context
wt-project() {
    local project="$1"

    case "$project" in
        ios|iOS)
            export WT_BASE="$WT_IOS_BASE"
            export WT_DIR="$WT_IOS_DIR"
            export WT_MAIN="$WT_IOS_MAIN"
            export WT_PROJECT="ios"
            echo "📱 Switched to iOS project (TNG - Enterprise-D)"
            echo "   Base: $WT_BASE"
            echo "   Main Branch: DEV"
            ;;
        firebase|fb|FB)
            export WT_BASE="$WT_FIREBASE_BASE"
            export WT_DIR="$WT_FIREBASE_DIR"
            export WT_MAIN="$WT_FIREBASE_MAIN"
            export WT_PROJECT="firebase"
            echo "🔥 Switched to Firebase project (DS9 - Deep Space Nine)"
            echo "   Base: $WT_BASE"
            echo "   Main Branch: develop"
            ;;
        android|droid|AND)
            export WT_BASE="$WT_ANDROID_BASE"
            export WT_DIR="$WT_ANDROID_DIR"
            export WT_MAIN="$WT_ANDROID_MAIN"
            export WT_PROJECT="android"
            echo "🤖 Switched to Android project (TOS - USS Enterprise)"
            echo "   Base: $WT_BASE"
            echo "   Main Branch: develop"
            ;;
        freelance|free|fl|FL)
            local fl_groupid="${2:-}"
            local fl_projectid="${3:-}"
            local fl_detect_dir=""

            if [ -n "$fl_groupid" ] && [ -n "$fl_projectid" ]; then
                # Both GROUPID and PROJECTID given: full path
                fl_detect_dir="/Users/Shared/Development/$fl_groupid/$fl_projectid"
            elif [ -n "$fl_groupid" ]; then
                # Only GROUPID given: treat as project name under DoubleNode
                fl_detect_dir="/Users/Shared/Development/DoubleNode/$fl_groupid"
            fi
            # If neither given, _detect_freelance_repo uses PWD (existing behavior)

            # When a direct path isn't a git repo, probe for branch-named subdirectories
            # (e.g., DoubleNode/Starwords/develop/ is the actual git repo, not Starwords/)
            if [ -n "$fl_detect_dir" ] && [ -d "$fl_detect_dir" ] && ! git -C "$fl_detect_dir" rev-parse --show-toplevel &>/dev/null; then
                for subdir in develop main master DEV; do
                    if [ -d "$fl_detect_dir/$subdir" ]; then
                        fl_detect_dir="$fl_detect_dir/$subdir"
                        break
                    fi
                done
            fi

            if ! _detect_freelance_repo "$fl_detect_dir"; then
                echo "❌ Not in a git repository or in a Main Event project"
                echo ""
                echo "💡 Usage:"
                echo "   wt-project freelance                    (detect from current directory)"
                echo "   wt-project freelance ProjectName        (DoubleNode/ProjectName)"
                echo "   wt-project freelance GroupID ProjectID  (GroupID/ProjectID)"
                echo ""
                echo "   cd /Users/Shared/Development/DoubleNode/client-name"
                echo "   wt-project freelance"
                return 1
            fi
            export WT_BASE="$WT_FREELANCE_BASE"
            export WT_DIR="$WT_FREELANCE_DIR"
            export WT_MAIN="$WT_FREELANCE_MAIN"
            export WT_PROJECT="freelance"
            # Create worktrees directory if needed
            mkdir -p "$WT_DIR"
            echo "🚀 Switched to Freelance project (ENT - Enterprise NX-01)"
            echo "   Repo: $(basename "$WT_BASE")"
            echo "   Base: $WT_BASE"
            echo "   Main Branch: $WT_FREELANCE_MAIN_BRANCH"
            ;;
        mainevent|me|ME)
            # Detect mainevent repo from current directory
            if ! _detect_mainevent_repo; then
                echo "❌ Not in a MainEvent project directory"
                echo ""
                echo "💡 Navigate to a MainEvent project directory first:"
                echo "   cd /Users/Shared/Development/Main\\ Event/ProjectName/develop"
                echo "   wt-project mainevent"
                return 1
            fi
            export WT_BASE="$WT_MAINEVENT_BASE"
            export WT_DIR="$WT_MAINEVENT_DIR"
            export WT_MAIN="$WT_MAINEVENT_MAIN"
            export WT_PROJECT="mainevent"
            # Create worktrees directory if needed
            mkdir -p "$WT_DIR"
            echo "🛸 Switched to MainEvent project (VOY - USS Voyager)"
            echo "   Repo: $(basename "$WT_BASE")"
            echo "   Base: $WT_BASE"
            echo "   Main Branch: $WT_MAINEVENT_MAIN_BRANCH"
            ;;
        academy|ac|AC|sfa|SFA)
            export WT_BASE="$WT_ACADEMY_BASE"
            export WT_DIR="$WT_ACADEMY_DIR"
            export WT_MAIN="$WT_ACADEMY_MAIN"
            export WT_PROJECT="academy"
            echo "🎓 Switched to Academy project (SFA - Starfleet Academy)"
            echo "   Base: $WT_BASE"
            echo "   Main Branch: develop"
            ;;
        command|cmd|CMD|sfc|SFC)
            export WT_BASE="$WT_COMMAND_BASE"
            export WT_DIR="$WT_COMMAND_DIR"
            export WT_MAIN="$WT_COMMAND_MAIN"
            export WT_PROJECT="command"
            echo "⭐ Switched to Command project (SFC - Starfleet Command)"
            echo "   Base: $WT_BASE"
            echo "   Main Branch: develop"
            ;;
        finance|fin|FIN)
            local finance_project="${2:-}"
            if ! _detect_finance_repo "$finance_project"; then
                echo "❌ Finance project not found"
                echo ""
                echo "💡 Usage:"
                echo "   wt-project finance              (uses 'personal' default)"
                echo "   wt-project finance personal"
                return 1
            fi
            export WT_BASE="$WT_FINANCE_BASE"
            export WT_DIR="$WT_FINANCE_DIR"
            export WT_MAIN="$WT_FINANCE_MAIN"
            export WT_PROJECT="finance"
            mkdir -p "$WT_DIR"
            echo "💰 Switched to Finance project (Ferengi Alliance)"
            echo "   Project: ${finance_project:-personal}"
            echo "   Base: $WT_BASE"
            echo "   Main Branch: $WT_FINANCE_MAIN_BRANCH"
            ;;
        medical|med|MED)
            local medical_project="${2:-}"
            if ! _detect_medical_repo "$medical_project"; then
                echo "❌ Medical project not found"
                echo ""
                echo "💡 Usage:"
                echo "   wt-project medical              (uses 'general' default)"
                echo "   wt-project medical general"
                return 1
            fi
            export WT_BASE="$WT_MEDICAL_BASE"
            export WT_DIR="$WT_MEDICAL_DIR"
            export WT_MAIN="$WT_MEDICAL_MAIN"
            export WT_PROJECT="medical"
            mkdir -p "$WT_DIR"
            echo "🏥 Switched to Medical project (Medical Division)"
            echo "   Project: ${medical_project:-general}"
            echo "   Base: $WT_BASE"
            echo "   Main Branch: $WT_MEDICAL_MAIN_BRANCH"
            ;;
        dns|DNS)
            export WT_BASE="$WT_DNS_BASE"
            export WT_DIR="$WT_DNS_DIR"
            export WT_MAIN="$WT_DNS_MAIN"
            export WT_PROJECT="dns"
            echo "🧬 Switched to DNS Framework project (Lower Decks - USS Cerritos)"
            echo "   Base: $WT_BASE"
            echo "   Main Branch: $WT_DNS_MAIN_BRANCH"
            ;;
        status)
            echo ""
            echo "🖖 Current Worktree Project Status"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            if [ -z "$WT_PROJECT" ]; then
                echo "❌ No project context set"
                echo ""
                echo "Use: wt-project [ios|firebase|android|freelance|mainevent|academy|command|finance|medical|dns]"
            else
                case "$WT_PROJECT" in
                    ios) echo "📱 Current: iOS (TNG - Enterprise-D)" ;;
                    firebase) echo "🔥 Current: Firebase (DS9 - Deep Space Nine)" ;;
                    android) echo "🤖 Current: Android (TOS - USS Enterprise)" ;;
                    freelance)
                        echo "🚀 Current: Freelance (ENT - Enterprise NX-01)"
                        echo "   Repo: $(basename "$WT_BASE")"
                        ;;
                    mainevent)
                        echo "🛸 Current: MainEvent (VOY - USS Voyager)"
                        echo "   Repo: $(basename "$WT_BASE")"
                        ;;
                    academy) echo "🎓 Current: Academy (SFA - Starfleet Academy)" ;;
                    command) echo "⭐ Current: Command (SFC - Starfleet Command)" ;;
                    finance)
                        echo "💰 Current: Finance (Ferengi Alliance)"
                        echo "   Project: $(basename "$WT_BASE")"
                        ;;
                    medical)
                        echo "🏥 Current: Medical (Medical Division)"
                        echo "   Project: $(basename "$WT_BASE")"
                        ;;
                    dns) echo "🧬 Current: DNS Framework (Lower Decks - USS Cerritos)" ;;
                esac
                echo "   Base: $WT_BASE"
                echo "   Worktrees: $WT_DIR"
                if [ "$WT_PROJECT" = "freelance" ]; then
                    echo "   Main Branch: $WT_FREELANCE_MAIN_BRANCH"
                elif [ "$WT_PROJECT" = "mainevent" ]; then
                    echo "   Main Branch: $WT_MAINEVENT_MAIN_BRANCH"
                elif [ "$WT_PROJECT" = "finance" ]; then
                    echo "   Main Branch: $WT_FINANCE_MAIN_BRANCH"
                elif [ "$WT_PROJECT" = "medical" ]; then
                    echo "   Main Branch: $WT_MEDICAL_MAIN_BRANCH"
                elif [ "$WT_PROJECT" = "dns" ]; then
                    echo "   Main Branch: $WT_DNS_MAIN_BRANCH"
                else
                    echo "   Main: $WT_MAIN"
                fi
            fi
            echo ""
            ;;
        status-short)
            # Single line output: current worktree path
            if [ -z "$WT_PROJECT" ] || [ -z "$WT_MAIN" ]; then
                echo "No project context set"
            elif [ -n "$CURRENT_WORKTREE" ]; then
                if [ "$CURRENT_WORKTREE" = "DEV" ] || [ "$CURRENT_WORKTREE" = "develop" ] || [ "$CURRENT_WORKTREE" = "main" ] || [ "$CURRENT_WORKTREE" = "master" ]; then
                    echo "$WT_MAIN"
                else
                    echo "$WT_DIR/$CURRENT_WORKTREE"
                fi
            else
                echo "$WT_MAIN"
            fi
            ;;
        status-name)
            # Output just the project name
            if [ -z "$WT_PROJECT" ]; then
                echo "No project"
            else
                case "$WT_PROJECT" in
                    ios) echo "iOS project (TNG)" ;;
                    firebase) echo "Firebase project (DS9)" ;;
                    android) echo "Android project (TOS)" ;;
                    freelance) echo "Freelance project (ENT)" ;;
                    mainevent) echo "MainEvent project (VOY)" ;;
                    academy) echo "Academy project (SFA)" ;;
                    command) echo "Command project (SFC)" ;;
                    finance) echo "Finance project (FER)" ;;
                    medical) echo "Medical project (MED)" ;;
                    dns) echo "DNS Framework project (LD)" ;;
                    *) echo "Unknown project" ;;
                esac
            fi
            ;;
        status-code)
            # Output just the project code
            if [ -z "$WT_PROJECT" ]; then
                echo "none"
            else
                echo "$WT_PROJECT"
            fi
            ;;
        *)
            echo "Usage: wt-project [ios|firebase|android|freelance|mainevent|academy|command|finance|medical|dns|status|...]"
            echo ""
            echo "Projects:"
            echo "  📱 ios        - iOS project (TNG)"
            echo "  🔥 firebase   - Firebase project (DS9)"
            echo "  🤖 android    - Android project (TOS)"
            echo "  🚀 freelance  - Freelance project (ENT)"
            echo "  🛸 mainevent  - MainEvent project (VOY)"
            echo "  🎓 academy    - Academy project (SFA)"
            echo "  ⭐ command    - Command project (SFC)"
            echo "  💰 finance    - Finance project (FER)"
            echo "  🏥 medical    - Medical project (MED)"
            echo "  🧬 dns        - DNS Framework project (LD)"
            echo ""
            echo "Status Commands:"
            echo "  📊 status      - Show full current project details"
            echo "  📍 status-short - Show current worktree path"
            echo "  🏷️  status-name - Show project name only (e.g., 'Freelance project (ENT)')"
            echo "  🔤 status-code - Show project code only (e.g., 'freelance')"
            echo ""
            echo "Examples:"
            echo "  wt-project ios                              Switch to iOS worktrees"
            echo "  wt-project firebase                         Switch to Firebase worktrees"
            echo "  wt-project android                          Switch to Android worktrees"
            echo "  wt-project freelance                        Switch to Freelance worktrees (detect from PWD)"
            echo "  wt-project freelance Starwords              Switch to DoubleNode/Starwords"
            echo "  wt-project freelance DoubleNode Starwords   Switch to DoubleNode/Starwords (explicit)"
            echo "  wt-project academy                          Switch to Academy worktrees"
            echo "  wt-project command                          Switch to Command worktrees"
            echo "  wt-project finance                          Switch to Finance project (personal)"
            echo "  wt-project finance personal                 Switch to Finance/personal project"
            echo "  wt-project medical                          Switch to Medical project (general)"
            echo "  wt-project medical general                  Switch to Medical/general project"
            echo "  wt-project dns                              Switch to DNS Framework worktrees"
            echo "  wt-project status                           Show current project"
            echo "  wt-project status-name                      Output: 'Freelance project (ENT)'"
            echo "  wt-project status-code                      Output: 'freelance'"
            return 1
            ;;
    esac
}

# ============================================================================
# Core Worktree Functions
# ============================================================================

# Create new worktree with branch
wt-new() {
    # Check if project context is set
    if [ -z "$WT_PROJECT" ] || [ -z "$WT_MAIN" ]; then
        echo "❌ No project context set"
        echo ""
        echo "First, set a project context:"
        echo "  wt-project ios         → Switch to iOS project"
        echo "  wt-project firebase    → Switch to Firebase project"
        echo "  wt-project android     → Switch to Android project"
        echo "  wt-project freelance   → Switch to Freelance project"
        echo "  wt-project academy     → Switch to Academy project"
        echo "  wt-project command     → Switch to Command project"
        echo "  wt-project finance     → Switch to Finance project"
        echo "  wt-project medical     → Switch to Medical project"
        echo "  wt-project dns         → Switch to DNS Framework project"
        return 1
    fi

    # DNS base is a workspace, not a git repo — worktrees must be created per sub-framework
    if [ "$WT_PROJECT" = "dns" ]; then
        echo "⚠️  DNS Framework is a workspace of independent sub-repos"
        echo "   wt-new cannot create worktrees at the workspace level"
        echo ""
        echo "💡 Navigate into a specific sub-framework first:"
        echo "   cd /Users/Shared/Development/DNSFramework/DNSFramework-iOS/DNSCore"
        echo "   wt-project freelance   # treat individual framework as freelance project"
        echo "   wt-new feature-name"
        return 1
    fi

    local name="$1"

    if [ -z "$name" ]; then
        echo "Usage: wt-new <branch-name>"
        echo ""
        echo "Examples:"
        echo "  wt-new feature-booking-flow        → feature/booking-flow"
        echo "  wt-new bugfix-crash-reload         → bugfix/crash-reload"
        echo "  wt-new refactor-api-client         → refactor/api-client"
        echo "  wt-new release-ios26               → release/ios26"
        echo "  wt-new docs-architecture           → docs/architecture"
        echo "  wt-new test-accessibility          → test/accessibility"
        return 1
    fi

    # Infer branch name from worktree name
    local branch
    if [[ "$name" =~ ^(feature|bugfix|hotfix|refactor|perf|release|docs|test|chore|style)-(.+)$ ]]; then
        local prefix="${match[1]}"
        local suffix="${match[2]}"
        branch="$prefix/${suffix//-//}"
    else
        # Default to feature if no prefix
        branch="feature/${name//-//}"
        name="feature-$name"
    fi

    local wt_path="$WT_DIR/$name"

    # Check if worktree already exists
    if [ -d "$wt_path" ]; then
        echo "⚠️  Worktree already exists: $name"
        echo "📁 Location: $wt_path"
        echo ""
        echo "Use: wt $name (to switch to it)"
        return 1
    fi

    echo "🔨 Creating worktree..."
    # Show current project
    case "$WT_PROJECT" in
        ios) echo "📱 Project: iOS (TNG)" ;;
        firebase) echo "🔥 Project: Firebase (DS9)" ;;
        android) echo "🤖 Project: Android (TOS)" ;;
        freelance) echo "🚀 Project: Freelance (ENT)" ;;
        mainevent) echo "🛸 Project: MainEvent (VOY)" ;;
        academy) echo "🎓 Project: Academy (SFA)" ;;
        command) echo "⭐ Project: Command (SFC)" ;;
        finance) echo "💰 Project: Finance (FER)" ;;
        medical) echo "🏥 Project: Medical (MED)" ;;
        dns) echo "🧬 Project: DNS Framework (LD)" ;;
    esac
    echo "📁 Name: $name"
    echo "📂 Location: $wt_path"
    echo "🌿 Branch: $branch"
    echo ""

    cd "$WT_MAIN" || return 1

    local main_branch=$(_wt_get_main_branch)

    # Check if branch already exists
    if git show-ref --verify --quiet "refs/heads/$branch"; then
        echo "⚠️  Branch '$branch' already exists"
        echo "Creating worktree from existing branch..."
        git worktree add "$wt_path" "$branch"
    else
        echo "Creating new branch from $main_branch..."
        git worktree add -b "$branch" "$wt_path" "$main_branch"
    fi

    if [ $? -eq 0 ]; then
        echo ""
        echo "✅ Worktree created successfully!"
        echo ""

        cd "$wt_path"

        # XACA-0588: deploy team personas into the new worktree's .claude/agents
        # (tap-machine equivalent of kb-sync-personas sync-worktrees, which is dev-only).
        # No-op on dev machines (helper detects ~/aiteamforge absent) and when the
        # helper isn't installed. Personas land UNTRACKED — intentionally ephemeral.
        local _dwp="${AITEAMFORGE_DIR:-$HOME/aiteamforge}/scripts/deploy-worktree-personas.sh"
        if [ -x "$_dwp" ]; then
            "$_dwp" "$wt_path" "$WT_PROJECT" || true
        fi

        # Update tmux if in tmux
        if [ -n "$TMUX" ]; then
            tmux set-option @current_worktree "$name" 2>/dev/null
            local agent=$(tmux show-options -v @claude_agent 2>/dev/null)
            if [ -n "$agent" ]; then
                tmux set-option status-right "🌿 $name | 🤖 $agent | 🖥  #h  " 2>/dev/null
            else
                tmux set-option status-right "🌿 $name | 🖥  #h  " 2>/dev/null
            fi
        fi

        export CURRENT_WORKTREE="$name"

        echo "📍 You are now in: $name"
        git status --short --branch
    else
        echo ""
        echo "❌ Failed to create worktree"
        return 1
    fi
}

# Switch to existing worktree
wt() {
    # Check if project context is set
    if [ -z "$WT_PROJECT" ] || [ -z "$WT_DIR" ]; then
        echo "❌ No project context set"
        echo ""
        echo "First, set a project context:"
        echo "  wt-project ios         → Switch to iOS project"
        echo "  wt-project firebase    → Switch to Firebase project"
        echo "  wt-project android     → Switch to Android project"
        echo "  wt-project freelance   → Switch to Freelance project"
        echo "  wt-project academy     → Switch to Academy project"
        echo "  wt-project command     → Switch to Command project"
        return 1
    fi

    local name="$1"

    if [ -z "$name" ]; then
        echo "Usage: wt <worktree-name>"
        echo ""
        echo "📋 Available worktrees:"
        wt-list
        return 1
    fi

    local wt_path="$WT_DIR/$name"

    if [ ! -d "$wt_path" ]; then
        echo "❌ Worktree not found: $name"
        echo ""
        echo "📋 Available worktrees:"
        wt-list
        echo ""
        echo "💡 Create it with: wt-new $name"
        return 1
    fi

    cd "$wt_path" || return 1

    # Update tmux if in tmux
    if [ -n "$TMUX" ]; then
        tmux set-option @current_worktree "$name" 2>/dev/null
        local agent=$(tmux show-options -v @claude_agent 2>/dev/null)
        if [ -n "$agent" ]; then
            tmux set-option status-right "🌿 $name | 🤖 $agent | 🖥  #h  " 2>/dev/null
        else
            tmux set-option status-right "🌿 $name | 🖥  #h  " 2>/dev/null
        fi
    fi

    export CURRENT_WORKTREE="$name"

    echo "📁 Switched to: $name"
    git status --short --branch
}

# List all worktrees
wt-list() {
    # Check if project context is set
    if [ -z "$WT_PROJECT" ] || [ -z "$WT_DIR" ]; then
        echo ""
        echo "❌ No project context set"
        echo ""
        echo "First, set a project context:"
        echo "  wt-project ios         → Switch to iOS project"
        echo "  wt-project firebase    → Switch to Firebase project"
        echo "  wt-project android     → Switch to Android project"
        echo "  wt-project freelance   → Switch to Freelance project"
        echo "  wt-project academy     → Switch to Academy project"
        echo "  wt-project command     → Switch to Command project"
        echo "  wt-project finance     → Switch to Finance project"
        echo "  wt-project medical     → Switch to Medical project"
        echo "  wt-project dns         → Switch to DNS Framework project"
        echo ""
        return 1
    fi

    echo ""
    # Show current project
    case "$WT_PROJECT" in
        ios) echo "📱 iOS Project (TNG - Enterprise-D)" ;;
        firebase) echo "🔥 Firebase Project (DS9 - Deep Space Nine)" ;;
        android) echo "🤖 Android Project (TOS - USS Enterprise)" ;;
        freelance)
            echo "🚀 Freelance Project (ENT - Enterprise NX-01)"
            echo "   Repo: $(basename "$WT_BASE")"
            ;;
        mainevent)
            echo "🛸 MainEvent Project (VOY - USS Voyager)"
            echo "   Repo: $(basename "$WT_BASE")"
            ;;
        academy) echo "🎓 Academy Project (SFA - Starfleet Academy)" ;;
        command) echo "⭐ Command Project (SFC - Starfleet Command)" ;;
        finance) echo "💰 Finance Project (Ferengi Alliance)" ;;
        medical) echo "🏥 Medical Project (Medical Division)" ;;
        dns) echo "🧬 DNS Framework Project (Lower Decks - USS Cerritos)" ;;
        *) echo "📂 Current Project: ${WT_PROJECT:-unknown}" ;;
    esac
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [ ! -d "$WT_DIR" ] || [ -z "$(ls -A "$WT_DIR" 2>/dev/null)" ]; then
        echo "No worktrees found."
        echo ""
        echo "💡 Create one with: wt-new <branch-name>"
        return
    fi

    cd "$WT_MAIN" || return 1

    # Get worktree info from git
    git worktree list --porcelain | awk -v wt_dir="$WT_DIR" '
        /^worktree / { path = substr($0, 10) }
        /^branch / {
            branch = substr($0, 8)
            gsub(/^refs\/heads\//, "", branch)
        }
        /^$/ {
            if (index(path, wt_dir) == 1) {
                name = substr(path, length(wt_dir) + 2)
                printf "  🌿 %-30s %s\n", name, branch
            }
            path = ""
            branch = ""
        }
    '
    echo ""
}

# Show detailed status of all worktrees
wt-status() {
    # Check if project context is set
    if [ -z "$WT_PROJECT" ] || [ -z "$WT_DIR" ]; then
        echo ""
        echo "❌ No project context set"
        echo ""
        echo "First, set a project context:"
        echo "  wt-project ios         → Switch to iOS project"
        echo "  wt-project firebase    → Switch to Firebase project"
        echo "  wt-project android     → Switch to Android project"
        echo "  wt-project freelance   → Switch to Freelance project"
        echo "  wt-project academy     → Switch to Academy project"
        echo "  wt-project command     → Switch to Command project"
        echo "  wt-project finance     → Switch to Finance project"
        echo "  wt-project medical     → Switch to Medical project"
        echo "  wt-project dns         → Switch to DNS Framework project"
        echo ""
        return 1
    fi

    echo ""
    # Show current project
    case "$WT_PROJECT" in
        ios) echo "📱 iOS Project (TNG - Enterprise-D)" ;;
        firebase) echo "🔥 Firebase Project (DS9 - Deep Space Nine)" ;;
        android) echo "🤖 Android Project (TOS - USS Enterprise)" ;;
        freelance)
            echo "🚀 Freelance Project (ENT - Enterprise NX-01)"
            echo "   Repo: $(basename "$WT_BASE")"
            ;;
        mainevent)
            echo "🛸 MainEvent Project (VOY - USS Voyager)"
            echo "   Repo: $(basename "$WT_BASE")"
            ;;
        academy) echo "🎓 Academy Project (SFA - Starfleet Academy)" ;;
        command) echo "⭐ Command Project (SFC - Starfleet Command)" ;;
        finance) echo "💰 Finance Project (Ferengi Alliance)" ;;
        medical) echo "🏥 Medical Project (Medical Division)" ;;
        dns) echo "🧬 DNS Framework Project (Lower Decks - USS Cerritos)" ;;
        *) echo "📂 Current Project: ${WT_PROJECT:-unknown}" ;;
    esac
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "📊 Worktree Status:"
    echo ""

    if [ ! -d "$WT_DIR" ] || [ -z "$(ls -A "$WT_DIR" 2>/dev/null)" ]; then
        echo "No worktrees found."
        echo ""
        return
    fi

    for dir in "$WT_DIR"/*; do
        if [ -d "$dir" ]; then
            local name=$(basename "$dir")
            echo "🌿 $name"
            cd "$dir" || continue

            local branch=$(git branch --show-current)
            local git_status=$(git status --short)
            local remote=$(_wt_get_remote)
            local ahead_behind=$(git rev-list --left-right --count HEAD...${remote}/$branch 2>/dev/null)

            echo "   Branch: $branch"

            if [ -n "$ahead_behind" ]; then
                local ahead=$(echo "$ahead_behind" | awk '{print $1}')
                local behind=$(echo "$ahead_behind" | awk '{print $2}')
                if [ "$ahead" -gt 0 ] || [ "$behind" -gt 0 ]; then
                    echo -n "   Sync: "
                    [ "$ahead" -gt 0 ] && echo -n "↑$ahead "
                    [ "$behind" -gt 0 ] && echo -n "↓$behind "
                    echo ""
                fi
            fi

            if [ -n "$git_status" ]; then
                echo "   Status: Modified"
                echo "$git_status" | head -5 | sed 's/^/     /'
                local count=$(echo "$git_status" | wc -l | tr -d ' ')
                [ "$count" -gt 5 ] && echo "     ... and $((count - 5)) more"
            else
                echo "   Status: Clean"
            fi

            echo ""
        fi
    done
}

# Sync current worktree with main branch
wt-sync() {
    local current_wt="$CURRENT_WORKTREE"

    if [ -z "$current_wt" ]; then
        echo "❌ Not in a worktree"
        echo "💡 Switch to a worktree first: wt <name>"
        return 1
    fi

    local main_branch=$(_wt_get_main_branch)
    echo "🔄 Syncing $current_wt with $main_branch..."
    echo ""

    # Get remote name dynamically
    local remote=$(_wt_get_remote)

    # Update main branch first
    echo "📥 Fetching latest from $remote..."
    cd "$WT_MAIN" || return 1
    git fetch "$remote"
    git checkout "$main_branch"
    git pull "$remote" "$main_branch"

    echo ""
    echo "📥 Merging $main_branch into current branch..."
    cd "$WT_DIR/$current_wt" || return 1

    local branch=$(git branch --show-current)
    git merge "${remote}/$main_branch"

    if [ $? -eq 0 ]; then
        echo ""
        echo "✅ Sync complete!"
        git status --short --branch
    else
        echo ""
        echo "⚠️  Merge conflicts detected"
        echo "Please resolve conflicts and commit"
    fi
}

# Sync all worktrees with main branch
wt-sync-all() {
    local main_branch=$(_wt_get_main_branch)
    echo "🔄 Syncing all worktrees with $main_branch..."
    echo ""

    # Get remote name dynamically
    local remote=$(_wt_get_remote)

    # Update main branch first
    echo "📥 Updating $main_branch from $remote..."
    cd "$WT_MAIN" || return 1
    git fetch "$remote"
    git checkout "$main_branch"
    git pull "$remote" "$main_branch"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [ ! -d "$WT_DIR" ] || [ -z "$(ls -A "$WT_DIR" 2>/dev/null)" ]; then
        echo "No worktrees to sync."
        return
    fi

    for dir in "$WT_DIR"/*; do
        if [ -d "$dir" ]; then
            local name=$(basename "$dir")
            echo "🌿 Syncing: $name"
            cd "$dir" || continue

            local branch=$(git branch --show-current)
            git merge "${remote}/$main_branch" --no-edit

            if [ $? -eq 0 ]; then
                echo "   ✅ Synced"
            else
                echo "   ⚠️  Conflicts - manual resolution needed"
            fi
            echo ""
        fi
    done

    echo "✅ Sync complete!"
}

# Finish current worktree (after PR merged)
wt-finish() {
    # Check if project context is set
    if [ -z "$WT_PROJECT" ] || [ -z "$WT_DIR" ]; then
        echo "❌ No project context set"
        echo ""
        echo "First, set a project context:"
        echo "  wt-project ios         → Switch to iOS project"
        echo "  wt-project firebase    → Switch to Firebase project"
        echo "  wt-project android     → Switch to Android project"
        echo "  wt-project freelance   → Switch to Freelance project"
        echo "  wt-project academy     → Switch to Academy project"
        echo "  wt-project command     → Switch to Command project"
        return 1
    fi

    # Accept optional worktree name argument
    local target_wt="$1"

    # If no argument provided, use current worktree
    if [ -z "$target_wt" ]; then
        target_wt="$CURRENT_WORKTREE"

        if [ -z "$target_wt" ]; then
            echo "❌ Not in a worktree and no worktree name provided"
            echo ""
            echo "Usage: wt-finish [worktree-name]"
            echo ""
            echo "Examples:"
            echo "  wt-finish              → Finish current worktree"
            echo "  wt-finish feature-123  → Finish specific worktree"
            return 1
        fi
    fi

    local wt_path="$WT_DIR/$target_wt"
    local branch=""

    # Verify worktree exists — either as directory OR as a stale git registration.
    # A manually-deleted directory still has a registration that needs cleanup.
    if [ -d "$wt_path" ]; then
        branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)
    else
        # Directory is missing — check for stale registration in main repo.
        # If registered, we can still complete cleanup; otherwise nothing to do.
        cd "$WT_MAIN" || return 1
        branch=$(git worktree list --porcelain | awk -v p="$wt_path" '
            $1 == "worktree" && $2 == p { found = 1; next }
            found && $1 == "branch" { sub(/^refs\/heads\//, "", $2); print $2; exit }
        ')
        if [ -z "$branch" ]; then
            echo "❌ Worktree '$target_wt' not found at: $wt_path"
            echo "   (no directory, no git registration)"
            echo ""
            echo "Available worktrees:"
            wt-list
            return 1
        fi
        echo "⚠️  Worktree directory missing — but stale git registration found"
        echo "   Branch: $branch"
        echo "   Will clean up registration and branch."
        echo ""
    fi

    if [ -z "$branch" ]; then
        echo "❌ Could not determine branch for worktree: $target_wt"
        return 1
    fi

    # Go back to main repository
    cd "$WT_MAIN" || return 1

    # Determine branch status and recommendation.
    # Safety classification delegates to _wt_classify_branch (single canonical source)
    # so wt-finish and _kb_offer_worktree_cleanup always agree on safety.
    local branch_status=""
    local delete_recommendation=""
    local pr_info=""
    local pr_number=""
    local pr_title=""

    # Fetch PR info ONCE, then thread it into the classifier so _wt_check_pr_merged
    # is not called twice on the happy path (XACA-0598-012).
    pr_info=$(_wt_check_pr_merged "$branch")
    local pr_rc=$?
    if [ $pr_rc -eq 0 ] && [ -n "$pr_info" ]; then
        pr_number="${pr_info%%|*}"
        pr_title="${pr_info#*|}"
    fi

    local wt_class
    wt_class=$(_wt_classify_branch "$branch" "$wt_path" "$pr_info")

    case "$wt_class" in
        merged)
            if [ -n "$pr_number" ]; then
                # PR verified via GitHub — skip interactive prompt (auto path)
                branch_status="✅ PR #$pr_number merged (verified via GitHub)"
                delete_recommendation="auto"
            else
                # Git heuristic: appears merged but not confirmed; show interactive prompt.
                # Map back to yes (remote gone) vs maybe (remote still exists) for
                # branch-deletion UX: "yes" → safe force-delete offer; "maybe" → unclear.
                local _merge_remote
                _merge_remote=$(git rev-parse --abbrev-ref "${branch}@{upstream}" 2>/dev/null)
                if [ $? -ne 0 ]; then
                    branch_status="✅ Remote deleted, all commits merged"
                    delete_recommendation="yes"
                else
                    branch_status="⚠️  Remote exists, commits appear merged"
                    delete_recommendation="maybe"
                fi
            fi
            ;;
        remote-gone)
            branch_status="⚠️  Remote deleted, but local commits remain"
            delete_recommendation="no"
            ;;
        unmerged-commits|*)
            # Distinguish remote-exists vs gone for display only (safety stays "no")
            local remote_ref
            remote_ref=$(git rev-parse --abbrev-ref "${branch}@{upstream}" 2>/dev/null)
            if [ $? -ne 0 ]; then
                branch_status="⚠️  Remote deleted, but unmerged commit(s) remain"
            else
                branch_status="❌ Remote exists, unmerged commit(s) present"
            fi
            delete_recommendation="no"
            ;;
    esac

    # Show initial status
    echo "🏁 Finishing worktree: $target_wt"
    echo "   Branch: $branch"
    echo "   Status: $branch_status"
    echo ""

    if [ "$delete_recommendation" = "auto" ]; then
        # PR verified merged — skip interactive prompt (safe for agents and humans)
        echo "This will:"
        echo "  1. Remove the worktree directory"
        echo "  2. Delete local and remote branch"
        echo ""
    else
        # Not verified via PR — show warning and ask for confirmation
        echo "This will:"
        echo "  1. Remove the worktree directory (always)"
        echo "  2. Ask about deleting the branch"
        echo ""
        echo "⚠️  Make sure your PR is merged and you've pushed all changes!"
        echo ""

        read -q "REPLY?Proceed with cleanup? (y/n) "
        echo ""

        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Cancelled."
            return 1
        fi
    fi

    # ═══════════════════════════════════════════════════════════════
    # WORKTREE REMOVAL LOGIC (Always executes - independent operation)
    # ═══════════════════════════════════════════════════════════════
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 1: Worktree Removal"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Remove worktree registration (use --force to handle untracked files)
    echo "🗑️  Removing worktree registration from git..."
    if git worktree remove --force "$wt_path" 2>/dev/null; then
        echo "   ✅ Worktree removed from git"
    else
        echo "   ⚠️  Git worktree remove had issues, but continuing..."
    fi

    # Delete the actual directory if it still exists
    if [ -d "$wt_path" ]; then
        echo "🗑️  Deleting worktree directory..."
        rm -rf "$wt_path"
        if [ -d "$wt_path" ]; then
            echo "   ❌ Could not delete directory: $wt_path"
            echo "   You may need to delete it manually"
        else
            echo "   ✅ Directory deleted"
        fi
    else
        echo "   ℹ️  Directory already removed"
    fi

    # Clear tmux vars if we were in this worktree.
    # This runs here (after worktree removal) since there is nothing more to do with the worktree.
    if [ -n "$TMUX" ] && [ "$CURRENT_WORKTREE" = "$target_wt" ]; then
        tmux set-option @current_worktree "" 2>/dev/null
        local agent=$(tmux show-options -v @claude_agent 2>/dev/null)
        if [ -n "$agent" ]; then
            tmux set-option status-right "🤖 $agent | 🖥  #h  " 2>/dev/null
        else
            tmux set-option status-right "" 2>/dev/null
        fi
        unset CURRENT_WORKTREE
    fi

    # ═══════════════════════════════════════════════════════════════
    # BRANCH DELETION LOGIC (Runs after worktree removal so git no
    # longer considers the branch "checked out" in another worktree)
    # ═══════════════════════════════════════════════════════════════
    local branch_deleted=false
    local remote_deleted=false

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 2: Branch Deletion"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [ "$delete_recommendation" = "auto" ]; then
        # PR verified merged — force delete directly (no prompts)
        echo "🔍 PR #$pr_number verified merged — deleting branch..."
        local _err
        if _err=$(git branch -D "$branch" 2>&1); then
            echo "   ✅ Local branch '$branch' deleted"
            branch_deleted=true
        else
            echo "   ❌ Could not delete local branch '$branch'"
            echo "       git: $_err"
        fi

        # Delete remote branch
        local remote=$(_wt_get_remote)
        if git ls-remote --heads "$remote" "$branch" 2>/dev/null | grep -q "$branch"; then
            echo "   🗑️  Deleting remote branch..."
            if git push "$remote" --delete "$branch" 2>/dev/null; then
                echo "   ✅ Remote branch '$branch' deleted"
                remote_deleted=true
            else
                echo "   ⚠️  Could not delete remote branch"
            fi
        else
            echo "   ℹ️  Remote branch already deleted"
            remote_deleted=true
        fi
    else
        # Non-PR path — use existing interactive logic
        # Try safe delete first.
        # Stderr is suppressed here intentionally: this is a probe to test whether git
        # considers the branch fully merged. A non-zero exit is expected when it is not.
        echo "🔍 Attempting safe branch deletion..."
        if git branch -d "$branch" 2>/dev/null; then
            echo "   ✅ Branch '$branch' deleted safely"
            branch_deleted=true
        else
            # Safe delete failed - offer options based on status
            echo "   ⚠️  Safe delete failed"
            echo ""

            if [ "$delete_recommendation" = "yes" ]; then
                # Recommend force delete - safe scenario
                echo "💡 Recommendation: SAFE to force-delete"
                echo "   Reason: Remote is deleted and all commits are merged"
                echo ""
                read -q "REPLY?Force delete the branch? (y/n) "
                echo ""

                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    local _err
                    if _err=$(git branch -D "$branch" 2>&1); then
                        echo "   ✅ Branch '$branch' force-deleted"
                        branch_deleted=true
                    else
                        echo "   ❌ Could not delete local branch '$branch'"
                        echo "       git: $_err"
                    fi
                else
                    echo "   ⏭️  Keeping branch (you chose to keep it)"
                fi

            elif [ "$delete_recommendation" = "no" ]; then
                # Do NOT recommend force delete - risky scenario
                echo "⚠️  NOT RECOMMENDED to delete this branch"
                echo "   Reason: Contains unmerged commits or active remote"
                echo ""
                read -q "REPLY?Force delete anyway? (NOT recommended) (y/n) "
                echo ""

                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    local _err
                    if _err=$(git branch -D "$branch" 2>&1); then
                        echo "   ⚠️  Branch '$branch' force-deleted (you chose to proceed)"
                        branch_deleted=true
                    else
                        echo "   ❌ Could not delete local branch '$branch'"
                        echo "       git: $_err"
                    fi
                else
                    echo "   ✅ Keeping branch (recommended choice)"
                fi

            else
                # Unclear case - let user decide
                echo "❓ Unclear if deletion is safe"
                echo "   Remote status indicates possible merge, but git disagrees"
                echo ""
                read -q "REPLY?Force delete the branch? (y/n) "
                echo ""

                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    local _err
                    if _err=$(git branch -D "$branch" 2>&1); then
                        echo "   ✅ Branch '$branch' force-deleted"
                        branch_deleted=true
                    else
                        echo "   ❌ Could not delete local branch '$branch'"
                        echo "       git: $_err"
                    fi
                else
                    echo "   ⏭️  Keeping branch"
                fi
            fi
        fi
    fi

    # ═══════════════════════════════════════════════════════════════
    # SUMMARY
    # ═══════════════════════════════════════════════════════════════
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    echo "✅ Worktree '$target_wt' cleaned up"
    if [ -n "$pr_number" ]; then
        echo "✅ PR #$pr_number merged"
    fi
    if [ "$branch_deleted" = true ]; then
        echo "✅ Local branch '$branch' deleted"
    else
        echo "ℹ️  Local branch '$branch' kept (not deleted)"
        echo ""
        echo "💡 To delete the branch later, run:"
        echo "   git branch -D $branch"
    fi
    if [ "$remote_deleted" = true ]; then
        echo "✅ Remote branch deleted"
    fi
    echo ""
}

# Handle PR merged workflow - complete cleanup after external PR merge
# Use this when inside Claude Code and the PR has been merged externally
wt-pr-merged() {
    # Check if project context is set
    if [ -z "$WT_PROJECT" ] || [ -z "$WT_DIR" ]; then
        echo "❌ No project context set"
        echo ""
        echo "First, set a project context:"
        echo "  wt-project ios         → Switch to iOS project"
        echo "  wt-project firebase    → Switch to Firebase project"
        echo "  wt-project android     → Switch to Android project"
        echo "  wt-project freelance   → Switch to Freelance project"
        echo "  wt-project academy     → Switch to Academy project"
        echo "  wt-project command     → Switch to Command project"
        return 1
    fi

    # Get current worktree info
    local current_wt="$CURRENT_WORKTREE"
    if [ -z "$current_wt" ]; then
        echo "❌ Not in a worktree"
        echo "💡 Switch to a worktree first: wt <name>"
        return 1
    fi

    local wt_path="$WT_DIR/$current_wt"
    local branch=$(git branch --show-current 2>/dev/null)

    if [ -z "$branch" ]; then
        echo "❌ Could not determine current branch"
        return 1
    fi

    echo ""
    echo "🔍 Checking PR status for branch: $branch"
    echo ""

    # Check GitHub PR status
    local pr_info=$(gh pr view "$branch" --json state,merged,mergedAt,number,title 2>/dev/null)

    if [ -z "$pr_info" ]; then
        echo "❌ No PR found for branch: $branch"
        echo ""
        echo "Options:"
        echo "  1. Create a PR first: gh pr create"
        echo "  2. Use wt-finish for manual cleanup"
        return 1
    fi

    local pr_state=$(echo "$pr_info" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('state',''))" 2>/dev/null)
    local pr_merged=$(echo "$pr_info" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('merged',False))" 2>/dev/null)
    local pr_number=$(echo "$pr_info" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('number',''))" 2>/dev/null)
    local pr_title=$(echo "$pr_info" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('title',''))" 2>/dev/null)

    echo "📋 PR #$pr_number: $pr_title"
    echo "   State: $pr_state"
    echo "   Merged: $pr_merged"
    echo ""

    if [ "$pr_state" != "MERGED" ] && [ "$pr_merged" != "True" ]; then
        echo "⚠️  PR is not merged yet (state: $pr_state)"
        echo ""
        echo "Wait for the PR to be merged, then run this command again."
        echo "Or use wt-finish for manual cleanup."
        return 1
    fi

    echo "✅ PR #$pr_number is merged!"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Starting cleanup workflow..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Step 1: Update kanban board if applicable
    local kanban_dir="$HOME/dev-team/kanban"
    local board_file=""
    local item_id=""

    # Find board file based on project
    case "$WT_PROJECT" in
        ios) board_file="$kanban_dir/ios-board.json" ;;
        android) board_file="$kanban_dir/android-board.json" ;;
        firebase) board_file="$kanban_dir/firebase-board.json" ;;
        academy) board_file="$kanban_dir/academy-board.json" ;;
        command) board_file="$kanban_dir/command-board.json" ;;
        freelance)
            # Try to find freelance board based on repo name
            local repo_name=$(basename "$WT_FREELANCE_BASE" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            board_file="$kanban_dir/freelance-*${repo_name}*-board.json"
            board_file=$(ls $board_file 2>/dev/null | head -1)
            ;;
        # XACA-0565: personal-org & passthrough teams route through the canonical
        # template→instance helper (_kb_template_to_instance in kanban-helpers.sh).
        # Adding a new personal-org team only needs a new case there. `legal` was
        # latently missing from this list before consolidation; now covered.
        finance|legal|medical|dns)
            board_file=$(_kb_get_board_file "$(_kb_template_to_instance "$WT_PROJECT")") ;;
    esac

    if [ -n "$board_file" ] && [ -f "$board_file" ]; then
        echo "📋 Step 1: Updating kanban board..."

        # Find item with matching worktree or branch
        item_id=$(python3 -c "
import json
import sys

try:
    with open('$board_file', 'r') as f:
        board = json.load(f)

    # Check backlog items for matching worktree or branch
    for item in board.get('backlog', []):
        wt = item.get('worktree', '')
        br = item.get('worktreeBranch', '')
        if wt == '$current_wt' or br == '$branch':
            print(item.get('id', ''))
            sys.exit(0)

    # Check active windows for matching workingOnId
    for window_key, window in board.get('activeWindows', {}).items():
        if window.get('worktree', '') == '$current_wt':
            print(window.get('workingOnId', ''))
            sys.exit(0)
except:
    pass
" 2>/dev/null)

        if [ -n "$item_id" ]; then
            echo "   Found linked item: $item_id"

            # Update item status to completed and clear worktree info
            python3 -c "
import json

with open('$board_file', 'r') as f:
    board = json.load(f)

# Update backlog item
for item in board.get('backlog', []):
    if item.get('id') == '$item_id':
        item['status'] = 'completed'
        item.pop('worktree', None)
        item.pop('worktreeBranch', None)
        item.pop('worktreeWindowId', None)
        break

# Clear workingOnId from active windows
for window_key, window in board.get('activeWindows', {}).items():
    if window.get('workingOnId') == '$item_id':
        window.pop('workingOnId', None)
        window.pop('worktree', None)
        window.pop('worktreeBranch', None)
        break

with open('$board_file', 'w') as f:
    json.dump(board, f, indent=2)
" 2>/dev/null

            if [ $? -eq 0 ]; then
                echo "   ✅ Item $item_id marked as completed"
            else
                echo "   ⚠️  Could not update kanban (manual update may be needed)"
            fi
        else
            echo "   ℹ️  No linked kanban item found"
        fi
    else
        echo "📋 Step 1: No kanban board found for project"
    fi

    echo ""

    # Step 2: Delete remote branch if it still exists
    echo "🌐 Step 2: Cleaning up remote branch..."
    local remote=$(_wt_get_remote)

    if git ls-remote --heads "$remote" "$branch" | grep -q "$branch"; then
        echo "   Deleting remote branch: $remote/$branch"
        git push "$remote" --delete "$branch" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "   ✅ Remote branch deleted"
        else
            echo "   ⚠️  Could not delete remote branch (may already be deleted by GitHub)"
        fi
    else
        echo "   ✅ Remote branch already deleted"
    fi

    echo ""

    # Step 3: Remove worktree and local branch
    echo "🗑️  Step 3: Removing worktree and local branch..."

    # Go back to main repository first
    cd "$WT_MAIN" || return 1

    # Remove worktree
    git worktree remove --force "$wt_path" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "   ✅ Worktree removed: $current_wt"
    else
        # Try manual removal
        rm -rf "$wt_path" 2>/dev/null
        echo "   ✅ Worktree directory removed"
    fi

    # Delete local branch — surface git's real error if it fails (XACA-0481)
    local _err
    if _err=$(git branch -D "$branch" 2>&1); then
        echo "   ✅ Local branch deleted: $branch"
    else
        echo "   ❌ Could not delete local branch: $branch"
        echo "       git: $_err"
    fi

    # Prune worktree references
    git worktree prune 2>/dev/null

    # Clear tmux vars
    if [ -n "$TMUX" ]; then
        tmux set-option @current_worktree "" 2>/dev/null
        local agent=$(tmux show-options -v @claude_agent 2>/dev/null)
        if [ -n "$agent" ]; then
            tmux set-option status-right "🤖 $agent | 🖥  #h  " 2>/dev/null
        else
            tmux set-option status-right "" 2>/dev/null
        fi
    fi
    unset CURRENT_WORKTREE

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ PR Merge Cleanup Complete!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Summary:"
    echo "  ✅ PR #$pr_number merged"
    [ -n "$item_id" ] && echo "  ✅ Kanban item $item_id completed"
    echo "  ✅ Remote branch cleaned up"
    echo "  ✅ Worktree '$current_wt' removed"
    echo "  ✅ Local branch '$branch' deleted"
    echo ""
    echo "🚪 You can now exit Claude Code:"
    echo "   Type 'exit' or press Ctrl+C"
    echo ""
    echo "📍 You are now in: $WT_MAIN"
    echo ""
}

# Clean up merged worktrees
wt-cleanup() {
    local main_branch=$(_wt_get_main_branch)
    echo "🧹 Cleaning up merged worktrees..."
    echo ""

    if [ ! -d "$WT_DIR" ] || [ -z "$(ls -A "$WT_DIR" 2>/dev/null)" ]; then
        echo "No worktrees to clean up."
        return
    fi

    # Get remote name dynamically
    local remote=$(_wt_get_remote)

    cd "$WT_MAIN" || return 1
    git fetch "$remote" --prune

    local cleaned=0

    for dir in "$WT_DIR"/*; do
        if [ -d "$dir" ]; then
            local name=$(basename "$dir")
            cd "$dir" || continue

            local branch=$(git branch --show-current)
            if [ -z "$branch" ] || [ "$branch" = "$main_branch" ]; then
                continue
            fi

            local should_clean=false
            local clean_reason=""

            # PRIMARY: Check GitHub PR status (handles squash merges)
            local pr_info
            pr_info=$(_wt_check_pr_merged "$branch")
            if [ $? -eq 0 ] && [ -n "$pr_info" ]; then
                local pr_num="${pr_info%%|*}"
                should_clean=true
                clean_reason="PR #$pr_num merged"
            else
                # FALLBACK: Git-based merge detection
                local merged=$(git branch --merged "${remote}/$main_branch" | grep "^. $branch$")
                if [ -n "$merged" ]; then
                    should_clean=true
                    clean_reason="merged into $main_branch"
                fi
            fi

            if [ "$should_clean" = true ]; then
                echo "🗑️  Removing worktree: $name"
                echo "   Branch: $branch ($clean_reason)"

                cd "$WT_MAIN" || continue
                # Worktree removal first, then branch delete — git refuses
                # to delete a branch checked out elsewhere (XACA-0481).
                local _err
                if _err=$(git worktree remove "$dir" 2>&1); then
                    echo "   ✅ Worktree removed"
                else
                    echo "   ⚠️  git worktree remove: $_err"
                fi
                if _err=$(git branch -D "$branch" 2>&1); then
                    echo "   ✅ Local branch deleted: $branch"
                else
                    echo "   ❌ Could not delete local branch: $branch"
                    echo "       git: $_err"
                fi

                # Delete remote branch if it still exists
                if git ls-remote --heads "$remote" "$branch" 2>/dev/null | grep -q "$branch"; then
                    if _err=$(git push "$remote" --delete "$branch" 2>&1); then
                        echo "   ✅ Remote branch deleted"
                    else
                        echo "   ⚠️  git push --delete: $_err"
                    fi
                fi

                ((cleaned++))
            fi
        fi
    done

    echo ""
    if [ $cleaned -eq 0 ]; then
        echo "✅ No merged worktrees to clean up"
    else
        echo "✅ Cleaned up $cleaned worktree(s)"
    fi

    # Prune stale worktree references
    cd "$WT_MAIN" || return 1
    git worktree prune
}

# Show current worktree info
wt-current() {
    local mode="$1"

    local main_branch=$(_wt_get_main_branch)

    # Short mode: single line for terminal banner
    if [ "$mode" = "short" ]; then
        if [ -z "$CURRENT_WORKTREE" ]; then
            echo "No worktree"
        else
            case "$WT_PROJECT" in
                ios) echo "📱 $CURRENT_WORKTREE" ;;
                firebase) echo "🔥 $CURRENT_WORKTREE" ;;
                android) echo "🤖 $CURRENT_WORKTREE" ;;
                freelance) echo "🚀 $CURRENT_WORKTREE" ;;
                mainevent) echo "🛸 $CURRENT_WORKTREE" ;;
                academy) echo "🎓 $CURRENT_WORKTREE" ;;
                command) echo "⭐ $CURRENT_WORKTREE" ;;
                finance) echo "💰 $CURRENT_WORKTREE" ;;
                medical) echo "🏥 $CURRENT_WORKTREE" ;;
                dns) echo "🧬 $CURRENT_WORKTREE" ;;
            esac
        fi
        return 0
    fi

    if [ -z "$CURRENT_WORKTREE" ]; then
        echo "Not currently in a worktree"
        echo ""
        case "$WT_PROJECT" in
            ios) echo "📱 Project: iOS (TNG)" ;;
            firebase) echo "🔥 Project: Firebase (DS9)" ;;
            android) echo "🤖 Project: Android (TOS)" ;;
            freelance) echo "🚀 Project: Freelance (ENT)" ;;
            mainevent) echo "🛸 Project: MainEvent (VOY)" ;;
            academy) echo "🎓 Project: Academy (SFA)" ;;
            command) echo "⭐ Project: Command (SFC)" ;;
            finance) echo "💰 Project: Finance (FER)" ;;
            medical) echo "🏥 Project: Medical (MED)" ;;
            dns) echo "🧬 Project: DNS Framework (LD)" ;;
        esac
        echo ""
        echo "📋 Available worktrees:"
        wt-list
        return 1
    fi

    echo ""
    case "$WT_PROJECT" in
        ios) echo "📱 Project: iOS (TNG - Enterprise-D)" ;;
        firebase) echo "🔥 Project: Firebase (DS9 - Deep Space Nine)" ;;
        android) echo "🤖 Project: Android (TOS - USS Enterprise)" ;;
        freelance)
            echo "🚀 Project: Freelance (ENT - Enterprise NX-01)"
            echo "   Repo: $(basename "$WT_BASE")"
            ;;
        mainevent)
            echo "🛸 Project: MainEvent (VOY - USS Voyager)"
            echo "   Repo: $(basename "$WT_BASE")"
            ;;
        academy) echo "🎓 Project: Academy (SFA - Starfleet Academy)" ;;
        command) echo "⭐ Project: Command (SFC - Starfleet Command)" ;;
        finance) echo "💰 Project: Finance (Ferengi Alliance)" ;;
        medical) echo "🏥 Project: Medical (Medical Division)" ;;
        dns) echo "🧬 Project: DNS Framework (Lower Decks - USS Cerritos)" ;;
    esac
    echo "📍 Current Worktree: $CURRENT_WORKTREE"
    echo "📂 Path: $WT_DIR/$CURRENT_WORKTREE"
    echo ""
    git status --short --branch
    echo ""
}

# Quick switch to main repository
wt-dev() {
    # Check if project context is set
    if [ -z "$WT_PROJECT" ] || [ -z "$WT_MAIN" ]; then
        echo "❌ No project context set"
        echo ""
        echo "First, set a project context:"
        echo "  wt-project ios         → Switch to iOS project"
        echo "  wt-project firebase    → Switch to Firebase project"
        echo "  wt-project android     → Switch to Android project"
        echo "  wt-project freelance   → Switch to Freelance project"
        echo "  wt-project academy     → Switch to Academy project"
        echo "  wt-project command     → Switch to Command project"
        echo "  wt-project finance     → Switch to Finance project"
        echo "  wt-project medical     → Switch to Medical project"
        echo "  wt-project dns         → Switch to DNS Framework project"
        return 1
    fi

    # Detect current project context first
    _detect_worktree

    local main_branch=$(basename "$WT_MAIN")
    cd "$WT_MAIN" || return 1

    if [ -n "$TMUX" ]; then
        tmux set-option @current_worktree "$main_branch" 2>/dev/null
        local agent=$(tmux show-options -v @claude_agent 2>/dev/null)
        if [ -n "$agent" ]; then
            tmux set-option status-right "🌿 $main_branch | 🤖 $agent | 🖥  #h  " 2>/dev/null
        else
            tmux set-option status-right "🌿 $main_branch | 🖥  #h  " 2>/dev/null
        fi
    fi

    export CURRENT_WORKTREE="$main_branch"

    echo "📁 Switched to: $main_branch (main repository)"
    case "$WT_PROJECT" in
        ios) echo "📱 Project: iOS (TNG - Enterprise-D)" ;;
        firebase) echo "🔥 Project: Firebase (DS9 - Deep Space Nine)" ;;
        android) echo "🤖 Project: Android (TOS - USS Enterprise)" ;;
        freelance) echo "🚀 Project: Freelance (ENT - Enterprise NX-01)" ;;
        mainevent) echo "🛸 Project: MainEvent (VOY - USS Voyager)" ;;
        academy) echo "🎓 Project: Academy (SFA - Starfleet Academy)" ;;
        command) echo "⭐ Project: Command (SFC - Starfleet Command)" ;;
        finance) echo "💰 Project: Finance (Ferengi Alliance)" ;;
        medical) echo "🏥 Project: Medical (Medical Division)" ;;
        dns) echo "🧬 Project: DNS Framework (Lower Decks - USS Cerritos)" ;;
    esac
    git status --short --branch
}

# ============================================================================
# Aliases for convenience
# ============================================================================

alias wtl='wt-list'
alias wts='wt-status'
alias wtc='wt-current'
alias wtn='wt-new'
alias wtd='wt-dev'
alias wtpm='wt-pr-merged'

# ============================================================================
# Auto-detection: Set CURRENT_WORKTREE and project if we're in one
# ============================================================================

_detect_worktree() {
    local current_dir="$PWD"

    # Check iOS worktrees first (most specific)
    if [[ "$current_dir" == "$WT_IOS_DIR"/* ]]; then
        local wt_name="${current_dir#$WT_IOS_DIR/}"
        wt_name="${wt_name%%/*}"
        export CURRENT_WORKTREE="$wt_name"
        export WT_BASE="$WT_IOS_BASE"
        export WT_DIR="$WT_IOS_DIR"
        export WT_MAIN="$WT_IOS_MAIN"
        export WT_PROJECT="ios"
    # Check if in iOS base directory (anywhere under it)
    elif [[ "$current_dir" == "$WT_IOS_BASE"* ]]; then
        export CURRENT_WORKTREE="DEV"
        export WT_BASE="$WT_IOS_BASE"
        export WT_DIR="$WT_IOS_DIR"
        export WT_MAIN="$WT_IOS_MAIN"
        export WT_PROJECT="ios"

    # Check Firebase worktrees
    elif [[ "$current_dir" == "$WT_FIREBASE_DIR"/* ]]; then
        local wt_name="${current_dir#$WT_FIREBASE_DIR/}"
        wt_name="${wt_name%%/*}"
        export CURRENT_WORKTREE="$wt_name"
        export WT_BASE="$WT_FIREBASE_BASE"
        export WT_DIR="$WT_FIREBASE_DIR"
        export WT_MAIN="$WT_FIREBASE_MAIN"
        export WT_PROJECT="firebase"
    # Check if in Firebase base directory (anywhere under it)
    elif [[ "$current_dir" == "$WT_FIREBASE_BASE"* ]]; then
        export CURRENT_WORKTREE="develop"
        export WT_BASE="$WT_FIREBASE_BASE"
        export WT_DIR="$WT_FIREBASE_DIR"
        export WT_MAIN="$WT_FIREBASE_MAIN"
        export WT_PROJECT="firebase"

    # Check Android worktrees
    elif [[ "$current_dir" == "$WT_ANDROID_DIR"/* ]]; then
        local wt_name="${current_dir#$WT_ANDROID_DIR/}"
        wt_name="${wt_name%%/*}"
        export CURRENT_WORKTREE="$wt_name"
        export WT_BASE="$WT_ANDROID_BASE"
        export WT_DIR="$WT_ANDROID_DIR"
        export WT_MAIN="$WT_ANDROID_MAIN"
        export WT_PROJECT="android"
    # Check if in Android base directory (anywhere under it)
    elif [[ "$current_dir" == "$WT_ANDROID_BASE"* ]]; then
        export CURRENT_WORKTREE="develop"
        export WT_BASE="$WT_ANDROID_BASE"
        export WT_DIR="$WT_ANDROID_DIR"
        export WT_MAIN="$WT_ANDROID_MAIN"
        export WT_PROJECT="android"

    # Check Academy worktrees
    elif [[ "$current_dir" == "$WT_ACADEMY_DIR"/* ]]; then
        local wt_name="${current_dir#$WT_ACADEMY_DIR/}"
        wt_name="${wt_name%%/*}"
        export CURRENT_WORKTREE="$wt_name"
        export WT_BASE="$WT_ACADEMY_BASE"
        export WT_DIR="$WT_ACADEMY_DIR"
        export WT_MAIN="$WT_ACADEMY_MAIN"
        export WT_PROJECT="academy"
    # Check if in Academy base directory (anywhere under it)
    elif [[ "$current_dir" == "$WT_ACADEMY_BASE"* ]]; then
        export CURRENT_WORKTREE="develop"
        export WT_BASE="$WT_ACADEMY_BASE"
        export WT_DIR="$WT_ACADEMY_DIR"
        export WT_MAIN="$WT_ACADEMY_MAIN"
        export WT_PROJECT="academy"

    # Check Command worktrees
    elif [[ "$current_dir" == "$WT_COMMAND_DIR"/* ]]; then
        local wt_name="${current_dir#$WT_COMMAND_DIR/}"
        wt_name="${wt_name%%/*}"
        export CURRENT_WORKTREE="$wt_name"
        export WT_BASE="$WT_COMMAND_BASE"
        export WT_DIR="$WT_COMMAND_DIR"
        export WT_MAIN="$WT_COMMAND_MAIN"
        export WT_PROJECT="command"
    # Check if in Command base directory (anywhere under it)
    elif [[ "$current_dir" == "$WT_COMMAND_BASE"* ]]; then
        export CURRENT_WORKTREE="develop"
        export WT_BASE="$WT_COMMAND_BASE"
        export WT_DIR="$WT_COMMAND_DIR"
        export WT_MAIN="$WT_COMMAND_MAIN"
        export WT_PROJECT="command"

    # Check Freelance - any git repo that's not iOS/Firebase/Android/Academy/Command
    else
        # Try to detect as freelance repo
        if _detect_freelance_repo "$current_dir"; then
            # Check if we're in a worktree subdirectory
            if [[ "$current_dir" == "$WT_FREELANCE_DIR"/* ]]; then
                local wt_name="${current_dir#$WT_FREELANCE_DIR/}"
                wt_name="${wt_name%%/*}"
                export CURRENT_WORKTREE="$wt_name"
            else
                export CURRENT_WORKTREE="$WT_FREELANCE_MAIN_BRANCH"
            fi
            export WT_BASE="$WT_FREELANCE_BASE"
            export WT_DIR="$WT_FREELANCE_DIR"
            export WT_MAIN="$WT_FREELANCE_MAIN"
            export WT_PROJECT="freelance"
        else
            unset CURRENT_WORKTREE
        fi
    fi
}

# Run detection on shell init
_detect_worktree

# ============================================================================
# Help
# ============================================================================

wt-help() {
    cat << 'EOF'

📚 Git Worktree Helper Commands

Project Selection:
  wt-project <project>   Switch between project worktrees
                         Usage: wt-project [ios|firebase|android|freelance|mainevent|academy|command|finance|medical|dns|status]

Creating & Switching:
  wt-new <name>          Create new worktree with branch
  wt <name>              Switch to existing worktree
  wt-dev                 Switch to main repository (DEV/main/develop)

Information:
  wt-list                List all worktrees for current project
  wt-status              Show detailed status of all worktrees
  wt-current             Show current worktree info

Syncing:
  wt-sync                Sync current worktree with main branch
  wt-sync-all            Sync all worktrees with main branch

Cleanup:
  wt-pr-merged           Complete cleanup after PR merged externally (use in Claude Code)
  wt-finish              Finish current worktree (manual cleanup)
  wt-cleanup             Clean up all merged worktrees

  Note: Worktrees auto-created by kb-run* will prompt for cleanup when Claude exits.
        Disable this prompt with: KB_WT_CLEANUP_PROMPT=0

Examples:
  wt-project ios                    Switch to iOS worktrees
  wt-project firebase               Switch to Firebase worktrees
  wt-project android                Switch to Android worktrees
  wt-project freelance              Switch to Freelance worktrees (detect from PWD)
  wt-project freelance Starwords    Switch to DoubleNode/Starwords freelance project
  wt-project academy                Switch to Academy worktrees
  wt-project command                Switch to Command worktrees
  wt-project finance                Switch to Finance project (personal)
  wt-project medical                Switch to Medical project (general)
  wt-project dns                    Switch to DNS Framework worktrees

  wt-new feature-booking-flow       Create feature worktree
  wt feature-booking-flow           Switch to that worktree
  wt-sync                           Sync with latest main branch
  wt-finish                         Clean up after PR merged

Project Main Branches:
  📱 iOS:       DEV
  🔥 Firebase:  develop
  🤖 Android:   develop
  🚀 Freelance: (auto-detected: main, master, develop, or DEV)
  🛸 MainEvent: (auto-detected: main, master, develop, or DEV)
  🎓 Academy:   develop
  ⭐ Command:   develop
  💰 Finance:   (auto-detected per project: main, master, develop, or DEV)
  🏥 Medical:   (auto-detected per project: main, master, develop, or DEV)
  🧬 DNS:       (static: /Users/Shared/Development/DNSFramework)

Aliases:
  wtl  = wt-list
  wts  = wt-status
  wtc  = wt-current
  wtn  = wt-new
  wtd  = wt-dev
  wtpm = wt-pr-merged

EOF
}

echo "✅ Git worktree helpers loaded!"
echo "   Current project: $WT_PROJECT"
echo "   Type 'wt-help' for usage information"
echo "   Type 'wt-project status' to see project details"