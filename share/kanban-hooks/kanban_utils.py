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
import subprocess
import tempfile
import warnings
from datetime import datetime, timezone
from pathlib import Path

KANBAN_DIR = os.path.expanduser("~/dev-team/kanban")

# ---------------------------------------------------------------------------
# Distributed kanban directories — XACA-0168
#
# Loaded from aiteamforge_paths (the single source of truth).  The dict is
# built eagerly at import time so callers can continue to do:
#
#     from kanban_utils import TEAM_KANBAN_DIRS
#     kanban_dir = TEAM_KANBAN_DIRS.get(team)
#     TEAM_KANBAN_DIRS["new-team"] = Path(...)   # runtime additions
#
# Tests that mutate this dict in-place (clear/update) still work because it
# is a plain mutable dict — not a proxy or property.
#
# To add a new team, edit aiteamforge_paths.DEFAULT_TEAMS (and run the
# Initialize Team skill which handles all downstream registrations).
# ---------------------------------------------------------------------------

def _build_team_kanban_dirs() -> dict:
    """Build TEAM_KANBAN_DIRS from the aiteamforge_paths registry.

    XACA-0628: enumerate teams via the registry (list_teams() +
    get_team_kanban_dir()), which reads the per-machine overlay
    (~/.aiteamforge/team-paths.json) merged with DEFAULT_TEAMS — NOT
    DEFAULT_TEAMS alone. This is required because the per-client/project
    freelance slugs are now overlay-only (removed from DEFAULT_TEAMS); the
    old DEFAULT_TEAMS-only build would silently drop them and route their
    boards/tmp dirs to the academy default. Mirrors server.py's
    _build_team_kanban_dirs(), which already used the registry path.
    """
    try:
        # kanban-hooks/ is always on sys.path when this module is imported
        from aiteamforge_paths import (  # noqa: PLC0415
            list_teams,
            get_team_kanban_dir,
            DEFAULT_TEAMS,
        )
        teams = list_teams()
        if teams:
            result = {}
            for team in teams:
                try:
                    result[team] = Path(get_team_kanban_dir(team)).expanduser()
                except Exception:
                    # Skip a single malformed entry rather than losing the map.
                    continue
            if result:
                return result
        # Empty/failed enumeration → fall back to DEFAULT_TEAMS directly.
        # XACA-0727: skip board-less aliases (e.g. "mainevent") — they carry no
        # kanban_dir, so Path(entry["kanban_dir"]) would KeyError and crash the
        # whole comprehension. The absent value is a missing key, None, "" or the
        # "null" sentinel (shell-heredoc seed) — exclude all of them.
        return {
            team: Path(entry["kanban_dir"]).expanduser()
            for team, entry in DEFAULT_TEAMS.items()
            if entry.get("kanban_dir") not in (None, "", "null")
        }
    except Exception as _exc:
        warnings.warn(
            f"kanban_utils: could not load aiteamforge_paths ({_exc}); "
            "falling back to hardcoded TEAM_KANBAN_DIRS",
            stacklevel=2,
        )
        # Hardcoded fallback — only reached if aiteamforge_paths is entirely
        # unavailable. XACA-0628: per-client/project freelance slugs are
        # overlay-only and intentionally omitted here; only the generic
        # 'freelance' fallback remains.
        _h = Path.home()
        return {
            "academy":     _h / "dev-team" / "kanban",
            "ios":         Path("/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban"),
            "android":     Path("/Users/Shared/Development/Main Event/MainEventApp-Android/kanban"),
            "firebase":    Path("/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban"),
            "command":     Path("/Users/Shared/Development/Main Event/dev-team/kanban"),
            "dns":         Path("/Users/Shared/Development/DNSFramework/kanban"),
            "legal-coparenting": _h / "legal" / "coparenting" / "kanban",
            "medical-general":   _h / "medical" / "general" / "kanban",
            "medical":           _h / "medical" / "general" / "kanban",
            "finance-personal":  _h / "finance" / "personal" / "kanban",
            # XACA-0727: "mainevent" removed — it is a board-less alias (no kanban
            # board of its own; "command" owns command-board.json). It must not
            # resolve to command's kanban_dir.
            "freelance":  _h / "dev-team" / "kanban",
        }

TEAM_KANBAN_DIRS: dict = _build_team_kanban_dirs()


def _overlay_kanban_dir(team: str):
    """Read kanban_dir for a team straight from the per-machine overlay.

    XACA-0628: per-client/project freelance slugs are overlay-only. When the
    aiteamforge_paths registry is unavailable (so TEAM_KANBAN_DIRS fell back to
    the hardcoded subset that omits them), resolve their kanban_dir directly
    from ~/.aiteamforge/team-paths.json — mirroring the overlay-lookup fallback
    in lcars-tmp-dir.sh / statusline-command.sh. Returns a Path or None.
    """
    try:
        overlay = Path.home() / ".aiteamforge" / "team-paths.json"
        if not overlay.is_file():
            return None
        with open(overlay) as fh:
            data = json.load(fh)
        teams = data.get("teams", data)
        if not isinstance(teams, dict):
            return None
        entry = teams.get(team)
        if not isinstance(entry, dict):
            return None
        val = entry.get("kanban_dir")
        if not val:
            return None
        return Path(val).expanduser()
    except Exception:
        return None


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
    kanban_dir = TEAM_KANBAN_DIRS.get(team)
    if kanban_dir is None and isinstance(team, str) and team.startswith("freelance-"):
        # XACA-0628: overlay-only freelance project not in the map (registry
        # unavailable) — resolve from the overlay directly.
        kanban_dir = _overlay_kanban_dir(team)
    if kanban_dir is None:
        kanban_dir = KANBAN_DIR
    return os.path.join(str(kanban_dir), f"{team}-board.json")


def get_lcars_tmp_dir(session_name: str) -> str:
    """
    Map a tmux session name to the correct kanban/tmp/ directory for that team.

    Mirrors _get_lcars_tmp_dir() in scripts/lcars-tmp-dir.sh.
    This function reads paths from TEAM_KANBAN_DIRS (built from
    aiteamforge_paths.DEFAULT_TEAMS).  Adding a new team to DEFAULT_TEAMS
    automatically updates this function's behaviour.  The shell counterpart
    lcars-tmp-dir.sh must still be updated by hand until Wave 4 lands.

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

        # Look up team in TEAM_KANBAN_DIRS (built from aiteamforge_paths)
        kanban_dir = TEAM_KANBAN_DIRS.get(team)
        if kanban_dir is None and team.startswith("freelance-"):
            # XACA-0628: overlay-only freelance project not in the map (registry
            # unavailable) — resolve from the overlay directly.
            kanban_dir = _overlay_kanban_dir(team)
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


# ---------------------------------------------------------------------------
# Activity Logging
# ---------------------------------------------------------------------------

# Maps the 3-letter team code (positions 1-3 of an item ID like XACA-0001)
# to the team name used in TEAM_KANBAN_DIRS (built from aiteamforge_paths).
# Mirrors _kb_get_team_from_code() in kanban-helpers.sh.
#
# XACA-0542: Derived at import time from aiteamforge_paths.build_team_code_map()
# so the registry (DEFAULT_TEAMS + team-paths.json) is the single source of
# truth.  The hardcoded fallback below is retained ONLY as a safety net for
# environments where aiteamforge_paths is unavailable (CI, bootstrap).
def _build_team_code_map() -> dict:
    """Build _TEAM_CODE_MAP from aiteamforge_paths registry."""
    try:
        from aiteamforge_paths import build_team_code_map  # noqa: PLC0415
        result = build_team_code_map()
        if result:
            return result
    except Exception as _exc:
        warnings.warn(
            f"kanban_utils: could not load team_code map from aiteamforge_paths ({_exc}); "
            "falling back to hardcoded _TEAM_CODE_MAP",
            stacklevel=2,
        )
    # Hardcoded fallback — only reached if registry import fails.
    # MUST EXACTLY MIRROR DEFAULT_TEAMS team_code values in aiteamforge_paths.py.
    # XACA-0628: per-client/project freelance codes (FSW/FAP/.../BWA/BWD) are
    # overlay-only and resolve via build_team_code_map() above; only the generic
    # FRE remains here.
    return {
        "IOS": "ios",
        "AND": "android",
        "FIR": "firebase",
        "FRE": "freelance",
        "ACA": "academy",
        "DNS": "dns",
        "CMD": "command",
        "MEV": "mainevent",
        "LCP": "legal-coparenting",
        "MED": "medical-general",
        "FIN": "finance-personal",
    }

_TEAM_CODE_MAP: dict = _build_team_code_map()


def get_parent_item_id(item_or_subitem_id: str) -> str:
    """
    Return the parent item ID for a subitem ID, or the ID itself for an item.

    Item IDs have the form:    PREFIX-NNNN        (e.g. XACA-0117)
    Subitem IDs have the form: PREFIX-NNNN-NNN   (e.g. XACA-0117-003)

    Args:
        item_or_subitem_id: An item or subitem ID string.

    Returns:
        The parent item ID (PREFIX-NNNN).
    """
    parts = item_or_subitem_id.split("-")
    # Subitem IDs have three dash-separated segments; strip the last one.
    if len(parts) == 3:
        return f"{parts[0]}-{parts[1]}"
    return item_or_subitem_id


def get_team_from_item_id(item_id: str) -> str:
    """
    Map an item or subitem ID to its team name.

    Resolves subitem IDs to their parent item ID first, then extracts the
    3-letter team code from the prefix (characters at positions 1-3).

    Args:
        item_id: An item ID (XACA-0117) or subitem ID (XACA-0117-003).

    Returns:
        The team name string (e.g. "academy"), or "" if the code is unknown.
    """
    parent_id = get_parent_item_id(item_id)
    # Extract the 3-letter code: "XACA-0117" -> code = "ACA"
    if len(parent_id) >= 4 and parent_id[0] == "X":
        code = parent_id[1:4].upper()
        return _TEAM_CODE_MAP.get(code, "")
    return ""


def get_activity_dir(item_id: str) -> str:
    """
    Return the path to the activity/ subdirectory for the given item's team.

    Creates the directory if it does not already exist.

    Args:
        item_id: An item or subitem ID.

    Returns:
        Absolute path string to the activity directory.
    """
    team = get_team_from_item_id(item_id)
    kanban_dir = TEAM_KANBAN_DIRS.get(team)
    if kanban_dir is None:
        # Fall back to the default academy directory so logging never crashes
        # callers entirely, but surface a warning.
        warnings.warn(
            f"get_activity_dir: unknown team for item_id={item_id!r}, "
            f"falling back to default KANBAN_DIR",
            stacklevel=2,
        )
        kanban_dir = Path(KANBAN_DIR)

    activity_dir = Path(kanban_dir) / "activity"
    activity_dir.mkdir(parents=True, exist_ok=True)
    return str(activity_dir)


def _resolve_agent_from_tmux():
    """Resolve agent handle from tmux session name via amb-session-map.json.

    Returns the agent handle string, or None if resolution fails.
    """
    try:
        pane_target = os.environ.get("TMUX_PANE", "")
        if not pane_target and not os.environ.get("TMUX"):
            return None
        tmux_cmd = ["tmux", "display-message"]
        if pane_target:
            tmux_cmd.extend(["-t", pane_target])
        tmux_cmd.extend(["-p", "#S"])
        result = subprocess.run(tmux_cmd, capture_output=True, text=True, timeout=2)
        if result.returncode != 0:
            return None
        session_name = result.stdout.strip()
        if not session_name:
            return None
        session_map_file = os.path.expanduser("~/dev-team/amb-session-map.json")
        if not os.path.isfile(session_map_file):
            return None
        with open(session_map_file) as f:
            session_map = json.load(f)
        handle = session_map.get(session_name)
        # XACA-0628: overlay-only freelance projects reduce to the generic
        # 'freelance-<terminal>' key (no project-specific map entry exists).
        if not handle and session_name.startswith("freelance-"):
            handle = session_map.get("freelance-" + session_name.rsplit("-", 1)[-1])
        return handle
    except Exception:
        return None


def log_activity(
    action: str,
    target_id: str,
    target_type: str,
    field: str = None,
    old_value: str = None,
    new_value: str = None,
    context: str = None,
) -> None:
    """
    Append an activity entry to the item's activity log file.

    The log file lives at:
        <team-kanban-dir>/activity/<parent-item-id>.json

    File writes use exclusive fcntl locking and an atomic temp-file rename so
    concurrent callers never corrupt the log.  All exceptions are swallowed
    and surfaced as warnings — this function is fire-and-forget and must never
    raise.

    Args:
        action:      Short action label (e.g. "status_change", "created").
        target_id:   The item or subitem ID being acted on.
        target_type: "item" or "subitem".
        field:       Optional field name that changed.
        old_value:   Optional previous value of the field.
        new_value:   Optional new value of the field.
        context:     Optional free-form context string.
    """
    try:
        # Resolve agent identity from environment variables in priority order.
        agent = (
            os.environ.get("CLAUDE_AGENT_HANDLE")
            or os.environ.get("CLAUDE_CODENAME")
            or os.environ.get("LCARS_SESSION_NAME")
            or _resolve_agent_from_tmux()
            or "unknown"
        )

        parent_id = get_parent_item_id(target_id)
        activity_dir = get_activity_dir(target_id)
        activity_file = os.path.join(activity_dir, f"{parent_id}.json")
        lock_file = activity_file + ".lock"

        now = datetime.now(timezone.utc)
        timestamp = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"

        # Build entry dict, omitting None/null fields.
        entry = {
            "timestamp": timestamp,
            "agent": agent,
            "action": action,
            "target": target_id,
            "targetType": target_type,
        }
        if field is not None:
            entry["field"] = field
        if old_value is not None:
            entry["oldValue"] = old_value
        if new_value is not None:
            entry["newValue"] = new_value
        if context is not None:
            entry["context"] = context

        # Create lock file if needed.
        Path(lock_file).touch(exist_ok=True)

        with open(lock_file, "r+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                # Load or initialise the activity document.
                if os.path.exists(activity_file):
                    with open(activity_file, "r") as f:
                        doc = json.load(f)
                else:
                    doc = {
                        "entries": [],
                        "itemId": parent_id,
                        "created": timestamp,
                        "lastUpdated": timestamp,
                    }

                doc["entries"].append(entry)
                doc["lastUpdated"] = timestamp

                # Atomic write: temp file then rename.
                tmp_fd, tmp_path = tempfile.mkstemp(
                    dir=activity_dir, prefix=f"{parent_id}_", suffix=".tmp"
                )
                try:
                    with os.fdopen(tmp_fd, "w") as f:
                        json.dump(doc, f, indent=2)
                        f.flush()
                        os.fsync(f.fileno())
                    os.rename(tmp_path, activity_file)
                except Exception:
                    try:
                        os.remove(tmp_path)
                    except OSError:
                        pass
                    raise
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    except Exception as exc:
        warnings.warn(f"log_activity failed for {target_id!r}: {exc}", stacklevel=2)


def read_activity_log(
    item_id: str,
    limit: int = None,
    offset: int = 0,
    action_filter: str = None,
    agent_filter: str = None,
    subitem_filter: str = None,
) -> dict:
    """
    Read and optionally filter/paginate an activity log for an item.

    Args:
        item_id:        Item or subitem ID whose log to read.
        limit:          Maximum number of entries to return (None = all).
        offset:         Number of entries to skip from the beginning.
        action_filter:  If set, return only entries where action == action_filter.
        agent_filter:   If set, return only entries where agent == agent_filter.
        subitem_filter: If set, return only entries where target == subitem_filter.

    Returns:
        The activity document dict with a filtered ``entries`` list.
        Returns ``{"entries": [], "itemId": <parent_id>}`` if no log exists.
    """
    parent_id = get_parent_item_id(item_id)

    try:
        activity_dir = get_activity_dir(item_id)
    except Exception:
        return {"entries": [], "itemId": parent_id}

    activity_file = os.path.join(activity_dir, f"{parent_id}.json")

    if not os.path.exists(activity_file):
        return {"entries": [], "itemId": parent_id}

    lock_file = activity_file + ".lock"

    try:
        Path(lock_file).touch(exist_ok=True)

        with open(lock_file, "r") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_SH)
            try:
                with open(activity_file, "r") as f:
                    doc = json.load(f)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    except (json.JSONDecodeError, IOError):
        return {"entries": [], "itemId": parent_id}

    entries = doc.get("entries", [])

    # Apply filters.
    if action_filter is not None:
        entries = [e for e in entries if e.get("action") == action_filter]
    if agent_filter is not None:
        entries = [e for e in entries if e.get("agent") == agent_filter]
    if subitem_filter is not None:
        entries = [e for e in entries if e.get("target") == subitem_filter]

    # Newest first for display.
    entries = list(reversed(entries))

    # Apply pagination.
    entries = entries[offset:]
    if limit is not None:
        entries = entries[:limit]

    result = dict(doc)
    result["entries"] = entries
    return result
