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
from typing import Optional


def _get_aiteamforge_dir() -> Path:
    """
    Resolve the AITeamForge installation directory.

    Priority:
    1. AITEAMFORGE_DIR environment variable (set in installed kanban-helpers.sh)
    2. install_dir field in ~/.aiteamforge-config / ~/aiteamforge/.aiteamforge-config
    3. Fallback to ~/aiteamforge

    This allows hooks to work correctly even when the install dir is non-default.
    """
    # 1. Environment variable (most reliable — set by the sourced kanban-helpers.sh)
    env_dir = os.environ.get("AITEAMFORGE_DIR", "").strip()
    if env_dir:
        return Path(env_dir)

    # 2. Read from config file
    for config_candidate in [
        Path.home() / "aiteamforge" / ".aiteamforge-config",
        Path.home() / ".aiteamforge-config",
    ]:
        if config_candidate.exists():
            try:
                with open(config_candidate) as f:
                    cfg = json.load(f)
                install_dir = cfg.get("install_dir", "").strip()
                if install_dir:
                    return Path(install_dir)
            except (json.JSONDecodeError, IOError):
                pass

    # 3. Default
    return Path.home() / "aiteamforge"


def _get_team_kanban_dir_from_config(team: str) -> Optional[Path]:
    """
    Look up a team's kanban directory from .aiteamforge-config.

    Returns None if the config is missing or the team is not found.
    """
    aiteamforge_dir = _get_aiteamforge_dir()
    config_file = aiteamforge_dir / ".aiteamforge-config"
    if not config_file.exists():
        return None
    try:
        with open(config_file) as f:
            cfg = json.load(f)
        working_dir = cfg.get("team_paths", {}).get(team, {}).get("working_dir", "")
        if working_dir:
            return Path(working_dir) / "kanban"
    except (json.JSONDecodeError, IOError, AttributeError):
        pass
    return None


# Resolve installation root once at import time
_AITEAMFORGE_DIR = _get_aiteamforge_dir()

KANBAN_DIR = str(_AITEAMFORGE_DIR / "kanban")

# Distributed kanban directories - must match server.py TEAM_KANBAN_DIRS
# NOTE: Academy uses the aiteamforge install directory, which is resolved
# dynamically. Other well-known teams have fixed paths from their repositories.
TEAM_KANBAN_DIRS = {
    # Main Event Teams
    "academy": _AITEAMFORGE_DIR / "kanban",
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
    "freelance-doublenode-caravan": Path("/Users/Shared/Development/DoubleNode/Caravan/kanban"),
    "freelance-doublenode-awaysentry": Path("/Users/Shared/Development/DoubleNode/AwaySentry/kanban"),

    # Liquidstyle Freelance Projects
    "freelance-liquidstyle-agentbadges-app": Path("/Users/Shared/Development/Liquidstyle/AgentBadges-APP/kanban"),
    "freelance-liquidstyle-agentbadges-ios": Path("/Users/Shared/Development/Liquidstyle/AgentBadges-IOS/kanban"),

    # Legal Projects
    "legal-coparenting": Path.home() / "legal" / "coparenting" / "kanban",

    # Finance Projects
    "finance-personal": Path.home() / "finance" / "personal" / "kanban",

    # Medical Projects
    "medical-general": Path.home() / "medical" / "general" / "kanban",
    "medical": Path.home() / "medical" / "general" / "kanban",  # alias

    # Aliases (shell helper has these via case-statement pipe syntax)
    "mainevent": Path("/Users/Shared/Development/Main Event/aiteamforge/kanban"),
    "freelance": _AITEAMFORGE_DIR / "kanban",  # generic fallback
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
    """
    Get path to team's kanban board file using distributed directories.

    Resolution order:
    1. .aiteamforge-config team_paths (set during install wizard)
    2. TEAM_KANBAN_DIRS static mapping (known platform/team paths)
    3. Default KANBAN_DIR fallback
    """
    # Priority 1: config-based lookup (authoritative for fresh installs)
    config_dir = _get_team_kanban_dir_from_config(team)
    if config_dir is not None:
        return os.path.join(str(config_dir), f"{team}-board.json")

    # Priority 2: static mapping
    kanban_dir = str(TEAM_KANBAN_DIRS.get(team, KANBAN_DIR))
    return os.path.join(kanban_dir, f"{team}-board.json")


def get_lcars_tmp_dir(session_name: str) -> str:
    """
    Map a tmux session name to the correct kanban/tmp/ directory for that team.

    Mirrors _get_lcars_tmp_dir() in scripts/lcars-tmp-dir.sh.
    All three sources of truth (this function, lcars-tmp-dir.sh, and
    TEAM_KANBAN_DIRS) must be kept in sync when adding new teams.

    Session name format: <team>-<terminal>
      Simple:        "academy-reno"                      -> team=academy
      Multi-segment: "legal-coparenting-advocate"        -> team=legal-coparenting
      Three-part:    "freelance-doublenode-starwords-archer" -> team=freelance-doublenode-starwords

    Algorithm:
      1. Extract team via parse_session_name() (everything before the last "-")
      2. Look up the team's kanban directory from TEAM_KANBAN_DIRS
      3. Return <kanban_dir>/tmp/ — creating the directory if it doesn't exist
      4. Falls back to /tmp/ for unknown teams or invalid session names

    Args:
        session_name: tmux session name string.

    Returns:
        Absolute path to the tmp directory (with trailing slash).
        Always returns a usable path — never raises.
    """
    try:
        team, terminal = parse_session_name(session_name)
        if not team:
            return "/tmp/"

        # Use TEAM_KANBAN_DIRS; fall back to default academy kanban dir
        kanban_dir = TEAM_KANBAN_DIRS.get(team)
        if kanban_dir is None:
            # Unknown team — use the default
            kanban_dir = Path(KANBAN_DIR)

        tmp_dir = Path(kanban_dir) / "tmp"
        tmp_dir.mkdir(parents=True, exist_ok=True)
        return str(tmp_dir) + "/"

    except Exception:
        return "/tmp/"


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
