#!/usr/bin/env python3
"""
aiteamforge_paths.py — Canonical team path config loader.

XACA-0168-001 — Wave 1: Config schema + loader module

Design
------
This module is the single source of truth for team → kanban/working directory
mappings.  Previously these lived as hardcoded dicts in 31+ Python and shell
files (TEAM_KANBAN_DIRS in kanban_utils.py, server.py, etc.) and case
statements in kanban-helpers.sh.  This module replaces all of them by loading
from ~/.aiteamforge/team-paths.json (or the path in $AITEAMFORGE_CONFIG).

Config file schema (schema_version 1):
    {
      "schema_version": 1,
      "teams": {
        "<team-id>": {
          "kanban_dir": "/abs/path/to/kanban",
          "working_dir": "/abs/path/to/working",   # parent of kanban_dir
          "lcars_port": 8203                         # optional, int
        },
        ...
      }
    }

Bootstrap behaviour (when config is missing or corrupt):
    - Interactive TTY  → print a human-readable "run init" message to stderr,
      then fall back to DEFAULT_TEAMS so nothing breaks.
    - Non-interactive  → silently write DEFAULT_TEAMS to the config file,
      log one line to stderr.

Module-level side effects
    NONE.  All I/O happens on first function call, not at import time.
    The config is cached in _CONFIG_CACHE after the first load.

Usage
-----
    from aiteamforge_paths import get_team_kanban_dir, list_teams
    kanban = get_team_kanban_dir("academy")  # -> Path
    teams  = list_teams()                    # -> ["academy", "android", ...]

Consumers still importing TEAM_KANBAN_DIRS directly from kanban_utils should
migrate to this module (Wave 3, XACA-0168-006 onwards).  For now both exist.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Config path
# ---------------------------------------------------------------------------

def get_config_path() -> Path:
    """Return the path to team-paths.json, honouring $AITEAMFORGE_CONFIG."""
    override = os.environ.get("AITEAMFORGE_CONFIG", "")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".aiteamforge" / "team-paths.json"


# ---------------------------------------------------------------------------
# Baked-in defaults — the migration baseline.
#
# These MUST match the hardcoded values in:
#   - kanban-hooks/kanban_utils.py  TEAM_KANBAN_DIRS
#   - lcars-ui/server.py            TEAM_KANBAN_DIRS
#   - kanban-helpers.sh             _kb_get_kanban_dir() case statement
#   - kanban-helpers.sh             TEAM_PORTS associative array (lcars_port)
#   - lcars-health-check.sh         LCARS_SERVERS array
#
# If you add a team here, also update the shell DEFAULT_TEAMS heredoc in
# homebrew-tap/libexec/lib/aiteamforge-paths.sh (kept in sync by hand until
# Wave 4 automation lands).
#
# kanban_dir  — absolute path to the live board directory
# working_dir — parent of kanban_dir (= kanban_dir.parent)
# lcars_port  — local port for this team's LCARS server, or None
# ---------------------------------------------------------------------------

_HOME = str(Path.home())

DEFAULT_TEAMS: dict[str, dict[str, Any]] = {
    # ── Main Event Teams ──────────────────────────────────────────────────
    "academy": {
        "kanban_dir": f"{_HOME}/dev-team/kanban",
        "working_dir": f"{_HOME}/dev-team",
        "lcars_port": 8203,
    },
    "ios": {
        "kanban_dir": "/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/MainEventApp-iOS",
        "lcars_port": 8260,
    },
    "android": {
        "kanban_dir": "/Users/Shared/Development/Main Event/MainEventApp-Android/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/MainEventApp-Android",
        "lcars_port": 8280,
    },
    "firebase": {
        "kanban_dir": "/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/MainEventApp-Functions",
        "lcars_port": 8240,
    },
    "command": {
        "kanban_dir": "/Users/Shared/Development/Main Event/dev-team/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/dev-team",
        "lcars_port": 8234,
    },
    "dns": {
        "kanban_dir": "/Users/Shared/Development/DNSFramework/kanban",
        "working_dir": "/Users/Shared/Development/DNSFramework",
        "lcars_port": 8180,
    },

    # ── Freelance — DoubleNode ────────────────────────────────────────────
    "freelance-doublenode-starwords": {
        "kanban_dir": "/Users/Shared/Development/DoubleNode/Starwords/kanban",
        "working_dir": "/Users/Shared/Development/DoubleNode/Starwords",
        "lcars_port": 8505,
    },
    "freelance-doublenode-appplanning": {
        "kanban_dir": "/Users/Shared/Development/DoubleNode/appPlanning/kanban",
        "working_dir": "/Users/Shared/Development/DoubleNode/appPlanning",
        "lcars_port": 8505,
    },
    "freelance-doublenode-workstats": {
        "kanban_dir": "/Users/Shared/Development/DoubleNode/WorkStats/kanban",
        "working_dir": "/Users/Shared/Development/DoubleNode/WorkStats",
        "lcars_port": 8505,
    },
    "freelance-doublenode-lifeboard": {
        "kanban_dir": "/Users/Shared/Development/DoubleNode/LifeBoard/kanban",
        "working_dir": "/Users/Shared/Development/DoubleNode/LifeBoard",
        "lcars_port": 8505,
    },
    "freelance-doublenode-caravan": {
        "kanban_dir": "/Users/Shared/Development/DoubleNode/Caravan/kanban",
        "working_dir": "/Users/Shared/Development/DoubleNode/Caravan",
        "lcars_port": 8505,
    },
    "freelance-doublenode-awaysentry": {
        "kanban_dir": "/Users/Shared/Development/DoubleNode/AwaySentry/kanban",
        "working_dir": "/Users/Shared/Development/DoubleNode/AwaySentry",
        "lcars_port": 8505,
    },

    # ── Freelance — Liquidstyle ───────────────────────────────────────────
    "freelance-liquidstyle-agentbadges-app": {
        "kanban_dir": "/Users/Shared/Development/Liquidstyle/AgentBadges-APP/kanban",
        "working_dir": "/Users/Shared/Development/Liquidstyle/AgentBadges-APP",
        "lcars_port": 8960,
    },
    "freelance-liquidstyle-agentbadges-ios": {
        "kanban_dir": "/Users/Shared/Development/Liquidstyle/AgentBadges-IOS/kanban",
        "working_dir": "/Users/Shared/Development/Liquidstyle/AgentBadges-IOS",
        "lcars_port": 8970,
    },

    # ── Legal ─────────────────────────────────────────────────────────────
    "legal-coparenting": {
        "kanban_dir": f"{_HOME}/legal/coparenting/kanban",
        "working_dir": f"{_HOME}/legal/coparenting",
        "lcars_port": None,
    },

    # ── Medical ───────────────────────────────────────────────────────────
    "medical-general": {
        "kanban_dir": f"{_HOME}/medical/general/kanban",
        "working_dir": f"{_HOME}/medical/general",
        "lcars_port": None,
    },

    # ── Finance ───────────────────────────────────────────────────────────
    "finance-personal": {
        "kanban_dir": f"{_HOME}/finance/personal/kanban",
        "working_dir": f"{_HOME}/finance/personal",
        "lcars_port": None,
    },

    # ── Aliases (backward-compat, mirrors kanban_utils.py) ────────────────
    "mainevent": {
        "kanban_dir": "/Users/Shared/Development/Main Event/dev-team/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/dev-team",
        "lcars_port": 8234,
    },
    "medical": {
        # alias for medical-general
        "kanban_dir": f"{_HOME}/medical/general/kanban",
        "working_dir": f"{_HOME}/medical/general",
        "lcars_port": None,
    },
    "freelance": {
        # generic fallback — mirrors kanban_utils.py
        "kanban_dir": f"{_HOME}/dev-team/kanban",
        "working_dir": f"{_HOME}/dev-team",
        "lcars_port": 8505,
    },
}

# ---------------------------------------------------------------------------
# Internal config cache
# ---------------------------------------------------------------------------

_CONFIG_CACHE: dict | None = None
_CONFIG_PATH_AT_LOAD: str | None = None  # detect $AITEAMFORGE_CONFIG changes

SUPPORTED_SCHEMA_VERSION = 1


def _make_default_config() -> dict:
    """Build a config dict from DEFAULT_TEAMS, ready to write as JSON."""
    return {
        "schema_version": SUPPORTED_SCHEMA_VERSION,
        "teams": DEFAULT_TEAMS,
    }


def _write_defaults(config_path: Path) -> None:
    """Write DEFAULT_TEAMS to config_path (non-interactive bootstrap)."""
    try:
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text(
            json.dumps(_make_default_config(), indent=2) + "\n",
            encoding="utf-8",
        )
    except OSError as exc:
        print(
            f"[aiteamforge-paths] WARNING: could not write default config to "
            f"{config_path}: {exc}",
            file=sys.stderr,
        )


def _interactive_tty() -> bool:
    """Return True if stdin is a real terminal (interactive session)."""
    try:
        return os.isatty(sys.stdin.fileno())
    except Exception:
        return False


def _bootstrap(config_path: Path) -> dict:
    """Handle missing/corrupt config.  Returns a usable config dict."""
    if _interactive_tty():
        print(
            f"[aiteamforge-paths] Config not found at {config_path}.\n"
            f"  Run: aiteamforge-paths init\n"
            f"  Falling back to built-in defaults.",
            file=sys.stderr,
        )
    else:
        print(
            f"[aiteamforge-paths] Config missing — writing defaults to {config_path}",
            file=sys.stderr,
        )
        _write_defaults(config_path)

    return _make_default_config()


def _available_teams_hint(config: dict) -> str:
    """Return a comma-separated list of team names for error messages."""
    teams = list(config.get("teams", {}).keys())
    # Filter out alias names to keep the hint shorter
    primary = [t for t in teams if t not in ("mainevent", "medical", "freelance")]
    return ", ".join(sorted(primary)) or "(none)"


# ---------------------------------------------------------------------------
# Public API — load_config and friends
# ---------------------------------------------------------------------------

def load_config() -> dict:
    """Load, validate, and cache the team-paths config.

    On missing config: bootstraps (see _bootstrap).
    On unknown schema_version: warns but continues.
    On corrupt JSON: bootstraps.

    Returns a dict with at least {"schema_version": int, "teams": dict}.
    Never raises.
    """
    global _CONFIG_CACHE, _CONFIG_PATH_AT_LOAD

    config_path = get_config_path()
    config_path_str = str(config_path)

    # Re-load if env var changed (important for tests)
    if _CONFIG_CACHE is not None and _CONFIG_PATH_AT_LOAD == config_path_str:
        return _CONFIG_CACHE

    config: dict | None = None

    if config_path.exists():
        try:
            raw = config_path.read_text(encoding="utf-8")
            config = json.loads(raw)
        except (json.JSONDecodeError, OSError) as exc:
            print(
                f"[aiteamforge-paths] WARNING: could not parse {config_path}: {exc} — using defaults",
                file=sys.stderr,
            )
            config = None

    if config is None:
        config = _bootstrap(config_path)

    # Validate schema_version
    version = config.get("schema_version")
    if version != SUPPORTED_SCHEMA_VERSION:
        print(
            f"[aiteamforge-paths] WARNING: schema_version={version!r} is not "
            f"supported (expected {SUPPORTED_SCHEMA_VERSION}). Proceeding anyway.",
            file=sys.stderr,
        )

    # Ensure "teams" key exists
    if "teams" not in config:
        print(
            "[aiteamforge-paths] WARNING: config has no 'teams' key — using defaults",
            file=sys.stderr,
        )
        config["teams"] = DEFAULT_TEAMS

    _CONFIG_CACHE = config
    _CONFIG_PATH_AT_LOAD = config_path_str
    return _CONFIG_CACHE


# ---------------------------------------------------------------------------
# Team accessor functions
# ---------------------------------------------------------------------------

def list_teams() -> list[str]:
    """Return all team IDs defined in the config."""
    config = load_config()
    return list(config["teams"].keys())


def get_team_kanban_dir(team: str) -> Path:
    """Return the kanban directory Path for the given team.

    Raises KeyError with a helpful message if the team is not found.
    """
    config = load_config()
    entry = config["teams"].get(team)
    if entry is None:
        hint = _available_teams_hint(config)
        raise KeyError(
            f"Team '{team}' not found. Available: {hint} — "
            f"edit {get_config_path()} or run `aiteamforge-paths init`."
        )
    return Path(entry["kanban_dir"]).expanduser()


def get_team_working_dir(team: str) -> Path:
    """Return the working directory Path for the given team.

    The working_dir is the parent of kanban_dir (the project root).

    Raises KeyError with a helpful message if the team is not found.
    """
    config = load_config()
    entry = config["teams"].get(team)
    if entry is None:
        hint = _available_teams_hint(config)
        raise KeyError(
            f"Team '{team}' not found. Available: {hint} — "
            f"edit {get_config_path()} or run `aiteamforge-paths init`."
        )
    return Path(entry["working_dir"]).expanduser()


def get_team_lcars_port(team: str) -> int | None:
    """Return the LCARS port for the given team, or None if not applicable.

    Raises KeyError with a helpful message if the team is not found.
    """
    config = load_config()
    entry = config["teams"].get(team)
    if entry is None:
        hint = _available_teams_hint(config)
        raise KeyError(
            f"Team '{team}' not found. Available: {hint} — "
            f"edit {get_config_path()} or run `aiteamforge-paths init`."
        )
    port = entry.get("lcars_port")
    return int(port) if port is not None else None


# ---------------------------------------------------------------------------
# Wizard hook (for subitem 002 — interactive setup wizard)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Export / backup exclusion rules — XACA-0168-017
#
# These are the canonical exclusion patterns for kanban directory backups.
# kanban-backup.py imports these instead of defining them inline.
# ---------------------------------------------------------------------------

#: File suffixes excluded from backup archives and delta-hash computation.
EXPORT_EXCLUSION_SUFFIXES: frozenset[str] = frozenset({".lock"})

#: Exact filenames excluded from backup archives and delta-hash computation.
EXPORT_EXCLUSION_NAMES: frozenset[str] = frozenset({".DS_Store", "firebase-debug.log"})

#: Glob-style patterns excluded from backup archives and delta-hash computation.
#: Matched with Path.match() against each candidate file path.
EXPORT_EXCLUSION_PATTERNS: tuple[str, ...] = ("*-debug.log",)


def is_excluded_from_export(filepath: "Path") -> bool:  # type: ignore[name-defined]
    """Return True if *filepath* should be excluded from backup/export.

    Checks EXPORT_EXCLUSION_SUFFIXES, EXPORT_EXCLUSION_NAMES, and
    EXPORT_EXCLUSION_PATTERNS in order.  Import Path from pathlib before use.
    """
    name = filepath.name
    if name in EXPORT_EXCLUSION_NAMES:
        return True
    if filepath.suffix in EXPORT_EXCLUSION_SUFFIXES:
        return True
    for pattern in EXPORT_EXCLUSION_PATTERNS:
        if filepath.match(pattern):
            return True
    return False


def wizard_hook_create_config(teams_dict: dict, force: bool = False) -> bool:
    """Create or overwrite the config file with the provided teams_dict.

    Called by the interactive setup wizard (XACA-0168-002) after collecting
    team paths from the user.

    Args:
        teams_dict: dict mapping team IDs to {"kanban_dir", "working_dir",
                    "lcars_port"} entries.
        force:      If True, overwrite an existing config file.

    Returns:
        True on success, False on failure.
    """
    global _CONFIG_CACHE, _CONFIG_PATH_AT_LOAD

    config_path = get_config_path()
    if config_path.exists() and not force:
        print(
            f"[aiteamforge-paths] Config already exists at {config_path}. "
            "Pass force=True to overwrite.",
            file=sys.stderr,
        )
        return False

    config = {
        "schema_version": SUPPORTED_SCHEMA_VERSION,
        "teams": teams_dict,
    }
    try:
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text(
            json.dumps(config, indent=2) + "\n",
            encoding="utf-8",
        )
        # Invalidate cache so the next load_config() re-reads the file
        _CONFIG_CACHE = None
        _CONFIG_PATH_AT_LOAD = None
        return True
    except OSError as exc:
        print(
            f"[aiteamforge-paths] ERROR: could not write config: {exc}",
            file=sys.stderr,
        )
        return False
