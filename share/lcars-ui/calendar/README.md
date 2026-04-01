# Fleet Monitor Calendar Sync

Bidirectional synchronization between Fleet Monitor kanban items and external calendar providers (Apple iCloud, Google Calendar).

## Architecture

```
calendar/
├── provider.py            # Abstract base class and data models
├── mock_provider.py       # In-memory provider for testing
├── apple_provider.py      # Apple iCloud CalDAV implementation
├── google_provider.py     # Google Calendar API implementation
├── sync_service.py        # Bidirectional sync service
├── example_apple_usage.py # Apple provider examples
└── example_sync_usage.py  # Sync service examples
```

## Provider Abstraction

All providers inherit from `CalendarProvider` and implement:

- `authenticate(credentials)` - Validate credentials and establish connection
- `create_event(event)` - Create calendar event from kanban item
- `update_event(event_id, event)` - Update existing event
- `delete_event(event_id)` - Delete event
- `fetch_events(since=None)` - Fetch events, optionally filtered by modification time
- `verify_connection()` - Test that connection is working

## Apple CalDAV Provider

**Endpoint:** `https://caldav.icloud.com`

**Authentication:** Username (iCloud email) + app-specific password

**Event Format:** iCalendar (RFC 5545) with custom X- properties

### Features

- Principal URL discovery via PROPFIND
- Calendar home set resolution
- Event CRUD via CalDAV PUT/DELETE/REPORT
- ETag-based optimistic locking
- Custom X- properties for Fleet Monitor metadata

### Example Usage

```python
from calendar.apple_provider import AppleCalendarProvider
from calendar.provider import CalendarCredentials, CalendarEvent

# Create provider
provider = AppleCalendarProvider(calendar_id="primary")

# Authenticate with app-specific password
credentials = CalendarCredentials(
    provider="apple",
    raw_data={
        "username": "user@icloud.com",
        "appPassword": "xxxx-xxxx-xxxx-xxxx"
    }
)

success = provider.authenticate(credentials)

# Create event
event = CalendarEvent(
    kanban_id="XACA-0040",
    title="File initial motion",
    description="Legal filing task",
    due_date="2026-02-15",
    priority="high",
    team="academy",
    event_type="item"
)

result = provider.create_event(event)
print(f"Event ID: {result.event_id}")  # XACA-0040@fleetmonitor
```

### Event ID Format

Apple CalDAV events use UID format: `{kanban_id}@fleetmonitor`

Example: `XACA-0040@fleetmonitor`

### Metadata Storage

Fleet Monitor metadata is stored in custom X- properties:

```ics
BEGIN:VEVENT
UID:XACA-0040@fleetmonitor
DTSTART;VALUE=DATE:20260215
SUMMARY:File initial motion
X-KANBAN-ID:XACA-0040
X-TYPE:item
X-TEAM:academy
X-STATUS:in-progress
X-PRIORITY:high
X-SOURCE:fleet-monitor
X-VERSION:1
END:VEVENT
```

## Google Calendar Provider

**Status:** Not yet implemented (XACA-0039-004)

Will use Google Calendar API v3 with OAuth2 authentication.

## Mock Provider

In-memory provider for testing sync logic without requiring actual calendar service credentials.

### Example Usage

```python
from calendar.mock_provider import MockCalendarProvider
from calendar.provider import CalendarCredentials, CalendarEvent

# Create mock provider
provider = MockCalendarProvider(calendar_id="test-calendar")

# Authenticate (always succeeds for mock)
credentials = CalendarCredentials(provider="mock", raw_data={})
provider.authenticate(credentials)

# Create event
event = CalendarEvent.from_kanban_item({
    "id": "XACA-0050",
    "title": "Review discovery",
    "dueDate": "2026-02-20",
    "priority": "high"
})

result = provider.create_event(event)
print(f"Created: {result.event_id}")  # mock-event-0001

# Fetch events
fetch_result = provider.fetch_events()
print(f"Total events: {fetch_result.total_count}")
```

## Calendar Sync Service

**Module:** `calendar.sync_service.CalendarSyncService`

The sync service handles bidirectional synchronization between Fleet Monitor and external calendars.

### Outbound Sync (Fleet Monitor → Calendar)

Pushes changes from kanban items/epics to calendar events:

```python
from calendar.sync_service import CalendarSyncService

sync_service = CalendarSyncService()

# Register provider for team (after authentication)
sync_service._providers["academy:apple:primary"] = apple_provider

# Sync items with due dates
items = [
    {
        "id": "XACA-0040",
        "title": "File motion",
        "dueDate": "2026-02-15",
        "priority": "high"
    }
]

result = sync_service.sync_outbound("academy", items)

# Check results
print(f"Synced: {result['synced']}, Errors: {result['errors']}")
```

### Features

- **Batch processing**: Sync multiple items in one operation
- **Create/Update detection**: Automatically creates new events or updates existing ones
- **Epic support**: Handles epic due dates and court dates
- **Error handling**: Tracks retry counts and error messages
- **Metadata tracking**: Updates `calendarSync` object on each item

### Calendar Sync Metadata

Each synced item gets a `calendarSync` object:

```json
{
  "externalEventId": "XACA-0040@fleetmonitor",
  "provider": "apple",
  "lastSyncedAt": "2026-01-25T12:30:00Z",
  "syncStatus": "synced",
  "lastModifiedLocal": "2026-01-25T12:00:00Z",
  "lastModifiedExternal": "2026-01-25T11:00:00Z",
  "syncError": null,
  "retryCount": 0
}
```

### API Endpoint

**POST** `/api/calendar/sync/trigger`

Triggers manual sync for a team:

```json
{
  "team": "academy",
  "direction": "outbound"
}
```

Response:

```json
{
  "success": true,
  "message": "Calendar sync completed (outbound)",
  "team": "academy",
  "direction": "outbound",
  "result": {
    "outbound": {
      "success": true,
      "total_items": 3,
      "synced": 3,
      "created": 2,
      "updated": 1,
      "skipped": 0,
      "errors": 0,
      "error_messages": []
    }
  }
}
```

## Known Issues

### Module Name Collision

**Problem:** The `calendar` package name conflicts with Python's built-in `calendar` module, causing import errors when using libraries like `requests`:

```
ImportError: cannot import name 'timegm' from 'calendar'
```

**Affected:** `AppleCalendarProvider` (uses `requests` library)

**Not Affected:** `MockCalendarProvider` (no external dependencies)

**Solution:** Rename the `calendar/` directory to avoid the conflict:

```bash
# Option 1: Rename to fleetmonitor_calendar
mv calendar/ fleetmonitor_calendar/

# Update imports throughout codebase:
# from calendar.provider import ...
# → from fleetmonitor_calendar.provider import ...

# Option 2: Rename to fm_calendar
mv calendar/ fm_calendar/
```

**Workaround:** Use absolute imports from outside the `lcars-ui` directory:

```python
# Run Python from /Users/darrenehlers/dev-team, not from lcars-ui/
import sys
sys.path.insert(0, '/Users/darrenehlers/dev-team/lcars-ui')
from calendar.apple_provider import AppleCalendarProvider
```

**Status:** Pending architectural decision on package rename.

## Testing

### Syntax Validation

```bash
# Verify Python syntax without executing imports
python3 -m py_compile calendar/apple_provider.py
python3 -m py_compile calendar/mock_provider.py
python3 -m py_compile calendar/provider.py
```

### Smoke Tests

Run basic functionality tests:

```bash
python3 calendar/smoke_test.py
```

**Note:** Due to package naming conflict, some tests that require `requests` library (Apple/Google providers) will fail on import. Tests for mock provider and sync service inbound functionality work correctly.

### Unit Tests

```bash
# Run existing sync service tests
python3 -m calendar.test_sync_service

# Note: Requires manual setup due to import path issues
```

## Known Issues

### Package Name Shadowing

⚠️ **CRITICAL**: This package is named `calendar`, which shadows Python's stdlib `calendar` module.

**Impact:**
- Some stdlib modules (e.g., `http.cookiejar`) cannot import `calendar.timegm`
- The `requests` library fails to import with `ImportError: cannot import name 'timegm'`
- This affects Apple and Google providers which use `requests`

**Workarounds:**

1. **Direct module import** (bypasses `requests`):
   ```python
   # Works
   from calendar.mock_provider import MockCalendarProvider
   from calendar.sync_service import CalendarSyncService

   # Fails (uses requests)
   from calendar.apple_provider import AppleCalendarProvider
   ```

2. **Import stdlib calendar first**:
   ```python
   import calendar as stdlib_calendar  # Import stdlib FIRST
   from calendar import apple_provider   # Then import our package
   ```

3. **Use absolute imports**:
   ```python
   import sys
   from calendar.provider import CalendarCredentials
   ```

**Resolution:**
- Consider renaming package to `fm_calendar` or `cal_sync` in future refactor
- For now, documentation and careful import ordering required

## Security

### Credential Encryption

Credentials stored in kanban board JSON are encrypted using AES-256-GCM:

- Master key from environment: `CALENDAR_ENCRYPTION_KEY`
- Per-team salt: team ID
- Encrypted blob stored in `calendarConfig.credentials.encrypted`

### App-Specific Passwords (Apple)

Generate at: https://appleid.apple.com/account/manage → Security → App-Specific Passwords

Format: `xxxx-xxxx-xxxx-xxxx`

### OAuth2 Tokens (Google)

Refresh tokens stored encrypted, access tokens cached in memory (not persisted).

## References

- [RFC 4791 - CalDAV](https://datatracker.ietf.org/doc/html/rfc4791)
- [RFC 5545 - iCalendar](https://datatracker.ietf.org/doc/html/rfc5545)
- [Google Calendar API v3](https://developers.google.com/calendar/api/v3/reference)
- [XACA-0039-001 - Data Model Spec](../../docs/kanban/XACA-0039-001_calendar-data-model.md)

---

**Last Updated:** 2026-01-25
**Author:** Commander Jett Reno - Chief Technical Instructor, Academy
