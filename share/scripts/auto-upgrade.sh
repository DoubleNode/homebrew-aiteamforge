#!/bin/bash
# auto-upgrade.sh — Daily AITeamForge tap auto-upgrade with version-pin support.
#
# Invoked by the com.aiteamforge.auto-upgrade LaunchAgent (daily at 03:15).
# Safe to run manually: ./auto-upgrade.sh
#
# Behaviour:
#   1. Verify brew + aiteamforge tap are installed; bail with warning if not.
#   2. Run `brew update`.
#   3. Check if aiteamforge is outdated.
#   4. If outdated: check version-pin sentinel (~/.aiteamforge/version-pin).
#      - If available version > pinned version: refuse upgrade, log + notify.
#      - Otherwise: run `brew upgrade aiteamforge`.
#        On success: fire macOS success notification (opt-out via quiet flag).
#        On failure: fire failure notification; exit 1.
#   5. If already up-to-date: log and exit 0.
#
# Version-pin sentinel:
#   ~/.aiteamforge/version-pin — single line, e.g. "v0.12.3" or "0.12.3"
#   Empty / missing = no pin (upgrade freely).
#   Unparseable = warn + treat as no pin.
#
# Notification opt-out:
#   Set AITEAMFORGE_AUTO_UPGRADE_QUIET=1 in environment or in
#   ~/.aiteamforge/auto-upgrade.env to suppress all osascript notifications.
#
# Log rotation: rotates auto-upgrade.log when it exceeds 5 MB.
#
# XACA-0571

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

AITEAMFORGE_DIR="${AITEAMFORGE_DIR:-$HOME/.aiteamforge}"
LOG_DIR="$AITEAMFORGE_DIR/logs"
LOG_FILE="$LOG_DIR/auto-upgrade.log"
LOG_MAX_BYTES=5242880  # 5 MB
PIN_FILE="$AITEAMFORGE_DIR/version-pin"
ENV_FILE="$AITEAMFORGE_DIR/auto-upgrade.env"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

# ── Optional env override file ────────────────────────────────────────────────

# Source the env file before any logic so AITEAMFORGE_AUTO_UPGRADE_QUIET can be
# set there as well as in the plist EnvironmentVariables.
if [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

QUIET="${AITEAMFORGE_AUTO_UPGRADE_QUIET:-0}"

# ── Logging helpers ───────────────────────────────────────────────────────────

_ensure_log_dir() {
    mkdir -p "$LOG_DIR"
}

_rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        local size
        size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -ge "$LOG_MAX_BYTES" ]; then
            mv "$LOG_FILE" "${LOG_FILE}.1"
        fi
    fi
}

log() {
    printf '[%s] %s\n' "$TIMESTAMP" "$*" >> "$LOG_FILE"
}

log_cmd_output() {
    # Runs a command; appends all output (stdout+stderr) to the log.
    # Returns the command's exit code.
    "$@" >> "$LOG_FILE" 2>&1
}

# ── Notification helper ───────────────────────────────────────────────────────

notify() {
    local message="$1"
    # Respect opt-out; silently skip on headless machines where osascript is absent
    if [ "$QUIET" = "1" ]; then
        return 0
    fi
    if command -v osascript &>/dev/null; then
        osascript -e "display notification \"$message\" with title \"AITeamForge Auto-Upgrade\"" 2>/dev/null || true
    fi
}

# ── Version comparison (sort -V portable wrapper) ────────────────────────────

# Returns 0 if $1 > $2 (version-sort semantics), 1 otherwise.
# Strips leading 'v' from both arguments.
_version_gt() {
    local a="${1#v}"
    local b="${2#v}"
    # `sort -V` sorts lowest-first; the larger version will appear last.
    local winner
    winner=$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)
    [ "$winner" = "$a" ] && [ "$a" != "$b" ]
}

# ── Pin-check helper ──────────────────────────────────────────────────────────

# Echoes the pinned version string (without leading v), or empty string if no pin.
_read_pin() {
    if [ ! -f "$PIN_FILE" ]; then
        echo ""
        return 0
    fi
    local raw
    raw=$(head -1 "$PIN_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$raw" ]; then
        echo ""
        return 0
    fi
    # Validate: must look like a semver with optional leading v
    if [[ "$raw" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-zA-Z0-9._-]+)?$ ]]; then
        echo "${raw#v}"
    else
        log "WARNING: version-pin file contains unparseable value '$raw' — treating as no pin"
        echo ""
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

_ensure_log_dir
_rotate_log

log "===== auto-upgrade start ====="

# Step 1: verify brew is installed
if ! command -v brew &>/dev/null; then
    log "ERROR: brew not found on PATH ($PATH) — cannot run auto-upgrade"
    notify "Auto-upgrade FAILED — see $LOG_FILE"
    exit 1
fi

BREW=$(command -v brew)
log "brew: $BREW"

# Step 2: verify aiteamforge tap is installed
if ! brew tap 2>/dev/null | grep -qi "doublenode/aiteamforge"; then
    log "WARNING: doublenode/aiteamforge tap not found — skipping upgrade"
    exit 0
fi

# Step 3: brew update
log "Running: brew update"
if ! log_cmd_output "$BREW" update; then
    log "WARNING: brew update failed (continuing — may have stale index)"
fi

# Step 4: check if aiteamforge is outdated
log "Running: brew outdated aiteamforge --quiet"
OUTDATED_OUTPUT=$("$BREW" outdated aiteamforge --quiet 2>/dev/null || true)

if [ -z "$OUTDATED_OUTPUT" ]; then
    log "aiteamforge is up-to-date — nothing to do"
    log "===== auto-upgrade complete (no-op) ====="
    exit 0
fi

log "aiteamforge is outdated: $OUTDATED_OUTPUT"

# Step 5: determine the available version for pin comparison
AVAILABLE_VERSION=""
if command -v jq &>/dev/null; then
    AVAILABLE_VERSION=$("$BREW" info aiteamforge --json 2>/dev/null \
        | jq -r '.[0].versions.stable // ""' 2>/dev/null || true)
fi

# Step 6: check version-pin sentinel
PINNED_VERSION=$(_read_pin)

if [ -n "$PINNED_VERSION" ] && [ -n "$AVAILABLE_VERSION" ]; then
    log "Version-pin active: pinned=$PINNED_VERSION  available=$AVAILABLE_VERSION"
    if _version_gt "$AVAILABLE_VERSION" "$PINNED_VERSION"; then
        log "HELD: available version ($AVAILABLE_VERSION) > pin ($PINNED_VERSION) — refusing upgrade"
        notify "Upgrade held at pin v$PINNED_VERSION (available: $AVAILABLE_VERSION)"
        log "===== auto-upgrade complete (held by pin) ====="
        exit 0
    else
        log "Available version ($AVAILABLE_VERSION) does not exceed pin ($PINNED_VERSION) — proceeding"
    fi
elif [ -n "$PINNED_VERSION" ]; then
    # jq absent — can't compare; log a warning and skip pin enforcement
    log "WARNING: jq not found — cannot compare versions; ignoring pin $PINNED_VERSION and upgrading"
fi

# Step 7: run the brew upgrade
log "Running: brew upgrade aiteamforge"
BREW_EXIT=0
log_cmd_output "$BREW" upgrade aiteamforge || BREW_EXIT=$?
if [ "$BREW_EXIT" -ne 0 ]; then
    log "ERROR: brew upgrade aiteamforge failed (exit $BREW_EXIT)"
    notify "Auto-upgrade FAILED — see $LOG_FILE"
    log "===== auto-upgrade complete (FAILED) ====="
    exit 1
fi

NEW_VERSION=""
if command -v jq &>/dev/null; then
    NEW_VERSION=$("$BREW" info aiteamforge --json 2>/dev/null \
        | jq -r '.[0].installed[0].version // ""' 2>/dev/null || true)
fi

# Step 8: refresh the working-dir copy of the framework so user-facing files
# (lcars-ui, kanban-hooks, scripts) are replaced with the new versions. Without
# this, `brew upgrade` only refreshes the Cellar — the LCARS watcher LaunchAgent
# (WatchPaths on $AITEAMFORGE_DIR/lcars-ui) wouldn't see the file changes and
# the running server would keep serving the OLD assets.
if command -v aiteamforge &>/dev/null; then
    log "Refreshing working-dir copy: aiteamforge upgrade --non-interactive"
    if ! log_cmd_output aiteamforge upgrade --non-interactive; then
        log "WARNING: 'aiteamforge upgrade --non-interactive' failed — brew upgrade succeeded but working-dir copy may be stale"
        notify "Upgrade partial — see $LOG_FILE (brew succeeded, working-dir refresh failed)"
    fi
else
    log "WARNING: 'aiteamforge' CLI not on PATH after brew upgrade — working-dir copy not refreshed"
fi

if [ -n "$NEW_VERSION" ]; then
    log "SUCCESS: upgraded aiteamforge to $NEW_VERSION"
    notify "Upgraded aiteamforge to $NEW_VERSION"
else
    log "SUCCESS: aiteamforge upgrade complete"
    notify "aiteamforge upgraded successfully"
fi

log "===== auto-upgrade complete ====="
exit 0
