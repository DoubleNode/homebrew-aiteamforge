#!/usr/bin/env python3
"""
Import Issue CLI - Preview and import external issues into kanban.

Usage:
    python import_issue.py --id ME-123 --preview
    python import_issue.py --id ME-123 --execute --team Academy
    python import_issue.py --id gh:owner/repo#123 --preview

Supports JIRA, GitHub, and Monday.com issues.
"""

import argparse
import fcntl
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Any, Optional, List

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from integrations import get_manager, ImportedIssue, FetchResult


# ANSI color codes for terminal output
class Colors:
    RESET = '\033[0m'
    BOLD = '\033[1m'
    DIM = '\033[2m'

    # Colors
    RED = '\033[91m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    MAGENTA = '\033[95m'
    CYAN = '\033[96m'
    WHITE = '\033[97m'

    # LCARS-inspired
    GOLD = '\033[38;5;214m'
    ORANGE = '\033[38;5;208m'
    PEACH = '\033[38;5;217m'


def print_header(title: str) -> None:
    """Print a formatted header."""
    line = "═" * 79
    print(f"\n{Colors.GOLD}{line}{Colors.RESET}")
    print(f"{Colors.GOLD} {title}{Colors.RESET}")
    print(f"{Colors.GOLD}{line}{Colors.RESET}")


def print_section(title: str) -> None:
    """Print a section header."""
    line = "─" * 79
    print(f"\n{Colors.CYAN} {line}{Colors.RESET}")
    print(f"{Colors.CYAN} {title}{Colors.RESET}")
    print(f"{Colors.CYAN} {line}{Colors.RESET}")


def print_field(label: str, value: str, indent: int = 1) -> None:
    """Print a labeled field."""
    spaces = "  " * indent
    print(f"{spaces}{Colors.DIM}{label}:{Colors.RESET}  {value}")


def format_status(status: str) -> str:
    """Format status with color."""
    status_lower = status.lower()
    if status_lower in ('done', 'closed', 'complete', 'completed'):
        return f"{Colors.GREEN}[{status}]{Colors.RESET}"
    elif status_lower in ('in progress', 'in_progress', 'active', 'working'):
        return f"{Colors.YELLOW}[{status}]{Colors.RESET}"
    elif status_lower in ('blocked', 'on hold'):
        return f"{Colors.RED}[{status}]{Colors.RESET}"
    else:
        return f"{Colors.DIM}[{status}]{Colors.RESET}"


def display_preview(
    issue: ImportedIssue,
    integration_name: str,
    integration_id: str,
    team: str,
    next_item_id: str
) -> None:
    """
    Display the import preview in terminal.

    Args:
        issue: The fetched issue data
        integration_name: Display name of the integration
        integration_id: ID of the integration
        team: Target team for import
        next_item_id: The ID that will be assigned to the kanban item
    """
    print_header(f"IMPORT PREVIEW - {issue.ticket_id}")

    # Source info
    print(f"\n{Colors.DIM} Source:{Colors.RESET}     {integration_name} ({integration_id})")
    print(f"{Colors.DIM} Ticket:{Colors.RESET}     {issue.ticket_id}")
    print(f"{Colors.DIM} URL:{Colors.RESET}        {issue.url}")

    # Issue details
    print_section("ISSUE DETAILS")
    print()
    print_field("Title", issue.title)
    print_field("Type", issue.issue_type or "Unknown")
    print_field("Status", format_status(issue.status) if issue.status else "Unknown")
    print_field("Priority", issue.priority or "Medium")

    if issue.assignee:
        print_field("Assignee", issue.assignee)

    if issue.labels:
        print_field("Labels", ", ".join(issue.labels))

    # Description (truncated)
    if issue.description:
        print()
        print(f"{Colors.DIM} Description:{Colors.RESET}")
        desc_lines = issue.description.strip().split('\n')
        for i, line in enumerate(desc_lines[:5]):  # Max 5 lines
            print(f"   {line[:76]}")
        if len(desc_lines) > 5:
            print(f"   {Colors.DIM}... ({len(desc_lines) - 5} more lines){Colors.RESET}")

    # Children/Subtasks
    if issue.children:
        print_section(f"SUBTASKS ({len(issue.children)})")
        print()
        for i, child in enumerate(issue.children, 1):
            status_str = format_status(child.status) if child.status else ""
            ticket_ref = f" → {child.ticket_id}" if child.ticket_id and not child.ticket_id.startswith('task-') else ""
            print(f"   {i}. {child.title:50} {status_str}{ticket_ref}")

    # What will be created
    print_section("WILL CREATE")
    print()
    print(f"   {Colors.BOLD}Kanban Item:{Colors.RESET}  {next_item_id}")
    print(f"   {Colors.BOLD}Team:{Colors.RESET}         {team}")
    print(f"   {Colors.BOLD}Subitems:{Colors.RESET}     {len(issue.children)} (from subtasks)")
    print(f"   {Colors.BOLD}Ticket Links:{Colors.RESET} {issue.ticket_id} → parent", end="")
    if issue.children:
        child_links = sum(1 for c in issue.children if c.ticket_id and not c.ticket_id.startswith('task-'))
        if child_links:
            print(f", {child_links} → subitems")
        else:
            print()
    else:
        print()

    print(f"\n{Colors.GOLD}{'═' * 79}{Colors.RESET}")


def map_status_to_kanban(external_status: str) -> str:
    """
    Map external issue status to kanban status.

    Args:
        external_status: Status from external system

    Returns:
        Kanban status (todo, in_progress, done, blocked)
    """
    status_lower = external_status.lower()

    # Done statuses
    if status_lower in ('done', 'closed', 'complete', 'completed', 'resolved', 'fixed'):
        return 'done'

    # In progress statuses
    if status_lower in ('in progress', 'in_progress', 'active', 'working', 'in development', 'open'):
        return 'in_progress'

    # Blocked statuses
    if status_lower in ('blocked', 'on hold', 'waiting', 'pending'):
        return 'blocked'

    # Default to todo
    return 'todo'


def map_priority_to_kanban(external_priority: str) -> str:
    """
    Map external priority to kanban priority.

    Args:
        external_priority: Priority from external system

    Returns:
        Kanban priority (critical, high, medium, low)
    """
    priority_lower = external_priority.lower()

    if priority_lower in ('highest', 'critical', 'blocker', 'p0'):
        return 'critical'
    elif priority_lower in ('high', 'major', 'p1'):
        return 'high'
    elif priority_lower in ('low', 'minor', 'trivial', 'p3', 'p4'):
        return 'low'
    else:
        return 'medium'


def get_next_item_id(team: str, board_path: Path, board_data: Optional[Dict[str, Any]] = None) -> str:
    """
    Generate the next kanban item ID for a team.

    Args:
        team: Team identifier
        board_path: Path to the board JSON file
        board_data: Optional pre-loaded board data (to avoid race conditions when
                    caller already holds a lock and has loaded the data)

    Returns:
        Next item ID (e.g., XACA-0035)
    """
    # Load board data if not provided (needed to read series field)
    if board_data is None and board_path.exists():
        try:
            with open(board_path, 'r') as f:
                board_data = json.load(f)
        except Exception:
            board_data = None

    # Priority 1: Use the 'series' field from board configuration (single source of truth)
    if board_data and 'series' in board_data:
        prefix = board_data['series']
    else:
        # Priority 2: Fall back to hardcoded team prefixes for backwards compatibility
        prefixes = {
            'academy': 'XACA',
            'ios': 'XIOS',
            'android': 'XAND',
            'firebase': 'XFIR',
            'freelance': 'XFRE',
            'mainevent': 'XME',
            'command': 'XCMD',
            'dns': 'XDNS',
            'legal-coparenting': 'XLCP',
        }
        prefix = prefixes.get(team.lower(), 'XGEN')

    # Find highest existing ID
    max_num = 0

    if board_data:
        for item in board_data.get('backlog', []):
            item_id = item.get('id', '')
            if item_id.startswith(prefix + '-'):
                try:
                    num = int(item_id.split('-')[1])
                    max_num = max(max_num, num)
                except (IndexError, ValueError):
                    pass

    return f"{prefix}-{max_num + 1:04d}"


def create_kanban_item(
    issue: ImportedIssue,
    team: str,
    integration_id: str,
    board_path: Path,
    board_data: Optional[Dict[str, Any]] = None
) -> Dict[str, Any]:
    """
    Create a kanban item from an imported issue.

    Args:
        issue: The imported issue data
        team: Target team
        integration_id: ID of the source integration
        board_path: Path to the board JSON
        board_data: Optional pre-loaded board data (to avoid race conditions when
                    caller already holds a lock and has loaded the data)

    Returns:
        Created kanban item dictionary
    """
    timestamp = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
    item_id = get_next_item_id(team, board_path, board_data)

    # Create the item
    item = {
        'id': item_id,
        'title': issue.title,
        'description': issue.description,
        'status': map_status_to_kanban(issue.status),
        'priority': map_priority_to_kanban(issue.priority),
        'createdAt': timestamp,
        'updatedAt': timestamp,
        'importedFrom': {
            'integration': integration_id,
            'ticketId': issue.ticket_id,
            'importedAt': timestamp
        },
        'ticketLinks': [
            {
                'integrationId': integration_id,
                'ticketId': issue.ticket_id,
                'ticketUrl': issue.url,
                'summary': issue.title,
                'status': issue.status,
                'linkedAt': timestamp,
                'linkedBy': 'kb-import'
            }
        ],
        'subitems': []
    }

    # Add tags from labels
    if issue.labels:
        item['tags'] = issue.labels[:5]  # Max 5 tags

    # Create subitems
    for i, child in enumerate(issue.children, 1):
        subitem_id = f"{item_id}-{i:03d}"

        subitem = {
            'id': subitem_id,
            'title': child.title,
            'status': map_status_to_kanban(child.status),
            'createdAt': timestamp,
            'updatedAt': timestamp,
        }

        # Add ticket link if child has a real ticket ID
        if child.ticket_id and not child.ticket_id.startswith('task-'):
            subitem['ticketLinks'] = [
                {
                    'integrationId': integration_id,
                    'ticketId': child.ticket_id,
                    'ticketUrl': child.url or '',
                    'summary': child.title,
                    'status': child.status,
                    'linkedAt': timestamp,
                    'linkedBy': 'kb-import'
                }
            ]

        item['subitems'].append(subitem)

    return item


def save_to_board(item: Dict[str, Any], board_path: Path) -> bool:
    """
    Save a kanban item to the board JSON file with atomic locking.

    This function uses file locking to prevent race conditions when multiple
    processes attempt to save items concurrently. The entire read-modify-write
    operation is protected by an exclusive lock.

    Args:
        item: The kanban item to save
        board_path: Path to the board JSON

    Returns:
        True if successful
    """
    lock_file = board_path.with_suffix('.json.lock')
    tmp_file = board_path.with_suffix('.json.tmp')

    try:
        # Ensure directory exists
        board_path.parent.mkdir(parents=True, exist_ok=True)

        # Create lock file if it doesn't exist
        lock_file.touch(exist_ok=True)

        with open(lock_file, 'r+') as lock:
            # Acquire exclusive lock for the entire read-modify-write operation
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                # Load existing board (inside the lock)
                if board_path.exists():
                    with open(board_path, 'r') as f:
                        board_data = json.load(f)
                else:
                    board_data = {
                        'version': '1.0',
                        'backlog': [],
                        'lastUpdated': datetime.now(timezone.utc).isoformat()
                    }

                # Add item to backlog
                board_data['backlog'].append(item)
                board_data['lastUpdated'] = datetime.now(timezone.utc).isoformat()

                # Write to temporary file first
                with open(tmp_file, 'w') as f:
                    json.dump(board_data, f, indent=2)
                    f.flush()
                    os.fsync(f.fileno())  # Ensure data is on disk

                # Atomic rename (prevents partial writes)
                os.rename(tmp_file, board_path)

                return True
            finally:
                # Always release the lock
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    except Exception as e:
        # Clean up temp file if it exists
        try:
            if tmp_file.exists():
                tmp_file.unlink()
        except Exception:
            pass
        print(f"{Colors.RED}Error saving to board: {e}{Colors.RESET}")
        return False


def create_and_save_item_atomically(
    issue: ImportedIssue,
    team: str,
    integration_id: str,
    board_path: Path
) -> Optional[Dict[str, Any]]:
    """
    Atomically create and save a kanban item with proper locking.

    This function combines item creation and board saving into a single atomic
    operation to prevent race conditions. The ID is generated inside the lock
    using the current board state.

    Args:
        issue: The imported issue data
        team: Target team
        integration_id: ID of the source integration
        board_path: Path to the board JSON

    Returns:
        The created item if successful, None otherwise
    """
    lock_file = board_path.with_suffix('.json.lock')
    tmp_file = board_path.with_suffix('.json.tmp')

    try:
        # Ensure directory exists
        board_path.parent.mkdir(parents=True, exist_ok=True)

        # Create lock file if it doesn't exist
        lock_file.touch(exist_ok=True)

        with open(lock_file, 'r+') as lock:
            # Acquire exclusive lock for the entire operation
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                # Load existing board (inside the lock)
                if board_path.exists():
                    with open(board_path, 'r') as f:
                        board_data = json.load(f)
                else:
                    board_data = {
                        'version': '1.0',
                        'backlog': [],
                        'lastUpdated': datetime.now(timezone.utc).isoformat()
                    }

                # Create item with the loaded board data (ID generated inside lock)
                item = create_kanban_item(issue, team, integration_id, board_path, board_data)

                # Add item to backlog
                board_data['backlog'].append(item)
                board_data['lastUpdated'] = datetime.now(timezone.utc).isoformat()

                # Write to temporary file first
                with open(tmp_file, 'w') as f:
                    json.dump(board_data, f, indent=2)
                    f.flush()
                    os.fsync(f.fileno())  # Ensure data is on disk

                # Atomic rename (prevents partial writes)
                os.rename(tmp_file, board_path)

                return item
            finally:
                # Always release the lock
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    except Exception as e:
        # Clean up temp file if it exists
        try:
            if tmp_file.exists():
                tmp_file.unlink()
        except Exception:
            pass
        print(f"{Colors.RED}Error creating item: {e}{Colors.RESET}")
        return None


def display_success(item: Dict[str, Any], integration_id: str) -> None:
    """Display success message after import."""
    print_header("IMPORT COMPLETE")

    print(f"\n {Colors.GREEN}Created:{Colors.RESET} [{item['id']}] {item['title']}")
    print(f" {Colors.GREEN}Subitems:{Colors.RESET} {len(item.get('subitems', []))} created")

    if item.get('subitems'):
        print()
        for subitem in item['subitems']:
            status_icon = "✓" if subitem['status'] == 'done' else "○"
            ticket_ref = ""
            if subitem.get('ticketLinks'):
                ticket_ref = f" → {subitem['ticketLinks'][0]['ticketId']}"
            print(f"   {status_icon} {subitem['id']}: {subitem['title'][:40]}{ticket_ref}")

    # Ticket links summary
    print(f"\n {Colors.CYAN}Ticket Links:{Colors.RESET}")
    print(f"   • {item['id']} ↔ {item['ticketLinks'][0]['ticketId']}")
    for subitem in item.get('subitems', []):
        if subitem.get('ticketLinks'):
            print(f"   • {subitem['id']} ↔ {subitem['ticketLinks'][0]['ticketId']}")

    # Next steps
    print(f"\n {Colors.DIM}Next steps:{Colors.RESET}")
    print(f"   kb-run {item['id']}     # Start working on this item")
    print(f"   kb-show {item['id']}    # View item details")

    print(f"\n{Colors.GOLD}{'═' * 79}{Colors.RESET}\n")


def get_board_path(team: str) -> Path:
    """Get the path to a team's board file."""
    # Teams with non-standard kanban locations (outside ~/aiteamforge/kanban/)
    _team_board_paths = {
        "legal-coparenting": Path.home() / "legal" / "coparenting" / "kanban" / "legal-coparenting-board.json",
        "medical-general": Path.home() / "medical" / "general" / "kanban" / "medical-general-board.json",
        "finance-personal": Path.home() / "finance" / "personal" / "kanban" / "finance-personal-board.json",
    }

    # Check team-specific paths first
    if team in _team_board_paths:
        return _team_board_paths[team]

    dev_team = Path.home() / 'aiteamforge'

    # Try different board file patterns
    patterns = [
        dev_team / 'kanban' / f'{team.lower()}-board.json',
        dev_team / 'kanban' / f'{team}-board.json',
    ]

    for path in patterns:
        if path.exists():
            return path

    # Return default path even if doesn't exist
    return patterns[0]


def main():
    parser = argparse.ArgumentParser(
        description='Import external issues into LCARS kanban'
    )
    parser.add_argument(
        '--id', '-i',
        required=True,
        help='External ticket ID (e.g., ME-123, gh:owner/repo#123)'
    )
    parser.add_argument(
        '--integration',
        help='Integration ID to use (auto-detected if not specified)'
    )
    parser.add_argument(
        '--team', '-t',
        default=os.environ.get('LCARS_TEAM', 'academy'),
        help='Target team for import (default: from LCARS_TEAM env or academy)'
    )
    parser.add_argument(
        '--preview', '-p',
        action='store_true',
        help='Show preview only, do not import'
    )
    parser.add_argument(
        '--execute', '-e',
        action='store_true',
        help='Execute the import (skip confirmation)'
    )
    parser.add_argument(
        '--no-children',
        action='store_true',
        help='Do not import subtasks/children'
    )
    parser.add_argument(
        '--json',
        action='store_true',
        help='Output as JSON (for programmatic use)'
    )

    args = parser.parse_args()

    # Get the integration manager
    manager = get_manager()

    # Detect or get the provider
    if args.integration:
        provider = manager.get_provider(args.integration)
        if not provider:
            print(f"{Colors.RED}Error: Integration not found: {args.integration}{Colors.RESET}")
            sys.exit(1)
    else:
        provider = manager.detect_provider(args.id)
        if not provider:
            print(f"{Colors.RED}Error: Could not detect integration for: {args.id}{Colors.RESET}")
            print(f"{Colors.DIM}Tip: Use --integration to specify explicitly{Colors.RESET}")
            sys.exit(1)

    # Fetch the issue
    include_children = not args.no_children
    result = manager.fetch_issue(args.id, provider.id, include_children)

    if not result.success:
        if args.json:
            print(json.dumps({'success': False, 'error': result.error}))
        else:
            print(f"{Colors.RED}Error: {result.error}{Colors.RESET}")
        sys.exit(1)

    issue = result.issue
    board_path = get_board_path(args.team)
    next_id = get_next_item_id(args.team, board_path)

    # JSON output mode
    if args.json:
        output = {
            'success': True,
            'issue': issue.to_dict(),
            'integration': {
                'id': provider.id,
                'name': provider.name,
                'type': provider.provider_type
            },
            'target': {
                'team': args.team,
                'itemId': next_id,
                'boardPath': str(board_path)
            }
        }
        print(json.dumps(output, indent=2))
        sys.exit(0)

    # Display preview
    display_preview(issue, provider.name, provider.id, args.team, next_id)

    # Warnings
    if result.warnings:
        print(f"\n{Colors.YELLOW} Warnings:{Colors.RESET}")
        for warning in result.warnings:
            print(f"   • {warning}")

    # Preview only mode
    if args.preview:
        print(f"\n{Colors.DIM} Preview only - no changes made{Colors.RESET}\n")
        sys.exit(0)

    # Confirm import
    if not args.execute:
        try:
            response = input(f"\n {Colors.BOLD}Proceed with import? [Y/n]{Colors.RESET} ").strip().lower()
            if response in ('n', 'no'):
                print(f"\n{Colors.DIM} Import cancelled{Colors.RESET}\n")
                sys.exit(0)
        except (KeyboardInterrupt, EOFError):
            print(f"\n\n{Colors.DIM} Import cancelled{Colors.RESET}\n")
            sys.exit(0)

    # Create and save the item atomically (prevents race conditions)
    item = create_and_save_item_atomically(issue, args.team, provider.id, board_path)

    if item:
        display_success(item, provider.id)
    else:
        print(f"{Colors.RED}Error: Failed to save to board{Colors.RESET}")
        sys.exit(1)


if __name__ == '__main__':
    main()
