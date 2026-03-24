# Integration Selector UI Component

## Overview

The Integration Selector is a new dropdown UI component for the +LINK popup that allows users to select from configured integrations (Jira, Monday.com, GitHub, etc.) when linking or creating tickets.

## Location

- **File:** `js/lcars.js` (function `showJiraEditor`)
- **Styles:** `css/lcars.css` (Integration Selector Styles section)

## Features

### 1. Mode Toggle
Two modes for ticket operations:
- **Link Existing:** Link to an existing ticket in the selected integration
- **Create New:** Create a new ticket in the selected integration (coming soon)

### 2. Integration Dropdown
- Displays all enabled integrations from `config/integrations.json`
- Shows integration name with appropriate icon
- Automatically loads configured integrations on popup open

### 3. Dynamic Placeholders
Input placeholder changes based on selected integration and mode:
- **Jira (Link):** 📋 ME-123
- **GitHub (Link):** 🐙 owner/repo#123
- **Monday (Link):** 📊 Item ID or URL
- **Create Mode:** 🔗 New ticket title...

### 4. Integration Icons
Visual indicators for each integration type:
- Jira: 📋
- Monday: 📊
- GitHub: 🐙
- Linear: 📐
- Asana: ✓
- Trello: 📌
- Custom: 🔗

## Events

The selector emits custom events when tickets are linked or created:

### `integration-ticket-link`
Fired when linking to an existing ticket.
```javascript
{
  detail: {
    integration: { id, name, type, pattern },
    ticketId: "ME-123",
    summary: "Ticket summary",
    mode: "link",
    item: { kanban item object },
    isSubitem: false,
    parentIndex: null,
    subIndex: null
  }
}
```

### `integration-ticket-create`
Fired when creating a new ticket (future implementation).
```javascript
{
  detail: {
    integration: { id, name, type, pattern },
    title: "New ticket title",
    mode: "create",
    item: { kanban item object },
    isSubitem: false,
    parentIndex: null,
    subIndex: null
  }
}
```

## CSS Classes

### Layout
- `.integration-selector-header` - Container for selector UI
- `.integration-mode-toggle` - Mode toggle button group
- `.integration-selector-row` - Dropdown row container

### Components
- `.integration-mode-btn` - Toggle button (Link/Create)
- `.integration-mode-btn.active` - Active toggle state
- `.integration-selector-label` - "Integration:" label
- `.integration-selector` - Dropdown select element

## Usage Example

1. Click the +LINK button or existing Jira ID on a kanban item
2. Integration selector appears at top of popup
3. Select desired integration from dropdown
4. Choose mode (Link Existing or Create New)
5. Enter ticket ID or title based on mode
6. Search/verify/save as usual

## API Integration

The selector communicates with these backend endpoints:
- `GET /api/integrations/list` - Fetch configured integrations
- `POST /api/integrations/verify` - Verify ticket exists (includes integrationId)
- `POST /api/integrations/search` - Search for tickets
- `POST /api/integrations/create` - Create new ticket (coming soon)

## Configuration

Integrations are defined in `config/integrations.json`:
```json
{
  "integrations": [
    {
      "id": "jira-mainevent",
      "type": "jira",
      "name": "Main Event Jira",
      "enabled": true,
      "baseUrl": "https://mainevent.atlassian.net",
      "browseUrl": "https://mainevent.atlassian.net/browse/{ticketId}",
      "icon": "📋"
    }
  ]
}
```

## Future Enhancements

### Create New Mode (XACA-0053-005)
- API endpoint for ticket creation
- Pre-fill with kanban item details
- Return created ticket ID
- Auto-link to kanban item

### Multi-Link Support (XACA-0053-006)
- Link items to multiple tickets across different integrations
- Display multiple ticket pills
- Manage ticketLinks array instead of single jiraId

## Testing

To test the integration selector:
1. Configure integrations in `config/integrations.json`
2. Open LCARS UI in browser
3. Click +LINK on any kanban item
4. Verify selector appears with mode toggle
5. Verify dropdown shows configured integrations
6. Verify placeholder updates when changing integration
7. Verify mode toggle hides/shows search button appropriately

## Notes

- Selector only shows **enabled** integrations
- Falls back gracefully if no integrations configured
- Maintains backward compatibility with existing Jira ID workflow
- Search functionality works across all selected integrations
