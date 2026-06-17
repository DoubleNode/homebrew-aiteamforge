#!/usr/bin/env bash
# cellar-watch-trigger.sh — Invoked by com.aiteamforge.cellar-watch LaunchAgent when
# the Homebrew Cellar dir for aiteamforge changes.
#
# Guards against the uninstall-fires-watcher race (XACA-0578 audit Q1d): when a
# user runs `brew uninstall aiteamforge`, launchd fires this watcher because the
# Cellar parent dir's mtime changes. At that moment the formula is gone and an
# `aiteamforge upgrade` call would fail confusingly. Verify the formula is
# actually installed before chaining the upgrade.
#
# XACA-0578

set -eo pipefail

AITEAMFORGE_DIR="${AITEAMFORGE_DIR:-$HOME/.aiteamforge}"
LOG_FILE="${AITEAMFORGE_DIR}/logs/cellar-watch.log"
mkdir -p "$(dirname "$LOG_FILE")"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }

log "===== cellar-watch trigger fired ====="

# Guard 1: brew available?
if ! command -v brew &>/dev/null; then
  log "WARNING: brew not on PATH ($PATH) — skipping upgrade"
  exit 0
fi

# Guard 2: formula installed? (catches uninstall events firing this watcher)
if ! brew list aiteamforge &>/dev/null; then
  log "INFO: aiteamforge formula not installed — likely an uninstall event, skipping upgrade"
  exit 0
fi

# Guard 3: aiteamforge CLI reachable?
if ! command -v aiteamforge &>/dev/null; then
  log "WARNING: aiteamforge CLI not on PATH — Cellar may be mid-install, skipping"
  exit 0
fi

# Run the working-dir refresh
log "Running: aiteamforge upgrade --non-interactive"
if aiteamforge upgrade --non-interactive >> "$LOG_FILE" 2>&1; then
  log "SUCCESS: working-dir refresh complete"
else
  rc=$?
  log "ERROR: aiteamforge upgrade --non-interactive exited $rc"
  exit "$rc"
fi

log "===== cellar-watch trigger complete ====="
