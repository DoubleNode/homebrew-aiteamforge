#!/usr/bin/env python3

#
#  sync_release_manifests.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Sync Release Manifests with Current Board Data

This script updates all release manifest files with the current
title and priority from the kanban board items. 'status' is
deprecated in manifest rows (XACA-0948, ITEM_STATUS_CONTRACT.md §4)
and is never written here — it is resolved live from the board.

Usage: python3 sync_release_manifests.py [--dry-run]
"""

import json
import os
import stat
import sys
import tempfile
from pathlib import Path
from datetime import datetime, timezone

# Add kanban-hooks to path for shared modules (XACA-0168)
_KANBAN_HOOKS_DIR = str(Path(__file__).parent.parent / "kanban-hooks")
if _KANBAN_HOOKS_DIR not in sys.path:
    sys.path.insert(0, _KANBAN_HOOKS_DIR)

try:
    from aiteamforge_paths import get_team_kanban_dir, list_teams, read_config_view
    _AITEAMFORGE_PATHS_AVAILABLE = True
except ImportError:
    _AITEAMFORGE_PATHS_AVAILABLE = False

# Legacy fallback kanban directory
KANBAN_DIR = Path.home() / "dev-team" / "kanban"

# Distributed kanban directories — loaded from aiteamforge_paths (XACA-0168)
def _build_team_kanban_dirs() -> dict:
    if _AITEAMFORGE_PATHS_AVAILABLE:
        try:
            # XACA-1193-005: read-only — resolve the registry once via
            # read_config_view() (never mutates/quarantines/reseeds) and pass
            # it through explicitly so list_teams()/get_team_kanban_dir() do
            # not each fall through to a mutating load_config().
            _view = read_config_view()
            # XACA-0727: skip board-less alias teams (e.g. "mainevent") per-item.
            # A bare comprehension would let one KeyError escape to the except
            # below and collapse the WHOLE map to the hardcoded subset (dropping
            # per-machine freelance slugs). Mirrors server.py / kanban_utils.py.
            _dirs = {}
            for team in list_teams(config=_view):
                try:
                    _dirs[team] = get_team_kanban_dir(team, config=_view)
                except KeyError:
                    continue
            return _dirs
        except Exception:
            pass
    # Fallback: hardcoded subset (main teams used by this script).
    # Main Event teams (ios/android/firebase/command) are intentionally absent:
    # Main Event content does not belong in fleet code (XACA-1799).
    return {
        "academy": Path.home() / "dev-team" / "kanban",
        "spacedock": Path.home() / ".aiteamforge" / "spacedock" / "kanban",
        "dns": Path("/Users/Shared/Development/DNSFramework/kanban"),
    }

TEAM_KANBAN_DIRS = _build_team_kanban_dirs()

# Team configurations. Built only from teams actually present in the registry
# so a host lacking one cannot KeyError at import (XACA-1799).
TEAMS = {}
if "spacedock" in TEAM_KANBAN_DIRS:
    TEAMS["spacedock"] = {
        'board': TEAM_KANBAN_DIRS["spacedock"] / "spacedock-board.json",
        'releases': TEAM_KANBAN_DIRS["spacedock"] / "releases",
    }

def load_board(board_path):
    """Load kanban board and index items by ID"""
    if not board_path.exists():
        print(f"  WARNING: Board not found: {board_path}")
        return {}

    with open(board_path, 'r') as f:
        data = json.load(f)

    items_by_id = {}
    for item in data.get('backlog', []):
        item_id = item.get('id')
        if item_id:
            items_by_id[item_id] = item

    return items_by_id

def sync_manifest(manifest_path, items_by_id, dry_run=False):
    """Sync a single manifest file with current board data"""
    if not manifest_path.exists():
        return 0, 0

    with open(manifest_path, 'r') as f:
        manifest = json.load(f)

    items = manifest.get('items', [])
    updated_count = 0

    for manifest_item in items:
        item_id = manifest_item.get('itemId')
        if not item_id:
            continue

        board_item = items_by_id.get(item_id)
        if not board_item:
            print(f"    WARNING: Item {item_id} not found in board")
            continue

        # Check for changes - only update if board has a valid value
        changes = []

        board_title = board_item.get('title')
        if board_title and manifest_item.get('title') != board_title:
            old_title = manifest_item.get('title', '')[:30]
            new_title = board_title[:30]
            changes.append(f"title: '{old_title}...' -> '{new_title}...'")
            manifest_item['title'] = board_title

        # XACA-0948: 'status' is deprecated in manifest.items[] rows
        # (ITEM_STATUS_CONTRACT.md §4) — this was a THIRD, undocumented
        # resolution rule (raw-with-no-default, guarded by `if board_status`
        # so an unrecorded board item left the stale manifest value in
        # place). A manifest row records ASSIGNMENT only; status is
        # resolved live from the board on every read, never persisted here.

        board_priority = board_item.get('priority')
        if board_priority and manifest_item.get('priority') != board_priority:
            changes.append(f"priority: {manifest_item.get('priority')} -> {board_priority}")
            manifest_item['priority'] = board_priority

        if changes:
            manifest_item['lastSynced'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
            updated_count += 1
            print(f"    {item_id}: {', '.join(changes)}")

    if updated_count > 0 and not dry_run:
        manifest['items'] = items
        manifest['updatedAt'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

        _atomic_write_json(manifest_path, manifest)

    return len(items), updated_count


def _atomic_write_json(path, doc):
    """Temp file in the SAME directory + fsync + os.replace (XACA-1799).

    Mirrors lcars-ui/server.py's manifest write: a reader (or an interrupted
    run) sees the old file or the new one, never a truncated one. The temp
    file is removed on any failure. No cross-process lock: LCARS guards
    manifests with an in-process RLock, so a file lock here would not
    coordinate with it -- atomic replace is the guarantee both sides share.
    """
    try:
        mode = stat.S_IMODE(os.stat(path).st_mode)
    except OSError:
        mode = 0o644
    fd, tmp = tempfile.mkstemp(prefix='.manifest.json.', suffix='.tmp', dir=str(Path(path).parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(doc, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

def main():
    import sys
    dry_run = '--dry-run' in sys.argv

    if dry_run:
        print("DRY RUN - No changes will be written\n")

    total_items = 0
    total_updated = 0

    # A host without spacedock has nothing to sync -- a no-op, not a failure
    # (test_xaca1193_007 pins exit 0 here). Say so loudly instead of printing
    # an empty summary that reads like a successful sync.
    if not TEAMS:
        print("NOTICE: no syncable teams found (spacedock is not in this host's "
              "team registry); nothing to sync.", file=sys.stderr)
        return 0

    for team_name, config in TEAMS.items():
        print(f"\n{'='*60}")
        print(f"Team: {team_name.upper()}")
        print(f"{'='*60}")

        # Load board
        items_by_id = load_board(config['board'])
        if not items_by_id:
            print(f"  Skipping - no board data")
            continue

        print(f"  Board items loaded: {len(items_by_id)}")

        # Find and sync all release manifests
        releases_dir = config['releases']
        if not releases_dir.exists():
            print(f"  No releases directory")
            continue

        for release_dir in sorted(releases_dir.iterdir()):
            if not release_dir.is_dir():
                continue

            manifest_path = release_dir / "manifest.json"
            release_id = release_dir.name

            print(f"\n  Release: {release_id}")

            item_count, updated = sync_manifest(manifest_path, items_by_id, dry_run)
            total_items += item_count
            total_updated += updated

            if updated == 0:
                print(f"    No changes needed ({item_count} items)")
            else:
                action = "Would update" if dry_run else "Updated"
                print(f"    {action} {updated}/{item_count} items")

    print(f"\n{'='*60}")
    print(f"SUMMARY")
    print(f"{'='*60}")
    print(f"Total items checked: {total_items}")
    print(f"Total items {'needing update' if dry_run else 'updated'}: {total_updated}")

    if dry_run and total_updated > 0:
        print(f"\nRun without --dry-run to apply changes")

if __name__ == '__main__':
    sys.exit(main() or 0)
