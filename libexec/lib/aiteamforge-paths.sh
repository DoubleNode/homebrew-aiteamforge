#!/bin/bash
# aiteamforge-paths.sh — Canonical team path config loader (shell layer)
#
# XACA-0168-001 — Wave 1: Config schema + loader module
# XACA-0139-002 — De-branding: org-resolver integration
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
# shellcheck source=./aiteamforge-org-paths.sh
[ -f "$_atf_paths_script_dir/aiteamforge-org-paths.sh" ] && . "$_atf_paths_script_dir/aiteamforge-org-paths.sh" 2>/dev/null || true
unset _atf_paths_script_dir

# ─────────────────────────────────────────────────────────────────────────────
# Internal: org-resolver helpers for path composition
#
# These helpers allow the DEFAULT_TEAMS heredoc and any other path builder to
# reference organization-specific directory segments without hard-coding client
# names.  All helpers are safe to call when the org resolver is not loaded
# (they produce the legacy fallback values so existing installs keep working).
# ─────────────────────────────────────────────────────────────────────────────

# _atf_paths_org_shared_dev_root
# Echoes the shared_dev_root from the org resolver, or empty string.
# Used when composing /Users/Shared/Development or equivalent.
_atf_paths_org_shared_dev_root() {
    if command -v _aiteamforge_org_shared_dev_root >/dev/null 2>&1; then
        _aiteamforge_org_shared_dev_root 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# _atf_paths_org_name
# Echoes the org name from the resolver.  Falls back to empty so callers
# can detect "no resolver / not configured" and use the legacy literal.
_atf_paths_org_name() {
    if command -v _aiteamforge_org_slug >/dev/null 2>&1; then
        local slug
        slug=$(_aiteamforge_org_slug 2>/dev/null || echo "example-org")
        # Treat the placeholder as "not configured" — return empty so callers
        # fall back to their baked-in legacy value.
        if [ "$slug" = "example-org" ] || [ -z "$slug" ]; then
            echo ""
            return 0
        fi
        _aiteamforge_org_name 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# _atf_paths_org_plugin_dir_name <legacy_dir_name>
# xaca-0139:allowed — doc comment naming legacy dir names as examples for the resolver function
# Given a legacy hard-coded directory name (e.g. "Main Event", "DoubleNode"),
# returns the org-resolver name when the resolver is configured and the plugin
# matching the legacy name appears to be active; otherwise returns the legacy
# name unchanged.  This keeps directory resolution correct for existing installs
# that have not yet run `aiteamforge setup` to write organization.yaml.
#
# Usage is internal to _AITEAMFORGE_DEFAULT_TEAMS_DATA.
_atf_paths_org_plugin_dir_name() {
    local legacy_name="$1"
    local org_name
    org_name=$(_atf_paths_org_name)
    if [ -n "$org_name" ]; then
        echo "$org_name"
    else
        echo "$legacy_name"
    fi
}

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
#
# XACA-0139-002: Paths for org-specific teams (ios, android, firebase, command,
# and legacy mainevent alias) are now composed via the org resolver so the same # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
# defaults work for any org whose shared_dev_root and name are configured.
# When the resolver returns placeholder / empty values the literal legacy paths
# are used — this preserves backward compatibility for existing installs that
# have not yet run `aiteamforge setup` to write organization.yaml.
#
# xaca-0139:allowed — doc comment explaining DoubleNode dir name is a stable project-family path, not org branding
# DoubleNode freelance team paths use the same resolver-driven composition:
# <shared_dev_root>/DoubleNode/<project> is replaced with # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
# <shared_dev_root>/<doublenode_dir>/<project> where doublenode_dir is the # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
# literal string "DoubleNode" (a stable project-family directory name, not an # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
# org display name) — kept as-is to avoid breaking existing disk layouts.
# ─────────────────────────────────────────────────────────────────────────────

_AITEAMFORGE_DEFAULT_TEAMS_DATA() {
    # Emit: team_id TAB kanban_dir TAB working_dir TAB lcars_port
    # (lcars_port is empty when not applicable)

    # Resolve org-driven path prefix for the primary org's shared projects.
    # Falls back to the hardcoded legacy prefix when the resolver is not yet
    # configured (org slug = "example-org" or resolver unavailable).
    local _shared_dev
    _shared_dev=$(_atf_paths_org_shared_dev_root)
    # If shared_dev_root is not configured use the canonical shared-Mac path.
    if [ -z "$_shared_dev" ]; then
        _shared_dev="/Users/Shared/Development"
    fi

    # Primary org name as a directory segment (e.g. "Main Event"). # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
    # Empty when resolver is not configured → falls back to legacy literal.
    local _org_name
    _org_name=$(_atf_paths_org_name)

    # Compose the org-named project root.  If the org name is not yet known
    # we use the legacy "Main Event" literal so existing installs keep working. # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
    local _org_prefix
    if [ -n "$_org_name" ]; then
        _org_prefix="${_shared_dev}/${_org_name}"
    else
        # xaca-0139:allowed — backward-compat fallback for pre-XACA-0139 installs without organization.yaml
        _org_prefix="${_shared_dev}/Main Event"
    fi

    # Shared-dev prefix used for org-agnostic third-party project families
    # (DNSFramework, Liquidstyle) — these never carry the org name.
    local _shared_prefix="${_shared_dev}"

    printf '%s\t%s\t%s\t%s\n' "academy"      "${HOME}/dev-team/kanban"                                    "${HOME}/dev-team"                                          "8203"
    # xaca-0139:allowed — MainEventApp-* are stable per-project repo directory names (not org branding); resolved via _org_prefix
    printf '%s\t%s\t%s\t%s\n' "ios"           "${_org_prefix}/MainEventApp-iOS/kanban"                    "${_org_prefix}/MainEventApp-iOS"                           "8260"
    printf '%s\t%s\t%s\t%s\n' "android"       "${_org_prefix}/MainEventApp-Android/kanban"                "${_org_prefix}/MainEventApp-Android"                       "8280" # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
    printf '%s\t%s\t%s\t%s\n' "firebase"      "${_org_prefix}/MainEventApp-Functions/kanban"              "${_org_prefix}/MainEventApp-Functions"                     "8240" # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
    printf '%s\t%s\t%s\t%s\n' "command"       "${_org_prefix}/dev-team/kanban"                            "${_org_prefix}/dev-team"                                   "8234"
    printf '%s\t%s\t%s\t%s\n' "dns"           "${_shared_prefix}/DNSFramework/kanban"                     "${_shared_prefix}/DNSFramework"                            "8180"
    # xaca-0139:allowed — freelance-doublenode-* are stable team slug / disk path constants; DoubleNode is a project-family dir name
    printf '%s\t%s\t%s\t%s\n' "freelance-doublenode-starwords"    "${_shared_prefix}/DoubleNode/Starwords/kanban"     "${_shared_prefix}/DoubleNode/Starwords"     "8505"
    printf '%s\t%s\t%s\t%s\n' "freelance-doublenode-appplanning"  "${_shared_prefix}/DoubleNode/appPlanning/kanban"  "${_shared_prefix}/DoubleNode/appPlanning"  "8505" # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
    printf '%s\t%s\t%s\t%s\n' "freelance-doublenode-workstats"    "${_shared_prefix}/DoubleNode/WorkStats/kanban"    "${_shared_prefix}/DoubleNode/WorkStats"    "8505" # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
    printf '%s\t%s\t%s\t%s\n' "freelance-doublenode-lifeboard"    "${_shared_prefix}/DoubleNode/LifeBoard/kanban"    "${_shared_prefix}/DoubleNode/LifeBoard"    "8505" # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
    printf '%s\t%s\t%s\t%s\n' "freelance-doublenode-caravan"      "${_shared_prefix}/DoubleNode/Caravan/kanban"      "${_shared_prefix}/DoubleNode/Caravan"      "8505" # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
    printf '%s\t%s\t%s\t%s\n' "freelance-doublenode-awaysentry"   "${_shared_prefix}/DoubleNode/AwaySentry/kanban"   "${_shared_prefix}/DoubleNode/AwaySentry"   "8505" # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
    printf '%s\t%s\t%s\t%s\n' "freelance-liquidstyle-agentbadges-app" "${_shared_prefix}/Liquidstyle/AgentBadges-APP/kanban" "${_shared_prefix}/Liquidstyle/AgentBadges-APP" "8960"
    printf '%s\t%s\t%s\t%s\n' "freelance-liquidstyle-agentbadges-ios" "${_shared_prefix}/Liquidstyle/AgentBadges-IOS/kanban" "${_shared_prefix}/Liquidstyle/AgentBadges-IOS" "8970"
    printf '%s\t%s\t%s\n'     "legal-coparenting"  "${HOME}/legal/coparenting/kanban"                     "${HOME}/legal/coparenting"
    printf '%s\t%s\t%s\n'     "medical-general"    "${HOME}/medical/general/kanban"                       "${HOME}/medical/general"
    printf '%s\t%s\t%s\n'     "finance-personal"   "${HOME}/finance/personal/kanban"                      "${HOME}/finance/personal"
    # Legacy alias kept for backward compatibility with pre-XACA-0139 installs.
    # The "mainevent" team ID was used before the org plugin system existed; # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
    # new installs use the "command" team or enable the primary org plugin.
    # xaca-0139:allowed — "mainevent" is a registered legacy team slug (backward-compat alias, not user-facing org branding)
    printf '%s\t%s\t%s\t%s\n' "mainevent"     "${_org_prefix}/dev-team/kanban"                            "${_org_prefix}/dev-team"                                   "8234"
    printf '%s\t%s\t%s\n'     "medical"        "${HOME}/medical/general/kanban"                           "${HOME}/medical/general"
    printf '%s\t%s\t%s\t%s\n' "freelance"      "${HOME}/dev-team/kanban"                                  "${HOME}/dev-team"                                          "8505"
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
        # Note: do NOT re-declare `local value` here — zsh's `local NAME` (no
        # assignment) on an already-local variable prints `NAME=...` to stdout,
        # which corrupts the captured return of this function. $value is
        # already local from the jq branch above.
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
