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
title, status, and priority from the kanban board items.

Usage: python3 sync_release_manifests.py [--dry-run]
"""

import json
import os
import sys
from pathlib import Path
from datetime import datetime, timezone

# Add kanban-hooks to path for shared modules (XACA-0168)
_KANBAN_HOOKS_DIR = str(Path(__file__).parent.parent / "kanban-hooks")
if _KANBAN_HOOKS_DIR not in sys.path:
    sys.path.insert(0, _KANBAN_HOOKS_DIR)

try:
    from aiteamforge_paths import get_team_kanban_dir, list_teams
    _AITEAMFORGE_PATHS_AVAILABLE = True
except ImportError:
    _AITEAMFORGE_PATHS_AVAILABLE = False

# Legacy fallback kanban directory
KANBAN_DIR = Path.home() / "dev-team" / "kanban"

# Distributed kanban directories — loaded from aiteamforge_paths (XACA-0168)
def _build_team_kanban_dirs() -> dict:
    if _AITEAMFORGE_PATHS_AVAILABLE:
        try:
            # XACA-0727: skip board-less alias teams (e.g. "mainevent") per-item.
            # A bare comprehension would let one KeyError escape to the except
            # below and collapse the WHOLE map to the hardcoded subset (dropping
            # per-machine freelance slugs). Mirrors server.py / kanban_utils.py.
            _dirs = {}
            for team in list_teams():
                try:
                    _dirs[team] = get_team_kanban_dir(team)
                except KeyError:
                    continue
            return _dirs
        except Exception:
            pass
    # Fallback: hardcoded subset (main teams used by this script)
    return {
        "academy": Path.home() / "dev-team" / "kanban",
        "ios": Path("/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban"),
        "android": Path("/Users/Shared/Development/Main Event/MainEventApp-Android/kanban"),
        "firebase": Path("/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban"),
        "command": Path("/Users/Shared/Development/Main Event/dev-team/kanban"),
        "dns": Path("/Users/Shared/Development/DNSFramework/kanban"),
    }

TEAM_KANBAN_DIRS = _build_team_kanban_dirs()

# Team configurations
TEAMS = {
    'ios': {
        'board': TEAM_KANBAN_DIRS["ios"] / "ios-board.json",
        'releases': Path("/Users/Shared/Development/Main Event/MainEventApp-iOS/DEV/dev-team/kanban/releases"),
    },
    'android': {
        'board': TEAM_KANBAN_DIRS["android"] / "android-board.json",
        'releases': Path("/Users/Shared/Development/Main Event/MainEventApp-Android/develop/dev-team/kanban/releases"),
    },
    'firebase': {
        'board': TEAM_KANBAN_DIRS["firebase"] / "firebase-board.json",
        'releases': Path("/Users/Shared/Development/Main Event/MainEventApp-Functions/develop/dev-team/kanban/releases"),
    },
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

        board_status = board_item.get('status')
        if board_status and manifest_item.get('status') != board_status:
            changes.append(f"status: {manifest_item.get('status')} -> {board_status}")
            manifest_item['status'] = board_status

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

        with open(manifest_path, 'w') as f:
            json.dump(manifest, f, indent=2)

    return len(items), updated_count

def main():
    import sys
    dry_run = '--dry-run' in sys.argv

    if dry_run:
        print("DRY RUN - No changes will be written\n")

    total_items = 0
    total_updated = 0

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
    main()
