#!/usr/bin/env python3
"""
Migration Script: jiraId -> ticketLinks

Migrates all kanban board files from legacy jiraId/jiraKey/jira fields
to the new ticketLinks array format.

Usage:
    python3 migrate_jira_to_ticketlinks.py [--dry-run] [--preserve-legacy]

Options:
    --dry-run           Show what would be changed without modifying files
    --preserve-legacy   Keep the original jiraId fields after migration
    --board BOARD       Only migrate specific board (e.g., 'ios')
"""

import json
import os
import sys
import argparse
from pathlib import Path
from datetime import datetime, timezone
from typing import Dict, Any, List, Tuple

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

try:
    from integrations.ticket_links import (
        migrate_jira_id_to_ticket_links,
        get_ticket_links
    )
except ImportError:
    # Fallback if running standalone
    def migrate_jira_id_to_ticket_links(item, default_integration_id='jira-mainevent', preserve_legacy=True):
        jira_id = item.get('jiraId') or item.get('jiraKey') or item.get('jira')
        if not jira_id:
            return item

        if 'ticketLinks' not in item:
            item['ticketLinks'] = []

        # Check if already migrated
        for link in item['ticketLinks']:
            if link.get('integrationId') == default_integration_id and link.get('ticketId') == jira_id:
                return item

        item['ticketLinks'].append({
            'integrationId': default_integration_id,
            'ticketId': jira_id,
            'ticketUrl': f"https://mainevent.atlassian.net/browse/{jira_id}",
            'linkedAt': datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        })

        if not preserve_legacy:
            item.pop('jiraId', None)
            item.pop('jiraKey', None)
            item.pop('jira', None)

        return item


# Default kanban directory
KANBAN_DIR = Path.home() / "dev-team" / "kanban"


def find_legacy_jira_fields(item: Dict[str, Any]) -> List[str]:
    """Find which legacy JIRA fields exist in an item."""
    legacy_fields = []
    if item.get('jiraId'):
        legacy_fields.append('jiraId')
    if item.get('jiraKey'):
        legacy_fields.append('jiraKey')
    if item.get('jira'):
        legacy_fields.append('jira')
    return legacy_fields


def migrate_item(
    item: Dict[str, Any],
    preserve_legacy: bool = True,
    default_integration_id: str = 'jira-mainevent'
) -> Tuple[Dict[str, Any], bool]:
    """
    Migrate a single item.

    Returns:
        Tuple of (updated_item, was_modified)
    """
    legacy_fields = find_legacy_jira_fields(item)

    if not legacy_fields:
        return item, False

    # Migrate main item
    item = migrate_jira_id_to_ticket_links(
        item,
        default_integration_id=default_integration_id,
        preserve_legacy=preserve_legacy
    )

    return item, True


def migrate_board(
    board_path: Path,
    dry_run: bool = False,
    preserve_legacy: bool = True
) -> Dict[str, Any]:
    """
    Migrate a single board file.

    Returns:
        Migration statistics
    """
    stats = {
        'board': board_path.stem,
        'items_scanned': 0,
        'items_migrated': 0,
        'subitems_migrated': 0,
        'errors': []
    }

    try:
        with open(board_path, 'r') as f:
            data = json.load(f)
    except Exception as e:
        stats['errors'].append(f"Failed to read: {e}")
        return stats

    modified = False
    backlog = data.get('backlog', [])

    for item in backlog:
        stats['items_scanned'] += 1

        # Migrate main item
        item, was_modified = migrate_item(item, preserve_legacy)
        if was_modified:
            stats['items_migrated'] += 1
            modified = True

        # Migrate subitems
        subitems = item.get('subitems', [])
        for subitem in subitems:
            subitem, sub_modified = migrate_item(subitem, preserve_legacy)
            if sub_modified:
                stats['subitems_migrated'] += 1
                modified = True

    # Write back if modified
    if modified and not dry_run:
        try:
            # Update lastUpdated
            data['lastUpdated'] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

            # Write atomically
            tmp_path = board_path.with_suffix('.json.tmp')
            with open(tmp_path, 'w') as f:
                json.dump(data, f, indent=2)
                f.flush()
                os.fsync(f.fileno())
            os.rename(tmp_path, board_path)

        except Exception as e:
            stats['errors'].append(f"Failed to write: {e}")
            # Clean up tmp file if exists
            if tmp_path.exists():
                tmp_path.unlink()

    return stats


def migrate_all_boards(
    kanban_dir: Path = KANBAN_DIR,
    dry_run: bool = False,
    preserve_legacy: bool = True,
    board_filter: str = None
) -> List[Dict[str, Any]]:
    """
    Migrate all board files in the kanban directory.

    Returns:
        List of migration statistics per board
    """
    results = []

    if not kanban_dir.exists():
        print(f"Kanban directory not found: {kanban_dir}")
        return results

    board_files = list(kanban_dir.glob("*-board.json"))

    if board_filter:
        board_files = [f for f in board_files if board_filter in f.stem]

    for board_path in sorted(board_files):
        print(f"Processing: {board_path.name}")
        stats = migrate_board(board_path, dry_run, preserve_legacy)
        results.append(stats)

    return results


def print_results(results: List[Dict[str, Any]], dry_run: bool = False):
    """Print migration results."""
    print("\n" + "=" * 60)
    print("MIGRATION RESULTS" + (" (DRY RUN)" if dry_run else ""))
    print("=" * 60)

    total_scanned = 0
    total_migrated = 0
    total_subitems = 0
    total_errors = 0

    for stats in results:
        board = stats['board']
        items_migrated = stats['items_migrated']
        subitems = stats['subitems_migrated']
        errors = len(stats['errors'])

        total_scanned += stats['items_scanned']
        total_migrated += items_migrated
        total_subitems += subitems
        total_errors += errors

        status = ""
        if items_migrated or subitems:
            status = f"Migrated: {items_migrated} items, {subitems} subitems"
        else:
            status = "No changes needed"

        if errors:
            status += f" ({errors} errors)"

        print(f"  {board:30} {status}")

        for error in stats['errors']:
            print(f"    ERROR: {error}")

    print("-" * 60)
    print(f"Total: {total_scanned} items scanned")
    print(f"       {total_migrated} items migrated")
    print(f"       {total_subitems} subitems migrated")
    if total_errors:
        print(f"       {total_errors} errors")
    print("=" * 60)


def main():
    parser = argparse.ArgumentParser(
        description='Migrate jiraId fields to ticketLinks array'
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Show what would be changed without modifying files'
    )
    parser.add_argument(
        '--preserve-legacy',
        action='store_true',
        default=True,
        help='Keep the original jiraId fields after migration (default: True)'
    )
    parser.add_argument(
        '--remove-legacy',
        action='store_true',
        help='Remove legacy jiraId fields after migration'
    )
    parser.add_argument(
        '--board',
        type=str,
        help='Only migrate specific board (e.g., "ios")'
    )
    parser.add_argument(
        '--kanban-dir',
        type=str,
        help=f'Kanban directory path (default: {KANBAN_DIR})'
    )

    args = parser.parse_args()

    # Handle preserve_legacy logic
    preserve_legacy = True
    if args.remove_legacy:
        preserve_legacy = False

    kanban_dir = Path(args.kanban_dir) if args.kanban_dir else KANBAN_DIR

    print("=" * 60)
    print("JIRA ID to ticketLinks Migration")
    print("=" * 60)
    print(f"Kanban Dir: {kanban_dir}")
    print(f"Dry Run: {args.dry_run}")
    print(f"Preserve Legacy: {preserve_legacy}")
    if args.board:
        print(f"Board Filter: {args.board}")
    print()

    results = migrate_all_boards(
        kanban_dir=kanban_dir,
        dry_run=args.dry_run,
        preserve_legacy=preserve_legacy,
        board_filter=args.board
    )

    print_results(results, args.dry_run)

    if args.dry_run:
        print("\nThis was a dry run. No files were modified.")
        print("Run without --dry-run to apply changes.")


if __name__ == '__main__':
    main()
