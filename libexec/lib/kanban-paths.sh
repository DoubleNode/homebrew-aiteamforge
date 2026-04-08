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

    # Strategy: check the .aiteamforge-config file first (authoritative for this
    # install), then fall back to the default kanban directory.
    #
    # The config file records team_paths with working_dir for each team.
    # Board files live at <working_dir>/kanban/ or <install_dir>/kanban/.

    # 1. Try .aiteamforge-config (written by setup wizard)
    local config_file="${HOME}/aiteamforge/.aiteamforge-config"
    if [ -f "$config_file" ] && command -v jq &>/dev/null; then
        local working_dir
        working_dir=$(jq -r ".team_paths.\"${team}\".working_dir // empty" "$config_file" 2>/dev/null)
        if [ -n "$working_dir" ]; then
            echo "${working_dir}/kanban"
            return 0
        fi
    fi

    # 2. Default: boards live under the install dir's kanban/ directory
    local install_dir="${HOME}/aiteamforge"
    if [ -f "$config_file" ] && command -v jq &>/dev/null; then
        local cfg_dir
        cfg_dir=$(jq -r '.install_dir // empty' "$config_file" 2>/dev/null)
        [ -n "$cfg_dir" ] && install_dir="$cfg_dir"
    fi

    # Check if board exists at install_dir/kanban/
    if [ -d "${install_dir}/kanban" ]; then
        echo "${install_dir}/kanban"
        return 0
    fi

    # 3. Nothing found — signal failure
    return 1
}
