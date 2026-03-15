#!/bin/bash
# kanban-paths.sh
# CANONICAL source of truth for team → kanban directory mappings.
#
# This is the single authoritative mapping used by kanban-board-check.sh,
# kanban-restore-helper.sh, and any other script that needs to resolve a
# team's live kanban directory. All per-script duplicates have been removed
# in favour of sourcing this file.
#
# NOTE: install-kanban.sh has its own get_team_kanban_dir() that is
# intentionally kept separate — it reads from installer wizard env vars and
# .conf files at installation time, which is a different use-case. Do not
# merge that function here.
#
# USAGE:
#   source /path/to/kanban-paths.sh
#   dir=$(get_kanban_dir "academy") || echo "unknown team"
#
# DEPENDENCIES:
#   None. This library is intentionally dependency-free (no common.sh, no
#   external commands) so it can be sourced early in any script.
#
# Author: Reno's Engineering Lab (Academy Team)

# Guard against double-sourcing
if [ -n "${_KANBAN_PATHS_LOADED:-}" ]; then
    return 0
fi
_KANBAN_PATHS_LOADED=1

# ──────────────────────────────────────────────────────────────────────────────
# get_kanban_dir <team>
#
# Prints the live kanban directory path for the given team ID.
# Returns 0 on success, 1 if the team ID is unrecognised.
#
# The mapping here must stay in sync with the TEAM_KANBAN_DIRS dictionary in
# kanban-backup.py (the Python backup system uses the same paths).
#
# Known team IDs and their directories:
#   academy                         ~/aiteamforge/kanban
#   ios                             /Users/Shared/Development/Main Event/MainEventApp-iOS/kanban
#   android                         /Users/Shared/Development/Main Event/MainEventApp-Android/kanban
#   firebase                        /Users/Shared/Development/Main Event/MainEventApp-Functions/kanban
#   command                         /Users/Shared/Development/Main Event/aiteamforge/kanban
#   dns                             /Users/Shared/Development/DNSFramework/kanban
#   freelance-doublenode-starwords  /Users/Shared/Development/DoubleNode/Starwords/kanban
#   freelance-doublenode-appplanning /Users/Shared/Development/DoubleNode/appPlanning/kanban
#   freelance-doublenode-workstats  /Users/Shared/Development/DoubleNode/WorkStats/kanban
#   freelance-doublenode-lifeboard  /Users/Shared/Development/DoubleNode/LifeBoard/kanban
#   freelance-*                     /Users/Shared/Development/DoubleNode/<suffix>/kanban (generic fallback)
#   legal-*                         ~/legal/<suffix>/kanban
#   medical-*                       ~/medical/<suffix>/kanban
# ──────────────────────────────────────────────────────────────────────────────
get_kanban_dir() {
    local team="$1"

    case "$team" in
        academy)
            echo "${HOME}/aiteamforge/kanban"
            ;;
        ios)
            echo "/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban"
            ;;
        android)
            echo "/Users/Shared/Development/Main Event/MainEventApp-Android/kanban"
            ;;
        firebase)
            echo "/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban"
            ;;
        command)
            echo "/Users/Shared/Development/Main Event/aiteamforge/kanban"
            ;;
        dns)
            echo "/Users/Shared/Development/DNSFramework/kanban"
            ;;
        freelance-doublenode-starwords)
            echo "/Users/Shared/Development/DoubleNode/Starwords/kanban"
            ;;
        freelance-doublenode-appplanning)
            echo "/Users/Shared/Development/DoubleNode/appPlanning/kanban"
            ;;
        freelance-doublenode-workstats)
            echo "/Users/Shared/Development/DoubleNode/WorkStats/kanban"
            ;;
        freelance-doublenode-lifeboard)
            echo "/Users/Shared/Development/DoubleNode/LifeBoard/kanban"
            ;;
        freelance-*)
            # Generic fallback for unknown freelance projects: derive path from
            # the team suffix (everything after "freelance-").
            local project="${team#freelance-}"
            echo "/Users/Shared/Development/DoubleNode/${project}/kanban"
            ;;
        legal-*)
            local project="${team#legal-}"
            echo "${HOME}/legal/${project}/kanban"
            ;;
        medical-*)
            local project="${team#medical-}"
            echo "${HOME}/medical/${project}/kanban"
            ;;
        *)
            # Unknown team — return nothing and signal failure so callers can
            # decide how to handle it (warn, default, or abort).
            return 1
            ;;
    esac
}
