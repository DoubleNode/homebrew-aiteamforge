# LCARS Multi-Platform Integration System

A flexible integration system for connecting kanban items to external ticket tracking platforms.

## Supported Platforms

- **JIRA** - Atlassian JIRA Cloud/Server
- **Monday.com** - Monday.com boards and items
- **GitHub** - GitHub Issues (planned)
- **Linear** - Linear App (planned)
- **Custom** - Custom integrations via provider interface

## Architecture

```
integrations/
  __init__.py           # Package exports
  provider.py           # Base IntegrationProvider class
  manager.py            # IntegrationManager singleton
  jira_provider.py      # JIRA implementation
  monday_provider.py    # Monday.com implementation
  sync_service.py       # Bidirectional sync service
  ticket_links.py       # ticketLinks data model helpers
  migrate_jira_to_ticketlinks.py  # Migration script
  test_integrations.py  # Unit tests
  test_monday_integration.py  # Manual Monday.com integration test
```

## Configuration

Integrations are configured in `config/integrations.json`:

```json
{
  "integrations": [
    {
      "id": "jira-mainevent",
      "type": "jira",
      "name": "Main Event JIRA",
      "enabled": true,
      "baseUrl": "https://mainevent.atlassian.net",
      "browseUrl": "https://mainevent.atlassian.net/browse/{ticketId}",
      "apiVersion": "3",
      "ticketPattern": "^[A-Z]{1,10}-[0-9]+$",
      "auth": {
        "type": "basic",
        "userEnvVar": "JIRA_USER",
        "tokenEnvVar": "JIRA_API_TOKEN"
      }
    },
    {
      "id": "monday-projects",
      "type": "monday",
      "name": "Monday.com Projects",
      "enabled": true,
      "baseUrl": "https://api.monday.com/v2",
      "browseUrl": "https://view.monday.com/pulse/{ticketId}",
      "ticketPattern": "^(MON-)?[0-9]+$",
      "auth": {
        "type": "bearer",
        "tokenEnvVar": "MONDAY_API_TOKEN"
      }
    }
  ]
}
```

## Credentials

Credentials are stored in environment variables for security:

```bash
# JIRA
export JIRA_USER="your-email@example.com"
export JIRA_API_TOKEN="your-api-token"

# Monday.com
export MONDAY_API_TOKEN="your-monday-api-token"
```

### Getting a Monday.com API Token

1. Log in to Monday.com
2. Click your profile picture → Admin
3. Go to the **API** section
4. Generate a **Personal API Token**
5. Copy the token and set it as `MONDAY_API_TOKEN` environment variable

## ticketLinks Data Model

The new `ticketLinks` array replaces the legacy `jiraId` field:

```json
{
  "id": "item-001",
  "title": "My Task",
  "ticketLinks": [
    {
      "integrationId": "jira-mainevent",
      "ticketId": "ME-123",
      "ticketUrl": "https://mainevent.atlassian.net/browse/ME-123",
      "summary": "Ticket summary",
      "status": "In Progress",
      "linkedAt": "2025-01-15T10:30:00Z"
    }
  ]
}
```

### Helper Functions

```python
from integrations import (
    get_ticket_links,
    add_ticket_link,
    remove_ticket_link,
    has_ticket_link,
    get_primary_ticket_link,
    migrate_jira_id_to_ticket_links
)

# Get all links from an item
links = get_ticket_links(item)

# Check if item has any links
if has_ticket_link(item):
    primary = get_primary_ticket_link(item)

# Add a new link
link = TicketLink(integrationId='jira-mainevent', ticketId='ME-456')
add_ticket_link(item, link)

# Remove a specific link
remove_ticket_link(item, 'jira-mainevent', 'ME-456')
```

## Migration

To migrate existing boards from `jiraId` to `ticketLinks`:

```bash
# Dry run first
python3 migrate_jira_to_ticketlinks.py --dry-run

# Run migration (preserves legacy fields)
python3 migrate_jira_to_ticketlinks.py

# Remove legacy fields after migration
python3 migrate_jira_to_ticketlinks.py --remove-legacy

# Migrate specific board
python3 migrate_jira_to_ticketlinks.py --board ios
```

## API Endpoints

### GET /api/integrations
List all configured integrations.

### POST /api/integrations/search
Search for tickets across integrations.
```json
{
  "integrationId": "jira-mainevent",
  "query": "search term"
}
```

### POST /api/integrations/verify
Verify a ticket ID exists.
```json
{
  "integrationId": "jira-mainevent",
  "ticketId": "ME-123"
}
```

### POST /api/integrations/test
Test connection to an integration.
```json
{
  "integrationId": "jira-mainevent"
}
```

### POST /api/integrations/boards
Fetch boards from Monday.com (Monday.com only).
```json
{
  "integrationId": "monday-projects",
  "limit": 50
}
```

## Monday.com Specific Features

The Monday.com provider includes additional features beyond the standard interface:

### Board Access
```python
provider = manager.get_provider('monday-projects')

# Get accessible boards
boards = provider.get_boards(limit=50)
for board in boards:
    print(f"{board['name']} ({board['id']})")
```

### Status Column Detection
```python
# Get status columns for a board
status_columns = provider.detect_status_columns(board_id)

# Get status column info for a specific item
status_info = provider.get_status_column_for_item(item_id)
# Returns: {
#   'column_id': 'status',
#   'column_title': 'Status',
#   'current_value': 'Working on it',
#   'board_id': 12345,
#   'labels': {'0': 'Done', '1': 'Working on it', ...}
# }
```

### Status Synchronization
```python
# Sync status for a Monday.com item
result = provider.sync_status(
    item_id=12345,
    new_status='Done',
    status_mapping={
        'completed': 'Done',
        'in_progress': 'Working on it',
        'backlog': 'Not Started'
    }
)
# Returns: {
#   'success': True,
#   'item_id': 12345,
#   'old_status': 'Working on it',
#   'new_status': 'Done',
#   'message': 'Status updated successfully'
# }
```

### Ticket ID Format
Monday.com items can be referenced by:
- Numeric ID: `1234567890`
- Prefixed ID: `MON-1234567890`

Both formats are valid and the prefix is stripped when making API calls.

## Creating New Providers

Extend `IntegrationProvider` to add new platforms:

```python
from integrations.provider import IntegrationProvider, IntegrationConfig
from integrations.manager import IntegrationManager

class MyProvider(IntegrationProvider):
    @property
    def id(self) -> str:
        return self.config.id

    @property
    def name(self) -> str:
        return self.config.name

    def search(self, query: str) -> SearchResult:
        # Implement search
        pass

    def verify(self, ticket_id: str) -> VerifyResult:
        # Implement verification
        pass

    def test_connection(self) -> ConnectionTestResult:
        # Implement connection test
        pass

# Register provider
IntegrationManager.register_provider('mytype', MyProvider)
```

## Running Tests

```bash
cd lcars-ui
python3 -m pytest integrations/test_integrations.py -v
# OR
python3 integrations/test_integrations.py
```

## Backward Compatibility

The system maintains backward compatibility with legacy `jiraId` fields:
- `get_ticket_links()` automatically converts legacy fields
- Old data continues to work without migration
- Migration is recommended but not required
