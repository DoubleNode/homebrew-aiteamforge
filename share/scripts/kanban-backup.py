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
from typing import Optional

# Configuration
# Distributed kanban directories - each team has their own
TEAM_KANBAN_DIRS = {
    # Main Event Teams
    "academy": Path.home() / "dev-team" / "kanban",
    "ios": Path("/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban"),
    "android": Path("/Users/Shared/Development/Main Event/MainEventApp-Android/kanban"),
    "firebase": Path("/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban"),
    "command": Path("/Users/Shared/Development/Main Event/dev-team/kanban"),
    "dns": Path("/Users/Shared/Development/DNSFramework/kanban"),

    # Freelance Projects
    "freelance-doublenode-starwords": Path("/Users/Shared/Development/DoubleNode/Starwords/kanban"),
    "freelance-doublenode-appplanning": Path("/Users/Shared/Development/DoubleNode/appPlanning/kanban"),
    "freelance-doublenode-workstats": Path("/Users/Shared/Development/DoubleNode/WorkStats/kanban"),
    "freelance-doublenode-lifeboard": Path("/Users/Shared/Development/DoubleNode/LifeBoard/kanban"),

    # Legal Projects
    "legal-coparenting": Path.home() / "legal" / "coparenting" / "kanban",
}

# Centralized backup destination
BACKUP_DIR = Path.home() / "dev-team-backups" / "kanban"
STATUS_FILE = BACKUP_DIR / "backup-status.json"
HASH_FILE = BACKUP_DIR / "file-hashes.json"

# Retention settings (how many to keep)
RETENTION = {
    "hourly": 24,      # Keep last 24 hourly backups
    "daily": 7,        # Keep last 7 daily backups
    "weekly": 4,       # Keep last 4 weekly backups
    "monthly": 6,      # Keep last 6 monthly backups
}


def create_directory_backup_zip(team_name: str, source_dir: Path, dest_file: Path) -> bool:
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

    Returns:
        True if backup succeeded, False on failure
    """
    if not source_dir.exists():
        print(f"  [ERROR] {team_name}: Source directory does not exist: {source_dir}")
        return False

    # Files/patterns to exclude
    exclude_suffixes = {'.lock'}
    exclude_names = {'.DS_Store', 'firebase-debug.log'}
    exclude_patterns = {'*-debug.log'}

    def should_exclude(filepath: Path) -> bool:
        """Check if a file should be excluded from backup."""
        name = filepath.name
        # Check exact name matches
        if name in exclude_names:
            return True
        # Check suffix matches
        if filepath.suffix in exclude_suffixes:
            return True
        # Check pattern matches
        for pattern in exclude_patterns:
            if filepath.match(pattern):
                return True
        return False

    try:
        # Create destination directory if needed
        dest_file.parent.mkdir(parents=True, exist_ok=True)

        # Create the zip archive
        with zipfile.ZipFile(dest_file, 'w', zipfile.ZIP_DEFLATED) as zipf:
            files_added = 0

            # Recursively add ALL files in the kanban directory
            for item in source_dir.rglob("*"):
                if item.is_file() and not should_exclude(item):
                    # Use relative path to maintain directory structure
                    arcname = item.relative_to(source_dir)
                    zipf.write(item, str(arcname))
                    files_added += 1

        # Verify the archive was created and has content
        if dest_file.exists() and dest_file.stat().st_size > 0:
            print(f"  [ZIP] {team_name}: Created {dest_file.name} ({files_added} files)")
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


def get_file_hash(filepath: Path) -> Optional[str]:
    """Calculate SHA256 hash of a file's contents."""
    try:
        if not filepath.exists() or filepath.stat().st_size == 0:
            return None
        with open(filepath, 'rb') as f:
            return hashlib.sha256(f.read()).hexdigest()
    except Exception:
        return None


def get_directory_hash(kanban_dir: Path, team: str) -> Optional[str]:
    """
    Calculate combined SHA256 hash of ALL files that would be backed up.

    Includes: ALL files in the kanban directory recursively.
    Excludes: .lock files, debug logs, .DS_Store (same as backup).
    """
    # Same exclusion logic as create_directory_backup_zip
    exclude_suffixes = {'.lock'}
    exclude_names = {'.DS_Store', 'firebase-debug.log'}
    exclude_patterns = {'*-debug.log'}

    def should_exclude(filepath: Path) -> bool:
        """Check if a file should be excluded from hash."""
        name = filepath.name
        if name in exclude_names:
            return True
        if filepath.suffix in exclude_suffixes:
            return True
        for pattern in exclude_patterns:
            if filepath.match(pattern):
                return True
        return False

    try:
        if not kanban_dir.exists():
            return None

        # Collect ALL files to hash (same logic as create_directory_backup_zip)
        files_to_hash = []
        for item in kanban_dir.rglob("*"):
            if item.is_file() and not should_exclude(item):
                files_to_hash.append(item)

        if not files_to_hash:
            return None

        # Sort for consistent ordering
        files_to_hash.sort()

        # Compute combined hash
        combined_hash = hashlib.sha256()
        for filepath in files_to_hash:
            try:
                # Include relative path in hash (so renames are detected)
                rel_path = filepath.relative_to(kanban_dir)
                combined_hash.update(str(rel_path).encode())
                # Include file contents
                with open(filepath, 'rb') as f:
                    combined_hash.update(f.read())
            except Exception:
                continue

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


def get_board_files() -> list[Path]:
    """Get all kanban board files from all team directories."""
    board_files = []
    for team, kanban_dir in TEAM_KANBAN_DIRS.items():
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
    kanban_dir = TEAM_KANBAN_DIRS.get(team)
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

    # Calculate current hash of ALL files that will be backed up
    current_hash = get_directory_hash(kanban_dir, team)
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

    # Create zip archive of entire kanban directory
    success = create_directory_backup_zip(team, kanban_dir, backup_file)

    if success:
        stored_hashes[team] = current_hash
        result["action"] = "backed_up"
        result["message"] = f"Created {backup_file.name}"
    else:
        result["action"] = "error"
        result["message"] = f"Backup failed: zip creation failed"

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
    print(f"Source: Distributed ({len(TEAM_KANBAN_DIRS)} team directories)")
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
    if team not in TEAM_KANBAN_DIRS:
        print(f"ERROR: Unknown team '{team}'")
        print(f"Available teams: {', '.join(sorted(TEAM_KANBAN_DIRS.keys()))}")
        sys.exit(1)

    kanban_dir = TEAM_KANBAN_DIRS[team]
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
