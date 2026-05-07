#!/bin/bash
#
# CR Lifecycle Monitor — Per-team LaunchAgent installer (XACA-0294-006)
#
# Mirrors the XACA-0350 pattern used by install-cr-confluence-poller (which lives
# as a function in install-kanban.sh).  This standalone script lets operators
# install, uninstall, or check status of the cr-lifecycle-monitor LaunchAgents
# without running the full kanban installer.
#
# Usage:
#   Install: bash install-cr-lifecycle-monitor.sh
#   Uninstall: bash install-cr-lifecycle-monitor.sh --uninstall
#   Status: bash install-cr-lifecycle-monitor.sh --status
#   Dry-run: bash install-cr-lifecycle-monitor.sh --dry-run
#
# After install, verify:
#   launchctl list | grep cr-lifecycle-monitor
#   tail -f ~/Library/Logs/aiteamforge/cr-lifecycle-monitor/<team>.err.log
#
# Logs include scan-cycle summary lines from the daemon.  If a team's
# daemon flap-restarts, check the err.log first; flap-prevention is
# built into the daemon (per-team config errors exit 0, not 1).
#
# CONFIG:
#   Primary:  ~/.config/aiteamforge/cr-automations.json
#   Fallback: ~/.config/aiteamforge/confluence-credentials.json
#
#   If neither file exists, the installer exits 0 with a friendly note.
#   See share/config/cr-automations.json.example for schema.
#
# FAILURE ISOLATION:
#   A broken config for team X exits 0 (daemon flap-prevention); other
#   teams' agents continue running independently.  This mirrors the
#   per-team isolation introduced for cr-confluence-poller in XACA-0350.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source common utilities (provides info/warning/success/error helpers) ─────
COMMON_LIB="$SCRIPT_DIR/../lib/common.sh"
if [ -f "$COMMON_LIB" ]; then
    # shellcheck source=/dev/null
    source "$COMMON_LIB"
else
    # Minimal fallbacks so the script works standalone without the full tap layout
    info()    { echo "[INFO]    $*"; }
    warning() { echo "[WARNING] $*" >&2; }
    success() { echo "[OK]      $*"; }
    error()   { echo "[ERROR]   $*" >&2; exit 1; }
fi

#──────────────────────────────────────────────────────────────────────────────
# Constants
#──────────────────────────────────────────────────────────────────────────────

LABEL_PREFIX="com.aiteamforge.cr-lifecycle-monitor"
DAEMON_SCRIPT_NAME="cr-lifecycle-monitor.py"
LOG_SUBDIR="cr-lifecycle-monitor"
STATUS_TAIL_LINES=20

# Resolve INSTALL_ROOT (two levels up from libexec/installers/)
INSTALL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# AITEAMFORGE_DIR — where the tap installs runtime artifacts
AITEAMFORGE_DIR="${AITEAMFORGE_DIR:-$HOME/.aiteamforge}"

#──────────────────────────────────────────────────────────────────────────────
# Argument parsing
#──────────────────────────────────────────────────────────────────────────────

MODE="install"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --uninstall) MODE="uninstall" ;;
        --status)    MODE="status"    ;;
        --dry-run)   DRY_RUN=true     ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            warning "Unknown argument: $arg (ignored)"
            ;;
    esac
done

#──────────────────────────────────────────────────────────────────────────────
# Helpers
#──────────────────────────────────────────────────────────────────────────────

# dry_run_or_run CMD ARGS...
# In --dry-run mode, prints the command instead of executing it.
dry_run_or_run() {
    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] $*"
    else
        "$@"
    fi
}

# dry_run_or_write DEST CONTENT
# In --dry-run mode, prints what WOULD be written instead of writing.
dry_run_or_write() {
    local dest="$1"
    local content="$2"
    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would write: $dest"
        echo "  [DRY-RUN] Content preview (first 5 lines):"
        echo "$content" | head -5 | sed 's/^/            /'
        echo "            ..."
    else
        echo "$content" > "$dest"
    fi
}

# Read team list from cr-automations.json; fall back to confluence-credentials.json.
# Prints one team name per line.  Returns 1 if no config found.
_read_teams() {
    local automations_file="$HOME/.config/aiteamforge/cr-automations.json"
    local creds_file="$HOME/.config/aiteamforge/confluence-credentials.json"

    if [ -f "$automations_file" ]; then
        jq -r '.teams | keys[]' "$automations_file" 2>/dev/null || true
        return 0
    fi

    if [ -f "$creds_file" ]; then
        jq -r '.teams | keys[]' "$creds_file" 2>/dev/null || true
        return 0
    fi

    return 1
}

#──────────────────────────────────────────────────────────────────────────────
# Install
#──────────────────────────────────────────────────────────────────────────────

do_install() {
    local plist_template="$INSTALL_ROOT/share/templates/kanban/cr-lifecycle-monitor-plist.template"
    local daemon_src="$INSTALL_ROOT/share/scripts/$DAEMON_SCRIPT_NAME"
    local daemon_dest="$AITEAMFORGE_DIR/scripts/$DAEMON_SCRIPT_NAME"
    local launch_agents_dir="$HOME/Library/LaunchAgents"
    local log_dir="$HOME/Library/Logs/aiteamforge/$LOG_SUBDIR"

    [ "$DRY_RUN" = true ] && info "=== DRY-RUN MODE — nothing will be written or loaded ==="

    # ── Install daemon script ──────────────────────────────────────────────────
    if [ -f "$daemon_src" ]; then
        if [ "$DRY_RUN" = true ]; then
            info "[DRY-RUN] Would install daemon: $daemon_dest"
        else
            mkdir -p "$AITEAMFORGE_DIR/scripts"
            cp "$daemon_src" "$daemon_dest"
            chmod +x "$daemon_dest"
            info "Installed: $DAEMON_SCRIPT_NAME"
        fi
    else
        warning "$DAEMON_SCRIPT_NAME not found at $daemon_src"
        warning "LaunchAgents will reference the pre-existing installation at $daemon_dest"
        warning "(Re-run after a full 'aiteamforge install' to pick up the script.)"
    fi

    if [ ! -f "$plist_template" ]; then
        warning "Plist template not found: $plist_template (skipping LaunchAgent install)"
        return 0
    fi

    if [ "$DRY_RUN" = false ]; then
        mkdir -p "$launch_agents_dir"
        mkdir -p "$log_dir"
    fi

    # ── jq preflight ─────────────────────────────────────────────────────────
    if ! command -v jq &>/dev/null; then
        warning "jq is required for per-team install — install jq and re-run."
        return 0
    fi

    # ── Read teams ────────────────────────────────────────────────────────────
    local teams_raw
    if ! teams_raw="$(_read_teams)"; then
        info "No CR-enabled teams configured."
        info "To set up Phase 4 automations, create ~/.config/aiteamforge/cr-automations.json"
        info "with a teams: {} map.  See share/config/cr-automations.json.example."
        return 0
    fi

    if [ -z "$teams_raw" ]; then
        info "No teams defined in config — skipping per-team LaunchAgent installation."
        info "Add teams to .teams in ~/.config/aiteamforge/cr-automations.json then re-run."
        return 0
    fi

    # ── Resolve python3 once ─────────────────────────────────────────────────
    local python3_path
    python3_path="$(command -v python3 2>/dev/null || echo "/usr/bin/python3")"

    info "Installing per-team CR Lifecycle Monitor LaunchAgents"

    # ── Render and load one plist per team ────────────────────────────────────
    local team plist_dest rendered
    while IFS= read -r team; do
        [ -z "$team" ] && continue

        # Sanitize team name — must be safe for a LaunchAgent label and sed replacement
        if [[ ! "$team" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            warning "Skipping team '$team': name must match [a-zA-Z0-9_-]+ for LaunchAgent label."
            continue
        fi

        plist_dest="$launch_agents_dir/${LABEL_PREFIX}.${team}.plist"

        rendered="$(
            sed -e "s|{{USER_HOME}}|$HOME|g" \
                -e "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g" \
                -e "s|{{PYTHON3_PATH}}|$python3_path|g" \
                -e "s|{{TEAM_NAME}}|$team|g" \
                "$plist_template"
        )"

        if [ "$DRY_RUN" = true ]; then
            echo ""
            info "[DRY-RUN] Team: $team"
            info "[DRY-RUN] Would write plist: $plist_dest"
            info "[DRY-RUN] Would run: launchctl unload $plist_dest (graceful)"
            info "[DRY-RUN] Would run: launchctl load -w $plist_dest"
            info "[DRY-RUN] Rendered plist:"
            echo "$rendered" | sed 's/^/            /'
            continue
        fi

        echo "$rendered" > "$plist_dest"

        launchctl unload "$plist_dest" 2>/dev/null || true

        if launchctl load -w "$plist_dest"; then
            success "Loaded CR Lifecycle Monitor LaunchAgent: $team"
        else
            warning "Failed to load LaunchAgent for team '$team' (may need manual activation)"
        fi
    done <<< "$teams_raw"

    if [ "$DRY_RUN" = false ]; then
        info "Per-team lifecycle monitors run every 24 hours"
        info "Logs: $log_dir/<team>.{out,err}.log"
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# Uninstall
#──────────────────────────────────────────────────────────────────────────────

do_uninstall() {
    local launch_agents_dir="$HOME/Library/LaunchAgents"
    local found_any=0

    [ "$DRY_RUN" = true ] && info "=== DRY-RUN MODE — nothing will be removed ==="

    # ── jq preflight (needed for --dry-run team listing) ──────────────────────
    if ! command -v jq &>/dev/null; then
        warning "jq is required — install jq and re-run."
        return 0
    fi

    # ── Unload and remove per-team plists ─────────────────────────────────────
    # Use nullglob-safe pattern (shopt only affects bash, not zsh sourcing)
    shopt -s nullglob
    local plist_files=("$launch_agents_dir"/${LABEL_PREFIX}*.plist)
    shopt -u nullglob

    for plist_file in "${plist_files[@]}"; do
        [ -e "$plist_file" ] || continue
        if [ "$DRY_RUN" = true ]; then
            info "[DRY-RUN] Would unload and remove: $(basename "$plist_file")"
        else
            info "Unloading: $(basename "$plist_file")"
            launchctl unload "$plist_file" 2>/dev/null || true
            rm -f "$plist_file"
        fi
        found_any=1
    done

    if [ "$found_any" -eq 0 ]; then
        info "No cr-lifecycle-monitor LaunchAgents found."
        return 0
    fi

    if [ "$DRY_RUN" = false ]; then
        success "Removed CR Lifecycle Monitor LaunchAgent(s)"
        info "Note: logs in ~/Library/Logs/aiteamforge/$LOG_SUBDIR/ are preserved."
        info "Remove manually if no longer needed."
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# Status
#──────────────────────────────────────────────────────────────────────────────

do_status() {
    local log_dir="$HOME/Library/Logs/aiteamforge/$LOG_SUBDIR"

    info "=== CR Lifecycle Monitor — LaunchAgent status ==="
    echo ""

    # launchctl list filtered to this daemon family
    local launchctl_out
    launchctl_out="$(launchctl list 2>/dev/null | grep "$LABEL_PREFIX" || true)"
    if [ -z "$launchctl_out" ]; then
        info "(no cr-lifecycle-monitor agents currently loaded)"
    else
        echo "$launchctl_out"
    fi

    echo ""

    # Per-team log tail
    if [ ! -d "$log_dir" ]; then
        info "Log directory not found: $log_dir"
        return 0
    fi

    local found_log=false
    for err_log in "$log_dir"/*.err.log; do
        [ -f "$err_log" ] || continue
        found_log=true
        local team
        team="$(basename "$err_log" .err.log)"
        echo "── $team (stderr — last $STATUS_TAIL_LINES lines) ──"
        tail -n "$STATUS_TAIL_LINES" "$err_log" 2>/dev/null || true
        echo ""
    done

    for out_log in "$log_dir"/*.out.log; do
        [ -f "$out_log" ] || continue
        found_log=true
        local team
        team="$(basename "$out_log" .out.log)"
        echo "── $team (stdout — last $STATUS_TAIL_LINES lines) ──"
        tail -n "$STATUS_TAIL_LINES" "$out_log" 2>/dev/null || true
        echo ""
    done

    if [ "$found_log" = false ]; then
        info "No log files found in $log_dir"
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# Dispatch
#──────────────────────────────────────────────────────────────────────────────

case "$MODE" in
    install)   do_install   ;;
    uninstall) do_uninstall ;;
    status)    do_status    ;;
esac
