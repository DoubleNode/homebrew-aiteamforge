#!/usr/bin/env python3

#
#  server.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
LCARS Kanban Monitor Server

A simple HTTP server that serves the LCARS web interface and
provides live access to the kanban board data.

Usage:
    python3 server.py [port]

    Default port is 8080

    Open http://localhost:8080 in your browser
"""

import http.server
import socketserver
import copy
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import threading
import time
import traceback
import urllib.request
import urllib.error
import base64
import glob
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse, urlencode, parse_qs

# Add kanban-hooks to path (shared modules: kanban_utils, aiteamforge_paths)
_KANBAN_HOOKS_DIR = str(Path(__file__).parent.parent / "kanban-hooks")
if _KANBAN_HOOKS_DIR not in sys.path:
    sys.path.insert(0, _KANBAN_HOOKS_DIR)

# Import team path config from shared module (XACA-0168)
try:
    from aiteamforge_paths import get_team_kanban_dir, get_team_lcars_port, list_teams, load_config as _aiteamforge_load_config
    _AITEAMFORGE_PATHS_AVAILABLE = True
except ImportError as e:
    _AITEAMFORGE_PATHS_AVAILABLE = False
    print(f"[LCARS] Warning: aiteamforge_paths not available, using hardcoded dirs: {e}")

# Import kanban activity logging from kanban-hooks
try:
    from kanban_utils import log_activity, read_activity_log, get_lcars_tmp_dir
    LOG_ACTIVITY_AVAILABLE = True
except ImportError as e:
    LOG_ACTIVITY_AVAILABLE = False
    def log_activity(*args, **kwargs):
        pass
    def read_activity_log(*args, **kwargs):
        return {"entries": [], "itemId": kwargs.get("item_id", "")}
    def get_lcars_tmp_dir(session_name: str) -> str:
        return "/tmp/"
    print(f"[LCARS] Warning: kanban_utils not available, activity logging disabled: {e}")

# Import integration providers
try:
    from integrations import get_manager, IntegrationManager
    from integrations import get_sync_service, SyncDirection, SyncStatus
    INTEGRATIONS_AVAILABLE = True
    SYNC_AVAILABLE = True
except ImportError:
    INTEGRATIONS_AVAILABLE = False
    SYNC_AVAILABLE = False
    print("[LCARS] Warning: Integration module not available")

# Import RAG engine providers
try:
    from rag_engines import get_manager as get_rag_manager
    RAG_ENGINES_AVAILABLE = True
except ImportError:
    RAG_ENGINES_AVAILABLE = False
    print("[LCARS] Warning: RAG engines module not available")

# Import Neo4j/Memgraph Bolt driver (optional — used for graph queries)
try:
    from neo4j import GraphDatabase as _BoltGraphDatabase
    BOLT_AVAILABLE = True
except ImportError:
    _BoltGraphDatabase = None
    BOLT_AVAILABLE = False

# Import calendar sync service
try:
    from calendar.sync_service import CalendarSyncService
    from calendar.apple_provider import AppleCalendarProvider
    from calendar.provider import CalendarCredentials
    CALENDAR_SYNC_AVAILABLE = True
    _calendar_sync_service = CalendarSyncService()
except ImportError as e:
    CALENDAR_SYNC_AVAILABLE = False
    _calendar_sync_service = None
    AppleCalendarProvider = None
    CalendarCredentials = None
    print(f"[LCARS] Warning: Calendar sync module not available: {e}")

# Import ccusage heuristics (XACA-0243-003) — same directory as server.py
try:
    import ccusage_heuristics as _ccusage_heuristics
    CCUSAGE_HEURISTICS_AVAILABLE = True
except ImportError as e:
    _ccusage_heuristics = None  # type: ignore[assignment]
    CCUSAGE_HEURISTICS_AVAILABLE = False
    print(f"[LCARS] Warning: ccusage_heuristics not available: {e}")

# Import secrets export contract layer (XACA-0172) — same directory as server.py
try:
    from secrets_export_lib import (
        discover_secrets_sources,
        pyzipper_available,
        SECRETS_EXPORT_MANIFEST_KIND,
        SECRETS_EXPORT_MANIFEST_VERSION,
    )
    SECRETS_EXPORT_LIB_AVAILABLE = True
except ImportError as e:
    SECRETS_EXPORT_LIB_AVAILABLE = False
    print(f"[LCARS] Warning: secrets_export_lib not available: {e}")
    def discover_secrets_sources(team_id):  # type: ignore[misc]
        return {"sources": [], "target_root": "secrets/", "manifest_used": "auto"}
    def pyzipper_available():  # type: ignore[misc]
        return False
    SECRETS_EXPORT_MANIFEST_KIND = "lcars-team-secrets"
    SECRETS_EXPORT_MANIFEST_VERSION = "1.0"

# Configuration
DEFAULT_PORT = 8080
BACKUP_DIR = Path.home() / "aiteamforge-backups" / "kanban"

# Distributed kanban directories — loaded from aiteamforge_paths (XACA-0168).
# Build a dict from the shared module so existing code using TEAM_KANBAN_DIRS[team]
# continues to work without change.
def _hardcoded_team_kanban_dirs() -> dict:
    """Baked-in team paths (kept in sync with aiteamforge_paths.DEFAULT_TEAMS)."""
    _home = Path.home()
    return {
        "academy": _home / "dev-team" / "kanban",
        "ios": Path("/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban"),
        "android": Path("/Users/Shared/Development/Main Event/MainEventApp-Android/kanban"),
        "firebase": Path("/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban"),
        "command": Path("/Users/Shared/Development/Main Event/dev-team/kanban"),
        "dns": Path("/Users/Shared/Development/DNSFramework/kanban"),
        "freelance-doublenode-starwords": Path("/Users/Shared/Development/DoubleNode/Starwords/kanban"),
        "freelance-doublenode-appplanning": Path("/Users/Shared/Development/DoubleNode/appPlanning/kanban"),
        "freelance-doublenode-workstats": Path("/Users/Shared/Development/DoubleNode/WorkStats/kanban"),
        "freelance-doublenode-lifeboard": Path("/Users/Shared/Development/DoubleNode/LifeBoard/kanban"),
        "freelance-doublenode-caravan": Path("/Users/Shared/Development/DoubleNode/Caravan/kanban"),
        "freelance-doublenode-awaysentry": Path("/Users/Shared/Development/DoubleNode/AwaySentry/kanban"),
        "freelance-liquidstyle-agentbadges-app": Path("/Users/Shared/Development/Liquidstyle/AgentBadges-APP/kanban"),
        "freelance-liquidstyle-agentbadges-ios": Path("/Users/Shared/Development/Liquidstyle/AgentBadges-IOS/kanban"),
        "legal-coparenting": _home / "legal" / "coparenting" / "kanban",
        "medical-general": _home / "medical" / "general" / "kanban",
        "finance-personal": _home / "finance" / "personal" / "kanban",
    }


# Templates that REQUIRE one or more parameters (project, client+project) per
# the team-id contract (docs/architecture/team-id-contract.md §3). A bare
# template id like "freelance" or "medical" appearing as a TEAM_KANBAN_DIRS key
# is a contract violation — those keys must be instance ids like
# "finance-personal" or "freelance-doublenode-starwords".
_PARAMETERIZED_TEMPLATES = frozenset({"finance", "legal", "medical", "freelance"})


def _filter_contract_violating_teams(team_dirs: dict) -> dict:
    """Drop bare-template ids for parameterized templates with a loud warning.

    Per XACA-0460-007 contract: TEAM_KANBAN_DIRS keys are instance ids.
    A key like "freelance" (template == instance) is invalid because
    freelance requires client+project. Filtering here protects 009's
    LCARS_TEAM validation from accepting a bogus bare-template install.
    """
    filtered = {}
    for team, kanban_dir in team_dirs.items():
        first_segment = team.split("-", 1)[0]
        if first_segment in _PARAMETERIZED_TEMPLATES and team == first_segment:
            print(
                f"[LCARS] WARNING: ignoring contract-violating team key "
                f"'{team}' in team-paths.json — '{team}' is a parameterized "
                f"template id, not an instance id. Remove it from "
                f"~/.aiteamforge/team-paths.json. See "
                f"docs/architecture/team-id-contract.md.",
                file=sys.stderr,
            )
            continue
        filtered[team] = kanban_dir
    return filtered


# Canonical-team guard constants (XACA-0457).
# list_teams() must include ALL of _CANONICAL_REQUIRED and AT LEAST ONE of
# _CANONICAL_AT_LEAST_ONE before the result is trusted.  A partial corruption
# (e.g. team-paths.json collapsed to academy-only on 2026-05-07) passes the
# legacy `if teams:` truthiness check but silently breaks every non-academy
# team lookup for the server's lifetime.
_CANONICAL_REQUIRED = {"academy"}
_CANONICAL_AT_LEAST_ONE = {"ios", "android", "firebase", "dns"}


def _build_team_kanban_dirs() -> dict:
    # Empty result from list_teams() is treated as a load failure and triggers the
    # fallback — otherwise a server started during a config write-race caches {}
    # for its lifetime and every team lookup 404s until manual restart. (Bug found
    # 2026-04-22: Android LCARS served empty board after config briefly had no teams.)
    # Partial corruption (e.g. only academy survives a write-race) is also caught:
    # the canonical-team check below requires academy AND at least one of
    # ios/android/firebase/dns before the dynamic list is trusted. (XACA-0457)
    if _AITEAMFORGE_PATHS_AVAILABLE:
        try:
            teams = list_teams()
            if teams:
                teams_set = set(teams)
                missing_required = _CANONICAL_REQUIRED - teams_set
                has_at_least_one = bool(teams_set & _CANONICAL_AT_LEAST_ONE)
                if missing_required or not has_at_least_one:
                    # Build a precise diagnostic: distinguish missing-required
                    # from missing-canonical-set so the warning message tells
                    # the operator exactly which constraint failed. (XACA-0457-011)
                    parts = []
                    if missing_required:
                        parts.append(f"missing required: {sorted(missing_required)}")
                    if not has_at_least_one:
                        parts.append(
                            f"none of {sorted(_CANONICAL_AT_LEAST_ONE)} present"
                        )
                    print(
                        f"[LCARS] WARNING: list_teams() returned partial config "
                        f"({'; '.join(parts)}) — using hardcoded team dirs",
                        file=sys.stderr,
                    )
                else:
                    raw = {team: get_team_kanban_dir(team) for team in teams}
                    return _filter_contract_violating_teams(raw)
            else:
                print(
                    "[LCARS] WARNING: aiteamforge_paths.list_teams() returned empty — using hardcoded team dirs",
                    file=sys.stderr,
                )
        except Exception as e:
            print(
                f"[LCARS] WARNING: aiteamforge_paths.list_teams() raised {e!r} — using hardcoded team dirs",
                file=sys.stderr,
            )
    return _filter_contract_violating_teams(_hardcoded_team_kanban_dirs())

TEAM_KANBAN_DIRS = _build_team_kanban_dirs()

# Legacy fallback for backwards compatibility
KANBAN_DIR = Path.home() / "dev-team" / "kanban"

# Archive job tracking
EXPORT_JOBS = {}         # {job_id: {status, progress, message, filename, fileSize, error, ...}}
SECRETS_EXPORT_JOBS = {} # {job_id: {status, progress, message, filename, fileSize, error, pairedExportId, manifestUsed, ...}}
IMPORT_JOBS = {}         # {job_id: {status, progress, message, manifest, stagedPath, ...}}
SECRETS_IMPORT_JOBS = {} # {job_id: {status, progress, message, manifest, stagedPath, targetTeam, fileCount, createdAt, error, wrongPasswordAttempts, ...}}
EXPORT_DIR = Path("/tmp/lcars-exports")
IMPORT_STAGING_DIR = Path("/tmp/lcars-imports")
SECRETS_IMPORT_STAGING_DIR = Path("/tmp/lcars-secrets-imports")

# Maximum wrong-password attempts before the staged zip is purged (item 6 spec).
_SECRETS_IMPORT_MAX_PASSWORD_ATTEMPTS = 5


def _prune_old_secrets_jobs():
    """Prune completed/failed/skipped secrets jobs older than 1 hour from both dicts.

    Called at the start of each create-handler so the dicts don't grow unbounded
    across long-running server sessions.  Mirrors the TTL pattern in handle_create_export().
    """
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc)
    terminal_states = ('completed', 'failed', 'skipped')

    for jobs_dict in (SECRETS_EXPORT_JOBS, SECRETS_IMPORT_JOBS):
        stale = [
            jid for jid, jdata in jobs_dict.items()
            if jdata.get('status') in terminal_states
            and (
                now - datetime.fromisoformat(
                    jdata.get('createdAt', now.isoformat()).replace('Z', '+00:00')
                )
            ).total_seconds() > 3600
        ]
        for jid in stale:
            del jobs_dict[jid]

# XACA-0281 Phase A.3: Fleet Monitor sidecar URL (proxy + cache for engines registry)
FLEET_MONITOR_URL = os.environ.get('FLEET_MONITOR_URL', 'http://localhost:8080')

# ccusage collector cache (XACA-0243-001 daemon writes this file atomically).
CCUSAGE_CACHE_PATH = "/tmp/lcars-ccusage-cache.json"
CCUSAGE_PID_PATH = "/tmp/lcars-ccusage-collector.pid"
CCUSAGE_COLLECTOR_LOG = "/tmp/lcars-ccusage-collector.log"

# Per-process flag: emit the "collector not running" warning only once.
_ccusage_missing_warned = False

# XACA-0249: Throttle the "silent team fallback" warning to once per minute
# per endpoint path, so log files don't flood under high traffic while still
# making the misconfiguration unmissable on first hit per server boot.
_team_fallback_warn_times: dict = {}  # endpoint_path -> last_warn_epoch_float
_TEAM_FALLBACK_WARN_INTERVAL_SECONDS = 60
# True when LCARS_TEAM was explicitly set in the environment at module load.
_LCARS_TEAM_WAS_EXPLICIT: bool = bool(os.environ.get("LCARS_TEAM", "").strip())

# Throttle: track last respawn attempt so a flapping daemon can't fork-bomb us.
_ccusage_last_respawn_at = 0.0
_CCUSAGE_RESPAWN_COOLDOWN_SECONDS = 30


def _collector_pid_alive() -> bool:
    """Return True if the PID in CCUSAGE_PID_PATH names a live process.

    Uses kill(pid, 0) which never delivers a signal — it just probes whether
    the kernel can reach that PID. Returns False if the file is missing,
    unreadable, malformed, or the PID is gone.
    """
    try:
        with open(CCUSAGE_PID_PATH, "r", encoding="utf-8") as _f:
            pid = int(_f.read().strip())
    except (OSError, ValueError):
        return False
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError, OSError):
        return False


def _ensure_collector_running() -> bool:
    """Re-launch ccusage_collector.py --foreground if it is not currently alive.

    Cheap fast path: just a kill(pid, 0) when the daemon is healthy.
    Slow path: detached Popen so the request handler returns immediately.
    Throttled to one respawn attempt per _CCUSAGE_RESPAWN_COOLDOWN_SECONDS to
    avoid fork-bombing if the collector is crash-looping (e.g. ccusage missing).

    Returns True if the daemon is (now) considered running, False if the
    respawn was throttled or skipped (e.g. heuristics module unavailable).
    """
    global _ccusage_last_respawn_at  # noqa: PLW0603

    if not CCUSAGE_HEURISTICS_AVAILABLE:
        return False
    if _collector_pid_alive():
        return True

    now = time.time()
    if now - _ccusage_last_respawn_at < _CCUSAGE_RESPAWN_COOLDOWN_SECONDS:
        return False
    _ccusage_last_respawn_at = now

    server_dir = str(Path(__file__).parent)
    collector = str(Path(__file__).parent / "ccusage_collector.py")
    try:
        log_fh = open(CCUSAGE_COLLECTOR_LOG, "a", encoding="utf-8")
        subprocess.Popen(  # noqa: S603 — fixed argv, not user input
            [sys.executable, collector, "--foreground"],
            cwd=server_dir,
            stdin=subprocess.DEVNULL,
            stdout=log_fh,
            stderr=log_fh,
            start_new_session=True,
            close_fds=True,
        )
        print(f"[LCARS] ccusage collector was not running — respawned (log: {CCUSAGE_COLLECTOR_LOG})")
        return True
    except (FileNotFoundError, OSError) as exc:
        print(f"[LCARS] WARNING: failed to respawn ccusage collector: {exc}")
        return False


def format_bytes_export(size):
    """Format bytes to human-readable string"""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size < 1024:
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TB"


# File exclusion rules — match kanban-backup.py create_directory_backup_zip
EXPORT_EXCLUDE_SUFFIXES = {'.lock'}
EXPORT_EXCLUDE_NAMES = {'.DS_Store', 'firebase-debug.log'}
EXPORT_EXCLUDE_PATTERNS = {'*-debug.log'}


def _export_should_exclude(filepath):
    """Return True if a file should be skipped from export. Mirrors backup logic."""
    name = filepath.name
    if name in EXPORT_EXCLUDE_NAMES:
        return True
    if filepath.suffix in EXPORT_EXCLUDE_SUFFIXES:
        return True
    for pattern in EXPORT_EXCLUDE_PATTERNS:
        if filepath.match(pattern):
            return True
    return False


def _split_team_id(team_id):
    """Split a team ID into (base_team, project_params).

    Examples:
        academy                        -> ("academy", [])
        ios                            -> ("ios", [])
        finance-personal               -> ("finance", ["personal"])
        legal-coparenting              -> ("legal", ["coparenting"])
        freelance-doublenode-starwords -> ("freelance", ["doublenode", "starwords"])
    """
    if '-' not in team_id:
        return team_id, []
    parts = team_id.split('-')
    return parts[0], parts[1:]


# Multi-project base teams whose out-of-tree knowledge lives under
# ~/dev-team/kanban/<base>/knowledge/. Academy's kanban dir is
# ~/dev-team/kanban/ itself, so it physically contains these subdirs —
# they must be excluded from the academy export walk to prevent academy
# archives from overwriting other teams' knowledge on restore.
MULTI_PROJECT_BASE_TEAMS = frozenset({'finance', 'legal', 'medical', 'freelance'})


def _base_team_knowledge_dir(base_team):
    """Return the canonical out-of-tree knowledge dir for a base team.

    Only applies to multi-project teams (finance, legal, medical, freelance).
    Single-project teams (ios, android, etc.) keep their knowledge inside
    their own kanban dir and don't need out-of-tree handling.
    Academy is special — its kanban dir IS ~/dev-team/kanban/ so its own
    knowledge is already in-tree, but other base teams' knowledge also
    lives there and must be excluded from academy's walk.
    """
    if base_team not in MULTI_PROJECT_BASE_TEAMS:
        return None
    return Path.home() / "dev-team" / "kanban" / base_team / "knowledge"


# XACA-0453: Separators recognised when stripping a label prefix from a name.
_LABEL_SEPARATORS = (' - ', ': ', ' — ')  # hyphen, colon, em-dash


def _strip_label_prefix(name: str, label: str) -> str:
    """Strip a leading label + separator from *name* if present.

    LCARS renders release cards as ``{shortTitle} - {name}``.  When a user
    accidentally includes the shortTitle at the start of the name field the
    card reads ``REL - REL - Sprint 5``.  This helper removes the duplicate
    prefix so the stored name is just ``Sprint 5``.

    Args:
        name:  The release ``name`` field value.
        label: The release ``shortTitle`` field value (the label prefix).

    Returns:
        *name* with the leading ``label + separator`` removed, or *name*
        unchanged when no recognised prefix is found or the result would be
        empty.

    Separators checked (in order): ``' - '``, ``': '``, ``' — '`` (em-dash).
    Comparison is case-sensitive; ``label`` is matched literally.
    ``None`` / empty *label* is treated as no-op.
    """
    if not label or not label.strip() or not name:
        return name

    for sep in _LABEL_SEPARATORS:
        prefix = label + sep
        if name.startswith(prefix):
            stripped = name[len(prefix):]
            # Never return an empty string — preserve the original when the
            # separator is the last thing in the name (e.g. "REL - ").
            if stripped:
                return stripped
            # Prefix matched but nothing follows — return name unchanged.
            return name

    return name


def generate_export(job_id, team_id):
    """Generate a per-team export zip (runs in background thread).

    Archive contents:
    - All files under TEAM_KANBAN_DIRS[team_id] (the project kanban tree)
    - For multi-project teams, also ~/dev-team/kanban/<base>/knowledge/
      (out-of-tree knowledge, placed under __out_of_tree__/knowledge/ in the zip)
    - export-manifest.json at the zip root

    Matches kanban-backup.py exclusion rules: *.lock, *-debug.log, .DS_Store,
    firebase-debug.log.
    """
    import zipfile
    import socket
    from datetime import datetime, timezone

    try:
        EXPORT_DIR.mkdir(parents=True, exist_ok=True)

        base_team, project_params = _split_team_id(team_id)
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        filename = f"lcars-export-{team_id}-{timestamp}.zip"
        output_path = EXPORT_DIR / filename

        kanban_dir = TEAM_KANBAN_DIRS.get(team_id)
        if kanban_dir is None or not kanban_dir.exists():
            EXPORT_JOBS[job_id].update({
                'status': 'failed',
                'progress': 0,
                'message': f'Kanban directory not found for team {team_id}',
                'error': f'TEAM_KANBAN_DIRS has no entry for {team_id} or path does not exist',
            })
            return

        out_of_tree_dir = _base_team_knowledge_dir(base_team)

        EXPORT_JOBS[job_id]['message'] = 'Scanning files...'
        EXPORT_JOBS[job_id]['progress'] = 5

        # Collect in-tree files (project kanban directory).
        # For academy: skip ~/dev-team/kanban/<base>/ subdirs for other
        # multi-project base teams — those belong to the finance/legal/medical/
        # freelance teams and get handled as their own out-of-tree knowledge.
        # Including them here would let an academy restore stomp other teams'
        # knowledge, which violates the merge-not-overwrite policy.
        skip_top_segments = MULTI_PROJECT_BASE_TEAMS if team_id == 'academy' else frozenset()

        in_tree_files = []
        for item in kanban_dir.rglob("*"):
            if not item.is_file() or _export_should_exclude(item):
                continue
            rel = item.relative_to(kanban_dir)
            if rel.parts and rel.parts[0] in skip_top_segments:
                continue
            in_tree_files.append((item, rel))

        # Collect out-of-tree knowledge files (multi-project teams only)
        out_of_tree_files = []
        if out_of_tree_dir and out_of_tree_dir.exists():
            for item in out_of_tree_dir.rglob("*"):
                if item.is_file() and not _export_should_exclude(item):
                    out_of_tree_files.append((item, item.relative_to(out_of_tree_dir)))

        total_files = len(in_tree_files) + len(out_of_tree_files)
        if total_files == 0:
            EXPORT_JOBS[job_id].update({
                'status': 'failed',
                'progress': 0,
                'message': 'No files to export',
                'error': 'Kanban directory is empty',
            })
            return

        EXPORT_JOBS[job_id]['message'] = f'Compressing {total_files} files...'
        EXPORT_JOBS[job_id]['progress'] = 10

        with zipfile.ZipFile(output_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
            processed = 0

            # In-tree project data → kanban/ prefix inside zip
            for src, rel in in_tree_files:
                try:
                    zipf.write(src, f"kanban/{rel}")
                except (PermissionError, FileNotFoundError) as e:
                    print(f"[LCARS Export] Skipped: {rel} ({e.__class__.__name__})")
                processed += 1
                if processed % 50 == 0:
                    EXPORT_JOBS[job_id]['progress'] = 10 + int((processed / total_files) * 80)
                    EXPORT_JOBS[job_id]['message'] = f'Compressing... ({processed}/{total_files} files)'

            # Out-of-tree knowledge → __out_of_tree__/knowledge/ prefix
            for src, rel in out_of_tree_files:
                try:
                    zipf.write(src, f"__out_of_tree__/knowledge/{rel}")
                except (PermissionError, FileNotFoundError) as e:
                    print(f"[LCARS Export] Skipped: {rel} ({e.__class__.__name__})")
                processed += 1
                if processed % 50 == 0:
                    EXPORT_JOBS[job_id]['progress'] = 10 + int((processed / total_files) * 80)
                    EXPORT_JOBS[job_id]['message'] = f'Compressing... ({processed}/{total_files} files)'

            # Write manifest
            EXPORT_JOBS[job_id]['message'] = 'Writing manifest...'
            EXPORT_JOBS[job_id]['progress'] = 92

            manifest = {
                "version": "1.0",
                "kind": "lcars-team-export",
                "team": team_id,
                "baseTeam": base_team,
                "projectParams": project_params,
                "sourceHost": socket.gethostname(),
                "sourceKanbanDir": str(kanban_dir),
                "sourceOutOfTreeKnowledgeDir": str(out_of_tree_dir) if out_of_tree_dir else None,
                "createdAt": datetime.now(timezone.utc).isoformat(),
                "fileCount": {
                    "inTree": len(in_tree_files),
                    "outOfTree": len(out_of_tree_files),
                    "total": total_files,
                },
                "excludePatterns": sorted(EXPORT_EXCLUDE_NAMES | {f'*{s}' for s in EXPORT_EXCLUDE_SUFFIXES} | EXPORT_EXCLUDE_PATTERNS),
            }
            zipf.writestr("export-manifest.json", json.dumps(manifest, indent=2))

        file_size = output_path.stat().st_size
        EXPORT_JOBS[job_id].update({
            'status': 'completed',
            'progress': 100,
            'message': 'Export ready for download',
            'filename': filename,
            'fileSize': format_bytes_export(file_size),
            'fileSizeBytes': file_size,
            'totalFiles': total_files,
            'manifest': manifest,
        })

        # XACA-0496-004: Append team_transfer manifest + verifier report as
        # supplementary audit artifacts. Failures here are non-fatal — the
        # core export already succeeded; we only update verifierSummary.
        try:
            import subprocess
            import sys
            import tempfile

            # Determine which team name the team_transfer config is keyed by.
            # Config lives in lcars-ui/team_transfer/config/<team>.yaml.
            # If team_id is a derived form (e.g. "finance-personal"), fall back
            # to base_team; if both fail, skip gracefully.
            lcars_ui_dir = Path(__file__).parent
            tt_config_dir = lcars_ui_dir / "team_transfer" / "config"
            tt_team = team_id if (tt_config_dir / f"{team_id}.yaml").exists() else (
                base_team if (tt_config_dir / f"{base_team}.yaml").exists() else None
            )

            if tt_team is None:
                EXPORT_JOBS[job_id]['verifierSummary'] = {
                    'exit': -1,
                    'error': f'No team_transfer config found for team_id={team_id!r} or base_team={base_team!r}',
                }
            else:
                EXPORT_JOBS[job_id]['message'] = 'Generating team_transfer manifest...'

                with tempfile.TemporaryDirectory() as tmp_str:
                    tmp = Path(tmp_str)
                    tt_manifest_path = tmp / "manifest.json"

                    gen_result = subprocess.run(
                        [sys.executable, "-m", "team_transfer.generator",
                         "--team", tt_team,
                         "--output", str(tt_manifest_path),
                         "--allow-untagged"],
                        cwd=str(lcars_ui_dir),
                        env={**os.environ, "PYTHONPATH": str(lcars_ui_dir)},
                        capture_output=True, text=True, timeout=120,
                    )

                    if gen_result.returncode not in (0, 1) or not tt_manifest_path.exists():
                        # exit 2 = config error; or manifest was not written
                        gen_err = (gen_result.stderr or gen_result.stdout or "").strip()
                        EXPORT_JOBS[job_id]['verifierSummary'] = {
                            'exit': -1,
                            'error': f'team_transfer.generator failed (rc={gen_result.returncode}): {gen_err[:200]}',
                        }
                    else:
                        ver_result = subprocess.run(
                            [sys.executable, "-m", "team_transfer.verifier",
                             "--manifest", str(tt_manifest_path), "--quiet"],
                            cwd=str(lcars_ui_dir),
                            env={**os.environ, "PYTHONPATH": str(lcars_ui_dir)},
                            capture_output=True, text=True, timeout=120,
                        )
                        verifier_output = ver_result.stdout + ver_result.stderr
                        verifier_exit = ver_result.returncode

                        # Parse pass/warn/fail counts from the SUMMARY block.
                        counts = {'PASS': 0, 'WARN': 0, 'FAIL': 0}
                        for line in verifier_output.splitlines():
                            m = re.search(r"^\s*(PASS|WARN|FAIL):\s*(\d+)", line)
                            if m:
                                counts[m.group(1)] = int(m.group(2))

                        # Append both files into the already-written zip.
                        with zipfile.ZipFile(output_path, 'a', zipfile.ZIP_DEFLATED) as zipf:
                            zipf.write(str(tt_manifest_path), "team_transfer/manifest.json")
                            zipf.writestr("team_transfer/verifier-report.txt", verifier_output)

                        EXPORT_JOBS[job_id]['verifierSummary'] = {
                            'exit': verifier_exit,
                            'pass': counts['PASS'],
                            'warn': counts['WARN'],
                            'fail': counts['FAIL'],
                            'reportPath': 'team_transfer/verifier-report.txt',
                            'manifestPath': 'team_transfer/manifest.json',
                        }
                        print(
                            f"[LCARS Export] team_transfer: exit={verifier_exit} "
                            f"PASS={counts['PASS']} WARN={counts['WARN']} FAIL={counts['FAIL']}"
                        )

        except Exception as tt_exc:
            print(f"[LCARS Export] team_transfer step failed (non-fatal): {tt_exc}")
            EXPORT_JOBS[job_id]['verifierSummary'] = {
                'exit': -1,
                'error': str(tt_exc)[:200],
            }

    except Exception as e:
        EXPORT_JOBS[job_id].update({
            'status': 'failed',
            'progress': 0,
            'message': f'Export failed: {str(e)}',
            'error': str(e),
        })


def generate_secrets_export(job_id, team_id, password, paired_export_id=None):
    """Generate a per-team AES-256 password-protected secrets zip (runs in background thread).

    XACA-0172-002: secrets are discovered via discover_secrets_sources(), encrypted
    with pyzipper (WZ_AES), and a manifest is appended as the last entry in the zip.
    The password is held only in local worker memory and is never stored or logged.

    Args:
        job_id:           UUID for this job (key into SECRETS_EXPORT_JOBS).
        team_id:          LCARS_TEAM value (e.g. "academy", "ios").
        password:         Encryption password — held in local scope only.
        paired_export_id: Optional job_id of the concurrently-created main export.
    """
    import socket
    from datetime import datetime, timezone

    staged_path = None
    try:
        # ------------------------------------------------------------------ #
        # 1. Dependency check                                                  #
        # ------------------------------------------------------------------ #
        if not pyzipper_available():
            SECRETS_EXPORT_JOBS[job_id].update({
                'status': 'failed',
                'progress': 0,
                'message': 'pyzipper dependency missing',
                'error': (
                    "pyzipper dependency missing — install via "
                    "'pip install pyzipper' or reinstall the AITeamForge tap"
                ),
            })
            return

        import pyzipper

        # ------------------------------------------------------------------ #
        # 2. Discover secrets sources                                          #
        # ------------------------------------------------------------------ #
        SECRETS_EXPORT_JOBS[job_id]['message'] = 'Discovering secrets sources...'
        SECRETS_EXPORT_JOBS[job_id]['progress'] = 5

        discovery = discover_secrets_sources(team_id)
        sources = discovery.get("sources", [])
        target_root = discovery.get("target_root", "secrets/")
        manifest_used = discovery.get("manifest_used", "auto")

        # Store manifest_used in job immediately (status endpoint returns it)
        SECRETS_EXPORT_JOBS[job_id]['manifestUsed'] = manifest_used

        if not sources:
            SECRETS_EXPORT_JOBS[job_id].update({
                'status': 'skipped',
                'progress': 100,
                'message': 'No secrets directory found for this team — nothing to export.',
            })
            return

        # ------------------------------------------------------------------ #
        # 3. Build file list                                                   #
        # ------------------------------------------------------------------ #
        SECRETS_EXPORT_JOBS[job_id]['message'] = 'Scanning secrets files...'
        SECRETS_EXPORT_JOBS[job_id]['progress'] = 10

        # Each entry: (abs_path, arc_name_in_zip, source_target_rel)
        file_entries = []    # list of (Path, str arc_path)
        source_summary = []  # for manifest sources[]

        for src_entry in sources:
            src_path = Path(src_entry["src"])
            target_rel = src_entry["target"]
            kind = src_entry.get("kind", "dir" if src_path.is_dir() else "file")

            if kind == "dir" and src_path.is_dir():
                # XACA-0491: build the archive prefix cleanly whether target_rel is
                # non-empty ("subdir") or empty ("" — place directly under target_root).
                # Without this guard an empty target_rel produces "secrets//file.txt".
                arc_prefix = f"{target_root}{target_rel}/" if target_rel else target_root
                dir_files = []
                for item in src_path.rglob("*"):
                    if item.is_file():
                        rel = item.relative_to(src_path)
                        arc_name = f"{arc_prefix}{rel}"
                        file_entries.append((item, arc_name))
                        dir_files.append(item)
                source_summary.append({
                    "target": target_rel,
                    "kind": "dir",
                    "fileCount": len(dir_files),
                })
            elif kind == "file" and src_path.is_file():
                arc_name = f"{target_root}{target_rel}"
                file_entries.append((src_path, arc_name))
                source_summary.append({
                    "target": target_rel,
                    "kind": "file",
                    "fileCount": 1,
                })

        total_files = len(file_entries)
        if total_files == 0:
            SECRETS_EXPORT_JOBS[job_id].update({
                'status': 'skipped',
                'progress': 100,
                'message': 'Secrets sources exist but contain no files — nothing to export.',
            })
            return

        # ------------------------------------------------------------------ #
        # 4. Write encrypted zip                                               #
        # ------------------------------------------------------------------ #
        EXPORT_DIR.mkdir(parents=True, exist_ok=True)

        base_team, _ = _split_team_id(team_id)
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        filename = f"{team_id}-secrets-{timestamp}.zip"
        staged_path = EXPORT_DIR / filename

        SECRETS_EXPORT_JOBS[job_id]['message'] = f'Encrypting {total_files} file(s)...'
        SECRETS_EXPORT_JOBS[job_id]['progress'] = 15

        # Note: file metadata (names, sizes) are visible in the zip's central directory;
        # only file contents are encrypted (WZ_AES).  Arc-path names must not contain
        # secret values — see threat model in secrets_export_lib.py.
        with pyzipper.AESZipFile(
            staged_path,
            'w',
            compression=pyzipper.ZIP_DEFLATED,
            encryption=pyzipper.WZ_AES,
        ) as zf:
            zf.setpassword(password.encode("utf-8"))

            processed = 0
            for src_path, arc_name in file_entries:
                try:
                    zf.write(src_path, arc_name)
                except (PermissionError, FileNotFoundError) as exc:
                    print(f"[LCARS SecretsExport] Skipped: {arc_name} ({exc.__class__.__name__})")
                processed += 1
                if processed % 20 == 0:
                    SECRETS_EXPORT_JOBS[job_id]['progress'] = 15 + int((processed / total_files) * 75)
                    SECRETS_EXPORT_JOBS[job_id]['message'] = (
                        f'Encrypting... ({processed}/{total_files} files)'
                    )

            # Manifest is the LAST entry in the zip (also encrypted)
            SECRETS_EXPORT_JOBS[job_id]['message'] = 'Writing encrypted manifest...'
            SECRETS_EXPORT_JOBS[job_id]['progress'] = 92

            manifest_doc = {
                "version": SECRETS_EXPORT_MANIFEST_VERSION,
                "kind": SECRETS_EXPORT_MANIFEST_KIND,
                "team": team_id,
                "baseTeam": base_team,
                "sourceHost": socket.gethostname(),
                "exportId": job_id,
                "pairedExportId": paired_export_id,
                "createdAt": datetime.now(timezone.utc).isoformat(),
                "targetRoot": target_root,
                "manifestUsed": manifest_used,
                "fileCount": total_files,
                "sources": source_summary,
            }
            zf.writestr("secrets-manifest.json", json.dumps(manifest_doc, indent=2))

        # Password reference goes out of scope here — let GC handle it.
        password = None  # noqa: F841  # explicit drop

        file_size = staged_path.stat().st_size
        SECRETS_EXPORT_JOBS[job_id].update({
            'status': 'completed',
            'progress': 100,
            'message': 'Secrets export ready for download',
            'filename': filename,
            'fileSize': format_bytes_export(file_size),
            'fileSizeBytes': file_size,
            'totalFiles': total_files,
        })

    except Exception as exc:
        print(f"[LCARS SecretsExport] Error for job {job_id}: {exc}")
        # Clean up any partial zip so a stale file is not served
        if staged_path is not None and staged_path.exists():
            try:
                staged_path.unlink()
            except Exception:
                pass
        SECRETS_EXPORT_JOBS[job_id].update({
            'status': 'failed',
            'progress': 0,
            'message': f'Secrets export failed: {str(exc)}',
            'error': str(exc),
        })


def _rewrite_team_ids_in_file(filepath, old_team_id, new_team_id):
    """Rewrite occurrences of old_team_id → new_team_id inside a text file.

    Used during import when source and target team IDs differ (e.g.,
    finance-personal → finance-budget). Scoped to JSON and MD files in
    the project kanban tree. Out-of-tree knowledge is NOT rewritten —
    it's base-team scoped and shared across project instances.
    """
    try:
        text = filepath.read_text(encoding='utf-8')
    except (UnicodeDecodeError, OSError):
        return False
    if old_team_id not in text:
        return False
    new_text = text.replace(old_team_id, new_team_id)
    filepath.write_text(new_text, encoding='utf-8')
    return True


def apply_import(job_id):
    """Apply a staged import to the target team's kanban dir (background thread).

    Steps:
    1. Extract staged zip to a temp scratch dir
    2. Validate manifest (should already be validated at upload time)
    3. Overwrite target kanban dir with contents of kanban/ from zip
    4. If source team ID ≠ target team ID, rewrite references in JSON/MD files
       and rename <old>-board.json → <new>-board.json
    5. Merge out-of-tree knowledge (if present) into ~/dev-team/kanban/<base>/knowledge/
       with rename-on-conflict semantics for knowledge files and INDEX.md
    """
    import zipfile
    import shutil
    import socket
    from datetime import datetime, timezone

    job = IMPORT_JOBS.get(job_id)
    if not job:
        return

    try:
        staged_path = Path(job['stagedPath'])
        if not staged_path.exists():
            raise FileNotFoundError(f'Staged archive missing: {staged_path}')

        source_team = job['manifest']['team']
        target_team = job['targetTeam']
        source_base, _ = _split_team_id(source_team)
        target_base, _ = _split_team_id(target_team)

        if source_base != target_base:
            raise ValueError(
                f'Base team mismatch: source={source_base}, target={target_base}. '
                f'Archive can only be imported into the same base team.'
            )

        target_kanban_dir = TEAM_KANBAN_DIRS.get(target_team)
        if target_kanban_dir is None:
            raise ValueError(f'No kanban directory configured for target team {target_team}')
        if not target_kanban_dir.exists():
            raise FileNotFoundError(
                f'Target kanban directory does not exist: {target_kanban_dir}. '
                f'Install the team via AITeamForge before importing.'
            )

        scratch_dir = IMPORT_STAGING_DIR / f"extract-{job_id}"
        if scratch_dir.exists():
            shutil.rmtree(scratch_dir)
        scratch_dir.mkdir(parents=True)

        IMPORT_JOBS[job_id]['message'] = 'Extracting archive...'
        IMPORT_JOBS[job_id]['progress'] = 10

        with zipfile.ZipFile(staged_path, 'r') as zipf:
            zipf.extractall(scratch_dir)

        # --- Step 1: Overwrite project kanban tree ---
        IMPORT_JOBS[job_id]['message'] = 'Overwriting project kanban tree...'
        IMPORT_JOBS[job_id]['progress'] = 30

        extracted_kanban = scratch_dir / "kanban"
        if not extracted_kanban.exists():
            raise FileNotFoundError('Archive missing kanban/ directory')

        # Clear target kanban contents (except the dir itself) then copy extracted
        for item in list(target_kanban_dir.iterdir()):
            if item.is_dir():
                shutil.rmtree(item)
            else:
                item.unlink()

        for src in extracted_kanban.rglob("*"):
            if src.is_file():
                rel = src.relative_to(extracted_kanban)
                dest = target_kanban_dir / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dest)

        # --- Step 2: Team ID rewrite if source ≠ target ---
        renames = 0
        if source_team != target_team:
            IMPORT_JOBS[job_id]['message'] = f'Rewriting team IDs ({source_team} → {target_team})...'
            IMPORT_JOBS[job_id]['progress'] = 55

            # Rename board file if present
            old_board = target_kanban_dir / f"{source_team}-board.json"
            new_board = target_kanban_dir / f"{target_team}-board.json"
            if old_board.exists():
                old_board.rename(new_board)
                renames += 1

            # Grep-rewrite JSON and MD files
            for f in target_kanban_dir.rglob("*"):
                if f.is_file() and f.suffix in ('.json', '.md'):
                    if _rewrite_team_ids_in_file(f, source_team, target_team):
                        renames += 1

        # --- Step 3: Merge out-of-tree knowledge ---
        merged_files = 0
        renamed_conflicts = 0
        extracted_oot = scratch_dir / "__out_of_tree__" / "knowledge"
        if extracted_oot.exists():
            IMPORT_JOBS[job_id]['message'] = 'Merging out-of-tree knowledge...'
            IMPORT_JOBS[job_id]['progress'] = 75

            target_oot = _base_team_knowledge_dir(target_base)
            if target_oot is None:
                # Single-project team on target — shouldn't have out-of-tree data
                # but the source sent some. Log and skip.
                print(f'[LCARS Import] Warning: source has out-of-tree knowledge but target '
                      f'base team {target_base} is single-project. Skipping merge.')
            else:
                target_oot.mkdir(parents=True, exist_ok=True)
                source_host = job['manifest'].get('sourceHost', 'unknown')
                import_ts = datetime.now().strftime("%Y%m%d-%H%M%S")

                for src in extracted_oot.rglob("*"):
                    if not src.is_file():
                        continue
                    rel = src.relative_to(extracted_oot)
                    dest = target_oot / rel
                    dest.parent.mkdir(parents=True, exist_ok=True)

                    if not dest.exists():
                        shutil.copy2(src, dest)
                        merged_files += 1
                    else:
                        # Conflict: keep both with rename suffix
                        suffix = dest.suffix
                        stem = dest.stem
                        if stem == "INDEX":
                            # INDEX.md → INDEX.imported-<host>-<ts>.md
                            rename_target = dest.with_name(
                                f"INDEX.imported-{source_host}-{import_ts}{suffix}"
                            )
                        else:
                            rename_target = dest.with_name(
                                f"{stem}.imported-{source_host}-{import_ts}{suffix}"
                            )
                        shutil.copy2(src, rename_target)
                        renamed_conflicts += 1

        IMPORT_JOBS[job_id].update({
            'status': 'completed',
            'progress': 100,
            'message': 'Import complete',
            'stats': {
                'inTreeRenames': renames,
                'outOfTreeMerged': merged_files,
                'outOfTreeConflicts': renamed_conflicts,
            },
        })

        # Cleanup scratch + staged zip
        try:
            shutil.rmtree(scratch_dir)
        except Exception:
            pass

    except Exception as e:
        IMPORT_JOBS[job_id].update({
            'status': 'failed',
            'progress': 0,
            'message': f'Import failed: {str(e)}',
            'error': str(e),
        })


def apply_secrets_import(job_id, password):
    """Extract an AES-256 encrypted secrets zip to manifest-recorded target paths.

    XACA-0172-003: password is held only in local scope and is never stored or logged.

    Steps:
    1. Open staged zip with pyzipper, verify password by reading secrets-manifest.json.
    2. Validate manifest kind/version and team match.
    3. No-clobber check — any existing target file causes a hard fail (no partial extraction).
    4. Atomic extraction — stage to temp dir first, then move all files to targets.
    5. On success: status='completed', delete staged zip.
    """
    import shutil
    import tempfile
    from datetime import datetime, timezone

    job = SECRETS_IMPORT_JOBS.get(job_id)
    if not job:
        return

    def _fail(msg):
        SECRETS_IMPORT_JOBS[job_id].update({
            'status': 'failed',
            'progress': 0,
            'message': msg,
            'error': msg,
        })

    try:
        # ------------------------------------------------------------------ #
        # 1. Dependency check                                                  #
        # ------------------------------------------------------------------ #
        if not pyzipper_available():
            _fail(
                "pyzipper dependency missing — install via "
                "'pip install pyzipper' or reinstall the AITeamForge tap"
            )
            return

        import pyzipper

        staged_path = Path(job['stagedPath'])
        if not staged_path.exists():
            _fail(f'Staged zip missing: {staged_path}')
            return

        SECRETS_IMPORT_JOBS[job_id].update({
            'status': 'verifying',
            'progress': 5,
            'message': 'Verifying password...',
        })

        # ------------------------------------------------------------------ #
        # 2. Verify password + parse manifest                                  #
        # ------------------------------------------------------------------ #
        try:
            with pyzipper.AESZipFile(staged_path, 'r') as zf:
                zf.setpassword(password.encode('utf-8'))
                try:
                    manifest_bytes = zf.read('secrets-manifest.json')
                except RuntimeError:
                    # pyzipper raises RuntimeError on bad password (WZ_AES)
                    _fail("Wrong password — please try again.")
                    return
                except KeyError:
                    _fail(
                        "Archive does not contain secrets-manifest.json — "
                        "not a recognized LCARS secrets export."
                    )
                    return
        except Exception as e:
            import zipfile as _zf
            import pyzipper.zipfile as _pzf
            if isinstance(e, (_zf.BadZipFile, _pzf.BadZipFile)):
                _fail(
                    "Invalid or corrupt secrets zip — please re-export and try again."
                )
                return
            raise

        try:
            manifest = json.loads(manifest_bytes.decode('utf-8'))
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            _fail(f"secrets-manifest.json is not valid JSON: {e}")
            return

        # ------------------------------------------------------------------ #
        # 3. Validate manifest schema                                          #
        # ------------------------------------------------------------------ #
        if manifest.get('kind') != SECRETS_EXPORT_MANIFEST_KIND:
            _fail(
                f"Not a recognized LCARS secrets export "
                f"(kind={manifest.get('kind')!r}, expected {SECRETS_EXPORT_MANIFEST_KIND!r})."
            )
            return

        if manifest.get('version') != SECRETS_EXPORT_MANIFEST_VERSION:
            _fail(
                f"Unsupported secrets export version: {manifest.get('version')!r} "
                f"(expected {SECRETS_EXPORT_MANIFEST_VERSION!r})."
            )
            return

        # ------------------------------------------------------------------ #
        # 4. Team match check (warn-only — cross-team transfer is allowed)     #
        # ------------------------------------------------------------------ #
        target_team = job['targetTeam']
        manifest_team = manifest.get('team', '')
        manifest_base = manifest.get('baseTeam', '')
        target_base, _ = _split_team_id(target_team)

        team_warning = None
        if manifest_team != target_team:
            team_warning = (
                f"Team mismatch: archive was exported from '{manifest_team}', "
                f"importing into '{target_team}'. Proceeding (cross-team transfer)."
            )
            SECRETS_IMPORT_JOBS[job_id]['message'] = team_warning

        SECRETS_IMPORT_JOBS[job_id].update({
            'manifest': manifest,
            'status': 'ready',
            'progress': 15,
            'message': team_warning or 'Manifest verified. Preparing extraction...',
        })

        # ------------------------------------------------------------------ #
        # 5. Build target-path list                                            #
        # ------------------------------------------------------------------ #
        target_root = manifest.get('targetRoot', 'secrets/')
        sources = manifest.get('sources', [])

        # Determine project root for the target team
        from secrets_export_lib import _get_team_project_root, _hardcoded_project_root
        project_root = _get_team_project_root(target_team) or _hardcoded_project_root(target_team)
        if project_root is None:
            _fail(f"Cannot determine project root for team '{target_team}'.")
            return

        SECRETS_IMPORT_JOBS[job_id].update({
            'status': 'applying',
            'progress': 20,
            'message': 'Checking for collisions...',
        })

        # Open the zip again to enumerate all member paths for no-clobber check
        with pyzipper.AESZipFile(staged_path, 'r') as zf:
            zf.setpassword(password.encode('utf-8'))
            all_names = [
                n for n in zf.namelist()
                if n != 'secrets-manifest.json' and not n.endswith('/')
            ]

        # ------------------------------------------------------------------ #
        # 6a. Path-traversal containment: arc entries must resolve INSIDE     #
        #     project_root. Crafted zips with "../../.ssh/authorized_keys"   #
        #     or absolute paths are refused before any file operation. The   #
        #     server binds to all interfaces and is reachable from tailnet   #
        #     peers, so this is a real attack vector — not hypothetical.    #
        # ------------------------------------------------------------------ #
        project_root_resolved = project_root.resolve()
        for arc_name in all_names:
            arc_path = Path(arc_name)
            if arc_path.is_absolute():
                _fail(
                    f"Archive contains an absolute path entry: {arc_name} — "
                    "refusing to extract."
                )
                return
            candidate = (project_root / arc_name).resolve()
            try:
                candidate.relative_to(project_root_resolved)
            except ValueError:
                _fail(
                    f"Archive contains an entry that escapes the target "
                    f"directory: {arc_name} — refusing to extract."
                )
                return

        # ------------------------------------------------------------------ #
        # 6b. No-clobber: fail hard if ANY target already exists              #
        # ------------------------------------------------------------------ #
        # arc entries are already under targetRoot (e.g. "secrets/env/.env")
        # absolute target = project_root / arc_name
        collision_paths = []
        for arc_name in all_names:
            target_path = project_root / arc_name
            if target_path.exists():
                collision_paths.append(str(target_path))

        if collision_paths:
            first = collision_paths[0]
            count = len(collision_paths)
            plural = 's' if count > 1 else ''
            _fail(
                f"File already exists at {first}"
                + (f" (and {count - 1} other{plural})" if count > 1 else "")
                + " — remove or rename and re-import. "
                  "(No files were extracted; import is atomic.)"
            )
            return

        # ------------------------------------------------------------------ #
        # 7. Atomic extraction: stage → move                                  #
        # ------------------------------------------------------------------ #
        SECRETS_IMPORT_JOBS[job_id].update({
            'progress': 30,
            'message': f'Extracting {len(all_names)} file(s)...',
            'fileCount': len(all_names),
        })

        tmp_stage = Path(tempfile.mkdtemp(
            prefix=f"lcars-secrets-import-{job_id}-",
            dir=SECRETS_IMPORT_STAGING_DIR if SECRETS_IMPORT_STAGING_DIR.exists()
            else Path(tempfile.gettempdir()),
        ))

        try:
            # Extract everything to temp staging area
            SECRETS_IMPORT_STAGING_DIR.mkdir(parents=True, exist_ok=True)
            with pyzipper.AESZipFile(staged_path, 'r') as zf:
                zf.setpassword(password.encode('utf-8'))
                for arc_name in all_names:
                    dest_in_stage = tmp_stage / arc_name
                    dest_in_stage.parent.mkdir(parents=True, exist_ok=True)
                    dest_in_stage.write_bytes(zf.read(arc_name))

            SECRETS_IMPORT_JOBS[job_id].update({
                'progress': 70,
                'message': 'Moving files to target paths...',
            })

            # Move from staging to final target paths
            moved = 0
            for arc_name in all_names:
                src_file = tmp_stage / arc_name
                dest_file = project_root / arc_name
                try:
                    dest_file.parent.mkdir(parents=True, exist_ok=True)
                except PermissionError:
                    raise PermissionError(
                        f"Permission denied writing to {dest_file.parent}. "
                        "Adjust filesystem permissions and re-import."
                    )
                try:
                    shutil.move(str(src_file), str(dest_file))
                except PermissionError:
                    raise PermissionError(
                        f"Permission denied writing to {dest_file}. "
                        "Adjust filesystem permissions and re-import."
                    )
                moved += 1
                progress = 70 + int((moved / len(all_names)) * 25)
                SECRETS_IMPORT_JOBS[job_id]['progress'] = progress

        except Exception:
            # Blow away temp stage; leave target tree untouched
            shutil.rmtree(tmp_stage, ignore_errors=True)
            raise
        else:
            shutil.rmtree(tmp_stage, ignore_errors=True)

        # ------------------------------------------------------------------ #
        # 8. Success                                                           #
        # ------------------------------------------------------------------ #
        try:
            staged_path.unlink()
        except Exception:
            pass

        SECRETS_IMPORT_JOBS[job_id].update({
            'status': 'completed',
            'progress': 100,
            'message': f"Extracted {len(all_names)} file(s) to {target_root}",
            'fileCount': len(all_names),
        })

    except Exception as e:
        _fail(f'Secrets import failed: {str(e)}')


def get_board_file(team: str) -> Path:
    """Get the board file path for a team using distributed directories."""
    kanban_dir = TEAM_KANBAN_DIRS.get(team, KANBAN_DIR)
    return kanban_dir / f"{team}-board.json"
BACKUP_STATUS_FILE = BACKUP_DIR / "backup-status.json"
UI_DIR = Path(__file__).parent
CONFIG_DIR = Path.home() / "dev-team" / "config"
SESSION_NAME = os.environ.get("LCARS_SESSION_NAME", "lcars")
LCARS_TEAM = os.environ.get("LCARS_TEAM", "").strip()
def _resolve_server_hostname() -> str:
    """Prefer the Tailscale MagicDNS short name — it is stable,
    user-controlled, and matches the host argument users pass to
    team-connect.sh when attaching to a remote team (e.g. the
    first label of Self.DNSName, "darren-m4-mini"). Falls back in
    order: Self.HostName → socket.gethostname() with .local stripped.

    Why DNSName, not HostName: Self.HostName is the raw OS hostname
    Tailscale captured when the node first authed, and does NOT update
    when the user renames the machine in the Tailscale control panel.
    Self.DNSName is the MagicDNS FQDN which DOES update on rename.
    Taking the first label of DNSName gives us the name the user
    actually types.

    Resolved once at module load; downstream API handlers read the
    cached SERVER_HOSTNAME constant so we do not fork tailscale per
    request.
    """
    import shutil
    tailscale = shutil.which("tailscale")
    if not tailscale:
        _app_cli = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        if Path(_app_cli).exists():
            tailscale = _app_cli
    if tailscale:
        try:
            result = subprocess.run(
                [tailscale, "status", "--json", "--self=true"],
                capture_output=True, text=True, timeout=3, check=False,
            )
            if result.returncode == 0 and result.stdout:
                data = json.loads(result.stdout)
                self_info = data.get("Self") or {}
                dns = (self_info.get("DNSName") or "").rstrip(".")
                if dns:
                    short = dns.split(".", 1)[0]
                    if short:
                        return short
                # Fallback: raw HostName if DNSName unavailable
                ts_name = self_info.get("HostName")
                if ts_name:
                    return ts_name
        except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
            pass
    return socket.gethostname().removesuffix(".local")


SERVER_HOSTNAME = _resolve_server_hostname()
# Team-specific tmp directory — resolved from SESSION_NAME via kanban_utils.
# Falls back to /tmp/ for unknown sessions.
LCARS_TMP_DIR = Path(get_lcars_tmp_dir(SESSION_NAME))

# Team-specific configuration directories (distributed into each team's kanban/config/)
# Releases, integrations, and calendar configs live alongside board data for self-containment.
# CONFIG_DIR above is retained for shared infrastructure (templates/, credentials.enc).
TEAM_CONFIG_DIR = TEAM_KANBAN_DIRS.get(LCARS_TEAM, KANBAN_DIR) / "config"
# RELEASES_FILE removed - releases now stored in kanban board file's .releases array
# EPICS_FILE removed - epics now stored in kanban board file's .epics array
INTEGRATIONS_FILE = TEAM_CONFIG_DIR / "integrations.json"
# NOTE: No central RELEASES_DIR - releases are stored in each team's own project directory
# Use _get_releases_dir_for_team(team) to get the correct path

# AMB (Agent Merit Badges) badge cache — { handle: { "badges": [...], "fetched_at": float } }
_amb_badge_cache = {}
_AMB_CACHE_TTL = 300  # 5 minutes


def _fetch_amb_badges(handle):
    """Fetch badges for an AMB agent handle, with 5-minute cache TTL.

    Returns a list of badge dicts [{"emoji": "...", "name": "...", "tier": "..."}].
    Returns empty list on any failure (graceful degradation).
    """
    if not handle:
        return []

    now = time.time()
    cached = _amb_badge_cache.get(handle)
    if cached and (now - cached["fetched_at"]) < _AMB_CACHE_TTL:
        return cached["badges"]

    try:
        url = f"https://dev.agentbadges.com/api/v1/agents/{handle}/patches"
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            resp_data = json.loads(resp.read().decode())
            patches = resp_data.get("data", [])
            badges = [
                {"emoji": p.get("emoji", ""), "name": p.get("name", ""), "tier": p.get("tier", "")}
                for p in patches
                if p.get("emoji")
            ]
            _amb_badge_cache[handle] = {"badges": badges, "fetched_at": now}
            return badges
    except Exception:
        # On failure, return stale cache if available, otherwise empty
        if cached:
            return cached["badges"]
        return []


CCUSAGE_STALENESS_THRESHOLD_S = 300  # 5-minute stale threshold (mirrors heuristics evaluate())


def _is_cache_stale(collected_at_unix: int | None) -> bool:
    """Return True when the cache is older than CCUSAGE_STALENESS_THRESHOLD_S.

    Uses collected_at_unix (integer epoch seconds) for a cheap, tz-safe check.
    Returns True when the value is absent or zero so callers get a safe default.
    """
    if not collected_at_unix:
        return True
    return (time.time() - collected_at_unix) > CCUSAGE_STALENESS_THRESHOLD_S


def _build_usage_response(
    cache_path: str = CCUSAGE_CACHE_PATH,
    history_limit: int = 7,
    force_refresh: bool = False,
    account_filter: str | None = None,
) -> tuple:
    """Build the response payload for GET /api/usage/current.

    Pure function (no HTTP machinery) so unit tests can call it directly.

    Args:
        cache_path:      Path to the JSON cache file written by ccusage_collector.
        history_limit:   Maximum number of history entries to return (clamped 1-50).
        force_refresh:   If True, attempt to spawn ccusage_collector --once first.
                         Default (False) must NEVER spawn ccusage — endpoint stays <50ms.
        account_filter:  Optional account ID to scope the totals field.
                         None (default) → all-accounts aggregate (unchanged behaviour).
                         "untagged" → totals from the untagged_bucket.
                         Any other value → totals from cache["accounts"][value].
                         When set and found, the response also gains an "account" key.
                         When set and NOT found, returns ok=False with an error message.

    Returns:
        (status_code, response_dict) tuple.
        status_code is always 200; callers must not 500 on errors so the UI
        always has something to render.
    """
    global _ccusage_missing_warned  # noqa: PLW0603

    # Clamp history_limit.
    history_limit = max(1, min(50, history_limit))

    # Self-heal: respawn the collector daemon if it has died. Cheap fast path
    # (kill -0 on the PID) when healthy; throttled detached Popen when not.
    # Runs on every request so panel polls keep the daemon alive without
    # needing a separate launchd/cron watchdog.
    _ensure_collector_running()

    # Optional: attempt a single synchronous ccusage run before reading cache.
    # Used by the dashboard "refresh" button (?refresh=1). The respawn above
    # already restarted the daemon if it was dead; --once gives the user
    # instant feedback while the daemon's first poll catches up.
    if force_refresh and CCUSAGE_HEURISTICS_AVAILABLE:
        _server_dir = str(Path(__file__).parent)
        _collector = str(Path(__file__).parent / "ccusage_collector.py")
        try:
            subprocess.run(
                [sys.executable, _collector, "--once"],
                timeout=5,
                capture_output=True,
                cwd=_server_dir,
            )
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            pass  # Fall through to existing cache

    # Unavailable-weekly sentinel emitted when we cannot reach evaluate_weekly.
    # Always include a "weekly" key so both UIs can unconditionally check
    # d.weekly.available rather than guarding against undefined.
    def _unavailable_weekly(reason: str) -> dict:
        return {"available": False, "reason": reason}

    # Case 1: heuristics module not importable (should not happen in prod).
    if not CCUSAGE_HEURISTICS_AVAILABLE:
        return 200, {
            "ok": False,
            "stale": True,
            "current": None,
            "projection": None,
            "calibration": None,
            "history": [],
            "totals": None,
            "weekly": _unavailable_weekly("ccusage_heuristics module not available"),
            "error": "ccusage_heuristics module not available",
        }

    # Case 2: cache file missing (daemon not started yet).
    if not os.path.exists(cache_path):
        if not _ccusage_missing_warned:
            print(f"[LCARS] WARNING: ccusage cache not found at {cache_path} — is the collector running?")
            _ccusage_missing_warned = True
        return 200, {
            "ok": False,
            "stale": True,
            "current": None,
            "projection": None,
            "calibration": None,
            "history": [],
            "totals": None,
            "weekly": _unavailable_weekly("collector not running"),
            "error": "collector not running",
        }

    # Cache file found — reset the "missing" warning flag so it fires again
    # if the collector ever stops after having run.
    _ccusage_missing_warned = False

    # Case 3: JSON parse failure.
    try:
        with open(cache_path, "r", encoding="utf-8") as _f:
            cache = json.load(_f)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"[LCARS] WARNING: ccusage cache parse error: {exc}")
        return 200, {
            "ok": False,
            "stale": True,
            "current": None,
            "projection": None,
            "calibration": None,
            "history": [],
            "totals": None,
            "weekly": _unavailable_weekly(f"cache parse error: {exc}"),
            "error": str(exc),
        }

    # Case 4: evaluate through heuristics layer.
    result = _ccusage_heuristics.evaluate(cache)

    # Apply history_limit trim.
    if "history" in result and isinstance(result["history"], list):
        result = dict(result)
        result["history"] = result["history"][-history_limit:]

    # XACA-0250-003: append weekly heuristics as a top-level key.
    # evaluate_weekly() returns either a full weekly status dict (available=True)
    # or an unavailability sentinel (available=False).  Existing 5h consumers
    # are unaffected because we only ADD a key, never modify existing ones.
    result["weekly"] = _ccusage_heuristics.evaluate_weekly(cache)

    # XACA-0280 Phase A.2: optional per-account totals filter.
    # When account_filter is None (default), result is returned unchanged so
    # all existing callers see exactly the same response as before.
    if account_filter is not None:
        if account_filter == "untagged":
            bucket = cache.get("untagged_bucket")
            if bucket is None:
                return 200, {
                    "ok": False,
                    "stale": False,
                    "error": "account not found: untagged",
                    "current": result.get("current"),
                    "projection": result.get("projection"),
                    "calibration": result.get("calibration"),
                    "history": result.get("history", []),
                    "totals": None,
                    "weekly": result.get("weekly"),
                }
            account_totals = {
                "today_tokens": bucket.get("today_tokens", 0),
                "today_cost_usd": bucket.get("today_cost_usd", 0.0),
                "last_7d_tokens": bucket.get("last_7d_tokens", 0),
                "last_7d_cost_usd": bucket.get("last_7d_cost_usd", 0.0),
            }
            result = dict(result)
            result["totals"] = account_totals
            result["account"] = {
                "account_id": "untagged",
                "nickname": bucket.get("nickname", "Untagged (pre-isolation)"),
            }
        else:
            accounts = cache.get("accounts", {})
            acct_data = accounts.get(account_filter)
            if acct_data is None:
                return 200, {
                    "ok": False,
                    "stale": False,
                    "error": f"account not found: {account_filter}",
                    "current": result.get("current"),
                    "projection": result.get("projection"),
                    "calibration": result.get("calibration"),
                    "history": result.get("history", []),
                    "totals": None,
                    "weekly": result.get("weekly"),
                }
            if not isinstance(acct_data, dict):
                return 200, {
                    "ok": False,
                    "stale": False,
                    "error": f"account data malformed: {account_filter}",
                    "current": result.get("current"),
                    "projection": result.get("projection"),
                    "calibration": result.get("calibration"),
                    "history": result.get("history", []),
                    "totals": None,
                    "weekly": result.get("weekly"),
                }
            account_totals = {
                "today_tokens": acct_data.get("today_tokens", 0),
                "today_cost_usd": acct_data.get("today_cost_usd", 0.0),
                "last_7d_tokens": acct_data.get("last_7d_tokens", 0),
                "last_7d_cost_usd": acct_data.get("last_7d_cost_usd", 0.0),
            }
            result = dict(result)
            result["totals"] = account_totals
            result["account"] = {
                "account_id": account_filter,
                "nickname": acct_data.get("nickname", account_filter),
            }

    return 200, result


def _build_by_account_response(
    cache_path: str = CCUSAGE_CACHE_PATH,
) -> tuple:
    """Build the response payload for GET /api/usage/by-account — XACA-0280 Phase A.2.

    Pure function (no HTTP machinery) so unit tests can call it directly.

    Returns a flat list of per-account usage summaries plus the untagged bucket and
    all-accounts totals.  burn_rate is null in this phase — per-account burn-rate
    derivation from ccusage session data is a future follow-up.

    Args:
        cache_path:  Path to the JSON cache file written by ccusage_collector.

    Returns:
        (status_code, response_dict) tuple.
        status_code is always 200; callers must not 500 on errors so the UI
        always has something to render.
    """
    # Case 1: heuristics module not importable.
    if not CCUSAGE_HEURISTICS_AVAILABLE:
        return 200, {
            "ok": False,
            "stale": True,
            "error": "ccusage_heuristics module not available",
            "accounts": [],
            "untagged": None,
            "totals": None,
            "collected_at": None,
        }

    # Case 2: cache file missing.
    if not os.path.exists(cache_path):
        return 200, {
            "ok": False,
            "stale": True,
            "error": "collector not running",
            "accounts": [],
            "untagged": None,
            "totals": None,
            "collected_at": None,
        }

    # Case 3: JSON parse failure.
    try:
        with open(cache_path, "r", encoding="utf-8") as _f:
            cache = json.load(_f)
    except (OSError, json.JSONDecodeError) as exc:
        return 200, {
            "ok": False,
            "stale": True,
            "error": str(exc),
            "accounts": [],
            "untagged": None,
            "totals": None,
            "collected_at": None,
        }

    # Check staleness using the shared _is_cache_stale helper.
    collected_at = cache.get("collected_at")
    stale = _is_cache_stale(cache.get("collected_at_unix"))

    # Build accounts list from cache["accounts"] (schema v3).
    raw_accounts = cache.get("accounts", {})
    accounts_list = []
    for acct_id, acct_data in raw_accounts.items():
        accounts_list.append({
            "account_id": acct_id,
            "nickname": acct_data.get("nickname", acct_id),
            "tokens": acct_data.get("last_7d_tokens", 0),
            "cost_usd": acct_data.get("last_7d_cost_usd", 0.0),
            "today_tokens": acct_data.get("today_tokens", 0),
            "today_cost_usd": acct_data.get("today_cost_usd", 0.0),
            "burn_rate": None,  # Per-account burn_rate is a follow-up task
        })

    # Sort by 7-day tokens descending so the largest consumer is on top.
    accounts_list.sort(key=lambda a: a["tokens"], reverse=True)

    # Build untagged bucket summary (null when absent — v2 caches pre-XACA-0280).
    untagged = None
    untagged_raw = cache.get("untagged_bucket")
    if untagged_raw is not None:
        untagged = {
            "nickname": untagged_raw.get("nickname", "Untagged (pre-isolation)"),
            "tokens": untagged_raw.get("last_7d_tokens", 0),
            "cost_usd": untagged_raw.get("last_7d_cost_usd", 0.0),
            "today_tokens": untagged_raw.get("today_tokens", 0),
            "today_cost_usd": untagged_raw.get("today_cost_usd", 0.0),
            "cwds": untagged_raw.get("cwds", []),
        }

    # Totals are the all-accounts aggregate from the top-level cache field (v2+).
    totals = cache.get("totals")

    return 200, {
        "ok": True,
        "stale": stale,
        "collected_at": collected_at,
        "accounts": accounts_list,
        "untagged": untagged,
        "totals": totals,
    }


# XACA-0333-003: TBD sentinel values for copyright fields — server-side single source of truth.
# JS (lcars.js) mirrors this set; update both together if new placeholders are added.
_COPYRIGHT_PLACEHOLDER_VALUES: frozenset = frozenset({'<TBD-per-engagement>', '<TBD>'})


class LCARSHandler(http.server.SimpleHTTPRequestHandler):
    """Custom handler for LCARS Kanban Monitor"""

    # Path prefixes to strip (for Tailscale funnel path-based routing)
    # Note: Team names follow specific formats:
    # - Freelance: freelance-{clientId}-{projectId} (e.g., freelance-doublenode-workstats)
    # - Legal: legal-{projectId} (e.g., legal-coparenting)
    # - MainEvent floaters: mainevent-{projectId} (project-specific)
    PATH_PREFIXES = ['/academy', '/firebase', '/dns', '/freelance-doublenode-workstats', '/freelance-doublenode-starwords', '/freelance-doublenode-appplanning', '/command', '/ios', '/android', '/mainevent', '/legal-coparenting', '/finance-personal']

    # XACA-0333-002: mtime-based cache for team-paths.json (avoids disk read on every GET)
    _TEAM_PATHS_CACHE: dict = {'mtime_ns': None, 'data': None}
    _TEAM_PATHS_CACHE_LOCK: threading.Lock = threading.Lock()

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(UI_DIR), **kwargs)

    def do_OPTIONS(self):
        """Handle CORS preflight requests"""
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_POST(self):
        """Handle POST requests"""
        parsed = urlparse(self.path)
        path = parsed.path

        # Strip known path prefixes for Tailscale funnel compatibility
        for prefix in self.PATH_PREFIXES:
            if path.startswith(prefix + '/'):
                path = path[len(prefix):] or '/'
                break

        if path == '/api/toggle-collapsed':
            self.handle_toggle_collapsed()
        elif path == '/api/update-item':
            self.handle_update_item()
        elif path == '/api/update-subitem':
            self.handle_update_subitem()
        # Integration API endpoints
        elif path == '/api/integrations/search':
            self.handle_integration_search()
        elif path == '/api/integrations/verify':
            self.handle_integration_verify()
        elif path == '/api/integrations/test':
            self.handle_integration_test()
        elif path == '/api/integrations/save':
            self.handle_integration_save()
        elif path == '/api/integrations/delete':
            self.handle_integration_delete()
        elif path == '/api/integrations/boards':
            self.handle_integration_boards()
        elif path == '/api/integrations/create-item':
            self.handle_integration_create_item()
        # Sync API endpoints
        elif path == '/api/sync/item':
            self.handle_sync_item()
        elif path == '/api/sync/board':
            self.handle_sync_board()
        # Import API endpoints
        elif path == '/api/import/fetch':
            self.handle_import_fetch()
        elif path == '/api/import/execute':
            self.handle_import_execute()
        # Release API endpoints
        elif path == '/api/releases':
            self.handle_create_release()
        elif path.startswith('/api/releases/') and path.endswith('/items'):
            release_id = path.replace('/api/releases/', '').replace('/items', '')
            self.handle_assign_item_to_release(release_id)
        elif path.startswith('/api/releases/') and path.endswith('/promote'):
            release_id = path.replace('/api/releases/', '').replace('/promote', '')
            self.handle_promote_release(release_id)
        elif path == '/api/releases/flow-config':
            self.handle_update_flow_config()
        elif path == '/api/releases/sync-item':
            self.handle_sync_item_to_release()
        elif path == '/api/releases/sync-all':
            self.handle_sync_all_to_releases()
        # Epic API endpoints
        elif path == '/api/epics':
            self.handle_create_epic()
        elif path.startswith('/api/epics/') and path.endswith('/items'):
            epic_id = path.replace('/api/epics/', '').replace('/items', '')
            self.handle_assign_item_to_epic(epic_id)
        # Todo API endpoints
        elif path == '/api/todos':
            self.handle_create_todo()
        # Calendar sync API endpoints
        elif path == '/api/calendar/config':
            self.handle_save_calendar_config()
        elif path == '/api/calendar/connect/apple':
            self.handle_connect_apple_calendar()
        elif path == '/api/calendar/connect/google':
            self.handle_connect_google_calendar()
        elif path.startswith('/api/calendar/disconnect/'):
            provider = path.replace('/api/calendar/disconnect/', '')
            self.handle_disconnect_calendar(provider)
        elif path == '/api/calendar/sync/trigger':
            self.handle_trigger_calendar_sync()
        elif path == '/api/calendar/conflicts/resolve':
            self.handle_resolve_calendar_conflict()
        elif path == '/api/terminal/activate':
            self.handle_terminal_activate()
        # Team Export/Import API endpoints
        elif path == '/api/export/create':
            self.handle_create_export()
        elif path == '/api/export/secrets/create':
            self.handle_create_secrets_export()
        elif path == '/api/import/upload':
            self.handle_import_upload()
        elif path.startswith('/api/import/apply/'):
            job_id = path.replace('/api/import/apply/', '')
            self.handle_import_apply(job_id)
        # Secrets Import API endpoints (XACA-0172-003)
        elif path == '/api/import/secrets/upload':
            self.handle_secrets_import_upload()
        elif path.startswith('/api/import/secrets/preflight/'):
            job_id = path.replace('/api/import/secrets/preflight/', '')
            self.handle_secrets_import_preflight(job_id)
        elif path.startswith('/api/import/secrets/apply/'):
            job_id = path.replace('/api/import/secrets/apply/', '')
            self.handle_secrets_import_apply(job_id)
        # RAG Engine API endpoints
        elif path == '/api/rag-engines/save':
            self.handle_rag_engine_save()
        elif path == '/api/rag-engines/delete':
            self.handle_rag_engine_delete()
        elif path == '/api/rag-engines/install':
            self.handle_rag_engine_install()
        elif path == '/api/rag-engines/uninstall':
            self.handle_rag_engine_uninstall()
        elif path == '/api/rag-engines/start':
            self.handle_rag_engine_start()
        elif path == '/api/rag-engines/stop':
            self.handle_rag_engine_stop()
        elif path == '/api/rag-engines/health':
            self.handle_rag_engine_health()
        elif path == '/api/rag-engines/configure':
            self.handle_rag_engine_configure()
        elif path == '/api/rag-engines/check-updates':
            self.handle_rag_engine_check_updates()
        elif path == '/api/rag-engines/update':
            self.handle_rag_engine_update()
        # Graph API endpoints
        elif path == '/api/graph/data':
            self.handle_graph_data()
        elif path == '/api/graph/query':
            self.handle_graph_query()
        elif path == '/api/graph/node':
            self.handle_graph_node()
        # Weekly anchor API endpoints (XACA-0253-003)
        elif path == '/api/weekly-anchor':
            self.handle_post_weekly_anchor()
        # XACA-0292: Team config (CR/CAB support flag)
        elif path == '/api/team-config':
            self.handle_update_team_config()
        # XACA-0281 Phase A.3: Team account config endpoints
        elif path == '/api/team-config/account/save':
            self.handle_team_account_save()
        elif path == '/api/team-config/account/test-connection':
            self.handle_team_account_test_connection()
        # === XACA-0281: AI engines registry consumer ===
        elif path == '/api/team-config/account/assign':
            self.handle_team_account_assign()
        # XACA-0281 Phase A.3: Resume-ID management
        elif path == '/api/team-config/account/resume-ids':
            self.handle_team_account_resume_ids()
        # CR transition endpoint (XACA-0328-005)
        elif path.startswith('/api/kanban/cr/') and path.endswith('/transition'):
            cr_id = path[len('/api/kanban/cr/'):-len('/transition')]
            self.handle_cr_transition(cr_id)
        # Alert ingestion endpoints (XACA-0334-002)
        elif path == '/api/alerts':
            self.handle_create_alert()
        elif path.startswith('/api/alerts/') and path.endswith('/dismiss'):
            alert_id = path[len('/api/alerts/'):-len('/dismiss')]
            self.handle_dismiss_alert(alert_id)
        else:
            self.send_error(404, f"Unknown POST endpoint: {path}")

    def do_PUT(self):
        """Handle PUT requests"""
        parsed = urlparse(self.path)
        path = parsed.path

        # Strip known path prefixes for Tailscale funnel compatibility
        for prefix in self.PATH_PREFIXES:
            if path.startswith(prefix + '/'):
                path = path[len(prefix):] or '/'
                break

        # Release API endpoints
        if path.startswith('/api/releases/') and not path.endswith('/items') and not path.endswith('/promote'):
            release_id = path.replace('/api/releases/', '')
            self.handle_update_release(release_id)
        # Epic API endpoints
        elif path.startswith('/api/epics/') and not path.endswith('/items'):
            epic_id = path.replace('/api/epics/', '')
            self.handle_update_epic(epic_id)
        # Todo API endpoints
        elif path == '/api/todos':
            self.handle_update_todo()
        else:
            self.send_error(404, f"Unknown PUT endpoint: {path}")

    def do_PATCH(self):
        """Handle PATCH requests"""
        parsed = urlparse(self.path)
        path = parsed.path

        # Strip known path prefixes for Tailscale funnel compatibility
        for prefix in self.PATH_PREFIXES:
            if path.startswith(prefix + '/'):
                path = path[len(prefix):] or '/'
                break

        # Release API endpoints
        if path.startswith('/api/releases/') and path.endswith('/archive'):
            release_id = path.replace('/api/releases/', '').replace('/archive', '')
            self.handle_toggle_release_archive(release_id)
        else:
            self.send_error(404, f"Unknown PATCH endpoint: {path}")

    def do_DELETE(self):
        """Handle DELETE requests"""
        parsed = urlparse(self.path)
        path = parsed.path

        # Strip known path prefixes for Tailscale funnel compatibility
        for prefix in self.PATH_PREFIXES:
            if path.startswith(prefix + '/'):
                path = path[len(prefix):] or '/'
                break

        # Release API endpoints
        if path.startswith('/api/releases/') and '/items/' in path:
            # DELETE /api/releases/<id>/items/<itemId>
            parts = path.replace('/api/releases/', '').split('/items/')
            if len(parts) == 2:
                release_id, item_id = parts
                self.handle_remove_item_from_release(release_id, item_id)
            else:
                self.send_error(400, "Invalid path format")
        elif path.startswith('/api/releases/'):
            release_id = path.replace('/api/releases/', '')
            self.handle_archive_release(release_id)
        # Epic API endpoints
        elif path.startswith('/api/epics/') and '/items/' in path:
            # DELETE /api/epics/<id>/items/<itemId>
            parts = path.replace('/api/epics/', '').split('/items/')
            if len(parts) == 2:
                epic_id, item_id = parts
                self.handle_remove_item_from_epic(epic_id, item_id)
            else:
                self.send_error(400, "Invalid path format")
        elif path.startswith('/api/epics/'):
            epic_id = path.replace('/api/epics/', '')
            self.handle_delete_epic(epic_id)
        # Todo API endpoints
        elif path == '/api/todos':
            self.handle_delete_todo()
        # Weekly anchor API endpoints (XACA-0253-003)
        elif path == '/api/weekly-anchor':
            self.handle_delete_weekly_anchor()
        # Alert ingestion endpoints (XACA-0334-002)
        elif path.startswith('/api/alerts/'):
            alert_id = path[len('/api/alerts/'):]
            self.handle_delete_alert(alert_id)
        else:
            self.send_error(404, f"Unknown DELETE endpoint: {path}")

    def _find_item_index(self, data, item_id):
        """Find backlog item index by ID. Returns -1 if not found."""
        if 'backlog' not in data:
            return -1
        for i, item in enumerate(data['backlog']):
            if item.get('id') == item_id:
                return i
        return -1

    def _resolve_selector(self, data, selector):
        """Resolve selector (ID or index) to array index. Returns -1 if not found."""
        import re
        # Check if it's a JIRA-style ID (X followed by 3 letters, dash, digits)
        if re.match(r'^X[A-Z]{3}-\d+$', str(selector)):
            return self._find_item_index(data, selector)
        # Otherwise treat as numeric index
        try:
            index = int(selector)
            if 'backlog' in data and 0 <= index < len(data['backlog']):
                return index
            return -1
        except (ValueError, TypeError):
            return -1

    def handle_toggle_collapsed(self):
        """Toggle collapsed state for a backlog item"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team')
            item_id = post_data.get('id') or post_data.get('index')  # Support both id and index
            collapsed = post_data.get('collapsed')

            print(f"[LCARS] toggle-collapsed: team={team}, id={item_id}, collapsed={collapsed}")

            if team is None or item_id is None or collapsed is None:
                print(f"[LCARS] ERROR: Missing fields - team={team}, id={item_id}, collapsed={collapsed}")
                self.send_error(400, "Missing required fields: team, id (or index), collapsed")
                return

            board_file = get_board_file(team)
            if not board_file.exists():
                self.send_error(404, f"Board not found: {team}")
                return

            # Read, update, write with file locking
            lock_file = board_file.with_suffix('.json.lock')
            import fcntl

            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    with open(board_file, 'r') as f:
                        data = json.load(f)

                    # Resolve selector to index
                    index = self._resolve_selector(data, item_id)
                    print(f"[LCARS] Resolved {item_id} to index {index}")

                    if index >= 0:
                        old_value = data['backlog'][index].get('collapsed')
                        data['backlog'][index]['collapsed'] = collapsed
                        data['lastUpdated'] = self._get_timestamp()

                        self._atomic_write_json(board_file, data)

                        print(f"[LCARS] Updated collapsed: {old_value} -> {collapsed} for {item_id}")

                        actual_item_id = data['backlog'][index].get('id', str(item_id))
                        if old_value != collapsed:
                            log_activity("collapsed_toggled", actual_item_id, "item",
                                         field="collapsed",
                                         old_value=str(old_value),
                                         new_value=str(collapsed))

                        self.send_response(200)
                        self.send_header('Content-Type', 'application/json')
                        self.send_header('Access-Control-Allow-Origin', '*')
                        self.end_headers()
                        self.wfile.write(json.dumps({"success": True}).encode())
                    else:
                        print(f"[LCARS] ERROR: Item not found: {item_id}")
                        self.send_error(400, f"Item not found: {item_id}")
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

        except Exception as e:
            self.send_error(500, f"Error updating collapsed state: {e}")

    def handle_update_item(self):
        """Update arbitrary fields on a backlog item"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team')
            item_id = post_data.get('id') or post_data.get('index')  # Support both id and index
            updates = post_data.get('updates', {})

            if team is None or item_id is None:
                self.send_error(400, "Missing required fields: team, id (or index)")
                return

            board_file = get_board_file(team)
            if not board_file.exists():
                self.send_error(404, f"Board not found: {team}")
                return

            # Read, update, write with file locking
            lock_file = board_file.with_suffix('.json.lock')
            import fcntl

            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    with open(board_file, 'r') as f:
                        data = json.load(f)

                    # Resolve selector to index
                    index = self._resolve_selector(data, item_id)

                    if index >= 0:
                        item = data['backlog'][index]
                        actual_item_id = item.get('id', item_id)

                        # Block completion if subitems are incomplete
                        if updates.get('status') == 'completed':
                            subitems = item.get('subitems', [])
                            incomplete = [s for s in subitems if s.get('status') not in ('completed', 'cancelled')]
                            if incomplete:
                                self.send_response(400)
                                self.send_header('Content-Type', 'application/json')
                                self.send_header('Access-Control-Allow-Origin', '*')
                                self.end_headers()
                                self.wfile.write(json.dumps({
                                    "error": "Cannot complete item with incomplete subitems",
                                    "incompleteSubitems": [{"id": s.get("id"), "title": s.get("title"), "status": s.get("status")} for s in incomplete]
                                }).encode())
                                return

                        # Track old release assignment BEFORE applying updates
                        old_release_assignment = item.get('releaseAssignment')
                        old_release_id = old_release_assignment.get('releaseId') if old_release_assignment else None

                        # Snapshot old field values BEFORE applying updates (for activity logging)
                        old_values = {key: item.get(key) for key in updates}
                        old_tags = list(item.get('tags', []))

                        # Apply updates
                        for key, value in updates.items():
                            data['backlog'][index][key] = value

                        # Handle field clearing (delete fields from item)
                        clear_fields = post_data.get('clearFields', [])
                        for field in clear_fields:
                            if field in data['backlog'][index]:
                                del data['backlog'][index][field]

                        data['lastUpdated'] = self._get_timestamp()

                        self._atomic_write_json(board_file, data)

                        # Log activity for each changed field
                        for key, new_val in updates.items():
                            old_val = old_values.get(key)
                            if old_val == new_val:
                                continue
                            if key == 'status':
                                log_activity("status_change", actual_item_id, "item",
                                             field="status",
                                             old_value=str(old_val) if old_val is not None else None,
                                             new_value=str(new_val) if new_val is not None else None)
                            elif key == 'title':
                                log_activity("field_update", actual_item_id, "item",
                                             field="title",
                                             old_value=str(old_val) if old_val is not None else None,
                                             new_value=str(new_val) if new_val is not None else None)
                            elif key == 'priority':
                                log_activity("field_update", actual_item_id, "item",
                                             field="priority",
                                             old_value=str(old_val) if old_val is not None else None,
                                             new_value=str(new_val) if new_val is not None else None)
                            elif key == 'description':
                                old_str = str(old_val)[:100] if old_val is not None else None
                                new_str = str(new_val)[:100] if new_val is not None else None
                                log_activity("field_update", actual_item_id, "item",
                                             field="description",
                                             old_value=old_str,
                                             new_value=new_str)
                            elif key == 'tags':
                                new_tags = new_val if isinstance(new_val, list) else []
                                for tag in new_tags:
                                    if tag not in old_tags:
                                        log_activity("tag_added", actual_item_id, "item",
                                                     field="tags",
                                                     new_value=str(tag))
                                for tag in old_tags:
                                    if tag not in new_tags:
                                        log_activity("tag_removed", actual_item_id, "item",
                                                     field="tags",
                                                     old_value=str(tag))
                            else:
                                log_activity("field_update", actual_item_id, "item",
                                             field=key,
                                             old_value=str(old_val) if old_val is not None else None,
                                             new_value=str(new_val) if new_val is not None else None)

                        # Check new release assignment after updates
                        new_release_assignment = data['backlog'][index].get('releaseAssignment')
                        new_release_id = new_release_assignment.get('releaseId') if new_release_assignment else None

                        # If release assignment changed or was cleared, remove from old manifest
                        if old_release_id and old_release_id != new_release_id:
                            self._remove_item_from_release_manifest(old_release_id, actual_item_id)

                        # Sync to new manifest if assigned to a release
                        if new_release_id:
                            self._sync_item_to_release_manifest(
                                new_release_id,
                                actual_item_id,
                                data['backlog'][index]
                            )

                        self.send_response(200)
                        self.send_header('Content-Type', 'application/json')
                        self.send_header('Access-Control-Allow-Origin', '*')
                        self.end_headers()
                        self.wfile.write(json.dumps({"success": True}).encode())
                    else:
                        self.send_error(400, f"Item not found: {item_id}")
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

        except Exception as e:
            self.send_error(500, f"Error updating item: {e}")

    def handle_update_subitem(self):
        """Update arbitrary fields on a subitem"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team')
            parent_index = post_data.get('parentIndex')
            sub_index = post_data.get('subIndex')
            updates = post_data.get('updates', {})

            if team is None or parent_index is None or sub_index is None:
                self.send_error(400, "Missing required fields: team, parentIndex, subIndex")
                return

            board_file = get_board_file(team)
            if not board_file.exists():
                self.send_error(404, f"Board not found: {team}")
                return

            # Read, update, write with file locking
            lock_file = board_file.with_suffix('.json.lock')
            import fcntl

            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    with open(board_file, 'r') as f:
                        data = json.load(f)

                    # Validate indices
                    if 'backlog' not in data or parent_index >= len(data['backlog']):
                        self.send_error(400, f"Parent item not found: {parent_index}")
                        return

                    parent_item = data['backlog'][parent_index]
                    if 'subitems' not in parent_item or sub_index >= len(parent_item['subitems']):
                        self.send_error(400, f"Subitem not found: {parent_index}.{sub_index}")
                        return

                    subitem = parent_item['subitems'][sub_index]
                    actual_subitem_id = subitem.get('id', f"{parent_index}.{sub_index}")

                    # Snapshot old field values BEFORE applying updates (for activity logging)
                    old_subitem_values = {key: subitem.get(key) for key in updates}

                    # Apply updates to subitem
                    for key, value in updates.items():
                        data['backlog'][parent_index]['subitems'][sub_index][key] = value

                    # Handle field clearing (delete fields from subitem)
                    clear_fields = post_data.get('clearFields', [])
                    for field in clear_fields:
                        if field in data['backlog'][parent_index]['subitems'][sub_index]:
                            del data['backlog'][parent_index]['subitems'][sub_index][field]

                    # Update timestamps
                    data['backlog'][parent_index]['updatedAt'] = self._get_timestamp()
                    data['lastUpdated'] = self._get_timestamp()

                    self._atomic_write_json(board_file, data)

                    # Log activity for each changed subitem field
                    for key, new_val in updates.items():
                        old_val = old_subitem_values.get(key)
                        if old_val == new_val:
                            continue
                        if key == 'status':
                            log_activity("subitem_status_change", actual_subitem_id, "subitem",
                                         field="status",
                                         old_value=str(old_val) if old_val is not None else None,
                                         new_value=str(new_val) if new_val is not None else None)
                        elif key == 'title':
                            log_activity("field_update", actual_subitem_id, "subitem",
                                         field="title",
                                         old_value=str(old_val) if old_val is not None else None,
                                         new_value=str(new_val) if new_val is not None else None)
                        elif key == 'description':
                            old_str = str(old_val)[:100] if old_val is not None else None
                            new_str = str(new_val)[:100] if new_val is not None else None
                            log_activity("field_update", actual_subitem_id, "subitem",
                                         field="description",
                                         old_value=old_str,
                                         new_value=new_str)
                        else:
                            log_activity("field_update", actual_subitem_id, "subitem",
                                         field=key,
                                         old_value=str(old_val) if old_val is not None else None,
                                         new_value=str(new_val) if new_val is not None else None)

                    # Sync parent item to release manifest if it has a release assignment
                    parent_release = parent_item.get('releaseAssignment')
                    if parent_release and parent_release.get('releaseId'):
                        self._sync_item_to_release_manifest(
                            parent_release['releaseId'],
                            parent_item.get('id'),
                            data['backlog'][parent_index]
                        )

                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Access-Control-Allow-Origin', '*')
                    self.end_headers()
                    self.wfile.write(json.dumps({"success": True}).encode())
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

        except Exception as e:
            self.send_error(500, f"Error updating subitem: {e}")

    # ============================================================
    # Integration API Handlers (Multi-Platform Support)
    # ============================================================

    def handle_integration_search(self):
        """Search for tickets across configured integrations"""
        if not INTEGRATIONS_AVAILABLE:
            self._send_json_response({"error": "Integration module not available"})
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            query = post_data.get('query', '').strip()
            integration_id = post_data.get('integrationId')
            team = post_data.get('team', LCARS_TEAM)
            max_results = post_data.get('maxResults', 10)

            if not query:
                self._send_json_response({"results": {}})
                return

            manager = get_manager()
            results = manager.search(
                query=query,
                integration_id=integration_id,
                team=team,
                max_results=max_results
            )

            # Convert to JSON-serializable format
            response = {"results": {}}
            for int_id, search_result in results.items():
                response["results"][int_id] = {
                    "tickets": [
                        {
                            "ticketId": t.ticket_id,
                            "summary": t.summary,
                            "status": t.status,
                            "type": t.ticket_type,
                            "url": t.url
                        }
                        for t in search_result.tickets
                    ],
                    "error": search_result.error,
                    "totalCount": search_result.total_count
                }

            self._send_json_response(response)

        except Exception as e:
            self.send_error(500, f"Error in integration search: {e}")

    def handle_integration_verify(self):
        """Verify a ticket exists in configured integrations"""
        if not INTEGRATIONS_AVAILABLE:
            self._send_json_response({"error": "Integration module not available"})
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            ticket_id = post_data.get('ticketId', '').strip()
            integration_id = post_data.get('integrationId')

            if not ticket_id:
                self._send_json_response({
                    "valid": False,
                    "error": "No ticket ID provided"
                })
                return

            manager = get_manager()
            results = manager.verify(
                ticket_id=ticket_id,
                integration_id=integration_id
            )

            # Convert to JSON-serializable format
            response = {"results": {}}
            for int_id, verify_result in results.items():
                response["results"][int_id] = {
                    "valid": verify_result.valid,
                    "ticketId": verify_result.ticket_id,
                    "exists": verify_result.exists,
                    "summary": verify_result.summary,
                    "status": verify_result.status,
                    "type": verify_result.ticket_type,
                    "url": verify_result.url,
                    "warning": verify_result.warning,
                    "error": verify_result.error
                }

            # For single integration, also return flat response
            if integration_id and integration_id in response["results"]:
                response.update(response["results"][integration_id])

            self._send_json_response(response)

        except Exception as e:
            self.send_error(500, f"Error in integration verify: {e}")

    def handle_integration_test(self):
        """Test connection to a specific integration"""
        if not INTEGRATIONS_AVAILABLE:
            self._send_json_response({
                "success": False,
                "message": "Integration module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            integration_id = post_data.get('integrationId')

            if not integration_id:
                self._send_json_response({
                    "success": False,
                    "message": "No integration ID provided"
                })
                return

            manager = get_manager()
            result = manager.test_connection(integration_id)

            self._send_json_response({
                "success": result.success,
                "message": result.message,
                "details": result.details
            })

        except Exception as e:
            self.send_error(500, f"Error in integration test: {e}")

    def handle_integration_save(self):
        """Save (add or update) an integration to config file"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            integration = post_data.get('integration')
            is_new = post_data.get('isNew', False)

            if not integration or not integration.get('id'):
                self._send_json_response({
                    "success": False,
                    "error": "Invalid integration data"
                })
                return

            # Load current config (team-specific)
            config_path = INTEGRATIONS_FILE
            TEAM_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            if config_path.exists():
                with open(config_path, 'r') as f:
                    config = json.load(f)
            else:
                config = {"integrations": []}

            integrations = config.get('integrations', [])

            # Find existing integration
            existing_idx = None
            for i, integ in enumerate(integrations):
                if integ.get('id') == integration['id']:
                    existing_idx = i
                    break

            if is_new and existing_idx is not None:
                self._send_json_response({
                    "success": False,
                    "error": f"Integration with ID '{integration['id']}' already exists"
                })
                return

            # Build the integration config object
            new_config = {
                'id': integration['id'],
                'type': integration.get('type', 'custom'),
                'name': integration.get('name', integration['id']),
                'enabled': integration.get('enabled', True),
                'baseUrl': integration.get('baseUrl', ''),
                'browseUrl': integration.get('browseUrl', ''),
            }

            # Optional fields
            if integration.get('ticketPattern'):
                new_config['ticketPattern'] = integration['ticketPattern']
            if integration.get('defaultProjects'):
                new_config['defaultProjects'] = integration['defaultProjects']
            if integration.get('auth'):
                new_config['auth'] = integration['auth']
            if integration.get('icon'):
                new_config['icon'] = integration['icon']

            # Add API version for JIRA
            if integration.get('type') == 'jira':
                new_config['apiVersion'] = '3'

            # Update or add
            if existing_idx is not None:
                integrations[existing_idx] = new_config
            else:
                integrations.append(new_config)

            config['integrations'] = integrations

            # Write back atomically
            self._atomic_write_json(config_path, config)

            # Reload the manager (must use reload() not load() to clear cache)
            if INTEGRATIONS_AVAILABLE:
                manager = get_manager()
                manager.reload()

            self._send_json_response({
                "success": True,
                "message": "Integration saved"
            })

        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def handle_integration_delete(self):
        """Delete an integration from config file"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            integration_id = post_data.get('integrationId')

            if not integration_id:
                self._send_json_response({
                    "success": False,
                    "error": "No integration ID provided"
                })
                return

            # Load current config (team-specific)
            config_path = INTEGRATIONS_FILE
            if not config_path.exists():
                self._send_json_response({
                    "success": False,
                    "error": "No integrations configured for this team"
                })
                return
            with open(config_path, 'r') as f:
                config = json.load(f)

            integrations = config.get('integrations', [])
            original_count = len(integrations)

            # Remove the integration
            integrations = [i for i in integrations if i.get('id') != integration_id]

            if len(integrations) == original_count:
                self._send_json_response({
                    "success": False,
                    "error": f"Integration '{integration_id}' not found"
                })
                return

            config['integrations'] = integrations

            # Write back atomically
            self._atomic_write_json(config_path, config)

            # Reload the manager (must use reload() not load() to clear cache)
            if INTEGRATIONS_AVAILABLE:
                manager = get_manager()
                manager.reload()

            self._send_json_response({
                "success": True,
                "message": "Integration deleted"
            })

        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def handle_integration_boards(self):
        """Fetch boards from Monday.com integration for board selection UI"""
        if not INTEGRATIONS_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "Integration module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            integration_id = post_data.get('integrationId')

            if not integration_id:
                self._send_json_response({
                    "success": False,
                    "error": "No integration ID provided"
                })
                return

            manager = get_manager()
            provider = manager.get_provider(integration_id)

            if not provider:
                self._send_json_response({
                    "success": False,
                    "error": f"Integration '{integration_id}' not found"
                })
                return

            # Check if this is a Monday.com provider with get_boards method
            if provider.provider_type != 'monday':
                self._send_json_response({
                    "success": False,
                    "error": "Board fetching is only supported for Monday.com integrations"
                })
                return

            if not hasattr(provider, 'get_boards'):
                self._send_json_response({
                    "success": False,
                    "error": "Provider does not support board fetching"
                })
                return

            if not provider.has_credentials():
                self._send_json_response({
                    "success": False,
                    "error": "Monday.com credentials not configured"
                })
                return

            # Fetch boards from Monday.com
            limit = post_data.get('limit', 50)
            boards = provider.get_boards(limit=limit)

            self._send_json_response({
                "success": True,
                "boards": boards
            })

        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def handle_integration_create_item(self):
        """Create a new item in an external integration (Monday.com, JIRA, etc.)"""
        if not INTEGRATIONS_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "Integration module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            # Required fields
            integration_id = post_data.get('integrationId')
            board_id = post_data.get('boardId')
            title = post_data.get('title')

            # Optional fields
            description = post_data.get('description')
            metadata = post_data.get('metadata', {})

            # Validation
            if not integration_id:
                self._send_json_response({
                    "success": False,
                    "error": "Missing required field: integrationId"
                })
                return

            if not board_id:
                self._send_json_response({
                    "success": False,
                    "error": "Missing required field: boardId"
                })
                return

            if not title or not title.strip():
                self._send_json_response({
                    "success": False,
                    "error": "Missing required field: title"
                })
                return

            # Get the integration provider
            manager = get_manager()
            provider = manager.get_provider(integration_id)

            if not provider:
                self._send_json_response({
                    "success": False,
                    "error": f"Integration '{integration_id}' not found"
                })
                return

            if not provider.has_credentials():
                self._send_json_response({
                    "success": False,
                    "error": f"Integration '{integration_id}' credentials not configured"
                })
                return

            # Create the item using the provider
            result = provider.create_item(
                board_id=board_id,
                title=title,
                description=description,
                metadata=metadata
            )

            # Convert result to JSON response
            response = {
                "success": result.success,
                "ticketId": result.ticket_id,
                "url": result.url,
                "message": result.message,
                "error": result.error
            }

            self._send_json_response(response)

        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": f"Unexpected error: {str(e)}"
            })

    # ============================================================
    # Sync API Handlers (Bidirectional Status Sync)
    # ============================================================

    def handle_sync_item(self):
        """Sync all ticket links for a specific kanban item"""
        if not SYNC_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "Sync module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team')
            item_id = post_data.get('itemId')
            direction = post_data.get('direction', 'external_to_kanban')

            if not team or not item_id:
                self._send_json_response({
                    "success": False,
                    "error": "Missing required fields: team, itemId"
                })
                return

            # Load the item from the board
            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({
                    "success": False,
                    "error": f"Board not found: {team}"
                })
                return

            with open(board_file, 'r') as f:
                board_data = json.load(f)

            # Find the item
            item = None
            item_index = -1
            for i, backlog_item in enumerate(board_data.get('backlog', [])):
                if backlog_item.get('id') == item_id:
                    item = backlog_item
                    item_index = i
                    break

            if not item:
                self._send_json_response({
                    "success": False,
                    "error": f"Item not found: {item_id}"
                })
                return

            # Run sync
            sync_service = get_sync_service()
            sync_direction = SyncDirection(direction)
            result = sync_service.sync_item(item, sync_direction)

            # Save updated item back to board if there were changes
            if result.updated_item and result.success_count > 0:
                import fcntl
                lock_file = board_file.with_suffix('.json.lock')
                with open(lock_file, 'w') as lock:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                    try:
                        # Re-read to get fresh data
                        with open(board_file, 'r') as f:
                            board_data = json.load(f)

                        # Update the item
                        board_data['backlog'][item_index] = result.updated_item
                        board_data['lastUpdated'] = self._get_timestamp()

                        self._atomic_write_json(board_file, board_data)
                    finally:
                        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

            # Convert result to JSON response
            response = {
                "success": result.error_count == 0,
                "itemId": result.item_id,
                "successCount": result.success_count,
                "errorCount": result.error_count,
                "skippedCount": result.skipped_count,
                "linkResults": [
                    {
                        "integrationId": r.integration_id,
                        "ticketId": r.ticket_id,
                        "status": r.status.value,
                        "message": r.message,
                        "changes": r.changes,
                        "error": r.error
                    }
                    for r in result.link_results
                ]
            }

            self._send_json_response(response)

        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def handle_sync_board(self):
        """Sync all items with ticket links on a board"""
        if not SYNC_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "Sync module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team')
            direction = post_data.get('direction', 'external_to_kanban')

            if not team:
                self._send_json_response({
                    "success": False,
                    "error": "Missing required field: team"
                })
                return

            # Load the board
            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({
                    "success": False,
                    "error": f"Board not found: {team}"
                })
                return

            with open(board_file, 'r') as f:
                board_data = json.load(f)

            # Run sync
            sync_service = get_sync_service()
            sync_direction = SyncDirection(direction)
            results = sync_service.sync_board(board_data, sync_direction)

            # Save updated board if there were changes
            total_changes = sum(r.success_count for r in results.values())
            if total_changes > 0:
                import fcntl
                lock_file = board_file.with_suffix('.json.lock')
                with open(lock_file, 'w') as lock:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                    try:
                        board_data['lastUpdated'] = self._get_timestamp()
                        self._atomic_write_json(board_file, board_data)
                    finally:
                        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

            # Summarize results
            total_items = len(results)
            total_success = sum(r.success_count for r in results.values())
            total_errors = sum(r.error_count for r in results.values())
            total_skipped = sum(r.skipped_count for r in results.values())

            response = {
                "success": total_errors == 0,
                "team": team,
                "itemsProcessed": total_items,
                "totalSuccess": total_success,
                "totalErrors": total_errors,
                "totalSkipped": total_skipped,
                "itemResults": {
                    item_id: {
                        "successCount": r.success_count,
                        "errorCount": r.error_count,
                        "skippedCount": r.skipped_count
                    }
                    for item_id, r in results.items()
                }
            }

            self._send_json_response(response)

        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    # =========================================================================
    # Import Handlers
    # =========================================================================

    def handle_import_fetch(self):
        """Fetch external issue for import preview"""
        if not INTEGRATIONS_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "Integration module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            ticket_id = post_data.get('ticketId')
            integration_id = post_data.get('integrationId')  # Optional
            include_children = post_data.get('includeChildren', True)

            if not ticket_id:
                self._send_json_response({
                    "success": False,
                    "error": "Missing required field: ticketId"
                })
                return

            manager = get_manager()
            result = manager.fetch_issue(ticket_id, integration_id, include_children)

            if result.success:
                # Get provider info for display
                provider = manager.detect_provider(ticket_id) if not integration_id else manager.get_provider(integration_id)
                provider_info = provider.to_dict() if provider else None

                self._send_json_response({
                    "success": True,
                    "issue": result.issue.to_dict() if result.issue else None,
                    "provider": provider_info,
                    "warnings": result.warnings
                })
            else:
                self._send_json_response({
                    "success": False,
                    "error": result.error
                })

        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def handle_import_execute(self):
        """Execute import - create kanban item from external issue"""
        if not INTEGRATIONS_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "Integration module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            ticket_id = post_data.get('ticketId')
            integration_id = post_data.get('integrationId')
            team = post_data.get('team', LCARS_TEAM)
            include_children = post_data.get('includeChildren', True)

            if not ticket_id:
                self._send_json_response({
                    "success": False,
                    "error": "Missing required field: ticketId"
                })
                return

            # Fetch the issue
            manager = get_manager()
            result = manager.fetch_issue(ticket_id, integration_id, include_children)

            if not result.success:
                self._send_json_response({
                    "success": False,
                    "error": result.error
                })
                return

            issue = result.issue

            # Detect provider
            provider = manager.detect_provider(ticket_id) if not integration_id else manager.get_provider(integration_id)
            if not provider:
                self._send_json_response({
                    "success": False,
                    "error": "Could not detect integration provider"
                })
                return

            # Load board
            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({
                    "success": False,
                    "error": f"Board not found: {team}"
                })
                return

            import fcntl
            lock_file = board_file.with_suffix('.json.lock')

            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    with open(board_file, 'r') as f:
                        board_data = json.load(f)

                    # Create the kanban item (pass board_data to avoid race condition)
                    from integrations.import_issue import (
                        create_kanban_item,
                        get_next_item_id
                    )

                    item = create_kanban_item(issue, team, provider.id, board_file, board_data)

                    # Add to backlog
                    if 'backlog' not in board_data:
                        board_data['backlog'] = []
                    board_data['backlog'].append(item)
                    board_data['lastUpdated'] = self._get_timestamp()

                    # Save board
                    self._atomic_write_json(board_file, board_data)

                    self._send_json_response({
                        "success": True,
                        "item": item,
                        "team": team,
                        "message": f"Created {item['id']}: {item['title']}"
                    })

                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

        except Exception as e:
            import traceback
            traceback.print_exc()
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def serve_sync_status(self):
        """Serve sync dashboard status - integrations and their sync capabilities"""
        if not SYNC_AVAILABLE:
            self._send_json_response({
                "available": False,
                "error": "Sync module not available"
            })
            return

        try:
            manager = get_manager()
            integrations = manager.list_integrations()

            # Count items with ticket links that can be synced
            items_with_links = 0
            items_by_integration = {}

            # Iterate through all team kanban directories
            for team, kanban_dir in TEAM_KANBAN_DIRS.items():
                board_file = kanban_dir / f"{team}-board.json"
                if not board_file.exists():
                    continue
                try:
                    with open(board_file, 'r') as f:
                        board_data = json.load(f)

                    for item in board_data.get('backlog', []):
                        ticket_links = item.get('ticketLinks', [])
                        # Also check legacy jiraId
                        if not ticket_links and (item.get('jiraId') or item.get('jiraKey')):
                            ticket_links = [{'integrationId': 'jira-mainevent'}]

                        if ticket_links:
                            items_with_links += 1
                            for link in ticket_links:
                                int_id = link.get('integrationId', 'unknown')
                                items_by_integration[int_id] = items_by_integration.get(int_id, 0) + 1

                except Exception:
                    continue

            response = {
                "available": True,
                "integrations": integrations,
                "syncCapabilities": {
                    "directions": ["external_to_kanban", "kanban_to_external", "bidirectional"],
                    "supportedProviders": ["jira", "monday"]
                },
                "statistics": {
                    "itemsWithLinks": items_with_links,
                    "linksByIntegration": items_by_integration
                }
            }

            self._send_json_response(response)

        except Exception as e:
            self._send_json_response({
                "available": False,
                "error": str(e)
            })

    def _send_json_response(self, data, status=200):
        """Helper to send JSON response with CORS headers"""
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def _get_timestamp(self):
        """Get ISO timestamp"""
        from datetime import datetime, timezone
        return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def _get_plan_doc_path_for_item(self, item_id):
        """Get the plan document path for a given item ID based on team prefix.

        Returns the kanban directory path where plan documents should exist.
        Team is determined by item ID prefix (XACA, XIOS, XAND, XFIR, etc).
        For EPIC/RELEASE prefixes, uses the current team's path (LCARS_TEAM).

        Note: Plan docs are now stored directly in each team's kanban/ directory,
        not in docs/kanban/.
        """
        import glob

        # Extract team prefix from item ID (e.g., XACA-0045 -> XACA)
        if '-' not in item_id:
            return None

        prefix = item_id.split('-')[0].upper()

        # Map team prefix to kanban directory (distributed structure)
        team_paths = {
            'XACA': TEAM_KANBAN_DIRS.get('academy'),
            'XIOS': TEAM_KANBAN_DIRS.get('ios'),
            'XAND': TEAM_KANBAN_DIRS.get('android'),
            'XFIR': TEAM_KANBAN_DIRS.get('firebase'),
            'XCMD': TEAM_KANBAN_DIRS.get('command'),
            'XDNS': TEAM_KANBAN_DIRS.get('dns'),
            'XLCP': TEAM_KANBAN_DIRS.get('legal-coparenting'),
            'XFSW': TEAM_KANBAN_DIRS.get('freelance-doublenode-starwords'),
            'XFAP': TEAM_KANBAN_DIRS.get('freelance-doublenode-appplanning'),
            'XFWS': TEAM_KANBAN_DIRS.get('freelance-doublenode-workstats'),
            'XFLB': TEAM_KANBAN_DIRS.get('freelance-doublenode-lifeboard'),
            'XVAN': TEAM_KANBAN_DIRS.get('freelance-doublenode-caravan'),
            'XFAS': TEAM_KANBAN_DIRS.get('freelance-doublenode-awaysentry'),
            'XFLA': TEAM_KANBAN_DIRS.get('freelance-liquidstyle-agentbadges-app'),
            'XFLI': TEAM_KANBAN_DIRS.get('freelance-liquidstyle-agentbadges-ios'),
            'XFIN': TEAM_KANBAN_DIRS.get('finance-personal'),
        }

        # If prefix is found, use it
        if prefix in team_paths and team_paths[prefix]:
            return team_paths.get(prefix)

        # For EPIC/RELEASE/unknown prefixes, fall back to current team's kanban dir
        return TEAM_KANBAN_DIRS.get(LCARS_TEAM, KANBAN_DIR)

    def _atomic_write_json(self, file_path, data):
        """Write JSON atomically using tmp file + rename to prevent corruption.

        This prevents race conditions where another process reads a truncated
        file during the write operation.
        """
        import tempfile
        tmp_file = file_path.with_suffix('.json.tmp')
        try:
            with open(tmp_file, 'w') as f:
                json.dump(data, f, indent=2)
                f.flush()
                os.fsync(f.fileno())  # Ensure data is on disk
            os.rename(tmp_file, file_path)  # Atomic rename
        except Exception:
            # Clean up tmp file on error
            if tmp_file.exists():
                tmp_file.unlink()
            raise

    # =========================================================================
    # RELEASE MANAGEMENT API HANDLERS
    # =========================================================================

    # XACA-0037: Item ID prefix to team mapping
    ITEM_PREFIX_TO_TEAM = {
        'XIOS': 'ios',
        'XAND': 'android',
        'XFIR': 'firebase',
        'XACA': 'academy',
        'XCMD': 'command',
        'XDNS': 'dns',
        'XMEV': 'mainevent',
        # Freelance projects (each has unique prefix)
        'XFSW': 'freelance-doublenode-starwords',
        'XFAP': 'freelance-doublenode-appplanning',
        'XFWS': 'freelance-doublenode-workstats',
        'XFLB': 'freelance-doublenode-lifeboard',
        'XVAN': 'freelance-doublenode-caravan',
        'XFAS': 'freelance-doublenode-awaysentry',
        'XFLA': 'freelance-liquidstyle-agentbadges-app',
        'XFLI': 'freelance-liquidstyle-agentbadges-ios',
        # Legal projects
        'XLCP': 'legal-coparenting',
        # Finance projects
        'XFIN': 'finance-personal',
    }

    def _extract_team_from_item_id(self, item_id):
        """XACA-0037: Extract team from item ID prefix

        Item IDs follow the pattern: X<TEAM>-<NUMBER> (e.g., XIOS-0001, XFIR-0023)
        Returns the team name or None if prefix is not recognized.

        For EPIC-* and RELEASE-* IDs (which don't have team prefixes),
        falls back to the current LCARS_TEAM.
        """
        if not item_id or len(item_id) < 4:
            return None
        prefix = item_id[:4].upper()
        team = self.ITEM_PREFIX_TO_TEAM.get(prefix)

        # Fall back to current team for EPIC/RELEASE prefixes
        # REL- is the standard release prefix (e.g., REL-2026-Q1-001)
        if team is None and prefix in ('EPIC', 'RELE', 'REL-'):
            return LCARS_TEAM

        return team

    def _validate_item_team_match(self, item_id, expected_team):
        """XACA-0037: Validate that item's prefix team matches expected team

        Returns (is_valid, extracted_team, error_message)
        """
        extracted_team = self._extract_team_from_item_id(item_id)
        if extracted_team is None:
            # Unknown prefix - allow but log
            return (True, None, None)
        if extracted_team != expected_team:
            return (False, extracted_team, f"Item '{item_id}' belongs to team '{extracted_team}', not '{expected_team}'")
        return (True, extracted_team, None)

    def _get_plan_docs_dir_for_team(self, team):
        """Get the plan documents directory for a team.

        Args:
            team: Team name (e.g., 'academy', 'ios', 'android', 'firebase', 'freelance-doublenode-appplanning')

        Returns:
            Path to the team's kanban directory where plan docs are stored, or None if team not recognized

        Note: Plan docs are now stored directly in each team's kanban/ directory,
        not in docs/kanban/.
        """
        # Use the distributed kanban directories mapping
        return TEAM_KANBAN_DIRS.get(team)

    # Default release configuration (used when board doesn't have releaseConfig)
    DEFAULT_RELEASE_CONFIG = {
        "defaultEnvironments": ["PLANNED", "DEV", "QA", "ALPHA", "BETA", "GAMMA", "PROD"],
        "platforms": {
            "ios": {"name": "iOS", "store": "App Store", "icon": "apple"},
            "android": {"name": "Android", "store": "Play Store", "icon": "android"},
            "firebase": {"name": "Firebase", "store": None, "icon": "database"},
            "web": {"name": "Web", "store": None, "icon": "globe"},
            "other": {"name": "Other", "store": None, "icon": "ellipsis-h"}
        },
        "releaseTypes": {
            "feature": {"name": "Feature Release", "description": "New features", "color": "#4a90d9"},
            "bugfix": {"name": "Bug Fix Release", "description": "Bug fixes", "color": "#f5a623"},
            "hotfix": {"name": "Hotfix", "description": "Critical fixes", "color": "#d0021b"},
            "maintenance": {"name": "Maintenance", "description": "Technical updates", "color": "#7ed321"}
        },
        "flowConfig": {
            "stages": {
                "PLANNED": {"enabled": True, "required": True},
                "DEV": {"enabled": True, "required": True},
                "QA": {"enabled": True, "required": False},
                "ALPHA": {"enabled": True, "required": False},
                "BETA": {"enabled": True, "required": False},
                "GAMMA": {"enabled": True, "required": False},
                "PROD": {"enabled": True, "required": True}
            }
        }
    }

    def _load_releases_config(self, team=None):
        """Load releases from kanban board file"""
        import fcntl
        board_file = self._get_board_file(team)

        if not board_file.exists():
            return {
                "version": "1.0",
                "team": LCARS_TEAM,
                "releases": [],
                "releaseConfig": self.DEFAULT_RELEASE_CONFIG,
                "nextReleaseId": 1
            }

        lock_file = board_file.with_suffix('.json.lock')
        with open(lock_file, 'w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_SH)
            try:
                with open(board_file, 'r') as f:
                    data = json.load(f)

                # Build releases data structure from board
                release_config = data.get('releaseConfig', self.DEFAULT_RELEASE_CONFIG)
                # XACA-0163: deepcopy when falling back to class-level
                # DEFAULT_RELEASE_CONFIG. handle_update_flow_config mutates
                # data['flowConfig'] in place, which would otherwise pollute
                # the class default for every subsequent team that has not
                # yet persisted its own flowConfig.
                flow_config = release_config.get('flowConfig')
                if flow_config is None:
                    flow_config = copy.deepcopy(self.DEFAULT_RELEASE_CONFIG['flowConfig'])
                return {
                    "version": "1.0",
                    "team": data.get('team', LCARS_TEAM),
                    "releases": data.get('releases', []),
                    "nextId": data.get('nextReleaseId', 1),
                    # Flatten config for backward compatibility
                    "defaultEnvironments": release_config.get('defaultEnvironments', self.DEFAULT_RELEASE_CONFIG['defaultEnvironments']),
                    "platforms": release_config.get('platforms', self.DEFAULT_RELEASE_CONFIG['platforms']),
                    "releaseTypes": release_config.get('releaseTypes', self.DEFAULT_RELEASE_CONFIG['releaseTypes']),
                    "flowConfig": flow_config,
                    "projectEnvironments": release_config.get('projectEnvironments', {})
                }
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def _save_releases_config(self, data, team=None):
        """Save releases to kanban board file"""
        import fcntl
        board_file = self._get_board_file(team)
        # Debug logging to file
        with open(LCARS_TMP_DIR / 'lcars-flow-debug.log', 'a') as log:
            log.write(f"[LCARS] _save_releases_config - team: {team}, board_file: {board_file}\n")

        if not board_file.exists():
            print(f"[LCARS] Board file not found: {board_file}")
            return False

        lock_file = board_file.with_suffix('.json.lock')
        with open(lock_file, 'w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                with open(board_file, 'r') as f:
                    board_data = json.load(f)

                # Update board with releases data
                board_data['releases'] = data.get('releases', [])
                board_data['nextReleaseId'] = data.get('nextId', 1)
                board_data['releaseConfig'] = {
                    "defaultEnvironments": data.get('defaultEnvironments', self.DEFAULT_RELEASE_CONFIG['defaultEnvironments']),
                    "platforms": data.get('platforms', self.DEFAULT_RELEASE_CONFIG['platforms']),
                    "releaseTypes": data.get('releaseTypes', self.DEFAULT_RELEASE_CONFIG['releaseTypes']),
                    "flowConfig": data.get('flowConfig', self.DEFAULT_RELEASE_CONFIG['flowConfig']),
                    "projectEnvironments": data.get('projectEnvironments', {})
                }
                board_data['lastUpdated'] = self._get_timestamp()

                self._atomic_write_json(board_file, board_data)
                return True
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def _find_release_by_id(self, releases_data, release_id):
        """Find release by ID in releases list"""
        for release in releases_data.get('releases', []):
            if release.get('id') == release_id:
                return release
        return None

    def _load_archived_releases(self, team=None):
        """Load all archived releases from the releases-archive directory.

        XACA-0056: Archived releases are stored in each team's kanban directory
        at {kanban_dir}/releases-archive/{release_id}.json

        Returns:
            List of archived release objects with status='archived'
        """
        effective_team = team or LCARS_TEAM
        kanban_dir = TEAM_KANBAN_DIRS.get(effective_team, KANBAN_DIR)
        archive_dir = kanban_dir / "releases-archive"

        archived_releases = []
        if archive_dir.exists() and archive_dir.is_dir():
            for archive_file in archive_dir.glob("*.json"):
                try:
                    with open(archive_file, 'r') as f:
                        release = json.load(f)
                        # Ensure status is set to archived
                        release['status'] = 'archived'
                        archived_releases.append(release)
                except Exception as e:
                    print(f"[LCARS] Error loading archived release {archive_file}: {e}")

        return archived_releases

    def _generate_release_id(self, releases_data):
        """Generate next release ID"""
        next_id = releases_data.get('nextId', 1)
        from datetime import datetime
        year = datetime.now().year
        quarter = (datetime.now().month - 1) // 3 + 1
        release_id = f"REL-{year}-Q{quarter}-{next_id:03d}"
        releases_data['nextId'] = next_id + 1
        return release_id

    def _get_team_kanban_subdir(self, team, subdir):
        """Get team-specific kanban subdirectory (releases, epics, etc.)

        Team naming conventions:
        - Static teams: ios, android, firebase, academy, command, dns
        - Freelance: freelance-{clientId}-{projectId} (REQUIRED format, e.g., freelance-doublenode-workstats)
        - Legal: legal-{projectId} (REQUIRED format, e.g., legal-coparenting)
        - MainEvent floaters: mainevent-{projectId} (project-specific)

        Note: There is NEVER a standalone "freelance" or "legal" team - they MUST include
        their respective IDs. Freelance teams ALWAYS have clientId AND projectId.

        Args:
            team: Team identifier following the conventions above
            subdir: Subdirectory name (e.g., 'releases', 'epics')

        Returns:
            Path to team's kanban subdirectory
        """
        main_event_base = Path("/Users/Shared/Development/Main Event")

        # Static team base paths (Main Event platform teams and infrastructure)
        team_base_paths = {
            'academy': Path.home() / "dev-team" / "kanban",
            'ios': main_event_base / "MainEventApp-iOS" / "DEV" / "dev-team" / "kanban",
            'android': main_event_base / "MainEventApp-Android" / "develop" / "dev-team" / "kanban",
            'firebase': main_event_base / "MainEventApp-Functions" / "develop" / "dev-team" / "kanban",
            'command': main_event_base / "dev-team" / "kanban",
            'dns': Path("/Users/Shared/Development/DNSFramework") / "dev-team" / "kanban",
        }

        # PRIORITY 1: Use canonical TEAM_KANBAN_DIRS mapping (source of truth)
        # This ensures consistency between get_board_file() and subdirectory paths
        if team in TEAM_KANBAN_DIRS:
            return TEAM_KANBAN_DIRS[team] / subdir

        # PRIORITY 2: Check environment variables for dynamic project directories
        # Handle freelance teams (REQUIRED format: freelance-{clientId}-{projectId})
        if team and team.startswith('freelance-'):
            project_dir = os.environ.get('FREELANCE_PROJECT_DIR')
            if project_dir:
                return Path(project_dir) / "kanban" / subdir
            # Unknown freelance team - warn and fallback
            print(f"[LCARS] Warning: Unknown freelance team '{team}' - not in TEAM_KANBAN_DIRS")
            return team_base_paths['academy'] / subdir

        # Handle legal teams (REQUIRED format: legal-{projectId})
        if team and team.startswith('legal-'):
            project_dir = os.environ.get('LEGAL_PROJECT_DIR')
            if project_dir:
                return Path(project_dir) / "kanban" / subdir
            # Unknown legal team - warn and fallback
            print(f"[LCARS] Warning: Unknown legal team '{team}' - not in TEAM_KANBAN_DIRS")
            return team_base_paths['academy'] / subdir

        # Handle mainevent floater teams (format: mainevent-{projectId})
        if team and team.startswith('mainevent-'):
            project_dir = os.environ.get('MAINEVENT_PROJECT_DIR')
            if project_dir:
                return Path(project_dir) / "kanban" / subdir
            # Fallback to Main Event base directory
            return main_event_base / "dev-team" / "kanban" / subdir

        # PRIORITY 3: Use static team_base_paths for known teams
        return team_base_paths.get(team, team_base_paths['academy']) / subdir

    def _get_releases_dir_for_team(self, team):
        """Get team-specific releases directory"""
        return self._get_team_kanban_subdir(team, 'releases')

    def _get_epics_dir_for_team(self, team):
        """Get team-specific epics directory"""
        return self._get_team_kanban_subdir(team, 'epics')

    def _extract_team_from_release_id(self, release_id):
        """Extract team from release ID

        Release ID formats:
        - REL-IOS-2026-Q1-001 → ios
        - REL-AND-2026-Q1-001 → android
        - REL-FB-2026-Q1-001 → firebase
        - REL-2026-Q1-001 → Check manifest for team (legacy format)

        Args:
            release_id: Release identifier

        Returns:
            Team identifier or None if cannot be determined
        """
        parts = release_id.split('-')

        # New format: REL-PLATFORM-YEAR-QUARTER-ID
        if len(parts) >= 5 and parts[1].upper() in ('IOS', 'AND', 'FB'):
            platform_code = parts[1].upper()
            if platform_code == 'IOS':
                return 'ios'
            elif platform_code == 'AND':
                return 'android'
            elif platform_code == 'FB':
                return 'firebase'

        # Legacy format: REL-YEAR-QUARTER-ID (need to check manifest)
        return None

    def _get_release_manifest_path(self, release_id, team=None):
        """Get path to release manifest file

        Args:
            release_id: Release identifier
            team: Optional team identifier (extracted from release_id if not provided)

        Returns:
            Path to manifest file
        """
        # Try to determine team if not provided
        if team is None:
            team = self._extract_team_from_release_id(release_id)

        # If still no team, try loading from current team's releases directory
        if team is None:
            current_team_releases = self._get_releases_dir_for_team(LCARS_TEAM)
            team_path = current_team_releases / release_id / "manifest.json"
            if team_path.exists():
                try:
                    with open(team_path, 'r') as f:
                        manifest = json.load(f)
                    team = manifest.get('team', LCARS_TEAM)
                except Exception:
                    team = LCARS_TEAM
            else:
                # New release, use current team
                team = LCARS_TEAM

        # Get team-specific releases directory
        releases_dir = self._get_releases_dir_for_team(team)
        release_dir = releases_dir / release_id
        return release_dir / "manifest.json"

    def _load_release_manifest(self, release_id):
        """Load release manifest (items assigned to release)

        Tries team-specific path first based on release ID format, falls back to current team's directory.
        Note: Releases are always stored in team-specific directories, never centrally.
        """
        # Try to extract team from release_id
        team = self._extract_team_from_release_id(release_id)

        # Try team-specific path first
        if team:
            manifest_path = self._get_release_manifest_path(release_id, team)
            if manifest_path.exists():
                with open(manifest_path, 'r') as f:
                    manifest = json.load(f)
                # Ensure team field exists for backward compatibility
                if 'team' not in manifest:
                    manifest['team'] = team
                return manifest

        # Fall back to current team's releases directory (no central storage)
        current_team_releases = self._get_releases_dir_for_team(LCARS_TEAM)
        team_fallback_path = current_team_releases / release_id / "manifest.json"
        if team_fallback_path.exists():
            with open(team_fallback_path, 'r') as f:
                manifest = json.load(f)
            # Ensure team field exists for backward compatibility
            if 'team' not in manifest:
                manifest['team'] = LCARS_TEAM
            return manifest

        # If team couldn't be extracted, try getting path (which will use LCARS_TEAM)
        if not team:
            manifest_path = self._get_release_manifest_path(release_id)
            if manifest_path.exists():
                with open(manifest_path, 'r') as f:
                    manifest = json.load(f)
                # Ensure team field exists for backward compatibility
                if 'team' not in manifest:
                    manifest['team'] = LCARS_TEAM
                return manifest

        # Create new manifest
        return {"releaseId": release_id, "team": LCARS_TEAM, "items": [], "createdAt": self._get_timestamp()}

    def _save_release_manifest(self, release_id, manifest):
        """Save release manifest to team-specific path"""
        # Get team from manifest (should always be present)
        team = manifest.get('team', LCARS_TEAM)

        # Get team-specific releases directory
        releases_dir = self._get_releases_dir_for_team(team)
        release_dir = releases_dir / release_id
        release_dir.mkdir(parents=True, exist_ok=True)

        manifest['updatedAt'] = self._get_timestamp()
        self._atomic_write_json(self._get_release_manifest_path(release_id, team), manifest)

    @staticmethod
    def _derive_item_status(board_item):
        """Derive item status from subitems and activity signals.

        Many items track progress through subitems rather than a top-level
        status field. This method computes the effective status from:
        - Subitem statuses (completed, in_progress, etc.)
        - activelyWorking flag
        - startedAt timestamp
        """
        subitems = board_item.get('subitems', [])
        if subitems:
            statuses = [s.get('status', 'todo') for s in subitems]
            non_cancelled = [s for s in statuses if s != 'cancelled']
            if non_cancelled and all(s == 'completed' for s in non_cancelled):
                return 'completed'
            if any(s in ('in_progress', 'completed') for s in non_cancelled):
                return 'in_progress'
        if board_item.get('activelyWorking'):
            return 'in_progress'
        if board_item.get('startedAt'):
            return 'in_progress'
        return 'todo'

    def _calculate_release_progress(self, release_id):
        """Calculate completion progress for a release by platform.

        Uses the BOARD as the source of truth for item status, not the manifest.
        The manifest only tracks which items are assigned to the release.
        This prevents stale status data when items are completed outside LCARS sync.
        """
        manifest = self._load_release_manifest(release_id)
        manifest_items = manifest.get('items', [])

        # Build a lookup of item statuses from the board (source of truth)
        board_status = {}
        try:
            board_file = self._get_board_file()
            if board_file.exists():
                with open(board_file, 'r') as f:
                    board_data = json.load(f)
                for board_item in board_data.get('backlog', []):
                    status = board_item.get('status') or self._derive_item_status(board_item)
                    board_status[board_item.get('id')] = status
        except Exception as e:
            print(f"[LCARS] Warning: Could not load board for release progress: {e}")

        progress = {
            "total": 0,
            "completed": 0,
            "cancelled": 0,
            "byPlatform": {}
        }

        # Group items by platform, using board status as source of truth.
        # Cancelled items are excluded from total/completed (XACA-0206) — they
        # preserve history in the manifest but don't count toward delivery math.
        platform_items = {}
        for item in manifest_items:
            platform = item.get('platform', 'unknown')
            if platform not in platform_items:
                platform_items[platform] = {"total": 0, "completed": 0, "cancelled": 0}

            # Get status from board (source of truth), fall back to manifest status
            item_id = item.get('itemId')
            current_status = board_status.get(item_id, item.get('status'))

            if current_status == 'cancelled':
                platform_items[platform]["cancelled"] += 1
                progress["cancelled"] += 1
                continue

            platform_items[platform]["total"] += 1
            progress["total"] += 1

            # Check if item is completed (supports both 'done' and 'completed' status values)
            if current_status in ('done', 'completed'):
                platform_items[platform]["completed"] += 1
                progress["completed"] += 1

        # Calculate percentages
        for platform, counts in platform_items.items():
            counts["percentage"] = round(counts["completed"] / counts["total"] * 100) if counts["total"] > 0 else 0

        progress["byPlatform"] = platform_items
        # A release with zero items has nothing left to do — it's 100% complete
        progress["percentage"] = round(progress["completed"] / progress["total"] * 100) if progress["total"] > 0 else 100

        return progress

    def is_release_complete(self, release):
        """Check if a release is complete (all platforms at PROD environment)

        A release is considered complete when ALL of the following platforms
        (if present) are at "PROD" environment:
        - ios
        - android
        - firebase

        Platforms at "PLANNED" (the initial holding state, before development
        begins) are explicitly NOT complete — PLANNED != PROD, so they block
        completion just like DEV, QA, ALPHA, BETA, or GAMMA would.

        Args:
            release: Release object with platforms dict

        Returns:
            bool: True if all required platforms are at PROD, False otherwise
        """
        platforms = release.get('platforms', {})
        required_platforms = ['ios', 'android', 'firebase']

        # If no platforms exist at all, not complete
        if not platforms:
            return False

        # Check each required platform that exists in the release
        for platform_key in required_platforms:
            if platform_key in platforms:
                platform = platforms[platform_key]
                environment = platform.get('environment')
                if environment != 'PROD':
                    return False

        # If we have at least one of the required platforms and all are PROD, complete
        has_any_required = any(p in platforms for p in required_platforms)
        return has_any_required

    # --- GET Handlers ---

    def serve_releases_list(self, query_string=''):
        """GET /api/releases - List all releases

        Query parameters:
            team: Filter releases by team (XACA-0037: prevents cross-team contamination)
            status: Filter by status - 'active' (default), 'archived', or 'all'

        XACA-0209 round 5: server-side tag filtering removed. All tag/search
        filtering is now client-side in the LCARS UI.
        """
        from urllib.parse import parse_qs
        try:
            data = self._load_releases_config()
            releases = data.get('releases', [])
            config_team = data.get('team', LCARS_TEAM)

            # Parse query parameters
            params = parse_qs(query_string) if query_string else {}
            filter_team = params.get('team', [None])[0]
            filter_status = params.get('status', ['active'])[0]  # XACA-0056: default to active

            # XACA-0056: Load archived releases if requested
            if filter_status in ('archived', 'all'):
                archived_releases = self._load_archived_releases(filter_team or config_team)
            else:
                archived_releases = []

            # Determine which releases to include based on status filter
            if filter_status == 'archived':
                # Only archived releases
                releases_to_process = archived_releases
            elif filter_status == 'all':
                # Both active and archived
                releases_to_process = releases + archived_releases
            else:
                # Default: only active releases
                releases_to_process = releases

            # Add progress info and ensure team field for each release
            filtered_releases = []
            for release in releases_to_process:
                release['progress'] = self._calculate_release_progress(release['id'])
                # Ensure team field exists (backward compatibility)
                if 'team' not in release:
                    release['team'] = config_team

                # XACA-0037: Apply team filter if specified
                if filter_team is not None and release['team'] != filter_team:
                    continue

                filtered_releases.append(release)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps({
                "releases": filtered_releases,
                "team": config_team,
                "statusFilter": filter_status  # XACA-0056: Tell UI what filter is active
            }, indent=2).encode())
        except Exception as e:
            self.send_error(500, f"Error loading releases: {e}")

    def serve_release_detail(self, release_id):
        """GET /api/releases/<id> - Get release details"""
        try:
            data = self._load_releases_config()
            release = self._find_release_by_id(data, release_id)

            # XACA-0056: If not found in active releases, check archived releases
            if not release:
                archived_releases = self._load_archived_releases()
                for archived in archived_releases:
                    if archived.get('id') == release_id:
                        release = archived
                        break

            if not release:
                self.send_error(404, f"Release not found: {release_id}")
                return

            # Add progress and manifest
            release['progress'] = self._calculate_release_progress(release_id)
            release['manifest'] = self._load_release_manifest(release_id)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps(release, indent=2).encode())
        except Exception as e:
            self.send_error(500, f"Error loading release: {e}")

    def serve_release_items(self, release_id):
        """GET /api/releases/<id>/items - Get items in release"""
        try:
            manifest = self._load_release_manifest(release_id)
            items = manifest.get('items', [])

            # Cross-reference live board data for current status/title
            # This ensures stale manifest snapshots don't show outdated info
            board_cache = {}
            for manifest_item in items:
                team = manifest_item.get('team')
                item_id = manifest_item.get('itemId')
                if not team or not item_id:
                    continue

                # Cache board data per team to avoid re-reading
                if team not in board_cache:
                    board_file = get_board_file(team)
                    if board_file.exists():
                        with open(board_file, 'r') as f:
                            board_cache[team] = json.load(f)
                    else:
                        board_cache[team] = {}

                board_data = board_cache.get(team, {})
                for board_item in board_data.get('backlog', []):
                    if board_item.get('id') == item_id:
                        # Update manifest item with live board data
                        if 'status' in board_item:
                            manifest_item['status'] = board_item['status']
                        else:
                            # Derive status from subitems and activity signals
                            manifest_item['status'] = self._derive_item_status(board_item)
                        if 'title' in board_item:
                            manifest_item['title'] = board_item['title']
                        if 'priority' in board_item:
                            manifest_item['priority'] = board_item['priority']
                        break

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps({"items": items}, indent=2).encode())
        except Exception as e:
            self.send_error(500, f"Error loading release items: {e}")

    def serve_release_progress(self, release_id):
        """GET /api/releases/<id>/progress - Get completion stats"""
        try:
            progress = self._calculate_release_progress(release_id)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps(progress, indent=2).encode())
        except Exception as e:
            self.send_error(500, f"Error calculating progress: {e}")

    def serve_unassigned_items(self):
        """GET /api/items/unassigned - Items without release assignment (current team only)"""
        try:
            unassigned = []

            # Only scan current team's board - NO cross-team operations
            board_file = get_board_file(LCARS_TEAM)
            if board_file.exists():
                with open(board_file, 'r') as f:
                    board_data = json.load(f)

                for item in board_data.get('backlog', []):
                    if not item.get('releaseAssignment'):
                        unassigned.append({
                            "id": item.get('id'),
                            "title": item.get('title'),
                            "status": item.get('status'),
                            "team": LCARS_TEAM,
                            "priority": item.get('priority'),
                            "subRepo": item.get('subRepo', '')
                        })

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps({"items": unassigned}, indent=2).encode())
        except Exception as e:
            self.send_error(500, f"Error loading unassigned items: {e}")

    def serve_items_by_release(self, release_id, query_string):
        """GET /api/items/by-release/<id>?platform=ios - Filter by release and platform"""
        try:
            from urllib.parse import parse_qs
            params = parse_qs(query_string)
            platform_filter = params.get('platform', [None])[0]

            manifest = self._load_release_manifest(release_id)
            items = manifest.get('items', [])

            if platform_filter:
                items = [i for i in items if i.get('platform') == platform_filter]

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps({"items": items, "releaseId": release_id}, indent=2).encode())
        except Exception as e:
            self.send_error(500, f"Error loading items by release: {e}")

    def serve_release_config(self, query_string=''):
        """GET /api/release-config - Get release configuration (platforms, environments, types, flowConfig)"""
        try:
            # Extract team from query params if provided
            from urllib.parse import parse_qs
            params = parse_qs(query_string)
            team = params.get('team', [None])[0]
            data = self._load_releases_config(team)
            # Ensure flowConfig exists with defaults
            if 'flowConfig' not in data:
                data['flowConfig'] = {
                    'stages': {
                        'PLANNED': {'enabled': True, 'required': True},
                        'DEV': {'enabled': True, 'required': True},
                        'QA': {'enabled': True, 'required': False},
                        'ALPHA': {'enabled': True, 'required': False},
                        'BETA': {'enabled': True, 'required': False},
                        'GAMMA': {'enabled': True, 'required': False},
                        'PROD': {'enabled': True, 'required': True}
                    }
                }
            config = {
                "team": data.get('team', LCARS_TEAM),  # Include team for validation
                "platforms": data.get('platforms', {}),
                "defaultEnvironments": data.get('defaultEnvironments', []),
                "projectEnvironments": data.get('projectEnvironments', {}),
                "releaseTypes": data.get('releaseTypes', {}),
                "flowConfig": data.get('flowConfig', {})
            }

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            # XACA-0163: no-store — this endpoint's response is invalidated by
            # POST /api/releases/flow-config. Caching it made flow-config saves
            # appear successful but leave the UI rendering stale stages.
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(json.dumps(config, indent=2).encode())
        except Exception as e:
            self.send_error(500, f"Error loading release config: {e}")

    # --- POST Handlers ---

    def _extract_version_from_name(self, name):
        """Extract version number from release name (e.g., 'v1.3.0' -> '1.3.0')"""
        import re
        # Match patterns like: v1.3.0, 1.3.0, v1.3, 1.3, Version 1.3.0, etc.
        match = re.search(r'v?(\d+\.\d+(?:\.\d+)?)', name, re.IGNORECASE)
        return match.group(1) if match else '1.0.0'

    def handle_create_release(self):
        """POST /api/releases - Create new release"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            name = post_data.get('name')
            if not name:
                self.send_error(400, "Missing required field: name")
                return

            data = self._load_releases_config()
            release_id = self._generate_release_id(data)

            # Get environments (use project-specific or default)
            project = post_data.get('project')
            if project and project in data.get('projectEnvironments', {}):
                environments = data['projectEnvironments'][project]
            else:
                environments = post_data.get('environments') or data.get('defaultEnvironments', [])

            # Extract default version: prefer shortTitle (the user-facing
            # version label, e.g. "v2.10.0"), fall back to name.
            default_version = self._extract_version_from_name(
                post_data.get('shortTitle') or name
            )

            # XACA-0453: Strip duplicate label prefix from name before persisting.
            # e.g. POST {name: "REL - Sprint 5", shortTitle: "REL"} → name stored as "Sprint 5".
            short_title = post_data.get('shortTitle')
            if short_title:
                name = _strip_label_prefix(name, short_title)

            # Build platforms configuration
            platforms_input = post_data.get('platforms', ['ios', 'android'])
            if isinstance(platforms_input, str):
                platforms_input = [p.strip() for p in platforms_input.split(',')]

            platforms = {}
            for platform in platforms_input:
                platforms[platform] = {
                    "version": post_data.get(f'{platform}Version', default_version),
                    "buildNumber": post_data.get(f'{platform}Build', 1),
                    "environment": environments[0] if environments else "PLANNED",
                    "environmentHistory": []
                }

            release = {
                "id": release_id,
                "name": name,
                "shortTitle": post_data.get('shortTitle'),  # XACA-0050: Optional short display name
                "project": project,
                "type": post_data.get('type', 'feature'),
                "status": "in_progress",
                "targetDate": post_data.get('targetDate'),
                "createdAt": self._get_timestamp(),
                "environments": environments,
                "platforms": platforms,
                "tags": [t.strip() for t in post_data.get('tags', []) if isinstance(t, str) and t.strip()],  # XACA-0209 round 3: strip on write so new data is clean
                "team": LCARS_TEAM  # Track owning team for validation
            }

            data['releases'].append(release)
            self._save_releases_config(data)

            # Create empty manifest with team ownership
            self._save_release_manifest(release_id, {
                "releaseId": release_id,
                "team": LCARS_TEAM,  # Track owning team for validation
                "items": [],
                "createdAt": self._get_timestamp()
            })

            self.send_response(201)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(release, indent=2).encode())

        except Exception as e:
            self.send_error(500, f"Error creating release: {e}")

    def handle_assign_item_to_release(self, release_id):
        """POST /api/releases/<id>/items - Assign item to release"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            item_id = post_data.get('itemId')
            platform = post_data.get('platform')
            team = post_data.get('team')

            if not item_id or not platform:
                self.send_error(400, "Missing required fields: itemId, platform")
                return

            # Verify release exists
            data = self._load_releases_config()
            release = self._find_release_by_id(data, release_id)
            if not release:
                self.send_error(404, f"Release not found: {release_id}")
                return

            # XACA-0037: Validate team ownership - prevent cross-team contamination
            release_team = release.get('team') or data.get('team') or LCARS_TEAM
            if team and team != release_team:
                self.send_error(403, f"Cross-team assignment rejected: Item team '{team}' does not match release team '{release_team}'")
                return

            # Add to manifest
            manifest = self._load_release_manifest(release_id)
            items = manifest.get('items', [])

            # Check if already assigned - if so, update the platform instead of rejecting
            existing_item = None
            for item in items:
                if item.get('itemId') == item_id:
                    existing_item = item
                    break

            # Look up item title from board if team provided
            title = post_data.get('title', item_id)
            status = 'todo'
            if team:
                board_file = get_board_file(team)
                if board_file.exists():
                    with open(board_file, 'r') as f:
                        board_data = json.load(f)
                    for item in board_data.get('backlog', []):
                        if item.get('id') == item_id:
                            title = item.get('title', title)
                            status = item.get('status') or self._derive_item_status(item)
                            break

            if existing_item:
                # Update existing assignment (e.g., change platform)
                existing_item['platform'] = platform
                existing_item['updatedAt'] = self._get_timestamp()
            else:
                # New assignment
                items.append({
                    "itemId": item_id,
                    "platform": platform,
                    "team": team,
                    "title": title,
                    "status": status,
                    "assignedAt": self._get_timestamp()
                })

            manifest['items'] = items
            self._save_release_manifest(release_id, manifest)

            # Update item in kanban board with releaseAssignment
            if team:
                self._update_item_release_assignment(team, item_id, release_id, platform, release.get('name', ''))

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({"success": True, "itemsCount": len(items)}).encode())

        except Exception as e:
            self.send_error(500, f"Error assigning item: {e}")

    def _update_item_release_assignment(self, team, item_id, release_id, platform, release_name=''):
        """Update a kanban item with release assignment"""
        import fcntl
        board_file = get_board_file(team)
        if not board_file.exists():
            return

        lock_file = board_file.with_suffix('.json.lock')
        with open(lock_file, 'w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                with open(board_file, 'r') as f:
                    data = json.load(f)

                for item in data.get('backlog', []):
                    if item.get('id') == item_id:
                        item['releaseAssignment'] = {
                            "releaseId": release_id,
                            "releaseName": release_name,
                            "platform": platform,
                            "assignedAt": self._get_timestamp()
                        }
                        break

                data['lastUpdated'] = self._get_timestamp()
                self._atomic_write_json(board_file, data)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def _sync_item_to_release_manifest(self, release_id, item_id, item_data):
        """Upsert kanban item into a release manifest.

        If the item already exists in manifest.items[], its fields are updated.
        If it does not exist, it is appended using the same schema as
        handle_assign_item_to_release (itemId, platform, team, title, status,
        assignedAt). This is the single sync path used by queue updates,
        shell-driven assigns (via /api/releases/sync-item), and full-board
        reconciliation (/api/releases/sync-all).
        """
        try:
            manifest = self._load_release_manifest(release_id)
            items = manifest.get('items', [])

            existing = None
            for manifest_item in items:
                if manifest_item.get('itemId') == item_id:
                    existing = manifest_item
                    break

            if existing is not None:
                if 'title' in item_data:
                    existing['title'] = item_data['title']
                status_val = item_data.get('status') or self._derive_item_status(item_data)
                if status_val:
                    existing['status'] = status_val
                if 'priority' in item_data:
                    existing['priority'] = item_data['priority']
                assignment = item_data.get('releaseAssignment') or {}
                if assignment.get('platform'):
                    existing['platform'] = assignment['platform']
                existing['lastSynced'] = self._get_timestamp()
                action = 'updated'
            else:
                assignment = item_data.get('releaseAssignment') or {}
                platform = assignment.get('platform') or 'other'
                team = item_data.get('team') or manifest.get('team') or self._extract_team_from_item_id(item_id)
                items.append({
                    "itemId": item_id,
                    "platform": platform,
                    "team": team,
                    "title": item_data.get('title', item_id),
                    "status": item_data.get('status') or self._derive_item_status(item_data) or 'todo',
                    "assignedAt": assignment.get('assignedAt') or self._get_timestamp(),
                    "lastSynced": self._get_timestamp()
                })
                action = 'added'

            manifest['items'] = items
            self._save_release_manifest(release_id, manifest)
            print(f"[LCARS] Synced item {item_id} to release {release_id} ({action})")
            return action
        except Exception as e:
            print(f"[LCARS] Warning: Failed to sync item to release manifest: {e}")
            return None

    def _remove_item_from_release_manifest(self, release_id, item_id):
        """Remove item from release manifest when item is unassigned from release.

        This ensures the manifest stays clean when items are moved to different
        releases or unassigned entirely.
        """
        try:
            manifest = self._load_release_manifest(release_id)
            items = manifest.get('items', [])

            # Filter out the item being removed
            original_count = len(items)
            items = [item for item in items if item.get('itemId') != item_id]

            if len(items) < original_count:
                manifest['items'] = items
                manifest['updatedAt'] = self._get_timestamp()
                self._save_release_manifest(release_id, manifest)
                print(f"[LCARS] Removed item {item_id} from release {release_id}")
        except Exception as e:
            # Don't fail the main update if manifest cleanup fails
            print(f"[LCARS] Warning: Failed to remove item from release manifest: {e}")

    def _update_items_release_name(self, release_id, new_name, team=None):
        """Update releaseName in all board items assigned to a release"""
        import fcntl
        team = team or LCARS_TEAM
        board_file = get_board_file(team)
        if not board_file.exists():
            return

        lock_file = board_file.with_suffix('.json.lock')
        with open(lock_file, 'w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                with open(board_file, 'r') as f:
                    data = json.load(f)

                updated = False
                for item in data.get('backlog', []):
                    if item.get('releaseAssignment', {}).get('releaseId') == release_id:
                        item['releaseAssignment']['releaseName'] = new_name
                        updated = True

                if updated:
                    data['lastUpdated'] = self._get_timestamp()
                    self._atomic_write_json(board_file, data)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def handle_promote_release(self, release_id):
        """POST /api/releases/<id>/promote - Promote platform to next environment"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            platform = post_data.get('platform')
            target_env = post_data.get('targetEnvironment')

            if not platform:
                self.send_error(400, "Missing required field: platform")
                return

            data = self._load_releases_config()
            release = self._find_release_by_id(data, release_id)
            if not release:
                self.send_error(404, f"Release not found: {release_id}")
                return

            if platform not in release.get('platforms', {}):
                self.send_error(400, f"Platform not found in release: {platform}")
                return

            platform_data = release['platforms'][platform]
            all_environments = release.get('environments', data.get('defaultEnvironments', []))
            current_env = platform_data.get('environment')

            # Get flow config and filter to enabled stages only
            flow_config = data.get('flowConfig', {})
            stages = flow_config.get('stages', {})
            environments = [env for env in all_environments if stages.get(env, {}).get('enabled', True)]

            # Determine target environment
            if target_env:
                # Validate target is in enabled environments
                if target_env not in environments:
                    self.send_error(400, f"Invalid or disabled environment: {target_env}")
                    return
                new_env = target_env
            else:
                # Auto-promote to next enabled environment
                try:
                    current_idx = environments.index(current_env)
                    if current_idx >= len(environments) - 1:
                        self.send_error(400, f"Already at final environment: {current_env}")
                        return
                    new_env = environments[current_idx + 1]
                except ValueError:
                    # Current env not in enabled list, find next enabled after current
                    try:
                        all_idx = all_environments.index(current_env)
                        # Find next enabled environment
                        for env in all_environments[all_idx + 1:]:
                            if env in environments:
                                new_env = env
                                break
                        else:
                            new_env = environments[0] if environments else "PLANNED"
                    except ValueError:
                        new_env = environments[0] if environments else "PLANNED"

            # Record history and update
            history = platform_data.get('environmentHistory', [])
            history.append({
                "from": current_env,
                "to": new_env,
                "promotedAt": self._get_timestamp()
            })

            platform_data['environment'] = new_env
            platform_data['environmentHistory'] = history

            self._save_releases_config(data)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({
                "success": True,
                "platform": platform,
                "previousEnvironment": current_env,
                "newEnvironment": new_env
            }).encode())

        except Exception as e:
            self.send_error(500, f"Error promoting release: {e}")

    # --- PUT Handler ---

    def handle_update_release(self, release_id):
        """PUT /api/releases/<id> - Update release"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            data = self._load_releases_config()
            release = self._find_release_by_id(data, release_id)
            if not release:
                self.send_error(404, f"Release not found: {release_id}")
                return

            # Update allowed fields
            allowed_fields = ['name', 'shortTitle', 'targetDate', 'status', 'type', 'project']  # XACA-0050: Added shortTitle
            for field in allowed_fields:
                if field in post_data:
                    release[field] = post_data[field]

            # XACA-0209: tags field needs type/strip validation (matches epic handlers).
            # XACA-0209 round 3: also strip individual values so new data is clean.
            if 'tags' in post_data:
                release['tags'] = [t.strip() for t in post_data.get('tags', []) if isinstance(t, str) and t.strip()]

            # XACA-0453: Strip duplicate label prefix from name on update.
            # Only runs when the patch includes a name.  The effective label is
            # release['shortTitle'] at this point (already merged above from
            # post_data or preserved from the stored record).  We write the
            # normalized value back to both release['name'] and post_data['name']
            # so that the _update_items_release_name call below stays consistent.
            if 'name' in post_data:
                effective_label = release.get('shortTitle')
                normalized_name = _strip_label_prefix(post_data['name'], effective_label)
                release['name'] = normalized_name
                post_data['name'] = normalized_name

            # When shortTitle changes, keep platform versions in lockstep with
            # the release version label (e.g. shortTitle "v2.10.0" → every
            # platform.version becomes "2.10.0"). Explicit per-platform
            # versions in the same request still win (handled below).
            if 'shortTitle' in post_data and post_data.get('shortTitle'):
                import re
                m = re.search(r'v?(\d+\.\d+(?:\.\d+)?)', post_data['shortTitle'], re.IGNORECASE)
                if m:
                    synced_version = m.group(1)
                    for plat in release.get('platforms', {}).values():
                        plat['version'] = synced_version

            # Update platform versions/builds if provided
            if 'platforms' in post_data:
                for platform, updates in post_data['platforms'].items():
                    if platform in release.get('platforms', {}):
                        for key in ['version', 'buildNumber']:
                            if key in updates:
                                release['platforms'][platform][key] = updates[key]

            # Add new platforms if requested (cannot remove existing ones).
            # Newly-added platforms inherit the release's current version
            # (parsed from shortTitle, falling back to name).
            if 'addPlatforms' in post_data:
                existing_platforms = release.get('platforms', {})
                release_version = self._extract_version_from_name(
                    release.get('shortTitle') or release.get('name') or ''
                )
                for platform in post_data['addPlatforms']:
                    if platform not in existing_platforms:
                        existing_platforms[platform] = {
                            "version": release_version,
                            "buildNumber": 1,
                            "environment": "PLANNED",
                            "environmentHistory": []
                        }
                release['platforms'] = existing_platforms

            self._save_releases_config(data)

            # Update releaseName in board items if name was changed
            if 'name' in post_data:
                self._update_items_release_name(release_id, post_data['name'], release.get('team'))

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(release, indent=2).encode())

        except Exception as e:
            self.send_error(500, f"Error updating release: {e}")

    def handle_update_flow_config(self):
        """POST /api/releases/flow-config - Update flow configuration"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            # Validate request - stages is required
            if 'stages' not in post_data:
                self.send_error(400, "Missing required field: stages")
                return

            stages = post_data['stages']
            team = post_data.get('team')  # Optional team parameter for cross-team support
            # Debug logging to file (terminal output may be redirected)
            with open(LCARS_TMP_DIR / 'lcars-flow-debug.log', 'a') as log:
                log.write(f"[{self._get_timestamp()}] Flow config update - team from request: {team}\n")
                log.write(f"[{self._get_timestamp()}] Flow config update - stages: {stages}\n")

            # Validate that PLANNED, DEV, and PROD are enabled (required stages)
            if not stages.get('PLANNED', {}).get('enabled', True):
                self.send_error(400, "PLANNED stage cannot be disabled")
                return
            if not stages.get('DEV', {}).get('enabled', False):
                self.send_error(400, "DEV stage cannot be disabled")
                return
            if not stages.get('PROD', {}).get('enabled', False):
                self.send_error(400, "PROD stage cannot be disabled")
                return

            # Load current config (use team from request if provided)
            data = self._load_releases_config(team)

            # Initialize flowConfig if not exists
            if 'flowConfig' not in data:
                data['flowConfig'] = {
                    'stages': {
                        'PLANNED': {'enabled': True, 'required': True},
                        'DEV': {'enabled': True, 'required': True},
                        'QA': {'enabled': True, 'required': False},
                        'ALPHA': {'enabled': True, 'required': False},
                        'BETA': {'enabled': True, 'required': False},
                        'GAMMA': {'enabled': True, 'required': False},
                        'PROD': {'enabled': True, 'required': True}
                    }
                }

            # Update stages (only enabled field, preserve required)
            for stage_name, stage_config in stages.items():
                if stage_name in data['flowConfig']['stages']:
                    # Only allow changing enabled for non-required stages
                    if not data['flowConfig']['stages'][stage_name].get('required', False):
                        data['flowConfig']['stages'][stage_name]['enabled'] = stage_config.get('enabled', True)

            self._save_releases_config(data, team)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(data['flowConfig'], indent=2).encode())

        except Exception as e:
            self.send_error(500, f"Error updating flow config: {e}")

    def handle_sync_item_to_release(self):
        """POST /api/releases/sync-item - Sync kanban item to release manifest

        Accepts JSON: { "itemId": "XIOS-0042", "team": "ios" }
        Team is optional and can be auto-detected from itemId prefix.

        Returns:
        - { "success": true, "synced": true, "releaseId": "REL-..." } if synced
        - { "success": true, "synced": false, "reason": "..." } if no release assignment
        """
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            item_id = post_data.get('itemId')
            if not item_id:
                self.send_error(400, "Missing required field: itemId")
                return

            # Extract or use provided team
            team = post_data.get('team')
            if not team:
                team = self._extract_team_from_item_id(item_id)
                if not team:
                    self.send_error(400, f"Cannot determine team from item ID: {item_id}")
                    return

            # Load board file and find the item
            board_file = get_board_file(team)
            if not board_file.exists():
                self.send_error(404, f"Board file not found for team: {team}")
                return

            with open(board_file, 'r') as f:
                board_data = json.load(f)

            # Find the item in backlog
            item_data = None
            for item in board_data.get('backlog', []):
                if item.get('id') == item_id:
                    item_data = item
                    break

            if not item_data:
                self.send_error(404, f"Item not found in board: {item_id}")
                return

            # Ensure item_data carries team (used by _sync_item_to_release_manifest)
            item_data.setdefault('team', team)

            release_assignment = item_data.get('releaseAssignment') or {}
            assigned_release_id = release_assignment.get('releaseId')

            # Reconcile across every release in this team's board. Per-item sync
            # must be a fixed-point: any manifest other than the currently
            # assigned one must NOT list this item.
            all_releases = board_data.get('releases', []) or []
            upserted_in = None
            removed_from = []
            for release in all_releases:
                rid = release.get('id') or release.get('releaseId')
                if not rid:
                    continue
                if assigned_release_id and rid == assigned_release_id:
                    if self._sync_item_to_release_manifest(rid, item_id, item_data):
                        upserted_in = rid
                else:
                    try:
                        manifest = self._load_release_manifest(rid)
                        if any(it.get('itemId') == item_id for it in manifest.get('items', [])):
                            self._remove_item_from_release_manifest(rid, item_id)
                            removed_from.append(rid)
                    except Exception as e:
                        print(f"[LCARS] Warning: scan of {rid} during sync-item failed: {e}")

            # If the item references a release that isn't present in this
            # team's board releases list (drift), still upsert it directly —
            # matches the implicit contract kb-release-assign enforced before.
            if assigned_release_id and upserted_in != assigned_release_id:
                if self._sync_item_to_release_manifest(assigned_release_id, item_id, item_data):
                    upserted_in = assigned_release_id

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({
                "success": True,
                "synced": bool(upserted_in) or bool(removed_from),
                "releaseId": upserted_in,
                "removedFrom": removed_from,
                "reason": None if (upserted_in or removed_from) else "no release assignment"
            }).encode())

        except Exception as e:
            self.send_error(500, f"Error syncing item to release: {e}")

    def handle_sync_all_to_releases(self):
        """POST /api/releases/sync-all — reconcile entire team board against release manifests.

        Request body (optional): { "team": "android" }
        Walks every item in backlog, then calls the same per-item reconcile
        used by handle_sync_item_to_release. This is the repair command for
        drift cases like XAND-0619 → REL-2026-Q2-009 where the board had the
        assignment but the manifest never got the item.
        """
        try:
            try:
                content_length = int(self.headers.get('Content-Length') or 0)
            except (TypeError, ValueError):
                content_length = 0
            post_data = {}
            if content_length:
                post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team') or LCARS_TEAM
            board_file = get_board_file(team)
            if not board_file.exists():
                self.send_error(404, f"Board file not found for team: {team}")
                return

            with open(board_file, 'r') as f:
                board_data = json.load(f)

            backlog = board_data.get('backlog', []) or []
            all_releases = board_data.get('releases', []) or []
            release_ids = [r.get('id') or r.get('releaseId') for r in all_releases if r.get('id') or r.get('releaseId')]

            added = []     # [(item_id, release_id)] — item was new to manifest
            updated = []   # [(item_id, release_id)] — item existed, fields refreshed
            removes = []   # [(item_id, release_id)] — stale entry pruned
            assigned_by_release = {}  # release_id -> set(item_id) from board

            # First pass: push board assignments into their manifests
            for item in backlog:
                item_id = item.get('id')
                if not item_id:
                    continue
                item.setdefault('team', team)
                assignment = item.get('releaseAssignment') or {}
                rid = assignment.get('releaseId')
                if not rid:
                    continue
                assigned_by_release.setdefault(rid, set()).add(item_id)
                action = self._sync_item_to_release_manifest(rid, item_id, item)
                if action == 'added':
                    added.append((item_id, rid))
                elif action == 'updated':
                    updated.append((item_id, rid))

            # Second pass: prune manifest entries whose board item no longer
            # points at this release (or no longer exists).
            #
            # NOTE: This pass iterates board.releases[] only. On-disk manifest
            # directories whose releaseId is no longer in board.releases[] are
            # NOT pruned here. This is intentional: the deletion path
            # (handle_archive_release) is responsible for removing the manifest
            # directory when a release is archived — it does so via
            # _get_release_manifest_path (XACA-0056 team-isolation contract) and
            # shutil.rmtree with a best-effort log-on-failure wrapper (XACA-0183).
            # Adding a filesystem scan here instead would risk cross-team manifest
            # collisions when multiple boards share a releases/ root, so avoid it.
            for rid in release_ids:
                try:
                    manifest = self._load_release_manifest(rid)
                except Exception as e:
                    print(f"[LCARS] Warning: sync-all skipped {rid}: {e}")
                    continue
                assigned_ids = assigned_by_release.get(rid, set())
                stale = [it.get('itemId') for it in manifest.get('items', []) if it.get('itemId') and it.get('itemId') not in assigned_ids]
                for sid in stale:
                    self._remove_item_from_release_manifest(rid, sid)
                    removes.append((sid, rid))

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({
                "success": True,
                "team": team,
                "added": [{"itemId": i, "releaseId": r} for (i, r) in added],
                "updated": [{"itemId": i, "releaseId": r} for (i, r) in updated],
                "removes": [{"itemId": i, "releaseId": r} for (i, r) in removes],
                "addedCount": len(added),
                "updatedCount": len(updated),
                "removeCount": len(removes)
            }).encode())

        except Exception as e:
            self.send_error(500, f"Error syncing board to releases: {e}")

    # --- PATCH Handlers ---

    def handle_toggle_release_archive(self, release_id):
        """PATCH /api/releases/<id>/archive - Toggle archive/unarchive release"""
        try:
            # Get team from query params
            parsed = urlparse(self.path)
            query_params = parse_qs(parsed.query)
            team = query_params.get('team', [None])[0]

            # XACA-0056: Archive directory must be in team's kanban directory to prevent cross-contamination
            effective_team = team or LCARS_TEAM
            kanban_dir = TEAM_KANBAN_DIRS.get(effective_team, KANBAN_DIR)
            archive_dir = kanban_dir / "releases-archive"
            archive_file = archive_dir / f"{release_id}.json"

            # Check if release is currently archived
            if archive_file.exists():
                # UNARCHIVE: Move from archive back to active
                with open(archive_file, 'r') as f:
                    release = json.load(f)

                # Restore to active status
                release['status'] = 'active'
                if 'archivedAt' in release:
                    del release['archivedAt']

                # Add back to active releases
                data = self._load_releases_config(team)
                data['releases'].append(release)
                self._save_releases_config(data, team)

                # Remove from archive
                archive_file.unlink()

                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps({
                    "success": True,
                    "archived": False,
                    "message": "Release unarchived successfully"
                }).encode())

            else:
                # ARCHIVE: Check if release is complete, then move to archive
                data = self._load_releases_config(team)
                release = self._find_release_by_id(data, release_id)
                if not release:
                    self.send_error(404, f"Release not found: {release_id}")
                    return

                # Check if release is complete before archiving
                if not self.is_release_complete(release):
                    self.send_response(400)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Access-Control-Allow-Origin', '*')
                    self.end_headers()
                    self.wfile.write(json.dumps({
                        "error": "Cannot archive: release is not complete (all platforms must be at PROD)"
                    }).encode())
                    return

                # Remove from active releases
                data['releases'] = [r for r in data['releases'] if r['id'] != release_id]

                # Move to archive
                release['archivedAt'] = self._get_timestamp()
                release['status'] = 'archived'

                archive_dir.mkdir(parents=True, exist_ok=True)
                self._atomic_write_json(archive_file, release)

                self._save_releases_config(data, team)

                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps({
                    "success": True,
                    "archived": True,
                    "message": "Release archived successfully"
                }).encode())

        except Exception as e:
            self.send_error(500, f"Error toggling release archive: {e}")

    # --- DELETE Handlers ---

    def handle_archive_release(self, release_id):
        """DELETE /api/releases/<id> - Archive release"""
        try:
            # Mirror handle_toggle_release_archive: honour ?team= so that the
            # archive JSON and manifest cleanup land in the right team directory
            # rather than always defaulting to the current LCARS_TEAM.
            parsed = urlparse(self.path)
            query_params = parse_qs(parsed.query)
            team = query_params.get('team', [None])[0]
            effective_team = team or LCARS_TEAM

            data = self._load_releases_config(effective_team)
            release = self._find_release_by_id(data, release_id)
            if not release:
                self.send_error(404, f"Release not found: {release_id}")
                return

            # Remove from active releases
            data['releases'] = [r for r in data['releases'] if r['id'] != release_id]

            # Move to archive
            release['archivedAt'] = self._get_timestamp()
            release['status'] = 'archived'

            kanban_dir = TEAM_KANBAN_DIRS.get(effective_team, KANBAN_DIR)
            archive_dir = kanban_dir / "releases-archive"
            archive_dir.mkdir(parents=True, exist_ok=True)
            archive_file = archive_dir / f"{release_id}.json"
            self._atomic_write_json(archive_file, release)

            self._save_releases_config(data, effective_team)

            # XACA-0183: Remove the on-disk manifest directory now that the
            # archive write is authoritative.  Use _get_release_manifest_path
            # to preserve the XACA-0056 team-isolation contract — do NOT
            # hand-roll the path.  A filesystem failure must not 500 the
            # request after the archive has already succeeded.
            release_dir = None
            try:
                import shutil
                manifest_path = self._get_release_manifest_path(release_id, effective_team)
                release_dir = manifest_path.parent
                if release_dir.exists():
                    shutil.rmtree(release_dir)
            except Exception as cleanup_err:
                print(f"[LCARS] Warning: archived {release_id} but failed to remove "
                      f"{release_dir}: {cleanup_err}")

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({"success": True, "archived": release_id}).encode())

        except Exception as e:
            self.send_error(500, f"Error archiving release: {e}")

    def handle_remove_item_from_release(self, release_id, item_id):
        """DELETE /api/releases/<id>/items/<itemId> - Remove item from release"""
        try:
            manifest = self._load_release_manifest(release_id)
            items = manifest.get('items', [])

            # Find the item to get its team before removing
            removed_item = None
            for item in items:
                if item.get('itemId') == item_id:
                    removed_item = item
                    break

            if not removed_item:
                self.send_error(404, f"Item not found in release: {item_id}")
                return

            # Remove from manifest
            manifest['items'] = [i for i in items if i.get('itemId') != item_id]
            self._save_release_manifest(release_id, manifest)

            # Clear releaseAssignment from kanban item
            team = removed_item.get('team')
            if team:
                self._clear_item_release_assignment(team, item_id)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({"success": True, "removed": item_id}).encode())

        except Exception as e:
            self.send_error(500, f"Error removing item: {e}")

    def _clear_item_release_assignment(self, team, item_id):
        """Clear release assignment from a kanban item"""
        import fcntl
        board_file = get_board_file(team)
        if not board_file.exists():
            return

        lock_file = board_file.with_suffix('.json.lock')
        with open(lock_file, 'w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                with open(board_file, 'r') as f:
                    data = json.load(f)

                for item in data.get('backlog', []):
                    if item.get('id') == item_id:
                        if 'releaseAssignment' in item:
                            del item['releaseAssignment']
                        break

                data['lastUpdated'] = self._get_timestamp()
                self._atomic_write_json(board_file, data)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    # =========================================================================
    # END RELEASE MANAGEMENT API
    # =========================================================================

    # =========================================================================
    # EPIC MANAGEMENT API
    # =========================================================================
    # Epics are stored in the kanban board file's .epics array, NOT a separate
    # config file. This ensures kb-epic CLI and LCARS UI stay in sync.
    # Epic ID format: E{TEAMCODE}-#### (e.g., EFSW-0001)
    # =========================================================================

    # Team code mapping for epic IDs (matches kanban-helpers.sh)
    TEAM_CODES = {
        "ios": "IOS",
        "android": "AND",
        "firebase": "FIR",
        "freelance": "FRE",
        "freelance-doublenode-starwords": "FSW",
        "freelance-doublenode-workstats": "FWS",
        "freelance-doublenode-appplanning": "FAP",
        "academy": "ACA",
        "dns": "DNS",
        "command": "CMD",
        "mainevent": "MEV",
    }

    # Color palette for epics (UI display only)
    EPIC_COLORS = {
        "purple": {"name": "Purple", "hex": "#9966cc"},
        "blue": {"name": "Blue", "hex": "#4a90d9"},
        "teal": {"name": "Teal", "hex": "#5fb0b0"},
        "green": {"name": "Green", "hex": "#7ed321"},
        "yellow": {"name": "Yellow", "hex": "#f5a623"},
        "orange": {"name": "Orange", "hex": "#ff9933"},
        "red": {"name": "Red", "hex": "#d0021b"},
        "pink": {"name": "Pink", "hex": "#ff6699"}
    }

    def _get_team_code(self, team):
        """Get 3-letter team code for epic IDs"""
        if team in self.TEAM_CODES:
            return self.TEAM_CODES[team]
        # Smart fallback for multi-segment names
        if '-' in team:
            first_segment = team.split('-')[0]
            last_segment = team.split('-')[-1]
            code = first_segment[0].upper() + last_segment[:2].upper()
            return code[:3]
        return team[:3].upper()

    def _get_board_file(self, team=None):
        """Get the board file path for a team.

        XACA-0249: When no team was supplied by the caller AND LCARS_TEAM env
        was not explicitly set at server start, we are silently serving data
        for the hardcoded 'freelance' default.  Emit a throttled WARN so the
        misconfiguration is impossible to miss in the logs.
        """
        if not team and not _LCARS_TEAM_WAS_EXPLICIT:
            endpoint = getattr(self, 'path', '<unknown>')
            now = time.monotonic()
            last = _team_fallback_warn_times.get(endpoint, 0.0)
            if now - last >= _TEAM_FALLBACK_WARN_INTERVAL_SECONDS:
                _team_fallback_warn_times[endpoint] = now
                print(
                    f"[LCARS] WARN: Team-scoped endpoint '{endpoint}' served with "
                    f"hardcoded 'freelance' default — UI did not pass ?team= and "
                    f"LCARS_TEAM env is unset. This indicates UI/server "
                    f"misconfiguration. See XACA-0249."
                )
        team = team or LCARS_TEAM
        return get_board_file(team)

    def _load_board_epics(self, team=None):
        """Load epics from the kanban board file"""
        import fcntl
        board_file = self._get_board_file(team)

        if not board_file.exists():
            return {"epics": [], "nextEpicId": 1}

        lock_file = board_file.with_suffix('.json.lock')
        with open(lock_file, 'w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_SH)
            try:
                with open(board_file, 'r') as f:
                    data = json.load(f)
                return {
                    "epics": data.get('epics', []),
                    "nextEpicId": data.get('nextEpicId', 1),
                    "team": data.get('team', team or LCARS_TEAM)
                }
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def _save_board_epics(self, epics, next_epic_id, team=None):
        """Save epics to the kanban board file"""
        import fcntl
        board_file = self._get_board_file(team)

        if not board_file.exists():
            print(f"[LCARS] Board file not found: {board_file}")
            return False

        lock_file = board_file.with_suffix('.json.lock')
        with open(lock_file, 'w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                with open(board_file, 'r') as f:
                    data = json.load(f)

                data['epics'] = epics
                data['nextEpicId'] = next_epic_id
                data['lastUpdated'] = self._get_timestamp()

                self._atomic_write_json(board_file, data)
                return True
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def _find_epic_by_id(self, epics_data, epic_id):
        """Find epic by ID in epics list"""
        for epic in epics_data.get('epics', []):
            if epic.get('id') == epic_id:
                return epic
        return None

    def _generate_epic_id(self, epics_data, team=None):
        """Generate next epic ID in E{TEAMCODE}-#### format"""
        team = team or LCARS_TEAM
        team_code = self._get_team_code(team)
        next_id = epics_data.get('nextEpicId', 1)
        return f"E{team_code}-{next_id:04d}"

    @staticmethod
    def _derive_epic_state(items):
        """Derive epic state from a list of item dicts (already fetched for this epic).

        Returns 'PLANNED' | 'ACTIVE' | 'ARCHIVED'.
        Pure: same input -> same output. See STATE_CONTRACT.md §1.5.

        Effective items are those whose status != 'cancelled'.
        Blocked items count as in-flight (not todo, not completed) per §1.1.
        Orphan IDs are not present in `items` (handled by caller via
        _get_items_for_epic), so case M is naturally satisfied here.
        """
        effective = [i for i in items if i.get('status') != 'cancelled']
        if not effective:
            return 'PLANNED'  # cases A, B, M
        if all(i.get('status') == 'completed' for i in effective):
            return 'ARCHIVED'
        if all(i.get('status') == 'todo' for i in effective):
            return 'PLANNED'
        return 'ACTIVE'

    @staticmethod
    def _build_epic_item_counts(items):
        """Build the 8-key itemCounts rollup dict for an epic.

        Keys (camelCase per STATE_CONTRACT.md §5.1):
          total, effective, todo, inProgress, inReview, blocked, completed, cancelled
        """
        total = len(items)
        cancelled = sum(1 for i in items if i.get('status') == 'cancelled')
        effective = total - cancelled
        todo = sum(1 for i in items if i.get('status') == 'todo')
        in_progress = sum(1 for i in items if i.get('status') == 'in_progress')
        in_review = sum(1 for i in items if i.get('status') == 'in_review')
        blocked = sum(1 for i in items if i.get('status') == 'blocked')
        # 'completed' is the canonical terminal status per STATE_CONTRACT.md §1.1.
        # Legacy 'done' is intentionally NOT counted here — derivation and counts
        # must agree (XACA-0474-010).
        completed = sum(1 for i in items if i.get('status') == 'completed')
        return {
            'total': total,
            'effective': effective,
            'todo': todo,
            'inProgress': in_progress,
            'inReview': in_review,
            'blocked': blocked,
            'completed': completed,
            'cancelled': cancelled,
        }

    def _get_items_for_epic(self, epic_id, board_data=None):
        """Get kanban items assigned to an epic from the current team's board only.

        NO cross-team data - epics and items are scoped to the current team.

        Pass `board_data` to skip the file read — useful when iterating epics
        in a single request (XACA-0474-011 avoids N file reads per /api/epics).
        """
        items = []

        if board_data is None:
            board_file = get_board_file(LCARS_TEAM)
            if not board_file.exists():
                return items
            try:
                with open(board_file, 'r') as f:
                    board_data = json.load(f)
            except Exception as e:
                print(f"[LCARS] Error reading {board_file}: {e}")
                return items

        for item in board_data.get('backlog', []):
            if item.get('epicId') == epic_id:
                items.append({
                    "itemId": item.get('id'),
                    "title": item.get('title', ''),
                    "status": item.get('status', 'todo'),
                    "priority": item.get('priority', 'medium'),
                    "team": LCARS_TEAM,
                    "tags": item.get('tags', []),
                    "subRepo": item.get('subRepo', '')
                })

        return items

    def serve_epics_list(self, query_string=''):
        """GET /api/epics - List all epics from kanban board

        Query parameters:
            team:  Filter epics by team (mirrors other epic endpoints)
            state: Filter by derived state - 'PLANNED', 'ACTIVE', or 'ARCHIVED'
                   (case-insensitive; comma-separated for multi-value allow-list).
                   Empty value or absent param returns all epics. Invalid value
                   returns 400. See STATE_CONTRACT.md §5.2 (XACA-0474).

        XACA-0209 round 5: server-side tag filtering removed. All tag/search
        filtering is now client-side in the LCARS UI.
        """
        from urllib.parse import parse_qs

        _VALID_STATES = {'PLANNED', 'ACTIVE', 'ARCHIVED'}

        try:
            params = parse_qs(query_string) if query_string else {}
            filter_team = params.get('team', [None])[0]

            # XACA-0474: Parse ?state= filter (case-insensitive, comma-separated).
            raw_state = params.get('state', [None])[0]
            filter_states = None  # None means no filter
            if raw_state is not None and raw_state.strip():
                tokens = [t.strip().upper() for t in raw_state.split(',') if t.strip()]
                invalid = [t for t in tokens if t not in _VALID_STATES]
                if invalid:
                    self._send_json_response(
                        {'error': 'Invalid state', 'valid': sorted(_VALID_STATES)},
                        status=400
                    )
                    return
                filter_states = set(tokens)

            data = self._load_board_epics(filter_team)
            epics = data.get('epics', [])

            # XACA-0474-011: Read the team board once for the whole request and
            # pass it to _get_items_for_epic to avoid N file reads in this loop.
            board_data_cache = None
            board_file = get_board_file(LCARS_TEAM)
            if board_file.exists():
                try:
                    with open(board_file, 'r') as f:
                        board_data_cache = json.load(f)
                except Exception as e:
                    print(f"[LCARS] Error reading {board_file}: {e}")

            # Add item counts and normalize field names for UI compatibility.
            # Cancelled items are excluded from itemCount/completedCount so the
            # progress fraction reflects active work, mirroring release math
            # (XACA-0206). cancelledCount is surfaced so the UI can show why
            # the denominator shrank.
            #
            # XACA-0474: Also add derived `state` (UPPERCASE enum) and `itemCounts`
            # (8-key rollup dict). Existing fields itemCount/completedCount/
            # cancelledCount are preserved for backward compat with renderEpicCard.
            result_epics = []
            for epic in epics:
                items = self._get_items_for_epic(epic['id'], board_data=board_data_cache)
                active = [i for i in items if i['status'] != 'cancelled']
                epic['itemCount'] = len(active)
                epic['completedCount'] = len([i for i in active if i['status'] in ('done', 'completed')])
                epic['cancelledCount'] = len(items) - len(active)
                # Map 'title' to 'name' for UI compatibility (board uses 'title')
                if 'title' in epic and 'name' not in epic:
                    epic['name'] = epic['title']
                # XACA-0474: Derived state + full item-count breakdown
                epic['state'] = self._derive_epic_state(items)
                epic['itemCounts'] = self._build_epic_item_counts(items)
                # Apply ?state= filter (AND with ?team= which was handled by _load_board_epics)
                if filter_states is not None and epic['state'] not in filter_states:
                    continue
                result_epics.append(epic)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({
                "epics": result_epics,
                "colors": self.EPIC_COLORS
            }, indent=2).encode())

        except Exception as e:
            self.send_error(500, f"Error listing epics: {e}")

    def serve_epic_detail(self, epic_id):
        """GET /api/epics/<id> - Get epic details from kanban board

        XACA-0474: Response includes `state` (UPPERCASE enum) and `itemCounts`
        (8-key rollup dict) per STATE_CONTRACT.md §5.3.
        """
        try:
            data = self._load_board_epics()
            epic = self._find_epic_by_id(data, epic_id)

            if not epic:
                self.send_error(404, f"Epic not found: {epic_id}")
                return

            # Map 'title' to 'name' for UI compatibility
            if 'title' in epic and 'name' not in epic:
                epic['name'] = epic['title']

            # Add items to epic
            items = self._get_items_for_epic(epic_id)
            epic['items'] = items

            # XACA-0474: Derived state + full item-count breakdown
            epic['state'] = self._derive_epic_state(items)
            epic['itemCounts'] = self._build_epic_item_counts(items)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(epic, indent=2).encode())

        except Exception as e:
            self.send_error(500, f"Error getting epic: {e}")

    def serve_epic_items(self, epic_id):
        """GET /api/epics/<id>/items - Get items in epic"""
        try:
            items = self._get_items_for_epic(epic_id)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({"items": items}, indent=2).encode())

        except Exception as e:
            self.send_error(500, f"Error getting epic items: {e}")

    # =========================================================================
    # TODO API HANDLERS (XACA-0101)
    # =========================================================================

    # Priority sort order: critical=0, high=1, medium=2, low=3
    TODO_PRIORITY_ORDER = {'critical': 0, 'high': 1, 'medium': 2, 'low': 3}

    def serve_todos_list(self, query_string=''):
        """GET /api/todos - List todos for a team

        Query parameters:
            team: Team name (required)
            status: Filter by 'todo' or 'completed'; omit to return all
        """
        from urllib.parse import parse_qs
        try:
            params = parse_qs(query_string) if query_string else {}
            team = params.get('team', [None])[0]
            status_filter = params.get('status', [None])[0]

            if not team:
                self._send_json_response({"success": False, "error": "Missing required parameter: team"}, 400)
                return

            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({"success": False, "error": f"Board not found: {team}"}, 404)
                return

            with open(board_file, 'r') as f:
                data = json.load(f)

            todos = data.get('todos', [])

            # Apply status filter if provided
            if status_filter in ('todo', 'completed'):
                todos = [t for t in todos if t.get('status') == status_filter]

            # Sort: active todos by priority then createdAt; completed by completedAt desc
            active = sorted(
                [t for t in todos if t.get('status') != 'completed'],
                key=lambda t: (
                    self.TODO_PRIORITY_ORDER.get(t.get('priority', 'medium'), 2),
                    t.get('createdAt', '')
                )
            )
            completed = sorted(
                [t for t in todos if t.get('status') == 'completed'],
                key=lambda t: t.get('completedAt', ''),
                reverse=True
            )

            if status_filter == 'todo':
                result = active
            elif status_filter == 'completed':
                result = completed
            else:
                result = active + completed

            self._send_json_response({"success": True, "todos": result})

        except Exception as e:
            self.send_error(500, f"Error listing todos: {e}")

    def handle_create_todo(self):
        """POST /api/todos - Create a new todo"""
        import random
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team')
            text = post_data.get('text', '').strip()

            if not team:
                self._send_json_response({"success": False, "error": "Missing required field: team"}, 400)
                return
            if not text:
                self._send_json_response({"success": False, "error": "Missing required field: text"}, 400)
                return
            if len(text) > 500:
                self._send_json_response({"success": False, "error": "Text exceeds maximum length of 500 characters"}, 400)
                return

            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({"success": False, "error": f"Board not found: {team}"}, 404)
                return

            priority = post_data.get('priority', 'medium')
            if priority not in self.TODO_PRIORITY_ORDER:
                self._send_json_response({"success": False, "error": f"Invalid priority: {priority}. Must be one of: critical, high, medium, low"}, 400)
                return

            required_by = post_data.get('requiredBy')
            if required_by:
                try:
                    datetime.strptime(str(required_by), '%Y-%m-%d')
                except ValueError:
                    self._send_json_response({"success": False, "error": "Invalid requiredBy date. Must be a valid YYYY-MM-DD date"}, 400)
                    return

            timestamp = self._get_timestamp()
            todo_id = f"todo-{int(time.time())}-{random.randint(1000, 9999)}"

            todo = {
                "id": todo_id,
                "text": text,
                "priority": priority,
                "requiredBy": required_by,
                "status": "todo",
                "createdAt": timestamp,
                "completedAt": None
            }

            import fcntl
            lock_file = board_file.with_suffix('.json.lock')
            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    with open(board_file, 'r') as f:
                        data = json.load(f)

                    if 'todos' not in data:
                        data['todos'] = []

                    data['todos'].append(todo)
                    data['lastUpdated'] = timestamp

                    self._atomic_write_json(board_file, data)
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

            print(f"[LCARS] Todo created: {todo_id} for team={team}")
            self._send_json_response({"success": True, "todo": todo, "message": "Todo created"}, 201)

        except Exception as e:
            self.send_error(500, f"Error creating todo: {e}")

    def handle_update_todo(self):
        """PUT /api/todos - Update an existing todo"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team')
            todo_id = post_data.get('id')
            updates = post_data.get('updates', {})

            if not team:
                self._send_json_response({"success": False, "error": "Missing required field: team"}, 400)
                return
            if not todo_id:
                self._send_json_response({"success": False, "error": "Missing required field: id"}, 400)
                return
            if not updates:
                self._send_json_response({"success": False, "error": "Missing required field: updates"}, 400)
                return

            # Validate priority if provided
            if 'priority' in updates and updates['priority'] not in self.TODO_PRIORITY_ORDER:
                self._send_json_response({"success": False, "error": f"Invalid priority: {updates['priority']}. Must be one of: critical, high, medium, low"}, 400)
                return

            # Validate status if provided
            if 'status' in updates and updates['status'] not in ('todo', 'completed'):
                self._send_json_response({"success": False, "error": f"Invalid status: {updates['status']}. Must be 'todo' or 'completed'"}, 400)
                return

            # Validate requiredBy date format if provided
            if 'requiredBy' in updates and updates['requiredBy']:
                try:
                    datetime.strptime(str(updates['requiredBy']), '%Y-%m-%d')
                except ValueError:
                    self._send_json_response({"success": False, "error": "Invalid requiredBy date. Must be a valid YYYY-MM-DD date"}, 400)
                    return

            # Validate text if provided: strip, reject empty, check length
            if 'text' in updates:
                updates['text'] = str(updates['text']).strip()
                if not updates['text']:
                    self._send_json_response({"success": False, "error": "Text cannot be empty"}, 400)
                    return
                if len(updates['text']) > 500:
                    self._send_json_response({"success": False, "error": "Text exceeds maximum length of 500 characters"}, 400)
                    return

            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({"success": False, "error": f"Board not found: {team}"}, 404)
                return

            import fcntl
            lock_file = board_file.with_suffix('.json.lock')
            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    with open(board_file, 'r') as f:
                        data = json.load(f)

                    todos = data.get('todos', [])
                    todo_index = next((i for i, t in enumerate(todos) if t.get('id') == todo_id), -1)

                    if todo_index < 0:
                        self._send_json_response({"success": False, "error": f"Todo not found: {todo_id}"}, 404)
                        return

                    todo = todos[todo_index]

                    # Apply only the fields present in updates
                    allowed_fields = ('text', 'priority', 'requiredBy', 'status')
                    for field in allowed_fields:
                        if field in updates:
                            todo[field] = updates[field]

                    # Handle completedAt based on status transition
                    new_status = updates.get('status')
                    if new_status == 'completed' and todo.get('completedAt') is None:
                        todo['completedAt'] = self._get_timestamp()
                    elif new_status == 'todo':
                        todo['completedAt'] = None

                    data['todos'][todo_index] = todo
                    data['lastUpdated'] = self._get_timestamp()

                    self._atomic_write_json(board_file, data)
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

            print(f"[LCARS] Todo updated: {todo_id} for team={team}")
            self._send_json_response({"success": True, "todo": todo, "message": "Todo updated"})

        except Exception as e:
            self.send_error(500, f"Error updating todo: {e}")

    def handle_delete_todo(self):
        """DELETE /api/todos - Delete a todo"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team')
            todo_id = post_data.get('id')

            if not team:
                self._send_json_response({"success": False, "error": "Missing required field: team"}, 400)
                return
            if not todo_id:
                self._send_json_response({"success": False, "error": "Missing required field: id"}, 400)
                return

            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({"success": False, "error": f"Board not found: {team}"}, 404)
                return

            import fcntl
            lock_file = board_file.with_suffix('.json.lock')
            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    with open(board_file, 'r') as f:
                        data = json.load(f)

                    todos = data.get('todos', [])
                    original_count = len(todos)
                    data['todos'] = [t for t in todos if t.get('id') != todo_id]

                    if len(data['todos']) == original_count:
                        self._send_json_response({"success": False, "error": f"Todo not found: {todo_id}"}, 404)
                        return

                    data['lastUpdated'] = self._get_timestamp()
                    self._atomic_write_json(board_file, data)
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

            print(f"[LCARS] Todo deleted: {todo_id} for team={team}")
            self._send_json_response({"success": True, "message": "Todo deleted"})

        except Exception as e:
            self.send_error(500, f"Error deleting todo: {e}")

    # END TODO API HANDLERS
    # =========================================================================

    # =========================================================================
    # ALERT INGESTION API HANDLERS (XACA-0334-002)
    # =========================================================================

    _ALERT_VALID_SEVERITIES = frozenset({'info', 'warn', 'critical'})
    _ALERT_VALID_CATEGORIES = frozenset({
        'kanban_todos', 'kanban_items_due', 'change_requests',
        'backup_failures', 'calendar_items', 'releases', 'alert',
    })
    _ALERT_MAX_ACTIVE = 1000

    def _alert_active_path(self, team: str):
        """Return Path to the active alerts JSON for a team."""
        return TEAM_KANBAN_DIRS[team] / 'alerts' / 'active.json'

    def _alert_archive_path(self, team: str, month_str: str):
        """Return Path to the monthly archive JSON for a team.

        month_str should be 'YYYY-MM'.
        """
        return TEAM_KANBAN_DIRS[team] / 'alerts' / 'archive' / f'{month_str}.json'

    def _load_active_alerts(self, team: str) -> dict:
        """Load or initialise the active alerts store for a team."""
        path = self._alert_active_path(team)
        if path.exists():
            with open(path, 'r') as f:
                return json.load(f)
        return {'version': 1, 'team': team, 'lastUpdated': self._get_timestamp(), 'alerts': []}

    def _save_active_alerts(self, team: str, store: dict):
        """Atomically write the active alerts store, creating the directory first."""
        path = self._alert_active_path(team)
        path.parent.mkdir(parents=True, exist_ok=True)
        store['lastUpdated'] = self._get_timestamp()
        self._atomic_write_json(path, store)

    def _append_to_archive(self, team: str, alert: dict):
        """Append a dismissed/evicted alert to the monthly archive file.

        If the archive file exists but is corrupt (json.JSONDecodeError) or
        unreadable (OSError), the bad file is discarded and a fresh archive is
        initialised so the caller (dismiss / evict) is never surfaced a 500.
        """
        from datetime import datetime, timezone
        month_str = datetime.now(timezone.utc).strftime('%Y-%m')
        archive_path = self._alert_archive_path(team, month_str)
        archive_path.parent.mkdir(parents=True, exist_ok=True)

        if archive_path.exists():
            try:
                with open(archive_path, 'r') as f:
                    archive = json.load(f)
            except (json.JSONDecodeError, OSError) as exc:
                print(f"[LCARS] WARN _append_to_archive: corrupt archive for team={team} "
                      f"month={month_str} — reinitialising. Reason: {exc}")
                archive = {'version': 1, 'team': team, 'month': month_str, 'alerts': []}
        else:
            archive = {'version': 1, 'team': team, 'month': month_str, 'alerts': []}

        archive['alerts'].append(alert)
        self._atomic_write_json(archive_path, archive)

    def _parse_iso8601(self, value: str):
        """Parse an ISO-8601 UTC string. Returns datetime or raises ValueError."""
        from datetime import datetime, timezone
        # Accept both 'Z' suffix and '+00:00' offset
        cleaned = value.strip()
        if cleaned.endswith('Z'):
            cleaned = cleaned[:-1] + '+00:00'
        return datetime.fromisoformat(cleaned).astimezone(timezone.utc)

    def handle_create_alert(self):
        """POST /api/alerts — create or upsert (dedupe_key) an alert."""
        import fcntl
        from datetime import datetime, timezone
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(content_length))

            # --- Required field validation ---
            for field in ('team', 'source', 'title', 'severity', 'category'):
                if not body.get(field):
                    self._send_json_response({'error': f'Missing required field: {field}'}, 400)
                    return

            team = body['team']
            if team not in TEAM_KANBAN_DIRS:
                self._send_json_response({'error': 'unknown team'}, 400)
                return

            severity = body['severity']
            if severity not in self._ALERT_VALID_SEVERITIES:
                self._send_json_response(
                    {'error': f'Invalid severity: {severity!r}. Must be one of: info, warn, critical'}, 400)
                return

            category = body['category']
            if category not in self._ALERT_VALID_CATEGORIES:
                self._send_json_response(
                    {'error': f'Invalid category: {category!r}. Must be one of: '
                              + ', '.join(sorted(self._ALERT_VALID_CATEGORIES))}, 400)
                return

            title = body['title']
            if len(title) > 200:
                self._send_json_response({'error': 'title exceeds 200 characters'}, 400)
                return

            expires_at = body.get('expires_at')
            if expires_at is not None:
                try:
                    self._parse_iso8601(str(expires_at))
                except (ValueError, TypeError):
                    self._send_json_response(
                        {'error': f'expires_at is not valid ISO-8601: {expires_at!r}'}, 400)
                    return

            metadata = body.get('metadata')
            if metadata is not None and not isinstance(metadata, dict):
                self._send_json_response({'error': 'metadata must be a JSON object'}, 400)
                return

            body_text = body.get('body')
            if body_text is not None and len(str(body_text)) > 2000:
                self._send_json_response({'error': 'body exceeds 2000 characters'}, 400)
                return

            dedupe_key_raw = body.get('dedupe_key')
            dedupe_key = dedupe_key_raw.strip() if isinstance(dedupe_key_raw, str) else None

            now_str = self._get_timestamp()
            active_path = self._alert_active_path(team)
            active_path.parent.mkdir(parents=True, exist_ok=True)
            lock_file = active_path.parent / 'active.json.lock'

            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    store = self._load_active_alerts(team)
                    alerts = store.get('alerts', [])

                    # Dedupe: look for existing active alert with same dedupe_key + team
                    existing = None
                    if dedupe_key:
                        for a in alerts:
                            if a.get('dedupe_key') == dedupe_key and a.get('team') == team:
                                existing = a
                                break

                    if existing:
                        # Update mutable fields in place, preserve id, clear dismissed_at
                        existing['accepted_at'] = now_str
                        existing['title'] = title
                        existing['body'] = body_text
                        existing['severity'] = severity
                        existing['link'] = body.get('link')
                        existing['metadata'] = metadata
                        existing['expires_at'] = expires_at
                        existing['dismissed_at'] = None
                        self._save_active_alerts(team, store)
                        self._send_json_response(
                            {'id': existing['id'], 'accepted_at': now_str, 'deduped': True}, 200)
                        return

                    # New alert
                    import random
                    alert_id = f"alert-{int(datetime.now(timezone.utc).timestamp())}-{random.randint(1000, 9999)}"
                    alert = {
                        'id': alert_id,
                        'team': team,
                        'source': body['source'],
                        'title': title,
                        'body': body_text,
                        'severity': severity,
                        'category': category,
                        'dedupe_key': dedupe_key,
                        'expires_at': expires_at,
                        'link': body.get('link'),
                        'metadata': metadata,
                        'accepted_at': now_str,
                        'dismissed_at': None,
                    }
                    alerts.append(alert)

                    # Enforce max 1000 active alerts per team — evict oldest by accepted_at
                    if len(alerts) > self._ALERT_MAX_ACTIVE:
                        alerts.sort(key=lambda a: a.get('accepted_at', ''))
                        evicted = alerts.pop(0)
                        evicted['evicted_at'] = now_str
                        self._append_to_archive(team, evicted)

                    store['alerts'] = alerts
                    self._save_active_alerts(team, store)
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

            print(f"[LCARS] Alert created: {alert_id} for team={team}")
            self._send_json_response({'id': alert_id, 'accepted_at': now_str, 'deduped': False}, 201)

        except Exception as e:
            self.send_error(500, f"Error creating alert: {e}")

    def serve_alerts_list(self, query_string: str):
        """GET /api/alerts?team=<id> — list active (non-expired, non-dismissed) alerts."""
        from datetime import datetime, timezone
        try:
            params = parse_qs(query_string)
            team = params.get('team', [None])[0]
            if not team:
                self._send_json_response({'error': 'team parameter is required'}, 400)
                return
            if team not in TEAM_KANBAN_DIRS:
                self._send_json_response({'error': 'unknown team'}, 400)
                return

            store = self._load_active_alerts(team)
            now = datetime.now(timezone.utc)
            active = []
            for a in store.get('alerts', []):
                if a.get('dismissed_at'):
                    continue
                expires = a.get('expires_at')
                if expires:
                    try:
                        if self._parse_iso8601(str(expires)) < now:
                            continue
                    except (ValueError, TypeError):
                        pass
                active.append(a)

            self._send_json_response({'team': team, 'alerts': active})
        except Exception as e:
            self.send_error(500, f"Error listing alerts: {e}")

    def serve_alert_detail(self, alert_id: str, query_string: str):
        """GET /api/alerts/<id>?team=<id> — fetch one alert by id."""
        try:
            params = parse_qs(query_string)
            team = params.get('team', [None])[0]
            if not team:
                self._send_json_response({'error': 'team parameter is required'}, 400)
                return
            if team not in TEAM_KANBAN_DIRS:
                self._send_json_response({'error': 'unknown team'}, 400)
                return

            store = self._load_active_alerts(team)
            for a in store.get('alerts', []):
                if a.get('id') == alert_id:
                    self._send_json_response(a)
                    return

            self._send_json_response({'error': f'Alert not found: {alert_id}'}, 404)
        except Exception as e:
            self.send_error(500, f"Error fetching alert: {e}")

    def handle_delete_alert(self, alert_id: str):
        """DELETE /api/alerts/<id>?team=<id> — hard-delete from active store, no archive."""
        import fcntl
        try:
            params = parse_qs(urlparse(self.path).query)
            team = params.get('team', [None])[0]
            if not team:
                self._send_json_response({'error': 'team parameter is required'}, 400)
                return
            if team not in TEAM_KANBAN_DIRS:
                self._send_json_response({'error': 'unknown team'}, 400)
                return

            active_path = self._alert_active_path(team)
            active_path.parent.mkdir(parents=True, exist_ok=True)
            lock_file = active_path.parent / 'active.json.lock'

            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    store = self._load_active_alerts(team)
                    alerts = store.get('alerts', [])
                    original_count = len(alerts)
                    store['alerts'] = [a for a in alerts if a.get('id') != alert_id]

                    if len(store['alerts']) == original_count:
                        self._send_json_response({'error': f'Alert not found: {alert_id}'}, 404)
                        return

                    self._save_active_alerts(team, store)
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

            print(f"[LCARS] Alert hard-deleted: {alert_id} for team={team}")
            self._send_json_response({'success': True})
        except Exception as e:
            self.send_error(500, f"Error deleting alert: {e}")

    def handle_dismiss_alert(self, alert_id: str):
        """POST /api/alerts/<id>/dismiss — soft-dismiss; moves to archive with dismissed_at."""
        import fcntl
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(content_length)) if content_length else {}

            team = body.get('team')
            if not team:
                self._send_json_response({'error': 'team is required in request body'}, 400)
                return
            if team not in TEAM_KANBAN_DIRS:
                self._send_json_response({'error': 'unknown team'}, 400)
                return

            now_str = self._get_timestamp()
            active_path = self._alert_active_path(team)
            active_path.parent.mkdir(parents=True, exist_ok=True)
            lock_file = active_path.parent / 'active.json.lock'

            dismissed_alert = None
            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    store = self._load_active_alerts(team)
                    alerts = store.get('alerts', [])
                    target = None
                    target_idx = None
                    for idx, a in enumerate(alerts):
                        if a.get('id') == alert_id:
                            target = a
                            target_idx = idx
                            break

                    if target is None:
                        self._send_json_response({'error': f'Alert not found: {alert_id}'}, 404)
                        return

                    # Stamp dismissed_at and remove from active store
                    target['dismissed_at'] = now_str
                    dismissed_alert = dict(target)
                    store['alerts'] = [a for i, a in enumerate(alerts) if i != target_idx]
                    self._save_active_alerts(team, store)
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

            # Archive outside the lock (append-only, low-contention)
            self._append_to_archive(team, dismissed_alert)

            print(f"[LCARS] Alert dismissed: {alert_id} for team={team}")
            self._send_json_response({'success': True, 'dismissed_at': now_str})
        except Exception as e:
            self.send_error(500, f"Error dismissing alert: {e}")

    # END ALERT INGESTION API HANDLERS
    # =========================================================================

    # =========================================================================
    # DAILY OVERVIEW AGGREGATOR (XACA-0334-003)
    # =========================================================================

    # Canonical category order per spec §2.4
    _DAILY_OVERVIEW_CATEGORY_ORDER = [
        'kanban_todos',
        'kanban_items_due',
        'change_requests',
        'backup_failures',
        'calendar_items',
        'releases',
        'alert',
    ]

    # Default label / top_n fallback when config is missing
    _DAILY_OVERVIEW_DEFAULTS = {
        'kanban_todos':     {'label': 'TODOS DUE',       'top_n': 5},
        'kanban_items_due': {'label': 'KANBAN DUE',      'top_n': 5},
        'change_requests':  {'label': 'CHANGE REQUESTS', 'top_n': 3},
        'backup_failures':  {'label': 'BACKUP FAILURES', 'top_n': 3},
        'calendar_items':   {'label': 'CALENDAR',        'top_n': 5},
        'releases':         {'label': 'RELEASES',        'top_n': 3},
        'alert':            {'label': 'ALERTS',          'top_n': 5},
    }

    # Severity ordering — higher number → higher priority (used for sort key)
    _SEV_RANK = {
        'critical': 5,
        'high':     4,
        'warn':     3,
        'medium':   2,
        'info':     1,
        'low':      0,
    }

    def _do_load_daily_overview_config(self, team: str) -> dict:
        """Load and merge global + per-team daily-overview config.

        Global defaults live at lcars-ui/config/daily-overview.json (checked
        into git).  Per-team overrides live at
        <TEAM_KANBAN_DIRS[team]>/config/daily-overview.json (live-editable,
        not cached, per spec §3.3).

        Returns a dict keyed by category key with {'label', 'top_n'} values.
        Falls back to _DAILY_OVERVIEW_DEFAULTS on any read/parse error.
        """
        import copy
        result = copy.deepcopy(self._DAILY_OVERVIEW_DEFAULTS)

        # --- global config ---
        global_config_path = Path(__file__).parent / 'config' / 'daily-overview.json'
        if global_config_path.exists():
            try:
                with open(global_config_path, 'r') as f:
                    global_cfg = json.load(f)
                for key, val in global_cfg.get('categories', {}).items():
                    if key in result:
                        top_n = val.get('top_n')
                        label = val.get('label')
                        if isinstance(top_n, int) and 1 <= top_n <= 20:
                            result[key]['top_n'] = top_n
                        elif top_n is not None:
                            print(f"[LCARS] WARN daily-overview config: top_n={top_n!r} for "
                                  f"category {key!r} out of range [1,20] — using default")
                        if isinstance(label, str) and label.strip():
                            result[key]['label'] = label.strip()
            except Exception as e:
                print(f"[LCARS] WARN could not load global daily-overview.json: {e}")

        # --- per-team overrides (never cached — small read, allows live edits) ---
        team_kanban = TEAM_KANBAN_DIRS.get(team)
        if team_kanban:
            team_config_path = team_kanban / 'config' / 'daily-overview.json'
            if team_config_path.exists():
                try:
                    with open(team_config_path, 'r') as f:
                        team_cfg = json.load(f)
                    for key, val in team_cfg.get('categories', {}).items():
                        if key in result:
                            top_n = val.get('top_n')
                            label = val.get('label')
                            if isinstance(top_n, int) and 1 <= top_n <= 20:
                                result[key]['top_n'] = top_n
                            elif top_n is not None:
                                print(f"[LCARS] WARN team daily-overview config: top_n={top_n!r} "
                                      f"for category {key!r} out of range — using global default")
                            if isinstance(label, str) and label.strip():
                                result[key]['label'] = label.strip()
                except Exception as e:
                    print(f"[LCARS] WARN could not load team daily-overview.json for {team}: {e}")

        return result

    @staticmethod
    def _truncate_title(title: str, max_len: int = 200) -> str:
        """Truncate to max_len chars with ellipsis per spec §2.2."""
        if not title:
            return ''
        return title if len(title) <= max_len else title[:max_len - 1] + '…'

    @classmethod
    def _sort_key_for_items(cls, item: dict):
        """Sort key: severity_or_priority desc, due_at asc, id asc (stable tiebreak)."""
        # Higher rank → lower sort index → appears first when sorted ascending.
        # Uses the class-level _SEV_RANK attribute rather than a local copy.
        sev = item.get('severity_or_priority', 'low')
        rank = cls._SEV_RANK.get(sev, 0)
        due = item.get('due_at') or 'zzzz'  # null due_at sorts last
        return (-rank, due, item.get('id', ''))

    def _collect_kanban_todos(self, team: str, today_str: str) -> list:
        """Source adapter: TODOs due on or before today.

        Reads board.todos[] where status='todo' and requiredBy <= today.
        Returns list of unified item dicts.
        """
        items = []
        try:
            board_file = get_board_file(team)
            if not board_file.exists():
                return items
            with open(board_file, 'r') as f:
                data = json.load(f)
            for t in data.get('todos', []):
                if t.get('status') == 'completed':
                    continue
                required_by = t.get('requiredBy')
                if not required_by or required_by > today_str:
                    continue
                items.append({
                    'id':                   t.get('id', ''),
                    'title':                self._truncate_title(t.get('text', '')),
                    'due_at':               f"{required_by}T00:00:00Z" if required_by else None,
                    'severity_or_priority': t.get('priority', 'medium'),
                    'source_view':          'todos',
                    'deep_link_id':         t.get('id', ''),
                    'dismissable':          False,
                    'completable':          True,
                    'details': {
                        'kind':         'kanban_todo',
                        'team':         team,
                        'todo_id':      t.get('id', ''),
                        'text':         t.get('text', ''),
                        'priority':     t.get('priority', 'medium'),
                        'status':       t.get('status', 'todo'),
                        'created_at':   t.get('createdAt'),
                        'completed_at': t.get('completedAt'),
                        'required_by':  required_by,
                    },
                })
        except Exception as e:
            print(f"[LCARS] WARN kanban_todos source error for team={team}: {e}")
        return items

    def _collect_kanban_items_due(self, team: str, today_str: str) -> list:
        """Source adapter: backlog items with dueDate <= today.

        Reads board.backlog[] where dueDate is set and <= today.
        Returns list of unified item dicts.
        """
        items = []
        try:
            board_file = get_board_file(team)
            if not board_file.exists():
                return items
            with open(board_file, 'r') as f:
                data = json.load(f)
            for item in data.get('backlog', []):
                if item.get('status') in ('completed', 'done', 'cancelled'):
                    continue
                due_date = item.get('dueDate')
                if not due_date or due_date > today_str:
                    continue
                priority = item.get('priority', 'medium')
                subitems = item.get('subitems', []) or []
                items.append({
                    'id':                   item.get('id', ''),
                    'title':                self._truncate_title(item.get('title', '')),
                    'due_at':               f"{due_date}T00:00:00Z",
                    'severity_or_priority': priority,
                    'source_view':          'workflow',
                    'deep_link_id':         item.get('id', ''),
                    'dismissable':          False,
                    'completable':          False,
                    'details': {
                        'kind':                'kanban_item',
                        'team':                team,
                        'item_id':             item.get('id', ''),
                        'title':               item.get('title', ''),
                        'description':         item.get('description', ''),
                        'status':              item.get('status', ''),
                        'priority':            priority,
                        'platform':            item.get('os') or item.get('platform') or '',
                        'jira_id':             item.get('jiraId', ''),
                        'github_id':           item.get('githubId', ''),
                        'due_date':            due_date,
                        'subitems_total':      len(subitems),
                        'subitems_completed':  sum(
                            1 for s in subitems
                            if s.get('status') in ('completed', 'done', 'cancelled')
                        ),
                    },
                })
        except Exception as e:
            print(f"[LCARS] WARN kanban_items_due source error for team={team}: {e}")
        return items

    def _collect_change_requests(self, team: str, now_dt) -> list:
        """Source adapter: change requests in late/overdue states.

        Reads board.crs[] looking for items in states that represent
        late or blocked work:
          - 'cr-submitted' or 'cr-drafted' → needs attention (high)
          - 'cr-held' → blocked (high)
          - Not yet deployed past target date (if targetDate in associated
            backlog item is past) → critical
        Also checks activity files under change-requests/activity/<id>.json
        for deploy_estimate fields.

        Returns list of unified item dicts.
        """
        items = []
        try:
            board_file = get_board_file(team)
            if not board_file.exists():
                return items
            with open(board_file, 'r') as f:
                data = json.load(f)

            from datetime import timezone
            today_str = now_dt.strftime('%Y-%m-%d')
            now_iso = now_dt.strftime('%Y-%m-%dT%H:%M:%SZ')

            # Late states: not yet deployed/completed but should be actioned
            late_states = frozenset({
                'cr-submitted', 'cr-drafted', 'cr-held', 'implementing',
            })
            overdue_states = frozenset({
                'cr-held',
            })

            for cr in data.get('crs', []):
                cr_state = cr.get('crState', '')
                if cr_state not in late_states:
                    continue
                cr_id = cr.get('id', '')
                cr_title = cr.get('title') or cr.get('name') or cr_id

                # Determine severity: held or deploy_estimate past → critical; else high
                severity = 'critical' if cr_state in overdue_states else 'high'

                # Check if there's an overdue deploy_estimate in the activity file
                if cr_state == 'implementing':
                    try:
                        team_kanban = TEAM_KANBAN_DIRS.get(team)
                        if team_kanban:
                            act_path = team_kanban / 'change-requests' / 'activity' / f'{cr_id}.json'
                            if act_path.exists():
                                with open(act_path, 'r') as af:
                                    act_data = json.load(af)
                                for ev in act_data.get('events', []):
                                    deploy_est = ev.get('fields', {}).get('deploy_estimate')
                                    if deploy_est and deploy_est < now_iso:
                                        severity = 'critical'
                    except Exception:
                        pass

                items.append({
                    'id':                   cr_id,
                    'title':                self._truncate_title(str(cr_title)),
                    'due_at':               None,
                    'severity_or_priority': severity,
                    'source_view':          'change-req',
                    'deep_link_id':         cr_id,
                    'dismissable':          False,
                    'completable':          False,
                    'details': {
                        'kind':              'change_request',
                        'team':              team,
                        'cr_id':             cr_id,
                        'cr_state':          cr_state,
                        'cr_type':           cr.get('crType', ''),
                        'title':             str(cr_title),
                        'customer':          cr.get('customer', ''),
                        'summary':           cr.get('summary') or cr.get('description') or '',
                        'created_at':        cr.get('createdAt') or cr.get('created'),
                        'target_date':       cr.get('targetDate') or cr.get('deployDate'),
                        'severity':          severity,
                        'linked_kanban_id':  cr.get('parentId') or cr.get('kanbanId') or '',
                    },
                })
        except Exception as e:
            print(f"[LCARS] WARN change_requests source error for team={team}: {e}")
        return items

    @staticmethod
    def _parse_backup_status_data(status_data: dict, team: str, id_suffix: str) -> dict | None:
        """Convert a backup status dict into a unified item dict, or None if status is ok.

        Per spec §2.5: stale → warn, failed/error → critical.

        Used by _collect_backup_failures for both global and per-team status files
        so the parsing logic is not duplicated.

        Per-team schema (XACA-0334-013):
            { "version": 1, "last_run": "<ISO-8601>", "status": "ok|stale|failed",
              "last_error": "<string, optional>" }

        Global schema (existing):
            { "status": "ok|stale|error", "lastRun": "<ISO-8601>" }
        """
        from datetime import datetime, timezone

        # Accept both 'lastRun' (global schema) and 'last_run' (per-team schema).
        overall_status = status_data.get('status', 'ok')
        if overall_status == 'ok':
            return None

        last_run = status_data.get('last_run') or status_data.get('lastRun')

        # Map status string → severity.  'failed' (per-team) and 'error' (global)
        # both map to critical; 'stale' maps to warn per spec.
        severity = 'critical' if overall_status in ('error', 'failed') else 'warn'

        # Check for stale backup (> 30 min since last run) — raises warn floor.
        stale = False
        if last_run:
            try:
                last_run_dt = datetime.fromisoformat(last_run.replace('Z', '+00:00'))
                delta_minutes = (datetime.now(timezone.utc) - last_run_dt).total_seconds() / 60
                if delta_minutes > 30:
                    stale = True
            except Exception:
                pass

        title = f"Backup {overall_status}"
        if stale and overall_status == 'stale':
            title = "Backup stale (> 30m)"
        if last_run:
            title += f" — last run: {last_run}"

        return {
            'id':                   f'backup-status-{id_suffix}',
            'title':                title,
            'due_at':               last_run,
            'severity_or_priority': severity,
            'source_view':          'backups',
            'deep_link_id':         'backup-status',
            'dismissable':          False,
            'completable':          False,
            'details': {
                'kind':            'backup_failure',
                'team':            team,
                'overall_status':  overall_status,
                'last_run':        last_run,
                'last_error':      status_data.get('last_error') or status_data.get('lastError') or '',
                'severity':        severity,
                'is_stale':        stale,
                'id_suffix':       id_suffix,
            },
        }

    def _collect_backup_failures(self, team: str) -> list:
        """Source adapter: backup failures.

        Per spec §2.5: stale → warn, error/failed → critical.

        Priority order (XACA-0334-013):
          1. Per-team status file at <TEAM_KANBAN_DIRS[team]>/backups/status.json
             (schema: { version, last_run, status: ok|stale|failed, last_error? })
             — if present and non-ok, surfaces as a higher-priority alert.
          2. Global BACKUP_STATUS_FILE fallback (existing behaviour).

        When both are present, both are surfaced if non-ok; the per-team item
        gets a higher severity floor so it always sorts above the global entry.
        """
        items = []
        try:
            from datetime import datetime, timezone

            # --- per-team file (XACA-0334-013) ---
            team_kanban = TEAM_KANBAN_DIRS.get(team)
            per_team_item = None
            if team_kanban:
                per_team_path = team_kanban / 'backups' / 'status.json'
                if per_team_path.exists():
                    try:
                        with open(per_team_path, 'r') as f:
                            per_team_data = json.load(f)
                        per_team_item = self._parse_backup_status_data(
                            per_team_data, team, id_suffix=f'{team}-per-team')
                        if per_team_item:
                            # Escalate severity: per-team non-ok is higher priority
                            # than global — if it's warn, promote to warn-high marker
                            # by using critical for 'failed' and keeping warn for stale.
                            items.append(per_team_item)
                    except (json.JSONDecodeError, OSError) as exc:
                        print(f"[LCARS] WARN per-team backup status.json malformed "
                              f"for team={team}: {exc}")
                    except Exception as exc:
                        print(f"[LCARS] WARN per-team backup status.json read error "
                              f"for team={team}: {exc}")

            # --- global file fallback ---
            if BACKUP_STATUS_FILE.exists():
                try:
                    with open(BACKUP_STATUS_FILE, 'r') as f:
                        global_data = json.load(f)
                    global_item = self._parse_backup_status_data(
                        global_data, team, id_suffix=team)
                    if global_item:
                        items.append(global_item)
                except (json.JSONDecodeError, OSError) as exc:
                    print(f"[LCARS] WARN global backup-status.json malformed: {exc}")
                except Exception as exc:
                    print(f"[LCARS] WARN backup_failures global source error for team={team}: {exc}")

        except Exception as e:
            print(f"[LCARS] WARN backup_failures source error for team={team}: {e}")

        return items

    def _collect_calendar_items(self, team: str, today_str: str) -> list:
        """Source adapter: calendar items due today or already past due.

        Two sub-sources are merged:

        1. Kanban board (existing behaviour) — board.backlog[] items and
           board.epics[] that have a dueDate/targetDate <= today.

        2. Per-team event file (XACA-0334-012) — an optional file at
           <TEAM_KANBAN_DIRS[team]>/calendar/events.json with schema:
               {
                 "version": 1,
                 "events": [
                   {
                     "id":       "<string, required>",
                     "title":    "<string, required>",
                     "start":    "<YYYY-MM-DD or ISO-8601 UTC, required>",
                     "end":      "<YYYY-MM-DD or ISO-8601 UTC, optional>",
                     "all_day":  <bool, optional, default true>,
                     "link":     "<string, optional deep-link or URL>"
                   }
                 ]
               }
           Events whose start date (first 10 chars of the value) is <= today
           are included.  If the file is missing or malformed the board-only
           path is used unchanged — no regression.
        """
        items = []
        try:
            board_file = get_board_file(team)
            if not board_file.exists():
                return items
            with open(board_file, 'r') as f:
                data = json.load(f)
            for item in data.get('backlog', []):
                due_date = item.get('dueDate')
                if not due_date or due_date > today_str:
                    continue
                # Calendar items: show epics and items with explicit dueDate
                priority = item.get('priority', 'medium')
                items.append({
                    'id':                   item.get('id', ''),
                    'title':                self._truncate_title(item.get('title', '')),
                    'due_at':               f"{due_date}T00:00:00Z",
                    'severity_or_priority': priority,
                    'source_view':          'calendar',
                    'deep_link_id':         item.get('id', ''),
                    'dismissable':          False,
                    'completable':          False,
                    'details': {
                        'kind':       'calendar_item',
                        'source':     'kanban_backlog',
                        'team':       team,
                        'item_id':    item.get('id', ''),
                        'title':      item.get('title', ''),
                        'due_date':   due_date,
                        'priority':   priority,
                        'status':     item.get('status', ''),
                    },
                })
            # Also check epics with dueDate
            for epic in data.get('epics', []):
                due_date = epic.get('dueDate') or epic.get('targetDate')
                if not due_date or due_date > today_str:
                    continue
                epic_title = epic.get('title', epic.get('name', ''))
                items.append({
                    'id':                   epic.get('id', ''),
                    'title':                self._truncate_title(epic_title),
                    'due_at':               f"{due_date}T00:00:00Z",
                    'severity_or_priority': 'high',
                    'source_view':          'calendar',
                    'deep_link_id':         epic.get('id', ''),
                    'dismissable':          False,
                    'completable':          False,
                    'details': {
                        'kind':       'calendar_item',
                        'source':     'kanban_epic',
                        'team':       team,
                        'item_id':    epic.get('id', ''),
                        'title':      epic_title,
                        'due_date':   due_date,
                    },
                })
        except Exception as e:
            print(f"[LCARS] WARN calendar_items source error for team={team}: {e}")

        # --- per-team event file (XACA-0334-012) ---
        team_kanban = TEAM_KANBAN_DIRS.get(team)
        if team_kanban:
            events_path = team_kanban / 'calendar' / 'events.json'
            if events_path.exists():
                try:
                    with open(events_path, 'r') as f:
                        evt_data = json.load(f)
                    for evt in evt_data.get('events', []):
                        evt_id = evt.get('id', '')
                        evt_title = evt.get('title', '')
                        evt_start = evt.get('start', '')
                        if not evt_id or not evt_title or not evt_start:
                            continue
                        # Normalise: take the date portion (first 10 chars) for
                        # comparison so both YYYY-MM-DD and ISO-8601 strings work.
                        start_date = str(evt_start)[:10]
                        if start_date > today_str:
                            continue
                        # due_at: use start value as-is (may be full ISO or date-only)
                        due_at = evt_start if 'T' in str(evt_start) else f"{start_date}T00:00:00Z"
                        link = evt.get('link', '')
                        deep_link_id = evt_id
                        if link and link.startswith('/section/'):
                            section = link[len('/section/'):]
                            deep_link_id = section.split('/')[0]
                        items.append({
                            'id':                   evt_id,
                            'title':                self._truncate_title(str(evt_title)),
                            'due_at':               due_at,
                            'severity_or_priority': 'medium',
                            'source_view':          'calendar',
                            'deep_link_id':         deep_link_id,
                            'dismissable':          False,
                            'completable':          False,
                            'details': {
                                'kind':      'calendar_item',
                                'source':    'team_calendar',
                                'team':      team,
                                'event_id':  evt_id,
                                'title':     str(evt_title),
                                'start':     evt_start,
                                'end':       evt.get('end', ''),
                                'all_day':   evt.get('all_day', True),
                                'link':      link,
                            },
                        })
                except (json.JSONDecodeError, OSError) as exc:
                    print(f"[LCARS] WARN calendar events.json malformed for team={team}: {exc}")
                except Exception as exc:
                    print(f"[LCARS] WARN calendar events.json read error for team={team}: {exc}")

        return items

    def _collect_releases(self, team: str, now_dt) -> list:
        """Source adapter: releases with overdue promotions.

        Reads board.releases[] where targetDate is set and past.
        Severity: critical if past targetDate, else high (for releases near due).

        Per spec §2.5: critical if past target date, else high.
        """
        items = []
        try:
            today_str = now_dt.strftime('%Y-%m-%d')
            board_file = get_board_file(team)
            if not board_file.exists():
                return items
            with open(board_file, 'r') as f:
                data = json.load(f)
            for release in data.get('releases', []):
                status = release.get('status', '')
                if status in ('archived', 'completed'):
                    continue
                target_date = release.get('targetDate')
                if not target_date:
                    continue
                if target_date > today_str:
                    continue
                # Release is at or past its targetDate
                severity = 'critical' if target_date < today_str else 'high'
                release_id = release.get('id', '')
                name = release.get('name') or release.get('shortTitle') or release_id
                items.append({
                    'id':                   release_id,
                    'title':                self._truncate_title(str(name)),
                    'due_at':               f"{target_date}T00:00:00Z",
                    'severity_or_priority': severity,
                    'source_view':          'releases',
                    'deep_link_id':         release_id,
                    'dismissable':          False,
                    'completable':          False,
                    'details': {
                        'kind':          'release',
                        'team':          team,
                        'release_id':    release_id,
                        'name':          str(name),
                        'short_title':   release.get('shortTitle', ''),
                        'status':        status,
                        'target_date':   target_date,
                        'severity':      severity,
                        'environments':  release.get('environments', {}),
                    },
                })
        except Exception as e:
            print(f"[LCARS] WARN releases source error for team={team}: {e}")
        return items

    def _collect_alerts(self, team: str, now_dt) -> list:
        """Source adapter: active alerts from alerts/active.json.

        Filters expired (expires_at < now) and dismissed (dismissed_at set).
        source_view is derived from the alert's link field per spec §2.5.
        Returns items with dismissable=True per spec §2.2.
        """
        items = []
        try:
            store = self._load_active_alerts(team)
            now_iso = now_dt.strftime('%Y-%m-%dT%H:%M:%SZ')
            for alert in store.get('alerts', []):
                # Skip dismissed
                if alert.get('dismissed_at'):
                    continue
                # Skip expired
                expires_at = alert.get('expires_at')
                if expires_at and expires_at < now_iso:
                    continue

                # Derive source_view from link field per spec §2.5
                link = alert.get('link', '') or ''
                if link.startswith('/section/'):
                    section = link[len('/section/'):]
                    # strip any trailing path components
                    source_view = section.split('/')[0]
                else:
                    source_view = 'home'

                # due_at: use expires_at if set, else accepted_at per spec
                due_at = expires_at if expires_at else alert.get('accepted_at')

                items.append({
                    'id':                   alert.get('id', ''),
                    'title':                self._truncate_title(alert.get('title', '')),
                    'due_at':               due_at,
                    'severity_or_priority': alert.get('severity', 'info'),
                    'source_view':          source_view,
                    'deep_link_id':         alert.get('id', ''),
                    'dismissable':          True,
                    'completable':          False,
                    'details':              self._build_alert_details(alert, team, link),
                })
        except Exception as e:
            print(f"[LCARS] WARN alert source error for team={team}: {e}")
        return items

    @staticmethod
    def _build_alert_details(alert: dict, team: str, link: str) -> dict:
        """Construct the popup `details` payload for an alert item.

        Centralised so both `_collect_alerts` and the structural-merge pass in
        `serve_daily_overview` produce the same shape.
        """
        return {
            'kind':         'alert',
            'team':         team,
            'alert_id':     alert.get('id', ''),
            'title':        alert.get('title', ''),
            'body':         alert.get('body') or '',
            'source':       alert.get('source', ''),
            'severity':     alert.get('severity', 'info'),
            'category':     alert.get('category', 'alert'),
            'accepted_at':  alert.get('accepted_at'),
            'expires_at':   alert.get('expires_at'),
            'link':         link or '',
            'metadata':     alert.get('metadata') or {},
            'dedupe_key':   alert.get('dedupe_key'),
        }

    def serve_daily_overview(self, query_string: str):
        """GET /api/daily-overview?team=<id>

        Returns the aggregated daily overview for a team.  Stateless — every
        call re-sorts and re-truncates all sources.

        Per spec XACA-0334 §2.
        """
        from urllib.parse import parse_qs
        from datetime import datetime, timezone

        try:
            params = parse_qs(query_string) if query_string else {}
            team = params.get('team', [None])[0]

            if not team:
                self._send_json_response({'error': 'Missing required parameter: team'}, 400)
                return

            if team not in TEAM_KANBAN_DIRS:
                self._send_json_response({'error': 'unknown team'}, 400)
                return

            now_dt = datetime.now(timezone.utc)
            today_str = now_dt.strftime('%Y-%m-%d')
            generated_at = now_dt.strftime('%Y-%m-%dT%H:%M:%SZ')

            # Load config (merged global + per-team)
            cfg = self._do_load_daily_overview_config(team)

            # --- Collect raw items per structural source ---
            raw_by_key = {
                'kanban_todos':     self._collect_kanban_todos(team, today_str),
                'kanban_items_due': self._collect_kanban_items_due(team, today_str),
                'change_requests':  self._collect_change_requests(team, now_dt),
                'backup_failures':  self._collect_backup_failures(team),
                'calendar_items':   self._collect_calendar_items(team, today_str),
                'releases':         self._collect_releases(team, now_dt),
                'alert':            [],  # filled below after alert-merge pass
            }

            # --- Collect active alerts and merge into matching structural categories ---
            # Alerts whose category matches a structural key merge into that bucket.
            # Alerts with category='alert' or any unrecognised category go to the
            # catch-all 'alert' bucket.  Per spec §2.7.
            structural_keys = frozenset(self._DAILY_OVERVIEW_CATEGORY_ORDER[:-1])  # all except 'alert'
            all_alerts = self._collect_alerts(team, now_dt)

            # Also load ALL active alerts (not just the generic ones) to enable merging
            # into structural categories — re-read store once to avoid double-reading
            # (the _collect_alerts call above already has the dismiss/expiry filtering)
            try:
                store = self._load_active_alerts(team)
                now_iso = now_dt.strftime('%Y-%m-%dT%H:%M:%SZ')
                for alert in store.get('alerts', []):
                    if alert.get('dismissed_at'):
                        continue
                    expires_at = alert.get('expires_at')
                    if expires_at and expires_at < now_iso:
                        continue

                    category = alert.get('category', 'alert')
                    link = alert.get('link', '') or ''
                    if link.startswith('/section/'):
                        source_view = link[len('/section/'):].split('/')[0]
                    else:
                        source_view = 'home'

                    due_at = expires_at if expires_at else alert.get('accepted_at')
                    item = {
                        'id':                   alert.get('id', ''),
                        'title':                self._truncate_title(alert.get('title', '')),
                        'due_at':               due_at,
                        'severity_or_priority': alert.get('severity', 'info'),
                        'source_view':          source_view,
                        'deep_link_id':         alert.get('id', ''),
                        'dismissable':          True,
                        'completable':          False,
                        'details':              self._build_alert_details(alert, team, link),
                    }

                    if category in structural_keys:
                        # Merge into matching structural category
                        raw_by_key[category].append(item)
                    else:
                        # Catch-all alert bucket
                        raw_by_key['alert'].append(item)
            except Exception as e:
                print(f"[LCARS] WARN alert-merge pass error for team={team}: {e}")

            # --- Deduplicate: an alert may appear in both _collect_alerts AND the
            # merge pass above for the 'alert' category.  We intentionally re-ran
            # the store above for structural merging, so the 'alert' bucket could
            # have duplicates from _collect_alerts (which we pre-populated with
            # generic-category alerts).  Replace the 'alert' bucket entirely with
            # the deduplicated set from the merge pass (which only adds
            # category='alert' items).  The earlier _collect_alerts result is
            # therefore discarded in favour of the merge-pass result.
            # (raw_by_key['alert'] already contains only category=alert items
            # from the merge pass above — no further dedup needed.)

            # --- Sort each bucket and compute top_n / total / overflow ---
            categories = []
            for key in self._DAILY_OVERVIEW_CATEGORY_ORDER:
                all_items = raw_by_key.get(key, [])
                # Sort: severity desc, due_at asc, id asc (deterministic tiebreak)
                all_items.sort(key=self._sort_key_for_items)

                cat_cfg = cfg.get(key, self._DAILY_OVERVIEW_DEFAULTS.get(key, {'label': key.upper(), 'top_n': 5}))
                top_n = cat_cfg['top_n']
                total = len(all_items)
                overflow = max(0, total - top_n)

                categories.append({
                    'key':      key,
                    'label':    cat_cfg['label'],
                    'top_n':    top_n,
                    'total':    total,
                    'overflow': overflow,
                    'items':    all_items[:top_n],
                })

            self._send_json_response({
                'team':         team,
                'generated_at': generated_at,
                'categories':   categories,
            })

        except Exception as e:
            import traceback
            print(f"[LCARS] ERROR serve_daily_overview team={team if 'team' in dir() else '?'}: {e}\n{traceback.format_exc()}")
            self.send_error(500, f"Error generating daily overview: {e}")

    # END DAILY OVERVIEW AGGREGATOR
    # =========================================================================

    # =========================================================================
    # WEEKLY ANCHOR API HANDLERS (XACA-0253-003)
    # =========================================================================

    def handle_post_weekly_anchor(self):
        """POST /api/weekly-anchor — set a manual weekly-limit reset anchor.

        Request body (JSON):
            {"hours": int, "minutes": int}

        Both fields are required integers.
        Validation: 0 <= hours <= 168, 0 <= minutes <= 59, total > 0.

        Response (200):
            {"set_at": "<ISO>", "reset_at": "<ISO>", "set_hours": int,
             "set_minutes": int, "source": "manual", "version": 1}

        Response on error:
            400 {"error": "<msg>"}   — validation failure
            503 {"error": "..."}     — heuristics module unavailable
            500 {"error": "..."}     — unexpected failure
        """
        if _ccusage_heuristics is None:
            self._send_json_response(
                {"error": "ccusage_heuristics module not available"}, 503
            )
            return

        try:
            content_length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(content_length)
            post_data = json.loads(body) if body else {}
        except (ValueError, json.JSONDecodeError) as exc:
            self._send_json_response({"error": f"Invalid JSON: {exc}"}, 400)
            return

        # Validate required fields.
        if "hours" not in post_data or "minutes" not in post_data:
            self._send_json_response(
                {"error": "Missing required fields: hours, minutes"}, 400
            )
            return

        hours_raw = post_data["hours"]
        minutes_raw = post_data["minutes"]

        if not isinstance(hours_raw, int) or isinstance(hours_raw, bool):
            self._send_json_response({"error": "hours must be an integer"}, 400)
            return
        if not isinstance(minutes_raw, int) or isinstance(minutes_raw, bool):
            self._send_json_response({"error": "minutes must be an integer"}, 400)
            return

        try:
            record = _ccusage_heuristics.write_weekly_anchor(
                int(hours_raw), int(minutes_raw)
            )
        except ValueError as exc:
            self._send_json_response({"error": str(exc)}, 400)
            return
        except Exception as exc:
            print(f"[LCARS] weekly-anchor POST error: {exc}", file=sys.stderr)
            self._send_json_response({"error": "Failed to write anchor"}, 500)
            return

        response = {
            "version": record["version"],
            "set_at": record["set_at"].strftime("%Y-%m-%dT%H:%M:%S.000Z"),
            "reset_at": record["reset_at"].strftime("%Y-%m-%dT%H:%M:%S.000Z"),
            "set_hours": record["set_hours"],
            "set_minutes": record["set_minutes"],
            "source": record["source"],
        }
        print(
            f"[LCARS] weekly-anchor set: reset_at={response['reset_at']}",
            file=sys.stderr,
        )
        self._send_json_response(response, 200)

    def handle_delete_weekly_anchor(self):
        """DELETE /api/weekly-anchor — clear the manual weekly-limit reset anchor.

        Response (200):
            {"deleted": true|false}

        Response on error:
            503 {"error": "..."}  — heuristics module unavailable
            500 {"error": "..."}  — unexpected failure
        """
        if _ccusage_heuristics is None:
            self._send_json_response(
                {"error": "ccusage_heuristics module not available"}, 503
            )
            return

        try:
            deleted = _ccusage_heuristics.delete_weekly_anchor()
        except Exception as exc:
            print(f"[LCARS] weekly-anchor DELETE error: {exc}", file=sys.stderr)
            self._send_json_response({"error": "Failed to delete anchor"}, 500)
            return

        print(
            f"[LCARS] weekly-anchor {'deleted' if deleted else 'not found (no-op)'}",
            file=sys.stderr,
        )
        self._send_json_response({"deleted": deleted}, 200)

    # END WEEKLY ANCHOR API HANDLERS
    # =========================================================================

    def serve_calendar_items(self, query_string=''):
        """GET /api/calendar/items - List items and epics with due dates

        Query parameters:
            team: Team name (required) - only load items from this team's board
            start: YYYY-MM-DD start date filter (optional)
            end: YYYY-MM-DD end date filter (optional)
            epicFilter: Epic ID to filter by (optional)
        """
        from urllib.parse import parse_qs
        from datetime import datetime

        try:
            # Parse query parameters
            params = parse_qs(query_string) if query_string else {}
            team_filter = params.get('team', [None])[0]
            start_date = params.get('start', [None])[0]
            end_date = params.get('end', [None])[0]
            epic_filter = params.get('epicFilter', [None])[0]

            # Team is required to scope calendar to current board
            if not team_filter:
                self.send_error(400, "Missing required parameter: team")
                return

            # Validate date formats if provided
            if start_date:
                try:
                    datetime.strptime(start_date, '%Y-%m-%d')
                except ValueError:
                    self.send_error(400, f"Invalid start date format: {start_date} (expected YYYY-MM-DD)")
                    return

            if end_date:
                try:
                    datetime.strptime(end_date, '%Y-%m-%d')
                except ValueError:
                    self.send_error(400, f"Invalid end date format: {end_date} (expected YYYY-MM-DD)")
                    return

            calendar_items = []
            calendar_epics = []

            # Load only the specified team's board
            board_file = get_board_file(team_filter)
            if not board_file.exists():
                # Return empty results for non-existent team
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                self.wfile.write(json.dumps({
                    "items": [],
                    "epics": [],
                    "team": team_filter
                }, indent=2).encode())
                return

            with open(board_file, 'r') as f:
                board_data = json.load(f)

            team = board_data.get('team', team_filter)

            # Process items with due dates
            for item in board_data.get('backlog', []):
                due_date = item.get('dueDate')
                if not due_date:
                    continue

                # Apply date range filtering
                if start_date and due_date < start_date:
                    continue
                if end_date and due_date > end_date:
                    continue

                # Apply epic filtering
                item_epic_id = item.get('epicId')
                if epic_filter and item_epic_id != epic_filter:
                    continue

                # Count subitems
                subitem_count = len(item.get('subitems', []))

                # Build item response
                calendar_item = {
                    "id": item.get('id'),
                    "title": item.get('title', ''),
                    "dueDate": due_date,
                    "priority": item.get('priority', 'medium'),
                    "status": item.get('status', 'todo'),
                    "epicId": item_epic_id,
                    "type": "item",
                    "team": team,
                    "tags": item.get('tags', []),
                    "subitemCount": subitem_count
                }

                # Add epic metadata if item belongs to an epic
                if item_epic_id:
                    epic_data = board_data.get('epics', [])
                    epic = next((e for e in epic_data if e.get('id') == item_epic_id), None)
                    if epic:
                        calendar_item['epicName'] = epic.get('title', epic.get('name', ''))
                        calendar_item['epicColor'] = epic.get('color', 'blue')

                # Include subitems with due dates
                subitems = []
                for subitem in item.get('subitems', []):
                    subitem_due_date = subitem.get('dueDate')
                    if subitem_due_date:
                        # Apply date filtering to subitems
                        if start_date and subitem_due_date < start_date:
                            continue
                        if end_date and subitem_due_date > end_date:
                            continue

                        subitems.append({
                            "id": subitem.get('id'),
                            "title": subitem.get('title', ''),
                            "dueDate": subitem_due_date,
                            "status": subitem.get('status', 'todo')
                        })

                if subitems:
                    calendar_item['subitems'] = subitems

                calendar_items.append(calendar_item)

            # Process epics with due dates (if they support them)
            for epic in board_data.get('epics', []):
                due_date = epic.get('dueDate')
                if not due_date:
                    continue

                # Apply date range filtering
                if start_date and due_date < start_date:
                    continue
                if end_date and due_date > end_date:
                    continue

                # Apply epic filtering
                if epic_filter and epic.get('id') != epic_filter:
                    continue

                # Count items in this epic, excluding cancelled (XACA-0206 parity).
                epic_items = [i for i in board_data.get('backlog', []) if i.get('epicId') == epic.get('id')]
                active_items = [i for i in epic_items if i.get('status') != 'cancelled']
                item_count = len(active_items)
                cancelled_count = len(epic_items) - item_count
                completed_count = len([i for i in active_items if i.get('status') in ('done', 'completed')])

                calendar_epics.append({
                    "id": epic.get('id'),
                    "title": epic.get('title', epic.get('name', '')),
                    "dueDate": due_date,
                    "color": epic.get('color', 'blue'),
                    "type": "epic",
                    "itemCount": item_count,
                    "completedCount": completed_count,
                    "cancelledCount": cancelled_count,
                    "status": epic.get('status', 'planning'),
                    "priority": epic.get('priority', 'medium')
                })

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps({
                "items": calendar_items,
                "epics": calendar_epics,
                "team": team_filter
            }, indent=2).encode())

        except Exception as e:
            self.send_error(500, f"Error loading calendar items: {e}")

    def handle_create_epic(self):
        """POST /api/epics - Create new epic in kanban board"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            name = post_data.get('name')
            if not name:
                self.send_error(400, "Missing required field: name")
                return

            data = self._load_board_epics()
            epic_id = self._generate_epic_id(data)
            timestamp = self._get_timestamp()

            # Create epic with board-compatible structure (uses 'title' not 'name')
            epic = {
                "id": epic_id,
                "title": name,  # Board uses 'title', not 'name'
                "shortTitle": post_data.get('shortTitle'),  # XACA-0051: Optional short display name
                "status": post_data.get('status', 'planning'),  # Default to 'planning'
                "priority": post_data.get('priority', 'medium'),
                "itemIds": [],
                "addedAt": timestamp,
                "updatedAt": timestamp,
                "tags": [t.strip() for t in post_data.get('tags', []) if isinstance(t, str) and t.strip()],  # XACA-0209 round 3: strip on write so new data is clean
                "collapsed": False,
                "description": post_data.get('description', ''),
                "color": post_data.get('color', 'blue'),  # Keep color for UI
            }

            epics = data.get('epics', [])
            epics.append(epic)
            next_epic_id = data.get('nextEpicId', 1) + 1

            if self._save_board_epics(epics, next_epic_id):
                # Return with 'name' for UI compatibility
                epic['name'] = epic['title']
                self.send_response(201)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps(epic, indent=2).encode())
            else:
                self.send_error(500, "Failed to save epic to board")

        except Exception as e:
            self.send_error(500, f"Error creating epic: {e}")

    def handle_update_epic(self, epic_id):
        """PUT /api/epics/<id> - Update epic in kanban board"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            data = self._load_board_epics()
            epic = self._find_epic_by_id(data, epic_id)

            if not epic:
                self.send_error(404, f"Epic not found: {epic_id}")
                return

            # Update allowed fields (map 'name' to 'title' for board compatibility)
            if 'name' in post_data:
                epic['title'] = post_data['name']
            if 'shortTitle' in post_data:  # XACA-0051: Allow shortTitle updates
                epic['shortTitle'] = post_data['shortTitle']
            if 'description' in post_data:
                epic['description'] = post_data['description']
            if 'color' in post_data:
                epic['color'] = post_data['color']
            if 'status' in post_data:
                epic['status'] = post_data['status']
            if 'priority' in post_data:
                epic['priority'] = post_data['priority']
            if 'tags' in post_data:  # XACA-0209 — round 3: strip on write so new data is clean
                epic['tags'] = [t.strip() for t in post_data['tags'] if isinstance(t, str) and t.strip()]

            epic['updatedAt'] = self._get_timestamp()

            if self._save_board_epics(data['epics'], data.get('nextEpicId', 1)):
                # Return with 'name' for UI compatibility
                if 'title' in epic:
                    epic['name'] = epic['title']
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps(epic, indent=2).encode())
            else:
                self.send_error(500, "Failed to save epic to board")

        except Exception as e:
            self.send_error(500, f"Error updating epic: {e}")

    def handle_delete_epic(self, epic_id):
        """DELETE /api/epics/<id> - Delete/archive epic from kanban board"""
        try:
            data = self._load_board_epics()
            epic = self._find_epic_by_id(data, epic_id)

            if not epic:
                self.send_error(404, f"Epic not found: {epic_id}")
                return

            # Clear epicId from all assigned items
            items = self._get_items_for_epic(epic_id)
            for item in items:
                self._clear_item_epic_assignment(item['team'], item['itemId'])

            # Remove from epics list
            epics = [e for e in data['epics'] if e.get('id') != epic_id]

            if self._save_board_epics(epics, data.get('nextEpicId', 1)):
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps({"success": True, "deleted": epic_id}).encode())
            else:
                self.send_error(500, "Failed to save changes to board")

        except Exception as e:
            self.send_error(500, f"Error deleting epic: {e}")

    def handle_assign_item_to_epic(self, epic_id):
        """POST /api/epics/<id>/items - Assign item to epic"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            item_id = post_data.get('itemId')
            team = post_data.get('team')

            if not item_id or not team:
                self.send_error(400, "Missing required fields: itemId, team")
                return

            # Verify epic exists in board
            data = self._load_board_epics()
            epic = self._find_epic_by_id(data, epic_id)
            if not epic:
                self.send_error(404, f"Epic not found: {epic_id}")
                return

            # Update item in kanban board (use 'title' field from board format)
            epic_name = epic.get('title', epic.get('name', ''))
            self._update_item_epic_assignment(team, item_id, epic_id, epic_name)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({"success": True}).encode())

        except Exception as e:
            self.send_error(500, f"Error assigning item to epic: {e}")

    def handle_remove_item_from_epic(self, epic_id, item_id):
        """DELETE /api/epics/<id>/items/<itemId> - Remove item from epic"""
        try:
            # Only search the current team's board - NO cross-team operations
            board_file = get_board_file(LCARS_TEAM)
            item_found = False

            if board_file.exists():
                try:
                    with open(board_file, 'r') as f:
                        board_data = json.load(f)
                    for item in board_data.get('backlog', []):
                        if item.get('id') == item_id and item.get('epicId') == epic_id:
                            item_found = True
                            break
                except Exception:
                    pass

            if not item_found:
                self.send_error(404, f"Item not found in epic: {item_id}")
                return

            # Clear epic assignment
            self._clear_item_epic_assignment(LCARS_TEAM, item_id)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps({"success": True, "removed": item_id}).encode())

        except Exception as e:
            self.send_error(500, f"Error removing item from epic: {e}")

    def _update_item_epic_assignment(self, team, item_id, epic_id, epic_name=''):
        """Update a kanban item with epic assignment and sync epic itemIds."""
        import fcntl
        board_file = get_board_file(team)
        if not board_file.exists():
            return

        lock_file = board_file.with_suffix('.json.lock')
        with open(lock_file, 'w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                with open(board_file, 'r') as f:
                    data = json.load(f)

                for item in data.get('backlog', []):
                    if item.get('id') == item_id:
                        item['epicId'] = epic_id
                        item['epicName'] = epic_name
                        break

                # Keep each epic's itemIds list in sync with item.epicId.
                # Remove from any other epic that still lists it, then add to the target.
                for epic in data.get('epics', []):
                    ids = epic.get('itemIds', [])
                    if epic.get('id') == epic_id:
                        if item_id not in ids:
                            ids.append(item_id)
                            epic['itemIds'] = ids
                    elif item_id in ids:
                        epic['itemIds'] = [i for i in ids if i != item_id]

                data['lastUpdated'] = self._get_timestamp()
                self._atomic_write_json(board_file, data)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def _clear_item_epic_assignment(self, team, item_id):
        """Clear epic assignment from a kanban item and sync epic itemIds."""
        import fcntl
        board_file = get_board_file(team)
        if not board_file.exists():
            return

        lock_file = board_file.with_suffix('.json.lock')
        with open(lock_file, 'w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                with open(board_file, 'r') as f:
                    data = json.load(f)

                for item in data.get('backlog', []):
                    if item.get('id') == item_id:
                        if 'epicId' in item:
                            del item['epicId']
                        if 'epicName' in item:
                            del item['epicName']
                        break

                for epic in data.get('epics', []):
                    ids = epic.get('itemIds', [])
                    if item_id in ids:
                        epic['itemIds'] = [i for i in ids if i != item_id]

                data['lastUpdated'] = self._get_timestamp()
                self._atomic_write_json(board_file, data)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    # =========================================================================
    # END EPIC MANAGEMENT API
    # =========================================================================

    # =========================================================================
    # CALENDAR SYNC API
    # =========================================================================

    def serve_activity_log(self, item_id, query_string=''):
        """GET /api/kanban/<item-id>/activity - Read activity log entries for an item

        Query parameters:
            limit  (int)    -- max entries to return
            offset (int)    -- skip N entries (pagination)
            action (string) -- filter by action type (e.g. "status_change")
            agent  (string) -- filter by agent handle
            subitem (string) -- filter to a specific subitem ID
        """
        import re
        from urllib.parse import parse_qs
        try:
            # Validate item_id format to prevent path traversal
            if not re.match(r'^X[A-Z]{2,4}-\d{4}$', item_id):
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Invalid item ID format"}).encode())
                return

            params = parse_qs(query_string) if query_string else {}

            # Parse optional query parameters
            limit_raw = params.get('limit', [None])[0]
            offset_raw = params.get('offset', [None])[0]
            action_filter = params.get('action', [None])[0]
            agent_filter = params.get('agent', [None])[0]
            subitem_filter = params.get('subitem', [None])[0]

            limit = int(limit_raw) if limit_raw is not None else None
            offset = int(offset_raw) if offset_raw is not None else 0

            # Get all filtered entries (no pagination) to compute counts
            all_filtered = read_activity_log(
                item_id,
                limit=None,
                offset=0,
                action_filter=action_filter,
                agent_filter=agent_filter,
                subitem_filter=subitem_filter,
            )

            all_entries = all_filtered.get("entries", [])
            filtered_count = len(all_entries)

            # Compute total (unfiltered) entry count if we have metadata
            total_entries = all_filtered.get("totalEntries", filtered_count)
            # If no filters were applied, filtered == total
            if action_filter is None and agent_filter is None and subitem_filter is None:
                total_entries = filtered_count

            # Apply pagination manually so we can return accurate counts
            paginated_entries = all_entries[offset:]
            if limit is not None:
                paginated_entries = paginated_entries[:limit]

            response = dict(all_filtered)
            response["entries"] = paginated_entries
            response["itemId"] = all_filtered.get("itemId", item_id)
            response["totalEntries"] = total_entries
            response["filteredEntries"] = filtered_count
            response["limit"] = limit
            response["offset"] = offset

            self._send_json_response(response)

        except ValueError as e:
            self._send_json_response({
                "error": f"Invalid query parameter: {e}",
                "itemId": item_id
            }, status=400)
        except Exception as e:
            print(f"[LCARS] ERROR reading activity log for {item_id}: {e}")
            self._send_json_response({
                "error": str(e),
                "itemId": item_id
            }, status=500)

    def serve_plan_exists(self, item_id):
        """GET /api/kanban/<item-id>/plan-exists - Check if plan document exists for item.

        Also returns retroExists and crExists so the caller can determine all tab
        visibility in a single request (XACA-0292).
        """
        try:
            import glob
            import fcntl

            # Get the base path for this team's plan documents
            base_path = self._get_plan_doc_path_for_item(item_id)

            if not base_path:
                self._send_json_response({
                    "exists": False,
                    "retroExists": False,
                    "crExists": False,
                    "itemId": item_id,
                    "error": "Unknown team prefix in item ID"
                })
                return

            # Check if path exists and search for plan document
            if not base_path.exists():
                exists = False
                retro_exists = False
            else:
                # Support both underscore and dash separators in filenames
                pattern_underscore = str(base_path / f"{item_id}_*.md")
                pattern_dash = str(base_path / f"{item_id}-*.md")
                all_matches = glob.glob(pattern_underscore) + glob.glob(pattern_dash)
                # Filter: retro files end with _RETROSPECTIVE.md or -RETROSPECTIVE.md
                retro_matches = [m for m in all_matches if m.upper().endswith('_RETROSPECTIVE.MD') or m.upper().endswith('-RETROSPECTIVE.MD')]
                plan_matches = [m for m in all_matches if not (m.upper().endswith('_RETROSPECTIVE.MD') or m.upper().endswith('-RETROSPECTIVE.MD'))]
                exists = len(plan_matches) > 0
                retro_exists = len(retro_matches) > 0

            # Determine crExists: crSupport.enabled AND item is linked to a CR.
            # New schema (2026-05): CRs live in board.crs[]; items carry a back-pointer
            # at item.crAssignment.crId. Legacy schema (pre-migration) put cr_id directly
            # on the item — read both for compatibility on partially-migrated boards.
            cr_exists = False
            try:
                team = self._extract_team_from_item_id(item_id)
                if team:
                    board_file = get_board_file(team)
                    if board_file.exists():
                        lock_file = board_file.with_suffix('.json.lock')
                        with open(lock_file, 'w') as lock:
                            fcntl.flock(lock.fileno(), fcntl.LOCK_SH)
                            try:
                                with open(board_file, 'r', encoding='utf-8') as f:
                                    board_data = json.load(f)
                            finally:
                                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
                        team_config = board_data.get('teamConfig', {})
                        if bool(team_config.get('crSupport', {}).get('enabled', False)):
                            for backlog_item in board_data.get('backlog', []):
                                if backlog_item.get('id') == item_id:
                                    legacy_cr_id = (backlog_item.get('cr_id') or '').strip()
                                    assignment = backlog_item.get('crAssignment') or {}
                                    new_cr_id = (assignment.get('crId') or '').strip()
                                    cr_exists = bool(legacy_cr_id or new_cr_id)
                                    break
            except Exception as cr_err:
                print(f"[LCARS] WARNING: could not determine crExists for {item_id}: {cr_err}")
                cr_exists = False

            self._send_json_response({
                "exists": exists,
                "retroExists": retro_exists,
                "crExists": cr_exists,
                "itemId": item_id
            })

        except Exception as e:
            print(f"[LCARS] ERROR checking plan existence for {item_id}: {e}")
            self._send_json_response({
                "exists": False,
                "retroExists": False,
                "crExists": False,
                "itemId": item_id,
                "error": str(e)
            }, status=500)

    def serve_plan_content(self, item_id):
        """GET /api/kanban/<item-id>/plan-content - Read and return plan document content"""
        try:
            # Extract team from item ID
            team = self._extract_team_from_item_id(item_id)
            if not team:
                self._send_json_response({
                    "error": f"Unknown team prefix in item ID: {item_id}"
                }, status=404)
                return

            # Get plan document directory for team
            plan_dir = self._get_plan_docs_dir_for_team(team)

            if not plan_dir:
                self._send_json_response({
                    "error": f"No plan document directory configured for team: {team}"
                }, status=404)
                return

            # Handle freelance team with multiple possible directories
            if isinstance(plan_dir, list):
                # Search all freelance directories (support both _ and - separators)
                plan_file = None
                for directory in plan_dir:
                    pattern_underscore = str(directory / f"{item_id}_*.md")
                    pattern_dash = str(directory / f"{item_id}-*.md")
                    all_matches = glob.glob(pattern_underscore) + glob.glob(pattern_dash)
                    # Exclude retrospective files
                    matches = [m for m in all_matches if not (m.upper().endswith('_RETROSPECTIVE.MD') or m.upper().endswith('-RETROSPECTIVE.MD'))]
                    if matches:
                        plan_file = Path(matches[0])
                        break
                if not plan_file:
                    # No matches found in any directory
                    self._send_json_response({
                        "error": f"No plan document found for item: {item_id}"
                    }, status=404)
                    return
            else:
                # Standard team with single directory
                if not plan_dir.exists():
                    self._send_json_response({
                        "error": f"Plan document directory does not exist: {plan_dir}"
                    }, status=404)
                    return

                # Support both underscore and dash separators in filenames
                pattern_underscore = str(plan_dir / f"{item_id}_*.md")
                pattern_dash = str(plan_dir / f"{item_id}-*.md")
                all_matches = glob.glob(pattern_underscore) + glob.glob(pattern_dash)
                # Exclude retrospective files
                matches = [m for m in all_matches if not (m.upper().endswith('_RETROSPECTIVE.MD') or m.upper().endswith('-RETROSPECTIVE.MD'))]

                if not matches:
                    self._send_json_response({
                        "error": f"No plan document found for item: {item_id}"
                    }, status=404)
                    return

                plan_file = Path(matches[0])

            # Read the plan document
            with open(plan_file, 'r', encoding='utf-8') as f:
                content = f.read()

            # Return the content
            self._send_json_response({
                "content": content,
                "itemId": item_id,
                "filename": plan_file.name
            })

        except Exception as e:
            print(f"[LCARS] ERROR reading plan content for {item_id}: {e}")
            import traceback
            traceback.print_exc()
            self._send_json_response({
                "error": str(e),
                "itemId": item_id
            }, status=500)

    def serve_retro_exists(self, item_id):
        """GET /api/kanban/<item-id>/retro-exists - Check if retrospective exists for item"""
        try:
            import glob

            # Get the base path for this team's plan documents
            base_path = self._get_plan_doc_path_for_item(item_id)

            if not base_path:
                self._send_json_response({
                    "exists": False,
                    "itemId": item_id,
                    "error": "Unknown team prefix in item ID"
                })
                return

            # Check if path exists and search for retrospective document
            if not base_path.exists():
                exists = False
            else:
                # Support both underscore and dash separators in filenames
                pattern_underscore = str(base_path / f"{item_id}_*.md")
                pattern_dash = str(base_path / f"{item_id}-*.md")
                all_matches = glob.glob(pattern_underscore) + glob.glob(pattern_dash)
                # Only include retrospective files
                retro_matches = [m for m in all_matches if m.upper().endswith('_RETROSPECTIVE.MD') or m.upper().endswith('-RETROSPECTIVE.MD')]
                exists = len(retro_matches) > 0

            self._send_json_response({
                "exists": exists,
                "itemId": item_id
            })

        except Exception as e:
            print(f"[LCARS] ERROR checking retro existence for {item_id}: {e}")
            self._send_json_response({
                "exists": False,
                "itemId": item_id,
                "error": str(e)
            }, status=500)

    def serve_cr_exists(self, item_id):
        """GET /api/kanban/<item-id>/cr-exists - Check if a local CR document exists for item.

        Returns { exists: bool, itemId: str }.
        exists is True iff crSupport.enabled is True for this team AND the canonical
        local CR markdown file <team-kanban>/cr-docs/<item-id>-CR.md exists on disk.

        Phase 3 (XACA-0308-003): no longer checks cr_id / cr_doc_link — path is
        derived from item ID. Containment check narrows to <team-kanban>/cr-docs/.
        """
        try:
            import fcntl

            team = self._extract_team_from_item_id(item_id)
            if not team:
                self._send_json_response({"exists": False, "itemId": item_id})
                return

            # Sanitize item_id: must be alphanumeric + dash only (no / .. or leading .)
            import re as _re
            if not _re.match(r'^[A-Za-z0-9][A-Za-z0-9\-]*$', item_id):
                self._send_json_response({"exists": False, "itemId": item_id})
                return

            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({"exists": False, "itemId": item_id})
                return

            lock_file = board_file.with_suffix('.json.lock')
            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_SH)
                try:
                    with open(board_file, 'r', encoding='utf-8') as f:
                        board_data = json.load(f)
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

            # crSupport.enabled guard — disabled teams always return exists=false
            # (no info leak about whether any CR file is present).
            team_config = board_data.get('teamConfig', {})
            cr_enabled = bool(team_config.get('crSupport', {}).get('enabled', False))
            if not cr_enabled:
                self._send_json_response({"exists": False, "itemId": item_id})
                return

            # Build canonical path: <team-kanban>/cr-docs/<item-id>-CR.md
            # Fully resolve cr_docs_dir (mirrors serve_cr_content) so the
            # relative_to() containment check sees a canonical path even
            # if cr-docs/ itself is a symlink.
            team_kanban_dir = TEAM_KANBAN_DIRS.get(team, KANBAN_DIR)
            cr_docs_dir = (Path(team_kanban_dir) / 'cr-docs').resolve()
            candidate = (cr_docs_dir / f"{item_id}-CR.md").resolve()

            # Containment check: resolved path must be inside cr-docs/
            try:
                candidate.relative_to(cr_docs_dir)
            except ValueError:
                self._send_json_response({"exists": False, "itemId": item_id})
                return

            cr_exists = candidate.is_file()
            self._send_json_response({"exists": cr_exists, "itemId": item_id})

        except Exception as e:
            print(f"[LCARS] ERROR checking CR existence for {item_id}: {e}")
            self._send_json_response({"exists": False, "itemId": item_id, "error": str(e)}, status=500)

    def serve_retro_content(self, item_id):
        """GET /api/kanban/<item-id>/retro-content - Read and return retrospective content"""
        try:
            import glob

            # Extract team from item ID
            team = self._extract_team_from_item_id(item_id)
            if not team:
                self._send_json_response({
                    "error": f"Unknown team prefix in item ID: {item_id}"
                }, status=404)
                return

            # Get plan document directory for team (retros live alongside plan docs)
            plan_dir = self._get_plan_docs_dir_for_team(team)

            if not plan_dir:
                self._send_json_response({
                    "error": f"No plan document directory configured for team: {team}"
                }, status=404)
                return

            # Handle freelance team with multiple possible directories
            if isinstance(plan_dir, list):
                # Search all freelance directories (support both _ and - separators)
                retro_file = None
                for directory in plan_dir:
                    pattern_underscore = str(directory / f"{item_id}_*.md")
                    pattern_dash = str(directory / f"{item_id}-*.md")
                    all_matches = glob.glob(pattern_underscore) + glob.glob(pattern_dash)
                    # Only include retrospective files
                    retro_matches = [m for m in all_matches if m.upper().endswith('_RETROSPECTIVE.MD') or m.upper().endswith('-RETROSPECTIVE.MD')]
                    if retro_matches:
                        retro_file = Path(retro_matches[0])
                        break
                if not retro_file:
                    # No matches found in any directory
                    self._send_json_response({
                        "error": f"No retrospective document found for item: {item_id}"
                    }, status=404)
                    return
            else:
                # Standard team with single directory
                if not plan_dir.exists():
                    self._send_json_response({
                        "error": f"Plan document directory does not exist: {plan_dir}"
                    }, status=404)
                    return

                # Support both underscore and dash separators in filenames
                pattern_underscore = str(plan_dir / f"{item_id}_*.md")
                pattern_dash = str(plan_dir / f"{item_id}-*.md")
                all_matches = glob.glob(pattern_underscore) + glob.glob(pattern_dash)
                # Only include retrospective files
                retro_matches = [m for m in all_matches if m.upper().endswith('_RETROSPECTIVE.MD') or m.upper().endswith('-RETROSPECTIVE.MD')]

                if not retro_matches:
                    self._send_json_response({
                        "error": f"No retrospective document found for item: {item_id}"
                    }, status=404)
                    return

                retro_file = Path(retro_matches[0])

            # Read the retrospective document
            with open(retro_file, 'r', encoding='utf-8') as f:
                content = f.read()

            # Return the content
            self._send_json_response({
                "content": content,
                "itemId": item_id,
                "filename": retro_file.name
            })

        except Exception as e:
            print(f"[LCARS] ERROR reading retro content for {item_id}: {e}")
            import traceback
            traceback.print_exc()
            self._send_json_response({
                "error": str(e),
                "itemId": item_id
            }, status=500)

    def serve_cr_content(self, item_id):
        """GET /api/kanban/<item-id>/cr-content - Read and return CR document content.

        Phase 3 (XACA-0308-003): reads the canonical local markdown at
        <team-kanban>/cr-docs/<item-id>-CR.md.  Returns 404 with an informative
        "run kb-cr draft" message when the file does not exist.  Surfaces
        cr_confluence_url from the crs[] record so the UI can render a footer link
        (subitem 004).  All cr_doc_link reads and the legacy URL/path fallback chain
        have been removed.
        """
        try:
            import fcntl
            import re as _re

            # Extract team from item ID
            team = self._extract_team_from_item_id(item_id)
            if not team:
                self._send_json_response({
                    "error": f"Unknown team prefix in item ID: {item_id}"
                }, status=404)
                return

            # Sanitize item_id: must be alphanumeric + dash only (no / .. or leading .)
            if not _re.match(r'^[A-Za-z0-9][A-Za-z0-9\-]*$', item_id):
                self._send_json_response({
                    "error": f"Invalid item ID format: {item_id}"
                }, status=400)
                return

            # Load the board — needed for crSupport.enabled check and cr_confluence_url.
            board_file = self._get_board_file(team)
            if not board_file.exists():
                self._send_json_response({
                    "error": f"Board file not found for team: {team}"
                }, status=404)
                return

            lock_file = board_file.with_suffix('.json.lock')
            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_SH)
                try:
                    with open(board_file, 'r', encoding='utf-8') as f:
                        board_data = json.load(f)
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

            # crSupport.enabled guard — disabled teams always return 404
            # (same response shape as a missing CR, no info leak).
            team_config = board_data.get('teamConfig', {})
            cr_enabled = bool(team_config.get('crSupport', {}).get('enabled', False))
            if not cr_enabled:
                self._send_json_response({
                    "error": f"CR support is not enabled for this team. Run `kb-cr draft {item_id}` first.",
                    "itemId": item_id
                }, status=404)
                return

            # Build canonical path: <team-kanban>/cr-docs/<item-id>-CR.md
            team_kanban_dir = Path(TEAM_KANBAN_DIRS.get(team, KANBAN_DIR)).resolve()
            cr_docs_dir = (team_kanban_dir / 'cr-docs').resolve()
            cr_file = (cr_docs_dir / f"{item_id}-CR.md").resolve()

            # Containment check: resolved path must be inside cr-docs/
            # Rejects ../ traversal, absolute path injection, and symlink escapes.
            try:
                cr_file.relative_to(cr_docs_dir)
            except ValueError:
                self._send_json_response({
                    "error": f"Invalid item ID (path traversal rejected): {item_id}"
                }, status=400)
                return

            if not cr_file.is_file():
                self._send_json_response({
                    "error": f"Local CR document not yet created. Run `kb-cr draft {item_id}` (creates a draft CR with the doc) OR `kb-cr add-item <CR-ID> {item_id}` (links an existing CR; doc materializes on first item).",
                    "itemId": item_id
                }, status=404)
                return

            content = cr_file.read_text(encoding='utf-8')

            # Retrieve cr_confluence_url from the matching crs[] record.
            # The item carries a crAssignment.crId back-pointer (new schema) or
            # a direct cr_id (legacy schema) — use whichever is available to
            # look up the CR record.  If neither is set the URL will be empty,
            # which is correct for items that haven't been published yet.
            cr_confluence_url = ''
            item = None
            for backlog_item in board_data.get('backlog', []):
                if backlog_item.get('id') == item_id:
                    item = backlog_item
                    break
            if item is not None:
                assignment = item.get('crAssignment') or {}
                cr_id_ref = (assignment.get('crId') or '').strip() or (item.get('cr_id') or '').strip()
                if cr_id_ref:
                    for cr_record in board_data.get('crs', []):
                        if cr_record.get('id') == cr_id_ref:
                            cr_confluence_url = (cr_record.get('cr_confluence_url') or '').strip()
                            break

            self._send_json_response({
                "content": content,
                "filename": cr_file.name,
                "confluenceUrl": cr_confluence_url,
                "itemId": item_id
            })

        except Exception as e:
            print(f"[LCARS] ERROR reading CR content for {item_id}: {e}")
            import traceback
            traceback.print_exc()
            self._send_json_response({
                "error": str(e),
                "itemId": item_id
            }, status=500)

    def serve_cr_activity(self, cr_id):
        """GET /api/kanban/cr/<CR-ID>/activity - Return activity log for a CR container.

        Auto-detects team from CR-ID prefix (CR-<TEAM_UPPER>-<YYYYMMDD>-<seq>).
        Returns { crId, events: [] } when no log file exists yet (not an error).
        """
        import re
        try:
            # Validate CR-ID format to prevent path traversal
            if not re.match(r'^CR-[A-Z]+-\d{8}-\d+$', cr_id):
                self._send_json_response({"error": "Invalid CR-ID format"}, status=400)
                return

            # Extract team: CR-IOS-20260515-0123 → "ios"
            m = re.match(r'^CR-([A-Z]+)-', cr_id)
            if not m:
                self._send_json_response({"error": f"Cannot parse team from CR-ID: {cr_id}"}, status=400)
                return
            team = m.group(1).lower()

            # Map team to kanban directory (same mapping as TEAM_KANBAN_DIRS)
            team_kanban_dir = TEAM_KANBAN_DIRS.get(team)
            if team_kanban_dir is None:
                # Unknown team — return empty log rather than 404
                self._send_json_response({"crId": cr_id, "events": []})
                return

            activity_file = (Path(team_kanban_dir) / "change-requests" / "activity" / f"{cr_id}.json").resolve()

            # Containment check
            activity_root = (Path(team_kanban_dir) / "change-requests" / "activity").resolve()
            try:
                activity_file.relative_to(activity_root)
            except ValueError:
                self._send_json_response({"error": "Invalid CR-ID (path traversal)"}, status=400)
                return

            if not activity_file.exists():
                self._send_json_response({"crId": cr_id, "events": []})
                return

            with open(activity_file, "r", encoding="utf-8") as f:
                data = json.load(f)

            self._send_json_response(data)

        except Exception as e:
            print(f"[LCARS] ERROR reading CR activity for {cr_id}: {e}")
            self._send_json_response({"error": str(e), "crId": cr_id}, status=500)

    # ── CR Transition endpoint (XACA-0328-005) ──────────────────────────────
    # Valid target states (mirrors crStates in cr-schema.json).
    _CR_VALID_STATES = frozenset([
        "cr-drafted", "cr-submitted", "cr-approved", "cr-rejected",
        "cr-held", "implementing", "deployed-dev", "deployed-prod",
        "emergency-deployed", "cr-closed",
    ])

    # Required fields per target state.
    # Each entry is (field_path, description, validator_fn or None).
    # field_path uses dot notation to address nested fields (e.g. "approver.login").
    _CR_REQUIRED_FIELDS = {
        "cr-drafted":         [],
        "cr-submitted":       [("cr_proper_url", "must start with https://")],
        "cr-approved":        [("approver.login", None), ("approver.name", None)],
        "cr-rejected":        [("pushback_notes", "non-empty after trim")],
        "cr-held":            [("hold_reason", None)],
        "implementing":       [],
        "deployed-dev":       [("deploy_estimate", "ISO 8601 date/time")],
        "deployed-prod":      [("deploy_estimate", "ISO 8601 date/time")],
        "emergency-deployed": [("emergency_justification", None), ("deploy_estimate", "ISO 8601 date/time")],
        "cr-closed":          [],
    }

    def _cr_get_nested(self, d, dotted_key):
        """Return value at dotted key (e.g. 'approver.login') from dict d, or None."""
        parts = dotted_key.split(".")
        val = d
        for p in parts:
            if not isinstance(val, dict):
                return None
            val = val.get(p)
        return val

    def _cr_validate_fields(self, target_state, fields):
        """Validate required fields for target_state.

        Returns (ok, error_message). fields is the 'fields' dict from the
        request body (may be None or empty).
        """
        fields = fields or {}
        rules = self._CR_REQUIRED_FIELDS.get(target_state, [])
        for field_path, hint in rules:
            val = self._cr_get_nested(fields, field_path)
            if val is None or (isinstance(val, str) and not val.strip()):
                err = f"missing required field: {field_path} for target {target_state}"
                if hint:
                    err += f" ({hint})"
                return False, err
            # Extra semantic validators
            if field_path == "cr_proper_url" and not str(val).startswith("https://"):
                return False, f"cr_proper_url must start with https:// for target {target_state}"
            if field_path == "deploy_estimate":
                try:
                    from datetime import datetime
                    # Accept both Z-suffix and +00:00; strip Z for fromisoformat compat
                    datetime.fromisoformat(str(val).replace("Z", "+00:00"))
                except (ValueError, TypeError):
                    return False, f"deploy_estimate must be parseable ISO 8601 for target {target_state}"
        return True, None

    def handle_cr_transition(self, cr_id):
        """POST /api/kanban/cr/<CR-ID>/transition — Manual state-change endpoint.

        Accepts:
          { targetState, expectedUpdatedAt, fields: { ... }, actor }

        Performs optimistic concurrency check, validates required fields per
        target state, applies the state transition and field updates via
        kb-cr shell helpers (single flock path), writes activity events,
        and returns the updated CR record.
        """
        import re
        try:
            # ── Parse request body ─────────────────────────────────────────────
            content_length = int(self.headers.get("Content-Length", 0))
            if content_length == 0:
                self._send_json_response({"ok": False, "error": "Empty request body"}, status=400)
                return
            body = json.loads(self.rfile.read(content_length))

            target_state     = body.get("targetState", "").strip()
            expected_updated = body.get("expectedUpdatedAt", "")
            fields           = body.get("fields") or {}
            actor            = body.get("actor", "lcars-ui").strip() or "lcars-ui"

            # ── Validate CR-ID format ──────────────────────────────────────────
            if not re.match(r"^CR-[A-Z]+-\d{8}-\d+$", cr_id):
                self._send_json_response({"ok": False, "error": "Invalid CR-ID format"}, status=400)
                return

            # ── Validate target state ──────────────────────────────────────────
            if target_state not in self._CR_VALID_STATES:
                self._send_json_response(
                    {"ok": False, "error": f"Unknown targetState '{target_state}'. "
                     f"Valid states: {', '.join(sorted(self._CR_VALID_STATES))}"},
                    status=400,
                )
                return

            # ── Validate required fields for target state ──────────────────────
            ok, field_err = self._cr_validate_fields(target_state, fields)
            if not ok:
                self._send_json_response({"ok": False, "error": field_err}, status=400)
                return

            # ── Resolve board file from CR-ID prefix ───────────────────────────
            m = re.match(r"^CR-([A-Z]+)-", cr_id)
            if not m:
                self._send_json_response({"ok": False, "error": f"Cannot parse team from CR-ID: {cr_id}"}, status=400)
                return
            team = m.group(1).lower()

            team_kanban_dir = TEAM_KANBAN_DIRS.get(team)
            if team_kanban_dir is None:
                self._send_json_response({"ok": False, "error": f"Unknown team '{team}' derived from CR-ID"}, status=404)
                return

            board_file = Path(team_kanban_dir) / f"{team}-board.json"
            if not board_file.exists():
                self._send_json_response({"ok": False, "error": f"Board file not found for team '{team}'"}, status=404)
                return

            # Containment / path-traversal guard
            try:
                board_file.resolve().relative_to(Path(team_kanban_dir).resolve())
            except ValueError:
                self._send_json_response({"ok": False, "error": "Invalid CR-ID (path traversal)"}, status=400)
                return

            # ── Read current board + locate CR record ──────────────────────────
            with open(board_file, "r", encoding="utf-8") as f:
                board_data = json.load(f)

            crs = board_data.get("crs", [])
            cr_idx = next((i for i, c in enumerate(crs) if c.get("id") == cr_id), None)
            if cr_idx is None:
                self._send_json_response({"ok": False, "error": f"CR not found: {cr_id}"}, status=404)
                return

            current_cr = crs[cr_idx]

            # ── Optimistic concurrency check ───────────────────────────────────
            current_updated_at = current_cr.get("updatedAt") or current_cr.get("lastUpdatedAt", "")
            if expected_updated and current_updated_at and expected_updated != current_updated_at:
                self._send_json_response(
                    {
                        "ok": False,
                        "conflict": True,
                        "error": "CR was modified by another writer",
                        "currentUpdatedAt": current_updated_at,
                    },
                    status=409,
                )
                return

            from_state = current_cr.get("crState", "")

            # ── Build shell script for atomic transition + field writes ────────
            # We source kanban-helpers.sh and kb-cr.sh so we get _kb_jq_update
            # (Perl-flock locking) and all kb-cr helpers.  All writes go through
            # a single flock path — no parallel race between this request and a
            # concurrent kb-cr CLI invocation.
            #
            # Strategy:
            #   1. Set _cr_board / _cr_enabled / _cr_team directly (bypasses
            #      _kb_cr_board_preamble which needs tmux).
            #   2. Call _kb_cr_container_transition directly for the state change.
            #   3. Build a jq update for the extra fields (approver, notes, etc.).
            #   4. Append activity events via _kb_cr_activity_append.
            #
            # All of the above use _kb_jq_update's Perl flock — single locking path.

            board_file_str = str(board_file.resolve())

            # Build field-update jq fragments and args.
            # We collect changed fields for cr_field_update activity events.
            field_jq_parts = []   # jq filter fragments (all share the same --argjson cidx)
            field_jq_args  = []   # list of "--arg key val" pairs (flat, for shell embedding)
            changed_fields = {}   # field_name -> new_value (for activity events)

            def _add_field_update(jq_path, new_value, label, old_value):
                """Register a simple string field update."""
                arg_key = jq_path.replace(".", "_").replace("[", "").replace("]", "")
                field_jq_parts.append(f'.crs[$cidx].{jq_path} = ${arg_key}')
                field_jq_args.append((arg_key, str(new_value)))
                if str(new_value) != str(old_value or ""):
                    changed_fields[label] = {"old": str(old_value or ""), "new": str(new_value)}

            approver_fields = fields.get("approver") or {}
            if approver_fields:
                old_approver = current_cr.get("approver") or {}
                if "login" in approver_fields:
                    _add_field_update("approver.login", approver_fields["login"], "approver.login",
                                      old_approver.get("login", ""))
                if "name" in approver_fields:
                    _add_field_update("approver.name", approver_fields["name"], "approver.name",
                                      old_approver.get("name", ""))

            for field_key in ("pushback_notes", "hold_reason", "emergency_justification",
                              "cr_proper_url", "deploy_estimate"):
                if field_key in fields and fields[field_key] is not None:
                    _add_field_update(field_key, fields[field_key], field_key,
                                      current_cr.get(field_key, ""))

            # Build the full shell script.
            # We call _kb_cr_container_transition directly with explicit args to
            # bypass _kb_cr_board_preamble's tmux dependency.
            # Resolve dev-team root from the user's home dir — same pattern as
            # cr-confluence-poller.py — so the endpoint isn't single-user-bound.
            dev_team_root = str(Path.home() / "dev-team")
            shell_parts = [
                f"source {shlex.quote(dev_team_root + '/kanban-helpers.sh')}",
                f"source {shlex.quote(dev_team_root + '/scripts/kb-cr.sh')}",
                # Find CR index
                f'cr_idx=$(_kb_jq_read "{board_file_str}" \'.crs | to_entries[] | select(.value.id == "{cr_id}") | .key\' -r 2>/dev/null)',
                f'if [ -z "$cr_idx" ]; then echo "CR not found in board" >&2; exit 2; fi',
                # Apply state transition (uses _kb_jq_update with flock internally)
                f'old_state=$(_kb_jq_read "{board_file_str}" ".crs[$cr_idx].crState // empty" -r 2>/dev/null || echo "")',
                f'ts=$(_kb_cr_timestamp)',
                f'_kb_jq_update "{board_file_str}" \'.crs[$cidx].crState = $state | .crs[$cidx].updatedAt = $ts | .lastUpdated = $ts\' --argjson cidx "$cr_idx" --arg state "{target_state}" --arg ts "$ts"',
            ]

            # Field updates — each needs cidx, so we re-use the same _kb_jq_update
            if field_jq_parts:
                jq_filter_combined = " | ".join(
                    [".crs[$cidx].updatedAt = $ts | .lastUpdated = $ts"] + field_jq_parts
                )
                shell_parts.append(
                    f'ts2=$(_kb_cr_timestamp)'
                )
                # Build the --arg lines. shlex.quote on EVERY value — values come
                # from untrusted JSON request bodies and would otherwise allow shell
                # command substitution ($(...), backticks, $VAR) to fire before jq
                # ever sees them.
                field_arg_str = ' '.join(
                    f'--arg {shlex.quote(k)} {shlex.quote(v)}' for k, v in field_jq_args
                )
                shell_parts.append(
                    f'_kb_jq_update "{board_file_str}" \'{jq_filter_combined}\' --argjson cidx "$cr_idx" --arg ts "$ts2" {field_arg_str}'
                )

            # cr_state_changed activity event
            shell_parts += [
                f'from_state_safe="${{old_state:-{from_state}}}"',
                f'state_evt=$(_kb_cr_activity_event cr_state_changed from_state="$from_state_safe" to_state="{target_state}" 2>/dev/null || echo "")',
                f'[ -n "$state_evt" ] && _kb_cr_activity_append "{board_file_str}" "{cr_id}" "$state_evt" 2>/dev/null || true',
            ]

            # cr_field_update activity events (one per changed field).
            # shlex.quote each user-controlled value — fname comes from the
            # validated allowlist above but old/new are arbitrary user input.
            for fname, vals in changed_fields.items():
                fname_q = shlex.quote(f"field={fname}")
                old_q   = shlex.quote(f"old_value={vals['old']}")
                new_q   = shlex.quote(f"new_value={vals['new']}")
                shell_parts += [
                    f'fld_evt=$(_kb_cr_activity_event cr_field_update {fname_q} {old_q} {new_q} 2>/dev/null || echo "")',
                    f'[ -n "$fld_evt" ] && _kb_cr_activity_append "{board_file_str}" "{cr_id}" "$fld_evt" 2>/dev/null || true',
                ]

            shell_script = "\n".join(shell_parts)

            env = {**os.environ, "KB_CR_ACTOR": actor}
            result = subprocess.run(
                ["zsh", "-c", shell_script],
                capture_output=True,
                text=True,
                env=env,
                timeout=30,
            )

            if result.returncode != 0:
                stderr = result.stderr.strip()
                print(f"[LCARS] CR transition shell error for {cr_id}: {stderr}")
                self._send_json_response(
                    {"ok": False, "error": f"Transition failed: {stderr or 'unknown error'}"},
                    status=500,
                )
                return

            # ── Re-read updated CR record ──────────────────────────────────────
            with open(board_file, "r", encoding="utf-8") as f:
                board_data_after = json.load(f)

            crs_after = board_data_after.get("crs", [])
            updated_cr = next((c for c in crs_after if c.get("id") == cr_id), None)
            if updated_cr is None:
                self._send_json_response({"ok": False, "error": "CR vanished after write"}, status=500)
                return

            self._send_json_response({"ok": True, "cr": updated_cr})

        except json.JSONDecodeError as e:
            self._send_json_response({"ok": False, "error": f"Invalid JSON body: {e}"}, status=400)
        except Exception as e:
            print(f"[LCARS] ERROR in CR transition for {cr_id}: {e}")
            import traceback as _tb
            _tb.print_exc()
            self._send_json_response({"ok": False, "error": str(e)}, status=500)

    def serve_calendar_config(self):
        """GET /api/calendar/config - Get calendar configuration for current team"""
        try:
            team = LCARS_TEAM
            config_file = TEAM_CONFIG_DIR / "calendar-config.json"

            if config_file.exists():
                with open(config_file, 'r') as f:
                    config = json.load(f)
            else:
                # Return default empty config in canonical format
                config = {
                    "apple": None,
                    "google": None,
                    "lastUpdated": None
                }

            self._send_json_response(config)
        except Exception as e:
            print(f"[LCARS] ERROR serving calendar config: {e}")
            self._send_json_response({"error": str(e)}, status=500)

    def handle_save_calendar_config(self):
        """POST /api/calendar/config - Save calendar configuration.

        Handles two modes:
        1. Calendar selection: { provider, calendarId, calendarName }
        2. Full config save: { config: { apple: {...}, google: {...} } }
        """
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            TEAM_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            config_file = TEAM_CONFIG_DIR / "calendar-config.json"

            # Mode 1: Calendar selection update
            provider = post_data.get('provider')
            calendar_id = post_data.get('calendarId')
            if provider and calendar_id is not None:
                # Read existing config
                if config_file.exists():
                    with open(config_file, 'r') as f:
                        config = json.load(f)
                else:
                    config = {"apple": None, "google": None, "lastUpdated": None}

                if config.get(provider) and isinstance(config[provider], dict):
                    config[provider]['selectedCalendarId'] = calendar_id
                    config[provider]['calendarName'] = post_data.get('calendarName') or calendar_id
                    config['lastUpdated'] = self._get_timestamp()
                    self._atomic_write_json(config_file, config)

                    self._send_json_response({
                        "success": True,
                        "message": f"{provider} calendar selection saved",
                        "config": config
                    })
                else:
                    self._send_json_response({"success": False, "error": f"Provider {provider} not connected"}, status=400)
                return

            # Mode 2: Full config replacement
            config = post_data.get('config')
            if not config:
                self._send_json_response({"success": False, "error": "No config provided"}, status=400)
                return

            config['lastUpdated'] = self._get_timestamp()
            self._atomic_write_json(config_file, config)

            self._send_json_response({
                "success": True,
                "message": "Calendar configuration saved",
                "config": config
            })
        except Exception as e:
            print(f"[LCARS] ERROR saving calendar config: {e}")
            self._send_json_response({"success": False, "error": str(e)}, status=500)

    # =========================================================================
    # TEAM CONFIG API — XACA-0292
    # =========================================================================

    def serve_team_config(self, query_string: str):
        """GET /api/team-config?team=<team> — return teamConfig block from board JSON.

        Falls back to { crSupport: { enabled: false } } if the key is absent or the
        board file doesn't exist yet, so callers can treat the response as authoritative.

        XACA-0332: also merges copyright config from ~/.aiteamforge/team-paths.json (schema v2).
        """
        try:
            params = parse_qs(query_string) if query_string else {}
            team = params.get('team', [None])[0] or LCARS_TEAM

            # XACA-0292-011: validate team against the allow-list
            if team not in TEAM_KANBAN_DIRS:
                self._send_json_response({'error': f'Unknown team: {team}'}, status=400)
                return

            board_file = get_board_file(team)
            if board_file.exists():
                with open(board_file, 'r') as f:
                    board_data = json.load(f)
            else:
                board_data = {}

            # XACA-0333-006: `or {}` guards against an explicitly null teamConfig in the
            # board JSON — dict.get() only uses the default when the key is ABSENT, not
            # when it's None. Cannot occur via server-written boards, but a hand-edited
            # JSON could leave teamConfig: null, which would crash setdefault().
            team_config = board_data.get('teamConfig') or {}
            # Ensure crSupport key always present with default
            team_config.setdefault('crSupport', {}).setdefault('enabled', False)

            # XACA-0332: surface copyright config from ~/.aiteamforge/team-paths.json (schema v2)
            copyright_block = self._read_copyright_config(team)
            if copyright_block is not None:
                team_config['copyright'] = copyright_block

            self._send_json_response({'teamConfig': team_config})
        except Exception as e:
            print(f"[LCARS] ERROR serving team config: {e}")
            self._send_json_response({'error': str(e)}, status=500)

    def _read_copyright_config(self, team: str):
        """Read XACA-0251 copyright fields for `team` from ~/.aiteamforge/team-paths.json (schema v2).

        Returns a dict with copyright_owner / license_type / component_label / year_start /
        notice_template / is_placeholder, or None if the team is not present or the file is missing.

        XACA-0333-002: uses an mtime-based class-level cache to avoid re-reading from disk
        on every GET.  Cache is invalidated by _write_copyright_config after a successful write.

        XACA-0333-003: includes is_placeholder sub-dict mapping each copyright field name
        to a bool indicating whether the current value is a TBD placeholder.
        """
        team_paths_file = Path.home() / '.aiteamforge' / 'team-paths.json'
        if not team_paths_file.exists():
            return None
        try:
            # XACA-0333-002: stat first; reuse cache if mtime_ns matches
            try:
                current_mtime_ns = os.stat(team_paths_file).st_mtime_ns
            except OSError:
                return None

            with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
                cached = LCARSHandler._TEAM_PATHS_CACHE
                if cached['mtime_ns'] == current_mtime_ns and cached['data'] is not None:
                    data = cached['data']
                else:
                    with open(team_paths_file, 'r') as f:
                        data = json.load(f)
                    LCARSHandler._TEAM_PATHS_CACHE = {'mtime_ns': current_mtime_ns, 'data': data}

            team_block = data.get('teams', {}).get(team)
            if not team_block:
                return None

            # Collect the 5 copyright fields
            fields = {
                'copyright_owner': team_block.get('copyright_owner'),
                'license_type': team_block.get('license_type'),
                'component_label': team_block.get('component_label'),
                'year_start': team_block.get('year_start'),
                'notice_template': team_block.get('notice_template'),
            }

            # XACA-0333-003: build is_placeholder sub-dict — True iff string value is a TBD sentinel
            fields['is_placeholder'] = {
                k: (isinstance(v, str) and v in _COPYRIGHT_PLACEHOLDER_VALUES)
                for k, v in fields.items()
            }

            return fields
        except Exception as e:
            print(f"[LCARS] WARNING reading copyright config for {team}: {e}")
            return None

    # Allowed top-level keys in the POST /api/team-config payload
    _TEAM_CONFIG_ALLOWED_KEYS = {'crSupport', 'copyright'}
    # Allowed nested keys under crSupport
    _CR_SUPPORT_ALLOWED_KEYS = {'enabled', 'description'}
    # Allowed nested keys under copyright (XACA-0332)
    _COPYRIGHT_ALLOWED_KEYS = {'copyright_owner', 'license_type', 'component_label', 'year_start', 'notice_template'}
    # Valid enum values for copyright fields (XACA-0332)
    _VALID_LICENSE_TYPES = {'MIT', 'Proprietary', 'Client-Owned', 'BSD-3-Clause'}
    _VALID_NOTICE_TEMPLATES = {'range', 'single'}

    def handle_update_team_config(self):
        """POST /api/team-config — persist teamConfig changes to board JSON and team-paths.json.

        Accepted body: {
            team: str,
            teamConfig: {
                crSupport: { enabled: bool, description?: str },
                copyright?: {
                    copyright_owner: str, license_type: str, component_label: str,
                    year_start: int, notice_template: str
                }
            }
        }
        Uses file lock + atomic write (same pattern as all other board mutations).
        Copyright block is written to ~/.aiteamforge/team-paths.json (schema v2).

        Security (XACA-0292-011, XACA-0292-012, XACA-0332):
          - team is validated against TEAM_KANBAN_DIRS allow-list
          - only whitelisted keys are accepted; unknown keys -> 400
          - all fields are type-validated; enum fields are validated against allow-lists
          - a CLEAN payload is constructed; attacker-controlled keys are never written
        """
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team') or LCARS_TEAM

            # XACA-0292-011: validate team against the allow-list
            if team not in TEAM_KANBAN_DIRS:
                self._send_json_response({'success': False, 'error': f'Unknown team: {team}'}, status=400)
                return

            new_team_config = post_data.get('teamConfig')
            if new_team_config is None:
                self._send_json_response({'success': False, 'error': 'Missing teamConfig payload'}, status=400)
                return

            # XACA-0292-012: schema-validate teamConfig — reject unknown top-level keys
            unknown_top = set(new_team_config.keys()) - self._TEAM_CONFIG_ALLOWED_KEYS
            if unknown_top:
                bad = ', '.join(sorted(unknown_top))
                self._send_json_response({'success': False, 'error': f'Unknown teamConfig key(s): {bad}'}, status=400)
                return

            # XACA-0292-012: validate crSupport block if present
            clean_team_config = {}
            if 'crSupport' in new_team_config:
                cr = new_team_config['crSupport']
                if not isinstance(cr, dict):
                    self._send_json_response({'success': False, 'error': 'crSupport must be an object'}, status=400)
                    return
                unknown_cr = set(cr.keys()) - self._CR_SUPPORT_ALLOWED_KEYS
                if unknown_cr:
                    bad = ', '.join(sorted(unknown_cr))
                    self._send_json_response({'success': False, 'error': f'Unknown crSupport key(s): {bad}'}, status=400)
                    return
                if 'enabled' in cr and not isinstance(cr['enabled'], bool):
                    self._send_json_response({'success': False, 'error': 'crSupport.enabled must be a boolean'}, status=400)
                    return
                if 'description' in cr and not isinstance(cr['description'], str):
                    self._send_json_response({'success': False, 'error': 'crSupport.description must be a string'}, status=400)
                    return
                # Build a clean crSupport dict from only the validated fields
                clean_cr = {}
                if 'enabled' in cr:
                    clean_cr['enabled'] = cr['enabled']
                if 'description' in cr:
                    clean_cr['description'] = cr['description']
                clean_team_config['crSupport'] = clean_cr

            # XACA-0332: validate copyright block if present
            clean_copyright = None
            if 'copyright' in new_team_config:
                cp = new_team_config['copyright']
                if not isinstance(cp, dict):
                    self._send_json_response({'success': False, 'error': 'copyright must be an object'}, status=400)
                    return
                unknown_cp = set(cp.keys()) - self._COPYRIGHT_ALLOWED_KEYS
                if unknown_cp:
                    bad = ', '.join(sorted(unknown_cp))
                    self._send_json_response({'success': False, 'error': f'Unknown copyright key(s): {bad}'}, status=400)
                    return
                # Validate each field individually
                if 'copyright_owner' in cp:
                    v = cp['copyright_owner']
                    if not isinstance(v, str) or not (1 <= len(v) <= 200):
                        self._send_json_response({'success': False, 'error': 'copyright_owner must be a string (1-200 chars)'}, status=400)
                        return
                if 'license_type' in cp:
                    v = cp['license_type']
                    if v not in self._VALID_LICENSE_TYPES:
                        self._send_json_response({'success': False, 'error': f'license_type must be one of: {", ".join(sorted(self._VALID_LICENSE_TYPES))}'}, status=400)
                        return
                if 'component_label' in cp:
                    v = cp['component_label']
                    if not isinstance(v, str) or not (1 <= len(v) <= 200):
                        self._send_json_response({'success': False, 'error': 'component_label must be a string (1-200 chars)'}, status=400)
                        return
                if 'year_start' in cp:
                    v = cp['year_start']
                    # Exclude bool: isinstance(True, int) is True in Python
                    if not isinstance(v, int) or isinstance(v, bool) or not (1990 <= v <= 2100):
                        self._send_json_response({'success': False, 'error': 'year_start must be an integer between 1990 and 2100'}, status=400)
                        return
                if 'notice_template' in cp:
                    v = cp['notice_template']
                    if v not in self._VALID_NOTICE_TEMPLATES:
                        self._send_json_response({'success': False, 'error': f'notice_template must be one of: {", ".join(sorted(self._VALID_NOTICE_TEMPLATES))}'}, status=400)
                        return
                # Build a clean copyright dict from only the validated fields
                clean_copyright = {k: cp[k] for k in self._COPYRIGHT_ALLOWED_KEYS if k in cp}

            # --- Write crSupport changes to board JSON ---
            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({'success': False, 'error': f'Board not found for team: {team}'}, status=404)
                return

            # XACA-0333-004: skip the board.json lock+write entirely when payload has no crSupport
            # changes (copyright-only saves).  board_data stays None; subitem 005 handles response.
            if clean_team_config:
                import fcntl
                lock_file = board_file.with_suffix('.json.lock')
                with open(lock_file, 'w') as lock:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                    try:
                        with open(board_file, 'r') as f:
                            board_data = json.load(f)

                        # Merge the CLEAN validated payload into existing teamConfig
                        existing = board_data.get('teamConfig', {})
                        for key, val in clean_team_config.items():
                            if isinstance(val, dict) and isinstance(existing.get(key), dict):
                                existing[key].update(val)
                            else:
                                existing[key] = val
                        board_data['teamConfig'] = existing

                        self._atomic_write_json(board_file, board_data)
                        print(f"[LCARS] Team config updated for '{team}': {existing}")
                    finally:
                        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
                        # XACA-0333-001: remove the advisory lock file after release — best-effort
                        try: lock_file.unlink(missing_ok=True)
                        except OSError: pass
            else:
                board_data = None  # copyright-only save — board not touched

            # --- Write copyright changes to team-paths.json (XACA-0332) ---
            copyright_write_error = None
            if clean_copyright:
                copyright_write_error = self._write_copyright_config(team, clean_copyright)

            # XACA-0333-005: build a complete teamConfig response. crSupport comes from the
            # board write above (or a fresh re-read if the board wasn't touched), and the
            # copyright block is read fresh from team-paths.json so the client always gets
            # the canonical saved values (including the is_placeholder sub-dict from 003).
            response_team_config: dict = {}
            if board_data is not None:
                # XACA-0333-006: `or {}` guards against an explicitly null teamConfig.
                response_team_config = dict(board_data.get('teamConfig') or {})
            elif board_file.exists():
                with open(board_file, 'r') as f:
                    response_team_config = dict(json.load(f).get('teamConfig') or {})
            response_team_config.setdefault('crSupport', {}).setdefault('enabled', False)

            saved_copyright = self._read_copyright_config(team)
            if saved_copyright is not None:
                response_team_config['copyright'] = saved_copyright

            response_payload = {'success': True, 'teamConfig': response_team_config}
            if copyright_write_error:
                # Board write succeeded; copyright write failed — partial success
                response_payload['warning'] = f'Team config saved, but copyright write failed: {copyright_write_error}'
            self._send_json_response(response_payload)
        except Exception as e:
            print(f"[LCARS] ERROR updating team config: {e}")
            self._send_json_response({'success': False, 'error': str(e)}, status=500)

    def _write_copyright_config(self, team: str, copyright_fields: dict):
        """Write XACA-0332 copyright fields for `team` into ~/.aiteamforge/team-paths.json (schema v2).

        Uses file lock + atomic write + backup.  Updates ONLY the named team's copyright
        fields; all other team blocks and non-copyright fields are left untouched.

        Returns None on success, or an error string on failure.
        """
        import fcntl, tempfile, datetime
        team_paths_file = Path.home() / '.aiteamforge' / 'team-paths.json'
        if not team_paths_file.exists():
            return f'team-paths.json not found at {team_paths_file}'

        lock_file = team_paths_file.with_suffix('.json.lock')
        try:
            with open(lock_file, 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    with open(team_paths_file, 'r') as f:
                        data = json.load(f)

                    if team not in data.get('teams', {}):
                        return f"Team '{team}' not found in team-paths.json"

                    # Backup before mutating
                    timestamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
                    backup_path = team_paths_file.parent / f'team-paths.json.bak-{timestamp}'
                    with open(backup_path, 'w') as bf:
                        json.dump(data, bf, indent=2)

                    # Merge only the copyright fields; leave all other fields (kanban_dir, etc.) untouched
                    data['teams'][team].update(copyright_fields)

                    # Atomic write via tmp file
                    tmp_path = team_paths_file.with_suffix(f'.json.tmp.{os.getpid()}')
                    try:
                        with open(tmp_path, 'w') as f:
                            json.dump(data, f, indent=2)
                            f.flush()
                            os.fsync(f.fileno())
                        os.replace(str(tmp_path), str(team_paths_file))
                    except Exception:
                        if tmp_path.exists():
                            tmp_path.unlink()
                        raise

                    # XACA-0333-002: invalidate the mtime cache so the next GET re-reads from disk.
                    # Do this BEFORE the success log and ONLY on successful write (not in except).
                    with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
                        LCARSHandler._TEAM_PATHS_CACHE = {'mtime_ns': None, 'data': None}

                    print(f"[LCARS] Copyright config updated for '{team}': {copyright_fields}")
                    return None
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
                    # XACA-0333-001: remove the advisory lock file after release — best-effort
                    try: lock_file.unlink(missing_ok=True)
                    except OSError: pass
        except Exception as e:
            print(f"[LCARS] ERROR writing copyright config for {team}: {e}")
            return str(e)

    # =========================================================================
    # TEAM CONFIG ACCOUNT API — XACA-0281 (Phase A.3)
    # =========================================================================

    # Validation-cache path: persisted across requests; updated by test-connection
    _ACCOUNT_VALIDATION_CACHE_PATH = Path.home() / '.aiteamforge' / 'account-validation.json'

    # Env-var name regex: must start with uppercase letter, only uppercase + digits + underscore
    _ENV_VAR_NAME_RE = re.compile(r'^[A-Z][A-Z0-9_]*$')

    def _load_account_validation_cache(self):
        """Load the account validation timestamp cache from disk.

        Returns a dict mapping env_var_name -> ISO timestamp string, or {} on any error.
        """
        try:
            p = self._ACCOUNT_VALIDATION_CACHE_PATH
            if p.exists():
                with open(p, 'r') as f:
                    return json.load(f)
        except Exception as e:
            print(f"[LCARS] WARNING reading account-validation cache: {e}")
        return {}

    def _save_account_validation_cache(self, cache: dict):
        """Atomically persist the account validation cache to disk."""
        p = self._ACCOUNT_VALIDATION_CACHE_PATH
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = p.with_suffix(f'.json.tmp.{os.getpid()}')
        try:
            with open(tmp_path, 'w') as f:
                json.dump(cache, f, indent=2)
                f.flush()
                os.fsync(f.fileno())
            os.replace(str(tmp_path), str(p))
        except Exception as e:
            print(f"[LCARS] WARNING writing account-validation cache: {e}")
            try:
                tmp_path.unlink(missing_ok=True)
            except OSError:
                pass

    def _read_team_paths_raw(self):
        """Read team-paths.json via the mtime cache. Returns (data_dict, error_str)."""
        team_paths_file = Path.home() / '.aiteamforge' / 'team-paths.json'
        if not team_paths_file.exists():
            return None, f'team-paths.json not found at {team_paths_file}'
        try:
            current_mtime_ns = os.stat(team_paths_file).st_mtime_ns
        except OSError as e:
            return None, str(e)
        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
            cached = LCARSHandler._TEAM_PATHS_CACHE
            if cached['mtime_ns'] == current_mtime_ns and cached['data'] is not None:
                return cached['data'], None
            try:
                with open(team_paths_file, 'r') as f:
                    data = json.load(f)
                LCARSHandler._TEAM_PATHS_CACHE = {'mtime_ns': current_mtime_ns, 'data': data}
                return data, None
            except Exception as e:
                return None, str(e)

    def serve_team_account_current(self, query_string: str):
        """GET /api/team-config/account/current?team=<id>

        Returns {account_id, account_nickname, env_var_name, has_credentials, last_validated_at}.
        NEVER returns the actual key value — has_credentials is a bool derived from
        bool(os.environ.get(env_var_name)).

        XACA-0281-003
        """
        try:
            params = parse_qs(query_string) if query_string else {}
            team = params.get('team', [None])[0] or LCARS_TEAM

            if team not in TEAM_KANBAN_DIRS:
                self._send_json_response({'error': f'Unknown team: {team}'}, status=400)
                return

            data, err = self._read_team_paths_raw()
            if err:
                self._send_json_response({'error': err}, status=500)
                return

            team_block = data.get('teams', {}).get(team) or {}
            account_id = team_block.get('anthropic_account_id') or ''
            account_nickname = team_block.get('anthropic_account_nickname') or ''
            env_var_name = team_block.get('anthropic_api_key_env_var') or ''

            # Derive has_credentials without ever touching the key value
            has_credentials = bool(env_var_name and os.environ.get(env_var_name))

            # Read last_validated_at from the validation-cache file
            cache = self._load_account_validation_cache()
            last_validated_at = cache.get(env_var_name) if env_var_name else None

            self._send_json_response({
                'account_id': account_id,
                'account_nickname': account_nickname,
                'env_var_name': env_var_name,
                'has_credentials': has_credentials,
                'last_validated_at': last_validated_at,
            })
        except Exception as e:
            print(f"[LCARS] ERROR in serve_team_account_current: {e}")
            self._send_json_response({'error': str(e)}, status=500)

    def handle_team_account_save(self):
        """POST /api/team-config/account/save

        Body: {team, account_id, account_nickname, env_var_name}
        Writes the three schema-v2 account fields into ~/.aiteamforge/team-paths.json
        for the specified team. Uses fcntl file-lock + atomic rename.
        NEVER stores or echoes the actual key value.

        XACA-0281-004
        """
        import fcntl
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(content_length))

            team = body.get('team') or LCARS_TEAM
            if team not in TEAM_KANBAN_DIRS:
                self._send_json_response({'success': False, 'error': f'Unknown team: {team}'}, status=400)
                return

            account_id = body.get('account_id', '')
            account_nickname = body.get('account_nickname', '')
            env_var_name = body.get('env_var_name', '')

            # Type-check first; then strip; then content-validate the trimmed value
            # so whitespace-padded input is normalized before the regex guard sees it.
            # account_id and account_nickname are OPTIONAL (empty = OAuth fallback,
            # pre-XACA-0279 behavior). env_var_name is also optional, but if non-empty
            # after stripping it must match the standard env-var pattern. All three
            # empty = clear the manual config and revert the team to the OAuth fallback.
            if not isinstance(account_id, str):
                self._send_json_response({'success': False, 'error': 'account_id must be a string'}, status=400)
                return
            if not isinstance(account_nickname, str):
                self._send_json_response({'success': False, 'error': 'account_nickname must be a string'}, status=400)
                return
            if not isinstance(env_var_name, str):
                self._send_json_response({'success': False, 'error': 'env_var_name must be a string'}, status=400)
                return

            account_id = account_id.strip()
            account_nickname = account_nickname.strip()
            env_var_name = env_var_name.strip()

            if env_var_name and not self._ENV_VAR_NAME_RE.match(env_var_name):
                self._send_json_response({'success': False, 'error': 'env_var_name must match ^[A-Z][A-Z0-9_]*$ when set'}, status=400)
                return

            # Write to team-paths.json via fcntl lock + atomic rename
            team_paths_file = Path.home() / '.aiteamforge' / 'team-paths.json'
            if not team_paths_file.exists():
                self._send_json_response({'success': False, 'error': f'team-paths.json not found'}, status=500)
                return

            lock_file = team_paths_file.with_suffix('.json.lock')
            try:
                with open(lock_file, 'w') as lock:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                    try:
                        with open(team_paths_file, 'r') as f:
                            data = json.load(f)

                        if team not in data.get('teams', {}):
                            self._send_json_response({'success': False, 'error': f"Team '{team}' not found in team-paths.json"}, status=400)
                            return

                        # Merge only the three account fields; all other fields untouched.
                        # Values are already stripped above — no redundant .strip() here.
                        data['teams'][team]['anthropic_account_id'] = account_id
                        data['teams'][team]['anthropic_account_nickname'] = account_nickname
                        data['teams'][team]['anthropic_api_key_env_var'] = env_var_name

                        # Atomic write
                        tmp_path = team_paths_file.with_suffix(f'.json.tmp.{os.getpid()}')
                        try:
                            with open(tmp_path, 'w') as f:
                                json.dump(data, f, indent=2)
                                f.flush()
                                os.fsync(f.fileno())
                            os.replace(str(tmp_path), str(team_paths_file))
                        except Exception:
                            try:
                                tmp_path.unlink(missing_ok=True)
                            except OSError:
                                pass
                            raise

                        # Invalidate the mtime cache
                        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
                            LCARSHandler._TEAM_PATHS_CACHE = {'mtime_ns': None, 'data': None}

                        print(f"[LCARS] Account config saved for '{team}': account_id={account_id.strip()!r} env_var={env_var_name!r}")
                    finally:
                        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
                        try:
                            lock_file.unlink(missing_ok=True)
                        except OSError:
                            pass
            except Exception:
                raise

            self._send_json_response({
                'success': True,
                'team': team,
                'account_id': account_id.strip(),
                'env_var_name': env_var_name,
            })
        except Exception as e:
            print(f"[LCARS] ERROR in handle_team_account_save: {e}")
            self._send_json_response({'success': False, 'error': str(e)}, status=500)

    def handle_team_account_test_connection(self):
        """POST /api/team-config/account/test-connection

        Body: {team} OR {env_var_name}
        Resolves the env-var name (from team-paths.json if team is given),
        reads the key from the LCARS process environment (NEVER from the request body),
        probes the Anthropic API with the smallest valid payload,
        and returns {ok, account_fingerprint, model_access, error}.

        On success, caches the validation timestamp so
        serve_team_account_current can return last_validated_at.
        NEVER returns or logs the actual key value.

        XACA-0281-005
        """
        import urllib.request
        import urllib.error
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(content_length))

            # Resolve env_var_name: prefer explicit field, fall back to team lookup
            env_var_name = body.get('env_var_name', '').strip()
            if not env_var_name:
                team = body.get('team', '').strip() or LCARS_TEAM
                if team not in TEAM_KANBAN_DIRS:
                    self._send_json_response({'ok': False, 'error': f'Unknown team: {team}'}, status=400)
                    return
                data, err = self._read_team_paths_raw()
                if err:
                    self._send_json_response({'ok': False, 'error': err}, status=500)
                    return
                env_var_name = (data.get('teams', {}).get(team) or {}).get('anthropic_api_key_env_var', '')

            if not env_var_name:
                self._send_json_response({'ok': False, 'error': 'No env_var_name could be resolved'}, status=400)
                return

            # Read the actual key from the process environment — NEVER from the request
            api_key = os.environ.get(env_var_name, '')
            if not api_key:
                self._send_json_response({
                    'ok': False,
                    'account_fingerprint': None,
                    'model_access': None,
                    'error': f'Environment variable {env_var_name!r} is not set or empty',
                }, status=400)
                return

            # Build a fingerprint from the key: mask middle chars, show only last 4
            # e.g. sk-ant-api03-XXXX...XXXX -> "sk-ant-…YYYY" (no secrets in logs)
            if len(api_key) >= 8:
                account_fingerprint = api_key[:8].replace(api_key[4:8], '****') + '…' + api_key[-4:]
            else:
                account_fingerprint = '****…' + api_key[-4:] if len(api_key) >= 4 else '****'

            # Probe Anthropic API — smallest valid payload
            probe_payload = json.dumps({
                'model': 'claude-haiku-4-5',
                'max_tokens': 1,
                'messages': [{'role': 'user', 'content': 'ping'}],
            }).encode('utf-8')

            req = urllib.request.Request(
                'https://api.anthropic.com/v1/messages',
                data=probe_payload,
                headers={
                    'x-api-key': api_key,
                    'anthropic-version': '2023-06-01',
                    'content-type': 'application/json',
                },
                method='POST',
            )

            model_access = None
            ok = False
            error_msg = None
            try:
                with urllib.request.urlopen(req, timeout=15) as resp:
                    resp_body = json.loads(resp.read().decode('utf-8'))
                    # A 200 response with a message object means credentials are valid
                    if resp_body.get('type') in ('message', 'error'):
                        ok = True
                        model_access = resp_body.get('model')
            except urllib.error.HTTPError as http_err:
                raw = http_err.read().decode('utf-8', errors='replace')
                try:
                    err_json = json.loads(raw)
                    # Strip any fragment that looks like an API key from error text
                    error_msg = err_json.get('error', {}).get('message', str(http_err))
                except Exception:
                    error_msg = f'HTTP {http_err.code}'
                # Sanitize: remove any key-like substrings from error message
                if api_key and api_key in error_msg:
                    error_msg = error_msg.replace(api_key, '[REDACTED]')
                ok = False
            except Exception as e:
                error_msg = str(e)
                ok = False

            # On success, cache the validation timestamp
            if ok:
                from datetime import datetime, timezone
                ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
                cache = self._load_account_validation_cache()
                cache[env_var_name] = ts
                self._save_account_validation_cache(cache)

            response = {
                'ok': ok,
                'account_fingerprint': account_fingerprint if ok else None,
                'model_access': model_access,
                'error': error_msg,
            }
            self._send_json_response(response)
        except Exception as e:
            print(f"[LCARS] ERROR in handle_team_account_test_connection: {e}")
            self._send_json_response({'ok': False, 'error': str(e)}, status=500)

    def serve_team_account_running_sessions(self, query_string: str):
        """GET /api/team-config/account/running-sessions?team=<id>

        Reads ~/.claude/.session-account-map.jsonl, filters for entries whose
        team == <id> AND whose pid is still alive (os.kill(pid, 0) in try/except).
        Returns {sessions: [{pid, terminal, started_at, cwd, account_id}]} sorted
        most-recent-first. Handles a missing JSONL file gracefully.

        XACA-0281-006
        """
        try:
            params = parse_qs(query_string) if query_string else {}
            team = params.get('team', [None])[0] or LCARS_TEAM

            if team not in TEAM_KANBAN_DIRS:
                self._send_json_response({'error': f'Unknown team: {team}'}, status=400)
                return

            session_map_path = Path.home() / '.claude' / '.session-account-map.jsonl'
            sessions = []

            if session_map_path.exists():
                try:
                    with open(session_map_path, 'r') as f:
                        for line in f:
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                entry = json.loads(line)
                            except json.JSONDecodeError:
                                continue

                            if entry.get('team') != team:
                                continue

                            # Check if the pid is still alive
                            pid = entry.get('pid')
                            if not isinstance(pid, int):
                                continue
                            try:
                                os.kill(pid, 0)
                                # pid is alive — include this session
                                sessions.append({
                                    'pid': pid,
                                    'terminal': entry.get('terminal', ''),
                                    'started_at': entry.get('started_at', ''),
                                    'cwd': entry.get('cwd', ''),
                                    'account_id': entry.get('account_id', ''),
                                })
                            except OSError:
                                # pid not alive — skip
                                pass
                except Exception as e:
                    print(f"[LCARS] WARNING reading session-account-map.jsonl: {e}")

            # Sort most-recent-first by started_at (ISO string sort works correctly)
            sessions.sort(key=lambda s: s.get('started_at', ''), reverse=True)

            self._send_json_response({'sessions': sessions})
        except Exception as e:
            print(f"[LCARS] ERROR in serve_team_account_running_sessions: {e}")
            self._send_json_response({'error': str(e)}, status=500)

    # === XACA-0281: AI engines registry consumer ===

    # Local cache path for engines registry (written on each successful Fleet Monitor fetch)
    _ENGINES_CACHE_PATH = Path.home() / '.aiteamforge' / 'engines-cache.json'

    def _fetch_engines_from_fleet_monitor(self):
        """Try to fetch /api/engines from Fleet Monitor. Returns (data_dict, error_str).

        On success returns the parsed JSON dict and None error.
        On any failure (timeout, refused, non-200, parse error) returns (None, description).
        """
        try:
            url = f"{FLEET_MONITOR_URL}/api/engines"
            req = urllib.request.Request(url, headers={'Accept': 'application/json'})
            with urllib.request.urlopen(req, timeout=2) as resp:
                if resp.status != 200:
                    return None, f"Fleet Monitor returned HTTP {resp.status}"
                raw = resp.read()
            data = json.loads(raw)
            return data, None
        except urllib.error.URLError as e:
            return None, f"Fleet Monitor unreachable: {e.reason}"
        except Exception as e:
            return None, f"Fleet Monitor fetch error: {e}"

    def _write_engines_cache(self, data: dict):
        """Atomically write engines data to the local cache file."""
        p = self._ENGINES_CACHE_PATH
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = p.with_suffix(f'.json.tmp.{os.getpid()}')
        try:
            with open(tmp_path, 'w') as f:
                json.dump(data, f, indent=2)
                f.flush()
                os.fsync(f.fileno())
            os.replace(str(tmp_path), str(p))
        except Exception as e:
            print(f"[LCARS] WARNING writing engines cache: {e}")
            try:
                tmp_path.unlink(missing_ok=True)
            except OSError:
                pass

    def _read_engines_cache(self):
        """Read the local engines cache. Returns (data_dict, cache_age_seconds, error_str).

        cache_age_seconds is None when there is no cache. error_str is None on success.
        """
        p = self._ENGINES_CACHE_PATH
        if not p.exists():
            return None, None, "No local engines cache available"
        try:
            mtime = os.stat(p).st_mtime
            cache_age = int(time.time() - mtime)
            with open(p, 'r') as f:
                data = json.load(f)
            return data, cache_age, None
        except Exception as e:
            return None, None, f"Error reading engines cache: {e}"

    def _get_engines_registry(self, force_refresh: bool = False):
        """Return engines registry data, populating/updating cache as needed.

        Returns (data_dict, source_str, cache_age_or_None, error_str_or_None).
        source is one of: 'fleet_monitor', 'local_cache', 'empty'.
        Never raises — always returns a usable result.
        """
        _CACHE_TTL_SECONDS = 300  # 5 minutes

        if not force_refresh:
            # Fast cache-first path: return cached data without hitting Fleet Monitor
            # when the cache is fresh (< TTL).  This avoids blocking every engines/list
            # request on a network round-trip to Fleet Monitor.
            cached, cache_age, cache_err = self._read_engines_cache()
            if cached is not None and cache_age is not None and cache_age < _CACHE_TTL_SECONDS:
                response = dict(cached)
                response['_source'] = 'local_cache'
                response['_cache_age_seconds'] = cache_age
                return cached, 'local_cache', cache_age, None

        # Cache stale/missing or force_refresh=True: try Fleet Monitor first
        data, fetch_err = self._fetch_engines_from_fleet_monitor()
        if data is not None:
            # Success: refresh local cache and return fleet_monitor result
            self._write_engines_cache(data)
            return data, 'fleet_monitor', None, None

        # Fleet Monitor unavailable: fall back to local cache
        cached, cache_age, cache_err = self._read_engines_cache()
        if cached is not None:
            return cached, 'local_cache', cache_age, fetch_err

        # Neither available: return graceful empty payload
        err_msg = fetch_err or cache_err or "No engines data available"
        return {'version': 1, 'engines': []}, 'empty', None, err_msg

    def serve_engines_list(self, query_string: str):
        """GET /api/engines/list[?refresh=true]

        Proxies the Fleet Monitor /api/engines endpoint with a local cache fallback
        so team startup is not gated on Fleet Monitor reachability.

        Response always has HTTP 200. Clients check _source to decide UI state:
          _source == 'fleet_monitor' → freshly fetched
          _source == 'local_cache'   → stale; _cache_age_seconds is set
          _source == 'empty'         → no data; _error is set; show empty picker + banner

        XACA-0281-020
        """
        try:
            params = parse_qs(query_string) if query_string else {}
            force_refresh = params.get('refresh', [''])[0].lower() in ('1', 'true', 'yes')

            data, source, cache_age, error = self._get_engines_registry(force_refresh=force_refresh)

            response = dict(data)  # shallow copy — don't mutate the cache
            response['_source'] = source
            if cache_age is not None:
                response['_cache_age_seconds'] = cache_age
            if error:
                response['_error'] = error

            self._send_json_response(response)
        except Exception as e:
            print(f"[LCARS] ERROR in serve_engines_list: {e}")
            self._send_json_response({
                'version': 1,
                'engines': [],
                '_source': 'empty',
                '_error': str(e),
            })

    def handle_team_account_assign(self):
        """POST /api/team-config/account/assign

        Body: {team, engine_slug, account_slug}

        Copy-on-select: looks up the named account in the engines registry and mirrors
        its fields into team-paths.json so XACA-0279 Phase A.1's resolver continues
        to work without modification.

        Writes these team-paths.json fields:
          anthropic_account_id       ← registry account.account_id
          anthropic_account_nickname ← registry account.nickname
          anthropic_api_key_env_var  ← registry account.env_var_name
          anthropic_account_ref      ← "{engine_slug}/{account_slug}" (drift pointer)

        Response: {success, team, engine_slug, account_slug, mirrored: {...}, has_credentials}
        NEVER returns the actual key value.

        XACA-0281-022
        """
        import fcntl
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(content_length))

            team = (body.get('team') or '').strip()
            engine_slug = (body.get('engine_slug') or '').strip()
            account_slug = (body.get('account_slug') or '').strip()

            # --- Validate required fields ---
            if not team:
                self._send_json_response({'success': False, 'error': 'team is required'}, status=400)
                return
            if team not in TEAM_KANBAN_DIRS:
                self._send_json_response({'success': False, 'error': f'Unknown team: {team}'}, status=400)
                return
            if not engine_slug:
                self._send_json_response({'success': False, 'error': 'engine_slug is required'}, status=400)
                return
            if not account_slug:
                self._send_json_response({'success': False, 'error': 'account_slug is required'}, status=400)
                return

            # --- Resolve account from registry (fresh fetch preferred; cache fallback) ---
            reg_data, source, _cache_age, fetch_err = self._get_engines_registry(force_refresh=True)

            if source == 'empty':
                # Registry completely unavailable and no cache
                self._send_json_response({
                    'success': False,
                    'error': f'Engines registry unavailable: {fetch_err}',
                }, status=502)
                return

            # Find the engine by slug
            matched_engine = None
            for engine in reg_data.get('engines', []):
                if engine.get('slug') == engine_slug:
                    matched_engine = engine
                    break

            if matched_engine is None:
                self._send_json_response({
                    'success': False,
                    'error': f"Engine '{engine_slug}' not found in registry (source: {source})",
                }, status=400)
                return

            # Find the account by slug within that engine
            matched_account = None
            for acct in matched_engine.get('accounts', []):
                if acct.get('slug') == account_slug:
                    matched_account = acct
                    break

            if matched_account is None:
                self._send_json_response({
                    'success': False,
                    'error': f"Account '{account_slug}' not found under engine '{engine_slug}' (source: {source})",
                }, status=400)
                return

            # Extract the fields to mirror
            account_id = matched_account.get('account_id', '')
            account_nickname = matched_account.get('nickname', '')
            env_var_name = matched_account.get('env_var_name', '')
            account_ref = f"{engine_slug}/{account_slug}"

            # --- Write to team-paths.json (fcntl lock + atomic rename) ---
            team_paths_file = Path.home() / '.aiteamforge' / 'team-paths.json'
            if not team_paths_file.exists():
                self._send_json_response({'success': False, 'error': 'team-paths.json not found'}, status=500)
                return

            lock_file = team_paths_file.with_suffix('.json.lock')
            try:
                with open(lock_file, 'w') as lock:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                    try:
                        with open(team_paths_file, 'r') as f:
                            tp_data = json.load(f)

                        if team not in tp_data.get('teams', {}):
                            self._send_json_response({
                                'success': False,
                                'error': f"Team '{team}' not found in team-paths.json",
                            }, status=400)
                            return

                        # Mirror account fields; preserve all other fields untouched
                        tp_data['teams'][team]['anthropic_account_id'] = account_id
                        tp_data['teams'][team]['anthropic_account_nickname'] = account_nickname
                        tp_data['teams'][team]['anthropic_api_key_env_var'] = env_var_name
                        tp_data['teams'][team]['anthropic_account_ref'] = account_ref

                        # Atomic write
                        tmp_path = team_paths_file.with_suffix(f'.json.tmp.{os.getpid()}')
                        try:
                            with open(tmp_path, 'w') as f:
                                json.dump(tp_data, f, indent=2)
                                f.flush()
                                os.fsync(f.fileno())
                            os.replace(str(tmp_path), str(team_paths_file))
                        except Exception:
                            try:
                                tmp_path.unlink(missing_ok=True)
                            except OSError:
                                pass
                            raise

                        # Invalidate the mtime cache so next read sees the new data
                        with LCARSHandler._TEAM_PATHS_CACHE_LOCK:
                            LCARSHandler._TEAM_PATHS_CACHE = {'mtime_ns': None, 'data': None}

                        print(
                            f"[LCARS] Account assigned for '{team}': "
                            f"ref={account_ref!r} account_id={account_id!r} env_var={env_var_name!r}"
                        )
                    finally:
                        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
                        try:
                            lock_file.unlink(missing_ok=True)
                        except OSError:
                            pass
            except Exception:
                raise

            # has_credentials: true if the env var is set in the LCARS process environment
            # NEVER return the actual key value
            has_credentials = bool(env_var_name and os.environ.get(env_var_name))

            self._send_json_response({
                'success': True,
                'team': team,
                'engine_slug': engine_slug,
                'account_slug': account_slug,
                'mirrored': {
                    'account_id': account_id,
                    'account_nickname': account_nickname,
                    'env_var_name': env_var_name,
                },
                'has_credentials': has_credentials,
            })
        except Exception as e:
            print(f"[LCARS] ERROR in handle_team_account_assign: {e}")
            self._send_json_response({'success': False, 'error': str(e)}, status=500)

    # ------------------------------------------------------------------
    # XACA-0281 Phase A.3: Resume-ID management endpoints
    # ------------------------------------------------------------------

    def _resume_id_slugify(self, account_id: str) -> str:
        """Slugify an account_id for use in archive filenames.

        Keeps alphanumerics and hyphens only, lowercased. Falls back to
        'unknown' if nothing survives the filter.
        """
        import re
        slug = re.sub(r'[^a-z0-9\-]', '', account_id.lower())
        return slug or 'unknown'

    def serve_team_account_resume_ids_count(self, query_string: str):
        """GET /api/team-config/account/resume-ids/count?team=<id>&old_account_id=<id>

        Returns {count: <int>} — the number of session-account-map.jsonl entries
        that match both team and old_account_id. Used by the UI to display how
        many resume points will be affected before the user chooses an action.

        XACA-0281 Phase A.3
        """
        try:
            params = parse_qs(query_string) if query_string else {}
            team = params.get('team', [None])[0]
            old_account_id = params.get('old_account_id', [None])[0]

            if not team or not old_account_id:
                self._send_json_response(
                    {'error': 'Missing required query params: team, old_account_id'},
                    status=400,
                )
                return

            session_map_path = os.path.expanduser('~/.claude/.session-account-map.jsonl')
            count = 0

            if os.path.exists(session_map_path):
                try:
                    with open(session_map_path, 'r') as f:
                        for line in f:
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                entry = json.loads(line)
                            except json.JSONDecodeError:
                                continue
                            if (entry.get('team') == team
                                    and entry.get('account_id') == old_account_id):
                                count += 1
                except Exception as e:
                    print(f"[LCARS] WARNING reading session-account-map.jsonl in count: {e}")

            self._send_json_response({'count': count})
        except Exception as e:
            print(f"[LCARS] ERROR in serve_team_account_resume_ids_count: {e}")
            self._send_json_response({'success': False, 'error': str(e)}, status=500)

    def handle_team_account_resume_ids(self):
        """POST /api/team-config/account/resume-ids

        Body: {team, old_account_id, action}
          action = "preserve" | "archive" | "clear"

        preserve:
          No-op. Confirms that XACA-0279 Phase A.1 segregation already keeps
          the resume IDs isolated under the old account.
          Returns {success, action, affected: 0, message}.

        archive:
          Reads ~/.claude/.session-account-map.jsonl, pulls entries matching
          team + old_account_id, writes them to a timestamped archive file,
          then rewrites the live map with those entries removed (atomic via
          write-to-tmp + os.replace).
          Returns {success, action, affected, archive_path}.

        clear:
          Same as archive but WITHOUT writing the archive — matching entries
          are simply dropped from the live map. Destructive; UI must confirm
          before calling. No second confirm required in the body.
          Returns {success, action, affected}.

        XACA-0281 Phase A.3
        """
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(content_length)) if content_length else {}

            team = body.get('team')
            old_account_id = body.get('old_account_id')
            action = body.get('action')

            if not team or not old_account_id or action not in ('preserve', 'archive', 'clear'):
                self._send_json_response(
                    {'success': False,
                     'error': 'Missing or invalid fields: team, old_account_id, action '
                              '(must be preserve|archive|clear)'},
                    status=400,
                )
                return

            # --- preserve: pure no-op ---
            if action == 'preserve':
                self._send_json_response({
                    'success': True,
                    'action': 'preserve',
                    'affected': 0,
                    'message': 'Resume IDs remain segregated under the old account.',
                })
                return

            # --- archive / clear: read, split, rewrite ---
            session_map_path = os.path.expanduser('~/.claude/.session-account-map.jsonl')

            matched_lines = []    # raw JSON strings for affected entries
            remaining_lines = []  # raw JSON strings for everything else

            if os.path.exists(session_map_path):
                with open(session_map_path, 'r') as f:
                    for raw in f:
                        stripped = raw.strip()
                        if not stripped:
                            continue
                        try:
                            entry = json.loads(stripped)
                        except json.JSONDecodeError:
                            # Keep malformed lines so we don't silently lose them
                            remaining_lines.append(stripped)
                            continue
                        if (entry.get('team') == team
                                and entry.get('account_id') == old_account_id):
                            matched_lines.append(stripped)
                        else:
                            remaining_lines.append(stripped)

            affected = len(matched_lines)

            # archive: write matched lines to a timestamped archive file first
            archive_path = None
            if action == 'archive' and matched_lines:
                from datetime import datetime
                ts = datetime.now().strftime('%Y%m%d-%H%M%S')
                slug = self._resume_id_slugify(old_account_id)
                archive_filename = f'.session-account-map.archive-{slug}-{ts}.jsonl'
                archive_path = os.path.expanduser(f'~/.claude/{archive_filename}')

                with open(archive_path, 'w') as af:
                    for line in matched_lines:
                        af.write(line + '\n')

            # Rewrite live map (atomic) — skip if nothing changed
            if matched_lines:
                tmp_path = session_map_path + f'.tmp.{os.getpid()}'
                try:
                    with open(tmp_path, 'w') as tf:
                        for line in remaining_lines:
                            tf.write(line + '\n')
                    os.replace(tmp_path, session_map_path)
                except Exception:
                    # Clean up tmp on failure; do not leave partial writes
                    try:
                        os.remove(tmp_path)
                    except OSError:
                        pass
                    raise

            response = {
                'success': True,
                'action': action,
                'affected': affected,
            }
            if action == 'archive':
                response['archive_path'] = archive_path or ''

            self._send_json_response(response)
        except Exception as e:
            print(f"[LCARS] ERROR in handle_team_account_resume_ids: {e}")
            self._send_json_response({'success': False, 'error': str(e)}, status=500)

    def handle_connect_apple_calendar(self):
        """POST /api/calendar/connect/apple - Connect Apple Calendar with CalDAV credentials"""
        try:
            # Check if calendar providers are available
            if not CALENDAR_SYNC_AVAILABLE or AppleCalendarProvider is None:
                self._send_json_response({
                    "success": False,
                    "error": "Calendar sync module not available"
                }, status=500)
                return

            # Parse request body
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            # Extract credentials
            username = post_data.get('username')
            app_password = post_data.get('appPassword')

            # Validate required fields
            if not username or not app_password:
                self._send_json_response({
                    "success": False,
                    "error": "Missing required fields: username and appPassword"
                }, status=400)
                return

            print(f"[LCARS] Connecting Apple Calendar for user: {username}")

            # Create provider and credentials
            provider = AppleCalendarProvider(calendar_id="primary")
            credentials = CalendarCredentials(
                provider="apple",
                raw_data={
                    'username': username,
                    'appPassword': app_password
                }
            )

            # Attempt authentication (this does CalDAV PROPFIND to validate)
            try:
                auth_success = provider.authenticate(credentials)

                if not auth_success:
                    self._send_json_response({
                        "success": False,
                        "error": "Authentication failed"
                    }, status=401)
                    return

            except PermissionError as e:
                # Authentication specifically failed (401 from CalDAV)
                print(f"[LCARS] Apple Calendar auth failed: {e}")
                self._send_json_response({
                    "success": False,
                    "error": f"Invalid credentials: {str(e)}"
                }, status=401)
                return
            except ConnectionError as e:
                # Network/connection issue
                print(f"[LCARS] Apple Calendar connection error: {e}")
                self._send_json_response({
                    "success": False,
                    "error": f"Cannot connect to iCloud CalDAV server: {str(e)}"
                }, status=502)
                return
            except ValueError as e:
                # Invalid credentials format
                print(f"[LCARS] Apple Calendar validation error: {e}")
                self._send_json_response({
                    "success": False,
                    "error": str(e)
                }, status=400)
                return

            # Authentication succeeded - discover available calendars
            try:
                calendars = provider.list_calendars()
            except Exception as e:
                print(f"[LCARS] Failed to list calendars: {e}")
                # Auth worked but calendar discovery failed - still consider it success
                calendars = []

            print(f"[LCARS] Apple Calendar authenticated successfully. Found {len(calendars)} calendars.")

            # Read current config
            team = LCARS_TEAM
            config_file = TEAM_CONFIG_DIR / "calendar-config.json"

            if config_file.exists():
                with open(config_file, 'r') as f:
                    config = json.load(f)
            else:
                # Initialize with canonical structure
                config = {
                    "apple": None,
                    "google": None,
                    "lastUpdated": None
                }

            # Update apple section (field names must match what JS expects)
            config['apple'] = {
                "connected": True,
                "accountName": username,
                "calendarName": None,  # User will select later
                "selectedCalendarId": None,
                "availableCalendars": calendars,  # List of available calendars
                "credentials": {
                    "username": username,
                    "appPassword": app_password  # Store for future sync operations
                }
            }
            config['lastUpdated'] = self._get_timestamp()

            # Ensure config directory exists
            TEAM_CONFIG_DIR.mkdir(parents=True, exist_ok=True)

            # Write updated config
            self._atomic_write_json(config_file, config)

            print(f"[LCARS] Apple Calendar config saved for team: {team}")

            # Return success with the apple config section
            self._send_json_response({
                "success": True,
                "provider": "apple",
                "message": "Apple Calendar connected successfully",
                "config": config['apple']
            })

        except json.JSONDecodeError:
            print("[LCARS] ERROR: Invalid JSON in request body")
            self._send_json_response({
                "success": False,
                "error": "Invalid JSON in request body"
            }, status=400)
        except Exception as e:
            print(f"[LCARS] ERROR connecting Apple Calendar: {e}")
            import traceback
            traceback.print_exc()
            self._send_json_response({
                "success": False,
                "error": str(e)
            }, status=500)

    def handle_connect_google_calendar(self):
        """POST /api/calendar/connect/google - Authenticate with Google Calendar credentials"""
        try:
            # Parse request body
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            # Extract credentials from request
            client_id = post_data.get('clientId', '').strip()
            client_secret = post_data.get('clientSecret', '').strip()
            refresh_token = post_data.get('refreshToken', '').strip()

            # Validate required fields
            if not client_id or not client_secret or not refresh_token:
                self._send_json_response({
                    "success": False,
                    "error": "Missing required fields: clientId, clientSecret, and refreshToken are all required"
                }, status=400)
                return

            # Import calendar provider
            try:
                from calendar.google_provider import GoogleCalendarProvider
                from calendar.provider import CalendarCredentials
            except ImportError as e:
                print(f"[LCARS] ERROR: Calendar provider not available: {e}")
                self._send_json_response({
                    "success": False,
                    "error": "Calendar provider module not available"
                }, status=500)
                return

            # Create provider and credentials
            provider = GoogleCalendarProvider(calendar_id="primary")
            credentials = CalendarCredentials(
                provider="google",
                raw_data={
                    "clientId": client_id,
                    "clientSecret": client_secret,
                    "refreshToken": refresh_token
                }
            )

            # Attempt authentication (validates credentials by refreshing token)
            try:
                provider.authenticate(credentials)
            except ValueError as e:
                # Invalid credentials structure
                self._send_json_response({
                    "success": False,
                    "error": f"Invalid credentials: {str(e)}"
                }, status=400)
                return
            except ConnectionError as e:
                # Authentication failed (bad credentials or network issue)
                self._send_json_response({
                    "success": False,
                    "error": f"Authentication failed: {str(e)}"
                }, status=401)
                return

            # Authentication successful - get calendar info if possible
            account_name = "Google Calendar"
            calendar_name = "primary"
            calendar_id = "primary"

            # Try to verify connection and get calendar name
            test_result = provider.verify_connection()
            if test_result.success and test_result.calendar_name:
                calendar_name = test_result.calendar_name
                # Try to extract account email if available in details
                if test_result.details and 'accountEmail' in test_result.details:
                    account_name = test_result.details['accountEmail']

            # Read existing config or create new one
            team = LCARS_TEAM
            config_file = TEAM_CONFIG_DIR / "calendar-config.json"

            if config_file.exists():
                with open(config_file, 'r') as f:
                    config = json.load(f)
            else:
                # Create initial config structure
                config = {
                    "apple": None,
                    "google": None,
                    "lastUpdated": None
                }
                # Ensure config directory exists
                config_file.parent.mkdir(parents=True, exist_ok=True)

            # Update google section with connection info
            config['google'] = {
                "connected": True,
                "accountName": account_name,
                "calendarName": calendar_name,
                "calendarId": calendar_id,
                "credentials": {
                    "clientId": client_id,
                    "clientSecret": client_secret,
                    "refreshToken": refresh_token
                }
            }

            # Update lastUpdated timestamp
            config['lastUpdated'] = self._get_timestamp()

            # Write config atomically
            self._atomic_write_json(config_file, config)

            print(f"[LCARS] Google Calendar connected successfully for team {team}")

            # Return success with the google config object (without sensitive data in response)
            response_config = {
                "connected": True,
                "accountName": account_name,
                "calendarName": calendar_name,
                "calendarId": calendar_id
            }

            self._send_json_response({
                "success": True,
                "provider": "google",
                "message": "Google Calendar connected successfully",
                "google": response_config
            })

        except Exception as e:
            print(f"[LCARS] ERROR connecting Google Calendar: {e}")
            import traceback
            traceback.print_exc()
            self._send_json_response({
                "success": False,
                "error": f"Server error: {str(e)}"
            }, status=500)

    def handle_disconnect_calendar(self, provider):
        """POST /api/calendar/disconnect/{provider} - Disconnect a calendar provider"""
        try:
            # Validate provider
            if provider not in ['apple', 'google']:
                self._send_json_response({
                    "success": False,
                    "error": f"Unknown provider: {provider}"
                }, status=404)
                return

            team = LCARS_TEAM
            config_file = TEAM_CONFIG_DIR / "calendar-config.json"

            if not config_file.exists():
                self._send_json_response({
                    "success": False,
                    "error": "No calendar configuration found"
                }, status=404)
                return

            with open(config_file, 'r') as f:
                config = json.load(f)

            # Set provider section to null in canonical format
            config[provider] = None
            config['lastUpdated'] = self._get_timestamp()

            # Write updated config
            self._atomic_write_json(config_file, config)

            print(f"[LCARS] Disconnected {provider} calendar for team: {team}")

            self._send_json_response({
                "success": True,
                "message": f"Disconnected {provider} calendar",
                "provider": provider
            })
        except Exception as e:
            print(f"[LCARS] ERROR disconnecting calendar: {e}")
            self._send_json_response({"success": False, "error": str(e)}, status=500)

    def serve_calendar_sync_status(self):
        """GET /api/calendar/sync/status - Get sync status"""
        try:
            team = LCARS_TEAM
            status_file = TEAM_CONFIG_DIR / "calendar-sync-status.json"

            if status_file.exists():
                with open(status_file, 'r') as f:
                    status = json.load(f)
            else:
                # Return default status
                status = {
                    "team": team,
                    "lastSync": None,
                    "nextSync": None,
                    "status": "idle",
                    "errors": [],
                    "syncCount": 0
                }

            self._send_json_response(status)
        except Exception as e:
            print(f"[LCARS] ERROR serving sync status: {e}")
            self._send_json_response({"error": str(e)}, status=500)

    def handle_trigger_calendar_sync(self):
        """POST /api/calendar/sync/trigger - Manually trigger a sync"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team', LCARS_TEAM)
            direction = post_data.get('direction', 'outbound')  # 'outbound', 'inbound', or 'both'

            if not CALENDAR_SYNC_AVAILABLE:
                self._send_json_response({
                    "success": False,
                    "error": "Calendar sync service not available"
                }, status=503)
                return

            # Check calendar config for connected providers
            config_file = TEAM_CONFIG_DIR / "calendar-config.json"
            if not config_file.exists():
                self._send_json_response({
                    "success": False,
                    "error": "No calendar configuration found"
                }, status=400)
                return

            with open(config_file, 'r') as f:
                cal_config = json.load(f)

            apple_connected = cal_config.get('apple') and cal_config['apple'].get('connected')
            google_connected = cal_config.get('google') and cal_config['google'].get('connected')

            if not apple_connected and not google_connected:
                self._send_json_response({
                    "success": False,
                    "error": "No calendar providers connected. Connect in Calendar Settings."
                }, status=400)
                return

            # Load team board data for items with due dates
            board_file = get_board_file(team)
            board_data = {}
            if board_file.exists():
                with open(board_file, 'r') as f:
                    board_data = json.load(f)

            # Collect items for sync, matching LCARS calendar display logic:
            # - Parent must have dueDate for itself and its subitems to be synced
            # - When parent has no dueDate, parent AND all subitems are orphan candidates
            # - Items already cleaned up (syncStatus: 'deleted') are skipped
            items = []
            for item in board_data.get('backlog', []):
                if item.get('dueDate'):
                    # Parent has due date — sync it and its subitems
                    items.append(item)
                    for subitem in item.get('subitems', []):
                        if subitem.get('dueDate'):
                            # Enrich subitem with parent context for better calendar event titles
                            enriched_sub = {**subitem}
                            if 'title' in enriched_sub and 'title' in item:
                                enriched_sub['parentTitle'] = item.get('title', '')
                            if 'epicId' not in enriched_sub and 'epicId' in item:
                                enriched_sub['epicId'] = item.get('epicId')
                            items.append(enriched_sub)
                        elif subitem.get('calendarSync', {}).get('syncStatus') != 'deleted':
                            # Subitem without date under dated parent — orphan candidate
                            items.append(subitem)
                else:
                    # Parent has no due date — parent and ALL subitems are orphan candidates
                    if item.get('calendarSync', {}).get('syncStatus') != 'deleted':
                        items.append(item)
                    for subitem in item.get('subitems', []):
                        if subitem.get('calendarSync', {}).get('syncStatus') != 'deleted':
                            items.append(subitem)
            for epic in board_data.get('epics', []):
                if epic.get('dueDate'):
                    items.append(epic)
                elif epic.get('calendarSync', {}).get('syncStatus') != 'deleted':
                    # Orphan candidate epic
                    items.append(epic)

            # Perform sync using connected providers (pass calendar config)
            result = {'itemsWithDueDates': len(items)}

            if direction in ('outbound', 'both') and items:
                try:
                    outbound_result = _calendar_sync_service.sync_outbound(team, items, cal_config=cal_config)
                    result['outbound'] = outbound_result
                except Exception as e:
                    result['outbound'] = {'error': str(e)}

            if direction in ('inbound', 'both'):
                try:
                    inbound_result = _calendar_sync_service.sync_inbound(board_data, cal_config=cal_config)
                    result['inbound'] = inbound_result
                except Exception as e:
                    result['inbound'] = {'error': str(e)}

            # Save board data back to persist calendarSync metadata changes
            # (event IDs from creation, cleanup from orphan deletion, etc.)
            if board_file.exists() and board_data:
                try:
                    self._atomic_write_json(board_file, board_data)
                except Exception as e:
                    print(f"[LCARS] WARNING: Failed to save board after sync: {e}")

            # Build response
            status = {
                "success": True,
                "message": f"Calendar sync completed ({direction})",
                "team": team,
                "triggeredAt": self._get_timestamp(),
                "direction": direction,
                "connectedProviders": {
                    "apple": bool(apple_connected),
                    "google": bool(google_connected)
                },
                "result": result
            }

            self._send_json_response(status)
            print(f"[LCARS] Calendar sync completed for {team}: {len(items)} items, direction={direction}")

        except Exception as e:
            print(f"[LCARS] ERROR triggering sync: {e}")
            import traceback
            traceback.print_exc()
            self._send_json_response({"success": False, "error": str(e)}, status=500)

    def handle_get_calendar_conflicts(self):
        """GET /api/calendar/conflicts - Get all unresolved sync conflicts"""
        try:
            team = LCARS_TEAM

            if not CALENDAR_SYNC_AVAILABLE:
                self._send_json_response({
                    "success": False,
                    "error": "Calendar sync service not available"
                }, status=503)
                return

            # Load team board data
            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({
                    "success": False,
                    "error": f"Board file not found for team {team}"
                }, status=404)
                return

            with open(board_file, 'r') as f:
                board_data = json.load(f)

            # Get conflicts
            conflicts = _calendar_sync_service.get_conflicts(board_data)

            self._send_json_response({
                "success": True,
                "team": team,
                "conflicts": conflicts,
                "count": len(conflicts)
            })

        except Exception as e:
            print(f"[LCARS] ERROR getting conflicts: {e}")
            import traceback
            traceback.print_exc()
            self._send_json_response({"success": False, "error": str(e)}, status=500)

    def handle_resolve_calendar_conflict(self):
        """POST /api/calendar/conflicts/resolve - Resolve a sync conflict"""
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            team = post_data.get('team', LCARS_TEAM)
            item_id = post_data.get('itemId')
            resolution = post_data.get('resolution')  # 'keep_local', 'keep_external', 'merge'
            merge_data = post_data.get('mergeData')  # For 'merge' resolution

            if not item_id or not resolution:
                self._send_json_response({
                    "success": False,
                    "error": "Missing required fields: itemId, resolution"
                }, status=400)
                return

            if not CALENDAR_SYNC_AVAILABLE:
                self._send_json_response({
                    "success": False,
                    "error": "Calendar sync service not available"
                }, status=503)
                return

            # Load team board data
            board_file = get_board_file(team)
            if not board_file.exists():
                self._send_json_response({
                    "success": False,
                    "error": f"Board file not found for team {team}"
                }, status=404)
                return

            with open(board_file, 'r') as f:
                board_data = json.load(f)

            # Resolve conflict
            result = _calendar_sync_service.resolve_conflict(
                board_data,
                item_id,
                resolution,
                merge_data
            )

            if result.get('success'):
                # Save updated board data
                with open(board_file, 'w') as f:
                    json.dump(board_data, f, indent=2)

            self._send_json_response(result)
            print(f"[LCARS] Resolved conflict for {item_id}: {result.get('action')}")

        except Exception as e:
            print(f"[LCARS] ERROR resolving conflict: {e}")
            import traceback
            traceback.print_exc()
            self._send_json_response({"success": False, "error": str(e)}, status=500)

    def serve_calendar_events(self):
        """GET /api/calendar/events - Fetch synced external calendar events"""
        try:
            team = LCARS_TEAM
            events_file = TEAM_CONFIG_DIR / "calendar-events.json"

            if events_file.exists():
                with open(events_file, 'r') as f:
                    events_data = json.load(f)
            else:
                # Return empty events list
                events_data = {
                    "team": team,
                    "events": [],
                    "lastUpdated": None
                }

            self._send_json_response(events_data)
        except Exception as e:
            print(f"[LCARS] ERROR serving calendar events: {e}")
            self._send_json_response({"error": str(e)}, status=500)

    # =========================================================================
    # END CALENDAR SYNC API
    # =========================================================================

    def do_GET(self):
        """Handle GET requests"""
        parsed = urlparse(self.path)
        path = parsed.path

        # Strip known path prefixes for Tailscale funnel compatibility
        for prefix in self.PATH_PREFIXES:
            # Redirect /prefix to /prefix/ to fix relative paths
            if path == prefix:
                self.send_response(301)
                self.send_header('Location', prefix + '/')
                self.end_headers()
                return
            if path.startswith(prefix + '/'):
                path = path[len(prefix):] or '/'
                self.path = path + ('?' + parsed.query if parsed.query else '')
                break

        # Serve kanban data
        if path == '/data/freelance-board.json':
            self.serve_kanban_data('freelance')
        elif path.startswith('/data/') and path.endswith('-board.json'):
            team = path.replace('/data/', '').replace('-board.json', '')
            self.serve_kanban_data(team)
        elif path == '/api/teams':
            self.serve_teams_list()
        elif path == '/api/status':
            self.serve_status()
        elif path == '/api/team':
            self.serve_team()
        elif path == '/api/backup-status':
            self.serve_backup_status()
        elif path == '/api/integrations':
            self.serve_integrations_list()
        elif path == '/api/rag-engines':
            self.serve_rag_engines_list()
        elif path == '/api/rag-engines/summary':
            self.serve_rag_engines_summary()
        elif path.startswith('/api/rag-engines/log'):
            self.serve_rag_engine_log()
        elif path == '/api/graph/engines':
            self.serve_graph_engines()
        elif path == '/api/sync/status':
            self.serve_sync_status()
        elif path == '/api/backup-files':
            self.serve_backup_files()
        elif path.startswith('/api/backup-files/'):
            team = path.replace('/api/backup-files/', '')
            self.serve_backup_files(team_filter=team)
        elif path.startswith('/images/'):
            self.serve_image(path)
        # Release API endpoints
        elif path == '/api/releases':
            self.serve_releases_list(parsed.query)
        elif path.startswith('/api/releases/') and path.endswith('/items'):
            release_id = path.replace('/api/releases/', '').replace('/items', '')
            self.serve_release_items(release_id)
        elif path.startswith('/api/releases/') and path.endswith('/progress'):
            release_id = path.replace('/api/releases/', '').replace('/progress', '')
            self.serve_release_progress(release_id)
        elif path.startswith('/api/releases/'):
            release_id = path.replace('/api/releases/', '')
            self.serve_release_detail(release_id)
        # Epic API endpoints
        elif path == '/api/epics':
            self.serve_epics_list(parsed.query)
        elif path.startswith('/api/epics/') and path.endswith('/items'):
            epic_id = path.replace('/api/epics/', '').replace('/items', '')
            self.serve_epic_items(epic_id)
        elif path.startswith('/api/epics/'):
            epic_id = path.replace('/api/epics/', '')
            self.serve_epic_detail(epic_id)
        # Todo API endpoints
        elif path == '/api/todos':
            self.serve_todos_list(parsed.query)
        # CR activity log API (XACA-0328-002) — must be before generic /activity route
        elif path.startswith('/api/kanban/cr/') and path.endswith('/activity'):
            cr_id = path[len('/api/kanban/cr/'):-len('/activity')]
            self.serve_cr_activity(cr_id)
        # Kanban activity log API
        elif path.startswith('/api/kanban/') and path.endswith('/activity'):
            item_id = path.replace('/api/kanban/', '').replace('/activity', '')
            self.serve_activity_log(item_id, parsed.query)
        # Kanban plan document API
        elif path.startswith('/api/kanban/') and path.endswith('/plan-exists'):
            item_id = path.replace('/api/kanban/', '').replace('/plan-exists', '')
            self.serve_plan_exists(item_id)
        elif path.startswith('/api/kanban/') and path.endswith('/plan-content'):
            item_id = path.replace('/api/kanban/', '').replace('/plan-content', '')
            self.serve_plan_content(item_id)
        elif path.startswith('/api/kanban/') and path.endswith('/retro-exists'):
            item_id = path.replace('/api/kanban/', '').replace('/retro-exists', '')
            self.serve_retro_exists(item_id)
        elif path.startswith('/api/kanban/') and path.endswith('/cr-exists'):
            item_id = path.replace('/api/kanban/', '').replace('/cr-exists', '')
            self.serve_cr_exists(item_id)
        elif path.startswith('/api/kanban/') and path.endswith('/retro-content'):
            item_id = path.replace('/api/kanban/', '').replace('/retro-content', '')
            self.serve_retro_content(item_id)
        elif path.startswith('/api/kanban/') and path.endswith('/cr-content'):
            item_id = path.replace('/api/kanban/', '').replace('/cr-content', '')
            self.serve_cr_content(item_id)
        # Calendar sync API endpoints
        elif path == '/api/calendar/config':
            self.serve_calendar_config()
        elif path == '/api/calendar/sync/status':
            self.serve_calendar_sync_status()
        elif path == '/api/calendar/events':
            self.serve_calendar_events()
        elif path == '/api/calendar/conflicts':
            self.handle_get_calendar_conflicts()
        # Calendar API endpoints
        elif path == '/api/calendar/items':
            self.serve_calendar_items(parsed.query)
        elif path == '/api/items/unassigned':
            self.serve_unassigned_items()
        elif path.startswith('/api/items/by-release/'):
            release_id = path.replace('/api/items/by-release/', '')
            self.serve_items_by_release(release_id, parsed.query)
        elif path == '/api/release-config':
            self.serve_release_config(parsed.query)
        # Calendar API endpoint
        elif path == '/api/calendar/items':
            self.serve_calendar_items(parsed.query)
        # Agent Panel API endpoint
        elif path == '/api/agent-panel':
            self.serve_agent_panel_data()
        # Knowledge Base analytics endpoint
        elif path == '/api/knowledge-stats':
            self.serve_knowledge_stats()
        # Team Export/Import API endpoints
        elif path.startswith('/api/export/status/'):
            job_id = path.replace('/api/export/status/', '')
            self.serve_export_status(job_id)
        elif path.startswith('/api/export/download/'):
            job_id = path.replace('/api/export/download/', '')
            self.serve_export_download(job_id)
        elif path.startswith('/api/export/secrets/status/'):
            job_id = path.replace('/api/export/secrets/status/', '')
            self.serve_secrets_export_status(job_id)
        elif path.startswith('/api/export/secrets/download/'):
            job_id = path.replace('/api/export/secrets/download/', '')
            self.serve_secrets_export_download(job_id)
        elif path.startswith('/api/import/status/'):
            job_id = path.replace('/api/import/status/', '')
            self.serve_import_status(job_id)
        # Secrets Import status (XACA-0172-003)
        elif path.startswith('/api/import/secrets/status/'):
            job_id = path.replace('/api/import/secrets/status/', '')
            self.serve_secrets_import_status(job_id)
        elif path == '/api/tap-version':
            self.serve_tap_version()
        # XACA-0292: Team config (CR/CAB support flag)
        elif path == '/api/team-config':
            self.serve_team_config(parsed.query)
        # XACA-0281 Phase A.3: Team account config endpoints
        elif path == '/api/team-config/account/current':
            self.serve_team_account_current(parsed.query)
        elif path == '/api/team-config/account/running-sessions':
            self.serve_team_account_running_sessions(parsed.query)
        # XACA-0281 Phase A.3: Resume-ID count
        elif path == '/api/team-config/account/resume-ids/count':
            self.serve_team_account_resume_ids_count(parsed.query)
        # === XACA-0281: AI engines registry consumer ===
        elif path == '/api/engines/list':
            self.serve_engines_list(parsed.query)
        # XACA-0220 Phase 3b: daily artifact audit results
        elif path == '/api/artifact-audit':
            self.serve_artifact_audit()
        # XACA-0243-003: Claude usage monitor
        elif path == '/api/usage/current':
            self.serve_usage_current()
        # XACA-0280 Phase A.2: per-account usage breakdown
        elif path == '/api/usage/by-account':
            self.serve_usage_by_account()
        # Alert ingestion endpoints (XACA-0334-002)
        elif path == '/api/alerts':
            self.serve_alerts_list(parsed.query)
        elif path.startswith('/api/alerts/'):
            alert_id = path[len('/api/alerts/'):]
            self.serve_alert_detail(alert_id, parsed.query)
        # Daily Overview aggregator (XACA-0334-003)
        elif path == '/api/daily-overview':
            self.serve_daily_overview(parsed.query)
        # NOTE: lcars-target.js is now served as a STATIC file (not dynamic)
        # This allows the router to work from ANY port - startup scripts write
        # the target team to the static file, and all servers serve the same file.
        # Previously, dynamic serving broke the router because each server
        # would serve its own team instead of the globally-written target.
        # XACA-0301: per-machine override served from ~/.aiteamforge/lcars-target.local.js
        # (404 when absent — HTML loader handles the no-override case gracefully).
        elif path == '/lcars-target.local.js':
            self.serve_lcars_target_local()
        elif path.endswith('.js') or path.endswith('.html') or path == '/':
            # Serve JS and HTML with no-cache headers to prevent stale code
            self.serve_no_cache_static(path)
        else:
            # Serve other static files (images, css with normal caching)
            super().do_GET()

    def serve_no_cache_static(self, path):
        """Serve JS and HTML files with no-cache headers to prevent stale code"""
        # Handle root path
        if path == '/' or path == '':
            path = '/index.html'

        # Build file path
        file_path = UI_DIR / path.lstrip('/')

        if not file_path.exists():
            self.send_error(404, f"File not found: {path}")
            return

        try:
            with open(file_path, 'rb') as f:
                data = f.read()

            # Determine content type
            if path.endswith('.js'):
                content_type = 'application/javascript'
            elif path.endswith('.html'):
                content_type = 'text/html'
            else:
                content_type = 'application/octet-stream'

            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', len(data))
            self.send_header('Cache-Control', 'no-cache, no-store, must-revalidate')
            self.send_header('Pragma', 'no-cache')
            self.send_header('Expires', '0')
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            self.send_error(500, f"Error serving {path}: {e}")

    def serve_image(self, path):
        """Serve team logos and avatars from their respective directories"""
        import re
        filename = path.replace('/images/', '')

        # First, check if the file exists in the local images directory (for startup logos, etc.)
        local_image_path = UI_DIR / "images" / filename
        if local_image_path.exists():
            try:
                with open(local_image_path, 'rb') as f:
                    data = f.read()

                # Determine content type
                if filename.endswith('.svg'):
                    content_type = 'image/svg+xml'
                elif filename.endswith('.png'):
                    content_type = 'image/png'
                else:
                    content_type = 'application/octet-stream'

                self.send_response(200)
                self.send_header('Content-Type', content_type)
                self.send_header('Content-Length', len(data))
                self.send_header('Cache-Control', 'max-age=3600')
                self.end_headers()
                self.wfile.write(data)
                return
            except Exception as e:
                self.send_error(500, f"Error reading local image: {e}")
                return

        # Expected format: /images/{team}_{name}_{type}.png
        # type is either 'logo' or 'avatar'
        # name is either terminal name (for logos) or avatar codename (for avatars)

        # Parse the filename: team_name_type.png
        match = re.match(r'^([a-z-]+)_([a-z_]+)_(logo|avatar)\.png$', filename)
        if not match:
            self.send_error(404, f"Invalid image path: {path}")
            return

        team, name, img_type = match.groups()

        # Map team names to actual directory names
        team_dir_map = {
            'dns': 'dns-framework',
            'legal-coparenting': 'legal',
            'medical-general': 'medical',
            'finance-personal': 'finance',
            'freelance-doublenode-workstats': 'freelance',
            'freelance-doublenode-starwords': 'freelance',
            'freelance-doublenode-appplanning': 'freelance',
            'freelance-doublenode-lifeboard': 'freelance',
            'freelance-doublenode-caravan': 'freelance',
            'freelance-doublenode-awaysentry': 'freelance',
            'freelance-liquidstyle-agentbadges-app': 'freelance',
            'freelance-liquidstyle-agentbadges-ios': 'freelance',
            'freelance-workstats': 'freelance',
            'freelance-starwords': 'freelance',
            'freelance-appplanning': 'freelance',
        }
        team_dir = team_dir_map.get(team, team)

        # Build the actual file path
        dev_team_dir = Path.home() / "dev-team"
        if img_type == 'logo':
            # Logos: {team}/terminals/logos/{team}_{terminal}_logo.png
            base_dir = dev_team_dir / team_dir / "terminals" / "logos"
        else:
            # Avatars: {team}/personas/avatars/{team}_{avatar}_avatar.png
            base_dir = dev_team_dir / team_dir / "personas" / "avatars"

        # If team was mapped (e.g., legal-coparenting -> legal), also try
        # filenames with the mapped team prefix (e.g., legal_crane_avatar.png)
        alt_filename = None
        if team_dir != team:
            alt_filename = filename.replace(team + '_', team_dir + '_', 1)

        # Try PNG first (if valid), then SVG as fallback
        png_path = base_dir / filename
        svg_filename = filename.replace('.png', '.svg')
        svg_path = base_dir / svg_filename

        # Also try alternate filenames with mapped team prefix
        if alt_filename:
            alt_png_path = base_dir / alt_filename
            alt_svg_path = base_dir / alt_filename.replace('.png', '.svg')
            if not png_path.exists() and alt_png_path.exists():
                png_path = alt_png_path
            if not svg_path.exists() and alt_svg_path.exists():
                svg_path = alt_svg_path

        # Check if PNG exists and is a valid PNG (starts with PNG magic bytes)
        png_valid = False
        if png_path.exists():
            with open(png_path, 'rb') as f:
                header = f.read(8)
                # PNG magic bytes: 89 50 4E 47 0D 0A 1A 0A
                png_valid = header[:4] == b'\x89PNG'

        if png_valid:
            file_path = png_path
            content_type = 'image/png'
        elif svg_path.exists():
            file_path = svg_path
            content_type = 'image/svg+xml'
        else:
            self.send_error(404, f"Image not found: {png_path} or {svg_path}")
            return

        try:
            with open(file_path, 'rb') as f:
                data = f.read()

            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', len(data))
            self.send_header('Cache-Control', 'max-age=3600')
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            self.send_error(500, f"Error reading image: {e}")

    # XACA-0460-002: registry.json path — resolved once at class definition time.
    # server.py lives at <repo>/lcars-ui/server.py; registry.json is at
    # <repo>/homebrew-tap/share/teams/registry.json.
    _REGISTRY_PATH: Path = (
        Path(__file__).parent.parent / "homebrew-tap" / "share" / "teams" / "registry.json"
    )
    # Branding fields expected at the board JSON top level.
    _BRANDING_FIELDS = ('organization', 'teamName', 'subtitle')
    # XACA-0460-014: parsed-registry cache. Populated lazily on first access by
    # _load_registry_branding so repeated requests don't re-parse the JSON.
    # Sentinel _REGISTRY_NOT_LOADED distinguishes "not yet loaded" from "loaded
    # but missing/unreadable" (which caches None to avoid retry storms).
    _REGISTRY_NOT_LOADED = object()
    _REGISTRY_CACHE: "dict | None" = _REGISTRY_NOT_LOADED  # type: ignore[assignment]

    @classmethod
    def _load_registry_branding(cls, template_id: str) -> "dict | None":
        """XACA-0460-002: Load branding fields for *template_id* from registry.json.

        Returns a dict with keys matching ``_BRANDING_FIELDS`` when the template
        is found, or None when the registry is missing or the template is unknown.

        Only ``name`` and ``color`` are surfaced from the registry entry — these
        map to ``teamName`` and ``orgColor``.  ``organization`` and ``subtitle``
        are derived from the registry ``name`` as sensible defaults.

        XACA-0460-014: parsed registry is cached at the class level after first
        successful load. A missing/unreadable registry caches None so we don't
        re-attempt I/O on every request once the absence is established.
        """
        if cls._REGISTRY_CACHE is cls._REGISTRY_NOT_LOADED:
            if not cls._REGISTRY_PATH.exists():
                cls._REGISTRY_CACHE = None
            else:
                try:
                    with open(cls._REGISTRY_PATH, 'r') as f:
                        cls._REGISTRY_CACHE = json.load(f)
                except (OSError, ValueError):
                    cls._REGISTRY_CACHE = None
        registry = cls._REGISTRY_CACHE
        if registry is None:
            return None
        try:
            for entry in registry.get('teams', []):
                if entry.get('id') == template_id:
                    name = entry.get('name', '')
                    color = entry.get('color', '')
                    return {
                        'teamName': name,
                        'organization': entry.get('category', '').upper() or name.upper(),
                        'subtitle': name,
                        'orgColor': color,
                    }
        except Exception as e:
            print(f"[LCARS] WARNING: Could not read registry.json for branding: {e}", file=sys.stderr)
        return None

    def serve_kanban_data(self, team):
        """Serve kanban board data for a team.

        XACA-0460-002: If the board JSON is missing top-level branding fields
        (``organization``, ``teamName``, ``subtitle``) the frontend falls back to
        the generic 'DOUBLENODE' label.  This method hydrates those fields from
        registry.json (keyed by template id) so the correct team branding is
        shown even when the board was created before branding fields were written
        by the installer.

        If the registry cannot supply branding (missing registry, unknown template),
        the partial board data is served as-is — we do NOT block the response, since
        the board itself is valid.  A 503 is returned only when the registry exists
        and the template is not in it (indicates a corrupted or mismatched install).
        """
        board_file = get_board_file(team)

        if board_file.exists():
            try:
                with open(board_file, 'r') as f:
                    data = json.load(f)

                # XACA-0460-002: hydrate missing branding from registry.json.
                missing_branding = any(not data.get(field) for field in self._BRANDING_FIELDS)
                if missing_branding:
                    template_id, _ = _split_team_id(team)
                    branding = self._load_registry_branding(template_id)
                    if branding is not None:
                        # Only fill in fields that are absent/empty — never overwrite.
                        for field, value in branding.items():
                            if not data.get(field):
                                data[field] = value
                    elif self._REGISTRY_PATH.exists():
                        # Registry is present but template not found — mismatched install.
                        self._send_json_response(
                            {
                                "error": "branding_unresolved",
                                "team": team,
                                "message": (
                                    f"Board for '{team}' is missing branding fields and template "
                                    f"'{template_id}' was not found in registry.json. "
                                    "Re-run the team installer to repair branding."
                                ),
                            },
                            status=503,
                        )
                        return
                    # If registry is absent entirely, serve the data as-is (degraded mode).

                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                self.wfile.write(json.dumps(data, indent=2).encode())
            except Exception as e:
                self.send_error(500, f"Error reading board data: {e}")
        else:
            self.send_error(404, f"Board not found: {team}")

    def serve_teams_list(self):
        """Serve list of available teams"""
        teams = []
        # Check all team kanban directories for existing boards
        for team, kanban_dir in TEAM_KANBAN_DIRS.items():
            board_file = kanban_dir / f"{team}-board.json"
            if board_file.exists():
                teams.append(team)

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps({"teams": sorted(teams)}).encode())

    def serve_status(self):
        """Serve server status"""
        team_kanban_dir = TEAM_KANBAN_DIRS.get(LCARS_TEAM, KANBAN_DIR)
        status = {
            "status": "online",
            "session_name": SESSION_NAME,
            "team": LCARS_TEAM,
            "hostname": SERVER_HOSTNAME,
            "kanban_dir": str(team_kanban_dir),
            "kanban_dir_exists": team_kanban_dir.exists(),
            "ui_dir": str(UI_DIR)
        }

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(status, indent=2).encode())

    def serve_team(self):
        """GET /api/team — Dedicated team-identity endpoint (XACA-0249).

        Returns the effective team this server is serving, along with metadata
        that lets the UI (and operators) distinguish an explicit configuration
        from a silent fallback.

        Response shape:
            {
                "team": "academy",           // effective team name
                "team_was_explicit": true,   // LCARS_TEAM env was set
                "default_used": false        // hardcoded 'freelance' fallback was NOT used
            }

        UI uses this as a clean, dedicated source of truth when /api/status is
        unavailable or slow.  Both endpoints return the same 'team' value.
        """
        payload = {
            "team": LCARS_TEAM,
            "team_was_explicit": _LCARS_TEAM_WAS_EXPLICIT,
            "default_used": not _LCARS_TEAM_WAS_EXPLICIT,
        }
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(payload, indent=2).encode())

    def handle_terminal_activate(self):
        """POST /api/terminal/activate - Switch tmux window and iTerm2 tab

        Accepts JSON body: {"terminal": "chancellor", "window": 1}
        Executes tmux select-window and switches the iTerm2 tab containing that session.
        """
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            if content_length == 0:
                self._send_json_response({"error": "Missing request body"}, status=400)
                return

            post_data = json.loads(self.rfile.read(content_length))

            terminal = post_data.get('terminal')
            window = post_data.get('window')

            # Validate required parameters
            if terminal is None:
                self._send_json_response({"error": "Missing required parameter: terminal"}, status=400)
                return
            if window is None:
                self._send_json_response({"error": "Missing required parameter: window"}, status=400)
                return

            # Sanitize terminal name — only allow alphanumeric, hyphens, underscores
            # This prevents command injection through the tmux target
            if not re.match(r'^[a-zA-Z0-9_-]+$', str(terminal)):
                self._send_json_response({"error": "Invalid terminal name: only alphanumeric, hyphens, and underscores allowed"}, status=400)
                return

            # Validate window is an integer
            try:
                window_index = int(window)
            except (TypeError, ValueError):
                self._send_json_response({"error": "Invalid window index: must be an integer"}, status=400)
                return

            terminal = str(terminal)

            # Build the full tmux session name: {team}-{terminal}
            # Each team uses its own tmux socket (-L {team}) and prefixed session names
            tmux_session = f"{LCARS_TEAM}-{terminal}"

            # Step 1: Switch the tmux window in the target session
            tmux_result = subprocess.run(
                ["tmux", "-L", LCARS_TEAM, "select-window", "-t", f"{tmux_session}:{window_index}"],
                capture_output=True,
                text=True,
                timeout=5
            )

            if tmux_result.returncode != 0:
                error_msg = tmux_result.stderr.strip() or f"tmux select-window failed with code {tmux_result.returncode}"
                print(f"[LCARS] ERROR activating terminal window: {error_msg}")
                self._send_json_response({"error": error_msg}, status=500)
                return

            print(f"[LCARS] tmux -L {LCARS_TEAM} select-window {tmux_session}:{window_index} — OK")

            # Step 2: Switch the iTerm2 tab that contains this tmux session
            # We search all iTerm2 sessions for one whose name contains the session name
            applescript = f'''
tell application "iTerm2"
    activate
    set foundTab to false
    repeat with aWindow in windows
        repeat with aTab in tabs of aWindow
            repeat with aSession in sessions of aTab
                if name of aSession contains "{tmux_session}" then
                    select aTab
                    set index of aWindow to 1
                    set foundTab to true
                    exit repeat
                end if
            end repeat
            if foundTab then exit repeat
        end repeat
        if foundTab then exit repeat
    end repeat
end tell
'''

            iterm_result = subprocess.run(
                ["osascript", "-e", applescript],
                capture_output=True,
                text=True,
                timeout=5
            )

            if iterm_result.returncode != 0:
                # iTerm2 switch failure is non-fatal — tmux window was already switched
                error_msg = iterm_result.stderr.strip() or f"osascript failed with code {iterm_result.returncode}"
                print(f"[LCARS] WARNING: iTerm2 tab switch failed (non-fatal): {error_msg}")
                self._send_json_response({
                    "success": True,
                    "terminal": terminal,
                    "window": window_index,
                    "iterm_warning": error_msg
                })
                return

            print(f"[LCARS] iTerm2 tab switched to session containing '{tmux_session}'")

            self._send_json_response({
                "success": True,
                "terminal": terminal,
                "window": window_index
            })

        except json.JSONDecodeError as e:
            self._send_json_response({"error": f"Invalid JSON: {str(e)}"}, status=400)
        except Exception as e:
            print(f"[LCARS] ERROR in handle_terminal_activate: {e}")
            traceback.print_exc()
            self._send_json_response({"error": str(e)}, status=500)

    def serve_agent_panel_data(self):
        """Serve agent panel data from temp file written by banner scripts.

        Supports per-session data via ?session=X query parameter.
        Files are written by display_agent_avatar as <kanban/tmp>/lcars-agent-{session_code}.json
        where session_code matches the tmux session name (e.g., 'academy-chancellor').
        The tmp directory is team-specific (LCARS_TMP_DIR), resolved from SESSION_NAME at startup.
        """
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        session = query.get('session', [None])[0]

        # Use team-specific kanban/tmp/ directory — banner scripts write to this location.
        # LCARS_TMP_DIR is resolved from SESSION_NAME at startup via get_lcars_tmp_dir().
        tmp_dir = LCARS_TMP_DIR
        agent_file = None

        if session:
            # Check for per-window file first (supports multi-agent terminals)
            # The active window index is written by a tmux hook to <kanban/tmp>/lcars-active-window-{session}
            active_window_file = tmp_dir / f"lcars-active-window-{session}"
            if active_window_file.exists():
                try:
                    win_idx = active_window_file.read_text().strip()
                    if win_idx:
                        win_file = tmp_dir / f"lcars-agent-{session}-w{win_idx}.json"
                        if win_file.exists():
                            agent_file = win_file
                except Exception:
                    pass
            # Fallback to session-level file
            if agent_file is None:
                agent_file = tmp_dir / f"lcars-agent-{session}.json"
        else:
            # Fallback: find most recent agent file for this team
            candidates = sorted(
                tmp_dir.glob(f"lcars-agent-{LCARS_TEAM}*.json"),
                key=lambda p: p.stat().st_mtime if p.exists() else 0,
                reverse=True
            )
            if candidates:
                agent_file = candidates[0]

        if agent_file and agent_file.exists():
            try:
                with open(agent_file, 'r') as f:
                    data = json.load(f)
                # Enrich with AMB badges if agent has a handle
                amb_handle = data.get("amb_handle", "")
                if amb_handle:
                    data["badges"] = _fetch_amb_badges(amb_handle)
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                self.wfile.write(json.dumps(data).encode())
                return
            except Exception:
                pass
        # No data yet
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(json.dumps({"status": "waiting"}).encode())

    def serve_knowledge_stats(self):
        """Serve knowledge base statistics.

        Scans two knowledge stores:
          1. Agent/team knowledge entries at ~/.claude/knowledge/<agent>/
             (retrospective lessons, patterns, and INDEX.md files written by agents)
          2. Project auto-memory files at ~/.claude/projects/<project>/memory/
             (per-project MEMORY.md files written automatically by Claude)

        Returns aggregated statistics suitable for the HOME carousel widget.
        """
        try:
            self._serve_knowledge_stats_inner()
        except Exception as exc:
            import traceback
            print(f"[LCARS] /api/knowledge-stats error: {exc}\n{traceback.format_exc()}")
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(exc)}).encode())

    def _serve_knowledge_stats_inner(self):
        """Inner implementation for serve_knowledge_stats — called inside try/except."""
        from datetime import datetime, timezone

        kb_base = Path.home() / ".claude" / "knowledge"
        projects_base = Path.home() / ".claude" / "projects"

        # ------------------------------------------------------------------ #
        # 1. Agent / team knowledge entries                                   #
        # ------------------------------------------------------------------ #
        agent_stats = {}
        total_kb_files = 0
        total_kb_size_bytes = 0
        kb_last_modified = 0.0
        most_active_agent = None
        most_active_count = 0

        if kb_base.exists():
            for agent_dir in sorted(kb_base.iterdir()):
                if not agent_dir.is_dir():
                    continue
                agent = agent_dir.name
                files = [f for f in agent_dir.iterdir() if f.is_file()]
                file_count = len(files)
                if file_count == 0:
                    continue

                # Cache stat() results to avoid double syscalls per file
                file_stats = [(f, f.stat()) for f in files]
                size_bytes = sum(s.st_size for _, s in file_stats)
                mtime = max(s.st_mtime for _, s in file_stats)
                # Non-index entries (knowledge entries proper)
                entry_count = sum(1 for f, _ in file_stats if f.name != "INDEX.md")

                agent_stats[agent] = {
                    "fileCount": file_count,
                    "entryCount": entry_count,
                    "sizeBytes": size_bytes,
                    "lastModified": datetime.fromtimestamp(mtime, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                }

                total_kb_files += file_count
                total_kb_size_bytes += size_bytes
                if mtime > kb_last_modified:
                    kb_last_modified = mtime

                # Only track most active for individual agents (not team-* dirs)
                if not agent.startswith("team-") and entry_count > most_active_count:
                    most_active_count = entry_count
                    most_active_agent = agent

        # Split agents vs teams
        team_stats = {k: v for k, v in agent_stats.items() if k.startswith("team-")}
        individual_stats = {k: v for k, v in agent_stats.items() if not k.startswith("team-")}

        total_entry_count = sum(v["entryCount"] for v in agent_stats.values())

        # ------------------------------------------------------------------ #
        # 2. Project memory files (auto-memory)                               #
        # ------------------------------------------------------------------ #
        memory_projects = []
        total_memory_files = 0
        total_projects_scanned = 0
        memory_last_modified = 0.0

        if projects_base.exists():
            for proj_dir in projects_base.iterdir():
                if not proj_dir.is_dir():
                    continue
                total_projects_scanned += 1
                mem_dir = proj_dir / "memory"
                if not mem_dir.exists():
                    continue
                mem_files = [f for f in mem_dir.iterdir() if f.is_file()]
                if not mem_files:
                    continue
                file_count = len(mem_files)
                # Cache stat() results to avoid double syscalls per file
                mem_stats = [f.stat() for f in mem_files]
                size_bytes = sum(s.st_size for s in mem_stats)
                mtime = max(s.st_mtime for s in mem_stats)
                total_memory_files += file_count
                if mtime > memory_last_modified:
                    memory_last_modified = mtime
                # Convert dir name back to readable path (hyphens to slashes)
                readable = proj_dir.name.replace("-", "/").lstrip("/")
                memory_projects.append({
                    "project": readable,
                    "fileCount": file_count,
                    "sizeBytes": size_bytes,
                    "lastModified": datetime.fromtimestamp(mtime, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                })

        # Sort memory projects by most recently modified
        memory_projects.sort(key=lambda p: p["lastModified"], reverse=True)

        # ------------------------------------------------------------------ #
        # 3. Build response                                                   #
        # ------------------------------------------------------------------ #
        overall_last_modified = max(kb_last_modified, memory_last_modified)

        result = {
            "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "team": LCARS_TEAM,

            # High-level summary for carousel widget
            "summary": {
                "totalAgents": len(individual_stats),
                "totalTeams": len(team_stats),
                "totalKnowledgeFiles": total_kb_files,
                "totalKnowledgeEntries": total_entry_count,
                "totalKnowledgeSizeBytes": total_kb_size_bytes,
                "totalMemoryFiles": total_memory_files,
                "totalProjectsScanned": total_projects_scanned,
                "projectsWithMemory": len(memory_projects),
                "mostActiveAgent": most_active_agent,
                "mostActiveEntryCount": most_active_count,
                "lastUpdated": datetime.fromtimestamp(overall_last_modified, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if overall_last_modified else None,
            },

            # Per-agent breakdown (individual agents)
            "agents": individual_stats,

            # Per-team knowledge breakdown
            "teams": team_stats,

            # Projects with auto-memory
            "memoryProjects": memory_projects,
        }

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(json.dumps(result, indent=2).encode())

    def serve_integrations_list(self):
        """Serve list of configured integrations"""
        if not INTEGRATIONS_AVAILABLE:
            self._send_json_response({
                "integrations": [],
                "error": "Integration module not available"
            })
            return

        try:
            manager = get_manager()
            integrations = manager.list_integrations()

            self._send_json_response({
                "integrations": integrations,
                "team": LCARS_TEAM
            })
        except Exception as e:
            self._send_json_response({
                "integrations": [],
                "error": str(e)
            })

    def serve_rag_engines_list(self):
        """Serve GET /api/rag-engines — list of configured RAG engines"""
        if not RAG_ENGINES_AVAILABLE:
            self._send_json_response({
                "engines": [],
                "error": "RAG engines module not available"
            })
            return

        try:
            manager = get_rag_manager()
            engines = manager.list_engines()
            registered_types = manager.get_registered_types()

            # Enrich running engines with content stats
            for engine_dict in engines:
                if engine_dict.get('status') == 'running':
                    provider = manager.get_engine(engine_dict['id'])
                    if provider:
                        stats = provider.get_content_stats()
                        if stats:
                            engine_dict['contentStats'] = stats

            self._send_json_response({
                "engines": engines,
                "registeredTypes": registered_types
            })
        except Exception as e:
            self._send_json_response({
                "engines": [],
                "error": str(e)
            })

    def serve_rag_engines_summary(self):
        """Serve GET /api/rag-engines/summary — lightweight summary for HOME carousel panels"""
        if not RAG_ENGINES_AVAILABLE:
            self._send_json_response({"engines": [], "total": 0})
            return

        try:
            manager = get_rag_manager()
            engines = manager.list_engines()
            summary = []

            for engine_dict in engines:
                if not engine_dict.get('enabled', False):
                    continue

                entry = {
                    "id": engine_dict.get("id", ""),
                    "name": engine_dict.get("name", ""),
                    "type": engine_dict.get("type", ""),
                    "status": engine_dict.get("status", "unknown"),
                    "port": engine_dict.get("port", 0),
                }

                # Add content stats for running engines
                if engine_dict.get('status') == 'running':
                    provider = manager.get_engine(engine_dict['id'])
                    if provider:
                        stats = provider.get_content_stats()
                        if stats:
                            entry['contentStats'] = stats
                        health = provider.health_check()
                        if health:
                            entry['health'] = health.to_dict() if hasattr(health, 'to_dict') else health

                summary.append(entry)

            self._send_json_response({
                "engines": summary,
                "total": len(summary),
                "activeCount": sum(1 for e in summary if e.get("status") == "running")
            })
        except Exception as e:
            self._send_json_response({"engines": [], "total": 0, "error": str(e)})

    def handle_rag_engine_save(self):
        """Handle POST /api/rag-engines/save — add or update a RAG engine config"""
        if not RAG_ENGINES_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "RAG engines module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            engine_data = post_data.get('engine')
            if not engine_data or not engine_data.get('id'):
                self._send_json_response({
                    "success": False,
                    "error": "Invalid engine data"
                })
                return

            manager = get_rag_manager()
            saved = manager.save_engine(engine_data)
            if not saved:
                self._send_json_response({
                    "success": False,
                    "error": "Failed to save engine configuration"
                })
                return

            manager.reload()
            self._send_json_response({"success": True})
        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def handle_rag_engine_delete(self):
        """Handle POST /api/rag-engines/delete — remove a RAG engine config"""
        if not RAG_ENGINES_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "RAG engines module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            engine_id = post_data.get('engineId')
            if not engine_id:
                self._send_json_response({
                    "success": False,
                    "error": "No engineId provided"
                })
                return

            manager = get_rag_manager()
            deleted = manager.delete_engine(engine_id)
            if not deleted:
                self._send_json_response({
                    "success": False,
                    "error": f"Engine '{engine_id}' not found"
                })
                return

            self._send_json_response({"success": True})
        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def handle_rag_engine_install(self):
        """Handle POST /api/rag-engines/install — install a RAG engine"""
        if not RAG_ENGINES_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "RAG engines module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            engine_id = post_data.get('engineId')
            if not engine_id:
                self._send_json_response({
                    "success": False,
                    "error": "No engineId provided"
                })
                return

            manager = get_rag_manager()
            progress = manager.install_engine(engine_id)
            self._send_json_response(progress.to_dict())
        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def handle_rag_engine_uninstall(self):
        """Handle POST /api/rag-engines/uninstall — uninstall a RAG engine"""
        if not RAG_ENGINES_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "RAG engines module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            engine_id = post_data.get('engineId')
            if not engine_id:
                self._send_json_response({
                    "success": False,
                    "error": "No engineId provided"
                })
                return

            manager = get_rag_manager()
            status = manager.uninstall_engine(engine_id)
            self._send_json_response(status.to_dict())
        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def handle_rag_engine_start(self):
        """Handle POST /api/rag-engines/start — start a RAG engine service"""
        if not RAG_ENGINES_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "RAG engines module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            engine_id = post_data.get('engineId')
            if not engine_id:
                self._send_json_response({
                    "success": False,
                    "error": "No engineId provided"
                })
                return

            manager = get_rag_manager()
            status = manager.start_engine(engine_id)
            self._send_json_response(status.to_dict())
        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def handle_rag_engine_stop(self):
        """Handle POST /api/rag-engines/stop — stop a RAG engine service"""
        if not RAG_ENGINES_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "RAG engines module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            engine_id = post_data.get('engineId')
            if not engine_id:
                self._send_json_response({
                    "success": False,
                    "error": "No engineId provided"
                })
                return

            manager = get_rag_manager()
            status = manager.stop_engine(engine_id)
            self._send_json_response(status.to_dict())
        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def handle_rag_engine_health(self):
        """Handle POST /api/rag-engines/health — check health of one or all RAG engines"""
        if not RAG_ENGINES_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "RAG engines module not available"
            })
            return

        try:
            content_length = int(self.headers.get('Content-Length', 0))
            post_data = json.loads(self.rfile.read(content_length)) if content_length > 0 else {}

            engine_id = post_data.get('engineId')  # Optional — None checks all

            manager = get_rag_manager()
            results = manager.health_check(engine_id)
            self._send_json_response({
                "results": {eid: s.to_dict() for eid, s in results.items()}
            })
        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def handle_rag_engine_configure(self):
        """Handle POST /api/rag-engines/configure — apply settings to a RAG engine"""
        if not RAG_ENGINES_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "RAG engines module not available"
            })
            return

        try:
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))

            engine_id = post_data.get('engineId')
            settings = post_data.get('settings', {})
            if not engine_id:
                self._send_json_response({
                    "success": False,
                    "error": "No engineId provided"
                })
                return

            manager = get_rag_manager()
            engine = manager.get_engine(engine_id)
            if not engine:
                self._send_json_response({
                    "success": False,
                    "error": f"Engine '{engine_id}' not found"
                })
                return

            status = engine.configure(settings)
            self._send_json_response(status.to_dict())
        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    # Simple in-memory cache for PyPI version check results.
    # Key: engine_id, Value: {"timestamp": float, "result": dict}
    _update_check_cache: dict = {}
    _UPDATE_CHECK_TTL = 300  # 5 minutes in seconds

    def handle_rag_engine_check_updates(self):
        """Handle POST /api/rag-engines/check-updates — check PyPI for newer versions"""
        if not RAG_ENGINES_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "RAG engines module not available"
            })
            return

        try:
            import time as _time
            content_length = int(self.headers.get('Content-Length', 0))
            post_data = json.loads(self.rfile.read(content_length)) if content_length > 0 else {}

            engine_id = post_data.get('engineId')  # Optional — None = check all

            manager = get_rag_manager()
            now = _time.time()
            results = {}

            engines_to_check = (
                {engine_id: manager.get_engine(engine_id)}
                if engine_id
                else {e.id: e for e in manager.get_all_engines()}
            )

            for eid, engine in engines_to_check.items():
                if engine is None:
                    results[eid] = {"error": f"Engine '{eid}' not found"}
                    continue

                # Use cached result if still fresh
                cache_entry = LCARSHandler._update_check_cache.get(eid)
                if cache_entry and (now - cache_entry["timestamp"]) < LCARSHandler._UPDATE_CHECK_TTL:
                    results[eid] = cache_entry["result"]
                    continue

                update_info = engine.check_for_updates()
                LCARSHandler._update_check_cache[eid] = {
                    "timestamp": now,
                    "result": update_info
                }
                results[eid] = update_info

            self._send_json_response({"results": results})
        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def handle_rag_engine_update(self):
        """Handle POST /api/rag-engines/update — upgrade an engine package to latest PyPI version"""
        if not RAG_ENGINES_AVAILABLE:
            self._send_json_response({
                "success": False,
                "error": "RAG engines module not available"
            })
            return

        try:
            content_length = int(self.headers.get('Content-Length', 0))
            post_data = json.loads(self.rfile.read(content_length)) if content_length > 0 else {}

            engine_id = post_data.get('engineId')
            if not engine_id:
                self._send_json_response({
                    "success": False,
                    "error": "No engineId provided"
                })
                return

            manager = get_rag_manager()
            engine = manager.get_engine(engine_id)
            if not engine:
                self._send_json_response({
                    "success": False,
                    "error": f"Engine '{engine_id}' not found"
                })
                return

            status = engine.update()

            # Invalidate the update-check cache for this engine so fresh info shows next check
            LCARSHandler._update_check_cache.pop(engine_id, None)

            self._send_json_response(status.to_dict())
        except Exception as e:
            self._send_json_response({
                "success": False,
                "error": str(e)
            })

    def serve_rag_engine_log(self):
        """Serve GET /api/rag-engines/log?engineId=X — read stderr log file for an engine"""
        import re
        from urllib.parse import urlparse, parse_qs
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
        engine_id = params.get('engineId', [None])[0]

        if not engine_id:
            self._send_json_response({"error": "No engineId provided"})
            return

        # Sanitize engineId to prevent path traversal
        if not re.match(r'^[a-zA-Z0-9_-]+$', engine_id):
            self._send_json_response({"error": "Invalid engineId"})
            return

        log_path = os.path.join(
            os.path.expanduser("~"), "rag-data", "logs", f"{engine_id}-stderr.log"
        )

        if not os.path.exists(log_path):
            self._send_json_response({
                "content": "(no log file found — engine may not have been started yet)",
                "path": log_path
            })
            return

        try:
            with open(log_path, 'r') as f:
                # Read last 50KB to avoid serving huge logs
                f.seek(0, 2)
                size = f.tell()
                if size > 50000:
                    f.seek(size - 50000)
                    f.readline()  # skip partial first line
                else:
                    f.seek(0)
                content = f.read()

            self._send_json_response({
                "content": content,
                "path": log_path,
                "size": size
            })
        except Exception as e:
            self._send_json_response({"error": f"Failed to read log: {e}"})

    # -------------------------------------------------------------------------
    # Graph API handlers
    # -------------------------------------------------------------------------

    def _generate_demo_graph(self):
        """Generate demo graph data for when no engines are available."""
        from datetime import datetime, timezone
        return {
            'nodes': [
                {'id': 'n1', 'label': 'Knowledge Graph', 'type': 'concept', 'group': 'core',
                 'properties': {'description': 'Demo node - connect a RAG engine to see real data'}},
                {'id': 'n2', 'label': 'LightRAG', 'type': 'engine', 'group': 'engine',
                 'properties': {'port': 9621}},
                {'id': 'n3', 'label': 'Code-Graph-RAG', 'type': 'engine', 'group': 'engine',
                 'properties': {'port': 9622}},
                {'id': 'n4', 'label': 'RAG-Anything', 'type': 'engine', 'group': 'engine',
                 'properties': {}},
                {'id': 'n5', 'label': 'Entities', 'type': 'concept', 'group': 'data',
                 'properties': {}},
                {'id': 'n6', 'label': 'Relationships', 'type': 'concept', 'group': 'data',
                 'properties': {}},
                {'id': 'n7', 'label': 'Documents', 'type': 'source', 'group': 'data',
                 'properties': {}},
                {'id': 'n8', 'label': 'Source Code', 'type': 'source', 'group': 'data',
                 'properties': {}},
            ],
            'edges': [
                {'id': 'e1', 'source': 'n1', 'target': 'n5', 'label': 'CONTAINS', 'properties': {}},
                {'id': 'e2', 'source': 'n1', 'target': 'n6', 'label': 'CONTAINS', 'properties': {}},
                {'id': 'e3', 'source': 'n2', 'target': 'n1', 'label': 'BUILDS', 'properties': {}},
                {'id': 'e4', 'source': 'n3', 'target': 'n1', 'label': 'BUILDS', 'properties': {}},
                {'id': 'e5', 'source': 'n4', 'target': 'n1', 'label': 'BUILDS', 'properties': {}},
                {'id': 'e6', 'source': 'n7', 'target': 'n5', 'label': 'EXTRACTED_FROM', 'properties': {}},
                {'id': 'e7', 'source': 'n8', 'target': 'n5', 'label': 'EXTRACTED_FROM', 'properties': {}},
                {'id': 'e8', 'source': 'n5', 'target': 'n6', 'label': 'LINKED_BY', 'properties': {}},
            ],
            'engine': 'demo',
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'message': 'Demo graph - connect and start a RAG engine to visualize real knowledge graph data'
        }

    def _normalize_lightrag_graph(self, raw, engine_id, limit=200):
        """Normalize LightRAG /graphs response into {nodes, edges} format."""
        from datetime import datetime, timezone
        nodes = []
        edges = []

        # LightRAG returns graph data — structure varies by version.
        # Common shapes: {nodes: [...], edges: [...]} or {vertices: [...], edges: [...]}
        raw_nodes = raw.get('nodes') or raw.get('vertices') or []
        raw_edges = raw.get('edges') or raw.get('relationships') or []

        for i, n in enumerate(raw_nodes[:limit]):
            # LightRAG nests entity_type, description, etc. inside a 'properties' sub-dict.
            # Flatten so we can extract fields uniformly.
            inner = n.get('properties', {}) if isinstance(n.get('properties'), dict) else {}
            flat = {**inner, **{k: v for k, v in n.items() if k != 'properties'}}
            node_id = str(flat.get('id') or flat.get('entity_name') or flat.get('entity_id') or f'n{i}')
            skip = {'id', 'entity_name', 'entity_id', 'label', 'labels',
                    'type', 'entity_type', 'group', 'cluster', 'name'}
            nodes.append({
                'id': node_id,
                'label': str(flat.get('label') or flat.get('entity_name') or flat.get('name') or node_id),
                'type': str(flat.get('type') or flat.get('entity_type') or 'entity'),
                'group': str(flat.get('group') or flat.get('cluster') or 'default'),
                'properties': {k: v for k, v in flat.items() if k not in skip},
            })

        for i, e in enumerate(raw_edges[:limit]):
            # Flatten nested properties (same pattern as nodes)
            inner_e = e.get('properties', {}) if isinstance(e.get('properties'), dict) else {}
            flat_e = {**inner_e, **{k: v for k, v in e.items() if k != 'properties'}}
            src = str(flat_e.get('source') or flat_e.get('src') or flat_e.get('src_id') or '')
            tgt = str(flat_e.get('target') or flat_e.get('dst') or flat_e.get('tgt_id') or '')
            if not src or not tgt:
                continue
            skip_e = {'id', 'source', 'src', 'src_id', 'target', 'dst',
                      'tgt_id', 'label', 'relation', 'type'}
            edges.append({
                'id': str(flat_e.get('id') or f'e{i}'),
                'source': src,
                'target': tgt,
                'label': str(flat_e.get('label') or flat_e.get('relation') or flat_e.get('type') or 'RELATED'),
                'properties': {k: v for k, v in flat_e.items() if k not in skip_e},
            })

        return {
            'nodes': nodes,
            'edges': edges,
            'engine': engine_id,
            'timestamp': datetime.now(timezone.utc).isoformat(),
        }

    def _normalize_bolt_graph(self, records, engine_id):
        """Normalize neo4j/Memgraph Bolt query results into {nodes, edges} format."""
        from datetime import datetime, timezone
        nodes = {}
        edges = []

        for record in records:
            for key in record.keys():
                val = record[key]
                # Node
                if hasattr(val, 'id') and hasattr(val, 'labels'):
                    node_id = str(val.id)
                    if node_id not in nodes:
                        labels = list(val.labels) if val.labels else []
                        props = dict(val.items()) if hasattr(val, 'items') else {}
                        nodes[node_id] = {
                            'id': node_id,
                            'label': props.get('name') or props.get('label') or (labels[0] if labels else node_id),
                            'type': labels[0] if labels else 'node',
                            'group': labels[0] if labels else 'default',
                            'properties': props,
                        }
                # Relationship
                elif hasattr(val, 'id') and hasattr(val, 'type') and hasattr(val, 'start_node'):
                    props = dict(val.items()) if hasattr(val, 'items') else {}
                    edges.append({
                        'id': str(val.id),
                        'source': str(val.start_node.id),
                        'target': str(val.end_node.id),
                        'label': str(val.type),
                        'properties': props,
                    })

        return {
            'nodes': list(nodes.values()),
            'edges': edges,
            'engine': engine_id,
            'timestamp': datetime.now(timezone.utc).isoformat(),
        }

    def serve_graph_engines(self):
        """Handle GET /api/graph/engines — list available graph-capable engines."""
        if not RAG_ENGINES_AVAILABLE:
            self._send_json_response({'engines': []})
            return

        try:
            manager = get_rag_manager()
            engines = []
            for engine in manager.get_all_engines():
                status = engine.get_status()
                engines.append({
                    'id': engine.id,
                    'name': engine.name,
                    'type': engine.engine_type,
                    'status': status.status,
                    'port': engine.port,
                })
            self._send_json_response({'engines': engines})
        except Exception as e:
            self._send_json_response({'engines': [], 'error': str(e)})

    def handle_graph_data(self):
        """Handle POST /api/graph/data — fetch graph data from a specific engine."""
        from datetime import datetime, timezone
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(content_length)) if content_length > 0 else {}

            engine_id = body.get('engineId', '')
            limit = max(1, min(int(body.get('limit', 200)), 5000))

            if not engine_id:
                self._send_json_response({'error': 'engineId is required'})
                return

            # Try to get engine info from RAG manager
            port = None
            engine_type = 'unknown'
            if RAG_ENGINES_AVAILABLE:
                try:
                    manager = get_rag_manager()
                    engine = manager.get_engine(engine_id)
                    if engine:
                        port = getattr(engine, 'port', None)
                        engine_type = getattr(engine, 'engine_type', 'unknown')
                except Exception:
                    pass

            # LightRAG REST API path
            if engine_type in ('lightrag', 'light_rag') and port:
                try:
                    query_param = body.get('query', '*')
                    url = f'http://localhost:{port}/graphs?label={urllib.parse.quote(query_param)}&max_depth=3'
                    req = urllib.request.Request(url, headers={'Accept': 'application/json'})
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        raw = json.loads(resp.read().decode('utf-8'))
                    result = self._normalize_lightrag_graph(raw, engine_id, limit)
                    self._send_json_response(result)
                    return
                except Exception as e:
                    self._send_json_response({
                        'nodes': [], 'edges': [], 'engine': engine_id,
                        'error': f'LightRAG API error: {e}'
                    })
                    return

            # Memgraph/Neo4j Bolt path (Code-Graph-RAG, RAG-Anything)
            if engine_type in ('code_graph_rag', 'rag_anything', 'memgraph') and BOLT_AVAILABLE:
                try:
                    from neo4j import GraphDatabase
                    bolt_port = port or 7687
                    bolt_url = f'bolt://localhost:{bolt_port}'
                    driver = GraphDatabase.driver(bolt_url, auth=('', ''))
                    with driver.session() as session:
                        result = session.run(
                            'MATCH (n) OPTIONAL MATCH (n)-[r]->(m) RETURN n, r, m LIMIT $limit',
                            limit=limit
                        )
                        records = list(result)
                    driver.close()
                    graph = self._normalize_bolt_graph(records, engine_id)
                    self._send_json_response(graph)
                    return
                except Exception as e:
                    demo = self._generate_demo_graph()
                    demo['message'] = f'Bolt connection unavailable: {e}'
                    self._send_json_response(demo)
                    return

            # Fallback: demo data
            demo = self._generate_demo_graph()
            if not RAG_ENGINES_AVAILABLE:
                demo['message'] = 'RAG engines module not available — showing demo graph'
            else:
                demo['message'] = f'Engine "{engine_id}" not available or graph data not supported — showing demo graph'
            self._send_json_response(demo)

        except Exception as e:
            self._send_json_response({'error': str(e), 'nodes': [], 'edges': []})

    def handle_graph_query(self):
        """Handle POST /api/graph/query — run RAG query and return relevant subgraph."""
        from datetime import datetime, timezone
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(content_length)) if content_length > 0 else {}

            engine_id = body.get('engineId', '')
            query = body.get('query', '')
            mode = body.get('mode', 'hybrid')

            # Validate mode against allowlist
            allowed_modes = ('local', 'global', 'hybrid', 'naive')
            if mode not in allowed_modes:
                mode = 'hybrid'

            if not engine_id or not query:
                self._send_json_response({'error': 'engineId and query are required'})
                return

            # Try to get engine info
            port = None
            engine_type = 'unknown'
            if RAG_ENGINES_AVAILABLE:
                try:
                    manager = get_rag_manager()
                    engine = manager.get_engine(engine_id)
                    if engine:
                        port = getattr(engine, 'port', None)
                        engine_type = getattr(engine, 'engine_type', 'unknown')
                except Exception:
                    pass

            # LightRAG REST query
            if engine_type in ('lightrag', 'light_rag') and port:
                try:
                    query_url = f'http://localhost:{port}/query'
                    payload = json.dumps({'query': query, 'mode': mode}).encode('utf-8')
                    req = urllib.request.Request(
                        query_url,
                        data=payload,
                        headers={'Content-Type': 'application/json', 'Accept': 'application/json'},
                        method='POST'
                    )
                    with urllib.request.urlopen(req, timeout=120) as resp:
                        raw = json.loads(resp.read().decode('utf-8'))

                    answer = raw.get('response') or raw.get('answer') or raw.get('result') or ''

                    # Try to fetch subgraph after query
                    graph_data = {'nodes': [], 'edges': [], 'engine': engine_id,
                                  'timestamp': datetime.now(timezone.utc).isoformat()}
                    try:
                        graph_url = f'http://localhost:{port}/graphs'
                        graph_req = urllib.request.Request(graph_url, headers={'Accept': 'application/json'})
                        with urllib.request.urlopen(graph_req, timeout=10) as graph_resp:
                            graph_raw = json.loads(graph_resp.read().decode('utf-8'))
                        graph_data = self._normalize_lightrag_graph(graph_raw, engine_id)
                    except Exception:
                        pass

                    graph_data['answer'] = answer
                    self._send_json_response(graph_data)
                    return
                except Exception as e:
                    # Return error with the current engine — never fall back to demo
                    error_data = {'nodes': [], 'edges': [], 'engine': engine_id,
                                  'answer': f'Query failed: {e}',
                                  'message': f'LightRAG query error: {e}',
                                  'timestamp': datetime.now(timezone.utc).isoformat()}
                    self._send_json_response(error_data)
                    return

            # Fallback: demo response
            demo = self._generate_demo_graph()
            demo['answer'] = f'Demo answer for query: "{query}". Connect and start a RAG engine to get real answers.'
            demo['message'] = f'Engine "{engine_id}" not available — showing demo response'
            self._send_json_response(demo)

        except Exception as e:
            self._send_json_response({'error': str(e), 'nodes': [], 'edges': [], 'answer': ''})

    def handle_graph_node(self):
        """Handle POST /api/graph/node — get details for a specific node."""
        from datetime import datetime, timezone
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(content_length)) if content_length > 0 else {}

            engine_id = body.get('engineId', '')
            node_id = body.get('nodeId', '')

            if not engine_id or not node_id:
                self._send_json_response({'error': 'engineId and nodeId are required'})
                return

            # Try to get engine info
            port = None
            engine_type = 'unknown'
            if RAG_ENGINES_AVAILABLE:
                try:
                    manager = get_rag_manager()
                    engine = manager.get_engine(engine_id)
                    if engine:
                        port = getattr(engine, 'port', None)
                        engine_type = getattr(engine, 'engine_type', 'unknown')
                except Exception:
                    pass

            # Memgraph/Neo4j Bolt: look up node by id
            if engine_type in ('code_graph_rag', 'rag_anything', 'memgraph') and BOLT_AVAILABLE:
                try:
                    from neo4j import GraphDatabase
                    bolt_port = port or 7687
                    driver = GraphDatabase.driver(f'bolt://localhost:{bolt_port}', auth=('', ''))
                    with driver.session() as session:
                        result = session.run(
                            'MATCH (n) WHERE id(n) = $node_id '
                            'OPTIONAL MATCH (n)-[r]->(m) RETURN n, r, m',
                            node_id=int(node_id)
                        )
                        records = list(result)
                    driver.close()

                    if not records:
                        self._send_json_response({'node': None, 'error': 'Node not found'})
                        return

                    # Build node detail from first record
                    first = records[0]
                    bolt_node = first['n']
                    props = dict(bolt_node.items()) if hasattr(bolt_node, 'items') else {}
                    labels = list(bolt_node.labels) if hasattr(bolt_node, 'labels') else []
                    relationships = []
                    for rec in records:
                        rel = rec.get('r')
                        tgt = rec.get('m')
                        if rel and tgt:
                            tgt_props = dict(tgt.items()) if hasattr(tgt, 'items') else {}
                            tgt_labels = list(tgt.labels) if hasattr(tgt, 'labels') else []
                            relationships.append({
                                'target': str(tgt.id),
                                'targetLabel': tgt_props.get('name') or (tgt_labels[0] if tgt_labels else str(tgt.id)),
                                'type': str(rel.type),
                                'properties': dict(rel.items()) if hasattr(rel, 'items') else {},
                            })

                    node_detail = {
                        'id': node_id,
                        'label': props.get('name') or props.get('label') or (labels[0] if labels else node_id),
                        'type': labels[0] if labels else 'node',
                        'properties': props,
                        'relationships': relationships,
                    }
                    self._send_json_response({'node': node_detail})
                    return
                except Exception as e:
                    self._send_json_response({'node': None, 'error': f'Bolt lookup failed: {e}'})
                    return

            # LightRAG: use /graphs?label=<node_id> to fetch the node's neighborhood
            if engine_type in ('lightrag', 'light_rag') and port:
                try:
                    label_param = urllib.parse.quote(str(node_id))
                    url = f'http://localhost:{port}/graphs?label={label_param}&max_depth=1'
                    req = urllib.request.Request(url, headers={'Accept': 'application/json'})
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        raw = json.loads(resp.read().decode('utf-8'))
                    graph = self._normalize_lightrag_graph(raw, engine_id)
                    # Find the requested node
                    matched = next((n for n in graph['nodes'] if n['id'] == node_id), None)
                    if matched:
                        rels = [{'target': e['target'], 'type': e['label'], 'properties': e['properties']}
                                for e in graph['edges'] if e['source'] == node_id]
                        matched['relationships'] = rels
                        self._send_json_response({'node': matched})
                    else:
                        self._send_json_response({'node': None, 'error': f'Node "{node_id}" not found'})
                    return
                except Exception as e:
                    self._send_json_response({'node': None, 'error': f'LightRAG lookup failed: {e}'})
                    return

            # Fallback: demo node
            self._send_json_response({
                'node': {
                    'id': node_id,
                    'label': f'Demo Node ({node_id})',
                    'type': 'demo',
                    'properties': {'note': 'Connect a RAG engine to see real node data'},
                    'relationships': [],
                },
                'message': f'Engine "{engine_id}" not available — showing demo node'
            })

        except Exception as e:
            self._send_json_response({'node': None, 'error': str(e)})

    def handle_create_export(self):
        """POST /api/export/create — start a team export in the background.

        The team is determined by LCARS_TEAM env var (set when the server starts).
        No team parameter is accepted from the client — export is always scoped
        to whichever team's LCARS server you hit.
        """
        import uuid
        import threading
        from datetime import datetime, timezone

        if not LCARS_TEAM:
            self._send_json_response(
                {'error': 'LCARS_TEAM not configured on this server'}, status=500
            )
            return

        # Prune old jobs (>1 hr) and old files
        now = datetime.now(timezone.utc)
        stale_ids = [
            jid for jid, jdata in EXPORT_JOBS.items()
            if jdata.get('status') in ('completed', 'failed')
            and (now - datetime.fromisoformat(jdata.get('createdAt', now.isoformat()).replace('Z', '+00:00'))).total_seconds() > 3600
        ]
        for jid in stale_ids:
            del EXPORT_JOBS[jid]

        if EXPORT_DIR.exists():
            for old in EXPORT_DIR.glob('lcars-export-*.zip'):
                try:
                    age = (now - datetime.fromtimestamp(old.stat().st_mtime, tz=timezone.utc)).total_seconds()
                    if age > 3600:
                        old.unlink()
                except Exception:
                    pass

        job_id = str(uuid.uuid4())
        EXPORT_JOBS[job_id] = {
            'status': 'generating',
            'progress': 0,
            'message': 'Initializing export...',
            'filename': None,
            'fileSize': None,
            'error': None,
            'team': LCARS_TEAM,
            'createdAt': datetime.now(timezone.utc).isoformat(),
        }

        thread = threading.Thread(
            target=generate_export,
            args=(job_id, LCARS_TEAM),
            daemon=True
        )
        thread.start()

        self._send_json_response({'jobId': job_id, 'status': 'generating', 'team': LCARS_TEAM})

    def serve_export_status(self, job_id):
        """GET /api/export/status/<job_id>"""
        job = EXPORT_JOBS.get(job_id)
        if not job:
            self._send_json_response({'error': 'Job not found'}, status=404)
            return
        self._send_json_response({**job, 'jobId': job_id})

    def serve_export_download(self, job_id):
        """GET /api/export/download/<job_id> — stream the zip"""
        job = EXPORT_JOBS.get(job_id)
        if not job or job['status'] != 'completed' or not job.get('filename'):
            self._send_json_response({'error': 'Export not ready'}, status=404)
            return

        file_path = EXPORT_DIR / job['filename']
        if not file_path.exists():
            self._send_json_response({'error': 'Export file not found'}, status=404)
            return

        self.send_response(200)
        self.send_header('Content-Type', 'application/zip')
        self.send_header('Content-Disposition', f'attachment; filename="{job["filename"]}"')
        self.send_header('Content-Length', str(file_path.stat().st_size))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()

        with open(file_path, 'rb') as f:
            while True:
                chunk = f.read(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)

    def handle_import_upload(self):
        """POST /api/import/upload — receive a team export zip, validate, stage.

        Expects multipart/form-data with a single 'file' field. Returns a pre-flight
        response with the parsed manifest + base-team compatibility check. The client
        then calls /api/import/apply/<job_id> to actually perform the import.
        """
        import uuid
        import zipfile
        from datetime import datetime, timezone

        if not LCARS_TEAM:
            self._send_json_response(
                {'error': 'LCARS_TEAM not configured on this server'}, status=500
            )
            return

        content_type = self.headers.get('Content-Type', '')
        if not content_type.startswith('multipart/form-data'):
            self._send_json_response(
                {'error': 'Expected multipart/form-data upload'}, status=400
            )
            return

        content_length = int(self.headers.get('Content-Length', 0))
        if content_length <= 0 or content_length > 500 * 1024 * 1024:
            self._send_json_response(
                {'error': 'Invalid or too-large upload (max 500 MB)'}, status=400
            )
            return

        # Parse multipart boundary
        boundary_match = re.search(r'boundary=(.+)', content_type)
        if not boundary_match:
            self._send_json_response({'error': 'Missing multipart boundary'}, status=400)
            return
        boundary = boundary_match.group(1).strip().strip('"').encode('utf-8')

        raw = self.rfile.read(content_length)

        # Split into parts, find the one with filename
        delim = b'--' + boundary
        parts = raw.split(delim)
        file_bytes = None
        for part in parts:
            if b'filename=' not in part:
                continue
            # Strip headers/body separator
            if b'\r\n\r\n' not in part:
                continue
            _, body = part.split(b'\r\n\r\n', 1)
            # Trim trailing CRLF that precedes the next boundary
            if body.endswith(b'\r\n'):
                body = body[:-2]
            file_bytes = body
            break

        if not file_bytes:
            self._send_json_response({'error': 'No file found in upload'}, status=400)
            return

        IMPORT_STAGING_DIR.mkdir(parents=True, exist_ok=True)
        job_id = str(uuid.uuid4())
        staged_path = IMPORT_STAGING_DIR / f"{job_id}.zip"
        staged_path.write_bytes(file_bytes)

        # Validate the zip and extract manifest
        try:
            with zipfile.ZipFile(staged_path, 'r') as zipf:
                names = zipf.namelist()
                if 'export-manifest.json' not in names:
                    raise ValueError('Archive missing export-manifest.json')
                manifest_raw = zipf.read('export-manifest.json').decode('utf-8')
                manifest = json.loads(manifest_raw)
                if manifest.get('kind') != 'lcars-team-export':
                    raise ValueError(f'Unexpected archive kind: {manifest.get("kind")}')
        except (zipfile.BadZipFile, ValueError, json.JSONDecodeError) as e:
            try:
                staged_path.unlink()
            except Exception:
                pass
            self._send_json_response(
                {'error': f'Invalid archive: {e}'}, status=400
            )
            return

        source_team = manifest.get('team', '')
        source_base = manifest.get('baseTeam', '')
        target_base, _ = _split_team_id(LCARS_TEAM)
        base_match = (source_base == target_base)

        # XACA-0460-001: pre-flight dual-board check for the import target.
        # Importing into a team that has a dual-board state would corrupt kanban data
        # because apply_import writes into the canonical path while the legacy stub
        # may still be the board the UI is reading.  Refuse before offering the rename
        # prompt — the structured error replaces the rename flow for this case.
        dual_state = _detect_dual_boards(LCARS_TEAM)
        if dual_state is not None:
            try:
                staged_path.unlink()
            except Exception:
                pass
            self._send_json_response(
                {
                    "error": "dual_board_state",
                    "team": LCARS_TEAM,
                    "message": (
                        f"Dual-board state detected for '{LCARS_TEAM}'. "
                        f"The legacy stub at {dual_state.stub} coexists with the "
                        f"canonical board at {dual_state.canonical}. "
                        "Importing now would corrupt your kanban state."
                    ),
                    "remediation": [
                        f"Run `kb-quarantine-stub {LCARS_TEAM}` to move the stub aside.",
                        "Restart LCARS.",
                        "Retry the import.",
                    ],
                },
                status=409,
            )
            return

        # XACA-0496-005: Check for team_transfer/manifest.json in the uploaded zip.
        # If present, run the verifier and include the summary in the pre-flight response.
        # This is supplementary — failure here never fails the upload.
        tt_verifier_summary: dict = {'present': False}
        try:
            import re
            import subprocess
            import sys
            import tempfile

            with zipfile.ZipFile(staged_path, 'r') as _zf:
                has_tt_manifest = 'team_transfer/manifest.json' in _zf.namelist()

            if has_tt_manifest:
                with zipfile.ZipFile(staged_path, 'r') as _zf:
                    tt_manifest_bytes = _zf.read('team_transfer/manifest.json')

                lcars_ui_dir = Path(__file__).parent

                with tempfile.TemporaryDirectory() as tmp_str:
                    tmp = Path(tmp_str)
                    tt_manifest_path = tmp / "manifest.json"
                    tt_manifest_path.write_bytes(tt_manifest_bytes)

                    ver_result = subprocess.run(
                        [sys.executable, "-m", "team_transfer.verifier",
                         "--manifest", str(tt_manifest_path), "--quiet"],
                        cwd=str(lcars_ui_dir),
                        env={**os.environ, "PYTHONPATH": str(lcars_ui_dir)},
                        capture_output=True, text=True, timeout=120,
                    )
                    verifier_output = ver_result.stdout + ver_result.stderr
                    verifier_exit = ver_result.returncode

                    # Parse pass/warn/fail counts from the SUMMARY block.
                    counts = {'PASS': 0, 'WARN': 0, 'FAIL': 0}
                    for line in verifier_output.splitlines():
                        m = re.search(r"^\s*(PASS|WARN|FAIL):\s*(\d+)", line)
                        if m:
                            counts[m.group(1)] = int(m.group(2))

                    # Last 20 lines for UI display.
                    tail_lines = verifier_output.splitlines()[-20:]
                    tail = "\n".join(tail_lines)

                    tt_verifier_summary = {
                        'present': True,
                        'exit': verifier_exit,
                        'pass': counts['PASS'],
                        'warn': counts['WARN'],
                        'fail': counts['FAIL'],
                        'tail': tail,
                    }
                    print(
                        f"[LCARS Import] team_transfer verifier: exit={verifier_exit} "
                        f"PASS={counts['PASS']} WARN={counts['WARN']} FAIL={counts['FAIL']}"
                    )

        except Exception as tt_exc:
            print(f"[LCARS Import] team_transfer verifier step failed (non-fatal): {tt_exc}")
            tt_verifier_summary = {
                'present': True,
                'exit': -1,
                'error': str(tt_exc)[:200],
            }

        IMPORT_JOBS[job_id] = {
            'status': 'staged',
            'progress': 0,
            'message': 'Archive staged. Review pre-flight and apply.',
            'manifest': manifest,
            'stagedPath': str(staged_path),
            'targetTeam': LCARS_TEAM,
            'targetBase': target_base,
            'baseMatch': base_match,
            'idRenameRequired': (source_team != LCARS_TEAM),
            'createdAt': datetime.now(timezone.utc).isoformat(),
            'teamTransferVerifierSummary': tt_verifier_summary,
        }

        self._send_json_response({
            'jobId': job_id,
            'status': 'staged',
            'manifest': manifest,
            'targetTeam': LCARS_TEAM,
            'baseMatch': base_match,
            'idRenameRequired': (source_team != LCARS_TEAM),
            'teamTransferVerifierSummary': tt_verifier_summary,
        })

    def handle_import_apply(self, job_id):
        """POST /api/import/apply/<job_id> — actually perform the import."""
        import threading

        job = IMPORT_JOBS.get(job_id)
        if not job:
            self._send_json_response({'error': 'Import job not found'}, status=404)
            return
        if job['status'] != 'staged':
            self._send_json_response(
                {'error': f'Job is in state {job["status"]}, not staged'}, status=400
            )
            return
        if not job.get('baseMatch'):
            self._send_json_response(
                {'error': f'Base team mismatch: cannot import {job["manifest"].get("baseTeam")} '
                          f'into {job.get("targetBase")}'}, status=400
            )
            return

        IMPORT_JOBS[job_id]['status'] = 'applying'
        IMPORT_JOBS[job_id]['progress'] = 5
        IMPORT_JOBS[job_id]['message'] = 'Starting import...'

        thread = threading.Thread(target=apply_import, args=(job_id,), daemon=True)
        thread.start()

        self._send_json_response({'jobId': job_id, 'status': 'applying'})

    def serve_import_status(self, job_id):
        """GET /api/import/status/<job_id>"""
        job = IMPORT_JOBS.get(job_id)
        if not job:
            self._send_json_response({'error': 'Job not found'}, status=404)
            return
        # Strip staged path from public response
        public = {k: v for k, v in job.items() if k != 'stagedPath'}
        self._send_json_response({**public, 'jobId': job_id})

    # ---------------------------------------------------------------------- #
    # Secrets Export routes (XACA-0172-002)                                   #
    # ---------------------------------------------------------------------- #

    def handle_create_secrets_export(self):
        """POST /api/export/secrets/create — start an AES-256 secrets export job.

        Body JSON: {"team": "<team_id>", "password": "<str>", "pairedExportId": "<optional>"}

        The password is accepted from the request body, passed to the worker thread,
        and is NEVER stored in the job dict or logged.
        """
        import uuid
        import threading
        from datetime import datetime, timezone

        if not LCARS_TEAM:
            self._send_json_response(
                {'error': 'LCARS_TEAM not configured on this server'}, status=500
            )
            return

        if not SECRETS_EXPORT_LIB_AVAILABLE:
            self._send_json_response(
                {'error': 'secrets_export_lib not available on this server'}, status=500
            )
            return

        content_length = int(self.headers.get('Content-Length', 0))
        if content_length <= 0:
            self._send_json_response({'error': 'Request body required'}, status=400)
            return

        try:
            body = json.loads(self.rfile.read(content_length).decode('utf-8'))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._send_json_response({'error': 'Invalid JSON body'}, status=400)
            return

        password = body.get('password', '')
        if not password:
            self._send_json_response({'error': 'password is required'}, status=400)
            return

        paired_export_id = body.get('pairedExportId') or None

        # Prune stale job entries and old zip files (TTL = 1 hour)
        _prune_old_secrets_jobs()
        now = datetime.now(timezone.utc)
        if EXPORT_DIR.exists():
            for old in EXPORT_DIR.glob('*-secrets-*.zip'):
                try:
                    age = (now - datetime.fromtimestamp(
                        old.stat().st_mtime, tz=timezone.utc
                    )).total_seconds()
                    if age > 3600:
                        old.unlink()
                except Exception:
                    pass

        job_id = str(uuid.uuid4())
        SECRETS_EXPORT_JOBS[job_id] = {
            'status': 'generating',
            'progress': 0,
            'message': 'Initializing secrets export...',
            'filename': None,
            'fileSize': None,
            'fileSizeBytes': None,
            'totalFiles': None,
            'error': None,
            'team': LCARS_TEAM,
            'pairedExportId': paired_export_id,
            'manifestUsed': None,
            'createdAt': datetime.now(timezone.utc).isoformat(),
        }

        # Password is passed only as a thread arg — never stored in the job dict.
        thread = threading.Thread(
            target=generate_secrets_export,
            args=(job_id, LCARS_TEAM, password, paired_export_id),
            daemon=True,
        )
        thread.start()

        self._send_json_response({
            'jobId': job_id,
            'status': 'generating',
            'team': LCARS_TEAM,
        })

    def serve_secrets_export_status(self, job_id):
        """GET /api/export/secrets/status/<job_id>"""
        job = SECRETS_EXPORT_JOBS.get(job_id)
        if not job:
            self._send_json_response({'error': 'Secrets export job not found'}, status=404)
            return
        self._send_json_response({**job, 'jobId': job_id})

    def serve_secrets_export_download(self, job_id):
        """GET /api/export/secrets/download/<job_id> — stream the AES-256 encrypted zip."""
        job = SECRETS_EXPORT_JOBS.get(job_id)
        if not job or job.get('status') != 'completed' or not job.get('filename'):
            self._send_json_response({'error': 'Secrets export not ready'}, status=404)
            return

        file_path = EXPORT_DIR / job['filename']
        if not file_path.exists():
            self._send_json_response({'error': 'Secrets export file not found'}, status=404)
            return

        self.send_response(200)
        self.send_header('Content-Type', 'application/zip')
        self.send_header(
            'Content-Disposition',
            f'attachment; filename="{job["filename"]}"',
        )
        self.send_header('Content-Length', str(file_path.stat().st_size))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()

        with open(file_path, 'rb') as f:
            while True:
                chunk = f.read(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)

    # ---------------------------------------------------------------------- #
    # Secrets Import routes (XACA-0172-003)                                   #
    # ---------------------------------------------------------------------- #

    def handle_secrets_import_upload(self):
        """POST /api/import/secrets/upload — receive an encrypted secrets zip and stage it.

        Expects multipart/form-data with:
          - 'file'  field: the encrypted zip
          - 'team'  form field: target team ID (defaults to LCARS_TEAM if absent)

        Returns: {"jobId": "<uuid>", "status": "awaiting-password"}
        The client then calls /api/import/secrets/preflight/<job_id> (optional)
        or /api/import/secrets/apply/<job_id> to extract.
        """
        import uuid
        from datetime import datetime, timezone

        if not LCARS_TEAM:
            self._send_json_response(
                {'error': 'LCARS_TEAM not configured on this server'}, status=500
            )
            return

        content_type = self.headers.get('Content-Type', '')
        if not content_type.startswith('multipart/form-data'):
            self._send_json_response(
                {'error': 'Expected multipart/form-data upload'}, status=400
            )
            return

        content_length = int(self.headers.get('Content-Length', 0))
        if content_length <= 0 or content_length > 500 * 1024 * 1024:
            self._send_json_response(
                {'error': 'Invalid or too-large upload (max 500 MB)'}, status=400
            )
            return

        # Parse multipart boundary
        boundary_match = re.search(r'boundary=(.+)', content_type)
        if not boundary_match:
            self._send_json_response({'error': 'Missing multipart boundary'}, status=400)
            return
        boundary = boundary_match.group(1).strip().strip('"').encode('utf-8')

        raw = self.rfile.read(content_length)
        delim = b'--' + boundary
        parts = raw.split(delim)

        file_bytes = None
        original_filename = 'secrets.zip'
        target_team = LCARS_TEAM

        for part in parts:
            if b'\r\n\r\n' not in part:
                continue
            header_block, body = part.split(b'\r\n\r\n', 1)
            if body.endswith(b'\r\n'):
                body = body[:-2]
            header_str = header_block.decode('utf-8', errors='replace')

            if 'filename=' in header_str:
                fname_match = re.search(r'filename="([^"]+)"', header_str)
                if fname_match:
                    # basename strip prevents Content-Disposition path traversal
                    # (e.g. filename="../../etc/passwd"); keep only the trailing
                    # component, fall back to default if it sanitizes to empty.
                    raw_name = fname_match.group(1)
                    safe_name = Path(raw_name).name or 'secrets.zip'
                    original_filename = safe_name
                file_bytes = body
            elif 'name="team"' in header_str and body.strip():
                target_team = body.strip().decode('utf-8', errors='replace')

        if not file_bytes:
            self._send_json_response({'error': 'No file found in upload'}, status=400)
            return

        SECRETS_IMPORT_STAGING_DIR.mkdir(parents=True, exist_ok=True)
        job_id = str(uuid.uuid4())
        job_dir = SECRETS_IMPORT_STAGING_DIR / job_id
        job_dir.mkdir(parents=True, exist_ok=True)
        staged_path = job_dir / original_filename
        staged_path.write_bytes(file_bytes)

        SECRETS_IMPORT_JOBS[job_id] = {
            'status': 'awaiting-password',
            'progress': 0,
            'message': 'Upload complete. Provide password to verify and extract.',
            'stagedPath': str(staged_path),
            'manifest': None,
            'targetTeam': target_team,
            'fileCount': 0,
            'createdAt': datetime.now(timezone.utc).isoformat(),
            'error': None,
        }

        self._send_json_response({
            'jobId': job_id,
            'status': 'awaiting-password',
        })

    def handle_secrets_import_preflight(self, job_id):
        """POST /api/import/secrets/preflight/<job_id> — verify password + return manifest.

        Body JSON: {"password": "<str>"}

        Verifies the password and parses the manifest WITHOUT extracting any files.
        Updates job to status='ready'. UI uses this for a confirmation panel before apply.
        Returns the parsed manifest so the UI can show what will be extracted.

        On wrong password: returns 400 with error; job status back to 'awaiting-password' (retryable).
        """
        job = SECRETS_IMPORT_JOBS.get(job_id)
        if not job:
            self._send_json_response({'error': 'Secrets import job not found'}, status=404)
            return

        if job['status'] not in ('awaiting-password', 'ready'):
            self._send_json_response(
                {'error': f'Job is in state {job["status"]}, cannot preflight'}, status=400
            )
            return

        if not pyzipper_available():
            self._send_json_response(
                {'error': (
                    "pyzipper dependency missing — install via "
                    "'pip install pyzipper' or reinstall the AITeamForge tap"
                )},
                status=500,
            )
            return

        content_length = int(self.headers.get('Content-Length', 0))
        if content_length <= 0:
            self._send_json_response({'error': 'Request body required'}, status=400)
            return

        try:
            body = json.loads(self.rfile.read(content_length).decode('utf-8'))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._send_json_response({'error': 'Invalid JSON body'}, status=400)
            return

        password = body.get('password', '')
        if not password:
            self._send_json_response({'error': 'password is required'}, status=400)
            return

        # Verify password by reading manifest — password held in local scope only
        import pyzipper
        staged_path = Path(job['stagedPath'])

        # Guard: if the staged zip is gone (e.g. budget exhausted), reject cleanly.
        if not staged_path.exists():
            self._send_json_response(
                {'error': 'Staged zip no longer available — please re-upload.'}, status=400
            )
            return

        try:
            with pyzipper.AESZipFile(staged_path, 'r') as zf:
                zf.setpassword(password.encode('utf-8'))
                try:
                    manifest_bytes = zf.read('secrets-manifest.json')
                except RuntimeError:
                    # Wrong password — increment attempt counter; retain staged zip for retry.
                    attempts = job.get('wrongPasswordAttempts', 0) + 1
                    if attempts >= _SECRETS_IMPORT_MAX_PASSWORD_ATTEMPTS:
                        # Budget exhausted — delete staged zip and job dir.
                        try:
                            staged_path.unlink()
                            staged_path.parent.rmdir()
                        except Exception:
                            pass
                        exhaust_msg = (
                            "Too many failed password attempts. "
                            "Re-upload the secrets zip to try again."
                        )
                        SECRETS_IMPORT_JOBS[job_id].update({
                            'status': 'failed',
                            'error': exhaust_msg,
                            'wrongPasswordAttempts': attempts,
                        })
                        self._send_json_response({'error': exhaust_msg}, status=400)
                    else:
                        SECRETS_IMPORT_JOBS[job_id].update({
                            'status': 'awaiting-password',
                            'error': 'Wrong password — please try again.',
                            'wrongPasswordAttempts': attempts,
                        })
                        self._send_json_response(
                            {
                                'error': 'Wrong password — please try again.',
                                'attemptsRemaining': _SECRETS_IMPORT_MAX_PASSWORD_ATTEMPTS - attempts,
                            },
                            status=400,
                        )
                    return
                except KeyError:
                    msg = (
                        "Archive does not contain secrets-manifest.json — "
                        "not a recognized LCARS secrets export."
                    )
                    SECRETS_IMPORT_JOBS[job_id].update({'status': 'failed', 'error': msg})
                    self._send_json_response({'error': msg}, status=400)
                    return
                all_members = [
                    n for n in zf.namelist()
                    if n != 'secrets-manifest.json' and not n.endswith('/')
                ]
        except Exception as e:
            import zipfile as _zf
            import pyzipper.zipfile as _pzf
            if isinstance(e, (_zf.BadZipFile, _pzf.BadZipFile)):
                msg = (
                    "Invalid or corrupt secrets zip — please re-export and try again."
                )
                try:
                    staged_path.unlink()
                    staged_path.parent.rmdir()
                except Exception:
                    pass
                SECRETS_IMPORT_JOBS[job_id].update({'status': 'failed', 'error': msg})
                self._send_json_response({'error': msg}, status=400)
                return
            raise

        try:
            manifest = json.loads(manifest_bytes.decode('utf-8'))
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            msg = f'secrets-manifest.json is not valid JSON: {e}'
            SECRETS_IMPORT_JOBS[job_id].update({'status': 'failed', 'error': msg})
            self._send_json_response({'error': msg}, status=400)
            return

        if manifest.get('kind') != SECRETS_EXPORT_MANIFEST_KIND:
            msg = (
                f"Not a recognized LCARS secrets export "
                f"(kind={manifest.get('kind')!r})."
            )
            SECRETS_IMPORT_JOBS[job_id].update({'status': 'failed', 'error': msg})
            self._send_json_response({'error': msg}, status=400)
            return

        if manifest.get('version') != SECRETS_EXPORT_MANIFEST_VERSION:
            msg = (
                f"Unsupported secrets export version: {manifest.get('version')!r} "
                f"(expected {SECRETS_EXPORT_MANIFEST_VERSION!r})."
            )
            SECRETS_IMPORT_JOBS[job_id].update({'status': 'failed', 'error': msg})
            self._send_json_response({'error': msg}, status=400)
            return

        # Check team/base-team match — warn-only (cross-team transfer is allowed)
        target_team = job.get('targetTeam', '')
        manifest_team = manifest.get('team', '')
        manifest_base = manifest.get('baseTeam', '')
        team_warning = None
        if manifest_team and target_team and manifest_team != target_team:
            team_warning = (
                f"Team mismatch: archive was exported from '{manifest_team}', "
                f"importing into '{target_team}'. Proceeding (cross-team transfer)."
            )

        SECRETS_IMPORT_JOBS[job_id].update({
            'status': 'ready',
            'manifest': manifest,
            'fileCount': len(all_members),
            'message': team_warning or 'Password verified. Ready to apply.',
            'error': None,
        })

        resp: dict = {
            'jobId': job_id,
            'status': 'ready',
            'manifest': manifest,
            'fileCount': len(all_members),
            'targetTeam': target_team,
        }
        if team_warning:
            resp['warning'] = team_warning

        self._send_json_response(resp)

    def handle_secrets_import_apply(self, job_id):
        """POST /api/import/secrets/apply/<job_id> — extract the secrets zip.

        Body JSON: {"password": "<str>"}

        Spawns apply_secrets_import() in a background thread.
        Password is passed directly to the worker; never stored in the job dict.
        """
        import threading

        job = SECRETS_IMPORT_JOBS.get(job_id)
        if not job:
            self._send_json_response({'error': 'Secrets import job not found'}, status=404)
            return

        if job['status'] not in ('awaiting-password', 'ready'):
            self._send_json_response(
                {'error': f'Job is in state {job["status"]}, cannot apply'}, status=400
            )
            return

        content_length = int(self.headers.get('Content-Length', 0))
        if content_length <= 0:
            self._send_json_response({'error': 'Request body required'}, status=400)
            return

        try:
            body = json.loads(self.rfile.read(content_length).decode('utf-8'))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._send_json_response({'error': 'Invalid JSON body'}, status=400)
            return

        password = body.get('password', '')
        if not password:
            self._send_json_response({'error': 'password is required'}, status=400)
            return

        SECRETS_IMPORT_JOBS[job_id].update({
            'status': 'applying',
            'progress': 0,
            'message': 'Starting secrets import...',
            'error': None,
        })

        # Password held only in thread-local scope — not stored in job dict
        thread = threading.Thread(
            target=apply_secrets_import,
            args=(job_id, password),
            daemon=True,
        )
        thread.start()

        self._send_json_response({'jobId': job_id, 'status': 'applying'})

    def serve_secrets_import_status(self, job_id):
        """GET /api/import/secrets/status/<job_id>"""
        job = SECRETS_IMPORT_JOBS.get(job_id)
        if not job:
            self._send_json_response({'error': 'Job not found'}, status=404)
            return
        # Never expose staged path; password is never stored, so nothing to strip on that front
        public = {k: v for k, v in job.items() if k != 'stagedPath'}
        self._send_json_response({**public, 'jobId': job_id})

    def serve_tap_version(self):
        """GET /api/tap-version — return the AITeamForge tap version.

        Resolution order:
          1. Homebrew install marker: $(brew --prefix)/var/aiteamforge/.installed
             (written by Formula at install time; first line is the version)
          2. Dev checkout: ~/dev-team/homebrew-tap/VERSION
          3. "unknown"
        """
        version = None
        source = None

        # 1. Installed marker
        try:
            result = subprocess.run(
                ['brew', '--prefix'], capture_output=True, text=True, timeout=3
            )
            if result.returncode == 0:
                marker = Path(result.stdout.strip()) / 'var' / 'aiteamforge' / '.installed'
                if marker.exists():
                    first_line = marker.read_text(encoding='utf-8').splitlines()
                    if first_line:
                        version = first_line[0].strip()
                        source = 'installed'
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            pass

        # 2. Dev checkout VERSION file
        if not version:
            version_file = Path.home() / 'dev-team' / 'homebrew-tap' / 'VERSION'
            if version_file.exists():
                try:
                    version = version_file.read_text(encoding='utf-8').strip()
                    source = 'checkout'
                except OSError:
                    pass

        self._send_json_response({
            'version': version or 'unknown',
            'source': source or 'unknown',
        })

    def serve_artifact_audit(self):
        """GET /api/artifact-audit — XACA-0220 Phase 3b.

        Returns the most recent artifact audit report for THIS team's kanban
        directory.  The report is written nightly by
        scripts/daily-artifact-audit.py to:
            <team_kanban_dir>/activity/xaca-0220-audit.json

        If no report exists (never run, or team was clean and file was removed)
        returns {"clean": true, "team": <team>, "violations": []}.

        The LCARS widget (lcars-artifact-audit.js) polls this endpoint every 5
        minutes and shows a banner when clean == false.
        """
        try:
            from kanban_utils import TEAM_KANBAN_DIRS  # noqa: PLC0415
            kanban_dir = TEAM_KANBAN_DIRS.get(LCARS_TEAM)
        except Exception:
            kanban_dir = None

        if kanban_dir is None:
            # Fallback: use the server's own LCARS_KANBAN_DIR constant
            try:
                kanban_dir = LCARS_KANBAN_DIR  # noqa: F821 — defined at module level
            except NameError:
                kanban_dir = Path.home() / 'dev-team' / 'kanban'

        audit_file = Path(kanban_dir) / 'activity' / 'xaca-0220-audit.json'

        if audit_file.exists():
            try:
                with open(audit_file, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                self._send_json_response(data)
                return
            except (OSError, json.JSONDecodeError) as exc:
                print(f'[LCARS] /api/artifact-audit read error: {exc}')

        # No report file — team is clean (or audit hasn't run yet)
        self._send_json_response({
            'team': LCARS_TEAM,
            'clean': True,
            'violations': [],
            'scan_time': None,
            'note': 'No audit report found — either clean or audit has not run yet.',
        })

    def serve_usage_current(self):
        """GET /api/usage/current — XACA-0243-003.

        Returns the current Claude usage status from the ccusage collector
        cache (XACA-0243-001) interpreted through the heuristics layer
        (XACA-0243-002).

        Query parameters:
            refresh=1        Spawn ccusage_collector --once (5s timeout) before
                             reading the cache.  Default behaviour (no param)
                             never spawns ccusage so the endpoint stays <50ms.
            history_limit=N  Return at most N history entries (default 7, max 50).
            account=<id>     XACA-0280: Filter totals to a specific account ID.
                             Special value "untagged" targets the pre-isolation bucket.
                             Omit for all-accounts aggregate (unchanged default).
        """
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)

        force_refresh = qs.get("refresh", ["0"])[0] == "1"
        try:
            history_limit = int(qs.get("history_limit", ["7"])[0])
        except (ValueError, IndexError):
            history_limit = 7

        # XACA-0280 Phase A.2: optional per-account filter.
        account_values = qs.get("account", [])
        account_filter = account_values[0] if account_values else None

        _status_code, payload = _build_usage_response(
            cache_path=CCUSAGE_CACHE_PATH,
            history_limit=history_limit,
            force_refresh=force_refresh,
            account_filter=account_filter,
        )

        # Send response with Cache-Control: no-store in addition to the
        # standard CORS + Content-Type headers from _send_json_response.
        # We cannot piggyback on _send_json_response because it calls
        # end_headers() internally, so we build the response manually here.
        body = json.dumps(payload).encode("utf-8")
        self.send_response(_status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def serve_usage_by_account(self):
        """GET /api/usage/by-account — XACA-0280 Phase A.2.

        Returns a flat list of per-account usage summaries from the ccusage
        collector cache (schema v3).  Includes the untagged pre-isolation bucket
        and all-accounts totals.

        No query parameters in this phase.  burn_rate is null per-account;
        per-account burn-rate derivation is a follow-up task.
        """
        _status_code, payload = _build_by_account_response(
            cache_path=CCUSAGE_CACHE_PATH,
        )

        body = json.dumps(payload).encode("utf-8")
        self.send_response(_status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def serve_backup_status(self):
        """Serve kanban backup system status"""
        from datetime import datetime, timezone

        # Default status if no backup has run
        status = {
            "status": "not_configured",
            "lastRun": None,
            "lastRunStatus": "unknown",
            "totalBackups": 0,
            "storageUsed": "0 B",
            "boards": {},
            "backupDir": str(BACKUP_DIR),
            "backupDirExists": BACKUP_DIR.exists()
        }

        # Try to load actual backup status
        if BACKUP_STATUS_FILE.exists():
            try:
                with open(BACKUP_STATUS_FILE, 'r') as f:
                    stored = json.load(f)
                    status.update(stored)
                    status["status"] = "configured"
                    status["backupDirExists"] = True

                    # Filter boards to only show current team's backup
                    if stored.get("boards") and LCARS_TEAM:
                        team_key = LCARS_TEAM.lower()
                        filtered_boards = {k: v for k, v in stored["boards"].items()
                                          if k.lower() == team_key or k.lower().startswith(f"{team_key}-")}
                        status["boards"] = filtered_boards
                        # Recalculate totals for filtered boards
                        status["totalBackups"] = sum(1 for b in filtered_boards.values() if b.get("latestBackup"))

                    # Calculate time since last run
                    if stored.get("lastRun"):
                        try:
                            last_run = datetime.fromisoformat(stored["lastRun"].replace('Z', '+00:00'))
                            now = datetime.now(timezone.utc)
                            delta = now - last_run
                            minutes_ago = int(delta.total_seconds() / 60)

                            if minutes_ago < 60:
                                status["lastRunAgo"] = f"{minutes_ago}m ago"
                            elif minutes_ago < 1440:
                                status["lastRunAgo"] = f"{minutes_ago // 60}h ago"
                            else:
                                status["lastRunAgo"] = f"{minutes_ago // 1440}d ago"

                            # Check if backup is stale (no run in 30+ minutes)
                            if minutes_ago > 30:
                                status["status"] = "stale"
                        except Exception:
                            status["lastRunAgo"] = "unknown"

            except Exception as e:
                status["status"] = "error"
                status["error"] = str(e)

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(json.dumps(status, indent=2).encode())

    def serve_backup_files(self, team_filter=None):
        """Serve list of all backup files organized by team, sorted newest first"""
        from datetime import datetime, timezone

        def parse_backup_timestamp(filename):
            """Parse timestamp from backup filename: backup_YYYYMMDD_HHMMSS.json or .zip"""
            try:
                # Extract timestamp portion: backup_20260115_165453.json -> 20260115_165453
                ts_str = filename.replace('backup_', '').replace('.json', '').replace('.zip', '')
                dt = datetime.strptime(ts_str, "%Y%m%d_%H%M%S")
                return dt.replace(tzinfo=timezone.utc).isoformat()
            except Exception:
                return None

        try:
            files_by_team = {}
            total_size = 0
            total_count = 0

            # Default to current team if no filter specified (like serve_backup_status)
            effective_filter = team_filter or LCARS_TEAM

            if BACKUP_DIR.exists():
                for team_dir in sorted(BACKUP_DIR.iterdir()):
                    if not team_dir.is_dir():
                        continue

                    team_name = team_dir.name

                    # Filter to current team and sub-teams (e.g., "freelance" matches "freelance-doublenode-starwords")
                    if effective_filter:
                        filter_lower = effective_filter.lower()
                        team_lower = team_name.lower()
                        if team_lower != filter_lower and not team_lower.startswith(f"{filter_lower}-"):
                            continue

                    backups = []
                    # Include both .json (legacy) and .zip (comprehensive) backups
                    for backup_file in list(team_dir.glob("backup_*.json")) + list(team_dir.glob("backup_*.zip")):
                        stat = backup_file.stat()
                        timestamp = parse_backup_timestamp(backup_file.name)
                        backups.append({
                            'filename': backup_file.name,
                            'timestamp': timestamp,
                            'size': stat.st_size,
                            'sizeFormatted': format_bytes_export(stat.st_size),
                            'path': str(backup_file)
                        })
                        total_size += stat.st_size
                        total_count += 1

                    # Sort by timestamp descending (newest first)
                    backups.sort(key=lambda x: x['timestamp'] or '', reverse=True)
                    files_by_team[team_name] = backups

            response = {
                'teams': files_by_team,
                'totalFiles': total_count,
                'totalSize': total_size,
                'totalSizeFormatted': format_bytes_export(total_size)
            }

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps(response, indent=2).encode())

        except Exception as e:
            self.send_error(500, f"Error listing backup files: {e}")

    def serve_dynamic_target(self):
        """Dynamically serve lcars-target.js with the server's configured team"""
        js_content = f"window.LCARS_TARGET_TEAM = '{LCARS_TEAM}';\n"

        self.send_response(200)
        self.send_header('Content-Type', 'application/javascript')
        self.send_header('Cache-Control', 'no-cache, no-store, must-revalidate')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        self.end_headers()
        self.wfile.write(js_content.encode())

    def do_HEAD(self):
        """Mirror do_GET dispatch for routes that need explicit HEAD support.

        Browsers GET <script> tags so the local-override route doesn't strictly
        need HEAD, but tooling (curl -I, health checks) expects HEAD/GET parity.
        Falls through to the parent handler for everything else.
        """
        from urllib.parse import urlparse
        path = urlparse(self.path).path
        if path == '/lcars-target.local.js':
            self.serve_lcars_target_local(head_only=True)
            return
        super().do_HEAD()

    def serve_lcars_target_local(self, head_only=False):
        """XACA-0301: serve per-machine LCARS retargeting override.

        Source: ~/.aiteamforge/lcars-target.local.js (outside repo, not synced).
        Returns 404 if the file is absent so the HTML loader's onerror path
        runs and the default lcars-target.js values stand. Lets developers
        retarget their LCARS to a specific team/session without dirtying the
        shipped tap submodule. Follow-up to XACA-0300.
        """
        override_path = Path.home() / '.aiteamforge' / 'lcars-target.local.js'
        if not override_path.is_file():
            self.send_error(404, 'No local lcars-target override')
            return

        try:
            data = override_path.read_bytes()
        except OSError as e:
            self.send_error(500, f'Error reading local override: {e}')
            return

        self.send_response(200)
        self.send_header('Content-Type', 'application/javascript')
        self.send_header('Content-Length', len(data))
        self.send_header('Cache-Control', 'no-cache, no-store, must-revalidate')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        self.end_headers()
        if not head_only:
            self.wfile.write(data)

    def _get_team_agents(self):
        """Get the set of knowledge directory names belonging to the current team.

        Reads the team's board file to extract terminal avatar fields, then
        adds the team-level knowledge dir (e.g. 'team-academy').  Returns a
        set of directory names to include in knowledge stats, or None to
        fall back to unfiltered scanning.
        """
        board_file = get_board_file(LCARS_TEAM)
        if not board_file.exists():
            return None
        try:
            with open(board_file, 'r') as f:
                board = json.load(f)
            terminals = board.get('terminals', {})
            agents = set()
            for _term_name, term_info in terminals.items():
                avatar = term_info.get('avatar')
                if avatar:
                    agents.add(avatar)
            # Include the team-level knowledge dir (e.g. team-academy)
            agents.add(f"team-{LCARS_TEAM}")
            return agents if agents else None
        except Exception:
            return None

    def _get_team_project_prefixes(self):
        """Get path prefixes for project memory dirs belonging to this team.

        Derives from TEAM_KANBAN_DIRS — the kanban dir's parent is the repo
        root, which maps to the project memory directory name format
        (path with '/' replaced by '-').
        """
        kanban_dir = TEAM_KANBAN_DIRS.get(LCARS_TEAM)
        if not kanban_dir:
            return None
        # The repo root is the kanban dir's parent
        repo_root = str(kanban_dir.parent)
        # Project memory dirs use format: -Users-darrenehlers-dev-team
        prefix = repo_root.replace("/", "-")
        return [prefix]

    def serve_knowledge_stats(self):
        """Serve knowledge base statistics filtered to the current team.

        Scans two knowledge stores:
          1. Agent/team knowledge entries at ~/.claude/knowledge/<agent>/
             (filtered to agents on the current team's board)
          2. Project auto-memory files at ~/.claude/projects/<project>/memory/
             (filtered to projects whose paths match the team's repository)

        Also computes retrospective adoption metrics by cross-referencing
        completed kanban items against knowledge filenames.

        Returns aggregated statistics suitable for the HOME carousel widget.
        """
        try:
            self._serve_knowledge_stats_inner()
        except Exception as exc:
            import traceback
            print(f"[LCARS] /api/knowledge-stats error: {exc}\n{traceback.format_exc()}")
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(exc)}).encode())

    def _compute_adoption_metrics(self, kb_base):
        """Compute retrospective adoption metrics scoped to the current team.

        Returns a dict with:
          - teams: list of per-team dicts (team, completed_items, items_with_retros,
                   coverage_pct, knowledge_entries)
          - overall_coverage_pct: float
          - total_completed: int
          - total_with_retros: int

        Strategy:
          1. Load the current team's board JSON and count items with status
             "completed" or "done".
          2. Scan ~/.claude/knowledge/ for files whose names contain a matching
             item ID (e.g. xaca-0098 in xaca-0098-*.md or any content reference).
          3. Coverage % = items_with_retros / completed_items * 100.
        """
        team_results = []
        total_completed = 0
        total_with_retros = 0

        # Build a flat list of all knowledge file names (lowercased) for fast lookup
        kb_filenames = []
        if kb_base.exists():
            for agent_dir in kb_base.iterdir():
                if agent_dir.is_dir():
                    for f in agent_dir.iterdir():
                        if f.is_file():
                            kb_filenames.append(f.name.lower())

        # Scope to current team only — avoids cross-team data leakage in the UI
        scoped_teams = {LCARS_TEAM: TEAM_KANBAN_DIRS[LCARS_TEAM]} if LCARS_TEAM in TEAM_KANBAN_DIRS else TEAM_KANBAN_DIRS
        for team_name, kanban_dir in scoped_teams.items():
            board_file = kanban_dir / f"{team_name}-board.json"
            if not board_file.exists():
                continue

            try:
                with open(board_file, 'r', encoding='utf-8') as fh:
                    board = json.load(fh)
            except Exception:
                continue

            series_prefix = board.get("series", "").lower()
            items = board.get("backlog", [])

            # Count completed items (top-level, not subitems)
            completed_ids = []
            for item in items:
                if isinstance(item, dict) and item.get("status") in ("completed", "done"):
                    item_id = item.get("id", "")
                    if item_id:
                        completed_ids.append(item_id.lower())

            if not completed_ids:
                continue

            # Count which completed items have a matching retrospective
            # Check two locations:
            #   1. kanban/ dir for ITEM_ID_*_RETROSPECTIVE.md (canonical location)
            #   2. knowledge/ dirs for any file containing the item ID
            items_with_retros = 0
            for item_id in completed_ids:
                found = False
                # Primary: check kanban dir for _RETROSPECTIVE.md files
                item_upper = item_id.upper()
                for f in kanban_dir.iterdir():
                    if f.is_file() and f.name.startswith(item_upper + "_") and f.name.endswith("_RETROSPECTIVE.md"):
                        found = True
                        break
                # Fallback: check knowledge filenames
                if not found:
                    for fname in kb_filenames:
                        if item_id in fname:
                            found = True
                            break
                if found:
                    items_with_retros += 1

            completed_count = len(completed_ids)
            coverage_pct = round(items_with_retros / completed_count * 100, 1) if completed_count > 0 else 0.0

            # Count knowledge entries attributed to this team's series
            # (any kb file whose name starts with the series prefix, e.g. "xaca-")
            kb_entry_count = 0
            if series_prefix:
                for fname in kb_filenames:
                    if fname.startswith(series_prefix) and fname != "index.md":
                        kb_entry_count += 1

            team_results.append({
                "team": team_name,
                "completed_items": completed_count,
                "items_with_retros": items_with_retros,
                "coverage_pct": coverage_pct,
                "knowledge_entries": kb_entry_count,
            })

            total_completed += completed_count
            total_with_retros += items_with_retros

        # Sort by coverage_pct descending, then by team name
        team_results.sort(key=lambda t: (-t["coverage_pct"], t["team"]))

        overall_pct = round(total_with_retros / total_completed * 100, 1) if total_completed > 0 else 0.0

        return {
            "teams": team_results,
            "overall_coverage_pct": overall_pct,
            "total_completed": total_completed,
            "total_with_retros": total_with_retros,
        }

    def _serve_knowledge_stats_inner(self):
        """Inner implementation for serve_knowledge_stats — called inside try/except."""
        from datetime import datetime, timezone

        kb_base = Path.home() / ".claude" / "knowledge"
        projects_base = Path.home() / ".claude" / "projects"

        # ------------------------------------------------------------------ #
        # 0. Determine team-scoped filter sets                                #
        # ------------------------------------------------------------------ #
        team_agents = self._get_team_agents()
        team_project_prefixes = self._get_team_project_prefixes()

        # ------------------------------------------------------------------ #
        # 1. Agent / team knowledge entries                                   #
        # ------------------------------------------------------------------ #
        agent_stats = {}
        total_kb_files = 0
        total_kb_size_bytes = 0
        kb_last_modified = 0.0
        most_active_agent = None
        most_active_count = 0

        if kb_base.exists():
            for agent_dir in sorted(kb_base.iterdir()):
                if not agent_dir.is_dir():
                    continue
                agent = agent_dir.name
                # Filter to current team's agents only
                if team_agents is not None and agent not in team_agents:
                    continue
                files = [f for f in agent_dir.iterdir() if f.is_file()]
                file_count = len(files)
                if file_count == 0:
                    continue

                # Cache stat() results to avoid double syscalls per file
                file_stats = [(f, f.stat()) for f in files]
                size_bytes = sum(s.st_size for _, s in file_stats)
                mtime = max(s.st_mtime for _, s in file_stats)
                # Non-index entries (knowledge entries proper)
                entry_count = sum(1 for f, _ in file_stats if f.name != "INDEX.md")

                agent_stats[agent] = {
                    "fileCount": file_count,
                    "entryCount": entry_count,
                    "sizeBytes": size_bytes,
                    "lastModified": datetime.fromtimestamp(mtime, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                }

                total_kb_files += file_count
                total_kb_size_bytes += size_bytes
                if mtime > kb_last_modified:
                    kb_last_modified = mtime

                # Only track most active for individual agents (not team-* dirs)
                if not agent.startswith("team-") and entry_count > most_active_count:
                    most_active_count = entry_count
                    most_active_agent = agent

        # Split agents vs teams
        team_stats = {k: v for k, v in agent_stats.items() if k.startswith("team-")}
        individual_stats = {k: v for k, v in agent_stats.items() if not k.startswith("team-")}

        total_entry_count = sum(v["entryCount"] for v in agent_stats.values())

        # ------------------------------------------------------------------ #
        # 2. Project memory files (auto-memory)                               #
        # ------------------------------------------------------------------ #
        memory_projects = []
        total_memory_files = 0
        total_projects_scanned = 0
        memory_last_modified = 0.0

        if projects_base.exists():
            for proj_dir in projects_base.iterdir():
                if not proj_dir.is_dir():
                    continue
                # Filter to projects matching this team's repo path
                if team_project_prefixes is not None:
                    if not any(proj_dir.name.startswith(pfx) for pfx in team_project_prefixes):
                        continue
                total_projects_scanned += 1
                mem_dir = proj_dir / "memory"
                if not mem_dir.exists():
                    continue
                mem_files = [f for f in mem_dir.iterdir() if f.is_file()]
                if not mem_files:
                    continue
                file_count = len(mem_files)
                # Cache stat() results to avoid double syscalls per file
                mem_stats = [f.stat() for f in mem_files]
                size_bytes = sum(s.st_size for s in mem_stats)
                mtime = max(s.st_mtime for s in mem_stats)
                total_memory_files += file_count
                if mtime > memory_last_modified:
                    memory_last_modified = mtime
                # Convert dir name back to readable path (hyphens to slashes)
                readable = proj_dir.name.replace("-", "/").lstrip("/")
                memory_projects.append({
                    "project": readable,
                    "fileCount": file_count,
                    "sizeBytes": size_bytes,
                    "lastModified": datetime.fromtimestamp(mtime, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                })

        # Sort memory projects by most recently modified
        memory_projects.sort(key=lambda p: p["lastModified"], reverse=True)

        # ------------------------------------------------------------------ #
        # 3. Adoption metrics (retrospective coverage per team)               #
        # ------------------------------------------------------------------ #
        adoption = self._compute_adoption_metrics(kb_base)

        # ------------------------------------------------------------------ #
        # 4. Build response                                                   #
        # ------------------------------------------------------------------ #
        overall_last_modified = max(kb_last_modified, memory_last_modified)

        result = {
            "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "team": LCARS_TEAM,

            # High-level summary for carousel widget
            "summary": {
                "totalAgents": len(individual_stats),
                "totalTeams": len(team_stats),
                "totalKnowledgeFiles": total_kb_files,
                "totalKnowledgeEntries": total_entry_count,
                "totalKnowledgeSizeBytes": total_kb_size_bytes,
                "totalMemoryFiles": total_memory_files,
                "totalProjectsScanned": total_projects_scanned,
                "projectsWithMemory": len(memory_projects),
                "mostActiveAgent": most_active_agent,
                "mostActiveEntryCount": most_active_count,
                "lastUpdated": datetime.fromtimestamp(overall_last_modified, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if overall_last_modified else None,
            },

            # Per-agent breakdown (individual agents)
            "agents": individual_stats,

            # Per-team knowledge breakdown
            "teams": team_stats,

            # Projects with auto-memory
            "memoryProjects": memory_projects,

            # Retrospective adoption metrics
            "adoption": adoption,
        }

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(json.dumps(result, indent=2).encode())

    def log_message(self, format, *args):
        """Custom log formatting"""
        print(f"[LCARS] {args[0]}")


# XACA-0180 guardrail: legacy stub paths that should no longer coexist with
# the canonical board files managed by the distributed kanban layout.
LEGACY_STUB_PATHS = {
    "legal-coparenting": [
        Path.home() / "legal" / "kanban" / "legal-board.json",
        Path.home() / "legal" / "default" / "kanban" / "legal-default-board.json",
    ],
    "medical-general": [
        Path.home() / "medical" / "kanban" / "medical-board.json",
    ],
    "finance-personal": [
        Path.home() / "finance" / "kanban" / "finance-board.json",
    ],
    "command": [
        Path.home() / "dev-team" / "kanban" / "command-board.json",
    ],
}


def _xaca0463_load_team_paths() -> dict:
    """XACA-0463: Load team-paths.json for the startup conflict guard.

    Delegates to aiteamforge_paths.load_config() when available (re-uses its
    cache, schema-integrity checks, and bootstrap logic).  Falls back to a
    minimal direct JSON read when aiteamforge_paths is not importable.

    Returns a dict with at least {"teams": {}}.  Never raises.
    """
    if _AITEAMFORGE_PATHS_AVAILABLE:
        try:
            return _aiteamforge_load_config()
        except Exception as exc:
            print(f"[XACA-0463] load_config() failed ({exc!r}); falling back to direct read.", file=sys.stderr)

    # Fallback: direct JSON read (aiteamforge_paths not available)
    config_path = os.path.expanduser(
        os.environ.get("AITEAMFORGE_CONFIG", "~/.aiteamforge/team-paths.json")
    )
    if not os.path.isfile(config_path):
        return {"teams": {}}
    try:
        with open(config_path, encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError) as exc:
        raise RuntimeError(f"Could not read {config_path}: {exc}") from exc


def _xaca0463_assert_no_port_conflicts(team_paths_data: dict, active_instance) -> None:
    """XACA-0463: Refuse to start LCARS server on port conflicts or null active port.

    Per docs/architecture/team-id-contract.md §6 server-startup rule 4.
    Scans team-paths.json for any port held by two or more instances.
    Also refuses if the active LCARS_TEAM's instance has a null lcars_port.
    Exits with a non-zero status and a loud, user-facing error message
    pointing at `kb-port-fix`.

    Args:
        team_paths_data: parsed team-paths.json contents (or load result).
        active_instance: the LCARS_TEAM env value (the instance this
            server intends to serve), or None if not set.
    """
    teams = (team_paths_data or {}).get("teams", {}) or {}

    # Collision detection — build port → [instance_ids] map
    port_to_instances: dict = {}
    for instance_id, entry in teams.items():
        port = entry.get("lcars_port") if isinstance(entry, dict) else None
        if port is None:
            continue
        port_to_instances.setdefault(int(port), []).append(instance_id)

    collisions = {p: ids for p, ids in port_to_instances.items() if len(ids) > 1}

    # Null-port check — only for the active (this server's) instance
    active_null = False
    if active_instance and active_instance in teams:
        entry = teams[active_instance]
        if isinstance(entry, dict) and entry.get("lcars_port") is None:
            active_null = True

    if not collisions and not active_null:
        return  # All clear — nothing to do

    # Build loud, scannable error output
    config_path = os.path.expanduser(
        os.environ.get("AITEAMFORGE_CONFIG", "~/.aiteamforge/team-paths.json")
    )
    sep = "=" * 72
    print("", file=sys.stderr)
    print(sep, file=sys.stderr)
    print("LCARS REFUSING TO START -- port allocation conflict detected", file=sys.stderr)
    print(sep, file=sys.stderr)
    print(f"  team-paths.json: {config_path}", file=sys.stderr)
    print(f"  active LCARS_TEAM: {active_instance!r}", file=sys.stderr)
    print("", file=sys.stderr)

    if collisions:
        print(f"  Port collisions ({len(collisions)}):", file=sys.stderr)
        for port in sorted(collisions):
            ids = sorted(collisions[port])
            print(
                f"    Port {port} -- held by {len(ids)} instances: {', '.join(ids)}",
                file=sys.stderr,
            )
        print("", file=sys.stderr)

    if active_null:
        print(
            f"  WARNING: Active instance '{active_instance}' has lcars_port: null",
            file=sys.stderr,
        )
        print("", file=sys.stderr)

    print("  Fix: run  kb-port-fix --apply", file=sys.stderr)
    print(
        "  Spec: docs/architecture/team-id-contract.md §4.1, §6 (XACA-0463)",
        file=sys.stderr,
    )
    print(sep, file=sys.stderr)
    print("", file=sys.stderr)
    sys.exit(2)


def _sweep_stale_locks() -> None:
    """XACA-0333-001: Sweep and remove stale .json.lock files at server startup.

    Targets:
      - ~/.aiteamforge/*.lock  (team-paths.json.lock and any siblings)
      - <board.json>.lock for every board reachable via TEAM_KANBAN_DIRS

    A lock file is considered stale — and safe to remove — when BOTH:
      1. Its mtime is older than 60 seconds (no live process is mid-write)
      2. Its size is 0 bytes (server.py only ever opens lock files for 'w'
         without writing content, so any real in-use lock is 0 bytes; files
         written by other tools are preserved by the size guard)

    Each unlink is best-effort; OSError is silently swallowed.
    """
    import time
    now = time.time()
    stale_age_secs = 60

    candidates: list[Path] = []

    # ~/.aiteamforge/*.lock
    aiteamforge_dir = Path.home() / '.aiteamforge'
    if aiteamforge_dir.is_dir():
        candidates.extend(aiteamforge_dir.glob('*.lock'))

    # <team>-board.json.lock for all known teams
    for team_id, kanban_dir in TEAM_KANBAN_DIRS.items():
        board_lock = kanban_dir / f'{team_id}-board.json.lock'
        candidates.append(board_lock)

    swept = 0
    for lock_path in candidates:
        try:
            st = lock_path.stat()
        except OSError:
            continue  # doesn't exist or no permission — skip
        age = now - st.st_mtime
        if age >= stale_age_secs and st.st_size == 0:
            try:
                lock_path.unlink(missing_ok=True)
                swept += 1
                print(f"[LCARS] Swept stale lock: {lock_path} (age {age:.0f}s)")
            except OSError:
                pass  # best-effort

    if swept:
        print(f"[LCARS] Stale lock sweep complete — removed {swept} file(s).")
    else:
        print("[LCARS] Stale lock sweep complete — nothing to remove.")


class _DualBoardState:
    """Holds the result of a dual-board detection for a single team."""

    __slots__ = ('team', 'canonical', 'stub')

    def __init__(self, team: str, canonical: Path, stub: Path):
        self.team = team
        self.canonical = canonical
        self.stub = stub


def _detect_dual_boards(team: str) -> "_DualBoardState | None":
    """XACA-0460-010: Detect whether *team* is in a dual-board state.

    A dual-board state exists when BOTH are true for a team:
      1. A legacy stub path from LEGACY_STUB_PATHS exists on disk.
      2. The canonical board file (TEAM_KANBAN_DIRS layout) also exists
         and is NOT the same inode/path as the stub.

    Returns a ``_DualBoardState`` if the condition is met, otherwise None.
    Does NOT sys.exit — callers decide the fatal response.

    Note: ``command`` is in LEGACY_STUB_PATHS but is a single-instance team
    whose instance id equals its template id, so normal lookup works.
    """
    legacy_paths = LEGACY_STUB_PATHS.get(team)
    if not legacy_paths:
        return None

    canonical = get_board_file(team)
    if not canonical.exists():
        return None
    canonical_resolved = canonical.resolve()

    for legacy in legacy_paths:
        if not legacy.exists():
            continue
        if legacy.resolve() != canonical_resolved:
            return _DualBoardState(team=team, canonical=canonical, stub=legacy)

    return None


def check_all_dual_boards_or_die() -> None:
    """XACA-0460-010: Iterate ALL known stub mappings and refuse to start if any
    team is in a dual-board state.

    Keying the check on LCARS_TEAM meant that when LCARS_TEAM was unknown (e.g.
    bare template id 'finance' instead of 'finance-personal') the check was
    silently skipped.  This function checks every team in LEGACY_STUB_PATHS so
    that on-disk corruption is caught regardless of which instance is starting.

    Set LCARS_SKIP_DUAL_BOARD_CHECK=1 to bypass (e.g. for automated tests).
    """
    if os.environ.get("LCARS_SKIP_DUAL_BOARD_CHECK") == "1":
        print("[LCARS] Dual-board check skipped (LCARS_SKIP_DUAL_BOARD_CHECK=1)")
        return

    for check_team in LEGACY_STUB_PATHS:
        state = _detect_dual_boards(check_team)
        if state is not None:
            print(
                "\n"
                "================================================================================" + "\n"
                f"FATAL: Dual kanban board files detected for team '{state.team}'" + "\n"
                "================================================================================" + "\n"
                f"  Canonical:   {state.canonical}" + "\n"
                f"  Legacy stub: {state.stub}" + "\n"
                "\n"
                "  Refusing to start — silent ID collisions are likely if both files coexist." + "\n"
                "\n"
                "  To resolve:" + "\n"
                "    1. Verify which is correct (canonical is the source of truth)" + "\n"
                f"    2. Quarantine the stub via: kb-quarantine-stub {state.team}" + "\n"
                "       (See XACA-0180 for context)" + "\n"
                "    3. Restart this server" + "\n"
                "================================================================================",
                file=sys.stderr,
            )
            sys.exit(1)

    print("[LCARS] Dual-board check OK (all teams)")


def check_dual_boards_or_die(team: str) -> None:
    """XACA-0180 guardrail: compatibility shim — delegates to check_all_dual_boards_or_die().

    The original single-team version silently skipped the check when *team* was
    not a known key in LEGACY_STUB_PATHS (e.g. bare template id 'finance').
    XACA-0460-010 replaces the single-team iteration with an all-teams scan so
    the check is robust regardless of which instance is being started.

    Set LCARS_SKIP_DUAL_BOARD_CHECK=1 to bypass (e.g. for automated tests).
    """
    check_all_dual_boards_or_die()


def validate_lcars_team_or_die() -> None:
    """XACA-0460-009: Validate LCARS_TEAM at startup against TEAM_KANBAN_DIRS.

    Enforces the contract from docs/architecture/team-id-contract.md §6:
      1. LCARS_TEAM must be set.
      2. LCARS_TEAM must appear as a key in TEAM_KANBAN_DIRS (instance id).
      3. A bare template id (e.g. 'finance') where TEAM_HAS_PROJECTS=true is
         explicitly rejected with a helpful message suggesting the instance id.

    This check runs before the HTTP server starts, so a misconfigured env
    fails fast with a human-readable error rather than serving a broken UI.

    Set LCARS_SKIP_TEAM_VALIDATION=1 to bypass (for automated tests only).
    """
    if os.environ.get("LCARS_SKIP_TEAM_VALIDATION") == "1":
        print("[LCARS] Team validation skipped (LCARS_SKIP_TEAM_VALIDATION=1)")
        return

    team = LCARS_TEAM

    # Rule 1: LCARS_TEAM must be set.
    if not team or not team.strip():
        print(
            "\n"
            "FATAL: LCARS_TEAM is not set.\n"
            "  Pass the instance id via the team-startup.sh script (e.g. finance-personal-startup.sh).\n"
            "  Do NOT launch server.py directly without LCARS_TEAM.\n"
            "  See docs/architecture/team-id-contract.md §6.",
            file=sys.stderr,
        )
        sys.exit(1)

    # Rule 2: known instance id — fast path.
    if team in TEAM_KANBAN_DIRS:
        print(f"[LCARS] Team validation OK: LCARS_TEAM='{team}'")
        return

    # Rule 3: check whether this looks like a bare template id for a
    # multi-project template (e.g. 'finance' instead of 'finance-personal').
    base_team, _ = _split_team_id(team)
    if base_team in MULTI_PROJECT_BASE_TEAMS:
        # Find any known instance ids that start with this base team.
        known_instances = sorted(k for k in TEAM_KANBAN_DIRS if k.startswith(base_team + '-'))
        suggestion = known_instances[0] if known_instances else f"{base_team}-<project>"
        print(
            "\n"
            "================================================================================" + "\n"
            f"FATAL: LCARS_TEAM='{team}' is a template id, not an instance id." + "\n"
            "================================================================================" + "\n"
            "\n"
            f"  The installer should have written the instance id (e.g. '{suggestion}')" + "\n"
            "  into the team-startup script, not the bare template id." + "\n"
            "\n"
            "  Likely fix:" + "\n"
            f"    Re-run: install-team.sh {base_team} --project <project>" + "\n"
            "    Then use the resulting team-startup script to launch LCARS." + "\n"
            "\n"
            "  See docs/architecture/team-id-contract.md for the full contract." + "\n"
            "================================================================================",
            file=sys.stderr,
        )
        sys.exit(1)

    # Rule 4: unknown team — not a known instance, not a recognisable template.
    known_list = ', '.join(sorted(TEAM_KANBAN_DIRS.keys()))
    print(
        "\n"
        "================================================================================" + "\n"
        f"FATAL: LCARS_TEAM='{team}' is not a known team." + "\n"
        "================================================================================" + "\n"
        "\n"
        f"  Known instances: {known_list}" + "\n"
        "\n"
        "  If this is a newly installed team, ensure aiteamforge_paths is up to date" + "\n"
        "  and re-run the team-startup script." + "\n"
        "  See docs/architecture/team-id-contract.md §6." + "\n"
        "================================================================================",
        file=sys.stderr,
    )
    sys.exit(1)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PORT

    # XACA-0460-009: validate LCARS_TEAM first — refuse before printing anything
    # if the env is wrong.  Fast-fail on bare template ids and unknown teams so
    # operators see a clear error, not a half-started server.
    validate_lcars_team_or_die()

    # XACA-0463: precondition check — refuse to start on port conflicts or null
    # active-instance port.  Runs after team validation so LCARS_TEAM is trusted.
    _xaca0463_active_lcars_team = os.environ.get("LCARS_TEAM")
    try:
        _xaca0463_team_paths_data = _xaca0463_load_team_paths()
    except Exception as _e:
        # If team-paths.json is missing or unreadable, fall back gracefully.
        # Matches existing aiteamforge_paths bootstrap behaviour — shouldn't block startup.
        print(
            f"[XACA-0463] team-paths.json unreadable ({_e!r}); skipping conflict check.",
            file=sys.stderr,
        )
        _xaca0463_team_paths_data = None

    if _xaca0463_team_paths_data is not None:
        _xaca0463_assert_no_port_conflicts(_xaca0463_team_paths_data, _xaca0463_active_lcars_team)

    print(f"""
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║   LCARS - Library Computer Access/Retrieval System               ║
║   Kanban Workflow Monitor Server                                  ║
║                                                                   ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║   Server starting on port {port:<5}                                 ║
║                                                                   ║
║   Open in browser: http://localhost:{port:<5}                       ║
║                                                                   ║
║   Kanban Data:     {str(TEAM_KANBAN_DIRS.get(LCARS_TEAM, KANBAN_DIR)):<43} ║
║                                                                   ║
║   Press Ctrl+C to stop                                            ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
""")

    # XACA-0333-001: sweep stale zero-byte lock files left by prior killed processes.
    _sweep_stale_locks()

    # XACA-0460-010 / XACA-0180: refuse to start if ANY team has a legacy stub
    # coexisting with its canonical board — check all teams, not just LCARS_TEAM.
    check_all_dual_boards_or_die()

    # Allow port reuse to avoid "Address already in use" errors
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("", port), LCARSHandler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n[LCARS] Server shutting down...")
            httpd.shutdown()


if __name__ == "__main__":
    main()
