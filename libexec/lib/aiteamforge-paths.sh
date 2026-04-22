#!/bin/bash
# aiteamforge-paths.sh — Canonical team path config loader (shell layer)
#
# XACA-0168-001 — Wave 1: Config schema + loader module
#
# This file is the shell counterpart to kanban-hooks/aiteamforge_paths.py.
# Both must produce identical results for the same ~/.aiteamforge/team-paths.json
# input.  The baked-in DEFAULT_TEAMS heredoc below must stay in sync with
# DEFAULT_TEAMS in aiteamforge_paths.py.
#
# Relationship to kanban-paths.sh (existing file in this directory):
#   kanban-paths.sh   — reads from ~/aiteamforge/.aiteamforge-config (old
#                       installer config, get_kanban_dir function).
#   aiteamforge-paths.sh (THIS FILE) — reads from ~/.aiteamforge/team-paths.json
#                       (new schema, Wave 1 of XACA-0168 migration).
#   Both files are kept for backward compatibility.  Consumers should migrate
#   to the aiteamforge_* functions in this file.
#
# USAGE:
#   source /path/to/aiteamforge-paths.sh
#   kanban_dir=$(aiteamforge_team_kanban_dir "academy") || exit 1
#   port=$(aiteamforge_team_lcars_port "ios") || echo "no port"
#
# DEPENDENCIES:
#   jq (preferred) or python3 (fallback).  Both are optional — if neither
#   is available the built-in shell defaults are used directly.
#
# ENVIRONMENT:
#   AITEAMFORGE_CONFIG — override config path (for testing)
#
# Author: Reno's Engineering Lab (Academy Team)

# Guard against double-sourcing
if [ -n "${_AITEAMFORGE_PATHS_LOADED:-}" ]; then
    return 0
fi
_AITEAMFORGE_PATHS_LOADED=1

# Resolve tap-owned Python venv interpreter ($AITEAMFORGE_PYTHON).
# python-env.sh lives alongside this file in the same lib/ directory.
_atf_paths_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# shellcheck source=./python-env.sh
[ -f "$_atf_paths_script_dir/python-env.sh" ] && . "$_atf_paths_script_dir/python-env.sh" 2>/dev/null || true
unset _atf_paths_script_dir

# ─────────────────────────────────────────────────────────────────────────────
# Config path
# ─────────────────────────────────────────────────────────────────────────────

aiteamforge_config_path() {
    if [ -n "${AITEAMFORGE_CONFIG:-}" ]; then
        echo "$AITEAMFORGE_CONFIG"
    else
        echo "${HOME}/.aiteamforge/team-paths.json"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Baked-in defaults (shell representation)
#
# Format: one line per team, TAB-separated:
#   team_id<TAB>kanban_dir<TAB>working_dir<TAB>lcars_port
# lcars_port is empty string when not applicable.
#
# THIS LIST MUST MIRROR DEFAULT_TEAMS in kanban-hooks/aiteamforge_paths.py.
# ─────────────────────────────────────────────────────────────────────────────

_AITEAMFORGE_DEFAULT_TEAMS_DATA() {
    # Emit: team_id TAB kanban_dir TAB working_dir TAB lcars_port
    # (lcars_port is empty when not applicable)
    cat <<DEFAULTS
academy	${HOME}/dev-team/kanban	${HOME}/dev-team	8203
ios	/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban	/Users/Shared/Development/Main Event/MainEventApp-iOS	8260
android	/Users/Shared/Development/Main Event/MainEventApp-Android/kanban	/Users/Shared/Development/Main Event/MainEventApp-Android	8280
firebase	/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban	/Users/Shared/Development/Main Event/MainEventApp-Functions	8240
command	/Users/Shared/Development/Main Event/dev-team/kanban	/Users/Shared/Development/Main Event/dev-team	8234
dns	/Users/Shared/Development/DNSFramework/kanban	/Users/Shared/Development/DNSFramework	8180
freelance-doublenode-starwords	/Users/Shared/Development/DoubleNode/Starwords/kanban	/Users/Shared/Development/DoubleNode/Starwords	8505
freelance-doublenode-appplanning	/Users/Shared/Development/DoubleNode/appPlanning/kanban	/Users/Shared/Development/DoubleNode/appPlanning	8505
freelance-doublenode-workstats	/Users/Shared/Development/DoubleNode/WorkStats/kanban	/Users/Shared/Development/DoubleNode/WorkStats	8505
freelance-doublenode-lifeboard	/Users/Shared/Development/DoubleNode/LifeBoard/kanban	/Users/Shared/Development/DoubleNode/LifeBoard	8505
freelance-doublenode-caravan	/Users/Shared/Development/DoubleNode/Caravan/kanban	/Users/Shared/Development/DoubleNode/Caravan	8505
freelance-doublenode-awaysentry	/Users/Shared/Development/DoubleNode/AwaySentry/kanban	/Users/Shared/Development/DoubleNode/AwaySentry	8505
freelance-liquidstyle-agentbadges-app	/Users/Shared/Development/Liquidstyle/AgentBadges-APP/kanban	/Users/Shared/Development/Liquidstyle/AgentBadges-APP	8960
freelance-liquidstyle-agentbadges-ios	/Users/Shared/Development/Liquidstyle/AgentBadges-IOS/kanban	/Users/Shared/Development/Liquidstyle/AgentBadges-IOS	8970
legal-coparenting	${HOME}/legal/coparenting/kanban	${HOME}/legal/coparenting
medical-general	${HOME}/medical/general/kanban	${HOME}/medical/general
finance-personal	${HOME}/finance/personal/kanban	${HOME}/finance/personal
mainevent	/Users/Shared/Development/Main Event/dev-team/kanban	/Users/Shared/Development/Main Event/dev-team	8234
medical	${HOME}/medical/general/kanban	${HOME}/medical/general
freelance	${HOME}/dev-team/kanban	${HOME}/dev-team	8505
DEFAULTS
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal: bootstrap helpers
# ─────────────────────────────────────────────────────────────────────────────

_aiteamforge_is_interactive() {
    # Returns 0 (true) if stdin is a terminal
    [ -t 0 ]
}

_aiteamforge_write_defaults() {
    local config_path
    config_path=$(aiteamforge_config_path)
    local config_dir
    config_dir="$(dirname "$config_path")"
    mkdir -p "$config_dir" 2>/dev/null || true

    # Build JSON from the default data using python3 (always available on macOS)
    "${AITEAMFORGE_PYTHON:-python3}" - "$config_path" <<'PYEOF'
import sys, json
from pathlib import Path
import os

config_path = sys.argv[1]
home = str(Path.home())

teams = {}
for line in sys.stdin:
    line = line.rstrip('\n')
    if not line:
        continue
    parts = line.split('\t')
    if len(parts) < 3:
        continue
    team_id = parts[0]
    kanban_dir = parts[1].replace('${HOME}', home).replace('$HOME', home)
    working_dir = parts[2].replace('${HOME}', home).replace('$HOME', home)
    port_str = parts[3] if len(parts) > 3 else ''
    entry = {"kanban_dir": kanban_dir, "working_dir": working_dir}
    entry["lcars_port"] = int(port_str) if port_str else None
    teams[team_id] = entry

config = {"schema_version": 1, "teams": teams}
Path(config_path).parent.mkdir(parents=True, exist_ok=True)
Path(config_path).write_text(json.dumps(config, indent=2) + '\n', encoding='utf-8')
PYEOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal: low-level field lookup
#
# _aiteamforge_get_field <team> <field>
#   field: kanban_dir | working_dir | lcars_port
#
# Priority:
#   1. Parse config file with jq (fast, reliable)
#   2. Parse config file with python3 (jq not available)
#   3. Fall back to baked-in shell defaults (neither available or config missing)
# ─────────────────────────────────────────────────────────────────────────────

_aiteamforge_get_field() {
    local team="$1"
    local field="$2"
    local config_path
    config_path=$(aiteamforge_config_path)

    # ── Try jq ────────────────────────────────────────────────────────────
    if [ -f "$config_path" ] && command -v jq &>/dev/null; then
        local version
        version=$(jq -r '.schema_version // 0' "$config_path" 2>/dev/null)
        if [ "$version" != "1" ] && [ "$version" != "0" ]; then
            echo "[aiteamforge-paths] WARNING: schema_version=${version} unsupported" >&2
        fi

        local value
        value=$(jq -r --arg t "$team" --arg f "$field" \
            '.teams[$t][$f] // empty' "$config_path" 2>/dev/null)
        if [ -n "$value" ] && [ "$value" != "null" ]; then
            echo "$value"
            return 0
        fi
        # Team not in file — fall through to bootstrap or defaults
    fi

    # ── Try python3 (jq unavailable) ─────────────────────────────────────
    if [ -f "$config_path" ] && command -v python3 &>/dev/null; then
        local value
        value=$("${AITEAMFORGE_PYTHON:-python3}" - "$config_path" "$team" "$field" <<'PYEOF' 2>/dev/null
import sys, json
from pathlib import Path
config_path, team, field = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    config = json.loads(Path(config_path).read_text(encoding='utf-8'))
    entry = config.get('teams', {}).get(team, {})
    v = entry.get(field)
    if v is not None:
        print(v)
except Exception:
    pass
PYEOF
)
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    fi

    # ── Bootstrap: config missing ─────────────────────────────────────────
    if [ ! -f "$config_path" ]; then
        if _aiteamforge_is_interactive; then
            echo "[aiteamforge-paths] Config not found at ${config_path}." >&2
            echo "  Run: aiteamforge-paths init" >&2
            echo "  Falling back to built-in defaults." >&2
        else
            echo "[aiteamforge-paths] Config missing — writing defaults to ${config_path}" >&2
            _AITEAMFORGE_DEFAULT_TEAMS_DATA | _aiteamforge_write_defaults
        fi
    fi

    # ── Shell default fallback ────────────────────────────────────────────
    local home="$HOME"
    local found_team=0
    local result=""

    while IFS=$'\t' read -r t kanban_dir working_dir lcars_port; do
        # Expand $HOME / ${HOME} in paths (heredoc uses literal ${HOME})
        kanban_dir="${kanban_dir/\$\{HOME\}/$home}"
        kanban_dir="${kanban_dir/\$HOME/$home}"
        working_dir="${working_dir/\$\{HOME\}/$home}"
        working_dir="${working_dir/\$HOME/$home}"

        if [ "$t" = "$team" ]; then
            found_team=1
            case "$field" in
                kanban_dir)  result="$kanban_dir" ;;
                working_dir) result="$working_dir" ;;
                lcars_port)  result="$lcars_port" ;;
            esac
            break
        fi
    done < <(_AITEAMFORGE_DEFAULT_TEAMS_DATA)

    if [ "$found_team" -eq 0 ]; then
        return 1  # team not found
    fi

    if [ -n "$result" ]; then
        echo "$result"
        return 0
    fi
    return 1  # field not set (e.g. lcars_port for teams without LCARS)
}

# ─────────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────────

# aiteamforge_team_kanban_dir <team>
# Prints the kanban directory for the given team, or returns nonzero.
aiteamforge_team_kanban_dir() {
    local team="$1"
    local result
    result=$(_aiteamforge_get_field "$team" "kanban_dir") || {
        local config_path
        config_path=$(aiteamforge_config_path)
        echo "Team '${team}' not found. Available: $(aiteamforge_list_teams | tr '\n' ' ') — edit ${config_path} or run \`aiteamforge-paths init\`." >&2
        return 1
    }
    echo "$result"
}

# aiteamforge_team_working_dir <team>
# Prints the working directory (project root) for the given team.
aiteamforge_team_working_dir() {
    local team="$1"
    local result
    result=$(_aiteamforge_get_field "$team" "working_dir") || {
        local config_path
        config_path=$(aiteamforge_config_path)
        echo "Team '${team}' not found. Available: $(aiteamforge_list_teams | tr '\n' ' ') — edit ${config_path} or run \`aiteamforge-paths init\`." >&2
        return 1
    }
    echo "$result"
}

# aiteamforge_team_lcars_port <team>
# Prints the LCARS port number, or returns nonzero if not applicable / unknown team.
aiteamforge_team_lcars_port() {
    local team="$1"
    local result
    result=$(_aiteamforge_get_field "$team" "lcars_port") || {
        local config_path
        config_path=$(aiteamforge_config_path)
        echo "Team '${team}' not found. Available: $(aiteamforge_list_teams | tr '\n' ' ') — edit ${config_path} or run \`aiteamforge-paths init\`." >&2
        return 1
    }
    if [ -z "$result" ] || [ "$result" = "null" ]; then
        return 1  # team exists but has no LCARS port
    fi
    echo "$result"
}

# aiteamforge_export_exclusions
# Prints one exclusion pattern per line, suitable for use with:
#   zip --exclude or rsync --exclude
# Mirrors EXPORT_EXCLUSION_SUFFIXES / EXPORT_EXCLUSION_NAMES / EXPORT_EXCLUSION_PATTERNS
# in kanban-hooks/aiteamforge_paths.py — keep in sync. (XACA-0168-017)
aiteamforge_export_exclusions() {
    # Suffix-based exclusions
    printf '*.lock\n'
    # Exact-name exclusions
    printf '.DS_Store\n'
    printf 'firebase-debug.log\n'
    # Pattern exclusions
    printf '*-debug.log\n'
}

# aiteamforge_list_teams
# Prints one team ID per line.
aiteamforge_list_teams() {
    local config_path
    config_path=$(aiteamforge_config_path)

    if [ -f "$config_path" ] && command -v jq &>/dev/null; then
        jq -r '.teams | keys[]' "$config_path" 2>/dev/null
        return 0
    fi

    if [ -f "$config_path" ] && command -v python3 &>/dev/null; then
        "${AITEAMFORGE_PYTHON:-python3}" - "$config_path" <<'PYEOF' 2>/dev/null
import sys, json
from pathlib import Path
config = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
for team in config.get('teams', {}).keys():
    print(team)
PYEOF
        return 0
    fi

    # Fall back to built-in defaults
    while IFS=$'\t' read -r team _rest; do
        echo "$team"
    done < <(_AITEAMFORGE_DEFAULT_TEAMS_DATA)
}
