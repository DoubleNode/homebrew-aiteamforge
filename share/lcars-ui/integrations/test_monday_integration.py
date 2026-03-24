#!/usr/bin/env python3
"""
Manual Integration Test for Monday.com Provider

This script tests the MondayProvider against a real Monday.com account.
Requires MONDAY_API_TOKEN environment variable to be set.

Usage:
    export MONDAY_API_TOKEN="your-api-token-here"
    python3 test_monday_integration.py

To get a Monday.com API token:
1. Go to Monday.com → Profile Picture → Admin → API
2. Generate a personal API token
"""

import os
import sys
from pathlib import Path

# Add parent directory for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from integrations.provider import IntegrationConfig
from integrations.monday_provider import MondayProvider


def create_test_provider():
    """Create a Monday provider for testing."""
    config = IntegrationConfig(
        id='monday-test',
        type='monday',
        name='Monday.com Test',
        base_url='https://api.monday.com/v2',
        browse_url='https://view.monday.com/pulse/{ticketId}',
        ticket_pattern=r'^(MON-)?[0-9]+$',
        auth_config={
            'type': 'bearer',
            'tokenEnvVar': 'MONDAY_API_TOKEN'
        }
    )
    return MondayProvider(config)


def test_connection(provider):
    """Test connection to Monday.com."""
    print("\n" + "=" * 60)
    print("TEST: Connection Test")
    print("=" * 60)

    result = provider.test_connection()
    print(f"Success: {result.success}")
    print(f"Message: {result.message}")
    if result.details:
        print(f"Details: {result.details}")

    return result.success


def test_get_boards(provider):
    """Test fetching boards."""
    print("\n" + "=" * 60)
    print("TEST: Get Boards")
    print("=" * 60)

    try:
        boards = provider.get_boards(limit=5)
        print(f"Found {len(boards)} boards:")
        for board in boards:
            print(f"  - [{board.get('id')}] {board.get('name')} ({board.get('board_kind', 'unknown')})")
        return boards
    except Exception as e:
        print(f"Error: {e}")
        return []


def test_search(provider, query="test"):
    """Test searching for items."""
    print("\n" + "=" * 60)
    print(f"TEST: Search for '{query}'")
    print("=" * 60)

    result = provider.search(query, max_results=5)

    if result.error:
        print(f"Error: {result.error}")
        return

    print(f"Found {len(result.tickets)} items:")
    for ticket in result.tickets:
        print(f"  - [{ticket.ticket_id}] {ticket.summary} (Status: {ticket.status})")
        print(f"    URL: {ticket.url}")


def test_verify(provider, item_id):
    """Test verifying an item exists."""
    print("\n" + "=" * 60)
    print(f"TEST: Verify Item '{item_id}'")
    print("=" * 60)

    result = provider.verify(item_id)

    print(f"Valid: {result.valid}")
    print(f"Exists: {result.exists}")
    if result.summary:
        print(f"Summary: {result.summary}")
    if result.status:
        print(f"Status: {result.status}")
    if result.url:
        print(f"URL: {result.url}")
    if result.error:
        print(f"Error: {result.error}")
    if result.warning:
        print(f"Warning: {result.warning}")


def test_status_detection(provider, board_id):
    """Test status column detection."""
    print("\n" + "=" * 60)
    print(f"TEST: Detect Status Columns (Board {board_id})")
    print("=" * 60)

    try:
        status_columns = provider.detect_status_columns(board_id)
        print(f"Found {len(status_columns)} status columns:")
        for col in status_columns:
            print(f"  - {col['title']} (id: {col['id']})")
            print(f"    Labels: {col['labels']}")
    except Exception as e:
        print(f"Error: {e}")


def main():
    """Run all tests."""
    print("=" * 60)
    print("Monday.com Integration Test")
    print("=" * 60)

    # Check for API token
    if not os.environ.get('MONDAY_API_TOKEN'):
        print("\nError: MONDAY_API_TOKEN environment variable not set.")
        print("\nTo get a token:")
        print("1. Go to Monday.com → Profile Picture → Admin → API")
        print("2. Generate a personal API token")
        print("\nThen run:")
        print("  export MONDAY_API_TOKEN='your-token-here'")
        print("  python3 test_monday_integration.py")
        sys.exit(1)

    # Create provider
    provider = create_test_provider()
    print(f"\nProvider: {provider.name}")
    print(f"API URL: {provider._api_url}")
    print(f"Has credentials: {provider.has_credentials()}")

    # Run tests
    if not test_connection(provider):
        print("\n❌ Connection test failed. Aborting.")
        sys.exit(1)

    print("\n✓ Connection successful!")

    # Get boards
    boards = test_get_boards(provider)

    # Test search
    test_search(provider, "task")

    # If we have boards, test status detection
    if boards:
        first_board = boards[0]
        board_id = int(first_board.get('id'))
        test_status_detection(provider, board_id)

        # Try to find an item to verify
        items = provider.search("", max_results=1)
        if items.tickets:
            test_verify(provider, items.tickets[0].ticket_id)

    print("\n" + "=" * 60)
    print("Integration tests complete!")
    print("=" * 60)


if __name__ == '__main__':
    main()
