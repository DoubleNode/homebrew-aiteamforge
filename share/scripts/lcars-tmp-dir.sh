#!/usr/bin/env bash
# lcars-tmp-dir.sh — Shared helper: map tmux session name to kanban/tmp/ dir
#
# Source this file to get _get_lcars_tmp_dir().
#
# Usage:
#   source /path/to/lcars-tmp-dir.sh
#   tmp_dir=$(_get_lcars_tmp_dir "academy-reno")
#   # => ~/dev-team/kanban/tmp/
#
# Session name format: <team>-<terminal>
#   Simple:        "academy-reno"    -> team=academy
#   Multi-segment: "legal-coparenting-advocate" -> team=legal-coparenting
#   Three-part:    "freelance-doublenode-starwords-archer" -> team=freelance-doublenode-starwords
#
# This mirrors:
#   - _get_team_kanban_dir() in claude/statusline-command.sh (shell)
#   - TEAM_KANBAN_DIRS + get_lcars_tmp_dir() in kanban-hooks/kanban_utils.py (Python)
#
# XACA-0168: Team→path resolution now delegates to aiteamforge-paths.sh loader
# when available. The built-in case statement is kept as a fallback.

# ─────────────────────────────────────────────────────────────────────────────
# Load the canonical team-path config loader (XACA-0168).
# Provides aiteamforge_team_kanban_dir() for dynamic team→path resolution.
# Guard against double-sourcing is built into the loader itself.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${_AITEAMFORGE_PATHS_LOADED:-}" ]; then
    _lctd_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for _lctd_candidate in \
        "${HOME}/dev-team/homebrew-tap/libexec/lib/aiteamforge-paths.sh" \
        "$(brew --prefix 2>/dev/null)/share/aiteamforge/libexec/lib/aiteamforge-paths.sh" \
        "${_lctd_script_dir}/../homebrew-tap/libexec/lib/aiteamforge-paths.sh" \
        "${HOME}/.aiteamforge/lib/aiteamforge-paths.sh"; do
        if [ -f "$_lctd_candidate" ]; then
            # shellcheck source=/dev/null
            source "$_lctd_candidate"
            break
        fi
    done
    unset _lctd_script_dir _lctd_candidate
fi

# ---------------------------------------------------------------------------
# _get_team_kanban_dir_for_tmp()
#
# Internal helper: map a team name to its kanban directory path.
# Delegates to aiteamforge_team_kanban_dir() (XACA-0168) when available;
# falls back to a built-in case statement for environments without the loader.
# ---------------------------------------------------------------------------
_get_team_kanban_dir_for_tmp() {
    local team="$1"

    # Prefer the canonical loader
    if command -v aiteamforge_team_kanban_dir &>/dev/null 2>&1; then
        local _result
        _result=$(aiteamforge_team_kanban_dir "$team" 2>/dev/null)
        if [ -n "$_result" ]; then
            echo "$_result"
            return 0
        fi
    fi

    # Fallback: built-in case statement (kept for environments without the loader)
    case "$team" in
        # Core teams
        academy)                               echo "${HOME}/dev-team/kanban" ;;
        ios)                                   echo "/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban" ;;
        android)                               echo "/Users/Shared/Development/Main Event/MainEventApp-Android/kanban" ;;
        firebase)                              echo "/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban" ;;
        command|mainevent)                     echo "/Users/Shared/Development/Main Event/dev-team/kanban" ;;
        dns)                                   echo "/Users/Shared/Development/DNSFramework/kanban" ;;

        # Freelance — generic fallback (no specific project)
        freelance)                             echo "${HOME}/dev-team/kanban" ;;

        # Freelance — DoubleNode projects
        freelance-doublenode-starwords)        echo "/Users/Shared/Development/DoubleNode/Starwords/kanban" ;;
        freelance-doublenode-appplanning)      echo "/Users/Shared/Development/DoubleNode/appPlanning/kanban" ;;
        freelance-doublenode-workstats)        echo "/Users/Shared/Development/DoubleNode/WorkStats/kanban" ;;
        freelance-doublenode-lifeboard)        echo "/Users/Shared/Development/DoubleNode/LifeBoard/kanban" ;;
        freelance-doublenode-caravan)          echo "/Users/Shared/Development/DoubleNode/Caravan/kanban" ;;
        freelance-doublenode-awaysentry)      echo "/Users/Shared/Development/DoubleNode/AwaySentry/kanban" ;;

        # Freelance — Liquidstyle projects
        freelance-liquidstyle-agentbadges-app) echo "/Users/Shared/Development/Liquidstyle/AgentBadges-APP/kanban" ;;
        freelance-liquidstyle-agentbadges-ios) echo "/Users/Shared/Development/Liquidstyle/AgentBadges-IOS/kanban" ;;

        # Personal life teams
        legal-coparenting)                     echo "${HOME}/legal/coparenting/kanban" ;;
        finance-personal)                      echo "${HOME}/finance/personal/kanban" ;;
        medical|medical-general)               echo "${HOME}/medical/general/kanban" ;;

        # Unknown team — fall back to academy kanban (safe default)
        *)                                     echo "${HOME}/dev-team/kanban" ;;
    esac
}

# ---------------------------------------------------------------------------
# _get_lcars_tmp_dir()
#
# Map a tmux session name to the correct kanban/tmp/ directory for that team.
#
# Algorithm:
#   1. Extract team = everything before the last "-" segment
#      (terminal = the last "-" segment)
#   2. Look up the team's kanban directory
#   3. Append /tmp/ to that directory
#   4. Create the directory if it doesn't exist
#   5. Fall back to /tmp/ if the team lookup produces no result
#
# Args:
#   $1 - tmux session name (e.g. "academy-reno", "legal-coparenting-advocate")
#
# Prints the resolved tmp directory path (with trailing slash).
# Returns 0 on success, 1 if the session name is empty or has no dash.
# ---------------------------------------------------------------------------
_get_lcars_tmp_dir() {
    local session_name="$1"

    # Require a non-empty session name with at least one dash
    if [[ -z "$session_name" || "$session_name" != *-* ]]; then
        echo "/tmp/"
        return 1
    fi

    # If KANBAN_DIR is set by the startup script, use it directly
    # (avoids hardcoded path mismatches on homebrew installs)
    if [[ -n "${KANBAN_DIR:-}" && -d "${KANBAN_DIR}" ]]; then
        local env_tmp="${KANBAN_DIR}/tmp"
        mkdir -p "$env_tmp" 2>/dev/null && { echo "${env_tmp}/"; return 0; }
    fi

    # Extract team and terminal.
    # terminal = last segment after final dash
    # team     = everything before the final dash
    local terminal team
    terminal="${session_name##*-}"
    team="${session_name%-*}"

    if [[ -z "$team" ]]; then
        echo "/tmp/"
        return 1
    fi

    # Look up the kanban directory for this team
    local kanban_dir
    kanban_dir=$(_get_team_kanban_dir_for_tmp "$team")

    # Build the tmp path
    local tmp_dir="${kanban_dir}/tmp"

    # Create the directory (safe to call even if it already exists)
    mkdir -p "$tmp_dir" 2>/dev/null || {
        # If we can't create the team's tmp dir, fall back to /tmp/
        echo "/tmp/"
        return 1
    }

    echo "${tmp_dir}/"
    return 0
}
