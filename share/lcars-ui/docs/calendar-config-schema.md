# Calendar Configuration Schema

This document describes the JSON schema for per-team calendar configuration files stored in `config/{team}/calendar-config.json`.

## File Location

Each team has its own calendar configuration:
- `config/academy/calendar-config.json`
- `config/ios/calendar-config.json`
- `config/android/calendar-config.json`
- `config/firebase/calendar-config.json`
- etc.

## Schema

```json
{
  "apple": {
    "connected": true,
    "accountName": "user@example.com",
    "accountId": "unique-account-identifier",
    "selectedCalendarId": "calendar-uuid",
    "calendarName": "Work Calendar",
    "availableCalendars": [
      {
        "id": "calendar-uuid-1",
        "name": "Work Calendar"
      },
      {
        "id": "calendar-uuid-2",
        "name": "Personal"
      }
    ],
    "accessToken": "encrypted-or-keychain-reference",
    "refreshToken": "encrypted-or-keychain-reference",
    "tokenExpiry": "2026-02-01T12:00:00Z"
  },
  "google": {
    "connected": true,
    "accountName": "user@gmail.com",
    "accountId": "google-user-id",
    "selectedCalendarId": "primary",
    "calendarName": "Primary Calendar",
    "availableCalendars": [
      {
        "id": "primary",
        "name": "Primary Calendar"
      },
      {
        "id": "calendar-id-2",
        "name": "Team Calendar"
      }
    ],
    "accessToken": "encrypted-oauth-token",
    "refreshToken": "encrypted-refresh-token",
    "tokenExpiry": "2026-02-01T12:00:00Z"
  },
  "lastUpdated": "2026-01-25T15:30:00Z"
}
```

## Fields

### Top Level

- `apple` (object|null): Apple Calendar configuration, null if not connected
- `google` (object|null): Google Calendar configuration, null if not connected
- `lastUpdated` (string|null): ISO 8601 timestamp of last configuration change

### Provider Object (apple/google)

- `connected` (boolean): Whether the provider is currently connected
- `accountName` (string): Display name for the connected account (email)
- `accountId` (string): Unique identifier for the account
- `selectedCalendarId` (string): ID of the calendar selected for sync
- `calendarName` (string): Display name of the selected calendar
- `availableCalendars` (array): List of calendars available in the account
  - Each calendar has `id` (string) and `name` (string)
- `accessToken` (string): OAuth access token (should be encrypted or stored securely)
- `refreshToken` (string): OAuth refresh token (should be encrypted or stored securely)
- `tokenExpiry` (string): ISO 8601 timestamp when the access token expires

## Security Considerations

**IMPORTANT:** Access tokens and refresh tokens should NEVER be stored in plain text:

1. Use environment variables or secure credential storage (macOS Keychain, etc.)
2. Encrypt tokens before storing in JSON
3. Reference tokens by key/ID rather than storing actual values
4. Implement token rotation and automatic refresh

Example secure storage approach:
```json
{
  "accessToken": "keychain:calendar-apple-access",
  "refreshToken": "keychain:calendar-apple-refresh"
}
```

## API Endpoints

The following API endpoints are expected for calendar configuration:

- `GET /api/calendar-config/{team}` - Load calendar configuration
- `POST /api/calendar-config/{team}/{provider}/connect` - Initiate OAuth flow
- `POST /api/calendar-config/{team}/{provider}/disconnect` - Disconnect provider
- `POST /api/calendar-config/{team}/{provider}/select` - Select a calendar

## UI Integration

The calendar settings UI is accessible via:
1. Settings button in the Calendar section
2. Click "⚙ SETTINGS" in calendar controls

The UI shows:
- Connection status for each provider
- Account and calendar information when connected
- Connect/Disconnect buttons
- Calendar selection dropdown (when connected)
- Per-team configuration notice
