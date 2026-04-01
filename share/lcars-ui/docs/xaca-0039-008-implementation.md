# XACA-0039-008: Per-Team Calendar Configuration UI

## Overview

This subitem implements the calendar settings UI for LCARS Fleet Monitor, allowing each team to configure their own Apple Calendar and Google Calendar integrations independently.

## What Was Implemented

### 1. Calendar Settings Modal (HTML)
**File:** `index.html`

Added a new LCARS-styled modal with:
- Two provider sections (Apple Calendar and Google Calendar)
- Connection status display for each provider
- Account and calendar information when connected
- Calendar selection dropdowns (populated from available calendars)
- Connect/Disconnect buttons with proper state management
- Per-team configuration notice

### 2. Calendar Settings Styles (CSS)
**File:** `css/lcars.css`

Added comprehensive LCARS-themed styles:
- `.calendar-settings-modal` - Modal container with max-width
- `.calendar-provider-section` - Provider configuration sections with left border accent
- `.provider-status` - Connection status indicator
- `.provider-info` - Account/calendar information display
- `.provider-select` - Calendar selection dropdown
- `.calendar-settings-btn` - Settings button in calendar controls
- Proper color coding (Apple = amber accent, Google = teal accent)

### 3. Calendar Settings JavaScript (JS)
**File:** `js/lcars.js`

Added comprehensive functionality:

**Modified Function:**
- `renderCalendarControls()` - Added settings button to calendar controls

**New Functions:**
- `openCalendarSettingsModal()` - Opens modal and loads config
- `closeCalendarSettingsModal()` - Closes the modal
- `loadCalendarConfig()` - Fetches config from `/api/calendar-config/{team}`
- `updateCalendarSettingsUI(config)` - Updates UI based on configuration
- `populateCalendarSelect()` - Populates calendar dropdowns
- `saveCalendarSelection()` - Saves calendar selection to server
- `connectAppleCalendar()` - Initiates Apple Calendar OAuth flow
- `disconnectAppleCalendar()` - Disconnects Apple Calendar
- `connectGoogleCalendar()` - Initiates Google Calendar OAuth flow
- `disconnectGoogleCalendar()` - Disconnects Google Calendar

### 4. Configuration Schema Documentation
**File:** `docs/calendar-config-schema.md`

Documented the JSON schema for calendar configuration files:
- File locations per team
- Complete schema with all fields
- Security considerations for token storage
- Expected API endpoints
- UI integration notes

### 5. Sample Configuration File
**File:** `config/academy/calendar-config.json`

Created initial empty config file for the Academy team as a template.

## Configuration Structure

```json
{
  "apple": {
    "connected": true,
    "accountName": "user@example.com",
    "selectedCalendarId": "calendar-uuid",
    "calendarName": "Work Calendar",
    "availableCalendars": [...]
  },
  "google": {
    "connected": true,
    "accountName": "user@gmail.com",
    "selectedCalendarId": "primary",
    "calendarName": "Primary Calendar",
    "availableCalendars": [...]
  },
  "lastUpdated": "2026-01-25T15:30:00Z"
}
```

Configuration is stored per-team in `config/{team}/calendar-config.json`.

## API Integration Requirements

The UI expects the following backend API endpoints to be implemented:

1. **GET /api/calendar-config/{team}**
   - Returns the calendar configuration for the specified team
   - Returns 404 if no configuration exists

2. **POST /api/calendar-config/{team}/{provider}/connect**
   - Initiates OAuth flow for the specified provider
   - Returns `{ "authUrl": "https://..." }`
   - Opens OAuth in popup window

3. **POST /api/calendar-config/{team}/{provider}/disconnect**
   - Disconnects the specified provider
   - Removes stored tokens and configuration

4. **POST /api/calendar-config/{team}/{provider}/select**
   - Body: `{ "calendarId": "calendar-uuid" }`
   - Saves the selected calendar ID
   - Fetches calendar name and updates configuration

## UI Flow

1. User clicks "⚙ SETTINGS" button in calendar controls
2. Modal opens and loads current configuration
3. User sees connection status for both providers
4. **If disconnected:**
   - Click "Connect [Provider] Calendar"
   - OAuth popup opens
   - User authenticates
   - Popup closes
   - Configuration reloads, showing connected state
   - Available calendars populate dropdown
5. **If connected:**
   - User can select different calendar from dropdown
   - Selection auto-saves
   - User can click "Disconnect" to remove integration

## Visual Design

- LCARS-themed modal with orange header
- Provider sections use color coding:
  - Apple Calendar: Amber accent
  - Google Calendar: Teal accent
- Connection status shows green "CONNECTED" or red "NOT CONNECTED"
- Buttons follow LCARS button styling
- Settings button in calendar controls has amber background

## Testing Checklist

- [ ] Settings button appears in calendar controls
- [ ] Clicking settings button opens modal
- [ ] Modal displays correct disconnected state initially
- [ ] Connect buttons trigger OAuth flow (requires backend)
- [ ] Disconnect buttons show confirmation and disconnect (requires backend)
- [ ] Calendar dropdowns populate when connected (requires backend)
- [ ] Calendar selection saves automatically (requires backend)
- [ ] Configuration loads correctly per team
- [ ] Close button and backdrop click close modal
- [ ] Toast notifications appear for success/error states

## Files Modified

1. `/Users/darrenehlers/dev-team/lcars-ui/index.html` - Added modal HTML
2. `/Users/darrenehlers/dev-team/lcars-ui/css/lcars.css` - Added styles
3. `/Users/darrenehlers/dev-team/lcars-ui/js/lcars.js` - Added functionality

## Files Created

1. `/Users/darrenehlers/dev-team/lcars-ui/config/academy/calendar-config.json` - Sample config
2. `/Users/darrenehlers/dev-team/lcars-ui/docs/calendar-config-schema.md` - Schema docs
3. `/Users/darrenehlers/dev-team/lcars-ui/docs/xaca-0039-008-implementation.md` - This file

## Next Steps

This UI is now ready for backend integration. The following subitems will implement:
- XACA-0039-009: Apple Calendar OAuth implementation
- XACA-0039-010: Google Calendar OAuth implementation
- XACA-0039-011: Two-way sync logic

## Notes

- All configuration is per-team, allowing each team to connect their own calendars
- OAuth flows open in popup windows to avoid navigation issues
- Token storage should use secure methods (keychain, encryption, env vars)
- The UI gracefully handles missing or invalid configuration
- Toast notifications provide feedback for all actions
