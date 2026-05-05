#!/usr/bin/env python3
"""
Kanban Board Backup System
==========================

A comprehensive backup system for kanban board JSON files with:
- Delta detection (only backup when content changes)
- Auto-restore (detect and restore from zero-byte/corrupt files)
- Tiered retention (recent backups kept longer, old ones pruned)
- Status reporting for LCARS UI integration

Usage:
    python3 kanban-backup.py [--backup | --restore <team> | --status | --prune]

    --backup    Run backup cycle (default)
    --restore   Restore a specific team's board from backup
    --status    Show backup status for all boards
    --prune     Run retention pruning only

Retention Policy:
    - Hourly:  Keep backups from the last 24 hours
    - Daily:   Keep one backup per day for 7 days
    - Weekly:  Keep one backup per week for 4 weeks
    - Monthly: Keep one backup per month for 6 months

Completeness Invariants:
    These invariants enforce data integrity across the backup pipeline. Future
    modifications must preserve them.

    1. Single source-of-truth snapshot
       Per backup run, per team, the source directory is walked exactly once by
       snapshot_source_dir(). The resulting DirSnapshot is the SOLE input to
       both hashing and zipping. Any future code path that needs to know "what
       files are in this backup" must consume the snapshot, never re-walk.

    2. Hash and zip derived from same snapshot
       get_directory_hash(snapshot) and create_directory_backup_zip(snapshot)
       accept the identical snapshot. Result: stored hash and archive contents
       cannot diverge for that run. Eliminates the TOCTOU window that existed
       between two independent rglob calls.

    3. No silent partial backups
       Every successful zip is verified post-write by _verify_zip_integrity()
       against the snapshot for file count AND top-level directory manifest.
       Mismatch → run FAILS (not silent success). A missing subdirectory is
       immediately caught before the backup is considered complete.

    4. Failure is loud and forensic
       Integrity failure (per kanban-backup.py main loop):
       - Bad zip renamed to ~/aiteamforge-backups/_failed/<team>_<name>.FAILED
       - Previous-known-good hash preserved in stored_hashes[team]
       - status["boards"][team]["lastIntegrityFailure"] populated with detail
       - [INTEGRITY-FAIL] logged to stderr for LCARS alert pickup

    5. Cross-run regressions surfaced
       kanban-backup-health.py check_cross_run_regressions() compares latest
       2–3 zips per team. Subdirectory disappearance = always ERROR. File-count
       drops > 10% OR > 50 files = WARNING; > 25% = ERROR. Catches source-dir
       content loss (the XACA-0276 origin incident).

    6. Structured per-run audit trail
       Each successful per-team backup writes one JSON line to backup.log:
       - run_start (timestamp, teams_total, force flag)
       - team_backup_ok (file_count, uncompressed_bytes, compressed_bytes,
         top_level_dirs, zip_filename)
       - run_end (totals)
       Enables future trend analysis and post-incident forensics.

Author: Reno's Engineering Lab
"""

import argparse
import hashlib
import json
import os
import shutil
import sys
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import NamedTuple, Optional

# ---------------------------------------------------------------------------
# Shared path config — XACA-0168-007
# Import team directories and exclusion rules from the canonical shared module.
# ---------------------------------------------------------------------------
try:
    # kanban-hooks/ must be on sys.path; add it relative to this file if needed.
    _hooks_dir = Path(__file__).parent / "kanban-hooks"
    if str(_hooks_dir) not in sys.path:
        sys.path.insert(0, str(_hooks_dir))
    from aiteamforge_paths import (
        list_teams,
        get_team_kanban_dir,
        EXPORT_EXCLUSION_SUFFIXES,
        EXPORT_EXCLUSION_NAMES,
        EXPORT_EXCLUSION_PATTERNS,
        is_excluded_from_export,
    )
    _USE_SHARED_PATHS = True
except ImportError:
    _USE_SHARED_PATHS = False
    # Fallback: hardcoded dirs retained for resilience when module is absent.
    # Remove this block once all installations have kanban-hooks/ in place.
    def list_teams():  # type: ignore[misc]
        return list(_FALLBACK_TEAM_DIRS.keys())

    def get_team_kanban_dir(team):  # type: ignore[misc]
        d = _FALLBACK_TEAM_DIRS.get(team)
        if d is None:
            raise KeyError(f"Team '{team}' not found in fallback dirs")
        return d

    EXPORT_EXCLUSION_SUFFIXES = frozenset({".lock"})
    EXPORT_EXCLUSION_NAMES = frozenset({".DS_Store", "firebase-debug.log"})
    EXPORT_EXCLUSION_PATTERNS = ("*-debug.log",)

    def is_excluded_from_export(filepath):  # type: ignore[misc]
        name = filepath.name
        if name in EXPORT_EXCLUSION_NAMES:
            return True
        if filepath.suffix in EXPORT_EXCLUSION_SUFFIXES:
            return True
        for pattern in EXPORT_EXCLUSION_PATTERNS:
            if filepath.match(pattern):
                return True
        return False

    _FALLBACK_TEAM_DIRS = {
        "academy": Path.home() / "dev-team" / "kanban",
        "ios": Path("/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban"),
        "android": Path("/Users/Shared/Development/Main Event/MainEventApp-Android/kanban"),
        "firebase": Path("/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban"),
        "command": Path("/Users/Shared/Development/Main Event/dev-team/kanban"),
        "dns": Path("/Users/Shared/Development/DNSFramework/kanban"),
        "freelance-doublenode-starwords": Path("/Users/Shared/Development/DoubleNode/Starwords/kanban"),
        "freelance-doublenode-appplanning": Path("/Users/Shared/Development/DoubleNode/appPlanning/kanban"),
        "freelance-doublenode-workstats": Path("/Users/Shared/Development/DoubleNode/WorkStats/kanban"),
        "freelance-doublenode-lifeboard": Path("/Users/Shared/Development/DoubleNode/LifeBoard/kanban"),
        "legal-coparenting": Path.home() / "legal" / "coparenting" / "kanban",
    }

# Centralized backup destination
BACKUP_DIR = Path.home() / "aiteamforge-backups" / "kanban"
FAILED_BACKUP_DIR = Path.home() / "aiteamforge-backups" / "_failed"
STATUS_FILE = BACKUP_DIR / "backup-status.json"
HASH_FILE = BACKUP_DIR / "file-hashes.json"
LOG_PATH = BACKUP_DIR / "backup.log"

# Retention settings (how many to keep)
RETENTION = {
    "hourly": 24,      # Keep last 24 hourly backups
    "daily": 7,        # Keep last 7 daily backups
    "weekly": 4,       # Keep last 4 weekly backups
    "monthly": 6,      # Keep last 6 monthly backups
}


class DirSnapshot(NamedTuple):
    """Immutable snapshot of a source directory's file list.

    Resolved once per backup run and shared between hashing and zipping so
    both operations see the exact same file set (avoids TOCTOU between the
    two independent rglob calls that previously existed).
    """
    files: tuple  # tuple[Path, ...] — sorted, exclusions already applied. Tuple (not list) so .append() can't silently mutate the snapshot.
    top_level_dirs: frozenset  # first path component of each file relative to source_dir


def snapshot_source_dir(source_dir: Path) -> DirSnapshot:
    """Walk source_dir exactly once and return a stable snapshot.

    Single rglob to avoid TOCTOU between hash and zip.  All exclusion rules
    are applied here; callers must not filter the snapshot further.
    """
    files = []
    for item in source_dir.rglob("*"):
        if item.is_file() and not is_excluded_from_export(item):
            files.append(item)
    files.sort()

    top_level_dirs: frozenset = frozenset(
        item.relative_to(source_dir).parts[0]
        for item in files
        if len(item.relative_to(source_dir).parts) > 1
    )
    return DirSnapshot(files=tuple(files), top_level_dirs=top_level_dirs)


def create_directory_backup_zip(team_name: str, source_dir: Path, dest_file: Path, snapshot: DirSnapshot) -> bool:
    """
    Creates a zip archive of the ENTIRE kanban directory recursively.

    Archives EVERYTHING in the kanban directory:
    - {team}-board.json (the board file)
    - All files in the root directory
    - ALL subdirectories and their contents recursively
      (releases/, releases-archive/, epics/, and any future directories)

    Excludes only:
    - *.lock files (temporary lock files)
    - *-debug.log files (debug logs)
    - .DS_Store files (macOS metadata)

    Args:
        team_name: Name of the team (used for logging)
        source_dir: Path to the kanban directory to backup
        dest_file: Path where the zip archive should be created
        snapshot: Pre-resolved file list (must be the same snapshot used for hashing)

    Returns:
        True if backup succeeded, False on failure
    """
    if not source_dir.exists():
        print(f"  [ERROR] {team_name}: Source directory does not exist: {source_dir}")
        return False

    try:
        # Create destination directory if needed
        dest_file.parent.mkdir(parents=True, exist_ok=True)

        # Iterate the pre-resolved snapshot — no second rglob
        with zipfile.ZipFile(dest_file, 'w', zipfile.ZIP_DEFLATED) as zipf:
            for item in snapshot.files:
                arcname = item.relative_to(source_dir)
                zipf.write(item, str(arcname))

        if dest_file.exists() and dest_file.stat().st_size > 0:
            print(f"  [ZIP] {team_name}: Created {dest_file.name} ({len(snapshot.files)} files)")
            return True
        else:
            print(f"  [ERROR] {team_name}: Archive created but is empty or invalid")
            return False

    except PermissionError as e:
        print(f"  [ERROR] {team_name}: Permission denied - {e}")
        return False
    except Exception as e:
        print(f"  [ERROR] {team_name}: Failed to create zip archive - {e}")
        return False


def _verify_zip_integrity(
    team_name: str, zip_path: Path, source_dir: Path, snapshot: DirSnapshot
) -> tuple:
    """Verify that a freshly-written zip matches the pre-zip snapshot exactly.

    Checks file count and top-level directory manifest.  zf.testzip() is NOT
    used here — it only catches CRC corruption; we need completeness guarantees.

    Returns:
        (ok: bool, error_detail: str)  — error_detail is "" when ok is True.
    """
    try:
        with zipfile.ZipFile(zip_path, 'r') as zf:
            zip_names = zf.namelist()
    except Exception as e:
        return False, f"could not open zip for verification: {e}"

    expected_count = len(snapshot.files)
    actual_count = len(zip_names)

    if actual_count != expected_count:
        # Derive which top-level dirs are missing from the zip
        zip_top_dirs: frozenset = frozenset(
            n.split("/")[0] for n in zip_names if "/" in n
        )
        missing_dirs = snapshot.top_level_dirs - zip_top_dirs
        detail = (
            f"file count mismatch: expected {expected_count}, got {actual_count}; "
            f"missing top-level dirs: {sorted(missing_dirs) if missing_dirs else '(root files only)'}"
        )
        return False, detail

    # Count match — spot-check top-level directory coverage
    zip_top_dirs = frozenset(n.split("/")[0] for n in zip_names if "/" in n)
    missing_dirs = snapshot.top_level_dirs - zip_top_dirs
    if missing_dirs:
        detail = (
            f"top-level dir mismatch: expected {sorted(snapshot.top_level_dirs)}, "
            f"zip has {sorted(zip_top_dirs)}, missing: {sorted(missing_dirs)}"
        )
        return False, detail

    return True, ""


def get_file_hash(filepath: Path) -> Optional[str]:
    """Calculate SHA256 hash of a file's contents."""
    try:
        if not filepath.exists() or filepath.stat().st_size == 0:
            return None
        with open(filepath, 'rb') as f:
            return hashlib.sha256(f.read()).hexdigest()
    except Exception:
        return None


def get_directory_hash(kanban_dir: Path, team: str, snapshot: DirSnapshot) -> Optional[str]:
    """
    Calculate combined SHA256 hash of ALL files in snapshot.

    Accepts the pre-resolved snapshot so it hashes exactly the same file set
    that will be zipped — no independent rglob.
    """
    try:
        if not kanban_dir.exists() or not snapshot.files:
            return None

        combined_hash = hashlib.sha256()
        skipped = 0
        for filepath in snapshot.files:
            try:
                # Include relative path in hash (so renames are detected)
                rel_path = filepath.relative_to(kanban_dir)
                combined_hash.update(str(rel_path).encode())
                with open(filepath, 'rb') as f:
                    combined_hash.update(f.read())
            except Exception:
                skipped += 1
                continue

        if skipped:
            # Hash is degraded — caller can correlate with zip integrity check
            print(f"[HASH-DEGRADED] team={team} skipped={skipped}/{len(snapshot.files)} unreadable files", file=sys.stderr)

        return combined_hash.hexdigest()
    except Exception:
        return None


def is_valid_json(filepath: Path) -> bool:
    """Check if a file contains valid JSON."""
    try:
        if not filepath.exists() or filepath.stat().st_size == 0:
            return False
        with open(filepath, 'r') as f:
            json.load(f)
        return True
    except Exception:
        return False


def _get_team_kanban_dirs() -> dict:
    """Build a team -> kanban_dir mapping from the shared path module."""
    result = {}
    for team in list_teams():
        try:
            d = get_team_kanban_dir(team)
            result[team] = d
        except KeyError:
            pass
    return result


def get_board_files() -> list[Path]:
    """Get all kanban board files from all team directories."""
    board_files = []
    for team, kanban_dir in _get_team_kanban_dirs().items():
        if kanban_dir.exists():
            board_file = kanban_dir / f"{team}-board.json"
            if board_file.exists():
                board_files.append(board_file)
    return sorted(board_files)


def load_hashes() -> dict:
    """Load stored file hashes."""
    if HASH_FILE.exists():
        try:
            with open(HASH_FILE, 'r') as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def save_hashes(hashes: dict):
    """Save file hashes."""
    HASH_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(HASH_FILE, 'w') as f:
        json.dump(hashes, f, indent=2)


def load_status() -> dict:
    """Load backup status."""
    if STATUS_FILE.exists():
        try:
            with open(STATUS_FILE, 'r') as f:
                return json.load(f)
        except Exception:
            pass
    return {
        "lastRun": None,
        "lastRunStatus": "unknown",
        "boards": {},
        "totalBackups": 0,
        "storageUsed": "0 B"
    }


def save_status(status: dict):
    """Save backup status."""
    STATUS_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(STATUS_FILE, 'w') as f:
        json.dump(status, f, indent=2)


def format_bytes(size: int) -> str:
    """Format bytes to human-readable string."""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size < 1024:
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TB"


_LOG_MAX_BYTES = 10 * 1024 * 1024  # 10 MB — sized for ~17 months of 15-min runs at typical payload size


def _append_log_line(payload: dict) -> None:
    """Append one JSON line to backup.log (machine-parseable structured log).

    Each line is a self-contained JSON object — no embedded newlines.
    Failures to write are silenced so a log I/O error never aborts a backup.
    Rotates to backup.log.1 (single generation, overwriting any previous .1)
    when size exceeds _LOG_MAX_BYTES so disk doesn't grow unbounded.
    """
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        if LOG_PATH.exists() and LOG_PATH.stat().st_size > _LOG_MAX_BYTES:
            LOG_PATH.replace(LOG_PATH.with_suffix(LOG_PATH.suffix + ".1"))
        line = json.dumps(payload, sort_keys=True)
        with open(LOG_PATH, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


def get_backup_dir_for_board(team: str) -> Path:
    """Get the backup directory for a specific board."""
    return BACKUP_DIR / team


def get_backup_filename(timestamp: datetime) -> str:
    """Generate backup filename from timestamp."""
    return f"backup_{timestamp.strftime('%Y%m%d_%H%M%S')}.zip"


def parse_backup_timestamp(filename: str) -> Optional[datetime]:
    """Parse timestamp from backup filename (supports both .json and .zip)."""
    try:
        # Format: backup_YYYYMMDD_HHMMSS.json or backup_YYYYMMDD_HHMMSS.zip
        ts_str = filename.replace("backup_", "").replace(".json", "").replace(".zip", "")
        return datetime.strptime(ts_str, "%Y%m%d_%H%M%S").replace(tzinfo=timezone.utc)
    except Exception:
        return None


def restore_from_backup(team: str, backup_file: Path, target_board_file: Path) -> bool:
    """
    Restore a board from a backup file (handles both .zip and .json).

    Args:
        team: Team name
        backup_file: Path to the backup file (.zip or .json)
        target_board_file: Path where the board JSON should be restored

    Returns:
        True if restore succeeded, False otherwise
    """
    try:
        # Ensure target directory exists
        target_board_file.parent.mkdir(parents=True, exist_ok=True)

        if backup_file.suffix == '.zip':
            # Extract zip archive to the kanban directory
            with zipfile.ZipFile(backup_file, 'r') as zipf:
                zipf.extractall(target_board_file.parent)
            return True
        else:
            # Old .json backup - just copy it
            shutil.copy2(backup_file, target_board_file)
            return True
    except Exception:
        return False


def get_latest_backup(team: str) -> Optional[Path]:
    """Get the most recent backup for a team (prefers .zip over .json)."""
    backup_dir = get_backup_dir_for_board(team)
    if not backup_dir.exists():
        return None

    # Collect both .zip and .json backups
    zip_backups = list(backup_dir.glob("backup_*.zip"))
    json_backups = list(backup_dir.glob("backup_*.json"))

    # Prefer .zip files over .json files
    all_backups = sorted(zip_backups, reverse=True) + sorted(json_backups, reverse=True)

    for backup in all_backups:
        if backup.suffix == '.zip':
            # For zip files, verify they exist, have content, and are valid
            if backup.exists() and backup.stat().st_size > 0:
                try:
                    # Quick validation - ensure zip can be opened
                    with zipfile.ZipFile(backup, 'r') as zf:
                        _ = zf.namelist()  # Verify archive is readable
                    return backup
                except Exception:
                    continue  # Skip corrupted zip
        else:
            # For old JSON backups, validate JSON
            if is_valid_json(backup):
                return backup

    return None


def backup_board(board_file: Path, stored_hashes: dict, status: dict, force: bool = False) -> dict:
    """
    Backup a single board file if changed or if last backup was > 24 hours ago.

    Returns a result dict with status info.
    """
    team = board_file.stem.replace("-board", "")
    try:
        kanban_dir = get_team_kanban_dir(team)
    except KeyError:
        kanban_dir = None
    result = {
        "team": team,
        "action": "none",
        "message": "",
        "timestamp": datetime.now(timezone.utc).isoformat()
    }

    # Check team directory exists
    if not kanban_dir:
        result["action"] = "error"
        result["message"] = f"Unknown team directory mapping for {team}"
        return result

    # Check if file exists and is valid
    if not board_file.exists():
        result["action"] = "error"
        result["message"] = "Board file does not exist"
        return result

    file_size = board_file.stat().st_size

    # Zero-byte detection - auto-restore!
    if file_size == 0:
        result["action"] = "auto-restore"
        latest = get_latest_backup(team)
        if latest:
            if restore_from_backup(team, latest, board_file):
                result["message"] = f"Restored from {latest.name} (zero-byte detected)"
                print(f"  [RESTORE] {team}: Zero-byte file detected, restored from {latest.name}")
            else:
                result["action"] = "error"
                result["message"] = f"Failed to restore from {latest.name}"
                print(f"  [ERROR] {team}: Failed to restore from backup")
        else:
            result["action"] = "error"
            result["message"] = "Zero-byte file with no backup available!"
            print(f"  [CRITICAL] {team}: Zero-byte file with NO backup available!")
        return result

    # Validate JSON
    if not is_valid_json(board_file):
        result["action"] = "auto-restore"
        latest = get_latest_backup(team)
        if latest:
            if restore_from_backup(team, latest, board_file):
                result["message"] = f"Restored from {latest.name} (invalid JSON detected)"
                print(f"  [RESTORE] {team}: Invalid JSON detected, restored from {latest.name}")
            else:
                result["action"] = "error"
                result["message"] = f"Failed to restore from {latest.name}"
                print(f"  [ERROR] {team}: Failed to restore from backup")
        else:
            result["action"] = "error"
            result["message"] = "Invalid JSON with no backup available!"
            print(f"  [CRITICAL] {team}: Invalid JSON with NO backup available!")
        return result

    # Single rglob to avoid TOCTOU between hash and zip (XACA-0276-002)
    snapshot = snapshot_source_dir(kanban_dir)

    # Calculate current hash using the snapshot — same file set that will be zipped
    current_hash = get_directory_hash(kanban_dir, team, snapshot)
    stored_hash = stored_hashes.get(team)

    # Check if backup needed (delta detection + 24-hour daily backup requirement)
    needs_daily_backup = False
    board_status = status.get("boards", {}).get(team, {})
    last_backup_str = board_status.get("lastBackup")
    if last_backup_str:
        try:
            last_backup_time = datetime.fromisoformat(last_backup_str.replace('Z', '+00:00'))
            hours_since_backup = (datetime.now(timezone.utc) - last_backup_time).total_seconds() / 3600
            if hours_since_backup >= 24:
                needs_daily_backup = True
                print(f"  [DAILY] {team}: Last backup was {hours_since_backup:.1f}h ago, forcing daily backup")
        except Exception:
            needs_daily_backup = True  # If we can't parse, force backup
    else:
        needs_daily_backup = True  # No previous backup recorded

    if not force and not needs_daily_backup and current_hash and current_hash == stored_hash:
        result["action"] = "skipped"
        result["message"] = "No changes detected"
        return result

    # Perform backup (full directory zip)
    backup_dir = get_backup_dir_for_board(team)
    backup_dir.mkdir(parents=True, exist_ok=True)

    now = datetime.now(timezone.utc)
    backup_file = backup_dir / get_backup_filename(now)

    # Create zip archive using the same snapshot used for hashing
    success = create_directory_backup_zip(team, kanban_dir, backup_file, snapshot)

    if not success:
        result["action"] = "error"
        result["message"] = "Backup failed: zip creation failed"
        return result

    # Post-zip integrity check: zip contents must exactly match the snapshot (XACA-0276-003)
    integrity_ok, integrity_error = _verify_zip_integrity(team, backup_file, kanban_dir, snapshot)

    if not integrity_ok:
        # --- XACA-0276-004: Loud failure mode ---
        # Quarantine the bad zip (keep for forensics, do NOT delete)
        FAILED_BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        failed_path = FAILED_BACKUP_DIR / f"{team}_{backup_file.name}.FAILED"
        try:
            backup_file.rename(failed_path)
        except Exception:
            failed_path = backup_file  # rename failed; leave in place

        # Do NOT update stored_hashes — preserve last-known-good baseline so
        # the next run retries rather than treating this failure as canonical.
        failure_ts = datetime.now(timezone.utc).isoformat()
        error_msg = f"Integrity failure: {integrity_error}; quarantined to {failed_path}"

        # Structured error line that LCARS log-tail can pick up
        print(
            f"  [INTEGRITY-FAIL] {team}: {integrity_error} "
            f"| zip quarantined: {failed_path}",
            file=sys.stderr,
        )
        print(f"  [INTEGRITY-FAIL] {team}: stored hash NOT updated — next run will retry")

        # Record in status so LCARS can surface it
        if "boards" not in status:
            status["boards"] = {}
        board_entry = status["boards"].get(team, {})
        board_entry["lastIntegrityFailure"] = {
            "timestamp": failure_ts,
            "detail": integrity_error,
            "quarantinedZip": str(failed_path),
            "expectedCount": len(snapshot.files),
        }
        status["boards"][team] = board_entry

        result["action"] = "error"
        result["message"] = error_msg
        return result

    # Integrity passed — safe to advance the stored hash
    stored_hashes[team] = current_hash
    result["action"] = "backed_up"
    result["message"] = f"Created {backup_file.name}"

    # --- XACA-0276-006: structured per-team success log line ---
    uncompressed_bytes = sum(
        item.stat().st_size for item in snapshot.files if item.exists()
    )
    compressed_bytes = backup_file.stat().st_size if backup_file.exists() else 0
    _append_log_line({
        "event": "team_backup_ok",
        "ts": datetime.now(timezone.utc).isoformat(),
        "team": team,
        "file_count": len(snapshot.files),
        "uncompressed_bytes": uncompressed_bytes,
        "compressed_bytes": compressed_bytes,
        "top_level_dirs": sorted(snapshot.top_level_dirs),
        "zip_filename": backup_file.name,
    })

    return result


def prune_backups(team: str) -> dict:
    """
    Apply tiered retention policy to backups for a team.

    Returns pruning statistics.
    """
    backup_dir = get_backup_dir_for_board(team)
    if not backup_dir.exists():
        return {"pruned": 0, "kept": 0}

    now = datetime.now(timezone.utc)
    backups = []

    # Collect all backups with their timestamps (both .json and .zip)
    for backup_file in backup_dir.glob("backup_*"):
        if backup_file.suffix in ['.json', '.zip']:
            ts = parse_backup_timestamp(backup_file.name)
            if ts:
                backups.append((ts, backup_file))

    if not backups:
        return {"pruned": 0, "kept": 0}

    # Sort by timestamp (newest first)
    backups.sort(key=lambda x: x[0], reverse=True)

    # Determine which backups to keep
    keep = set()

    # Always keep the most recent backup
    keep.add(backups[0][1])

    # Hourly: Keep last 24 hours
    hourly_cutoff = now - timedelta(hours=RETENTION["hourly"])
    for ts, path in backups:
        if ts >= hourly_cutoff:
            keep.add(path)

    # Daily: Keep one per day for last 7 days
    daily_kept = {}
    daily_cutoff = now - timedelta(days=RETENTION["daily"])
    for ts, path in backups:
        if ts >= daily_cutoff:
            day_key = ts.strftime("%Y-%m-%d")
            if day_key not in daily_kept:
                daily_kept[day_key] = path
                keep.add(path)

    # Weekly: Keep one per week for last 4 weeks
    weekly_kept = {}
    weekly_cutoff = now - timedelta(weeks=RETENTION["weekly"])
    for ts, path in backups:
        if ts >= weekly_cutoff:
            # Week number (year + week)
            week_key = ts.strftime("%Y-W%W")
            if week_key not in weekly_kept:
                weekly_kept[week_key] = path
                keep.add(path)

    # Monthly: Keep one per month for last 6 months
    monthly_kept = {}
    monthly_cutoff = now - timedelta(days=RETENTION["monthly"] * 30)
    for ts, path in backups:
        if ts >= monthly_cutoff:
            month_key = ts.strftime("%Y-%m")
            if month_key not in monthly_kept:
                monthly_kept[month_key] = path
                keep.add(path)

    # Delete backups not in keep set
    pruned = 0
    for ts, path in backups:
        if path not in keep:
            try:
                path.unlink()
                pruned += 1
            except Exception as e:
                print(f"  [WARNING] Failed to prune {path.name}: {e}")

    return {"pruned": pruned, "kept": len(keep)}


def calculate_storage() -> tuple[int, int]:
    """Calculate total storage used and backup count."""
    if not BACKUP_DIR.exists():
        return 0, 0

    total_size = 0
    total_count = 0

    for team_dir in BACKUP_DIR.iterdir():
        if team_dir.is_dir():
            # Count both .json and .zip backups
            for backup_file in team_dir.glob("backup_*"):
                if backup_file.suffix in ['.json', '.zip']:
                    total_size += backup_file.stat().st_size
                    total_count += 1

    return total_size, total_count


def run_backup(force: bool = False):
    """Run a full backup cycle."""
    print(f"\n{'='*60}")
    print("KANBAN BACKUP SYSTEM")
    print(f"{'='*60}")
    print(f"Time: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
    print(f"Source: Distributed ({len(_get_team_kanban_dirs())} team directories)")
    print(f"Destination: {BACKUP_DIR}")
    print(f"{'='*60}\n")

    BACKUP_DIR.mkdir(parents=True, exist_ok=True)

    board_files = get_board_files()
    if not board_files:
        print("No board files found!")
        return

    print(f"Found {len(board_files)} board(s) to process\n")

    stored_hashes = load_hashes()
    status = load_status()

    backed_up = 0
    skipped = 0
    restored = 0
    errors = 0

    # --- XACA-0276-006: run-start structured log line ---
    run_start_ts = datetime.now(timezone.utc).isoformat()
    _append_log_line({
        "event": "run_start",
        "ts": run_start_ts,
        "teams_total": len(board_files),
        "force": force,
    })

    print("Processing boards:")
    print("-" * 40)

    for board_file in board_files:
        result = backup_board(board_file, stored_hashes, status, force)
        team = result["team"]

        # Update board status
        status["boards"][team] = {
            "lastBackup": result["timestamp"] if result["action"] == "backed_up" else status["boards"].get(team, {}).get("lastBackup"),
            "lastCheck": result["timestamp"],
            "lastAction": result["action"],
            "lastMessage": result["message"],
            "latestBackup": str(get_latest_backup(team)) if get_latest_backup(team) else None
        }

        if result["action"] == "backed_up":
            backed_up += 1
        elif result["action"] == "skipped":
            skipped += 1
        elif result["action"] == "auto-restore":
            restored += 1
        elif result["action"] == "error":
            errors += 1

    # Save updated hashes
    save_hashes(stored_hashes)

    print("\nRunning retention pruning:")
    print("-" * 40)

    total_pruned = 0
    for board_file in board_files:
        team = board_file.stem.replace("-board", "")
        prune_result = prune_backups(team)
        if prune_result["pruned"] > 0:
            print(f"  [PRUNE] {team}: Removed {prune_result['pruned']} old backups, kept {prune_result['kept']}")
            total_pruned += prune_result["pruned"]

    if total_pruned == 0:
        print("  No backups needed pruning")

    # Calculate storage
    storage_bytes, backup_count = calculate_storage()

    # Update status
    status["lastRun"] = datetime.now(timezone.utc).isoformat()
    status["lastRunStatus"] = "success" if errors == 0 else "errors"
    status["totalBackups"] = backup_count
    status["storageUsed"] = format_bytes(storage_bytes)
    status["lastRunStats"] = {
        "backedUp": backed_up,
        "skipped": skipped,
        "restored": restored,
        "errors": errors,
        "pruned": total_pruned
    }

    save_status(status)

    # --- XACA-0276-006: run-end structured log line ---
    _append_log_line({
        "event": "run_end",
        "ts": datetime.now(timezone.utc).isoformat(),
        "run_start_ts": run_start_ts,
        "teams_backed_up": backed_up,
        "teams_skipped": skipped,
        "teams_restored": restored,
        "teams_errors": errors,
        "teams_pruned": total_pruned,
        "run_status": "success" if errors == 0 else "errors",
    })

    print(f"\n{'='*60}")
    print("SUMMARY")
    print(f"{'='*60}")
    print(f"  Backed up:  {backed_up}")
    print(f"  Skipped:    {skipped} (no changes)")
    print(f"  Restored:   {restored}")
    print(f"  Errors:     {errors}")
    print(f"  Pruned:     {total_pruned}")
    print(f"  Total:      {backup_count} backups ({format_bytes(storage_bytes)})")
    print(f"{'='*60}\n")


def run_restore(team: str):
    """Restore a specific team's board from backup."""
    print(f"\nRestoring {team} board...")

    # Get board file location from distributed directory mapping
    try:
        kanban_dir = get_team_kanban_dir(team)
    except KeyError:
        available = ", ".join(sorted(list_teams()))
        print(f"ERROR: Unknown team '{team}'")
        print(f"Available teams: {available}")
        sys.exit(1)
    board_file = kanban_dir / f"{team}-board.json"
    latest = get_latest_backup(team)

    if not latest:
        print(f"ERROR: No backup found for {team}")
        sys.exit(1)

    print(f"Latest backup: {latest}")
    print(f"Target: {board_file}")

    # Confirm
    response = input("\nProceed with restore? [y/N]: ")
    if response.lower() != 'y':
        print("Restore cancelled")
        return

    if restore_from_backup(team, latest, board_file):
        if latest.suffix == '.zip':
            print(f"SUCCESS: Restored {team} from {latest.name} (extracted zip)")
        else:
            print(f"SUCCESS: Restored {team} from {latest.name}")
    else:
        print(f"ERROR: Failed to restore from {latest.name}")
        sys.exit(1)


def show_status():
    """Display backup status for all boards."""
    status = load_status()

    print(f"\n{'='*60}")
    print("KANBAN BACKUP STATUS")
    print(f"{'='*60}")
    print(f"Last Run: {status.get('lastRun', 'Never')}")
    print(f"Status: {status.get('lastRunStatus', 'Unknown')}")
    print(f"Total Backups: {status.get('totalBackups', 0)}")
    print(f"Storage Used: {status.get('storageUsed', '0 B')}")

    if status.get('lastRunStats'):
        stats = status['lastRunStats']
        print(f"\nLast Run Stats:")
        print(f"  Backed up: {stats.get('backedUp', 0)}")
        print(f"  Skipped: {stats.get('skipped', 0)}")
        print(f"  Restored: {stats.get('restored', 0)}")
        print(f"  Errors: {stats.get('errors', 0)}")

    print(f"\n{'='*60}")
    print("BOARD STATUS")
    print(f"{'='*60}")

    for team, info in sorted(status.get('boards', {}).items()):
        print(f"\n{team}:")
        print(f"  Last Backup: {info.get('lastBackup', 'Never')}")
        print(f"  Last Check: {info.get('lastCheck', 'Never')}")
        print(f"  Last Action: {info.get('lastAction', 'Unknown')}")
        if info.get('lastMessage'):
            print(f"  Message: {info['lastMessage']}")

    print()


def main():
    parser = argparse.ArgumentParser(
        description="Kanban Board Backup System",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )

    parser.add_argument(
        '--backup', '-b',
        action='store_true',
        help='Run backup cycle (default action)'
    )
    parser.add_argument(
        '--restore', '-r',
        metavar='TEAM',
        help='Restore a specific team board from backup'
    )
    parser.add_argument(
        '--status', '-s',
        action='store_true',
        help='Show backup status'
    )
    parser.add_argument(
        '--prune', '-p',
        action='store_true',
        help='Run retention pruning only'
    )
    parser.add_argument(
        '--force', '-f',
        action='store_true',
        help='Force backup even if no changes detected'
    )

    args = parser.parse_args()

    # Default to backup if no action specified
    if not any([args.backup, args.restore, args.status, args.prune]):
        args.backup = True

    if args.status:
        show_status()
    elif args.restore:
        run_restore(args.restore)
    elif args.prune:
        print("Running retention pruning...")
        for board_file in get_board_files():
            team = board_file.stem.replace("-board", "")
            result = prune_backups(team)
            print(f"  {team}: Pruned {result['pruned']}, Kept {result['kept']}")
    elif args.backup:
        run_backup(force=args.force)


if __name__ == "__main__":
    main()
