#!/bin/bash
# validate-install.sh
# Post-install validation for AITeamForge
# Checks that all installed components landed correctly after setup
#
# Usage: source this file, then call validate_installation [install_dir]
# Returns: 0 if all required checks pass, 1 if any required checks fail
#
# Output: structured pass/warn/fail summary with remediation hints

# Guard against double-sourcing
if [[ -n "${_VALIDATE_INSTALL_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_VALIDATE_INSTALL_SH_LOADED=1

# Resolve tap-owned Python venv interpreter ($AITEAMFORGE_PYTHON).
# python-env.sh lives alongside this file in the same lib/ directory.
_atf_validate_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# shellcheck source=./python-env.sh
[ -f "$_atf_validate_script_dir/python-env.sh" ] && . "$_atf_validate_script_dir/python-env.sh" 2>/dev/null || true
# shellcheck source=./common.sh
[ -f "$_atf_validate_script_dir/common.sh" ] && . "$_atf_validate_script_dir/common.sh" 2>/dev/null || true
unset _atf_validate_script_dir

# ─── Colors (safe to redefine if not already set) ───────────────────────────

_VAL_RED='\033[0;31m'
_VAL_GREEN='\033[0;32m'
_VAL_YELLOW='\033[1;33m'
_VAL_CYAN='\033[0;36m'
_VAL_BOLD='\033[1m'
_VAL_NC='\033[0m'

# ─── Counters ────────────────────────────────────────────────────────────────

_VAL_PASS=0
_VAL_WARN=0
_VAL_FAIL=0
_VAL_FAIL_MSGS=()
_VAL_WARN_MSGS=()

# ─── Internal helpers ─────────────────────────────────────────────────────────

_val_pass() {
    echo -e "  ${_VAL_GREEN}✓${_VAL_NC} $1"
    _VAL_PASS=$((_VAL_PASS + 1))
}

_val_warn() {
    local msg="$1"
    local hint="${2:-}"
    echo -e "  ${_VAL_YELLOW}⚠${_VAL_NC} ${msg}"
    [ -n "$hint" ] && echo -e "    ${_VAL_CYAN}Fix:${_VAL_NC} ${hint}"
    _VAL_WARN=$((_VAL_WARN + 1))
    _VAL_WARN_MSGS+=("$msg")
}

_val_fail() {
    local msg="$1"
    local hint="${2:-}"
    echo -e "  ${_VAL_RED}✗${_VAL_NC} ${msg}"
    [ -n "$hint" ] && echo -e "    ${_VAL_CYAN}Fix:${_VAL_NC} ${hint}"
    _VAL_FAIL=$((_VAL_FAIL + 1))
    _VAL_FAIL_MSGS+=("$msg")
}

_val_section() {
    echo ""
    echo -e "${_VAL_BOLD}${_VAL_CYAN}$1${_VAL_NC}"
    echo "  ─────────────────────────────────────────────────────"
}

_file_exists_x() {
    local path="$1"
    [ -f "$path" ] && [ -x "$path" ]
}

# ─── Reset counters (call before each validation run) ────────────────────────

_val_reset() {
    _VAL_PASS=0
    _VAL_WARN=0
    _VAL_FAIL=0
    _VAL_FAIL_MSGS=()
    _VAL_WARN_MSGS=()
}

# ─── Check: Config file exists and is valid JSON ─────────────────────────────

_val_check_config() {
    local install_dir="$1"
    local config="${install_dir}/.aiteamforge-config"

    _val_section "Installation Config"

    if [ ! -f "$config" ]; then
        _val_fail "Config file missing: ${config}" \
            "Run: aiteamforge setup"
        return
    fi
    _val_pass "Config file exists"

    if command -v jq &>/dev/null; then
        if jq empty "$config" 2>/dev/null; then
            _val_pass "Config file is valid JSON"
        else
            _val_fail "Config file is malformed JSON" \
                "Run: aiteamforge setup --upgrade  (will regenerate config)"
        fi

        # Validate required fields
        local version
        version="$(jq -r '.version // empty' "$config" 2>/dev/null || true)"
        if [ -n "$version" ]; then
            _val_pass "Config version: ${version}"
        else
            _val_warn "Config missing version field"
        fi

        local install_d
        install_d="$(jq -r '.install_dir // empty' "$config" 2>/dev/null || true)"
        if [ -n "$install_d" ]; then
            _val_pass "Config install_dir: ${install_d}"
        else
            _val_warn "Config missing install_dir field"
        fi
    else
        _val_warn "jq not installed — cannot validate JSON config structure"
    fi
}

# ─── Check: Core install directory structure ──────────────────────────────────

_val_check_install_dir() {
    local install_dir="$1"

    _val_section "Core Directory Structure"

    if [ ! -d "$install_dir" ]; then
        _val_fail "Install directory missing: ${install_dir}" \
            "Run: aiteamforge setup"
        return
    fi
    _val_pass "Install directory: ${install_dir}"

    # Directories that should always be present after setup
    local required_dirs=(
        "templates"
        "docs"
        "scripts"
        "avatars"
    )

    for d in "${required_dirs[@]}"; do
        if [ -d "${install_dir}/${d}" ]; then
            _val_pass "${d}/"
        else
            _val_warn "${d}/ missing" \
                "Run: aiteamforge setup --upgrade"
        fi
    done
}

# ─── Check: Helper scripts are present and executable ────────────────────────

_val_check_scripts() {
    local install_dir="$1"
    local scripts_dir="${install_dir}/scripts"

    _val_section "Helper Scripts"

    if [ ! -d "$scripts_dir" ]; then
        _val_fail "scripts/ directory missing" \
            "Run: aiteamforge setup --upgrade"
        return
    fi

    # Key scripts that must be present and executable
    local required_scripts=(
        "iterm2_window_manager.py"
        "agent-panel-display.sh"
        "display-agent-avatar.sh"
        "lcars-tmp-dir.sh"
        "init-agent-panel-json.py"
        # XACA-0796: the kb-msg relay entrypoints. fleet-reporter.sh resolves
        # msg-client.sh as a SIBLING and Guard 1 tests `[ -x "$client" ]`, so
        # both must be present AND executable for the relay to run at all.
        "fleet-reporter.sh"
        "msg-client.sh"
    )

    for script in "${required_scripts[@]}"; do
        local path="${scripts_dir}/${script}"
        if [ ! -f "$path" ]; then
            _val_warn "${script} missing from scripts/"  \
                "Run: aiteamforge setup --upgrade"
        elif [ ! -x "$path" ]; then
            _val_warn "${script} not executable" \
                "Run: chmod +x '${path}'"
        else
            _val_pass "${script} (executable)"
        fi
    done

    # XACA-0796: non-executed relay payload — presence only, NO executable check.
    # These have no shebang and are never exec'd directly (msg-client.js is
    # reached via `exec node`, vault-keygen.js via require(), package.json is a
    # manifest), so asserting +x here would demand a mode bit the installer
    # deliberately does not set.
    #
    # Why doctor checks these at all: the original XACA-0796 defect was an
    # install-time ALLOWLIST GAP — files mirrored into share/ but never copied
    # to scripts/. That class is invisible to a check that only looks at
    # entrypoints, because the entrypoint is present and it is the transitive
    # sibling that is missing. Checking the payload is what makes a recurrence
    # detectable by `aiteamforge doctor` instead of surfacing as a silently
    # swallowed MODULE_NOT_FOUND every reporter cycle.
    local required_relay_data=(
        "msg-client.js"
        "vault-keygen.js"
        "package.json"
        "package-lock.json"
    )

    for datafile in "${required_relay_data[@]}"; do
        local dpath="${scripts_dir}/${datafile}"
        if [ ! -f "$dpath" ]; then
            _val_warn "${datafile} missing from scripts/ (kb-msg relay will fail)" \
                "Run: aiteamforge setup --upgrade"
        else
            _val_pass "${datafile} (present)"
        fi
    done

    # Root-level backward-compat copy of window manager
    local root_wm="${install_dir}/iterm2_window_manager.py"
    if [ -f "$root_wm" ]; then
        _val_pass "iterm2_window_manager.py (root copy)"
    else
        _val_warn "iterm2_window_manager.py missing from install root" \
            "Run: cp '${scripts_dir}/iterm2_window_manager.py' '${install_dir}/iterm2_window_manager.py'"
    fi
}

# ─── Check: Team directories have required structure ─────────────────────────

_val_check_teams() {
    local install_dir="$1"
    local config="${install_dir}/.aiteamforge-config"

    _val_section "Team Directories"

    # Read team list from config
    local teams=()
    if command -v jq &>/dev/null && [ -f "$config" ]; then
        while IFS= read -r t; do
            [ -n "$t" ] && teams+=("$t")
        done < <(jq -r '.teams[]? // empty' "$config" 2>/dev/null)
    fi

    if [ ${#teams[@]} -eq 0 ]; then
        _val_warn "No teams found in config — skipping team checks"
        return
    fi

    local team_paths_present=false
    if command -v jq &>/dev/null && [ -f "$config" ]; then
        local tp_count
        tp_count="$(jq '.team_paths | length' "$config" 2>/dev/null || echo 0)"
        [ "${tp_count:-0}" -gt 0 ] && team_paths_present=true
    fi

    for team_id in "${teams[@]}"; do
        echo ""
        echo -e "  ${_VAL_BOLD}Team: ${team_id}${_VAL_NC}"

        # Determine team working dir from config's team_paths
        local team_dir=""
        if [ "$team_paths_present" = true ] && command -v jq &>/dev/null; then
            team_dir="$(jq -r --arg t "$team_id" '.team_paths[$t].working_dir // empty' "$config" 2>/dev/null || true)"
        fi

        # Fallback to install_dir/<team_id>
        if [ -z "$team_dir" ]; then
            team_dir="${install_dir}/${team_id}"
        fi

        if [ ! -d "$team_dir" ]; then
            _val_fail "  Team directory missing: ${team_dir}" \
                "Run: aiteamforge setup --upgrade"
            continue
        fi
        _val_pass "  Directory: ${team_dir}"

        # Kanban board — can be at team_dir/kanban/ or install_dir/kanban/
        local kanban_found=false
        local kanban_locations=(
            "${team_dir}/kanban/${team_id}-board.json"
            "${install_dir}/kanban/${team_id}-board.json"
        )
        for kb in "${kanban_locations[@]}"; do
            if [ -f "$kb" ]; then
                _val_pass "  Kanban board: ${kb##*/}"
                kanban_found=true
                break
            fi
        done
        if [ "$kanban_found" = false ]; then
            _val_warn "  Kanban board missing (${team_id}-board.json)" \
                "Run: aiteamforge setup --upgrade"
        fi

        # Personas directory
        local personas_dir="${team_dir}/personas"
        if [ -d "$personas_dir" ]; then
            local agent_count
            agent_count="$(find "$personas_dir" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
            if [ "${agent_count:-0}" -gt 0 ]; then
                _val_pass "  Personas: ${agent_count} agent file(s)"
            else
                _val_warn "  Personas directory empty — no agent .md files" \
                    "Run: aiteamforge setup --upgrade"
            fi
        else
            _val_warn "  personas/ directory missing" \
                "Run: aiteamforge setup --upgrade"
        fi

        # Startup/shutdown scripts at install_dir root
        local startup_script="${install_dir}/${team_id}-startup.sh"
        local shutdown_script="${install_dir}/${team_id}-shutdown.sh"
        if _file_exists_x "$startup_script"; then
            _val_pass "  ${team_id}-startup.sh (executable)"
        elif [ -f "$startup_script" ]; then
            _val_warn "  ${team_id}-startup.sh not executable" \
                "Run: chmod +x '${startup_script}'"
        else
            _val_warn "  ${team_id}-startup.sh missing" \
                "Run: aiteamforge setup --upgrade"
        fi

        if _file_exists_x "$shutdown_script"; then
            _val_pass "  ${team_id}-shutdown.sh (executable)"
        elif [ -f "$shutdown_script" ]; then
            _val_warn "  ${team_id}-shutdown.sh not executable" \
                "Run: chmod +x '${shutdown_script}'"
        else
            _val_warn "  ${team_id}-shutdown.sh missing" \
                "Run: aiteamforge setup --upgrade"
        fi
    done
}

# ─── Check: LCARS UI files deployed ──────────────────────────────────────────

_val_check_lcars() {
    local install_dir="$1"

    _val_section "LCARS Kanban UI"

    local lcars_dir="${install_dir}/lcars-ui"
    if [ ! -d "$lcars_dir" ]; then
        _val_warn "lcars-ui/ directory missing — LCARS not deployed" \
            "Run: aiteamforge setup --upgrade  (select LCARS Kanban)"
        return
    fi
    _val_pass "lcars-ui/ directory"

    # Core LCARS files
    local lcars_files=(
        "server.py"
        "index.html"
    )

    for f in "${lcars_files[@]}"; do
        if [ -f "${lcars_dir}/${f}" ]; then
            _val_pass "lcars-ui/${f}"
        else
            _val_warn "lcars-ui/${f} missing" \
                "Run: aiteamforge setup --upgrade"
        fi
    done

    # Port config file
    local port_file="${lcars_dir}/.lcars-port"
    if [ -f "$port_file" ]; then
        local port
        port="$(cat "$port_file" 2>/dev/null | tr -d '[:space:]')"
        _val_pass "LCARS port config: ${port:-unknown}"
    else
        _val_warn "LCARS .lcars-port file missing" \
            "Run: aiteamforge setup --upgrade"
    fi

    # Python executable check for server
    if [ -f "${lcars_dir}/server.py" ]; then
        if command -v python3 &>/dev/null; then
            _val_pass "python3 available for LCARS server"
        else
            _val_fail "python3 not found — LCARS server cannot start" \
                "Run: brew install python@3.13"
        fi
    fi
}

# ─── Check: Python venv (tap-owned) ─────────────────────────────────────────

_val_check_python_venv() {
    # install_dir kept as parameter for call-site compatibility; not used here —
    # Python deps now live in the tap-owned venv, not in ~/aiteamforge/.venv.
    local install_dir="$1"

    _val_section "Python Virtual Environment (tap-owned)"

    # AITEAMFORGE_PYTHON is resolved at file-source time via python-env.sh.
    if [ -n "${AITEAMFORGE_PYTHON:-}" ] && [ "$AITEAMFORGE_PYTHON" != "python3" ] \
       && [ -x "$AITEAMFORGE_PYTHON" ]; then
        local atf_py_version
        atf_py_version=$("$AITEAMFORGE_PYTHON" --version 2>&1 | awk '{print $2}')
        _val_pass "Tap-owned venv Python (${atf_py_version:-unknown}) — ${AITEAMFORGE_PYTHON}"

        local venv_pip
        venv_pip="$(dirname "$AITEAMFORGE_PYTHON")/pip"
        if [ -x "$venv_pip" ]; then
            if "$venv_pip" show iterm2 &>/dev/null 2>&1; then
                local iterm2_ver
                iterm2_ver="$("$venv_pip" show iterm2 2>/dev/null | grep '^Version:' | awk '{print $2}')"
                _val_pass "iterm2 package installed (${iterm2_ver:-unknown version})"
            else
                _val_warn "iterm2 package not in tap venv" \
                    "Run: brew reinstall aiteamforge (provisions the tap-owned venv with all Python deps)"
            fi
        else
            _val_warn "pip not found in tap venv — venv may be incomplete" \
                "Run: brew reinstall aiteamforge (provisions the tap-owned venv with all Python deps)"
        fi
    else
        _val_warn "Tap-owned Python venv not found — Python deps unavailable" \
            "Run: brew reinstall aiteamforge (provisions the tap-owned venv with all Python deps)"
    fi
}

# ─── Check: Shell profile integration ────────────────────────────────────────

_val_check_shell_integration() {
    local install_dir="$1"

    _val_section "Shell Profile Integration"

    local zshrc="$HOME/.zshrc"
    if [ ! -f "$zshrc" ]; then
        _val_warn "~/.zshrc not found — cannot verify shell integration" \
            "Create ~/.zshrc and run: aiteamforge setup --upgrade"
        return
    fi

    # Check if aiteamforge is sourced anywhere in zshrc
    if grep -q "aiteamforge" "$zshrc" 2>/dev/null; then
        _val_pass "aiteamforge sourced in ~/.zshrc"
    else
        _val_warn "aiteamforge not found in ~/.zshrc" \
            "Run: aiteamforge setup --upgrade  (select shell environment)"
    fi

    # Check for kanban-helpers sourcing (may be in .zshrc directly or via aiteamforge-env.sh)
    if grep -q "kanban-helpers" "$zshrc" 2>/dev/null; then
        _val_pass "kanban-helpers sourced in ~/.zshrc"
    elif [ -f "${install_dir}/kanban-helpers.sh" ]; then
        _val_pass "kanban-helpers available (sourced via aiteamforge-env.sh)"
    else
        _val_warn "kanban-helpers not sourced in ~/.zshrc" \
            "Run: aiteamforge setup --upgrade  (select shell environment)"
    fi

    # Check that the aliases file exists (even if not yet sourced in current shell)
    local aliases_file="${install_dir}/claude_agent_aliases.sh"
    if [ -f "$aliases_file" ]; then
        _val_pass "Agent aliases file exists"
    else
        _val_warn "Agent aliases file missing: claude_agent_aliases.sh" \
            "Run: aiteamforge setup --upgrade"
    fi
}

# ─── Check: Fleet reporter config (if fleet was installed) ───────────────────

_val_check_fleet() {
    local install_dir="$1"

    local fleet_config="$HOME/.aiteamforge/fleet-config.json"
    local fleet_dir="${install_dir}/fleet-monitor"

    # Only run this check if fleet was actually installed
    if [ ! -f "$fleet_config" ] && [ ! -d "$fleet_dir" ]; then
        return  # Fleet not installed — skip silently
    fi

    _val_section "Fleet Monitor"

    if [ -f "$fleet_config" ]; then
        _val_pass "Fleet reporter config: ${fleet_config}"

        if command -v jq &>/dev/null; then
            if jq empty "$fleet_config" 2>/dev/null; then
                _val_pass "Fleet config is valid JSON"
            else
                _val_warn "Fleet config is malformed JSON"
            fi
        fi
    else
        _val_warn "Fleet reporter config missing: ${fleet_config}"
    fi

    local reporter_script="${fleet_dir}/client/fleet-reporter.sh"
    if [ -f "$reporter_script" ]; then
        if [ -x "$reporter_script" ]; then
            _val_pass "fleet-reporter.sh (executable)"
        else
            _val_warn "fleet-reporter.sh not executable" \
                "Run: chmod +x '${reporter_script}'"
        fi
    else
        _val_warn "fleet-reporter.sh missing" \
            "Run: aiteamforge setup --upgrade  (select Fleet Monitor)"
    fi
}

# ─── Check: LaunchAgents loaded ──────────────────────────────────────────────

_val_check_launchagents() {
    _val_section "LaunchAgents"

    local agents=(
        "com.aiteamforge.kanban-backup"
        "com.aiteamforge.lcars-health"
        "com.aiteamforge.cr-confluence-poller"
    )

    for agent in "${agents[@]}"; do
        local plist="$HOME/Library/LaunchAgents/${agent}.plist"
        if [ ! -f "$plist" ]; then
            _val_warn "${agent} plist missing" \
                "Run: aiteamforge setup --upgrade"
        elif launchctl list 2>/dev/null | grep -q "$agent"; then
            _val_pass "${agent} loaded"
        else
            # Auto-fix: load the plist instead of just warning
            if _aitf_launchctl load "$plist" 2>/dev/null; then
                _val_pass "${agent} loaded (was unloaded — auto-fixed)"
            else
                _val_warn "${agent} plist exists but could not load" \
                    "Run: launchctl load '${plist}'"
            fi
        fi
    done
}

# ─── Main validation entrypoint ───────────────────────────────────────────────

# validate_installation [install_dir]
# install_dir defaults to ~/aiteamforge if not provided
# Returns 0 on all-pass/warn-only, 1 if any failures
validate_installation() {
    local install_dir="${1:-$HOME/aiteamforge}"

    _val_reset

    # Detect install profile — read marker file to suppress cockpit-irrelevant checks
    local _val_profile="full"
    if [ -f "${install_dir}/.install-profile" ]; then
        _val_profile="$(tr -d '[:space:]' < "${install_dir}/.install-profile")"
    fi

    echo ""
    echo -e "${_VAL_BOLD}╔════════════════════════════════════════════════════════════╗${_VAL_NC}"
    echo -e "${_VAL_BOLD}║         AITeamForge - Post-Install Validation              ║${_VAL_NC}"
    echo -e "${_VAL_BOLD}╚════════════════════════════════════════════════════════════╝${_VAL_NC}"
    echo ""
    echo -e "  Validating install at: ${_VAL_CYAN}${install_dir}${_VAL_NC}"
    echo -e "  Install profile:       ${_VAL_CYAN}${_val_profile}${_VAL_NC}"

    _val_check_config      "$install_dir"
    _val_check_install_dir "$install_dir"
    _val_check_scripts     "$install_dir"

    if [ "$_val_profile" = "cockpit" ]; then
        # Cockpit profile: skip team dirs, LCARS server, shell integration,
        # fleet monitor, and LaunchAgents — they are not installed by design.
        # Instead validate cockpit-critical components.
        _val_section "Teams"
        _val_pass "Team directories (not installed — cockpit profile)"

        _val_section "LCARS Kanban UI"
        _val_pass "LCARS server (not installed — cockpit profile; runs on remote host)"

        _val_check_python_venv "$install_dir"

        _val_section "Shell Profile Integration"
        _val_pass "Shell aliases (not installed — cockpit profile)"

        _val_section "Fleet Monitor"
        _val_pass "Fleet monitor (not installed — cockpit profile)"

        _val_section "LaunchAgents"
        _val_pass "LaunchAgents (not installed — cockpit profile)"

        # Cockpit-specific: verify connect scripts exist
        _val_section "Connect Scripts (cockpit)"
        local _cs_count=0
        for _cs in "${install_dir}"/*-connect.sh; do
            [ -f "$_cs" ] && _cs_count=$((_cs_count + 1))
        done
        if [ "$_cs_count" -gt 0 ]; then
            _val_pass "Connect scripts installed (${_cs_count} team(s))"
        else
            _val_fail "No connect scripts found — re-run: aiteamforge setup --cockpit-only"
        fi
    else
        _val_check_teams       "$install_dir"
        _val_check_lcars       "$install_dir"
        _val_check_python_venv "$install_dir"
        _val_check_shell_integration "$install_dir"
        _val_check_fleet       "$install_dir"
        _val_check_launchagents
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    echo -e "${_VAL_BOLD}Validation Summary${_VAL_NC}"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${_VAL_GREEN}Passed:${_VAL_NC}   ${_VAL_PASS}"
    echo -e "  ${_VAL_YELLOW}Warnings:${_VAL_NC} ${_VAL_WARN}"
    echo -e "  ${_VAL_RED}Failed:${_VAL_NC}   ${_VAL_FAIL}"
    echo ""

    if [ $_VAL_FAIL -eq 0 ] && [ $_VAL_WARN -eq 0 ]; then
        echo -e "  ${_VAL_GREEN}Installation verified successfully — everything looks good.${_VAL_NC}"
    elif [ $_VAL_FAIL -eq 0 ]; then
        echo -e "  ${_VAL_YELLOW}Install complete with ${_VAL_WARN} warning(s). Non-critical items may need attention.${_VAL_NC}"
        echo -e "  Run ${_VAL_CYAN}aiteamforge doctor --verbose${_VAL_NC} for detailed diagnostics."
    else
        echo -e "  ${_VAL_RED}Install has ${_VAL_FAIL} failure(s) that need to be resolved.${_VAL_NC}"
        echo ""
        echo -e "  ${_VAL_BOLD}Failed checks:${_VAL_NC}"
        for msg in "${_VAL_FAIL_MSGS[@]}"; do
            echo -e "    ${_VAL_RED}•${_VAL_NC} ${msg}"
        done
        echo ""
        echo -e "  Run ${_VAL_CYAN}aiteamforge doctor${_VAL_NC} for diagnostics."
        echo -e "  Run ${_VAL_CYAN}aiteamforge setup --upgrade${_VAL_NC} to re-run the installer."
    fi

    echo ""

    [ $_VAL_FAIL -eq 0 ]
}
