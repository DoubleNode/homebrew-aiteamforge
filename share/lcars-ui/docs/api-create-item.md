# API: Create Item in External Integration

## Endpoint

```
POST /api/integrations/create-item
```

## Description

Creates a new item (ticket, card, issue) in an external integration system (Monday.com, JIRA, GitHub, etc.). The request is routed to the appropriate integration provider based on the integration ID.

## Request

### Headers

```
Content-Type: application/json
```

### Body

```json
{
  "integrationId": "string (required)",
  "boardId": "string (required)",
  "title": "string (required)",
  "description": "string (optional)",
  "metadata": {
    "status": "string (optional)",
    "priority": "string (optional)",
    "column_values": {}
  }
}
```

### Parameters

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `integrationId` | string | **Yes** | The ID of the configured integration (e.g., "monday-main", "jira-prod") |
| `boardId` | string | **Yes** | The board/project ID in the external system |
| `title` | string | **Yes** | The item title/summary |
| `description` | string | No | Optional item description (added as notes/comments) |
| `metadata` | object | No | Additional provider-specific fields |

### Metadata Fields (Provider-Specific)

#### Monday.com
```json
{
  "status": "Working on it",
  "priority": "High",
  "status_column_id": "status",
  "column_values": {
    "status": {"label": "Working on it"},
    "priority": {"label": "High"}
  }
}
```

#### JIRA (Future)
```json
{
  "issueType": "Task",
  "priority": "High",
  "labels": ["feature", "urgent"]
}
```

## Response

### Success Response

```json
{
  "success": true,
  "ticketId": "1234567890",
  "url": "https://monday.com/boards/123/items/1234567890",
  "message": "Created item 'New Feature' on board ProjectBoard",
  "error": null
}
```

### Error Response

```json
{
  "success": false,
  "ticketId": null,
  "url": null,
  "message": null,
  "error": "Authentication failed: Invalid API token"
}
```

## Error Codes

| HTTP Status | Error Message | Cause |
|-------------|---------------|-------|
| 400 | Missing required field: integrationId | Request missing required field |
| 400 | Missing required field: boardId | Request missing required field |
| 400 | Missing required field: title | Request missing required field |
| 404 | Integration 'xyz' not found | Integration ID not configured |
| 401 | Integration 'xyz' credentials not configured | No credentials for integration |
| 500 | Unexpected error: ... | Server or provider error |

## Examples

### cURL Example

```bash
curl -X POST http://localhost:8080/api/integrations/create-item \
  -H "Content-Type: application/json" \
  -d '{
    "integrationId": "monday-main",
    "boardId": "1234567890",
    "title": "Implement user authentication",
    "description": "Add JWT-based authentication to the API",
    "metadata": {
      "status": "Working on it",
      "priority": "High"
    }
  }'
```

### JavaScript Example

```javascript
async function createItem() {
  const response = await fetch('/api/integrations/create-item', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      integrationId: 'monday-main',
      boardId: '1234567890',
      title: 'Fix login bug',
      description: 'Users cannot log in after password reset',
      metadata: {
        status: 'Working on it',
        priority: 'Critical'
      }
    })
  });

  const result = await response.json();

  if (result.success) {
    console.log('Created item:', result.ticketId);
    console.log('View at:', result.url);
  } else {
    console.error('Failed to create item:', result.error);
  }
}
```

### Python Example

```python
import requests
import json

def create_item(integration_id, board_id, title, description=None, metadata=None):
    """Create an item in an external integration."""
    url = 'http://localhost:8080/api/integrations/create-item'

    payload = {
        'integrationId': integration_id,
        'boardId': board_id,
        'title': title,
        'description': description,
        'metadata': metadata or {}
    }

    response = requests.post(url, json=payload)
    result = response.json()

    if result['success']:
        print(f"Created item: {result['ticketId']}")
        print(f"URL: {result['url']}")
        return result['ticketId']
    else:
        print(f"Error: {result['error']}")
        return None

# Example usage
create_item(
    integration_id='monday-main',
    board_id='1234567890',
    title='Add dark mode support',
    description='Implement dark theme for better UX',
    metadata={
        'status': 'Planned',
        'priority': 'Medium'
    }
)
```

## Provider Support

| Provider | Supported | Notes |
|----------|-----------|-------|
| Monday.com | ✅ Yes | Full support with column values |
| JIRA | ⏳ Planned | Coming soon |
| GitHub | ⏳ Planned | Coming soon |
| Linear | ⏳ Planned | Coming soon |

## Implementation Details

### Provider Interface

All integration providers inherit from `IntegrationProvider` and can optionally implement:

```python
def create_item(
    self,
    board_id: str,
    title: str,
    description: Optional[str] = None,
    metadata: Optional[Dict[str, Any]] = None
) -> CreateItemResult:
    """Create a new item in the external integration."""
    pass
```

Providers that don't implement `create_item` will return:

```json
{
  "success": false,
  "error": "<Provider Name> does not support item creation"
}
```

### Monday.com GraphQL

The Monday.com provider uses the following GraphQL mutation:

```graphql
mutation createItem($boardId: ID!, $itemName: String!, $columnValues: JSON) {
  create_item(
    board_id: $boardId,
    item_name: $itemName,
    column_values: $columnValues
  ) {
    id
    name
    board {
      id
      name
    }
  }
}
```

## Related Endpoints

- `POST /api/integrations/search` - Search for existing items
- `POST /api/integrations/verify` - Verify an item exists
- `POST /api/integrations/boards` - List available boards
- `POST /api/sync/item` - Sync item status with external integration

## Version History

- **v1.0** (2026-02-02) - Initial implementation
  - Monday.com provider support
  - Basic field mapping (title, description)
  - Error handling and validation
