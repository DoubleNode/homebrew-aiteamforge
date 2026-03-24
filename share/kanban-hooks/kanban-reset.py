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

import json
import os
import sys
from datetime import datetime, timezone

# Add kanban-hooks directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kanban_utils import get_board_file

def reset_kanban(team, session_filter=None):
    """Clear activeWindows for a team, optionally filtered by session pattern."""
    board_file = get_board_file(team)

    if not os.path.exists(board_file):
        print(f"  No kanban board found for team: {team}")
        return False

    try:
        with open(board_file, 'r') as f:
            board = json.load(f)

        original_count = len(board.get("activeWindows", []))

        if session_filter:
            # Filter out windows that match the session pattern
            # Session pattern could be like "doublenode" or "doublenode-workstats"
            remaining = []
            removed_count = 0
            for win in board.get("activeWindows", []):
                # Check if this window's session matches the filter
                # Window IDs are like "engineering:window-name"
                # We need to check against the original tmux session name
                window_name = win.get("windowName", "")
                # If the filter appears in the window name or task, remove it
                if session_filter.lower() not in window_name.lower():
                    remaining.append(win)
                else:
                    removed_count += 1
                    print(f"  Removing: {win.get('id')} ({win.get('developer', 'Unknown')})")

            board["activeWindows"] = remaining
            print(f"  Removed {removed_count} window(s) matching '{session_filter}'")
        else:
            # Clear all activeWindows
            removed_count = original_count
            for win in board.get("activeWindows", []):
                print(f"  Removing: {win.get('id')} ({win.get('developer', 'Unknown')})")
            board["activeWindows"] = []
            print(f"  Cleared all {removed_count} active window(s)")

        board["lastUpdated"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        with open(board_file, 'w') as f:
            json.dump(board, f, indent=2)

        return True

    except Exception as e:
        print(f"  Error resetting kanban: {e}")
        return False

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
