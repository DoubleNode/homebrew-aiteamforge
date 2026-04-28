#!/bin/bash
# aiteamforge-org-paths.sh — Organization identity resolver (shell layer)
#
# XACA-0139-001 — Foundation: org identity config loader
#
# This file is the shell counterpart to
# share/kanban-hooks/aiteamforge_org_paths.py.  Both must produce identical
# results for the same organization.yaml input.
#
# Relationship to sibling resolvers in this directory:
#   aiteamforge-paths.sh     — TEAM identity (team → kanban/working dir)
#   aiteamforge-org-paths.sh — ORG  identity (slug, name, plugins, integrations)
#
# Both are loaded at shell startup; callers should `source` whichever they
# need and call the public functions below.
#
# USAGE:
#   source /path/to/aiteamforge-org-paths.sh
#   slug=$(_aiteamforge_org_slug)
#   if _aiteamforge_org_plugin_enabled "main-event"; then
#       echo "main-event plugin is on"
#   fi
#   jira_url=$(_aiteamforge_org_integration_get jira base_url)
#
# DEPENDENCIES:
#   yq (preferred, if installed) OR python3 + PyYAML (fallback).
#   If neither works the loader prints a clear error to stderr and returns
#   non-zero from the first function that needs parsed data.
#
# ENVIRONMENT:
#   AITEAMFORGE_ORG_CONFIG  — override config path (for tests / CI)
#   AITEAMFORGE_DIR         — optional working-dir override
#   AITEAMFORGE_SHARE_DIR   — framework share/ dir (used to locate the
#                             shipped organization.yaml.example fallback)
#
# Author: Academy Team — XACA-0139

# Guard against double-sourcing
if [ -n "${_AITEAMFORGE_ORG_PATHS_LOADED:-}" ]; then
    return 0
fi
_AITEAMFORGE_ORG_PATHS_LOADED=1

# Resolve tap-owned Python venv interpreter ($AITEAMFORGE_PYTHON) if available.
# python-env.sh lives alongside this file in the same lib/ directory.
_atf_org_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# shellcheck source=./python-env.sh
[ -f "$_atf_org_script_dir/python-env.sh" ] && . "$_atf_org_script_dir/python-env.sh" 2>/dev/null || true

# If AITEAMFORGE_SHARE_DIR is unset, try to infer it: this file lives at
# <tap>/libexec/lib/, share is at <tap>/share.  Safe under `set -u`.
if [ -z "${AITEAMFORGE_SHARE_DIR:-}" ] && [ -n "$_atf_org_script_dir" ]; then
    _atf_org_guess_share="$(cd "$_atf_org_script_dir/../../share" 2>/dev/null && pwd || echo "")"
    if [ -n "$_atf_org_guess_share" ]; then
        AITEAMFORGE_SHARE_DIR="$_atf_org_guess_share"
    fi
    unset _atf_org_guess_share
fi
unset _atf_org_script_dir

# ─────────────────────────────────────────────────────────────────────────────
# Module-level cache (populated on first successful parse)
# ─────────────────────────────────────────────────────────────────────────────

_AITEAMFORGE_ORG_CACHE_LOADED=""
_AITEAMFORGE_ORG_CACHE_PATH=""     # the path we loaded (for invalidation)
_AITEAMFORGE_ORG_CACHE_SLUG=""
_AITEAMFORGE_ORG_CACHE_NAME=""
_AITEAMFORGE_ORG_CACHE_SHORT=""
_AITEAMFORGE_ORG_CACHE_DOMAIN=""
_AITEAMFORGE_ORG_CACHE_PROJECTS_ROOT=""
_AITEAMFORGE_ORG_CACHE_SHARED_DEV_ROOT=""
_AITEAMFORGE_ORG_CACHE_PLUGINS=""   # newline-separated list of enabled slugs
# Integrations are looked up on demand (not cached as a single flat list)
# because they have unknown depth — the cache stores only the config path,
# and _aiteamforge_org_integration_get re-queries the YAML.

# ─────────────────────────────────────────────────────────────────────────────
# Public: config path resolution
# ─────────────────────────────────────────────────────────────────────────────

# _aiteamforge_org_config_path
# Echoes the path to the active organization.yaml (or the shipped .example
# as the final fallback).  Prints nothing to stderr on the normal path.
_aiteamforge_org_config_path() {
    # 1. Explicit env override wins
    if [ -n "${AITEAMFORGE_ORG_CONFIG:-}" ]; then
        echo "$AITEAMFORGE_ORG_CONFIG"
        return 0
    fi

    # 2. Working-dir config (for multi-install / per-project overrides)
    if [ -n "${AITEAMFORGE_DIR:-}" ] && [ -f "${AITEAMFORGE_DIR}/organization.yaml" ]; then
        echo "${AITEAMFORGE_DIR}/organization.yaml"
        return 0
    fi

    # 3. Canonical per-user config
    if [ -f "${HOME}/.aiteamforge/organization.yaml" ]; then
        echo "${HOME}/.aiteamforge/organization.yaml"
        return 0
    fi

    # 4. Fallback: the shipped example ships with the framework.  This keeps
    # lookups working on a fresh install before setup has populated the user
    # config — all values fall back to the "example-org" defaults.
    if [ -n "${AITEAMFORGE_SHARE_DIR:-}" ] && \
       [ -f "${AITEAMFORGE_SHARE_DIR}/config/organization.yaml.example" ]; then
        echo "${AITEAMFORGE_SHARE_DIR}/config/organization.yaml.example"
        return 0
    fi

    # Nothing found — emit empty (caller decides what to do)
    echo ""
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal: invalidate cache if the resolved config path changed
# (e.g. a test toggles $AITEAMFORGE_ORG_CONFIG between calls)
# ─────────────────────────────────────────────────────────────────────────────

_aiteamforge_org_cache_valid() {
    local current
    current=$(_aiteamforge_org_config_path 2>/dev/null || echo "")
    if [ "$_AITEAMFORGE_ORG_CACHE_LOADED" = "1" ] && \
       [ "$_AITEAMFORGE_ORG_CACHE_PATH" = "$current" ]; then
        return 0
    fi
    return 1
}

_aiteamforge_org_cache_reset() {
    _AITEAMFORGE_ORG_CACHE_LOADED=""
    _AITEAMFORGE_ORG_CACHE_PATH=""
    _AITEAMFORGE_ORG_CACHE_SLUG=""
    _AITEAMFORGE_ORG_CACHE_NAME=""
    _AITEAMFORGE_ORG_CACHE_SHORT=""
    _AITEAMFORGE_ORG_CACHE_DOMAIN=""
    _AITEAMFORGE_ORG_CACHE_PROJECTS_ROOT=""
    _AITEAMFORGE_ORG_CACHE_SHARED_DEV_ROOT=""
    _AITEAMFORGE_ORG_CACHE_PLUGINS=""
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal: raw YAML value lookup via yq or python3+PyYAML.
#
# _aiteamforge_org_yaml_get <config_path> <dotted.path> [default]
#   Echoes the value at the dotted path, or `default` (or empty) if absent.
#   Uses yq if available, falls back to python3+PyYAML.
#   Fails clearly (non-zero, stderr message) if neither is available.
# ─────────────────────────────────────────────────────────────────────────────

_aiteamforge_org_yaml_get() {
    local config_path="$1"
    local dotted="$2"
    local default="${3:-}"

    if [ ! -f "$config_path" ]; then
        echo "$default"
        return 0
    fi

    # ── yq path ────────────────────────────────────────────────────────────
    if command -v yq >/dev/null 2>&1; then
        local value
        value=$(yq eval ".${dotted} // \"\"" "$config_path" 2>/dev/null)
        if [ -n "$value" ] && [ "$value" != "null" ]; then
            echo "$value"
            return 0
        fi
        echo "$default"
        return 0
    fi

    # ── python3 + PyYAML fallback ──────────────────────────────────────────
    if command -v "${AITEAMFORGE_PYTHON:-python3}" >/dev/null 2>&1; then
        local py_result
        py_result=$("${AITEAMFORGE_PYTHON:-python3}" - "$config_path" "$dotted" "$default" <<'PYEOF' 2>/dev/null
import sys
try:
    import yaml
except ImportError:
    sys.exit(2)

config_path, dotted, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(config_path, "r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
except Exception:
    print(default, end="")
    sys.exit(0)

node = data
for part in dotted.split("."):
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        node = None
        break

if node is None:
    print(default, end="")
elif isinstance(node, (list, dict)):
    # Callers for list/dict values use dedicated helpers; as a scalar
    # fallback we print nothing rather than the dict repr.
    print(default, end="")
else:
    print(str(node), end="")
PYEOF
        )
        local rc=$?
        if [ $rc -eq 2 ]; then
            echo "[aiteamforge-org-paths] ERROR: PyYAML not installed; cannot parse YAML config" >&2
            return 1
        fi
        echo "$py_result"
        return 0
    fi

    echo "[aiteamforge-org-paths] ERROR: need yq or python3+PyYAML to parse ${config_path}" >&2
    return 1
}

# Expand ${HOME} / $HOME references in a value.  Safe under `set -u`.
_aiteamforge_org_expand_home() {
    local value="${1:-}"
    local home="$HOME"
    value="${value//\$\{HOME\}/$home}"
    value="${value//\$HOME/$home}"
    echo "$value"
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal: populate the cache from the current config file.
# Idempotent — does nothing if the cache is already valid for this path.
# ─────────────────────────────────────────────────────────────────────────────

_aiteamforge_org_load() {
    if _aiteamforge_org_cache_valid; then
        return 0
    fi

    _aiteamforge_org_cache_reset

    local config_path
    config_path=$(_aiteamforge_org_config_path 2>/dev/null || echo "")

    _AITEAMFORGE_ORG_CACHE_PATH="$config_path"
    _AITEAMFORGE_ORG_CACHE_LOADED=1

    if [ -z "$config_path" ] || [ ! -f "$config_path" ]; then
        # No config anywhere — defaults are baked into the public getters.
        return 0
    fi

    # Scalars
    _AITEAMFORGE_ORG_CACHE_SLUG=$(_aiteamforge_org_yaml_get "$config_path" "organization.slug" "example-org")
    _AITEAMFORGE_ORG_CACHE_NAME=$(_aiteamforge_org_yaml_get "$config_path" "organization.name" "Example Organization")
    _AITEAMFORGE_ORG_CACHE_SHORT=$(_aiteamforge_org_yaml_get "$config_path" "organization.display_short" "")
    _AITEAMFORGE_ORG_CACHE_DOMAIN=$(_aiteamforge_org_yaml_get "$config_path" "organization.domain" "")

    local projects_root shared_dev
    projects_root=$(_aiteamforge_org_yaml_get "$config_path" "paths.projects_root" "\${HOME}/projects")
    shared_dev=$(_aiteamforge_org_yaml_get "$config_path" "paths.shared_dev_root" "")
    _AITEAMFORGE_ORG_CACHE_PROJECTS_ROOT=$(_aiteamforge_org_expand_home "$projects_root")
    _AITEAMFORGE_ORG_CACHE_SHARED_DEV_ROOT=$(_aiteamforge_org_expand_home "$shared_dev")

    # Plugins list — we need the whole array, not a scalar.  Render it as
    # newline-separated text in the cache.
    if command -v yq >/dev/null 2>&1; then
        _AITEAMFORGE_ORG_CACHE_PLUGINS=$(yq eval '.plugins.enabled[]' "$config_path" 2>/dev/null || echo "")
    elif command -v "${AITEAMFORGE_PYTHON:-python3}" >/dev/null 2>&1; then
        _AITEAMFORGE_ORG_CACHE_PLUGINS=$(
            "${AITEAMFORGE_PYTHON:-python3}" - "$config_path" <<'PYEOF' 2>/dev/null
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
except Exception:
    sys.exit(0)
plugins = (data.get("plugins") or {}).get("enabled") or []
if isinstance(plugins, list):
    for p in plugins:
        print(str(p))
PYEOF
        )
    fi

    # Fallbacks if the YAML parsed successfully but the values are empty
    [ -z "$_AITEAMFORGE_ORG_CACHE_SLUG" ] && _AITEAMFORGE_ORG_CACHE_SLUG="example-org"
    [ -z "$_AITEAMFORGE_ORG_CACHE_NAME" ] && _AITEAMFORGE_ORG_CACHE_NAME="Example Organization"

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Public API — scalar getters
# ─────────────────────────────────────────────────────────────────────────────

# _aiteamforge_org_slug
# Echoes organization.slug (default "example-org" if unset).
_aiteamforge_org_slug() {
    _aiteamforge_org_load
    if [ -n "$_AITEAMFORGE_ORG_CACHE_SLUG" ]; then
        echo "$_AITEAMFORGE_ORG_CACHE_SLUG"
    else
        echo "example-org"
    fi
}

# _aiteamforge_org_name
# Echoes organization.name (default "Example Organization" if unset).
_aiteamforge_org_name() {
    _aiteamforge_org_load
    if [ -n "$_AITEAMFORGE_ORG_CACHE_NAME" ]; then
        echo "$_AITEAMFORGE_ORG_CACHE_NAME"
    else
        echo "Example Organization"
    fi
}

# _aiteamforge_org_display_short
# Echoes organization.display_short, falling back to organization.name.
_aiteamforge_org_display_short() {
    _aiteamforge_org_load
    if [ -n "$_AITEAMFORGE_ORG_CACHE_SHORT" ]; then
        echo "$_AITEAMFORGE_ORG_CACHE_SHORT"
    else
        _aiteamforge_org_name
    fi
}

# _aiteamforge_org_domain
# Echoes organization.domain, or empty string if unset.
_aiteamforge_org_domain() {
    _aiteamforge_org_load
    echo "$_AITEAMFORGE_ORG_CACHE_DOMAIN"
}

# _aiteamforge_org_projects_root
# Echoes paths.projects_root with ${HOME} expanded.
# Default: "$HOME/projects" if unset.
_aiteamforge_org_projects_root() {
    _aiteamforge_org_load
    if [ -n "$_AITEAMFORGE_ORG_CACHE_PROJECTS_ROOT" ]; then
        echo "$_AITEAMFORGE_ORG_CACHE_PROJECTS_ROOT"
    else
        echo "${HOME}/projects"
    fi
}

# _aiteamforge_org_shared_dev_root
# Echoes paths.shared_dev_root (empty string if unset).
_aiteamforge_org_shared_dev_root() {
    _aiteamforge_org_load
    echo "$_AITEAMFORGE_ORG_CACHE_SHARED_DEV_ROOT"
}

# ─────────────────────────────────────────────────────────────────────────────
# Public API — plugin + integration helpers
# ─────────────────────────────────────────────────────────────────────────────

# _aiteamforge_org_plugin_enabled <slug>
# Returns 0 if the plugin slug appears in plugins.enabled, 1 otherwise.
# Prints nothing to stdout.
_aiteamforge_org_plugin_enabled() {
    local target="${1:-}"
    if [ -z "$target" ]; then
        return 1
    fi
    _aiteamforge_org_load
    if [ -z "$_AITEAMFORGE_ORG_CACHE_PLUGINS" ]; then
        return 1
    fi
    # Iterate newline-separated cache; match exact slug
    local plugin
    while IFS= read -r plugin; do
        [ -z "$plugin" ] && continue
        if [ "$plugin" = "$target" ]; then
            return 0
        fi
    done <<EOF
$_AITEAMFORGE_ORG_CACHE_PLUGINS
EOF
    return 1
}

# _aiteamforge_org_integration_get <integration> <key>
# Echoes the scalar value at integrations.<integration>.<key>, or empty
# string if the integration block or key is absent.  List-valued keys
# (e.g. integrations.jira.project_keys) are joined with newlines.
_aiteamforge_org_integration_get() {
    local integration="${1:-}"
    local key="${2:-}"
    if [ -z "$integration" ] || [ -z "$key" ]; then
        echo ""
        return 1
    fi

    _aiteamforge_org_load
    local config_path="$_AITEAMFORGE_ORG_CACHE_PATH"
    if [ -z "$config_path" ] || [ ! -f "$config_path" ]; then
        echo ""
        return 0
    fi

    # Try yq first.  Detect list-valued keys via the `tag` probe; lists emit
    # one unquoted item per line via `.[]`, scalars emit the raw value.
    if command -v yq >/dev/null 2>&1; then
        local tag
        tag=$(yq eval ".integrations.${integration}.${key} | tag" "$config_path" 2>/dev/null)
        if [ "$tag" = "!!null" ] || [ -z "$tag" ]; then
            echo ""
            return 0
        fi
        if [ "$tag" = "!!seq" ]; then
            yq eval ".integrations.${integration}.${key}[]" "$config_path" 2>/dev/null
            return 0
        fi
        if [ "$tag" = "!!map" ]; then
            # Nested dict — callers wanting nested blocks should use Python
            echo ""
            return 0
        fi
        yq eval ".integrations.${integration}.${key}" "$config_path" 2>/dev/null
        return 0
    fi

    # python3 + PyYAML fallback — handles both scalar and list naturally
    if command -v "${AITEAMFORGE_PYTHON:-python3}" >/dev/null 2>&1; then
        "${AITEAMFORGE_PYTHON:-python3}" - "$config_path" "$integration" "$key" <<'PYEOF' 2>/dev/null
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)

config_path, integration, key = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(config_path, "r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
except Exception:
    sys.exit(0)

block = (data.get("integrations") or {}).get(integration) or {}
if not isinstance(block, dict):
    sys.exit(0)
value = block.get(key)
if value is None:
    sys.exit(0)
if isinstance(value, list):
    for item in value:
        print(str(item))
elif isinstance(value, dict):
    # Dict values aren't meaningful via this flat accessor — emit nothing.
    pass
else:
    print(str(value), end="")
PYEOF
        return 0
    fi

    echo "[aiteamforge-org-paths] ERROR: need yq or python3+PyYAML to read integrations" >&2
    echo ""
    return 1
}
