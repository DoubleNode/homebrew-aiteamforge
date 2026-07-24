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
# Live LCARS process inspection (XACA-0799)
#──────────────────────────────────────────────────────────────────────────────
# aiteamforge_lcars_running_ports
# Prints the port of every LCARS server currently running on this box, one per
# line, deduplicated and numerically sorted. Prints nothing (exit 0) when none
# are running.
#
# XACA-0799: `aiteamforge stop` reaps EVERY `server.py <port>` on the box — that
# is deliberate and documented (see the kill-all note in aiteamforge-stop.sh) —
# but `aiteamforge start` only launches teams listed in .aiteamforge-config's
# .teams[]. On a machine where most LCARS servers were started by their own
# per-team *-startup.sh, those teams are NOT in .teams[], so a restart killed
# every server and brought back only the configured handful. The rest stayed
# down until the 300s lcars-health check healed them — a fleet-wide LCARS
# outage of up to 5 minutes on every restart (observed on M4Mini after the
# v0.17.7 upgrade: 8 killed, 1 restarted).
#
# Snapshotting the live ports BEFORE teardown is what lets start restore exactly
# the set stop is about to take down.
#
# CONTRACT: the pgrep pattern below MUST stay in lockstep with stop_lcars()'s
# matcher in libexec/commands/aiteamforge-stop.sh. This function's entire
# meaning is "the set stop is about to kill" — if that matcher is ever changed,
# change this one identically or restart silently stops restoring the delta.
aiteamforge_lcars_running_ports() {
    local pids pid args port
    pids=$(pgrep -f "server\.py [0-9]" 2>/dev/null || true)
    if [ -z "$pids" ]; then
        return 0
    fi

    # Iterate line-by-line via read rather than `for pid in $pids`. The
    # word-splitting form is NOT portable: zsh does not split unquoted parameter
    # expansions, so under zsh the loop would run ONCE with the entire multi-line
    # PID blob as a single value, every ps lookup would fail, and this function
    # would silently return nothing while still exiting 0 — a vacuous success
    # that hands `restart` an empty restore set and quietly reinstates the very
    # outage this fixes. read -r is unambiguous under both bash and zsh.
    printf '%s\n' "$pids" | while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        args=$(ps -o args= -p "$pid" 2>/dev/null) || continue
        [ -z "$args" ] && continue
        # Extract the numeric argument immediately following server.py — that is
        # the bind port. Anchored on server.py so an unrelated numeric arg
        # elsewhere in the cmdline cannot be mistaken for the port.
        port=$(aiteamforge_extract_lcars_port "$args")
        [ -n "$port" ] && echo "$port"
    done | sort -un
}

# aiteamforge_extract_lcars_port <ps-args-string>
# Prints the LCARS bind port carried in a `server.py` command line, or nothing.
#
# XACA-0799-006: split out of aiteamforge_lcars_running_ports so the extraction
# RULE is exercised directly by the suite rather than re-implemented inside a
# test case. A test that re-types the production sed proves only that the test's
# own copy works, and keeps passing after production drifts away from it.
#
# Anchored on `server.py`, taking the token IMMEDIATELY after it. A right-to-left
# "last all-numeric token" scan looks equivalent and is not: it returns the LAST
# number on the line, so any trailing numeric argument (`server.py 8203 --workers
# 2`) yields 2 and the snapshot records a port no team owns. Anchoring is what
# actually tolerates trailing flags.
aiteamforge_extract_lcars_port() {
    printf '%s\n' "${1:-}" \
        | sed -n 's/.*server\.py[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p'
}

# aiteamforge_restore_key_is_new <candidate-instance-id> <configured-id>...
# Returns 0 if <candidate> is NOT already represented among the configured ids,
# 1 if it is (i.e. it would be a duplicate start).
#
# XACA-0799-001: split out of start_lcars()'s restore loop. Inline there the
# dedupe was only reachable by launching real servers, so the suite could assert
# nothing about it beyond a presence-grep for an identifier — and a review-round
# mutation pass proved that inadequate by DELETING the dedupe with the suite
# still green.
#
# Comparison happens in BOTH raw and resolved space on purpose: `.teams[]` holds
# BASE ids ("finance") while the reverse lookup returns the registry INSTANCE id
# ("finance-personal"). A raw-only comparison queues the same team twice and
# races two servers onto one port — XACA-0792 is exactly this base-vs-instance
# split.
aiteamforge_restore_key_is_new() {
    local candidate="${1:-}"
    shift || true
    [ -z "$candidate" ] && return 1

    local seen seen_key
    for seen in "$@"; do
        [ -z "$seen" ] && continue
        [ "$seen" = "$candidate" ] && return 1
        seen_key=$(aiteamforge_resolve_team_key "$seen" 2>/dev/null) || seen_key=""
        [ -n "$seen_key" ] && [ "$seen_key" = "$candidate" ] && return 1
    done
    return 0
}

# aiteamforge_build_restore_union <configured-ids> <restore-ports> <port-map>
# Prints the FINAL launch list, one team id per line: the configured ids followed
# by any team a restore port maps to that is not already represented.
# Warnings for unmappable ports go to stderr; they are never added to the list.
#
# XACA-0799-015/016/017/020: this whole decision used to live inline in
# start_lcars()'s restore loop, where the only way to reach it was to launch real
# servers. A review-round mutation pass showed four separate regressions passing
# 29/29 with the suite fully green: deleting the dedupe CALL (the previous round
# extracted the predicate but left its call site unpinned — the wrong half),
# turning `teams+=` into `teams=` so a restore REPLACED the configured list
# instead of adding to it, replacing the unowned-port warn+continue with a
# synthesized id, and swapping the safe `read -ra` split for `($VAR)`.
#
# As a pure function every one of those is directly assertable, and the caller
# keeps only the parts that genuinely need the process: launching and printing.
aiteamforge_build_restore_union() {
    local configured="${1:-}"
    local ports="${2:-}"
    local port_map="${3:-}"

    local -a out=()
    local t
    # Split with read -ra, never `out=($configured)`: the unquoted-array form is
    # subject to glob expansion, and zsh does not word-split it at all.
    read -ra out <<< "$configured"

    local -a plist=()
    read -ra plist <<< "$ports"

    local pt team
    for pt in ${plist[@]+"${plist[@]}"}; do
        [ -z "$pt" ] && continue
        team=$(aiteamforge_team_for_lcars_port_in_map "$pt" "$port_map" 2>/dev/null) || team=""
        if [ -z "$team" ]; then
            # Recorded and surfaced, never started: LCARS_TEAM is mandatory since
            # XACA-0555, so a server on an unregistered port cannot be relaunched.
            printf 'LCARS was serving on port %s but no team owns it in the registry — not restoring\n' \
                "$pt" >&2
            continue
        fi
        if aiteamforge_restore_key_is_new "$team" ${out[@]+"${out[@]}"}; then
            out+=("$team")
        fi
    done

    for t in ${out[@]+"${out[@]}"}; do
        [ -n "$t" ] && printf '%s\n' "$t"
    done
    return 0
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
