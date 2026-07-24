#!/bin/bash
# common.sh
# Bash-compatible utility functions for aiteamforge installer scripts
# Provides basic output functions: header, info, success, warning, error, prompt_yes_no

# Guard against double-sourcing (readonly errors in subshells)
if [[ -n "${_COMMON_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_COMMON_SH_LOADED=1

#──────────────────────────────────────────────────────────────────────────────
# launchctl guard — skips real GUI-domain side effects under test/sandbox.
# Set AITEAMFORGE_SKIP_LAUNCHCTL=1 to suppress mutating load/unload/bootstrap/
# bootout/enable/disable/kickstart. Read-only operations (launchctl list | grep …)
# are NOT routed here — they are harmless and the test PATH mock handles them.
# Canonical home for the wrapper (XACA-0683); originally introduced inline in
# install-fleet-monitor.sh + validate-install.sh by XACA-0682.
#──────────────────────────────────────────────────────────────────────────────
_aitf_launchctl() {
    if [ "${AITEAMFORGE_SKIP_LAUNCHCTL:-}" = "1" ]; then
        return 0
    fi
    launchctl "$@"
}

# ANSI color codes
COLOR_RESET='\033[0m'
COLOR_BOLD='\033[1m'
COLOR_GREEN='\033[38;5;46m'
COLOR_RED='\033[38;5;196m'
COLOR_AMBER='\033[38;5;214m'
COLOR_BLUE='\033[38;5;33m'
COLOR_LILAC='\033[38;5;183m'

# Semantic colors (for compatibility with wizard-ui.sh callers)
COLOR_SUCCESS="${COLOR_GREEN}"
COLOR_ERROR="${COLOR_RED}"
COLOR_WARNING="${COLOR_AMBER}"
COLOR_INFO="${COLOR_BLUE}"

# Print colored message
print_colored() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${COLOR_RESET}"
}

# Print header (main header)
header() {
    local text="$1"
    echo ""
    print_colored "${COLOR_AMBER}${COLOR_BOLD}" "═══════════════════════════════════════════════════════════════════════════"
    print_colored "${COLOR_AMBER}${COLOR_BOLD}" "  $text"
    print_colored "${COLOR_AMBER}${COLOR_BOLD}" "═══════════════════════════════════════════════════════════════════════════"
    echo ""
}

# Print header (compatibility alias)
print_header() {
    header "$1"
}

# Print section header
print_section() {
    local text="$1"
    echo ""
    print_colored "${COLOR_BLUE}${COLOR_BOLD}" "───────────────────────────────────────────────────────────────────────────"
    print_colored "${COLOR_BLUE}${COLOR_BOLD}" "  $text"
    print_colored "${COLOR_BLUE}${COLOR_BOLD}" "───────────────────────────────────────────────────────────────────────────"
    echo ""
}

# Print with explicit color (for backward compatibility)
print_color() {
    local color="$1"
    local text="$2"
    print_colored "$color" "$text"
}

# Print info message
info() {
    print_colored "${COLOR_BLUE}" "ℹ $1"
}

# Print success message
success() {
    print_colored "${COLOR_GREEN}" "✓ $1"
}

# Print warning message
warning() {
    print_colored "${COLOR_AMBER}" "⚠ $1"
}

# Print error message
error() {
    print_colored "${COLOR_RED}" "✗ $1" >&2
}

# Prompt for yes/no answer
# Usage: prompt_yes_no <question> [default]
# Returns: 0 for yes, 1 for no
prompt_yes_no() {
    local question="$1"
    local default="${2:-n}"
    local prompt="[y/n]"

    if [ "$default" = "y" ]; then
        prompt="[Y/n]"
    elif [ "$default" = "n" ]; then
        prompt="[y/N]"
    fi

    while true; do
        print_colored "${COLOR_AMBER}" "$question $prompt"
        read -r answer

        # Use default if empty
        if [ -z "$answer" ]; then
            answer="$default"
        fi

        case "$answer" in
            [Yy]|[Yy][Ee][Ss])
                return 0
                ;;
            [Nn]|[Nn][Oo])
                return 1
                ;;
            *)
                error "Please answer 'y' or 'n'"
                ;;
        esac
    done
}

#──────────────────────────────────────────────────────────────────────────────
# Compatibility Aliases
#──────────────────────────────────────────────────────────────────────────────

# Aliases for scripts that use print_ prefix
print_success() { success "$@"; }
print_error() { error "$@"; }
print_warning() { warning "$@"; }
print_info() { info "$@"; }

# Alias for scripts that use section without print_ prefix
section() { print_section "$@"; }

# Alias for scripts that use warn instead of warning
warn() { warning "$@"; }

#──────────────────────────────────────────────────────────────────────────────
# Legacy LaunchAgent teardown — com.aiteamforge.lcars-runatload (XACA-0763-005)
#──────────────────────────────────────────────────────────────────────────────
# lcars-runatload was retired: XACA-0626 Defect C already relaxed lcars-health's
# tmux gate, so com.aiteamforge.lcars-health (RunAtLoad=true) now covers the
# post-reboot cold-start case runatload existed for, making it a redundant
# fourth writer to LCARS lifecycle state.
#
# Deleting the template and the install-side wiring (XACA-0763-005) only stops
# NEW installs from getting the agent. Every machine that already installed it
# has com.aiteamforge.lcars-runatload.plist LOADED in the GUI domain right now
# and will keep firing `aiteamforge start lcars` at every login forever unless
# something tears it down. This function is that something: it is wired into
# BOTH `aiteamforge upgrade` and `aiteamforge migrate` (not just `aiteamforge
# uninstall`, which most machines never run) so the whole fleet self-heals on
# the next routine upgrade/migrate instead of carrying the orphaned agent
# indefinitely.
#
# Idempotent + silent when the agent was never installed. Honors a dry-run
# flag so callers under --dry-run only report intent.
# Usage: remove_legacy_lcars_runatload_agent [launchagents_dir] [dry_run(true|false)]
remove_legacy_lcars_runatload_agent() {
    local launchagents_dir="${1:-$HOME/Library/LaunchAgents}"
    local dry_run="${2:-false}"
    local label="com.aiteamforge.lcars-runatload"
    local plist="${launchagents_dir}/${label}.plist"

    # Probe the LOADED job, not just the plist file. Removing the plist without a
    # bootout leaves the job registered and firing in the live launchd session;
    # guarding on `[ -f "$plist" ]` alone would then skip that machine on every
    # future upgrade and the orphan would never be reaped. Check both, act on
    # either. `launchctl print` is read-only, so it is not routed through
    # _aitf_launchctl (see that wrapper's header).
    local loaded=false
    if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
        loaded=true
    fi

    if [ "$loaded" != "true" ] && [ ! -f "$plist" ]; then
        return 0
    fi

    if [ "$dry_run" = "true" ]; then
        echo "[DRY RUN] Would remove legacy LaunchAgent: ${label}"
        return 0
    fi

    # Prefer bootout (modern, synchronous unregister from the GUI domain);
    # fall back to unload for older launchd/macOS where bootout semantics
    # differ. Both are no-ops (idempotent) if the job isn't currently loaded.
    if [ "$loaded" = "true" ]; then
        _aitf_launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null \
            || _aitf_launchctl unload "$plist" 2>/dev/null || true
    fi

    rm -f "$plist"
    success "Removed legacy LaunchAgent: ${label} (retired, XACA-0763-005)"
}

#──────────────────────────────────────────────────────────────────────────────
# Homebrew tap-trust helpers (XACA-0676)
#──────────────────────────────────────────────────────────────────────────────
# Recent Homebrew gates formula loading behind tap-trust when
# $HOMEBREW_REQUIRE_TAP_TRUST is set. On a gated box an UNTRUSTED tap makes brew
# silently refuse to load the formula, so `brew outdated`/`brew upgrade` no-op and
# the machine rots on an old version while reporting success. These helpers let the
# installer/upgrade trust the tap (idempotent) and let any command DETECT the
# refused-load condition so it can warn loudly instead of faking "up to date".
#
# Tap name resolves via ${AITF_TAP_NAME:-$AITF_TAP_NAME_DEFAULT:-doublenode/aiteamforge}
# so these work whether or not libexec/lib/constants.sh was sourced first.

_aitf_tap_name() {
    echo "${AITF_TAP_NAME:-${AITF_TAP_NAME_DEFAULT:-doublenode/aiteamforge}}"
}

# tap_load_refused — return 0 (true) when Homebrew is refusing to load the
# aiteamforge formula because the tap is untrusted; 1 otherwise (incl. no brew).
# Probes the formula load directly so it reflects the live trust gate rather than
# guessing from config.
tap_load_refused() {
    command -v brew >/dev/null 2>&1 || return 1
    brew info aiteamforge 2>&1 \
        | grep -qiE "untrusted tap|refus(e|ing) to load"
}

# ensure_tap_trusted — idempotently trust the aiteamforge tap so Homebrew can
# load the formula. Safe to call unconditionally: no-op success when already
# trusted, and a quiet non-zero (logged by caller) on older Homebrew that lacks
# the `brew trust` subcommand. Never aborts the caller.
# Returns 0 on success (or trust not needed), 1 if the trust attempt failed.
ensure_tap_trusted() {
    command -v brew >/dev/null 2>&1 || return 0
    brew trust --tap "$(_aitf_tap_name)" >/dev/null 2>&1
}
