#!/usr/bin/env python3
"""
Kanban Board Utilities
Shared utilities for safe, atomic board file operations.

This module provides thread-safe and process-safe file operations
to prevent corruption from concurrent writes.
"""

import json
import os
import fcntl
from pathlib import Path

KANBAN_DIR = os.path.expanduser("~/aiteamforge/kanban")

# Distributed kanban directories - must match server.py TEAM_KANBAN_DIRS
TEAM_KANBAN_DIRS = {
    # Main Event Teams
    "academy": Path.home() / "aiteamforge" / "kanban",
    "ios": Path("/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban"),
    "android": Path("/Users/Shared/Development/Main Event/MainEventApp-Android/kanban"),
    "firebase": Path("/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban"),
    "command": Path("/Users/Shared/Development/Main Event/aiteamforge/kanban"),
    "dns": Path("/Users/Shared/Development/DNSFramework/kanban"),

    # Freelance Projects
    "freelance-doublenode-starwords": Path("/Users/Shared/Development/DoubleNode/Starwords/kanban"),
    "freelance-doublenode-appplanning": Path("/Users/Shared/Development/DoubleNode/appPlanning/kanban"),
    "freelance-doublenode-workstats": Path("/Users/Shared/Development/DoubleNode/WorkStats/kanban"),
    "freelance-doublenode-lifeboard": Path("/Users/Shared/Development/DoubleNode/LifeBoard/kanban"),

    # Legal Projects
    "legal-coparenting": Path.home() / "legal" / "coparenting" / "kanban",
}


def parse_session_name(session_name):
    """
    Parse tmux session name to extract team/board-prefix and terminal.

    Works for any number of segments:
      freelance-command → team=freelance, terminal=command
      freelance-doublenode-starwords-command → team=freelance-doublenode-starwords, terminal=command
      ios-bridge → team=ios, terminal=bridge

    Returns:
        tuple: (team, terminal) or (None, None) if invalid
    """
    if not session_name:
        return None, None

    parts = session_name.split("-")
    if len(parts) < 2:
        return None, None

    # Terminal is always the last segment
    terminal = parts[-1]
    # Team/board-prefix is everything before the last segment
    team = "-".join(parts[:-1])

    return team, terminal


def get_board_file(team):
    """Get path to team's kanban board file using distributed directories."""
    kanban_dir = str(TEAM_KANBAN_DIRS.get(team, KANBAN_DIR))
    return os.path.join(kanban_dir, f"{team}-board.json")


def read_board_safely(board_file):
    """
    Read board data with file locking to prevent reading during writes.

    Args:
        board_file: Path to the board JSON file

    Returns:
        dict: Board data, or None if file doesn't exist or is invalid
    """
    if not os.path.exists(board_file):
        return None

    lock_file = board_file + ".lock"

    try:
        # Create lock file if it doesn't exist
        Path(lock_file).touch(exist_ok=True)

        with open(lock_file, 'r') as lock:
            # Shared lock for reading (allows multiple readers)
            fcntl.flock(lock.fileno(), fcntl.LOCK_SH)
            try:
                with open(board_file, 'r') as f:
                    return json.load(f)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    except (json.JSONDecodeError, IOError) as e:
        # Log error but don't crash
        return None


def write_board_safely(board_file, board_data):
    """
    Write board data atomically with file locking.

    This function:
    1. Acquires an exclusive lock to prevent concurrent access
    2. Writes to a temporary file first
    3. Atomically renames the temp file to the target file

    This ensures:
    - No partial writes (atomic rename)
    - No concurrent write corruption (exclusive lock)
    - No read-during-write issues (lock blocks readers too)

    Args:
        board_file: Path to the board JSON file
        board_data: Dictionary to write as JSON

    Returns:
        bool: True if successful, False otherwise
    """
    lock_file = board_file + ".lock"
    tmp_file = board_file + ".tmp"

    try:
        # Ensure kanban directory exists
        os.makedirs(os.path.dirname(board_file), exist_ok=True)

        # Create lock file if it doesn't exist
        Path(lock_file).touch(exist_ok=True)

        with open(lock_file, 'r+') as lock:
            # Exclusive lock for writing (blocks all other access)
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                # Write to temporary file first
                with open(tmp_file, 'w') as f:
                    json.dump(board_data, f, indent=2)
                    f.flush()
                    os.fsync(f.fileno())  # Ensure data is on disk

                # Atomic rename (this is the key to preventing corruption)
                os.rename(tmp_file, board_file)
                return True
            finally:
                # Always release the lock
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    except Exception as e:
        # Clean up temp file if it exists
        try:
            if os.path.exists(tmp_file):
                os.remove(tmp_file)
        except:
            pass
        return False


def update_board_safely(board_file, update_func):
    """
    Read-modify-write pattern with proper locking.

    This is the safest way to update a board file as it:
    1. Acquires exclusive lock
    2. Reads current data
    3. Applies update function
    4. Writes atomically
    5. Releases lock

    Args:
        board_file: Path to the board JSON file
        update_func: Function that takes board dict and returns modified dict

    Returns:
        bool: True if successful, False otherwise
    """
    lock_file = board_file + ".lock"
    tmp_file = board_file + ".tmp"

    if not os.path.exists(board_file):
        return False

    try:
        # Create lock file if it doesn't exist
        Path(lock_file).touch(exist_ok=True)

        with open(lock_file, 'r+') as lock:
            # Exclusive lock for the entire read-modify-write operation
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                # Read current data
                with open(board_file, 'r') as f:
                    board_data = json.load(f)

                # Apply update
                updated_data = update_func(board_data)

                if updated_data is None:
                    # Update function returned None, skip write
                    return True

                # Write to temporary file
                with open(tmp_file, 'w') as f:
                    json.dump(updated_data, f, indent=2)
                    f.flush()
                    os.fsync(f.fileno())

                # Atomic rename
                os.rename(tmp_file, board_file)
                return True
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    except Exception as e:
        # Clean up temp file if it exists
        try:
            if os.path.exists(tmp_file):
                os.remove(tmp_file)
        except:
            pass
        return False
