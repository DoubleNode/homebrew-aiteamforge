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

XACA-0658: Versioned release-push flow — optional per-team keys (schema_version 2+)
----------------------------------------------------------------------------
The following keys are OPTIONAL and backward-compatible.  Teams that omit them
continue to work exactly as before.  Do NOT bump schema_version when adding
these keys — they are additive extensions.

Key: version_sources (list)
    A list of per-platform version-source entries.  Each entry describes how to
    locate, read, and write the authoritative version string for a given platform.

    [
      {
        "platform":      "ios",                                # required
        "file":          "MainEventApp.xcodeproj/project.pbxproj",  # required, relative to working_dir
        "match_pattern": "MARKETING_VERSION = {version};",    # required; {version} is a placeholder
        "write_pattern": "MARKETING_VERSION = {version};",    # required; {version} replaced with target
        "encoding":      "utf-8",                             # optional, default "utf-8"
        "replace_all":   true                                 # optional, default false
      },
      ...
    ]

    match_pattern / write_pattern: {version} is expanded to a semver capture-
    group regex ([0-9]+\\.[0-9]+(?:\\.[0-9]+)?) for reading, or to the literal
    target version string for writing.

    replace_all: When true (e.g. pbxproj has multiple MARKETING_VERSION lines),
    replace ALL matches.  When false (default), replace first match only.

    If version_sources is absent for a team, the version gate is skipped with a
    stderr warning, preserving backward compatibility.

Key: relnotes_sources (list)
    A list of per-platform relnotes-directory entries.  Each entry specifies
    which directory holds RELNOTES-<ENV>.md files for a given platform.

    [
      {
        "platform": "ios",      # required
        "dir":      "."         # required, relative to working_dir
      },
      ...
    ]

    If relnotes_sources is absent, the RELNOTES promotion step defaults to
    working_dir for each platform.

Key: branch_env_map (object)
    Maps exact branch names to environment stage strings OR per-platform
    environment maps.  Two forms are accepted:

    String form (all-platforms shorthand):
        {
          "develop": "DEV",
          "release/qa": "QA"
        }
    The string value means "promote ALL platforms on the active release to
    this environment."  At read time the normalizer expands it to
    {platform: env} for every platform in the release.

    Object form (per-platform precise):
        {
          "develop": {"ios": "DEV", "android": "DEV"},
          "release/qa": {"ios": "QA", "android": "QA", "firebase": "QA"}
        }
    Each value is an object mapping platform → environment.

    Branch names are matched exactly (no glob support in v1).

    If branch_env_map is absent, branch-push auto-promotion is disabled for
    that team.

    normalize_branch_env(branch_map_value, release_platforms) normalizes either
    form to {platform: env} given the release's platform list.
----------------------------------------------------------------------------

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

import fcntl
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
        "team_code": "ACA",
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
        "team_code": "IOS",
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
        "team_code": "AND",
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
        "team_code": "FIR",
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
        "team_code": "CMD",
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
        "team_code": "DNS",
        "kanban_dir": "/Users/Shared/Development/DNSFramework/kanban",
        "working_dir": "/Users/Shared/Development/DNSFramework",
        "lcars_port_base": 8180,
        "lcars_port_range": 10,
        "lcars_port": 8180,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_DNS_API_KEY",
    },

    # ── Freelance — per-client/project entries (overlay-only, XACA-0628) ──
    # The 9 per-CLIENT/PROJECT freelance slugs (DoubleNode/Liquidstyle/Bandwear)
    # were removed from DEFAULT_TEAMS in XACA-0628 and now live solely in the
    # per-machine overlay (~/.aiteamforge/team-paths.json). build_team_code_map()
    # MERGES overlay team_codes on top of these defaults, so the overlay entries
    # (FSW/FAP/FWS/FLB/VAN/FAS/FLA/FLI/BWA/BWD) supply routing on machines that
    # actually host those client repos. XACA-0643 removed the bare `freelance`
    # (FRE) alias that used to sit here — it is a parameterized template, so a
    # bare key violates the team-id contract (the server dropped it on every
    # read). freelance therefore has NO seeded instance in DEFAULT_TEAMS; its
    # canonical port band lives in `_TEMPLATE_PORT_BANDS` so port allocation
    # still works for freelance-<client>-<project> installs.

    # ── Legal ─────────────────────────────────────────────────────────────
    "legal-coparenting": {
        "team_code": "LCP",
        "kanban_dir": f"{_HOME}/legal/coparenting/kanban",
        "working_dir": f"{_HOME}/legal/coparenting",
        "lcars_port_base": 8320,
        "lcars_port_range": 10,
        "lcars_port": 8320,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_LEGAL_COPARENTING_API_KEY",
    },

    # ── Medical ───────────────────────────────────────────────────────────
    "medical-general": {
        "team_code": "MED",
        "kanban_dir": f"{_HOME}/medical/general/kanban",
        "working_dir": f"{_HOME}/medical/general",
        "lcars_port_base": 8340,
        "lcars_port_range": 10,
        "lcars_port": 8340,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_MEDICAL_GENERAL_API_KEY",
    },

    # ── Finance ───────────────────────────────────────────────────────────
    "finance-personal": {
        "team_code": "FIN",
        "kanban_dir": f"{_HOME}/finance/personal/kanban",
        "working_dir": f"{_HOME}/finance/personal",
        "lcars_port_base": 8360,
        "lcars_port_range": 10,
        "lcars_port": 8360,
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
        "team_code": "MEV",
        "kanban_dir": "/Users/Shared/Development/Main Event/dev-team/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/dev-team",
        "lcars_port_base": 8400,
        "lcars_port_range": 10,
        "lcars_port": 8400,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_MAINEVENT_API_KEY",
    },
    # XACA-0643: bare "medical" and "freelance" aliases REMOVED. They are
    # parameterized templates (medical needs a project; freelance needs
    # client+project) per the team-id contract, so a bare key is a contract
    # violation — lcars-ui/server.py:_filter_contract_violating_teams() already
    # drops them with a loud warning on every read. Seeding them here just
    # produced the warning noise + invalid team-paths.json keys. The concrete
    # instances ("medical-general", "freelance-<client>-<project>") are the
    # only valid forms. "mainevent" stays above: it is NOT parameterized
    # (single instance), so a bare key is legitimate.
}

# ---------------------------------------------------------------------------
# Internal config cache
# ---------------------------------------------------------------------------

_CONFIG_CACHE: dict | None = None
_CONFIG_PATH_AT_LOAD: str | None = None  # detect $AITEAMFORGE_CONFIG changes
_A1_BACKFILL_ATTEMPTED: bool = False  # once-per-process guard (XACA-0522)
_CONTRACT_SCRUB_ATTEMPTED: bool = False  # once-per-process guard (XACA-0643)

SUPPORTED_SCHEMA_VERSION = 3

# Teams that MUST appear in any valid config.  If any are absent the config is
# considered corrupt and load_config() falls back to _bootstrap().  (XACA-0457)
CANONICAL_REQUIRED_TEAMS: frozenset[str] = frozenset({"academy"})


def teams_satisfy_canonical_guard(teams_keys) -> tuple[frozenset, bool]:
    """Canonical-team structural guard — SINGLE SOURCE OF TRUTH (XACA-0647).

    Returns (missing_required, has_non_required) for a set of team-name keys:
      - missing_required: CANONICAL_REQUIRED_TEAMS absent from the set (academy).
      - has_non_required: True iff at least one team beyond the required set exists.

    NOTE (XACA-0705): The validity rule is NOT "not missing_required and has_non_required"
    anymore — see config_is_structurally_valid() for the authoritative predicate.
    The old academy-required rule wrongly clobbered consumer configs that have zero
    academy team (custom-only installs). The canonical corruption signatures remain:
    no schema_version, OR empty teams, OR academy-alone (has_non_required=False).

    Both load_config() (this module) and lcars-ui/server.py's
    _build_team_kanban_dirs() call config_is_structurally_valid() so the validity
    rule cannot drift across the two sites (ends the k501 two-site sibling drift).
    (XACA-0457 / XACA-0647 / XACA-0705)
    """
    teams_keys = set(teams_keys)
    missing_required = CANONICAL_REQUIRED_TEAMS - teams_keys
    has_non_required = bool(teams_keys - CANONICAL_REQUIRED_TEAMS)
    return frozenset(missing_required), has_non_required


def config_is_structurally_valid(teams_keys, has_schema: bool) -> bool:
    """Return True iff a parsed config is structurally sound — SINGLE SOURCE OF
    TRUTH for the load_config() and server.py _build_team_kanban_dirs() guard.

    Valid iff ALL of:
      1. schema_version key is present (has_schema=True)
      2. at least one NON-academy team exists (has_non_required=True)

    Corruption signatures (→ bootstrap / fallback):
      - missing schema_version
      - empty teams dict  (has_non_required=False)
      - academy-alone     (has_non_required=False — same check as empty)

    XACA-0705: The prior rule required academy to be present (missing_required
    must be empty). That wrongly clobbered consumer installs whose team-paths.json
    has only a custom non-academy team (e.g. a freelance-only box). The fix:
    drop the academy-required constraint from the validity test. Academy absence
    is now only a diagnostic hint, not a corruption signal.

    Truth table:
      {custom-instance-team}         → VALID  (consumer fix)
      {academy}                      → corrupt (academy-alone, no non-required)
      {}                             → corrupt (empty)
      {academy, ios, ...}            → VALID  (normal dev box)
      missing schema_version         → corrupt

    SIBLING-DRIFT NOTE: this function is called in EXACTLY TWO places:
      1. kanban-hooks/aiteamforge_paths.py — load_config()
      2. lcars-ui/server.py — _build_team_kanban_dirs()
    Both sites import this function. If you add a third call site, update this
    comment. Never inline the validity logic at a call site. (XACA-0705 / k501)
    """
    _, has_non_required = teams_satisfy_canonical_guard(teams_keys)
    return has_schema and has_non_required


# Templates that REQUIRE one or more parameters (project, or client+project) per
# the team-id contract (docs/architecture/team-id-contract.md §3). A bare key
# like "freelance" or "medical" in a config's "teams" map is a contract
# violation — valid keys are instance ids ("medical-general",
# "freelance-doublenode-starwords"). This is the SINGLE SOURCE OF TRUTH: both
# lcars-ui/server.py and homebrew-tap/libexec/commands/kb-port-fix.py import this
# frozenset (with a literal fallback) so they cannot drift. (XACA-0643)
_PARAMETERIZED_TEMPLATES: frozenset[str] = frozenset({"finance", "legal", "medical", "freelance"})

# Canonical LCARS port band (base, range) for parameterized templates that have
# NO seeded instance in DEFAULT_TEAMS — so _resolve_template_band()'s direct/
# strip-dash/prefix-scan steps can't find a band. freelance is client+project
# only (XACA-0628 purged the client roster; XACA-0643 removed the bare alias),
# yet kb-port-fix still needs its band to renumber freelance-<client>-<project>
# installs. finance/legal/medical resolve via their seeded *-instance entries and
# intentionally are NOT duplicated here (avoids band drift). (XACA-0643)
_TEMPLATE_PORT_BANDS: dict[str, tuple[int, int]] = {
    "freelance": (8500, 100),
}


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
    # Filter out the non-parameterized alias name to keep the hint shorter.
    # (medical/freelance bare aliases removed in XACA-0643.)
    primary = [t for t in teams if t not in ("mainevent",)]
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
    global _CONFIG_CACHE, _CONFIG_PATH_AT_LOAD, _A1_BACKFILL_ATTEMPTED, _CONTRACT_SCRUB_ATTEMPTED

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
        # XACA-0705: validity rule lives in config_is_structurally_valid() — the
        # single source of truth shared with lcars-ui/server.py (ends k501 drift).
        # Valid iff schema_version present AND at least one non-academy team exists.
        # Academy absence is a diagnostic hint only, NOT a corruption signal (fixes
        # consumer installs that have no academy team in their overlay).
        missing_required, has_non_required = teams_satisfy_canonical_guard(teams_keys)
        if not config_is_structurally_valid(teams_keys, has_schema):
            print(
                f"[aiteamforge-paths] WARNING: {config_path} appears corrupt "
                f"(has_schema_version={has_schema}, missing_required={sorted(missing_required)}, "
                f"has_non_required_team={has_non_required}) — bootstrapping defaults",
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

    # Contract scrub (XACA-0643) — self-heal configs written before XACA-0643,
    # which seeded bare parameterized-template keys ("medical", "freelance").
    # Those keys are contract violations that lcars-ui/server.py drops with a
    # loud warning on every read; removing them here stops the noise on existing
    # machines. Flag-flipped BEFORE the call (same once-per-process discipline
    # as the A.1 backfill below). Runs first so the backfill operates on the
    # already-cleaned team set.
    if not _CONTRACT_SCRUB_ATTEMPTED:
        _CONTRACT_SCRUB_ATTEMPTED = True
        maybe_scrubbed = _scrub_contract_violating_keys_on_disk(config_path, config)
        if maybe_scrubbed is not None:
            config = maybe_scrubbed

    # A.1 backfill (XACA-0522) — flag-flipped BEFORE the call so even a failed
    # disk write doesn't cause a second lock attempt within the same process.
    if not _A1_BACKFILL_ATTEMPTED:
        _A1_BACKFILL_ATTEMPTED = True
        maybe_upgraded = _backfill_a1_fields_on_disk(config_path, config)
        if maybe_upgraded is not None:
            config = maybe_upgraded

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

    This function is a pure transformer — it never touches disk.  It IS now
    called automatically from ``load_config()`` (XACA-0522) via the
    ``_backfill_a1_fields_on_disk`` wrapper, which adds the disk-write half.
    The pure half remains here for unit-testability and for any future
    explicit-invocation path.

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


def diff_missing_anthropic_fields(config: dict) -> list[tuple[str, list[str]]]:
    """Return [(team_slug, [missing_field_names, ...]), ...] for teams needing backfill.

    Empty list means no migration needed (skip-fast).  The three fields checked
    are ``anthropic_account_id``, ``anthropic_account_nickname``, and
    ``anthropic_api_key_env_var``.

    A field is considered missing only when the KEY is absent from the team
    entry.  An empty-string value is NOT missing and is preserved as-is by the
    subsequent upgrade.
    """
    _FIELDS = ("anthropic_account_id", "anthropic_account_nickname", "anthropic_api_key_env_var")
    result = []
    for slug, entry in sorted(config.get("teams", {}).items()):
        missing = [f for f in _FIELDS if f not in entry]
        if missing:
            result.append((slug, missing))
    return result


def _backfill_a1_fields_on_disk(config_path: Path, current: dict) -> dict | None:
    """Snapshot, lock, upgrade, and atomically write the config if any team lacks A.1 fields.

    Returns the upgraded config dict on success (disk write or in-memory fallback).
    Returns None only when no fields are missing (skip-fast — no lock, no backup, no write).
    Never raises.
    """
    if not diff_missing_anthropic_fields(current):
        return None

    try:
        lock_file = config_path.with_suffix(".json.lock")
        with open(lock_file, "w") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                # TOCTOU defense — re-read under the lock in case another process raced
                try:
                    reread = json.loads(config_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    reread = current

                if not diff_missing_anthropic_fields(reread):
                    # Someone else won the race; the in-memory current is stale but
                    # we should still return the in-memory upgraded form so this
                    # process sees the correct fields.
                    return upgrade_config_to_v3(current)

                timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
                backup_path = config_path.with_name(
                    f"{config_path.name}.bak-pre-a1-backfill-{timestamp}"
                )
                try:
                    backup_path.write_bytes(config_path.read_bytes())
                except OSError as exc:
                    print(
                        f"[aiteamforge-paths] A.1 backfill: snapshot failed ({exc}) — aborting disk write",
                        file=sys.stderr,
                    )
                    return upgrade_config_to_v3(current)

                upgraded = upgrade_config_to_v3(reread)
                tmp_path = config_path.with_suffix(f".json.tmp.{os.getpid()}")
                try:
                    with open(tmp_path, "w", encoding="utf-8") as f:
                        json.dump(upgraded, f, indent=2)
                        f.flush()
                        os.fsync(f.fileno())
                    os.replace(str(tmp_path), str(config_path))
                except Exception:
                    tmp_path.unlink(missing_ok=True)
                    raise

                for slug, fields in diff_missing_anthropic_fields(current):
                    print(
                        f"[aiteamforge-paths] A.1 backfill: team={slug} fields={fields}",
                        file=sys.stderr,
                    )
                print(
                    f"[aiteamforge-paths] A.1 backfill: snapshot={backup_path}",
                    file=sys.stderr,
                )
                return upgraded
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
                lock_file.unlink(missing_ok=True)
    except Exception as exc:
        print(
            f"[aiteamforge-paths] A.1 backfill: disk write failed ({exc}) — degrading to in-memory upgrade",
            file=sys.stderr,
        )
        return upgrade_config_to_v3(current)


def _find_contract_violating_keys(config: dict) -> list[str]:
    """Return bare parameterized-template keys present in config['teams'].

    A key is a violation when its first '-'-segment is a parameterized template
    AND the whole key equals that segment (no '-instance' suffix), e.g.
    "medical" or "freelance". Pure predicate — never mutates, never raises.
    Mirrors lcars-ui/server.py:_filter_contract_violating_teams() logic. (XACA-0643)
    """
    out = []
    for key in config.get("teams", {}):
        first = key.split("-", 1)[0]
        if first in _PARAMETERIZED_TEMPLATES and key == first:
            out.append(key)
    return out


def _scrub_contract_violating_keys_on_disk(config_path: Path, current: dict) -> dict | None:
    """Snapshot, lock, drop bare parameterized-template keys, atomically rewrite.

    Self-heals configs written before XACA-0643 (which seeded bare "medical"/
    "freelance"). Mirrors _backfill_a1_fields_on_disk's lock/TOCTOU/backup/
    atomic-write discipline. Returns the cleaned config dict when a change is
    made, or None when there is nothing to scrub (skip-fast — no lock, no
    backup, no write). Never raises.
    """
    if not _find_contract_violating_keys(current):
        return None

    def _clean(cfg: dict) -> dict:
        import copy
        out = copy.deepcopy(cfg)
        teams = out.get("teams", {})
        for k in _find_contract_violating_keys(cfg):
            teams.pop(k, None)
        return out

    try:
        lock_file = config_path.with_suffix(".json.lock")
        with open(lock_file, "w") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                # TOCTOU defense — re-read under the lock in case another process raced.
                try:
                    reread = json.loads(config_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    reread = current

                violations = _find_contract_violating_keys(reread)
                if not violations:
                    # Someone else won the race; return the in-memory cleaned form
                    # so this process still sees the corrected team set.
                    return _clean(current)

                timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
                backup_path = config_path.with_name(
                    f"{config_path.name}.bak-pre-contract-scrub-{timestamp}"
                )
                try:
                    backup_path.write_bytes(config_path.read_bytes())
                except OSError as exc:
                    print(
                        f"[aiteamforge-paths] contract scrub: snapshot failed ({exc}) — aborting disk write",
                        file=sys.stderr,
                    )
                    return _clean(current)

                cleaned = _clean(reread)
                tmp_path = config_path.with_suffix(f".json.tmp.{os.getpid()}")
                try:
                    with open(tmp_path, "w", encoding="utf-8") as f:
                        json.dump(cleaned, f, indent=2)
                        f.flush()
                        os.fsync(f.fileno())
                    os.replace(str(tmp_path), str(config_path))
                except Exception:
                    tmp_path.unlink(missing_ok=True)
                    raise

                print(
                    f"[aiteamforge-paths] contract scrub: removed bare "
                    f"parameterized-template keys {sorted(violations)} from "
                    f"{config_path} (team-id contract violation); snapshot={backup_path}",
                    file=sys.stderr,
                )
                return cleaned
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
                lock_file.unlink(missing_ok=True)
    except Exception as exc:
        print(
            f"[aiteamforge-paths] contract scrub: disk write failed ({exc}) — degrading to in-memory clean",
            file=sys.stderr,
        )
        return _clean(current)


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


# ---------------------------------------------------------------------------
# XACA-0542: Team-code registry accessors
# ---------------------------------------------------------------------------
# team_code is the 3-letter code (e.g. "ACA", "IOS") stored in each team
# entry in DEFAULT_TEAMS.  These accessors allow consumers to derive the
# code<->team mapping from the registry instead of maintaining parallel
# hardcoded dicts / case statements.
#
# Aliases (entries without team_code) are intentionally skipped in the
# reverse-lookup to avoid ambiguous code→team resolution.


def get_team_code(team: str) -> str:
    """Return the 3-letter team code for the given team id, or "" if unknown.

    Lookup strategy (in priority order):
    1. Live config (team-paths.json overlaid on DEFAULT_TEAMS) if team_code present.
    2. DEFAULT_TEAMS directly — covers migration case where live config doesn't
       yet have team_code fields (pre-XACA-0542 installs).
    Returns "" for aliases (entries with no team_code field).
    """
    # 1. Live config
    try:
        config = load_config()
        entry = config["teams"].get(team)
        if entry is not None:
            code = entry.get("team_code", "")
            if code:
                return code
    except Exception:
        pass
    # 2. DEFAULT_TEAMS fallback (loader unavailable OR live config lacks team_code)
    entry = DEFAULT_TEAMS.get(team)
    if entry is not None:
        return entry.get("team_code", "")
    return ""


def get_team_from_code(code: str) -> str:
    """Return the team id for the given 3-letter code, or "" if unknown.

    Lookup strategy (in priority order):
    1. Live config (team-paths.json overlaid on DEFAULT_TEAMS) if team_code present.
    2. DEFAULT_TEAMS directly — covers migration case where live config doesn't
       yet have team_code fields (pre-XACA-0542 installs).
    Skips alias entries (entries with no team_code field) to avoid ambiguity.
    """
    code_upper = code.upper()
    # 1. Live config
    try:
        config = load_config()
        for team_id, entry in config["teams"].items():
            if entry.get("team_code", "").upper() == code_upper:
                return team_id
    except Exception:
        pass
    # 2. DEFAULT_TEAMS fallback (loader unavailable OR live config lacks team_code)
    for team_id, entry in DEFAULT_TEAMS.items():
        if entry.get("team_code", "").upper() == code_upper:
            return team_id
    return ""


def build_team_code_map() -> dict[str, str]:
    """Return a mapping of {3-letter-code: team-id} derived from the registry.

    Merge strategy (team-paths.json overlaid on DEFAULT_TEAMS — XACA-0628):
    1. Start from DEFAULT_TEAMS team_codes (the always-present base).
    2. Overlay live-config (team-paths.json) team_codes ON TOP — live wins on
       conflict, and overlay-only slugs (per-project freelance codes that have
       NO DEFAULT_TEAMS entry, e.g. freelance-bandwear-dashboard → BWD) are
       additive.
    3. Only include entries with a non-empty team_code field.

    Why a MERGE (not exclusive-or): the previous exclusive-or only fell back to
    DEFAULT_TEAMS when the live config yielded *zero* team_codes. Once any
    overlay entry carries a team_code (e.g. per-project freelance codes), that
    fallback was skipped and every non-overlay team (academy/ios/…) silently
    dropped out of the map. Merging keeps the DEFAULT_TEAMS base intact while
    layering per-project overlay codes on top.

    With TODAY's overlay (no overlay team_codes) the result is identical to the
    DEFAULT_TEAMS-derived map — regression-safe.

    This is the authoritative source for the code->team mapping.
    Consumers that previously maintained hardcoded _TEAM_CODE_MAP dicts
    should use this function instead. (XACA-0542, XACA-0628)
    """
    result: dict[str, str] = {}
    # 1. Base: DEFAULT_TEAMS team_codes (always present, even if the loader is
    #    entirely unavailable).
    for team_id, entry in DEFAULT_TEAMS.items():
        code = entry.get("team_code", "")
        if code:
            result[code.upper()] = team_id
    # 2. Overlay: live-config team_codes on top (live wins on conflict; adds
    #    overlay-only per-project slugs that have no DEFAULT_TEAMS entry).
    try:
        config = load_config()
        for team_id, entry in config["teams"].items():
            code = entry.get("team_code", "")
            if code:
                result[code.upper()] = team_id
    except Exception:
        # Loader unavailable → keep the DEFAULT_TEAMS base built in step 1.
        pass
    return result


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

    # 4. Canonical band fallback: parameterized templates with no seeded instance
    #    in DEFAULT_TEAMS (e.g. freelance — client+project only) declare their
    #    band in _TEMPLATE_PORT_BANDS so allocation still works. (XACA-0643)
    if entry is None:
        base_template = template_id.split("-")[0] if "-" in template_id else template_id
        band = _TEMPLATE_PORT_BANDS.get(template_id) or _TEMPLATE_PORT_BANDS.get(base_template)
        if band is not None:
            return int(band[0]), int(band[1])

    if entry is None:
        raise ValueError(
            f"Template '{template_id}' has no lcars_port_base declared "
            f"(not found in DEFAULT_TEAMS directly, by stripping dashes, "
            f"via prefix scan, or in _TEMPLATE_PORT_BANDS)."
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
# XACA-0579: Import preflight path-map derivation
# ---------------------------------------------------------------------------

# Subdirectory name under $HOME on a tap-installed AITeamForge machine.
_TAP_SUBDIR = "aiteamforge"
# Subdirectory name under $HOME on a dev-team monorepo machine (the source of
# truth for development; never installed alongside the tap — see CLAUDE.md).
_DEV_SUBDIR = "dev-team"


def build_import_path_maps(manifest: dict) -> list[str]:
    """Derive --path-map SRC=DST strings for the import-preflight verifier.

    The verifier runs on the *destination* machine against a manifest generated
    on the *source* machine.  When the two machines have different directory
    layouts (e.g. M3Pro dev-team monorepo vs M1Pro tap-install), absolute paths
    in the manifest will not exist at their literal locations on the destination.
    This function derives the minimal set of prefix mappings needed to bridge
    the gap so the verifier can resolve source paths to destination equivalents.

    Layout detection strategy
    -------------------------
    1.  Check whether the destination machine has the tap install root
        (``~/aiteamforge/``) present on disk or holds a ``.installed-version``
        sentinel inside it.  This is the canonical tap-install indicator and
        does NOT require any team working_dir to live under ``~/aiteamforge/``
        — many real machines route teams to canonical home paths (e.g.
        ``~/finance/personal``, ``~/academy``) while still being tap-installs.
        The previous approach (XACA-0579) walked team working_dirs looking for
        an ``~/aiteamforge/`` prefix — this failed for every M1Pro layout
        where teams live at their canonical home paths.

    2.  Examine the source home prefix from ``manifest["home"]``.  The source
        machine is ALWAYS assumed to be a DEV-TEAM machine (monorepo layout) when
        the destination is a tap install — this is the only migration scenario
        that crosses layout boundaries in this codebase.  If both src and dst are
        dev-team machines, their working_dirs share the same relative structure
        under home; only a home-prefix rewrite is needed (handled by the verifier
        natively when ``src_home != dst_home``), so no explicit --path-map is
        required.

    3.  Emit two classes of mappings:

        a.  Shared-infra mapping: ``<src_home>/dev-team → <dst_home>/aiteamforge``.
            Covers lcars-ui/, kanban-hooks/, scripts/, etc.

        b.  Per-team mappings derived from ``manifest["teams"]`` (source layout
            snapshot) and local config (destination layout).  For each team where
            ``src_wd != dst_wd``, emit ``"src_wd=dst_wd"``.  Handles scope-suffix
            drift (e.g. source ``~/finance`` vs destination ``~/finance/personal``).

        All mappings are de-duplicated and sorted longest-src-prefix first so
        the verifier's first-match-wins logic picks the most specific mapping.

    Concrete example (M3Pro → M1Pro, scope-suffix drift):
        Manifest["teams"]["finance"]["working_dir"]: /Users/darrenehlers/finance
        Destination config:  working_dir = /Users/darrenehlers/finance/personal
        Emitted mappings:
            /Users/darrenehlers/finance=/Users/darrenehlers/finance/personal  (per-team)
            /Users/darrenehlers/dev-team=/Users/darrenehlers/aiteamforge      (shared-infra)

    Cross-user example (M3Pro → M1Pro, different username):
        Destination has:  ~/aiteamforge/.installed-version  (tap indicator)
        Manifest has:     home = /Users/developer
        Emitted mapping:  /Users/developer/dev-team=/Users/alice/aiteamforge
        (home-prefix rewrite handles the user part; tap-vs-devteam handled here)

    Args:
        manifest: The parsed manifest dict (from json.loads of manifest.json).
                  Must contain at least ``home`` (str).

    Returns:
        List of ``"SRC=DST"`` strings to pass as ``--path-map`` arguments.
        Empty list if no mapping is needed (same-layout machines or no config).

    Never raises.
    """
    try:
        # XACA-0580-012: strip whitespace BEFORE rstrip("/"); a whitespace-only
        # "home" must fail the early-exit check, otherwise a garbage manifest
        # could produce a bogus path-map on a tap-install destination.
        src_home = manifest.get("home", "").strip().rstrip("/")
        if not src_home:
            return []

        dst_home = str(Path.home()).rstrip("/")

        dst_aiteamforge_root = dst_home + "/" + _TAP_SUBDIR
        src_devteam_root = src_home + "/" + _DEV_SUBDIR

        config = load_config()

        # Tap-install detection: check for the canonical tap install root, which
        # exists IFF this machine has the homebrew tap installed.  Team working_dirs
        # are NOT required to live under ~/aiteamforge/ — many real machines route
        # teams to canonical home paths (e.g. ~/finance/personal, ~/academy) while
        # still being tap-installs.  Heuristic-on-team-paths was the XACA-0579 bug.
        dst_aiteamforge_dir = Path(dst_aiteamforge_root)
        tap_install_detected = (
            dst_aiteamforge_dir.is_dir()
            or (dst_aiteamforge_dir / ".installed-version").exists()
        )

        if not tap_install_detected:
            # Destination is a dev-team monorepo or unknown layout.
            # The verifier's built-in home-prefix rewrite handles cross-user cases.
            return []

        # Destination is a tap install.  Build path mappings:
        #   1. Shared-infra: <src_home>/dev-team → <dst_home>/aiteamforge
        #      Covers lcars-ui/, kanban-hooks/, scripts/, etc.
        #   2. Per-team: src_wd → dst_wd for teams where layout differs between
        #      source (manifest snapshot) and destination (local config).
        #      Handles scope-suffix drift (e.g. ~/finance vs ~/finance/personal).
        shared_infra_map = f"{src_devteam_root}={dst_aiteamforge_root}"

        mappings: list[str] = [shared_infra_map]

        # Per-team mappings from manifest teams snapshot vs local config.
        manifest_teams: dict = manifest.get("teams") or {}
        local_teams: dict = config.get("teams") or {}
        seen: set[str] = {shared_infra_map}

        for slug, src_entry in manifest_teams.items():
            src_wd = (src_entry or {}).get("working_dir", "").rstrip("/")
            if not src_wd:
                continue
            # XACA-0581: teams whose source working_dir IS the dev-team root
            # (e.g. academy, freelance) are already covered by shared_infra_map.
            # Emitting a per-team map keyed on the same src prefix collides with
            # it — identical prefix length means the verifier's longest-first sort
            # falls back to stable insertion order, and the per-team map would
            # mis-route dev-team paths into a team subdir (e.g. ~/academy) instead
            # of ~/aiteamforge. Skip them; shared-infra is the correct mapping.
            if src_wd == src_devteam_root:
                continue
            dst_entry = local_teams.get(slug) or {}
            dst_wd_raw = (dst_entry or {}).get("working_dir", "")
            if not dst_wd_raw:
                continue
            dst_wd = str(Path(dst_wd_raw).expanduser()).rstrip("/")
            if not dst_wd or src_wd == dst_wd:
                continue
            mapping = f"{src_wd}={dst_wd}"
            if mapping not in seen:
                seen.add(mapping)
                mappings.append(mapping)

        # Sort longest src prefix first — verifier uses first-match-wins so the
        # most specific (per-team) mapping must precede the generic shared-infra one.
        mappings.sort(key=lambda m: len(m.split("=", 1)[0]), reverse=True)
        return mappings

    except Exception as exc:
        print(
            f"[aiteamforge-paths] build_import_path_maps: error deriving path maps: {exc}",
            file=sys.stderr,
        )
        return []


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


# ---------------------------------------------------------------------------
# XACA-0658: Versioned release-push flow — version-source config accessors
# ---------------------------------------------------------------------------


def get_team_version_sources(team_id: str, platform: str | None = None) -> list[dict]:
    """Return the version_sources list for *team_id*, optionally filtered by platform.

    Args:
        team_id:  Team slug (e.g. "ios", "android").
        platform: If given, return only entries whose ``platform`` field matches
                  (case-sensitive).  If None, return all entries.

    Returns:
        List of version-source dicts (may be empty if key is absent or no match).
        Each dict has at minimum: platform, file, match_pattern, write_pattern.
        Optional fields: encoding (default "utf-8"), replace_all (default False).

    Never raises — missing team or missing key returns an empty list.
    """
    config = load_config()
    entry = config.get("teams", {}).get(team_id, {})
    sources = entry.get("version_sources", [])
    if not isinstance(sources, list):
        return []
    if platform is not None:
        sources = [s for s in sources if isinstance(s, dict) and s.get("platform") == platform]
    return [s for s in sources if isinstance(s, dict)]


def get_team_branch_env_map(team_id: str) -> dict:
    """Return the raw branch_env_map for *team_id*.

    The map values are either strings (all-platforms shorthand) or dicts
    (per-platform).  Use normalize_branch_env() to resolve a specific branch
    and platform list to a {platform: env} dict.

    Returns:
        dict — the raw branch_env_map (may be empty if key is absent).

    Never raises — missing team or missing key returns an empty dict.
    """
    config = load_config()
    entry = config.get("teams", {}).get(team_id, {})
    raw = entry.get("branch_env_map", {})
    if not isinstance(raw, dict):
        return {}
    return raw


def get_team_relnotes_sources(team_id: str, platform: str | None = None) -> list[dict]:
    """Return the relnotes_sources list for *team_id*, optionally filtered by platform.

    Args:
        team_id:  Team slug.
        platform: If given, return only entries whose ``platform`` field matches.

    Returns:
        List of relnotes-source dicts (may be empty if key is absent or no match).
        Each dict has at minimum: platform, dir (relative to working_dir).

    Never raises — missing team or missing key returns an empty list.
    """
    config = load_config()
    entry = config.get("teams", {}).get(team_id, {})
    sources = entry.get("relnotes_sources", [])
    if not isinstance(sources, list):
        return []
    if platform is not None:
        sources = [s for s in sources if isinstance(s, dict) and s.get("platform") == platform]
    return [s for s in sources if isinstance(s, dict)]


def normalize_branch_env(branch_map_value: str | dict, release_platforms: list[str]) -> dict[str, str]:
    """Normalize a branch_env_map value to a {platform: env} dict.

    Handles both forms:
      - String value: ``"DEV"`` → ``{p: "DEV" for p in release_platforms}``
      - Object value: ``{"ios": "DEV", "android": "DEV"}`` → returned as-is
        (filtered to only keys present in release_platforms).

    Args:
        branch_map_value: The value from branch_env_map for a specific branch
                          key.  Either a string or a dict.
        release_platforms: List of platform strings from the active release
                           (e.g. ["ios", "android"]).  Used to expand the
                           string form to all platforms.

    Returns:
        dict mapping platform → environment string.
        Empty dict if branch_map_value is neither a str nor a dict.

    Never raises.
    """
    if isinstance(branch_map_value, str):
        env = branch_map_value
        return {p: env for p in release_platforms}
    if isinstance(branch_map_value, dict):
        return {p: v for p, v in branch_map_value.items()
                if p in release_platforms and isinstance(v, str)}
    return {}


# ---------------------------------------------------------------------------
# TimePad config loader — XACA-0619-002
# ---------------------------------------------------------------------------
# Loads, validates, and caches kanban-hooks/timepad_config.json.
#
# Config file location (in priority order):
#   1. $AITEAMFORGE_TIMEPAD_CONFIG env var (override for tests)
#   2. ~/.aiteamforge/timepad_config.json  (runtime user copy)
#   3. <dev-team-root>/kanban-hooks/timepad_config.json  (source/fallback)
#
# The schema ships with all UUID fields set to the placeholder
# "<fetch-from-timepad.io>" — a valid-but-unconfigured marker.  The loader
# does NOT crash on placeholders; callers use timepad_team_has_placeholders()
# to distinguish configured from unconfigured teams.
#
# Security rules (never relax):
#   - tokenRef must be an env-var reference NAME only — never a raw token value.
#   - Any value that looks like a raw token (starts with "tp_", "sk-", or is
#     longer than 80 chars) is rejected.
#   - liquidstyle references in apiBaseUrl or tokenRef are hard-rejected
#     (hard cutover; these UUIDs are from a retired database).
# ---------------------------------------------------------------------------

_TIMEPAD_CONFIG_CACHE: dict | None = None
_TIMEPAD_CONFIG_PATH_AT_LOAD: str | None = None  # detect env-var changes

#: Placeholder string used in the shipped schema for unconfigured UUID fields.
TIMEPAD_PLACEHOLDER = "<fetch-from-timepad.io>"

#: UUID fields in each team block that may carry TIMEPAD_PLACEHOLDER.
_TIMEPAD_UUID_FIELDS = ("clientId", "projectId", "tagId")

#: Pattern fragments that look like raw token values — reject if found in tokenRef.
_TIMEPAD_RAW_TOKEN_PREFIXES = ("tp_", "sk-", "Bearer ", "token ", "apikey ")


def get_timepad_config_path() -> Path:
    """Return the path to timepad_config.json, honouring $AITEAMFORGE_TIMEPAD_CONFIG.

    Search order:
      1. $AITEAMFORGE_TIMEPAD_CONFIG env var (explicit override — tests use this)
      2. ~/.aiteamforge/timepad_config.json  (runtime user copy)
      3. <this-file's-dir>/timepad_config.json  (dev-team source fallback)
    """
    override = os.environ.get("AITEAMFORGE_TIMEPAD_CONFIG", "")
    if override:
        return Path(override).expanduser()
    user_copy = Path.home() / ".aiteamforge" / "timepad_config.json"
    if user_copy.exists():
        return user_copy
    # Fallback: sibling in kanban-hooks/ (dev-team source tree)
    return Path(__file__).parent / "timepad_config.json"


def _validate_timepad_team_block(team_slug: str, block: Any) -> list[str]:
    """Validate a single per-team block from timepad_config.json.

    Returns a list of error strings (empty = valid).  Does NOT raise.

    Validation rules:
      - block must be a dict
      - apiBaseUrl must be a non-empty string starting with "https://"
      - apiBaseUrl must NOT contain "liquidstyle" (hard cutover)
      - tokenRef must be a non-empty string
      - tokenRef must NOT start with a raw-token-looking prefix
      - tokenRef must NOT be longer than 80 chars (env-var names don't get that long)
      - tokenRef must NOT contain "liquidstyle"
      - UUID fields (clientId, projectId, tagId) must be strings
      - UUID fields may be the TIMEPAD_PLACEHOLDER sentinel (valid-but-unconfigured)

    Note: the `enabled` field is intentionally NOT validated here (XACA-0619-005).
    The enable gate lives in the board JSON at teamConfig.timepadSupport.enabled
    (single source of truth, mirrors crSupport pattern).  A stale `enabled` field
    in a config block is silently ignored — callers use is_timepad_enabled().
    """
    errors: list[str] = []
    if not isinstance(block, dict):
        errors.append(f"teams.{team_slug}: block must be a dict, got {type(block).__name__}")
        return errors  # can't check sub-fields if block isn't a dict

    # apiBaseUrl — must be non-empty https:// URL, no liquidstyle
    api_base = block.get("apiBaseUrl", "")
    if not isinstance(api_base, str) or not api_base:
        errors.append(f"teams.{team_slug}.apiBaseUrl: must be a non-empty string")
    elif not api_base.startswith("https://"):
        errors.append(
            f"teams.{team_slug}.apiBaseUrl: must start with 'https://', got {api_base!r}"
        )
    elif "liquidstyle" in api_base.lower():
        errors.append(
            f"teams.{team_slug}.apiBaseUrl: contains 'liquidstyle' — hard cutover; "
            "this is a retired host.  Update to 'https://timepad.io/api'."
        )

    # tokenRef — name reference only, never a raw token
    token_ref = block.get("tokenRef", "")
    if not isinstance(token_ref, str) or not token_ref:
        errors.append(f"teams.{team_slug}.tokenRef: must be a non-empty string")
    else:
        if "liquidstyle" in token_ref.lower():
            errors.append(
                f"teams.{team_slug}.tokenRef: contains 'liquidstyle' — "
                "stale credential reference.  Use TIMEPAD_API_KEY or "
                "TEAM_<CODE>_TIMEPAD_API_KEY."
            )
        for prefix in _TIMEPAD_RAW_TOKEN_PREFIXES:
            if token_ref.lower().startswith(prefix.lower()):
                errors.append(
                    f"teams.{team_slug}.tokenRef: looks like a raw token value "
                    f"(starts with {prefix!r}) — store only the env-var/vault key NAME"
                )
                break
        if len(token_ref) > 80:
            errors.append(
                f"teams.{team_slug}.tokenRef: suspiciously long ({len(token_ref)} chars) "
                "— env-var names don't exceed 80 chars; check if a raw token was stored"
            )

    # UUID fields — must be strings (placeholder or real)
    for field in _TIMEPAD_UUID_FIELDS:
        val = block.get(field)
        if not isinstance(val, str):
            errors.append(
                f"teams.{team_slug}.{field}: must be a string, "
                f"got {type(val).__name__!r} ({val!r})"
            )

    return errors


def load_timepad_config() -> dict:
    """Load, validate, and cache the TimePad per-team config.

    Returns the parsed dict from timepad_config.json.  On missing file, JSON
    parse errors, or hard validation failures the error is printed to stderr and
    an empty-teams dict ``{"_schemaVersion": 1, "teams": {}}`` is returned so
    callers degrade gracefully.

    Soft validation failures (individual team block errors) are printed to
    stderr but do NOT prevent the config from loading — the offending team
    block is left in the result so callers can inspect it.  Callers that need
    a clean team block should check the validation errors via
    ``validate_timepad_config(config)``.

    Caching: result is cached until ``bust_timepad_config_cache()`` is called
    or ``$AITEAMFORGE_TIMEPAD_CONFIG`` changes between calls (test-isolation).

    Never raises.
    """
    global _TIMEPAD_CONFIG_CACHE, _TIMEPAD_CONFIG_PATH_AT_LOAD

    config_path = get_timepad_config_path()
    config_path_str = str(config_path)

    # Re-load if env var changed (important for tests)
    if _TIMEPAD_CONFIG_CACHE is not None and _TIMEPAD_CONFIG_PATH_AT_LOAD == config_path_str:
        return _TIMEPAD_CONFIG_CACHE

    _empty: dict = {"_schemaVersion": 1, "teams": {}}

    if not config_path.exists():
        print(
            f"[aiteamforge-paths] WARNING: timepad_config.json not found at {config_path} "
            "— TimePad integration unavailable",
            file=sys.stderr,
        )
        _TIMEPAD_CONFIG_CACHE = _empty
        _TIMEPAD_CONFIG_PATH_AT_LOAD = config_path_str
        return _TIMEPAD_CONFIG_CACHE

    try:
        raw = config_path.read_text(encoding="utf-8")
        config = json.loads(raw)
    except (json.JSONDecodeError, OSError) as exc:
        print(
            f"[aiteamforge-paths] WARNING: could not parse timepad_config.json "
            f"at {config_path}: {exc} — TimePad integration unavailable",
            file=sys.stderr,
        )
        _TIMEPAD_CONFIG_CACHE = _empty
        _TIMEPAD_CONFIG_PATH_AT_LOAD = config_path_str
        return _TIMEPAD_CONFIG_CACHE

    if not isinstance(config, dict):
        print(
            f"[aiteamforge-paths] WARNING: timepad_config.json root must be a dict — "
            "TimePad integration unavailable",
            file=sys.stderr,
        )
        _TIMEPAD_CONFIG_CACHE = _empty
        _TIMEPAD_CONFIG_PATH_AT_LOAD = config_path_str
        return _TIMEPAD_CONFIG_CACHE

    # Run per-team validation — emit warnings but don't discard the config.
    errors = validate_timepad_config(config)
    for err in errors:
        print(f"[aiteamforge-paths] TIMEPAD CONFIG WARNING: {err}", file=sys.stderr)

    _TIMEPAD_CONFIG_CACHE = config
    _TIMEPAD_CONFIG_PATH_AT_LOAD = config_path_str
    return _TIMEPAD_CONFIG_CACHE


def validate_timepad_config(config: dict) -> list[str]:
    """Validate all team blocks in a parsed timepad_config.json dict.

    Returns a list of error strings (empty = all clean).  Suitable for use in
    tests and for callers that want to surface validation errors explicitly.

    Does NOT check whether UUID fields are still placeholders — that's a
    "not yet configured" state, not an error.  Use timepad_team_has_placeholders()
    for that check.

    Args:
        config: Parsed dict from timepad_config.json (not a file path).

    Returns:
        List of human-readable error strings.  Empty list = config is valid.
    """
    errors: list[str] = []
    teams = config.get("teams", {})
    if not isinstance(teams, dict):
        errors.append("'teams' must be a dict")
        return errors
    for slug, block in teams.items():
        errors.extend(_validate_timepad_team_block(slug, block))
    return errors


def get_timepad_team_config_raw(team_slug: str) -> dict:
    """Return the raw config block for a team from timepad_config.json.

    Returns an empty dict if the team is not present or the config failed to load.
    Does not raise.

    This is the low-level accessor.  Sibling 005 (accessor API) wraps this with
    board-JSON enable-flag merging.

    Args:
        team_slug: Canonical team slug (e.g. "academy", "mainevent").

    Returns:
        Per-team config dict, or {} if absent.
    """
    config = load_timepad_config()
    return config.get("teams", {}).get(team_slug, {})


def timepad_team_has_placeholders(team_slug: str) -> bool:
    """Return True iff any UUID field for the team still holds the placeholder sentinel.

    A placeholder indicates the team is valid-but-unconfigured — the UUIDs must
    be fetched from timepad.io before TimePad operations will work.

    Returns True also when the team block is absent (treat as unconfigured).

    Args:
        team_slug: Canonical team slug (e.g. "academy", "mainevent").

    Returns:
        True if any of clientId / projectId / tagId equals TIMEPAD_PLACEHOLDER,
        or if the team block is missing; False if all three are set to non-placeholder
        strings.
    """
    block = get_timepad_team_config_raw(team_slug)
    if not block:
        return True  # absent = unconfigured
    return any(
        block.get(field) == TIMEPAD_PLACEHOLDER
        for field in _TIMEPAD_UUID_FIELDS
    )


def bust_timepad_config_cache() -> None:
    """Invalidate the TimePad config cache.

    The next call to load_timepad_config() will re-read from disk.
    Intended for use in tests and for callers that write a new config to disk
    and need the cache to reflect the new content immediately.
    """
    global _TIMEPAD_CONFIG_CACHE, _TIMEPAD_CONFIG_PATH_AT_LOAD
    _TIMEPAD_CONFIG_CACHE = None
    _TIMEPAD_CONFIG_PATH_AT_LOAD = None


# ---------------------------------------------------------------------------
# Public accessor API (XACA-0619-005) — consumed by hooks + LCARS
# ---------------------------------------------------------------------------
# Design decision (locked by Opus lead, XACA-0619-005):
#   - get_timepad_team_config() returns only the *connection* config block from
#     timepad_config.json (apiBaseUrl, tokenRef, clientId, projectId, tagId).
#     It does NOT merge the enabled flag — config (connection) and enabled (gate)
#     are intentionally separate.
#   - is_timepad_enabled() reads the *gate* from the board JSON at
#     teamConfig.timepadSupport.enabled (single source of truth, mirrors crSupport).
#   - Consumers call both when they need to check if integration is active.
#
# This separation prevents drift: the board JSON toggle is the only place to
# flip the feature on or off; the config JSON is connection-only config.


def get_timepad_team_config(team_slug: str) -> dict:
    """Return the connection config block for a team from timepad_config.json.

    Public accessor for hook + LCARS consumers (XACA-0619-005).  Wraps
    ``get_timepad_team_config_raw()`` with an explicit public contract.

    Returns the dict with fields: apiBaseUrl, tokenRef, clientId, projectId,
    tagId.  Returns an empty dict when the team is absent or config failed to
    load.

    NOTE: This dict does NOT contain an ``enabled`` flag.  The enable gate lives
    in the board JSON at ``teamConfig.timepadSupport.enabled`` and is read by
    ``is_timepad_enabled()``.  Keep config (connection) and enabled (gate)
    separate — callers that need both call each function independently.

    Args:
        team_slug: Canonical team slug (e.g. "academy", "mainevent").

    Returns:
        Per-team connection config dict, or {} if absent / load failure.
    """
    return get_timepad_team_config_raw(team_slug)


def is_timepad_enabled(team_slug: str) -> bool:
    """Return True iff TimePad is enabled for the given team.

    Reads ``teamConfig.timepadSupport.enabled`` from the team's board JSON
    (``<kanban_dir>/<team>-board.json``).  This is the single source of truth
    for the enable/disable gate, mirroring the ``teamConfig.crSupport.enabled``
    pattern already used by the CR workflow.

    Key path: board_data["teamConfig"]["timepadSupport"]["enabled"]
    Default:  False (disabled) at every level of the chain.

    The ``enabled`` field that previously existed in ``timepad_config.json`` has
    been removed (XACA-0619-005) to eliminate the duplicate source.  This
    function is the only place that reads the gate.

    Args:
        team_slug: Canonical team slug (e.g. "academy", "mainevent").

    Returns:
        True if the board JSON declares timepadSupport.enabled = true,
        False in all other cases (key absent, board missing, parse error, etc.).
    """
    try:
        kanban_dir = get_team_kanban_dir(team_slug)
        board_file = kanban_dir / f"{team_slug}-board.json"
        if not board_file.exists():
            return False
        board_data = json.loads(board_file.read_text(encoding="utf-8"))
        # Mirror the server.py pattern (XACA-0333-006):
        #   board_data.get('teamConfig') or {}  — guards against explicit null
        team_config = board_data.get("teamConfig") or {}
        return bool(
            team_config.get("timepadSupport", {}).get("enabled", False)
        )
    except Exception:
        return False  # safe default — disabled


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
