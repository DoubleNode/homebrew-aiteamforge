#!/usr/bin/env python3
"""
Smoke tests for Calendar Integration System.

These tests validate basic functionality without requiring pytest.
Tests focus on components that can be tested in isolation.

Run with: python3 calendar/smoke_test.py
"""

import sys
import os

# Add parent directory to path for imports BEFORE importing datetime
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Import stdlib datetime BEFORE importing calendar package (name conflict)
from datetime import datetime, timezone, timedelta


def test_imports():
    """Test that all calendar modules can be imported."""
    print("\n=== Test: Module Imports ===")

    try:
        # Import each module individually to isolate issues
        print("  Importing provider...")
        from calendar import provider
        print("  Importing mock_provider...")
        from calendar import mock_provider
        print("  Importing apple_provider...")
        from calendar import apple_provider
        print("  Importing google_provider...")
        from calendar import google_provider
        print("  Importing sync_service...")
        from calendar import sync_service

        print("✅ All modules import successfully")
        return True
    except Exception as e:
        print(f"❌ Import failed: {e}")
        import traceback
        traceback.print_exc()
        return False


def test_mock_provider_basic():
    """Test that mock provider works for basic operations."""
    print("\n=== Test: Mock Provider Basic Operations ===")

    try:
        from calendar.provider import CalendarEvent, CalendarCredentials
        from calendar.mock_provider import MockCalendarProvider

        provider = MockCalendarProvider()

        # Authenticate (returns bool, not result)
        credentials = CalendarCredentials(provider='mock', raw_data={})
        authenticated = provider.authenticate(credentials)
        assert authenticated, "Authentication failed"

        # Create an event
        event = CalendarEvent(
            event_id='test-001',
            kanban_id='XACA-0001',
            title='Test Event',
            due_date='2026-02-15',
            last_modified=datetime.now(timezone.utc),
            deleted=False
        )

        create_result = provider.create_event(event)
        assert create_result.success, f"Create failed: {create_result.error}"
        assert create_result.event_id, "No event ID returned"

        # Fetch it back
        fetch_result = provider.fetch_events(since=datetime.now(timezone.utc) - timedelta(days=1))
        assert fetch_result.success, f"Fetch failed: {fetch_result.error}"
        assert len(fetch_result.events) == 1, f"Expected 1 event, got {len(fetch_result.events)}"
        assert fetch_result.events[0].title == 'Test Event', "Event title mismatch"

        # Update it
        event.title = 'Updated Event'
        update_result = provider.update_event('test-001', event)
        assert update_result.success, f"Update failed: {update_result.error}"

        fetch_result2 = provider.fetch_events(since=datetime.now(timezone.utc) - timedelta(days=1))
        assert fetch_result2.events[0].title == 'Updated Event', "Event not updated"

        # Delete it
        delete_result = provider.delete_event('test-001')
        assert delete_result.success, f"Delete failed: {delete_result.error}"

        # Verify it's gone
        fetch_result3 = provider.fetch_events(since=datetime.now(timezone.utc) - timedelta(days=1))
        # The deleted event is still in the list but marked deleted
        deleted_events = [e for e in fetch_result3.events if e.deleted]
        assert len(deleted_events) == 1, "Event should be marked as deleted"

        print("✅ Mock provider basic operations work")
        return True
    except Exception as e:
        print(f"❌ Mock provider test failed: {e}")
        import traceback
        traceback.print_exc()
        return False


def test_provider_abstraction():
    """Test that provider abstraction layer is properly designed."""
    print("\n=== Test: Provider Abstraction Layer ===")

    try:
        from calendar.provider import (
            CalendarProvider,
            CalendarEvent,
            CalendarCredentials,
            SyncResult,
            ConnectionTestResult,
            FetchEventsResult
        )
        from calendar.mock_provider import MockCalendarProvider
        from calendar.apple_provider import AppleCalendarProvider
        from calendar.google_provider import GoogleCalendarProvider

        # Verify all providers subclass CalendarProvider
        assert issubclass(MockCalendarProvider, CalendarProvider), "MockCalendarProvider not a subclass"
        assert issubclass(AppleCalendarProvider, CalendarProvider), "AppleCalendarProvider not a subclass"
        assert issubclass(GoogleCalendarProvider, CalendarProvider), "GoogleCalendarProvider not a subclass"

        # Verify data classes have expected attributes
        event = CalendarEvent(
            event_id='test',
            kanban_id='XACA-001',
            title='Test',
            due_date='2026-01-01',
            last_modified=datetime.now(timezone.utc),
            deleted=False
        )
        assert hasattr(event, 'event_id')
        assert hasattr(event, 'kanban_id')
        assert hasattr(event, 'title')
        assert hasattr(event, 'due_date')

        print("✅ Provider abstraction layer is well-designed")
        return True
    except Exception as e:
        print(f"❌ Provider abstraction test failed: {e}")
        import traceback
        traceback.print_exc()
        return False


def test_sync_service_inbound():
    """Test inbound sync from calendar to kanban."""
    print("\n=== Test: Sync Service Inbound ===")

    try:
        from calendar.provider import CalendarEvent, CalendarCredentials
        from calendar.mock_provider import MockCalendarProvider
        from calendar.sync_service import CalendarSyncService

        sync_service = CalendarSyncService()

        # Setup team with synced item
        team = {
            'team': 'academy',
            'calendarConfig': {
                'provider': 'mock',
                'enabled': True,
                'calendarId': 'primary',
                'lastSyncAt': (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat(),
                'credentials': {},
                'team': 'academy',
                'syncOptions': {
                    'conflictResolution': 'last-write-wins'
                }
            },
            'items': [
                {
                    'id': 'XACA-0200',
                    'title': 'Inbound Test Item',
                    'dueDate': '2026-04-01',
                    'calendarSync': {
                        'externalEventId': 'event-200',
                        'provider': 'mock',
                        'lastSyncedAt': (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat(),
                        'syncStatus': 'synced',
                        'lastModifiedLocal': (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()
                    }
                }
            ],
            'epics': []
        }

        # Get provider and add updated event
        provider = MockCalendarProvider()
        credentials = CalendarCredentials(provider='mock', raw_data={})
        provider.authenticate(credentials)

        updated_event = CalendarEvent(
            event_id='event-200',
            kanban_id='XACA-0200',
            title='Inbound Test Item - Updated',
            due_date='2026-04-05',  # Changed date
            last_modified=datetime.now(timezone.utc),
            deleted=False
        )
        provider._events['event-200'] = updated_event

        # Register provider
        cache_key = f"{team['team']}:mock:primary"
        sync_service._providers[cache_key] = provider

        # Run inbound sync
        result = sync_service.sync_inbound(team)

        assert result['success'], f"Sync failed: {result.get('error')}"
        assert result['stats']['pulled'] == 1, f"Expected 1 pulled, got {result['stats']['pulled']}"

        # Verify item was updated
        item = team['items'][0]
        assert item['dueDate'] == '2026-04-05', f"Due date should be updated to 2026-04-05, got {item['dueDate']}"

        print("✅ Sync service inbound works")
        return True
    except Exception as e:
        print(f"❌ Sync service inbound test failed: {e}")
        import traceback
        traceback.print_exc()
        return False


def test_conflict_detection():
    """Test that conflicts are properly detected."""
    print("\n=== Test: Conflict Detection ===")

    try:
        from calendar.provider import CalendarEvent, CalendarCredentials
        from calendar.mock_provider import MockCalendarProvider
        from calendar.sync_service import CalendarSyncService

        sync_service = CalendarSyncService()

        team = {
            'team': 'academy',
            'calendarConfig': {
                'provider': 'mock',
                'enabled': True,
                'calendarId': 'primary',
                'lastSyncAt': (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat(),
                'credentials': {},
                'team': 'academy',
                'syncOptions': {
                    'conflictResolution': 'last-write-wins'
                }
            },
            'items': [
                {
                    'id': 'XACA-0300',
                    'title': 'Conflict Test',
                    'dueDate': '2026-05-01',  # Changed locally
                    'calendarSync': {
                        'externalEventId': 'event-300',
                        'provider': 'mock',
                        'lastSyncedAt': (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat(),
                        'syncStatus': 'synced',
                        'lastModifiedLocal': (datetime.now(timezone.utc) - timedelta(minutes=30)).isoformat()
                    }
                }
            ],
            'epics': []
        }

        # Setup provider with conflicting change
        provider = MockCalendarProvider()
        credentials = CalendarCredentials(provider='mock', raw_data={})
        provider.authenticate(credentials)

        conflicting_event = CalendarEvent(
            event_id='event-300',
            kanban_id='XACA-0300',
            title='Conflict Test - External',
            due_date='2026-05-10',  # Different from local
            last_modified=datetime.now(timezone.utc),  # Newer
            deleted=False
        )
        provider._events['event-300'] = conflicting_event

        cache_key = f"{team['team']}:mock:primary"
        sync_service._providers[cache_key] = provider

        # Run sync
        result = sync_service.sync_inbound(team)

        assert result['success'], f"Sync failed: {result.get('error')}"
        assert result['stats']['conflicts'] == 1, f"Expected 1 conflict, got {result['stats']['conflicts']}"

        # With last-write-wins, external should win
        item = team['items'][0]
        assert item['dueDate'] == '2026-05-10', f"Expected external date, got {item['dueDate']}"

        print("✅ Conflict detection works")
        return True
    except Exception as e:
        print(f"❌ Conflict detection test failed: {e}")
        import traceback
        traceback.print_exc()
        return False


def test_external_events():
    """Test handling of external-only events."""
    print("\n=== Test: External Events ===")

    try:
        from calendar.provider import CalendarEvent, CalendarCredentials
        from calendar.mock_provider import MockCalendarProvider
        from calendar.sync_service import CalendarSyncService

        sync_service = CalendarSyncService()

        team = {
            'team': 'academy',
            'calendarConfig': {
                'provider': 'mock',
                'enabled': True,
                'calendarId': 'primary',
                'lastSyncAt': (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat(),
                'credentials': {},
                'team': 'academy',
                'syncOptions': {
                    'conflictResolution': 'last-write-wins'
                }
            },
            'items': [],
            'epics': []
        }

        provider = MockCalendarProvider()
        credentials = CalendarCredentials(provider='mock', raw_data={})
        provider.authenticate(credentials)

        # External event without kanban ID
        external = CalendarEvent(
            event_id='external-001',
            kanban_id=None,
            title='Doctor Appointment',
            due_date='2026-06-01',
            last_modified=datetime.now(timezone.utc),
            deleted=False
        )
        provider._events['external-001'] = external

        cache_key = f"{team['team']}:mock:primary"
        sync_service._providers[cache_key] = provider

        # Run sync
        result = sync_service.sync_inbound(team)

        assert result['success'], f"Sync failed: {result.get('error')}"
        assert result['stats']['externalEvents'] == 1, f"Expected 1 external event, got {result['stats']['externalEvents']}"

        # Check storage
        externals = sync_service.get_external_events('academy')
        assert len(externals) == 1, f"Expected 1 external event stored, got {len(externals)}"
        assert externals[0].title == 'Doctor Appointment', "External event title mismatch"

        print("✅ External events handling works")
        return True
    except Exception as e:
        print(f"❌ External events test failed: {e}")
        import traceback
        traceback.print_exc()
        return False


def run_all_tests():
    """Run all smoke tests."""
    print("=" * 70)
    print("Calendar Integration System - Smoke Tests")
    print("=" * 70)

    results = []

    results.append(("Module Imports", test_imports()))
    results.append(("Provider Abstraction", test_provider_abstraction()))
    results.append(("Mock Provider Basic", test_mock_provider_basic()))
    results.append(("Sync Service Inbound", test_sync_service_inbound()))
    results.append(("Conflict Detection", test_conflict_detection()))
    results.append(("External Events", test_external_events()))

    # Summary
    print("\n" + "=" * 70)
    print("Test Summary")
    print("=" * 70)

    passed = sum(1 for _, result in results if result)
    total = len(results)

    for test_name, result in results:
        status = "✅ PASS" if result else "❌ FAIL"
        print(f"{status}: {test_name}")

    print("-" * 70)
    print(f"Total: {passed}/{total} tests passed")
    print("=" * 70)

    return 0 if passed == total else 1


if __name__ == '__main__':
    sys.exit(run_all_tests())
