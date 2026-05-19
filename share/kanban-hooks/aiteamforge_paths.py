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
from datetime import datetime
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
# kanban_dir       — absolute path to the live board directory
# working_dir      — parent of kanban_dir (= kanban_dir.parent)
# lcars_port_base  — first port in the template's band (XACA-0463)
# lcars_port_range — inclusive count of ports in band (XACA-0463)
# lcars_port       — DEPRECATED (XACA-0463): per-instance port, derived from
#                    band base at install time and persisted to team-paths.json;
#                    use lcars_port_base + lcars_port_range for band queries.
#                    None means not yet allocated (pre-migration install).
# ---------------------------------------------------------------------------

_HOME = str(Path.home())

DEFAULT_TEAMS: dict[str, dict[str, Any]] = {
    # ── Main Event Teams ──────────────────────────────────────────────────
    "academy": {
        "kanban_dir": f"{_HOME}/dev-team/kanban",
        "working_dir": f"{_HOME}/dev-team",
        "lcars_port_base": 8200,
        "lcars_port_range": 10,
        "lcars_port": 8203,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_ACADEMY_API_KEY",
    },
    "ios": {
        "kanban_dir": "/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/MainEventApp-iOS",
        "lcars_port_base": 8260,
        "lcars_port_range": 10,
        "lcars_port": 8260,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_IOS_API_KEY",
    },
    "android": {
        "kanban_dir": "/Users/Shared/Development/Main Event/MainEventApp-Android/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/MainEventApp-Android",
        "lcars_port_base": 8280,
        "lcars_port_range": 10,
        "lcars_port": 8280,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_ANDROID_API_KEY",
    },
    "firebase": {
        "kanban_dir": "/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/MainEventApp-Functions",
        "lcars_port_base": 8240,
        "lcars_port_range": 10,
        "lcars_port": 8240,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_FIREBASE_API_KEY",
    },
    "command": {
        "kanban_dir": "/Users/Shared/Development/Main Event/dev-team/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/dev-team",
        "lcars_port_base": 8230,
        "lcars_port_range": 10,
        "lcars_port": 8234,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_COMMAND_API_KEY",
    },
    "dns": {
        "kanban_dir": "/Users/Shared/Development/DNSFramework/kanban",
        "working_dir": "/Users/Shared/Development/DNSFramework",
        "lcars_port_base": 8180,
        "lcars_port_range": 10,
        "lcars_port": 8180,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_DNS_API_KEY",
    },

    # ── Freelance — DoubleNode ────────────────────────────────────────────
    "freelance-doublenode-starwords": {
        "kanban_dir": "/Users/Shared/Development/DoubleNode/Starwords/kanban",
        "working_dir": "/Users/Shared/Development/DoubleNode/Starwords",
        "lcars_port_base": 8500,
        "lcars_port_range": 100,
        "lcars_port": 8505,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_FREELANCE_DOUBLENODE_STARWORDS_API_KEY",
    },
    "freelance-doublenode-appplanning": {
        "kanban_dir": "/Users/Shared/Development/DoubleNode/appPlanning/kanban",
        "working_dir": "/Users/Shared/Development/DoubleNode/appPlanning",
        "lcars_port_base": 8500,
        "lcars_port_range": 100,
        "lcars_port": 8505,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_FREELANCE_DOUBLENODE_APPPLANNING_API_KEY",
    },
    "freelance-doublenode-workstats": {
        "kanban_dir": "/Users/Shared/Development/DoubleNode/WorkStats/kanban",
        "working_dir": "/Users/Shared/Development/DoubleNode/WorkStats",
        "lcars_port_base": 8500,
        "lcars_port_range": 100,
        "lcars_port": 8505,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_FREELANCE_DOUBLENODE_WORKSTATS_API_KEY",
    },
    "freelance-doublenode-lifeboard": {
        "kanban_dir": "/Users/Shared/Development/DoubleNode/LifeBoard/kanban",
        "working_dir": "/Users/Shared/Development/DoubleNode/LifeBoard",
        "lcars_port_base": 8500,
        "lcars_port_range": 100,
        "lcars_port": 8505,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_FREELANCE_DOUBLENODE_LIFEBOARD_API_KEY",
    },
    "freelance-doublenode-caravan": {
        "kanban_dir": "/Users/Shared/Development/DoubleNode/Caravan/kanban",
        "working_dir": "/Users/Shared/Development/DoubleNode/Caravan",
        "lcars_port_base": 8500,
        "lcars_port_range": 100,
        "lcars_port": 8505,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_FREELANCE_DOUBLENODE_CARAVAN_API_KEY",
    },
    "freelance-doublenode-awaysentry": {
        "kanban_dir": "/Users/Shared/Development/DoubleNode/AwaySentry/kanban",
        "working_dir": "/Users/Shared/Development/DoubleNode/AwaySentry",
        "lcars_port_base": 8500,
        "lcars_port_range": 100,
        "lcars_port": 8505,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_FREELANCE_DOUBLENODE_AWAYSENTRY_API_KEY",
    },

    # ── Freelance — Liquidstyle ───────────────────────────────────────────
    "freelance-liquidstyle-agentbadges-app": {
        "kanban_dir": "/Users/Shared/Development/Liquidstyle/AgentBadges-APP/kanban",
        "working_dir": "/Users/Shared/Development/Liquidstyle/AgentBadges-APP",
        "lcars_port_base": 8500,
        "lcars_port_range": 100,
        "lcars_port": 8960,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_FREELANCE_LIQUIDSTYLE_AGENTBADGES_APP_API_KEY",
    },
    "freelance-liquidstyle-agentbadges-ios": {
        "kanban_dir": "/Users/Shared/Development/Liquidstyle/AgentBadges-IOS/kanban",
        "working_dir": "/Users/Shared/Development/Liquidstyle/AgentBadges-IOS",
        "lcars_port_base": 8500,
        "lcars_port_range": 100,
        "lcars_port": 8970,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_FREELANCE_LIQUIDSTYLE_AGENTBADGES_IOS_API_KEY",
    },

    # ── Legal ─────────────────────────────────────────────────────────────
    "legal-coparenting": {
        "kanban_dir": f"{_HOME}/legal/coparenting/kanban",
        "working_dir": f"{_HOME}/legal/coparenting",
        "lcars_port_base": 8320,
        "lcars_port_range": 10,
        "lcars_port": None,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_LEGAL_COPARENTING_API_KEY",
    },

    # ── Medical ───────────────────────────────────────────────────────────
    "medical-general": {
        "kanban_dir": f"{_HOME}/medical/general/kanban",
        "working_dir": f"{_HOME}/medical/general",
        "lcars_port_base": 8340,
        "lcars_port_range": 10,
        "lcars_port": None,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_MEDICAL_GENERAL_API_KEY",
    },

    # ── Finance ───────────────────────────────────────────────────────────
    "finance-personal": {
        "kanban_dir": f"{_HOME}/finance/personal/kanban",
        "working_dir": f"{_HOME}/finance/personal",
        "lcars_port_base": 8360,
        "lcars_port_range": 10,
        "lcars_port": None,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_FINANCE_PERSONAL_API_KEY",
    },

    # ── Aliases (backward-compat, mirrors kanban_utils.py) ────────────────
    # NOTE (XACA-0463): mainevent moves from 8234 → 8400 to resolve the existing
    # command/mainevent collision. 8234 is in command's band [8230, 8240);
    # mainevent's authoritative band is [8400, 8410). This is the one deliberate
    # schema-time renumber — mainevent has no concrete team-paths.json entry to
    # be confused about. The kb-port-fix migration tool (subitem 005) handles
    # live team-paths.json entries; DEFAULT_TEAMS reflects the correct post-migration
    # value here so fresh installs get the right port immediately.
    "mainevent": {
        "kanban_dir": "/Users/Shared/Development/Main Event/dev-team/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/dev-team",
        "lcars_port_base": 8400,
        "lcars_port_range": 10,
        "lcars_port": 8400,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_MAINEVENT_API_KEY",
    },
    "medical": {
        # alias for medical-general
        "kanban_dir": f"{_HOME}/medical/general/kanban",
        "working_dir": f"{_HOME}/medical/general",
        "lcars_port_base": 8340,
        "lcars_port_range": 10,
        "lcars_port": None,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_MEDICAL_API_KEY",
    },
    "freelance": {
        # generic fallback — mirrors kanban_utils.py
        "kanban_dir": f"{_HOME}/dev-team/kanban",
        "working_dir": f"{_HOME}/dev-team",
        "lcars_port_base": 8500,
        "lcars_port_range": 100,
        "lcars_port": 8505,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_FREELANCE_API_KEY",
    },
}

# ---------------------------------------------------------------------------
# Internal config cache
# ---------------------------------------------------------------------------

_CONFIG_CACHE: dict | None = None
_CONFIG_PATH_AT_LOAD: str | None = None  # detect $AITEAMFORGE_CONFIG changes

SUPPORTED_SCHEMA_VERSION = 3

# Teams that MUST appear in any valid config.  If any are absent the config is
# considered corrupt and load_config() falls back to _bootstrap().  (XACA-0457)
CANONICAL_REQUIRED_TEAMS: frozenset[str] = frozenset({"academy"})

# At least ONE of these must be present.  A config with only "academy" and none
# of the platform teams is almost certainly a partial-write artifact.  (XACA-0457)
CANONICAL_AT_LEAST_ONE_TEAMS: frozenset[str] = frozenset({"ios", "android", "firebase", "dns"})


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
        # Backup-before-write so regressions ALWAYS leave a forensic trail. (XACA-0457)
        if config_path.exists():
            timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            backup_path = config_path.with_name(f"{config_path.name}.bak-{timestamp}")
            try:
                backup_path.write_bytes(config_path.read_bytes())
                print(
                    f"[aiteamforge-paths] backup snapshot: {backup_path}",
                    file=sys.stderr,
                )
            except OSError as exc:
                print(
                    f"[aiteamforge-paths] WARNING: failed to write backup snapshot {backup_path}: {exc}",
                    file=sys.stderr,
                )
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

    # Schema-integrity check (XACA-0457) — catch partial-write corruption where
    # JSON is technically valid but the config is missing required teams or the
    # schema_version field.  Must run BEFORE the `if config is None` branch so
    # a corrupted-but-parseable file triggers bootstrap, not silent degradation.
    if config is not None:
        has_schema = "schema_version" in config
        teams_keys = set(config.get("teams", {}).keys())
        missing_required = CANONICAL_REQUIRED_TEAMS - teams_keys
        has_canonical_one = bool(CANONICAL_AT_LEAST_ONE_TEAMS & teams_keys)
        if not has_schema or missing_required or not has_canonical_one:
            print(
                f"[aiteamforge-paths] WARNING: {config_path} appears corrupt "
                f"(has_schema_version={has_schema}, missing_required={sorted(missing_required)}, "
                f"has_canonical_subset={has_canonical_one}) — bootstrapping defaults",
                file=sys.stderr,
            )
            # Snapshot the corrupt file BEFORE nulling config — _bootstrap may
            # take the interactive-TTY path and skip _write_defaults, leaving
            # the corrupt file on disk without a forensic trail.  (XACA-0457-012)
            if config_path.exists():
                timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
                backup_path = config_path.with_name(
                    f"{config_path.name}.bak-{timestamp}"
                )
                try:
                    backup_path.write_bytes(config_path.read_bytes())
                    print(
                        f"[aiteamforge-paths] backup snapshot (corrupt config): {backup_path}",
                        file=sys.stderr,
                    )
                except OSError as exc:
                    print(
                        f"[aiteamforge-paths] WARNING: failed to write backup snapshot {backup_path}: {exc}",
                        file=sys.stderr,
                    )
            config = None

    if config is None:
        config = _bootstrap(config_path)

    # Validate schema_version — v1/v2/v3 all load cleanly; warn only for
    # unknown/future versions.  Missing new fields (v1/v2 configs lacking the
    # anthropic_* keys added in v3) are tolerated; downstream consumers that
    # need those fields should use .get() with empty-string defaults.
    _READABLE_SCHEMA_VERSIONS: frozenset[int] = frozenset({1, 2, 3})
    version = config.get("schema_version")
    if version not in _READABLE_SCHEMA_VERSIONS:
        print(
            f"[aiteamforge-paths] WARNING: schema_version={version!r} is not "
            f"recognized (readable: {sorted(_READABLE_SCHEMA_VERSIONS)}). Proceeding anyway.",
            file=sys.stderr,
        )

    # Ensure "teams" is populated — catches both missing key AND empty dict,
    # the latter being the failure mode that produced a silently-empty team map
    # (bug found on 2026-04-22 when corrupt config made every team lookup 404).
    if not config.get("teams"):
        print(
            "[aiteamforge-paths] WARNING: config has no populated 'teams' — using defaults",
            file=sys.stderr,
        )
        config["teams"] = DEFAULT_TEAMS

    _CONFIG_CACHE = config
    _CONFIG_PATH_AT_LOAD = config_path_str
    return _CONFIG_CACHE


def upgrade_config_to_v3(config: dict) -> dict:
    """Return a copy of *config* with v3 Anthropic account fields back-filled.

    Takes an existing v1 or v2 config dict (or any config missing the three
    new fields) and returns a new dict with:
      - schema_version bumped to 3
      - anthropic_account_id: "" (empty; user fills this in via wizard)
      - anthropic_account_nickname: "" (empty; user fills this in via wizard)
      - anthropic_api_key_env_var: "TEAM_<SLUG_UPPER>_API_KEY" derived from
        the team slug (hyphens replaced with underscores, uppercased)

    This function does NOT write anything to disk and is NOT called
    automatically from load_config().  It is reserved for the interactive
    account-routing wizard (XACA-0279 subitem 003) to invoke explicitly after
    the user has acknowledged the migration.

    The input config is never mutated; a deep copy is returned.

    Example::

        import copy
        old = load_config()
        new = upgrade_config_to_v3(copy.deepcopy(old))
        # inspect new, then write to disk if user approves
    """
    import copy
    upgraded = copy.deepcopy(config)
    upgraded["schema_version"] = 3

    for slug, entry in upgraded.get("teams", {}).items():
        if "anthropic_account_id" not in entry:
            entry["anthropic_account_id"] = ""
        if "anthropic_account_nickname" not in entry:
            entry["anthropic_account_nickname"] = ""
        if "anthropic_api_key_env_var" not in entry:
            env_var = f"TEAM_{slug.upper().replace('-', '_')}_API_KEY"
            entry["anthropic_api_key_env_var"] = env_var

    return upgraded


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


def get_team_memory_dir(team: str) -> Path | None:
    """Return the Claude auto-memory directory for the given team, or None.

    Claude Code encodes the project working directory as a directory name
    under ``~/.claude/projects/`` by replacing every ``/`` with ``-`` and
    prepending a ``-`` (so the leading ``/`` of an absolute path becomes a
    leading ``-``).  For example::

        /Users/darrenehlers/dev-team
        ->  -Users-darrenehlers-dev-team
        /Users/Shared/Development/Main Event/MainEventApp-iOS-DEV
        ->  -Users-Shared-Development-Main-Event-MainEventApp-iOS-DEV

    However, spaces in path components are also replaced with ``-``, so
    ``Main Event`` becomes ``Main-Event``.  The resulting slug is the name
    of the project directory, and the memory subdirectory lives inside it.

    Derivation strategy (in order):
      1. Derive the encoded slug from the team's ``working_dir``.
      2. Probe ``~/.claude/projects/<slug>/memory/`` for existence.
      3. If the derived slug doesn't exist, scan ``~/.claude/projects/``
         for a directory whose name starts with the derived slug (handles
         the ``-develop`` / ``-DEV`` suffix variants Claude Code appends
         when the working-dir checkout has a branch suffix).
      4. If no match exists, return ``None`` (memory dir absent — team has
         never been opened in Claude Code, or has no memory yet).

    Notes:
      - The function never raises for a missing team — it returns ``None``.
      - The function never creates the directory; it is read-only.
      - The team must exist in the config; otherwise ``KeyError`` is raised
        (consistent with ``get_team_kanban_dir``).

    Raises:
        KeyError: if the team is not found in the config.

    Returns:
        Path to the memory directory, or ``None`` if it does not exist.
    """
    config = load_config()
    entry = config["teams"].get(team)
    if entry is None:
        hint = _available_teams_hint(config)
        raise KeyError(
            f"Team '{team}' not found. Available: {hint} — "
            f"edit {get_config_path()} or run `aiteamforge-paths init`."
        )

    working_dir = Path(entry["working_dir"]).expanduser()

    # Encode the working_dir path as Claude Code does:
    #   1. Replace spaces with hyphens (spaces in dir names map to -)
    #   2. Replace / with -  (each path separator becomes -)
    #   3. The result already starts with - because abs path starts with /
    encoded = working_dir.as_posix().replace(" ", "-").replace("/", "-")
    # encoded now looks like: -Users-darrenehlers-dev-team

    projects_root = Path.home() / ".claude" / "projects"

    # Strategy 1: exact match
    exact = projects_root / encoded / "memory"
    if exact.is_dir():
        return exact

    # Strategy 2: prefix scan — handles -DEV, -develop, and other suffixes
    # that Claude Code appends when the working dir itself has a branch suffix
    # or when the user opened a subdirectory.
    try:
        for candidate in sorted(projects_root.iterdir()):
            if not candidate.is_dir():
                continue
            if candidate.name == encoded or candidate.name.startswith(encoded + "-"):
                mem = candidate / "memory"
                if mem.is_dir():
                    return mem
    except OSError:
        pass

    # No memory directory found for this team
    return None


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


def _resolve_template_band(template_id: str) -> tuple[int, int]:
    """Return (lcars_port_base, lcars_port_range) for *template_id*.

    Lookup strategy (in order):
    1. Direct key match in DEFAULT_TEAMS.
    2. Tolerant input: if template_id contains a dash, strip to first
       dash-separated component (base template) and retry direct lookup
       (handles "finance-personal" → "finance").
    3. Prefix scan: search DEFAULT_TEAMS for any key that starts with
       "<template_id>-" and inherit its band. This handles pure template
       ids like "finance" that only appear as "finance-personal" in
       DEFAULT_TEAMS.

    Raises:
        ValueError: if no matching entry or the entry has no band declared.
    """
    # 1. Direct lookup.
    entry = DEFAULT_TEAMS.get(template_id)

    # 2. Tolerant input: instance id passed; strip to base template.
    if entry is None and "-" in template_id:
        base_template = template_id.split("-")[0]
        entry = DEFAULT_TEAMS.get(base_template)

    # 3. Prefix scan: template id exists only as part of instance keys.
    if entry is None:
        prefix = template_id + "-"
        for key, candidate in DEFAULT_TEAMS.items():
            if key.startswith(prefix) and candidate.get("lcars_port_base") is not None:
                entry = candidate
                break

    if entry is None:
        raise ValueError(
            f"Template '{template_id}' has no lcars_port_base declared "
            f"(not found in DEFAULT_TEAMS directly, by stripping dashes, "
            f"or via prefix scan)."
        )

    base = entry.get("lcars_port_base")
    band_range = entry.get("lcars_port_range")
    if base is None:
        raise ValueError(
            f"Template '{template_id}' has no lcars_port_base declared."
        )
    if band_range is None:
        raise ValueError(
            f"Template '{template_id}' has no lcars_port_range declared."
        )
    return int(base), int(band_range)


def compute_instance_port(template_id: str, existing_team_paths: dict) -> int:
    """Allocate the lowest free port in the template's band.

    Per XACA-0463 / team-id-contract §4.1: each template owns a port band
    declared as TEAM_LCARS_PORT_BASE + TEAM_LCARS_PORT_RANGE. The lowest
    port in the half-open interval [base, base+range) that is NOT already
    used by any entry in existing_team_paths["teams"][*]["lcars_port"] is
    returned. Cross-template collisions are honored (a port owned by
    another template is still considered taken).

    Args:
        template_id: A template id (e.g. "finance", "freelance"). MUST
            match a key in DEFAULT_TEAMS *with* lcars_port_base set, OR
            be derivable via splitting on '-' and taking the first segment
            (tolerant input: "finance-personal" resolves to "finance").
        existing_team_paths: The parsed contents of team-paths.json,
            shape {"teams": {"<instance>": {"lcars_port": int | None, ...}}}.

    Returns:
        The chosen port (int).

    Raises:
        ValueError: template unknown, band not declared, or band exhausted.
    """
    base, band_range = _resolve_template_band(template_id)

    # Collect every port already in use, across ALL templates.
    used_ports: set[int] = {
        int(entry["lcars_port"])
        for entry in existing_team_paths.get("teams", {}).values()
        if entry.get("lcars_port") is not None
    }

    for port in range(base, base + band_range):
        if port not in used_ports:
            return port

    # Band fully exhausted.
    used_in_band = [p for p in used_ports if base <= p < base + band_range]
    raise ValueError(
        f"Port band exhausted for template '{template_id}': "
        f"band [{base}, {base + band_range}), "
        f"{len(used_in_band)} of {band_range} used. "
        f"Extend TEAM_LCARS_PORT_RANGE in <template>.conf and rerun."
    )


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
        # Backup-before-write so future regressions ALWAYS leave a forensic trail. (XACA-0457)
        if config_path.exists():
            timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            backup_path = config_path.with_name(f"{config_path.name}.bak-{timestamp}")
            try:
                backup_path.write_bytes(config_path.read_bytes())
                print(
                    f"[aiteamforge-paths] backup snapshot: {backup_path}",
                    file=sys.stderr,
                )
            except OSError as exc:
                print(
                    f"[aiteamforge-paths] WARNING: failed to write backup snapshot {backup_path}: {exc}",
                    file=sys.stderr,
                )
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
