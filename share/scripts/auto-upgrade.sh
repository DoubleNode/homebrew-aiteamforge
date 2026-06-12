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

# ── Optional env override file ────────────────────────────────────────────────

# Source the env file before any logic so AITEAMFORGE_AUTO_UPGRADE_QUIET can be
# set there as well as in the plist EnvironmentVariables. XACA-0571-016: relax
# `set -u` while sourcing — operator typos that reference an unset variable
# inside the override file would otherwise abort the entire upgrade run before
# the log is initialized, leaving no diagnostic trail. The error path captures
# the source failure into $_ENV_SOURCE_ERROR for later logging.
_ENV_SOURCE_ERROR=""
if [ -f "$ENV_FILE" ]; then
    set +u
    # shellcheck source=/dev/null
    source "$ENV_FILE" 2>/dev/null || _ENV_SOURCE_ERROR="failed to source $ENV_FILE (operator typo? unset variable?)"
    set -u
fi

QUIET="${AITEAMFORGE_AUTO_UPGRADE_QUIET:-0}"

# ── Logging helpers ───────────────────────────────────────────────────────────

_ensure_log_dir() {
    mkdir -p "$LOG_DIR"
}

# XACA-0571-017: use `mv -n` (no-clobber) so a concurrent LaunchAgent + manual
# invocation race cannot overwrite the just-archived .1 with a fresh oversize
# log. The losing invocation's mv is a silent no-op; both proceed to write to
# the (now-empty) live log.
_rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        local size
        size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -ge "$LOG_MAX_BYTES" ]; then
            mv -n "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
        fi
    fi
}

# XACA-0571-013: re-evaluate `date` per log line so multi-minute upgrade runs
# (brew update + brew upgrade + aiteamforge upgrade) show per-step timestamps
# rather than the frozen script-start time.
log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

log_cmd_output() {
    # Runs a command; appends all output (stdout+stderr) to the log.
    # Returns the command's exit code.
    "$@" >> "$LOG_FILE" 2>&1
}

# ── Notification helper ───────────────────────────────────────────────────────

# XACA-0571-011: escape backslashes + double-quotes so $message can be safely
# interpolated into the AppleScript source. Current callers feed regex-validated
# version strings or fixed log paths, but the helper hardens future callers and
# documents the invariant.
_escape_for_osascript() {
    # macOS AppleScript string literals use \\ for backslash, \" for quote.
    local s="$1"
    s="${s//\\/\\\\}"  # backslashes first (escape order matters)
    s="${s//\"/\\\"}"  # then double quotes
    printf '%s' "$s"
}

notify() {
    local message="$1"
    # Respect opt-out; silently skip on headless machines where osascript is absent
    if [ "$QUIET" = "1" ]; then
        return 0
    fi
    if command -v osascript &>/dev/null; then
        local safe
        safe=$(_escape_for_osascript "$message")
        osascript -e "display notification \"$safe\" with title \"AITeamForge Auto-Upgrade\"" 2>/dev/null || true
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

# XACA-0571-016: surface any deferred error from the env-source step now that
# the log file exists.
if [ -n "$_ENV_SOURCE_ERROR" ]; then
    log "WARNING: $_ENV_SOURCE_ERROR — continuing with default settings"
fi

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

# Step 2.5 (XACA-0676): trust the tap BEFORE any brew load. Recent Homebrew gates
# formula loading behind tap-trust when $HOMEBREW_REQUIRE_TAP_TRUST is set; on a
# gated box an UNTRUSTED tap makes `brew outdated`/`brew upgrade` silently no-op,
# so this LaunchAgent would "succeed" forever while the box rots on an old version
# (observed on M4Mini stuck at 0.13.4). `brew trust --tap` is idempotent.
log "Running: brew trust --tap doublenode/aiteamforge (idempotent)"
if ! log_cmd_output "$BREW" trust --tap doublenode/aiteamforge; then
    log "WARNING: 'brew trust --tap doublenode/aiteamforge' failed (older Homebrew without trust gate?) — continuing"
fi

# Detect: is the formula STILL refused after trusting? If so, warn LOUDLY and bail
# with a non-zero exit + operator notification — never report a clean no-op while
# upgrades are actually blocked.
if "$BREW" info aiteamforge 2>&1 | grep -qiE "untrusted tap|refus(e|ing) to load"; then
    log "ERROR: doublenode/aiteamforge tap is UNTRUSTED — Homebrew is REFUSING to load the formula."
    log "       Upgrades are BLOCKED; this box will stay on the OLD version."
    log "       Remediation: brew trust --tap doublenode/aiteamforge"
    notify "Auto-upgrade BLOCKED: tap untrusted — run 'brew trust --tap doublenode/aiteamforge'"
    log "===== auto-upgrade complete (BLOCKED: untrusted tap) ====="
    exit 1
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
# XACA-0571-012: fail-closed when a pin is set but the available version
# cannot be determined. Previously a missing jq OR a failed `brew info` both
# fell through to "ignoring pin and upgrading" — that's unsafe: the operator
# explicitly held the upgrade at $PINNED_VERSION and a transient brew/jq
# failure should not silently bypass that gate. New behavior: pin active +
# unknown available version → HOLD (refuse upgrade), log the diagnostic.
PINNED_VERSION=$(_read_pin)

if [ -n "$PINNED_VERSION" ]; then
    if [ -z "$AVAILABLE_VERSION" ]; then
        if command -v jq &>/dev/null; then
            log "HELD: pin=$PINNED_VERSION but 'brew info aiteamforge --json' returned no version — refusing upgrade (fail-closed under active pin)"
        else
            log "HELD: pin=$PINNED_VERSION but jq is not on PATH (cannot determine available version) — refusing upgrade (fail-closed under active pin)"
        fi
        notify "Upgrade held at pin v$PINNED_VERSION (available version unknown)"
        log "===== auto-upgrade complete (held by pin, version unknown) ====="
        exit 0
    fi
    log "Version-pin active: pinned=$PINNED_VERSION  available=$AVAILABLE_VERSION"
    if _version_gt "$AVAILABLE_VERSION" "$PINNED_VERSION"; then
        log "HELD: available version ($AVAILABLE_VERSION) > pin ($PINNED_VERSION) — refusing upgrade"
        notify "Upgrade held at pin v$PINNED_VERSION (available: $AVAILABLE_VERSION)"
        log "===== auto-upgrade complete (held by pin) ====="
        exit 0
    fi
    log "Available version ($AVAILABLE_VERSION) does not exceed pin ($PINNED_VERSION) — proceeding"
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
