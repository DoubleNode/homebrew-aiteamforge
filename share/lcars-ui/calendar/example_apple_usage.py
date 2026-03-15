"""
Example usage of AppleCalendarProvider.

NOTE: This example cannot run until the calendar package is renamed
to avoid conflict with Python's built-in calendar module.

See calendar/README.md for details on the module name collision issue.
"""

# Commented out until module naming issue is resolved
"""
from calendar.apple_provider import AppleCalendarProvider
from calendar.provider import CalendarCredentials, CalendarEvent


def main():
    # Create Apple CalDAV provider
    provider = AppleCalendarProvider(calendar_id="primary")

    # Authenticate with iCloud app-specific password
    # Generate at: https://appleid.apple.com/account/manage
    credentials = CalendarCredentials(
        provider="apple",
        raw_data={
            "username": "your-email@icloud.com",
            "appPassword": "xxxx-xxxx-xxxx-xxxx"  # Replace with your app password
        }
    )

    try:
        success = provider.authenticate(credentials)
        if success:
            print("✓ Authentication successful")
        else:
            print("✗ Authentication failed")
            return

    except ValueError as e:
        print(f"✗ Invalid credentials: {e}")
        return
    except ConnectionError as e:
        print(f"✗ Connection error: {e}")
        return
    except PermissionError as e:
        print(f"✗ Authentication error: {e}")
        return

    # Verify connection
    test_result = provider.verify_connection()
    if test_result.success:
        print(f"✓ Connected to: {test_result.calendar_name}")
        print(f"  Calendar URL: {test_result.details.get('calendarUrl')}")
    else:
        print(f"✗ Connection test failed: {test_result.message}")
        return

    # Create a test event
    event = CalendarEvent(
        kanban_id="XACA-0999",
        title="Test Calendar Event",
        description="Testing Apple CalDAV integration from Fleet Monitor",
        due_date="2026-02-15",
        priority="medium",
        status="in-progress",
        team="academy",
        event_type="item",
        tags=["test", "calendar-sync"]
    )

    print(f"\nCreating event: {event.title}")
    create_result = provider.create_event(event)

    if create_result.success:
        print(f"✓ Event created: {create_result.event_id}")
        event_id = create_result.event_id

        # Update the event
        event.title = "Updated Test Event"
        event.due_date = "2026-02-16"

        print(f"\nUpdating event: {event_id}")
        update_result = provider.update_event(event_id, event)

        if update_result.success:
            print(f"✓ Event updated")
        else:
            print(f"✗ Update failed: {update_result.error}")

        # Fetch all events
        print("\nFetching all events...")
        fetch_result = provider.fetch_events()

        if fetch_result.success:
            print(f"✓ Found {fetch_result.total_count} events")
            for evt in fetch_result.events:
                print(f"  - {evt.title} (due: {evt.due_date})")
        else:
            print(f"✗ Fetch failed: {fetch_result.error}")

        # Delete the event
        print(f"\nDeleting event: {event_id}")
        delete_result = provider.delete_event(event_id)

        if delete_result.success:
            print(f"✓ Event deleted")
        else:
            print(f"✗ Delete failed: {delete_result.error}")

    else:
        print(f"✗ Create failed: {create_result.error}")


if __name__ == "__main__":
    main()
"""

print(__doc__)
print("\nThis example is disabled due to module name collision.")
print("See calendar/README.md for resolution steps.")
