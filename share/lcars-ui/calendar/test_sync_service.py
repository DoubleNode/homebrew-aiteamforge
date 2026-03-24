#!/usr/bin/env python3
"""
Test script for CalendarSyncService inbound sync functionality.

Tests:
- Fetching events from mock provider
- Updating items from calendar events
- Handling deleted events
- Conflict detection and resolution
- External event storage
"""

import sys
from datetime import datetime, timezone, timedelta

# Use relative imports since we're in the calendar package
from sync_service import CalendarSyncService
from mock_provider import MockCalendarProvider
from provider import CalendarEvent, CalendarCredentials


def test_inbound_sync_basic():
    """Test basic inbound sync with updated event."""
    print("\n=== Test: Basic Inbound Sync ===")

    # Setup team with one item
    team = {
        'team': 'academy',
        'teamName': 'ACADEMY',
        'calendarConfig': {
            'provider': 'mock',
            'enabled': True,
            'calendarId': 'primary',
            'lastSyncAt': (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat(),
            'syncOptions': {
                'conflictResolution': 'last-write-wins'
            }
        },
        'items': [
            {
                'id': 'XACA-0001',
                'title': 'Test Item',
                'dueDate': '2026-02-15',
                'status': 'in-progress',
                'calendarSync': {
                    'externalEventId': 'event-001',
                    'provider': 'mock',
                    'lastSyncedAt': (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat(),
                    'syncStatus': 'synced',
                    'lastModifiedLocal': (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()
                }
            }
        ],
        'epics': []
    }

    # Create mock provider with updated event
    sync_service = CalendarSyncService()

    # Mock provider returns updated event
    provider = MockCalendarProvider()
    credentials = CalendarCredentials(provider='mock', raw_data={})
    provider.authenticate(credentials)

    # Manually add a modified event to mock provider
    updated_event = CalendarEvent(
        event_id='event-001',
        kanban_id='XACA-0001',
        title='Test Item - Updated',
        due_date='2026-02-16',  # Changed date
        last_modified=datetime.now(timezone.utc) - timedelta(minutes=30),
        deleted=False
    )
    provider._events['event-001'] = updated_event

    # Register provider in sync service
    team_config = team['calendarConfig']
    team_config['credentials'] = {}
    team_config['team'] = 'academy'
    cache_key = f"{team['team']}:mock:primary"
    sync_service._providers[cache_key] = provider

    # Run inbound sync
    result = sync_service.sync_inbound(team)

    # Verify results
    assert result['success'], f"Sync failed: {result.get('error')}"
    assert result['stats']['pulled'] == 1, f"Expected 1 item pulled, got {result['stats']['pulled']}"
    assert result['stats']['conflicts'] == 0, f"Unexpected conflicts: {result['stats']['conflicts']}"

    # Verify item was updated
    item = team['items'][0]
    assert item['dueDate'] == '2026-02-16', f"Due date not updated: {item['dueDate']}"

    print("✅ Basic inbound sync passed")


def test_inbound_sync_deleted_event():
    """Test inbound sync with deleted event."""
    print("\n=== Test: Deleted Event Sync ===")

    team = {
        'team': 'academy',
        'calendarConfig': {
            'provider': 'mock',
            'enabled': True,
            'calendarId': 'primary',
            'lastSyncAt': (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat(),
            'syncOptions': {
                'conflictResolution': 'last-write-wins'
            },
            'credentials': {},
            'team': 'academy'
        },
        'items': [
            {
                'id': 'XACA-0002',
                'title': 'Item to Delete',
                'dueDate': '2026-03-01',
                'calendarSync': {
                    'externalEventId': 'event-002',
                    'provider': 'mock',
                    'lastSyncedAt': (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat(),
                    'syncStatus': 'synced',
                    'lastModifiedLocal': (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()
                }
            }
        ],
        'epics': []
    }

    sync_service = CalendarSyncService()

    # Mock provider with deleted event
    provider = MockCalendarProvider()
    credentials = CalendarCredentials(provider='mock', raw_data={})
    provider.authenticate(credentials)

    deleted_event = CalendarEvent(
        event_id='event-002',
        kanban_id='XACA-0002',
        title='Item to Delete',
        due_date='2026-03-01',
        last_modified=datetime.now(timezone.utc) - timedelta(minutes=30),
        deleted=True  # Event was deleted
    )
    provider._events['event-002'] = deleted_event

    cache_key = f"{team['team']}:mock:primary"
    sync_service._providers[cache_key] = provider

    # Run sync
    result = sync_service.sync_inbound(team)

    # Verify
    assert result['success'], f"Sync failed: {result.get('error')}"

    item = team['items'][0]
    assert item['dueDate'] is None, f"Due date should be cleared, got: {item['dueDate']}"
    assert item['calendarSync']['syncStatus'] == 'synced', "Sync status should be 'synced'"

    print("✅ Deleted event sync passed")


def test_inbound_sync_conflict():
    """Test conflict detection and resolution."""
    print("\n=== Test: Conflict Detection ===")

    team = {
        'team': 'academy',
        'calendarConfig': {
            'provider': 'mock',
            'enabled': True,
            'calendarId': 'primary',
            'lastSyncAt': (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat(),
            'syncOptions': {
                'conflictResolution': 'last-write-wins'
            },
            'credentials': {},
            'team': 'academy'
        },
        'items': [
            {
                'id': 'XACA-0003',
                'title': 'Conflicted Item',
                'dueDate': '2026-04-01',  # Local change
                'calendarSync': {
                    'externalEventId': 'event-003',
                    'provider': 'mock',
                    'lastSyncedAt': (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat(),
                    'syncStatus': 'synced',
                    'lastModifiedLocal': (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()  # Changed locally
                }
            }
        ],
        'epics': []
    }

    sync_service = CalendarSyncService()

    provider = MockCalendarProvider()
    credentials = CalendarCredentials(provider='mock', raw_data={})
    provider.authenticate(credentials)

    # External also changed
    conflicting_event = CalendarEvent(
        event_id='event-003',
        kanban_id='XACA-0003',
        title='Conflicted Item - External Change',
        due_date='2026-04-05',  # External change (newer)
        last_modified=datetime.now(timezone.utc) - timedelta(minutes=30),
        deleted=False
    )
    provider._events['event-003'] = conflicting_event

    cache_key = f"{team['team']}:mock:primary"
    sync_service._providers[cache_key] = provider

    # Run sync
    result = sync_service.sync_inbound(team)

    # Verify conflict was detected and resolved
    assert result['success'], f"Sync failed: {result.get('error')}"
    assert result['stats']['conflicts'] == 1, f"Expected 1 conflict, got {result['stats']['conflicts']}"

    item = team['items'][0]
    # With last-write-wins, external should win (it's newer)
    assert item['dueDate'] == '2026-04-05', f"Expected external date to win, got: {item['dueDate']}"

    print("✅ Conflict detection passed")


def test_inbound_sync_external_events():
    """Test handling of external-only events."""
    print("\n=== Test: External Events ===")

    team = {
        'team': 'academy',
        'calendarConfig': {
            'provider': 'mock',
            'enabled': True,
            'calendarId': 'primary',
            'lastSyncAt': (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat(),
            'syncOptions': {
                'conflictResolution': 'last-write-wins'
            },
            'credentials': {},
            'team': 'academy'
        },
        'items': [],
        'epics': []
    }

    sync_service = CalendarSyncService()

    provider = MockCalendarProvider()
    credentials = CalendarCredentials(provider='mock', raw_data={})
    provider.authenticate(credentials)

    # External event without kanbanId
    external_event = CalendarEvent(
        event_id='external-001',
        kanban_id=None,  # No kanban ID - external event
        title='Dentist Appointment',
        due_date='2026-05-10',
        last_modified=datetime.now(timezone.utc),
        deleted=False
    )
    provider._events['external-001'] = external_event

    cache_key = f"{team['team']}:mock:primary"
    sync_service._providers[cache_key] = provider

    # Run sync
    result = sync_service.sync_inbound(team)

    # Verify
    assert result['success'], f"Sync failed: {result.get('error')}"
    assert result['stats']['externalEvents'] == 1, f"Expected 1 external event, got {result['stats']['externalEvents']}"

    # Check external events storage
    external_events = sync_service.get_external_events('academy')
    assert len(external_events) == 1, f"Expected 1 external event stored, got {len(external_events)}"
    assert external_events[0].title == 'Dentist Appointment', "External event title mismatch"

    print("✅ External events handling passed")


def run_all_tests():
    """Run all test cases."""
    print("=" * 60)
    print("CalendarSyncService Inbound Sync Tests")
    print("=" * 60)

    try:
        test_inbound_sync_basic()
        test_inbound_sync_deleted_event()
        test_inbound_sync_conflict()
        test_inbound_sync_external_events()

        print("\n" + "=" * 60)
        print("✅ All tests passed!")
        print("=" * 60)
        return 0

    except AssertionError as e:
        print(f"\n❌ Test failed: {e}")
        return 1
    except Exception as e:
        print(f"\n❌ Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        return 1


if __name__ == '__main__':
    sys.exit(run_all_tests())
