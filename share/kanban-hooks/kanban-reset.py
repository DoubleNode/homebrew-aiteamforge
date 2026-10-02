#!/usr/bin/env python3
"""
Kanban Reset Script
Clears activeWindows for a team's kanban board.

Usage:
    python3 kanban-reset.py <team>           - Clear all activeWindows for team
    python3 kanban-reset.py <team> <session> - Clear windows matching session pattern

Examples:
    python3 kanban-reset.py freelance                    - Clear all freelance windows
    python3 kanban-reset.py freelance doublenode         - Clear doublenode project windows
    python3 kanban-reset.py freelance doublenode-workstats - Clear specific project
"""

import os
import sys
from datetime import datetime, timezone

# Add kanban-hooks directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kanban_utils import get_board_file, update_board_safely

def reset_kanban(team, session_filter=None):
    """Clear activeWindows for a team, optionally filtered by session pattern."""
    board_file = get_board_file(team)

    if not os.path.exists(board_file):
        print(f"  No kanban board found for team: {team}")
        return False

    messages = []

    def _mutate(board):
        """Runs under update_board_safely's exclusive lock on the fresh board."""
        original_count = len(board.get("activeWindows", []))

        if session_filter:
            # Filter out windows that match the session pattern
            # Session pattern could be like "doublenode" or "doublenode-workstats"
            remaining = []
            removed_count = 0
            for win in board.get("activeWindows", []):
                # Window IDs are like "engineering:window-name"; match the
                # filter against the window name (original tmux session name).
                window_name = win.get("windowName", "")
                if session_filter.lower() not in window_name.lower():
                    remaining.append(win)
                else:
                    removed_count += 1
                    messages.append(f"  Removing: {win.get('id')} ({win.get('developer', 'Unknown')})")

            board["activeWindows"] = remaining
            messages.append(f"  Removed {removed_count} window(s) matching '{session_filter}'")
        else:
            # Clear all activeWindows
            for win in board.get("activeWindows", []):
                messages.append(f"  Removing: {win.get('id')} ({win.get('developer', 'Unknown')})")
            board["activeWindows"] = []
            messages.append(f"  Cleared all {original_count} active window(s)")

        board["lastUpdated"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        return board

    # XACA-1404: whole read-modify-write under the shared board.json.lock
    # (same lock as kb-* and the LCARS server) instead of an unlocked
    # open(...,'w') that could clobber concurrent writers.
    try:
        ok = update_board_safely(board_file, _mutate)
    except Exception as e:
        print(f"  Error resetting kanban: {e}")
        return False

    if not ok:
        print("  Error resetting kanban: board update failed (see error above)")
        return False

    for line in messages:
        print(line)
    return True

def main():
    if len(sys.argv) < 2:
        print("Usage: kanban-reset.py <team> [session-filter]")
        print("  team: freelance, academy, mainevent, ios, android, firebase, command, dns")
        print("  session-filter: optional filter (e.g., 'doublenode' or 'doublenode-workstats')")
        sys.exit(1)

    team = sys.argv[1].lower()
    session_filter = sys.argv[2].lower() if len(sys.argv) > 2 else None

    print(f"  Resetting kanban board for: {team}")
    if session_filter:
        print(f"  Filter: {session_filter}")

    success = reset_kanban(team, session_filter)
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
