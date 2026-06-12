#!/usr/bin/env bash
# TimePad auto-tracking hook wrapper — fail-soft, never blocks the session.
# Usage: timepad-track.sh start|stop   (called by SessionStart/SessionEnd hooks)
#
# EPIC-0039 Child B (XACA-0620). Relocated from ~/.config/timeapp/timeapp-track.sh
# and generalized: no team is hardcoded here. This wrapper only gathers the
# session's git context and hands off to timepad-track.py, which resolves the
# owning ENABLED team (if any), loads its config, and starts/stops the timer.
# Any session outside an enabled TimePad team no-ops inside the dispatcher.
#
# Always exits 0 — a tracking hiccup must never fail a Claude Code session.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LOG_DIR="$HOME/.config/timepad"
LOG="$LOG_DIR/track.log"
mkdir -p "$LOG_DIR" 2>/dev/null

{
  # Env-failover credentials (vault is primary; this file is the failover tier).
  # Renamed from the retired legacy secrets file in the XACA-0619 hard rebrand. Holds
  # TIMEPAD_API_KEY and/or TEAM_<CODE>_TIMEPAD_API_KEY. Absent on most machines.
  [ -f "$HOME/.timepad-secrets" ] && . "$HOME/.timepad-secrets"

  # Git context for the dispatcher (branch -> kanban item; toplevel -> team).
  export TT_BRANCH="$(git branch --show-current 2>/dev/null)"
  export TT_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"

  python3 "$HERE/timepad-track.py" "${1:-}"
} >> "$LOG" 2>&1
exit 0
