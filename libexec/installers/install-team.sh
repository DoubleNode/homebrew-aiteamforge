#!/bin/bash
# Team Installer Module
# Installs a specific team's environment, tools, and configuration
# Usage: install-team.sh <team-id> [--install-dir <path>]

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMEBREW_TAP_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEAMS_DIR="$HOMEBREW_TAP_ROOT/share/teams"

# Source org identity resolver (XACA-0139) — graceful no-op if lib not yet installed.
# Must come after HOMEBREW_TAP_ROOT is set so the resolver can locate its share/ fallback.
AITEAMFORGE_SHARE_DIR="$HOMEBREW_TAP_ROOT/share"
export AITEAMFORGE_SHARE_DIR
# shellcheck source=../lib/aiteamforge-org-paths.sh
# shellcheck disable=SC1091  # source guarded by file-test or `|| true`; default-mode can't follow
source "${SCRIPT_DIR}/../lib/aiteamforge-org-paths.sh" 2>/dev/null || true
# XACA-0463: Source the port allocator and path helpers.
# aiteamforge-paths.sh itself sources aiteamforge-org-paths.sh internally, so
# the double-source is safe (aiteamforge-org-paths.sh has a guard against it).
# shellcheck source=../lib/aiteamforge-paths.sh
# shellcheck disable=SC1091  # source guarded by file-test or `|| true`; default-mode can't follow
source "${SCRIPT_DIR}/../lib/aiteamforge-paths.sh"

# Default installation location (can be overridden)
AITEAMFORGE_DIR="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

TEAM_ID=""
CONNECT_ONLY=false
ARG_PROJECT=""
ARG_CLIENT=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --install-dir|--aiteamforge-dir)
            AITEAMFORGE_DIR="$2"
            shift 2
            ;;
        --connect-only)
            CONNECT_ONLY=true
            shift
            ;;
        --project)
            ARG_PROJECT="$2"
            shift 2
            ;;
        --client)
            ARG_CLIENT="$2"
            shift 2
            ;;
        *)
            if [[ -z "$TEAM_ID" ]]; then
                TEAM_ID="$1"
            else
                echo "Error: Unknown argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$TEAM_ID" ]]; then
    echo "Usage: install-team.sh <team-id> [--install-dir <path>] [--connect-only]"
    echo ""
    echo "Available teams:"
    for conf in "$TEAMS_DIR"/*.conf; do
        if [[ -f "$conf" ]]; then
            basename "$conf" .conf
        fi
    done
    exit 1
fi

# Validate TEAM_ID - alphanumeric, hyphens, and underscores only (BEFORE file check)
if [[ ! "$TEAM_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Invalid team ID: $TEAM_ID (alphanumeric, hyphens, and underscores only)"
    exit 1
fi

# ============================================================================
# DEV-SOURCE PROTECTION GUARD (XACA-0497)
# ============================================================================
# Refuse to install on top of an AITeamForge dev-team source tree. A sentinel
# file `.aiteamforge-source-tree` at the root of AITEAMFORGE_DIR marks the
# directory as a development source-of-truth. Installing the tap product on
# top of source pollutes it with rendered artifacts — the failure mode that
# XACA-0497 recovered from (AITEAMFORGE_DIR inherited from a dev shell
# overrode the safe `:-$HOME/aiteamforge` default).
_AITF_REAL="$(cd "$AITEAMFORGE_DIR" 2>/dev/null && pwd -P || echo "")"
if [[ -n "$_AITF_REAL" && -f "$_AITF_REAL/.aiteamforge-source-tree" ]]; then
    echo "Error: target directory is an AITeamForge dev-team source tree:" >&2
    echo "       $_AITF_REAL" >&2
    echo "       Refusing to install tap product on top of source." >&2
    echo "       Unset AITEAMFORGE_DIR or pass --install-dir to a different path." >&2
    exit 1
fi
unset _AITF_REAL

# ============================================================================
# LOAD TEAM DEFINITION
# ============================================================================

TEAM_CONF="$TEAMS_DIR/$TEAM_ID.conf"
if [[ ! -f "$TEAM_CONF" ]]; then
    echo "Error: Team configuration not found: $TEAM_CONF"
    exit 1
fi

# Read conf values safely in a subshell so the conf file cannot modify the
# current shell's PATH, functions, or other sensitive state.  The subshell
# sources the file and then serializes only the known scalar and array
# variables back to stdout as eval-safe quoted assignments.  The parent shell
# evals that output to import the values.
_read_conf() {
    local conf_file="$1"
    (
        # Source in a clean subshell — side effects are contained here.
        # shellcheck disable=SC1090
        source "$conf_file"

        # Emit scalar variables as KEY='value' lines.
        printf 'TEAM_NAME=%q\n'         "${TEAM_NAME:-}"
        printf 'TEAM_DESCRIPTION=%q\n'  "${TEAM_DESCRIPTION:-}"
        printf 'TEAM_CATEGORY=%q\n'     "${TEAM_CATEGORY:-}"
        printf 'TEAM_COLOR=%q\n'        "${TEAM_COLOR:-#5585CC}"
        printf 'TEAM_LCARS_PORT=%q\n'   "${TEAM_LCARS_PORT:-8200}"
        printf 'TEAM_TMUX_SOCKET=%q\n'  "${TEAM_TMUX_SOCKET:-$TEAM_ID}"
        printf 'TEAM_WORKING_DIR=%q\n'  "${TEAM_WORKING_DIR:-}"
        printf 'TEAM_THEME=%q\n'        "${TEAM_THEME:-}"
        printf 'TEAM_SHIP=%q\n'         "${TEAM_SHIP:-}"
        printf 'TEAM_STARTUP_SCRIPT=%q\n'  "${TEAM_STARTUP_SCRIPT:-${TEAM_ID}-startup.sh}"
        printf 'TEAM_SHUTDOWN_SCRIPT=%q\n' "${TEAM_SHUTDOWN_SCRIPT:-${TEAM_ID}-shutdown.sh}"
        printf 'TEAM_HAS_PROJECTS=%q\n'    "${TEAM_HAS_PROJECTS:-false}"
        printf 'TEAM_REQUIRES_CLIENT_ID=%q\n' "${TEAM_REQUIRES_CLIENT_ID:-false}"
        printf 'TEAM_DEFAULT_PROJECT=%q\n' "${TEAM_DEFAULT_PROJECT:-}"
        printf 'TEAM_ORGANIZATION=%q\n' "${TEAM_ORGANIZATION:-}"

        # Emit arrays as bash array declarations so they survive the eval.
        printf 'TEAM_AGENTS=('
        printf '%q ' "${TEAM_AGENTS[@]+"${TEAM_AGENTS[@]}"}"
        printf ')\n'

        printf 'TEAM_BREW_DEPS=('
        printf '%q ' "${TEAM_BREW_DEPS[@]+"${TEAM_BREW_DEPS[@]}"}"
        printf ')\n'

        printf 'TEAM_BREW_CASK_DEPS=('
        printf '%q ' "${TEAM_BREW_CASK_DEPS[@]+"${TEAM_BREW_CASK_DEPS[@]}"}"
        printf ')\n'

        # Emit per-agent window name variables (AGENT_WINDOWS_<agent>)
        for _a in "${TEAM_AGENTS[@]+"${TEAM_AGENTS[@]}"}"; do
            local _ak="${_a//-/_}"
            local _wvar="AGENT_WINDOWS_${_ak}"
            local _wval="${!_wvar:-}"
            if [[ -n "$_wval" ]]; then
                printf 'AGENT_WINDOWS_%s=%q\n' "$_ak" "$_wval"
            fi
        done
    )
}

# Import conf values into the current shell via eval.
eval "$(_read_conf "$TEAM_CONF")"

# ============================================================================
# INSTANCE ID COMPUTATION (XACA-0460-008)
# Implements contract §3 + §5: template-id vs instance-id separation.
# TEAM_ID (the template id) is preserved for branding lookups.
# INSTANCE_ID is the stable runtime key for paths, env vars, sockets, and
# generated artifact filenames.
# ============================================================================

# validate_instance_component: ensure a param component matches ^[a-z0-9_]+$
# (no dashes — dash is the component separator in the instance id).
_validate_instance_component() {
    local component="$1" label="$2"
    if [[ ! "$component" =~ ^[a-z0-9_]+$ ]]; then
        echo "Error: $label component '${component}' must match ^[a-z0-9_]+$ (lowercase letters, digits, underscores only — no dashes)" >&2
        exit 1
    fi
}

# compute_instance_id: pure function, no filesystem side-effects.
# Inputs: template_id, client (may be empty), project (may be empty)
# Output: instance id string on stdout
compute_instance_id() {
    local template_id="$1"
    local client="$2"
    local project="$3"
    local has_projects="$TEAM_HAS_PROJECTS"
    local requires_client="$TEAM_REQUIRES_CLIENT_ID"
    local default_project="$TEAM_DEFAULT_PROJECT"

    if [[ "$has_projects" != "true" ]]; then
        # Unparameterized template: instance == template
        if [[ -n "$client" || -n "$project" ]]; then
            echo "Error: Template '${template_id}' takes no parameters (TEAM_HAS_PROJECTS=false); --client and --project are not accepted" >&2
            exit 1
        fi
        echo "$template_id"
        return 0
    fi

    # Resolve project: --project flag, then TEAM_DEFAULT_PROJECT, then error
    local resolved_project="${project:-${default_project}}"
    if [[ -z "$resolved_project" ]]; then
        echo "Error: Template '${template_id}' requires a project (TEAM_HAS_PROJECTS=true). Pass --project <value> or set TEAM_DEFAULT_PROJECT in the conf." >&2
        exit 1
    fi
    # Lowercase the component
    resolved_project="$(echo "$resolved_project" | tr '[:upper:]' '[:lower:]')"
    _validate_instance_component "$resolved_project" "project"

    # Emit notice if we fell back to the default
    if [[ -z "$project" ]]; then
        echo "Note: Using default project '${resolved_project}' for ${template_id}; specify --project to override." >&2
    fi

    if [[ "$requires_client" != "true" ]]; then
        # template-project (finance, medical, legal)
        echo "${template_id}-${resolved_project}"
        return 0
    fi

    # Resolve client: --client flag required; no default
    local resolved_client="${client}"
    if [[ -z "$resolved_client" ]]; then
        # Try interactive prompt if on a TTY
        if (exec 9<>/dev/tty) 2>/dev/null; then
            printf "Client ID for '%s' (e.g. acme): " "$template_id" >/dev/tty
            read -r resolved_client </dev/tty 2>/dev/null || resolved_client=""
        fi
    fi
    if [[ -z "$resolved_client" ]]; then
        echo "Error: Template '${template_id}' requires a client id (TEAM_REQUIRES_CLIENT_ID=true). Pass --client <value>." >&2
        exit 1
    fi
    resolved_client="$(echo "$resolved_client" | tr '[:upper:]' '[:lower:]')"
    _validate_instance_component "$resolved_client" "client"

    # template-client-project (freelance)
    echo "${template_id}-${resolved_client}-${resolved_project}"
}

# Compute and validate instance id
INSTANCE_ID="$(compute_instance_id "$TEAM_ID" "$ARG_CLIENT" "$ARG_PROJECT")"

# Reject extra flags for unparameterized templates (belt-and-suspenders;
# compute_instance_id already errors, but be explicit here too)
if [[ "$TEAM_HAS_PROJECTS" != "true" ]]; then
    if [[ -n "$ARG_PROJECT" ]]; then
        echo "Error: --project is not valid for template '${TEAM_ID}' (TEAM_HAS_PROJECTS=false)" >&2
        exit 1
    fi
    if [[ -n "$ARG_CLIENT" ]]; then
        echo "Error: --client is not valid for template '${TEAM_ID}' (TEAM_HAS_PROJECTS=false)" >&2
        exit 1
    fi
fi

# Validate final instance id shape (contract §6, invariant 5)
if [[ ! "$INSTANCE_ID" =~ ^[a-z0-9_]+(-[a-z0-9_]+){0,2}$ ]]; then
    echo "Error: Computed instance id '${INSTANCE_ID}' does not match ^[a-z0-9_]+(-[a-z0-9_]+){0,2}$" >&2
    exit 1
fi

# ============================================================================
# XACA-0463: Per-instance LCARS port allocation (team-id-contract §4.1)
# ============================================================================
# Call the pure allocator from aiteamforge-paths.sh (sourced above).
# The allocator scans team-paths.json for all used ports in the template's band
# and returns the lowest free port on stdout.  It does NOT mutate team-paths.json;
# the writer below (WRITE BACK section, after the connect-only early exit) is
# responsible for persisting the resolved port for this instance.
#
# $TEAM_LCARS_PORT is overwritten here from the conf-file-read value (template
# default) to the per-instance allocated value.  All downstream consumers
# (sed substitutions in connect/disconnect/startup templates, the lcars-ports
# directory writer, and the agent port derivation at AGENT_PORT=$((TEAM_LCARS_PORT+n)))
# pick up the correct instance port automatically because they all reference the
# same variable.
_xaca0463_team_paths="${AITEAMFORGE_CONFIG:-$HOME/.aiteamforge/team-paths.json}"
if command -v aiteamforge_compute_instance_port >/dev/null 2>&1; then
    _xaca0463_allocated=""
    if ! _xaca0463_allocated=$(aiteamforge_compute_instance_port "$TEAM_ID" "$_xaca0463_team_paths" 2>&1); then
        echo "❌ XACA-0463 port allocator failed for template '$TEAM_ID':" >&2
        echo "   $_xaca0463_allocated" >&2
        echo "   See docs/architecture/team-id-contract.md §4.1 (Port allocation rule)." >&2
        exit 1
    fi
    TEAM_LCARS_PORT="$_xaca0463_allocated"
    unset _xaca0463_allocated
    echo "  ✓ XACA-0463: allocated port $TEAM_LCARS_PORT for instance $INSTANCE_ID (template $TEAM_ID band)"
else
    echo "❌ XACA-0463: aiteamforge_compute_instance_port not in scope." >&2
    echo "   aiteamforge-paths.sh should have been sourced above; check for errors." >&2
    exit 1
fi
unset _xaca0463_team_paths

# Load branding fields from registry.json keyed on TEAM_ID (template id).
# These are used for board JSON writes and summary display.
_REGISTRY_JSON="$HOMEBREW_TAP_ROOT/share/teams/registry.json"
if [[ ! -f "$_REGISTRY_JSON" ]]; then
    echo "Error: registry.json not found at $_REGISTRY_JSON" >&2
    exit 1
fi
_REGISTRY_ENTRY="$(jq -e --arg tid "$TEAM_ID" '.teams[] | select(.id == $tid)' "$_REGISTRY_JSON" 2>/dev/null)" || {
    echo "Error: Template '${TEAM_ID}' has no entry in registry.json — cannot proceed without branding." >&2
    exit 1
}
REGISTRY_NAME_RAW="$(echo "$_REGISTRY_ENTRY" | jq -r '.name')"
REGISTRY_COLOR="$(echo "$_REGISTRY_ENTRY"    | jq -r '.color')"
REGISTRY_ICON="$(echo "$_REGISTRY_ENTRY"     | jq -r '.icon')"
# XACA-0486 review feedback (XACA-0486-011): theme comes from <team>.conf's
# TEAM_THEME (loaded above via _read_conf), NOT registry.json's .theme field.
# Several registry.json entries (academy, command, legal, medical) have
# .theme == .name (stale data), which would produce duplicate teamName/subtitle
# on the board. <team>.conf TEAM_THEME values are authoritative and distinct
# from team names. registry.json data sync is a separate concern.

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Installing Team: $TEAM_ID  (instance: $INSTANCE_ID)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ============================================================================
# ORGANIZATION CONFIG SETUP (XACA-0139)
# Ensures ~/.aiteamforge/organization.yaml exists before any team work runs.
# If the resolver can find an existing config (user, AITEAMFORGE_DIR, or env
# override), we skip the prompt — the config is already established.
# On a first install (or when the config is still the shipped example), we
# prompt for basic org identity and write the user config.
# ============================================================================

_ensure_org_config() {
    local org_config_path
    org_config_path="${HOME}/.aiteamforge/organization.yaml"

    # If the user config already exists and was written by a prior install, skip.
    if [[ -f "$org_config_path" ]]; then
        return 0
    fi

    # If an explicit env override is in effect, skip (the caller controls config).
    if [[ -n "${AITEAMFORGE_ORG_CONFIG:-}" ]]; then
        return 0
    fi

    # /dev/tty is required: redirect to /dev/tty bypasses block-buffered stdout when parent pipes through sed.
    # Use exec to actually open the device — bash -r/-w only check permission bits, which are world-rw on /dev/tty
    # even when no controlling terminal exists (true on macOS), giving false positives in CI/daemon contexts.
    if ! (exec 9<>/dev/tty) 2>/dev/null; then
        echo "" >&2
        echo "ERROR: install-team.sh needs an interactive terminal to prompt for" >&2
        echo "organization identity, but /dev/tty is not available." >&2
        echo "" >&2
        echo "Fix one of:" >&2
        echo "  1. Run interactively in a terminal" >&2
        echo "  2. Pre-populate ~/.aiteamforge/organization.yaml" >&2
        echo "  3. Set AITEAMFORGE_ORG_CONFIG=/path/to/your-org.yaml before running" >&2
        return 1
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Organization Identity Setup"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "AITeamForge needs to know which organization this install belongs to."
    echo "This information is stored in ~/.aiteamforge/organization.yaml and"
    echo "used for agent prompts, LCARS headers, and generated documentation."
    echo ""
    echo "You can accept the defaults and update the file manually later."
    echo ""

    # Prompt for org slug (lowercase-kebab, stable identifier)
    local _slug _name _short _domain
    printf "Organization slug (e.g. my-company): " > /dev/tty
    read -r _slug < /dev/tty 2>/dev/null || _slug=""
    _slug="${_slug:-example-org}"
    # Sanitize: lowercase, replace spaces/underscores with hyphens, strip other chars
    _slug="$(echo "$_slug" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | tr -cd 'a-z0-9-')"
    [[ -z "$_slug" ]] && _slug="example-org"

    # Sanitize: strip characters that would break sed substitution (`|`, `\`) or
    # YAML double-quoted scalars (`"`, `\`, control chars). Keeps spaces, punctuation,
    # uppercase letters, and unicode — only stripping delimiters that corrupt downstream.
    _sanitize_free_text() {
        # shellcheck disable=SC1003  # tr -d arg, not a shell quote-escape: '|"\\' = strip pipe, dquote, backslash
        printf '%s' "$1" | tr -d '|"\\' | tr -d '\000-\037'
    }

    printf "Organization name (e.g. My Company): " > /dev/tty
    read -r _name < /dev/tty 2>/dev/null || _name=""
    _name="$(_sanitize_free_text "$_name")"
    [[ -z "$_name" ]] && _name="Example Organization"

    printf "Display short (<=12 chars, e.g. MyCo) [%s]: " "${_name:0:12}" > /dev/tty
    read -r _short < /dev/tty 2>/dev/null || _short=""
    _short="$(_sanitize_free_text "$_short")"
    [[ -z "$_short" ]] && _short="${_name:0:12}"

    printf "Primary domain (e.g. mycompany.com): " > /dev/tty
    read -r _domain < /dev/tty 2>/dev/null || _domain=""
    _domain="$(_sanitize_free_text "$_domain")"
    [[ -z "$_domain" ]] && _domain="example.com"

    echo ""
    echo "Writing organization config..."
    mkdir -p "${HOME}/.aiteamforge"

    # Write from the shipped example as a template, substituting user answers.
    # Fall back to an inline here-doc if the example file is missing.
    local _example_src="$HOMEBREW_TAP_ROOT/share/config/organization.yaml.example"
    if [[ -f "$_example_src" ]]; then
        sed \
            -e "s|slug: \"example-org\"|slug: \"${_slug}\"|" \
            -e "s|name: \"Example Organization\"|name: \"${_name}\"|" \
            -e "s|display_short: \"Example\"|display_short: \"${_short}\"|" \
            -e "s|domain: \"example.com\"|domain: \"${_domain}\"|" \
            "$_example_src" > "$org_config_path"
    else
        # Inline fallback (example file missing — unusual but safe)
        cat > "$org_config_path" <<ORGEOF
# AITeamForge Organization Identity Configuration
# Generated by install-team.sh on $(date)
# Edit this file to update your organization identity.
organization:
  slug: "${_slug}"
  name: "${_name}"
  display_short: "${_short}"
  domain: "${_domain}"
paths:
  projects_root: "\${HOME}/projects"
  shared_dev_root: ""
plugins:
  enabled: []
integrations: {}
ORGEOF
    fi

    echo "  Written: $org_config_path"
    echo "  Slug: ${_slug}  |  Name: ${_name}  |  Domain: ${_domain}"
    echo ""
    echo "To edit later: open ~/.aiteamforge/organization.yaml"
    echo ""
}

_ensure_org_config

# Pre-build template substitution variables now so the --connect-only path
# can use them before the heavy install sections run.
TEAM_TERMINAL_LIST="${TEAM_AGENTS[*]+"${TEAM_AGENTS[*]}"}"
TEAM_AGENT_WINDOWS_CONFIG=""
for _agent in "${TEAM_AGENTS[@]}"; do
    _agent_key="${_agent//-/_}"
    _var="AGENT_WINDOWS_${_agent_key}"
    _val="${!_var:-}"
    if [[ -n "$_val" ]]; then
        TEAM_AGENT_WINDOWS_CONFIG+="AGENT_WINDOWS_${_agent_key}=\"${_val}\""$'\n'
    fi
done

# ============================================================================
# CONNECT-ONLY EARLY EXIT
# Renders only the connect + disconnect scripts and exits.  Used by the
# setup wizard to generate connect scripts for ALL teams regardless of which
# teams were selected for full installation.
# ============================================================================

if [[ "$CONNECT_ONLY" == "true" ]]; then
    echo "🔗 Rendering connect scripts for $INSTANCE_ID (connect-only mode)..."
    mkdir -p "$AITEAMFORGE_DIR"

    CONNECT_TEMPLATE="$HOMEBREW_TAP_ROOT/share/templates/team-connect.sh.template"
    CONNECT_SCRIPT="$AITEAMFORGE_DIR/${INSTANCE_ID}-connect.sh"

    if [[ -f "$CONNECT_TEMPLATE" ]]; then
        sed -e "s|{{TEAM_ID}}|$INSTANCE_ID|g" \
            -e "s|{{TEAM_NAME}}|$TEAM_NAME|g" \
            -e "s|{{TEAM_THEME}}|$TEAM_THEME|g" \
            -e "s|{{TEAM_LCARS_PORT}}|$TEAM_LCARS_PORT|g" \
            -e "s|{{TEAM_TMUX_SOCKET}}|$INSTANCE_ID|g" \
            -e "s|{{TEAM_TERMINAL_LIST}}|$TEAM_TERMINAL_LIST|g" \
            -e "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g" \
            "$CONNECT_TEMPLATE" > "${CONNECT_SCRIPT}.tmp"

        python3 - "${CONNECT_SCRIPT}.tmp" "$CONNECT_SCRIPT" <<PYEOF
import sys
src, dst = sys.argv[1], sys.argv[2]
windows_config = """${TEAM_AGENT_WINDOWS_CONFIG}""".rstrip('\n')
if windows_config:
    windows_config += '\n'
with open(src) as f:
    content = f.read()
content = content.replace('{{TEAM_AGENT_WINDOWS_CONFIG}}\n', windows_config)
if '{{TEAM_AGENT_WINDOWS_CONFIG}}' in content:
    content = content.replace('{{TEAM_AGENT_WINDOWS_CONFIG}}', windows_config.rstrip('\n'))
with open(dst, 'w') as f:
    f.write(content)
PYEOF
        rm -f "${CONNECT_SCRIPT}.tmp"
        chmod +x "$CONNECT_SCRIPT"
        echo "  ✓ ${INSTANCE_ID}-connect.sh"
    else
        echo "  ⚠️  Template not found: team-connect.sh.template (skipping)"
    fi

    DISCONNECT_TEMPLATE="$HOMEBREW_TAP_ROOT/share/templates/team-disconnect.sh.template"
    DISCONNECT_SCRIPT="$AITEAMFORGE_DIR/${INSTANCE_ID}-disconnect.sh"

    if [[ -f "$DISCONNECT_TEMPLATE" ]]; then
        sed -e "s|{{TEAM_ID}}|$INSTANCE_ID|g" \
            -e "s|{{TEAM_NAME}}|$TEAM_NAME|g" \
            -e "s|{{TEAM_LCARS_PORT}}|$TEAM_LCARS_PORT|g" \
            -e "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g" \
            "$DISCONNECT_TEMPLATE" > "$DISCONNECT_SCRIPT"
        chmod +x "$DISCONNECT_SCRIPT"
        echo "  ✓ ${INSTANCE_ID}-disconnect.sh"
    else
        echo "  ⚠️  Template not found: team-disconnect.sh.template (skipping)"
    fi

    exit 0
fi

# Save the base working dir from conf (before env override or XACA-0485 augmentation).
# For project-based teams, this is the parent dir (e.g., ~/medical) — used for
# template-substitution defaults and other branding-time lookups.
TEAM_BASE_WORKING_DIR="${TEAM_WORKING_DIR}"
TEAM_BASE_WORKING_DIR="${TEAM_BASE_WORKING_DIR/\$HOME/$HOME}"

# XACA-0485: Self-sufficient TEAM_WORKING_DIR computation for parametric teams.
# The team conf sets TEAM_WORKING_DIR=$HOME/<team> (template-base, no project).
# _read_conf re-sources the conf in a subshell which overrides any pre-set env
# var, so the wizard cannot reliably pass a project-augmented value via env.
# To keep install-time paths in lockstep with .aiteamforge-config.team_paths
# (and with the LCARS server's kanban_dir resolution), install-team.sh appends
# the resolved project (and client, for template-client-project teams) here.
#
# Layouts after this block:
#   - unparameterized:        TEAM_WORKING_DIR = $TEAM_BASE_WORKING_DIR
#   - template-project:       TEAM_WORKING_DIR = $TEAM_BASE_WORKING_DIR/<project>
#   - template-client-project:TEAM_WORKING_DIR = $TEAM_BASE_WORKING_DIR/<client>/<project>
if [[ "$TEAM_HAS_PROJECTS" == "true" ]]; then
    _XACA0485_RESOLVED_PROJECT="${ARG_PROJECT:-$TEAM_DEFAULT_PROJECT}"
    _XACA0485_RESOLVED_PROJECT="$(echo "$_XACA0485_RESOLVED_PROJECT" | tr '[:upper:]' '[:lower:]')"
    if [[ "$TEAM_REQUIRES_CLIENT_ID" == "true" ]]; then
        _XACA0485_RESOLVED_CLIENT="$(echo "${ARG_CLIENT:-}" | tr '[:upper:]' '[:lower:]')"
        TEAM_WORKING_DIR="${TEAM_BASE_WORKING_DIR}/${_XACA0485_RESOLVED_CLIENT}/${_XACA0485_RESOLVED_PROJECT}"
    else
        TEAM_WORKING_DIR="${TEAM_BASE_WORKING_DIR}/${_XACA0485_RESOLVED_PROJECT}"
    fi
else
    # Unparameterized teams: just normalize the conf value with $HOME expansion.
    TEAM_WORKING_DIR="$TEAM_BASE_WORKING_DIR"
fi

# ============================================================================
# TEAM_WORKING_DIR DEV-SOURCE PROTECTION GUARD (XACA-0498)
# ============================================================================
# Parity guard for XACA-0497 (AITEAMFORGE_DIR guard, lines 82-99).  XACA-0497
# blocks installs when AITEAMFORGE_DIR itself is a dev-source tree, but does
# NOT catch the parallel case where TEAM_WORKING_DIR resolves to a direct
# $HOME child (e.g. ~/academy, ~/android) on a dev-source machine — a second
# installer writer (persona refresher / board writer) proved this gap exists
# during the 2026-05-12 ~/academy re-creation event.
#
# Detection: sentinel at $HOME/dev-team/.aiteamforge-source-tree.
# Cross-reference: docs/kanban/XACA-0497-academy-stub-forensics.md
#                  "Recommendations for follow-up" #2.
#
# Short-circuit on non-dev machines (no sentinel) — on-by-default path for
# tap-installed end-user machines.
if [[ -f "$HOME/dev-team/.aiteamforge-source-tree" ]]; then
    # Re-expand $HOME in TEAM_WORKING_DIR.  The augmentation block above may
    # have rebuilt TEAM_WORKING_DIR from TEAM_BASE_WORKING_DIR (which already
    # has $HOME expanded), but a defensive re-substitution is free and keeps
    # this block self-contained.
    _TWD_EXPANDED="${TEAM_WORKING_DIR/\$HOME/$HOME}"

    # Resolve to canonical path without requiring TEAM_WORKING_DIR to exist yet
    # (the installer creates it later).  cd into the parent (which does exist —
    # it is $HOME or a child of it) and concatenate the basename.
    _TWD_PARENT="$(cd "$(dirname "$_TWD_EXPANDED")" 2>/dev/null && pwd -P || echo "")"
    _TWD_REAL="$_TWD_PARENT/$(basename "$_TWD_EXPANDED")"

    # Re-resolve AITEAMFORGE_DIR canonical path (_AITF_REAL was unset at line 99).
    _AITF_REAL="$(cd "$AITEAMFORGE_DIR" 2>/dev/null && pwd -P || echo "")"

    # Deny when ALL three clauses are true:
    #   1. TEAM_WORKING_DIR is a direct child of $HOME (depth-1, e.g. ~/academy)
    #      — project-augmented teams (finance/legal/medical/freelance) resolve to
    #      depth-2+ and are allowed through.
    #   2. TEAM_WORKING_DIR is NOT inside AITEAMFORGE_DIR (i.e. AITEAMFORGE_DIR
    #      is not an ancestor of TEAM_WORKING_DIR) — user-supplied containment
    #      (TWD a child of AITF install root) is allowed through this clause.
    #   3. AITEAMFORGE_DIR is NOT inside TEAM_WORKING_DIR (i.e. TEAM_WORKING_DIR
    #      is not an ancestor of AITEAMFORGE_DIR) — Command monorepo
    #      ($HOME/dev-team containing $HOME/dev-team/aiteamforge) is allowed
    #      through this clause.
    # Trailing slashes on both sides assert directory containment rather than
    # raw string prefix, so AITF=$HOME/academy vs TWD=$HOME/academy-extra
    # cannot collide into a false ALLOW.
    if [[ -n "$_TWD_PARENT" && "$_TWD_PARENT" == "$HOME" ]] \
        && [[ -z "$_AITF_REAL" || "$_TWD_REAL/" != "$_AITF_REAL/"* ]] \
        && [[ -z "$_AITF_REAL" || "$_AITF_REAL/" != "$_TWD_REAL/"* ]]; then
        echo "Error: TEAM_WORKING_DIR resolves to a direct \$HOME child on a dev-source machine:" >&2
        echo "       $_TWD_REAL" >&2
        echo "       Installing here would write stub files into the dev source tree." >&2
        echo "       Pass --install-dir to a path outside \$HOME, or unset AITEAMFORGE_DIR" >&2
        echo "       and ensure the team conf uses a depth-2+ TEAM_WORKING_DIR." >&2
        exit 1
    fi

    unset _TWD_EXPANDED _TWD_PARENT _TWD_REAL _AITF_REAL
fi

echo "Team Name: $TEAM_NAME"
echo "Category: $TEAM_CATEGORY"
echo "Description: $TEAM_DESCRIPTION"
echo "Theme: $TEAM_THEME"
echo ""

# ============================================================================
# INSTALL HOMEBREW DEPENDENCIES
# ============================================================================

if [[ ${#TEAM_BREW_DEPS[@]} -gt 0 ]]; then
    echo "📦 Installing Homebrew dependencies..."
    for dep in "${TEAM_BREW_DEPS[@]}"; do
        [[ -z "$dep" ]] && continue
        if brew list "$dep" &>/dev/null; then
            echo "  ✓ $dep (already installed)"
        else
            echo "  → Installing $dep..."
            brew install "$dep" || {
                echo "  ⚠️  Warning: Failed to install $dep (continuing anyway)"
            }
        fi
    done
    echo ""
fi

if [[ ${#TEAM_BREW_CASK_DEPS[@]} -gt 0 ]]; then
    echo "📦 Installing Homebrew cask dependencies..."
    for dep in "${TEAM_BREW_CASK_DEPS[@]}"; do
        [[ -z "$dep" ]] && continue
        if brew list --cask "$dep" &>/dev/null; then
            echo "  ✓ $dep (already installed)"
        else
            echo "  → Installing $dep..."
            brew install --cask "$dep" || {
                echo "  ⚠️  Warning: Failed to install $dep (continuing anyway)"
            }
        fi
    done
    echo ""
fi

# ============================================================================
# CREATE TEAM DIRECTORY STRUCTURE
# ============================================================================

echo "📁 Creating team directory structure..."

TEAM_DIR="$AITEAMFORGE_DIR/$TEAM_ID"
mkdir -p "$TEAM_DIR"
mkdir -p "$TEAM_DIR/personas"
mkdir -p "$TEAM_DIR/personas/agents"
mkdir -p "$TEAM_DIR/personas/avatars"
mkdir -p "$TEAM_DIR/personas/docs"
mkdir -p "$TEAM_DIR/scripts"
mkdir -p "$TEAM_DIR/scripts/prompts"
mkdir -p "$TEAM_DIR/terminals"

echo "  ✓ $TEAM_DIR"
echo ""

# ============================================================================
# COPY TEAM PERSONA TEMPLATES (IF AVAILABLE)
# ============================================================================

# Check if persona templates exist in the homebrew-tap
PERSONAS_TEMPLATE_DIR="$HOMEBREW_TAP_ROOT/share/personas/$TEAM_ID"
if [[ -d "$PERSONAS_TEMPLATE_DIR" ]]; then
    echo "👤 Installing team personas..."
    cp -R "$PERSONAS_TEMPLATE_DIR"/* "$TEAM_DIR/personas/" || true
    echo "  ✓ Personas copied to $TEAM_DIR/personas/"
    # Also copy to the team working directory if it differs from TEAM_DIR,
    # but skip when TEAM_DIR is inside TEAM_WORKING_DIR (e.g. Command team
    # where TEAM_WORKING_DIR is the monorepo root that contains TEAM_DIR),
    # and skip when the destination would pollute an existing git work tree.
    if [[ -n "${TEAM_WORKING_DIR:-}" ]]; then
        _WORKING_DIR_RESOLVED="${TEAM_WORKING_DIR/\$HOME/$HOME}"
        _SHOULD_COPY=1
        # Skip: identical path
        if [[ "$_WORKING_DIR_RESOLVED" == "$TEAM_DIR" ]]; then
            _SHOULD_COPY=0
        fi
        # Skip: TEAM_DIR is inside TEAM_WORKING_DIR (Command case — parent dir)
        if [[ "$TEAM_DIR" == "$_WORKING_DIR_RESOLVED"/* ]]; then
            _SHOULD_COPY=0
        fi
        # Skip: destination parent is a git work tree we'd pollute
        if [[ $_SHOULD_COPY -eq 1 ]] && git -C "$_WORKING_DIR_RESOLVED" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            _SHOULD_COPY=0
            echo "  ⏭  Skipping working-dir persona copy (would pollute git repo at $_WORKING_DIR_RESOLVED)"
        fi
        if [[ $_SHOULD_COPY -eq 1 ]]; then
            mkdir -p "$_WORKING_DIR_RESOLVED/personas"
            cp -R "$PERSONAS_TEMPLATE_DIR"/* "$_WORKING_DIR_RESOLVED/personas/" || true
            echo "  ✓ Personas copied to $_WORKING_DIR_RESOLVED/personas/"
        fi
        unset _WORKING_DIR_RESOLVED _SHOULD_COPY
    fi
    # Also copy avatar images into the flat avatars/ pool so agent-panel-display.sh
    # can find them without fleet-monitor installed.
    FLAT_AVATARS_DIR="$AITEAMFORGE_DIR/avatars"
    mkdir -p "$FLAT_AVATARS_DIR"
    if [[ -d "$PERSONAS_TEMPLATE_DIR/avatars" ]]; then
        cp "$PERSONAS_TEMPLATE_DIR/avatars/"*.png "$FLAT_AVATARS_DIR/" 2>/dev/null || true
        echo "  ✓ Avatars added to shared pool ($FLAT_AVATARS_DIR)"
    fi

    # Copy .txt system prompt files into scripts/prompts/ so cc-aliases can find them.
    # cc-aliases reads <AITEAMFORGE_DIR>/<team>/scripts/prompts/<team>-<terminal>-prompt.txt
    # to load the Claude system prompt when launching agents.
    if [[ -d "$PERSONAS_TEMPLATE_DIR/prompts" ]]; then
        mkdir -p "$TEAM_DIR/scripts/prompts"
        cp "$PERSONAS_TEMPLATE_DIR/prompts/"*.txt "$TEAM_DIR/scripts/prompts/" 2>/dev/null || true
        PROMPT_COUNT=$(find "$TEAM_DIR/scripts/prompts" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')
        echo "  ✓ Installed $PROMPT_COUNT system prompt file(s) to scripts/prompts/"
    fi
    echo ""
fi

# ============================================================================
# CREATE STARTUP/SHUTDOWN SCRIPTS FROM TEMPLATES
# ============================================================================

echo "🚀 Creating startup/shutdown scripts..."

# XACA-0483: For parametric (TEAM_HAS_PROJECTS=true) teams that have dev-team
# source scripts shipped under share/scripts/teams/, install the parametric
# script verbatim instead of generating a per-instance template substitution.
# This restores ONE template-keyed script (e.g. finance-startup.sh) that takes
# project args, matching the dev-team source-of-truth design. Reverses the
# instance-keyed naming established in 0.11.5 / Contract §6 invariant 8.
#
# Non-parametric teams retain instance-keyed naming. Parameterized teams that
# don't (yet) have a shipped parametric script also retain instance-keyed
# naming via the legacy template path.
if [[ "$TEAM_HAS_PROJECTS" == "true" ]] && [[ -f "$HOMEBREW_TAP_ROOT/share/scripts/teams/${TEAM_ID}-startup.sh" ]]; then
    _PARAMETRIC_MODE="true"
    TEAM_STARTUP_SCRIPT="${TEAM_ID}-startup.sh"
    TEAM_SHUTDOWN_SCRIPT="${TEAM_ID}-shutdown.sh"
else
    _PARAMETRIC_MODE="false"
    # Override script filenames from conf to use INSTANCE_ID instead of template id.
    # The conf may provide e.g. "finance-startup.sh" (template-keyed). We replace
    # that with the instance-keyed name so multiple instances of the same template
    # get distinct files. Contract §6, invariant 8.
    TEAM_STARTUP_SCRIPT="${INSTANCE_ID}-startup.sh"
    TEAM_SHUTDOWN_SCRIPT="${INSTANCE_ID}-shutdown.sh"
fi

STARTUP_SCRIPT="$AITEAMFORGE_DIR/$TEAM_STARTUP_SCRIPT"
SHUTDOWN_SCRIPT="$AITEAMFORGE_DIR/$TEAM_SHUTDOWN_SCRIPT"

# XACA-0483 migration: when this template was previously installed in instance-keyed
# mode (0.11.5 layout), the user has files like finance-personal-startup.sh,
# finance-personal-shutdown.sh, etc. on disk. Move them aside with .stale-pre-XACA-0483
# suffix so the new template-keyed scripts can take their place without ambiguity.
# Non-destructive — user can audit or restore manually.
if [[ "$_PARAMETRIC_MODE" == "true" ]]; then
    _XACA0483_STALE_SUFFIX=".stale-pre-XACA-0483"
    for _stale_glob in "$AITEAMFORGE_DIR/${TEAM_ID}-"*-startup.sh \
                       "$AITEAMFORGE_DIR/${TEAM_ID}-"*-shutdown.sh \
                       "$AITEAMFORGE_DIR/${TEAM_ID}-"*-connect.sh \
                       "$AITEAMFORGE_DIR/${TEAM_ID}-"*-disconnect.sh; do
        [[ -f "$_stale_glob" ]] || continue
        # Skip the template-keyed names themselves
        case "$(basename "$_stale_glob")" in
            "${TEAM_ID}-startup.sh"|"${TEAM_ID}-shutdown.sh"|"${TEAM_ID}-connect.sh"|"${TEAM_ID}-disconnect.sh") continue ;;
        esac
        # Skip files already wearing the stale suffix
        [[ "$_stale_glob" == *"$_XACA0483_STALE_SUFFIX" ]] && continue
        mv "$_stale_glob" "${_stale_glob}${_XACA0483_STALE_SUFFIX}"
        echo "  📦 Migrated legacy instance-keyed script: $(basename "$_stale_glob") → $(basename "$_stale_glob")${_XACA0483_STALE_SUFFIX}"
    done
fi

# Determine if this is a project-based team (values already imported from conf)
IS_PROJECT_TEAM="$TEAM_HAS_PROJECTS"
REQUIRES_CLIENT="$TEAM_REQUIRES_CLIENT_ID"

# Check for team-specific template first, then generic/project template
STARTUP_TEMPLATE="$HOMEBREW_TAP_ROOT/share/templates/$TEAM_STARTUP_SCRIPT.template"
if [[ ! -f "$STARTUP_TEMPLATE" ]]; then
    if [[ "$IS_PROJECT_TEAM" == "true" ]]; then
        STARTUP_TEMPLATE="$HOMEBREW_TAP_ROOT/share/templates/team-project-startup.sh.template"
    else
        STARTUP_TEMPLATE="$HOMEBREW_TAP_ROOT/share/templates/team-startup.sh.template"
    fi
fi

SHUTDOWN_TEMPLATE="$HOMEBREW_TAP_ROOT/share/templates/$TEAM_SHUTDOWN_SCRIPT.template"
if [[ ! -f "$SHUTDOWN_TEMPLATE" ]]; then
    SHUTDOWN_TEMPLATE="$HOMEBREW_TAP_ROOT/share/templates/team-shutdown.sh.template"
fi

# XACA-0483: parametric mode — copy dev-team source scripts verbatim with
# path substitution from ~/dev-team/* to $AITEAMFORGE_DIR/*. Skips template
# substitution entirely. The dev-team scripts already implement the parametric
# pattern correctly (accept project/client args at runtime, compute instance id
# from them, set LCARS_TEAM accordingly via scripts/lcars-launch-helpers.sh).
if [[ "$_PARAMETRIC_MODE" == "true" ]]; then
    # Path-substitution helper: rewrite ~/dev-team and $HOME/dev-team references
    # to $AITEAMFORGE_DIR. One special case: dev-team has iterm2_window_manager.py
    # at the top level, but the tap installs it under scripts/. Handle that first.
    _xaca0483_install_script() {
        local src="$1" dst="$2"
        # The dev-team source uses ~/dev-team/iterm2_window_manager.py (top-level),
        # but the tap installs iterm2_window_manager.py under scripts/. Rewrite
        # that specific case first, then the general ~/dev-team → $AITEAMFORGE_DIR
        # path mapping. Covers all three reference forms: ~, $HOME, ${HOME}.
        sed -e "s|\$HOME/dev-team/iterm2_window_manager.py|$AITEAMFORGE_DIR/scripts/iterm2_window_manager.py|g" \
            -e "s|\${HOME}/dev-team/iterm2_window_manager.py|$AITEAMFORGE_DIR/scripts/iterm2_window_manager.py|g" \
            -e "s|~/dev-team/iterm2_window_manager.py|$AITEAMFORGE_DIR/scripts/iterm2_window_manager.py|g" \
            -e "s|\$HOME/dev-team|$AITEAMFORGE_DIR|g" \
            -e "s|\${HOME}/dev-team|$AITEAMFORGE_DIR|g" \
            -e "s|~/dev-team|$AITEAMFORGE_DIR|g" \
            "$src" > "$dst"
        chmod +x "$dst"
    }
    _xaca0483_install_script "$HOMEBREW_TAP_ROOT/share/scripts/teams/${TEAM_ID}-startup.sh" "$STARTUP_SCRIPT"
    echo "  ✓ $TEAM_STARTUP_SCRIPT (parametric, XACA-0483)"
    _xaca0483_install_script "$HOMEBREW_TAP_ROOT/share/scripts/teams/${TEAM_ID}-shutdown.sh" "$SHUTDOWN_SCRIPT"
    echo "  ✓ $TEAM_SHUTDOWN_SCRIPT (parametric, XACA-0483)"

    # Ensure lcars-launch-helpers.sh is installed (parametric scripts source it).
    # Always re-install: substitution is cheap and the installed file diverges
    # from the source by design (path rewrites), so a content-equality guard
    # would always trip false. Re-running is the cheaper-and-clearer behavior.
    mkdir -p "$AITEAMFORGE_DIR/scripts"
    _xaca0483_install_script "$HOMEBREW_TAP_ROOT/share/scripts/lcars-launch-helpers.sh" \
        "$AITEAMFORGE_DIR/scripts/lcars-launch-helpers.sh"
    echo "  ✓ scripts/lcars-launch-helpers.sh"

    # XACA-0484: install per-agent startup scripts (and team banner) referenced
    # by the master parametric script. Without these, tmux sessions never form
    # because the master script's [ -f "$script" ] guard silently skips missing files.
    if [[ -d "$HOMEBREW_TAP_ROOT/share/scripts/teams/${TEAM_ID}/scripts" ]]; then
        mkdir -p "$AITEAMFORGE_DIR/${TEAM_ID}/scripts"
        _xaca0484_count=0
        for _src in "$HOMEBREW_TAP_ROOT/share/scripts/teams/${TEAM_ID}/scripts/"*.sh; do
            [[ -f "$_src" ]] || continue
            _xaca0483_install_script "$_src" "$AITEAMFORGE_DIR/${TEAM_ID}/scripts/$(basename "$_src")"
            _xaca0484_count=$((_xaca0484_count + 1))
        done
        echo "  ✓ ${TEAM_ID}/scripts/ ($_xaca0484_count files — XACA-0484)"
    fi
elif [[ -f "$STARTUP_TEMPLATE" ]]; then
    # Step 1: single-line substitutions via sed
    # {{TEAM_ID}} receives INSTANCE_ID (not template id) so that the generated
    # script's TEAM_ID variable holds the instance id — keeping backwards compat
    # with callers that read TEAM_ID while correcting the cascade (contract §6.8).
    # {{TEAM_TMUX_SOCKET}} also uses INSTANCE_ID for per-instance socket isolation.
    # XACA-0463: per-instance LCARS port now allocated above via aiteamforge_compute_instance_port.
    # XACA-0485: for project teams, use the project-augmented TEAM_WORKING_DIR
    # (computed above with the resolved-project/client component). Previously
    # this used TEAM_BASE_WORKING_DIR which stripped the project component and
    # made the legacy template path inherit the same bug as KANBAN_DIR.
    _TEAM_WORKING_DIR_RESOLVED="$(if [[ "$IS_PROJECT_TEAM" == "true" ]]; then echo "$TEAM_WORKING_DIR"; else echo "${TEAM_WORKING_DIR:-$AITEAMFORGE_DIR/$TEAM_ID}"; fi)"
    sed -e "s|{{TEAM_ID}}|$INSTANCE_ID|g" \
        -e "s|{{TEAM_NAME}}|$TEAM_NAME|g" \
        -e "s|{{TEAM_THEME}}|$TEAM_THEME|g" \
        -e "s|{{TEAM_SHIP}}|$TEAM_SHIP|g" \
        -e "s|{{TEAM_LCARS_PORT}}|$TEAM_LCARS_PORT|g" \
        -e "s|{{TEAM_TMUX_SOCKET}}|$INSTANCE_ID|g" \
        -e "s|{{TEAM_TERMINAL_LIST}}|$TEAM_TERMINAL_LIST|g" \
        -e "s|{{TEAM_WORKING_DIR}}|${_TEAM_WORKING_DIR_RESOLVED}|g" \
        -e "s|{{TEAM_REQUIRES_CLIENT}}|${REQUIRES_CLIENT}|g" \
        -e "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g" \
        "$STARTUP_TEMPLATE" > "${STARTUP_SCRIPT}.tmp"

    # Step 2: multi-line substitution for per-agent window names via Python
    # {{TEAM_AGENT_WINDOWS_CONFIG}} may contain newlines which sed cannot handle
    python3 - "${STARTUP_SCRIPT}.tmp" "$STARTUP_SCRIPT" <<PYEOF
import sys
src, dst = sys.argv[1], sys.argv[2]
# Strip trailing newline then re-add one so the placeholder line is cleanly replaced
windows_config = """${TEAM_AGENT_WINDOWS_CONFIG}""".rstrip('\n')
if windows_config:
    windows_config += '\n'
with open(src) as f:
    content = f.read()
content = content.replace('{{TEAM_AGENT_WINDOWS_CONFIG}}\n', windows_config)
# Fallback: replace without trailing newline in case template line ending differs
if '{{TEAM_AGENT_WINDOWS_CONFIG}}' in content:
    content = content.replace('{{TEAM_AGENT_WINDOWS_CONFIG}}', windows_config.rstrip('\n'))
with open(dst, 'w') as f:
    f.write(content)
PYEOF
    rm -f "${STARTUP_SCRIPT}.tmp"
    chmod +x "$STARTUP_SCRIPT"
    echo "  ✓ $TEAM_STARTUP_SCRIPT"
else
    echo "  ⚠️  Template not found: $TEAM_STARTUP_SCRIPT.template (will create basic version)"
    cat > "$STARTUP_SCRIPT" <<EOF
#!/bin/zsh
# $TEAM_NAME Startup Script
# Auto-generated by aiteamforge installer

echo "🚀 $TEAM_NAME"
echo "   $TEAM_THEME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Team: $TEAM_ID"
echo "LCARS Port: $TEAM_LCARS_PORT"
echo ""
EOF
    chmod +x "$STARTUP_SCRIPT"
    echo "  ✓ $TEAM_STARTUP_SCRIPT (basic version)"
fi

CONNECT_TEMPLATE="$HOMEBREW_TAP_ROOT/share/templates/team-connect.sh.template"
CONNECT_SCRIPT="$AITEAMFORGE_DIR/${INSTANCE_ID}-connect.sh"

# XACA-0483: parametric teams (finance/medical/legal/freelance) don't ship a
# connect/disconnect script in the dev-team source. Skip generation in
# parametric mode to keep the install surface consistent with source-of-truth.
if [[ "$_PARAMETRIC_MODE" == "true" ]]; then
    :  # No connect script for parametric teams
elif [[ -f "$CONNECT_TEMPLATE" ]]; then
    # Step 1: single-line substitutions via sed
    # {{TEAM_ID}} → INSTANCE_ID; {{TEAM_TMUX_SOCKET}} → INSTANCE_ID (per-instance socket)
    sed -e "s|{{TEAM_ID}}|$INSTANCE_ID|g" \
        -e "s|{{TEAM_NAME}}|$TEAM_NAME|g" \
        -e "s|{{TEAM_THEME}}|$TEAM_THEME|g" \
        -e "s|{{TEAM_LCARS_PORT}}|$TEAM_LCARS_PORT|g" \
        -e "s|{{TEAM_TMUX_SOCKET}}|$INSTANCE_ID|g" \
        -e "s|{{TEAM_TERMINAL_LIST}}|$TEAM_TERMINAL_LIST|g" \
        -e "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g" \
        "$CONNECT_TEMPLATE" > "${CONNECT_SCRIPT}.tmp"

    # Step 2: multi-line substitution for per-agent window names via Python
    # {{TEAM_AGENT_WINDOWS_CONFIG}} may contain newlines which sed cannot handle
    python3 - "${CONNECT_SCRIPT}.tmp" "$CONNECT_SCRIPT" <<PYEOF
import sys
src, dst = sys.argv[1], sys.argv[2]
# Strip trailing newline then re-add one so the placeholder line is cleanly replaced
windows_config = """${TEAM_AGENT_WINDOWS_CONFIG}""".rstrip('\n')
if windows_config:
    windows_config += '\n'
with open(src) as f:
    content = f.read()
content = content.replace('{{TEAM_AGENT_WINDOWS_CONFIG}}\n', windows_config)
# Fallback: replace without trailing newline in case template line ending differs
if '{{TEAM_AGENT_WINDOWS_CONFIG}}' in content:
    content = content.replace('{{TEAM_AGENT_WINDOWS_CONFIG}}', windows_config.rstrip('\n'))
with open(dst, 'w') as f:
    f.write(content)
PYEOF
    rm -f "${CONNECT_SCRIPT}.tmp"
    chmod +x "$CONNECT_SCRIPT"
    echo "  ✓ ${INSTANCE_ID}-connect.sh"
else
    echo "  ⚠️  Template not found: team-connect.sh.template (skipping connect script)"
fi

# Disconnect script — symmetric counterpart to connect. Purely local
# cleanup: closes the iTerm2 connect window and resets the LCARS Web
# profile URL back to localhost. Simple single-pass sed substitution —
# no per-agent windows config needed.
DISCONNECT_TEMPLATE="$HOMEBREW_TAP_ROOT/share/templates/team-disconnect.sh.template"
DISCONNECT_SCRIPT="$AITEAMFORGE_DIR/${INSTANCE_ID}-disconnect.sh"

# XACA-0483: parametric teams skip disconnect generation — see connect comment above.
if [[ "$_PARAMETRIC_MODE" == "true" ]]; then
    :  # No disconnect script for parametric teams
elif [[ -f "$DISCONNECT_TEMPLATE" ]]; then
    sed -e "s|{{TEAM_ID}}|$INSTANCE_ID|g" \
        -e "s|{{TEAM_NAME}}|$TEAM_NAME|g" \
        -e "s|{{TEAM_LCARS_PORT}}|$TEAM_LCARS_PORT|g" \
        -e "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g" \
        "$DISCONNECT_TEMPLATE" > "$DISCONNECT_SCRIPT"
    chmod +x "$DISCONNECT_SCRIPT"
    echo "  ✓ ${INSTANCE_ID}-disconnect.sh"
else
    echo "  ⚠️  Template not found: team-disconnect.sh.template (skipping disconnect script)"
fi

# XACA-0483: parametric shutdown was already installed verbatim in the parametric
# block above. Skip the template-substitution path here.
if [[ "$_PARAMETRIC_MODE" == "true" ]]; then
    :  # Shutdown already installed parametrically above
elif [[ -f "$SHUTDOWN_TEMPLATE" ]]; then
    sed -e "s|{{TEAM_ID}}|$INSTANCE_ID|g" \
        -e "s|{{TEAM_NAME}}|$TEAM_NAME|g" \
        -e "s|{{TEAM_TMUX_SOCKET}}|$INSTANCE_ID|g" \
        -e "s|{{TEAM_LCARS_PORT}}|$TEAM_LCARS_PORT|g" \
        -e "s|{{TEAM_WORKING_DIR}}|${TEAM_WORKING_DIR:-$AITEAMFORGE_DIR/$TEAM_ID}|g" \
        -e "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g" \
        "$SHUTDOWN_TEMPLATE" > "$SHUTDOWN_SCRIPT"
    chmod +x "$SHUTDOWN_SCRIPT"
    echo "  ✓ $TEAM_SHUTDOWN_SCRIPT"
else
    cat > "$SHUTDOWN_SCRIPT" <<EOF
#!/bin/zsh
# $TEAM_NAME Shutdown Script
echo "Shutting down $TEAM_NAME..."
tmux -L $INSTANCE_ID kill-server 2>/dev/null || true
echo "✓ $TEAM_NAME shut down"
EOF
    chmod +x "$SHUTDOWN_SCRIPT"
    echo "  ✓ $TEAM_SHUTDOWN_SCRIPT (basic version)"
fi

echo ""

# ============================================================================
# GENERATE TEAM BANNER SCRIPT
# ============================================================================

echo "🎨 Generating team banner script..."

BANNER_TEMPLATE="$HOMEBREW_TAP_ROOT/share/templates/team-banner.sh.template"
BANNER_SCRIPT="$TEAM_DIR/scripts/${INSTANCE_ID}-banner.sh"

if [[ -f "$BANNER_TEMPLATE" ]]; then
    # Convert TEAM_COLOR hex (#RRGGBB) to a best-effort xterm-256 color code.
    # We use Python for the conversion since it handles the math cleanly.
    # The 256-color cube starts at index 16; gray ramp starts at 232.
    _hex_to_256() {
        local hex="${1#\#}"  # Strip leading #
        python3 -c "
import sys

def nearest_256(r, g, b):
    def cube_val(n):
        return 0 if n == 0 else 55 + n * 40

    # Brute-force search the full 6x6x6 color cube (indices 16-231)
    best_cube_dist = float('inf')
    best_cube_idx = 16
    for ri in range(6):
        for gi in range(6):
            for bi in range(6):
                cr, cg, cb = cube_val(ri), cube_val(gi), cube_val(bi)
                d = (r-cr)**2 + (g-cg)**2 + (b-cb)**2
                if d < best_cube_dist:
                    best_cube_dist = d
                    best_cube_idx = 16 + 36*ri + 6*gi + bi

    # Search the gray ramp (indices 232-255, values 8, 18, 28 ... 238)
    best_gray_dist = float('inf')
    best_gray_idx = 232
    for i in range(24):
        gv = 8 + i * 10
        d = (r-gv)**2 + (g-gv)**2 + (b-gv)**2
        if d < best_gray_dist:
            best_gray_dist = d
            best_gray_idx = 232 + i

    return best_cube_idx if best_cube_dist <= best_gray_dist else best_gray_idx

h = sys.argv[1].lstrip('#')
r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
print(nearest_256(r, g, b))
" "$hex" 2>/dev/null || echo "178"
    }

    # Extract team-specific color palette and theme-select blocks for banner.
    # Uses the same TEAM_COLORS data as the zshrc generator for consistency.
    # Writes palette and theme_select to temp files, then substitutes into banner template.
    BANNER_PALETTE_FILE=$(mktemp)
    BANNER_THEME_FILE=$(mktemp)
    python3 - "$TEAM_ID" "$BANNER_PALETTE_FILE" "$BANNER_THEME_FILE" <<'BANNER_COLORS_EOF'
import sys

team_id = sys.argv[1]
palette_file = sys.argv[2]
theme_file = sys.argv[3]

# Per-team color palettes — must match TEAM_COLORS in generate_per_agent_zshrc_files()
# SYNC PAIR: tests/test-team-banner.sh _apply_template also inlines this dict.  Keep both in sync.
TEAM_BANNER_COLORS = {
    "academy": {
        "palette": """\
# Command Red (32nd Century Starfleet Red)
COMMAND_RED='%F{124}'              # Deep red
COMMAND_RED_BRIGHT='%F{160}'       # Brighter red for highlights

# Operations Gold (32nd Century Starfleet Gold)
OPS_GOLD='%F{178}'                # Mustard gold
OPS_GOLD_DARK='%F{136}'           # Darker gold for contrast

# Sciences Blue (32nd Century Starfleet Blue)
SCIENCES_BLUE='%F{25}'             # Deep blue
SCIENCES_BLUE_BRIGHT='%F{33}'      # Brighter blue""",
        "theme_select": """\
if [[ $SESSION_THEME == "COMMAND" ]]; then
    THEME_COLOR=$COMMAND_RED
    THEME_COLOR_HIGHLIGHT=$COMMAND_RED_BRIGHT
fi
if [[ $SESSION_THEME == "OPERATIONS" ]]; then
    THEME_COLOR=$OPS_GOLD
    THEME_COLOR_HIGHLIGHT=$OPS_GOLD_DARK
fi
if [[ $SESSION_THEME == "SCIENCES" ]]; then
    THEME_COLOR=$SCIENCES_BLUE
    THEME_COLOR_HIGHLIGHT=$SCIENCES_BLUE_BRIGHT
fi""",
    },
    "android": {
        "palette": """\
COMMAND_GOLD='%F{220}'
COMMAND_GOLD_BRIGHT='%F{226}'
SCIENCE_BLUE='%F{27}'
SCIENCE_BLUE_BRIGHT='%F{33}'
MEDICAL_BLUE='%F{39}'
MEDICAL_BLUE_BRIGHT='%F{45}'
ENGINEERING_RED='%F{160}'
ENGINEERING_RED_BRIGHT='%F{196}'
OPERATIONS_GOLD='%F{178}'
OPERATIONS_GOLD_BRIGHT='%F{184}'""",
        "theme_select": """\
if [[ $SESSION_THEME == "COMMAND" ]]; then
    THEME_COLOR=$COMMAND_GOLD; THEME_COLOR_HIGHLIGHT=$COMMAND_GOLD_BRIGHT
fi
if [[ $SESSION_THEME == "SCIENCE" ]]; then
    THEME_COLOR=$SCIENCE_BLUE; THEME_COLOR_HIGHLIGHT=$SCIENCE_BLUE_BRIGHT
fi
if [[ $SESSION_THEME == "MEDICAL" ]]; then
    THEME_COLOR=$MEDICAL_BLUE; THEME_COLOR_HIGHLIGHT=$MEDICAL_BLUE_BRIGHT
fi
if [[ $SESSION_THEME == "ENGINEERING" ]]; then
    THEME_COLOR=$ENGINEERING_RED; THEME_COLOR_HIGHLIGHT=$ENGINEERING_RED_BRIGHT
fi
if [[ $SESSION_THEME == "OPERATIONS" ]]; then
    THEME_COLOR=$OPERATIONS_GOLD; THEME_COLOR_HIGHLIGHT=$OPERATIONS_GOLD_BRIGHT
fi""",
    },
    "ios": {
        "palette": """\
COMMAND_RED='%F{124}'
COMMAND_RED_BRIGHT='%F{196}'
OPS_GOLD='%F{136}'
OPS_GOLD_ACCENT='%F{220}'
SCIENCE_TEAL='%F{30}'
SCIENCE_TEAL_BRIGHT='%F{51}'""",
        "theme_select": """\
if [[ $SESSION_THEME == "COMMAND" ]]; then
    THEME_COLOR=$COMMAND_RED; THEME_COLOR_HIGHLIGHT=$COMMAND_RED_BRIGHT
fi
if [[ $SESSION_THEME == "OPERATIONS" ]]; then
    THEME_COLOR=$OPS_GOLD; THEME_COLOR_HIGHLIGHT=$OPS_GOLD_ACCENT
fi
if [[ $SESSION_THEME == "SCIENCE" ]]; then
    THEME_COLOR=$SCIENCE_TEAL; THEME_COLOR_HIGHLIGHT=$SCIENCE_TEAL_BRIGHT
fi""",
    },
    "firebase": {
        "palette": """\
OPS_BLUE='%F{25}'
OPS_BLUE_BRIGHT='%F{33}'
ENG_GOLD='%F{94}'
ENG_GOLD_DARK='%F{172}'
SECURITY_GRAY='%F{236}'
SECURITY_GRAY_LIGHT='%F{240}'
SCIENCE_PURPLE='%F{60}'
SCIENCE_PURPLE_BRIGHT='%F{99}'
INCIDENT_RED='%F{52}'
INCIDENT_RED_BRIGHT='%F{160}'
PROM_GOLD='%F{94}'
PROM_GOLD_BRIGHT='%F{214}'
STELLAR_BLUE='%F{24}'
STELLAR_BLUE_BRIGHT='%F{39}'
SICKBAY_RED='%F{52}'
SICKBAY_RED_BRIGHT='%F{160}'""",
        "theme_select": """\
if [[ $SESSION_THEME == "COMMAND" ]]; then
    THEME_COLOR=$OPS_BLUE; THEME_COLOR_HIGHLIGHT=$OPS_BLUE_BRIGHT
fi
if [[ $SESSION_THEME == "ENGINEERING" ]]; then
    THEME_COLOR=$ENG_GOLD; THEME_COLOR_HIGHLIGHT=$ENG_GOLD_DARK
fi
if [[ $SESSION_THEME == "SECURITY" ]]; then
    THEME_COLOR=$SECURITY_GRAY; THEME_COLOR_HIGHLIGHT=$SECURITY_GRAY_LIGHT
fi
if [[ $SESSION_THEME == "OBSERVATION" ]]; then
    THEME_COLOR=$SCIENCE_PURPLE; THEME_COLOR_HIGHLIGHT=$SCIENCE_PURPLE_BRIGHT
fi
if [[ $SESSION_THEME == "INCIDENT" ]]; then
    THEME_COLOR=$INCIDENT_RED; THEME_COLOR_HIGHLIGHT=$INCIDENT_RED_BRIGHT
fi
if [[ $SESSION_THEME == "PROMENADE" ]]; then
    THEME_COLOR=$PROM_GOLD; THEME_COLOR_HIGHLIGHT=$PROM_GOLD_BRIGHT
fi
if [[ $SESSION_THEME == "SCIENCE" ]]; then
    THEME_COLOR=$STELLAR_BLUE; THEME_COLOR_HIGHLIGHT=$STELLAR_BLUE_BRIGHT
fi
if [[ $SESSION_THEME == "OPERATIONS" ]]; then
    THEME_COLOR=$OPS_BLUE; THEME_COLOR_HIGHLIGHT=$OPS_BLUE_BRIGHT
fi""",
    },
    "command": {
        "palette": """\
COMMAND_RED='%F{124}'
COMMAND_RED_BRIGHT='%F{160}'""",
        "theme_select": """\
if [[ $SESSION_THEME == "COMMAND" ]]; then
    THEME_COLOR=$COMMAND_RED; THEME_COLOR_HIGHLIGHT=$COMMAND_RED_BRIGHT
fi""",
    },
    "freelance": {
        "palette": """\
COMMAND_BLUE='%F{24}'
COMMAND_BLUE_BRIGHT='%F{33}'
OPS_GOLD='%F{136}'
OPS_GOLD_DARK='%F{178}'
SCIENCE_TEAL='%F{30}'
SCIENCE_TEAL_BRIGHT='%F{37}'""",
        "theme_select": """\
if [[ $SESSION_THEME == "COMMAND" ]]; then
    THEME_COLOR=$COMMAND_BLUE; THEME_COLOR_HIGHLIGHT=$COMMAND_BLUE_BRIGHT
fi
if [[ $SESSION_THEME == "OPERATIONS" ]]; then
    THEME_COLOR=$OPS_GOLD; THEME_COLOR_HIGHLIGHT=$OPS_GOLD_DARK
fi
if [[ $SESSION_THEME == "SCIENCE" ]]; then
    THEME_COLOR=$SCIENCE_TEAL; THEME_COLOR_HIGHLIGHT=$SCIENCE_TEAL_BRIGHT
fi""",
    },
    "legal": {
        "palette": """\
COMMAND_BLUE='%F{25}'
COMMAND_BLUE_BRIGHT='%F{33}'
OPS_GOLD='%F{178}'
OPS_GOLD_DARK='%F{136}'
SCIENCES_BLUE='%F{25}'
SCIENCES_BLUE_BRIGHT='%F{33}'""",
        "theme_select": """\
if [[ $SESSION_THEME == "COMMAND" ]]; then
    THEME_COLOR=$COMMAND_BLUE; THEME_COLOR_HIGHLIGHT=$COMMAND_BLUE_BRIGHT
fi
if [[ $SESSION_THEME == "OPERATIONS" ]]; then
    THEME_COLOR=$OPS_GOLD; THEME_COLOR_HIGHLIGHT=$OPS_GOLD_DARK
fi
if [[ $SESSION_THEME == "SCIENCES" ]]; then
    THEME_COLOR=$SCIENCES_BLUE; THEME_COLOR_HIGHLIGHT=$SCIENCES_BLUE_BRIGHT
fi""",
    },
    "medical": {
        "palette": """\
COMMAND_BLUE='%F{25}'
COMMAND_BLUE_BRIGHT='%F{33}'
OPS_GOLD='%F{25}'
OPS_GOLD_ACCENT='%F{178}'
SCIENCES_BLUE='%F{25}'
SCIENCES_BLUE_BRIGHT='%F{39}'""",
        "theme_select": """\
if [[ $SESSION_THEME == "COMMAND" ]]; then
    THEME_COLOR=$COMMAND_BLUE; THEME_COLOR_HIGHLIGHT=$COMMAND_BLUE_BRIGHT
fi
if [[ $SESSION_THEME == "OPERATIONS" ]]; then
    THEME_COLOR=$OPS_GOLD; THEME_COLOR_HIGHLIGHT=$OPS_GOLD_ACCENT
fi
if [[ $SESSION_THEME == "SCIENCES" ]]; then
    THEME_COLOR=$SCIENCES_BLUE; THEME_COLOR_HIGHLIGHT=$SCIENCES_BLUE_BRIGHT
fi""",
    },
}

data = TEAM_BANNER_COLORS.get(team_id, {})
palette = data.get("palette", "# No team-specific palette defined")
theme_select = data.get("theme_select", "# No team-specific theme mapping")

with open(palette_file, "w") as f:
    f.write(palette)
with open(theme_file, "w") as f:
    f.write(theme_select)
BANNER_COLORS_EOF

    # Generate banner script — Python handles multi-line substitution cleanly
    # (awk -v breaks on $-signs and newlines in palette/theme strings)
    TEAM_BANNER_SCRIPT_NAME="${INSTANCE_ID}-banner.sh"
    python3 - "$BANNER_TEMPLATE" "$BANNER_SCRIPT" "$BANNER_PALETTE_FILE" "$BANNER_THEME_FILE" \
              "$INSTANCE_ID" "$TEAM_NAME" "${TEAM_SHIP:-${TEAM_THEME}}" "$TEAM_BANNER_SCRIPT_NAME" <<'BANNER_SUB_EOF'
import sys
template_path, output_path = sys.argv[1], sys.argv[2]
palette_path, theme_path = sys.argv[3], sys.argv[4]
team_id, team_name, team_ship, banner_name = sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8]

with open(template_path) as f:
    content = f.read()
with open(palette_path) as f:
    palette = f.read()
with open(theme_path) as f:
    theme_select = f.read()

content = content.replace("{{TEAM_ID}}", team_id)
content = content.replace("{{TEAM_NAME}}", team_name)
content = content.replace("{{TEAM_SHIP}}", team_ship)
content = content.replace("{{TEAM_BANNER_SCRIPT}}", banner_name)
content = content.replace("{{TEAM_BANNER_PALETTE}}", palette)
content = content.replace("{{TEAM_BANNER_THEME_SELECT}}", theme_select)

with open(output_path, "w") as f:
    f.write(content)
BANNER_SUB_EOF
    rm -f "$BANNER_PALETTE_FILE" "$BANNER_THEME_FILE"
    chmod +x "$BANNER_SCRIPT"
    echo "  ✓ ${INSTANCE_ID}-banner.sh (team-specific color palette)"
    echo "    Path: $BANNER_SCRIPT"
else
    echo "  ⚠️  Banner template not found: $BANNER_TEMPLATE (skipping)"
fi

echo ""

# ============================================================================
# AGENT FUNCTION NAME LOOKUP
# Resolves the claude-* shell function name for a given team/agent pair.
# Most agents map directly to claude-<agent> (matching agent-aliases.sh).
# Exceptions (where character names differ from function names) are listed here.
# ============================================================================

_agent_function_name() {
    local team="$1" agent="$2"
    case "${team}/${agent}" in
        # Academy exceptions: character names differ from function names
        academy/chancellor) echo "claude-ake" ;;
        # Command exceptions
        command/admiral)    echo "claude-vance" ;;
        command/commodore)  echo "claude-ross" ;;
        # Default: claude-<agent> matches the function in agent-aliases.sh
        *)                  echo "claude-${agent}" ;;
    esac
}

# ============================================================================
# CONFIGURE CLAUDE CODE AGENT ALIASES
# ============================================================================

echo "🤖 Configuring Claude Code agent aliases..."

ALIASES_FILE="$AITEAMFORGE_DIR/claude_agent_aliases.sh"
ALIASES_TEAM_SECTION="# $TEAM_NAME aliases"

# Create aliases file if it doesn't exist
if [[ ! -f "$ALIASES_FILE" ]]; then
    cat > "$ALIASES_FILE" <<EOF
#!/bin/bash
# Claude Code Agent Aliases
# Auto-generated by aiteamforge installer

EOF
fi

# Add team section if not already present
if ! grep -q "$ALIASES_TEAM_SECTION" "$ALIASES_FILE"; then
    cat >> "$ALIASES_FILE" <<EOF

$ALIASES_TEAM_SECTION
EOF

    for agent in "${TEAM_AGENTS[@]}"; do
        cat >> "$ALIASES_FILE" <<EOF
alias ${TEAM_ID}-${agent}='claude --agent-path "$AITEAMFORGE_DIR/claude/agents/${TEAM_NAME}/${agent}"'
EOF
        echo "  ✓ Alias: $(_agent_function_name "$TEAM_ID" "$agent")"
    done

    echo ""
fi

# ============================================================================
# SETUP TEAM KANBAN BOARD
# ============================================================================

echo "📋 Setting up team kanban board..."

# Use team working dir if set (project-based teams), otherwise central kanban dir
if [[ -n "${TEAM_WORKING_DIR:-}" && "$TEAM_WORKING_DIR" != "$AITEAMFORGE_DIR" && "$TEAM_WORKING_DIR" != "$AITEAMFORGE_DIR/$TEAM_ID" ]]; then
    KANBAN_DIR="${TEAM_WORKING_DIR}/kanban"
else
    KANBAN_DIR="$AITEAMFORGE_DIR/kanban"
fi
mkdir -p "$KANBAN_DIR"

# ============================================================================
# XACA-0463: Persist per-instance lcars_port to team-paths.json
# ============================================================================
# Upsert the INSTANCE_ID entry in team-paths.json with the allocated port.
# Runs after the connect-only early exit so only full installs write the file.
# KANBAN_DIR and TEAM_WORKING_DIR are both finalized by this point.
#
# The write is atomic (write-to-tmp + rename) to avoid corrupting team-paths.json
# if the installer is interrupted mid-write.
#
# If team-paths.json does not exist yet, the Python script initialises it with
# {"schema_version": 1, "teams": {}} before adding this entry.
echo "  ✓ XACA-0463: persisting lcars_port=$TEAM_LCARS_PORT for instance $INSTANCE_ID to team-paths.json..."
python3 - "$INSTANCE_ID" "$TEAM_ID" "$KANBAN_DIR" "$TEAM_WORKING_DIR" "$TEAM_LCARS_PORT" \
    "${AITEAMFORGE_CONFIG:-$HOME/.aiteamforge/team-paths.json}" <<'TEAM_PATHS_PYEOF'
import sys
import json
import os
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path

instance_id  = sys.argv[1]
template_id  = sys.argv[2]
kanban_dir   = sys.argv[3]
working_dir  = sys.argv[4]
lcars_port   = int(sys.argv[5])
config_path  = Path(sys.argv[6])

# XACA-0463 subitem 013: backup snapshot before write (parity with kb-port-fix --apply).
# Skipped on first install when config_path does not yet exist.
if config_path.exists():
    ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    backup_path = config_path.parent / (config_path.name + ".bak-xaca0463-installer-" + ts)
    shutil.copy2(str(config_path), str(backup_path))

# Load existing config, or start fresh.
if config_path.exists():
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        print(f"  Warning: could not parse {config_path}: {exc} — starting with empty config", file=sys.stderr)
        config = {"schema_version": 1, "teams": {}}
else:
    config = {"schema_version": 1, "teams": {}}
    config_path.parent.mkdir(parents=True, exist_ok=True)

# XACA-0463 subitem 015: _safe_teams-normalize parsed-but-malformed root/teams value.
# Mirrors the _safe_teams guard added to kb-port-fix.py in XACA-0463-013.
# Without this, a malformed team-paths.json (null root, [], or "teams": null)
# would crash at config["teams"][instance_id] = entry.
if not isinstance(config, dict):
    config = {}
if not isinstance(config.get("teams"), dict):
    config["teams"] = {}

teams = config.setdefault("teams", {})

# Upsert: preserve any existing fields; update or add lcars_port, kanban_dir, working_dir.
entry = teams.get(instance_id, {})
entry["kanban_dir"]  = kanban_dir
entry["working_dir"] = working_dir
entry["lcars_port"]  = lcars_port
# Preserve band metadata if already present (written by kb-port-fix or prior installs).
# Do not overwrite lcars_port_base / lcars_port_range — those come from DEFAULT_TEAMS,
# not from the installer; the reader falls back to DEFAULT_TEAMS for band queries.
teams[instance_id] = entry

# XACA-0463 subitem 014: concurrency-safe atomic write via tempfile.mkstemp + os.replace.
# mkstemp generates a unique name even if two installers race; os.replace is atomic on
# the same filesystem. Replaces the previous write_text + fixed-suffix .tmp approach.
#
# XACA-0463 subitem 016: preserve target file's mode bits across the atomic rename.
# mkstemp defaults to 0600; we carry over the original mode (or 0o644 for new files)
# before os.replace clobbers the target's permissions.
target_dir = str(config_path.parent)
tmp_fd, tmp_path = tempfile.mkstemp(prefix="team-paths-", dir=target_dir)
try:
    with os.fdopen(tmp_fd, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    # XACA-0463 subitem 016: stat existing file for mode; fall back to 0o644 for new.
    try:
        original_mode = os.stat(str(config_path)).st_mode
    except FileNotFoundError:
        original_mode = 0o644
    os.chmod(tmp_path, original_mode & 0o7777)
    os.replace(tmp_path, str(config_path))
    print(f"  ✓ XACA-0463: team-paths.json updated — {instance_id}.lcars_port={lcars_port}")
except Exception as exc:
    print(f"  Warning: XACA-0463 could not write {config_path}: {exc}", file=sys.stderr)
    try:
        os.unlink(tmp_path)
    except FileNotFoundError:
        pass
    raise
TEAM_PATHS_PYEOF

# Board filename uses INSTANCE_ID (not template id) — contract §6, invariant 8.
TEAM_BOARD="$KANBAN_DIR/${INSTANCE_ID}-board.json"

# XACA-0212: skip stub creation when a profile-scoped canonical board already exists
# Scan one level up from $KANBAN_DIR (the team root) for any profile-scoped board files.
# Capture all matches in a single find call (excluding $TEAM_BOARD itself) so we
# avoid a second scan when listing the canonicals — fewer NFS round-trips.
CANONICAL_MATCHES=()
while IFS= read -r line; do
    [[ -n "$line" && "$line" != "$TEAM_BOARD" ]] && CANONICAL_MATCHES+=("$line")
done < <(find "$(dirname "$KANBAN_DIR")" -maxdepth 3 -path "*/kanban/*-board.json" -type f 2>/dev/null)
if (( ${#CANONICAL_MATCHES[@]} > 0 )); then
    echo "  ⏭  Skipping stub: profile-scoped canonical board already exists"
    for canonical_path in "${CANONICAL_MATCHES[@]}"; do
        echo "      Canonical: $canonical_path"
    done
elif [[ -f "$TEAM_BOARD" ]]; then
    echo "  ✓ Kanban board already exists"
else
    # Build board JSON from registry.json branding (XACA-0460-011).
    # REGISTRY_NAME_RAW / REGISTRY_DESC / REGISTRY_COLOR / REGISTRY_ICON / REGISTRY_THEME
    # were loaded above when we validated the template entry.
    #
    # Field semantics (matches dev-team's academy-board.json model):
    #   teamName     = brand name (uppercase, e.g., "FERENGI COMMERCE AUTHORITY")
    #   organization = template id (uppercase, e.g., "FINANCE") — drives sidebar line 2
    #   subtitle     = theme (uppercase, e.g., "STAR TREK: DEEP SPACE NINE - FERENGI") — sidebar line 1
    #   ship         = TEAM_SHIP from conf (mixed case, e.g., "Ferengi Alliance Commerce Hub")
    # LCARS UI renders title as "${organization} ${teamName}" so these MUST be distinct
    # values; using the same string for both (the pre-XACA-0486 bug) caused the title
    # to render duplicated as "Ferengi Commerce Authority Ferengi Commerce Authority".
    _BOARD_CREATED="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    _BOARD_SERIES="$(echo "$TEAM_ID" | tr '[:lower:]' '[:upper:]' | cut -c1-3)"
    _BOARD_TEAMNAME_UPPER="$(echo "$REGISTRY_NAME_RAW" | tr '[:lower:]' '[:upper:]')"
    _BOARD_ORG_UPPER="$(echo "$TEAM_ID" | tr '[:lower:]' '[:upper:]')"
    _BOARD_SUBTITLE_UPPER="$(echo "$TEAM_THEME" | tr '[:lower:]' '[:upper:]')"
    jq -n \
        --arg team        "$INSTANCE_ID" \
        --arg teamName    "$_BOARD_TEAMNAME_UPPER" \
        --arg subtitle    "$_BOARD_SUBTITLE_UPPER" \
        --arg series      "X${_BOARD_SERIES}" \
        --arg organization "$_BOARD_ORG_UPPER" \
        --arg orgColor    "$REGISTRY_COLOR" \
        --arg ship        "${TEAM_SHIP:-Unknown Vessel}" \
        --arg icon        "$REGISTRY_ICON" \
        --arg template    "$TEAM_ID" \
        --arg instance    "$INSTANCE_ID" \
        --arg kanbanDir   "$KANBAN_DIR" \
        --arg created     "$_BOARD_CREATED" \
        '{
          "team":         $team,
          "teamName":     $teamName,
          "subtitle":     $subtitle,
          "series":       $series,
          "organization": $organization,
          "orgColor":     $orgColor,
          "ship":         $ship,
          "icon":         $icon,
          "template":     $template,
          "instance":     $instance,
          "kanbanDir":    $kanbanDir,
          "lastUpdated":  $created,
          "nextId":       1,
          "nextEpicId":   1,
          "nextReleaseId":1,
          "fleetMonitorUrl": "",
          "terminals":    {},
          "activeWindows":[],
          "backlog":      [],
          "epics":        [],
          "releases":     []
        }' > "$TEAM_BOARD"
    echo "  ✓ Created kanban board: ${INSTANCE_ID}-board.json (branding: $REGISTRY_NAME_RAW)"
fi

# XACA-0484: stub-board migration. Earlier installer versions wrote board files
# with null branding fields (teamName / organization / ship / subtitle). The
# "Kanban board already exists" check above means those stale stubs are never
# upgraded. Detect null/missing branding fields and patch them from the current
# registry+conf. Non-destructive: only updates the branding fields; preserves
# all backlog/epics/releases/terminals data.
if [[ -f "$TEAM_BOARD" ]]; then
    # XACA-0486 detection: also catch the duplicate-brand bug from 0.11.7/0.11.8
    # where boards have non-null but wrong values (organization == teamName).
    # That fingerprint can never be correct under the academy-board.json model
    # (organization is template-id-upper, teamName is brand-upper — they differ).
    _XACA0484_NEEDS_PATCH=$(jq -r '
        if (.teamName == null) or (.organization == null) or
           (.ship == null) or (.subtitle == null) or
           (.organization == .teamName) then "true" else "false" end
    ' "$TEAM_BOARD" 2>/dev/null || echo "false")
    if [[ "$_XACA0484_NEEDS_PATCH" == "true" ]]; then
        # XACA-0486 field semantics (matches academy-board.json model):
        #   teamName=brand (UPPER), organization=template-id (UPPER), subtitle=theme (UPPER).
        # Pre-XACA-0486 migration set all three from REGISTRY_NAME_RAW / REGISTRY_DESC
        # which produced duplicate org/teamName and the wrong subtitle.
        _XACA0486_TEAMNAME_UPPER="$(echo "$REGISTRY_NAME_RAW" | tr '[:lower:]' '[:upper:]')"
        _XACA0486_ORG_UPPER="$(echo "$TEAM_ID" | tr '[:lower:]' '[:upper:]')"
        _XACA0486_SUBTITLE_UPPER="$(echo "$TEAM_THEME" | tr '[:lower:]' '[:upper:]')"
        _XACA0484_BOARD_TMP="${TEAM_BOARD}.xaca0484-patch.tmp"
        # XACA-0486 patch: for the three semantic fields (teamName / organization /
        # subtitle), re-derive UNCONDITIONALLY from current registry+conf. Earlier
        # `// $default` coalescing preserved the wrong values from 0.11.7/0.11.8
        # installs. The install-time computation is the source of truth for
        # parametric teams — users who manually edit these should expect re-derive.
        # Other fields (ship, icon, template, instance) keep `// $default` since
        # they may legitimately predate or post-date this migration.
        jq \
            --arg teamName    "$_XACA0486_TEAMNAME_UPPER" \
            --arg subtitle    "$_XACA0486_SUBTITLE_UPPER" \
            --arg organization "$_XACA0486_ORG_UPPER" \
            --arg orgColor    "$REGISTRY_COLOR" \
            --arg ship        "${TEAM_SHIP:-Unknown Vessel}" \
            --arg icon        "$REGISTRY_ICON" \
            --arg template    "$TEAM_ID" \
            --arg instance    "$INSTANCE_ID" \
            '.teamName     = $teamName
           | .subtitle     = $subtitle
           | .organization = $organization
           | .orgColor     = (.orgColor     // $orgColor)
           | .ship         = (.ship         // $ship)
           | .icon         = (.icon         // $icon)
           | .template     = (.template     // $template)
           | .instance     = (.instance     // $instance)' \
            "$TEAM_BOARD" > "$_XACA0484_BOARD_TMP" \
        && mv "$_XACA0484_BOARD_TMP" "$TEAM_BOARD" \
        && echo "  🔧 Patched stub branding fields in ${INSTANCE_ID}-board.json (XACA-0484)"
    fi
fi

echo ""

# ============================================================================
# CREATE LCARS PORT CONFIGURATION
# ============================================================================

echo "🖥️  Configuring LCARS port assignments..."

LCARS_PORTS_DIR="$AITEAMFORGE_DIR/lcars-ports"
mkdir -p "$LCARS_PORTS_DIR"

# Create port files for each agent
for agent in "${TEAM_AGENTS[@]}"; do
    PORT_FILE="$LCARS_PORTS_DIR/${TEAM_ID}-${agent}.port"
    if [[ ! -f "$PORT_FILE" ]]; then
        # Assign a port (this is a simple incrementing scheme, can be improved)
        # Base port + offset based on agent index
        AGENT_INDEX=0
        for ((i=0; i<${#TEAM_AGENTS[@]}; i++)); do
            if [[ "${TEAM_AGENTS[$i]}" == "$agent" ]]; then
                AGENT_INDEX=$i
                break
            fi
        done

        AGENT_PORT=$((TEAM_LCARS_PORT + AGENT_INDEX))
        echo "$AGENT_PORT" > "$PORT_FILE"

        # Create theme file (default to team color)
        THEME_FILE="$LCARS_PORTS_DIR/${TEAM_ID}-${agent}.theme"
        echo "$TEAM_COLOR" > "$THEME_FILE"

        # Create order file
        ORDER_FILE="$LCARS_PORTS_DIR/${TEAM_ID}-${agent}.order"
        echo "$AGENT_INDEX" > "$ORDER_FILE"
    fi
done

echo "  ✓ Port assignments created"
echo ""

# ============================================================================
# GENERATE PER-AGENT STARTUP SCRIPTS
# ============================================================================
# Creates individual startup scripts for each agent persona found in the team's
# personas directory.  Scripts are named <team>-<terminal_id>-startup.sh and
# follow the android-bridge-startup.sh pattern: hardcoded persona variables,
# a setup_window() function, 4 named tmux windows, status-line theming, and a
# SKIP_ATTACH guard.
#
# The generator is driven by persona .md files (not TEAM_AGENTS) so the script
# name uses the frontmatter 'name:' field (e.g. "reno") rather than the TEAM_AGENTS
# role label (e.g. "engineering").  AGENT_WINDOWS_* variables are read directly
# from the raw conf text because the _read_conf() loader only serialises windows
# for agents whose names appear in TEAM_AGENTS, and character names (reno, emh,
# thok) often differ from role labels (engineering, medical, training).
# ============================================================================

generate_per_agent_startup_scripts() {
    local personas_dir="$AITEAMFORGE_DIR/$TEAM_ID/personas/agents"
    # Fall back to the homebrew-tap share layout if installed layout is absent
    if [[ ! -d "$personas_dir" ]]; then
        personas_dir="$HOMEBREW_TAP_ROOT/share/personas/$TEAM_ID/agents"
    fi
    if [[ ! -d "$personas_dir" ]]; then
        echo "  ⚠️  No personas directory found for $TEAM_ID — skipping per-agent startup scripts"
        return 0
    fi

    local scripts_dir="$AITEAMFORGE_DIR/$TEAM_ID/scripts"
    mkdir -p "$scripts_dir"

    # Read all AGENT_WINDOWS_* values directly from the raw conf text so that
    # character-named keys (e.g. AGENT_WINDOWS_reno) are found even when the
    # TEAM_AGENTS array uses role labels (e.g. "engineering").
    local raw_conf_text
    raw_conf_text=$(grep '^AGENT_WINDOWS_' "$TEAM_CONF" 2>/dev/null || true)

    local tap_version
    tap_version="$(cat "$HOMEBREW_TAP_ROOT/VERSION" 2>/dev/null || echo "unknown")"

    python3 - "$personas_dir" "$scripts_dir" "$TEAM_ID" \
              "$AITEAMFORGE_DIR" "$TEAM_COLOR" "$raw_conf_text" "$tap_version" <<'PYEOF'
import re
import sys
import os
from pathlib import Path

# ---- Arguments ----
personas_dir  = Path(sys.argv[1])
scripts_dir   = Path(sys.argv[2])
team_id       = sys.argv[3]
atf_dir       = sys.argv[4]
team_color    = sys.argv[5]          # hex e.g. "#0099CC"
raw_conf_text = sys.argv[6]          # raw AGENT_WINDOWS_* lines from conf
tap_version   = sys.argv[7] if len(sys.argv) > 7 else "unknown"

# ---- Parse AGENT_WINDOWS from raw conf text ----
# Each line looks like:  AGENT_WINDOWS_reno="win0 win1 win2 win3"
agent_windows = {}
for line in raw_conf_text.splitlines():
    m = re.match(r'^AGENT_WINDOWS_(\w+)="([^"]*)"', line.strip())
    if m:
        agent_windows[m.group(1).lower()] = m.group(2).split()

# ---- Frontmatter parser ----
def parse_frontmatter(text):
    result = {}
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return result
    for line in lines[1:]:
        stripped = line.strip()
        if stripped == "---":
            break
        if ":" in stripped:
            key, _, val = stripped.partition(":")
            val = val.strip().strip('"').strip("'")
            if key.strip() not in result:
                result[key.strip()] = val
    return result

# ---- Bold-field extractor (matches ## Core Identity section) ----
def parse_core_identity(text):
    result = {"developer": "", "role": "", "location": "", "theme": ""}
    for header_pattern in (r"^##\s+Core Identity", r"^##\s+Your Identity"):
        m = re.search(header_pattern, text, re.MULTILINE)
        if m:
            rest = text[m.end():]
            ns = re.search(r"^##\s+", rest, re.MULTILINE)
            section = rest[:ns.start()] if ns else rest
            break
    else:
        return result

    def find_field(field, text):
        pat = rf"\*\*{re.escape(field)}\*\*:?\s*(.+)"
        m = re.search(pat, text)
        if m:
            return m.group(1).strip().rstrip("\\").strip()
        pat2 = rf"\*\*{re.escape(field)}:\*\*\s*(.+)"
        m2 = re.search(pat2, text)
        if m2:
            return m2.group(1).strip().rstrip("\\").strip()
        return ""

    result["developer"] = find_field("Name", section) or find_field("Character", section)
    result["role"]      = find_field("Role", section)
    result["location"]  = find_field("Location", section)
    theme_raw           = find_field("Uniform Color", section)
    if theme_raw:
        result["theme"] = theme_raw.upper()
    return result

# ---- Uniform-color → tmux colour codes ----
# Format: (bg_code, accent_code)
# Derived from proven dev-team per-agent startup scripts.
# These are default values; teams can override via THEME_COLORS_<THEME> in .conf.
THEME_COLORS = {
    "COMMAND":    (124, 160),
    "OPERATIONS": (136, 178),
    "SCIENCES":   (25,  33),
    "SCIENCE":    (30,  37),
    "SECURITY":   (236, 240),
    "PROMENADE":  (94,  214),
    "MEDICAL":    (25,  33),
    "INCIDENT":   (52,  160),
    "ENGINEERING":(94,  172),
    "OBSERVATION":(60,  99),
    "HELM":       (136, 220),
    "NAVIGATION": (58,  220),
    "COMMUNICATIONS": (124, 196),
}
DEFAULT_THEME_COLORS = (240, 250)

# ---- Session description builder ----
def make_session_desc(team_id, terminal_id, frontmatter_desc):
    team_upper     = team_id.upper().replace("-", " ")
    terminal_upper = terminal_id.upper().replace("-", " ")
    base = f"{team_upper} {terminal_upper}"
    if frontmatter_desc and " - " in frontmatter_desc:
        after_dash = frontmatter_desc.split(" - ", 1)[1].strip()
        suffix = re.split(r"[,.]", after_dash)[0].strip()
        if suffix:
            return f"{base} - {suffix.upper()}"
    return base

# ---- Location formatter ----
def make_location(team_id, parsed_location):
    if parsed_location and " - " in parsed_location:
        parts = parsed_location.split(" - ", 1)
        short_team = parts[0].strip().split()[-1] if parts[0].strip().split() else parts[0].strip()
        return f"{short_team}: {parts[1].strip()}"
    return parsed_location or team_id.title()

# ---- Window description helper ----
def window_desc(win_name, terminal_id, win_index):
    """Derive a TERMINAL_DESCRIPTION for a window name.
    Window 0 is always '<Division> Command Center' to match dev-team pattern.
    Subsequent windows use the window name in title case."""
    if win_index == 0:
        return f"{terminal_id.replace('-', ' ').title()} Command Center"
    # Subsequent windows: capitalise the window name
    return win_name.replace("-", " ").title()

# ---- Script generator ----
def generate_script(terminal_id, identity, windows, frontmatter, session_desc, location, aiteamforge_dir):
    developer = identity["developer"]
    role      = identity["role"]
    theme     = identity["theme"] or "OPERATIONS"

    bg_code, accent_code = THEME_COLORS.get(theme, DEFAULT_THEME_COLORS)

    # Ensure we have at least 4 windows; pad with generic names if needed
    base_windows = list(windows) if windows else [f"{terminal_id}-cmd", "monitor", "scratch", "debug"]
    while len(base_windows) < 4:
        base_windows.append(f"window-{len(base_windows)}")
    win_names = base_windows[:4]

    # Build set_window_metadata case branches (reused by panel-regen loop
    # and session-creation loop below).
    metadata_cases = []
    for i, wname in enumerate(win_names):
        wdesc = window_desc(wname, terminal_id, i)
        metadata_cases.append(
            f'        {i}) TERMINAL_NUMBER={i}; TERMINAL_NAME="{wname}"; TERMINAL_DESCRIPTION="{wdesc}" ;;'
        )
    window_metadata_section = "\n".join(metadata_cases)

    # Build 4-window block — now uses set_window_metadata instead of inlining
    window_blocks = []
    for i, wname in enumerate(win_names):
        if i == 0:
            window_blocks.append(
                f'    # Window 0: Primary\n'
                f'    set_window_metadata 0\n'
                f'    echo -n "- Connecting to $TERMINAL_DESCRIPTION..."\n'
                f'    $TMUX_CMD new-session -d -s $SESSION_CODE -n $TERMINAL_NAME -c "$SESSION_DIRECTORY"\n'
                f'    setup_window\n'
                f'    sleep 0.2\n'
                f'    echo "CONNECTED"'
            )
        else:
            window_blocks.append(
                f'    # Window {i}\n'
                f'    set_window_metadata {i}\n'
                f'    echo -n "- Connecting to $TERMINAL_DESCRIPTION..."\n'
                f'    $TMUX_CMD new-window -t $SESSION_CODE:$TERMINAL_NUMBER -n $TERMINAL_NAME\n'
                f'    setup_window\n'
                f'    sleep 0.2\n'
                f'    echo "CONNECTED"'
            )

    window_section = "\n\n".join(window_blocks)

    script = f'''#!/bin/bash
set +x
# {team_id.title()} {terminal_id.title()} Terminal Startup
# Auto-generated by aiteamforge installer (install-team.sh generate_per_agent_startup_scripts)
# AITEAMFORGE_GENERATED_VERSION={tap_version}

SESSION_THEME="{theme}"
SESSION_TYPE="{team_id}"
SESSION_NAME="{terminal_id}"
SESSION_DESCRIPTION="{session_desc}"
SESSION_LOCATION="{location}"
SESSION_DEVELOPER="{developer}"
SESSION_ROLE="{role}"
SESSION_DIRECTORY="$HOME/{team_id}"
THEME_COLOR="{team_color}"

SESSION_CODE="${{SESSION_TYPE}}-${{SESSION_NAME}}"

AITEAMFORGE_DIR="{aiteamforge_dir}"

# Theme color file directory for fleet-monitor integration
THEME_PORTS_DIR="$AITEAMFORGE_DIR/lcars-ports"

# Use team-specific tmux socket if set, otherwise use default server
TMUX_CMD="tmux${{TMUX_SOCKET:+ -L $TMUX_SOCKET}}"

# Resolve display hostname for tmux status-right.
# Prefers Tailscale machine name (consistent across Macs, matches the
# host argument passed to team-connect.sh on the client side) and falls
# back to `hostname -s` if the resolver is missing or tailscaled is down.
_HOSTNAME_RESOLVER="$AITEAMFORGE_DIR/scripts/aiteamforge-resolve-hostname.sh"
if [ -x "$_HOSTNAME_RESOLVER" ]; then
    DISPLAY_HOST=$("$_HOSTNAME_RESOLVER" 2>/dev/null)
fi
if [ -z "${{DISPLAY_HOST:-}}" ]; then
    DISPLAY_HOST=$(hostname -s 2>/dev/null | sed 's/\\.local$//')
fi

# ============================================================================
# Function: set_window_metadata
# Sets TERMINAL_NUMBER / TERMINAL_NAME / TERMINAL_DESCRIPTION for a window.
# Factored out so the panel-regen loop AND session-creation loop can reuse it.
# ============================================================================
set_window_metadata() {{
    case "$1" in
{window_metadata_section}
    esac
}}

# ============================================================================
# Function: setup_window
# Executes the common setup commands for each tmux window
# ============================================================================
KANBAN_HELPERS="$AITEAMFORGE_DIR/kanban-helpers.sh"

setup_window() {{
    sleep 0.1
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER "cd $SESSION_DIRECTORY" C-m
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". ~/.zshrc_${{SESSION_TYPE}}_${{SESSION_NAME}}" C-m
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". $KANBAN_HELPERS" C-m
    $TMUX_CMD send-keys -t $SESSION_CODE:$TERMINAL_NUMBER ". $AITEAMFORGE_DIR/$SESSION_TYPE/scripts/$SESSION_TYPE-banner.sh \\"$SESSION_THEME\\" \\"$SESSION_TYPE\\" \\"$SESSION_NAME\\" \\"$TERMINAL_NUMBER\\" \\"$TERMINAL_NAME\\" \\"$SESSION_DESCRIPTION\\" \\"$SESSION_LOCATION\\" \\"$SESSION_DEVELOPER\\" \\"$SESSION_ROLE\\" \\"$TERMINAL_DESCRIPTION\\"" C-m
}}

# ============================================================================
# Refresh agent panel JSON for every window — UNCONDITIONAL.
# The has-session block below only fires on first tmux session creation;
# the banner that writes panel JSON via display_agent_avatar only runs then.
# Panel JSON lives outside tmux, so we regenerate it on every invocation of
# this script — protects against iTerm restarts, tmux socket reboots, and
# infrastructure upgrades leaving panels stuck on "Awaiting agent...".
#
# Replaces an earlier init-agent-panel-json.py call that wrote persona-named
# files (e.g. lcars-agent-legal-advocate.json) which the display panels
# (keyed on session names like lcars-agent-legal-coparenting-chambers.json)
# never read.
# ============================================================================
_AVATAR_HELPER="$AITEAMFORGE_DIR/scripts/display-agent-avatar.sh"
[ ! -f "$_AVATAR_HELPER" ] && _AVATAR_HELPER="$AITEAMFORGE_DIR/share/scripts/display-agent-avatar.sh"
if [ -f "$_AVATAR_HELPER" ]; then
    source "$_AVATAR_HELPER"
    for _i in 0 1 2 3; do
        set_window_metadata "$_i"
        export SESSION_THEME SESSION_DESCRIPTION SESSION_LOCATION SESSION_ROLE
        export SESSION_CODE TERMINAL_NUMBER TERMINAL_NAME TERMINAL_DESCRIPTION
        display_agent_avatar "$SESSION_TYPE" "$SESSION_DEVELOPER" >/dev/null 2>&1
    done
fi

$TMUX_CMD has-session -t $SESSION_CODE

if [ $? != 0 ]; then
    clear
    echo "Initializing {team_id.title()} {terminal_id.title()}..."

{window_section}

    # Configure tmux for iTerm2 compatibility (must be AFTER new-session creates the server)
    # allow-passthrough: Required for imgcat inline images through tmux panes
    # mouse: Enables clicking on tmux window tabs and pane borders
    $TMUX_CMD set -g allow-passthrough on 2>/dev/null
    $TMUX_CMD set -g mouse on 2>/dev/null
    $TMUX_CMD set-option -g allow-rename off 2>/dev/null
    $TMUX_CMD set-window-option -g automatic-rename off 2>/dev/null

    # Configure tmux status line - {theme} theme
    $TMUX_CMD set -t $SESSION_CODE status-left-length 15
    $TMUX_CMD set -t $SESSION_CODE status-left "  $SESSION_NAME "
    # Set session-specific variables for dynamic status-right
    $TMUX_CMD set -t $SESSION_CODE @developer "$SESSION_DEVELOPER"
    $TMUX_CMD set -t $SESSION_CODE @claude_agent "{terminal_id}"
    $TMUX_CMD set -t $SESSION_CODE status-right "🤖 #{{@claude_agent}} | 🖥  $DISPLAY_HOST  "
    $TMUX_CMD set -t $SESSION_CODE status-style "bg=colour{bg_code},fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE status-left-style "bg=colour{accent_code},fg=colour255,bold"
    $TMUX_CMD set -t $SESSION_CODE status-right-style "bg=colour{bg_code},fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-style "bg=colour{bg_code},fg=colour255"
    $TMUX_CMD set -t $SESSION_CODE window-status-current-style "bg=colour{accent_code},fg=colour255,bold"
    $TMUX_CMD set -t $SESSION_CODE pane-border-style "fg=colour{bg_code}"
    $TMUX_CMD set -t $SESSION_CODE pane-active-border-style "fg=colour{accent_code}"

    sleep 0.5
    $TMUX_CMD select-window -t $SESSION_CODE:0

    # Write theme color file for fleet-monitor integration
    mkdir -p "$THEME_PORTS_DIR"
    echo "$THEME_COLOR" > "$THEME_PORTS_DIR/${{SESSION_CODE}}.theme"

    echo "{team_id.title()} {terminal_id.title()} initialized"
    echo ""
    echo "--> {len(win_names)} command stations active"
    echo "--> {developer} reporting for duty"
    echo ""
    sleep 1
fi

# Only attach if not being launched by master startup script
if [ -z "$SKIP_ATTACH" ]; then
    $TMUX_CMD attach-session -t $SESSION_CODE
fi
'''
    return script

# ---- Main loop over persona files ----
persona_files = sorted(personas_dir.glob("*_persona.md"))
if not persona_files:
    print(f"  Warning: no persona files found in {personas_dir}", file=sys.stderr)
    sys.exit(0)

generated = 0
for pfile in persona_files:
    try:
        content = pfile.read_text()
    except Exception as e:
        print(f"  Warning: cannot read {pfile}: {e}", file=sys.stderr)
        continue

    frontmatter = parse_frontmatter(content)
    terminal_id = frontmatter.get("name", "").strip()
    if not terminal_id:
        print(f"  Warning: no 'name' field in {pfile.name} — skipping", file=sys.stderr)
        continue

    identity = parse_core_identity(content)
    frontmatter_desc = frontmatter.get("description", "")
    session_desc     = make_session_desc(team_id, terminal_id, frontmatter_desc)
    location         = make_location(team_id, identity["location"])

    # Resolve window names: try persona frontmatter name first, then filename character
    filename_parts = pfile.stem.replace("_persona", "").split("_")
    char_name = filename_parts[1] if len(filename_parts) >= 2 else terminal_id
    windows = agent_windows.get(terminal_id) or agent_windows.get(char_name) or []

    script_text = generate_script(terminal_id, identity, windows, frontmatter, session_desc, location, atf_dir)

    out_path = scripts_dir / f"{team_id}-{terminal_id}-startup.sh"
    try:
        out_path.write_text(script_text)
        out_path.chmod(0o755)
        print(f"  ✓ {out_path.name}")
        generated += 1
    except Exception as e:
        print(f"  Warning: cannot write {out_path}: {e}", file=sys.stderr)

print(f"  Generated {generated} per-agent startup script(s) in {scripts_dir}")
PYEOF
}

echo "📜 Generating per-agent startup scripts..."
generate_per_agent_startup_scripts
echo ""

# ============================================================================
# GENERATE PER-AGENT ZSHRC FILES
# ============================================================================
#
# Generates ~/.zshrc_<team>_<terminal_id> files for each agent persona found
# in the team's personas directory.  Each file sets up the LCARS-themed zsh
# prompt for one tmux window.
#
# Pattern based on dev-team home-scripts/.zshrc_<team>_<terminal> files.
# Gold standard reference: dev-team/home-scripts/.zshrc_android_bridge
#
# Each generated file contains:
#   1. Header comment (character name, division)
#   2. SESSION_* variables (TITLE, THEME, TYPE, NAME, CODE)
#   3. Unset block — clears all OTHER team theme vars
#   4. Theme export — sets CLAUDE_<SERIES>_THEME="<TERMINAL_ID_UPPER>"
#   5. Common color definitions (team-specific palette)
#   6. Theme selection if-blocks (division → THEME_COLOR / THEME_COLOR_HIGHLIGHT)
#   7. Prompt setup (parse_git_branch, show_worktree, PROMPT)
#   8. TMUX developer / agent name exports
#   9. Source helpers (claude_agent_aliases, worktree-helpers, prompt file)
#  10. wt-project / wt-dev context setup
# ============================================================================

generate_per_agent_zshrc_files() {
    local personas_dir="$AITEAMFORGE_DIR/$TEAM_ID/personas/agents"
    if [[ ! -d "$personas_dir" ]]; then
        personas_dir="$HOMEBREW_TAP_ROOT/share/personas/$TEAM_ID/agents"
    fi
    if [[ ! -d "$personas_dir" ]]; then
        echo "  ⚠️  No personas directory found for $TEAM_ID — skipping zshrc generation"
        return 0
    fi

    python3 - "$personas_dir" "$TEAM_ID" "$HOME" "$AITEAMFORGE_DIR" <<'ZSHRC_PYEOF'
import re
import sys
import os
from pathlib import Path

# ---- Arguments ----
personas_dir  = Path(sys.argv[1])
team_id       = sys.argv[2]
home_dir      = sys.argv[3]
atf_dir       = sys.argv[4]

# -------------------------------------------------------------------------
# Team ID → Claude theme variable name
# Must match statusline-command.sh and LCARS UI routing logic.
# Note: "mainevent" below is the TEAM SLUG (permanent internal identifier), # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
# not org branding.  It is preserved as a team-taxonomy constant regardless
# of which organization owns this install.  See XACA-0139 for context.
# -------------------------------------------------------------------------
TEAM_THEME_VARS = {
    "academy":   "CLAUDE_ACADEMY_THEME",
    "android":   "CLAUDE_TOS_THEME",
    "ios":       "CLAUDE_TNG_THEME",
    "firebase":  "CLAUDE_DS9_THEME",
    "command":   "CLAUDE_COMMAND_THEME",
    "freelance": "CLAUDE_ENT_THEME",
    "finance":   "CLAUDE_FINANCE_THEME",
    # xaca-0139:allowed — "mainevent" is a permanent team slug / theme-var constant, not user-facing org branding
    "mainevent": "CLAUDE_MAINEVENT_THEME",   # team slug — not org branding
    "dns":       "CLAUDE_DNS_THEME",
    "legal":     "CLAUDE_LEGAL_THEME",
    "medical":   "CLAUDE_MEDICAL_THEME",
}
# Default for unknown teams
tid_upper = team_id.upper().replace("-", "_")
theme_var = TEAM_THEME_VARS.get(team_id, f"CLAUDE_{tid_upper}_THEME")

# Lowercase version used in the temp-file path written by the zshrc
# e.g. CLAUDE_TOS_THEME → claude_tos_theme
theme_var_lower = theme_var.lower()

# -------------------------------------------------------------------------
# All known theme variables — every zshrc unsets all except its own
# -------------------------------------------------------------------------
ALL_THEME_VARS = [
    "CLAUDE_ACADEMY_THEME",
    "CLAUDE_TOS_THEME",
    "CLAUDE_TNG_THEME",
    "CLAUDE_DS9_THEME",
    "CLAUDE_ENT_THEME",
    "CLAUDE_COMMAND_THEME",
    # xaca-0139:allowed — env var naming follows CLAUDE_<TEAM_SLUG>_THEME convention; mainevent is a stable team slug
    "CLAUDE_MAINEVENT_THEME",
    "CLAUDE_DNS_THEME",
    "CLAUDE_FINANCE_THEME",
    "CLAUDE_LEGAL_THEME",
    "CLAUDE_MEDICAL_THEME",
]

# -------------------------------------------------------------------------
# Per-team color palette block and theme-selection if-block
# Derived from existing dev-team/home-scripts/.zshrc_<team>_* files.
# -------------------------------------------------------------------------
TEAM_COLORS = {
    "academy": {
        "palette": """\
# Command Red (32nd Century Starfleet Red)
COMMAND_RED='%F{124}'              # Deep red
COMMAND_RED_BRIGHT='%F{160}'       # Brighter red for highlights

# Operations Gold (32nd Century Starfleet Gold)
OPS_GOLD='%F{178}'                 # Mustard gold
OPS_GOLD_DARK='%F{136}'            # Darker gold for contrast

# Sciences Blue (32nd Century Starfleet Blue)
SCIENCES_BLUE='%F{25}'             # Deep blue
SCIENCES_BLUE_BRIGHT='%F{33}'      # Brighter blue""",
        "theme_select": """\
if [[ $SESSION_THEME == "COMMAND" ]]
then
THEME_COLOR=$COMMAND_RED
THEME_COLOR_HIGHLIGHT=$COMMAND_RED_BRIGHT
fi
if [[ $SESSION_THEME == "OPERATIONS" ]]
then
THEME_COLOR=$OPS_GOLD
THEME_COLOR_HIGHLIGHT=$OPS_GOLD_DARK
fi
if [[ $SESSION_THEME == "SCIENCES" ]]
then
THEME_COLOR=$SCIENCES_BLUE
THEME_COLOR_HIGHLIGHT=$SCIENCES_BLUE_BRIGHT
fi""",
    },
    "android": {
        "palette": """\
# Command Gold (Kirk's Bridge)
COMMAND_GOLD='%F{220}'               # Warm gold
COMMAND_GOLD_BRIGHT='%F{226}'        # Brighter gold for highlights

# Science Blue (Spock's Lab)
SCIENCE_BLUE='%F{27}'                # Science blue
SCIENCE_BLUE_BRIGHT='%F{33}'         # Brighter science blue

# Medical Blue (McCoy's Sickbay)
MEDICAL_BLUE='%F{39}'                # Medical blue
MEDICAL_BLUE_BRIGHT='%F{45}'         # Brighter medical blue

# Engineering Red (Scotty's Engineering)
ENGINEERING_RED='%F{160}'            # Engineering red
ENGINEERING_RED_BRIGHT='%F{196}'     # Brighter red

# Operations Gold (Uhura, Chekov, Sulu)
OPERATIONS_GOLD='%F{178}'            # Operations gold
OPERATIONS_GOLD_BRIGHT='%F{184}'     # Brighter operations gold""",
        "theme_select": """\
if [[ $SESSION_THEME == "COMMAND" ]]
then
THEME_COLOR=$COMMAND_GOLD
THEME_COLOR_HIGHLIGHT=$COMMAND_GOLD_BRIGHT
fi
if [[ $SESSION_THEME == "SCIENCE" ]]
then
THEME_COLOR=$SCIENCE_BLUE
THEME_COLOR_HIGHLIGHT=$SCIENCE_BLUE_BRIGHT
fi
if [[ $SESSION_THEME == "MEDICAL" ]]
then
THEME_COLOR=$MEDICAL_BLUE
THEME_COLOR_HIGHLIGHT=$MEDICAL_BLUE_BRIGHT
fi
if [[ $SESSION_THEME == "ENGINEERING" ]]
then
THEME_COLOR=$ENGINEERING_RED
THEME_COLOR_HIGHLIGHT=$ENGINEERING_RED_BRIGHT
fi
if [[ $SESSION_THEME == "COMMUNICATIONS" ]] || [[ $SESSION_THEME == "NAVIGATION" ]] || [[ $SESSION_THEME == "HELM" ]]
then
THEME_COLOR=$OPERATIONS_GOLD
THEME_COLOR_HIGHLIGHT=$OPERATIONS_GOLD_BRIGHT
fi""",
    },
    "ios": {
        "palette": """\
# Command Red/Burgundy (Picard's Bridge)
COMMAND_RED='%F{52}'              # Dark burgundy/maroon
COMMAND_RED_BRIGHT='%F{88}'       # Lighter burgundy for highlights

# Operations Gold (Engineering, Holodeck, Stellar Cartography)
OPS_GOLD='%F{178}'                # Mustard gold
OPS_GOLD_DARK='%F{136}'           # Darker gold for contrast

# Science/Medical Teal (Sickbay, Observation)
SCIENCE_TEAL='%F{30}'             # Teal/cyan
SCIENCE_TEAL_BRIGHT='%F{37}'      # Brighter teal""",
        "theme_select": """\
if [[ $SESSION_THEME == "COMMAND" ]]
then
THEME_COLOR=$COMMAND_RED
THEME_COLOR_HIGHLIGHT=$COMMAND_RED_BRIGHT
fi
if [[ $SESSION_THEME == "OPERATIONS" ]]
then
THEME_COLOR=$OPS_GOLD
THEME_COLOR_HIGHLIGHT=$OPS_GOLD_DARK
fi
if [[ $SESSION_THEME == "SCIENCE" ]]
then
THEME_COLOR=$SCIENCE_TEAL
THEME_COLOR_HIGHLIGHT=$SCIENCE_TEAL_BRIGHT
fi""",
    },
    "firebase": {
        "palette": """\
# Operations Blue/Teal - for firebase-ops
OPS_BLUE='%F{24}'                  # Deep blue
OPS_BLUE_BRIGHT='%F{33}'           # Brighter blue

# Engineering Gold/Amber - for firebase-engineering
ENG_GOLD='%F{214}'                 # Amber/gold
ENG_GOLD_DARK='%F{172}'            # Darker gold

# Security Gray - for firebase-holodeck (Odo's office)
SECURITY_GRAY='%F{240}'            # Dark gray
SECURITY_GRAY_LIGHT='%F{246}'      # Lighter gray

# Science Purple - for firebase-stellar (Dax's lab)
SCIENCE_PURPLE='%F{93}'            # Purple
SCIENCE_PURPLE_BRIGHT='%F{141}'    # Brighter purple

# Medical/Incident Red - for firebase-sickbay
INCIDENT_RED='%F{160}'             # Red
INCIDENT_RED_BRIGHT='%F{196}'      # Bright red

# Promenade Gold - for firebase-promenade (Quark's bar)
PROM_GOLD='%F{220}'                # Warm gold
PROM_GOLD_BRIGHT='%F{226}'         # Bright gold""",
        "theme_select": """\
if [[ $SESSION_THEME == "OPERATIONS" ]]
then
THEME_COLOR=$OPS_BLUE
THEME_COLOR_HIGHLIGHT=$OPS_BLUE_BRIGHT
fi
if [[ $SESSION_THEME == "ENGINEERING" ]]
then
THEME_COLOR=$ENG_GOLD
THEME_COLOR_HIGHLIGHT=$ENG_GOLD_DARK
fi
if [[ $SESSION_THEME == "SECURITY" ]]
then
THEME_COLOR=$SECURITY_GRAY
THEME_COLOR_HIGHLIGHT=$SECURITY_GRAY_LIGHT
fi
if [[ $SESSION_THEME == "SCIENCE" ]]
then
THEME_COLOR=$SCIENCE_PURPLE
THEME_COLOR_HIGHLIGHT=$SCIENCE_PURPLE_BRIGHT
fi
if [[ $SESSION_THEME == "INCIDENT" ]]
then
THEME_COLOR=$INCIDENT_RED
THEME_COLOR_HIGHLIGHT=$INCIDENT_RED_BRIGHT
fi
if [[ $SESSION_THEME == "PROMENADE" ]]
then
THEME_COLOR=$PROM_GOLD
THEME_COLOR_HIGHLIGHT=$PROM_GOLD_BRIGHT
fi""",
    },
    "freelance": {
        "palette": """\
# Command Blue (Enterprise NX-01)
COMMAND_BLUE='%F{24}'              # Deep blue
COMMAND_BLUE_BRIGHT='%F{33}'       # Brighter blue for highlights

# Operations Gold (Early Starfleet)
OPS_GOLD='%F{178}'                # Mustard gold
OPS_GOLD_DARK='%F{136}'           # Darker gold for contrast

# Science/Medical Teal
SCIENCE_TEAL='%F{30}'             # Teal/cyan
SCIENCE_TEAL_BRIGHT='%F{37}'      # Brighter teal""",
        "theme_select": """\
if [[ $SESSION_THEME == "COMMAND" ]]
then
THEME_COLOR=$COMMAND_BLUE
THEME_COLOR_HIGHLIGHT=$COMMAND_BLUE_BRIGHT
fi
if [[ $SESSION_THEME == "OPERATIONS" ]]
then
THEME_COLOR=$OPS_GOLD
THEME_COLOR_HIGHLIGHT=$OPS_GOLD_DARK
fi
if [[ $SESSION_THEME == "SCIENCE" ]]
then
THEME_COLOR=$SCIENCE_TEAL
THEME_COLOR_HIGHLIGHT=$SCIENCE_TEAL_BRIGHT
fi""",
    },
    "command": {
        "palette": """\
# Command Red (Starfleet Command)
COMMAND_RED='%F{124}'              # Deep red
COMMAND_RED_BRIGHT='%F{160}'       # Brighter red for highlights""",
        "theme_select": """\
THEME_COLOR=$COMMAND_RED
THEME_COLOR_HIGHLIGHT=$COMMAND_RED_BRIGHT""",
    },
    "finance": {
        "palette": """\
# Command Gold (Supreme Financial Authority) - for finance-nagus
COMMAND_GOLD='%F{94}'              # Deep amber/gold
COMMAND_GOLD_BRIGHT='%F{220}'      # Bright gold for highlights

# Operations Orange (Commerce & Transactions)
OPS_ORANGE='%F{130}'               # Deep orange
OPS_ORANGE_BRIGHT='%F{208}'        # Bright orange for highlights

# Sciences Green (Data & Analysis)
SCIENCES_GREEN='%F{22}'            # Deep green
SCIENCES_GREEN_BRIGHT='%F{34}'     # Brighter green""",
        "theme_select": """\
if [[ $SESSION_THEME == "COMMAND" ]]
then
THEME_COLOR=$COMMAND_GOLD
THEME_COLOR_HIGHLIGHT=$COMMAND_GOLD_BRIGHT
fi
if [[ $SESSION_THEME == "OPERATIONS" ]]
then
THEME_COLOR=$OPS_ORANGE
THEME_COLOR_HIGHLIGHT=$OPS_ORANGE_BRIGHT
fi
if [[ $SESSION_THEME == "SCIENCE" ]]
then
THEME_COLOR=$SCIENCES_GREEN
THEME_COLOR_HIGHLIGHT=$SCIENCES_GREEN_BRIGHT
fi""",
    },
}

# Generic fallback palette for teams not listed above (legal, medical, dns,
# org-specific teams, or any team slug not in TEAM_COLORS).
GENERIC_COLORS = {
    "palette": """\
# Primary color
PRIMARY_COLOR='%F{33}'             # Blue
PRIMARY_COLOR_BRIGHT='%F{45}'      # Brighter blue

# Secondary color
SECONDARY_COLOR='%F{178}'          # Gold
SECONDARY_COLOR_BRIGHT='%F{220}'   # Brighter gold""",
    "theme_select": """\
THEME_COLOR=$PRIMARY_COLOR
THEME_COLOR_HIGHLIGHT=$PRIMARY_COLOR_BRIGHT""",
}

palette_block = TEAM_COLORS.get(team_id, GENERIC_COLORS)["palette"]
theme_select_block = TEAM_COLORS.get(team_id, GENERIC_COLORS)["theme_select"]

# -------------------------------------------------------------------------
# Division name → SESSION_THEME value
# "Uniform Color: Operations" → SESSION_THEME="OPERATIONS"
# Keeps the existing theme-select if-blocks working correctly.
# -------------------------------------------------------------------------
def division_to_session_theme(division):
    """Map Uniform Color / division text to the SESSION_THEME string.

    GOTCHA: Persona files use "Sciences" (with trailing S) but some teams'
    zshrc theme-select if-blocks expect "SCIENCE" (no trailing S). Academy
    is the exception — it uses "SCIENCES" everywhere. When adding a new
    team, check which spelling its color if-blocks use.
    """
    d = division.upper().strip()
    mapping = {
        "COMMAND":       "COMMAND",
        "OPERATIONS":    "OPERATIONS",
        "ENGINEERING":   "ENGINEERING",
        "SCIENCES":      "SCIENCES",
        "SCIENCE":       "SCIENCE",
        "SECURITY":      "SECURITY",
        "MEDICAL":       "MEDICAL",
        "PROMENADE":     "PROMENADE",
        "INCIDENT":      "INCIDENT",
    }
    # SCIENCES → SCIENCE for non-academy teams (see docstring above)
    if d == "SCIENCES" and team_id not in ("academy",):
        return "SCIENCE"
    return mapping.get(d, "COMMAND")

# -------------------------------------------------------------------------
# Frontmatter + Core Identity parsers
# TODO: These duplicate the parsers in generate_per_agent_startup_scripts().
# Extract to a shared .py helper (e.g. share/scripts/persona_parser.py) to
# eliminate the duplication across both Python heredocs.
# -------------------------------------------------------------------------
def parse_frontmatter(text):
    result = {}
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return result
    for line in lines[1:]:
        stripped = line.strip()
        if stripped == "---":
            break
        if ":" in stripped:
            key, _, val = stripped.partition(":")
            val = val.strip().strip('"').strip("'")
            if key.strip() not in result:
                result[key.strip()] = val
    return result

def find_bold_field(text, field):
    """Extract value from **Field:** or **Field**: pattern in markdown."""
    pat = rf"\*\*{re.escape(field)}\*\*:?\s*(.+)"
    m = re.search(pat, text)
    if m:
        return m.group(1).strip().rstrip("\\").strip()
    pat2 = rf"\*\*{re.escape(field)}:\*\*\s*(.+)"
    m2 = re.search(pat2, text)
    if m2:
        return m2.group(1).strip().rstrip("\\").strip()
    return ""

def parse_core_identity(text):
    """Return dict with developer, role, division from ## Core Identity section."""
    result = {"developer": "", "role": "", "division": ""}
    section_text = text
    for header_pattern in (r"^##\s+Core Identity", r"^##\s+Your Identity"):
        m = re.search(header_pattern, text, re.MULTILINE)
        if m:
            rest = text[m.end():]
            ns = re.search(r"^##\s+", rest, re.MULTILINE)
            section_text = rest[:ns.start()] if ns else rest
            break

    result["developer"] = (
        find_bold_field(section_text, "Name") or
        find_bold_field(section_text, "Character")
    )
    result["role"] = find_bold_field(section_text, "Role")
    result["division"] = (
        find_bold_field(section_text, "Uniform Color") or
        find_bold_field(section_text, "Command Color") or
        find_bold_field(section_text, "Division")
    )
    return result

# -------------------------------------------------------------------------
# Build the unset block — omits the current team's own theme var
# -------------------------------------------------------------------------
unset_lines = "\n".join(
    f"unset {v}" for v in ALL_THEME_VARS if v != theme_var
)

# -------------------------------------------------------------------------
# Main loop — one file per persona
# -------------------------------------------------------------------------
persona_files = sorted(personas_dir.glob("*_persona.md"))
if not persona_files:
    print(f"  Warning: no persona files found in {personas_dir}", file=sys.stderr)
    sys.exit(0)

generated = 0
for pfile in persona_files:
    try:
        content = pfile.read_text()
    except Exception as e:
        print(f"  Warning: cannot read {pfile}: {e}", file=sys.stderr)
        continue

    frontmatter = parse_frontmatter(content)
    terminal_id = frontmatter.get("name", "").strip()
    if not terminal_id:
        print(f"  Warning: no 'name' field in {pfile.name} — skipping", file=sys.stderr)
        continue

    identity = parse_core_identity(content)
    char_name  = identity["developer"] or terminal_id.replace("-", " ").title()
    division   = identity["division"] or "COMMAND"
    session_theme = division_to_session_theme(division)

    # Theme export value = uppercase terminal_id
    theme_value = terminal_id.upper().replace("-", "_")

    # SESSION_TITLE = uppercase terminal_id
    session_title = terminal_id.upper().replace("-", " ")

    # Output path: $HOME/.zshrc_<team>_<terminal_id>
    out_path = Path(home_dir) / f".zshrc_{team_id}_{terminal_id}"

    # Escape single quotes in char_name for shell safety
    char_name_safe = char_name.replace("'", "'\\''")

    zshrc = f'''\
#!/bin/zsh
# {team_id.title()} {terminal_id.title()} - Agent Terminal
# Character: {char_name}
# Division: {division.title()}

SESSION_TITLE='{session_title}'
SESSION_THEME="{session_theme}"
SESSION_TYPE="{team_id}"
SESSION_NAME="{terminal_id}"
SESSION_CODE="${{SESSION_TYPE}}-${{SESSION_NAME}}"

# Clear all other team theme variables (prevents priority conflicts)
{unset_lines}

# Set Claude Code theme (session-specific)
export {theme_var}="{theme_value}"
if [ -n "$TERM_SESSION_ID" ]; then
    echo "{theme_value}" > ~/.{theme_var_lower}_${{TERM_SESSION_ID}}
else
    echo "{theme_value}" > ~/.{theme_var_lower}
fi

# Common colors
BLACK='%F{{black}}'
WHITE='%F{{white}}'
GRAY='%F{{245}}'
RESET='%f%b'
YELLOW='%F{{yellow}}'
CYAN='%F{{cyan}}'
GREEN='%F{{green}}'
RED='%F{{red}}'
MAGENTA='%F{{magenta}}'
BLUE='%F{{blue}}'
BOLD='%B'

{palette_block}

{theme_select_block}

# Common strings
HOSTNAME="%m"
USERNAME="%n"
WORKING_PATH="%~"

# Enable command substitution in prompt
setopt PROMPT_SUBST

# Git branch function
parse_git_branch() {{
    git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \\(.*\\)/(\\1)/'
}}

SESSION_COLOR=$RESET
SESSION_STATUS=''

# Worktree indicator function
show_worktree() {{
    if [ -n "$CURRENT_WORKTREE" ]; then
        echo "🌿${{CURRENT_WORKTREE}}"
    fi
}}

# Custom prompt (with worktree support)
PROMPT='${{THEME_COLOR_HIGHLIGHT}}┌─[${{WHITE}}${{BOLD}}${{SESSION_TITLE}}${{RESET}}${{THEME_COLOR_HIGHLIGHT}}]─[${{GREEN}}$(show_worktree)${{THEME_COLOR_HIGHLIGHT}}]─[${{YELLOW}}${{USERNAME}}${{THEME_COLOR_HIGHLIGHT}}@${{CYAN}}${{HOSTNAME}}${{THEME_COLOR_HIGHLIGHT}}]─[${{WHITE}}${{WORKING_PATH}}${{THEME_COLOR_HIGHLIGHT}}]${{YELLOW}}$(parse_git_branch)${{SESSION_COLOR}}${{SESSION_STATUS}}${{RESET}}
${{THEME_COLOR_HIGHLIGHT}}└─➤${{RESET}} '

# Set session-specific developer for tmux status bar
if [ -n "$TMUX" ]; then
    tmux set-option @developer "{char_name_safe}"
    tmux set-option @claude_agent "{team_id}-{terminal_id}"
fi

# Source shared helpers (prefer AITEAMFORGE_DIR, fall back gracefully)
_ATFD="${{AITEAMFORGE_DIR:-$HOME/aiteamforge}}"
[[ -f "$_ATFD/claude_agent_aliases.sh" ]]   && source "$_ATFD/claude_agent_aliases.sh"
[[ -f "$_ATFD/claude_code_cc_aliases.sh" ]] && source "$_ATFD/claude_code_cc_aliases.sh"
[[ -f "$_ATFD/worktree-helpers.sh" ]]       && source "$_ATFD/worktree-helpers.sh"

# Load agent prompt (character persona for Claude Code)
# .txt files are plain prompt text — read directly into the env var rather than
# `source` (which would try to execute the prose as shell and choke on heredocs / quoting).
_PROMPT_FILE="$_ATFD/${{SESSION_TYPE}}/scripts/prompts/${{SESSION_CODE}}-prompt.txt"
[[ -f "$_PROMPT_FILE" ]] && CLAUDE_SYSTEM_PROMPT="$(<"$_PROMPT_FILE")" && export CLAUDE_SYSTEM_PROMPT

# Auto-set worktree project context
wt-project $SESSION_TYPE > /dev/null 2>&1 || true
wt-dev > /dev/null 2>&1 || true
'''

    try:
        out_path.write_text(zshrc)
        # zshrc files are read by the shell, not executed — no chmod +x needed
        print(f"  ✓ {out_path.name}")
        generated += 1
    except Exception as e:
        print(f"  Warning: cannot write {out_path}: {e}", file=sys.stderr)

print(f"  Generated {generated} zshrc file(s)")
ZSHRC_PYEOF
}

echo "🖥️  Generating per-agent zshrc files..."
echo "  Note: Reinstalling will overwrite existing zshrc files — back up any manual customizations first."
generate_per_agent_zshrc_files
echo ""

# ============================================================================
# INSTALLATION SUMMARY
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Team Installation Complete: $TEAM_NAME"
echo "  Template: $TEAM_ID  |  Instance: $INSTANCE_ID"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Team directory: $TEAM_DIR"
echo "Startup script: $AITEAMFORGE_DIR/$TEAM_STARTUP_SCRIPT"
echo "Connect script: $AITEAMFORGE_DIR/${INSTANCE_ID}-connect.sh"
echo "Shutdown script: $AITEAMFORGE_DIR/$TEAM_SHUTDOWN_SCRIPT"
echo "Kanban board: $TEAM_BOARD"
echo ""
echo "Agent aliases:"
_first_agent_func=""
for agent in "${TEAM_AGENTS[@]}"; do
    _func="$(_agent_function_name "$TEAM_ID" "$agent")"
    echo "  ${_func}"
    [[ -z "$_first_agent_func" ]] && _first_agent_func="$_func"
done
echo ""
echo "Next steps:"
echo "  1. Source the aliases file: source $ALIASES_FILE"
echo "  2. Launch the team: $AITEAMFORGE_DIR/$TEAM_STARTUP_SCRIPT"
echo "  3. Start working with agents: ${_first_agent_func}"
echo ""
