#!/bin/bash
# kanban-paths.sh
# CANONICAL source of truth for team → kanban directory mappings.
#
# This is the single authoritative mapping used by kanban-board-check.sh,
# kanban-restore-helper.sh, and any other script that needs to resolve a
# team's live kanban directory. All per-script duplicates have been removed
# in favour of sourcing this file.
#
# XACA-0139-002 — De-branding: org-resolver sourced for future callers that
# need to build display strings or compose paths from organization identity.
# get_kanban_dir() itself reads from the .aiteamforge-config written by the
# setup wizard, so it is already org-neutral at runtime.
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

# Source the org-resolver if available.  This file has no hard dependency on
# it — get_kanban_dir() reads from .aiteamforge-config at runtime — but
# sourcing it here ensures callers that need org identity can access it after
# sourcing kanban-paths.sh alone.
# shellcheck source=./aiteamforge-org-paths.sh
_kp_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
[ -f "$_kp_script_dir/aiteamforge-org-paths.sh" ] && . "$_kp_script_dir/aiteamforge-org-paths.sh" 2>/dev/null || true
unset _kp_script_dir

# ──────────────────────────────────────────────────────────────────────────────
# get_kanban_dir <team>
#
# Prints the live kanban directory path for the given team ID.
# Returns 0 on success, 1 if the team ID is unrecognised.
#
# The mapping here must stay in sync with the TEAM_KANBAN_DIRS dictionary in
# kanban-backup.py (the Python backup system uses the same paths).
#
# Actual paths are resolved at runtime from .aiteamforge-config (written by the
# setup wizard) so they adapt to the installed org's directory layout without
# hard-coding any client-specific paths here.
#
# Well-known team IDs (paths resolved from config or install_dir):
#   academy                              ~/aiteamforge/kanban  (or configured working_dir)
#   ios, android, firebase, command      org shared-dev tree (via config working_dir)
#   dns                                  shared-dev DNS root
#   freelance-<family>-<project>         project working_dir from config
#   legal-*, medical-*, finance-*        ~/legal/, ~/medical/, ~/finance/ subtrees
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

# ──────────────────────────────────────────────────────────────────────────────
# get_board_id <team>
#
# Maps a TEMPLATE key (as stored in .aiteamforge-config teams[]) to its
# canonical INSTANCE id, which is what board filenames actually use on disk.
# Personal-org teams ship a single instance whose id differs from the template
# key (e.g. "finance" in the config → "finance-personal" on disk).
# Returns the instance id, or the input unchanged if it is already an instance
# id (the common case for multi-user teams like "academy", "ios", etc.).
#
# This MUST stay a deterministic map — NOT a "${team}*-board.json" glob —
# because a glob would match BOTH the canonical finance-personal-board.json AND
# a legacy finance-board.json stub that _kb_check_dual_boards
# (kanban-helpers.sh) intentionally tolerates.  See worktree-helpers.sh:1566
# for the same template→instance precedent (XACA-0180 / XACA-0565).
# Note: aiteamforge_paths.py _resolve_template_band maps the OPPOSITE direction
# (instance→template) and is not reusable here.
# ──────────────────────────────────────────────────────────────────────────────
get_board_id() {
    local team="$1"
    case "$team" in
        finance)  echo "finance-personal"  ;;
        legal)    echo "legal-coparenting" ;;
        medical)  echo "medical-general"   ;;
        *)        echo "$team"             ;;
    esac
}
