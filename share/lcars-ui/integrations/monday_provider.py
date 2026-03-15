"""
MondayProvider - Monday.com integration for LCARS kanban.

Implements IntegrationProvider for Monday.com GraphQL API.
Supports search, item verification, and connection testing.
"""

import json
import logging
import urllib.request
import urllib.error
from typing import Optional, Dict, Any, List

from .provider import (
    IntegrationProvider,
    IntegrationConfig,
    SearchResult,
    VerifyResult,
    ConnectionTestResult,
    TicketInfo,
    FetchResult,
    ImportedIssue
)
from .manager import IntegrationManager

logger = logging.getLogger(__name__)


class MondayProviderError(Exception):
    """Base exception for Monday.com provider errors."""
    pass


class MondayAuthError(MondayProviderError):
    """Raised when authentication fails."""
    pass


class MondayProvider(IntegrationProvider):
    """
    Monday.com integration provider.

    Uses Monday.com GraphQL API v2 for search and item operations.
    Authentication via API token (bearer auth).
    """

    DEFAULT_TIMEOUT = 10  # seconds
    API_URL = "https://api.monday.com/v2"

    def __init__(self, config: IntegrationConfig):
        super().__init__(config)
        self._api_url = config.base_url or self.API_URL

    def _make_request(
        self,
        query: str,
        variables: Optional[Dict[str, Any]] = None,
        timeout: int = DEFAULT_TIMEOUT
    ) -> Dict[str, Any]:
        """
        Make an authenticated GraphQL request to Monday.com API.

        Args:
            query: GraphQL query string
            variables: Optional variables for the query
            timeout: Request timeout in seconds

        Returns:
            Parsed JSON response data

        Raises:
            MondayAuthError: On authentication errors
            MondayProviderError: On other errors
        """
        creds = self.get_credentials()
        token = creds.get('token', '')

        if not token:
            raise MondayAuthError("Monday.com API token not configured")

        headers = {
            'Authorization': token,  # Monday uses just the token, no 'Bearer' prefix
            'Content-Type': 'application/json',
            'API-Version': '2024-10'  # Use stable API version
        }

        body = {'query': query}
        if variables:
            body['variables'] = variables

        data = json.dumps(body).encode('utf-8')
        req = urllib.request.Request(self._api_url, data=data, headers=headers, method='POST')

        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                result = json.loads(response.read().decode())

                # Check for GraphQL errors
                if 'errors' in result:
                    errors = result['errors']
                    error_msg = errors[0].get('message', 'Unknown error') if errors else 'Unknown error'

                    if 'authentication' in error_msg.lower() or 'unauthorized' in error_msg.lower():
                        raise MondayAuthError(f"Authentication failed: {error_msg}")

                    raise MondayProviderError(f"GraphQL error: {error_msg}")

                return result.get('data', {})

        except urllib.error.HTTPError as e:
            if e.code == 401:
                raise MondayAuthError("Monday.com authentication failed - check API token")
            elif e.code == 403:
                raise MondayAuthError("Monday.com access denied - check token permissions")
            else:
                error_body = ""
                try:
                    error_body = e.read().decode()
                except:
                    pass
                raise MondayProviderError(f"Monday.com API error ({e.code}): {error_body or e.reason}")

        except urllib.error.URLError as e:
            raise MondayProviderError(f"Network error: {e.reason}")

    def _parse_item_id(self, ticket_id: str) -> Optional[int]:
        """
        Parse Monday.com item ID from various formats.

        Supports:
        - Plain numeric ID: "1234567890"
        - Prefixed ID: "MON-1234567890"
        - Colon prefix: "mon:1234567890" or "monday:1234567890"
        - Board/Item format: "board123#item456"

        Returns:
            Integer item ID or None if invalid
        """
        ticket_id = ticket_id.strip()

        # Handle colon prefix format (mon:123456 or monday:123456)
        if ticket_id.lower().startswith('mon:'):
            ticket_id = ticket_id[4:]
        elif ticket_id.lower().startswith('monday:'):
            ticket_id = ticket_id[7:]

        # Handle dash prefix format (MON-123456)
        if ticket_id.upper().startswith('MON-'):
            ticket_id = ticket_id[4:]

        # Handle board#item format
        if '#' in ticket_id:
            parts = ticket_id.split('#')
            if len(parts) == 2:
                ticket_id = parts[1]

        # Try to parse as integer
        try:
            return int(ticket_id)
        except ValueError:
            return None

    def search(self, query: str, max_results: int = 10) -> SearchResult:
        """
        Search Monday.com for items matching query.

        Args:
            query: Search string
            max_results: Max items to return

        Returns:
            SearchResult with matching tickets
        """
        if not query.strip():
            return SearchResult()

        if not self.has_credentials():
            return SearchResult(error="Monday.com API token not configured")

        # Build GraphQL query for searching items
        # Monday.com search is done via items_page with a query filter
        gql_query = """
        query searchItems($query: String!, $limit: Int!) {
            items_page_by_column_values(
                limit: $limit,
                columns: [{column_id: "name", column_values: [$query]}]
            ) {
                items {
                    id
                    name
                    state
                    board {
                        id
                        name
                    }
                    column_values {
                        id
                        text
                    }
                }
            }
        }
        """

        # Alternative: Use boards_page with items search if column search doesn't work
        # This is a fallback that searches item names
        fallback_query = """
        query searchBoards($limit: Int!) {
            boards(limit: 10) {
                id
                name
                items_page(limit: $limit) {
                    items {
                        id
                        name
                        state
                    }
                }
            }
        }
        """

        try:
            # Try item search first
            data = self._make_request(fallback_query, {'limit': max_results})

            tickets = []
            boards = data.get('boards', [])

            for board in boards:
                board_name = board.get('name', '')
                items_page = board.get('items_page', {})
                items = items_page.get('items', [])

                for item in items:
                    item_name = item.get('name', '')
                    # Filter by query (case-insensitive)
                    if query.lower() in item_name.lower():
                        item_id = str(item.get('id', ''))
                        tickets.append(TicketInfo(
                            ticket_id=f"MON-{item_id}",
                            summary=item_name,
                            status=item.get('state', 'active'),
                            ticket_type='Item',
                            url=self.get_ticket_url(item_id),
                            exists=True,
                            raw_data={
                                'item': item,
                                'board': {'id': board.get('id'), 'name': board_name}
                            }
                        ))

                        if len(tickets) >= max_results:
                            break

                if len(tickets) >= max_results:
                    break

            return SearchResult(
                tickets=tickets,
                total_count=len(tickets)
            )

        except MondayProviderError as e:
            logger.error(f"[{self.id}] Search failed: {e}")
            return SearchResult(error=str(e))
        except Exception as e:
            logger.error(f"[{self.id}] Search failed: {e}")
            return SearchResult(error=f"Search failed: {str(e)}")

    def verify(self, ticket_id: str) -> VerifyResult:
        """
        Verify a Monday.com item exists.

        Args:
            ticket_id: Monday.com item ID (e.g., 'MON-1234567890' or '1234567890')

        Returns:
            VerifyResult with item info or error
        """
        item_id = self._parse_item_id(ticket_id)

        if not item_id:
            return VerifyResult(
                valid=False,
                error=f"Invalid Monday.com item ID format: '{ticket_id}'"
            )

        # Validate format if pattern configured
        if not self.validate_ticket_format(ticket_id):
            return VerifyResult(
                valid=False,
                error=f"Invalid format for {self.name}"
            )

        # If no credentials, accept with format-only validation
        if not self.has_credentials():
            return VerifyResult(
                valid=True,
                ticket_id=f"MON-{item_id}",
                url=self.get_ticket_url(str(item_id)),
                warning="Monday.com API token not configured - format validated only"
            )

        # Verify via API
        gql_query = """
        query getItem($ids: [ID!]!) {
            items(ids: $ids) {
                id
                name
                state
                board {
                    id
                    name
                }
                column_values {
                    id
                    text
                    type
                }
            }
        }
        """

        try:
            data = self._make_request(gql_query, {'ids': [item_id]})
            items = data.get('items', [])

            if not items:
                return VerifyResult(
                    valid=False,
                    exists=False,
                    error=f"Item '{ticket_id}' not found in Monday.com"
                )

            item = items[0]
            formatted_id = f"MON-{item.get('id', item_id)}"

            # Try to find status column
            status = item.get('state', 'active')
            column_values = item.get('column_values', [])
            for col in column_values:
                if col.get('type') == 'status' or col.get('id') == 'status':
                    status = col.get('text') or status
                    break

            return VerifyResult(
                valid=True,
                ticket_id=formatted_id,
                exists=True,
                summary=item.get('name'),
                status=status,
                ticket_type='Item',
                url=self.get_ticket_url(str(item.get('id', item_id)))
            )

        except MondayProviderError as e:
            if "not found" in str(e).lower():
                return VerifyResult(
                    valid=False,
                    exists=False,
                    error=f"Item '{ticket_id}' not found in Monday.com"
                )
            else:
                return VerifyResult(
                    valid=True,
                    ticket_id=f"MON-{item_id}",
                    url=self.get_ticket_url(str(item_id)),
                    warning=f"Could not verify ({e}) - format validated only"
                )

        except Exception as e:
            return VerifyResult(
                valid=False,
                error=f"Verification failed: {str(e)}"
            )

    def test_connection(self) -> ConnectionTestResult:
        """
        Test connection to Monday.com.

        Returns:
            ConnectionTestResult
        """
        if not self.has_credentials():
            return ConnectionTestResult(
                success=False,
                message="Monday.com API token not configured"
            )

        gql_query = """
        query {
            me {
                id
                name
                email
            }
        }
        """

        try:
            data = self._make_request(gql_query)
            me = data.get('me', {})

            return ConnectionTestResult(
                success=True,
                message=f"Connected as {me.get('name', 'Unknown')}",
                details={
                    'user': me.get('name'),
                    'email': me.get('email'),
                    'userId': me.get('id')
                }
            )

        except MondayAuthError as e:
            return ConnectionTestResult(
                success=False,
                message=str(e)
            )

        except MondayProviderError as e:
            return ConnectionTestResult(
                success=False,
                message=f"Connection failed: {e}"
            )

        except Exception as e:
            return ConnectionTestResult(
                success=False,
                message=f"Connection test failed: {str(e)}"
            )

    def get_ticket_url(self, ticket_id: str) -> str:
        """
        Generate the browse URL for a Monday.com item.

        Args:
            ticket_id: The item ID (numeric, without MON- prefix)

        Returns:
            Full URL to view the item
        """
        # Remove MON- prefix if present
        if ticket_id.upper().startswith('MON-'):
            ticket_id = ticket_id[4:]

        if self.config.browse_url:
            return self.config.browse_url.replace('{ticketId}', ticket_id)

        # Default Monday.com URL format
        # Note: Monday.com URLs are complex and may need board context
        # This returns a generic pulse URL that should work
        return f"https://view.monday.com/pulse/{ticket_id}"

    # ==========================================================================
    # Additional Monday.com-specific Methods
    # ==========================================================================

    def get_boards(self, limit: int = 50) -> List[Dict[str, Any]]:
        """
        Get list of accessible boards.

        Args:
            limit: Maximum boards to return

        Returns:
            List of board data
        """
        gql_query = """
        query getBoards($limit: Int!) {
            boards(limit: $limit) {
                id
                name
                state
                board_kind
                workspace {
                    id
                    name
                }
            }
        }
        """

        data = self._make_request(gql_query, {'limit': limit})
        return data.get('boards', [])

    def get_item(self, item_id: int) -> Optional[Dict[str, Any]]:
        """
        Get a single item by ID.

        Args:
            item_id: Numeric item ID

        Returns:
            Item data or None if not found
        """
        gql_query = """
        query getItem($ids: [ID!]!) {
            items(ids: $ids) {
                id
                name
                state
                board {
                    id
                    name
                }
                group {
                    id
                    title
                }
                column_values {
                    id
                    text
                    type
                    value
                }
                created_at
                updated_at
            }
        }
        """

        data = self._make_request(gql_query, {'ids': [item_id]})
        items = data.get('items', [])
        return items[0] if items else None

    def update_item_status(
        self,
        item_id: int,
        board_id: int,
        status_column_id: str,
        status_label: str
    ) -> Dict[str, Any]:
        """
        Update an item's status column.

        Args:
            item_id: Item ID to update
            board_id: Board ID containing the item
            status_column_id: ID of the status column
            status_label: New status label (e.g., "Done", "Working on it")

        Returns:
            Updated item data
        """
        gql_mutation = """
        mutation updateItem($itemId: ID!, $boardId: ID!, $columnId: String!, $value: JSON!) {
            change_column_value(
                item_id: $itemId,
                board_id: $boardId,
                column_id: $columnId,
                value: $value
            ) {
                id
                name
            }
        }
        """

        # Monday.com status column values are JSON with label key
        value = json.dumps({'label': status_label})

        data = self._make_request(gql_mutation, {
            'itemId': item_id,
            'boardId': board_id,
            'columnId': status_column_id,
            'value': value
        })

        return data.get('change_column_value', {})

    # =========================================================================
    # Import Support Methods
    # =========================================================================

    def fetch_issue(self, ticket_id: str, include_children: bool = True) -> FetchResult:
        """
        Fetch a complete Monday.com item with subitems for import.

        Args:
            ticket_id: Monday.com item ID (e.g., 'MON-1234567890' or '1234567890')
            include_children: Whether to fetch subitems

        Returns:
            FetchResult with complete item data
        """
        item_id = self._parse_item_id(ticket_id)

        if not item_id:
            return FetchResult(
                success=False,
                error=f"Invalid Monday.com item ID format: '{ticket_id}'"
            )

        if not self.has_credentials():
            return FetchResult(
                success=False,
                error="Monday.com API token not configured"
            )

        # GraphQL query for item with subitems
        gql_query = """
        query getItemWithSubitems($ids: [ID!]!) {
            items(ids: $ids) {
                id
                name
                state
                board {
                    id
                    name
                }
                group {
                    id
                    title
                }
                column_values {
                    id
                    text
                    type
                    value
                }
                subitems {
                    id
                    name
                    state
                    column_values {
                        id
                        text
                        type
                    }
                }
                created_at
                updated_at
            }
        }
        """

        try:
            data = self._make_request(gql_query, {'ids': [item_id]})
            items = data.get('items', [])

            if not items:
                return FetchResult(
                    success=False,
                    error=f"Item '{ticket_id}' not found in Monday.com"
                )

            item = items[0]
            formatted_id = f"MON-{item['id']}"

            # Extract status and priority from column values
            status = self._get_status_from_columns(item)
            priority = self._get_priority_from_columns(item)
            description = self._get_description_from_columns(item)

            issue = ImportedIssue(
                ticket_id=formatted_id,
                title=item.get('name', ''),
                description=description,
                status=status,
                issue_type='item',
                priority=priority,
                url=self.get_ticket_url(str(item['id'])),
                raw_data=item
            )

            # Add subitems as children
            if include_children:
                for subitem in item.get('subitems', []):
                    child_status = self._get_status_from_columns(subitem)
                    child_id = f"MON-{subitem['id']}"

                    issue.children.append(ImportedIssue(
                        ticket_id=child_id,
                        title=subitem.get('name', ''),
                        status=child_status,
                        issue_type='subitem',
                        url=self.get_ticket_url(str(subitem['id']))
                    ))

            return FetchResult(success=True, issue=issue)

        except MondayProviderError as e:
            if "not found" in str(e).lower():
                return FetchResult(
                    success=False,
                    error=f"Item '{ticket_id}' not found in Monday.com"
                )
            else:
                return FetchResult(
                    success=False,
                    error=f"Monday.com API error: {e}"
                )

        except Exception as e:
            return FetchResult(
                success=False,
                error=f"Fetch failed: {str(e)}"
            )

    def _get_status_from_columns(self, item: Dict[str, Any]) -> str:
        """Extract status from column values."""
        column_values = item.get('column_values', [])

        for col in column_values:
            col_type = col.get('type', '')
            col_id = col.get('id', '')

            # Look for status column
            if col_type == 'status' or 'status' in col_id.lower():
                text = col.get('text', '')
                if text:
                    return text

        # Fallback to item state
        state = item.get('state', 'active')
        if state == 'deleted':
            return 'done'
        return 'todo'

    def _get_priority_from_columns(self, item: Dict[str, Any]) -> str:
        """Extract priority from column values."""
        column_values = item.get('column_values', [])

        for col in column_values:
            col_id = col.get('id', '').lower()

            # Look for priority column
            if 'priority' in col_id:
                text = col.get('text', '').lower()
                if text in ('high', 'critical', 'urgent'):
                    return 'high'
                elif text in ('low', 'minor'):
                    return 'low'

        return 'medium'

    def _get_description_from_columns(self, item: Dict[str, Any]) -> str:
        """Extract description/notes from column values."""
        column_values = item.get('column_values', [])

        for col in column_values:
            col_type = col.get('type', '')
            col_id = col.get('id', '').lower()

            # Look for text/notes column
            if col_type in ('text', 'long-text') or any(x in col_id for x in ['desc', 'note', 'detail']):
                text = col.get('text', '')
                if text:
                    return text

        return ''

    # =========================================================================
    # Board Column Methods
    # =========================================================================

    def get_board_columns(self, board_id: int) -> List[Dict[str, Any]]:
        """
        Get all columns for a specific board.

        Args:
            board_id: The board ID

        Returns:
            List of column definitions with id, title, type, and settings
        """
        gql_query = """
        query getBoardColumns($boardId: [ID!]!) {
            boards(ids: $boardId) {
                id
                name
                columns {
                    id
                    title
                    type
                    settings_str
                }
            }
        }
        """

        data = self._make_request(gql_query, {'boardId': [board_id]})
        boards = data.get('boards', [])

        if not boards:
            return []

        columns = boards[0].get('columns', [])

        # Parse settings_str for each column
        for col in columns:
            settings_str = col.get('settings_str', '{}')
            try:
                col['settings'] = json.loads(settings_str)
            except json.JSONDecodeError:
                col['settings'] = {}

        return columns

    def detect_status_columns(self, board_id: int) -> List[Dict[str, Any]]:
        """
        Detect status-type columns in a board.

        Monday.com boards can have multiple status columns. This method
        finds all of them and returns their configuration including
        available labels (status values).

        Args:
            board_id: The board ID to analyze

        Returns:
            List of status column info:
            [
                {
                    'id': 'status',
                    'title': 'Status',
                    'labels': {'0': 'Done', '1': 'Working on it', ...},
                    'label_colors': {'0': '#00c875', ...}
                }
            ]
        """
        columns = self.get_board_columns(board_id)
        status_columns = []

        for col in columns:
            if col.get('type') == 'status':
                settings = col.get('settings', {})
                labels = settings.get('labels', {})
                label_colors = settings.get('labels_colors', {})

                status_columns.append({
                    'id': col.get('id'),
                    'title': col.get('title'),
                    'labels': labels,
                    'label_colors': label_colors
                })

        return status_columns

    def get_status_column_for_item(self, item_id: int) -> Optional[Dict[str, Any]]:
        """
        Get the primary status column and current value for an item.

        Fetches the item, finds its board, detects status columns,
        and returns the first status column with the item's current value.

        Args:
            item_id: The item ID

        Returns:
            Dict with column info and current value, or None:
            {
                'column_id': 'status',
                'column_title': 'Status',
                'current_value': 'Working on it',
                'board_id': 12345,
                'labels': {'0': 'Done', '1': 'Working on it', ...}
            }
        """
        item = self.get_item(item_id)
        if not item:
            return None

        board = item.get('board', {})
        board_id = board.get('id')
        if not board_id:
            return None

        # Get status columns for this board
        status_columns = self.detect_status_columns(int(board_id))
        if not status_columns:
            return None

        # Find the current value in item's column_values
        column_values = item.get('column_values', [])
        primary_status = status_columns[0]  # Use first status column

        current_value = None
        for cv in column_values:
            if cv.get('id') == primary_status['id']:
                current_value = cv.get('text', '')
                break

        return {
            'column_id': primary_status['id'],
            'column_title': primary_status['title'],
            'current_value': current_value,
            'board_id': int(board_id),
            'labels': primary_status['labels']
        }

    def sync_status(
        self,
        item_id: int,
        new_status: str,
        status_mapping: Optional[Dict[str, str]] = None
    ) -> Dict[str, Any]:
        """
        Sync status for a Monday.com item.

        This method handles status synchronization from kanban to Monday.com.
        It detects the status column, maps the kanban status to Monday labels,
        and updates the item.

        Args:
            item_id: The Monday.com item ID
            new_status: The desired status (kanban status or Monday label)
            status_mapping: Optional mapping from kanban status to Monday label
                           e.g., {'in_progress': 'Working on it', 'completed': 'Done'}

        Returns:
            Dict with sync result:
            {
                'success': True/False,
                'item_id': 12345,
                'old_status': 'Working on it',
                'new_status': 'Done',
                'message': 'Status updated successfully'
            }
        """
        try:
            # Get current status column info
            status_info = self.get_status_column_for_item(item_id)

            if not status_info:
                return {
                    'success': False,
                    'item_id': item_id,
                    'message': 'Could not detect status column for item'
                }

            old_status = status_info['current_value']
            board_id = status_info['board_id']
            column_id = status_info['column_id']
            available_labels = status_info['labels']

            # Map the status if a mapping is provided
            target_status = new_status
            if status_mapping and new_status in status_mapping:
                target_status = status_mapping[new_status]

            # Verify the target status is a valid label
            valid_labels = list(available_labels.values())
            if target_status not in valid_labels:
                # Try case-insensitive match
                target_lower = target_status.lower()
                matched = None
                for label in valid_labels:
                    if label.lower() == target_lower:
                        matched = label
                        break

                if matched:
                    target_status = matched
                else:
                    return {
                        'success': False,
                        'item_id': item_id,
                        'old_status': old_status,
                        'message': f"Invalid status '{target_status}'. Valid statuses: {', '.join(valid_labels)}"
                    }

            # Skip update if status is the same
            if old_status == target_status:
                return {
                    'success': True,
                    'item_id': item_id,
                    'old_status': old_status,
                    'new_status': target_status,
                    'message': 'Status unchanged'
                }

            # Update the status
            self.update_item_status(
                item_id=item_id,
                board_id=board_id,
                status_column_id=column_id,
                status_label=target_status
            )

            logger.info(
                f"[{self.id}] Synced item {item_id} status: "
                f"'{old_status}' -> '{target_status}'"
            )

            return {
                'success': True,
                'item_id': item_id,
                'old_status': old_status,
                'new_status': target_status,
                'message': 'Status updated successfully'
            }

        except MondayProviderError as e:
            logger.error(f"[{self.id}] Status sync failed for item {item_id}: {e}")
            return {
                'success': False,
                'item_id': item_id,
                'message': str(e)
            }

        except Exception as e:
            logger.error(f"[{self.id}] Status sync failed for item {item_id}: {e}")
            return {
                'success': False,
                'item_id': item_id,
                'message': f"Sync failed: {str(e)}"
            }

    def create_item(
        self,
        board_id: str,
        title: str,
        description: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None
    ) -> 'CreateItemResult':
        """
        Create a new item in a Monday.com board.

        Args:
            board_id: The Monday.com board ID (numeric or string)
            title: The item name/title
            description: Optional description (will be added to updates/notes)
            metadata: Optional dict with additional fields:
                - status: Status label (e.g., "Working on it", "Done")
                - priority: Priority label (e.g., "High", "Medium", "Low")
                - column_values: Dict of {column_id: value} for custom columns

        Returns:
            CreateItemResult with created item ID and URL or error
        """
        from .provider import CreateItemResult

        if not self.has_credentials():
            return CreateItemResult(
                success=False,
                error="Monday.com API token not configured"
            )

        try:
            # Parse board ID (handle both numeric and string formats)
            try:
                board_id_int = int(board_id)
            except ValueError:
                return CreateItemResult(
                    success=False,
                    error=f"Invalid board ID format: {board_id}"
                )

            # Build GraphQL mutation
            gql_mutation = """
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
            """

            # Build column values from metadata
            column_values = {}
            if metadata:
                # Handle custom column values
                if 'column_values' in metadata:
                    column_values.update(metadata['column_values'])

                # Handle common fields (status, priority)
                # Note: These would need the actual column IDs from the board
                # For v1, we'll just pass through what the caller provides
                if 'status' in metadata and 'status_column_id' in metadata:
                    column_values[metadata['status_column_id']] = {
                        'label': metadata['status']
                    }

            variables = {
                'boardId': board_id_int,
                'itemName': title,
                'columnValues': json.dumps(column_values) if column_values else None
            }

            # Make the request
            data = self._make_request(gql_mutation, variables)
            created_item = data.get('create_item', {})

            if not created_item or not created_item.get('id'):
                return CreateItemResult(
                    success=False,
                    error="Failed to create item - no ID returned from Monday.com"
                )

            item_id = created_item['id']
            item_name = created_item.get('name', title)
            board_info = created_item.get('board', {})

            # Add description as an update if provided
            if description:
                try:
                    self._add_update_to_item(int(item_id), description)
                except Exception as e:
                    logger.warning(f"[{self.id}] Created item {item_id} but failed to add description: {e}")

            # Build the URL
            url = self.get_ticket_url(item_id)

            logger.info(f"[{self.id}] Created item {item_id} on board {board_id}")

            return CreateItemResult(
                success=True,
                ticket_id=item_id,
                url=url,
                message=f"Created item '{item_name}' on board {board_info.get('name', board_id)}",
                raw_data=created_item
            )

        except MondayAuthError as e:
            logger.error(f"[{self.id}] Authentication error creating item: {e}")
            return CreateItemResult(
                success=False,
                error=f"Authentication failed: {str(e)}"
            )

        except MondayProviderError as e:
            logger.error(f"[{self.id}] Error creating item: {e}")
            return CreateItemResult(
                success=False,
                error=str(e)
            )

        except Exception as e:
            logger.error(f"[{self.id}] Unexpected error creating item: {e}")
            return CreateItemResult(
                success=False,
                error=f"Unexpected error: {str(e)}"
            )

    def _add_update_to_item(self, item_id: int, text: str) -> None:
        """
        Add an update (note/comment) to a Monday.com item.

        Args:
            item_id: The item ID
            text: The update text
        """
        gql_mutation = """
        mutation addUpdate($itemId: ID!, $body: String!) {
            create_update(item_id: $itemId, body: $body) {
                id
            }
        }
        """

        self._make_request(gql_mutation, {
            'itemId': item_id,
            'body': text
        })


# Register the provider
IntegrationManager.register_provider('monday', MondayProvider)
