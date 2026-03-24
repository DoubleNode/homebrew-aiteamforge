"""
Example: Using Calendar Sync Service for Outbound Sync

This demonstrates how to use CalendarSyncService to push Fleet Monitor
items to external calendars (Apple Calendar or Google Calendar).

Based on data model spec: docs/kanban/XACA-0039-001_calendar-data-model.md
"""

from calendar.sync_service import CalendarSyncService
from calendar.provider import CalendarCredentials
from calendar.apple_provider import AppleCalendarProvider
from calendar.google_provider import GoogleCalendarProvider


def example_apple_calendar_sync():
    """Example: Sync items to Apple Calendar via CalDAV"""

    # Initialize sync service
    sync_service = CalendarSyncService()

    # Setup Apple Calendar provider
    apple_provider = AppleCalendarProvider(calendar_id="primary")

    # Authenticate with app-specific password
    credentials = CalendarCredentials(
        provider="apple",
        raw_data={
            "username": "user@icloud.com",
            "appPassword": "xxxx-xxxx-xxxx-xxxx"  # App-specific password from iCloud settings
        }
    )

    apple_provider.authenticate(credentials)

    # Register provider for team
    sync_service._providers["academy:apple:primary"] = apple_provider

    # Prepare team config (would normally come from board JSON)
    team_config = {
        "team": "academy",
        "enabled": True,
        "provider": "apple",
        "calendarId": "primary",
        "credentials": credentials.raw_data,
        "syncOptions": {
            "syncEpics": True,
            "syncItems": True,
            "syncCourtDates": True,
            "autoSync": True,
            "conflictResolution": "last-write-wins"
        }
    }

    # Sample items with due dates
    items = [
        {
            "id": "XACA-0040",
            "title": "File initial motion",
            "dueDate": "2026-02-15",
            "priority": "high",
            "status": "in-progress",
            "tags": ["legal", "filing"],
            "description": "Prepare and file motion for summary judgment"
        },
        {
            "id": "EACA-0001",
            "type": "epic",
            "title": "Smith v. Jones Case",
            "dueDate": "2026-03-15",
            "priority": "high",
            "status": "active",
            "metadata": {
                "caseNumber": "2025-CV-1234",
                "courtDate": "2026-03-20"  # Separate court date event
            },
            "items": []  # Epic items would go here
        },
        {
            "id": "XACA-0041",
            "title": "Review discovery documents",
            "dueDate": "2026-02-20",
            "priority": "medium",
            "status": "backlog"
        }
    ]

    # Perform outbound sync
    print("Starting outbound sync to Apple Calendar...")
    result = sync_service.sync_outbound("academy", items)

    print(f"\nSync Results:")
    print(f"  Success: {result['success']}")
    print(f"  Total Items: {result['total_items']}")
    print(f"  Synced: {result['synced']}")
    print(f"  Created: {result['created']}")
    print(f"  Updated: {result['updated']}")
    print(f"  Skipped: {result['skipped']}")
    print(f"  Errors: {result['errors']}")

    if result['error_messages']:
        print("\nErrors:")
        for error in result['error_messages']:
            print(f"  - {error}")

    # Check calendarSync metadata on items
    print("\nItem Calendar Sync Status:")
    for item in items:
        item_id = item.get('id')
        calendar_sync = item.get('calendarSync', {})
        status = calendar_sync.get('syncStatus', 'not synced')
        event_id = calendar_sync.get('externalEventId', 'N/A')
        error = calendar_sync.get('syncError')

        print(f"  {item_id}:")
        print(f"    Status: {status}")
        print(f"    Event ID: {event_id}")
        if error:
            print(f"    Error: {error}")


def example_google_calendar_sync():
    """Example: Sync items to Google Calendar via OAuth2"""

    # Initialize sync service
    sync_service = CalendarSyncService()

    # Setup Google Calendar provider
    google_provider = GoogleCalendarProvider(calendar_id="primary")

    # Authenticate with OAuth2 refresh token
    credentials = CalendarCredentials(
        provider="google",
        raw_data={
            "refreshToken": "1//abc123def456...",
            "clientId": "xxx.apps.googleusercontent.com",
            "clientSecret": "GOCSPX-xxx..."
        }
    )

    google_provider.authenticate(credentials)

    # Register provider for team
    sync_service._providers["academy:google:primary"] = google_provider

    # Prepare team config
    team_config = {
        "team": "academy",
        "enabled": True,
        "provider": "google",
        "calendarId": "primary",
        "credentials": credentials.raw_data
    }

    # Sample items
    items = [
        {
            "id": "XACA-0050",
            "title": "Prepare client presentation",
            "dueDate": "2026-02-10",
            "priority": "high",
            "status": "in-progress"
        }
    ]

    # Perform outbound sync
    print("Starting outbound sync to Google Calendar...")
    result = sync_service.sync_outbound("academy", items)

    print(f"\nSync Results:")
    print(f"  Success: {result['success']}")
    print(f"  Total Items: {result['total_items']}")
    print(f"  Synced: {result['synced']}")
    print(f"  Created: {result['created']}")
    print(f"  Updated: {result['updated']}")


def example_update_existing_event():
    """Example: Update an item that's already synced"""

    sync_service = CalendarSyncService()

    # Item that was previously synced (has calendarSync metadata)
    item = {
        "id": "XACA-0040",
        "title": "File initial motion (UPDATED)",
        "dueDate": "2026-02-16",  # Date changed
        "priority": "high",
        "status": "in-progress",
        "calendarSync": {
            "externalEventId": "XACA-0040@fleetmonitor",
            "provider": "apple",
            "lastSyncedAt": "2026-01-25T10:00:00Z",
            "syncStatus": "synced",
            "lastModifiedLocal": "2026-01-25T10:00:00Z",
            "retryCount": 0
        }
    }

    # Sync will detect existing event and update it
    # (Assumes provider is registered and authenticated)
    result = sync_service.sync_outbound("academy", [item])

    # Item's calendarSync metadata will be updated
    calendar_sync = item.get('calendarSync', {})
    print(f"Updated event: {calendar_sync.get('syncStatus')}")
    print(f"Last synced: {calendar_sync.get('lastSyncedAt')}")


def example_error_handling():
    """Example: Handling sync errors with retry logic"""

    sync_service = CalendarSyncService()

    # Item with error
    item = {
        "id": "XACA-0042",
        "title": "Test item",
        "dueDate": "2026-02-20",
        "calendarSync": {
            "syncStatus": "error",
            "syncError": "Network timeout",
            "retryCount": 2,
            "lastErrorAt": "2026-01-25T14:30:00Z"
        }
    }

    # Check if should retry based on retry count
    calendar_sync = item.get('calendarSync', {})
    retry_count = calendar_sync.get('retryCount', 0)

    if retry_count < 5:
        # Retry the sync
        print(f"Retrying sync (attempt {retry_count + 1})...")
        result = sync_service.sync_outbound("academy", [item])

        # Check result
        new_sync = item.get('calendarSync', {})
        new_retry_count = new_sync.get('retryCount', 0)

        if new_sync.get('syncStatus') == 'synced':
            print("✓ Sync succeeded on retry")
        else:
            print(f"✗ Sync failed again (retry count: {new_retry_count})")
    else:
        print("Max retries exceeded - manual intervention required")


if __name__ == '__main__':
    print("=" * 70)
    print("Calendar Sync Service Examples")
    print("=" * 70)
    print()

    print("NOTE: These examples require valid credentials and network access.")
    print("      Uncomment the desired example to run.")
    print()

    # Uncomment to run:
    # example_apple_calendar_sync()
    # example_google_calendar_sync()
    # example_update_existing_event()
    # example_error_handling()

    print("Examples complete. See source code for details.")
